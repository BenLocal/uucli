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
const isFlag = app_mod.isFlag;
const signedInClient = app_mod.signedInClient;
const sharedDevice = target_mod.sharedDevice;
const resolveTarget = target_mod.resolveTarget;
const muxEnabled = mux_client.muxEnabled;
const portmapViaMux = mux_client.portmapViaMux;
const sessionLoop = runner.sessionLoop;

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    var device: ?[]const u8 = null;
    var assist = false;
    var reconnect = true;
    var shared = muxEnabled(app);
    var rules: std.ArrayList(portmap.Rule) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isFlag(a, "--no-reconnect", "-n")) {
            reconnect = false;
        } else if (eql(a, "--no-mux")) {
            shared = false;
        } else if (eql(a, "--assist")) {
            assist = true;
        } else if (eql(a, "-L") or std.mem.startsWith(u8, a, "-L")) {
            const spec = if (a.len > 2) a[2..] else blk: {
                i += 1;
                if (i == args.len) return usage(app, "-L needs [BIND:]LPORT:HOST:PORT", .{});
                break :blk args[i];
            };
            const r = portmap.parseRule(spec) catch return usage(app, "invalid forward {s}: expected [BIND:]LPORT:HOST:PORT", .{spec});
            try rules.append(app.arena, r);
        } else if (a.len > 1 and a[0] == '-') {
            return usage(app, "unknown option {s}", .{a});
        } else if (device == null) {
            device = a;
        } else return usage(app, "unexpected argument {s}", .{a});
    }
    const query = device orelse return usage(app, "portmap needs a DEVICE", .{});
    if (rules.items.len == 0) return usage(app, "portmap needs at least one -L", .{});

    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    const target = try resolveTarget(app, &client, &cfg, .{ .query = query, .assist = assist }, true);

    var pm = try portmap.PortMap.init(app.io, app.gpa, rules.items);
    defer pm.deinit();
    pm.listen() catch return app.fail(.other, "cannot set up the local listeners", .{});
    for (pm.rules) |r| {
        const br = if (std.mem.indexOfScalar(u8, r.rule.bind, ':') != null) "[" else "";
        const bc = if (br.len != 0) "]" else "";
        const hr = if (std.mem.indexOfScalar(u8, r.rule.host, ':') != null) "[" else "";
        const hc = if (hr.len != 0) "]" else "";
        try app.err.print("Listening on {s}{s}{s}:{d} -> {s}{s}{s}:{d}\n", .{ br, r.rule.bind, bc, r.bound_port, hr, r.rule.host, hc, r.rule.port });
    }
    try app.err.flush();
    // `--no-reconnect` asks to fail when the session ends; only an own session can do that.
    if (shared and reconnect)
        if (try portmapViaMux(app, sharedDevice(target), target.assist_code, &pm)) |code| return code;

    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(app.io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);
    try pm.startAccepting();

    return sessionLoop(app, .{
        .bus = &bus,
        .client = &client,
        .cfg = &cfg,
        .target = target.id,
        .assist_code = target.assist_code,
        .pm = &pm,
        .reconnect = reconnect,
        .proxy = false,
    });
}
