// SPDX-License-Identifier: GPL-3.0-or-later
//! Remote terminal over TERM frames on BINARY (spec §11.1). Upstream: src/viewer/tools/terminal.rs,
//! src/viewer/tools/cli.rs, host side src/terminal.rs. Terminal contents are never logged.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("../wire.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;

const log = std.log.scoped(.terminal);

pub const Kind = struct {
    pub const open = 1;
    pub const stdin = 2;
    pub const resize = 3;
    pub const close = 4;
    pub const stdout = 5;
    pub const exit = 6;
    pub const failure = 8;
    pub const list_req = 9;
    pub const list_resp = 10;
    pub const kill_req = 11;
    pub const kill_resp = 12;
    pub const open_resp = 13;
};

const header_len = 16;
/// Cap on the cleaned text `exec` keeps while waiting for its end marker.
pub const max_exec_output = 16 * 1024 * 1024;
/// Cap on the command `exec` sends (before encoding).
pub const max_exec_command = 8 * 1024;
const max_payload = 1024 * 1024;
const max_buffer = 2 * 1024 * 1024;
const max_stdin_chunk = 16 * 1024;

/// `"TERM" 01 KIND 00 00 SESSION(u32 le) LEN(u32 le) PAYLOAD`
pub fn encode(gpa: Allocator, kind: u8, session: u32, payload: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, header_len + payload.len);
    @memcpy(out[0..5], "TERM\x01");
    out[5] = kind;
    out[6] = 0;
    out[7] = 0;
    std.mem.writeInt(u32, out[8..12], session, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(payload.len), .little);
    @memcpy(out[16..], payload);
    return out;
}

pub const Frame = struct { kind: u8, session: u32, payload: []const u8 };

/// Reassembles TERM frames from BINARY messages (a frame may span messages).
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Bytes of `buf` already returned as frames; dropped on the next `push`.
    consumed: usize = 0,

    pub fn deinit(d: *Decoder, gpa: Allocator) void {
        d.buf.deinit(gpa);
    }

    /// Appends `data`; frames are then read with `next` (valid until the next `push`).
    pub fn push(d: *Decoder, gpa: Allocator, data: []const u8) !void {
        if (d.consumed != 0) {
            const rest = d.buf.items.len - d.consumed;
            std.mem.copyForwards(u8, d.buf.items[0..rest], d.buf.items[d.consumed..]);
            d.buf.shrinkRetainingCapacity(rest);
            d.consumed = 0;
        }
        if (d.buf.items.len + data.len > max_buffer) return error.TerminalBufferLimit;
        try d.buf.appendSlice(gpa, data);
    }

    pub fn next(d: *Decoder) !?Frame {
        const b = d.buf.items[d.consumed..];
        if (b.len < header_len) return null;
        if (!std.mem.eql(u8, b[0..5], "TERM\x01") or b[5] < 1 or b[5] > 16) return error.InvalidTermHeader;
        const len = std.mem.readInt(u32, b[12..16], .little);
        if (len > max_payload) return error.TermPayloadLimit;
        if (b.len < header_len + len) return null;
        d.consumed += header_len + len;
        return .{ .kind = b[5], .session = std.mem.readInt(u32, b[8..12], .little), .payload = b[16 .. 16 + len] };
    }
};

/// `envelope(id, 21, {1: {1: id}, 28: ""})`: the terminal environment check.
pub fn checkEnvRequest(gpa: Allocator, id: u64) Allocator.Error![]u8 {
    var head: wire.Builder = .init(gpa);
    defer head.deinit();
    try head.int(1, id);
    var b: wire.Builder = .init(gpa);
    defer b.deinit();
    try b.bytes(1, head.buf.items);
    try b.bytes(28, "");
    return wire.envelope(gpa, id, wire.kind.rpc_request, b.buf.items);
}

const Msg = union(enum) {
    reply: []u8,
    output: []u8,
    exit: i64,
    failed,
    input: []u8,
    input_end,
    resize,
    tick,
    session_end,

    fn deinit(m: Msg, gpa: Allocator) void {
        switch (m) {
            .reply, .output, .input => |d| gpa.free(d),
            else => {},
        }
    }
};

pub const SessionInfo = struct { id: u32, name: []const u8, state: []const u8 };

pub const Outcome = union(enum) {
    /// `~.` or end of input: the remote session keeps running.
    detached: u32,
    /// The remote shell exited.
    exited: i64,
};

pub const Error = error{
    /// The host answered a request with an error (exit 6).
    Rejected,
    /// The session no longer exists (attach to an unknown id).
    NoSuchSession,
    /// No answer in time (exit 6).
    RemoteTimeout,
    /// The session or the TERM stream failed (exit 5).
    SessionEnded,
    InvalidResponse,
    /// `exec`: the command did not finish within its timeout (exit 6).
    CommandTimeout,
    /// `exec`: the command printed more than `max_exec_output` (exit 6).
    OutputLimit,
} || Allocator.Error || Io.Cancelable;

pub const Terminal = struct {
    io: Io,
    gpa: Allocator,
    session: *Session,
    queue_buf: [1024]Msg = undefined,
    queue: Io.Queue(Msg) = undefined,
    mutex: Io.Mutex = .init,
    /// The (kind, key) a request waits for.
    want: ?[2]u64 = null,
    /// The attached terminal session; output for others is dropped.
    current: ?u32 = null,
    decoder: Decoder = .{},
    overflow: std.atomic.Value(bool) = .init(false),
    next_id: u32 = 1,
    rpc_id: u64 = 10,

    pub fn init(t: *Terminal, io: Io, gpa: Allocator, s: *Session) void {
        t.* = .{ .io = io, .gpa = gpa, .session = s };
        t.queue = .init(&t.queue_buf);
    }

    pub fn deinit(t: *Terminal) void {
        t.queue.close(t.io);
        while (t.queue.getOneUncancelable(t.io)) |m| m.deinit(t.gpa) else |_| {}
        t.decoder.deinit(t.gpa);
    }

    pub fn tool(t: *Terminal) session_mod.Tool {
        return .{ .ptr = t, .deliverFn = deliver };
    }

    /// Wakes the terminal loop (from other tasks: session end, SIGWINCH).
    pub fn post(t: *Terminal, m: Msg) void {
        const n = t.queue.putUncancelable(t.io, &.{m}, 0) catch 0;
        if (n == 0) {
            m.deinit(t.gpa);
            t.overflow.store(true, .release);
        }
    }

    /// Session task: never blocks.
    fn deliver(ptr: *anyopaque, channel: usize, data: []const u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ptr));
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        // RPC answers (check_env) come on CONTROL or, from the official Mac host, on BINARY.
        if (channel == wire.control or (channel == wire.binary and !std.mem.startsWith(u8, data, "TERM"))) {
            const r = wire.blob(data, wire.kind.rpc_response) orelse return;
            const h = wire.blob(r, 1) orelse return;
            const body = wire.blob(r, 24) orelse return;
            t.answer(.{ 24, wire.uint(h, 1) }, body);
            return;
        }
        if (channel != wire.binary) return;
        t.decoder.push(t.gpa, data) catch |err| return t.fail(err);
        while (t.decoder.next() catch |err| return t.fail(err)) |f| {
            const mine = t.current != null and t.current.? == f.session;
            switch (f.kind) {
                Kind.stdout => if (mine) {
                    const d = t.gpa.dupe(u8, f.payload) catch return t.fail(error.OutOfMemory);
                    t.post(.{ .output = d });
                },
                Kind.exit => if (mine) t.post(.{ .exit = exitCode(f.payload) }),
                Kind.failure => if (mine) t.post(.failed),
                Kind.open_resp => {
                    // Our-style hosts put the session in the header; the official Windows host answers
                    // with header 0, so only a nonzero header overrides the JSON body.
                    const id = if (f.session != 0) f.session else sessionIdOf(f.payload);
                    if (t.want != null and t.want.?[0] == Kind.open_resp) t.current = id;
                    t.answer(.{ Kind.open_resp, 0 }, f.payload);
                },
                else => t.answer(.{ f.kind, f.session }, f.payload),
            }
        }
    }

    fn fail(t: *Terminal, err: anyerror) void {
        log.warn("terminal stream failed: {t}", .{err});
        t.post(.failed);
    }

    fn answer(t: *Terminal, key: [2]u64, payload: []const u8) void {
        const w = t.want orelse return;
        if (w[0] != key[0] or w[1] != key[1]) return;
        t.want = null;
        const d = t.gpa.dupe(u8, payload) catch return t.fail(error.OutOfMemory);
        t.post(.{ .reply = d });
    }

    fn send(t: *Terminal, channel: usize, data: []const u8) Error!void {
        t.session.send(channel, data) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.SessionEnded,
        };
    }

    fn sendFrame(t: *Terminal, kind: u8, id: u32, payload: []const u8) Error!void {
        const f = try encode(t.gpa, kind, id, payload);
        defer t.gpa.free(f);
        try t.send(wire.binary, f);
    }

    /// Sends a request and waits for its answer, or null after `timeout`. The caller frees it.
    fn request(t: *Terminal, key: [2]u64, channel: usize, data: []const u8, timeout: Io.Duration) Error!?[]u8 {
        {
            t.mutex.lockUncancelable(t.io);
            defer t.mutex.unlock(t.io);
            t.want = key;
        }
        defer {
            t.mutex.lockUncancelable(t.io);
            t.want = null;
            t.mutex.unlock(t.io);
        }
        try t.send(channel, data);
        const deadline = Io.Clock.awake.now(t.io).addDuration(timeout);
        while (true) {
            const m = t.queue.getOne(t.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => return error.SessionEnded,
            };
            switch (m) {
                .reply => |d| return d,
                .tick => if (Io.Clock.awake.now(t.io).compare(.gt, deadline)) return null,
                .session_end, .failed => return error.SessionEnded,
                else => m.deinit(t.gpa),
            }
            if (t.overflow.load(.acquire)) return error.SessionEnded;
        }
    }

    /// Ticks for request deadlines; runs until canceled.
    pub fn ticker(t: *Terminal) Io.Cancelable!void {
        while (true) {
            try t.io.sleep(.fromMilliseconds(250), .awake);
            t.post(.tick);
        }
    }

    /// check_env: no answer within 3 s means "not implemented" (official Windows host), not an error.
    pub fn checkEnv(t: *Terminal) Error!void {
        const id = t.rpc_id;
        t.rpc_id += 1;
        const req = try checkEnvRequest(t.gpa, id);
        defer t.gpa.free(req);
        const body = (try t.request(.{ 24, id }, wire.control, req, .fromSeconds(3))) orelse return;
        defer t.gpa.free(body);
        if (wire.uint(body, 1) != 0) {
            const message = wire.blob(body, 2) orelse "";
            log.info("check_env: code {d}: {s}", .{ wire.uint(body, 1), message[0..@min(message.len, 80)] });
            return error.Rejected;
        }
    }

    /// Lists the host's terminal sessions (strings in `arena`).
    pub fn list(t: *Terminal, arena: Allocator) Error![]SessionInfo {
        const id = t.next_id;
        t.next_id += 1;
        const req = try encode(t.gpa, Kind.list_req, id, "");
        defer t.gpa.free(req);
        const body = (try t.request(.{ Kind.list_resp, id }, wire.binary, req, .fromSeconds(30))) orelse return error.RemoteTimeout;
        defer t.gpa.free(body);
        return parseList(arena, body);
    }

    /// Opens a new session (`id` 0) or reattaches to `id`; returns the attached session id.
    pub fn open(t: *Terminal, arena: Allocator, id: u32, cols: u16, rows: u16) Error!u32 {
        if (id != 0) {
            const sessions = try t.list(arena);
            for (sessions) |s| {
                if (s.id == id) break;
            } else return error.NoSuchSession;
        }
        var buf: [96]u8 = undefined;
        // The official Windows host rejects OPEN without "option"; "none" is its plain mode.
        const payload = std.fmt.bufPrint(&buf, "{{\"cols\":{d},\"rows\":{d},\"option\":\"none\"}}", .{ @max(cols, 1), @max(rows, 1) }) catch unreachable;
        const req = try encode(t.gpa, Kind.open, id, payload);
        defer t.gpa.free(req);
        const body = (try t.request(.{ Kind.open_resp, 0 }, wire.binary, req, .fromSeconds(30))) orelse return error.RemoteTimeout;
        defer t.gpa.free(body);
        if (codeOf(body) != 0) {
            log.info("open: code {d}: {s}", .{ codeOf(body), body[0..@min(body.len, 200)] });
            return error.Rejected;
        }
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        // The official Windows host answers without an id and serves session 0.
        if (t.current == null) t.current = 0;
        return t.current.?;
    }

    pub fn kill(t: *Terminal, id: u32) Error!void {
        const req = try encode(t.gpa, Kind.kill_req, id, "");
        defer t.gpa.free(req);
        const body = (try t.request(.{ Kind.kill_resp, id }, wire.binary, req, .fromSeconds(30))) orelse return error.RemoteTimeout;
        defer t.gpa.free(body);
        if (codeOf(body) != 0) return error.Rejected;
    }

    pub fn write(t: *Terminal, id: u32, data: []const u8) Error!void {
        var rest = data;
        while (rest.len != 0) {
            const n = @min(rest.len, max_stdin_chunk);
            try t.sendFrame(Kind.stdin, id, rest[0..n]);
            rest = rest[n..];
        }
    }

    pub fn resize(t: *Terminal, id: u32, cols: u16, rows: u16) Error!void {
        var buf: [64]u8 = undefined;
        try t.sendFrame(Kind.resize, id, std.fmt.bufPrint(&buf, "{{\"cols\":{d},\"rows\":{d}}}", .{ @max(cols, 1), @max(rows, 1) }) catch unreachable);
    }

    /// Detaches; the remote session keeps running.
    pub fn close(t: *Terminal, id: u32) void {
        t.sendFrame(Kind.close, id, "") catch {};
    }

    /// `exec`: types `line` (from `execLine`) into session `id` and waits for the end marker.
    /// Output is cleaned with `Stripper` into `text`; the result's slices point into it. A shell
    /// that exits before the end marker (the command ran `exit`) ends with that exit code.
    pub fn exec(t: *Terminal, id: u32, line: []const u8, nonce: []const u8, timeout: ?Io.Duration, text: *std.ArrayList(u8)) Error!ExecOutput {
        const deadline = if (timeout) |d| Io.Clock.awake.now(t.io).addDuration(d) else null;
        var strip: Stripper = .{};
        try t.write(id, line);
        while (true) {
            if (t.overflow.load(.acquire)) return error.SessionEnded;
            const m = t.queue.getOne(t.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => return error.SessionEnded,
            };
            defer m.deinit(t.gpa);
            switch (m) {
                .output => |d| {
                    if (text.items.len + d.len > max_exec_output) return error.OutputLimit;
                    try strip.feed(t.gpa, text, d);
                    if (extract(text.items, nonce)) |r| return r;
                },
                .exit => |code| return extract(text.items, nonce) orelse .{ .output = afterStart(text.items, nonce), .code = code },
                .failed, .session_end => return error.SessionEnded,
                .input_end => {
                    // Ctrl-C / SIGTERM: interrupt the remote command too.
                    t.write(id, "\x03") catch {};
                    return error.Canceled;
                },
                .tick => if (deadline) |dl| if (Io.Clock.awake.now(t.io).compare(.gt, dl)) {
                    t.write(id, "\x03") catch {};
                    return error.CommandTimeout;
                },
                .reply, .input, .resize => {},
            }
        }
    }

    pub const Attach = struct {
        id: u32,
        out: *Io.Writer,
        err: *Io.Writer,
        /// Escape character, null for none. Only used with `tty`.
        escape: ?u8,
        tty: bool,
        /// Window size source for `.resize` messages.
        size: *const fn () [2]u16,
    };

    /// Copies input to the remote session and output to `out` until exit, detach or failure.
    pub fn attach(t: *Terminal, a: Attach) Error!Outcome {
        var line_start = true;
        var escaped = false;
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(t.gpa);
        while (true) {
            if (t.overflow.load(.acquire)) return error.SessionEnded;
            const m = t.queue.getOne(t.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => return error.SessionEnded,
            };
            defer m.deinit(t.gpa);
            switch (m) {
                .output => |d| {
                    a.out.writeAll(d) catch return error.SessionEnded;
                    a.out.flush() catch return error.SessionEnded;
                },
                .exit => |code| return .{ .exited = code },
                .failed, .session_end => return error.SessionEnded,
                .input_end => return .{ .detached = a.id },
                .resize => {
                    const sz = a.size();
                    try t.resize(a.id, sz[0], sz[1]);
                },
                .input => |d| {
                    pending.clearRetainingCapacity();
                    const esc = if (a.tty) a.escape else null;
                    for (d) |b| {
                        if (escaped) {
                            escaped = false;
                            if (b == '.') {
                                try t.write(a.id, pending.items);
                                return .{ .detached = a.id };
                            }
                            if (b == '?') {
                                a.err.print("\r\nSupported escape sequences:\r\n  {c}.  detach (the remote session keeps running)\r\n  {c}?  this help\r\n  {c}{c}  send {c}\r\n", .{ esc.?, esc.?, esc.?, esc.?, esc.? }) catch {};
                                a.err.flush() catch {};
                                continue;
                            }
                            try pending.append(t.gpa, esc.?);
                            if (b == esc.?) {
                                line_start = false;
                                continue;
                            }
                        } else if (esc != null and line_start and b == esc.?) {
                            escaped = true;
                            continue;
                        }
                        try pending.append(t.gpa, b);
                        line_start = b == '\r' or b == '\n';
                    }
                    try t.write(a.id, pending.items);
                },
                .reply, .tick => {},
            }
        }
    }
};

// --- exec ------------------------------------------------------------------------------------

/// Which wrapper `execLine` builds: PowerShell for the official Windows host, sh otherwise.
pub const Shell = enum { powershell, posix };

pub const ExecOutput = struct { output: []const u8, code: i64 };

/// The input line that prints a start marker, runs `command`, prints an end marker with its exit
/// status and exits the shell with it. Markers are `UUCLI-S-NONCE` and `UUCLI-E-NONCE:CODE`; the
/// line builds them by concatenation, so the terminal's echo of the line never contains them.
/// PowerShell gets the command base64-encoded through `Invoke-Expression` in `try`, so quoting and
/// parse errors in it still reach the end marker.
pub fn execLine(gpa: Allocator, shell: Shell, nonce: []const u8, command: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (shell) {
        .powershell => {
            const enc = std.base64.standard.Encoder;
            const b64 = try gpa.alloc(u8, enc.calcSize(command.len));
            defer gpa.free(b64);
            _ = enc.encode(b64, command);
            try out.print(gpa, "$global:LASTEXITCODE=0; Write-Output ('UU'+'CLI-S-{s}'); " ++
                "try {{ Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{s}'))); $o=$? }} " ++
                "catch {{ $_; $o=$false }}; $u=if ($LASTEXITCODE) {{ $LASTEXITCODE }} elseif ($o) {{ 0 }} else {{ 1 }}; " ++
                "Write-Output ('UU'+'CLI-E-{s}:'+$u); exit $u\r", .{ nonce, b64, nonce });
        },
        .posix => {
            try out.print(gpa, "printf '%s\\n' \"UU\"\"CLI-S-{s}\"; eval '", .{nonce});
            for (command) |c| if (c == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, c);
            try out.print(gpa, "'; u=$?; printf '%s\\n' \"UU\"\"CLI-E-{s}:$u\"; exit $u\r", .{nonce});
        },
    }
    return out.toOwnedSlice(gpa);
}

/// The command output between the markers and its exit code, once the end marker line is complete.
pub fn extract(text: []const u8, nonce: []const u8) ?ExecOutput {
    var buf: [64]u8 = undefined;
    const end = std.fmt.bufPrint(&buf, "UUCLI-E-{s}:", .{nonce}) catch return null;
    const body = bodyStart(text, nonce) orelse return null;
    const e = std.mem.indexOfPos(u8, text, body, end) orelse return null;
    const nl = std.mem.indexOfScalarPos(u8, text, e + end.len, '\n') orelse return null;
    const code = std.fmt.parseInt(i64, std.mem.trim(u8, text[e + end.len .. nl], " \t"), 10) catch return null;
    const out_end = if (std.mem.lastIndexOfScalar(u8, text[body..e], '\n')) |i| body + i + 1 else body;
    return .{ .output = text[body..out_end], .code = code };
}

/// Text after the start marker's line (all of it when the marker never came).
fn afterStart(text: []const u8, nonce: []const u8) []const u8 {
    return text[bodyStart(text, nonce) orelse return text..];
}

fn bodyStart(text: []const u8, nonce: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const start = std.fmt.bufPrint(&buf, "UUCLI-S-{s}", .{nonce}) catch return null;
    const s = std.mem.indexOf(u8, text, start) orelse return null;
    return (std.mem.indexOfScalarPos(u8, text, s + start.len, '\n') orelse return null) + 1;
}

/// Turns host terminal output into plain text for `exec`: drops CSI, OSC and two-byte escape
/// sequences, CR and other control characters. `ESC [ n C` (cursor forward), which ConPTY sends
/// for runs of spaces, becomes n spaces. Screen redraws are not interpreted.
pub const Stripper = struct {
    state: enum { text, esc, csi, osc, osc_esc } = .text,
    param: u32 = 0,

    pub fn feed(s: *Stripper, gpa: Allocator, out: *std.ArrayList(u8), data: []const u8) Allocator.Error!void {
        for (data) |b| switch (s.state) {
            .text => switch (b) {
                0x1b => s.state = .esc,
                '\n', '\t' => try out.append(gpa, b),
                else => if (b >= 0x20 and b != 0x7f) try out.append(gpa, b),
            },
            .esc => switch (b) {
                '[' => {
                    s.state = .csi;
                    s.param = 0;
                },
                ']' => s.state = .osc,
                else => s.state = .text,
            },
            .csi => switch (b) {
                '0'...'9' => s.param = s.param *| 10 +| (b - '0'),
                ';' => s.param = 0,
                0x40...0x7e => {
                    if (b == 'C') try out.appendNTimes(gpa, ' ', @min(@max(s.param, 1), 1000));
                    s.state = .text;
                },
                else => {},
            },
            .osc => switch (b) {
                0x07 => s.state = .text,
                0x1b => s.state = .osc_esc,
                else => {},
            },
            .osc_esc => s.state = if (b == '\\') .text else .osc,
        };
    }
};

fn exitCode(payload: []const u8) i64 {
    var fba_buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), payload, .{}) catch return -1;
    if (v != .object) return -1;
    return switch (v.object.get("exit_code") orelse return -1) {
        .integer => |i| i,
        else => -1,
    };
}

fn codeOf(payload: []const u8) i64 {
    var fba_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), payload, .{}) catch return -1;
    if (v != .object) return -1;
    return switch (v.object.get("code") orelse return -1) {
        .integer => |i| i,
        else => -1,
    };
}

fn idValue(v: ?std.json.Value) ?u32 {
    return switch (v orelse return null) {
        .integer => |i| if (i > 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

fn sessionIdOf(payload: []const u8) u32 {
    var fba_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), payload, .{}) catch return 0;
    if (v != .object) return 0;
    return idValue(v.object.get("session_id")) orelse 0;
}

/// LIST_RESP: a bare JSON array of `{session_id, shell, state, ...}`; entries without a valid id
/// are skipped. Sorted by id.
pub fn parseList(arena: Allocator, body: []const u8) Error![]SessionInfo {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidResponse;
    if (v != .array) return error.InvalidResponse;
    var out: std.ArrayList(SessionInfo) = .empty;
    for (v.array.items) |s| {
        if (s != .object) continue;
        const id = idValue(s.object.get("session_id")) orelse continue;
        const str = struct {
            fn f(o: std.json.Value, k: []const u8) []const u8 {
                const x = o.object.get(k) orelse return "--";
                return if (x == .string) x.string else "--";
            }
        }.f;
        try out.append(arena, .{ .id = id, .name = str(s, "shell"), .state = str(s, "state") });
    }
    std.mem.sort(SessionInfo, out.items, {}, struct {
        fn lt(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.id < b.id;
        }
    }.lt);
    return out.items;
}

const testing = std.testing;

test "TERM encode and decode" {
    const gpa = testing.allocator;
    const f = try encode(gpa, Kind.stdin, 7, "ls\r");
    defer gpa.free(f);
    try testing.expectEqualSlices(u8, "TERM\x01\x02\x00\x00\x07\x00\x00\x00\x03\x00\x00\x00ls\r", f);
    var d: Decoder = .{};
    defer d.deinit(gpa);
    // Split across messages, two frames in one push.
    try d.push(gpa, f[0..10]);
    try testing.expectEqual(@as(?Frame, null), try d.next());
    const g = try encode(gpa, Kind.stdout, 7, "x");
    defer gpa.free(g);
    try d.push(gpa, f[10..]);
    try d.push(gpa, g);
    const a = (try d.next()).?;
    try testing.expectEqual(@as(u8, Kind.stdin), a.kind);
    try testing.expectEqual(@as(u32, 7), a.session);
    try testing.expectEqualStrings("ls\r", a.payload);
    const b = (try d.next()).?;
    try testing.expectEqualStrings("x", b.payload);
    try testing.expectEqual(@as(?Frame, null), try d.next());
    var bad: Decoder = .{};
    defer bad.deinit(gpa);
    try bad.push(gpa, "TERX\x01\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try testing.expectError(error.InvalidTermHeader, bad.next());
}

test "parseList, exit code, session id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const l = try parseList(arena.allocator(), "[{\"session_id\":3,\"shell\":\"bash\",\"state\":\"detached\"},{\"session_id\":0},{\"session_id\":\"2\",\"state\":\"running\"}]");
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqual(@as(u32, 2), l[0].id);
    try testing.expectEqualStrings("--", l[0].name);
    try testing.expectEqualStrings("bash", l[1].name);
    try testing.expectEqual(@as(i64, 3), exitCode("{\"exit_code\":3}"));
    try testing.expectEqual(@as(i64, -1), exitCode("x"));
    try testing.expectEqual(@as(u32, 9), sessionIdOf("{\"code\":0,\"session_id\":\"9\"}"));
    try testing.expectEqual(@as(u32, 0), sessionIdOf("{\"code\":0,\"message\":\"ok\"}"));
}

test "exec: strip ConPTY output and extract the result" {
    const gpa = testing.allocator;
    const nonce = "0123abcd";
    // Shaped like real Windows host output: OSC title, screen modes, coloured echo of the typed
    // line (which spells the markers as 'UU'+'CLI-...'), spaces as ESC[1C, CRLF line ends.
    const raw = "\x1b[?9001h\x1b]0;C:\\WINDOWS\\powershell.exe\x07\x1b[?25lPS C:\\Users\\me>\x1b[K\r\n" ++
        "\x1b[93mWrite-Output\x1b[m ('UU'+'CLI-S-0123abcd'); ... ('UU'+'CLI-E-0123abcd:'+$u)\r\n" ++
        "UUCLI-S-0123abcd\r\nStatus\x1b[3CName\r\n" ++
        "Running\x1b[1Csshd\x1b[K\r\nUUCLI-E-0123abcd:3\r\nPS\x1b[1CC:\\Users\\me>";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var s: Stripper = .{};
    // Fed in two chunks that split an escape sequence.
    try s.feed(gpa, &text, raw[0..120]);
    try testing.expect(extract(text.items, nonce) == null);
    try s.feed(gpa, &text, raw[120..]);
    const r = extract(text.items, nonce).?;
    try testing.expectEqualStrings("Status   Name\nRunning sshd\n", r.output);
    try testing.expectEqual(@as(i64, 3), r.code);
    // The end marker line must be complete.
    try testing.expect(extract("UUCLI-S-0123abcd\nx\nUUCLI-E-0123abcd:1", nonce) == null);
    try testing.expectEqualStrings("x\n", afterStart("echo\nUUCLI-S-0123abcd\nx\n", nonce));
}

test "exec: wrapper lines" {
    const gpa = testing.allocator;
    const ps = try execLine(gpa, .powershell, "n1", "Get-Service 'sshd'");
    defer gpa.free(ps);
    try testing.expect(std.mem.indexOf(u8, ps, "UUCLI-") == null);
    try testing.expect(std.mem.indexOf(u8, ps, "FromBase64String('R2V0LVNlcnZpY2UgJ3NzaGQn')") != null);
    try testing.expect(std.mem.endsWith(u8, ps, "exit $u\r"));
    const sh = try execLine(gpa, .posix, "n1", "echo 'a b'");
    defer gpa.free(sh);
    try testing.expect(std.mem.indexOf(u8, sh, "UUCLI-") == null);
    try testing.expectEqualStrings("printf '%s\\n' \"UU\"\"CLI-S-n1\"; eval 'echo '\\''a b'\\'''; u=$?; printf '%s\\n' \"UU\"\"CLI-E-n1:$u\"; exit $u\r", sh);
}

test {
    std.testing.refAllDecls(Terminal);
}
