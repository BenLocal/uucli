// SPDX-License-Identifier: GPL-3.0-or-later
//! Starts the shared background connection and connects local stream and lease clients.
const std = @import("std");
const Io = std.Io;
const session = @import("session.zig");
const interrupts = @import("interrupts.zig");
const mux = @import("mux.zig");
const portmap = @import("tools/portmap.zig");
const log = std.log.scoped(.uucli);
const app_mod = @import("app.zig");
const target_mod = @import("target.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const interruptedExit = app_mod.interruptedExit;
const DeviceArg = target_mod.DeviceArg;

/// Unix sockets exist, and `UUCLI_MUX` is not 0/false/no/off.
pub fn muxEnabled(app: *App) bool {
    if (!Io.net.has_unix_sockets) return false;
    const v = app.env.get("UUCLI_MUX") orelse return true;
    const t = std.mem.trim(u8, v, " ");
    for ([_][]const u8{ "0", "false", "no", "off" }) |no| if (std.ascii.eqlIgnoreCase(t, no)) return false;
    return true;
}

/// `proxy` through the shared session of DEVICE, starting it when needed. Null: not possible here
/// (socket path too long), connect directly instead.
pub fn proxyViaMux(app: *App, dev: DeviceArg, assist_code: ?[]const u8, host: []const u8, port: u16) !?Exit {
    const cfg_path = try app.configPath();
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = mux.path(&sock_buf, cfg_path, dev.assist, dev.query, .sock) catch {
        log.info("config path too long for a shared session; connecting directly", .{});
        return null;
    };
    // A server can go away between connect and reply (idle exit, session lost): start a new one.
    for (0..3) |_| switch (try muxOpen(app.io, sock, host, port)) {
        .conn => |conn| {
            defer conn.close(app.io);
            return try relayProxy(app, conn);
        },
        .refused => |reply| return muxRefused(app, reply),
        .gone => if (try startMuxServer(app, cfg_path, dev, sock, assist_code)) |code| return code,
    };
    return app.fail(.connect, "the shared session did not take the connection", .{});
}

fn relayProxy(app: *App, conn: Io.net.Stream) !Exit {
    const io = app.io;
    var bus_buf: [16]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);

    const Result = union(enum) { interrupt: Io.Cancelable!void, relay: anyerror!void };
    var results: [2]Result = undefined;
    var race: Io.Select(Result) = .init(io, &results);
    defer race.cancelDiscard();
    try race.concurrent(.interrupt, waitForInterrupt, .{&bus});
    try race.concurrent(.relay, muxRelay, .{ io, conn, .stdio });
    switch (try race.await()) {
        .interrupt => |result| try result,
        .relay => |result| {
            if (interrupts.last() == null) {
                result catch |err| switch (err) {
                    error.WriteFailed => return app.fail(.other, "cannot write stdout", .{}),
                    else => return err,
                };
                return .ok;
            }
        },
    }
    return interruptedExit();
}

fn waitForInterrupt(bus: *session.Bus) Io.Cancelable!void {
    while (true) {
        const event = try bus.next();
        defer event.deinit();
        if (event == .interrupt) return;
    }
}

const MuxOpen = union(enum) {
    /// `OK` received: the stream's bytes follow.
    conn: Io.net.Stream,
    /// No server, or it closed before answering.
    gone,
    refused: mux.Reply,
};

/// Asks the shared session at `sock` for a stream to HOST:PORT.
fn muxOpen(io: Io, sock: []const u8, host: []const u8, port: u16) !MuxOpen {
    const addr = try Io.net.UnixAddress.init(sock);
    const conn = addr.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return .gone,
        else => |e| return e,
    };
    var keep = false;
    defer if (!keep) conn.close(io);
    {
        var wb: [portmap.max_mux_request]u8 = undefined;
        var w = conn.writer(io, &wb);
        w.interface.print("{s} {d}\n", .{ host, port }) catch return .gone;
        w.interface.flush() catch return .gone;
    }
    var line: [32]u8 = undefined;
    var n: usize = 0;
    {
        // Unbuffered: the stream's bytes follow the reply line.
        var one: [1]u8 = undefined;
        var r = conn.reader(io, &one);
        while (true) {
            const b = r.interface.takeByte() catch return .gone;
            if (b == '\n') break;
            if (n == line.len) return .{ .refused = .failed };
            line[n] = b;
            n += 1;
        }
    }
    const reply = mux.parseReply(line[0..n]);
    if (reply != .ok) return .{ .refused = reply };
    keep = true;
    return .{ .conn = conn };
}

fn muxRefused(app: *App, reply: mux.Reply) Exit {
    return switch (reply) {
        .ok => unreachable,
        .rejected => app.fail(.remote, "the device refused the connection to the target", .{}),
        .timeout => app.fail(.connect, "the device did not answer the connection request", .{}),
        .failed => app.fail(.connect, "the shared session could not open the stream", .{}),
    };
}

/// The local side of a shared-session stream.
const MuxLocal = union(enum) { stdio, tcp: Io.net.Stream };

/// Copies bytes between `local` and the shared-session stream `conn` until the stream ends. The
/// end of local input half-closes the stream, so the target's remaining output still arrives.
fn muxRelay(io: Io, conn: Io.net.Stream, local: MuxLocal) !void {
    const U = union(enum) { up: void, down: Io.Writer.Error!void };
    var buf: [2]U = undefined;
    var sel: Io.Select(U) = .init(io, &buf);
    defer sel.cancelDiscard();
    try sel.concurrent(.up, muxUp, .{ io, conn, local });
    try sel.concurrent(.down, muxDown, .{ io, conn, local });
    while (true) switch (try sel.await()) {
        .up => conn.shutdown(io, .send) catch {},
        .down => |result| {
            // Wake the other direction if it still waits for local input.
            if (local == .tcp) local.tcp.shutdown(io, .recv) catch {};
            return result;
        },
    };
}

fn muxUp(io: Io, conn: Io.net.Stream, local: MuxLocal) void {
    var rb: [16 * 1024]u8 = undefined;
    var wb: [64]u8 = undefined;
    var w = conn.writer(io, &wb);
    switch (local) {
        .stdio => {
            var r = Io.File.stdin().readerStreaming(io, &rb);
            copyAll(&r.interface, &w.interface) catch {};
        },
        .tcp => |t| {
            var r = t.reader(io, &rb);
            copyAll(&r.interface, &w.interface) catch {};
        },
    }
}

fn muxDown(io: Io, conn: Io.net.Stream, local: MuxLocal) Io.Writer.Error!void {
    var rb: [16 * 1024]u8 = undefined;
    var r = conn.reader(io, &rb);
    var wb: [64]u8 = undefined;
    switch (local) {
        .stdio => {
            var w = Io.File.stdout().writerStreaming(io, &wb);
            try copyAll(&r.interface, &w.interface);
        },
        .tcp => |t| {
            var w = t.writer(io, &wb);
            copyAll(&r.interface, &w.interface) catch {};
        },
    }
}

/// Copies until end of input or an error on either side, flushing each chunk.
fn copyAll(r: *Io.Reader, w: *Io.Writer) Io.Writer.Error!void {
    while (true) {
        const data = r.peekGreedy(1) catch return;
        try w.writeAll(data);
        try w.flush();
        r.toss(data.len);
    }
}

/// `portmap` through the shared session of DEVICE: each accepted connection asks the session for
/// a stream (spec §7.2), starting the server when needed. Runs until SIGINT/SIGTERM.
pub fn portmapViaMux(app: *App, dev: DeviceArg, code: ?[]const u8, pm: *portmap.PortMap) !?Exit {
    const io = app.io;
    const cfg_path = try app.configPath();
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = mux.path(&sock_buf, cfg_path, dev.assist, dev.query, .sock) catch {
        log.info("config path too long for a shared session; connecting directly", .{});
        return null;
    };
    var ctx: MuxForwards = .{ .app = app, .cfg_path = cfg_path, .dev = dev, .code = code, .sock = sock };
    var bus_buf: [16]session.Event = undefined;
    var bus: session.Bus = undefined;
    try bus.init(io, &bus_buf);
    defer bus.deinit();
    try interrupts.install(&bus);
    var accepts: Io.Group = .init;
    defer accepts.cancel(io);
    for (pm.rules) |*r| try accepts.concurrent(io, MuxForwards.acceptTask, .{ &ctx, r.server.?, r.rule });
    while (true) {
        const e = try bus.next();
        defer e.deinit();
        if (e == .interrupt or e == .stop) break;
    }
    accepts.cancel(io);
    ctx.conns.cancel(io);
    return interruptedExit();
}

const MuxForwards = struct {
    app: *App,
    cfg_path: []const u8,
    dev: DeviceArg,
    code: ?[]const u8,
    sock: []const u8,
    /// One server start at a time, and stderr is not shared between tasks.
    mutex: Io.Mutex = .init,
    conns: Io.Group = .init,

    fn acceptTask(ctx: *MuxForwards, server: Io.net.Server, rule: portmap.Rule) Io.Cancelable!void {
        const io = ctx.app.io;
        var srv = server;
        while (true) {
            const conn = srv.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    log.warn("accept failed: {t}", .{err});
                    try io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            ctx.conns.concurrent(io, forwardTask, .{ ctx, conn, rule }) catch conn.close(io);
        }
    }

    fn forwardTask(ctx: *MuxForwards, local: Io.net.Stream, rule: portmap.Rule) Io.Cancelable!void {
        const io = ctx.app.io;
        defer local.close(io);
        for (0..3) |_| {
            const opened = muxOpen(io, ctx.sock, rule.host, rule.port) catch |err| {
                log.warn("shared session unreachable: {t}", .{err});
                return;
            };
            switch (opened) {
                .conn => |conn| {
                    defer conn.close(io);
                    muxRelay(io, conn, .{ .tcp = local }) catch |err| switch (err) {
                        error.Canceled => |e| return e,
                        else => log.warn("forwarding failed: {t}", .{err}),
                    };
                    return;
                },
                .refused => |reply| {
                    log.warn("connection to port {d} not forwarded: {t}", .{ rule.port, reply });
                    return;
                },
                .gone => {
                    try ctx.mutex.lock(io);
                    defer ctx.mutex.unlock(io);
                    const failed = startMuxServer(ctx.app, ctx.cfg_path, ctx.dev, ctx.sock, ctx.code) catch |err| {
                        log.warn("cannot start the shared session: {t}", .{err});
                        return;
                    };
                    ctx.app.err.flush() catch {};
                    if (failed != null) return;
                },
            }
        }
        log.warn("the shared session did not take the connection", .{});
    }
};

/// Starts the shared-session server of `dev` (`uucli __mux`) in its own process group, so that
/// killing the ssh ProxyCommand does not end it, and waits until it is ready. Null: ready (or
/// another client started one meanwhile); else the exit code, with the server's messages relayed.
/// `code`: an assistance code the server cannot find itself (asked for on the terminal).
pub fn startMuxServer(app: *App, cfg_path: []const u8, dev: DeviceArg, sock: []const u8, code: ?[]const u8) !?Exit {
    const io = app.io;
    const cwd = Io.Dir.cwd();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try cwd.createDirPathStatus(io, try mux.dir(&dir_buf, cfg_path), .fromMode(0o700));
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try cwd.createFile(io, try mux.path(&lock_buf, cfg_path, dev.assist, dev.query, .lock), .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io);
    if ((try Io.net.UnixAddress.init(sock)).connect(io)) |c| {
        c.close(io);
        return null;
    } else |_| {}
    // A server that died without cleaning up leaves its socket file behind.
    cwd.deleteFile(io, sock) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try mux.path(&log_buf, cfg_path, dev.assist, dev.query, .log);
    const log_file = try cwd.createFile(io, log_path, .{ .permissions = .fromMode(0o600) });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, try std.process.executablePathAlloc(io, app.arena));
    switch (app_mod.log_level) {
        .info => try argv.append(app.arena, "-v"),
        .debug => try argv.append(app.arena, "-vv"),
        else => {},
    }
    try argv.append(app.arena, "__mux");
    if (dev.assist) try argv.append(app.arena, "--assist");
    try argv.append(app.arena, dev.query);
    var env: ?std.process.Environ.Map = null;
    if (code != null or dev.name.len != 0) {
        env = try app.env.clone(app.arena);
        if (code) |c| try env.?.put("UUCLI_ASSIST_CODE", c);
        if (dev.name.len != 0) try env.?.put("UUCLI_MUX_NAME", dev.name);
    }
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = if (env) |*m| m else null,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = log_file },
        .pgid = 0,
    }) catch |err| {
        log_file.close(io);
        return app.fail(.other, "cannot start the shared session: {t}", .{err});
    };
    log_file.close(io);
    const ready = blk: {
        var rb: [16]u8 = undefined;
        var r = child.stdout.?.readerStreaming(io, &rb);
        const line = r.interface.takeDelimiterExclusive('\n') catch break :blk false;
        break :blk std.mem.eql(u8, line, "ready");
    };
    child.stdout.?.close(io);
    child.stdout = null;
    if (ready) return null;
    const term = child.wait(io) catch |err| return app.fail(.connect, "the shared session failed: {t}", .{err});
    const text = cwd.readFileAlloc(io, log_path, app.arena, .limited(64 * 1024)) catch "";
    app.err.writeAll(text) catch {};
    return switch (term) {
        .exited => |c| if (c == 0) app.fail(.connect, "the shared session ended before it was ready", .{}) else @fromBackingInt(c),
        else => app.fail(.connect, "the shared session stopped: {f}", .{term}),
    };
}

pub const MuxLease = struct { conn: Io.net.Stream, platform: i64 };

/// Asks the shared session at `sock` for a lease; waits while another client holds it. `gone`: no
/// server, or it closed before answering.
pub fn muxLease(io: Io, sock: []const u8) !union(enum) { granted: MuxLease, gone, unsupported } {
    const conn = (try Io.net.UnixAddress.init(sock)).connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return .gone,
        else => |e| return e,
    };
    var keep = false;
    defer if (!keep) conn.close(io);
    {
        var wb: [16]u8 = undefined;
        var w = conn.writer(io, &wb);
        w.interface.writeAll("LEASE\n") catch return .gone;
        w.interface.flush() catch return .gone;
    }
    var line: [32]u8 = undefined;
    var n: usize = 0;
    {
        // Unbuffered: frames follow the reply line.
        var one: [1]u8 = undefined;
        var r = conn.reader(io, &one);
        while (true) {
            const b = r.interface.takeByte() catch return .gone;
            if (b == '\n') break;
            if (n == line.len) return error.InvalidReply;
            line[n] = b;
            n += 1;
        }
    }
    if (std.mem.startsWith(u8, line[0..n], "ERR ")) return .unsupported;
    if (!std.mem.startsWith(u8, line[0..n], "OK ")) return error.InvalidReply;
    const platform = std.fmt.parseInt(i64, line[3..n], 10) catch return error.InvalidReply;
    keep = true;
    return .{ .granted = .{ .conn = conn, .platform = platform } };
}
