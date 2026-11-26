// SPDX-License-Identifier: GPL-3.0-or-later
//! SIGINT / SIGTERM (or Windows console control events) -> `.interrupt` on the session bus
//! (spec §3: SIGINT exits 130, SIGTERM exits 0). SIGPIPE is ignored on POSIX so a closed local
//! socket or stdout shows up as a write error instead of killing the process.
const std = @import("std");
const builtin = @import("builtin");
const Bus = @import("session.zig").Bus;

pub const Signal = enum(u8) { int = 1, term = 2 };

var last_signal: std.atomic.Value(u8) = .init(0);
var target: ?*Bus = null;

/// Called on the reader thread after SIGWINCH (installed with `onResize`).
pub const ResizeHook = struct { ptr: *anyopaque, call: *const fn (ptr: *anyopaque) void };
var resize_hook: ?ResizeHook = null;

const is_windows = builtin.os.tag == .windows;

var pipe_fds: [2]std.c.fd_t = if (is_windows) undefined else .{ -1, -1 };

fn posixHandler(sig: std.c.SIG) callconv(.c) void {
    if (sig != .WINCH) {
        const mapped: u8 = @backingInt(if (sig == .TERM) Signal.term else Signal.int);
        last_signal.store(mapped, .release);
    }
    const b: [1]u8 = .{if (sig == .WINCH) 1 else 0};
    _ = std.c.write(pipe_fds[1], &b, 1);
}

fn posixReaderThread() void {
    var b: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &b, 1);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return;
        }
        if (b[0] == 1) {
            if (resize_hook) |h| h.call(h.ptr);
        } else if (target) |bus| bus.put(.interrupt);
    }
}

const windows = std.os.windows;
var win_installed: std.atomic.Value(bool) = .init(false);

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

fn windowsCtrlHandler(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    const sig: Signal = switch (ctrl_type) {
        2, 5, 6 => .term, // CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT
        else => .int, // CTRL_C_EVENT (0), CTRL_BREAK_EVENT (1)
    };
    last_signal.store(@backingInt(sig), .release);
    if (target) |bus| bus.put(.interrupt);
    return .TRUE;
}

/// Installs the handlers; interrupts are delivered to `bus` from now on. Call once.
pub fn install(bus: *Bus) !void {
    target = bus;
    if (is_windows) {
        if (!win_installed.swap(true, .acq_rel)) {
            _ = SetConsoleCtrlHandler(windowsCtrlHandler, .TRUE);
        }
        return;
    }
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    // Default stack size: glibc carves static TLS (std's 256 KiB signal stack) out of the thread
    // stack, so a small explicit size makes pthread_create fail with EINVAL on Linux.
    const t = try std.Thread.spawn(.{}, posixReaderThread, .{});
    t.detach();
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = posixHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

pub fn ignoreBrokenPipe() void {
    if (is_windows) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

/// Delivers SIGWINCH to `hook` from now on (after `install`). No-op on Windows.
pub fn onResize(hook: ?ResizeHook) void {
    if (is_windows) return;
    resize_hook = hook;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = posixHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);
}

/// The signal that caused the last `.interrupt`, if any.
pub fn last() ?Signal {
    const v = last_signal.load(.acquire);
    return switch (v) {
        1 => .int,
        2 => .term,
        else => null,
    };
}

/// Exit code for an interrupt: SIGTERM 0, anything else 130.
pub fn exitCode() u8 {
    return if (last() == .term) 0 else 130;
}

test "install starts the reader thread and delivers SIGTERM to the bus" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var buf: [16]@import("session.zig").Event = undefined;
    var bus: Bus = undefined;
    try bus.init(io, &buf);
    defer bus.deinit();
    try install(&bus);
    defer target = null;
    _ = std.c.raise(.TERM);
    while (true) {
        const e = try bus.next();
        defer e.deinit();
        if (e == .interrupt) break;
    }
    try std.testing.expectEqual(@as(u8, 0), exitCode());
}
