// SPDX-License-Identifier: GPL-3.0-or-later
//! Local terminal: raw mode, console setup and window size (spec §11.1).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

/// Display columns for a printable code point. East Asian wide characters take two columns.
pub fn codepointWidth(cp: u21) u2 {
    const wide = (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
    return if (wide) 2 else 1;
}

const Win32 = struct {
    const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;

    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    const COORD = extern struct { X: i16, Y: i16 };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: windows.HANDLE) callconv(.winapi) windows.BOOL;
};

/// Configures UTF-8 and VT output on Windows consoles; no-op on POSIX.
pub fn initConsole() void {
    if (!is_windows) return;
    _ = Win32.SetConsoleOutputCP(65001);
    _ = Win32.SetConsoleCP(65001);
    for ([_]windows.HANDLE{ Io.File.stdout().handle, Io.File.stderr().handle }) |h| {
        var mode: windows.DWORD = 0;
        if (Win32.GetConsoleMode(h, &mode) != .FALSE) {
            _ = Win32.SetConsoleMode(h, mode | Win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}

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

pub const Raw = if (is_windows) struct {
    handle: Io.File.Handle,
    saved_in: windows.DWORD,
    out_handle: ?windows.HANDLE = null,
    saved_out: windows.DWORD = 0,

    /// Puts `handle` into raw console mode; `restore` undoes it.
    pub fn enter(handle: Io.File.Handle) !Raw {
        var saved_in: windows.DWORD = 0;
        if (Win32.GetConsoleMode(handle, &saved_in) == .FALSE) return error.NotATerminal;
        _ = Win32.FlushConsoleInputBuffer(handle);
        const raw_in = (saved_in & ~(Win32.ENABLE_LINE_INPUT | Win32.ENABLE_ECHO_INPUT | Win32.ENABLE_PROCESSED_INPUT)) |
            Win32.ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (Win32.SetConsoleMode(handle, raw_in) == .FALSE) return error.Unexpected;

        var out_handle: ?windows.HANDLE = null;
        var saved_out: windows.DWORD = 0;
        const out_h = Io.File.stdout().handle;
        if (Win32.GetConsoleMode(out_h, &saved_out) != .FALSE) {
            if (Win32.SetConsoleMode(out_h, saved_out | Win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != .FALSE) {
                out_handle = out_h;
            }
        }
        return .{
            .handle = handle,
            .saved_in = saved_in,
            .out_handle = out_handle,
            .saved_out = saved_out,
        };
    }

    /// Turns off echo only (for reading a secret line); `restore` undoes it.
    pub fn noEcho(handle: Io.File.Handle) !Raw {
        var saved_in: windows.DWORD = 0;
        if (Win32.GetConsoleMode(handle, &saved_in) == .FALSE) return error.NotATerminal;
        if (Win32.SetConsoleMode(handle, saved_in & ~Win32.ENABLE_ECHO_INPUT) == .FALSE) return error.Unexpected;
        return .{ .handle = handle, .saved_in = saved_in };
    }

    pub fn restore(r: Raw) void {
        _ = Win32.SetConsoleMode(r.handle, r.saved_in);
        if (r.out_handle) |oh| _ = Win32.SetConsoleMode(oh, r.saved_out);
    }
} else struct {
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

/// Columns and rows of the terminal, or 80x24.
pub fn size() [2]u16 {
    if (is_windows) {
        var info: Win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (Win32.GetConsoleScreenBufferInfo(Io.File.stdout().handle, &info) != .FALSE) {
            const cols = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
            const rows = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
            if (cols > 0 and rows > 0) return .{ @intCast(cols), @intCast(rows) };
        }
        return .{ 80, 24 };
    }
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(0, posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col != 0 and ws.row != 0) return .{ ws.col, ws.row };
    return .{ 80, 24 };
}
