// SPDX-License-Identifier: GPL-3.0-or-later
//! Local terminal: raw mode and window size (spec §11.1).
const std = @import("std");
const posix = std.posix;

pub const Raw = struct {
    fd: posix.fd_t,
    saved: posix.termios,

    /// Puts `fd` into raw mode (like cfmakeraw); `restore` undoes it.
    pub fn enter(fd: posix.fd_t) !Raw {
        const saved = try posix.tcgetattr(fd);
        var raw = saved;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .NOW, raw);
        return .{ .fd = fd, .saved = saved };
    }

    pub fn restore(r: Raw) void {
        posix.tcsetattr(r.fd, .NOW, r.saved) catch {};
    }
};

/// Columns and rows of stdin's terminal, or 80x24.
pub fn size() [2]u16 {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(0, posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col != 0 and ws.row != 0) return .{ ws.col, ws.row };
    return .{ 80, 24 };
}
