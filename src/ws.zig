// SPDX-License-Identifier: GPL-3.0-or-later
//! WebSocket client (RFC 6455) for Socket.IO signaling (spec §6.2). Upstream: src/ws_transport.rs.
//! The HTTP upgrade goes through `std.http.Client`, so TCP, TLS (wss), CA roots and the opt-in
//! HTTP(S) proxy (CONNECT) behave as for REST. No extensions, no subprotocol, no redirects.
//! Header values (room token) and payloads are never logged.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.ws);

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Message = struct {
    opcode: Opcode,
    /// Owned by the caller (free with the allocator passed to `receive`).
    data: []u8,
};

pub const Error = error{
    /// Upgrade refused or the response is not a valid WebSocket upgrade.
    HandshakeFailed,
    /// Peer sent a malformed frame or violated the protocol.
    ProtocolError,
    /// Close frame received or the connection ended.
    Closed,
    MessageTooLarge,
};

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const max_message = 8 * 1024 * 1024;

pub const Socket = struct {
    io: Io,
    http: *std.http.Client,
    conn: *std.http.Client.Connection,
    write_lock: Io.Mutex = .init,
    closed: bool = false,

    /// Opens `url` (`ws://` or `wss://`) with `extra_headers`. Errors carry no URL or header values.
    pub fn connect(io: Io, http: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header) !Socket {
        var uri = std.Uri.parse(url) catch return error.HandshakeFailed;
        if (std.mem.eql(u8, uri.scheme, "ws")) {
            uri.scheme = "http";
        } else if (std.mem.eql(u8, uri.scheme, "wss")) {
            uri.scheme = "https";
        } else return error.HandshakeFailed;
        if (uri.user != null or uri.password != null or uri.fragment != null) return error.HandshakeFailed;

        var key_raw: [16]u8 = undefined;
        io.random(&key_raw);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_raw);

        var headers: [16]std.http.Header = undefined;
        const fixed = [_]std.http.Header{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Sec-WebSocket-Key", .value = &key },
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
        };
        if (fixed.len + extra_headers.len > headers.len) return error.HandshakeFailed;
        @memcpy(headers[0..fixed.len], &fixed);
        @memcpy(headers[fixed.len..][0..extra_headers.len], extra_headers);

        var req = try http.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .connection = .{ .override = "Upgrade" }, .accept_encoding = .omit },
            .extra_headers = headers[0 .. fixed.len + extra_headers.len],
        });
        defer req.deinit();
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        if (response.head.status != .switching_protocols) {
            log.warn("websocket upgrade refused: http {d}", .{@backingInt(response.head.status)});
            return error.HandshakeFailed;
        }
        try verifyUpgrade(response.head.iterateHeaders(), &key);
        const conn = req.connection.?;
        // The connection now speaks WebSocket; keep it out of the pool.
        req.connection = null;
        conn.closing = true;
        return .{ .io = io, .http = http, .conn = conn };
    }

    /// Makes a task blocked in `receive` return with an error; `deinit` still has to follow.
    pub fn shutdownRead(s: *Socket) void {
        s.conn.stream_reader.stream.shutdown(s.io, .recv) catch {};
    }

    /// Closes the TCP/TLS connection (after a best-effort close frame).
    pub fn deinit(s: *Socket) void {
        if (!s.closed) s.send(.close, &.{ 0x03, 0xe8 }) catch {};
        s.http.connection_pool.release(s.conn, s.io);
    }

    /// Sends one unfragmented, masked frame. Safe to call from several tasks.
    pub fn send(s: *Socket, opcode: Opcode, payload: []const u8) !void {
        try s.write_lock.lock(s.io);
        defer s.write_lock.unlock(s.io);
        var mask: [4]u8 = undefined;
        s.io.random(&mask);
        const w = s.conn.writer();
        var head: [14]u8 = undefined;
        const n = encodeHeader(&head, opcode, payload.len, mask);
        try w.writeAll(head[0..n]);
        var chunk: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < payload.len) {
            const len = @min(chunk.len, payload.len - off);
            for (0..len) |i| chunk[i] = payload[off + i] ^ mask[(off + i) & 3];
            try w.writeAll(chunk[0..len]);
            off += len;
        }
        try s.conn.flush();
    }

    /// Next text or binary message; answers pings, skips pongs. Only one task may receive.
    pub fn receive(s: *Socket, gpa: Allocator) !Message {
        const r = s.conn.reader();
        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(gpa);
        var msg_opcode: ?Opcode = null;
        while (true) {
            const b0 = try r.takeByte();
            const b1 = try r.takeByte();
            const fin = b0 & 0x80 != 0;
            if (b0 & 0x70 != 0) return error.ProtocolError; // no extensions negotiated
            const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0))));
            if (b1 & 0x80 != 0) return error.ProtocolError; // servers never mask
            var len: u64 = b1 & 0x7f;
            if (len == 126) len = try r.takeInt(u16, .big) else if (len == 127) len = try r.takeInt(u64, .big);
            switch (opcode) {
                .ping, .pong, .close => {
                    if (!fin or len > 125) return error.ProtocolError;
                    var buf: [125]u8 = undefined;
                    const body = buf[0..@intCast(len)];
                    try r.readSliceAll(body);
                    switch (opcode) {
                        .ping => try s.send(.pong, body),
                        .close => {
                            s.closed = true;
                            s.send(.close, body[0..@min(body.len, 2)]) catch {};
                            return error.Closed;
                        },
                        else => {},
                    }
                    continue;
                },
                .text, .binary => {
                    if (msg_opcode != null) return error.ProtocolError;
                    msg_opcode = opcode;
                },
                .continuation => if (msg_opcode == null) return error.ProtocolError,
                _ => return error.ProtocolError,
            }
            // Not `msg.items.len + len`: a peer-chosen 64-bit length would overflow it.
            if (len > max_message - msg.items.len) return error.MessageTooLarge;
            const start = msg.items.len;
            try msg.resize(gpa, start + @as(usize, @intCast(len)));
            try r.readSliceAll(msg.items[start..]);
            if (fin) return .{ .opcode = msg_opcode.?, .data = try msg.toOwnedSlice(gpa) };
        }
    }
};

/// Frame header for a masked client frame; returns its length.
pub fn encodeHeader(out: *[14]u8, opcode: Opcode, len: usize, mask: [4]u8) usize {
    out[0] = 0x80 | @as(u8, @backingInt(opcode));
    var n: usize = 2;
    if (len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= 0xffff) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        n = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], len, .big);
        n = 10;
    }
    @memcpy(out[n..][0..4], &mask);
    return n + 4;
}

pub fn acceptKey(key: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// RFC 6455 §4.1 checks: Upgrade, Connection, Sec-WebSocket-Accept; no extensions/protocol.
fn verifyUpgrade(headers: std.http.HeaderIterator, key: []const u8) Error!void {
    var it = headers;
    var upgrade = false;
    var connection = false;
    var accept_ok = false;
    const want = acceptKey(key);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " "), "websocket");
        } else if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
            var tokens = std.mem.splitScalar(u8, h.value, ',');
            while (tokens.next()) |t| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " "), "upgrade")) {
                connection = true;
            };
        } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-accept")) {
            accept_ok = std.mem.eql(u8, std.mem.trim(u8, h.value, " "), &want);
        } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-extensions") or
            std.ascii.eqlIgnoreCase(h.name, "sec-websocket-protocol"))
        {
            return error.HandshakeFailed;
        }
    }
    if (!upgrade or !connection or !accept_ok) return error.HandshakeFailed;
}

const testing = std.testing;

test "accept key (RFC 6455 example)" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "frame header lengths" {
    var h: [14]u8 = undefined;
    const m = [4]u8{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(usize, 6), encodeHeader(&h, .text, 5, m));
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 1, 2, 3, 4 }, h[0..6]);
    try testing.expectEqual(@as(usize, 8), encodeHeader(&h, .binary, 300, m));
    try testing.expectEqualSlices(u8, &.{ 0x82, 0xfe, 0x01, 0x2c }, h[0..4]);
    try testing.expectEqual(@as(usize, 14), encodeHeader(&h, .binary, 70000, m));
    try testing.expectEqual(@as(u8, 0xff), h[1]);
}

/// Test server side: accepts one upgrade, then runs `script` against the raw stream.
pub const TestServer = struct {
    server: std.Io.net.Server,

    pub fn init(io: Io) !TestServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .server = try addr.listen(io, .{}) };
    }

    pub fn port(t: *TestServer) u16 {
        return t.server.socket.address.getPort();
    }

    pub fn deinit(t: *TestServer, io: Io) void {
        t.server.deinit(io);
    }

    /// Accepts and completes the upgrade. Returns the stream; `seen_header` gets the value of
    /// the request header `want_header` if present.
    pub fn accept(t: *TestServer, io: Io, want_header: []const u8, seen_header: []u8) !struct { stream: std.Io.net.Stream, seen_len: usize } {
        const stream = try t.server.accept(io);
        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var key: [24]u8 = undefined;
        var seen_len: usize = 0;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.interface.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key") and value.len == 24) @memcpy(&key, value);
            if (std.ascii.eqlIgnoreCase(name, want_header)) {
                seen_len = @min(value.len, seen_header.len);
                @memcpy(seen_header[0..seen_len], value[0..seen_len]);
            }
        }
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptKey(&key)});
        try w.interface.flush();
        return .{ .stream = stream, .seen_len = seen_len };
    }
};

/// Writes one unmasked server frame.
pub fn testServerFrame(w: *Io.Writer, fin: bool, opcode: Opcode, payload: []const u8) !void {
    try w.writeByte((if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode));
    if (payload.len < 126) {
        try w.writeByte(@intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(payload);
}

/// Reads one masked client frame (test helper); returns opcode and unmasked payload in `buf`.
pub fn testReadClientFrame(r: *Io.Reader, buf: []u8) !struct { opcode: Opcode, data: []u8 } {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    var len: u64 = b1 & 0x7f;
    if (len == 126) len = try r.takeInt(u16, .big) else if (len == 127) len = try r.takeInt(u64, .big);
    var mask: [4]u8 = undefined;
    try r.readSliceAll(&mask);
    const data = buf[0..@intCast(len)];
    try r.readSliceAll(data);
    for (data, 0..) |*c, i| c.* ^= mask[i & 3];
    return .{ .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0)))), .data = data };
}

fn serverScript(t: *TestServer, io: Io, seen: *[64]u8, seen_len: *usize) void {
    const acc = t.accept(io, "X-NRD-AUTH", seen) catch return;
    seen_len.* = acc.seen_len;
    defer acc.stream.close(io);
    var wbuf: [70000 + 16]u8 = undefined;
    var w = acc.stream.writer(io, &wbuf);
    var rbuf: [4096]u8 = undefined;
    var r = acc.stream.reader(io, &rbuf);
    // ping, then a text message in two fragments, then a big binary message.
    testServerFrame(&w.interface, true, .ping, "hi") catch return;
    testServerFrame(&w.interface, false, .text, "hel") catch return;
    testServerFrame(&w.interface, true, .continuation, "lo") catch return;
    const big: [70000]u8 = @splat(7);
    testServerFrame(&w.interface, true, .binary, &big) catch return;
    w.interface.flush() catch return;
    // Expect the pong, then echo the client's next text frame back, then close.
    var buf: [256]u8 = undefined;
    const pong = testReadClientFrame(&r.interface, &buf) catch return;
    if (pong.opcode != .pong or !std.mem.eql(u8, pong.data, "hi")) return;
    const f = testReadClientFrame(&r.interface, &buf) catch return;
    testServerFrame(&w.interface, true, .text, f.data) catch return;
    testServerFrame(&w.interface, true, .close, &.{ 0x03, 0xe8 }) catch return;
    w.interface.flush() catch return;
    _ = testReadClientFrame(&r.interface, &buf) catch return;
}

test "client against a local server" {
    const io = testing.io;
    var t: TestServer = try .init(io);
    defer t.deinit(io);
    var seen: [64]u8 = undefined;
    var seen_len: usize = 0;
    var task = try io.concurrent(serverScript, .{ &t, io, &seen, &seen_len });
    defer task.cancel(io);

    var http: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/socket.io/?transport=websocket&EIO=4", .{t.port()});
    var s = try Socket.connect(io, &http, url, &.{.{ .name = "X-NRD-AUTH", .value = "room-token" }});
    defer s.deinit();

    const m1 = try s.receive(testing.allocator);
    defer testing.allocator.free(m1.data);
    try testing.expectEqual(Opcode.text, m1.opcode);
    try testing.expectEqualStrings("hello", m1.data);
    const m2 = try s.receive(testing.allocator);
    defer testing.allocator.free(m2.data);
    try testing.expectEqual(Opcode.binary, m2.opcode);
    try testing.expectEqual(@as(usize, 70000), m2.data.len);
    try s.send(.text, "40");
    const m3 = try s.receive(testing.allocator);
    defer testing.allocator.free(m3.data);
    try testing.expectEqualStrings("40", m3.data);
    try testing.expectError(error.Closed, s.receive(testing.allocator));
    try testing.expectEqualStrings("room-token", seen[0..seen_len]);
}

fn hugeContinuationScript(t: *TestServer, io: Io) void {
    var seen: [1]u8 = undefined;
    const acc = t.accept(io, "-", &seen) catch return;
    defer acc.stream.close(io);
    var wbuf: [64]u8 = undefined;
    var w = acc.stream.writer(io, &wbuf);
    testServerFrame(&w.interface, false, .text, "a") catch return;
    // A continuation frame announcing 2^64 - 1 bytes.
    w.interface.writeAll(&.{ 0x80, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }) catch return;
    w.interface.flush() catch return;
    var rbuf: [256]u8 = undefined;
    var r = acc.stream.reader(io, &rbuf);
    _ = r.interface.discardRemaining() catch {};
}

test "an oversized frame length is rejected, not added up" {
    const io = testing.io;
    var t: TestServer = try .init(io);
    defer t.deinit(io);
    var task = try io.concurrent(hugeContinuationScript, .{ &t, io });
    defer task.cancel(io);

    var http: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/", .{t.port()});
    var s = try Socket.connect(io, &http, url, &.{});
    defer s.deinit();
    try testing.expectError(error.MessageTooLarge, s.receive(testing.allocator));
}
