// SPDX-License-Identifier: GPL-3.0-or-later
//! Device registration and QR sign-in (spec §5.2, §5.3). Upstream: src/login.rs
//! (`prepare_identity`, `prepare_device`, `flow`, `qr_poll_action`, `qr_ticket`, `csrf_from_token`).
//! Tokens and QR tickets are never printed or logged.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Config = config.Config;
const api = @import("api.zig");
const qr = @import("qr.zig");

const log = std.log.scoped(.login);

/// API code for an expired login QR code.
const code_qr_expired = 1190;

pub const Error = error{
    /// Another `uucli login` holds the login lock.
    LoginBusy,
    /// The QR flow stopped and cannot be retried (no tty), or the server gave no credentials.
    LoginFailed,
};

/// Random UUID v4, lowercase.
pub fn randomUuid(io: Io) [36]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return guid(&std.fmt.bytesToHex(b, .lower));
}

/// 32 hex digits as 8-4-4-4-12.
fn guid(hex: *const [32]u8) [36]u8 {
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return out;
}

/// The `csrf` claim of a JWT access token (payload is base64url, padding optional).
pub fn csrfFromToken(arena: Allocator, token: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload = std.mem.trimEnd(u8, parts.next() orelse return null, "=");
    if (payload.len > 16384) return null;
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(payload) catch return null;
    const bytes = arena.alloc(u8, n) catch return null;
    dec.decode(bytes, payload) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    const csrf = api.str(v, "csrf") orelse return null;
    return if (csrf.len == 0) null else csrf;
}

/// What to do with one answer of `/api/v1/qrcode/login/status` (spec §5.3 table).
pub const PollAction = union(enum) {
    /// Keep polling with this `login_status`.
    wait: i64,
    /// First "scanned" answer.
    scanned,
    confirmed,
    /// Generate a new QR after this many milliseconds.
    refresh: u32,
    failed: Failure,

    pub const Failure = enum { expired, query_failed, unexpected };
};

pub fn pollAction(last: i64, http_status: u16, body: ?std.json.Value) PollAction {
    const b = body orelse return .{ .failed = .query_failed };
    if (api.int(b, "code") == code_qr_expired) return .{ .failed = .expired };
    if (http_status != 200 or api.int(b, "code") != 0) return .{ .failed = .query_failed };
    const data = if (b == .object) b.object.get("data") orelse .null else .null;
    return switch (api.int(data, "status") orelse return .{ .failed = .unexpected }) {
        1 => .{ .wait = 1 },
        2 => if (last != 2) .scanned else .{ .wait = 2 },
        0 => .{ .refresh = 350 },
        3 => .{ .refresh = 0 },
        4 => .confirmed,
        else => .{ .failed = .unexpected },
    };
}

/// gen/login's status ticket: `status_query_ticket` if present, else the older `token` field.
/// A present but empty `status_query_ticket` means no ticket (no fallback), as upstream.
pub fn qrTicket(gen: std.json.Value) ?[]const u8 {
    if (gen != .object) return null;
    const v = gen.object.get("status_query_ticket") orelse gen.object.get("token") orelse return null;
    return switch (v) {
        .string => |t| if (t.len != 0) t else null,
        else => null,
    };
}

pub const Context = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    config_path: []const u8,
    /// Login progress, QR code and prompts.
    stderr: *Io.Writer,
    stdin_tty: bool,
    proxy_env: ?*const std.process.Environ.Map,
    /// null: ask on a terminal, else QR.
    method: ?Method = null,
};

pub const Method = enum { qr, phone };

pub const Account = struct { name: []const u8, user_id: []const u8 };

/// `uucli login`.
pub fn run(ctx: Context) !Account {
    const login_lock = config.lock(ctx.io, ctx.config_path, .login) catch |err| switch (err) {
        error.Busy => return error.LoginBusy,
        else => |e| return e,
    };
    defer login_lock.release(ctx.io);
    // Held for the whole login so device registration and the final write never interleave with
    // another process registering a device on the same config.
    const id_lock = try config.lock(ctx.io, ctx.config_path, .identity);
    defer id_lock.release(ctx.io);

    var cfg = try prepareDevice(ctx);
    const method = ctx.method orelse if (ctx.stdin_tty) try chooseMethod(ctx) else .qr;
    return switch (method) {
        .qr => flow(ctx, &cfg),
        .phone => phoneFlow(ctx, &cfg),
    };
}

fn chooseMethod(ctx: Context) !Method {
    try ctx.stderr.writeAll("Sign in with:\n  1) QR code (scan with the UU Remote app)\n  2) Phone number and SMS code\n");
    for (0..3) |_| {
        const a = try readLine(ctx, "Choice [1]: ");
        if (a.len == 0 or std.mem.eql(u8, a, "1")) return .qr;
        if (std.mem.eql(u8, a, "2")) return .phone;
        try ctx.stderr.writeAll("Enter 1 or 2\n");
    }
    return error.LoginFailed;
}

/// Prints `prompt` and reads one line of stdin, trimmed. One byte at a time, so nothing after the
/// line is consumed. End of input before a line → LoginFailed.
fn readLine(ctx: Context, prompt: []const u8) ![]const u8 {
    try ctx.stderr.writeAll(prompt);
    try ctx.stderr.flush();
    var buf: [1]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(ctx.io, &buf);
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const b = r.interface.takeByte() catch {
            if (line.items.len == 0) return error.LoginFailed;
            break;
        };
        if (b == '\n') break;
        if (line.items.len < 256) try line.append(ctx.arena, b);
    }
    return std.mem.trim(u8, line.items, " \t\r");
}

/// Loads the config, generates missing ids and registers the device if it has no `device_id`.
/// Caller holds the identity lock.
pub fn prepareDevice(ctx: Context) !Config {
    var cfg = try config.load(ctx.arena, ctx.io, ctx.config_path);
    var changed = false;
    if (cfg.client_id.len == 0) {
        cfg.client_id = try ctx.arena.dupe(u8, &randomUuid(ctx.io));
        changed = true;
    }
    if (cfg.system_id.len == 0) {
        var u = randomUuid(ctx.io);
        for (&u) |*ch| ch.* = std.ascii.toUpper(ch.*);
        cfg.system_id = try ctx.arena.dupe(u8, &u);
        changed = true;
    }
    if (cfg.machine_guid.len == 0) {
        cfg.machine_guid = try machineGuid(ctx.arena, ctx.io);
        changed = true;
    }
    if (changed) try config.save(ctx.io, ctx.config_path, cfg);
    if (cfg.device_id.len != 0) return cfg;

    const info = try hardware(ctx.arena, ctx.io);
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{
        .name = info.name,
        .client_id = cfg.client_id,
        .system_id = cfg.system_id,
        .machine_guid = cfg.machine_guid,
        .os = info.os,
        .base_board = info.base_board,
        .cpu = info.cpu,
        .video = info.video,
        .mac = info.mac,
        .memory = info.memory_mib,
        .screen = info.screen,
    }, .{});

    // Anonymous request: only the installation ids.
    const anon: Config = .{ .client_id = cfg.client_id, .system_id = cfg.system_id, .sign_key = cfg.sign_key };
    var client: api.Client = undefined;
    try initClient(ctx, &client, &anon);
    defer client.deinit();
    var resp = client.call(.POST, "/api/v1/device/windows/init", body, .fromSeconds(15)) catch |err| {
        reportCallError(ctx.stderr, "device registration", &client, err);
        return err;
    };
    defer resp.deinit();
    const id = api.str(resp.data, "device_id") orelse {
        try ctx.stderr.writeAll("device registration returned no device_id\n");
        return error.LoginFailed;
    };
    cfg.device_id = try ctx.arena.dupe(u8, id);
    log.info("registered device identity", .{});
    // Kept even if the QR step is abandoned, so the next login reuses this device.
    try config.save(ctx.io, ctx.config_path, cfg);
    return cfg;
}

fn initClient(ctx: Context, client: *api.Client, cfg: *const Config) !void {
    try client.init(ctx.io, ctx.gpa, cfg, if (ctx.proxy_env) |env| .{ .arena = ctx.arena, .env = env } else null);
}

pub fn reportCallError(w: *Io.Writer, what: []const u8, client: *const api.Client, err: anyerror) void {
    switch (err) {
        error.ApiError => w.print("{s} failed: {f}\n", .{ what, client.failure }) catch {},
        error.Network => w.print("{s} failed: network error ({t})\n", .{ what, client.network_error orelse error.Unknown }) catch {},
        error.Timeout => w.print("{s} failed: timed out\n", .{what}) catch {},
        error.BadResponse => w.print("{s} failed: malformed response ({f})\n", .{ what, client.failure }) catch {},
        else => {},
    }
    w.flush() catch {};
}

const qr_timeout: Io.Duration = .fromSeconds(60);

fn flow(ctx: Context, cfg: *Config) !Account {
    const w = ctx.stderr;
    // The login requests carry only the device identity, never an older token.
    var anon = cfg.*;
    anon.clearAccount();
    var client: api.Client = undefined;
    try initClient(ctx, &client, &anon);
    defer client.deinit();

    while (true) {
        var gen = client.call(.POST, "/api/v1/qrcode/gen/login", "", qr_timeout) catch |err| switch (err) {
            error.ApiError, error.BadResponse, error.Timeout, error.Network => {
                reportCallError(w, "QR code generation", &client, err);
                try waitForRefresh(ctx);
                continue;
            },
            else => |e| return e,
        };
        defer gen.deinit();
        const url = api.str(gen.data, "qrcode_jump_url") orelse {
            try w.writeAll("QR code generation returned no qrcode_jump_url\n");
            return error.LoginFailed;
        };
        const ticket = qrTicket(gen.data) orelse {
            try w.writeAll("QR code generation returned no status ticket\n");
            return error.LoginFailed;
        };
        const code = try qr.encode(try ctx.arena.dupeSentinel(u8, url, 0));
        try w.writeAll("\n");
        try qr.render(&code, w);
        try w.writeAll("Scan with the UU Remote mobile app\n");
        try w.flush();

        var last: i64 = 1;
        const outcome: enum { refresh, failed } = poll: while (true) {
            const query = try std.json.Stringify.valueAlloc(ctx.gpa, .{ .token = ticket, .qrcode_jump_url = url, .login_status = last }, .{});
            defer ctx.gpa.free(query);
            var status_resp = client.call(.POST, "/api/v1/qrcode/login/status", query, qr_timeout);
            const action: PollAction = if (status_resp) |r|
                pollAction(last, client.failure.status, r.parsed.value)
            else |err| switch (err) {
                error.ApiError => blk: {
                    // Non-success envelope: decide from the code alone.
                    var fake: std.json.ObjectMap = .empty;
                    defer fake.deinit(ctx.gpa);
                    if (client.failure.code) |c| try fake.put(ctx.gpa, "code", .{ .integer = c });
                    break :blk pollAction(last, client.failure.status, .{ .object = fake });
                },
                error.BadResponse, error.Timeout, error.Network => blk: {
                    reportCallError(w, "QR status check", &client, err);
                    break :blk .{ .failed = .query_failed };
                },
                else => |e| return e,
            };
            if (status_resp) |*r| r.deinit() else |_| {}
            switch (action) {
                .wait => |s| last = s,
                .scanned => {
                    last = 2;
                    try w.writeAll("Scanned, confirm on the phone\n");
                    try w.flush();
                },
                .refresh => |ms| {
                    if (ms == 0) {
                        try w.writeAll("QR code expired, generating a new one\n");
                    } else {
                        try ctx.io.sleep(.fromMilliseconds(ms), .awake);
                    }
                    break :poll .refresh;
                },
                .failed => |f| {
                    try w.print("{s}\n", .{switch (f) {
                        .expired => "QR code expired",
                        .query_failed => "QR status check failed (the QR code may still be valid)",
                        .unexpected => "Unexpected QR status response",
                    }});
                    break :poll .failed;
                },
                .confirmed => return finish(ctx, cfg, &client, ticket, url),
            }
        };
        if (outcome == .failed) try waitForRefresh(ctx);
    }
}

fn finish(ctx: Context, cfg: *Config, client: *api.Client, ticket: []const u8, url: []const u8) !Account {
    const w = ctx.stderr;
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .token = ticket, .qrcode_jump_url = url }, .{});
    var resp = client.call(.POST, "/api/v1/login/by_qrcode", body, qr_timeout) catch |err| {
        reportCallError(w, "QR sign-in", client, err);
        return error.LoginFailed;
    };
    defer resp.deinit();
    return saveLogin(ctx, cfg, resp.data);
}

/// Stores the account from a sign-in response (`by_qrcode` and `by_mobile` answer alike).
fn saveLogin(ctx: Context, cfg: *Config, data: std.json.Value) !Account {
    const w = ctx.stderr;
    const token = api.str(data, "token") orelse "";
    const user = api.str(data, "user_id") orelse "";
    if (token.len == 0 or user.len == 0) {
        try w.writeAll("sign-in response has no token or user_id\n");
        return error.LoginFailed;
    }
    const csrf = csrfFromToken(ctx.arena, token) orelse {
        try w.writeAll("sign-in token carries no csrf claim\n");
        return error.LoginFailed;
    };
    cfg.token = try ctx.arena.dupe(u8, token);
    cfg.user_id = try ctx.arena.dupe(u8, user);
    cfg.csrf = csrf;
    cfg.account_name = try ctx.arena.dupe(u8, api.str(data, "nickname") orelse "");
    try config.save(ctx.io, ctx.config_path, cfg.*);
    return .{ .name = cfg.account_name, .user_id = cfg.user_id };
}

pub const Phone = struct { country_code: []const u8, number: []const u8 };

/// `13800000000` (country code 86) or `+852 1234 5678`. Spaces and dashes in the number are
/// dropped; anything else that is not a digit → null.
pub fn parsePhone(arena: Allocator, input: []const u8) Allocator.Error!?Phone {
    var s = std.mem.trim(u8, input, " ");
    var cc: []const u8 = "86";
    if (s.len != 0 and s[0] == '+') {
        var n: usize = 1;
        while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
        cc = s[1..n];
        s = s[n..];
        if (cc.len == 0 or cc.len > 4) return null;
    }
    var digits: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (std.ascii.isDigit(b)) try digits.append(arena, b) else if (b != ' ' and b != '-') return null;
    }
    if (digits.items.len < 5 or digits.items.len > 15) return null;
    return .{ .country_code = cc, .number = digits.items };
}

/// Phone number and SMS code, as the official Android app signs in (spec §5.3.1).
fn phoneFlow(ctx: Context, cfg: *Config) !Account {
    const w = ctx.stderr;
    var anon = cfg.*;
    anon.clearAccount();
    var client: api.Client = undefined;
    try initClient(ctx, &client, &anon);
    defer client.deinit();

    const phone = for (0..3) |_| {
        if (try parsePhone(ctx.arena, try readLine(ctx, "Phone number (+CODE first outside mainland China): "))) |p| break p;
        try w.writeAll("Not a phone number\n");
    } else return error.LoginFailed;

    const send = try std.json.Stringify.valueAlloc(ctx.arena, .{ .country_code = phone.country_code, .mobile = phone.number, .type = "login" }, .{});
    var sent = client.call(.POST, "/api/v1/security/mobile/code", send, qr_timeout) catch |err| {
        reportPhoneError(w, "sending the SMS code", &client, err, "");
        return error.LoginFailed;
    };
    sent.deinit();
    try w.print("SMS code sent to +{s} {s}\n", .{ phone.country_code, phone.number });

    for (0..3) |_| {
        const code = try readLine(ctx, "SMS code: ");
        if (code.len == 0) continue;
        const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .country_code = phone.country_code, .mobile = phone.number, .code = code }, .{});
        var resp = client.call(.POST, "/api/v1/login/by_mobile", body, qr_timeout) catch |err| {
            reportPhoneError(w, "phone sign-in", &client, err, code);
            // A wrong code can be typed again; anything else ends the login.
            if (err == error.ApiError) continue;
            return error.LoginFailed;
        };
        defer resp.deinit();
        return saveLogin(ctx, cfg, resp.data);
    }
    return error.LoginFailed;
}

/// Like `reportCallError`, plus the server message (it says why: wrong code, too many requests),
/// unless it quotes the SMS code.
fn reportPhoneError(w: *Io.Writer, what: []const u8, client: *api.Client, err: anyerror, code: []const u8) void {
    if (err != error.ApiError) return reportCallError(w, what, client, err);
    const f = &client.failure;
    const show = f.msg_len != 0 and (code.len == 0 or std.mem.indexOf(u8, f.msg(), code) == null);
    w.print("{s} failed: {f}{s}{s}\n", .{ what, f.*, if (show) ": " else "", if (show) f.msg() else "" }) catch {};
    w.flush() catch {};
}

/// On a tty: wait for Enter. Otherwise stop the login.
fn waitForRefresh(ctx: Context) !void {
    if (!ctx.stdin_tty) return error.LoginFailed;
    try ctx.stderr.writeAll("Press Enter for a new QR code\n");
    try ctx.stderr.flush();
    var buf: [64]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(ctx.io, &buf);
    _ = r.interface.discardDelimiterInclusive('\n') catch return error.LoginFailed;
}

// --- Machine description for device/windows/init -------------------------------------------

pub const Hardware = struct {
    /// `uucli@HOSTNAME`
    name: []const u8,
    os: []const u8,
    cpu: []const u8,
    base_board: []const u8,
    mac: []const u8,
    memory_mib: u64,
    video: []const []const u8 = &.{"Unknown"},
    /// Constant: uucli is headless.
    screen: []const u8 = "1920x1080",
};

/// Whole file, trimmed; "" if unreadable. Streams, because procfs files report size 0.
fn readTrimmed(arena: Allocator, io: Io, path: []const u8) []const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    const bytes = r.interface.allocRemaining(arena, .limited(1 << 20)) catch return "";
    return std.mem.trim(u8, bytes, " \t\r\n");
}

/// Value after `key` up to the end of the line, in `text` such as /proc/cpuinfo or os-release.
fn lineValue(text: []const u8, key: []const u8, sep: u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const i = std.mem.indexOfScalar(u8, line, sep) orelse continue;
        if (std.mem.trim(u8, line[key.len..i], " \t").len != 0) continue;
        return std.mem.trim(u8, line[i + 1 ..], " \t\"");
    }
    return null;
}

fn machineGuid(arena: Allocator, io: Io) ![]const u8 {
    if (builtin.os.tag == .linux) {
        const id = readTrimmed(arena, io, "/etc/machine-id");
        if (id.len == 32 and for (id) |ch| {
            if (!std.ascii.isHex(ch)) break false;
        } else true) return arena.dupe(u8, &guid(id[0..32]));
    } else if (builtin.os.tag.isDarwin()) {
        const out = runOutput(arena, io, &.{ "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice" });
        if (std.mem.indexOf(u8, out, "\"IOPlatformUUID\" = \"")) |i| {
            const rest = out[i + 20 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| if (end == 36) return rest[0..36];
        }
    }
    return arena.dupe(u8, &randomUuid(io));
}

fn runOutput(arena: Allocator, io: Io, argv: []const []const u8) []const u8 {
    const r = std.process.run(arena, io, .{ .argv = argv }) catch return "";
    return std.mem.trim(u8, r.stdout, " \t\r\n");
}

fn sysctlString(arena: Allocator, name: [:0]const u8) []const u8 {
    var len: usize = 0;
    if (std.c.sysctlbyname(name, null, &len, null, 0) != 0 or len == 0) return "";
    const buf = arena.alloc(u8, len) catch return "";
    if (std.c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return "";
    return std.mem.sliceTo(buf, 0);
}

/// The machine fields of `device/windows/init` (spec §5.2).
pub fn hardware(arena: Allocator, io: Io) !Hardware {
    var host_buf: [256]u8 = undefined;
    var host: []const u8 = if (builtin.os.tag == .windows)
        windowsHostName(&host_buf)
    else blk: {
        var posix_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&posix_buf) catch break :blk "unknown";
        @memcpy(host_buf[0..name.len], name);
        break :blk host_buf[0..name.len];
    };
    // gethostname on macOS often returns a DHCP-assigned name or address; prefer the Bonjour name.
    if (builtin.os.tag.isDarwin()) {
        const local = runOutput(arena, io, &.{ "/usr/sbin/scutil", "--get", "LocalHostName" });
        if (local.len != 0) host = local;
    }
    var h: Hardware = .{
        .name = try std.fmt.allocPrint(arena, "uucli@{s}", .{host}),
        .os = "",
        .cpu = "",
        .base_board = "Unknown",
        .mac = "",
        .memory_mib = 0,
    };
    if (builtin.os.tag == .linux) {
        h.os = lineValue(readTrimmed(arena, io, "/etc/os-release"), "PRETTY_NAME", '=') orelse "Linux";
        h.cpu = lineValue(readTrimmed(arena, io, "/proc/cpuinfo"), "model name", ':') orelse @tagName(builtin.cpu.arch);
        const vendor = readTrimmed(arena, io, "/sys/class/dmi/id/board_vendor");
        const name = readTrimmed(arena, io, "/sys/class/dmi/id/board_name");
        const board = std.mem.trim(u8, try std.fmt.allocPrint(arena, "{s} {s}", .{ vendor, name }), " ");
        if (board.len != 0) h.base_board = board;
        if (lineValue(readTrimmed(arena, io, "/proc/meminfo"), "MemTotal", ':')) |v| {
            const kb = std.mem.trimEnd(u8, std.mem.trimEnd(u8, v, "kB"), " ");
            h.memory_mib = (std.fmt.parseInt(u64, kb, 10) catch 0) / 1024;
        }
        h.mac = try linuxMac(arena, io);
    } else if (builtin.os.tag.isDarwin()) {
        const name = runOutput(arena, io, &.{ "/usr/bin/sw_vers", "-productName" });
        const ver = runOutput(arena, io, &.{ "/usr/bin/sw_vers", "-productVersion" });
        h.os = if (name.len != 0) try std.fmt.allocPrint(arena, "{s} {s}", .{ name, ver }) else "macOS";
        h.cpu = sysctlString(arena, "machdep.cpu.brand_string");
        if (h.cpu.len == 0) h.cpu = @tagName(builtin.cpu.arch);
        const model = sysctlString(arena, "hw.model");
        if (model.len != 0) h.base_board = model;
        var mem: u64 = 0;
        var len: usize = @sizeOf(u64);
        if (std.c.sysctlbyname("hw.memsize", &mem, &len, null, 0) == 0) h.memory_mib = mem / (1024 * 1024);
        h.mac = Darwin.mac(arena);
    } else if (builtin.os.tag == .windows) {
        h.os = "Windows";
        h.cpu = @tagName(builtin.cpu.arch);
        h.memory_mib = windowsMemoryMib();
    }
    return h;
}

const Win32 = struct {
    const MEMORYSTATUSEX = extern struct {
        dwLength: std.os.windows.DWORD,
        dwMemoryLoad: std.os.windows.DWORD,
        ullTotalPhys: u64,
        ullAvailPhys: u64,
        ullTotalPageFile: u64,
        ullAvailPageFile: u64,
        ullTotalVirtual: u64,
        ullAvailVirtual: u64,
        ullAvailExtendedVirtual: u64,
    };

    extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) std.os.windows.BOOL;
};

fn windowsHostName(buf: *[256]u8) []const u8 {
    var size: std.os.windows.DWORD = @intCast(buf.len);
    if (Win32.GetComputerNameA(buf, &size) == .FALSE or size == 0) return "unknown";
    return buf[0..size];
}

fn windowsMemoryMib() u64 {
    var status: Win32.MEMORYSTATUSEX = std.mem.zeroes(Win32.MEMORYSTATUSEX);
    status.dwLength = @sizeOf(Win32.MEMORYSTATUSEX);
    if (Win32.GlobalMemoryStatusEx(&status) == .FALSE) return 0;
    return status.ullTotalPhys / (1024 * 1024);
}

/// Uppercase dash form, e.g. `AA-BB-CC-DD-EE-FF`.
fn formatMac(arena: Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes, 0..) |b, i| {
        if (i != 0) try out.append(arena, '-');
        try out.print(arena, "{X:0>2}", .{b});
    }
    return out.items;
}

/// First interface (sorted by name) backed by a device, with a non-zero address.
fn linuxMac(arena: Allocator, io: Io) ![]const u8 {
    var dir = Io.Dir.cwd().openDir(io, "/sys/class/net", .{ .iterate = true }) catch return "";
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        var buf: [256]u8 = undefined;
        const dev = std.fmt.bufPrint(&buf, "{s}/device", .{e.name}) catch continue;
        dir.access(io, dev, .{}) catch continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |n| {
        const addr = readTrimmed(arena, io, try std.fmt.allocPrint(arena, "/sys/class/net/{s}/address", .{n}));
        if (addr.len == 0 or std.mem.eql(u8, addr, "00:00:00:00:00:00")) continue;
        const out = try arena.dupe(u8, addr);
        for (out) |*ch| ch.* = if (ch.* == ':') '-' else std.ascii.toUpper(ch.*);
        return out;
    }
    return "";
}

const Darwin = struct {
    const ifaddrs = extern struct {
        next: ?*ifaddrs,
        name: [*:0]const u8,
        flags: c_uint,
        addr: ?*const std.c.sockaddr,
        netmask: ?*const std.c.sockaddr,
        dstaddr: ?*const std.c.sockaddr,
        data: ?*anyopaque,
    };
    extern "c" fn getifaddrs(out: *?*ifaddrs) c_int;
    extern "c" fn freeifaddrs(list: ?*ifaddrs) void;

    /// First Ethernet-type link address among `en*` interfaces, sorted by name.
    fn mac(arena: Allocator) []const u8 {
        var list: ?*ifaddrs = null;
        if (getifaddrs(&list) != 0) return "";
        defer freeifaddrs(list);
        var best_name: []const u8 = "";
        var best: [6]u8 = undefined;
        var it = list;
        while (it) |ifa| : (it = ifa.next) {
            const sa = ifa.addr orelse continue;
            const AF_LINK = 18;
            if (sa.family != AF_LINK) continue;
            // struct sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data[]
            const raw: [*]const u8 = @ptrCast(sa);
            const ift_ether = 6;
            if (raw[4] != ift_ether or raw[6] != 6) continue;
            const name = std.mem.span(ifa.name);
            if (!std.mem.startsWith(u8, name, "en")) continue;
            const addr = raw[8 + raw[5] ..][0..6];
            if (std.mem.allEqual(u8, addr, 0)) continue;
            if (best_name.len == 0 or std.mem.lessThan(u8, name, best_name)) {
                best_name = name;
                best = addr.*;
            }
        }
        if (best_name.len == 0) return "";
        return formatMac(arena, &best) catch "";
    }
};

const testing = std.testing;

fn parse(arena: Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{});
}

test "poll action table" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const reply = struct {
        fn f(al: Allocator, status: i64) !std.json.Value {
            return parse(al, try std.fmt.allocPrint(al, "{{\"code\":0,\"data\":{{\"status\":{d}}}}}", .{status}));
        }
    }.f;
    try testing.expectEqual(PollAction{ .wait = 1 }, pollAction(1, 200, try reply(ar, 1)));
    try testing.expectEqual(PollAction.scanned, pollAction(1, 200, try reply(ar, 2)));
    try testing.expectEqual(PollAction{ .wait = 2 }, pollAction(2, 200, try reply(ar, 2)));
    try testing.expectEqual(PollAction.confirmed, pollAction(2, 200, try reply(ar, 4)));
    try testing.expectEqual(PollAction{ .refresh = 350 }, pollAction(1, 200, try reply(ar, 0)));
    try testing.expectEqual(PollAction{ .refresh = 0 }, pollAction(2, 200, try reply(ar, 3)));
    try testing.expectEqual(PollAction{ .failed = .expired }, pollAction(2, 400, try parse(ar, "{\"code\":1190}")));
}

test "poll failures never imply expiry or confirmation" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    for ([_]i64{ 1, 2 }) |last| {
        for ([_][]const u8{ "null", "{\"code\":1}", "{\"code\":0,\"data\":{\"status\":4}}" }) |body|
            try testing.expectEqual(PollAction{ .failed = .query_failed }, pollAction(last, 503, try parse(ar, body)));
        try testing.expectEqual(PollAction{ .failed = .query_failed }, pollAction(last, 200, try parse(ar, "{\"code\":1}")));
        try testing.expectEqual(PollAction{ .failed = .query_failed }, pollAction(last, 200, null));
        for ([_][]const u8{ "null", "{}", "{\"status\":\"4\"}", "{\"status\":99}", "{\"status\":-1}" }) |data| {
            const body = try std.fmt.allocPrint(ar, "{{\"code\":0,\"data\":{s}}}", .{data});
            try testing.expectEqual(PollAction{ .failed = .unexpected }, pollAction(last, 200, try parse(ar, body)));
        }
    }
}

test "status ticket prefers status_query_ticket" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try testing.expectEqualStrings("new", qrTicket(try parse(ar, "{\"token\":\"old\",\"status_query_ticket\":\"new\"}")).?);
    try testing.expectEqualStrings("old", qrTicket(try parse(ar, "{\"token\":\"old\"}")).?);
    try testing.expect(qrTicket(try parse(ar, "{\"status_query_ticket\":\"\"}")) == null);
}

test "parsePhone" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const cn = (try parsePhone(ar, " 138-0000 0000 ")).?;
    try testing.expectEqualStrings("86", cn.country_code);
    try testing.expectEqualStrings("13800000000", cn.number);
    const hk = (try parsePhone(ar, "+852 1234 5678")).?;
    try testing.expectEqualStrings("852", hk.country_code);
    try testing.expectEqualStrings("12345678", hk.number);
    for ([_][]const u8{ "", "+", "+12345 6789012", "1234", "1380000000a", "+86", "1234567890123456" }) |bad|
        try testing.expectEqual(@as(?Phone, null), try parsePhone(ar, bad));
}

test "csrf is read from the JWT payload" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const payload = "{\"sub\":\"u\",\"csrf\":\"c-1\"}";
    var enc: [64]u8 = undefined;
    const p = std.base64.url_safe_no_pad.Encoder.encode(&enc, payload);
    try testing.expectEqualStrings("c-1", csrfFromToken(ar, try std.fmt.allocPrint(ar, "h.{s}.s", .{p})).?);
    try testing.expectEqualStrings("c-1", csrfFromToken(ar, try std.fmt.allocPrint(ar, "h.{s}==.s", .{p})).?);
    try testing.expect(csrfFromToken(ar, "bad") == null);
}

test "uuid shape and helpers" {
    const u = randomUuid(testing.io);
    try testing.expectEqual(@as(u8, '4'), u[14]);
    try testing.expectEqual(@as(u8, '-'), u[8]);
    try testing.expectEqualStrings("Ubuntu 24.04 LTS", lineValue("NAME=x\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n", "PRETTY_NAME", '=').?);
    try testing.expectEqualStrings("Intel X", lineValue("model name\t: Intel X\n", "model name", ':').?);
    try testing.expect(lineValue("model names: y", "model name", ':') == null);
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("0A-1B-00-FF-EE-01", try formatMac(a.allocator(), &.{ 0x0a, 0x1b, 0, 0xff, 0xee, 1 }));
}
