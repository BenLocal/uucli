// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");
const api = @import("../api.zig");
const app_mod = @import("../app.zig");
const target_mod = @import("../target.zig");
const App = app_mod.App;
const Exit = app_mod.Exit;
const usage = app_mod.usage;
const eql = app_mod.eql;
const isFlag = app_mod.isFlag;
const signedInClient = app_mod.signedInClient;
const pad = app_mod.pad;
const displayWidth = app_mod.displayWidth;
const fetchDevices = target_mod.fetchDevices;

pub fn run(app: *App, args: []const [:0]const u8) !Exit {
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
