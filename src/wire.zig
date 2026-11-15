// SPDX-License-Identifier: GPL-3.0-or-later
//! Protobuf wire format of the data channel messages (spec §6.3, §6.5, §7).
//! Upstream: src/viewer/wire.rs, src/protocol.rs, src/viewer/tools/mod.rs, src/viewer/tools/portmap.rs.
//! Payloads are never logged.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Message kinds (field numbers of the top-level envelope).
pub const kind = struct {
    pub const simple_action = 3;
    pub const rpc_request = 21;
    pub const rpc_response = 22;
    pub const port_forward = 27;
};

/// Data channels in creation order; the index is the channel number used everywhere.
pub const channels = [_][:0]const u8{
    "CONTROL_DATA_CHANNEL",
    "TEXT_DATA_CHANNEL",
    "STREAMER_DATA_CHANNEL",
    "FILE_DATA_CHANNEL",
    "BINARY_DATA_CHANNEL",
};
pub const control = 0;
pub const text = 1;
pub const file = 3;
pub const binary = 4;

/// Builds a protobuf message in a growable buffer.
pub const Builder = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa);
    }

    pub fn toOwned(b: *Builder) Allocator.Error![]u8 {
        return b.buf.toOwnedSlice(b.gpa);
    }

    pub fn varint(b: *Builder, value: u64) Allocator.Error!void {
        var n = value;
        while (n >= 0x80) : (n >>= 7) try b.buf.append(b.gpa, @as(u8, @truncate(n)) | 0x80);
        try b.buf.append(b.gpa, @truncate(n));
    }

    /// Varint field (wire type 0).
    pub fn int(b: *Builder, field: u32, value: u64) Allocator.Error!void {
        try b.varint(@as(u64, field) << 3);
        try b.varint(value);
    }

    /// Length-delimited field (wire type 2).
    pub fn bytes(b: *Builder, field: u32, value: []const u8) Allocator.Error!void {
        try b.varint((@as(u64, field) << 3) | 2);
        try b.varint(value.len);
        try b.buf.appendSlice(b.gpa, value);
    }
};

/// `{1: seq, kind: payload}`
pub fn envelope(gpa: Allocator, seq: u64, k: u32, payload: []const u8) Allocator.Error![]u8 {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.int(1, seq);
    try b.bytes(k, payload);
    return b.toOwned();
}

// --- Decoding ---------------------------------------------------------------------------------

pub const Value = union(enum) {
    varint: u64,
    fixed64: [8]u8,
    bytes: []const u8,
    fixed32: [4]u8,
};

pub const Field = struct { number: u32, value: Value };

pub const DecodeError = error{ Truncated, VarintOverflow, InvalidField, UnsupportedWireType };

/// Iterates the fields of one complete message, as upstream `decode_wire`.
pub const Iterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Iterator {
        return .{ .data = data };
    }

    fn readVarint(it: *Iterator) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (shift < 70) : (shift += 7) {
            if (it.pos >= it.data.len) return error.Truncated;
            const byte = it.data[it.pos];
            it.pos += 1;
            if (shift == 63 and byte > 1) return error.VarintOverflow;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
        }
        return error.VarintOverflow;
    }

    fn take(it: *Iterator, len: u64) DecodeError![]const u8 {
        if (len > it.data.len - it.pos) return error.Truncated;
        const n: usize = @intCast(len);
        defer it.pos += n;
        return it.data[it.pos..][0..n];
    }

    pub fn next(it: *Iterator) DecodeError!?Field {
        if (it.pos >= it.data.len) return null;
        const key = try it.readVarint();
        const number = key >> 3;
        if (number == 0 or number > 0x1fff_ffff) return error.InvalidField;
        const value: Value = switch (key & 7) {
            0 => .{ .varint = try it.readVarint() },
            1 => .{ .fixed64 = (try it.take(8))[0..8].* },
            2 => .{ .bytes = try it.take(try it.readVarint()) },
            5 => .{ .fixed32 = (try it.take(4))[0..4].* },
            else => return error.UnsupportedWireType,
        };
        return .{ .number = @intCast(number), .value = value };
    }
};

/// True if `data` decodes completely.
pub fn valid(data: []const u8) bool {
    var it: Iterator = .init(data);
    while (it.next() catch return false) |_| {}
    return true;
}

/// First varint field `n`, or 0 (upstream `tools::uint`). 0 also for undecodable messages.
pub fn uint(data: []const u8, n: u32) u64 {
    if (!valid(data)) return 0;
    var it: Iterator = .init(data);
    while (it.next() catch null) |f| if (f.number == n and f.value == .varint) return f.value.varint;
    return 0;
}

/// First length-delimited field `n` (upstream `tools::blob`). Null for undecodable messages.
pub fn blob(data: []const u8, n: u32) ?[]const u8 {
    if (!valid(data)) return null;
    var it: Iterator = .init(data);
    while (it.next() catch null) |f| if (f.number == n and f.value == .bytes) return f.value.bytes;
    return null;
}

/// True if a valid message has any field numbered in `numbers`.
pub fn hasField(data: []const u8, numbers: []const u32) bool {
    if (!valid(data)) return false;
    var it: Iterator = .init(data);
    while (it.next() catch null) |f| for (numbers) |n| if (f.number == n) return true;
    return false;
}

// --- Connect options and control request ------------------------------------------------------

pub const client_version = "4.42.0";
pub const platform = 3;

/// ConnectOptions for a tool session (upstream `Shape::connect_options` with the built-in shape, as
/// `tool_command` sets it up: feature flags cleared; for capture types 8/9 also decoders, display
/// modes, displays and codecs).
pub fn connectOptions(gpa: Allocator, capture_type: u32, device_id: []const u8) Allocator.Error![]u8 {
    std.debug.assert(capture_type == 5 or capture_type == 8 or capture_type == 9);
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.int(1, capture_type);
    if (capture_type == 8) try b.int(2, std.math.maxInt(u64));
    if (capture_type == 5) {
        var size: Builder = .init(gpa);
        defer size.deinit();
        try size.int(1, 1920);
        try size.int(2, 1080);
        var params: Builder = .init(gpa);
        defer params.deinit();
        try params.int(1, 2);
        try params.int(2, 4);
        try params.int(4, 2);
        try params.bytes(5, size.buf.items);
        try params.bytes(6, "");
        try b.bytes(3, params.buf.items);
        // decoders: [{fps 60, codec 1, 3840x2160}]
        var cap: Builder = .init(gpa);
        defer cap.deinit();
        try cap.int(1, 60);
        try cap.int(2, 1);
        try cap.int(3, 3840);
        try cap.int(4, 2160);
        try b.bytes(4, cap.buf.items);
        // display_modes: [[1920, 1080, 60]]
        var mode: Builder = .init(gpa);
        defer mode.deinit();
        try mode.int(1, 1920);
        try mode.int(2, 1080);
        try mode.int(3, 60);
        try b.bytes(6, mode.buf.items);
        try b.bytes(7, size.buf.items);
    }
    try b.int(8, platform);
    try b.bytes(9, device_id);
    try b.int(10, 1);
    if (capture_type != 5) try b.bytes(12, client_version);
    return b.toOwned();
}

/// The JSON object of the `control` event (upstream `Shape::control`), for capture type 5 with its
/// displays/codecs, and the empty lists for 8/9.
pub fn controlRequest(gpa: Allocator, capture_type: u32, app_control_id: []const u8) Allocator.Error![]u8 {
    const display_info = if (capture_type == 5) "[{\"fps\":60,\"hdr\":0,\"id\":1,\"type\":0}]" else "[]";
    const codecs = if (capture_type == 5)
        "[{\"bit_depth\":8,\"chroma_sampling\":1,\"codec_impl\":34,\"height\":2160,\"video_codec\":1,\"width\":3840}]"
    else
        "[]";
    const streamer = try std.fmt.allocPrint(gpa, "{{\"control_id\":{f},\"device_capability\":{{\"display_info\":{s},\"ice_id\":\"\",\"video_codec_capability\":{s}}}}}", .{
        std.json.fmt(app_control_id, .{}), display_info, codecs,
    });
    defer gpa.free(streamer);
    return std.fmt.allocPrint(gpa, "{{\"app_control_id\":{f},\"app_data\":{{\"_placeholder\":true,\"num\":0}},\"streamer_data\":{f}}}", .{
        std.json.fmt(app_control_id, .{}), std.json.fmt(streamer, .{}),
    });
}

// --- Echo (session readiness) -----------------------------------------------------------------

/// Viewer FeatureFlag pairs without clipboard (field 8).
const session_features = [_][2]u32{ .{ 1, 6 }, .{ 2, 2 }, .{ 3, 1 }, .{ 4, 2 }, .{ 6, 2 }, .{ 7, 2 }, .{ 9, 1 } };

fn features(b: *Builder) Allocator.Error!void {
    var f: Builder = .init(b.gpa);
    defer f.deinit();
    for (session_features) |p| try f.int(p[0], p[1]);
    try b.bytes(4, f.buf.items);
}

/// `envelope(seq, 3, {1: 0, 4: FEATURES})`
pub fn echoRequest(gpa: Allocator, seq: u64) Allocator.Error![]u8 {
    var action: Builder = .init(gpa);
    defer action.deinit();
    try action.int(1, 0);
    try features(&action);
    return envelope(gpa, seq, kind.simple_action, action.buf.items);
}

/// Answer to a host echo request: action 1, args `{"seq":REQUEST}`, our features.
pub fn echoResponse(gpa: Allocator, seq: u64, request_seq: u64) Allocator.Error![]u8 {
    var action: Builder = .init(gpa);
    defer action.deinit();
    try action.int(1, 1);
    var args_buf: [40]u8 = undefined;
    try action.bytes(2, std.fmt.bufPrint(&args_buf, "{{\"seq\":{d}}}", .{request_seq}) catch unreachable);
    try features(&action);
    return envelope(gpa, seq, kind.simple_action, action.buf.items);
}

/// The message seq when `data` is a host echo request (SimpleAction with action 0 or absent).
pub fn echoRequestSeq(data: []const u8) ?u64 {
    if (!valid(data)) return null;
    var seq: ?u64 = null;
    var it: Iterator = .init(data);
    while (it.next() catch null) |f| if (f.number == 1 and f.value == .varint) {
        seq = f.value.varint;
        break;
    };
    const s = seq orelse return null;
    it = .init(data);
    while (it.next() catch null) |f| {
        if (f.number != kind.simple_action or f.value != .bytes) continue;
        // Like upstream's find_map: an undecodable or non-request action moves on to the next one.
        const action = f.value.bytes;
        if (!valid(action)) continue;
        var ai: Iterator = .init(action);
        var act: u64 = 0;
        while (ai.next() catch null) |af| if (af.number == 1 and af.value == .varint) {
            act = af.value.varint;
            break;
        };
        if (act == 0) return s;
    }
    return null;
}

/// True if `data` is an echo response (action 1) whose args carry `"seq": seq`.
pub fn echoMatches(data: []const u8, seq: u64) bool {
    if (!valid(data)) return false;
    var it: Iterator = .init(data);
    while (it.next() catch null) |f| {
        if (f.number != kind.simple_action or f.value != .bytes) continue;
        const action = f.value.bytes;
        if (!valid(action)) continue;
        var response = false;
        var ai: Iterator = .init(action);
        while (ai.next() catch null) |af| if (af.number == 1 and af.value == .varint and af.value.varint == 1) {
            response = true;
        };
        if (!response) continue;
        ai = .init(action);
        while (ai.next() catch null) |af| {
            if (af.number != 2 or af.value != .bytes) continue;
            if (argsSeq(af.value.bytes) == seq) return true;
        }
    }
    return false;
}

/// `seq` of a JSON object like `{"seq":1}` (unsigned integer only).
fn argsSeq(json: []const u8) ?u64 {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), json, .{}) catch return null;
    if (v != .object) return null;
    return switch (v.object.get("seq") orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

// --- Port forwarding --------------------------------------------------------------------------

pub const PortFrame = struct {
    pub const syn = 0;
    pub const close = 1;
    pub const data = 2;
    pub const syn_ack = 3;
};

/// `envelope(0, 27, {1: session, 2: rule, 3: stream, 4: type, 5: payload})`
pub fn portFrame(gpa: Allocator, session: u64, rule: u64, stream: u64, frame_type: u64, payload: []const u8) Allocator.Error![]u8 {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.int(1, session);
    try b.int(2, rule);
    try b.int(3, stream);
    try b.int(4, frame_type);
    try b.bytes(5, payload);
    return envelope(gpa, 0, kind.port_forward, b.buf.items);
}

// --- RPC (terminal, files) --------------------------------------------------------------------

/// `envelope(id, 21|22, {1: {1: id}, 8|4: {case: body}})` (upstream `tools::rpc`).
pub fn rpc(gpa: Allocator, id: u64, response: bool, case: u32, body: []const u8) Allocator.Error![]u8 {
    var header: Builder = .init(gpa);
    defer header.deinit();
    try header.int(1, id);
    var inner: Builder = .init(gpa);
    defer inner.deinit();
    try inner.bytes(case, body);
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.bytes(1, header.buf.items);
    try b.bytes(if (response) 4 else 8, inner.buf.items);
    return envelope(gpa, id, if (response) kind.rpc_response else kind.rpc_request, b.buf.items);
}

// --- SDP --------------------------------------------------------------------------------------

/// The offer as sent (spec §6.4 step 4): `a=x-uuremote-quic` before `a=group:BUNDLE` and
/// `a=max-message-size:262144` after `a=sctp-port:`, each only when absent.
pub fn offerSdp(gpa: Allocator, sdp: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const quic = "a=x-uuremote-quic";
    const insert_quic: ?usize = if (std.mem.indexOf(u8, sdp, quic) == null) std.mem.indexOf(u8, sdp, "a=group:BUNDLE") else null;
    const add_mms = std.mem.indexOf(u8, sdp, "a=max-message-size:") == null;
    const eol: []const u8 = if (std.mem.indexOf(u8, sdp, "\r\n") != null) "\r\n" else "\n";
    var pos: usize = 0;
    while (pos < sdp.len) {
        const end = if (std.mem.indexOfScalarPos(u8, sdp, pos, '\n')) |i| i + 1 else sdp.len;
        if (insert_quic) |q| if (q >= pos and q < end) {
            try out.appendSlice(gpa, sdp[pos..q]);
            try out.appendSlice(gpa, quic ++ "\r\n");
            try out.appendSlice(gpa, sdp[q..end]);
            pos = end;
            continue;
        };
        const line = sdp[pos..end];
        try out.appendSlice(gpa, line);
        if (add_mms and std.mem.startsWith(u8, std.mem.trimEnd(u8, line, " \t\r\n"), "a=sctp-port:")) {
            try out.appendSlice(gpa, "a=max-message-size:262144");
            try out.appendSlice(gpa, eol);
        }
        pos = end;
    }
    return out.toOwnedSlice(gpa);
}

/// First `a=mid:` value of an SDP.
pub fn firstMid(sdp: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "a=mid:")) return std.mem.trim(u8, line["a=mid:".len..], " \t\r");
    }
    return null;
}

const testing = std.testing;

test "varint and envelope" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.varint(300);
    try b.varint(std.math.maxInt(u64));
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, b.buf.items);
    const e = try envelope(testing.allocator, 1, 3, "ab");
    defer testing.allocator.free(e);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x01, 0x1a, 0x02, 'a', 'b' }, e);
    try testing.expectEqual(@as(u64, 1), uint(e, 1));
    try testing.expectEqualStrings("ab", blob(e, 3).?);
    try testing.expect(blob(&.{0xff}, 3) == null);
}

test "echo request and response correlate" {
    const gpa = testing.allocator;
    const req = try echoRequest(gpa, 7);
    defer gpa.free(req);
    try testing.expectEqual(@as(?u64, 7), echoRequestSeq(req));
    try testing.expect(!echoMatches(req, 7));
    const resp = try echoResponse(gpa, 1000007, 7);
    defer gpa.free(resp);
    try testing.expect(echoMatches(resp, 7));
    try testing.expect(!echoMatches(resp, 1000007));
    try testing.expect(echoRequestSeq(resp) == null);
    try testing.expect(!echoMatches(&.{255}, 7));
}

test "offerSdp" {
    const gpa = testing.allocator;
    const got = try offerSdp(gpa, "v=0\r\na=group:BUNDLE 0\r\nm=application 9\r\na=sctp-port:5000\r\na=mid:0\r\n");
    defer gpa.free(got);
    try testing.expectEqualStrings("v=0\r\na=x-uuremote-quic\r\na=group:BUNDLE 0\r\nm=application 9\r\na=sctp-port:5000\r\na=max-message-size:262144\r\na=mid:0\r\n", got);
    const same = try offerSdp(gpa, "a=x-uuremote-quic\r\na=group:BUNDLE 0\r\na=max-message-size:1\r\n");
    defer gpa.free(same);
    try testing.expectEqualStrings("a=x-uuremote-quic\r\na=group:BUNDLE 0\r\na=max-message-size:1\r\n", same);
    try testing.expectEqualStrings("0", firstMid("v=0\r\na=mid:0\r\na=mid:1\r\n").?);
}

/// The answer SDP of a `soac` answer body (upstream `answer_sdp`): `sdp` (≤ 1 MiB), else `gzip_sdp`
/// (base64 of gzip, ≤ 2 MiB encoded, ≤ 1 MiB decoded). Caller frees.
pub fn answerSdp(gpa: Allocator, body: std.json.Value) error{ InvalidAnswer, OutOfMemory }![]u8 {
    const limit = 1024 * 1024;
    if (body != .object) return error.InvalidAnswer;
    if (body.object.get("sdp")) |v| if (v == .string and v.string.len <= limit) return gpa.dupe(u8, v.string);
    const gz = body.object.get("gzip_sdp") orelse return error.InvalidAnswer;
    if (gz != .string or gz.string.len > 2 * limit) return error.InvalidAnswer;
    const dec = std.base64.standard.Decoder;
    const raw = try gpa.alloc(u8, dec.calcSizeForSlice(gz.string) catch return error.InvalidAnswer);
    defer gpa.free(raw);
    dec.decode(raw, gz.string) catch return error.InvalidAnswer;
    var in: std.Io.Reader = .fixed(raw);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    const out = d.reader.allocRemaining(gpa, .limited(limit + 1)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidAnswer,
    };
    if (out.len > limit) {
        gpa.free(out);
        return error.InvalidAnswer;
    }
    return out;
}
