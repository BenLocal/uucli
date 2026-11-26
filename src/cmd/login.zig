// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const login = @import("../login.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    var method: ?login.Method = null;
    for (args) |a| {
        const m: login.Method = if (eql(a, "--qr")) .qr else if (eql(a, "--phone")) .phone else return usage(app, "expected `login [--qr | --phone]`", .{});
        if (method != null and method.? != m) return usage(app, "use only one of --qr, --phone", .{});
        method = m;
    }
    const path = try app.configPath();
    const account = login.run(.{
        .io = app.io,
        .gpa = app.gpa,
        .arena = app.arena,
        .config_path = path,
        .stderr = app.err,
        .stdin_tty = Io.File.stdin().isTty(app.io) catch false,
        .proxy_env = app.proxyEnv(),
        .method = method,
    }) catch |err| switch (err) {
        error.LoginBusy => return app.fail(.other, "another `uucli login` is running for {s}", .{path}),
        error.LoginFailed => return app.fail(.other, "login failed", .{}),
        error.InsecurePermissions, error.InvalidConfig => {
            _ = app.loadConfig(path, false) catch {};
            return .other;
        },
        // Already reported by the login flow.
        error.ApiError, error.Network, error.Timeout, error.BadResponse => return .other,
        else => |e| return e,
    };
    try app.err.print("Signed in as {s} ({s})\n", .{ if (account.name.len != 0) account.name else account.user_id, account.user_id });
    return .ok;
}
