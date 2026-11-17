// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const config = @import("../config.zig");
const api = @import("../api.zig");
const session = @import("../session.zig");
const interrupts = @import("../interrupts.zig");
const portmap = @import("../tools/portmap.zig");
const app_mod = @import("../app.zig");
const target_mod = @import("../target.zig");
const mux_client = @import("../mux_client.zig");
const runner = @import("../tool_runner.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const signedInClient = app_mod.signedInClient;
const sharedDevice = target_mod.sharedDevice;
const resolveTarget = target_mod.resolveTarget;
const muxEnabled = mux_client.muxEnabled;
const proxyViaMux = mux_client.proxyViaMux;
const sessionLoop = runner.sessionLoop;

pub fn run(app: *App, all_args: []const [:0]const u8) !Exit {
    var assist = false;
    var shared = muxEnabled(app);
    var args = all_args;
    while (args.len != 0) : (args = args[1..]) {
        if (eql(args[0], "--assist")) {
            assist = true;
        } else if (eql(args[0], "--no-mux")) {
            shared = false;
        } else break;
    }
    if (args.len != 3) return usage(app, "expected `proxy [--assist] [--no-mux] DEVICE HOST PORT`", .{});
    const port = std.fmt.parseInt(u16, args[2], 10) catch 0;
    if (port == 0 or args[1].len == 0 or args[1].len > 255) return usage(app, "invalid HOST PORT", .{});
    for (args[1]) |c| if (c <= ' ' or c == 0x7f) return usage(app, "invalid HOST PORT", .{});

    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    // stdin carries the stream, so a code cannot be read from it.
    const target = try resolveTarget(app, &client, &cfg, .{ .query = args[0], .assist = assist }, false);

    if (shared) if (try proxyViaMux(app, sharedDevice(target), target.assist_code, args[1], port)) |code| return code;

    var pm = try portmap.PortMap.init(app.io, app.gpa, &.{.{ .lport = 0, .host = args[1], .port = port }});
    defer pm.deinit();

    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(app.io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    return sessionLoop(app, .{
        .bus = &bus,
        .client = &client,
        .cfg = &cfg,
        .target = target.id,
        .assist_code = target.assist_code,
        .pm = &pm,
        .reconnect = false,
        .proxy = true,
    });
}
