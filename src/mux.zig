// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared connections (spec §7.2–§7.4): socket paths, management requests and idle expiry.
//! The serving side is `PortMap.startMuxAccepting`; startup and serving live in mux_client/server.zig.
const std = @import("std");
const Io = std.Io;
const portmap = @import("tools/portmap.zig");
const lease = @import("lease.zig");
const session = @import("session.zig");

/// Leaves room for the NUL of `sockaddr_un.sun_path` (104 bytes on macOS, 108 on Linux).
pub const max_socket_path = 103;

pub const Kind = enum { sock, lock, log };

/// `CONFIG_DIR/mux/HASH.KIND`. Callers supply a resolved device / share ID and connection mode.
/// Different config paths and modes have separate shared connections.
pub fn path(buf: []u8, config_path: []const u8, assist: bool, device: []const u8, kind: Kind) ![]const u8 {
    var h = std.hash.Wyhash.init(0x7575636c69);
    h.update(config_path);
    h.update(if (assist) "\x00assist\x00" else "\x00device\x00");
    h.update(device);
    const base = std.fs.path.dirname(config_path) orelse ".";
    const p = try std.fmt.bufPrint(buf, "{s}/mux/{x:0>16}.{t}", .{ base, h.final(), kind });
    if (kind == .sock and p.len > max_socket_path) return error.NameTooLong;
    return p;
}

pub fn dir(buf: []u8, config_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/mux", .{std.fs.path.dirname(config_path) orelse "."});
}

pub const Reply = enum { ok, rejected, timeout, failed };

/// The server's answer line (without newline) to `HOST PORT`.
pub fn parseReply(line: []const u8) Reply {
    if (std.mem.eql(u8, line, "OK")) return .ok;
    if (std.mem.eql(u8, line, "ERR rejected")) return .rejected;
    if (std.mem.eql(u8, line, "ERR timeout")) return .timeout;
    return .failed;
}

const testing = std.testing;

test "mux file names depend on config, assist and device" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const p1 = try path(&a, "/home/me/.config/uucli/config.json", false, "gqg", .sock);
    try testing.expect(std.mem.startsWith(u8, p1, "/home/me/.config/uucli/mux/"));
    try testing.expect(std.mem.endsWith(u8, p1, ".sock"));
    try testing.expectEqual(@as(usize, "/home/me/.config/uucli/mux/".len + 16 + ".sock".len), p1.len);
    try testing.expectEqualStrings(p1, try path(&b, "/home/me/.config/uucli/config.json", false, "gqg", .sock));
    try testing.expect(!std.mem.eql(u8, p1, try path(&b, "/home/me/.config/uucli/config.json", true, "gqg", .sock)));
    try testing.expect(!std.mem.eql(u8, p1, try path(&b, "/home/me/.config/uucli/other.json", false, "gqg", .sock)));
    try testing.expect(!std.mem.eql(u8, p1, try path(&b, "/home/me/.config/uucli/config.json", false, "gqh", .sock)));
    const lock = try path(&b, "/home/me/.config/uucli/config.json", false, "gqg", .lock);
    try testing.expectEqualStrings(p1[0 .. p1.len - 4], lock[0 .. lock.len - 4]);
    const long = "/" ++ @as([90]u8, @splat('d')) ++ "/config.json";
    try testing.expectError(error.NameTooLong, path(&a, long, false, "gqg", .sock));
    _ = try path(&a, long, false, "gqg", .lock);
}

test "mux replies" {
    try testing.expectEqual(Reply.ok, parseReply("OK"));
    try testing.expectEqual(Reply.rejected, parseReply("ERR rejected"));
    try testing.expectEqual(Reply.timeout, parseReply("ERR timeout"));
    try testing.expectEqual(Reply.failed, parseReply("ERR failed"));
    try testing.expectEqual(Reply.failed, parseReply("garbage"));
}

/// Live status, returned by the local socket, never inferred from a PID or a socket file.
pub const Status = struct {
    device: []const u8,
    name: []const u8,
    assist: bool,
    scope: u64,
    pinned: bool,
    streams: u32,
    active: u32,
    waiting: u32,
};

pub fn scope(config_path: []const u8) u64 {
    return std.hash.Wyhash.hash(0x73657373696f6e, config_path);
}

/// Management shares the listener with streams and leases, but never waits for a lease.
pub const Control = struct {
    io: Io,
    pm: *portmap.PortMap,
    leases: *lease.Server,
    bus: *session.Bus,
    device: []const u8,
    name: []const u8,
    assist: bool,
    config_scope: u64,
    mutex: Io.Mutex = .init,
    pinned: bool = false,
    stopping: bool = false,

    pub fn hook(c: *Control) portmap.ManagementHook {
        return .{ .ptr = c, .serveFn = serve };
    }

    fn serve(ptr: *anyopaque, conn: Io.net.Stream, request: []const u8) void {
        const c: *Control = @ptrCast(@alignCast(ptr));
        defer conn.close(c.io);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        var buf: [4096]u8 = undefined;
        var w = conn.writer(c.io, &buf);
        const out = &w.interface;
        if (c.stopping) {
            out.writeAll("ERR stopping\n") catch return;
        } else if (std.mem.eql(u8, request, "STATUS") or std.mem.eql(u8, request, "KEEPALIVE")) {
            if (std.mem.eql(u8, request, "KEEPALIVE")) c.pinned = true;
            const active: u32 = @intFromBool(c.leases.hasHolder());
            const clients = c.leases.clients.load(.monotonic);
            const status: Status = .{
                .device = c.device,
                .name = c.name,
                .assist = c.assist,
                .scope = c.config_scope,
                .pinned = c.pinned,
                .streams = c.pm.rules[0].streams.load(.monotonic),
                .active = active,
                .waiting = clients -| active,
            };
            std.json.Stringify.value(status, .{}, out) catch return;
            out.writeByte('\n') catch return;
        } else {
            const busy = c.pm.rules[0].streams.load(.monotonic) != 0 or c.leases.clients.load(.monotonic) != 0;
            if (busy and !std.mem.eql(u8, request, "STOP FORCE")) {
                out.writeAll("ERR busy\n") catch return;
            } else {
                c.stopping = true;
                out.writeAll("OK\n") catch {};
                out.flush() catch {};
                c.bus.put(.stop);
                return;
            }
        }
        out.flush() catch {};
    }

    /// A single idle watcher owns `since`; the mutex makes pinning and idle expiry exclusive.
    pub fn expire(c: *Control, since: *Io.Timestamp, idle: Io.Duration) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const now = Io.Clock.awake.now(c.io);
        if (c.pinned or c.pm.rules[0].streams.load(.monotonic) != 0 or c.leases.clients.load(.monotonic) != 0) {
            since.* = now;
        } else if (now.compare(.gt, since.addDuration(idle))) {
            c.stopping = true;
            c.bus.put(.stop);
            return true;
        }
        return false;
    }
};
