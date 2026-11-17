// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared CLI context, configuration errors, exit codes and output helpers.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const api = @import("api.zig");
const interrupts = @import("interrupts.zig");

pub var log_level: std.log.Level = .warn;

pub const Exit = enum(u8) {
    ok = 0,
    other = 1,
    usage = 2,
    not_signed_in = 3,
    no_device = 4,
    connect = 5,
    remote = 6,
    interrupted = 130,
    /// `exec` passes the remote command's exit status through.
    _,
};

pub const App = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,

    /// Prints a message on stderr and returns the exit code.
    pub fn fail(app: *App, code: Exit, comptime fmt: []const u8, args: anytype) Exit {
        app.err.print(fmt ++ "\n", args) catch {};
        return code;
    }

    pub fn configPath(app: *App) ![]const u8 {
        return config.resolvePath(app.arena, app.env);
    }

    pub fn proxyEnv(app: *App) ?*const std.process.Environ.Map {
        const v = app.env.get("UUCLI_USE_PROXY") orelse return null;
        const t = std.mem.trim(u8, v, " ");
        for ([_][]const u8{ "1", "true", "yes", "on" }) |yes| if (std.ascii.eqlIgnoreCase(t, yes)) return app.env;
        return null;
    }

    /// On a terminal, asks whether to remove saved codes in an unsupported (older) format.
    fn confirmDropCodes(app: *App, path: []const u8) bool {
        if (!(Io.File.stdin().isTty(app.io) catch false) or !(Io.File.stderr().isTty(app.io) catch false)) return false;
        app.err.print("Saved remote codes in {s} use an unsupported format (from an older uucli). Remove them? [y/N] ", .{path}) catch return false;
        app.err.flush() catch return false;
        // One byte at a time: nothing after the line is consumed.
        var buf: [1]u8 = undefined;
        var r = Io.File.stdin().readerStreaming(app.io, &buf);
        var answer: [8]u8 = undefined;
        var len: usize = 0;
        while (r.interface.takeByte()) |b| {
            if (b == '\n') break;
            if (len < answer.len) answer[len] = b;
            len += 1;
        } else |_| return false;
        if (len > answer.len) return false;
        const a = std.mem.trim(u8, answer[0..len], " \t\r");
        return std.ascii.eqlIgnoreCase(a, "y") or std.ascii.eqlIgnoreCase(a, "yes");
    }

    /// Loads the config and maps load errors to messages.
    pub fn loadConfig(app: *App, path: []const u8) !config.Config {
        return config.load(app.arena, app.io, path) catch |err| {
            if (err == error.UnsupportedCodeFormat and app.confirmDropCodes(path)) {
                if (config.dropUnsupportedCodes(app.arena, app.io, path)) |n| {
                    try app.err.print("Removed {d} saved remote code(s); enter them again when asked\n", .{n});
                    return app.loadConfig(path);
                } else |e| {
                    _ = app.fail(.other, "cannot remove the saved remote codes from {s}: {t}", .{ path, e });
                    return error.Reported;
                }
            }
            switch (err) {
                error.InsecurePermissions => _ = app.fail(.other, "{s} is accessible by group/other; fix with: chmod 600 {s}", .{ path, path }),
                error.InvalidConfig => _ = app.fail(.other, "{s} is not a valid uucli config", .{path}),
                error.InvalidEncryptionKey => _ = app.fail(.other, "cannot read the encryption key {s}.key: it must contain 32 bytes with mode 600; restore the original key to read saved codes", .{path}),
                error.CodeDecryptionFailed => _ = app.fail(.other, "cannot decrypt saved remote codes in {s}: the key or encrypted data is incorrect", .{path}),
                error.UnsupportedCodeFormat => _ = app.fail(.other, "saved remote codes in {s} use an unsupported format; remove assist_codes and enter the codes again", .{path}),
                else => _ = app.fail(.other, "cannot read {s}: {t}", .{ path, err }),
            }
            return error.Reported;
        };
    }
};

/// `long` or its one-letter `short` form.
pub fn isFlag(a: []const u8, long: []const u8, short: []const u8) bool {
    return eql(a, long) or eql(a, short);
}

pub fn usage(app: *App, comptime fmt: []const u8, args: anytype) Exit {
    app.err.print(fmt ++ "\nRun `uucli --help` for usage.\n", args) catch {};
    return .usage;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Maps errors that were not reported yet to an exit code and a message.
pub fn errorExit(app: *App, err: anyerror) Exit {
    return switch (err) {
        error.Reported => .other,
        error.ReportedUsage => .usage,
        error.ReportedNotSignedIn => .not_signed_in,
        error.ReportedNoDevice => .no_device,
        error.NotSignedIn => app.fail(.not_signed_in, "Not signed in or the login expired: run `uucli login`", .{}),
        error.NoConfigPath => app.fail(.other, "cannot locate the config: set HOME or UUCLI_CONFIG", .{}),
        error.Canceled => .interrupted,
        else => app.fail(.other, "error: {t}", .{err}),
    };
}

/// A signed-in API client; reports "not signed in" itself.
pub fn signedInClient(app: *App, client: *api.Client, cfg: *config.Config) !void {
    const path = try app.configPath();
    cfg.* = try app.loadConfig(path);
    if (!cfg.signedIn() or cfg.device_id.len == 0) {
        _ = app.fail(.not_signed_in, "Not signed in: run `uucli login`", .{});
        return error.ReportedNotSignedIn;
    }
    try client.init(app.io, app.gpa, cfg, if (app.proxyEnv()) |env| .{ .arena = app.arena, .env = env } else null);
}

pub fn interruptedExit() Exit {
    return @fromBackingInt(@intCast(interrupts.exitCode()));
}

pub fn pad(w: *Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    try w.splatByteAll(' ', width -| displayWidth(s));
}

/// Terminal columns of a UTF-8 string: East Asian wide characters count 2.
pub fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return s.len).iterator();
    while (it.nextCodepoint()) |cp| {
        const wide = (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
            (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
            (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
            (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF) or
            (cp >= 0x20000 and cp <= 0x3FFFD);
        n += if (wide) 2 else 1;
    }
    return n;
}

test "displayWidth" {
    try std.testing.expectEqual(@as(usize, 9), displayWidth("office-pc"));
    try std.testing.expectEqual(@as(usize, 8), displayWidth("办公电脑"));
}
