// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const session = @import("../session.zig");
const files = @import("../tools/files.zig");
const app_mod = @import("../app.zig");
const runner = @import("../tool_runner.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const interruptedExit = app_mod.interruptedExit;
const runToolSession = runner.runToolSession;

const FilesCmd = struct {
    pub const stdin_free = true;
    f: files.Files = undefined,
    op: union(enum) {
        ls: struct { path: []const u8, json: bool },
        get: struct { remote: []const u8, local: []const u8 },
        put: struct { local: []const u8, remote: []const u8, force: bool },
    },

    pub fn bind(c: *FilesCmd, io: Io, gpa: Allocator, link: session.Link) void {
        c.f.init(io, gpa, link);
    }
    pub fn unbind(c: *FilesCmd) void {
        c.f.deinit();
    }
    pub fn tool(c: *FilesCmd) session.Tool {
        return c.f.tool();
    }
    pub fn sessionEnded(c: *FilesCmd) void {
        c.f.post(.session_end);
    }
    pub fn interrupted(c: *FilesCmd) void {
        c.f.post(.cancel);
    }
};

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    const usage_files = "expected `files DEVICE ls REMOTE_DIR [--json] | get REMOTE LOCAL [--force] | put LOCAL REMOTE [--force]`";
    var pos: std.ArrayList([]const u8) = .empty;
    var json = false;
    var force = false;
    var assist = false;
    var own_session = false;
    for (args) |a| {
        if (isFlag(a, "--json", "-j")) json = true else if (isFlag(a, "--force", "-f")) force = true else if (eql(a, "--assist")) assist = true else if (eql(a, "--no-mux")) own_session = true else if (a.len > 1 and a[0] == '-') return usage(app, "unknown option {s}", .{a}) else try pos.append(app.arena, a);
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
    return runToolSession(app, .{ .query = p[0], .assist = assist, .own_session = own_session }, 5, FilesCmd, &cmd, filesWorker);
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

test "file hooks are visible to runToolSession" {
    try std.testing.expect(@hasDecl(FilesCmd, "interrupted"));
}
