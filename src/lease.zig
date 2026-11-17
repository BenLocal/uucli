// SPDX-License-Identifier: GPL-3.0-or-later
//! Leases on the shared session (spec §7.3): one `terminal` / `exec` / `files` client at a time
//! receives every message of the session that is not port forwarding, and sends its own messages
//! through it. Message bodies are never logged.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = Io.net;
const wire = @import("wire.zig");
const session = @import("session.zig");
const portmap = @import("tools/portmap.zig");

const log = std.log.scoped(.lease);

/// Largest message in a frame: above a 1 MiB TERM payload or a 256 KiB file block plus framing.
pub const max_frame = 2 * 1024 * 1024;

/// `CHANNEL (u8) LEN (u32 le) DATA`.
pub fn writeFrame(w: *Io.Writer, channel: usize, data: []const u8) Io.Writer.Error!void {
    try w.writeByte(@intCast(channel));
    try w.writeInt(u32, @intCast(data.len), .little);
    try w.writeAll(data);
    try w.flush();
}

pub const Frame = struct { channel: usize, data: []u8 };

/// Reads one frame; the caller frees `data`.
pub fn readFrame(r: *Io.Reader, gpa: Allocator) !Frame {
    const channel = try r.takeByte();
    if (channel >= wire.channels.len) return error.InvalidFrame;
    const len = try r.takeInt(u32, .little);
    if (len > max_frame) return error.InvalidFrame;
    const data = try gpa.alloc(u8, len);
    errdefer gpa.free(data);
    try r.readSliceAll(data);
    return .{ .channel = channel, .data = data };
}

/// The serving side, inside `uucli __mux`.
pub const Server = struct {
    io: Io,
    gpa: Allocator,
    link: session.Link,
    /// Platform number of the host (1 Windows, 4 Mac), told to each client.
    platform: i64,
    pm: *portmap.PortMap,
    /// Held by the client that has the lease; waiting clients queue on it.
    turn: Io.Mutex = .init,
    /// Guards `holder` (the session task delivers while leases change hands).
    mutex: Io.Mutex = .init,
    holder: ?*Holder = null,
    /// Clients holding or waiting for a lease, for the idle timer.
    clients: std.atomic.Value(u32) = .init(0),

    const Msg = struct { channel: usize, data: []u8 };

    const Holder = struct {
        queue_buf: [256]Msg = undefined,
        queue: Io.Queue(Msg) = undefined,
    };

    pub fn hook(s: *Server) portmap.RequestHook {
        return .{ .ptr = s, .serveFn = serveErased };
    }

    /// The session's tool: port forwarding frames go to the port mapper, the rest to the holder.
    pub fn tool(s: *Server) session.Tool {
        return .{ .ptr = s, .deliverFn = deliver };
    }

    /// Session task: never blocks. A holder that falls behind loses its lease.
    fn deliver(ptr: *anyopaque, channel: usize, data: []const u8) void {
        const s: *Server = @ptrCast(@alignCast(ptr));
        if (channel == wire.file and wire.blob(data, wire.kind.port_forward) != null) {
            const t = s.pm.tool();
            return t.deliverFn(t.ptr, channel, data);
        }
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const h = s.holder orelse return;
        const copy = s.gpa.dupe(u8, data) catch {
            h.queue.close(s.io);
            return;
        };
        const n = h.queue.putUncancelable(s.io, &.{.{ .channel = channel, .data = copy }}, 0) catch 0;
        if (n == 0) {
            s.gpa.free(copy);
            log.warn("lease holder fell behind, ending its lease", .{});
            h.queue.close(s.io);
        }
    }

    fn serveErased(ptr: *anyopaque, conn: net.Stream) Io.Cancelable!void {
        const s: *Server = @ptrCast(@alignCast(ptr));
        return s.serve(conn);
    }

    /// One client: wait for the lease, answer `OK PLATFORM`, then relay frames both ways until
    /// either side ends.
    fn serve(s: *Server, conn: net.Stream) Io.Cancelable!void {
        const io = s.io;
        _ = s.clients.fetchAdd(1, .monotonic);
        defer _ = s.clients.fetchSub(1, .monotonic);
        defer conn.close(io);
        try s.turn.lock(io);
        defer s.turn.unlock(io);

        var h: Holder = .{};
        h.queue = .init(&h.queue_buf);
        {
            var buf: [32]u8 = undefined;
            var w = conn.writer(io, &buf);
            w.interface.print("OK {d}\n", .{s.platform}) catch return;
            w.interface.flush() catch return;
        }
        {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            s.holder = &h;
        }
        defer {
            s.mutex.lockUncancelable(io);
            s.holder = null;
            s.mutex.unlock(io);
            h.queue.close(io);
            while (h.queue.getOneUncancelable(io)) |m| s.gpa.free(m.data) else |_| {}
        }
        log.info("lease granted", .{});
        const U = union(enum) { up: void, down: void };
        var sel_buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(io, &sel_buf);
        defer sel.cancelDiscard();
        sel.concurrent(.up, up, .{ s, conn }) catch return;
        sel.concurrent(.down, down, .{ s, conn, &h }) catch return;
        _ = try sel.await();
        // Wake the other direction: a closed queue ends `down`, a shut down socket ends `up`.
        h.queue.close(io);
        conn.shutdown(io, .both) catch {};
        log.info("lease returned", .{});
    }

    /// Client → session.
    fn up(s: *Server, conn: net.Stream) void {
        var rb: [64 * 1024]u8 = undefined;
        var r = conn.reader(s.io, &rb);
        while (true) {
            const f = readFrame(&r.interface, s.gpa) catch return;
            defer s.gpa.free(f.data);
            s.link.send(f.channel, f.data) catch |err| {
                log.info("lease send failed: {t}", .{err});
                return;
            };
        }
    }

    /// Session → client.
    fn down(s: *Server, conn: net.Stream, h: *Holder) void {
        var wb: [64 * 1024]u8 = undefined;
        var w = conn.writer(s.io, &wb);
        while (true) {
            const m = h.queue.getOne(s.io) catch return;
            defer s.gpa.free(m.data);
            writeFrame(&w.interface, m.channel, m.data) catch return;
        }
    }
};

/// The client side: a `session.Link` over a granted lease connection.
pub const Client = struct {
    io: Io,
    gpa: Allocator,
    conn: net.Stream,
    /// Senders: the tool loop and its input task.
    mutex: Io.Mutex = .init,
    /// Set when the lease ended (connection closed by the server or broken).
    lost: std.atomic.Value(bool) = .init(false),

    pub fn link(c: *Client) session.Link {
        return .{ .ptr = c, .sendFn = sendErased };
    }

    fn sendErased(ptr: *anyopaque, channel: usize, data: []const u8) anyerror!void {
        const c: *Client = @ptrCast(@alignCast(ptr));
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        var buf: [4096]u8 = undefined;
        var w = c.conn.writer(c.io, &buf);
        writeFrame(&w.interface, channel, data) catch return error.SessionClosed;
    }

    /// Hands every received message to `tool` until the lease ends, then calls `ended`.
    pub fn readTask(c: *Client, tool: session.Tool, ended: *const fn (ptr: *anyopaque) void, ended_ptr: *anyopaque) Io.Cancelable!void {
        defer {
            c.lost.store(true, .release);
            ended(ended_ptr);
        }
        var rb: [64 * 1024]u8 = undefined;
        var r = c.conn.reader(c.io, &rb);
        while (true) {
            const f = readFrame(&r.interface, c.gpa) catch |err| {
                if (err == error.InvalidFrame) log.warn("invalid frame from the shared session", .{});
                return;
            };
            defer c.gpa.free(f.data);
            tool.deliverFn(tool.ptr, f.channel, f.data);
        }
    }
};

const testing = std.testing;

test "lease frames round trip and reject bad headers" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeFrame(&w, wire.binary, "TERM-bytes");
    try writeFrame(&w, wire.control, "");
    var r: Io.Reader = .fixed(w.buffered());
    const a = try readFrame(&r, testing.allocator);
    defer testing.allocator.free(a.data);
    try testing.expectEqual(@as(usize, wire.binary), a.channel);
    try testing.expectEqualStrings("TERM-bytes", a.data);
    const b = try readFrame(&r, testing.allocator);
    defer testing.allocator.free(b.data);
    try testing.expectEqual(@as(usize, wire.control), b.channel);
    try testing.expectEqual(@as(usize, 0), b.data.len);
    try testing.expectError(error.EndOfStream, readFrame(&r, testing.allocator));

    var bad_channel: Io.Reader = .fixed(&.{ 9, 0, 0, 0, 0 });
    try testing.expectError(error.InvalidFrame, readFrame(&bad_channel, testing.allocator));
    var too_long: Io.Reader = .fixed(&.{ 0, 0xff, 0xff, 0xff, 0x7f });
    try testing.expectError(error.InvalidFrame, readFrame(&too_long, testing.allocator));
}
