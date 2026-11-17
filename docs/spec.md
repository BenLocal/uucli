# uucli specification

## 1. Goal

uucli is a headless UU Remote (网易UU远程) **controller** CLI written in Zig. It runs on Linux and macOS,
signs in with a UU account, and gives the user, against a device bound to that account or a host
that offers remote assistance (share id and code, §5.5):

- a TCP port forward (`portmap`, `proxy`), so ssh / scp / rsync / VS Code Remote work over UU Remote;
- a remote terminal attached to the current tty (`terminal`);
- single-file transfer (`files`).

Non-goals: remote desktop, audio/video, clipboard, gamepad, any GUI, acting as a controlled host
(including offering remote assistance), Windows as the uucli platform.

## 2. Fixed decisions

| Topic | Decision |
| --- | --- |
| Language / toolchain | Zig **0.17.1**, pinned via `minimum_zig_version` in `build.zig.zon`. Install with zvm or mise. Upgrading Zig is a recorded spec change. |
| License | **GPL-3.0-or-later** (same as upstream). Every source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`. `NOTICE` records the port origin. |
| Upstream reference | VallierDev/uu-remote-linux tag `v0.2.59`, commit `5f28047a341143a033d98be95b0e8152c3e1464d`. Cloned **outside** this repo. Each module names its upstream file (§9). Later upstream changes are tracked in §13. |
| WebRTC | libdatachannel **v0.24.6** (C API), built from source by `build.zig` with libjuice, usrsctp, plog and Mbed TLS; media support off. Statically linked. `-Dsystem-libdatachannel=true` links a system copy instead (for distro packaging). |
| Concurrency | All I/O goes through the `std.Io` interface. libdatachannel callbacks run on its own threads; only `rtc.zig` touches them and hands events to the rest of the program through a thread-safe queue (§8). |
| Controlled hosts | Official **Windows** host is the acceptance gate for M2–M4. Official **Mac** host is tracked per milestone in §12 and must pass (or be documented as unsupported with a reason) before M5. |
| Identity | uucli registers its own device identity, independent of `uuremote-server` / `uuremote-viewer` on the same machine. |
| Accounts | One account per config file. Multiple accounts = multiple files selected with `UUCLI_CONFIG`. |

## 3. Command-line contract

### 3.1 General rules

- Syntax: `uucli [GLOBAL OPTIONS] COMMAND [ARGS]`.
- Global options: `-v` (info), `-vv` (debug), `--version`, `-h/--help`. Default log level is `warn`.
- **stdout carries results only.** Logs, progress, prompts and the login QR code go to stderr.
- Commands that print lists accept `--json` and then print exactly one JSON document on stdout.
- No command ever prints tokens, csrf, QR tickets, room tokens, ICE credentials, terminal contents
  or file contents to logs, at any log level.
- Environment proxies (`HTTP_PROXY` etc.) are ignored by default, as upstream does (a TLS-intercepting
  local proxy breaks login and signaling). `UUCLI_USE_PROXY=1` opts back in.

### 3.2 Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Other error |
| 2 | Usage error: bad arguments, ambiguous `DEVICE`, target file exists without `--force` |
| 3 | Not signed in, or token invalid/expired (API code `1120`) |
| 4 | Device not found in the account, or offline |
| 5 | Connection setup failed: room join, signaling, ICE/DTLS, data channels or echo not ready in time |
| 6 | Remote side refused or timed out: API `2002` (host already being controlled), port-forward target rejected, RPC timeout, remote shell/file error |
| 130 | Interrupted by SIGINT (only where Ctrl-C reaches uucli, i.e. not inside `terminal`) |

SIGTERM ends `portmap` / `proxy` like SIGINT but exits 0, so a service manager stopping the unit
sees a clean exit. SIGPIPE is ignored: a closed local socket or stdout is a write error.

### 3.3 `DEVICE` resolution

`DEVICE` is resolved against `GET /api/v1/device/list` (both `my_binded_devices` and
`others_shared_devices`):

1. Exact match on `device_id`.
2. Otherwise exact, case-insensitive match on the display name (`alias`, falling back to `device_id`).
3. More than one name match → exit 2 and list the candidates (id, name, platform) on stderr.
4. No match → the same two steps against the account's remote-assistance favorites (§5.5): exact
   `connect_id`, else exact case-insensitive `remark` (falling back to `connect_id`). A match joins
   by share id and code (§6.1); more than one name match → exit 2.
5. No match → exit 4.

No fuzzy or prefix matching. A matched account device that is offline → exit 4.

`--assist` (accepted by `portmap`, `proxy`, `terminal`, `exec`, `files`) skips the lookup: `DEVICE`
is a share id, joined by code.

### 3.4 Commands

| Command | Milestone | Behavior |
| --- | --- | --- |
| `uucli login [--qr \| --phone]` | M1 | QR sign-in (§5.3), or phone number and SMS code (§5.3.1). Without a flag, on a terminal it asks which (`Choice [1]:`, empty = QR, three wrong answers → exit 1); without a terminal it uses QR. Prompts and the QR go to stderr. On success prints `Signed in as NAME (USER_ID)` to stderr; stdout stays empty. |
| `uucli logout` | M1 | Clears `user_id`, `token`, `csrf`, `account_name`. Keeps the device identity so the next login reuses the same device. Local only, no API call. |
| `uucli device list [--json]` | M1 | Lists account devices (§5.4). |
| `uucli fav list [--recent] [--json]` | — | Lists the account's remote-assistance favorites, or with `--recent` the recently connected hosts (§5.5). Columns `ID NAME FAVORITE CODE`; `CODE` is `saved` when a code is in the config. JSON: `[{"id", "name", "favorite", "code_saved"}]`. |
| `uucli fav add ID [NAME] [--save-code]` | — | Adds share `ID` to the favorites with remark `NAME` (§5.5). `--save-code` also stores its code in the config (§5.6). Adding an existing favorite again replaces its remark (verified 2026-11-16), so this also renames. |
| `uucli fav edit NAME\|ID [NEW_NAME] [--save-code]` | — | Changes a favorite (resolved like §3.3 step 4; exit 4 when absent): `NEW_NAME` re-adds it with that remark and its original `favorited_at`; `--save-code` replaces the code in the config. At least one of the two, else exit 2. |
| `uucli fav rm\|remove NAME\|ID` | — | Removes a favorite (resolved like §3.3 step 4; exit 4 when absent) and its saved code. |
| `uucli portmap DEVICE -L [BIND:]LPORT:HOST:PORT [-L ...] [--no-reconnect] [--no-mux]` | M2 | Forwards local TCP ports to `HOST:PORT` as seen from the controlled host. `BIND` defaults to `127.0.0.1`. `LPORT` 0 picks a free port; the chosen ports are printed on stderr as `Listening on BIND:PORT -> HOST:PORT`. Runs until SIGINT/SIGTERM. |
| `uucli proxy [--no-mux] DEVICE HOST PORT` | M2 | Opens one forwarded stream and connects it to stdin/stdout, for `ProxyCommand`. By default the stream goes through the shared session of DEVICE (§7.2); `--no-mux` opens a session of its own. Exits when the stream ends. |
| `uucli terminal DEVICE [SESSION] [-e CHAR\|none]` | M3 | Attaches the current tty to a remote PTY (§11.1). |
| `uucli terminal DEVICE --list [--json]` | M3 | Lists remote terminal sessions. |
| `uucli terminal DEVICE --kill SESSION` | M3 | Ends a remote terminal session. |
| `uucli exec DEVICE [--timeout SECONDS] [--json] [--] COMMAND...` | M3 | Runs one command in a new remote terminal and prints its output (§11.1.1). Exits with the remote exit code. |
| `uucli files DEVICE ls REMOTE_DIR [--json]` | M4 | Lists one remote directory. |
| `uucli files DEVICE get REMOTE LOCAL [--force]` | M4 | Downloads one file. |
| `uucli files DEVICE put LOCAL REMOTE [--force]` | M4 | Uploads one file. |
| `uucli debug device-info` / `debug rtc-loopback` | — | Diagnostics, not a stable interface: the machine fields of §5.2; the M0 WebRTC self test. |

### 3.5 Short forms

Fixed aliases, accepted everywhere the long form is. There is no prefix matching, so adding a
command never changes what an existing abbreviation means.

| Short | Long |
| --- | --- |
| `dev` | `device` |
| `ls` | `device list`, `files DEVICE list` (`files` takes `ls` and `list`) |
| `pm` | `portmap` |
| `px` | `proxy` |
| `term` | `terminal` |
| `fs` | `files` |
| `x` | `exec` |
| `-j` | `--json` |
| `-l` | `--list` |
| `-k` | `--kill` |
| `-f` | `--force` |
| `-n` | `--no-reconnect` |
| `-t` | `--timeout` |

`fav` and `--assist` have no short form.

`login` and `logout` have no short form: login is an interactive QR flow, and logout drops the
account, so neither should be typed by accident.

`ssh` integration example (documented in README at M2):

```sshconfig
Host office-pc
    User me
    ProxyCommand uucli proxy aeawswhnguarjyo6 127.0.0.1 22
```

## 4. Configuration

| Item | Value |
| --- | --- |
| Path | `$UUCLI_CONFIG`, else `$XDG_CONFIG_HOME/uucli/config.json`, else `~/.config/uucli/config.json` (macOS too) |
| Permissions | file `0600`, directory `0700`; uucli refuses to read a config readable by group/other and says how to fix it |
| Writes | write `config.json.tmp` (0600) → fsync → rename |
| Locking | Lock files are named after the config file's stem (`config.json` → `config.lock`, `config.login.lock`). Blocking `flock` on `STEM.lock` around device registration and login (and `logout`, and saving codes in `fav add` / `fav rm`), so two processes cannot register two devices |

```json
{
  "client_id": "uuid v4, lowercase",
  "system_id": "uuid v4, uppercase",
  "machine_guid": "see §5.2",
  "device_id": "assigned by device/windows/init",
  "user_id": "",
  "token": "JWT access token",
  "csrf": "csrf claim from the token",
  "account_name": "nickname, display only",
  "sign_key": "optional override; default is upstream DEFAULT_SIGN_KEY",
  "assist_codes": [{"id": "share id", "code": "enc:v1:BASE64_NONCE_TAG_CIPHERTEXT"}]
}
```

`assist_codes` is written only when non-empty.

Saved assistance codes are encrypted with the Zig standard library's XChaCha20-Poly1305.
Each save uses a fresh 24-byte nonce from `Io.randomSecure`; the share id is authenticated
as associated data. The `code` field is `enc:v1:` followed by standard base64 of
`nonce[24] || tag[16] || ciphertext`. Plaintext exists only in memory during use.
The random 32-byte key is stored in `CONFIG_PATH.key` (for example `config.json.key`),
mode 0600, created exclusively and synced before encrypted configuration is written.
The key is created only when saving codes, never when loading encrypted data.
Missing, malformed, or group/other-accessible keys and failed authentication cause a
config load error (exit 1); no fallback to plaintext occurs. Configs without saved
codes need no key. Existing plaintext entries are unsupported and are not migrated.
When stdin and stderr are terminals, loading such a config asks
`... Remove them? [y/N]`; `y`/`yes` removes the plaintext entries (encrypted ones stay), prints
`Removed N saved remote code(s); enter them again when asked` on stderr and continues. Any other
answer, or no terminal, is the load error (exit 1); remove the old `assist_codes` entries by hand
and enter the codes again.

The key must accompany the config when restoring encrypted codes. Copying the config
alone does not expose the saved passwords. Anyone who can read both files can decrypt
them. Account tokens and other config fields remain unchanged and are not encrypted.


uucli does not read `~/.config/uuremote/config.json` and does not honor upstream `UU_*` variables.

## 5. Cloud API (M1)

Base URL: `https://api.nrd.nie.163.com`. All requests are JSON, HTTP/1.1, timeout 15 s
(QR long-poll requests: 60 s).

### 5.1 Request signing and headers

Upstream: `src/auth.rs` `build_headers`, `sign_request`.

Signed parameter headers (all values strings):

| Header | Value |
| --- | --- |
| `x-param-plat` | `1` |
| `x-param-vn` | `4.42.0.2770` |
| `x-param-vc` | `2770` |
| `x-param-pkgn` | `com.netease.gameviewer` |
| `x-param-chn` | `gwqd` |
| `x-param-lang` | `zh-CN` |
| `x-param-cnt` | `CN` |
| `x-param-client-id`, `x-param-device-id`, `x-param-system-id`, `x-param-user-id` | from config; **omitted when empty** |
| `x-param-ts` | Unix time, seconds |

Signature:

```text
params     = the x-param-* headers above, keys lowercase, sorted by key, joined as "k=v&k=v"
to_sign    = UPPER(method) + path + params + body      (path without host or query; body exactly as sent)
X-Param-SIGN = lowercase hex(HMAC-SHA256(sign_key, to_sign))
```

Other headers: `Content-Type: application/json`, `Accept: application/json`,
`User-Agent: UURemote/4.42.0 (Windows NT 10.0; Win64; x64)`. When a token exists:
`Authorization: Bearer TOKEN`, `Cookie: nrd_access_token=TOKEN; nrd_csrf_access_token=CSRF`,
`X-CSRF-TOKEN: CSRF`.

`sign_key` default is the `DEFAULT_SIGN_KEY` constant in upstream `src/auth.rs` (the key built into the
official PC client, identical for all users). The config field overrides it if NetEase rotates the key.

Response envelope: `{"code": int, "msg": string, "data": any}`. Success is HTTP 200 and `code == 0`.
`code == 1120` anywhere → exit 3 with "run `uucli login`". Error messages shown to the user include
HTTP status and API code; they never echo response bodies of login/QR endpoints.

### 5.2 Device registration

Upstream: `src/login.rs` `prepare_identity`, `prepare_device`.

Runs under the config lock, only when `device_id` is empty. Missing `client_id` / `system_id` /
`machine_guid` are generated and saved first.

`POST /api/v1/device/windows/init` (no token):

```json
{"name": "uucli@HOSTNAME", "client_id": "...", "system_id": "...", "machine_guid": "...",
 "os": "...", "base_board": "...", "cpu": "...", "video": ["..."], "mac": "AA-BB-CC-DD-EE-FF",
 "memory": 16384, "screen": "1920x1080"}
```

| Field | Linux | macOS |
| --- | --- | --- |
| `machine_guid` | `/etc/machine-id` formatted as a GUID | `IOPlatformUUID` |
| `os` | `PRETTY_NAME` from `/etc/os-release` | `sw_vers` product name + version |
| `cpu` | `model name` from `/proc/cpuinfo` | `sysctl machdep.cpu.brand_string` |
| `base_board` | `/sys/class/dmi/id/board_{vendor,name}` or `Unknown` | `hw.model` |
| `video` | `["Unknown"]` | `["Unknown"]` |
| `mac` | first interface (by name) with a `/sys/class/net/*/device` link, uppercase, dash form, or empty | first `en*` Ethernet link address (`getifaddrs`) |
| `memory` | MiB | MiB |
| `screen` | `1920x1080` (constant: headless) | `1920x1080` |

`HOSTNAME` is `gethostname()`; on macOS `scutil --get LocalHostName` when set (`gethostname` there often
returns a DHCP name or address). `uucli debug device-info` prints these machine fields without sending them.
If the machine source is unreadable, `machine_guid` is a random UUID. Because it is saved, it stays
the same afterwards. Response: `data.device_id` → saved immediately, even if the QR step is abandoned.

Expected side effect: the account's device list gains one entry named `uucli@HOSTNAME`
(confirmed or corrected in M1, see §13).

### 5.3 QR login

Upstream: `src/login.rs` `flow`, `qr_poll_action`, `qr_ticket`, `csrf_from_token`.

1. `POST /api/v1/qrcode/gen/login` with an **empty body** (sign the empty string).
   `data.qrcode_jump_url` is the QR content. The status ticket is `data.status_query_ticket`,
   falling back to `data.token` only if the key is absent (present but empty = no ticket, exit 1).
2. Render the QR to stderr with Unicode half blocks (2 modules per character row), quiet zone on,
   dark-on-light inverted for dark terminals as upstream does. Below it print
   `Scan with the UU Remote mobile app`.
3. Long-poll `POST /api/v1/qrcode/login/status` with
   `{"token": TICKET, "qrcode_jump_url": URL, "login_status": LAST}` (`LAST` starts at 1), 60 s timeout,
   re-sending as soon as each answer arrives:

   | `data.status` | Action |
   | --- | --- |
   | 1 | keep waiting, `LAST = 1` |
   | 2 | first time: print "scanned, confirm on the phone"; `LAST = 2` |
   | 0 | wait 350 ms, generate a new QR (step 1) |
   | 3 | QR expired: generate a new QR immediately |
   | 4 | confirmed: go to step 4 |
   | API code `1190`, other error, or unknown status | stop; on a tty, "press Enter for a new QR code"; without a tty, exit 1 |

4. `POST /api/v1/login/by_qrcode` with `{"token": TICKET, "qrcode_jump_url": URL}`.
   Save `data.token`, `data.user_id`, `data.nickname` (as `account_name`), and `csrf` = the `csrf` claim
   of the JWT payload (base64url, no padding). Missing token/user_id/csrf → exit 1.

### 5.3.1 Phone login

Source: the official Android app 4.47.0 (requests `/api/v1/security/mobile/code` and
`/api/v1/login/by_mobile`; region default `86`). Not in upstream.

1. Read the phone number from stdin: digits, spaces and dashes; a leading `+CODE` (1–4 digits)
   selects the country code, else `86`; 5–15 digits. Three invalid entries → exit 1.
2. `POST /api/v1/security/mobile/code` with `{"country_code": "86", "mobile": NUMBER, "type": "login"}`.
   An error → exit 1 with the API code and the server message. The server answers success without
   checking the number (observed 2026-11-16 for `00000`).
3. Read the SMS code from stdin (echoed: it is single-use) and
   `POST /api/v1/login/by_mobile` with `{"country_code": "86", "mobile": NUMBER, "code": CODE}`.
   An API error (wrong code) asks again, up to three codes; other errors → exit 1. The server message is
   shown unless it contains the code.
4. The response is the same as `by_qrcode`'s; it is saved as in §5.3 step 4.

Only one login per config file runs at a time (non-blocking `flock` on `STEM.login.lock`; second run exits 1).
The login requests carry only the device identity (`client_id`, `system_id`, `device_id`), never an older token.

### 5.4 Device list

`GET /api/v1/device/list`, empty body. `data` contains `current_device`, `my_binded_devices[]`,
`others_shared_devices[]`. Per device: `device_id`, `alias`, `platform` (1 = Windows, 4 = Mac,
other values printed as `unknown(N)`), `status` (`"CONNECTED"` = online).

Text output (stdout), one row per device, aligned columns:

```text
ID                NAME          PLATFORM  ONLINE  SHARED
aeawswhnguarjyo6  office-pc     windows   yes     no
```

The uucli device itself (`current_device` / own `device_id`) is excluded from the list.

`--json`:

```json
[{"id": "aeawswhnguarjyo6", "name": "office-pc", "platform": "windows", "online": true, "shared": false}]
```

### 5.5 Remote-assistance favorites

Source: the official Android app 4.47.0 (`AssistFavoriteInput`, saved-share requests); response
structure observed live 2026-11-16. A host offering remote assistance gives out a share id
(`connect_id`, e.g. 9 digits) and a code. The account keeps two server-side lists of such hosts,
shared with the official apps:

- `GET /api/v1/device/share/saved/{favorites|recent}`, optional query `cursor`, `limit` (the query is
  part of the signed path). `data`: `{"saved": [...], "next": cursor or null}`. Entry fields:
  `publisher_device_id`, `connect_id`, `remark`, `is_favorite`, `platform` (may be null),
  `last_connected_at` (seconds), `favorited_at` (seconds or null). uucli follows `next` (at most 100
  pages). A host joined by code appears in `recent` by itself.
- `POST /api/v1/device/share/saved/favorites`, body
  `{"favorites": [{"connect_id": ID, "remark": NAME, "favorited_at": NOW_SECONDS}], "skip_invalid": false}`.
  For an existing favorite it replaces the remark (there is no separate edit call in the app).
- `DELETE /api/v1/device/share/saved/{favorites|recent}/{publisher_device_id}`, empty body. Removing a
  favorite also clears its remark in `recent`.

The server never stores the code.

### 5.6 Remote-assistance codes

The code for a share id comes from, in order:

1. `UUCLI_ASSIST_CODE`;
2. the config's `assist_codes` (saved by `fav add --save-code`);
3. a prompt `Code for ID: ` on stderr, read from stdin with echo off, when stdin is a terminal;
4. one line of stdin when it is not a terminal and the command does not use stdin (`exec`, `files`,
   `portmap`, `fav add`).

Otherwise (`proxy`, `terminal` without a terminal) → exit 2 naming the two first sources. The code is
never taken from the command line, where other local users could read it, and never logged. A
temporary code may stop working after it was used; a wrong or expired code fails the join (§6.1).

## 6. Connection setup (M2)

One **session** = one room join + one signaling socket + one PeerConnection, opened for one tool.
Each tool uses its own capture type; a session serves exactly one tool.

| Tool | `capture_type` | Channels the tool waits for |
| --- | --- | --- |
| portmap / proxy | 9 | CONTROL (0), FILE (3) |
| files | 5 | CONTROL (0), FILE (3) |
| terminal | 8 | CONTROL (0), BINARY (4) |

### 6.1 Join the room

Upstream: `src/viewer/api.rs` `join`, `parse_join`, `retry_delay`.

`POST /api/v1/room/join/by_device/{DEVICE_ID}` (path segment percent-encoded except `A-Za-z0-9-._~`),
body `{"force_join": false}`.

Response `data`: `token` (room token), `signaling_list[]` (ws/wss base URLs), `ws_connect_timeout_ms`,
`report_token`, `report_url` (required by schema, unused), `publisher_platform` (optional; 1 Windows, 4 Mac).
Empty `token` or `signaling_list` → exit 5.

Retry: on API error codes other than `-1, 2002, 2006, 2007, 4042`, retry up to 5 times, 3 s apart.
`2002` → exit 6 ("the host is already being controlled from another device").
`1120` → exit 3.

A remote-assistance host (§5.5) is joined by share id and code instead (upstream after the pin,
`src/viewer/api.rs` `join_share`): `POST /api/v2/room/join/share/by_code`, body
`{"connect_id": ID, "connect_code": CODE}`; when v2 answers HTTP 404 or 405, the same request to
`/api/v1/room/join/share/by_code`. Same response as above. A wrong or expired code, or a
host that turned assistance off → HTTP 400 code 1131 → exit 5; the server message is shown unless it
contains the code. Same-account devices cannot assist each other (server message). The join answer's
`publisher_platform` picks the `exec` shell (§11.1.1), since the host is not in the device list.
Assistance sessions skip the device-list check before a `portmap` reconnect (§7.1).

For `terminal` and `exec`, an assistance join rejected with HTTP 400 / API 1131 prompts
for a replacement code when stdin is a terminal, up to three replacements. The prompt also
explains that assistance may be disabled. Other failures and non-interactive calls do not
retry. Each replacement bypasses the environment and saved code. After a session reaches
ready, a code entered interactively (initial or replacement) is saved by share id under
the config lock with mode 0600. Environment-only codes are not automatically saved.
A failed connection leaves the saved code unchanged. Only session setup is retried,
before any terminal operation or remote command runs.


### 6.2 Signaling (Socket.IO over WebSocket)

Upstream: `src/viewer/signal.rs`, `src/ws_transport.rs`.

WebSocket client (`ws.zig`): RFC 6455 client over `std.crypto.tls` (wss) or plain TCP (ws), HTTP/1.1
upgrade, no extensions, no subprotocol. Supports text, binary, ping/pong, close; masks client frames.

Connect to each URL in `signaling_list` in order until one succeeds; per-URL timeout is
`ws_connect_timeout_ms` if > 0, else 12 s.

```text
GET {base}/socket.io/?transport=websocket&EIO=4
X-NRD-AUTH: {room token}
```

Engine.IO / Socket.IO frames (text):

| Frame | Direction | Meaning |
| --- | --- | --- |
| `0{json}` | in | EIO open → reply `40` |
| `40...` | in | Socket.IO connected → handshake done |
| `2...` | in | ping → reply `3` + same suffix |
| `42[name, body]` | both | event |
| `43{id}[...]` | in | ack for request `id` |
| `45{n}-[...]` / `46{n}-{id}[...]` | in | binary event / binary ack followed by `n` binary frames; each `{"_placeholder":true,"num":k}` is replaced by attachment `k` as a base64 string. Strip a leading `0x04` byte when the frame is `0x04 0x1f ...` (legacy prefix on gzip data). Max 8 attachments, 4 MiB each. |
| `41` or `1` | in | room closed → session ends |

### 6.3 Control request

Upstream: `src/viewer/session.rs` `open`, `src/viewer/wire.rs` `Shape::control`, `Shape::connect_options`.

Generate `app_control_id` = random UUID v4. Send a binary event with ack id `N` (start at 11, +1 per request):

```text
text:   451-{N}["control",{"app_control_id":ID,"app_data":{"_placeholder":true,"num":0},"streamer_data":STREAMER}]
binary: 0x04 ++ CONNECT_OPTIONS          (legacy prefix byte, as upstream tool commands send)
```

`STREAMER` is a JSON **string**:
`{"control_id":ID,"device_capability":{"display_info":[],"ice_id":"","video_codec_capability":[]}}`.

`CONNECT_OPTIONS` (protobuf wire, field order exactly as listed; see `connect_options`):

| capture_type 9 / 8 | capture_type 5 |
| --- | --- |
| 1: capture_type (varint) | 1: 5 |
| 2: `u64::MAX` (varint) — **only for 8** | 3: params {1:2, 2:4, 4:2, 5:{1:1920, 2:1080}, 6:empty} |
| 8: platform = 3 | 4: decoder {1:60, 2:1, 3:3840, 4:2160} |
| 9: own `device_id` (bytes) | 6: display mode {1:1920, 2:1080, 3:60} |
| 10: 1 | 7: size {1:1920, 2:1080} |
| 12: client version `4.42.0` (bytes) | 8: 3, 9: device_id, 10: 1 (no field 12) |

Values come from upstream `DEFAULT_SHAPE` in `src/viewer_main.rs`; for capture types 8 and 9 upstream
clears decoders, display modes, displays and codecs, and for all tools it clears the feature flags.
The golden vectors (§10) are the authority on exact bytes.

Wait up to 12 s for ack `N`: it must be `["success", {...}]`. From the ack object:

- `app_control_id`, if present, must equal ours.
- `ice_id`: use it if non-empty (≤ 128 chars); the cloud assigns it.
- `client_id`: remote route, required.
- `iceServers[]`: `{urls: string|string[], username?, credential?}`; URL schemes limited to
  `stun:`, `stuns:`, `turn:`, `turns:`. Empty list = host candidates only (never add a public STUN).
  `stuns:` entries are accepted but skipped (logged at info): libdatachannel does not support them.
- `force_relay` (bool, default false): relay-only ICE policy; requires at least one TURN URL.

Events received before the ack are buffered (max 64) and processed afterwards.

### 6.4 WebRTC

Upstream: `src/viewer/rtc.rs` `configuration`, `Peer::new`, `offer`, `receive`, `answer_sdp`.

Using libdatachannel (`rtc.zig`):

1. Create the PeerConnection from §6.3 ICE config; `iceTransportPolicy = relay` if `force_relay`;
   `maxMessageSize = 262144`.
2. **No media sections** for tool sessions (upstream adds recvonly media only for desktop,
   capture_type 1).
3. Create five ordered, reliable, in-band-negotiated data channels in this order:
   `CONTROL_DATA_CHANNEL`, `TEXT_DATA_CHANNEL`, `STREAMER_DATA_CHANNEL`, `FILE_DATA_CHANNEL`,
   `BINARY_DATA_CHANNEL` (indices 0–4).
4. Create the offer. The **sent** SDP copy is modified: insert `a=x-uuremote-quic\r\n` before
   `a=group:BUNDLE` if absent; add `a=max-message-size:262144` after `a=sctp-port:` if absent.
5. Send `42["soac",{"client_id":REMOTE,"data":{"type":"offer","sdp":SDP,"ice_id":ICE,"app_control_id":ID,"ice_network_type":3}}]`.
6. Local candidates → `42["soac",{"client_id":REMOTE,"data":{"type":"candidate","candidate":{"candidate":C,"sdpMid":MID,"sdpMLineIndex":0},"ice_id":ICE,"app_control_id":ID}}]`.
   `MID` is the first `a=mid:` of the local description. Key names follow how webrtc-rs serializes
   `RTCIceCandidateInit`; the golden vectors confirm them.
7. Incoming `soac` events: ignore unless `ice_id`, `app_control_id` and `client_id` (when present) match ours.
   - `type: "answer"`: SDP from `sdp`, or from `gzip_sdp` (base64 → gzip → text, ≤ 1 MiB). Apply once;
     then apply queued candidates.
   - `type: "candidate"`: `candidate` is either a string (with sibling `sdp_mid`, `sdp_mline_index`) or an
     object `{candidate, sdpMid, sdpMLineIndex}`. Queue (max 256) until the answer is applied.
8. `released` / `left` / `leave` events matching our route → session ends (exit 5 before ready,
   reconnect for portmap after ready).

### 6.5 Message envelope and echo

Upstream: `src/viewer/wire.rs` `envelope`, `echo_request`, `echo_matches`, `echo_request_seq`, `echo_response`.

All data channel messages are protobuf wire format. Top-level envelope:
`{1: seq (varint), K: payload (bytes)}` where `K` is the message kind:

| K | Use |
| --- | --- |
| 3 | SimpleAction (echo) |
| 21 | RPC request |
| 22 | RPC response |
| 27 | port-forward frame |

Echo (readiness): when CONTROL opens, send `envelope(1, 3, {1: 0, 4: FEATURES})`, where FEATURES is
`{1:6, 2:2, 3:1, 4:2, 6:2, 7:2, 9:1}`. The host replies on CONTROL with SimpleAction `{1: 1, 2: "{\"seq\":1}"}`.
The host may also send echo requests (SimpleAction with action 0 or field 1 absent); answer each with
`envelope(1000000 + seq, 3, {1: 1, 2: "{\"seq\":SEQ}", 4: FEATURES})`.

**Session ready** = required channels (§6 table) open **and** echo reply received. Deadline for the whole
setup (join → ready) is 30 s; exceeding it → exit 5.

### 6.6 Inbound routing

Messages are routed to the active tool as follows (this is how the official Windows host behaves):

- FILE (3) and BINARY (4): to the tool.
- TEXT (1) messages containing field 21, 22 or 27: to the tool **as if received on FILE**.
- CONTROL (0) messages containing field 22, or field 21 whose payload has field 8: to the tool
  (the latter as FILE).
- Everything else on CONTROL: echo handling only, otherwise dropped. A full tool queue drops the
  message; it never detaches the tool.

Sends: wait while the channel's buffered amount exceeds 1 MiB (poll every 5 ms); a single send
times out after 30 s.

## 7. Port forwarding (M2)

Upstream: `src/viewer/tools/portmap.rs`, host side `src/port_mapping.rs`.

All frames go on **FILE** (3) as `envelope(0, 27, FRAME)`:

```text
FRAME = {1: session (varint, always 1), 2: rule_id, 3: stream_id, 4: type, 5: payload (bytes)}
```

| type | Direction | Payload |
| --- | --- | --- |
| 0 SYN | out | JSON `{"version":1,"target_host":HOST,"target_port":PORT}` |
| 3 SYN-ACK | in | JSON `{"ok":true}` or ok ≠ true = rejected |
| 2 DATA | both | raw bytes, ≤ 16 KiB per frame outbound |
| 1 CLOSE | both | empty |
| 4 | in | ignored |

- `rule_id` and `stream_id` come from one process-wide counter, as upstream: rules take 1..n in
  `-L` order, streams continue from n + 1 and are unique across rules and reconnects.
- Inbound frames for a stream go to a bounded queue (64 frames); if it is full the stream is closed
  (upstream drops the route). After SYN-ACK, inbound CLOSE ends the stream, type 4 is ignored and
  any other type than DATA is an error that ends the stream.
- Per accepted TCP connection: send SYN, wait ≤ 12 s for SYN-ACK; a timeout or rejection closes the
  local socket (logged at warn, counted; a rejecting SYN-ACK, which holds only status JSON such as
  `{"ok":false,"error":"device_not_controllable"}`, is logged at info). Then copy both ways until either side closes; always send
  CLOSE at the end. TCP half-close is not supported (closing one direction closes the stream).
- Inbound frames with session ≠ 1 or unknown (rule, stream) are dropped (logged at debug, no payload).
- Max 128 concurrent streams per rule; further connections are accepted and closed immediately.

### 7.1 Reconnect

Default on for `portmap`, off for `proxy`.

- When the session ends after having been ready (PeerConnection failed/closed, signaling closed,
  `released` event, CONTROL closed), all open streams are closed and a new session is opened.
- Backoff: 1 s, 2 s, 4 s ... capped at 60 s, reset after a session stays ready for 60 s.
- Local listeners stay bound during reconnect. Connections accepted while no session is ready are
  closed immediately.
- Exit 3 (token expired) and exit 4 (device removed) end the process instead of retrying. A
  remote-assistance host is not on the account, so it is not looked up; its join retries with the
  same code, which fails once the host withdraws the share.
- `--no-reconnect`: exit with code 5 when the session ends.

### 7.2 Shared session for `proxy` and `portmap`

A host keeps one controller session at a time: a second session to it ends the first one
(`leave` → `released`), and two joining at once can end the later one (`RoomClosed`). So every
`proxy` of one DEVICE, and every connection accepted by `portmap`, shares one session, held by a background `uucli __mux [--assist] DEVICE`
process (internal command; not a stable interface).

- Files in `CONFIG_DIR/mux/` (mode 0700), named `HASH.sock`, `HASH.lock`, `HASH.log` (0600). HASH
  is a 64-bit Wyhash of the config path, `--assist`, and DEVICE as written, so different accounts
  and spellings of DEVICE get separate sessions.
- `proxy` connects to `HASH.sock`. If that fails it takes an exclusive `flock` on `HASH.lock`,
  tries again (another `proxy` may have started a server meanwhile), removes a stale socket file,
  and starts `__mux` with its own process group (an ssh client killing the ProxyCommand's group
  does not end it), stdin `/dev/null`, stdout a pipe, stderr `HASH.log` (truncated), passing `-v` /
  `-vv`. The server prints `ready` on stdout once it listens; if stdout ends without it, `proxy`
  copies `HASH.log` to stderr and exits with the server's exit code (for example 4 for an unknown
  DEVICE). A server that goes away before answering is replaced, at most 3 attempts.
- Wire: the client sends `HOST PORT
` (HOST 1..255 bytes without spaces or control characters,
  PORT 1..65535) and waits for one line: `OK` after the SYN-ACK, then the stream's bytes both ways;
  `ERR rejected` (exit 6), `ERR timeout` (exit 5), `ERR request` / `ERR failed` (exit 5). The
  request must arrive within 10 s. End of stdin half-closes the socket; `proxy` exits 0 when the
  socket ends.
- `portmap` resolves DEVICE (asking for an assistance code on a terminal as before), binds its
  listeners, and then opens no session itself: each accepted connection runs the client side above,
  starting the server when needed, and is closed when that fails (logged as a warning). A code it
  asked for is passed to the server as `UUCLI_ASSIST_CODE`. Reconnecting is therefore per
  connection: after the server exits, the next accepted connection starts a new one.
  `--no-reconnect` keeps the own-session behavior of §7.1 (it must fail when the session ends).
- The server opens the session like `portmap` (capture type 9) but does not reconnect: when the
  session ends it removes the socket file and exits, closing its streams; the next `proxy` starts
  a new one. It also ends after `UUCLI_MUX_IDLE` seconds (default 60) without streams, and on
  SIGINT / SIGTERM. The socket file is removed before the listener closes.
- An assistance code comes from `UUCLI_ASSIST_CODE` (inherited) or the config; the server never
  prompts.
- Off with `--no-mux` or `UUCLI_MUX=0` (also `false`, `no`, `off`), and when the socket path would
  exceed 103 bytes; then `proxy` and `portmap` behave as before (§7, §7.1). `terminal`, `exec` and
  `files` still open sessions of their own and compete with the shared one. Tried on the official
  Windows host (2026-11-17): a capture type 9 session also serves terminal open/list, `exec` and
  `files ls`, so they could share it too; not implemented yet.

## 8. Concurrency model

- One process, one `std.Io` instance: `std.Io.Threaded`, the one `std.process.Init` provides.
- libdatachannel invokes callbacks (`onOpen`, `onMessage`, `onLocalCandidate`, `onStateChange`, ...)
  on its own threads. `rtc.zig` copies the data and pushes an event onto a bounded `std.Io.Queue`
  (blocking when full, never dropping); nothing else runs in the callback. No other module sees
  libdatachannel threads or handles.
- The queue lives in a single process-wide `Hub` in static memory, because libdatachannel can invoke a
  callback after its peer is closed. `Hub.shutdown` sets a closing flag, closes the queue and waits for
  in-flight callbacks; later callbacks only read the flag. Peers from an earlier session (portmap
  reconnect) share the hub; consumers ignore events whose peer id is not current.
- `rtcCleanup()` is never called: it can deadlock against libdatachannel's own asynchronous channel
  close (observed in the M0 spike).
- `session.zig` owns signaling and the PeerConnection and drives the state machine from that queue.
- Tools (`portmap`, `terminal`, `files`) receive routed messages from `session.zig` and send through a
  `send(channel, bytes)` function that implements the back-pressure rule of §6.6.

The design relies on these `std.Io` features: TCP listen/accept/connect, TLS client, timers,
cancellation, and `Io.Queue` (thread-safe, so libdatachannel threads can push to it).

## 9. Module layout

```text
uucli/
├── build.zig              # builds libdatachannel + deps, qrcodegen, uucli; cross targets
├── build.zig.zon          # pinned sources: libdatachannel v0.24.6, libjuice, usrsctp, plog, mbedtls, qrcodegen
├── LICENSE  NOTICE
├── docs/spec.md
├── tests/vectors/         # golden data generated from upstream (§10)
└── src/
    ├── main.zig           # argument parsing, dispatch, exit codes
    ├── config.zig         # path, permissions, atomic write, flock
    ├── api.zig            # REST client, signing, error mapping
    ├── login.zig          # device registration, QR flow
    ├── qr.zig             # qrcodegen binding, half-block rendering
    ├── ws.zig             # WebSocket client
    ├── signal.zig         # Engine.IO/Socket.IO framing, control request, soac
    ├── rtc.zig            # libdatachannel binding, event queue
    ├── session.zig        # join → signal → rtc → echo → ready; routing
    ├── interrupts.zig     # SIGINT/SIGTERM self-pipe → session bus
    ├── wire.zig           # protobuf wire encode/decode, envelope, echo, connect options
    ├── tty.zig            # termios raw mode, window size
    └── tools/
        ├── portmap.zig    # portmap + proxy
        ├── terminal.zig
        └── files.zig
```

| uucli module | Upstream (v0.2.59) |
| --- | --- |
| `api.zig` | `src/auth.rs`, `src/viewer/api.rs` |
| `login.zig` | `src/login.rs` |
| `ws.zig` | `src/ws_transport.rs` |
| `signal.zig` | `src/viewer/signal.rs` |
| `rtc.zig`, `session.zig` | `src/viewer/rtc.rs`, `src/viewer/session.rs`, `src/viewer_main.rs` `tool_command` |
| `wire.zig` | `src/viewer/wire.rs`, `src/protocol.rs` |
| `tools/portmap.zig` | `src/viewer/tools/portmap.rs`, `src/port_mapping.rs` |
| `tools/terminal.zig` | `src/viewer/tools/terminal.rs`, `src/viewer/tools/cli.rs`, `src/terminal.rs` |
| `tools/files.zig` | `src/viewer/tools/files.rs`, `src/file_trans.rs` |
| shared RPC helpers | `src/viewer/tools/mod.rs` |

## 10. Testing

- `zig build test` runs offline and needs no account or device.
- **Golden vectors**: `tests/vectors/*.json` were computed by upstream's own code at the pinned
  commit, so they are the authority on exact bytes. `zig build test` embeds the files. The Rust
  generator that wrote them (`tools/gen-vectors`) was removed after the vectors were committed; it
  is in git history (commit `aeff338`) if the upstream pin ever moves and the vectors have to be
  regenerated. The vectors cover:
  - request signing: method, path, header map, body → signature;
  - `build_headers` with and without token;
  - protobuf: varint edge cases, `envelope`, `rpc`, portmap `frame`;
  - `connect_options` for capture types 5, 8, 9 with the uucli shape;
  - echo request / response / match;
  - `with_max_message_size`, `answer_sdp` (plain and gzip);
  - QR poll state table (§5.3) as input/output pairs;
  - JWT csrf extraction.
- Unit tests without vectors: Socket.IO frame parser (including binary attachments), WebSocket framing
  (masking, fragmented and control frames), config permission checks, `DEVICE` resolution, CLI parsing,
  exit-code mapping.
- Loopback test (`src/e2e_test.zig`): a fake REST API, a fake Socket.IO server and a second
  libdatachannel peer in-process play the cloud and host side of §6–§7, forwarding to a local TCP echo
  server, so `portmap` is tested end to end without the cloud (M2). The host peer's events are taken
  off the shared event hub by a test-only hook on the session bus (`Bus.divert`).
- The same harness drives `terminal` (open, list, kill, escapes, exit code) and `files` (list,
  upload, a host-driven download with out-of-order blocks) end to end.
- `zig build test -Dtest-filter=NAME` runs a subset.
- Real-device checks are manual and listed per milestone in §12.

## 11. Terminal, files and packaging (M3–M5)

The wire protocol below was ported from upstream before M2 passed on a real device, so the original
"after M2" ordering was not kept. It is verified against the in-process fake host (§10) only; the
real-device checks of §12 are still open for M2–M4 (first results in §12).

### 11.1 Terminal (M3)

Upstream: `src/viewer/tools/terminal.rs`, `src/viewer/tools/cli.rs`, host side `src/terminal.rs`.
Session capture type 8 (§6); everything except the environment check is a TERM frame on **BINARY**:

```text
"TERM" 01 KIND 00 00 SESSION (u32 le) LEN (u32 le) PAYLOAD
```

KIND is 1..16; LEN ≤ 1 MiB; a frame may span BINARY messages (reassembly buffer ≤ 2 MiB, overflow
fails the terminal).

| KIND | Direction | Payload |
| --- | --- | --- |
| 1 OPEN | out | `{"cols":C,"rows":R,"option":"none"}`; SESSION 0 = new, N = re-attach |
| 13 OPEN_RESP | in | `{"code":0,...}`; the session id is the header SESSION if non-zero, else `session_id` (number or string) in the body, else 0 (the official Windows host serves one terminal as session 0) |
| 2 STDIN | out | raw bytes, ≤ 16 KiB per frame |
| 3 RESIZE | out | `{"cols":C,"rows":R}` |
| 4 CLOSE | out | empty; detaches (the remote session keeps running) |
| 5 STDOUT | in | raw bytes |
| 6 EXIT | in | `{"exit_code":N}` (missing = -1) |
| 8 ERROR | in | the session failed |
| 9 / 10 LIST_REQ / LIST_RESP | out / in | request SESSION = a counter from 1; answer is a bare JSON array of `{session_id, shell, state, ...}` |
| 11 / 12 KILL_REQ / KILL_RESP | out / in | `{"code":0}` = killed |

- First an environment check: `envelope(id, 21, {1: {1: id}, 28: ""})` on CONTROL (`id` counts from
  10). The answer `{22: {1: {1: id}, 24: {1: code, 2: message}}}` comes on CONTROL, or on BINARY
  without the TERM magic (official Mac host). code ≠ 0 → exit 6, with the code and the first 80 bytes
  of the message logged at info (seen: code 2 `device_locked` while the Mac's screen is locked). No answer within 3 s means the host does not
  implement the check (official Windows host) and is not an error.
- Other requests wait up to 30 s (timeout → exit 6). Re-attaching to SESSION first checks it is in
  LIST_RESP (missing → exit 6). OPEN_RESP code ≠ 0 → exit 6; its status JSON is logged at info.
- STDOUT / EXIT / ERROR for other sessions are ignored. Output is copied to stdout unchanged.
- Attach: with stdin a tty, enter raw mode, send the initial window size, forward SIGWINCH resizes.
  With stdin not a tty there is no raw mode and no escape processing; stdin is forwarded as-is and
  EOF detaches like `~.`.
- Escape sequences (like ssh), only at the start of a line (after CR or LF, or first input): `~.`
  detach, `~?` help (stderr), `~~` sends `~`; `~` followed by anything else sends both. `-e CHAR`
  changes the escape char (one printable ASCII character), `-e none` disables it.
- CLOSE is always sent when uucli leaves the session. Remote exit code N ≠ 0 → uucli exits 6 and
  prints the code on stderr; exit 0 → uucli exits 0; detach → exit 0 and `Detached from terminal
  session N` on stderr.
- Raw mode is restored on every exit path; SIGTERM ends the attach like a detach (exit 0). Ctrl-C
  is a byte for the remote side in raw mode.
- `--list`: columns ID, NAME (`shell`), STATE, sorted by id; `--json` gives
  `[{"id","name","state"}]`. `--kill SESSION` prints `Killed terminal session N` on stderr.

#### 11.1.1 `exec`

`exec` is for scripts and agents: one command, its output on stdout, its exit code as uucli's.

- Options come before COMMAND; `--` ends them. The remaining words are joined with single spaces
  and run by the remote shell, so quote for that shell. COMMAND is at most 8 KiB.
- Opens a new terminal (200×50, so lines rarely wrap), waits for the prompt, then sends one input
  line that prints a start marker `UUCLI-S-NONCE`, runs COMMAND, and prints an end marker
  `UUCLI-E-NONCE:CODE`. NONCE is 16 random hex digits. Each marker is built by string concatenation
  (`'UU'+'CLI-S-…'`), so the echoed input line never contains it.
- Shell by the device platform from the device list (for a remote-assistance host, the join's
  `publisher_platform`, §6.1): `windows` → PowerShell, everything else →
  POSIX sh.
  - PowerShell: COMMAND is base64 (UTF-8) and run with `Invoke-Expression` inside `try`. CODE is
    `$LASTEXITCODE` if non-zero, else 1 if `$Error` has entries (a failed cmdlet), else 0. The line
    does not end with `exit`: on the official Windows host, a shell that exits at once loses its
    last screen update, end marker included.
  - POSIX: `eval` of COMMAND in single quotes, then `exit CODE`.
- Output is the terminal screen stream, so stdout and stderr are merged. ANSI sequences are
  stripped; ConPTY cursor moves (`ESC[nC`, `ESC[row;colH`, `G`, `d`) become spaces and newlines.
  Blank lines at the start and end are dropped. More than 16 MiB → exit 6.
- `--timeout SECONDS` (default 300, 0 = none): past it, uucli sends Ctrl-C and exits 6. SIGINT /
  SIGTERM also send Ctrl-C and end the run.
- Exit code: the remote CODE if 0..255 (so 1..6 can come from either side; stderr says which), else
  1. With `--json` stdout is `{"exit_code":N,"output":"..."}`.
- Limits: a COMMAND that itself runs `exit` ends the shell before the end marker (output may be
  lost); a PowerShell parse error shows part of the wrapper line.

### 11.2 Files (M4)

Upstream: `src/viewer/tools/files.rs`, host side `src/file_trans.rs`. Session capture type 5.

uucli's requests are `rpc(rid, request, CASE, BODY)` (§6.5 `rpc`, field 8) on CONTROL; the answer is
the rpc response with the same `rid` whose field 4 holds the expected case. Replies arrive on FILE,
CONTROL or TEXT. The official Windows host sends them as WebRTC *text* messages although they are
binary protobuf (zlib listings contain NUL bytes): the length is libdatachannel's `-(size + 1)`,
never `strlen` (which cut listings and made every non-root `ls` time out until 2026-11-16). `ID(task, index)` is field `1: {1: task, 2: index}`. Request ids and task ids share one
counter starting at 100. Result codes: 1 = success, anything else → exit 6 with the code
(`FT_*`: 4 permission, 5 disk, 6 I/O, 7 canceled, 9 not found). Each reply is awaited ≤ 30 s.

| Operation | Request (case: body) | Response (case: fields) |
| --- | --- | --- |
| list | 10: `ID(t,0)`, 2 path | 7: 4 code, 3 rows (repeated) or 5 zlib(`{1: row}`...) |
| upload request | 1: `ID(t,0)`, 2 dir, 3 info, 4 = 1, 6 zlib(`{1: info}`), 7 unique id (UUID text) | 1: 3 code |
| upload open | 3: `ID(t,1)`, 3 size | 3: 3 code; 2 and 4 must be 0 (no skip / resume) |
| upload block | 4: `ID(t,1)`, 2 block (from 0), 3 bytes (32 KiB) | 4: 3 code, 2 block, 4 length (must match) |
| upload finish | 9: `ID(t,1)`, 2 = 1 | 6: 2 code |
| download request | 2: `ID(t,0)`, 2 remote path | 2: 2 code, 3 file rows or 5 zlib, 4 folder name (non-empty = folder → exit 6) |

- Row: `{1 kind, 2 name, 3 size, 4 modified (unix s), 5 full path}`; kind 0 dir, 3 drive, 4 file.
  Upload info: `{1 name, 2 size, 3 modified}`. Inflated lists are limited to 16 MiB.
- The remote target of `put` is split at the last `/` or `\` into directory and name, keeping the
  host's separator; `/x` → `/`, `C:\x` → `C:\`, a bare name → `~/`. The name and a downloaded file's
  relative path must be plain components (no `..`, no drive, not absolute).
- Download is driven by the host after the request is accepted: it sends rpc requests (field 8) on
  FILE/CONTROL, uucli answers each with an rpc response on CONTROL:
  - 3 open `ID(t,1)`, 3 size → 3: `ID`, 3 code (size must match the list; only index 1).
  - 4 block `ID(t,1)`, 2 block, 3 bytes (≤ 256 KiB) → 4: `ID`, 2 block, 3 code, 4 length. Blocks may
    arrive out of order; up to 32 are buffered. The first block id is 0 (our host) or 1 (official
    Windows host): the base is fixed when block 0 arrives or 16 blocks are buffered.
  - 9 finish `ID(t,1)`, 2 status → 6: `ID`, 2 code (status 1, all bytes written).
  - 9 with index 2^64−1 ends the task: status must be 1 and the file complete.
- `put` without `--force` lists the remote directory first and refuses an existing name (exit 2).
  `get` without `--force` refuses an existing LOCAL before connecting (exit 2).
- `get` writes `LOCAL.uucli-part` and renames it on success; on failure the partial file is removed.
- Failed or canceled upload: send request 9 `ID(t,1)`, 2 = 7 without waiting. Failed or canceled
  download: for up to 3 s answer the host's outstanding requests of the task with code 7
  (open → 3 field 3, block → 4 field 3, finish → 6 field 2).
- Ctrl-C / SIGTERM: the session stays up while the tool cancels as above, then uucli exits 130 / 0.
- Progress on stderr (`DONE/TOTAL bytes  RATE KiB/s  ETA Ns`, every 250 ms) only when stderr is a tty.
- `ls` prints `KIND SIZE NAME` per line (kind `dir`, `drive`, `file`, `other`); `--json` prints
  `[{"kind","name","size","path"}]` with the same kind names.

### 11.3 Packaging (M5)

- `zig build release` builds ReleaseSafe, stripped binaries for x86_64 / aarch64 Linux (musl, fully
  static) and x86_64 / aarch64 macOS (libSystem only) and writes
  `zig-out/release/uucli-VERSION-ARCH-OS.tar.gz`, each with `uucli`, README, LICENSE, NOTICE and the
  systemd unit. The macOS targets need a macOS host with the SDK (usrsctp uses SDK-only headers).
  `-Drelease-os=linux` or `macos` builds only that OS's archives.
- GitHub Actions: `ci.yml` (every push and pull request) runs `zig fmt --check`, the SPDX header
  check, build + tests on Ubuntu and macOS, and an aarch64-linux-musl cross build. `release.yml`
  runs for a pushed tag `vVERSION` that equals `build.zig`'s version: Linux archives on Ubuntu, macOS
  archives on a macOS runner (best effort: a failure does not hold back the Linux release), then a
  GitHub release with the archives and `SHA256SUMS`.
- `contrib/systemd/uucli-portmap@.service`: user unit; instance `NAME` reads
  `~/.config/uucli/portmap-NAME.env` (`UUCLI_DEVICE`, `UUCLI_FORWARDS`), restarts on failure after
  30 s. Reconnects while the host is away are uucli's own (§7.1); SIGTERM stops it with exit 0.
- README in English with build, login, ssh config, terminal, files and systemd examples.

## 12. Milestones and acceptance

| Milestone | Scope | Acceptance (gate) |
| --- | --- | --- |
| M0 | Skeleton: `build.zig` builds libdatachannel v0.24.6 + deps + qrcodegen from `build.zig.zon`; `uucli --version`; `std.Io` spike with a libdatachannel callback waking the main loop | On macOS aarch64: `zig build` produces a binary with no non-system dynamic libraries (`otool -L`). `zig build -Dtarget=x86_64-linux-musl` and `aarch64-linux-musl` succeed, and the x86_64 binary runs `--version` on Linux. `zig build test` passes. |
| M1 | `login`, `logout`, `device list` | Scanning the QR with the UU app signs in; `device list` shows the same devices (minus uucli itself) as the official `uuyc-cli device list`; a second `login` on the same machine does not add another device; config is 0600. |
| M2 | Session setup, `portmap`, `proxy`, reconnect | Windows host: `uucli portmap DEV -L 2222:127.0.0.1:22` then `ssh -p 2222 user@127.0.0.1` logs in; `scp` of a 100 MB file matches sha256; `ProxyCommand uucli proxy DEV 127.0.0.1 22` works; after a 30 s network outage, a new ssh connection succeeds without restarting uucli. Loopback test passes. |
| M3 | `terminal` | Windows host: interactive shell; Ctrl-C reaches the remote process; a full-screen program (vim or similar) renders and resizes correctly; `~.` detaches and `terminal DEV SESSION` re-attaches to the same session; `--list` / `--kill` work. |
| M4 | `files` | Windows host: `ls` of a directory with > 5000 entries; `get` and `put` of a > 1 GB file match sha256; `--force` and partial-file cleanup behave as specified. |
| M5 | Packaging | Release archives built from a clean checkout; systemd unit keeps a portmap alive across a reboot of the controlled host; Mac host column below has no "untested" entry. |

Mac host compatibility (filled in as milestones complete):

| Milestone | Mac host result | Notes |
| --- | --- | --- |
| M2 portmap | blocked | 2026-11-15: session setup passes (room join, ICE, DTLS, all five data channels, echo). Every SYN is answered `{"ok":false,"error":"device_not_controllable"}`. |
| M3 terminal | blocked | 2026-11-15: `--list` works (empty list). OPEN is answered `{"code":403,"message":"device_not_controllable"}`; later, with the Mac's screen locked, check_env answers code 2 `device_locked`. |
| M4 files | blocked | 2026-11-15: `ls` gets no answer within 30 s. |

The 2026-11-15 Mac host was the official UU app on the same Mac that ran uucli. Upstream sends the
same OPEN and SYN, so `device_not_controllable` is taken to be a host-side state (the host's
"allow remote control" setting or macOS permissions), not a protocol error. It has to be re-run
with the host allowing control.

Real-device log:

| Date | Check | Result |
| --- | --- | --- |
| 2026-11-15 | M1 QR login | passed; config written with mode 0600; `device list` shows the account's 3 devices and not uucli itself |
| 2026-11-15 | M1 second login, comparison with `uuyc-cli device list` | not run |
| 2026-11-15 | Windows host `terminal --list` | room join refused with API 2002 (host controlled from another device); the host then went offline |
| 2026-11-15 | Windows host `terminal --list` | passed on retry: session ready (ICE, DTLS, all five data channels, echo); empty list |
| 2026-11-15 | Windows host `terminal` open, host locked | refused: no check_env answer (as expected for Windows), then OPEN answered `{"code":401,"message":"device_not_logged_in"}`. Cause: the host's screen was locked. The official `uuyc-cli term -d DEV list` failed at the same time (`Terminal environment check timed out`, code 105) |
| 2026-11-15 | Windows host unlock from uucli | no answer to either guess: SimpleAction 15 `AUTO_UNLOCK_SYSTEM` with `{"key": …}` on CONTROL (upstream Linux host format), or TERM `UNLOCK_REQ` (14) with `{"password": …}`. How the official Windows host takes the system password is unknown |
| 2026-11-15 | Windows host `terminal` open, host unlocked, no other controller | passed: OPEN accepted, PowerShell ran a command and printed its output; detach ends the session (one terminal per connection). No password was sent |
| 2026-11-15 | Windows host `proxy` as ssh `ProxyCommand` to `127.0.0.1:22` | passed up to authentication: SYN-ACK ok, SSH key exchange with the host's OpenSSH sshd completed. Login, `scp` and the reconnect check of M2 not run yet. Before this run, a setup failure (host refusing the control request) panicked with a double free in `Session.open`; fixed in `cdd540d` |
| 2026-11-15 | Windows host `exec` (PowerShell) | passed: plain output, table output (ConPTY cursor positioning), native exit code 3, failing cmdlet → 1 with its error text, parse error → 1, quotes, `--json`. One `exec` per connection, like `terminal` |
| 2026-11-15 | Windows host `files ls` | no answer within 30 s after session ready (same as the Mac host) |
| 2026-11-16 | Windows host `files ls` | `C:\` listed; every subdirectory timed out. The host did answer: its rpc response came as a text message with NUL bytes, and uucli cut it at the first NUL. Fixed; then three subdirectories listed (up to 106 entries) |
| 2026-11-16 | Windows host `files put` / `get` of a 20 MB file | passed after the fix: sha256 match; put 45 s, get 10 s; `put` of an existing name without `--force` → exit 2. The > 1 GB and > 5000-entry checks of M4 not run yet |
| 2026-11-16 | Remote assistance by code to a Windows host of another account | room join (v2 path) passed; `exec hostname` printed the host name, exit 0, PowerShell chosen from `publisher_platform`. Without it the POSIX wrapper reached PowerShell, so tool sessions are allowed in assistance rooms |
| 2026-11-16 | Same share id, same temporary code, a third join | HTTP 400 code 1131: the code had stopped working (used up or assistance turned off; not distinguished). `files` over assistance not tested yet |
| 2026-11-16 | `login` method prompt, `login --phone` input checks, send-code request for `00000` (on a copy of the config) | prompt and checks as specified; the send-code request was accepted (code 0) without validating the number. Receiving an SMS and `by_mobile` with a real number not tested yet |
| 2026-11-16 | `fav edit` rename and rename back; `fav edit --save-code` on a copy of the config | passed: both lists showed each new remark; the code was saved with mode 0600 |
| 2026-11-16 | `fav list` / `fav list --recent` / `fav add` / `fav rm` against the account | passed: the host joined above was in `recent`; add showed it in both lists as favorite with its remark; re-adding succeeded; rm removed it and the saved code; rm again → exit 4 |
| 2026-11-17 | Shared `proxy` session (§7.2), Linux hosts behind a remote-assistance host | passed: 3 concurrent `proxy` and 7 concurrent ssh logins (ah, ProxyCommand) to 7 machines behind one host through one `__mux` process; before, a second concurrent session ended the first (`released`) or failed (`RoomClosed`). Unknown DEVICE relayed as exit 4; idle exit after 60 s removed the socket; `--no-mux` and `UUCLI_MUX=0` connect directly |

## 13. Open questions and protocol drift

| Question | Closed in | Notes |
| --- | --- | --- |
| Does `device/windows/init` add a visible device to the account, and is the name `uucli@HOSTNAME` shown? | M1 | Partly: registration and login succeed; `device list` hides uucli itself, so how it is shown still needs the UU app. |
| Do official hosts accept tool sessions with no media sections in the offer? | M2 | Yes for the Mac host (2026-11-15): capture types 8 and 9 reach "session ready". Windows host: capture type 9 reaches "session ready" (2026-11-15). |
| Does the official host require a non-empty FeatureFlag (field 11) for tool sessions? | M2 | Not for session setup on the Mac host (2026-11-15). Whether it is behind `device_not_controllable` is open. |
| Does the Mac host support capture types 8 / 9 at all? | M2 / M3 | Upstream has not verified it. |
| Does libdatachannel produce candidates/SDP the host accepts (vs webrtc-rs upstream)? | M2 | Yes for the Mac and Windows hosts (2026-11-15): ICE connects, DTLS completes, all data channels open. |
| What does the API answer for bad requests? | M1 | Observed: wrong signature → HTTP 400 code 1003; `gen/login` without a registered `x-param-device-id` → HTTP 422 code 1001 ("无效的请求参数"); room join to a host that is being controlled → code 2002. |
| Which `std.Io` implementation to use with libdatachannel callbacks? | M0 | Closed: `std.Io.Threaded`; foreign-thread `Io.Queue` puts work (loopback self test, 60/60 runs on macOS, Linux x86_64 and aarch64). |

Upstream drift log (append when the pin moves):

| Date | Upstream version | Change affecting uucli |
| --- | --- | --- |
| 2026-11-14 | v0.2.59 | initial pin |
| 2026-11-16 | `13a40f9` (not pinned) | Viewer `assist CONNECT_ID` joins by share code (`join_share`, §6.1); taken over without moving the pin |

### Differences from earlier design assumptions

Found while reading upstream v0.2.59 source; this spec follows the source:

- ICE servers and `force_relay` come from the **control ack** (§6.3), not from the room join response.
- The QR status poll sends `status_query_ticket` as `token`, not the `token` from `gen/login`.
- The sign key is a shared constant from the official client, not a per-user credential.
- portmap does not use the RPC 21/22 envelope; it uses kind 27 frames on FILE (§7).
- Each tool needs its own session with a specific capture type (§6), so `portmap` and `terminal` cannot
  share one connection.
- Homebrew has no `libdatachannel` formula; it is built from source (§2).
