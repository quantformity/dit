#!/usr/bin/env python3
"""Offline terminal/pipe checks against scenario-e2e.sh's coverage fixture.

Usage: python3 scripts/check-table-headers.py DIT STORE MARKET_STORE
Uses a pseudo-terminal so terminal detection is exercised, not mocked.
"""

import errno
import json
import os
import pty
import re
import select
import subprocess
import sys
import time

binary, store, market = sys.argv[1:]
base = [binary, "--offline", "--backend", "file", "--store", store, "--market-store", market]
env = os.environ.copy()
env.pop("NO_COLOR", None)
env["TERM"] = "xterm-256color"


def run(args, terminal=False, extra_env=None):
    child_env = dict(env, **(extra_env or {}))
    if not terminal:
        result = subprocess.run(base + args, env=child_env, capture_output=True, timeout=15)
        assert result.returncode == 0, result.stderr.decode()
        return result.stdout.decode()
    master, slave = pty.openpty()
    child = subprocess.Popen(base + args, env=child_env, stdin=subprocess.DEVNULL,
                             stdout=slave, stderr=subprocess.PIPE)
    os.close(slave)
    data = bytearray()
    deadline = time.monotonic() + 15
    try:
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "terminal command timed out"
            assert select.select([master], [], [], remaining)[0], "terminal command timed out"
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            data.extend(chunk)
        _, stderr = child.communicate(timeout=15)
        assert child.returncode == 0, stderr.decode()
    finally:
        os.close(master)
        if child.poll() is None:
            child.kill()
            child.wait()
    return data.decode().replace("\r\n", "\n")


commands = [
    ["accounts"],
    ["summary"],
    ["account", "show", "Cov USD", "--history"],
    ["ticker", "list"],
    ["tx", "list"],
    ["tx", "list", "--ticker", "FAST"],
    ["pnl", "--from", "2026-06-10", "--to", "2026-09-30"],
    ["pnl", "--from", "2026-06-10", "--to", "2026-09-30", "--time-series"],
    ["quote", "FAST", "--as-of", "2026-06-30"],
    ["quote", "FAST", "--from", "2026-06-10", "--to", "2026-06-12"],
    ["quote", "USD/CAD/HKD", "--as-of", "2026-06-30"],
    ["market", "show"],
    ["market", "coverage", "--to", "2026-10-01"],
]


def table_lines(text):
    return [line for line in text.splitlines() if line.lstrip().startswith(("┌", "│", "├", "└"))]


for args in commands:
    styled = run(args, terminal=True)
    plain = run(args)
    assert "\x1b" not in plain, f"piped output contains ANSI: {args}"
    lines = styled.splitlines()
    header_count = 0
    for index, line in enumerate(lines):
        is_header = index > 0 and lines[index - 1].lstrip().startswith("┌")
        if is_header:
            header_count += 1
            cells = [cell.strip() for cell in line.split("│")[1:-1] if cell.strip()]
            assert cells, f"missing labels: {args}"
            assert all(cell.startswith("\x1b[1m") and cell.endswith("\x1b[22m") for cell in cells), args
        else:
            assert "\x1b" not in line, f"non-header styled: {args}"
    assert header_count, f"no tables rendered: {args}"
    stripped = re.sub(r"\x1b\[(?:1|22)m", "", styled)
    assert table_lines(stripped) == table_lines(plain), f"table alignment/content changed: {args}"
    print(f"PASS: {' '.join(args)} ({header_count} bold table headers; pipe unchanged)")

for setting in [{"NO_COLOR": "1"}, {"TERM": "dumb"}]:
    plain = run(["accounts"], terminal=True, extra_env=setting)
    assert "\x1b" not in plain, setting
    assert table_lines(plain) == table_lines(run(["accounts"])), setting
    print(f"PASS: terminal opt-out {setting}")

for terminal in [True, False]:
    document = run(["--json", "accounts"], terminal=terminal)
    assert "\x1b" not in document
    assert json.loads(document)["ok"] is True
    print(f"PASS: JSON remains valid and escape-free (terminal={terminal})")
