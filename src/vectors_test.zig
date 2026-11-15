// SPDX-License-Identifier: GPL-3.0-or-later
//! Checks uucli against the golden vectors in tests/vectors (spec §10).
const std = @import("std");
const vectors = @import("vectors");
const api = @import("api.zig");
const login = @import("login.zig");
const Config = @import("config.zig").Config;
const testing = std.testing;
const Value = std.json.Value;

fn load(arena: std.mem.Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, vectors.auth, .{});
}

fn s(v: Value, key: []const u8) []const u8 {
    return api.str(v, key) orelse "";
}

test "vectors: sign_request" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const root = try load(a.allocator());
    for (root.object.get("sign").?.array.items) |v| {
        var params: std.ArrayList(api.Param) = .empty;
        var it = v.object.get("params").?.object.iterator();
        while (it.next()) |kv| try params.append(a.allocator(), .{ .name = kv.key_ptr.*, .value = kv.value_ptr.string });
        const got = api.sign(s(v, "key"), s(v, "method"), s(v, "path"), params.items, s(v, "body"));
        try testing.expectEqualStrings(s(v, "sign"), &got);
    }
}

test "vectors: build_headers" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const root = try load(a.allocator());
    for (root.object.get("headers").?.array.items) |v| {
        const c = v.object.get("config").?;
        const cfg: Config = .{
            .client_id = s(c, "client_id"), .system_id = s(c, "system_id"), .device_id = s(c, "device_id"),
            .user_id = s(c, "user_id"), .token = s(c, "token"), .csrf = s(c, "csrf"), .sign_key = s(c, "sign_key"),
        };
        const want = v.object.get("headers").?.object;
        const ts = try std.fmt.parseInt(i64, want.get("x-param-ts").?.string, 10);
        var h: api.Headers = .{};
        try api.buildHeaders(&h, &cfg, s(v, "method"), s(v, "path"), s(v, "body"), ts);
        var it = want.iterator();
        var n: usize = 0;
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const value = kv.value_ptr.string;
            // std.http sends these two from Request.Headers, not from the list.
            if (std.mem.eql(u8, name, "user-agent")) {
                try testing.expectEqualStrings(api.user_agent, value);
            } else if (std.mem.eql(u8, name, "content-type")) {
                try testing.expectEqualStrings("application/json", value);
            } else {
                const got = h.get(name) orelse {
                    std.debug.print("missing header {s}\n", .{name});
                    return error.TestUnexpectedResult;
                };
                try testing.expectEqualStrings(value, got);
                n += 1;
            }
        }
        try testing.expectEqual(n, h.len);
    }
}

test "vectors: csrf_from_token" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const root = try load(a.allocator());
    for (root.object.get("csrf").?.array.items) |v| {
        const got = login.csrfFromToken(a.allocator(), s(v, "token"));
        switch (v.object.get("csrf").?) {
            .string => |want| try testing.expectEqualStrings(want, got.?),
            else => try testing.expect(got == null),
        }
    }
}

test "vectors: qr_poll_action" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const root = try load(a.allocator());
    for (root.object.get("qr_poll").?.array.items) |v| {
        const body = v.object.get("body").?;
        const got = login.pollAction(api.int(v, "last").?, @intCast(api.int(v, "http_status").?), if (body == .null) null else body);
        const want = v.object.get("action").?;
        const ok = switch (want) {
            .string => |t| (std.mem.eql(u8, t, "scanned") and got == .scanned) or (std.mem.eql(u8, t, "confirmed") and got == .confirmed),
            .object => |o| if (o.get("wait")) |w| got == .wait and got.wait == w.integer
                else if (o.get("refresh")) |r| got == .refresh and got.refresh == r.integer
                else got == .failed and std.mem.eql(u8, @tagName(got.failed), o.get("failed").?.string),
            else => false,
        };
        if (!ok) {
            std.debug.print("qr_poll mismatch: last={d} status={d} want={f} got={any}\n", .{
                api.int(v, "last").?, api.int(v, "http_status").?, std.json.fmt(want, .{}), got,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "vectors: qr_ticket" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const root = try load(a.allocator());
    for (root.object.get("qr_ticket").?.array.items) |v| {
        const got = login.qrTicket(v.object.get("gen").?);
        switch (v.object.get("ticket").?) {
            .string => |want| try testing.expectEqualStrings(want, got.?),
            else => try testing.expect(got == null),
        }
    }
}

// --- wire.json -------------------------------------------------------------------------------

const wire = @import("wire.zig");

fn loadWire(arena: std.mem.Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, vectors.wire, .{});
}

fn unhex(arena: std.mem.Allocator, h: []const u8) ![]u8 {
    const out = try arena.alloc(u8, h.len / 2);
    return std.fmt.hexToBytes(out, h);
}

fn expectHex(want: []const u8, got: []const u8) !void {
    var buf: [65536]u8 = undefined;
    const g = std.fmt.bufPrint(&buf, "{x}", .{got}) catch unreachable;
    try testing.expectEqualStrings(want, g);
}

fn u64Of(v: Value, key: []const u8) u64 {
    return switch (v.object.get(key).?) {
        .integer => |i| @intCast(i),
        .string => |t| std.fmt.parseInt(u64, t, 10) catch unreachable,
        else => unreachable,
    };
}

test "vectors: varint and envelope" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    for (root.object.get("varint").?.array.items) |v| {
        var b: wire.Builder = .init(ar);
        try b.varint(u64Of(v, "value"));
        try expectHex(s(v, "hex"), b.buf.items);
    }
    for (root.object.get("envelope").?.array.items) |v| {
        const got = try wire.envelope(ar, u64Of(v, "seq"), @intCast(u64Of(v, "kind")), try unhex(ar, s(v, "payload")));
        try expectHex(s(v, "hex"), got);
    }
}

test "vectors: connect options and control request" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    for (root.object.get("sessions").?.array.items) |v| {
        const capture: u32 = @intCast(u64Of(v, "capture_type"));
        try expectHex(s(v, "connect_options"), try wire.connectOptions(ar, capture, s(v, "device_id")));
        try testing.expectEqualStrings(s(v, "control"), try wire.controlRequest(ar, capture, s(v, "app_control_id")));
    }
}

test "vectors: echo" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    try expectHex(s(root, "echo_request_1"), try wire.echoRequest(ar, 1));
    try expectHex(s(root, "echo_response"), try wire.echoResponse(ar, 1000005, 5));
    for (root.object.get("echo").?.array.items) |v| {
        const data = try unhex(ar, s(v, "hex"));
        try testing.expectEqual(v.object.get("matches").?.bool, wire.echoMatches(data, u64Of(v, "seq")));
        const want: ?u64 = switch (v.object.get("request_seq").?) {
            .integer => |i| @intCast(i),
            else => null,
        };
        try testing.expectEqual(want, wire.echoRequestSeq(data));
    }
}

test "vectors: port frames and rpc" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    for (root.object.get("port_frame").?.array.items) |v| {
        const got = try wire.portFrame(ar, u64Of(v, "session"), u64Of(v, "rule"), u64Of(v, "stream"), u64Of(v, "type"), try unhex(ar, s(v, "payload")));
        try expectHex(s(v, "hex"), got);
    }
    for (root.object.get("rpc").?.array.items) |v| {
        const got = try wire.rpc(ar, u64Of(v, "id"), v.object.get("response").?.bool, @intCast(u64Of(v, "case")), try unhex(ar, s(v, "body")));
        try expectHex(s(v, "hex"), got);
    }
}

test "vectors: decode, uint, blob" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    for (root.object.get("decode").?.array.items) |v| {
        const data = try unhex(ar, s(v, "hex"));
        switch (v.object.get("fields").?) {
            .null => try testing.expect(!wire.valid(data)),
            .array => |fields| {
                var it: wire.Iterator = .init(data);
                for (fields.items) |f| {
                    const got = (try it.next()).?;
                    try testing.expectEqual(@as(u32, @intCast(u64Of(f, "number"))), got.number);
                    const val = f.object.get("value").?;
                    if (val.object.get("varint")) |x| try testing.expectEqual(try std.fmt.parseInt(u64, x.string, 10), got.value.varint);
                    if (val.object.get("bytes")) |x| try expectHex(x.string, got.value.bytes);
                    if (val.object.get("fixed32")) |x| try expectHex(x.string, &got.value.fixed32);
                    if (val.object.get("fixed64")) |x| try expectHex(x.string, &got.value.fixed64);
                }
                try testing.expect((try it.next()) == null);
            },
            else => unreachable,
        }
        try testing.expectEqual(u64Of(v, "uint1"), wire.uint(data, 1));
        try testing.expectEqual(u64Of(v, "uint4"), wire.uint(data, 4));
        for ([_]struct { key: []const u8, n: u32 }{ .{ .key = "blob3", .n = 3 }, .{ .key = "blob27", .n = 27 } }) |c| {
            switch (v.object.get(c.key).?) {
                .string => |h| try expectHex(h, wire.blob(data, c.n).?),
                else => try testing.expect(wire.blob(data, c.n) == null),
            }
        }
    }
}

test "vectors: sdp" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const root = try loadWire(ar);
    for (root.object.get("max_message_size").?.array.items) |v| {
        // offerSdp also inserts a=x-uuremote-quic, which needs a=group:BUNDLE; these inputs have none.
        try testing.expectEqualStrings(s(v, "out"), try wire.offerSdp(ar, s(v, "sdp")));
    }
    for (root.object.get("answer_sdp").?.array.items) |v| {
        const got = wire.answerSdp(ar, v.object.get("body").?);
        switch (v.object.get("sdp").?) {
            .string => |want| try testing.expectEqualStrings(want, try got),
            else => try testing.expectError(error.InvalidAnswer, got),
        }
    }
}
