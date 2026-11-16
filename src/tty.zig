// SPDX-License-Identifier: GPL-3.0-or-later
//! Local terminal: raw mode and window size (spec §11.1).
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

/// tcgetattr. On Linux the ioctl itself: Zig 0.17.1's `posix.termios` is the kernel's 44-byte struct,
/// but glibc's tcgetattr writes its own 60-byte one and overruns it (a stack-protector abort in
/// ReleaseSafe).
fn getAttr(fd: posix.fd_t) !posix.termios {
    if (builtin.os.tag != .linux) return posix.tcgetattr(fd);
    var t: posix.termios = undefined;
    return switch (linux.errno(linux.tcgetattr(fd, &t))) {
        .SUCCESS => t,
        .NOTTY => error.NotATerminal,
        else => error.Unexpected,
    };
}

fn setAttr(fd: posix.fd_t, when: posix.TCSA, t: posix.termios) !void {
    if (builtin.os.tag != .linux) return posix.tcsetattr(fd, when, t);
    return switch (linux.errno(linux.tcsetattr(fd, when, &t))) {
        .SUCCESS => {},
        .NOTTY => error.NotATerminal,
        else => error.Unexpected,
    };
}

pub const Raw = struct {
    fd: posix.fd_t,
    saved: posix.termios,

    /// Puts `fd` into raw mode (like cfmakeraw); `restore` undoes it. Input typed before is dropped:
    /// in cooked mode Enter became LF, which a Windows host reads as Ctrl+Enter.
    pub fn enter(fd: posix.fd_t) !Raw {
        const saved = try getAttr(fd);
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
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try setAttr(fd, .FLUSH, raw);
        return .{ .fd = fd, .saved = saved };
    }

    /// Turns off echo only (for reading a secret line); `restore` undoes it.
    pub fn noEcho(fd: posix.fd_t) !Raw {
        const saved = try getAttr(fd);
        var t = saved;
        t.lflag.ECHO = false;
        try setAttr(fd, .NOW, t);
        return .{ .fd = fd, .saved = saved };
    }

    pub fn restore(r: Raw) void {
        setAttr(r.fd, .NOW, r.saved) catch {};
    }
};

/// Columns and rows of stdin's terminal, or 80x24.
pub fn size() [2]u16 {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(0, posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col != 0 and ws.row != 0) return .{ ws.col, ws.row };
    return .{ 80, 24 };
}
