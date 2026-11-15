// SPDX-License-Identifier: GPL-3.0-or-later
//! In-process end-to-end test of `portmap` (spec §10): a fake REST API, a fake Socket.IO signaling
//! server and a fake host built on libdatachannel, forwarding to a local TCP echo server. Exercises
//! room join, control request, offer/answer/candidates, echo, SYN/SYN-ACK, DATA both ways and CLOSE.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const testing = std.testing;
const rtc = @import("rtc.zig");
const ws = @import("ws.zig");
const wire = @import("wire.zig");
const api = @import("api.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const portmap = @import("tools/portmap.zig");
const terminal = @import("tools/terminal.zig");
const files = @import("tools/files.zig");

const host_client_id = "host-1";

// --- Fake REST API -----------------------------------------------------------------------------

fn apiServer(server: *net.Server, io: Io, ws_port: u16) Io.Cancelable!void {
    while (true) {
        const conn = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        defer conn.close(io);
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var content_length: usize = 0;
        var join = false;
        var first = true;
        while (true) {
            const line = std.mem.trimEnd(u8, r.interface.takeDelimiterInclusive('\n') catch break, "\r\n");
            if (line.len == 0) break;
            if (first) join = std.mem.indexOf(u8, line, "/api/v1/room/join/by_device/host-dev") != null;
            first = false;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length"))
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch 0;
        }
        r.interface.discardAll(content_length) catch continue;
        var body_buf: [512]u8 = undefined;
        const body = if (join)
            std.fmt.bufPrint(&body_buf, "{{\"code\":0,\"msg\":\"\",\"data\":{{\"token\":\"room-token\",\"report_token\":\"x\",\"report_url\":\"x\",\"signaling_list\":[\"ws://127.0.0.1:{d}\"]}}}}", .{ws_port}) catch unreachable
        else
            "{\"code\":404,\"msg\":\"unknown\"}";
        var wbuf: [1024]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch continue;
        w.interface.flush() catch {};
    }
}

// --- Fake host -------------------------------------------------------------------------------

const HostEvent = union(enum) {
    rtc: rtc.Event,
    ws: struct { opcode: ws.Opcode, data: []u8 },
    ws_end,
};

const Host = struct {
    io: Io,
    gpa: Allocator,
    queue_buf: [256]HostEvent = undefined,
    queue: Io.Queue(HostEvent) = undefined,
    pc: std.atomic.Value(c_int) = .init(-1),
    /// Written and read on the bus pump task only.
    dcs: [8]c_int = @splat(-1),
    ndcs: usize = 0,
    peer: ?rtc.Peer = null,
    streams: std.AutoHashMapUnmanaged([2]u64, *HostStream) = .empty,
    mutex: Io.Mutex = .init,
    syns: std.atomic.Value(u32) = .init(0),
    /// Files: what was uploaded, and the file served for download.
    uploaded: std.ArrayList(u8) = .empty,
    serve: []const u8 = "",
    dl_task: u64 = 0,
    dl_acks: usize = 0,
    dl_req: u64 = 5000,

    fn hasDc(h: *const Host, dc: c_int) bool {
        return std.mem.indexOfScalar(c_int, h.dcs[0..h.ndcs], dc) != null;
    }

    fn take(ptr: *anyopaque, e: rtc.Event) bool {
        const h: *Host = @ptrCast(@alignCast(ptr));
        const pc = h.pc.load(.acquire);
        if (pc < 0) return false;
        const mine = switch (e) {
            .local_description => |d| d.pc == pc,
            .local_candidate => |d| d.pc == pc,
            .state => |s| s.pc == pc,
            .data_channel => |d| blk: {
                if (d.pc != pc) break :blk false;
                if (h.ndcs < h.dcs.len) {
                    h.dcs[h.ndcs] = d.dc;
                    h.ndcs += 1;
                }
                break :blk true;
            },
            .open, .closed => |dc| h.hasDc(dc),
            .message => |m| h.hasDc(m.dc),
            .@"error" => |x| h.hasDc(x.id) or x.id == pc,
        };
        if (!mine) return false;
        h.queue.putOneUncancelable(h.io, .{ .rtc = e }) catch e.deinit();
        return true;
    }

    fn wsReader(h: *Host, r: *Io.Reader) void {
        const buf = h.gpa.alloc(u8, 1 << 20) catch return;
        defer h.gpa.free(buf);
        while (true) {
            const f = ws.testReadClientFrame(r, buf) catch break;
            const data = h.gpa.dupe(u8, f.data) catch break;
            h.queue.putOneUncancelable(h.io, .{ .ws = .{ .opcode = f.opcode, .data = data } }) catch {
                h.gpa.free(data);
                break;
            };
        }
        h.queue.putOneUncancelable(h.io, .ws_end) catch {};
    }

    fn sendWs(w: *Io.Writer, text: []const u8) !void {
        try ws.testServerFrame(w, true, .text, text);
        try w.flush();
    }

    fn soac(h: *Host, w: *Io.Writer, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(h.gpa, .{ "soac", .{ .client_id = host_client_id, .data = data } }, .{});
        defer h.gpa.free(json);
        const text = try std.mem.concat(h.gpa, u8, &.{ "42", json });
        defer h.gpa.free(text);
        try sendWs(w, text);
    }

    /// Signaling server and host peer for one session.
    fn run(h: *Host, t: *ws.TestServer) !void {
        const io = h.io;
        var seen: [64]u8 = undefined;
        const acc = try t.accept(io, "X-NRD-AUTH", &seen);
        defer acc.stream.close(io);
        try testing.expectEqualStrings("room-token", seen[0..acc.seen_len]);
        var wbuf: [1 << 16]u8 = undefined;
        var w = acc.stream.writer(io, &wbuf);
        var rbuf: [1 << 16]u8 = undefined;
        var r = acc.stream.reader(io, &rbuf);
        try sendWs(&w.interface, "0{\"sid\":\"s1\",\"pingInterval\":25000,\"pingTimeout\":20000}");
        var hs_buf: [256]u8 = undefined;
        const hs = try ws.testReadClientFrame(&r.interface, &hs_buf);
        try testing.expectEqualStrings("40", hs.data);
        try sendWs(&w.interface, "40{\"sid\":\"c1\"}");

        var reader = try io.concurrent(wsReader, .{ h, &r.interface });
        defer reader.cancel(io);
        defer if (h.peer) |p| p.close();
        var group: Io.Group = .init;
        defer group.cancel(io);

        while (true) {
            const e = try h.queue.getOne(io);
            switch (e) {
                .ws_end => return,
                .ws => |m| {
                    defer h.gpa.free(m.data);
                    if (m.opcode != .text) continue;
                    try h.handleSignal(&w.interface, m.data);
                },
                .rtc => |ev| {
                    defer ev.deinit();
                    try h.handleRtc(&w.interface, ev, &group);
                },
            }
        }
    }

    fn handleSignal(h: *Host, w: *Io.Writer, text: []const u8) !void {
        if (std.mem.startsWith(u8, text, "451-")) {
            // Control request: ack with a peer route and no ICE servers (host candidates only).
            const open = std.mem.indexOfScalar(u8, text, '[') orelse return error.BadControl;
            const id = text[4..open];
            try testing.expect(std.mem.indexOf(u8, text[open..], "\"control\"") != null);
            var buf: [128]u8 = undefined;
            try sendWs(w, try std.fmt.bufPrint(&buf, "43{s}[\"success\",{{\"client_id\":\"{s}\",\"iceServers\":[]}}]", .{ id, host_client_id }));
            return;
        }
        if (!std.mem.startsWith(u8, text, "42")) return;
        var parsed = try std.json.parseFromSlice(std.json.Value, h.gpa, text[2..], .{});
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .array or v.array.items.len != 2 or !std.mem.eql(u8, v.array.items[0].string, "soac")) return;
        const ev = v.array.items[1];
        try testing.expectEqualStrings(host_client_id, api.str(ev, "client_id").?);
        const data = ev.object.get("data").?;
        const kind = api.str(data, "type").?;
        const hub = rtc.globalHub(h.io);
        if (std.mem.eql(u8, kind, "offer")) {
            const sdp = api.str(data, "sdp").?;
            try testing.expect(std.mem.indexOf(u8, sdp, "a=x-uuremote-quic") != null);
            const p = try rtc.Peer.create(hub, .{});
            h.peer = p;
            h.pc.store(p.id, .release);
            const z = try h.gpa.dupeSentinel(u8, sdp, 0);
            defer h.gpa.free(z);
            try p.setRemoteDescription(z, "offer");
            try p.setLocalDescription("answer");
        } else if (std.mem.eql(u8, kind, "candidate")) {
            const c = data.object.get("candidate").?;
            const cand = try h.gpa.dupeSentinel(u8, api.str(c, "candidate").?, 0);
            defer h.gpa.free(cand);
            const mid = try h.gpa.dupeSentinel(u8, api.str(c, "sdpMid").?, 0);
            defer h.gpa.free(mid);
            (h.peer orelse return error.CandidateBeforeOffer).addRemoteCandidate(cand, mid) catch {};
        }
    }

    fn handleRtc(h: *Host, w: *Io.Writer, e: rtc.Event, group: *Io.Group) !void {
        switch (e) {
            .local_description => |d| try h.soac(w, .{ .type = "answer", .sdp = d.sdp }),
            .local_candidate => |d| {
                const c = if (std.mem.startsWith(u8, d.candidate, "a=")) d.candidate[2..] else d.candidate;
                try h.soac(w, .{ .type = "candidate", .candidate = c, .sdp_mid = d.mid });
            },
            .message => |m| {
                if (std.mem.startsWith(u8, m.data, "TERM")) return h.handleTerm(m.dc, m.data);
                if (wire.blob(m.data, wire.kind.rpc_request)) |r| if (wire.blob(r, 8)) |ftp| return h.handleFtp(m.dc, wire.uint(wire.blob(r, 1).?, 1), ftp);
                if (wire.blob(m.data, wire.kind.rpc_response)) |r| if (wire.blob(r, 4)) |cases| return h.handleFtpResponse(m.dc, cases);
                if (wire.blob(m.data, wire.kind.rpc_request)) |r| if (wire.blob(r, 28) != null) {
                    // check_env: answer "available".
                    const id = wire.uint(wire.blob(r, 1).?, 1);
                    var head: wire.Builder = .init(h.gpa);
                    defer head.deinit();
                    try head.int(1, id);
                    var body: wire.Builder = .init(h.gpa);
                    defer body.deinit();
                    try body.int(1, 0);
                    var b: wire.Builder = .init(h.gpa);
                    defer b.deinit();
                    try b.bytes(1, head.buf.items);
                    try b.bytes(24, body.buf.items);
                    const env = try wire.envelope(h.gpa, id, wire.kind.rpc_response, b.buf.items);
                    defer h.gpa.free(env);
                    try rtc.send(m.dc, env);
                    return;
                };
                if (wire.echoRequestSeq(m.data)) |seq| {
                    const echo = try wire.echoResponse(h.gpa, 100, seq);
                    defer h.gpa.free(echo);
                    try rtc.send(m.dc, echo);
                    return;
                }
                const f = wire.blob(m.data, wire.kind.port_forward) orelse return;
                try h.handlePort(m.dc, f, group);
            },
            else => {},
        }
    }

    fn idOf(gpa: Allocator, task: u64, index: u64) !wire.Builder {
        var inner: wire.Builder = .init(gpa);
        defer inner.deinit();
        try inner.int(1, task);
        try inner.int(2, index);
        var b: wire.Builder = .init(gpa);
        try b.bytes(1, inner.buf.items);
        return b;
    }

    fn rpcSend(h: *Host, dc: c_int, id: u64, response: bool, case: u32, body: []const u8) !void {
        const m = try wire.rpc(h.gpa, id, response, case, body);
        defer h.gpa.free(m);
        try rtc.send(dc, m);
    }

    /// Host side of the FTP RPCs used by uucli.
    fn handleFtp(h: *Host, dc: c_int, rid: u64, ftp: []const u8) !void {
        var it: wire.Iterator = .init(ftp);
        const f = (try it.next()).?;
        const body = f.value.bytes;
        const tid = wire.blob(body, 1).?;
        const task = wire.uint(tid, 1);
        switch (f.number) {
            10 => { // list → 7 {4: code, 3: rows}
                var b = try idOf(h.gpa, task, 0);
                defer b.deinit();
                try b.int(4, 1);
                const rows = [_]struct { u64, []const u8, u64 }{ .{ 4, "a.bin", 5 }, .{ 0, "sub", 0 } };
                for (rows) |r| {
                    var row: wire.Builder = .init(h.gpa);
                    defer row.deinit();
                    try row.int(1, r[0]);
                    try row.bytes(2, r[1]);
                    try row.int(3, r[2]);
                    try row.int(4, 0);
                    const full = try std.fmt.allocPrint(h.gpa, "/dir/{s}", .{r[1]});
                    defer h.gpa.free(full);
                    try row.bytes(5, full);
                    try b.bytes(3, row.buf.items);
                }
                try h.rpcSend(dc, rid, true, 7, b.buf.items);
            },
            1 => { // upload request → 1 {3: code}; the file list must be in list_data (6)
                const z = wire.blob(body, 6).?;
                const list = try files.inflate(h.gpa, z);
                defer h.gpa.free(list);
                try testing.expectEqualStrings("up.bin", wire.blob(wire.blob(list, 1).?, 1).?);
                try testing.expect(wire.blob(body, 7).?.len == 36);
                var b = try idOf(h.gpa, task, 0);
                defer b.deinit();
                try b.int(3, 1);
                try h.rpcSend(dc, rid, true, 1, b.buf.items);
            },
            3 => { // upload open → 3 {3: code}
                var b = try idOf(h.gpa, task, 1);
                defer b.deinit();
                try b.int(3, 1);
                try h.rpcSend(dc, rid, true, 3, b.buf.items);
            },
            4 => { // upload block → 4 {2: block, 3: code, 4: len}
                const chunk = wire.blob(body, 3).?;
                try h.uploaded.appendSlice(h.gpa, chunk);
                var b = try idOf(h.gpa, task, 1);
                defer b.deinit();
                try b.int(2, wire.uint(body, 2));
                try b.int(3, 1);
                try b.int(4, chunk.len);
                try h.rpcSend(dc, rid, true, 4, b.buf.items);
            },
            9 => { // upload finish → 6 {2: code}
                var b = try idOf(h.gpa, task, 1);
                defer b.deinit();
                try b.int(2, 1);
                try h.rpcSend(dc, rid, true, 6, b.buf.items);
            },
            2 => { // download request → 2 {2: code, 3: {1: name, 2: size}}, then open the file
                h.dl_task = task;
                h.dl_acks = 0;
                var row: wire.Builder = .init(h.gpa);
                defer row.deinit();
                try row.bytes(1, "big.bin");
                try row.int(2, h.serve.len);
                var b = try idOf(h.gpa, task, 0);
                defer b.deinit();
                try b.int(2, 1);
                try b.bytes(3, row.buf.items);
                try h.rpcSend(dc, rid, true, 2, b.buf.items);
                var open = try idOf(h.gpa, task, 1);
                defer open.deinit();
                try open.int(3, h.serve.len);
                h.dl_req += 1;
                try h.rpcSend(dc, h.dl_req, false, 3, open.buf.items);
            },
            else => return error.UnexpectedFtpCase,
        }
    }

    const dl_block = 32 * 1024;

    fn dlBlocks(h: *Host) usize {
        return (h.serve.len + dl_block - 1) / dl_block;
    }

    /// The client's answers to host-initiated download requests.
    fn handleFtpResponse(h: *Host, dc: c_int, cases: []const u8) !void {
        if (wire.blob(cases, 3)) |r| {
            try testing.expectEqual(@as(u64, 1), wire.uint(r, 3));
            // Blocks 0.. sent in reverse order (our host may reorder within its window).
            var i = h.dlBlocks();
            while (i > 0) {
                i -= 1;
                const chunk = h.serve[i * dl_block .. @min(h.serve.len, (i + 1) * dl_block)];
                var b = try idOf(h.gpa, h.dl_task, 1);
                defer b.deinit();
                try b.int(2, i);
                try b.bytes(3, chunk);
                h.dl_req += 1;
                try h.rpcSend(dc, h.dl_req, false, 4, b.buf.items);
            }
        } else if (wire.blob(cases, 4)) |r| {
            try testing.expectEqual(@as(u64, 1), wire.uint(r, 3));
            h.dl_acks += 1;
            if (h.dl_acks == h.dlBlocks()) {
                var b = try idOf(h.gpa, h.dl_task, 1);
                defer b.deinit();
                try b.int(2, 1);
                h.dl_req += 1;
                try h.rpcSend(dc, h.dl_req, false, 9, b.buf.items);
            }
        } else if (wire.blob(cases, 6)) |r| {
            try testing.expectEqual(@as(u64, 1), wire.uint(r, 2));
            var b = try idOf(h.gpa, h.dl_task, std.math.maxInt(u64));
            defer b.deinit();
            try b.int(2, 1);
            h.dl_req += 1;
            try h.rpcSend(dc, h.dl_req, false, 9, b.buf.items);
        }
    }

    /// A host terminal: session 5 echoes input; "exit" ends it with code 3.
    fn handleTerm(h: *Host, dc: c_int, data: []const u8) !void {
        var d: terminal.Decoder = .{};
        defer d.deinit(h.gpa);
        try d.push(h.gpa, data);
        const K = terminal.Kind;
        while (try d.next()) |f| {
            const out: ?struct { u8, u32, []const u8 } = switch (f.kind) {
                K.open => .{ K.open_resp, 5, "{\"code\":0}" },
                K.list_req => .{ K.list_resp, f.session, "[{\"session_id\":5,\"shell\":\"sh\",\"state\":\"running\"}]" },
                K.kill_req => .{ K.kill_resp, f.session, if (f.session == 5) "{\"code\":0}" else "{\"code\":1}" },
                K.stdin => if (std.mem.indexOf(u8, f.payload, "exit") != null)
                    .{ K.exit, f.session, "{\"exit_code\":3}" }
                else
                    .{ K.stdout, f.session, f.payload },
                else => null,
            };
            const o = out orelse continue;
            const frame = try terminal.encode(h.gpa, o[0], o[1], o[2]);
            defer h.gpa.free(frame);
            try rtc.send(dc, frame);
        }
    }

    fn reply(dc: c_int, gpa: Allocator, key: [2]u64, kind: u64, payload: []const u8) !void {
        const f = try wire.portFrame(gpa, 1, key[0], key[1], kind, payload);
        defer gpa.free(f);
        try rtc.send(dc, f);
    }

    fn handlePort(h: *Host, dc: c_int, f: []const u8, group: *Io.Group) !void {
        const key: [2]u64 = .{ wire.uint(f, 2), wire.uint(f, 3) };
        try testing.expectEqual(@as(u64, 1), wire.uint(f, 1));
        const payload = wire.blob(f, 5).?;
        switch (wire.uint(f, 4)) {
            wire.PortFrame.syn => {
                _ = h.syns.fetchAdd(1, .monotonic);
                var parsed = try std.json.parseFromSlice(struct { version: u32, target_host: []const u8, target_port: u16 }, h.gpa, payload, .{});
                defer parsed.deinit();
                try testing.expectEqual(@as(u32, 1), parsed.value.version);
                if (std.mem.eql(u8, parsed.value.target_host, "reject.invalid"))
                    return reply(dc, h.gpa, key, wire.PortFrame.syn_ack, "{\"ok\":false,\"error\":\"denied\"}");
                const addr = try net.IpAddress.parse(parsed.value.target_host, parsed.value.target_port);
                const conn = try addr.connect(h.io, .{ .mode = .stream });
                const st = try h.gpa.create(HostStream);
                st.* = .{ .host = h, .dc = dc, .key = key, .conn = conn };
                h.mutex.lockUncancelable(h.io);
                try h.streams.put(h.gpa, key, st);
                h.mutex.unlock(h.io);
                try reply(dc, h.gpa, key, wire.PortFrame.syn_ack, "{\"ok\":true}");
                try group.concurrent(h.io, HostStream.upstream, .{st});
            },
            wire.PortFrame.data => {
                h.mutex.lockUncancelable(h.io);
                const st = h.streams.get(key);
                h.mutex.unlock(h.io);
                const s = st orelse return;
                var wb: [1]u8 = undefined;
                var cw = s.conn.writer(h.io, &wb);
                cw.interface.writeAll(payload) catch {};
                cw.interface.flush() catch {};
            },
            wire.PortFrame.close => {
                h.mutex.lockUncancelable(h.io);
                const kv = h.streams.fetchRemove(key);
                h.mutex.unlock(h.io);
                // The upstream task owns the connection; shutting it down ends that task.
                if (kv) |x| x.value.conn.shutdown(h.io, .both) catch {};
            },
            else => return error.UnexpectedPortFrame,
        }
    }
};

const HostStream = struct {
    host: *Host,
    dc: c_int,
    key: [2]u64,
    conn: net.Stream,

    /// Target → client.
    fn upstream(st: *HostStream) Io.Cancelable!void {
        const h = st.host;
        defer {
            h.mutex.lockUncancelable(h.io);
            _ = h.streams.remove(st.key);
            h.mutex.unlock(h.io);
            st.conn.close(h.io);
            h.gpa.destroy(st);
        }
        var buf: [8192]u8 = undefined;
        var r = st.conn.reader(h.io, &buf);
        while (true) {
            const data = r.interface.peekGreedy(1) catch break;
            Host.reply(st.dc, h.gpa, st.key, wire.PortFrame.data, data) catch break;
            r.interface.toss(data.len);
        }
        Host.reply(st.dc, h.gpa, st.key, wire.PortFrame.close, "") catch {};
    }
};

// --- Target: TCP echo server -------------------------------------------------------------------

fn echoServer(server: *net.Server, io: Io) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const conn = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        group.concurrent(io, echoConn, .{ conn, io }) catch conn.close(io);
    }
}

fn echoConn(conn: net.Stream, io: Io) Io.Cancelable!void {
    defer conn.close(io);
    var rb: [4096]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var r = conn.reader(io, &rb);
    var w = conn.writer(io, &wb);
    while (true) {
        const data = r.interface.peekGreedy(1) catch return;
        w.interface.writeAll(data) catch return;
        w.interface.flush() catch return;
        r.interface.toss(data.len);
    }
}

// --- The test ----------------------------------------------------------------------------------

fn roundTrip(io: Io, port: u16, payload: []const u8, got: []u8) !void {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const conn = try addr.connect(io, .{ .mode = .stream });
    defer conn.close(io);
    var wb: [4096]u8 = undefined;
    var w = conn.writer(io, &wb);
    var rb: [4096]u8 = undefined;
    var r = conn.reader(io, &rb);
    try w.interface.writeAll(payload);
    try w.interface.flush();
    try r.interface.readSliceAll(got[0..payload.len]);
    try testing.expectEqualSlices(u8, payload, got[0..payload.len]);
}

fn closedByPeer(io: Io, port: u16) !void {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const conn = try addr.connect(io, .{ .mode = .stream });
    defer conn.close(io);
    var rb: [64]u8 = undefined;
    var r = conn.reader(io, &rb);
    try testing.expectError(error.EndOfStream, r.interface.takeByte());
}

fn runHost(h: *Host, t: *ws.TestServer) Io.Cancelable!void {
    h.run(t) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => std.debug.print("fake host failed: {t}\n", .{err}),
    };
}

test "portmap end to end through a fake host" {
    const io = testing.io;
    const gpa = testing.allocator;
    testing.log_level = .debug;

    var echo = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
    defer echo.deinit(io);
    var echo_task = try io.concurrent(echoServer, .{ &echo, io });
    defer echo_task.cancel(io) catch {};

    var sig: ws.TestServer = try .init(io);
    defer sig.deinit(io);
    var api_server = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
    defer api_server.deinit(io);
    var api_task = try io.concurrent(apiServer, .{ &api_server, io, sig.port() });
    defer api_task.cancel(io) catch {};

    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(io, &bus_buf);
    defer bus.deinit();

    var host: Host = .{ .io = io, .gpa = gpa };
    host.queue = .init(&host.queue_buf);
    defer host.streams.deinit(gpa);
    bus.divert = .{ .ptr = &host, .take = Host.take };
    var host_task = try io.concurrent(runHost, .{ &host, &sig });
    defer host_task.cancel(io) catch {};

    const cfg: config.Config = .{ .device_id = "own-dev", .user_id = "u", .token = "t", .csrf = "c" };
    var client: api.Client = undefined;
    try client.init(io, gpa, &cfg, null);
    defer client.deinit();
    var base_buf: [64]u8 = undefined;
    client.base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{api_server.socket.address.getPort()});

    var pm = try portmap.PortMap.init(io, gpa, &.{
        .{ .lport = 0, .host = "127.0.0.1", .port = echo.socket.address.getPort() },
        .{ .lport = 0, .host = "reject.invalid", .port = 1 },
    });
    defer pm.deinit();
    try pm.listen();
    try testing.expectEqual(@as(u64, 1), pm.rules[0].id);
    try testing.expectEqual(@as(u64, 2), pm.rules[1].id);
    try pm.startAccepting();

    // No session yet: accepted connections are closed at once.
    try closedByPeer(io, pm.rules[0].bound_port);

    const s = try session.Session.open(.{
        .io = io,
        .gpa = gpa,
        .bus = &bus,
        .client = &client,
        .http = &client.http,
        .own_device_id = cfg.device_id,
        .target = "host-dev",
        .capture_type = 9,
    });
    pm.attach(s);
    var run_task = try io.concurrent(session.Session.run, .{ s, pm.tool() });

    const got = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(got);
    try roundTrip(io, pm.rules[0].bound_port, "hello uucli", got);
    // Larger than one DATA frame (16 KiB) and than the SCTP message limit.
    const big = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try roundTrip(io, pm.rules[0].bound_port, big, got);
    // Two streams at once.
    {
        var g: Io.Group = .init;
        defer g.cancel(io);
        const got2 = try gpa.alloc(u8, 64);
        defer gpa.free(got2);
        try g.concurrent(io, roundTripTask, .{ io, pm.rules[0].bound_port, "second stream", got2 });
        try roundTrip(io, pm.rules[0].bound_port, "first stream", got);
        try g.await(io);
    }
    // The host refuses the target: the local connection is closed.
    try closedByPeer(io, pm.rules[1].bound_port);
    try testing.expect(host.syns.load(.monotonic) >= 5);

    bus.put(.interrupt);
    try testing.expectEqual(session.End.interrupted, try run_task.await(io));
    pm.detach();
    s.close();
    // Detached again: connections are closed at once.
    try closedByPeer(io, pm.rules[0].bound_port);
}

fn roundTripTask(io: Io, port: u16, payload: []const u8, got: []u8) Io.Cancelable!void {
    roundTrip(io, port, payload, got) catch |err| std.debug.print("second stream failed: {t}\n", .{err});
}

/// Fake API, signaling and host, plus a bus and API client pointed at them.
const Env = struct {
    io: Io,
    gpa: Allocator,
    sig: ws.TestServer = undefined,
    api_server: net.Server = undefined,
    api_task: Io.Future(Io.Cancelable!void) = undefined,
    bus_buf: [256]session.Event = undefined,
    bus: session.Bus = undefined,
    host: Host = undefined,
    host_task: Io.Future(Io.Cancelable!void) = undefined,
    cfg: config.Config = .{ .device_id = "own-dev", .user_id = "u", .token = "t", .csrf = "c" },
    client: api.Client = undefined,
    base_buf: [64]u8 = undefined,

    fn init(e: *Env, io: Io, gpa: Allocator) !void {
        e.* = .{ .io = io, .gpa = gpa };
        e.sig = try .init(io);
        e.api_server = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
        e.api_task = try io.concurrent(apiServer, .{ &e.api_server, io, e.sig.port() });
        try e.bus.init(io, &e.bus_buf);
        e.host = .{ .io = io, .gpa = gpa };
        e.host.queue = .init(&e.host.queue_buf);
        e.bus.divert = .{ .ptr = &e.host, .take = Host.take };
        e.host_task = try io.concurrent(runHost, .{ &e.host, &e.sig });
        try e.client.init(io, gpa, &e.cfg, null);
        e.client.base = try std.fmt.bufPrint(&e.base_buf, "http://127.0.0.1:{d}", .{e.api_server.socket.address.getPort()});
    }

    fn open(e: *Env, capture: u32) !*session.Session {
        return session.Session.open(.{
            .io = e.io,
            .gpa = e.gpa,
            .bus = &e.bus,
            .client = &e.client,
            .http = &e.client.http,
            .own_device_id = e.cfg.device_id,
            .target = "host-dev",
            .capture_type = capture,
        });
    }

    fn deinit(e: *Env) void {
        e.client.deinit();
        e.host_task.cancel(e.io) catch {};
        e.host.streams.deinit(e.gpa);
        e.host.uploaded.deinit(e.gpa);
        e.bus.deinit();
        e.api_task.cancel(e.io) catch {};
        e.api_server.deinit(e.io);
        e.sig.deinit(e.io);
    }
};

fn smallSize() [2]u16 {
    return .{ 100, 30 };
}

test "terminal end to end through a fake host" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env: Env = undefined;
    try env.init(io, gpa);
    defer env.deinit();
    const s = try env.open(8);
    defer s.close();
    var t: terminal.Terminal = undefined;
    t.init(io, gpa, s);
    defer t.deinit();
    var run_task = try io.concurrent(session.Session.run, .{ s, t.tool() });
    var ticker = try io.concurrent(terminal.Terminal.ticker, .{&t});
    defer ticker.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try t.checkEnv();
    const l = try t.list(arena.allocator());
    try testing.expectEqual(@as(usize, 1), l.len);
    try testing.expectEqual(@as(u32, 5), l[0].id);
    try t.kill(5);
    try testing.expectError(error.Rejected, t.kill(6));
    try testing.expectError(error.NoSuchSession, t.open(arena.allocator(), 9, 80, 24));
    const id = try t.open(arena.allocator(), 0, 80, 24);
    try testing.expectEqual(@as(u32, 5), id);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const opts: terminal.Terminal.Attach = .{ .id = id, .out = &out.writer, .err = &err.writer, .escape = '~', .tty = true, .size = smallSize };

    // `~~` sends one `~`; `~.` in the middle of a line is plain input. The host echoes the line, then
    // "exit" ends the shell with code 3 (frames arrive in order on BINARY).
    t.post(.resize);
    t.post(.{ .input = try gpa.dupe(u8, "~~a~.b\r") });
    t.post(.{ .input = try gpa.dupe(u8, "exit\r") });
    try testing.expectEqual(terminal.Outcome{ .exited = 3 }, try t.attach(opts));
    try testing.expectEqualStrings("~a~.b\r", out.written());
    // `~?` prints help; `~.` at a line start detaches.
    t.post(.{ .input = try gpa.dupe(u8, "~?~.") });
    try testing.expectEqual(terminal.Outcome{ .detached = 5 }, try t.attach(opts));
    try testing.expect(std.mem.indexOf(u8, err.written(), "detach") != null);
    // Without a tty there are no escapes; end of input detaches.
    t.post(.input_end);
    try testing.expectEqual(terminal.Outcome{ .detached = 5 }, try t.attach(.{ .id = id, .out = &out.writer, .err = &err.writer, .escape = '~', .tty = false, .size = smallSize }));

    env.bus.put(.interrupt);
    try testing.expectEqual(session.End.interrupted, try run_task.await(io));
}

test "files end to end through a fake host" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env: Env = undefined;
    try env.init(io, gpa);
    defer env.deinit();
    const content = try gpa.alloc(u8, 100_000);
    defer gpa.free(content);
    for (content, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    env.host.serve = content;

    const s = try env.open(5);
    defer s.close();
    var f: files.Files = undefined;
    f.init(io, gpa, s);
    defer f.deinit();
    var run_task = try io.concurrent(session.Session.run, .{ s, f.tool() });
    var ticker = try io.concurrent(files.Files.ticker, .{&f});
    defer ticker.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const entries = try f.list(arena.allocator(), "/dir");
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("a.bin", entries[0].name);
    try testing.expectEqual(@as(u64, files.kind_file), entries[0].kind);
    try testing.expectEqualStrings("/dir/sub", entries[1].path);
    try testing.expect(try f.remoteExists(arena.allocator(), "/dir/a.bin"));
    try testing.expect(!try f.remoteExists(arena.allocator(), "/dir/b.bin"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const up = try tmp.dir.createFile(io, "up.bin", .{ .read = true });
        defer up.close(io);
        var wb: [4096]u8 = undefined;
        var w = up.writer(io, &wb);
        try w.interface.writeAll(content[0..70_000]);
        try w.interface.flush();
    }
    {
        const up = try tmp.dir.openFile(io, "up.bin", .{});
        defer up.close(io);
        try f.upload(up, "C:\\Users\\me\\up.bin");
    }
    try testing.expectEqualSlices(u8, content[0..70_000], env.host.uploaded.items);

    {
        const out = try tmp.dir.createFile(io, "big.bin", .{ .read = true });
        defer out.close(io);
        try f.download("/dir/big.bin", out);
    }
    const got = try tmp.dir.readFileAlloc(io, "big.bin", gpa, .limited(1 << 20));
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, content, got);

    env.bus.put(.interrupt);
    try testing.expectEqual(session.End.interrupted, try run_task.await(io));
}
