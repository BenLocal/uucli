// SPDX-License-Identifier: GPL-3.0-or-later
const config = @import("../config.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len != 0) return usage(app, "logout takes no arguments", .{});
    const path = try app.configPath();
    const l = try config.lock(app.io, path, .identity);
    defer l.release(app.io);
    var cfg = try app.loadConfig(path);
    if (!cfg.signedIn() and cfg.token.len == 0) {
        try app.err.writeAll("Not signed in\n");
        return .ok;
    }
    cfg.clearAccount();
    try config.save(app.io, path, cfg);
    try app.err.writeAll("Signed out\n");
    return .ok;
}
