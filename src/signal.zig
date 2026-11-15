// SPDX-License-Identifier: GPL-3.0-or-later
//! Engine.IO 4 / Socket.IO signaling over WebSocket (spec §6.2, §6.3). Upstream: src/viewer/signal.rs.
//! Never logs the room token, SDP, candidates or ICE credentials.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ws = @import("ws.zig");

const log = std.log.scoped(.signal);

pub const max_attachments = 8;
pub const max_attachment = 4 * 1024 * 1024;

/// One text frame, classified.
pub const Frame = union(enum) {
    /// `0{json}`: Engine.IO open.
    open,
    /// `40...`: Socket.IO namespace connected.
    connected,
    /// `2...`: ping; reply `3` + the same suffix.
    ping: []const u8,
    /// `42[...]`
    event: []const u8,
    /// `43{id}[...]`
    ack: struct { id: u64, json: []const u8 },
    /// `45{n}-[...]`: event followed by `n` binary attachments.
    binary_event: struct { count: usize, json: []const u8 },
    /// `46{n}-{id}[...]`
    binary_ack: struct { count: usize, id: u64, json: []const u8 },
    /// `41` or `1`: room closed.
    closed,
    other,
};

pub const ParseError = error{MalformedFrame};

pub fn parseFrame(t: []const u8) ParseError!Frame {
    if (t.len == 0) return .other;
    if (std.mem.eql(u8, t, "41") or std.mem.eql(u8, t, "1")) return .closed;
    if (std.mem.startsWith(u8, t, "40")) return .connected;
    if (t[0] == '0') return .open;
    if (t[0] == '2') return .{ .ping = t[1..] };
    if (std.mem.startsWith(u8, t, "42")) {
        const begin = std.mem.indexOfScalar(u8, t, '[') orelse return error.MalformedFrame;
        return .{ .event = t[begin..] };
    }
    if (std.mem.startsWith(u8, t, "43")) {
        const begin = std.mem.indexOfScalar(u8, t, '[') orelse return error.MalformedFrame;
        const id = std.fmt.parseInt(u64, t[2..begin], 10) catch return error.MalformedFrame;
        return .{ .ack = .{ .id = id, .json = t[begin..] } };
    }
    if (std.mem.startsWith(u8, t, "45") or std.mem.startsWith(u8, t, "46")) {
        const dash = std.mem.indexOfScalar(u8, t, '-') orelse return error.MalformedFrame;
        const count = std.fmt.parseInt(usize, t[2..dash], 10) catch return error.MalformedFrame;
        const begin = std.mem.indexOfScalar(u8, t, '[') orelse return error.MalformedFrame;
        if (begin < dash) return error.MalformedFrame;
        if (t[1] == '5') return .{ .binary_event = .{ .count = count, .json = t[begin..] } };
        const id = std.fmt.parseInt(u64, t[dash + 1 .. begin], 10) catch return error.MalformedFrame;
        return .{ .binary_ack = .{ .count = count, .id = id, .json = t[begin..] } };
    }
    return .other;
}

/// Replaces every `{"_placeholder":true,"num":k}` by attachment `k` as a base64 string.
pub fn fillPlaceholders(arena: Allocator, v: *std.json.Value, attachments: []const []const u8) Allocator.Error!void {
    switch (v.*) {
        .object => |*o| {
            if (o.get("_placeholder")) |p| if (p == .bool and p.bool) {
                const num = o.get("num") orelse return;
                if (num != .integer or num.integer < 0 or num.integer >= attachments.len) return;
                const raw = attachments[@intCast(num.integer)];
                const enc = std.base64.standard.Encoder;
                const out = try arena.alloc(u8, enc.calcSize(raw.len));
                _ = enc.encode(out, raw);
                v.* = .{ .string = out };
                return;
            };
            for (o.values()) |*x| try fillPlaceholders(arena, x, attachments);
        },
        .array => |*a| for (a.items) |*x| try fillPlaceholders(arena, x, attachments),
        else => {},
    }
}

/// A signaling event or ack with its JSON array (`[name, body]` or ack values). Owns its memory.
pub const Packet = struct {
    arena: *std.heap.ArenaAllocator,
    kind: union(enum) { event, ack: u64 },
    value: std.json.Value,

    pub fn deinit(p: Packet) void {
        const gpa = p.arena.child_allocator;
        p.arena.deinit();
        gpa.destroy(p.arena);
    }

    /// Deep copy (re-encoded), owned by `gpa`.
    pub fn clone(p: Packet, gpa: Allocator) !Packet {
        const json = try std.json.Stringify.valueAlloc(gpa, p.value, .{});
        defer gpa.free(json);
        return makePacket(gpa, json, p.kind, &.{});
    }

    /// Event name (`value[0]`) or null.
    pub fn name(p: Packet) ?[]const u8 {
        if (p.value != .array or p.value.array.items.len == 0) return null;
        return switch (p.value.array.items[0]) {
            .string => |s| s,
            else => null,
        };
    }

    /// `value[1]` or `.null`.
    pub fn body(p: Packet) std.json.Value {
        if (p.value != .array or p.value.array.items.len < 2) return .null;
        return p.value.array.items[1];
    }
};

fn makePacket(gpa: Allocator, json: []const u8, kind: @FieldType(Packet, "kind"), attachments: []const []const u8) !Packet {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{ .allocate = .alloc_always }) catch
        return error.MalformedFrame;
    if (attachments.len != 0) try fillPlaceholders(arena.allocator(), &value, attachments);
    return .{ .arena = arena, .kind = kind, .value = value };
}

/// The binary attachment as upstream keeps it: a leading 0x04 is stripped from `0x04 0x1f ...`
/// (legacy prefix in front of gzip data).
pub fn attachmentBytes(b: []const u8) []const u8 {
    if (b.len > 2 and b[0] == 4 and b[1] == 0x1f) return b[1..];
    return b;
}

pub const Signal = struct {
    io: Io,
    gpa: Allocator,
    socket: ws.Socket,
    next_ack: u64 = 10,

    /// Tries each URL in order; `timeout` per URL covers connect and handshake.
    pub fn connect(io: Io, gpa: Allocator, http: *std.http.Client, urls: []const []const u8, token: []const u8, timeout: Io.Duration) !Signal {
        for (urls) |base| {
            if (connectOne(io, gpa, http, base, token, timeout)) |s| return s else |err| switch (err) {
                error.Canceled => |e| return e,
                else => log.info("signaling endpoint failed: {t}", .{err}),
            }
        }
        return error.SignalingFailed;
    }

    fn connectOne(io: Io, gpa: Allocator, http: *std.http.Client, base: []const u8, token: []const u8, timeout: Io.Duration) !Signal {
        const U = union(enum) { done: anyerror!Signal, timeout: Io.Cancelable!void };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(io, &buf);
        try sel.concurrent(.done, handshake, .{ io, gpa, http, base, token });
        sel.concurrent(.timeout, Io.sleep, .{ io, timeout, .awake }) catch |err| {
            if (sel.cancel()) |r| if (r == .done) if (r.done) |s| {
                var x = s;
                x.close();
            } else |_| {};
            return err;
        };
        const first = try sel.await();
        // The loser is canceled; a handshake that completed anyway is closed.
        if (sel.cancel()) |late| if (late == .done) if (late.done) |s| {
            var x = s;
            x.close();
        } else |_| {};
        return switch (first) {
            .timeout => error.Timeout,
            .done => |r| r,
        };
    }

    fn handshake(io: Io, gpa: Allocator, http: *std.http.Client, base: []const u8, token: []const u8) anyerror!Signal {
        const url = try std.fmt.allocPrint(gpa, "{s}/socket.io/?transport=websocket&EIO=4", .{std.mem.trimEnd(u8, base, "/")});
        defer gpa.free(url);
        var s: Signal = .{
            .io = io,
            .gpa = gpa,
            .socket = try ws.Socket.connect(io, http, url, &.{.{ .name = "X-NRD-AUTH", .value = token }}),
        };
        errdefer s.close();
        var opened = false;
        while (true) {
            const m = try s.socket.receive(gpa);
            defer gpa.free(m.data);
            if (m.opcode != .text) return error.HandshakeFailed;
            switch (try parseFrame(m.data)) {
                .open => if (!opened) {
                    _ = std.json.validate(gpa, m.data[1..]) catch return error.HandshakeFailed;
                    opened = true;
                    try s.socket.send(.text, "40");
                } else return error.HandshakeFailed,
                .connected => if (opened) return s else return error.HandshakeFailed,
                .ping => |suffix| try s.pong(suffix),
                else => return error.HandshakeFailed,
            }
        }
    }

    pub fn close(s: *Signal) void {
        s.socket.deinit();
    }

    fn pong(s: *Signal, suffix: []const u8) !void {
        var buf: [64]u8 = undefined;
        const reply = std.fmt.bufPrint(&buf, "3{s}", .{suffix}) catch "3";
        try s.socket.send(.text, reply);
    }

    /// Next event or ack. Answers pings; returns error.RoomClosed / error.Closed when the room ends.
    /// Only one task may call this.
    pub fn next(s: *Signal) !Packet {
        while (true) {
            const m = try s.socket.receive(s.gpa);
            defer s.gpa.free(m.data);
            if (m.opcode != .text) {
                log.debug("signaling frame ignored: binary bytes={d}", .{m.data.len});
                continue;
            }
            switch (try parseFrame(m.data)) {
                .ping => |suffix| try s.pong(suffix),
                .event => |json| return makePacket(s.gpa, json, .event, &.{}),
                .ack => |a| return makePacket(s.gpa, a.json, .{ .ack = a.id }, &.{}),
                .binary_event => |b| return s.withAttachments(b.json, b.count, .event),
                .binary_ack => |b| return s.withAttachments(b.json, b.count, .{ .ack = b.id }),
                .closed => return error.RoomClosed,
                .open, .connected, .other => log.debug("signaling frame ignored: prefix={s} bytes={d}", .{ m.data[0..@min(3, m.data.len)], m.data.len }),
            }
        }
    }

    fn withAttachments(s: *Signal, json: []const u8, count: usize, kind: @FieldType(Packet, "kind")) !Packet {
        if (count > max_attachments) return error.MalformedFrame;
        var raw: [max_attachments][]u8 = undefined;
        var got: usize = 0;
        defer for (raw[0..got]) |b| s.gpa.free(b);
        var views: [max_attachments][]const u8 = undefined;
        while (got < count) {
            const m = try s.socket.receive(s.gpa);
            switch (m.opcode) {
                .binary => {
                    if (m.data.len > max_attachment + 1) {
                        s.gpa.free(m.data);
                        return error.MalformedFrame;
                    }
                    raw[got] = m.data;
                    views[got] = attachmentBytes(m.data);
                    got += 1;
                },
                else => {
                    defer s.gpa.free(m.data);
                    if (parseFrame(m.data) catch .other == .ping) try s.pong(m.data[1..]);
                },
            }
        }
        return makePacket(s.gpa, json, kind, views[0..count]);
    }

    /// Sends `451-{N}["control",HEADER]` and the binary attachment `0x04 ++ options`; returns N.
    pub fn sendControl(s: *Signal, header_json: []const u8, connect_options: []const u8) !u64 {
        s.next_ack += 1;
        const id = s.next_ack;
        const text = try std.fmt.allocPrint(s.gpa, "451-{d}[\"control\",{s}]", .{ id, header_json });
        defer s.gpa.free(text);
        try s.socket.send(.text, text);
        const bin = try s.gpa.alloc(u8, connect_options.len + 1);
        defer s.gpa.free(bin);
        bin[0] = 4;
        @memcpy(bin[1..], connect_options);
        try s.socket.send(.binary, bin);
        return id;
    }

    /// Sends `42["soac",VALUE]`.
    pub fn sendSoac(s: *Signal, value_json: []const u8) !void {
        const text = try std.fmt.allocPrint(s.gpa, "42[\"soac\",{s}]", .{value_json});
        defer s.gpa.free(text);
        try s.socket.send(.text, text);
    }
};

const testing = std.testing;

test "parseFrame" {
    try testing.expectEqual(Frame.open, try parseFrame("0{\"sid\":\"x\"}"));
    try testing.expectEqual(Frame.connected, try parseFrame("40{\"sid\":\"y\"}"));
    try testing.expectEqualStrings("", (try parseFrame("2")).ping);
    try testing.expectEqualStrings("probe", (try parseFrame("2probe")).ping);
    try testing.expectEqualStrings("[\"soac\",{}]", (try parseFrame("42[\"soac\",{}]")).event);
    const a = (try parseFrame("4311[\"success\",{}]")).ack;
    try testing.expectEqual(@as(u64, 11), a.id);
    const be = (try parseFrame("451-[\"soac\",{\"_placeholder\":true,\"num\":0}]")).binary_event;
    try testing.expectEqual(@as(usize, 1), be.count);
    const ba = (try parseFrame("462-12[\"success\",{}]")).binary_ack;
    try testing.expectEqual(@as(usize, 2), ba.count);
    try testing.expectEqual(@as(u64, 12), ba.id);
    try testing.expectEqual(Frame.closed, try parseFrame("41"));
    try testing.expectEqual(Frame.closed, try parseFrame("1"));
    try testing.expectError(error.MalformedFrame, parseFrame("43x[1]"));
    try testing.expectError(error.MalformedFrame, parseFrame("42{}"));
    try testing.expectEqual(Frame.other, try parseFrame("6"));
}

test "placeholders become base64 attachments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, ar,
        \\["soac",{"data":{"type":"answer","gzip_sdp":{"_placeholder":true,"num":1}},"x":[{"_placeholder":true,"num":0}],"y":{"_placeholder":true,"num":5}}]
    , .{});
    try fillPlaceholders(ar, &v, &.{ "ab", attachmentBytes(&.{ 4, 0x1f, 0x8b }) });
    const body = v.array.items[1].object;
    try testing.expectEqualStrings("H4s=", body.get("data").?.object.get("gzip_sdp").?.string);
    try testing.expectEqualStrings("YWI=", body.get("x").?.array.items[0].string);
    try testing.expect(body.get("y").? == .object); // out of range stays
    try testing.expectEqualSlices(u8, &.{ 4, 1 }, attachmentBytes(&.{ 4, 1 }));
}

fn fakeSignalServer(t: *ws.TestServer, io: Io) void {
    var seen: [64]u8 = undefined;
    const acc = t.accept(io, "X-NRD-AUTH", &seen) catch return;
    defer acc.stream.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = acc.stream.writer(io, &wbuf);
    var rbuf: [4096]u8 = undefined;
    var r = acc.stream.reader(io, &rbuf);
    var buf: [4096]u8 = undefined;
    ws.testServerFrame(&w.interface, true, .text, "0{\"sid\":\"s\",\"pingInterval\":25000}") catch return;
    w.interface.flush() catch return;
    const f40 = ws.testReadClientFrame(&r.interface, &buf) catch return;
    if (!std.mem.eql(u8, f40.data, "40")) return;
    ws.testServerFrame(&w.interface, true, .text, "2") catch return;
    ws.testServerFrame(&w.interface, true, .text, "40{\"sid\":\"n\"}") catch return;
    w.interface.flush() catch return;
    const pong = ws.testReadClientFrame(&r.interface, &buf) catch return;
    if (!std.mem.eql(u8, pong.data, "3")) return;
    // control text + binary
    const ctl = ws.testReadClientFrame(&r.interface, &buf) catch return;
    if (!std.mem.startsWith(u8, ctl.data, "451-11[\"control\",")) return;
    const bin = ws.testReadClientFrame(&r.interface, &buf) catch return;
    if (bin.opcode != .binary or bin.data[0] != 4) return;
    ws.testServerFrame(&w.interface, true, .text, "42[\"early\",{}]") catch return;
    ws.testServerFrame(&w.interface, true, .text, "4311[\"success\",{\"client_id\":\"r\"}]") catch return;
    ws.testServerFrame(&w.interface, true, .text, "451-[\"soac\",{\"data\":{\"type\":\"answer\",\"gzip_sdp\":{\"_placeholder\":true,\"num\":0}}}]") catch return;
    ws.testServerFrame(&w.interface, true, .text, "2") catch return;
    ws.testServerFrame(&w.interface, true, .binary, &.{ 4, 0x1f, 0x8b }) catch return;
    ws.testServerFrame(&w.interface, true, .text, "41") catch return;
    w.interface.flush() catch return;
    _ = ws.testReadClientFrame(&r.interface, &buf) catch return; // pong
    _ = ws.testReadClientFrame(&r.interface, &buf) catch return; // close
}

test "Signal against a fake server" {
    const io = testing.io;
    const gpa = testing.allocator;
    var t: ws.TestServer = try .init(io);
    defer t.deinit(io);
    var task = try io.concurrent(fakeSignalServer, .{ &t, io });
    defer task.cancel(io);
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{t.port()});
    var s = try Signal.connect(io, gpa, &http, &.{ "ws://127.0.0.1:1", url }, "tok", .fromSeconds(5));
    defer s.close();
    try testing.expectEqual(@as(u64, 11), try s.sendControl("{}", &.{ 8, 9 }));
    const early = try s.next();
    defer early.deinit();
    try testing.expectEqualStrings("early", early.name().?);
    const ack = try s.next();
    defer ack.deinit();
    try testing.expectEqual(@as(u64, 11), ack.kind.ack);
    const answer = try s.next();
    defer answer.deinit();
    try testing.expectEqualStrings("H4s=", answer.body().object.get("data").?.object.get("gzip_sdp").?.string);
    try testing.expectError(error.RoomClosed, s.next());
}
