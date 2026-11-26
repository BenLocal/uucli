// SPDX-License-Identifier: GPL-3.0-or-later
//! Internal __mux server: opens the remote connection and serves local clients.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");
const api = @import("api.zig");
const session = @import("session.zig");
const interrupts = @import("interrupts.zig");
const mux = @import("mux.zig");
const lease = @import("lease.zig");
const portmap = @import("tools/portmap.zig");
const log = std.log.scoped(.uucli);
const app_mod = @import("app.zig");
const target_mod = @import("target.zig");
const runner = @import("tool_runner.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const interruptedExit = app_mod.interruptedExit;
const signedInClient = app_mod.signedInClient;
const DeviceArg = target_mod.DeviceArg;
const resolveTarget = target_mod.resolveTarget;
const openFailure = runner.openFailure;

const default_idle_seconds: u32 = 600;

fn idleSeconds(env: *const std.process.Environ.Map) u32 {
    const v = env.get("UUCLI_MUX_IDLE") orelse return default_idle_seconds;
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch default_idle_seconds;
}

/// Internal (`uucli __mux [--assist] DEVICE`): one port mapping session for every `proxy` of
/// DEVICE (spec §7.2). Prints `ready` on stdout once clients can connect; messages go to stderr
/// (the mux log file). Automatic connections expire after `UUCLI_MUX_IDLE` seconds (default 600)
/// without streams or leases; kept connections skip idle expiry. All end on loss or SIGINT/SIGTERM.
pub fn run(app: *App, all_args: []const [:0]const u8) !Exit {
    if (builtin.os.tag == .windows) return app.fail(.other, "shared connections are not supported on Windows", .{});
    const io = app.io;
    const assist = all_args.len != 0 and eql(all_args[0], "--assist");
    const args = if (assist) all_args[1..] else all_args;
    if (args.len != 1) return usage(app, "expected `__mux [--assist] DEVICE`", .{});
    const dev: DeviceArg = .{ .query = args[0], .assist = assist };
    const idle: Io.Duration = .fromSeconds(idleSeconds(app.env));
    const cfg_path = try app.configPath();
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = mux.path(&sock_buf, cfg_path, dev.assist, dev.query, .sock) catch
        return app.fail(.other, "the config path is too long for a shared session", .{});

    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    const target = try resolveTarget(app, &client, &cfg, dev, false);

    // Clients name their own targets; the rule only holds the stream count.
    var pm = try portmap.PortMap.init(io, app.gpa, &.{.{ .lport = 0, .host = "-", .port = 1 }});
    defer pm.deinit();
    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    const s = session.Session.open(.{
        .io = io,
        .gpa = app.gpa,
        .bus = &bus,
        .client = &client,
        .http = &client.http,
        .own_device_id = cfg.device_id,
        .target = target.id,
        .capture_type = 9,
        .assist_code = target.assist_code,
    }) catch |err| return openFailure(app, err);
    defer s.close();
    pm.attach(s);
    defer pm.detach();
    const platform: i64 = if (target.device) |d| switch (d.platform) {
        .windows => 1,
        .mac => 4,
        .unknown => |n| n,
    } else s.publisher_platform orelse 0;
    var leases: lease.Server = .{ .io = io, .gpa = app.gpa, .link = s.link(), .platform = platform, .pm = &pm };
    pm.lease_hook = leases.hook();
    var control: mux.Control = .{
        .io = io,
        .pm = &pm,
        .leases = &leases,
        .bus = &bus,
        .device = target.id,
        .name = app.env.get("UUCLI_MUX_NAME") orelse target.name,
        .assist = dev.assist,
        .config_scope = mux.scope(cfg_path),
    };
    pm.management_hook = control.hook();

    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, sock) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var server = (try Io.net.UnixAddress.init(sock)).listen(io, .{}) catch |err|
        return app.fail(.other, "cannot listen on {s}: {t}", .{ sock, err });
    defer server.deinit(io);
    try pm.startMuxAccepting(&server);
    defer pm.stopAccepting();
    // First, so that no new client reaches a server that is going away.
    defer cwd.deleteFile(io, sock) catch {};
    var idle_task = try io.concurrent(muxIdleWatch, .{ &control, idle });
    defer idle_task.cancel(io) catch {};

    app.out.writeAll("ready\n") catch {};
    app.out.flush() catch {};
    log.info("shared session ready on {s}", .{sock});
    const end = s.run(leases.tool()) catch .interrupted;
    return switch (end) {
        .stopped => .ok,
        .interrupted => interruptedExit(),
        else => app.fail(.connect, "the session ended ({t})", .{end}),
    };
}

/// Stops the session once no stream was open for `idle`.
fn muxIdleWatch(control: *mux.Control, idle: Io.Duration) Io.Cancelable!void {
    var since = Io.Clock.awake.now(control.io);
    while (true) {
        try control.io.sleep(.fromSeconds(1), .awake);
        if (control.expire(&since, idle)) return;
    }
}

test "idleSeconds defaults to 600 and honors UUCLI_MUX_IDLE" {
    const t = std.testing;
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try t.expectEqual(@as(u32, 600), idleSeconds(&env));
    try env.put("UUCLI_MUX_IDLE", "120");
    try t.expectEqual(@as(u32, 120), idleSeconds(&env));
    try env.put("UUCLI_MUX_IDLE", " 30 ");
    try t.expectEqual(@as(u32, 30), idleSeconds(&env));
    try env.put("UUCLI_MUX_IDLE", "bad");
    try t.expectEqual(@as(u32, 600), idleSeconds(&env));
}
