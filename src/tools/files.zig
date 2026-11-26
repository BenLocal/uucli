// SPDX-License-Identifier: GPL-3.0-or-later
//! File listing and single-file transfer over the FTP RPC cases (spec §11.2). Upstream:
//! src/viewer/tools/files.rs, host side src/file_trans.rs. File contents and paths are never logged.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("../wire.zig");
const session_mod = @import("../session.zig");

const log = std.log.scoped(.files);

/// Host result codes (FT_*): 1 is success.
pub const code_ok = 1;
pub const code_canceled = 7;
/// Entry kinds (FileType).
pub const kind_dir = 0;
pub const kind_drive = 3;
pub const kind_file = 4;

const upload_block = 32 * 1024;
/// Our host sends 32 KiB blocks; the official Windows host larger ones, bounded by the SCTP limit.
const max_block = 256 * 1024;
const max_list = 16 * 1024 * 1024;
const reply_timeout: Io.Duration = .fromSeconds(30);

pub const Entry = struct { kind: u64, name: []const u8, size: u64, modified: u64, path: []const u8 };

pub const Error = error{
    /// The host answered with a result code other than 1 (exit 6); see `Files.remote_code`.
    Remote,
    /// No reply in time (exit 6).
    RemoteTimeout,
    /// Malformed or unexpected host message (exit 6).
    InvalidResponse,
    /// The remote path names a folder, not a regular file (exit 6).
    NotAFile,
    /// Ctrl-C / SIGTERM (exit 130 / 0).
    Interrupted,
    /// The session ended (exit 5).
    SessionEnded,
    InvalidRemoteName,
    LocalFile,
} || Allocator.Error || Io.Cancelable;

const Msg = union(enum) {
    data: []u8,
    tick,
    cancel,
    session_end,

    fn deinit(m: Msg, gpa: Allocator) void {
        if (m == .data) gpa.free(m.data);
    }
};

/// A field `1: {1: task, 2: index}` (upstream `id`).
fn idField(b: *wire.Builder, gpa: Allocator, task: u64, index: u64) !void {
    var inner: wire.Builder = .init(gpa);
    defer inner.deinit();
    try inner.int(1, task);
    try inner.int(2, index);
    try b.bytes(1, inner.buf.items);
}

/// All length-delimited fields `n` of a message.
fn allBytes(arena: Allocator, data: []const u8, n: u32) ![]const []const u8 {
    if (!wire.valid(data)) return error.InvalidResponse;
    var out: std.ArrayList([]const u8) = .empty;
    var it: wire.Iterator = .init(data);
    while (it.next() catch null) |f| if (f.number == n and f.value == .bytes) try out.append(arena, f.value.bytes);
    return out.items;
}

/// zlib-inflates a directory/file list (≤ 16 MiB).
pub fn inflate(gpa: Allocator, data: []const u8) ![]u8 {
    var in: Io.Reader = .fixed(data);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    const out = d.reader.allocRemaining(gpa, .limited(max_list + 1)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidResponse,
    };
    if (out.len > max_list) {
        gpa.free(out);
        return error.InvalidResponse;
    }
    return out;
}

/// zlib-deflates (stored blocks; the host only needs valid zlib).
pub fn deflate(gpa: Allocator, data: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var buf: [4096]u8 = undefined;
    var raw = std.compress.flate.Compress.Raw.init(&out.writer, &buf, .zlib) catch return error.OutOfMemory;
    raw.writer.writeAll(data) catch return error.OutOfMemory;
    raw.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Splits a remote target into (directory, name), keeping the host's separator style. No
/// directory means the remote home (`~/`). Null if there is no file name.
pub fn splitRemote(remote: []const u8) ?struct { []const u8, []const u8 } {
    const cut = std.mem.lastIndexOfAny(u8, remote, "/\\");
    const dir = if (cut) |i| remote[0..i] else "";
    const name = if (cut) |i| remote[i + 1 ..] else remote;
    if (name.len == 0) return null;
    // "/x" keeps the root; "C:\x" keeps "C:\" (a bare drive letter is not a directory).
    const d = if (cut) |i| (if (dir.len == 0 or dir[dir.len - 1] == ':') remote[0 .. i + 1] else dir) else "~/";
    return .{ d, name };
}

/// A host-supplied relative path must be plain components (no `..`, absolute paths or drives).
fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var any = false;
    while (it.next()) |c| {
        any = true;
        if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
    }
    return any;
}

pub const Progress = struct {
    w: *Io.Writer,
    started: Io.Timestamp,
    last: Io.Timestamp,
    shown: bool = false,
};

/// Ids shared by requests and tasks, unique per process (upstream starts at 100).
var next_id: std.atomic.Value(u64) = .init(100);

pub const Files = struct {
    io: Io,
    gpa: Allocator,
    link: session_mod.Link,
    queue_buf: [1024]Msg = undefined,
    queue: Io.Queue(Msg) = undefined,
    overflow: std.atomic.Value(bool) = .init(false),
    canceled: bool = false,
    /// The host's result code of the last `error.Remote`.
    remote_code: u64 = 0,
    progress: ?Progress = null,
    done: u64 = 0,
    total: u64 = 0,

    pub fn init(f: *Files, io: Io, gpa: Allocator, link: session_mod.Link) void {
        f.* = .{ .io = io, .gpa = gpa, .link = link };
        f.queue = .init(&f.queue_buf);
    }

    pub fn deinit(f: *Files) void {
        f.queue.close(f.io);
        while (f.queue.getOneUncancelable(f.io)) |m| m.deinit(f.gpa) else |_| {}
    }

    pub fn tool(f: *Files) session_mod.Tool {
        return .{ .ptr = f, .deliverFn = deliver };
    }

    pub fn post(f: *Files, m: Msg) void {
        const n = f.queue.putUncancelable(f.io, &.{m}, 0) catch 0;
        if (n == 0) {
            m.deinit(f.gpa);
            f.overflow.store(true, .release);
        }
    }

    /// Session task: FTP requests arrive on FILE, replies on FILE or CONTROL.
    fn deliver(ptr: *anyopaque, channel: usize, data: []const u8) void {
        const f: *Files = @ptrCast(@alignCast(ptr));
        if (channel != wire.file and channel != wire.control) return;
        const d = f.gpa.dupe(u8, data) catch return f.overflow.store(true, .release);
        f.post(.{ .data = d });
    }

    pub fn ticker(f: *Files) Io.Cancelable!void {
        while (true) {
            try f.io.sleep(.fromMilliseconds(250), .awake);
            f.post(.tick);
        }
    }

    fn id() u64 {
        return next_id.fetchAdd(1, .monotonic);
    }

    /// The next message (caller frees). `cancelable`: a `.cancel` ends the operation.
    fn recv(f: *Files, timeout: Io.Duration, cancelable: bool) Error![]u8 {
        const deadline = Io.Clock.awake.now(f.io).addDuration(timeout);
        while (true) {
            if (f.overflow.load(.acquire)) return error.SessionEnded;
            if (cancelable and f.canceled) return error.Interrupted;
            const m = f.queue.getOne(f.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => return error.SessionEnded,
            };
            switch (m) {
                .data => |d| return d,
                .tick => {
                    f.drawProgress(false);
                    if (Io.Clock.awake.now(f.io).compare(.gt, deadline)) return error.RemoteTimeout;
                },
                .cancel => f.canceled = true,
                .session_end => return error.SessionEnded,
            }
        }
    }

    fn sendControl(f: *Files, data: []const u8) Error!void {
        f.link.send(wire.control, data) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.SessionEnded,
        };
    }

    const Reply = struct {
        msg: []u8,
        body: []const u8,
        fn deinit(r: Reply, gpa: Allocator) void {
            gpa.free(r.msg);
        }
    };

    /// `rpc(rid, request, case, body)` on CONTROL; waits for the response with case `expected`.
    fn request(f: *Files, case: u32, body: []const u8, expected: u32) Error!Reply {
        const rid = id();
        const req = try wire.rpc(f.gpa, rid, false, case, body);
        defer f.gpa.free(req);
        try f.sendControl(req);
        while (true) {
            const m = try f.recv(reply_timeout, true);
            errdefer f.gpa.free(m);
            const r = wire.blob(m, wire.kind.rpc_response) orelse {
                f.gpa.free(m);
                continue;
            };
            const h = wire.blob(r, 1) orelse {
                f.gpa.free(m);
                continue;
            };
            if (wire.uint(h, 1) != rid) {
                f.gpa.free(m);
                continue;
            }
            const cases = wire.blob(r, 4) orelse return error.InvalidResponse;
            const out = wire.blob(cases, expected) orelse return error.InvalidResponse;
            return .{ .msg = m, .body = out };
        }
    }

    fn check(f: *Files, code: u64) Error!void {
        if (code == code_ok) return;
        f.remote_code = code;
        return error.Remote;
    }

    /// Lists a remote directory (strings in `arena`).
    pub fn list(f: *Files, arena: Allocator, path: []const u8) Error![]Entry {
        f.canceled = false;
        var b: wire.Builder = .init(f.gpa);
        defer b.deinit();
        try idField(&b, f.gpa, id(), 0);
        try b.bytes(2, path);
        const r = try f.request(10, b.buf.items, 7);
        defer r.deinit(f.gpa);
        try f.check(wire.uint(r.body, 4));
        const rows = if (wire.blob(r.body, 5)) |z| blk: {
            const d = try inflate(arena, z);
            break :blk try allBytes(arena, d, 1);
        } else try allBytes(arena, r.body, 3);
        const out = try arena.alloc(Entry, rows.len);
        for (rows, out) |row, *e| {
            const name = wire.blob(row, 2) orelse "";
            const p = wire.blob(row, 5) orelse "";
            if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(p)) return error.InvalidResponse;
            e.* = .{
                .kind = wire.uint(row, 1),
                .name = try arena.dupe(u8, name),
                .size = wire.uint(row, 3),
                .modified = wire.uint(row, 4),
                .path = try arena.dupe(u8, p),
            };
        }
        return out;
    }

    /// True if `remote` (dir + name) exists on the host.
    pub fn remoteExists(f: *Files, arena: Allocator, remote: []const u8) Error!bool {
        const parts = splitRemote(remote) orelse return error.InvalidRemoteName;
        const entries = f.list(arena, parts[0]) catch |err| switch (err) {
            error.Remote => return false,
            else => |e| return e,
        };
        for (entries) |e| if (std.mem.eql(u8, e.name, parts[1])) return true;
        return false;
    }

    pub fn upload(f: *Files, file: Io.File, remote: []const u8) Error!void {
        f.canceled = false;
        const io = f.io;
        const st = file.stat(io) catch return error.LocalFile;
        if (st.kind != .file) return error.LocalFile;
        const size = st.size;
        const parts = splitRemote(remote) orelse return error.InvalidRemoteName;
        if (!safeRelative(parts[1])) return error.InvalidRemoteName;
        const task = id();
        f.startProgress(size);

        // FileInfo {1 rel_path, 2 size, 3 modified (unix s)}; the official Windows host rejects a
        // request without the modified time or the task unique id (7).
        var info: wire.Builder = .init(f.gpa);
        defer info.deinit();
        try info.bytes(1, parts[1]);
        try info.int(2, size);
        try info.int(3, @intCast(@max(0, st.mtime.toSeconds())));
        var flist: wire.Builder = .init(f.gpa);
        defer flist.deinit();
        try flist.bytes(1, info.buf.items);
        const z = try deflate(f.gpa, flist.buf.items);
        defer f.gpa.free(z);
        var rnd: [16]u8 = undefined;
        io.random(&rnd);
        rnd[6] = (rnd[6] & 0x0f) | 0x40;
        rnd[8] = (rnd[8] & 0x3f) | 0x80;
        const hx = std.fmt.bytesToHex(rnd, .lower);
        var unique_buf: [36]u8 = undefined;
        const unique = std.fmt.bufPrint(&unique_buf, "{s}-{s}-{s}-{s}-{s}", .{ hx[0..8], hx[8..12], hx[12..16], hx[16..20], hx[20..32] }) catch unreachable;
        var body: wire.Builder = .init(f.gpa);
        defer body.deinit();
        try idField(&body, f.gpa, task, 0);
        try body.bytes(2, parts[0]);
        try body.bytes(3, info.buf.items);
        try body.int(4, 1);
        // Hosts with list compression only register files from list_data (6); keep the inline copy.
        try body.bytes(6, z);
        try body.bytes(7, unique);

        f.uploadSteps(file, task, size, body.buf.items) catch |err| {
            // Tell the host the task is over (status 7 = canceled); best effort, no reply awaited.
            var b: wire.Builder = .init(f.gpa);
            defer b.deinit();
            idField(&b, f.gpa, task, 1) catch return err;
            b.int(2, code_canceled) catch return err;
            const req = wire.rpc(f.gpa, id(), false, 9, b.buf.items) catch return err;
            defer f.gpa.free(req);
            f.sendControl(req) catch {};
            return err;
        };
        f.drawProgress(true);
    }

    fn uploadSteps(f: *Files, file: Io.File, task: u64, size: u64, body: []const u8) Error!void {
        {
            const r = try f.request(1, body, 1);
            defer r.deinit(f.gpa);
            try f.check(wire.uint(r.body, 3));
        }
        {
            var ask: wire.Builder = .init(f.gpa);
            defer ask.deinit();
            try idField(&ask, f.gpa, task, 1);
            try ask.int(3, size);
            const r = try f.request(3, ask.buf.items, 3);
            defer r.deinit(f.gpa);
            try f.check(wire.uint(r.body, 3));
            // A skip or resume strategy is not supported.
            if (wire.uint(r.body, 2) != 0 or wire.uint(r.body, 4) != 0) return error.InvalidResponse;
        }
        var rbuf: [upload_block]u8 = undefined;
        var reader = file.readerStreaming(f.io, &.{});
        var block: u64 = 0;
        while (true) {
            const n = reader.interface.readSliceShort(&rbuf) catch return error.LocalFile;
            if (n == 0) break;
            var b: wire.Builder = .init(f.gpa);
            defer b.deinit();
            try idField(&b, f.gpa, task, 1);
            try b.int(2, block);
            try b.bytes(3, rbuf[0..n]);
            const r = try f.request(4, b.buf.items, 4);
            defer r.deinit(f.gpa);
            try f.check(wire.uint(r.body, 3));
            if (wire.uint(r.body, 2) != block or wire.uint(r.body, 4) != n) return error.InvalidResponse;
            f.done += n;
            block += 1;
            if (n < rbuf.len) break;
        }
        if (f.done != size) return error.LocalFile;
        var b: wire.Builder = .init(f.gpa);
        defer b.deinit();
        try idField(&b, f.gpa, task, 1);
        try b.int(2, 1);
        const r = try f.request(9, b.buf.items, 6);
        defer r.deinit(f.gpa);
        try f.check(wire.uint(r.body, 2));
    }

    /// Downloads one regular file into `out` (the caller's `.uucli-part` file).
    pub fn download(f: *Files, remote: []const u8, out: Io.File) Error!void {
        f.canceled = false;
        const task = id();
        var accepted = false;
        var ended = false;
        f.downloadSteps(remote, out, task, &accepted, &ended) catch |err| {
            if (accepted and !ended) f.rejectOutstanding(task);
            return err;
        };
        f.drawProgress(true);
    }

    const Pending = std.AutoHashMapUnmanaged(u64, []u8);

    fn downloadSteps(f: *Files, remote: []const u8, out: Io.File, task: u64, accepted: *bool, ended: *bool) Error!void {
        var b: wire.Builder = .init(f.gpa);
        defer b.deinit();
        try idField(&b, f.gpa, task, 0);
        try b.bytes(2, remote);
        const r = try f.request(2, b.buf.items, 2);
        defer r.deinit(f.gpa);
        try f.check(wire.uint(r.body, 2));
        accepted.* = true;
        var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const rows = if (wire.blob(r.body, 5)) |z| try allBytes(arena, try inflate(arena, z), 1) else try allBytes(arena, r.body, 3);
        if (wire.blob(r.body, 4)) |folder| if (folder.len != 0) return error.NotAFile;
        if (rows.len != 1) return error.InvalidResponse;
        if (!safeRelative(wire.blob(rows[0], 1) orelse "")) return error.InvalidResponse;
        const size = wire.uint(rows[0], 2);
        f.startProgress(size);

        var wbuf: [64 * 1024]u8 = undefined;
        var w = out.writer(f.io, &wbuf);
        var opened = false;
        var completed = false;
        var written: u64 = 0;
        var next: ?u64 = null;
        var pending: Pending = .empty;
        defer {
            var it = pending.valueIterator();
            while (it.next()) |v| f.gpa.free(v.*);
            pending.deinit(f.gpa);
        }

        while (true) {
            const m = try f.recv(reply_timeout, true);
            defer f.gpa.free(m);
            const rpc_body = wire.blob(m, wire.kind.rpc_request) orelse continue;
            const ftp = wire.blob(rpc_body, 8) orelse continue;
            const rid = wire.uint(wire.blob(rpc_body, 1) orelse "", 1);
            // The request case is the first length-delimited field.
            var it: wire.Iterator = .init(ftp);
            const field = blk: {
                while (it.next() catch return error.InvalidResponse) |x| if (x.value == .bytes) break :blk x;
                return error.InvalidResponse;
            };
            const body = field.value.bytes;
            const tid = wire.blob(body, 1) orelse "";
            if (wire.uint(tid, 1) != task) return error.InvalidResponse;
            const index = wire.uint(tid, 2);
            var reply: wire.Builder = .init(f.gpa);
            defer reply.deinit();
            try idField(&reply, f.gpa, task, index);
            var code: u64 = code_ok;
            const response: u32 = switch (field.number) {
                3 => blk: {
                    if (index != 1 or opened or completed or wire.uint(body, 3) != size) code = 3 else opened = true;
                    try reply.int(3, code);
                    break :blk 3;
                },
                4 => blk: {
                    const blockn = wire.uint(body, 2);
                    const chunk = wire.blob(body, 3) orelse "";
                    if (index != 1 or !opened or chunk.len > max_block or (next != null and blockn < next.?) or
                        pending.contains(blockn) or pending.count() >= 32)
                    {
                        code = 3;
                    } else {
                        try pending.put(f.gpa, blockn, try f.gpa.dupe(u8, chunk));
                        // Block ids start at 1 (official host) or 0 (ours, out of order in a window of
                        // 16): the base is fixed when block 0 arrives or 16 blocks are buffered.
                        if (next == null and (blockn == 0 or pending.count() >= 16)) next = minKey(&pending);
                        if (!(try flushBlocks(f, &w.interface, &pending, &next, &written, size))) code = 6;
                    }
                    try reply.int(2, blockn);
                    try reply.int(3, code);
                    try reply.int(4, chunk.len);
                    break :blk 4;
                },
                9 => blk: {
                    if (index == std.math.maxInt(u64)) {
                        ended.* = true;
                        try f.check(wire.uint(body, 2));
                        if (!completed) return error.InvalidResponse;
                        return;
                    }
                    if (index == 1 and opened) {
                        if (next == null) next = minKey(&pending);
                        const ok = try flushBlocks(f, &w.interface, &pending, &next, &written, size);
                        w.interface.flush() catch return error.LocalFile;
                        opened = false;
                        if (!ok or wire.uint(body, 2) != 1 or written != size or pending.count() != 0) code = 6 else completed = true;
                    } else code = 3;
                    try reply.int(2, code);
                    break :blk 6;
                },
                else => return error.InvalidResponse,
            };
            const resp = try wire.rpc(f.gpa, rid, true, response, reply.buf.items);
            defer f.gpa.free(resp);
            try f.sendControl(resp);
            if (code != code_ok) {
                f.remote_code = code;
                return error.Remote;
            }
        }
    }

    fn minKey(p: *const Pending) ?u64 {
        var min: ?u64 = null;
        var it = p.keyIterator();
        while (it.next()) |k| if (min == null or k.* < min.?) {
            min = k.*;
        };
        return min;
    }

    /// Writes buffered blocks in order from `next`. False if the file would exceed `size`.
    fn flushBlocks(f: *Files, w: *Io.Writer, p: *Pending, next: *?u64, written: *u64, size: u64) Error!bool {
        while (next.*) |n| {
            const kv = p.fetchRemove(n) orelse break;
            defer f.gpa.free(kv.value);
            if (written.* + kv.value.len > size) return false;
            w.writeAll(kv.value) catch return error.LocalFile;
            written.* += kv.value.len;
            f.done += kv.value.len;
            next.* = n + 1;
        }
        return true;
    }

    /// After a failed or canceled download, answer the host's outstanding requests for `task` with
    /// status 7 for up to 3 s, so it releases its transfer window.
    fn rejectOutstanding(f: *Files, task: u64) void {
        const deadline = Io.Clock.awake.now(f.io).addDuration(.fromSeconds(3));
        while (Io.Clock.awake.now(f.io).compare(.lt, deadline)) {
            const m = f.recv(.fromSeconds(3), false) catch return;
            defer f.gpa.free(m);
            const r = wire.blob(m, wire.kind.rpc_request) orelse continue;
            const ftp = wire.blob(r, 8) orelse continue;
            const rid = wire.uint(wire.blob(r, 1) orelse "", 1);
            const map = [_][3]u32{ .{ 3, 3, 3 }, .{ 4, 4, 3 }, .{ 9, 6, 2 } };
            for (map) |e| {
                const body = wire.blob(ftp, e[0]) orelse continue;
                const tid = wire.blob(body, 1) orelse "";
                if (wire.uint(tid, 1) != task) continue;
                if (e[0] == 9 and wire.uint(tid, 2) == std.math.maxInt(u64)) return;
                var reply: wire.Builder = .init(f.gpa);
                defer reply.deinit();
                reply.bytes(1, tid) catch return;
                reply.int(e[2], code_canceled) catch return;
                if (e[0] == 4) reply.int(2, wire.uint(body, 2)) catch return;
                const resp = wire.rpc(f.gpa, rid, true, e[1], reply.buf.items) catch return;
                defer f.gpa.free(resp);
                f.sendControl(resp) catch return;
            }
        }
    }

    // --- Progress (stderr, tty only) ----------------------------------------------------------

    pub fn showProgress(f: *Files, w: *Io.Writer) void {
        const now = Io.Clock.awake.now(f.io);
        f.progress = .{ .w = w, .started = now, .last = now };
    }

    fn startProgress(f: *Files, total: u64) void {
        f.total = total;
        f.done = 0;
        if (f.progress) |*p| p.started = Io.Clock.awake.now(f.io);
    }

    /// Widened: `done * ns_per_s` overflows u64 above about 17 GiB.
    fn bytesPerSecond(done: u64, elapsed_ns: u64) u64 {
        return std.math.lossyCast(u64, @as(u128, done) * std.time.ns_per_s / elapsed_ns);
    }

    fn drawProgress(f: *Files, final: bool) void {
        const p = if (f.progress) |*x| x else return;
        const now = Io.Clock.awake.now(f.io);
        const elapsed_ns: u64 = @intCast(@max(1, p.started.durationTo(now).nanoseconds));
        const rate = bytesPerSecond(f.done, elapsed_ns);
        var eta_buf: [24]u8 = undefined;
        const eta = if (rate == 0 or f.done >= f.total) "" else std.fmt.bufPrint(&eta_buf, "  ETA {d}s", .{(f.total - f.done) / rate}) catch "";
        p.w.print("\r{d}/{d} bytes  {d} KiB/s{s}\x1b[K", .{ f.done, f.total, rate / 1024, eta }) catch return;
        if (final) p.w.writeByte('\n') catch {};
        p.w.flush() catch {};
        p.shown = true;
    }
};

const testing = std.testing;

test "splitRemote keeps the host separator" {
    const cases = [_]struct { []const u8, ?[2][]const u8 }{
        .{ "C:\\Users\\Public\\Downloads\\a.bin", .{ "C:\\Users\\Public\\Downloads", "a.bin" } },
        .{ "C:\\a.bin", .{ "C:\\", "a.bin" } },
        .{ "/tmp/a.bin", .{ "/tmp", "a.bin" } },
        .{ "/a.bin", .{ "/", "a.bin" } },
        .{ "a.bin", .{ "~/", "a.bin" } },
        .{ "/tmp/", null },
    };
    for (cases) |c| {
        const got = splitRemote(c[0]);
        if (c[1]) |want| {
            try testing.expectEqualStrings(want[0], got.?[0]);
            try testing.expectEqualStrings(want[1], got.?[1]);
        } else try testing.expect(got == null);
    }
}

test "safeRelative, deflate/inflate" {
    try testing.expect(safeRelative("a.bin"));
    try testing.expect(safeRelative("d/a.bin"));
    for ([_][]const u8{ "", "/a", "..", "a/../b", "C:x", "\\a" }) |bad| try testing.expect(!safeRelative(bad));
    const gpa = testing.allocator;
    const z = try deflate(gpa, "hello files");
    defer gpa.free(z);
    try testing.expectEqual(@as(u8, 0x78), z[0]);
    const back = try inflate(gpa, z);
    defer gpa.free(back);
    try testing.expectEqualStrings("hello files", back);
}

test {
    std.testing.refAllDecls(Files);
}

test "transfer rate of files above 17 GiB" {
    const gib: u64 = 1024 * 1024 * 1024;
    try testing.expectEqual(20 * gib / 10, Files.bytesPerSecond(20 * gib, 10 * std.time.ns_per_s));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), Files.bytesPerSecond(std.math.maxInt(u64), 1));
}

test "safeRelative rejects traversal with either host separator" {
    for ([_][]const u8{ ".", "./a", "a/./b", "a/..", "a\\..\\b", "a/..\\b", "\\\\server\\share", "d/a:stream" }) |path|
        try testing.expect(!safeRelative(path));
    for ([_][]const u8{ "dir\\a.bin", "dir/sub/file", "...", "a..b", "file name.bin" }) |path|
        try testing.expect(safeRelative(path));
}
