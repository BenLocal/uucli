// SPDX-License-Identifier: GPL-3.0-or-later
//! Process initialization, global options, fixed aliases and command dispatch (spec §3).
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const errorExit = app_mod.errorExit;
const mux_server = @import("mux_server.zig");
const cmd_login = @import("cmd/login.zig");
const cmd_logout = @import("cmd/logout.zig");
const cmd_device = @import("cmd/device.zig");
const cmd_fav = @import("cmd/fav.zig");
const cmd_portmap = @import("cmd/portmap.zig");
const cmd_proxy = @import("cmd/proxy.zig");
const cmd_session = @import("cmd/session.zig");
const cmd_terminal = @import("cmd/terminal.zig");
const cmd_exec = @import("cmd/exec.zig");
const cmd_files = @import("cmd/files.zig");
const cmd_debug = @import("cmd/debug.zig");

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@backingInt(level) > @backingInt(app_mod.log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

const usage_text =
    \\Usage: uucli [-v|-vv] COMMAND [ARGS]
    \\
    \\Commands:
    \\  login [--qr | --phone]                  Sign in: QR code scanned with the UU Remote app, or phone
    \\                                          number and SMS code (asked which on a terminal)
    \\  logout                                  Forget the account (keeps the device identity)
    \\  device list [--json]                    List the account's devices
    \\  fav list [--recent] [--json]            List remote-assistance favorites (or recent hosts)
    \\  fav add ID [NAME] [--save-code]         Add a share id to the favorites (optionally save its code)
    \\  fav edit NAME|ID [NEW_NAME] [--save-code]
    \\                                          Rename a favorite and/or replace its saved code
    \\  fav rm|remove NAME|ID                   Remove a favorite and its saved code
    \\  session start DEVICE                  Open and keep a shared connection
    \\  session list [--json] | status DEVICE [--json] | stop DEVICE [--force]
    \\  portmap DEVICE -L [BIND:]LPORT:HOST:PORT [-L ...] [--no-reconnect] [--no-mux]
    \\  proxy [--no-mux] DEVICE HOST PORT       Connect stdin/stdout to HOST:PORT (ssh ProxyCommand);
    \\                                          all commands share one background connection per DEVICE
    \\                                          (--no-mux on proxy, portmap, terminal, exec, files: own one)
    \\  terminal DEVICE [SESSION] [-e CHAR|none] | --list [--json] | --kill SESSION
    \\  files DEVICE ls REMOTE_DIR [--json] | get REMOTE LOCAL [--force] | put LOCAL REMOTE [--force]
    \\  exec DEVICE [--timeout SECONDS] [--json] [--] COMMAND...
    \\                                          Run one command in a new remote shell, print its output
    \\                                          and exit with its exit status
    \\
    \\DEVICE is a device id or name from `device list` or `fav list`. With --assist (portmap, proxy,
    \\terminal, exec, files, session), DEVICE is the share id of a host offering remote assistance. Its code
    \\comes from UUCLI_ASSIST_CODE, the config (fav add --save-code), or is asked for.
    \\Interactive terminal/exec saves entered codes after connection and prompts again for rejected codes.
    \\
    \\Short forms:
    \\  dev = device, ls = list, pm = portmap, px = proxy, term = terminal, fs = files, x = exec
    \\  -j = --json, -l = --list, -k = --kill, -f = --force, -n = --no-reconnect, -t = --timeout
    \\
    \\Options:
    \\  -v, -vv      More logging (info, debug) on stderr
    \\  --version    Print the version
    \\  -h, --help   Print this help
    \\
    \\Environment: UUCLI_CONFIG (config file), UUCLI_USE_PROXY=1 (honor HTTP(S)_PROXY),
    \\  UUCLI_ASSIST_CODE (remote-assistance code), UUCLI_MUX=0 (no shared connection),
    \\  UUCLI_MUX_IDLE (idle seconds for automatic connections, default 60)
    \\
;

pub fn main(init: std.process.Init) u8 {
    @import("interrupts.zig").ignoreBrokenPipe();
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
    const args = init.minimal.args.toSlice(app.arena) catch return @backingInt(Exit.other);
    var code = run(&app, args[1..]);
    app.out.flush() catch {};
    if (out_w.err) |err| code = app.fail(.other, "cannot write stdout: {t}", .{err});
    app.err.flush() catch {};
    return @backingInt(code);
}

fn run(app: *App, all_args: []const [:0]const u8) Exit {
    var args = all_args;
    while (args.len != 0 and args[0].len > 1 and args[0][0] == '-') : (args = args[1..]) {
        const a = args[0];
        if (eql(a, "-v")) {
            app_mod.log_level = .info;
        } else if (eql(a, "-vv")) {
            app_mod.log_level = .debug;
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
        cmd_login.run(app, rest)
    else if (eql(cmd, "logout"))
        cmd_logout.run(app, rest)
    else if (eql(cmd, "device"))
        cmd_device.run(app, rest)
    else if (eql(cmd, "fav"))
        cmd_fav.run(app, rest)
    else if (eql(cmd, "session"))
        cmd_session.run(app, rest)
    else if (eql(cmd, "portmap"))
        cmd_portmap.run(app, rest)
    else if (eql(cmd, "proxy"))
        cmd_proxy.run(app, rest)
    else if (eql(cmd, "terminal"))
        cmd_terminal.run(app, rest)
    else if (eql(cmd, "files"))
        cmd_files.run(app, rest)
    else if (eql(cmd, "exec"))
        cmd_exec.run(app, rest)
    else if (eql(cmd, "debug"))
        cmd_debug.run(app, rest)
    else if (eql(cmd, "__mux"))
        mux_server.run(app, rest)
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
    .{ "x", "exec" },
};

fn commandName(name: []const u8) []const u8 {
    for (command_aliases) |a| if (eql(name, a[0])) return a[1];
    return name;
}

test "short forms" {
    try std.testing.expectEqualStrings("device", commandName("dev"));
    try std.testing.expectEqualStrings("portmap", commandName("pm"));
    try std.testing.expectEqualStrings("proxy", commandName("px"));
    try std.testing.expectEqualStrings("terminal", commandName("term"));
    try std.testing.expectEqualStrings("files", commandName("fs"));
    try std.testing.expectEqualStrings("exec", commandName("x"));
    try std.testing.expectEqualStrings("login", commandName("login"));
    // No prefix matching.
    try std.testing.expectEqualStrings("ter", commandName("ter"));
    try std.testing.expect(isFlag("-j", "--json", "-j"));
    try std.testing.expect(isFlag("--json", "--json", "-j"));
    try std.testing.expect(!isFlag("--js", "--json", "-j"));
}

test {
    // Force discovery of tests in modules only reached by the production dispatcher.
    _ = app_mod;
    _ = @import("target.zig");
    _ = @import("tool_runner.zig");
    _ = @import("mux_client.zig");
    _ = mux_server;
    _ = cmd_login;
    _ = cmd_logout;
    _ = cmd_device;
    _ = cmd_fav;
    _ = cmd_portmap;
    _ = cmd_proxy;
    _ = cmd_session;
    _ = cmd_terminal;
    _ = cmd_exec;
    _ = cmd_files;
    _ = cmd_debug;
    _ = @import("rtc.zig");
    _ = @import("config.zig");
    _ = @import("api.zig");
    _ = @import("login.zig");
    _ = @import("qr.zig");
    _ = @import("wire.zig");
    _ = @import("ws.zig");
    _ = @import("signal.zig");
    _ = @import("session.zig");
    _ = @import("tools/portmap.zig");
    _ = @import("tools/terminal.zig");
    _ = @import("tools/files.zig");
    _ = @import("tty.zig");
    _ = @import("mux.zig");
    _ = @import("lease.zig");
    _ = @import("interrupts.zig");
    _ = @import("e2e_test.zig");
    _ = @import("vectors_test.zig");
}
