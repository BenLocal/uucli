// SPDX-License-Identifier: GPL-3.0-or-later
//! One tool session: room join → signaling → control request → WebRTC → echo → ready, then
//! message routing until the session ends (spec §6, §8). Upstream: src/viewer/session.rs,
//! src/viewer/rtc.rs, src/viewer_main.rs `tool_command`.
//!
//! Everything that happens to a session arrives as an `Event` on the process-wide `Bus` and is
//! handled on the task that calls `open` / `run`; tools send from their own tasks through `send`.
//! Never logs tokens, SDP, candidates, ICE credentials or payloads.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rtc = @import("rtc.zig");
const signal = @import("signal.zig");
const wire = @import("wire.zig");
const api = @import("api.zig");

const log = std.log.scoped(.session);

pub const Event = union(enum) {
    rtc: rtc.Event,
    signal: struct { gen: u32, packet: signal.Packet },
    /// The signaling reader of session `gen` stopped (room closed, socket error).
    signal_end: struct { gen: u32 },
    /// 250 ms timer, for deadlines.
    tick,
    /// SIGINT / SIGTERM.
    interrupt,
    /// A tool asks the session loop to return (e.g. `proxy` finished).
    stop,

    pub fn deinit(e: Event) void {
        switch (e) {
            .rtc => |r| r.deinit(),
            .signal => |s| s.packet.deinit(),
            else => {},
        }
    }
};

/// The process-wide event queue: libdatachannel events (pumped from `rtc.Hub`), signaling packets,
/// timer ticks and interrupts.
pub const Bus = struct {
    io: Io,
    queue: Io.Queue(Event),
    hub: *rtc.Hub,
    pump: ?Io.Future(void) = null,
    ticker: ?Io.Future(void) = null,
    /// Test hook: takes libdatachannel events of another in-process peer (the fake host).
    divert: ?Divert = null,

    pub const Divert = struct {
        ptr: *anyopaque,
        /// Called on the pump task; returns true if it took ownership of the event.
        take: *const fn (ptr: *anyopaque, e: rtc.Event) bool,
    };

    pub fn init(bus: *Bus, io: Io, buffer: []Event) !void {
        bus.* = .{ .io = io, .queue = .init(buffer), .hub = rtc.globalHub(io) };
        bus.pump = try io.concurrent(pumpTask, .{bus});
        bus.ticker = try io.concurrent(tickTask, .{bus});
    }

    /// Stops the tasks, the hub and the queue; pending events are freed.
    pub fn deinit(bus: *Bus) void {
        if (bus.ticker) |*t| t.cancel(bus.io);
        if (bus.pump) |*p| p.cancel(bus.io);
        bus.hub.shutdown();
        bus.queue.close(bus.io);
        while (bus.queue.getOneUncancelable(bus.io)) |e| e.deinit() else |_| {}
    }

    /// Thread-safe; blocks while the queue is full.
    pub fn put(bus: *Bus, e: Event) void {
        bus.queue.putOneUncancelable(bus.io, e) catch e.deinit();
    }

    pub fn next(bus: *Bus) Io.Cancelable!Event {
        return bus.queue.getOne(bus.io) catch |err| switch (err) {
            error.Canceled => |x| return x,
            error.Closed => return .stop,
        };
    }

    fn pumpTask(bus: *Bus) void {
        while (true) {
            const e = bus.hub.next() catch return;
            if (bus.divert) |d| if (d.take(d.ptr, e)) continue;
            bus.put(.{ .rtc = e });
        }
    }

    fn tickTask(bus: *Bus) void {
        while (true) {
            bus.io.sleep(.fromMilliseconds(250), .awake) catch return;
            bus.put(.tick);
        }
    }

    /// Consumes events until `deadline` (for backoff waits). Returns true on interrupt.
    pub fn waitUntil(bus: *Bus, deadline: Io.Timestamp) Io.Cancelable!bool {
        while (Io.Clock.awake.now(bus.io).compare(.lt, deadline)) {
            const e = try bus.next();
            defer e.deinit();
            if (e == .interrupt) return true;
        }
        return false;
    }
};

pub const Tool = struct {
    ptr: *anyopaque,
    /// Called on the session task for each routed message; must not block. `channel` is
    /// `wire.file` or `wire.binary` (CONTROL replies are delivered as `wire.control`).
    deliverFn: *const fn (ptr: *anyopaque, channel: usize, data: []const u8) void,
};

pub const End = enum {
    interrupted,
    stopped,
    /// `released` / `left` / `leave` for our route.
    released,
    peer_failed,
    signaling_closed,
    channel_closed,
};

pub const OpenError = error{
    NotSignedIn,
    /// API 2002.
    DeviceBusy,
    Interrupted,
    /// Room join, signaling, ICE/DTLS, channels or echo failed or timed out (exit 5).
    ConnectFailed,
    /// Control request refused or acked with an error (exit 6).
    Refused,
} || Allocator.Error || Io.Cancelable;

pub const Setup = struct {
    io: Io,
    gpa: Allocator,
    bus: *Bus,
    client: *api.Client,
    http: *std.http.Client,
    /// uucli's own device id (ConnectOptions field 9).
    own_device_id: []const u8,
    /// The controlled host (its share id when `assist_code` is set).
    target: []const u8,
    capture_type: u32,
    /// Remote-assistance code: join the partner's share room instead of an account device.
    assist_code: ?[]const u8 = null,
};

var next_gen: std.atomic.Value(u32) = .init(1);

pub const setup_timeout: Io.Duration = .fromSeconds(30);
const ack_timeout: Io.Duration = .fromSeconds(12);
const send_timeout: Io.Duration = .fromSeconds(30);
const max_buffered = 1024 * 1024;

pub const Session = struct {
    io: Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    bus: *Bus,
    gen: u32,
    capture_type: u32,
    own_device_id: []const u8,
    /// From the room join (1 Windows, 4 Mac); null when the server did not say.
    publisher_platform: ?i64,

    sig: signal.Signal,
    reader: ?Io.Future(void) = null,

    control_ack: u64 = 0,
    ack_deadline: Io.Timestamp = undefined,
    setup_deadline: Io.Timestamp,
    acked: bool = false,
    pending: std.ArrayList(signal.Packet) = .empty,

    app_control_id: [36]u8,
    ice_id: []const u8 = "",
    remote: []const u8 = "",

    peer: ?rtc.Peer = null,
    dcs: [wire.channels.len]c_int = @splat(-1),
    is_open: [wire.channels.len]bool = @splat(false),
    local_mid: []const u8 = "0",
    answered: bool = false,
    early: std.ArrayList(Candidate) = .empty,
    echo_received: bool = false,
    ready: bool = false,
    closing: std.atomic.Value(bool) = .init(false),
    /// Set when the loop decided the session is over; returned by `run`.
    ended: ?End = null,
    failure: ?OpenError = null,

    const Candidate = struct { candidate: [:0]const u8, mid: ?[:0]const u8 };

    /// Joins the room and brings the session up to "ready" (spec §6). The returned session must be
    /// closed with `close`.
    pub fn open(setup: Setup) OpenError!*Session {
        const io = setup.io;
        const started = Io.Clock.awake.now(io);
        var arena: std.heap.ArenaAllocator = .init(setup.gpa);
        // The session takes the arena by value below; from then on `s.close` frees it.
        var arena_moved = false;
        errdefer if (!arena_moved) arena.deinit();
        const joined = if (setup.assist_code) |code|
            api.joinShare(setup.client, arena.allocator(), setup.target, code)
        else
            api.joinRoom(setup.client, arena.allocator(), setup.target);
        const room = joined catch |err| return switch (err) {
            error.NotSignedIn => error.NotSignedIn,
            error.DeviceBusy => error.DeviceBusy,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.JoinFailed, error.ApiError => blk: {
                const f = &setup.client.failure;
                log.err("room join failed: {f}{s}{s}", .{ f.*, if (f.msg_len != 0) ": " else "", f.msg() });
                break :blk error.ConnectFailed;
            },
            else => blk: {
                log.err("room join failed: {t}", .{err});
                break :blk error.ConnectFailed;
            },
        };
        log.info("room joined: {d} signaling endpoint(s)", .{room.signaling_list.len});
        const ws_timeout: Io.Duration = if (room.ws_connect_timeout_ms > 0) .fromMilliseconds(room.ws_connect_timeout_ms) else .fromSeconds(12);
        const sig = signal.Signal.connect(io, setup.gpa, setup.http, room.signaling_list, room.token, ws_timeout) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.err("signaling connection failed", .{});
                return error.ConnectFailed;
            },
        };

        const s = try setup.gpa.create(Session);
        s.* = .{
            .io = io,
            .gpa = setup.gpa,
            .arena = arena,
            .bus = setup.bus,
            .gen = next_gen.fetchAdd(1, .monotonic),
            .capture_type = setup.capture_type,
            .own_device_id = setup.own_device_id,
            .publisher_platform = room.publisher_platform,
            .sig = sig,
            .setup_deadline = started.addDuration(setup_timeout),
            .app_control_id = uuid(io),
        };
        arena_moved = true;
        errdefer s.close();
        var ice_raw: [16]u8 = undefined;
        io.random(&ice_raw);
        s.ice_id = try s.arena.allocator().dupe(u8, &std.fmt.bytesToHex(ice_raw, .lower));
        s.reader = io.concurrent(readerTask, .{s}) catch return error.ConnectFailed;

        const header = try wire.controlRequest(s.gpa, s.capture_type, &s.app_control_id);
        defer s.gpa.free(header);
        const options = try wire.connectOptions(s.gpa, s.capture_type, s.own_device_id);
        defer s.gpa.free(options);
        s.control_ack = s.sig.sendControl(header, options) catch return error.ConnectFailed;
        s.ack_deadline = Io.Clock.awake.now(io).addDuration(ack_timeout);

        while (!s.ready) {
            const e = try s.bus.next();
            defer e.deinit();
            s.handle(e, null);
            if (s.failure) |f| return f;
            if (s.ended) |end| return if (end == .interrupted) error.Interrupted else error.ConnectFailed;
        }
        log.info("session ready", .{});
        return s;
    }

    /// Routes messages to `tool` until the session ends.
    pub fn run(s: *Session, tool: Tool) Io.Cancelable!End {
        while (s.ended == null) {
            const e = try s.bus.next();
            defer e.deinit();
            s.handle(e, tool);
        }
        return s.ended.?;
    }

    /// Lets `run` continue after it returned (a tool that needs the session to clean up after an
    /// interrupt, e.g. telling the host a transfer was canceled).
    pub fn resumeRun(s: *Session) void {
        s.ended = null;
    }

    /// Closes the peer connection and signaling and frees the session.
    pub fn close(s: *Session) void {
        s.closing.store(true, .release);
        if (s.peer) |p| p.close();
        // Cancel alone can miss a reader that is just entering its blocking read (seen with
        // std.Io.Threaded on macOS: close hung forever); shutting down the read side ends it.
        s.sig.interrupt();
        if (s.reader) |*r| r.cancel(s.io);
        s.sig.close();
        for (s.pending.items) |p| p.deinit();
        s.pending.deinit(s.gpa);
        s.early.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// Sends on a data channel with back-pressure (spec §6.6). Thread-safe.
    pub fn send(s: *Session, channel: usize, data: []const u8) !void {
        const dc = s.dcs[channel];
        if (dc < 0) return error.SessionClosed;
        const deadline = Io.Clock.awake.now(s.io).addDuration(send_timeout);
        while (rtc.bufferedAmount(dc) > max_buffered) {
            if (s.closing.load(.acquire)) return error.SessionClosed;
            if (Io.Clock.awake.now(s.io).compare(.gt, deadline)) return error.SendTimeout;
            try s.io.sleep(.fromMilliseconds(5), .awake);
        }
        if (s.closing.load(.acquire)) return error.SessionClosed;
        rtc.send(dc, data) catch return error.SessionClosed;
    }

    pub fn isClosing(s: *const Session) bool {
        return s.closing.load(.acquire);
    }

    fn readerTask(s: *Session) void {
        while (true) {
            const p = s.sig.next() catch |err| {
                if (err != error.Canceled and !s.closing.load(.acquire)) {
                    log.info("signaling ended: {t}", .{err});
                    s.bus.put(.{ .signal_end = .{ .gen = s.gen } });
                }
                return;
            };
            s.bus.put(.{ .signal = .{ .gen = s.gen, .packet = p } });
        }
    }

    fn fail(s: *Session, err: OpenError, comptime fmt: []const u8, args: anytype) void {
        if (!s.ready) {
            log.err(fmt, args);
            s.failure = err;
        } else {
            log.warn(fmt, args);
            s.ended = .peer_failed;
        }
    }

    fn handle(s: *Session, e: Event, tool: ?Tool) void {
        switch (e) {
            .interrupt => s.ended = .interrupted,
            .stop => s.ended = .stopped,
            .tick => {
                const now = Io.Clock.awake.now(s.io);
                if (!s.acked and now.compare(.gt, s.ack_deadline)) s.fail(error.ConnectFailed, "control acknowledgement timed out", .{});
                if (!s.ready and now.compare(.gt, s.setup_deadline)) s.fail(error.ConnectFailed, "session setup timed out (state: acked={} answered={} control={} echo={})", .{
                    s.acked, s.answered, s.is_open[wire.control], s.echo_received,
                });
            },
            .signal_end => |x| if (x.gen == s.gen) {
                if (s.ready) s.ended = .signaling_closed else s.fail(error.ConnectFailed, "signaling closed during setup", .{});
            },
            .signal => |x| if (x.gen == s.gen) s.handlePacket(x.packet),
            .rtc => |r| s.handleRtc(r, tool),
        }
        if (!s.ready and s.failure == null and s.ended == null) s.checkReady();
    }

    fn checkReady(s: *Session) void {
        const required: usize = if (s.capture_type == 8) wire.binary else wire.file;
        if (s.is_open[wire.control] and s.is_open[required] and s.echo_received) s.ready = true;
    }

    // --- Signaling ------------------------------------------------------------------------

    fn handlePacket(s: *Session, p: signal.Packet) void {
        if (!s.acked) {
            switch (p.kind) {
                .ack => |id| if (id == s.control_ack) s.handleAck(p),
                .event => {
                    if (s.pending.items.len >= 64) return s.fail(error.ConnectFailed, "too many signaling events before the control acknowledgement", .{});
                    // Keep a copy: the bus frees `p` after this returns.
                    const copy = signal.Packet.clone(p, s.gpa) catch return s.fail(error.OutOfMemory, "out of memory", .{});
                    s.pending.append(s.gpa, copy) catch {
                        copy.deinit();
                        return s.fail(error.OutOfMemory, "out of memory", .{});
                    };
                },
            }
            return;
        }
        if (p.kind == .event) s.handleEvent(p);
    }

    fn handleAck(s: *Session, p: signal.Packet) void {
        const v = p.value;
        if (v != .array or v.array.items.len != 2 or v.array.items[1] != .object or
            !(v.array.items[0] == .string and std.mem.eql(u8, v.array.items[0].string, "success")))
        {
            return s.fail(error.Refused, "control request refused by the host", .{});
        }
        const ack = v.array.items[1];
        const a = s.arena.allocator();
        if (api.str(ack, "app_control_id")) |id| if (!std.mem.eql(u8, id, &s.app_control_id))
            return s.fail(error.ConnectFailed, "control acknowledgement belongs to another session", .{});
        if (api.str(ack, "ice_id")) |ice| if (ice.len != 0 and ice.len <= 128) {
            s.ice_id = a.dupe(u8, ice) catch return s.fail(error.OutOfMemory, "out of memory", .{});
        };
        const remote = api.str(ack, "client_id") orelse "";
        if (remote.len == 0) return s.fail(error.ConnectFailed, "control acknowledgement has no peer route", .{});
        s.remote = a.dupe(u8, remote) catch return s.fail(error.OutOfMemory, "out of memory", .{});
        const cfg = iceConfig(a, ack) catch |err| return s.fail(error.ConnectFailed, "invalid ICE configuration in the control acknowledgement: {t}", .{err});
        log.info("control acknowledged: {d} ICE server(s), relay={}", .{ cfg.ice_servers.len, cfg.policy == .relay });
        s.acked = true;
        s.startPeer(cfg) catch |err| return s.fail(error.ConnectFailed, "peer connection setup failed: {t}", .{err});
        // Events that arrived before the acknowledgement.
        const pending = s.pending.toOwnedSlice(s.gpa) catch return;
        defer s.gpa.free(pending);
        for (pending) |q| {
            defer q.deinit();
            if (s.failure == null) s.handleEvent(q);
        }
    }

    fn startPeer(s: *Session, cfg: rtc.Config) !void {
        const h = s.bus.hub;
        const peer = try rtc.Peer.create(h, cfg);
        s.peer = peer;
        for (wire.channels, 0..) |label, i| s.dcs[i] = try peer.createChannel(h, label);
        try peer.setLocalDescription("offer");
    }

    fn matchesRoute(s: *const Session, event: std.json.Value) bool {
        const body = if (event == .object) event.object.get("data") orelse event else event;
        if (api.str(body, "ice_id")) |v| if (!std.mem.eql(u8, v, s.ice_id)) return false;
        if (body == .object) if (body.object.get("ice_id")) |v| if (v != .string) return false;
        if (api.str(body, "app_control_id")) |v| if (!std.mem.eql(u8, v, &s.app_control_id)) return false;
        if (body == .object) if (body.object.get("app_control_id")) |v| if (v != .string) return false;
        if (api.str(event, "client_id")) |v| if (!std.mem.eql(u8, v, s.remote)) return false;
        if (event == .object) if (event.object.get("client_id")) |v| if (v != .string) return false;
        return true;
    }

    fn handleEvent(s: *Session, p: signal.Packet) void {
        const name = p.name() orelse return;
        const event = p.body();
        log.debug("signaling event: {s}", .{name});
        if (std.mem.eql(u8, name, "soac")) {
            if (!s.matchesRoute(event)) return;
            const body = if (event == .object) event.object.get("data") orelse event else event;
            const kind = api.str(body, "type") orelse return;
            if (std.mem.eql(u8, kind, "answer")) {
                if (s.answered) return;
                const sdp = wire.answerSdp(s.gpa, body) catch return s.fail(error.ConnectFailed, "invalid answer", .{});
                defer s.gpa.free(sdp);
                const sdpz = s.gpa.dupeSentinel(u8, sdp, 0) catch return;
                defer s.gpa.free(sdpz);
                (s.peer orelse return).setRemoteDescription(sdpz, "answer") catch return s.fail(error.ConnectFailed, "the host's answer was rejected", .{});
                s.answered = true;
                log.info("answer applied", .{});
                for (s.early.items) |c| s.peer.?.addRemoteCandidate(c.candidate, c.mid) catch log.info("queued ICE candidate rejected", .{});
                s.early.clearRetainingCapacity();
            } else if (std.mem.eql(u8, kind, "candidate")) {
                const c = parseCandidate(s.arena.allocator(), body) catch return s.fail(error.ConnectFailed, "invalid candidate", .{});
                if (s.answered) {
                    s.peer.?.addRemoteCandidate(c.candidate, c.mid) catch log.info("ICE candidate rejected", .{});
                } else {
                    if (s.early.items.len >= 256) return s.fail(error.ConnectFailed, "too many early ICE candidates", .{});
                    s.early.append(s.gpa, c) catch return;
                }
            }
        } else if (std.mem.eql(u8, name, "released") or std.mem.eql(u8, name, "left") or std.mem.eql(u8, name, "leave")) {
            if (!s.matchesRoute(event)) return;
            if (s.ready) {
                log.warn("the host released the session", .{});
                s.ended = .released;
            } else s.fail(error.ConnectFailed, "the host released the session during setup", .{});
        }
    }

    fn parseCandidate(a: Allocator, body: std.json.Value) !Candidate {
        const v = (if (body == .object) body.object.get("candidate") else null) orelse return error.MissingCandidate;
        switch (v) {
            .string => |c| return .{
                .candidate = try a.dupeSentinel(u8, c, 0),
                .mid = if (api.str(body, "sdp_mid")) |m| try a.dupeSentinel(u8, m, 0) else null,
            },
            .object => {
                const c = api.str(v, "candidate") orelse return error.MissingCandidate;
                return .{
                    .candidate = try a.dupeSentinel(u8, c, 0),
                    .mid = if (api.str(v, "sdpMid")) |m| try a.dupeSentinel(u8, m, 0) else null,
                };
            },
            else => return error.MissingCandidate,
        }
    }

    // --- WebRTC ---------------------------------------------------------------------------

    fn channelIndex(s: *const Session, dc: c_int) ?usize {
        for (s.dcs, 0..) |d, i| if (d == dc and d >= 0) return i;
        return null;
    }

    fn handleRtc(s: *Session, e: rtc.Event, tool: ?Tool) void {
        const pc = if (s.peer) |p| p.id else return;
        switch (e) {
            .local_description => |d| if (d.pc == pc) s.sendOffer(d.sdp, d.kind),
            .local_candidate => |d| if (d.pc == pc) s.sendCandidate(d.candidate),
            .state => |st| if (st.pc == pc) {
                log.info("peer connection state: {d}", .{@backingInt(st.state)});
                if (st.state == .failed or st.state == .closed) {
                    if (s.ready) s.ended = .peer_failed else s.fail(error.ConnectFailed, "ICE/DTLS connection failed", .{});
                }
            },
            .data_channel => |d| if (d.pc == pc) log.debug("remote opened data channel {d}", .{d.dc}),
            .open => |dc| if (s.channelIndex(dc)) |i| {
                log.debug("{s} open", .{wire.channels[i]});
                s.is_open[i] = true;
                if (i == wire.control) {
                    const echo = wire.echoRequest(s.gpa, 1) catch return;
                    defer s.gpa.free(echo);
                    rtc.send(dc, echo) catch log.warn("echo request send failed", .{});
                }
            },
            .closed => |dc| if (s.channelIndex(dc)) |i| {
                log.info("{s} closed", .{wire.channels[i]});
                s.is_open[i] = false;
                if (i == wire.control or i == wire.file or i == wire.binary) {
                    if (s.ready) s.ended = .channel_closed else s.fail(error.ConnectFailed, "data channel closed during setup", .{});
                }
            },
            .@"error" => |x| log.info("libdatachannel error on {d}", .{x.id}),
            .message => |m| if (s.channelIndex(m.dc)) |i| s.route(i, m.data, tool),
        }
    }

    fn sendOffer(s: *Session, sdp: []const u8, kind: []const u8) void {
        if (!std.mem.eql(u8, kind, "offer")) return;
        s.local_mid = s.arena.allocator().dupe(u8, wire.firstMid(sdp) orelse "0") catch "0";
        const sent = wire.offerSdp(s.gpa, sdp) catch return;
        defer s.gpa.free(sent);
        const json = std.json.Stringify.valueAlloc(s.gpa, .{
            .client_id = s.remote,
            .data = .{
                .app_control_id = &s.app_control_id,
                .ice_id = s.ice_id,
                .ice_network_type = 3,
                .sdp = sent,
                .type = "offer",
            },
        }, .{}) catch return;
        defer s.gpa.free(json);
        s.sig.sendSoac(json) catch return s.fail(error.ConnectFailed, "offer send failed", .{});
        log.info("offer sent", .{});
    }

    fn sendCandidate(s: *Session, candidate: []const u8) void {
        const c = if (std.mem.startsWith(u8, candidate, "a=")) candidate[2..] else candidate;
        if (c.len == 0) return;
        const json = std.json.Stringify.valueAlloc(s.gpa, .{
            .client_id = s.remote,
            .data = .{
                .app_control_id = &s.app_control_id,
                .candidate = .{ .candidate = c, .sdpMLineIndex = 0, .sdpMid = s.local_mid, .usernameFragment = null },
                .ice_id = s.ice_id,
                .type = "candidate",
            },
        }, .{}) catch return;
        defer s.gpa.free(json);
        s.sig.sendSoac(json) catch log.info("candidate send failed", .{});
    }

    /// Echo handling and tool routing (spec §6.5, §6.6).
    fn route(s: *Session, index: usize, data: []const u8, tool: ?Tool) void {
        var target: ?usize = null;
        switch (index) {
            wire.control => {
                if (wire.echoMatches(data, 1)) {
                    if (!s.echo_received) log.info("echo received", .{});
                    s.echo_received = true;
                }
                if (wire.echoRequestSeq(data)) |seq| {
                    const reply = wire.echoResponse(s.gpa, 1_000_000 + seq, seq) catch return;
                    defer s.gpa.free(reply);
                    rtc.send(s.dcs[wire.control], reply) catch {};
                }
                if (wire.blob(data, wire.kind.rpc_request)) |r| {
                    if (wire.blob(r, 8) != null) target = wire.file;
                }
                if (target == null and wire.hasField(data, &.{wire.kind.rpc_response})) target = wire.control;
            },
            wire.text => if (wire.hasField(data, &.{ wire.kind.rpc_request, wire.kind.rpc_response, wire.kind.port_forward })) {
                target = wire.file;
            },
            wire.file, wire.binary => target = index,
            else => {},
        }
        const t = tool orelse return;
        if (target) |ch| t.deliverFn(t.ptr, ch, data);
    }
};

fn uuid(io: Io) [36]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] }) catch unreachable;
    return out;
}

/// Percent-encodes everything but unreserved characters (libdatachannel url-decodes credentials).
fn percentEncode(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~", b) != null) {
            try out.append(a, b);
        } else try out.print(a, "%{X:0>2}", .{b});
    }
    return out.items;
}

/// ICE configuration from the control acknowledgement (upstream `rtc::configuration`), as
/// libdatachannel URLs (`turn:USER:PASS@host:port?transport=...`).
pub fn iceConfig(a: Allocator, ack: std.json.Value) !rtc.Config {
    const list = (if (ack == .object) ack.object.get("iceServers") else null) orelse return error.MissingIceServers;
    if (list != .array) return error.MissingIceServers;
    var urls: std.ArrayList([:0]const u8) = .empty;
    var has_turn = false;
    for (list.array.items) |server| {
        if (server != .object) return error.InvalidIceServer;
        var server_urls: std.ArrayList([]const u8) = .empty;
        switch (server.object.get("urls") orelse return error.InvalidIceUrls) {
            .string => |u| try server_urls.append(a, u),
            .array => |arr| for (arr.items) |u| {
                if (u != .string) return error.InvalidIceUrls;
                try server_urls.append(a, u.string);
            },
            else => return error.InvalidIceUrls,
        }
        if (server_urls.items.len == 0) return error.InvalidIceUrls;
        const user = switch (server.object.get("username") orelse std.json.Value{ .string = "" }) {
            .string => |x| x,
            else => return error.InvalidIceAuth,
        };
        const pass = switch (server.object.get("credential") orelse std.json.Value{ .string = "" }) {
            .string => |x| x,
            else => return error.InvalidIceAuth,
        };
        for (server_urls.items) |u| {
            const scheme_end = std.mem.indexOfScalar(u8, u, ':') orelse return error.InvalidIceScheme;
            const scheme = u[0..scheme_end];
            const known = for ([_][]const u8{ "stun", "stuns", "turn", "turns" }) |k| {
                if (std.mem.eql(u8, scheme, k)) break true;
            } else false;
            if (!known) return error.InvalidIceScheme;
            const turn = std.mem.startsWith(u8, scheme, "turn");
            if (turn) has_turn = true;
            if (std.mem.eql(u8, scheme, "stuns")) {
                log.info("skipping a stuns: ICE server (unsupported by libdatachannel)", .{});
                continue;
            }
            const rest = u[scheme_end + 1 ..];
            const full = if (turn and (user.len != 0 or pass.len != 0))
                try std.fmt.allocPrintSentinel(a, "{s}:{s}:{s}@{s}", .{ scheme, try percentEncode(a, user), try percentEncode(a, pass), rest }, 0)
            else
                try a.dupeSentinel(u8, u, 0);
            try urls.append(a, full);
        }
    }
    const relay = switch ((if (ack == .object) ack.object.get("force_relay") else null) orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => return error.InvalidRelayPolicy,
    };
    if (relay and !has_turn) return error.RelayWithoutTurn;
    return .{ .ice_servers = urls.items, .policy = if (relay) .relay else .all };
}

const testing = std.testing;

test "iceConfig" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ack = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"iceServers":[{"urls":"stun:1.2.3.4:3478"},{"urls":["turn:5.6.7.8:3478?transport=udp","turns:t.example:443"],"username":"u:1","credential":"p@ss/w"},{"urls":"stuns:s.example"}],"force_relay":true}
    , .{});
    const cfg = try iceConfig(a, ack);
    try testing.expectEqual(rtc.TransportPolicy.relay, cfg.policy);
    try testing.expectEqual(@as(usize, 3), cfg.ice_servers.len);
    try testing.expectEqualStrings("stun:1.2.3.4:3478", cfg.ice_servers[0]);
    try testing.expectEqualStrings("turn:u%3A1:p%40ss%2Fw@5.6.7.8:3478?transport=udp", cfg.ice_servers[1]);
    try testing.expectEqualStrings("turns:u%3A1:p%40ss%2Fw@t.example:443", cfg.ice_servers[2]);

    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"iceServers\":[]}", .{});
    try testing.expectEqual(@as(usize, 0), (try iceConfig(a, empty)).ice_servers.len);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"iceServers\":[{\"urls\":\"http://x\"}]}", .{});
    try testing.expectError(error.InvalidIceScheme, iceConfig(a, bad));
    const relay = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"iceServers\":[{\"urls\":\"stun:x\"}],\"force_relay\":true}", .{});
    try testing.expectError(error.RelayWithoutTurn, iceConfig(a, relay));
    try testing.expectError(error.MissingIceServers, iceConfig(a, .null));
}
