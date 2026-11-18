// SPDX-License-Identifier: GPL-3.0-or-later
//! Runs workers on direct sessions or shared leases and owns interruption and teardown.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const api = @import("api.zig");
const session = @import("session.zig");
const interrupts = @import("interrupts.zig");
const mux = @import("mux.zig");
const lease = @import("lease.zig");
const portmap = @import("tools/portmap.zig");
const terminal = @import("tools/terminal.zig");
const log = std.log.scoped(.uucli);
const app_mod = @import("app.zig");
const target_mod = @import("target.zig");
const mux_client = @import("mux_client.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const interruptedExit = app_mod.interruptedExit;
const signedInClient = app_mod.signedInClient;
const DeviceArg = target_mod.DeviceArg;
const Target = target_mod.Target;
const sharedDevice = target_mod.sharedDevice;
const resolveIdentity = target_mod.resolveIdentity;
const assistCode = target_mod.assistCode;
const readCode = target_mod.readCode;
const updateSavedCode = target_mod.updateSavedCode;
const muxEnabled = mux_client.muxEnabled;
const startMuxServer = mux_client.startMuxServer;
const muxLease = mux_client.muxLease;
const MuxLease = mux_client.MuxLease;

pub const LoopSetup = struct {
    bus: *session.Bus,
    client: *api.Client,
    cfg: *const config.Config,
    target: []const u8,
    assist_code: ?[]const u8,
    pm: *portmap.PortMap,
    reconnect: bool,
    proxy: bool,
};

/// Opens sessions for the port mapper until interrupted (spec §7.1).
pub fn sessionLoop(app: *App, l: LoopSetup) !Exit {
    const io = app.io;
    const min_backoff: Io.Duration = .fromSeconds(1);
    const max_backoff: Io.Duration = .fromSeconds(60);
    var backoff = min_backoff;
    var first = true;
    while (true) {
        // An assistance host is not on the account; its join fails by itself once the share ends.
        if (!first and l.assist_code == null) {
            // The device may have been removed meanwhile (exit 4), or the login expired (exit 3).
            if (stillListed(app, l)) |listed| {
                if (!listed) return app.fail(.no_device, "device {s} is no longer on the account", .{l.target});
            } else |err| switch (err) {
                error.NotSignedIn => return err,
                else => {},
            }
        }
        const s = session.Session.open(.{
            .io = io,
            .gpa = app.gpa,
            .bus = l.bus,
            .client = l.client,
            .http = &l.client.http,
            .own_device_id = l.cfg.device_id,
            .target = l.target,
            .capture_type = 9,
            .assist_code = l.assist_code,
        }) catch |err| {
            const code: Exit = switch (err) {
                error.Interrupted => return interruptedExit(),
                error.Canceled => return .interrupted,
                error.NotSignedIn => return error.NotSignedIn,
                error.DeviceBusy => blk: {
                    _ = app.fail(.remote, "the device is being controlled from another device", .{});
                    break :blk .remote;
                },
                error.Refused => blk: {
                    _ = app.fail(.remote, "the device refused the port mapping session", .{});
                    break :blk .remote;
                },
                error.ConnectFailed => blk: {
                    _ = app.fail(.connect, "connection to the device failed", .{});
                    break :blk .connect;
                },
                error.OutOfMemory => return err,
            };
            if (!l.reconnect) return code;
            first = false;
            if (try waitBackoff(app, l.bus, &backoff, max_backoff)) return interruptedExit();
            continue;
        };
        first = false;
        const ready_at = Io.Clock.awake.now(io);
        l.pm.attach(s);
        if (l.proxy) l.pm.startStream(&l.pm.rules[0], .stdio, true, null) catch |err| {
            l.pm.detach();
            s.close();
            return app.fail(.other, "cannot start the stream: {t}", .{err});
        };
        if (!l.proxy) app.err.print("Connected to {s}\n", .{l.target}) catch {};
        app.err.flush() catch {};
        const end = s.run(l.pm.tool()) catch .interrupted;
        l.pm.detach();
        s.close();
        switch (end) {
            .interrupted => return interruptedExit(),
            .stopped => {
                // proxy: the stream ended.
                const err = l.pm.last_error orelse return .ok;
                return switch (err) {
                    error.Rejected => app.fail(.remote, "the device refused the connection to the target", .{}),
                    error.SynTimeout => app.fail(.connect, "the device did not answer the connection request", .{}),
                    else => app.fail(.connect, "the stream failed: {t}", .{err}),
                };
            },
            else => {},
        }
        log.warn("session ended: {t}", .{end});
        if (!l.reconnect) return app.fail(.connect, "the session ended ({t})", .{end});
        app.err.print("Session ended ({t}); reconnecting\n", .{end}) catch {};
        app.err.flush() catch {};
        if (Io.Clock.awake.now(io).compare(.gt, ready_at.addDuration(max_backoff))) backoff = min_backoff;
        if (try waitBackoff(app, l.bus, &backoff, max_backoff)) return interruptedExit();
    }
}

/// Sleeps for the current backoff (consuming bus events) and doubles it. True on interrupt.
fn waitBackoff(app: *App, bus: *session.Bus, backoff: *Io.Duration, max: Io.Duration) !bool {
    log.info("reconnecting in {d} s", .{@divTrunc(backoff.nanoseconds, std.time.ns_per_s)});
    const deadline = Io.Clock.awake.now(app.io).addDuration(backoff.*);
    const doubled: Io.Duration = .{ .nanoseconds = backoff.nanoseconds * 2 };
    backoff.* = if (doubled.nanoseconds > max.nanoseconds) max else doubled;
    return bus.waitUntil(deadline);
}

fn stillListed(app: *App, l: LoopSetup) !bool {
    var resp = try l.client.call(.GET, "/api/v1/device/list", "", .fromSeconds(15));
    defer resp.deinit();
    // Per-attempt arena: this runs on every reconnect of a long-lived portmap.
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const devices = try api.parseDevices(arena.allocator(), resp.data, l.cfg.device_id);
    for (devices) |d| if (std.mem.eql(u8, d.id, l.target)) return true;
    return false;
}

/// Maps a failed `Session.open` to an exit code (with a message).
pub fn openFailure(app: *App, err: session.OpenError) Exit {
    return switch (err) {
        error.Interrupted => interruptedExit(),
        error.Canceled => .interrupted,
        error.NotSignedIn => app.fail(.not_signed_in, "Not signed in or the login expired: run `uucli login`", .{}),
        error.DeviceBusy => app.fail(.remote, "the device is being controlled from another device", .{}),
        error.Refused => app.fail(.remote, "the device refused the session", .{}),
        error.ConnectFailed => app.fail(.connect, "connection to the device failed", .{}),
        error.OutOfMemory => app.fail(.other, "out of memory", .{}),
    };
}

/// Only rejected assistance joins may ask for a replacement; tool execution is never retried.
fn retryAssistCode(err: session.OpenError, failure: api.Failure, assist: bool, interactive: bool, retries: u8) bool {
    return err == error.ConnectFailed and failure.status == 400 and failure.code == 1131 and
        assist and interactive and retries < 3;
}

/// Runs `worker` on a lease of DEVICE's shared session (spec §7.3), starting the server when
/// needed. Null: no shared session possible here (socket path too long).
fn runLeased(
    app: *App,
    cfg: *const config.Config,
    target: Target,
    remember_prompt: bool,
    comptime Tool: type,
    tool_state: *Tool,
    comptime worker: fn (*App, *Tool) Exit,
) !?Exit {
    const io = app.io;
    const dev = sharedDevice(target);
    const cfg_path = try app.configPath();
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = mux.path(&sock_buf, cfg_path, dev.assist, dev.query, .sock) catch {
        log.info("config path too long for a shared session; connecting directly", .{});
        return null;
    };
    var granted: ?MuxLease = null;
    var join_code: ?[]const u8 = null;
    for (0..3) |_| {
        switch (try muxLease(io, sock)) {
            .granted => |g| {
                granted = g;
                break;
            },
            // A server of an older uucli (before leases) is still running: use an own session.
            .unsupported => {
                log.info("the running shared session does not take leases; connecting directly", .{});
                return null;
            },
            .gone => {
                if (dev.assist and join_code == null)
                    join_code = try assistCode(app, cfg, target.id, @hasDecl(Tool, "stdin_free") and Tool.stdin_free);
                if (try startMuxServer(app, cfg_path, dev, sock, join_code)) |exit| return exit;
            },
        }
    }
    const g = granted orelse return app.fail(.connect, "the shared session did not take the request", .{});
    var client: lease.Client = .{ .io = io, .gpa = app.gpa, .conn = g.conn };
    defer g.conn.close(io);
    if (join_code != null and remember_prompt) try savePromptedCode(app, target.id, join_code.?);
    // An assistance host is not in the device list; the server knows its platform from the join.
    if (@hasDecl(Tool, "device") and target.device == null)
        tool_state.device(.{ .id = target.id, .name = target.id, .platform = .from(g.platform), .online = true, .shared = true });
    tool_state.bind(io, app.gpa, client.link());
    defer tool_state.unbind();

    var bus_buf: [16]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    const Ctx = struct {
        fn run(a: *App, t: *Tool, b: *session.Bus) Exit {
            const code = worker(a, t);
            b.put(.stop);
            return code;
        }
        fn ended(ptr: *anyopaque) void {
            const t: *Tool = @ptrCast(@alignCast(ptr));
            t.sessionEnded();
        }
    };
    var reader = try io.concurrent(lease.Client.readTask, .{ &client, tool_state.tool(), Ctx.ended, @as(*anyopaque, tool_state) });
    defer {
        // Unblock the reader, then wait for it.
        g.conn.shutdown(io, .both) catch {};
        reader.cancel(io) catch {};
    }
    var task = try io.concurrent(Ctx.run, .{ app, tool_state, &bus });
    var interrupted = false;
    while (true) {
        const e = bus.next() catch break;
        defer e.deinit();
        switch (e) {
            .interrupt => if (!interrupted) {
                interrupted = true;
                // Optional hooks must be `pub`: @hasDecl does not see private declarations.
                if (@hasDecl(Tool, "interrupted")) tool_state.interrupted() else tool_state.sessionEnded();
            },
            .stop => break,
            else => {},
        }
    }
    const result = task.await(io);
    if (@hasDecl(Tool, "completed") and tool_state.completed()) return result;
    if (interrupted) return interruptedExit();
    if (client.lost.load(.acquire) and result == .ok) return app.fail(.connect, "the shared session ended", .{});
    return result;
}

fn savePromptedCode(app: *App, id: []const u8, code: []const u8) !void {
    try updateSavedCode(app, id, code);
    try app.err.writeAll("The remote code is saved in the config file\n");
    try app.err.flush();
}

/// One session for a tool that runs `worker` (on its own task) while this task routes messages.
pub fn runToolSession(
    app: *App,
    dev: DeviceArg,
    capture: u32,
    comptime Tool: type,
    tool_state: *Tool,
    comptime worker: fn (*App, *Tool) Exit,
) !Exit {
    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    var target = try resolveIdentity(app, &client, &cfg, dev);
    if (target.device) |d| if (@hasDecl(Tool, "device")) tool_state.device(d);

    const interactive = Io.File.stdin().isTty(app.io) catch false;
    const remember_codes = capture == 8;
    const remember_prompt = remember_codes and interactive and target.assist and
        cfg.assistCode(target.id) == null and
        (if (app.env.get("UUCLI_ASSIST_CODE")) |code| code.len == 0 else true);
    if (!dev.own_session and muxEnabled(app))
        if (try runLeased(app, &cfg, target, remember_prompt, Tool, tool_state, worker)) |code| return code;
    if (target.assist)
        target.assist_code = try assistCode(app, &cfg, target.id, @hasDecl(Tool, "stdin_free") and Tool.stdin_free);

    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(app.io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    var save_code = remember_prompt;
    var code_retries: u8 = 0;
    const s = while (true) {
        const opened = session.Session.open(.{
            .io = app.io,
            .gpa = app.gpa,
            .bus = &bus,
            .client = &client,
            .http = &client.http,
            .own_device_id = cfg.device_id,
            .target = target.id,
            .capture_type = capture,
            .assist_code = target.assist_code,
        }) catch |err| {
            if (!remember_codes or !retryAssistCode(err, client.failure, target.assist_code != null, interactive, code_retries))
                return openFailure(app, err);
            try app.err.writeAll("The remote code was rejected or expired, or assistance is disabled. Enter a new code (up to 3 retries).\n");
            target.assist_code = try readCode(app, target.id, false);
            code_retries += 1;
            save_code = true;
            continue;
        };
        break opened;
    };

    defer s.close();
    if (save_code) try savePromptedCode(app, target.id, target.assist_code.?);
    // An assistance host is not in the device list; its platform comes from the room join.
    if (@hasDecl(Tool, "device") and target.device == null) if (s.publisher_platform) |p|
        tool_state.device(.{ .id = target.id, .name = target.id, .platform = .from(p), .online = true, .shared = true });
    tool_state.bind(app.io, app.gpa, s.link());
    defer tool_state.unbind();

    const Ctx = struct {
        fn run(a: *App, t: *Tool, b: *session.Bus) Exit {
            const code = worker(a, t);
            b.put(.stop);
            return code;
        }
    };
    var task = try app.io.concurrent(Ctx.run, .{ app, tool_state, &bus });
    const end = s.run(tool_state.tool()) catch .interrupted;
    // Optional hooks must be `pub`: @hasDecl does not see private declarations.
    if (end == .interrupted and @hasDecl(Tool, "interrupted")) {
        // The tool winds down on a live session (bounded by its own timeouts), then stops it.
        tool_state.interrupted();
        s.resumeRun();
        const after = s.run(tool_state.tool()) catch .interrupted;
        if (after != .stopped) tool_state.sessionEnded();
    } else if (end != .stopped) tool_state.sessionEnded();
    const code = task.await(app.io);
    // A tool that already has its result (exec: the remote shell exits right after printing it)
    // does not fail because the host then closed the session.
    if (@hasDecl(Tool, "completed") and tool_state.completed()) return code;
    return switch (end) {
        .stopped => code,
        .interrupted => interruptedExit(),
        else => if (code == .ok) app.fail(.connect, "the session ended ({t})", .{end}) else code,
    };
}

pub fn terminalError(app: *App, err: terminal.Error) Exit {
    return switch (err) {
        error.Rejected => app.fail(.remote, "the device refused the terminal request", .{}),
        error.NoSuchSession => app.fail(.remote, "the terminal session no longer exists", .{}),
        error.RemoteTimeout => app.fail(.remote, "the device did not answer the terminal request", .{}),
        error.InvalidResponse => app.fail(.remote, "invalid terminal response from the device", .{}),
        error.SessionEnded => app.fail(.connect, "the terminal session failed", .{}),
        error.CommandTimeout => app.fail(.remote, "the command did not finish in time", .{}),
        error.OutputLimit => app.fail(.remote, "the command printed more than {d} MiB", .{terminal.max_exec_output / (1024 * 1024)}),
        error.Canceled => .interrupted,
        error.OutOfMemory => app.fail(.other, "out of memory", .{}),
    };
}

test "assistance code retries require a rejected join and interactive input" {
    const t = std.testing;
    const rejected: api.Failure = .{ .status = 400, .code = 1131 };
    try t.expect(retryAssistCode(error.ConnectFailed, rejected, true, true, 0));
    try t.expect(retryAssistCode(error.ConnectFailed, rejected, true, true, 2));
    try t.expect(!retryAssistCode(error.ConnectFailed, rejected, true, true, 3));
    try t.expect(!retryAssistCode(error.ConnectFailed, rejected, true, false, 0));
    try t.expect(!retryAssistCode(error.ConnectFailed, rejected, false, true, 0));
    for ([_]session.OpenError{ error.Refused, error.DeviceBusy, error.NotSignedIn, error.Canceled, error.OutOfMemory, error.Interrupted }) |err|
        try t.expect(!retryAssistCode(err, rejected, true, true, 0));
    try t.expect(!retryAssistCode(error.ConnectFailed, .{ .status = 500, .code = 1131 }, true, true, 0));
    try t.expect(!retryAssistCode(error.ConnectFailed, .{ .status = 400, .code = 2002 }, true, true, 0));
    try t.expect(!retryAssistCode(error.ConnectFailed, .{}, true, true, 0));
}
