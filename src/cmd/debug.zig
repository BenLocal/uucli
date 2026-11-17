// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const rtc = @import("../rtc.zig");
const login = @import("../login.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len == 1 and eql(args[0], "rtc-loopback")) {
        try rtc.loopback(app.io);
        try app.out.writeAll("rtc loopback ok\n");
        return .ok;
    }
    if (args.len == 1 and eql(args[0], "device-info")) {
        // What device registration would send about this machine (without the generated ids).
        const info = try login.hardware(app.arena, app.io);
        try std.json.Stringify.value(info, .{ .whitespace = .indent_2 }, app.out);
        try app.out.writeByte('\n');
        return .ok;
    }
    return usage(app, "unknown debug command", .{});
}
