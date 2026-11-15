// SPDX-License-Identifier: GPL-3.0-or-later
//! Config file (spec §4): path resolution, permission checks, atomic writes and locks.
//! The file holds the login token: it is never logged and always kept at mode 0600.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Config = struct {
    client_id: []const u8 = "",
    system_id: []const u8 = "",
    machine_guid: []const u8 = "",
    device_id: []const u8 = "",
    user_id: []const u8 = "",
    token: []const u8 = "",
    csrf: []const u8 = "",
    account_name: []const u8 = "",
    sign_key: []const u8 = "",

    pub fn signedIn(c: Config) bool {
        return c.token.len != 0 and c.user_id.len != 0 and c.csrf.len != 0;
    }

    /// Forgets the account but keeps the device identity (`uucli logout`).
    pub fn clearAccount(c: *Config) void {
        c.user_id = "";
        c.token = "";
        c.csrf = "";
        c.account_name = "";
    }
};

pub const Error = error{
    /// The file is readable or writable by group/other.
    InsecurePermissions,
    /// The file is not valid JSON or has fields of the wrong type.
    InvalidConfig,
    /// Neither UUCLI_CONFIG, XDG_CONFIG_HOME nor HOME is set.
    NoConfigPath,
    /// A non-blocking lock is held by another process.
    Busy,
};

/// `$UUCLI_CONFIG`, else `$XDG_CONFIG_HOME/uucli/config.json`, else `~/.config/uucli/config.json`.
pub fn resolvePath(arena: Allocator, env: *const Environ.Map) (Error || Allocator.Error)![]const u8 {
    if (env.get("UUCLI_CONFIG")) |p| if (p.len != 0) return arena.dupe(u8, p);
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len != 0 and std.fs.path.isAbsolute(x))
        return std.fs.path.join(arena, &.{ x, "uucli", "config.json" });
    const home = env.get("HOME") orelse return error.NoConfigPath;
    if (home.len == 0) return error.NoConfigPath;
    return std.fs.path.join(arena, &.{ home, ".config", "uucli", "config.json" });
}

const max_size = 1 << 20;

/// Reads the config; a missing file is an empty config.
pub fn load(arena: Allocator, io: Io, path: []const u8) !Config {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    const bytes = r.interface.allocRemaining(arena, .limited(max_size)) catch |err| switch (err) {
        error.ReadFailed => return r.err.?,
        else => |e| return e,
    };
    return std.json.parseFromSliceLeaky(Config, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => error.InvalidConfig,
    };
}

/// Writes `PATH.tmp` (0600), syncs it and renames it over `path`. Creates the directory (0700).
pub fn save(io: Io, path: []const u8, cfg: Config) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const file = try cwd.createFile(io, tmp, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        // An older tmp file may exist with other permissions.
        try file.setPermissions(io, .fromMode(0o600));
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        writeJson(&w.interface, cfg) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try file.sync(io);
    }
    try cwd.rename(tmp, cwd, path, io);
}

fn writeJson(w: *Io.Writer, cfg: Config) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    inline for (comptime std.meta.fieldNames(Config)) |name| {
        const v = @field(cfg, name);
        // sign_key is an optional override; keep the file free of the default.
        if (!(std.mem.eql(u8, name, "sign_key") and v.len == 0)) {
            try s.objectField(name);
            try s.write(v);
        }
    }
    try s.endObject();
    try w.writeByte('\n');
}

/// An exclusive `flock` on a file beside the config. Released by `release`.
pub const Lock = struct {
    file: Io.File,

    pub fn release(l: Lock, io: Io) void {
        l.file.close(io);
    }
};

pub const LockKind = enum {
    /// `STEM.lock`, around device registration and login (blocking).
    identity,
    /// `STEM.login.lock`, one `uucli login` at a time (non-blocking).
    login,
};

/// Lock file path for the config at `path`, e.g. `config.json` → `config.lock`, `config.login.lock`.
pub fn lockPath(buf: []u8, path: []const u8, kind: LockKind) ![]const u8 {
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    return std.fmt.bufPrint(buf, "{s}{s}", .{ stem, switch (kind) {
        .identity => ".lock",
        .login => ".login.lock",
    } });
}

pub fn lock(io: Io, path: []const u8, kind: LockKind) !Lock {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try lockPath(&buf, path, kind);
    const file = cwd.createFile(io, p, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = kind == .login,
        .permissions = .fromMode(0o600),
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Busy,
        else => |e| return e,
    };
    return .{ .file = file };
}

const testing = std.testing;

fn tmpPath(arena: Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    return std.fs.path.join(arena, &.{ dir, name });
}

test "resolvePath order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.NoConfigPath, resolvePath(arena, &env));
    try env.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.config/uucli/config.json", try resolvePath(arena, &env));
    try env.put("XDG_CONFIG_HOME", "relative");
    try testing.expectEqualStrings("/home/u/.config/uucli/config.json", try resolvePath(arena, &env));
    try env.put("XDG_CONFIG_HOME", "/x");
    try testing.expectEqualStrings("/x/uucli/config.json", try resolvePath(arena, &env));
    try env.put("UUCLI_CONFIG", "/y/work.json");
    try testing.expectEqualStrings("/y/work.json", try resolvePath(arena, &env));
}

test "lockPath" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/c/config.lock", try lockPath(&buf, "/c/config.json", .identity));
    try testing.expectEqualStrings("/c/config.login.lock", try lockPath(&buf, "/c/config.json", .login));
    try testing.expectEqualStrings("/c/work.lock", try lockPath(&buf, "/c/work", .identity));
}

test "save then load round-trips with 0600 and rejects group-readable files" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(arena, &tmp, "sub/config.json");

    try testing.expectEqual(Config{}, try load(arena, io, path));
    const cfg: Config = .{ .client_id = "c", .device_id = "d", .token = "t\"x", .account_name = "名字" };
    try save(io, path, cfg);
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    const dir_st = try Io.Dir.cwd().statFile(io, std.fs.path.dirname(path).?, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_st.permissions.toMode() & 0o777);

    const back = try load(arena, io, path);
    try testing.expectEqualStrings("t\"x", back.token);
    try testing.expectEqualStrings("名字", back.account_name);
    try testing.expectEqualStrings("", back.sign_key);

    try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o644), .{});
    try testing.expectError(error.InsecurePermissions, load(arena, io, path));
}

test "login lock is exclusive" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(arena_state.allocator(), &tmp, "config.json");
    const first = try lock(io, path, .login);
    defer first.release(io);
    try testing.expectError(error.Busy, lock(io, path, .login));
}
