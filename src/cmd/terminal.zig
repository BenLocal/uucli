// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const session = @import("../session.zig");
const interrupts = @import("../interrupts.zig");
const tty = @import("../tty.zig");
const terminal = @import("../tools/terminal.zig");
const log = std.log.scoped(.uucli);
const app_mod = @import("../app.zig");
const runner = @import("../tool_runner.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const runToolSession = runner.runToolSession;
const terminalError = runner.terminalError;

const TerminalCmd = struct {
    t: terminal.Terminal = undefined,
    mode: union(enum) { attach: u32, list: bool, kill: u32 },
    escape: ?u8,

    pub fn bind(c: *TerminalCmd, io: Io, gpa: Allocator, link: session.Link) void {
        c.t.init(io, gpa, link);
    }
    pub fn unbind(c: *TerminalCmd) void {
        c.t.deinit();
    }
    pub fn tool(c: *TerminalCmd) session.Tool {
        return c.t.tool();
    }
    pub fn sessionEnded(c: *TerminalCmd) void {
        c.t.post(.session_end);
    }
    /// SIGTERM (or SIGINT without raw mode): detach cleanly while the session is still up.
    pub fn interrupted(c: *TerminalCmd) void {
        c.t.post(.input_end);
    }
};

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    var device: ?[]const u8 = null;
    var session_id: ?u32 = null;
    var escape: ?u8 = '~';
    var list = false;
    var json = false;
    var kill: ?u32 = null;
    var assist = false;
    var own_session = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isFlag(a, "--list", "-l")) {
            list = true;
        } else if (eql(a, "--no-mux")) {
            own_session = true;
        } else if (eql(a, "--assist")) {
            assist = true;
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
    return runToolSession(app, .{ .query = query, .assist = assist, .own_session = own_session }, 8, TerminalCmd, &cmd, terminalWorker);
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

test "terminal hooks are visible to runToolSession" {
    try std.testing.expect(@hasDecl(TerminalCmd, "interrupted"));
}
