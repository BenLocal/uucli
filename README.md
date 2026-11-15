# uucli

A headless command-line client for NetEase UU Remote (网易UU远程), for Linux and macOS. It signs in
to your own UU account with a QR code and reaches the hosts bound to that account: TCP port
forwarding (for example as an SSH tunnel), a remote terminal, and file transfer.

The protocol is ported from [uu-remote-linux](https://github.com/VallierDev/uu-remote-linux)
v0.2.59. uucli is not affiliated with NetEase. The specification is in [docs/spec.md](docs/spec.md).

Status: all commands are implemented and tested against an in-process fake host; checks against
real Windows and Mac hosts are still pending (see [docs/spec.md](docs/spec.md) §12).

## Build

Requires Zig 0.17.1. Dependencies (libdatachannel and its libraries, qrcodegen) are fetched and
linked statically.

```sh
zig build -Doptimize=ReleaseSafe             # zig-out/bin/uucli
zig build -Doptimize=ReleaseSafe -p ~/.local # install to ~/.local/bin/uucli (-p = --prefix)
zig build -Dtarget=x86_64-linux-musl         # static Linux binary
zig build test                               # offline tests, no account needed
zig build release                            # zig-out/release/uucli-VERSION-ARCH-OS.tar.gz
```

Check `zig version` first: an older Zig fails with compile errors in `build.zig` rather than a
version message.

`zig build release` builds Linux x86_64/aarch64 (static musl) and macOS x86_64/aarch64; the macOS
archives need a macOS host with the SDK installed.

## Sign in

```sh
uucli login          # scan the QR code with the UU Remote app
uucli device list    # ID, NAME, PLATFORM, ONLINE, SHARED
uucli logout
```

uucli registers itself as a device on your account. The config, including the login token, is
stored at `$XDG_CONFIG_HOME/uucli/config.json` (or `~/.config/uucli/config.json`, or
`$UUCLI_CONFIG`) with mode 0600. uucli never prints or logs the token.

## Port forwarding and SSH

`DEVICE` is a device id or its display name from `uucli device list`. `HOST:PORT` is resolved on
the controlled host, so `127.0.0.1:22` is the host's own SSH server.

```sh
uucli portmap office-pc -L 2222:127.0.0.1:22
ssh -p 2222 user@127.0.0.1
```

Several `-L` options can be given. `BIND` defaults to `127.0.0.1`; `-L 0:...` picks a free port,
printed on stderr. `portmap` reconnects with backoff (1 s up to 60 s) when the session drops;
`--no-reconnect` exits with code 5 instead.

Without a listening port, `proxy` connects stdin/stdout to one stream, for `ProxyCommand`:

```sshconfig
Host office
    HostName office-pc
    User me
    ProxyCommand uucli proxy %h 127.0.0.1 22
```

## Remote terminal

```sh
uucli terminal office-pc            # new shell session
uucli terminal office-pc --list     # ID, NAME, STATE (--json for an array)
uucli terminal office-pc 3          # re-attach to session 3
uucli terminal office-pc --kill 3
```

Like ssh, `~.` at the start of a line detaches (the remote session keeps running), `~?` shows help
and `~~` sends a `~`. `-e CHAR` changes the escape character, `-e none` turns it off. A remote
exit code other than 0 makes uucli exit 6.

## Run one command

```sh
uucli exec office-pc 'Get-Service sshd'          # output on stdout, remote exit code as uucli's
uucli x -j office-pc -- hostname                 # {"exit_code":0,"output":"..."}
uucli x -t 30 office-pc 'cmd /c exit 7'; echo $? # 7
```

The command runs in a new remote terminal: PowerShell on Windows hosts, sh elsewhere. stdout and
stderr arrive merged. `--timeout` (default 300 s, 0 = none) sends Ctrl-C and exits 6 when it runs
out. Since the exit code is the remote one, codes 1..6 can come from either side; stderr says which.

## Files

```sh
uucli files office-pc ls 'C:\Users\me\Downloads'      # KIND SIZE NAME (--json for an array)
uucli files office-pc get 'C:\Users\me\a.zip' a.zip   # --force to overwrite a.zip
uucli files office-pc put backup.tar /home/me/backup.tar
```

One regular file per transfer. Remote paths are passed through as written. `get` writes
`LOCAL.uucli-part` and renames it when complete. Ctrl-C cancels and tells the host.

## Short forms

For scripts and agents every command has a fixed short form (no prefix matching):

```sh
uucli dev ls -j                    # device list --json
uucli term office-pc -l -j         # terminal office-pc --list --json
uucli term office-pc -k 3          # terminal office-pc --kill 3
uucli fs office-pc ls 'C:\Users\me' -j
uucli fs office-pc get 'C:\Users\me\a.zip' a.zip -f
uucli pm office-pc -L 2222:127.0.0.1:22 -n
uucli px office-pc 127.0.0.1 22
uucli x -t 60 office-pc hostname    # exec office-pc --timeout 60 hostname
```

`login` and `logout` have none.

## Keep a port mapping running (systemd)

```sh
mkdir -p ~/.config/uucli ~/.config/systemd/user
printf 'UUCLI_DEVICE=office-pc\nUUCLI_FORWARDS=-L 2222:127.0.0.1:22\n' > ~/.config/uucli/portmap-office.env
cp contrib/systemd/uucli-portmap@.service ~/.config/systemd/user/
systemctl --user enable --now uucli-portmap@office
loginctl enable-linger "$USER"
```

The unit runs `/usr/local/bin/uucli`; adjust `ExecStart` if it is installed elsewhere.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success (also SIGTERM for `portmap`/`proxy`) |
| 1 | Other error |
| 2 | Usage error, ambiguous `DEVICE` |
| 3 | Not signed in or login expired |
| 4 | Device not found or offline |
| 5 | Connection setup failed |
| 6 | Remote side refused |
| 130 | SIGINT |

`-v` / `-vv` log more on stderr. Set `UUCLI_USE_PROXY=1` to use `HTTP(S)_PROXY` for the API.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
