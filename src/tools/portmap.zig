// SPDX-License-Identifier: GPL-3.0-or-later
//! TCP port forwarding over kind-27 frames on FILE (spec §7). Upstream: src/viewer/tools/portmap.rs,
//! host side src/port_mapping.rs. Forwarded bytes and target addresses are never logged.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const wire = @import("../wire.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;

const log = std.log.scoped(.portmap);

/// One `-L [BIND:]LPORT:HOST:PORT`.
pub const Rule = struct {
    bind: []const u8 = "127.0.0.1",
    lport: u16,
    host: []const u8,
    port: u16,
};

/// Parses `[BIND:]LPORT:HOST:PORT`; BIND and HOST may be `[IPv6]`.
pub fn parseRule(spec: []const u8) error{InvalidForward}!Rule {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) {
        if (n == 4) return error.InvalidForward;
        var end = i;
        if (end < spec.len and spec[end] == '[') {
            end = std.mem.indexOfScalarPos(u8, spec, end, ']') orelse return error.InvalidForward;
            parts[n] = spec[i + 1 .. end];
            end += 1;
            if (end < spec.len and spec[end] != ':') return error.InvalidForward;
        } else {
            end = std.mem.indexOfScalarPos(u8, spec, i, ':') orelse spec.len;
            parts[n] = spec[i..end];
        }
        n += 1;
        i = end + 1;
    }
    const p = parts[0..n];
    const port = struct {
        fn f(s: []const u8, allow_zero: bool) error{InvalidForward}!u16 {
            const v = std.fmt.parseInt(u16, s, 10) catch return error.InvalidForward;
            if (v == 0 and !allow_zero) return error.InvalidForward;
            return v;
        }
    }.f;
    const r: Rule = switch (n) {
        3 => .{ .lport = try port(p[0], true), .host = p[1], .port = try port(p[2], false) },
        4 => .{ .bind = p[0], .lport = try port(p[1], true), .host = p[2], .port = try port(p[3], false) },
        else => return error.InvalidForward,
    };
    if (r.host.len == 0 or r.bind.len == 0 or std.mem.trim(u8, r.host, " ").len == 0) return error.InvalidForward;
    return r;
}

pub const max_streams_per_rule = 128;
const max_frame_payload = 16 * 1024;
const syn_timeout: Io.Duration = .fromSeconds(12);
const session_id = 1;

const Frame = struct { kind: u64, data: []u8 };

/// Where a stream's bytes come from and go to: an accepted TCP connection or stdin/stdout.
pub const Endpoint = union(enum) {
    tcp: net.Stream,
    stdio,

    fn shutdown(e: Endpoint, io: Io) void {
        switch (e) {
            .tcp => |s| s.shutdown(io, .both) catch {},
            .stdio => {},
        }
    }

    fn close(e: Endpoint, io: Io) void {
        switch (e) {
            .tcp => |s| s.close(io),
            .stdio => {},
        }
    }
};

const Stream = struct {
    pm: *PortMap,
    session: *Session,
    rule: *RuleState,
    id: u64,
    endpoint: Endpoint,
    inbox_buf: [64]Frame = undefined,
    inbox: Io.Queue(Frame) = undefined,
    /// `proxy`: ask the session loop to stop when this stream ends.
    stop_session: bool = false,
};

const RuleState = struct {
    rule: Rule,
    id: u64,
    server: ?net.Server = null,
    bound_port: u16 = 0,
    streams: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
};

pub const PortMap = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    /// The ready session streams are opened on, or null while (re)connecting.
    session: ?*Session = null,
    /// Rule and stream ids share one counter, as upstream.
    next_id: std.atomic.Value(u64) = .init(1),
    rules: []RuleState,
    streams: std.AutoHashMapUnmanaged([2]u64, *Stream) = .empty,
    /// Stream tasks of the current session.
    group: Io.Group = .init,
    accept_group: Io.Group = .init,
    /// `proxy` outcome: the error that ended its stream, if any.
    last_error: ?anyerror = null,

    pub fn init(io: Io, gpa: Allocator, rules: []const Rule) !PortMap {
        const states = try gpa.alloc(RuleState, rules.len);
        var pm: PortMap = .{ .io = io, .gpa = gpa, .rules = states };
        for (rules, states) |r, *st| st.* = .{ .rule = r, .id = pm.next_id.fetchAdd(1, .monotonic) };
        return pm;
    }

    pub fn deinit(pm: *PortMap) void {
        pm.accept_group.cancel(pm.io);
        for (pm.rules) |*r| if (r.server) |*s| s.deinit(pm.io);
        pm.streams.deinit(pm.gpa);
        pm.gpa.free(pm.rules);
    }

    /// Binds every rule's listener; returns the rule whose bind failed.
    pub fn listen(pm: *PortMap) !void {
        for (pm.rules) |*r| {
            const addr = net.IpAddress.parse(r.rule.bind, r.rule.lport) catch {
                log.err("invalid bind address {s}", .{r.rule.bind});
                return error.InvalidBind;
            };
            r.server = addr.listen(pm.io, .{ .reuse_address = true }) catch |err| {
                log.err("cannot listen on {s}:{d}: {t}", .{ r.rule.bind, r.rule.lport, err });
                return error.ListenFailed;
            };
            r.bound_port = r.server.?.socket.address.getPort();
        }
    }

    /// Starts one accept task per rule. Listeners stay bound across reconnects.
    pub fn startAccepting(pm: *PortMap) !void {
        for (pm.rules) |*r| try pm.accept_group.concurrent(pm.io, acceptTask, .{ pm, r });
    }

    pub fn tool(pm: *PortMap) session_mod.Tool {
        return .{ .ptr = pm, .deliverFn = deliver };
    }

    pub fn attach(pm: *PortMap, s: *Session) void {
        pm.mutex.lockUncancelable(pm.io);
        defer pm.mutex.unlock(pm.io);
        pm.session = s;
    }

    /// Ends every stream of the current session (sends CLOSE where possible) and waits for them.
    pub fn detach(pm: *PortMap) void {
        {
            pm.mutex.lockUncancelable(pm.io);
            defer pm.mutex.unlock(pm.io);
            pm.session = null;
            var it = pm.streams.valueIterator();
            while (it.next()) |st| {
                st.*.inbox.close(pm.io);
                st.*.endpoint.shutdown(pm.io);
            }
        }
        pm.group.cancel(pm.io);
    }

    fn acceptTask(pm: *PortMap, r: *RuleState) Io.Cancelable!void {
        while (true) {
            const conn = r.server.?.accept(pm.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    log.warn("accept failed: {t}", .{err});
                    try pm.io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            pm.startStream(r, .{ .tcp = conn }, false) catch |err| {
                log.info("connection on port {d} closed: {t}", .{ r.bound_port, err });
                conn.close(pm.io);
            };
        }
    }

    /// Opens a stream for `endpoint` on the current session.
    pub fn startStream(pm: *PortMap, r: *RuleState, endpoint: Endpoint, stop_session: bool) !void {
        pm.mutex.lockUncancelable(pm.io);
        defer pm.mutex.unlock(pm.io);
        const s = pm.session orelse return error.NotConnected;
        if (r.streams.load(.monotonic) >= max_streams_per_rule) return error.TooManyStreams;
        const st = try pm.gpa.create(Stream);
        errdefer pm.gpa.destroy(st);
        st.* = .{ .pm = pm, .session = s, .rule = r, .id = pm.next_id.fetchAdd(1, .monotonic), .endpoint = endpoint, .stop_session = stop_session };
        st.inbox = .init(&st.inbox_buf);
        try pm.streams.put(pm.gpa, .{ r.id, st.id }, st);
        errdefer _ = pm.streams.remove(.{ r.id, st.id });
        _ = r.streams.fetchAdd(1, .monotonic);
        errdefer _ = r.streams.fetchSub(1, .monotonic);
        try pm.group.concurrent(pm.io, streamTask, .{st});
    }

    /// Session task: one inbound message (spec §7). Never blocks.
    fn deliver(ptr: *anyopaque, channel: usize, data: []const u8) void {
        const pm: *PortMap = @ptrCast(@alignCast(ptr));
        if (channel != wire.file) return;
        const f = wire.blob(data, wire.kind.port_forward) orelse return;
        const key: [2]u64 = .{ wire.uint(f, 2), wire.uint(f, 3) };
        pm.mutex.lockUncancelable(pm.io);
        defer pm.mutex.unlock(pm.io);
        const st = pm.streams.get(key) orelse {
            log.debug("port frame for unknown stream dropped (type {d})", .{wire.uint(f, 4)});
            return;
        };
        if (wire.uint(f, 1) != session_id) {
            log.debug("port frame with session {d} dropped", .{wire.uint(f, 1)});
            return;
        }
        const payload = pm.gpa.dupe(u8, wire.blob(f, 5) orelse "") catch return;
        const n = st.inbox.putUncancelable(pm.io, &.{.{ .kind = wire.uint(f, 4), .data = payload }}, 0) catch 0;
        if (n == 0) {
            // Full (or already closed): like upstream, drop the route; the stream ends.
            pm.gpa.free(payload);
            log.warn("port mapping stream {d} overrun, closing it", .{st.id});
            st.inbox.close(pm.io);
        }
    }

    fn frame(st: *Stream, kind: u64, payload: []const u8) ![]u8 {
        return wire.portFrame(st.pm.gpa, session_id, st.rule.id, st.id, kind, payload);
    }

    fn sendFrame(st: *Stream, kind: u64, payload: []const u8) !void {
        const f = try frame(st, kind, payload);
        defer st.pm.gpa.free(f);
        try st.session.send(wire.file, f);
    }

    fn streamTask(st: *Stream) Io.Cancelable!void {
        const pm = st.pm;
        const io = pm.io;
        defer {
            pm.mutex.lockUncancelable(io);
            _ = pm.streams.remove(.{ st.rule.id, st.id });
            pm.mutex.unlock(io);
            st.inbox.close(io);
            while (st.inbox.getOneUncancelable(io)) |f| pm.gpa.free(f.data) else |_| {}
            st.endpoint.close(io);
            _ = st.rule.streams.fetchSub(1, .monotonic);
            if (st.stop_session) st.session.bus.put(.stop);
            pm.gpa.destroy(st);
        }
        const result = forward(st);
        // Always tell the host the stream is over (best effort; the session may be gone).
        const prev = io.swapCancelProtection(.blocked);
        sendFrame(st, wire.PortFrame.close, "") catch {};
        _ = io.swapCancelProtection(prev);
        result catch |err| switch (err) {
            error.Canceled => {},
            else => {
                _ = st.rule.failures.fetchAdd(1, .monotonic);
                log.warn("port mapping stream ended: {s}", .{switch (err) {
                    error.SynTimeout => "SYN timeout",
                    error.Rejected => "target rejected by the host",
                    error.UnexpectedFrame => "unexpected frame",
                    else => @errorName(err),
                }});
                if (st.stop_session) pm.last_error = err;
            },
        };
    }

    fn forward(st: *Stream) !void {
        const pm = st.pm;
        const io = pm.io;
        const syn = try std.json.Stringify.valueAlloc(pm.gpa, .{ .version = 1, .target_host = st.rule.rule.host, .target_port = st.rule.rule.port }, .{});
        defer pm.gpa.free(syn);
        try sendFrame(st, wire.PortFrame.syn, syn);

        const ack = try waitFrame(st, syn_timeout);
        defer pm.gpa.free(ack.data);
        if (ack.kind != wire.PortFrame.syn_ack or !synAckOk(ack.data)) {
            // A SYN-ACK carries only status JSON; a CLOSE or other frame is shown by type and size.
            if (ack.kind == wire.PortFrame.syn_ack)
                log.info("stream {d}: SYN-ACK {s}", .{ st.id, ack.data[0..@min(ack.data.len, 200)] })
            else
                log.info("stream {d}: frame type {d} ({d} bytes) instead of SYN-ACK", .{ st.id, ack.kind, ack.data.len });
            return error.Rejected;
        }
        log.debug("stream {d} established", .{st.id});

        const U = union(enum) { up: anyerror!void, down: anyerror!void };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(io, &buf);
        defer sel.cancelDiscard();
        try sel.concurrent(.up, upstream, .{st});
        try sel.concurrent(.down, downstream, .{st});
        const first = try sel.await();
        // Wake the other direction without relying on cancelation alone: a closed inbox ends
        // `drain`, a shut down socket ends `pump`.
        st.inbox.close(io);
        st.endpoint.shutdown(io);
        switch (first) {
            inline else => |r| return r,
        }
    }

    fn synAckOk(data: []const u8) bool {
        var fba_buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
        const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), data, .{}) catch return false;
        if (v != .object) return false;
        const ok = v.object.get("ok") orelse return false;
        return ok == .bool and ok.bool;
    }

    fn waitFrame(st: *Stream, timeout: Io.Duration) !Frame {
        const io = st.pm.io;
        const U = union(enum) { frame: (Io.QueueClosedError || Io.Cancelable)!Frame, timeout: Io.Cancelable!void };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(io, &buf);
        try sel.concurrent(.frame, Io.Queue(Frame).getOne, .{ &st.inbox, io });
        sel.concurrent(.timeout, Io.sleep, .{ io, timeout, .awake }) catch |err| {
            if (sel.cancel()) |late| if (late == .frame) if (late.frame) |f| st.pm.gpa.free(f.data) else |_| {};
            return err;
        };
        const first = try sel.await();
        if (sel.cancel()) |late| if (late == .frame) if (late.frame) |f| st.pm.gpa.free(f.data) else |_| {};
        return switch (first) {
            .timeout => error.SynTimeout,
            .frame => |r| r catch |err| switch (err) {
                error.Closed => error.StreamClosed,
                error.Canceled => |e| e,
            },
        };
    }

    /// Local → host: DATA frames of at most 16 KiB.
    fn upstream(st: *Stream) anyerror!void {
        const io = st.pm.io;
        var buf: [max_frame_payload]u8 = undefined;
        switch (st.endpoint) {
            .tcp => |conn| {
                var r = conn.reader(io, &buf);
                return pump(st, &r.interface);
            },
            .stdio => {
                var r = Io.File.stdin().readerStreaming(io, &buf);
                return pump(st, &r.interface);
            },
        }
    }

    fn pump(st: *Stream, r: *Io.Reader) anyerror!void {
        while (true) {
            const data = r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return error.LocalReadFailed,
            };
            try sendFrame(st, wire.PortFrame.data, data);
            r.toss(data.len);
        }
    }

    /// Host → local: DATA written to the endpoint until CLOSE.
    fn downstream(st: *Stream) anyerror!void {
        const io = st.pm.io;
        var buf: [max_frame_payload]u8 = undefined;
        switch (st.endpoint) {
            .tcp => |conn| {
                var w = conn.writer(io, &buf);
                return drain(st, &w.interface);
            },
            .stdio => {
                var w = Io.File.stdout().writerStreaming(io, &buf);
                return drain(st, &w.interface);
            },
        }
    }

    fn drain(st: *Stream, w: *Io.Writer) anyerror!void {
        const io = st.pm.io;
        while (true) {
            const f = st.inbox.getOne(io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => |e| return e,
            };
            defer st.pm.gpa.free(f.data);
            switch (f.kind) {
                wire.PortFrame.data => {
                    // A local client that hung up is a normal close.
                    w.writeAll(f.data) catch return;
                    w.flush() catch return;
                },
                wire.PortFrame.close => return,
                4 => {},
                else => return error.UnexpectedFrame,
            }
        }
    }
};

const testing = std.testing;

test "parseRule" {
    const r1 = try parseRule("2222:127.0.0.1:22");
    try testing.expectEqualStrings("127.0.0.1", r1.bind);
    try testing.expectEqual(@as(u16, 2222), r1.lport);
    try testing.expectEqualStrings("127.0.0.1", r1.host);
    try testing.expectEqual(@as(u16, 22), r1.port);
    const r2 = try parseRule("0.0.0.0:0:db.internal:5432");
    try testing.expectEqualStrings("0.0.0.0", r2.bind);
    try testing.expectEqual(@as(u16, 0), r2.lport);
    try testing.expectEqualStrings("db.internal", r2.host);
    const r3 = try parseRule("[::1]:8080:[fe80::1]:80");
    try testing.expectEqualStrings("::1", r3.bind);
    try testing.expectEqualStrings("fe80::1", r3.host);
    for ([_][]const u8{ "22", "1:2", "x:h:22", "1:h:0", "1:h:70000", "1::22", "a:b:c:d:e", "[::1:8080:h:1" }) |bad|
        try testing.expectError(error.InvalidForward, parseRule(bad));
}

test {
    std.testing.refAllDecls(PortMap);
}
