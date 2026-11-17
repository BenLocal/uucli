// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");
const api = @import("../api.zig");
const login = @import("../login.zig");
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
const fetchSaved = target_mod.fetchSaved;
const readCode = target_mod.readCode;
const updateSavedCode = target_mod.updateSavedCode;

/// Remote-assistance favorites, stored on the account like the official apps' (spec §5.5).
pub fn run(app: *App, args: []const [:0]const u8) !Exit {
    const usage_fav = "expected `fav list [--recent] [--json] | add ID [NAME] [--save-code] | edit NAME|ID [NEW_NAME] [--save-code] | rm|remove NAME|ID`";
    if (args.len == 0) return usage(app, usage_fav, .{});
    const sub = args[0];
    var pos: std.ArrayList([]const u8) = .empty;
    var json = false;
    var recent = false;
    var save_code = false;
    for (args[1..]) |a| {
        if (isFlag(a, "--json", "-j")) json = true else if (eql(a, "--recent")) recent = true else if (eql(a, "--save-code")) save_code = true else if (a.len > 1 and a[0] == '-') return usage(app, "unknown option {s}", .{a}) else try pos.append(app.arena, a);
    }
    const p = pos.items;
    const is_list = eql(sub, "list") or eql(sub, "ls");
    const is_add = eql(sub, "add");
    const is_edit = eql(sub, "edit");
    const is_rm = eql(sub, "rm") or eql(sub, "remove");
    if (!(is_list and p.len == 0 and !save_code) and
        !(is_add and p.len >= 1 and p.len <= 2 and !json and !recent) and
        // edit changes the name, the saved code, or both.
        !(is_edit and p.len >= 1 and p.len <= 2 and (p.len == 2 or save_code) and !json and !recent) and
        !(is_rm and p.len == 1 and !json and !recent and !save_code)) return usage(app, usage_fav, .{});

    var cfg: config.Config = undefined;
    var client: api.Client = undefined;
    try signedInClient(app, &client, &cfg);
    defer client.deinit();

    if (is_list) {
        const saved = try fetchSaved(app, &client, if (recent) .recent else .favorites);
        if (json) try writeSavedJson(app.out, saved, &cfg) else try writeSavedTable(app.out, saved, &cfg);
        return .ok;
    }
    if (is_add) {
        const id = p[0];
        const name = if (p.len == 2) p[1] else "";
        // Asked before the request, so a failed read changes nothing on the account.
        const code = if (save_code) try codeToSave(app, id) else null;
        api.addFavorite(&client, app.arena, id, name, Io.Clock.real.now(app.io).toSeconds()) catch |err| return favCallError(app, "adding the favorite", &client, err);
        if (code) |c| try updateSavedCode(app, id, c);
        try app.err.print("Added favorite {s}{s}{s}{s}\n", .{ id, if (name.len != 0) " (" else "", name, if (name.len != 0) ")" else "" });
        if (code != null) try app.err.writeAll("The code is saved in the config file\n");
        return .ok;
    }
    const saved = try fetchSaved(app, &client, .favorites);
    const f = switch (try api.resolveSaved(app.arena, saved, p[0])) {
        .found => |f| f,
        .not_found => return app.fail(.no_device, "no favorite {s}: see `uucli fav list`", .{p[0]}),
        .ambiguous => |list| {
            app.err.print("favorite name {s} is ambiguous; use an id:\n", .{p[0]}) catch {};
            for (list) |x| app.err.print("  {s}  {s}\n", .{ x.id, x.name }) catch {};
            return .usage;
        },
    };
    if (is_edit) {
        const code = if (save_code) try codeToSave(app, f.id) else null;
        if (p.len == 2) {
            // Re-adding replaces the remark; the original time keeps the favorite's place in the apps.
            const at = f.favorited_at orelse Io.Clock.real.now(app.io).toSeconds();
            api.addFavorite(&client, app.arena, f.id, p[1], at) catch |err| return favCallError(app, "editing the favorite", &client, err);
            try app.err.print("Renamed favorite {s} to {s}\n", .{ f.id, p[1] });
        }
        if (code) |c| {
            try updateSavedCode(app, f.id, c);
            try app.err.writeAll("The code is saved in the config file\n");
        }
        return .ok;
    }
    api.removeSaved(&client, .favorites, f.publisher_device_id) catch |err| return favCallError(app, "removing the favorite", &client, err);
    if (cfg.assistCode(f.id) != null) try updateSavedCode(app, f.id, null);
    try app.err.print("Removed favorite {s} ({s})\n", .{ f.name, f.id });
    return .ok;
}

/// A code for `--save-code`: UUCLI_ASSIST_CODE, else asked for (never the one already saved).
fn codeToSave(app: *App, id: []const u8) ![]const u8 {
    if (app.env.get("UUCLI_ASSIST_CODE")) |c| if (c.len != 0) return c;
    return readCode(app, id, true);
}

fn favCallError(app: *App, what: []const u8, client: *const api.Client, err: anyerror) anyerror!Exit {
    switch (err) {
        error.ApiError => {
            const f = &client.failure;
            return app.fail(.other, "{s} failed: {f}{s}{s}", .{ what, f.*, if (f.msg_len != 0) ": " else "", f.msg() });
        },
        error.Network, error.Timeout, error.BadResponse => {
            login.reportCallError(app.err, what, client, err);
            return .other;
        },
        else => return err,
    }
}

fn writeSavedJson(w: *Io.Writer, saved: []const api.Saved, cfg: *const config.Config) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginArray();
    for (saved) |x| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(x.id);
        try s.objectField("name");
        try s.write(x.name);
        try s.objectField("favorite");
        try s.write(x.favorite);
        try s.objectField("code_saved");
        try s.write(cfg.assistCode(x.id) != null);
        try s.endObject();
    }
    try s.endArray();
    try w.writeByte('\n');
}

fn writeSavedTable(w: *Io.Writer, saved: []const api.Saved, cfg: *const config.Config) !void {
    var id_w: usize = "ID".len;
    var name_w: usize = "NAME".len;
    for (saved) |x| {
        id_w = @max(id_w, displayWidth(x.id));
        name_w = @max(name_w, displayWidth(x.name));
    }
    try pad(w, "ID", id_w + 2);
    try pad(w, "NAME", name_w + 2);
    try w.writeAll("FAVORITE  CODE\n");
    for (saved) |x| {
        try pad(w, x.id, id_w + 2);
        try pad(w, x.name, name_w + 2);
        try pad(w, if (x.favorite) "yes" else "no", "FAVORITE".len + 2);
        try w.print("{s}\n", .{if (cfg.assistCode(x.id) != null) "saved" else "-"});
    }
}
