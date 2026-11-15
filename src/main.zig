// SPDX-License-Identifier: GPL-3.0-or-later
//! Argument parsing, dispatch and exit codes (spec §3).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const rtc = @import("rtc.zig");
const config = @import("config.zig");
const api = @import("api.zig");
const login = @import("login.zig");
const session = @import("session.zig");
const interrupts = @import("interrupts.zig");
const portmap = @import("tools/portmap.zig");
const terminal = @import("tools/terminal.zig");
const files = @import("tools/files.zig");
const tty = @import("tty.zig");

const log = std.log.scoped(.uucli);

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

/// Runtime log level: warn by default, `-v` info, `-vv` debug.
var log_level: std.log.Level = .warn;

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub const Exit = enum(u8) {
    ok = 0,
    other = 1,
    usage = 2,
    not_signed_in = 3,
    no_device = 4,
    connect = 5,
    remote = 6,
    interrupted = 130,
};

const usage_text =
    \\Usage: uucli [-v|-vv] COMMAND [ARGS]
    \\
    \\Commands:
    \\  login                                   Sign in by scanning a QR code with the UU Remote app
    \\  logout                                  Forget the account (keeps the device identity)
    \\  device list [--json]                    List the account's devices
    \\  portmap DEVICE -L [BIND:]LPORT:HOST:PORT [-L ...] [--no-reconnect]
    \\  proxy DEVICE HOST PORT                  Connect stdin/stdout to HOST:PORT (ssh ProxyCommand)
    \\  terminal DEVICE [SESSION] [-e CHAR|none] | --list [--json] | --kill SESSION
    \\  files DEVICE ls REMOTE_DIR [--json] | get REMOTE LOCAL [--force] | put LOCAL REMOTE [--force]
    \\
    \\DEVICE is a device id or name from `device list`.
    \\
    \\Short forms:
    \\  dev = device, ls = list, pm = portmap, px = proxy, term = terminal, fs = files
    \\  -j = --json, -l = --list, -k = --kill, -f = --force, -n = --no-reconnect
    \\
    \\Options:
    \\  -v, -vv      More logging (info, debug) on stderr
    \\  --version    Print the version
    \\  -h, --help   Print this help
    \\
    \\Environment: UUCLI_CONFIG (config file), UUCLI_USE_PROXY=1 (honor HTTP(S)_PROXY)
    \\
;

pub const App = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,

    /// Prints a message on stderr and returns the exit code.
    fn fail(app: *App, code: Exit, comptime fmt: []const u8, args: anytype) Exit {
        app.err.print(fmt ++ "\n", args) catch {};
        return code;
    }

    fn configPath(app: *App) ![]const u8 {
        return config.resolvePath(app.arena, app.env);
    }

    fn proxyEnv(app: *App) ?*const std.process.Environ.Map {
        const v = app.env.get("UUCLI_USE_PROXY") orelse return null;
        const t = std.mem.trim(u8, v, " ");
        for ([_][]const u8{ "1", "true", "yes", "on" }) |yes| if (std.ascii.eqlIgnoreCase(t, yes)) return app.env;
        return null;
    }

    /// Loads the config and maps load errors to messages.
    fn loadConfig(app: *App, path: []const u8) !config.Config {
        return config.load(app.arena, app.io, path) catch |err| {
            switch (err) {
                error.InsecurePermissions => _ = app.fail(.other, "{s} is accessible by group/other; fix with: chmod 600 {s}", .{ path, path }),
                error.InvalidConfig => _ = app.fail(.other, "{s} is not a valid uucli config", .{path}),
                else => _ = app.fail(.other, "cannot read {s}: {t}", .{ path, err }),
            }
            return error.Reported;
        };
    }
};

pub fn main(init: std.process.Init) u8 {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    // Streaming, not positional: appending to a redirected file must not overwrite it.
    var out_w: Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    var err_w: Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buf);
    var app: App = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .env = init.environ_map,
        .out = &out_w.interface,
        .err = &err_w.interface,
    };
    const args = init.minimal.args.toSlice(app.arena) catch return @intFromEnum(Exit.other);
    const code = run(&app, args[1..]);
    app.out.flush() catch {};
    app.err.flush() catch {};
    return @intFromEnum(code);
}

fn run(app: *App, all_args: []const [:0]const u8) Exit {
    var args = all_args;
    while (args.len != 0 and args[0].len > 1 and args[0][0] == '-') : (args = args[1..]) {
        const a = args[0];
        if (eql(a, "-v")) {
            log_level = .info;
        } else if (eql(a, "-vv")) {
            log_level = .debug;
        } else if (eql(a, "--version")) {
            app.out.print("uucli {s}\n", .{build_options.version}) catch {};
            return .ok;
        } else if (eql(a, "-h") or eql(a, "--help")) {
            app.out.writeAll(usage_text) catch {};
            return .ok;
        } else return usage(app, "unknown option {s}", .{a});
    }
    if (args.len == 0) {
        app.err.writeAll(usage_text) catch {};
        return .usage;
    }
    const cmd = commandName(args[0]);
    const rest = args[1..];
    const result = if (eql(cmd, "login"))
        cmdLogin(app, rest)
    else if (eql(cmd, "logout"))
        cmdLogout(app, rest)
    else if (eql(cmd, "device"))
        cmdDevice(app, rest)
    else if (eql(cmd, "portmap"))
        cmdPortmap(app, rest)
    else if (eql(cmd, "proxy"))
        cmdProxy(app, rest)
    else if (eql(cmd, "terminal"))
        cmdTerminal(app, rest)
    else if (eql(cmd, "files"))
        cmdFiles(app, rest)
    else if (eql(cmd, "debug"))
        cmdDebug(app, rest)
    else
        return usage(app, "unknown command {s}", .{cmd});
    return result catch |err| errorExit(app, err);
}

/// Short command names (fixed aliases, no prefix matching, so a new command never changes what
/// an existing abbreviation means).
const command_aliases = [_][2][]const u8{
    .{ "dev", "device" },
    .{ "pm", "portmap" },
    .{ "px", "proxy" },
    .{ "term", "terminal" },
    .{ "fs", "files" },
};

fn commandName(name: []const u8) []const u8 {
    for (command_aliases) |a| if (eql(name, a[0])) return a[1];
    return name;
}

/// `long` or its one-letter `short` form.
fn isFlag(a: []const u8, long: []const u8, short: []const u8) bool {
    return eql(a, long) or eql(a, short);
}

fn usage(app: *App, comptime fmt: []const u8, args: anytype) Exit {
    app.err.print(fmt ++ "\nRun `uucli --help` for usage.\n", args) catch {};
    return .usage;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Maps errors that were not reported yet to an exit code and a message.
fn errorExit(app: *App, err: anyerror) Exit {
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

fn cmdLogin(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len != 0) return usage(app, "login takes no arguments", .{});
    const path = try app.configPath();
    const account = login.run(.{
        .io = app.io,
        .gpa = app.gpa,
        .arena = app.arena,
        .config_path = path,
        .stderr = app.err,
        .stdin_tty = Io.File.stdin().isTty(app.io) catch false,
        .proxy_env = app.proxyEnv(),
    }) catch |err| switch (err) {
        error.LoginBusy => return app.fail(.other, "another `uucli login` is running for {s}", .{path}),
        error.LoginFailed => return app.fail(.other, "login failed", .{}),
        error.InsecurePermissions, error.InvalidConfig => {
            _ = app.loadConfig(path) catch {};
            return .other;
        },
        // Already reported by the login flow.
        error.ApiError, error.Network, error.Timeout, error.BadResponse => return .other,
        else => |e| return e,
    };
    try app.err.print("Signed in as {s} ({s})\n", .{ if (account.name.len != 0) account.name else account.user_id, account.user_id });
    return .ok;
}

fn cmdLogout(app: *App, args: []const [:0]const u8) !Exit {
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

/// A signed-in API client; reports "not signed in" itself.
fn signedInClient(app: *App, client: *api.Client, cfg: *config.Config) !void {
    const path = try app.configPath();
    cfg.* = try app.loadConfig(path);
    if (!cfg.signedIn() or cfg.device_id.len == 0) {
        _ = app.fail(.not_signed_in, "Not signed in: run `uucli login`", .{});
        return error.ReportedNotSignedIn;
    }
    try client.init(app.io, app.gpa, cfg, if (app.proxyEnv()) |env| .{ .arena = app.arena, .env = env } else null);
}

/// Fetches the account's devices (spec §5.4).
pub fn fetchDevices(app: *App, client: *api.Client, cfg: *const config.Config) ![]api.Device {
    var resp = client.call(.GET, "/api/v1/device/list", "", .fromSeconds(15)) catch |err| switch (err) {
        error.NotSignedIn => return err,
        error.ApiError, error.Network, error.Timeout, error.BadResponse => {
            login.reportCallError(app.err, "device list", client, err);
            return error.Reported;
        },
        else => |e| return e,
    };
    // Strings are copied to the arena so the response can go.
    defer resp.deinit();
    const devices = try api.parseDevices(app.arena, resp.data, cfg.device_id);
    for (devices) |*d| {
        d.id = try app.arena.dupe(u8, d.id);
        d.name = try app.arena.dupe(u8, d.name);
    }
    return devices;
}

fn cmdDevice(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len == 0 or !(eql(args[0], "list") or eql(args[0], "ls"))) return usage(app, "expected `device list [--json]`", .{});
    var json = false;
    for (args[1..]) |a| {
        if (isFlag(a, "--json", "-j")) json = true else return usage(app, "unknown argument {s}", .{a});
    }
    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    const devices = try fetchDevices(app, &client, &cfg);
    if (json) try writeDevicesJson(app.out, devices) else try writeDevicesTable(app.out, devices);
    return .ok;
}

fn writeDevicesJson(w: *Io.Writer, devices: []const api.Device) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginArray();
    for (devices) |d| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(d.id);
        try s.objectField("name");
        try s.write(d.name);
        try s.objectField("platform");
        var pbuf: [32]u8 = undefined;
        try s.write(try std.fmt.bufPrint(&pbuf, "{f}", .{d.platform}));
        try s.objectField("online");
        try s.write(d.online);
        try s.objectField("shared");
        try s.write(d.shared);
        try s.endObject();
    }
    try s.endArray();
    try w.writeByte('\n');
}

fn writeDevicesTable(w: *Io.Writer, devices: []const api.Device) !void {
    var id_w: usize = "ID".len;
    var name_w: usize = "NAME".len;
    var plat_w: usize = "PLATFORM".len;
    for (devices) |d| {
        id_w = @max(id_w, displayWidth(d.id));
        name_w = @max(name_w, displayWidth(d.name));
        var pbuf: [32]u8 = undefined;
        plat_w = @max(plat_w, (try std.fmt.bufPrint(&pbuf, "{f}", .{d.platform})).len);
    }
    try pad(w, "ID", id_w + 2);
    try pad(w, "NAME", name_w + 2);
    try pad(w, "PLATFORM", plat_w + 2);
    try w.writeAll("ONLINE  SHARED\n");
    for (devices) |d| {
        try pad(w, d.id, id_w + 2);
        try pad(w, d.name, name_w + 2);
        var pbuf: [32]u8 = undefined;
        try pad(w, try std.fmt.bufPrint(&pbuf, "{f}", .{d.platform}), plat_w + 2);
        try pad(w, if (d.online) "yes" else "no", "ONLINE".len + 2);
        try w.print("{s}\n", .{if (d.shared) "yes" else "no"});
    }
}

fn pad(w: *Io.Writer, s: []const u8, width: usize) !void {
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

// --- portmap / proxy ---------------------------------------------------------------------------

fn cmdPortmap(app: *App, args: []const [:0]const u8) !Exit {
    var device: ?[]const u8 = null;
    var reconnect = true;
    var rules: std.ArrayList(portmap.Rule) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isFlag(a, "--no-reconnect", "-n")) {
            reconnect = false;
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
    const target = try resolveTarget(app, &client, &cfg, query);

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
        .target = target,
        .pm = &pm,
        .reconnect = reconnect,
        .proxy = false,
    });
}

fn cmdProxy(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len != 3) return usage(app, "expected `proxy DEVICE HOST PORT`", .{});
    const port = std.fmt.parseInt(u16, args[2], 10) catch 0;
    if (port == 0 or args[1].len == 0) return usage(app, "invalid HOST PORT", .{});

    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    const target = try resolveTarget(app, &client, &cfg, args[0]);

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
        .target = target,
        .pm = &pm,
        .reconnect = false,
        .proxy = true,
    });
}

/// DEVICE (id or name) → device id; exit 2 when ambiguous, 4 when unknown or offline.
fn resolveTarget(app: *App, client: *api.Client, cfg: *const config.Config, query: []const u8) ![]const u8 {
    const devices = try fetchDevices(app, client, cfg);
    switch (try api.resolveDevice(app.arena, devices, query)) {
        .found => |d| {
            if (!d.online) {
                _ = app.fail(.no_device, "device {s} ({s}) is offline", .{ d.name, d.id });
                return error.ReportedNoDevice;
            }
            return d.id;
        },
        .not_found => {
            _ = app.fail(.no_device, "no device {s}: see `uucli device list`", .{query});
            return error.ReportedNoDevice;
        },
        .ambiguous => |list| {
            app.err.print("device name {s} is ambiguous; use an id:\n", .{query}) catch {};
            for (list) |d| app.err.print("  {s}  {s}\n", .{ d.id, d.name }) catch {};
            return error.ReportedUsage;
        },
    }
}

const LoopSetup = struct {
    bus: *session.Bus,
    client: *api.Client,
    cfg: *const config.Config,
    target: []const u8,
    pm: *portmap.PortMap,
    reconnect: bool,
    proxy: bool,
};

fn interruptedExit() Exit {
    return @enumFromInt(interrupts.exitCode());
}

/// Opens sessions for the port mapper until interrupted (spec §7.1).
fn sessionLoop(app: *App, l: LoopSetup) !Exit {
    const io = app.io;
    const min_backoff: Io.Duration = .fromSeconds(1);
    const max_backoff: Io.Duration = .fromSeconds(60);
    var backoff = min_backoff;
    var first = true;
    while (true) {
        if (!first) {
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
        if (l.proxy) l.pm.startStream(&l.pm.rules[0], .stdio, true) catch |err| {
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

// --- terminal ----------------------------------------------------------------------------------

/// Maps a failed `Session.open` to an exit code (with a message).
fn openFailure(app: *App, err: session.OpenError) Exit {
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

/// One session for a tool that runs `worker` (on its own task) while this task routes messages.
fn runToolSession(
    app: *App,
    query: []const u8,
    capture: u32,
    comptime Tool: type,
    tool_state: *Tool,
    comptime worker: fn (*App, *Tool) Exit,
) !Exit {
    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();
    const target = try resolveTarget(app, &client, &cfg, query);

    var bus_buf: [256]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(app.io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    const s = session.Session.open(.{
        .io = app.io,
        .gpa = app.gpa,
        .bus = &bus,
        .client = &client,
        .http = &client.http,
        .own_device_id = cfg.device_id,
        .target = target,
        .capture_type = capture,
    }) catch |err| return openFailure(app, err);
    defer s.close();
    tool_state.bind(app.io, app.gpa, s);
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
    return switch (end) {
        .stopped => code,
        .interrupted => interruptedExit(),
        else => if (code == .ok) app.fail(.connect, "the session ended ({t})", .{end}) else code,
    };
}

const TerminalCmd = struct {
    t: terminal.Terminal = undefined,
    mode: union(enum) { attach: u32, list: bool, kill: u32 },
    escape: ?u8,

    fn bind(c: *TerminalCmd, io: Io, gpa: Allocator, s: *session.Session) void {
        c.t.init(io, gpa, s);
    }
    fn unbind(c: *TerminalCmd) void {
        c.t.deinit();
    }
    fn tool(c: *TerminalCmd) session.Tool {
        return c.t.tool();
    }
    fn sessionEnded(c: *TerminalCmd) void {
        c.t.post(.session_end);
    }
    /// SIGTERM (or SIGINT without raw mode): detach cleanly while the session is still up.
    pub fn interrupted(c: *TerminalCmd) void {
        c.t.post(.input_end);
    }
};

fn cmdTerminal(app: *App, args: []const [:0]const u8) !Exit {
    var device: ?[]const u8 = null;
    var session_id: ?u32 = null;
    var escape: ?u8 = '~';
    var list = false;
    var json = false;
    var kill: ?u32 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isFlag(a, "--list", "-l")) {
            list = true;
        } else if (isFlag(a, "--json", "-j")) {
            json = true;
        } else if (isFlag(a, "--kill", "-k") or eql(a, "-e")) {
            i += 1;
            if (i == args.len) return usage(app, "{s} needs a value", .{a});
            const v = args[i];
            if (eql(a, "-e")) {
                if (eql(v, "none")) escape = null else if (v.len == 1 and v[0] >= 0x21 and v[0] < 0x7f) escape = v[0] else return usage(app, "-e takes one printable character or `none`", .{});
            } else kill = std.fmt.parseInt(u32, v, 10) catch return usage(app, "invalid session id {s}", .{v});
        } else if (a.len > 1 and a[0] == '-') {
            return usage(app, "unknown option {s}", .{a});
        } else if (device == null) {
            device = a;
        } else if (session_id == null) {
            session_id = std.fmt.parseInt(u32, a, 10) catch return usage(app, "invalid session id {s}", .{a});
            if (session_id.? == 0) return usage(app, "invalid session id {s}", .{a});
        } else return usage(app, "unexpected argument {s}", .{a});
    }
    const query = device orelse return usage(app, "terminal needs a DEVICE", .{});
    const modes = @as(u8, @intFromBool(list)) + @intFromBool(kill != null) + @intFromBool(session_id != null);
    if (modes > 1) return usage(app, "use only one of SESSION, --list, --kill", .{});
    if (json and !list) return usage(app, "--json only applies to --list", .{});
    var cmd: TerminalCmd = .{
        .mode = if (list) .{ .list = json } else if (kill) |k| .{ .kill = k } else .{ .attach = session_id orelse 0 },
        .escape = escape,
    };
    return runToolSession(app, query, 8, TerminalCmd, &cmd, terminalWorker);
}

fn terminalError(app: *App, err: terminal.Error) Exit {
    return switch (err) {
        error.Rejected => app.fail(.remote, "the device refused the terminal request", .{}),
        error.NoSuchSession => app.fail(.remote, "the terminal session no longer exists", .{}),
        error.RemoteTimeout => app.fail(.remote, "the device did not answer the terminal request", .{}),
        error.InvalidResponse => app.fail(.remote, "invalid terminal response from the device", .{}),
        error.SessionEnded => app.fail(.connect, "the terminal session failed", .{}),
        error.Canceled => .interrupted,
        error.OutOfMemory => app.fail(.other, "out of memory", .{}),
    };
}

fn terminalWorker(app: *App, cmd: *TerminalCmd) Exit {
    const t = &cmd.t;
    var group: Io.Group = .init;
    defer group.cancel(app.io);
    group.concurrent(app.io, terminal.Terminal.ticker, .{t}) catch return app.fail(.other, "cannot start the terminal", .{});
    t.checkEnv() catch |err| return switch (err) {
        error.Rejected => app.fail(.remote, "the terminal environment is unavailable on the device", .{}),
        else => terminalError(app, err),
    };
    switch (cmd.mode) {
        .list => |json| {
            const sessions = t.list(app.arena) catch |err| return terminalError(app, err);
            if (json) {
                std.json.Stringify.value(sessions, .{}, app.out) catch {};
                app.out.writeByte('\n') catch {};
            } else {
                app.out.writeAll("ID      NAME                STATE\n") catch {};
                for (sessions) |x| app.out.print("{d:<8}{s:<20}{s}\n", .{ x.id, x.name, x.state }) catch {};
            }
            return .ok;
        },
        .kill => |id| {
            t.kill(id) catch |err| return terminalError(app, err);
            app.err.print("Killed terminal session {d}\n", .{id}) catch {};
            return .ok;
        },
        .attach => |want| return terminalAttach(app, cmd, &group, want),
    }
}

fn terminalAttach(app: *App, cmd: *TerminalCmd, group: *Io.Group, want: u32) Exit {
    const t = &cmd.t;
    const is_tty = Io.File.stdin().isTty(app.io) catch false;
    const sz = if (is_tty) tty.size() else [2]u16{ 80, 24 };
    const id = t.open(app.arena, want, sz[0], sz[1]) catch |err| return terminalError(app, err);
    log.info("attached to terminal session {d}", .{id});
    var raw: ?tty.Raw = null;
    if (is_tty) raw = tty.Raw.enter(0) catch null;
    var restored = false;
    const restore = struct {
        fn f(r: ?tty.Raw, done: *bool) void {
            if (done.*) return;
            done.* = true;
            if (r) |x| x.restore();
        }
    }.f;
    defer restore(raw, &restored);
    if (is_tty) interrupts.onResize(.{ .ptr = t, .call = struct {
        fn f(p: *anyopaque) void {
            const term: *terminal.Terminal = @ptrCast(@alignCast(p));
            term.post(.resize);
        }
    }.f });
    defer interrupts.onResize(null);
    group.concurrent(app.io, stdinReader, .{ app.io, t }) catch return app.fail(.other, "cannot read stdin", .{});

    const outcome = t.attach(.{
        .id = id,
        .out = app.out,
        .err = app.err,
        .escape = cmd.escape,
        .tty = is_tty,
        .size = tty.size,
    });
    t.close(id);
    restore(raw, &restored);
    const o = outcome catch |err| return terminalError(app, err);
    switch (o) {
        .detached => |sid| {
            app.err.print("\nDetached from terminal session {d}\n", .{sid}) catch {};
            return .ok;
        },
        .exited => |code| {
            if (code == 0) return .ok;
            return app.fail(.remote, "remote shell exited with code {d}", .{code});
        },
    }
}

fn stdinReader(io: Io, t: *terminal.Terminal) Io.Cancelable!void {
    var buf: [16 * 1024]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(io, &buf);
    while (true) {
        const data = r.interface.peekGreedy(1) catch |err| {
            if (err == error.ReadFailed) if (r.err) |e| if (e == error.Canceled) return error.Canceled;
            t.post(.input_end);
            return;
        };
        const d = t.gpa.dupe(u8, data) catch {
            t.post(.input_end);
            return;
        };
        r.interface.toss(data.len);
        t.post(.{ .input = d });
    }
}

// --- files -------------------------------------------------------------------------------------

const FilesCmd = struct {
    f: files.Files = undefined,
    op: union(enum) {
        ls: struct { path: []const u8, json: bool },
        get: struct { remote: []const u8, local: []const u8 },
        put: struct { local: []const u8, remote: []const u8, force: bool },
    },

    fn bind(c: *FilesCmd, io: Io, gpa: Allocator, s: *session.Session) void {
        c.f.init(io, gpa, s);
    }
    fn unbind(c: *FilesCmd) void {
        c.f.deinit();
    }
    fn tool(c: *FilesCmd) session.Tool {
        return c.f.tool();
    }
    fn sessionEnded(c: *FilesCmd) void {
        c.f.post(.session_end);
    }
    pub fn interrupted(c: *FilesCmd) void {
        c.f.post(.cancel);
    }
};

fn cmdFiles(app: *App, args: []const [:0]const u8) !Exit {
    const usage_files = "expected `files DEVICE ls REMOTE_DIR [--json] | get REMOTE LOCAL [--force] | put LOCAL REMOTE [--force]`";
    var pos: std.ArrayList([]const u8) = .empty;
    var json = false;
    var force = false;
    for (args) |a| {
        if (isFlag(a, "--json", "-j")) json = true else if (isFlag(a, "--force", "-f")) force = true else if (a.len > 1 and a[0] == '-') return usage(app, "unknown option {s}", .{a}) else try pos.append(app.arena, a);
    }
    const p = pos.items;
    if (p.len < 2) return usage(app, usage_files, .{});
    const op = p[1];
    var cmd: FilesCmd = undefined;
    if ((eql(op, "ls") or eql(op, "list")) and p.len == 3 and !force) {
        cmd = .{ .op = .{ .ls = .{ .path = p[2], .json = json } } };
    } else if (eql(op, "get") and p.len == 4 and !json) {
        if (!force) if (Io.Dir.cwd().statFile(app.io, p[3], .{})) |_| {
            return usage(app, "{s} exists; use --force to overwrite it", .{p[3]});
        } else |_| {};
        cmd = .{ .op = .{ .get = .{ .remote = p[2], .local = p[3] } } };
    } else if (eql(op, "put") and p.len == 4 and !json) {
        const st = Io.Dir.cwd().statFile(app.io, p[2], .{}) catch |err| return app.fail(.other, "cannot read {s}: {t}", .{ p[2], err });
        if (st.kind != .file) return app.fail(.other, "{s} is not a regular file", .{p[2]});
        if (files.splitRemote(p[3]) == null) return usage(app, "invalid remote file name {s}", .{p[3]});
        cmd = .{ .op = .{ .put = .{ .local = p[2], .remote = p[3], .force = force } } };
    } else return usage(app, usage_files, .{});
    return runToolSession(app, p[0], 5, FilesCmd, &cmd, filesWorker);
}

fn filesError(app: *App, f: *const files.Files, err: files.Error) Exit {
    return switch (err) {
        error.Remote => app.fail(.remote, "the device reported file error code {d}", .{f.remote_code}),
        error.RemoteTimeout => app.fail(.remote, "the device did not answer in time", .{}),
        error.InvalidResponse => app.fail(.remote, "unexpected file response from the device", .{}),
        error.NotAFile => app.fail(.remote, "the remote path is a folder, not a file", .{}),
        error.InvalidRemoteName => app.fail(.usage, "invalid remote file name", .{}),
        error.Interrupted => interruptedExit(),
        error.SessionEnded => app.fail(.connect, "the file session failed", .{}),
        error.LocalFile => app.fail(.other, "local file error", .{}),
        error.Canceled => .interrupted,
        error.OutOfMemory => app.fail(.other, "out of memory", .{}),
    };
}

fn kindName(kind: u64) []const u8 {
    return switch (kind) {
        files.kind_dir => "dir",
        files.kind_drive => "drive",
        files.kind_file => "file",
        else => "other",
    };
}

fn filesWorker(app: *App, cmd: *FilesCmd) Exit {
    const f = &cmd.f;
    var group: Io.Group = .init;
    defer group.cancel(app.io);
    group.concurrent(app.io, files.Files.ticker, .{f}) catch return app.fail(.other, "cannot start the transfer", .{});
    if (Io.File.stderr().isTty(app.io) catch false) if (cmd.op != .ls) f.showProgress(app.err);
    switch (cmd.op) {
        .ls => |o| {
            const entries = f.list(app.arena, o.path) catch |err| return filesError(app, f, err);
            if (o.json) {
                var s: std.json.Stringify = .{ .writer = app.out };
                s.beginArray() catch {};
                for (entries) |e| s.write(.{ .kind = kindName(e.kind), .name = e.name, .size = e.size, .path = e.path }) catch {};
                s.endArray() catch {};
                app.out.writeByte('\n') catch {};
            } else for (entries) |e| app.out.print("{s:<6}{d:>14}  {s}\n", .{ kindName(e.kind), e.size, e.name }) catch {};
            return .ok;
        },
        .get => |o| {
            const part = std.fmt.allocPrint(app.arena, "{s}.uucli-part", .{o.local}) catch return .other;
            const cwd = Io.Dir.cwd();
            const out = cwd.createFile(app.io, part, .{ .truncate = true }) catch |err| return app.fail(.other, "cannot create {s}: {t}", .{ part, err });
            f.download(o.remote, out) catch |err| {
                out.close(app.io);
                cwd.deleteFile(app.io, part) catch {};
                return filesError(app, f, err);
            };
            out.close(app.io);
            cwd.rename(part, cwd, o.local, app.io) catch |err| {
                cwd.deleteFile(app.io, part) catch {};
                return app.fail(.other, "cannot rename {s} to {s}: {t}", .{ part, o.local, err });
            };
            return .ok;
        },
        .put => |o| {
            if (!o.force) {
                const exists = f.remoteExists(app.arena, o.remote) catch |err| return filesError(app, f, err);
                if (exists) return app.fail(.usage, "{s} exists on the device; use --force to overwrite it", .{o.remote});
            }
            const file = Io.Dir.cwd().openFile(app.io, o.local, .{}) catch |err| return app.fail(.other, "cannot open {s}: {t}", .{ o.local, err });
            defer file.close(app.io);
            f.upload(file, o.remote) catch |err| return filesError(app, f, err);
            return .ok;
        },
    }
}

fn cmdDebug(app: *App, args: []const [:0]const u8) !Exit {
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

test {
    _ = rtc;
    _ = config;
    _ = api;
    _ = login;
    _ = @import("qr.zig");
    _ = @import("wire.zig");
    _ = @import("ws.zig");
    _ = @import("signal.zig");
    _ = @import("session.zig");
    _ = @import("tools/portmap.zig");
    _ = @import("tools/terminal.zig");
    _ = @import("tools/files.zig");
    _ = @import("tty.zig");
    _ = interrupts;
    _ = @import("e2e_test.zig");
    _ = @import("vectors_test.zig");
}

test "tool hooks are visible to runToolSession" {
    // A private hook is silently skipped (@hasDecl only sees `pub` declarations).
    try std.testing.expect(@hasDecl(TerminalCmd, "interrupted"));
    try std.testing.expect(@hasDecl(FilesCmd, "interrupted"));
}

test "short forms" {
    try std.testing.expectEqualStrings("device", commandName("dev"));
    try std.testing.expectEqualStrings("portmap", commandName("pm"));
    try std.testing.expectEqualStrings("proxy", commandName("px"));
    try std.testing.expectEqualStrings("terminal", commandName("term"));
    try std.testing.expectEqualStrings("files", commandName("fs"));
    try std.testing.expectEqualStrings("login", commandName("login"));
    // No prefix matching.
    try std.testing.expectEqualStrings("ter", commandName("ter"));
    try std.testing.expect(isFlag("-j", "--json", "-j"));
    try std.testing.expect(isFlag("--json", "--json", "-j"));
    try std.testing.expect(!isFlag("--js", "--json", "-j"));
}

test "displayWidth" {
    try std.testing.expectEqual(@as(usize, 9), displayWidth("office-pc"));
    try std.testing.expectEqual(@as(usize, 8), displayWidth("办公电脑"));
}

test "device table and json" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const devs = [_]api.Device{
        .{ .id = "aeawswhnguarjyo6", .name = "office-pc", .platform = .windows, .online = true, .shared = false },
        .{ .id = "m1", .name = "家里", .platform = .{ .unknown = 7 }, .online = false, .shared = true },
    };
    try writeDevicesTable(&out.writer, &devs);
    try std.testing.expectEqualStrings(
        \\ID                NAME       PLATFORM    ONLINE  SHARED
        \\aeawswhnguarjyo6  office-pc  windows     yes     no
        \\m1                家里       unknown(7)  no      yes
        \\
    , out.written());
    out.clearRetainingCapacity();
    try writeDevicesJson(&out.writer, &devs);
    try std.testing.expectEqualStrings(
        \\[{"id":"aeawswhnguarjyo6","name":"office-pc","platform":"windows","online":true,"shared":false},{"id":"m1","name":"家里","platform":"unknown(7)","online":false,"shared":true}]
        \\
    , out.written());
}
