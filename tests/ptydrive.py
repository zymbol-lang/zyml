#!/usr/bin/env python3
"""Drive a program through a pty, feeding keystrokes as it asks for them.

`<<|` needs a real terminal, so a pipe cannot exercise it at all — this is the
only way to test key input without a human at the keyboard.

Keys are sent interleaved with reading, not up front: a program that has not
yet put the terminal into raw mode is still line-buffered, and anything sent
before that point is either echoed or swallowed.
"""
import os, pty, sys, time, select, signal, fcntl, termios, struct

def run(cmd, keys, settle=0.35, quiet=0.6, timeout=12.0, rows=30, cols=100):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    # A freshly forked pty reports 0x0, which makes every layout compute
    # negative coordinates.  Give it a real size so the program lays out as it
    # would on screen.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    out = b""
    pending = list(keys)
    deadline = time.time() + timeout
    last_read = time.time()
    time.sleep(settle)                      # let it reach the first read

    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            last_read = time.time()
        elif pending:
            os.write(fd, pending.pop(0))    # it is waiting: give it a key
            time.sleep(0.05)
        elif time.time() - last_read > quiet:
            break                           # no keys left and nothing coming

    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    return out.decode("utf-8", "replace")

if __name__ == "__main__":
    sep = sys.argv.index("--")
    cmd = sys.argv[1:sep]
    keys = [k.encode().decode("unicode_escape").encode("latin-1")
            for k in sys.argv[sep+1:]]
    sys.stdout.write(run(cmd, keys))
