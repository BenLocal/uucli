// SPDX-License-Identifier: GPL-3.0-or-later
//! libdatachannel binding. This is the only module that touches libdatachannel handles or threads:
//! every callback copies its data into an `Event` and pushes it onto `Hub.queue`, which the
//! program's own tasks drain through `std.Io`.
const std = @import("std");
const c = @import("c");
const Io = std.Io;

/// Heap for event payloads; must be usable from libdatachannel's threads.
const heap = std.heap.c_allocator;

pub const State = enum(c_int) { new = 0, connecting, connected, disconnected, failed, closed, _ };

pub const Event = union(enum) {
    local_description: struct { pc: c_int, sdp: []u8, kind: []u8 },
    local_candidate: struct { pc: c_int, candidate: []u8, mid: []u8 },
    state: struct { pc: c_int, state: State },
    data_channel: struct { pc: c_int, dc: c_int },
    open: c_int,
    closed: c_int,
    @"error": struct { id: c_int, message: []u8 },
    message: struct { dc: c_int, data: []u8, binary: bool },

    /// Frees the payload copied by the callback.
    pub fn deinit(e: Event) void {
        switch (e) {
            .local_description => |d| {
                heap.free(d.sdp);
                heap.free(d.kind);
            },
            .local_candidate => |d| {
                heap.free(d.candidate);
                heap.free(d.mid);
            },
            .@"error" => |d| heap.free(d.message),
            .message => |d| heap.free(d.data),
            .state, .data_channel, .open, .closed => {},
        }
    }
};

pub const Error = error{ Rtc, OutOfMemory };

fn check(rc: c_int) Error!c_int {
    return if (rc < 0) error.Rtc else rc;
}

/// Receives the events of every peer connection and data channel. There is one hub per process,
/// in static memory, because libdatachannel may still invoke a callback after its peer is closed.
pub const Hub = struct {
    io: Io,
    queue: Io.Queue(Event),
    /// Callbacks currently inside `push`.
    active: std.atomic.Value(u32) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),

    /// Waits for the next event; the caller owns it and calls `deinit`.
    pub fn next(h: *Hub) (Io.QueueClosedError || Io.Cancelable)!Event {
        return h.queue.getOne(h.io);
    }

    /// Stops delivering events. Afterwards no libdatachannel callback touches `io` again, so the
    /// `Io` instance may be torn down; late callbacks only read `closing` and return.
    pub fn shutdown(h: *Hub) void {
        h.closing.store(true, .seq_cst);
        // Wakes callbacks blocked on a full queue; they drop their event.
        h.queue.close(h.io);
        while (h.active.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        while (h.queue.getOneUncancelable(h.io)) |e| e.deinit() else |_| {}
    }

    fn push(h: *Hub, event: Event) void {
        _ = h.active.fetchAdd(1, .seq_cst);
        defer _ = h.active.fetchSub(1, .seq_cst);
        if (h.closing.load(.seq_cst)) return event.deinit();
        // Blocks the libdatachannel thread when the queue is full: back-pressure, never a drop.
        h.queue.putOneUncancelable(h.io, event) catch event.deinit();
    }
};

var hub_buffer: [256]Event = undefined;
var hub_storage: Hub = undefined;
var hub_ready = false;

/// Returns the process-wide hub, creating it on first use (or again after `shutdown`, for tests
/// that run several sessions). Not thread-safe; call from main first.
pub fn globalHub(io: Io) *Hub {
    if (!hub_ready or hub_storage.closing.load(.seq_cst)) {
        hub_storage = .{ .io = io, .queue = .init(&hub_buffer) };
        hub_ready = true;
    }
    return &hub_storage;
}

fn hubOf(_: ?*anyopaque) *Hub {
    return &hub_storage;
}

fn dupe(s: [*c]const u8) ?[]u8 {
    if (s == null) return heap.alloc(u8, 0) catch null;
    return heap.dupe(u8, std.mem.span(s)) catch null;
}

fn onDescription(pc: c_int, sdp: [*c]const u8, kind: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    const s = dupe(sdp) orelse return;
    const k = dupe(kind) orelse return heap.free(s);
    hubOf(ptr).push(.{ .local_description = .{ .pc = pc, .sdp = s, .kind = k } });
}

fn onCandidate(pc: c_int, cand: [*c]const u8, mid: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    const s = dupe(cand) orelse return;
    const m = dupe(mid) orelse return heap.free(s);
    hubOf(ptr).push(.{ .local_candidate = .{ .pc = pc, .candidate = s, .mid = m } });
}

fn onState(pc: c_int, state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
    hubOf(ptr).push(.{ .state = .{ .pc = pc, .state = @fromBackingInt(@intCast(state)) } });
}

fn onDataChannel(pc: c_int, dc: c_int, ptr: ?*anyopaque) callconv(.c) void {
    // Channels the remote opens get the same callbacks as our own.
    registerChannel(dc, hubOf(ptr));
    hubOf(ptr).push(.{ .data_channel = .{ .pc = pc, .dc = dc } });
}

fn onOpen(id: c_int, ptr: ?*anyopaque) callconv(.c) void {
    hubOf(ptr).push(.{ .open = id });
}

fn onClosed(id: c_int, ptr: ?*anyopaque) callconv(.c) void {
    hubOf(ptr).push(.{ .closed = id });
}

fn onError(id: c_int, message: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    const m = dupe(message) orelse return;
    hubOf(ptr).push(.{ .@"error" = .{ .id = id, .message = m } });
}

/// The bytes of a message callback. libdatachannel passes -(length + 1) for text messages. Not
/// strlen: the official Windows host sends binary protobuf (e.g. zlib directory listings) as text,
/// NUL bytes included.
fn messageBytes(message: [*c]const u8, size: c_int) []const u8 {
    return message[0..@intCast(if (size >= 0) size else -size - 1)];
}

fn onMessage(id: c_int, message: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
    const binary = size >= 0;
    const data = heap.dupe(u8, messageBytes(message, size)) catch return;
    hubOf(ptr).push(.{ .message = .{ .dc = id, .data = data, .binary = binary } });
}

fn registerChannel(dc: c_int, h: *Hub) void {
    c.rtcSetUserPointer(dc, h);
    _ = c.rtcSetOpenCallback(dc, onOpen);
    _ = c.rtcSetClosedCallback(dc, onClosed);
    _ = c.rtcSetErrorCallback(dc, onError);
    _ = c.rtcSetMessageCallback(dc, onMessage);
}

pub const TransportPolicy = enum { all, relay };

pub const Config = struct {
    /// "stun:host:port" / "turn:user:pass@host:port" URLs in libdatachannel syntax.
    ice_servers: []const [:0]const u8 = &.{},
    policy: TransportPolicy = .all,
    max_message_size: c_int = 262144,
};

pub const Peer = struct {
    id: c_int,

    pub fn create(h: *Hub, config: Config) Error!Peer {
        var urls: [16][*c]const u8 = undefined;
        if (config.ice_servers.len > urls.len) return error.Rtc;
        for (config.ice_servers, 0..) |u, i| urls[i] = u.ptr;
        var cfg = std.mem.zeroes(c.rtcConfiguration);
        cfg.iceServers = @ptrCast(&urls);
        cfg.iceServersCount = @intCast(config.ice_servers.len);
        cfg.iceTransportPolicy = switch (config.policy) {
            .all => c.RTC_TRANSPORT_POLICY_ALL,
            .relay => c.RTC_TRANSPORT_POLICY_RELAY,
        };
        cfg.maxMessageSize = config.max_message_size;
        // The offer is created explicitly once every channel exists.
        cfg.disableAutoNegotiation = true;
        const id = try check(c.rtcCreatePeerConnection(&cfg));
        c.rtcSetUserPointer(id, h);
        _ = c.rtcSetLocalDescriptionCallback(id, onDescription);
        _ = c.rtcSetLocalCandidateCallback(id, onCandidate);
        _ = c.rtcSetStateChangeCallback(id, onState);
        _ = c.rtcSetDataChannelCallback(id, onDataChannel);
        return .{ .id = id };
    }

    /// Creates an ordered, reliable, in-band negotiated channel.
    pub fn createChannel(p: Peer, h: *Hub, label: [:0]const u8) Error!c_int {
        const dc = try check(c.rtcCreateDataChannel(p.id, label.ptr));
        registerChannel(dc, h);
        return dc;
    }

    /// Starts negotiation; the description arrives as a `local_description` event.
    pub fn setLocalDescription(p: Peer, kind: ?[:0]const u8) Error!void {
        _ = try check(c.rtcSetLocalDescription(p.id, if (kind) |k| k.ptr else null));
    }

    pub fn setRemoteDescription(p: Peer, sdp: [:0]const u8, kind: [:0]const u8) Error!void {
        _ = try check(c.rtcSetRemoteDescription(p.id, sdp.ptr, kind.ptr));
    }

    pub fn addRemoteCandidate(p: Peer, candidate: [:0]const u8, mid: ?[:0]const u8) Error!void {
        _ = try check(c.rtcAddRemoteCandidate(p.id, candidate.ptr, if (mid) |m| m.ptr else null));
    }

    pub fn close(p: Peer) void {
        _ = c.rtcClosePeerConnection(p.id);
        _ = c.rtcDeletePeerConnection(p.id);
    }
};

pub fn send(dc: c_int, data: []const u8) Error!void {
    _ = try check(c.rtcSendMessage(dc, data.ptr, @intCast(data.len)));
}

pub fn bufferedAmount(dc: c_int) usize {
    const n = c.rtcGetBufferedAmount(dc);
    return if (n < 0) 0 else @intCast(n);
}

/// In-process self test: two peers negotiate over host candidates and exchange one message.
/// Exercises the libdatachannel callback thread → `Io.Queue` → task hand-off end to end.
pub fn loopback(io: Io) !void {
    const h = globalHub(io);
    defer h.shutdown();

    const a = try Peer.create(h, .{});
    defer a.close();
    const b = try Peer.create(h, .{});
    defer b.close();
    const dc = try a.createChannel(h, "uucli-loopback");
    try a.setLocalDescription("offer");

    const payload = "ping";
    while (true) {
        const e = try h.next();
        defer e.deinit();
        switch (e) {
            .local_description => |d| {
                const sdp = try heap.dupeSentinel(u8, d.sdp, 0);
                defer heap.free(sdp);
                const kind = try heap.dupeSentinel(u8, d.kind, 0);
                defer heap.free(kind);
                const other = if (d.pc == a.id) b else a;
                try other.setRemoteDescription(sdp, kind);
                if (other.id == b.id) try b.setLocalDescription("answer");
            },
            .local_candidate => |d| {
                const cand = try heap.dupeSentinel(u8, d.candidate, 0);
                defer heap.free(cand);
                const mid = try heap.dupeSentinel(u8, d.mid, 0);
                defer heap.free(mid);
                const other = if (d.pc == a.id) b else a;
                try other.addRemoteCandidate(cand, mid);
            },
            .open => |id| if (id == dc) try send(dc, payload),
            .message => |m| if (m.dc != dc) {
                if (!std.mem.eql(u8, m.data, payload)) return error.LoopbackMismatch;
                return;
            },
            .state => |s| if (s.state == .failed) return error.LoopbackFailed,
            .data_channel, .closed, .@"error" => {},
        }
    }
}

test "text messages keep their NUL bytes" {
    const text = "a\x00b\x00";
    try std.testing.expectEqualStrings("a\x00b", messageBytes(text, -4));
    try std.testing.expectEqualStrings("a\x00", messageBytes(text, 2));
    try std.testing.expectEqualStrings("", messageBytes(text, -1));
}
