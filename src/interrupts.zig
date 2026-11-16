// SPDX-License-Identifier: GPL-3.0-or-later
//! SIGINT / SIGTERM → `.interrupt` on the session bus, through a self-pipe and a reader thread
//! (spec §3: SIGINT exits 130, SIGTERM exits 0). SIGPIPE is ignored so a closed local socket or
//! stdout shows up as a write error instead of killing the process.
const std = @import("std");
const Bus = @import("session.zig").Bus;

var pipe_fds: [2]std.c.fd_t = .{ -1, -1 };
var last_signal: std.atomic.Value(u32) = .init(0);
var target: ?*Bus = null;

/// Called on the reader thread after SIGWINCH (installed with `onResize`).
pub const ResizeHook = struct { ptr: *anyopaque, call: *const fn (ptr: *anyopaque) void };
var resize_hook: ?ResizeHook = null;

fn handler(sig: std.c.SIG) callconv(.c) void {
    if (sig != .WINCH) last_signal.store(@intCast(@intFromEnum(sig)), .release);
    const b: [1]u8 = .{if (sig == .WINCH) 1 else 0};
    _ = std.c.write(pipe_fds[1], &b, 1);
}

fn readerThread() void {
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

/// Installs the handlers; interrupts are delivered to `bus` from now on. Call once.
pub fn install(bus: *Bus) !void {
    target = bus;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    // Default stack size: glibc carves static TLS (std's 256 KiB signal stack) out of the thread
    // stack, so a small explicit size makes pthread_create fail with EINVAL on Linux.
    const t = try std.Thread.spawn(.{}, readerThread, .{});
    t.detach();
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    act.handler = .{ .handler = std.posix.SIG.IGN };
    std.posix.sigaction(.PIPE, &act, null);
}

/// Delivers SIGWINCH to `hook` from now on (after `install`).
pub fn onResize(hook: ?ResizeHook) void {
    resize_hook = hook;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);
}

/// The signal that caused the last `.interrupt`, if any.
pub fn last() ?std.c.SIG {
    const v = last_signal.load(.acquire);
    return if (v == 0) null else @enumFromInt(v);
}

/// Exit code for an interrupt: SIGTERM 0, anything else 130.
pub fn exitCode() u8 {
    return if (last() == .TERM) 0 else 130;
}

test "install starts the reader thread and delivers SIGTERM to the bus" {
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
