// SPDX-License-Identifier: GPL-3.0-or-later
//! Device and favorite resolution, assistance code input and saved-code updates.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const api = @import("api.zig");
const login = @import("login.zig");
const tty = @import("tty.zig");
const mux = @import("mux.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

/// DEVICE as given: a device id or name (account devices, then favorites), or with `--assist` a
/// remote-assistance share id.
pub const DeviceArg = struct {
    query: []const u8,
    assist: bool = false,
    /// `--no-mux`: open a session of its own instead of using the shared one (spec §7.2, §7.3).
    own_session: bool = false,
    name: []const u8 = "",
};

/// Where a session goes: an account device or a remote-assistance share ID.
pub const Target = struct {
    id: []const u8,
    assist: bool = false,
    assist_code: ?[]const u8 = null,
    /// Set for account devices.
    device: ?api.Device = null,
    name: []const u8 = "",
};

pub fn sharedDevice(target: Target) DeviceArg {
    return .{ .query = target.id, .assist = target.assist, .name = target.name };
}

/// DEVICE → target (spec §3.3); exit 2 when ambiguous, 4 when unknown or offline. `stdin_free`:
/// the tool does not read stdin, so a code may be read from it when it is not a terminal.
pub fn resolveTarget(app: *App, client: *api.Client, cfg: *const config.Config, dev: DeviceArg, stdin_free: bool) !Target {
    var target = try resolveIdentity(app, client, cfg, dev);
    if (target.assist) target.assist_code = try assistCode(app, cfg, target.id, stdin_free);
    return target;
}

/// Resolve the device before deciding whether a new room join needs credentials.
pub fn resolveIdentity(app: *App, client: *api.Client, cfg: *const config.Config, dev: DeviceArg) !Target {
    if (dev.assist) return .{ .id = dev.query, .assist = true };
    const devices = try fetchDevices(app, client, cfg);
    switch (try api.resolveDevice(app.arena, devices, dev.query)) {
        .found => |d| {
            if (!d.online) {
                _ = app.fail(.no_device, "device {s} ({s}) is offline", .{ d.name, d.id });
                return error.ReportedNoDevice;
            }
            return .{ .id = d.id, .device = d, .name = d.name };
        },
        .not_found => {},
        .ambiguous => |list| {
            app.err.print("device name {s} is ambiguous; use an id:\n", .{dev.query}) catch {};
            for (list) |d| app.err.print("  {s}  {s}\n", .{ d.id, d.name }) catch {};
            return error.ReportedUsage;
        },
    }
    const saved = try fetchSaved(app, client, .favorites);
    switch (try api.resolveSaved(app.arena, saved, dev.query)) {
        .found => |f| return .{ .id = f.id, .assist = true, .name = f.name },
        .not_found => {
            _ = app.fail(.no_device, "no device {s}: see `uucli device list` and `uucli fav list`", .{dev.query});
            return error.ReportedNoDevice;
        },
        .ambiguous => |list| {
            app.err.print("favorite name {s} is ambiguous; use an id:\n", .{dev.query}) catch {};
            for (list) |f| app.err.print("  {s}  {s}\n", .{ f.id, f.name }) catch {};
            return error.ReportedUsage;
        },
    }
}

/// The code for share `id`: UUCLI_ASSIST_CODE, else the saved one, else asked for.
pub fn assistCode(app: *App, cfg: *const config.Config, id: []const u8, stdin_free: bool) ![]const u8 {
    if (app.env.get("UUCLI_ASSIST_CODE")) |c| if (c.len != 0) return c;
    if (cfg.assistCode(id)) |c| return c;
    return readCode(app, id, stdin_free);
}

/// Reads a code: prompted without echo on a terminal, else one line of stdin when the tool leaves
/// stdin alone. Never taken from the command line, where other users could see it.
pub fn readCode(app: *App, id: []const u8, stdin_free: bool) ![]const u8 {
    const is_tty = Io.File.stdin().isTty(app.io) catch false;
    if (!is_tty and !stdin_free) {
        _ = app.fail(.usage, "no code for {s}: set UUCLI_ASSIST_CODE or save one with `uucli fav add {s} --save-code`", .{ id, id });
        return error.ReportedUsage;
    }
    var echo: ?tty.Raw = null;
    if (is_tty) {
        try app.err.print("Code for {s}: ", .{id});
        try app.err.flush();
        echo = tty.Raw.noEcho(0) catch null;
    }
    // One byte at a time: nothing after the line is consumed.
    var buf: [1]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(app.io, &buf);
    var line: std.ArrayList(u8) = .empty;
    while (r.interface.takeByte()) |b| {
        if (b == '\n') break;
        if (line.items.len == 1024) break;
        try line.append(app.arena, b);
    } else |_| {}
    if (echo) |e| {
        e.restore();
        app.err.writeByte('\n') catch {};
    }
    const code = std.mem.trimEnd(u8, line.items, "\r");
    for (code) |b| if (b < 0x20 or b == 0x7f) {
        _ = app.fail(.usage, "invalid code", .{});
        return error.ReportedUsage;
    };
    if (std.mem.trim(u8, code, " ").len == 0) {
        _ = app.fail(.usage, "no code given", .{});
        return error.ReportedUsage;
    }
    return code;
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

/// Saved remote-assistance hosts of the account (spec §5.5).
pub fn fetchSaved(app: *App, client: *api.Client, kind: api.SavedKind) ![]api.Saved {
    return api.listSaved(client, app.arena, kind) catch |err| switch (err) {
        error.NotSignedIn, error.OutOfMemory, error.Canceled => |e| return e,
        error.ApiError, error.Network, error.Timeout, error.BadResponse => {
            login.reportCallError(app.err, "favorites", client, err);
            return error.Reported;
        },
        else => |e| return e,
    };
}

/// Stores (or with null forgets) the code of share `id`, under the config lock.
pub fn updateSavedCode(app: *App, id: []const u8, code: ?[]const u8) !void {
    const path = try app.configPath();
    const l = try config.lock(app.io, path, .identity);
    defer l.release(app.io);
    var cfg = try app.loadConfig(path);
    try cfg.setAssistCode(app.arena, id, code);
    try config.save(app.io, path, cfg);
}

test "shared connection identity uses resolved ids and assistance mode" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const devices = [_]api.Device{.{ .id = "host-1", .name = "office-pc", .platform = .windows, .online = true, .shared = false }};
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    for ([_][]const u8{ "office-pc", "OFFICE-PC", "host-1" }) |query| {
        const resolved = try api.resolveDevice(arena.allocator(), &devices, query);
        const d = resolved.found;
        const dev = sharedDevice(.{ .id = d.id, .name = d.name, .device = d });
        try t.expectEqualStrings(try mux.path(&first, "config.json", false, "host-1", .sock), try mux.path(&second, "config.json", dev.assist, dev.query, .sock));
    }
    const favorite = sharedDevice(.{ .id = "123456789", .name = "office-pc", .assist = true });
    try t.expectEqualStrings(try mux.path(&first, "config.json", true, "123456789", .sock), try mux.path(&second, "config.json", favorite.assist, favorite.query, .sock));
}
