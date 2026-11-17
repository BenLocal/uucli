// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared `proxy` session (spec §7.2): file names beside the config and the client's wire format.
//! The serving side is `PortMap.startMuxAccepting`; process handling is in main.zig.
const std = @import("std");

/// Leaves room for the NUL of `sockaddr_un.sun_path` (104 bytes on macOS, 108 on Linux).
pub const max_socket_path = 103;

pub const Kind = enum { sock, lock, log };

/// `CONFIG_DIR/mux/HASH.KIND`. HASH covers the config path and DEVICE as given (with `--assist`),
/// so every account and spelling of DEVICE gets its own shared session.
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
