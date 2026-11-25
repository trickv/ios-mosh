#!/usr/bin/env python3
"""Record a terminal session in a pty, for the golden corpus of the terminal model.

Runs a program in a pty of a given size (by default `bash --norc --noprofile -i`;
another one can be given after `--`), plays a script of keystrokes, delays and
window resizes, and writes a session file for
`mosh-oracle gen`: JSON lines, first {"width":W,"height":H}, then one line per
read() from the pty, {"bytes_b64":"..."}, with {"resize":[w,h]} lines in between
where the window size was changed.

One read is one session line and later one terminal state. The read sizes come from
a fixed pseudo-random sequence (--seed), so boundaries fall at arbitrary places,
including inside escape sequences and inside multi-byte characters.

Fixed settings, for repeatable recordings: TERM=xterm-256color, en_US.UTF-8,
PS1='golden$ ', HOME and the working directory in a directory the caller prepares
(no vimrc, tmux.conf or htoprc there), TZ=UTC.

With --oracle PATH the recorder runs `mosh-oracle respond` beside the program and
writes the terminal's answers (device attributes, cursor position reports) back to
the pty, as mosh-server does, so programs that query the terminal see what they
would see under mosh.

Script file: one command per line, arguments in Python literal syntax, # comments.
    size 80, 24          first command if present; default 80, 24
    seed 7               seed of the read-size sequence; default 1
    max_states 150       cap on session lines; adjacent reads are merged to fit
    wait 500             record for 500 ms
    send "ls\\r"          write these bytes at once
    type "ls -l", 40     write one character every 40 ms (default 30)
    expect "$ ", 5000    record until this text has appeared since the last input
                         (default timeout 5000 ms; a timeout is an error)
    resize 100, 30       TIOCSWINSZ, and a resize line in the session
    exit 3000            record until the program exits (default 3000 ms)
"""

import argparse
import ast
import base64
import fcntl
import json
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def set_winsize(fd, width, height):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))


class ReadSizes:
    """Fixed pseudo-random read sizes: a mix of tiny, medium and whole-buffer reads."""

    def __init__(self, seed):
        self.state = (seed * 2654435761 + 1) & 0xFFFFFFFF

    def rand(self):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return self.state >> 8

    def next(self):
        r = self.rand() % 100
        if r < 30:
            return 1 + self.rand() % 16
        if r < 70:
            return 17 + self.rand() % 240
        return 4096


class Recorder:
    def __init__(self, width, height, home, oracle, seed, command):
        self.width, self.height = width, height
        self.events = []
        self.recent = b""
        self.eof = False
        self.sizes = ReadSizes(seed)
        self.oracle = None
        if oracle:
            self.oracle = subprocess.Popen(
                [oracle, "respond", str(width), str(height)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)

        self.master, slave = os.openpty()
        set_winsize(self.master, width, height)
        attrs = termios.tcgetattr(slave)
        attrs[0] |= getattr(termios, "IUTF8", 0x4000)  # as mosh-server does (Linux value)
        termios.tcsetattr(slave, termios.TCSANOW, attrs)

        env = {
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PS1": "golden$ ",
            "HOME": home,
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "SHELL": "/bin/bash",
            "USER": "golden",
            "LOGNAME": "golden",
            "TZ": "UTC",
            "TMUX_TMPDIR": home,
            "HISTFILE": os.path.join(home, ".bash_history"),
        }
        self.pid = os.fork()
        if self.pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                os.closerange(3, 256)
                os.chdir(home)
                os.execvpe(command[0], command, env)
            finally:
                os._exit(127)
        os.close(slave)

    def ask_oracle(self, line):
        if not self.oracle:
            return b""
        self.oracle.stdin.write(line + b"\n")
        self.oracle.stdin.flush()
        reply = self.oracle.stdout.readline()
        if not reply.endswith(b"\n"):
            raise SystemExit("pty-record: the oracle co-process died")
        return base64.b64decode(reply.strip())

    def write(self, data):
        while data:
            n = os.write(self.master, data)
            data = data[n:]

    def pump(self, ms, until=None):
        """Record output for ms milliseconds, or until `until` has appeared."""
        deadline = time.monotonic() + ms / 1000.0
        while not self.eof:
            if until is not None and until in self.recent:
                return True
            left = deadline - time.monotonic()
            if left <= 0:
                break
            ready, _, _ = select.select([self.master], [], [], left)
            if not ready:
                continue
            try:
                data = os.read(self.master, self.sizes.next())
            except OSError:
                data = b""
            if not data:
                self.eof = True
                break
            self.events.append(("bytes", data))
            self.recent += data
            reply = self.ask_oracle(b"B " + base64.b64encode(data))
            if reply:
                self.write(reply)
        return until is None or until in self.recent

    def input(self, data):
        self.recent = b""
        self.write(data)

    def resize(self, width, height):
        self.recent = b""
        self.width, self.height = width, height
        # mosh-server: first the emulator, then the pty (which signals the program)
        self.events.append(("resize", width, height))
        self.ask_oracle(b"R %d %d" % (width, height))
        set_winsize(self.master, width, height)

    def finish(self):
        try:
            os.kill(self.pid, 0)
            os.killpg(self.pid, signal.SIGHUP)
            time.sleep(0.2)
            os.killpg(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        if self.oracle:
            self.oracle.stdin.close()
            self.oracle.wait()


def to_bytes(value):
    return value if isinstance(value, bytes) else value.encode("utf-8")


def cap_events(events, max_states):
    """Merge adjacent reads, smallest combined pair first, until the count fits."""
    events = list(events)
    while len(events) > max_states:
        best = None
        for i in range(len(events) - 1):
            if events[i][0] == "bytes" and events[i + 1][0] == "bytes":
                n = len(events[i][1]) + len(events[i + 1][1])
                if best is None or n < best[0]:
                    best = (n, i)
        if best is None:
            break
        i = best[1]
        events[i] = ("bytes", events[i][1] + events[i + 1][1])
        del events[i + 1]
    return events


def parse_script(path):
    commands = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, rest = line.partition(" ")
            try:
                args = ast.literal_eval("(" + rest + ",)") if rest.strip() else ()
            except (SyntaxError, ValueError) as e:
                raise SystemExit("%s:%d: %s" % (path, lineno, e))
            commands.append((lineno, name, args))
    return commands


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--script", required=True)
    ap.add_argument("--out", required=True, help="session file to write")
    ap.add_argument("--home", required=True, help="HOME and working directory of the recorded shell")
    ap.add_argument("--oracle", help="path of mosh-oracle, to answer terminal queries")
    ap.add_argument("command", nargs="*", default=["bash", "--norc", "--noprofile", "-i"],
                    help="program to run instead of bash (after --)")
    args = ap.parse_args()

    commands = parse_script(args.script)
    width, height, seed, max_states = 80, 24, 1, 150
    body = []
    for lineno, name, a in commands:
        if name == "size":
            width, height = a
        elif name == "seed":
            (seed,) = a
        elif name == "max_states":
            (max_states,) = a
        else:
            body.append((lineno, name, a))

    rec = Recorder(width, height, args.home, args.oracle, seed, args.command)
    first_size = (width, height)
    try:
        for lineno, name, a in body:
            if name == "wait":
                rec.pump(a[0])
            elif name == "send":
                rec.input(to_bytes(a[0]))
            elif name == "type":
                delay = a[1] if len(a) > 1 else 30
                text = a[0]
                units = [bytes([b]) for b in text] if isinstance(text, bytes) else [c.encode("utf-8") for c in text]
                rec.recent = b""
                for unit in units:
                    rec.write(unit)
                    rec.pump(delay)
            elif name == "expect":
                timeout = a[1] if len(a) > 1 else 5000
                if not rec.pump(timeout, until=to_bytes(a[0])):
                    tail = rec.recent[-400:]
                    raise SystemExit("%s:%d: expected %r, got eof=%s and output ending in %r"
                                     % (args.script, lineno, a[0], rec.eof, tail))
            elif name == "resize":
                rec.resize(a[0], a[1])
            elif name == "exit":
                timeout = a[0] if a else 3000
                deadline = time.monotonic() + timeout / 1000.0
                while not rec.eof and time.monotonic() < deadline:
                    rec.pump(50)
                if not rec.eof:
                    raise SystemExit("%s:%d: the program did not exit" % (args.script, lineno))
            else:
                raise SystemExit("%s:%d: unknown command %s" % (args.script, lineno, name))
    finally:
        rec.finish()

    events = cap_events(rec.events, max_states)
    with open(args.out, "w", encoding="ascii") as out:
        out.write(json.dumps({"width": first_size[0], "height": first_size[1]}, separators=(",", ":")) + "\n")
        for ev in events:
            if ev[0] == "bytes":
                line = {"bytes_b64": base64.b64encode(ev[1]).decode("ascii")}
            else:
                line = {"resize": [ev[1], ev[2]]}
            out.write(json.dumps(line, separators=(",", ":")) + "\n")
    total = sum(len(ev[1]) for ev in events if ev[0] == "bytes")
    sys.stderr.write("pty-record: %s: %d reads merged to %d lines, %d bytes\n"
                     % (args.out, len(rec.events), len(events), total))


if __name__ == "__main__":
    main()
