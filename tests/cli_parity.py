#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare two uucli binaries' offline CLI behavior during a refactor."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


CASES = [
    [], ["--help"], ["-h"], ["--version"], ["--unknown"], ["unknown"], ["ter"],
    ["login", "--unknown"], ["login", "--qr", "--phone"],
    ["logout"], ["logout", "extra"],
    ["device"], ["device", "list", "-j"], ["dev", "ls", "-j"],
    ["fav"], ["fav", "list", "-j"], ["fav", "add", "123456789", "office-pc"],
    ["fav", "edit", "office-pc"], ["fav", "rm", "office-pc"],
    ["portmap"], ["pm", "office-pc", "-L", "invalid"],
    ["portmap", "office-pc", "-L", "0:127.0.0.1:22"],
    ["proxy"], ["px", "office-pc", "127.0.0.1", "0"],
    ["proxy", "office-pc", "127.0.0.1", "22"],
    ["session"], ["session", "list", "-j"], ["session", "ls"],
    ["session", "status", "office-pc", "-j"], ["session", "stop", "office-pc"],
    ["session", "start", "office-pc"], ["session", "list", "--force"],
    ["terminal"], ["term", "office-pc", "--list", "--kill", "3"],
    ["terminal", "office-pc", "--list", "-j"],
    ["terminal", "office-pc", "-e", "invalid"],
    ["exec"], ["x", "office-pc", "--", "echo", "marker"],
    ["exec", "office-pc", "-t", "invalid", "echo marker"],
    ["files"], ["files", "office-pc", "ls", "/", "-j"],
    ["files", "office-pc", "get", "/file", "download", "-j"],
    ["files", "office-pc", "put", "missing-file", "/file"],
    ["debug", "unknown"], ["__mux"], ["__mux", "office-pc"],
    ["-v", "session", "list", "-j"], ["-vv", "exec", "office-pc", "echo marker"],
]


def invoke(binary, args, directory, config):
    env = dict(os.environ, UUCLI_CONFIG=str(config))
    for key in ("UUCLI_ASSIST_CODE", "UUCLI_MUX", "UUCLI_MUX_IDLE", "UUCLI_MUX_NAME"):
        env.pop(key, None)
    result = subprocess.run(
        [str(binary), *args], cwd=directory, env=env, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=15, check=False,
    )
    return result.returncode, result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    options = parser.parse_args()
    before, after = options.before.resolve(), options.after.resolve()
    checks = 0
    with tempfile.TemporaryDirectory(prefix="uucli-cli-parity-") as directory:
        config = Path(directory) / "config.json"
        for mode in ("signed-out", "invalid-config"):
            if mode == "invalid-config":
                config.write_text("{invalid JSON\n")
                config.chmod(0o600)
            for args in CASES:
                expected = invoke(before, args, directory, config)
                actual = invoke(after, args, directory, config)
                if actual != expected:
                    raise AssertionError(
                        f"CLI changed for {mode}: {args!r}\n"
                        f"before: {expected!r}\nafter: {actual!r}"
                    )
                checks += 1
    print(f"CLI parity passed: {checks} cases; exit codes, stdout and stderr match.")


if __name__ == "__main__":
    main()
