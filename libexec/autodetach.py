#!/usr/bin/env python3
"""Run an interactive `docker run -it ...`, optionally auto-fill credentials,
and auto-detach once connected.

Usage: autodetach.py <success-regex> <command> [args...]

The command runs attached to a pseudo-terminal with the caller's terminal passed
through, so prompts work normally. Behaviour:

  * If OP_PASSWORD is set in the environment, it is typed at the client's
    password prompt; if OP_OTP is set, it is typed at the 2FA/token prompt.
    (Values come from `op` on the host and are typed straight into the client --
    they never enter the container's environment or `docker inspect`.)
    The token prompt pattern can be overridden with VPN_OP_TOKEN_RE.
  * As soon as the child's output matches <success-regex>, it sends docker's
    detach sequence (ctrl-p ctrl-q) so the container keeps running in the
    background and control returns to the caller.

Falls back to a plain passthrough when no OP_* vars are set. Pure stdlib.
"""
import os
import sys
import re
import pty
import tty
import termios
import select
import signal
import fcntl


def main():
    if len(sys.argv) < 3:
        sys.exit("autodetach: usage: autodetach.py <regex> <command> [args...]")
    pattern = re.compile(sys.argv[1].encode())
    cmd = sys.argv[2:]

    op_password = os.environ.get("OP_PASSWORD", "").encode() or None
    op_otp = os.environ.get("OP_OTP", "").encode() or None
    pw_re = re.compile(rb"(?i)password[^\n]*:[ \t]*$")
    token_re = re.compile(
        os.environ.get(
            "VPN_OP_TOKEN_RE",
            r"(?i)(answer|passcode|token|otp|verification|one[- ]?time|"
            r"response|challenge|secondary|second\s+password|code)[^\n]*:[ \t]*$",
        ).encode()
    )
    pw_sent = op_password is None
    otp_sent = op_otp is None

    pid, fd = pty.fork()
    if pid == 0:  # child: become the docker client
        os.execvp(cmd[0], cmd)
        os._exit(127)

    def set_winsize(*_):
        try:
            sz = fcntl.ioctl(pty.STDIN_FILENO, termios.TIOCGWINSZ, b"\0" * 8)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, sz)
        except Exception:
            pass

    stdin_tty = sys.stdin.isatty()
    set_winsize()
    signal.signal(signal.SIGWINCH, set_winsize)

    old_attr = None
    if stdin_tty:
        old_attr = termios.tcgetattr(sys.stdin.fileno())
        tty.setraw(sys.stdin.fileno())

    detached = False
    watch_stdin = True
    buf = b""
    try:
        while True:
            watch = [fd] + ([sys.stdin.fileno()] if watch_stdin else [])
            try:
                readable, _, _ = select.select(watch, [], [])
            except select.error:
                continue

            if fd in readable:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
                buf = (buf + data)[-8192:]

                # Auto-fill: password first, then the token, each once.
                if not pw_sent and pw_re.search(buf):
                    os.write(fd, op_password + b"\n")
                    pw_sent, buf = True, b""
                elif pw_sent and not otp_sent and token_re.search(buf):
                    os.write(fd, op_otp + b"\n")
                    otp_sent, buf = True, b""
                elif not detached and pattern.search(buf):
                    os.write(fd, b"\x10\x11")  # ctrl-p ctrl-q -> docker detach
                    detached = True

            if watch_stdin and sys.stdin.fileno() in readable:
                try:
                    data = os.read(sys.stdin.fileno(), 65536)
                except OSError:
                    data = b""
                if not data:
                    watch_stdin = False  # our stdin closed; keep draining child
                else:
                    os.write(fd, data)
    finally:
        if old_attr is not None:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_attr)
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass


if __name__ == "__main__":
    main()
