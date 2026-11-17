---
name: uucli
description: Operate NetEase UU Remote hosts with uucli for device discovery, remote shell commands, terminal sessions, TCP forwarding, SSH ProxyCommand, file transfer, and remote-assistance favorites. Use when the user mentions uucli, 网易UU远程, UU remote assistance, or asks to access a host through UU Remote.
compatibility: Requires the uucli binary on Linux or macOS and an official UU Remote client on the controlled host.
---

# uucli

## Prepare and select the target

1. Locate the executable with `command -v uucli`. In a source checkout, use
   `zig-out/bin/uucli` if available. Use that executable in place of `uucli` below.
   Run `uucli --version` and `uucli --help` to check the installed interface.
   If unavailable, build the checkout with Zig 0.17.1:
   `zig version`, then `zig build -Doptimize=ReleaseSafe`.
2. Run `uucli device list --json` to discover account devices. Use the exact device ID
   for subsequent operations. Names match exactly, ignoring case; ambiguous names
   fail with exit 2. If the requested target is a saved remote-assistance favorite,
   use `uucli fav list --json` to find its ID or name.
3. If not signed in (exit 3), run `uucli login --qr` and let the user scan the QR
   with the UU Remote app. For SMS login, use `uucli login --phone` in a terminal
   and let the user supply the phone number and verification code. Resume discovery
   after login succeeds. Login registers this controller as a device on the account.
4. Select the operation below. Success requires its command result, not just a
   connection-ready log message. Report the selected target, result, and any
   unverified step.

Configuration is selected by `UUCLI_CONFIG`, otherwise
`$XDG_CONFIG_HOME/uucli/config.json`, otherwise `~/.config/uucli/config.json`.
Use an existing account configuration; keep its contents private. Config files
require mode 0600 and their directory 0700. `logout` clears local account
credentials while retaining the controller identity.

## Run a command

Prefer `exec` for agent tasks; it opens and closes a new remote terminal and
returns captured output without requiring interactive terminal automation.

```sh
uucli exec office-pc --json --timeout 60 -- hostname
uucli exec office-pc --json --timeout 60 -- 'Get-Service sshd'
uucli exec unix-host --json --timeout 60 -- 'uname -a; id'
```

The remote shell is PowerShell on Windows and sh elsewhere. Quote the command
as one local shell argument so local expansion does not consume remote variables,
pipes, redirects, or command substitutions. Choose syntax for the remote OS.
For example, use single quotes around a PowerShell command containing `$env:NAME`.

- JSON output is `{"exit_code":0,"output":"..."}`; stdout and stderr from the
  remote command are merged.
- The process returns the remote exit code (0..255). Codes 1..6 overlap with
  uucli failures: inspect stderr and any returned JSON before classifying them.
  Preserve nonzero status when capturing output; do not discard it with `|| true`.
- Timeout defaults to 300 seconds; 0 disables it. Expiry sends Ctrl-C and exits 6.
  A timeout does not prove the command had no effects. Check the remote state
  before retrying an operation that changes it.
- Avoid a command that explicitly exits its shell: it can terminate before
  uucli's completion marker, losing output. Captured output is limited to 16 MiB.

## Manage interactive terminals

```sh
uucli terminal office-pc --list --json
uucli terminal office-pc
uucli terminal office-pc 3
uucli terminal office-pc --kill 3
```

Use an interactive TTY for shell access. At the start of a line, `~.` detaches
and leaves the remote session running; `~?` shows help and `~~` sends a tilde.
`-e CHAR` changes the escape character and `-e none` disables it.
Kill only a session selected by the user's task; a detached session may still
be doing work. Interactive terminal failure uses exit 6 for a nonzero remote
exit, unlike `exec`, which returns the remote status directly.

## Transfer a file

```sh
uucli files office-pc ls 'C:\Users\Public\Downloads' --json
uucli files office-pc get 'C:\Users\Public\Downloads\report.txt' ./report.txt
uucli files unix-host put ./report.txt /home/me/report.txt
```

Paths use the controlled host's syntax and are passed through as written.
Transfers handle one regular file, with no directory recursion or resume.
For a directory, create an archive in a separately authorized remote command
and transfer the archive.

Use `--force` only when overwriting the destination is intended. Downloads use
`LOCAL.uucli-part` and rename it on completion; Ctrl-C cancels the transfer.
Verify the completed destination (size or hash when appropriate) before
reporting that the file arrived.

## Forward TCP or use SSH

```sh
uucli portmap office-pc -L 2222:127.0.0.1:22
ssh -p 2222 me@127.0.0.1
```

Keep the portmap process running while using the tunnel. `HOST:PORT` is resolved
on the controlled host: `127.0.0.1:22` means that host's own SSH service.
The bind address defaults to local loopback. Use `-L 0:127.0.0.1:22` to pick a
free port and read the chosen address from stderr. Multiple `-L` rules are
supported. Bracket IPv6 addresses, e.g. `[::1]:2222:[::1]:22`.

Wait for `Listening on ...` and then test the intended service. Portmap
reconnects with backoff; `--no-reconnect` exits with 5 on session loss.
Stop the process when a temporary tunnel is no longer needed. SIGTERM exits 0.

For a single SSH connection, avoid a persistent listener:

```sh
ssh -o 'ProxyCommand=uucli proxy office-pc 127.0.0.1 22' me@office-pc
```

`proxy` carries the byte stream on stdin/stdout, so leave those streams connected
to SSH. The remote SSH service and its authentication must already be available.

## Use remote assistance and favorites

With `--assist`, the target is a share ID supplied by the host owner:

```sh
uucli exec --assist 123456789 --json -- hostname
uucli files --assist 123456789 ls 'C:\' --json
uucli fav list --json
uucli fav list --recent --json
uucli fav add 123456789 lab-pc
uucli fav edit lab-pc lab-2
uucli fav rm lab-2
```

Assistance codes come from `UUCLI_ASSIST_CODE`, then saved config, then a prompt.
Provision the environment through the local secret mechanism, or let the user
enter the code in a terminal. Keep codes out of command arguments, logs, and
repository files. When stdin carries a terminal or proxy stream, use the
environment, saved config, or an interactive code prompt rather than piping a code.

`fav add --save-code` and `fav edit --save-code` persist the code in the private
config. Use these commands when explicitly managing saved codes. Adding an existing favorite replaces its
remark; removing a favorite also removes its saved code. A temporary assistance
code may need replacement after use. A saved favorite can be used as an ordinary
target without `--assist`.

For interactive `terminal` and `exec`, a join rejected with API 1131 asks for a new
code up to three times. This error may also mean assistance is disabled. A code
entered interactively is saved after the connection succeeds, including a replacement
for a stale saved code. Environment-only codes are not automatically saved.
Non-interactive calls do not prompt again. Retry applies only to setup, before
the remote command starts.


## Interpret failures

Lists support `--json`; stdout contains results, while logs, progress, prompts,
and QR codes go to stderr. Put verbosity before the command: `uucli -v ...`
or `uucli -vv ...`.

| Exit | Action |
| --- | --- |
| 1 | Read stderr for the specific local or API error. |
| 2 | Correct arguments, resolve an ambiguous name to an ID, or handle an existing destination. |
| 3 | Complete login for the selected configuration. |
| 4 | Check the target ID and host online state. |
| 5 | Diagnose room join, signaling, or RTC setup. |
| 6 | Check refusal or timeout details, including host state and target service. |
| 130 | Report interruption; check state before retrying an operation that changes it. |

Apply the `exec` exit-code exception above before using this table.
For API 2002, another controller occupies the host: ask the user to disconnect
that controller. For `device_locked` or `device_not_logged_in`, ask the host
owner to unlock its desktop. uucli does not provide a working automatic unlock
flow for official Windows hosts.

Environment proxies are ignored by default. Set `UUCLI_USE_PROXY=1` only when
the API should use the configured HTTP(S) proxy.

In a source checkout, consult `docs/spec.md` for the command contract and
`docs/memory/real-device-testing.md` for observed host-specific failures.
