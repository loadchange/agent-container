#!/usr/bin/env python3
"""Run a command under a real PTY and feed one line to its stdin."""

import os
import pty
import subprocess
import sys


def run_with_pipe_stdin_and_pty_output(argv: list[str]) -> int:
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=slave,
            stderr=slave,
            env=os.environ,
        )
    finally:
        os.close(slave)

    assert process.stdin is not None
    process.stdin.write(b"pipe-to-terminal-output\n")
    process.stdin.close()
    while True:
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        os.write(sys.stdout.fileno(), data)
    os.close(master)
    return process.wait()


def main() -> int:
    if len(sys.argv) < 2:
        return 64

    if sys.argv[1] == "--pipe-stdin":
        if len(sys.argv) < 3:
            return 64
        return run_with_pipe_stdin_and_pty_output(sys.argv[2:])

    pid, master = pty.fork()
    if pid == 0:
        os.execvpe(sys.argv[1], sys.argv[1:], os.environ)

    os.write(master, b"terminal-input\n")
    while True:
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        os.write(sys.stdout.fileno(), data)

    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    raise SystemExit(main())
