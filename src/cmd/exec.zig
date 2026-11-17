// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const api = @import("../api.zig");
const session = @import("../session.zig");
const terminal = @import("../tools/terminal.zig");
const app_mod = @import("../app.zig");
const runner = @import("../tool_runner.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const runToolSession = runner.runToolSession;
const terminalError = runner.terminalError;

const ExecCmd = struct {
    /// stdin is not used, so an assistance code may be read from it.
    pub const stdin_free = true;
    t: terminal.Terminal = undefined,
    command: []const u8,
    timeout: ?Io.Duration,
    json: bool,
    shell: terminal.Shell = .posix,
    /// Set once the command's result is in.
    done: std.atomic.Value(bool) = .init(false),

    pub fn completed(c: *ExecCmd) bool {
        return c.done.load(.acquire);
    }
    pub fn device(c: *ExecCmd, d: api.Device) void {
        // The official Windows host runs PowerShell; other hosts run a POSIX shell.
        c.shell = if (d.platform == .windows) .powershell else .posix;
    }
    pub fn bind(c: *ExecCmd, io: Io, gpa: Allocator, link: session.Link) void {
        c.t.init(io, gpa, link);
    }
    pub fn unbind(c: *ExecCmd) void {
        c.t.deinit();
    }
    pub fn tool(c: *ExecCmd) session.Tool {
        return c.t.tool();
    }
    pub fn sessionEnded(c: *ExecCmd) void {
        c.t.post(.session_end);
    }
    pub fn interrupted(c: *ExecCmd) void {
        c.t.post(.input_end);
    }
};

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    const usage_exec = "expected `exec DEVICE [--timeout SECONDS] [--json] [--] COMMAND...`";
    var device: ?[]const u8 = null;
    var timeout_s: u32 = 300;
    var json = false;
    var assist = false;
    var own_session = false;
    var i: usize = 0;
    // Options come before COMMAND; the first other word after DEVICE (or `--`) starts it, so the
    // command can have options of its own.
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--")) {
            i += 1;
            break;
        } else if (isFlag(a, "--json", "-j")) {
            json = true;
        } else if (eql(a, "--assist")) {
            assist = true;
        } else if (eql(a, "--no-mux")) {
            own_session = true;
        } else if (isFlag(a, "--timeout", "-t")) {
            i += 1;
            if (i == args.len) return usage(app, "{s} needs a number of seconds", .{a});
            timeout_s = std.fmt.parseInt(u32, args[i], 10) catch return usage(app, "invalid timeout {s}", .{args[i]});
        } else if (a.len > 1 and a[0] == '-' and device == null) {
            return usage(app, "unknown option {s}", .{a});
        } else if (device == null) {
            device = a;
        } else break;
    }
    const query = device orelse return usage(app, usage_exec, .{});
    if (i == args.len) return usage(app, usage_exec, .{});
    var command: std.ArrayList(u8) = .empty;
    for (args[i..], 0..) |w, n| {
        if (n != 0) try command.append(app.arena, ' ');
        try command.appendSlice(app.arena, w);
    }
    if (command.items.len > terminal.max_exec_command) return usage(app, "COMMAND is longer than {d} bytes", .{terminal.max_exec_command});
    var cmd: ExecCmd = .{
        .command = command.items,
        .timeout = if (timeout_s == 0) null else .fromSeconds(timeout_s),
        .json = json,
    };
    return runToolSession(app, .{ .query = query, .assist = assist, .own_session = own_session }, 8, ExecCmd, &cmd, execWorker);
}

fn execWorker(app: *App, cmd: *ExecCmd) Exit {
    const t = &cmd.t;
    var group: Io.Group = .init;
    defer group.cancel(app.io);
    group.concurrent(app.io, terminal.Terminal.ticker, .{t}) catch return app.fail(.other, "cannot start the terminal", .{});
    t.checkEnv() catch |err| return switch (err) {
        error.Rejected => app.fail(.remote, "the terminal environment is unavailable on the device", .{}),
        else => terminalError(app, err),
    };
    // Wide, so the shell rarely wraps output lines.
    const id = t.open(app.arena, 0, 200, 50) catch |err| return terminalError(app, err);
    defer {
        // The PowerShell line does not exit (spec §11.1.1), and on a shared session CLOSE only
        // detaches: end the shell, or every exec would leave one running on the host.
        t.write(id, "exit\r") catch {};
        t.close(id);
    }
    var nonce_raw: [8]u8 = undefined;
    app.io.random(&nonce_raw);
    const nonce = std.fmt.bytesToHex(nonce_raw, .lower);
    const line = terminal.execLine(app.arena, cmd.shell, &nonce, cmd.command) catch return app.fail(.other, "out of memory", .{});
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app.gpa);
    const r = t.exec(id, line, &nonce, cmd.timeout, &text) catch |err| return terminalError(app, err);
    cmd.done.store(true, .release);
    if (cmd.json) {
        std.json.Stringify.value(.{ .exit_code = r.code, .output = r.output }, .{}, app.out) catch {};
        app.out.writeByte('\n') catch {};
    } else app.out.writeAll(r.output) catch {};
    // Statuses outside 0..255 (Windows NTSTATUS values, negative numbers) become 1.
    return if (r.code >= 0 and r.code <= 255) @fromBackingInt(@intCast(r.code)) else .other;
}

test "exec hooks are visible to runToolSession" {
    try std.testing.expect(@hasDecl(ExecCmd, "interrupted"));
    try std.testing.expect(@hasDecl(ExecCmd, "completed"));
    try std.testing.expect(@hasDecl(ExecCmd, "device"));
}
