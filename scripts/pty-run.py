#!/usr/bin/env python3
"""Run one command under a pty and stream the raw transcript to stdout.

The twin harness normally pipes output, which is exactly the case where the
reference binary refuses to bold table headers. To prove the port matches the
terminal behaviour too, both binaries are run through this wrapper: stdout
and stderr become a pty slave (isatty(1) is true, so the bold policy fires),
while stdin stays /dev/null so interactive confirmation paths take the same
non-interactive branch they take when piped. Output keeps the pty's
ONLCR translation on both sides, which cancels out under comparison.
"""
import os
import select
import signal
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: pty-run.py COMMAND [ARGS...]", file=sys.stderr)
        return 2
    master, slave = os.openpty()
    pid = os.fork()
    if pid == 0:
        try:
            os.dup2(slave, 1)
            os.dup2(slave, 2)
            devnull = os.open(os.devnull, os.O_RDWR)
            os.dup2(devnull, 0)
            os.close(master)
            os.execvp(sys.argv[1], sys.argv[1:])
        except BaseException:
            pass
        os._exit(127)
    os.close(slave)
    transcript = bytearray()
    idle_deadline = 25.0
    while True:
        ready, _, _ = select.select([master], [], [], idle_deadline)
        if not ready:
            break
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        transcript += chunk
    # A child stuck on anything must not hang the harness: cut it loose
    # after the read loop ended (idle timeout or EOF), then collect.
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        code = 1
    sys.stdout.buffer.write(bytes(transcript))
    sys.stdout.buffer.flush()
    return code


sys.exit(main())
