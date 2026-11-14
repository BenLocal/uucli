# uucli specification

## 1. Goal

uucli is a headless UU Remote (网易UU远程) **controller** CLI written in Zig. It runs on Linux and macOS,
signs in with a UU account, and gives the user, against a device bound to that account:

- a TCP port forward (`portmap`, `proxy`), so ssh / scp / rsync / VS Code Remote work over UU Remote;
- a remote terminal attached to the current tty (`terminal`);
- single-file transfer (`files`).

Non-goals: remote desktop, audio/video, clipboard, gamepad, remote assistance (share codes), any GUI,
acting as a controlled host, Windows as the uucli platform.

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

### 3.3 `DEVICE` resolution

`DEVICE` is resolved against `GET /api/v1/device/list` (both `my_binded_devices` and
`others_shared_devices`):

1. Exact match on `device_id`.
2. Otherwise exact, case-insensitive match on the display name (`alias`, falling back to `device_id`).
3. More than one name match → exit 2 and list the candidates (id, name, platform) on stderr.
4. No match → exit 4.

No fuzzy or prefix matching.

### 3.4 Commands

| Command | Milestone | Behavior |
| --- | --- | --- |
| `uucli login` | M1 | QR sign-in (§5.3). Prints the QR to stderr. On success prints `Signed in as NAME (USER_ID)` to stderr; stdout stays empty. |
| `uucli logout` | M1 | Clears `user_id`, `token`, `csrf`, `account_name`. Keeps the device identity so the next login reuses the same device. Local only, no API call. |
| `uucli device list [--json]` | M1 | Lists account devices (§5.4). |
| `uucli portmap DEVICE -L [BIND:]LPORT:HOST:PORT [-L ...] [--no-reconnect]` | M2 | Forwards local TCP ports to `HOST:PORT` as seen from the controlled host. `BIND` defaults to `127.0.0.1`. `LPORT` 0 picks a free port; the chosen ports are printed on stderr as `Listening on BIND:PORT -> HOST:PORT`. Runs until SIGINT/SIGTERM. |
| `uucli proxy DEVICE HOST PORT` | M2 | Opens one forwarded stream and connects it to stdin/stdout, for `ProxyCommand`. Exits when either side closes. |
| `uucli terminal DEVICE [SESSION] [-e CHAR\|none]` | M3 | Attaches the current tty to a remote PTY (§11.1). |
| `uucli terminal DEVICE --list [--json]` | M3 | Lists remote terminal sessions. |
| `uucli terminal DEVICE --kill SESSION` | M3 | Ends a remote terminal session. |
| `uucli files DEVICE ls REMOTE_DIR [--json]` | M4 | Lists one remote directory. |
| `uucli files DEVICE get REMOTE LOCAL [--force]` | M4 | Downloads one file. |
| `uucli files DEVICE put LOCAL REMOTE [--force]` | M4 | Uploads one file. |

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
| Locking | `flock` on `config.lock` around device registration and login, so two `uucli login` runs cannot register two devices |

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
  "sign_key": "optional override; default is upstream DEFAULT_SIGN_KEY"
}
```

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
| `mac` | first physical interface, uppercase, dash form, or empty | same |
| `memory` | MiB | MiB |
| `screen` | `1920x1080` (constant: headless) | `1920x1080` |

If the machine source is unreadable, `machine_guid` is a random UUID. Because it is saved, it stays
the same afterwards. Response: `data.device_id` → saved immediately, even if the QR step is abandoned.

Expected side effect: the account's device list gains one entry named `uucli@HOSTNAME`
(confirmed or corrected in M1, see §13).

### 5.3 QR login

Upstream: `src/login.rs` `flow`, `qr_poll_action`, `qr_ticket`, `csrf_from_token`.

1. `POST /api/v1/qrcode/gen/login` with an **empty body** (sign the empty string).
   `data.qrcode_jump_url` is the QR content. The status ticket is `data.status_query_ticket`,
   falling back to `data.token` if absent.
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

Only one login per config file runs at a time (non-blocking `flock` on `login.lock`; second run exits 1).

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

- `rule_id`: one per `-L` (1, 2, ...). `stream_id`: process-wide counter, unique across rules.
- Per accepted TCP connection: send SYN, wait ≤ 12 s for SYN-ACK; a timeout or rejection closes the
  local socket (logged at warn, counted). Then copy both ways until either side closes; always send
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
- Exit 3 (token expired) and exit 4 (device removed) end the process instead of retrying.
- `--no-reconnect`: exit with code 5 when the session ends.

## 8. Concurrency model

- One process, one `std.Io` instance (threaded implementation unless the M0 spike shows the evented
  one works with libdatachannel's wakeups).
- libdatachannel invokes callbacks (`onOpen`, `onMessage`, `onLocalCandidate`, `onStateChange`, ...)
  on its own threads. `rtc.zig` copies the data and pushes an event onto a bounded MPSC queue; nothing
  else runs in the callback. No other module sees libdatachannel threads or handles.
- `session.zig` owns signaling and the PeerConnection and drives the state machine from that queue.
- Tools (`portmap`, `terminal`, `files`) receive routed messages from `session.zig` and send through a
  `send(channel, bytes)` function that implements the back-pressure rule of §6.6.

The exact `std.Io` API is verified against the Zig 0.17.1 standard library in M0; the design only relies
on: TCP listen/accept/connect, TLS client, timers, cancellation, and a queue that a foreign thread can
push to.

## 9. Module layout

```text
uucli/
├── build.zig              # builds libdatachannel + deps, qrcodegen, uucli; cross targets
├── build.zig.zon          # pinned sources: libdatachannel v0.24.6, libjuice, usrsctp, plog, mbedtls, qrcodegen
├── LICENSE  NOTICE
├── docs/spec.md
├── tests/vectors/         # golden data generated from upstream (§10)
├── tools/gen-vectors/     # Rust program that produces tests/vectors from upstream v0.2.59
└── src/
    ├── main.zig           # argument parsing, dispatch, exit codes
    ├── config.zig         # path, permissions, atomic write, flock
    ├── api.zig            # REST client, signing, error mapping
    ├── login.zig          # device registration, QR flow
    ├── qr.zig             # qrcodegen binding, half-block rendering
    ├── ws.zig             # WebSocket client
    ├── signal.zig         # Engine.IO/Socket.IO framing, control request, soac
    ├── rtc.zig            # libdatachannel binding, event queue
    ├── session.zig        # join → signal → rtc → echo → ready; routing; reconnect
    ├── wire.zig           # protobuf wire encode/decode, envelope, echo, connect options
    ├── tty.zig            # termios raw mode, window size, SIGWINCH
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
- **Golden vectors**: `tools/gen-vectors` is a small Rust program that depends on the upstream crate at
  the pinned commit and writes JSON/hex files to `tests/vectors/`. Vectors are committed; regenerating
  them is only needed when the upstream pin changes. Required vectors:
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
- Loopback test: a fake signaling server and a second libdatachannel peer in-process play the host side
  of §6–§7 so `portmap` can be tested end to end without the cloud (M2).
- Real-device checks are manual and listed per milestone in §12.

## 11. Later milestones (contract only)

Protocol details for these are written into this spec after M2 is accepted.

### 11.1 Terminal (M3)

- Attach: with stdin a tty, enter raw mode, send initial window size, forward SIGWINCH resizes.
  With stdin not a tty, no raw mode; stdin is forwarded as-is and EOF closes the remote input.
- Escape sequences (like ssh), only at the start of a line: `~.` detach (remote session keeps running),
  `~?` help, `~~` sends `~`. `-e CHAR` changes the escape char, `-e none` disables it.
- Remote shell exit code N ≠ 0 → uucli exits 6 and prints the code on stderr; exit 0 → uucli exits 0.
- Terminal is always restored on exit, including on signals and errors.
- `--list` output columns: session id, name, state; `--json` gives the same as an array.

### 11.2 Files (M4)

- `ls` prints one entry per line: kind, size, name; `--json` prints `[{kind, name, size, path}]`.
- `get` / `put` transfer a single regular file. No recursion, no resume.
- Destination exists → exit 2 unless `--force`.
- Remote paths are passed through untouched (no Windows/Unix conversion).
- Data is written to `DEST.uucli-part` and renamed on success; on failure the partial file is removed.
- Progress on stderr (bytes, rate, ETA) only when stderr is a tty.
- Ctrl-C cancels the transfer, notifies the host, and exits 130.

### 11.3 Packaging (M5)

- Release archives for Linux x86_64 / aarch64 and macOS aarch64 / x86_64, statically linked.
- `contrib/systemd/uucli-portmap@.service` (user unit) running a long-lived `portmap`.
- README in English with install, login, ssh config and systemd examples.

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
| M2 portmap | untested | |
| M3 terminal | untested | |
| M4 files | untested | |

## 13. Open questions and protocol drift

| Question | Closed in | Notes |
| --- | --- | --- |
| Does `device/windows/init` add a visible device to the account, and is the name `uucli@HOSTNAME` shown? | M1 | |
| Do official hosts accept tool sessions with no media sections in the offer? | M2 | Upstream adds media only for desktop (capture_type 1), so expected yes. |
| Does the official host require a non-empty FeatureFlag (field 11) for tool sessions? | M2 | Upstream clears it for tools and only sends it for desktop. |
| Does the Mac host support capture types 8 / 9 at all? | M2 / M3 | Upstream has not verified it. |
| Does libdatachannel produce candidates/SDP the host accepts (vs webrtc-rs upstream)? | M2 | Watch `sdpMid`, `ice-options`, DTLS role. |
| Which `std.Io` implementation to use with libdatachannel callbacks? | M0 | |

Upstream drift log (append when the pin moves):

| Date | Upstream version | Change affecting uucli |
| --- | --- | --- |
| 2026-11-14 | v0.2.59 | initial pin |

### Differences from earlier design assumptions

Found while reading upstream v0.2.59 source; this spec follows the source:

- ICE servers and `force_relay` come from the **control ack** (§6.3), not from the room join response.
- The QR status poll sends `status_query_ticket` as `token`, not the `token` from `gen/login`.
- The sign key is a shared constant from the official client, not a per-user credential.
- portmap does not use the RPC 21/22 envelope; it uses kind 27 frames on FILE (§7).
- Each tool needs its own session with a specific capture type (§6), so `portmap` and `terminal` cannot
  share one connection.
- Homebrew has no `libdatachannel` formula; it is built from source (§2).
