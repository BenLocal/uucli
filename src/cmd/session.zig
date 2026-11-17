// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");
const api = @import("../api.zig");
const mux = @import("../mux.zig");
const portmap = @import("../tools/portmap.zig");
const app_mod = @import("../app.zig");
const target_mod = @import("../target.zig");
const mux_client = @import("../mux_client.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const signedInClient = app_mod.signedInClient;
const sharedDevice = target_mod.sharedDevice;
const resolveTarget = target_mod.resolveTarget;
const startMuxServer = mux_client.startMuxServer;

/// Management never starts a server except for an explicit `session start`.
fn sessionRequest(app: *App, sock: []const u8, request: []const u8) !?[]const u8 {
    const conn = (try Io.net.UnixAddress.init(sock)).connect(app.io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return null,
        else => return err,
    };
    defer conn.close(app.io);
    var wb: [64]u8 = undefined;
    var w = conn.writer(app.io, &wb);
    try w.interface.print("{s}\n", .{request});
    try w.interface.flush();
    var line: [4096]u8 = undefined;
    const reply = try portmap.PortMap.readLineTimed(app.io, conn, &line);
    return try app.arena.dupe(u8, reply);
}

const LocalSession = struct { sock: []const u8, status: mux.Status };

const SessionInfo = struct {
    device: []const u8,
    name: []const u8,
    assist: bool,
    pinned: bool,
    streams: u32,
    active: u32,
    waiting: u32,

    fn from(s: mux.Status) SessionInfo {
        return .{ .device = s.device, .name = s.name, .assist = s.assist, .pinned = s.pinned, .streams = s.streams, .active = s.active, .waiting = s.waiting };
    }
};

fn localSessions(app: *App, cfg_path: []const u8) ![]LocalSession {
    var found: std.ArrayList(LocalSession) = .empty;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try mux.dir(&dir_buf, cfg_path);
    var dir = Io.Dir.cwd().openDir(app.io, base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |entry| {
        if (entry.kind != .unix_domain_socket or !std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const sock = try std.fs.path.join(app.arena, &.{ base, entry.name });
        const reply = sessionRequest(app, sock, "STATUS") catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => continue,
        } orelse continue;
        const status = std.json.parseFromSliceLeaky(mux.Status, app.arena, reply, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (status.scope == mux.scope(cfg_path)) try found.append(app.arena, .{ .sock = sock, .status = status });
    }
    return found.toOwnedSlice(app.arena);
}

fn printSession(app: *App, s: mux.Status) !void {
    try app.out.print("{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
        s.device, s.name, if (s.assist) "yes" else "no", if (s.pinned) "kept" else "auto", s.streams, s.active, s.waiting,
    });
}

fn findLocalSession(app: *App, sessions: []const LocalSession, query: []const u8, assist: bool) !?LocalSession {
    var match: ?LocalSession = null;
    // Exact ids take precedence over names, as with device resolution.
    for (sessions) |s| {
        if ((!assist or s.status.assist) and eql(query, s.status.device)) {
            if (match != null) {
                _ = usage(app, "session is ambiguous; use --assist or session list", .{});
                return error.ReportedUsage;
            }
            match = s;
        }
    }
    if (match == null and !assist) for (sessions) |s| {
        if (s.status.name.len != 0 and std.ascii.eqlIgnoreCase(query, s.status.name)) {
            if (match != null) {
                _ = usage(app, "session name is ambiguous; use an id", .{});
                return error.ReportedUsage;
            }
            match = s;
        }
    };
    return match;
}

fn keepSession(app: *App, sock: []const u8) !Exit {
    const reply = (try sessionRequest(app, sock, "KEEPALIVE")) orelse
        return app.fail(.connect, "the shared session ended before it could be kept", .{});
    const status = std.json.parseFromSliceLeaky(mux.Status, app.arena, reply, .{}) catch
        return app.fail(.connect, "the shared session cannot be managed; stop the old background process and retry", .{});
    if (!status.pinned) return app.fail(.connect, "the shared session was not kept", .{});
    try app.err.print("Keeping session for {s}\n", .{status.device});
    return .ok;
}

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    if (args.len == 0) return usage(app, "expected session start|list|status|stop", .{});
    const action = args[0];
    const list = eql(action, "list") or eql(action, "ls");
    const start = eql(action, "start");
    const stop = eql(action, "stop");
    if (!list and !start and !stop and !eql(action, "status")) return usage(app, "unknown session command {s}", .{action});
    var query: ?[]const u8 = null;
    var json = false;
    var force = false;
    var assist = false;
    for (args[1..]) |a| {
        if (isFlag(a, "--json", "-j")) json = true else if (isFlag(a, "--force", "-f")) force = true else if (eql(a, "--assist")) assist = true else if (a.len > 0 and a[0] == '-') return usage(app, "unknown option {s}", .{a}) else if (query == null) query = a else return usage(app, "unexpected argument {s}", .{a});
    }
    if ((list and (query != null or assist)) or (!list and query == null) or
        (force and !stop) or (json and (start or stop)))
        return usage(app, "expected session start DEVICE | list [-j] | status DEVICE [-j] | stop DEVICE [-f]", .{});
    const cfg_path = try app.configPath();
    const sessions = try localSessions(app, cfg_path);
    const existing = if (list) null else try findLocalSession(app, sessions, query.?, assist);
    if (start) {
        if (existing) |s| return keepSession(app, s.sock);
        var cfg: config.Config = undefined;
        var client: api.Client = undefined;
        try signedInClient(app, &client, &cfg);
        defer client.deinit();
        const target = try resolveTarget(app, &client, &cfg, .{ .query = query.?, .assist = assist }, true);
        const dev = sharedDevice(target);
        var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sock = mux.path(&sock_buf, cfg_path, dev.assist, dev.query, .sock) catch
            return app.fail(.other, "the config path is too long for a shared session", .{});
        if (try startMuxServer(app, cfg_path, dev, sock, target.assist_code)) |code| return code;
        return keepSession(app, sock);
    }
    if (list) {
        if (json) {
            var statuses: std.ArrayList(SessionInfo) = .empty;
            for (sessions) |s| try statuses.append(app.arena, .from(s.status));
            try std.json.Stringify.value(statuses.items, .{}, app.out);
            try app.out.writeByte('\n');
        } else {
            try app.out.writeAll("DEVICE\tNAME\tASSIST\tMODE\tSTREAMS\tACTIVE\tWAITING\n");
            for (sessions) |s| try printSession(app, s.status);
        }
        return .ok;
    }
    const selected = existing orelse {
        if (stop) return .ok;
        return app.fail(.no_device, "no local session for {s}", .{query.?});
    };
    if (!stop) {
        if (json) {
            try std.json.Stringify.value(SessionInfo.from(selected.status), .{}, app.out);
            try app.out.writeByte('\n');
        } else {
            try app.out.writeAll("DEVICE\tNAME\tASSIST\tMODE\tSTREAMS\tACTIVE\tWAITING\n");
            try printSession(app, selected.status);
        }
        return .ok;
    }
    const reply = (try sessionRequest(app, selected.sock, if (force) "STOP FORCE" else "STOP")) orelse return .ok;
    if (eql(reply, "ERR busy")) return app.fail(.remote, "session is in use; use --force to interrupt its users", .{});
    if (!eql(reply, "OK")) return app.fail(.connect, "the shared session did not accept the stop request", .{});
    // Wait until teardown removes the listener, so a subsequent start cannot reuse it.
    for (0..100) |_| {
        const conn = (try Io.net.UnixAddress.init(selected.sock)).connect(app.io) catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused => {
                try app.err.print("Stopped session for {s}\n", .{selected.status.device});
                return .ok;
            },
            else => return err,
        };
        conn.close(app.io);
        try app.io.sleep(.fromMilliseconds(50), .awake);
    }
    return app.fail(.connect, "the shared session is still stopping", .{});
}

test "session commands use live local status, isolate configs and ignore stale sockets" {
    const t = std.testing;
    const io = t.io;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cfg_path = try std.fs.path.join(a, &.{ base, "config.json" });
    const mux_dir = try std.fs.path.join(a, &.{ base, "mux" });
    try Io.Dir.cwd().createDirPath(io, mux_dir);
    const sock = try std.fs.path.join(a, &.{ mux_dir, "live.sock" });
    const other_sock = try std.fs.path.join(a, &.{ mux_dir, "other.sock" });
    const stale = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ mux_dir, "stale.sock" }), .{});
    stale.close(io);
    var server = try (try Io.net.UnixAddress.init(sock)).listen(io, .{});
    defer server.deinit(io);
    var dead = try (try Io.net.UnixAddress.init(try std.fs.path.join(a, &.{ mux_dir, "dead.sock" }))).listen(io, .{});
    dead.deinit(io);
    var other = try (try Io.net.UnixAddress.init(other_sock)).listen(io, .{});
    defer other.deinit(io);
    const Fake = struct {
        fn serve(srv: *Io.net.Server, socket: []const u8, config_scope: u64) Io.Cancelable!void {
            while (true) {
                const conn = srv.accept(t.io) catch |e| switch (e) {
                    error.Canceled => return error.Canceled,
                    else => return,
                };
                defer conn.close(t.io);
                var line: [128]u8 = undefined;
                const request = portmap.PortMap.readLineTimed(t.io, conn, &line) catch continue;
                var wb: [1024]u8 = undefined;
                var w = conn.writer(t.io, &wb);
                if (eql(request, "STOP")) {
                    w.interface.writeAll("ERR busy\n") catch continue;
                } else if (eql(request, "STOP FORCE")) {
                    Io.Dir.cwd().deleteFile(t.io, socket) catch {};
                    w.interface.writeAll("OK\n") catch return;
                    w.interface.flush() catch {};
                    return;
                } else {
                    const status: mux.Status = .{
                        .device = "host-1",
                        .name = "office-pc",
                        .assist = false,
                        .scope = config_scope,
                        .pinned = true,
                        .streams = 2,
                        .active = 1,
                        .waiting = 3,
                    };
                    std.json.Stringify.value(status, .{}, &w.interface) catch continue;
                    w.interface.writeByte('\n') catch continue;
                }
                w.interface.flush() catch {};
            }
        }
    };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fake.serve, .{ &server, sock, mux.scope(cfg_path) });
    try group.concurrent(io, Fake.serve, .{ &other, other_sock, mux.scope("other-config.json") });
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("UUCLI_CONFIG", cfg_path);
    try env.put("UUCLI_MUX", "0");
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    var app: App = .{ .io = io, .gpa = t.allocator, .arena = a, .env = &env, .out = &out.writer, .err = &err.writer };
    try t.expectEqual(Exit.ok, try run(&app, &.{ "list", "-j" }));
    const statuses = try std.json.parseFromSliceLeaky([]SessionInfo, a, out.written(), .{});
    try t.expectEqual(@as(usize, 1), statuses.len);
    try t.expectEqualStrings("host-1", statuses[0].device);
    out.clearRetainingCapacity();
    try t.expectEqual(Exit.ok, try run(&app, &.{ "status", "OFFICE-PC", "-j" }));
    const status = try std.json.parseFromSliceLeaky(SessionInfo, a, out.written(), .{});
    try t.expectEqual(@as(u32, 2), status.streams);
    try t.expectEqual(@as(u32, 3), status.waiting);
    try t.expectEqual(Exit.ok, try run(&app, &.{ "start", "office-pc" }));
    try t.expectEqual(Exit.ok, try run(&app, &.{ "start", "host-1" }));
    try t.expectEqual(Exit.no_device, try run(&app, &.{ "status", "missing" }));
    try t.expectEqual(Exit.remote, try run(&app, &.{ "stop", "host-1" }));
    try t.expectEqual(Exit.ok, try run(&app, &.{ "stop", "host-1", "--force" }));
    try t.expectEqual(Exit.ok, try run(&app, &.{ "stop", "host-1" }));
    out.clearRetainingCapacity();
    try t.expectEqual(Exit.ok, try run(&app, &.{ "ls", "-j" }));
    try t.expectEqualStrings("[]\n", out.written());
    for ([_][]const [:0]const u8{
        &.{},                                &.{ "list", "device" },        &.{"start"},
        &.{ "status", "host-1", "--force" }, &.{ "start", "host-1", "-j" },
    }) |args| try t.expectEqual(Exit.usage, try run(&app, args));
}
