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
    /// Remote-assistance codes saved with `fav add --save-code`, by share id.
    assist_codes: []const AssistCode = &.{},

    pub const AssistCode = struct { id: []const u8, code: []const u8 };

    /// The saved code for share `id`.
    pub fn assistCode(c: Config, id: []const u8) ?[]const u8 {
        for (c.assist_codes) |a| if (std.mem.eql(u8, a.id, id)) return a.code;
        return null;
    }

    /// Replaces (or with `code == null` removes) the saved code for `id`.
    pub fn setAssistCode(c: *Config, arena: Allocator, id: []const u8, code: ?[]const u8) Allocator.Error!void {
        var list: std.ArrayList(AssistCode) = .empty;
        for (c.assist_codes) |a| if (!std.mem.eql(u8, a.id, id)) try list.append(arena, a);
        if (code) |k| try list.append(arena, .{ .id = id, .code = k });
        c.assist_codes = list.items;
    }

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
    InvalidEncryptionKey,
    CodeDecryptionFailed,
    UnsupportedCodeFormat,
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
    var cfg = std.json.parseFromSliceLeaky(Config, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidConfig,
    };
    if (cfg.assist_codes.len != 0) {
        for (cfg.assist_codes) |entry| if (!std.mem.startsWith(u8, entry.code, code_prefix))
            return error.UnsupportedCodeFormat;
        var key = try encryptionKey(io, path, false);
        defer std.crypto.secureZero(u8, &key);
        const codes = try arena.dupe(Config.AssistCode, cfg.assist_codes);
        for (codes) |*entry| entry.code = try decryptCode(arena, key, entry.id, entry.code);
        cfg.assist_codes = codes;
    }
    return cfg;
}

/// Writes `PATH.tmp` (0600), syncs it and renames it over `path`. Creates the directory (0700).
pub fn save(io: Io, path: []const u8, cfg: Config) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stored = cfg;
    if (cfg.assist_codes.len != 0) {
        var key = try encryptionKey(io, path, true);
        defer std.crypto.secureZero(u8, &key);
        const codes = try arena.dupe(Config.AssistCode, cfg.assist_codes);
        for (codes) |*entry| entry.code = try encryptCode(arena, io, key, entry.id, entry.code);
        stored.assist_codes = codes;
    }
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const file = try cwd.createFile(io, tmp, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        // An older tmp file may exist with other permissions.
        try file.setPermissions(io, .fromMode(0o600));
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        writeJson(&w.interface, stored) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try file.sync(io);
    }
    try cwd.rename(tmp, cwd, path, io);
}

const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const code_prefix = "enc:v1:";

/// A random per-config key; encrypted configs never recreate a missing key while loading.
fn encryptionKey(io: Io, path: []const u8, create: bool) ![Cipher.key_length]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&path_buf, "{s}.key", .{path});
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, key_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (!create) return error.InvalidEncryptionKey;
            var key: [Cipher.key_length]u8 = undefined;
            try io.randomSecure(&key);
            defer std.crypto.secureZero(u8, &key);
            const out = cwd.createFile(io, key_path, .{
                .exclusive = true,
                .permissions = .fromMode(0o600),
            }) catch |e| switch (e) {
                error.PathAlreadyExists => return encryptionKey(io, path, false),
                else => return e,
            };
            defer out.close(io);
            var w = out.writer(io, &.{});
            try w.interface.writeAll(&key);
            try w.interface.flush();
            try out.sync(io);
            return key;
        },
        else => return err,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.permissions.toMode() & 0o077 != 0 or st.size != Cipher.key_length)
        return error.InvalidEncryptionKey;
    var key: [Cipher.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    var r = file.reader(io, &.{});
    try r.interface.readSliceAll(&key);
    return key;
}

/// Share id is authenticated so ciphertext cannot be moved to another saved host.
fn encryptCode(arena: Allocator, io: Io, key: [Cipher.key_length]u8, id: []const u8, code: []const u8) ![]const u8 {
    const raw = try arena.alloc(u8, Cipher.nonce_length + Cipher.tag_length + code.len);
    defer arena.free(raw);
    var nonce: [Cipher.nonce_length]u8 = undefined;
    try io.randomSecure(&nonce);
    @memcpy(raw[0..Cipher.nonce_length], &nonce);
    const tag = raw[Cipher.nonce_length..][0..Cipher.tag_length];
    Cipher.encrypt(raw[Cipher.nonce_length + Cipher.tag_length ..], tag, code, id, nonce, key);
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, code_prefix.len + encoder.calcSize(raw.len));
    @memcpy(out[0..code_prefix.len], code_prefix);
    _ = encoder.encode(out[code_prefix.len..], raw);
    return out;
}

fn decryptCode(arena: Allocator, key: [Cipher.key_length]u8, id: []const u8, stored: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, stored, code_prefix)) return error.UnsupportedCodeFormat;
    const decoder = std.base64.standard.Decoder;
    const encoded = stored[code_prefix.len..];
    const raw = try arena.alloc(u8, decoder.calcSizeForSlice(encoded) catch return error.CodeDecryptionFailed);
    defer arena.free(raw);
    decoder.decode(raw, encoded) catch return error.CodeDecryptionFailed;
    if (raw.len < Cipher.nonce_length + Cipher.tag_length) return error.CodeDecryptionFailed;
    const out = try arena.alloc(u8, raw.len - Cipher.nonce_length - Cipher.tag_length);
    errdefer arena.free(out);
    Cipher.decrypt(out, raw[Cipher.nonce_length + Cipher.tag_length ..], raw[Cipher.nonce_length..][0..Cipher.tag_length].*, id, raw[0..Cipher.nonce_length].*, key) catch return error.CodeDecryptionFailed;
    return out;
}

fn writeJson(w: *Io.Writer, cfg: Config) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    inline for (comptime std.meta.fieldNames(Config)) |name| {
        const v = @field(cfg, name);
        // sign_key is an optional override; keep the file free of the default. Same for the codes.
        if (!(std.mem.eql(u8, name, "sign_key") and v.len == 0) and !(std.mem.eql(u8, name, "assist_codes") and v.len == 0)) {
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

test "assistance codes are saved per share id and omitted when empty" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(arena, &tmp, "config.json");

    var cfg: Config = .{ .device_id = "d" };
    try cfg.setAssistCode(arena, "111", "old");
    try cfg.setAssistCode(arena, "222", "b");
    try cfg.setAssistCode(arena, "111", "new");
    try save(io, path, cfg);
    var back = try load(arena, io, path);
    try testing.expectEqualStrings("new", back.assistCode("111").?);
    try testing.expectEqualStrings("b", back.assistCode("222").?);
    try testing.expectEqual(@as(usize, 2), back.assist_codes.len);

    try back.setAssistCode(arena, "111", null);
    try back.setAssistCode(arena, "222", null);
    try save(io, path, back);
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, text, "assist_codes") == null);
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

test "saved assistance codes are encrypted on disk with a private key" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(arena, &tmp, "config.json");
    var cfg: Config = .{};
    try cfg.setAssistCode(arena, "share-test", "private-test-code");
    try save(io, path, cfg);
    const first = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, first, "private-test-code") == null);
    try testing.expect(std.mem.indexOf(u8, first, code_prefix) != null);
    const key_path = try std.fmt.allocPrint(arena, "{s}.key", .{path});
    const st = try Io.Dir.cwd().statFile(io, key_path, .{});
    try testing.expectEqual(@as(u64, Cipher.key_length), st.size);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    const back = try load(arena, io, path);
    try testing.expectEqualStrings("private-test-code", back.assistCode("share-test").?);
    try save(io, path, back);
    const second = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    try testing.expect(!std.mem.eql(u8, first, second));
    try Io.Dir.cwd().setFilePermissions(io, key_path, .fromMode(0o644), .{});
    try testing.expectError(error.InvalidEncryptionKey, load(arena, io, path));
    try Io.Dir.cwd().setFilePermissions(io, key_path, .fromMode(0o600), .{});
    try Io.Dir.cwd().deleteFile(io, key_path);
    try testing.expectError(error.InvalidEncryptionKey, load(arena, io, path));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, key_path, .{}));
}

test "encrypted assistance codes reject tampering wrong keys and swapped hosts" {
    const gpa = testing.allocator;
    const key: [Cipher.key_length]u8 = @splat(7);
    const sealed = try encryptCode(gpa, testing.io, key, "host-a", "private-test-code");
    defer gpa.free(sealed);
    const plain = try decryptCode(gpa, key, "host-a", sealed);
    defer gpa.free(plain);
    try testing.expectEqualStrings("private-test-code", plain);
    try testing.expectError(error.CodeDecryptionFailed, decryptCode(gpa, key, "host-b", sealed));
    try testing.expectError(error.CodeDecryptionFailed, decryptCode(gpa, @as([Cipher.key_length]u8, @splat(8)), "host-a", sealed));
    const damaged = try gpa.dupe(u8, sealed);
    defer gpa.free(damaged);
    damaged[code_prefix.len] = if (damaged[code_prefix.len] == 'A') 'B' else 'A';
    try testing.expectError(error.CodeDecryptionFailed, decryptCode(gpa, key, "host-a", damaged));
    for ([_][]const u8{ "enc:v1:!", "enc:v1:", "enc:v1:AAAA" }) |bad|
        try testing.expectError(error.CodeDecryptionFailed, decryptCode(gpa, key, "host-a", bad));
    try testing.expectError(error.UnsupportedCodeFormat, decryptCode(gpa, key, "host-a", "legacy-plain-code"));
}

test "configs without assistance codes need no encryption key" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(arena, &tmp, "config.json");
    try save(io, path, .{ .device_id = "test-device" });
    const key_path = try std.fmt.allocPrint(arena, "{s}.key", .{path});
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, key_path, .{}));
    const cfg = try load(arena, io, path);
    try testing.expectEqualStrings("test-device", cfg.device_id);
}
