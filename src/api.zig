// SPDX-License-Identifier: GPL-3.0-or-later
//! UU cloud REST client (spec §5): request signing, headers, timeouts, envelope and error mapping.
//! Upstream: src/auth.rs (`sign_request`, `build_headers`), src/viewer/api.rs.
//! Never logs tokens, csrf, tickets or response bodies.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Config = @import("config.zig").Config;

pub const base_url = "https://api.nrd.nie.163.com";

/// Request-signing key built into the official UU PC client; the same for every user.
/// Config `sign_key` overrides it if NetEase rotates the key.
pub const default_sign_key = "alWiSzXZTLu3WfFnw13uBru3";

/// API code for an invalid or expired login token.
pub const code_token_invalid = 1120;

pub const user_agent = "UURemote/4.42.0 (Windows NT 10.0; Win64; x64)";

pub const Param = struct { name: []const u8, value: []const u8 };

/// Lowercase hex HMAC-SHA256 over `UPPER(method) + path + "k=v&k=v" + body`; `params` are the
/// x-param-* headers (names lowercase), in any order.
pub fn sign(key: []const u8, method: []const u8, path: []const u8, params: []const Param, body: []const u8) [64]u8 {
    var sorted_buf: [16]Param = undefined;
    std.debug.assert(params.len <= sorted_buf.len);
    const sorted = sorted_buf[0..params.len];
    @memcpy(sorted, params);
    std.mem.sortUnstable(Param, sorted, {}, struct {
        fn lt(_: void, a: Param, b: Param) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var mac = HmacSha256.init(key);
    for (method) |ch| mac.update(&.{std.ascii.toUpper(ch)});
    mac.update(path);
    for (sorted, 0..) |p, i| {
        if (i != 0) mac.update("&");
        mac.update(p.name);
        mac.update("=");
        mac.update(p.value);
    }
    mac.update(body);
    var out: [HmacSha256.mac_length]u8 = undefined;
    mac.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

/// The signed x-param-* headers and the other request headers, as `build_headers` sends them.
pub const Headers = struct {
    /// Storage for header values that are not borrowed from the config.
    ts_buf: [20]u8 = undefined,
    sign_buf: [64]u8 = undefined,
    bearer_buf: [4096]u8 = undefined,
    cookie_buf: [8192]u8 = undefined,
    list: [24]std.http.Header = undefined,
    len: usize = 0,

    pub fn slice(h: *const Headers) []const std.http.Header {
        return h.list[0..h.len];
    }

    fn add(h: *Headers, name: []const u8, value: []const u8) void {
        h.list[h.len] = .{ .name = name, .value = value };
        h.len += 1;
    }

    pub fn get(h: *const Headers, name: []const u8) ?[]const u8 {
        for (h.slice()) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
        return null;
    }
};

pub const HeaderError = error{CredentialTooLong};

/// Fills `h` for one request. `ts` is Unix time in seconds.
pub fn buildHeaders(h: *Headers, cfg: *const Config, method: []const u8, path: []const u8, body: []const u8, ts: i64) HeaderError!void {
    h.len = 0;
    var params: [16]Param = undefined;
    var n: usize = 0;
    const fixed = [_]Param{
        .{ .name = "x-param-plat", .value = "1" },
        .{ .name = "x-param-vn", .value = "4.42.0.2770" },
        .{ .name = "x-param-vc", .value = "2770" },
        .{ .name = "x-param-pkgn", .value = "com.netease.gameviewer" },
        .{ .name = "x-param-chn", .value = "gwqd" },
        .{ .name = "x-param-lang", .value = "zh-CN" },
        .{ .name = "x-param-cnt", .value = "CN" },
    };
    for (fixed) |p| {
        params[n] = p;
        n += 1;
    }
    // Identifiers that do not exist yet are neither sent nor signed.
    const ids = [_]Param{
        .{ .name = "x-param-client-id", .value = cfg.client_id },
        .{ .name = "x-param-device-id", .value = cfg.device_id },
        .{ .name = "x-param-system-id", .value = cfg.system_id },
        .{ .name = "x-param-user-id", .value = cfg.user_id },
    };
    for (ids) |p| if (p.value.len != 0) {
        params[n] = p;
        n += 1;
    };
    params[n] = .{ .name = "x-param-ts", .value = std.fmt.bufPrint(&h.ts_buf, "{d}", .{ts}) catch unreachable };
    n += 1;

    const key = if (cfg.sign_key.len != 0) cfg.sign_key else default_sign_key;
    h.sign_buf = sign(key, method, path, params[0..n], body);

    h.add("Accept", "application/json");
    if (cfg.token.len != 0) {
        h.add("Authorization", std.fmt.bufPrint(&h.bearer_buf, "Bearer {s}", .{cfg.token}) catch return error.CredentialTooLong);
        h.add("Cookie", std.fmt.bufPrint(&h.cookie_buf, "nrd_access_token={s}; nrd_csrf_access_token={s}", .{ cfg.token, cfg.csrf }) catch
            return error.CredentialTooLong);
        h.add("X-CSRF-TOKEN", cfg.csrf);
    }
    for (params[0..n]) |p| h.add(p.name, p.value);
    h.add("X-Param-SIGN", &h.sign_buf);
}

/// Why the last call failed, safe to show: never contains bodies, tokens or messages.
pub const Failure = struct {
    status: u16 = 0,
    code: ?i64 = null,
    /// Server `msg`, truncated. Shown only for non-login endpoints (room join).
    msg_buf: [384]u8 = undefined,
    msg_len: usize = 0,

    pub fn msg(f: *const Failure) []const u8 {
        return f.msg_buf[0..f.msg_len];
    }

    pub fn format(f: Failure, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("http {d}", .{f.status});
        if (f.code) |c| try w.print(", api code {d}", .{c});
    }
};

pub const CallError = error{
    /// API code 1120: the login token is invalid or expired.
    NotSignedIn,
    /// HTTP status != 200 or code != 0; see `Client.failure`.
    ApiError,
    /// The response was not a JSON envelope.
    BadResponse,
    Timeout,
    /// TCP/TLS/HTTP transport failure.
    Network,
    ConcurrencyUnavailable,
} || HeaderError || Allocator.Error || Io.Cancelable;

pub const Client = struct {
    io: Io,
    gpa: Allocator,
    http: std.http.Client,
    cfg: *const Config,
    /// Overridable for tests.
    base: []const u8 = base_url,
    failure: Failure = .{},
    /// Name of the transport error behind `error.Network`, for messages.
    network_error: ?anyerror = null,

    /// `proxy_env`: honor HTTP(S)_PROXY (UUCLI_USE_PROXY=1); `arena` holds the proxy config.
    pub fn init(c: *Client, io: Io, gpa: Allocator, cfg: *const Config, proxy: ?struct { arena: Allocator, env: *const std.process.Environ.Map }) !void {
        c.* = .{ .io = io, .gpa = gpa, .http = .{ .allocator = gpa, .io = io }, .cfg = cfg };
        if (proxy) |p| try c.http.initDefaultProxies(p.arena, p.env);
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    pub const Method = enum { GET, POST };

    pub const Response = struct {
        parsed: std.json.Parsed(std.json.Value),
        /// `data` of the envelope (`.null` if absent).
        data: std.json.Value,

        pub fn deinit(r: *Response) void {
            r.parsed.deinit();
        }
    };

    /// Signed request with `body` sent verbatim (empty = no body, signed as ""). Succeeds only on
    /// HTTP 200 with `code == 0`.
    pub fn call(c: *Client, method: Method, path: []const u8, body: []const u8, timeout: Io.Duration) CallError!Response {
        c.failure = .{};
        c.network_error = null;
        var headers: Headers = .{};
        const now = Io.Clock.real.now(c.io).toSeconds();
        try buildHeaders(&headers, c.cfg, @tagName(method), path, body, now);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ c.base, path }) catch return error.BadResponse;
        var out: Io.Writer.Allocating = .init(c.gpa);
        defer out.deinit();
        const status = try c.fetchTimeout(.{
            .location = .{ .url = url },
            .method = switch (method) {
                .GET => .GET,
                .POST => .POST,
            },
            .payload = if (method == .POST) body else null,
            .keep_alive = false,
            .response_writer = &out.writer,
            .headers = .{ .user_agent = .{ .override = user_agent }, .content_type = .{ .override = "application/json" } },
            .extra_headers = headers.slice(),
        }, timeout);
        c.failure.status = status;

        var parsed = std.json.parseFromSlice(std.json.Value, c.gpa, out.written(), .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.BadResponse,
        };
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.BadResponse;
        const obj = parsed.value.object;
        const code: ?i64 = if (obj.get("code")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        c.failure.code = code;
        if (obj.get("msg")) |m| if (m == .string) {
            // At most 120 characters, as upstream; never cut inside a UTF-8 sequence.
            var n: usize = 0;
            var chars: usize = 0;
            var view = std.unicode.Utf8View.init(m.string) catch std.unicode.Utf8View.initUnchecked("");
            var it = view.iterator();
            while (it.nextCodepointSlice()) |cp| {
                if (chars == 120 or n + cp.len > c.failure.msg_buf.len) break;
                @memcpy(c.failure.msg_buf[n..][0..cp.len], cp);
                n += cp.len;
                chars += 1;
            }
            c.failure.msg_len = n;
        };
        if (code == code_token_invalid) return error.NotSignedIn;
        if (status != 200 or code != 0) return error.ApiError;
        return .{ .parsed = parsed, .data = obj.get("data") orelse .null };
    }

    const FetchError = std.http.Client.FetchError;

    fn fetchTimeout(c: *Client, options: std.http.Client.FetchOptions, timeout: Io.Duration) CallError!u16 {
        const U = union(enum) {
            done: FetchError!std.http.Client.FetchResult,
            timeout: Io.Cancelable!void,
        };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(c.io, &buf);
        try sel.concurrent(.done, std.http.Client.fetch, .{ &c.http, options });
        sel.concurrent(.timeout, Io.sleep, .{ c.io, timeout, .awake }) catch |err| {
            sel.cancelDiscard();
            return err;
        };
        const first = sel.await() catch |err| {
            sel.cancelDiscard();
            return err;
        };
        sel.cancelDiscard();
        switch (first) {
            .timeout => return error.Timeout,
            .done => |r| {
                const res = r catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.OutOfMemory => |e| return e,
                    else => |e| {
                        c.network_error = e;
                        return error.Network;
                    },
                };
                return @intFromEnum(res.status);
            },
        }
    }
};

/// String field of a JSON object, or null when absent or not a string.
pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Integer field of a JSON object, or null.
pub fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    return switch (v.object.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

pub const Platform = union(enum) {
    windows,
    mac,
    unknown: i64,

    pub fn from(n: i64) Platform {
        return switch (n) {
            1 => .windows,
            4 => .mac,
            else => .{ .unknown = n },
        };
    }

    pub fn format(p: Platform, w: *Io.Writer) Io.Writer.Error!void {
        switch (p) {
            .windows => try w.writeAll("windows"),
            .mac => try w.writeAll("mac"),
            .unknown => |n| try w.print("unknown({d})", .{n}),
        }
    }
};

pub const Device = struct {
    id: []const u8,
    name: []const u8,
    platform: Platform,
    online: bool,
    shared: bool,
};

/// Devices of the account (spec §5.4), minus uucli itself (`current_device` and `own_id`).
/// Strings point into `data`.
pub fn parseDevices(arena: Allocator, data: std.json.Value, own_id: []const u8) Allocator.Error![]Device {
    var out: std.ArrayList(Device) = .empty;
    const current: []const u8 = if (data == .object) if (data.object.get("current_device")) |cd| str(cd, "device_id") orelse "" else "" else "";
    for ([_]struct { key: []const u8, shared: bool }{
        .{ .key = "my_binded_devices", .shared = false },
        .{ .key = "others_shared_devices", .shared = true },
    }) |group| {
        if (data != .object) break;
        const list = data.object.get(group.key) orelse continue;
        if (list != .array) continue;
        for (list.array.items) |d| {
            const id = str(d, "device_id") orelse continue;
            if (id.len == 0) continue;
            if (std.mem.eql(u8, id, own_id) or std.mem.eql(u8, id, current)) continue;
            const alias = str(d, "alias") orelse "";
            try out.append(arena, .{
                .id = id,
                .name = if (alias.len != 0) alias else id,
                .platform = .from(int(d, "platform") orelse 0),
                .online = std.mem.eql(u8, str(d, "status") orelse "", "CONNECTED"),
                .shared = group.shared,
            });
        }
    }
    return out.items;
}

pub const Resolution = union(enum) {
    found: Device,
    not_found,
    /// More than one display-name match; the candidates.
    ambiguous: []const Device,
};

/// `DEVICE` resolution (spec §3.3): exact id, else exact case-insensitive display name.
pub fn resolveDevice(arena: Allocator, devices: []const Device, query: []const u8) Allocator.Error!Resolution {
    for (devices) |d| if (std.mem.eql(u8, d.id, query)) return .{ .found = d };
    var matches: std.ArrayList(Device) = .empty;
    for (devices) |d| if (std.ascii.eqlIgnoreCase(d.name, query)) try matches.append(arena, d);
    return switch (matches.items.len) {
        0 => .not_found,
        1 => .{ .found = matches.items[0] },
        else => .{ .ambiguous = matches.items },
    };
}

pub const Room = struct {
    token: []const u8,
    signaling_list: []const []const u8,
    /// 0 = use the default.
    ws_connect_timeout_ms: i64,
    publisher_platform: ?i64,
};

pub const JoinError = error{
    /// API 2002: the host is already being controlled from another device.
    DeviceBusy,
    /// Join refused or no usable room; see `Client.failure`.
    JoinFailed,
} || CallError;

/// Percent-encodes a device id as one path segment (unreserved characters kept).
pub fn pathSegment(buf: []u8, device: []const u8) error{InvalidDevice}![]const u8 {
    if (device.len == 0 or std.mem.eql(u8, device, ".") or std.mem.eql(u8, device, "..")) return error.InvalidDevice;
    var n: usize = 0;
    for (device) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~", b) != null) {
            if (n + 1 > buf.len) return error.InvalidDevice;
            buf[n] = b;
            n += 1;
        } else {
            if (n + 3 > buf.len) return error.InvalidDevice;
            _ = std.fmt.bufPrint(buf[n..][0..3], "%{X:0>2}", .{b}) catch unreachable;
            n += 3;
        }
    }
    return buf[0..n];
}

/// Codes that are not retried (upstream `retry_delay`); -1 = no code.
fn retryable(code: i64) bool {
    return for ([_]i64{ -1, 2002, 2006, 2007, 4042 }) |c| {
        if (c == code) break false;
    } else true;
}

/// `POST /api/v1/room/join/by_device/{id}` with up to 5 retries 3 s apart (spec §6.1). The room
/// strings are copied into `arena`.
pub fn joinRoom(c: *Client, arena: Allocator, device: []const u8) (JoinError || error{InvalidDevice})!Room {
    var seg_buf: [512]u8 = undefined;
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/api/v1/room/join/by_device/{s}", .{try pathSegment(&seg_buf, device)}) catch return error.InvalidDevice;
    var retries: usize = 0;
    while (true) {
        var resp = c.call(.POST, path, "{\"force_join\":false}", .fromSeconds(15)) catch |err| switch (err) {
            error.ApiError => {
                const code: i64 = if (c.failure.code) |k| (if (k == 0) c.failure.status else k) else -1;
                if (code == 2002) return error.DeviceBusy;
                if (retries < 5 and retryable(code)) {
                    retries += 1;
                    std.log.scoped(.api).info("room join refused (api code {d}), retry {d}/5", .{ code, retries });
                    try c.io.sleep(.fromSeconds(3), .awake);
                    continue;
                }
                return error.JoinFailed;
            },
            else => |e| return e,
        };
        defer resp.deinit();
        const d = resp.data;
        if (d != .object) return error.JoinFailed;
        // Required by upstream's schema although unused.
        if (str(d, "report_token") == null or str(d, "report_url") == null) return error.BadResponse;
        const token = str(d, "token") orelse "";
        var list: std.ArrayList([]const u8) = .empty;
        if (d.object.get("signaling_list")) |l| if (l == .array) for (l.array.items) |u| if (u == .string)
            try list.append(arena, try arena.dupe(u8, u.string));
        if (token.len == 0 or list.items.len == 0) return error.JoinFailed;
        return .{
            .token = try arena.dupe(u8, token),
            .signaling_list = list.items,
            .ws_connect_timeout_ms = int(d, "ws_connect_timeout_ms") orelse 0,
            .publisher_platform = int(d, "publisher_platform"),
        };
    }
}

const testing = std.testing;

test "pathSegment" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aeaw-._~9", try pathSegment(&buf, "aeaw-._~9"));
    try testing.expectEqualStrings("a%2Fb%3F%20%E4%B8%AD", try pathSegment(&buf, "a/b? 中"));
    try testing.expectError(error.InvalidDevice, pathSegment(&buf, ".."));
    try testing.expectError(error.InvalidDevice, pathSegment(&buf, ""));
}

test "sign matches the upstream algorithm" {
    // HMAC-SHA256("k", "POST/p" + "a=1&b=2" + "{}")
    const got = sign("k", "post", "/p", &.{ .{ .name = "b", .value = "2" }, .{ .name = "a", .value = "1" } }, "{}");
    var expect_mac: [32]u8 = undefined;
    HmacSha256.create(&expect_mac, "POST/pa=1&b=2{}", "k");
    try testing.expectEqualStrings(&std.fmt.bytesToHex(expect_mac, .lower), &got);
}

test "buildHeaders omits empty ids and token headers" {
    var h: Headers = .{};
    const cfg: Config = .{ .client_id = "c" };
    try buildHeaders(&h, &cfg, "POST", "/api/v1/qrcode/gen/login", "", 1700000000);
    try testing.expectEqualStrings("c", h.get("x-param-client-id").?);
    try testing.expect(h.get("x-param-device-id") == null);
    try testing.expect(h.get("x-param-user-id") == null);
    try testing.expect(h.get("Authorization") == null);
    try testing.expect(h.get("Cookie") == null);
    try testing.expectEqualStrings("1700000000", h.get("x-param-ts").?);

    var params: [16]Param = undefined;
    var n: usize = 0;
    for (h.slice()) |x| if (std.mem.startsWith(u8, x.name, "x-param-")) {
        params[n] = .{ .name = x.name, .value = x.value };
        n += 1;
    };
    try testing.expectEqual(@as(usize, 9), n);
    const expect = sign(default_sign_key, "POST", "/api/v1/qrcode/gen/login", params[0..n], "");
    try testing.expectEqualStrings(&expect, h.get("X-Param-SIGN").?);
}

test "buildHeaders with token" {
    var h: Headers = .{};
    const cfg: Config = .{ .client_id = "c", .device_id = "d", .system_id = "S", .user_id = "u", .token = "T", .csrf = "X", .sign_key = "custom" };
    try buildHeaders(&h, &cfg, "GET", "/api/v1/device/list", "", 1);
    try testing.expectEqualStrings("Bearer T", h.get("authorization").?);
    try testing.expectEqualStrings("nrd_access_token=T; nrd_csrf_access_token=X", h.get("cookie").?);
    try testing.expectEqualStrings("X", h.get("x-csrf-token").?);
    try testing.expectEqualStrings("u", h.get("x-param-user-id").?);
    const params = [_]Param{
        .{ .name = "x-param-plat", .value = "1" },         .{ .name = "x-param-vn", .value = "4.42.0.2770" },
        .{ .name = "x-param-vc", .value = "2770" },        .{ .name = "x-param-pkgn", .value = "com.netease.gameviewer" },
        .{ .name = "x-param-chn", .value = "gwqd" },       .{ .name = "x-param-lang", .value = "zh-CN" },
        .{ .name = "x-param-cnt", .value = "CN" },         .{ .name = "x-param-client-id", .value = "c" },
        .{ .name = "x-param-device-id", .value = "d" },    .{ .name = "x-param-system-id", .value = "S" },
        .{ .name = "x-param-user-id", .value = "u" },      .{ .name = "x-param-ts", .value = "1" },
    };
    try testing.expectEqualStrings(&sign("custom", "GET", "/api/v1/device/list", &params, ""), h.get("X-Param-SIGN").?);
}

test "parseDevices and resolveDevice" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const data = try std.json.parseFromSliceLeaky(std.json.Value, ar,
        \\{"current_device":{"device_id":"self"},
        \\ "my_binded_devices":[
        \\   {"device_id":"aeaw","alias":"office-pc","platform":1,"status":"CONNECTED"},
        \\   {"device_id":"self","alias":"uucli@x","platform":1,"status":"CONNECTED"},
        \\   {"device_id":"own","alias":"uucli@y","platform":1,"status":"CONNECTED"},
        \\   {"device_id":"m1","alias":"","platform":4,"status":"OFFLINE"},
        \\   {"device_id":"dup1","alias":"Lab","platform":7}],
        \\ "others_shared_devices":[{"device_id":"dup2","alias":"lab","platform":1,"status":"CONNECTED"}]}
    , .{});
    const devs = try parseDevices(ar, data, "own");
    try testing.expectEqual(@as(usize, 4), devs.len);
    try testing.expectEqualStrings("office-pc", devs[0].name);
    try testing.expect(devs[0].online and !devs[0].shared);
    try testing.expectEqualStrings("m1", devs[1].name);
    try testing.expectEqual(Platform.mac, devs[1].platform);
    try testing.expectEqual(Platform{ .unknown = 7 }, devs[2].platform);
    try testing.expect(devs[3].shared);

    try testing.expectEqualStrings("aeaw", (try resolveDevice(ar, devs, "aeaw")).found.id);
    try testing.expectEqualStrings("aeaw", (try resolveDevice(ar, devs, "OFFICE-PC")).found.id);
    try testing.expectEqual(@as(usize, 2), (try resolveDevice(ar, devs, "LAB")).ambiguous.len);
    try testing.expect((try resolveDevice(ar, devs, "office")) == .not_found);
}

/// Accepts one connection, reads the request head and answers with `reply` (never, if null).
fn fakeServer(server: *std.Io.net.Server, io: Io, reply: ?[]const u8) void {
    const conn = server.accept(io) catch return;
    defer conn.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    // Request head ends with an empty line; the body is empty in these tests.
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return;
        if (line.len <= 2) break;
    }
    const body = reply orelse {
        io.sleep(.fromSeconds(5), .awake) catch {};
        return;
    };
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        if (std.mem.indexOf(u8, body, "1120") != null) "422 Unprocessable Entity" else "200 OK", body.len, body,
    }) catch return;
    w.interface.flush() catch {};
}

fn testCall(reply: ?[]const u8, timeout: Io.Duration) CallError!Client.Response {
    const io = testing.io;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = addr.listen(io, .{}) catch unreachable;
    defer server.deinit(io);
    var task = io.concurrent(fakeServer, .{ &server, io, reply }) catch unreachable;
    defer task.cancel(io);
    var base_buf: [64]u8 = undefined;
    const cfg: Config = .{};
    var c: Client = undefined;
    c.init(io, testing.allocator, &cfg, null) catch unreachable;
    defer c.deinit();
    c.base = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()}) catch unreachable;
    return c.call(.POST, "/api/v1/x", "", timeout);
}

test "call maps envelopes and times out" {
    {
        var r = try testCall("{\"code\":0,\"msg\":\"\",\"data\":{\"device_id\":\"d1\"}}", .fromSeconds(5));
        defer r.deinit();
        try testing.expectEqualStrings("d1", str(r.data, "device_id").?);
    }
    try testing.expectError(error.NotSignedIn, testCall("{\"code\":1120,\"msg\":\"x\"}", .fromSeconds(5)));
    try testing.expectError(error.ApiError, testCall("{\"code\":7,\"msg\":\"x\"}", .fromSeconds(5)));
    try testing.expectError(error.BadResponse, testCall("<html>", .fromSeconds(5)));
    try testing.expectError(error.Timeout, testCall(null, .fromMilliseconds(200)));
}
