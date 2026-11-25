#!/usr/bin/env python3
"""Starts mosh-server sessions for the app's UI tests (docs/PLAN.md, M5).

Runs on the Mac during the test step and listens on 127.0.0.1 only. The simulator
shares the Mac's network, so a UI test reaches it at 127.0.0.1 as well.

  GET /new           starts `mosh-server new -i 127.0.0.1 -- /bin/sh` and answers
                     {"port": P, "key": "...", "pid": N}
      ?delay_ms=D    (1-5000) a slow link for local echo tests (M10): the answer's port
                     is a UDP relay on 127.0.0.1 that holds every datagram D ms in each
                     direction (loopback has no delay); "serverPort" is the server's own.
                     The relay stops with the server (/stop) or with the spawner
      ?program=NAME  instead of /bin/sh: "first-then-upper", a program in raw mode that
                     prints "ready", echoes the first byte typed as it is and every later
                     one upper-cased (a server whose echo differs from mosh's guess)
  GET /alive?pid=N   {"pid": N, "alive": true|false}   (servers started here only)
  GET /stop?pid=N    kills that server; {"pid": N, "stopped": true|false}

  GET /mark?event=E  the app (UI-test launches with -uiTestingSpawnerPort) reports a
                     lifecycle fact, such as "background-clean"; {"marked": E}
  GET /marks         {"events": [...]} in arrival order
  GET /marks/clear   forgets them; {"cleared": true}

  GET /diagnostics?name=N   (with --diag-dir and --sim-udid) a failed UI test asks for the
                     evidence while the app is still as the failure left it: copies the
                     app's debug.log, its session records and session-hosts.json from the
                     simulator's data container, and writes the marks, the app's processes
                     and the files open in its records (lsof) into DIR/N/; {"saved": path,
                     "removed": [...]}. Processes are pid, parent, state, start time and
                     program path only, never a command line: the app's arguments carry
                     -debugMoshKey and its value. Every kept file is then searched for the
                     session keys this spawner handed out (as text and as raw bytes) and
                     for a "-debugMoshKey <key>" argument; a file that holds one is
                     deleted and named in "removed" and in the log.
  GET /keycheck      searches DIR and every --key-check-dir the same way, deletes what holds
                     a key and answers {"files": n, "removed": [...]}; scripts/sim-test.sh
                     asks for it at the end of the run and fails if "removed" is not empty

A server exits after 60 s without a client, so a test asks for one just before it
launches the app. On exit (SIGTERM, SIGINT) every server started here that still
runs is killed.

With --sshd it also runs a throwaway sshd for the SSH bootstrap UI test: the
system's /usr/sbin/sshd as the current user (no root, no sudo), on 127.0.0.1 and a
free port, with its own config, host key and authorized_keys in a temporary
directory. Nothing in ~/.ssh or /etc is read for keys or changed: the config names
its own files, and it accepts only public keys handed to /sshd/authorize, only for
the current user.

  GET /sshd                 {"port", "user", "hostKeyFingerprint", "udpPorts",
                             "serverPath"}  (503 if sshd did not start)
  GET /sshd/authorize?key=  appends one "ssh-ed25519 AAAA... comment" line to the
                            throwaway authorized_keys; {"added": true}
  GET /sshd/servers         {"pids": [...]}: mosh-servers of this user whose
                            command line has "-p <range>" with a port or a range that
                            lies inside <udpPorts> (the UI tests' hosts use that range
                            or a part of it, such as a host with two ports, so they are
                            the tests' servers)
  GET /sshd/stop?pid=N      kills (SIGKILL) one of those servers; {"pid": N,
                            "stopped": true|false} (false: not one of them)
  GET /sshd/signal?pid=N&sig=STOP|CONT
                            sends SIGSTOP or SIGCONT to one of those servers (a server
                            that cannot answer, as behind a dead network, and the same
                            server back); {"pid": N, "signalled": true|false}
  GET /sshd/hold?on=1|0     SIGSTOP (on=1) or SIGCONT (on=0) to the throwaway sshd
                            itself: a new connection waits in its listen queue and the
                            login (and so the app's host key question) comes only after
                            on=0; {"held": true|false}

On exit sshd is stopped, those mosh-servers are killed and the directory removed.

  scripts/mosh-spawner.py [--port 0] [--port-file FILE] [--mosh-server PATH] [--sshd]
                         [--diag-dir DIR --sim-udid UDID [--bundle-id ID]]
                         [--key-check-dir DIR ...]

With --port 0 the system picks the port; --port-file receives it once the server
listens (scripts/sim-test.sh waits for that file). Standard library only. The
session key is a throwaway, but it is still never logged.
"""

import argparse
import base64
import heapq
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONNECT_RE = re.compile(r"^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\s*$", re.M)
PID_RE = re.compile(r"\[mosh-server detached, pid = (\d+)\]")

spawned = set()
spawned_lock = threading.Lock()
relays = {}  # server pid -> DelayRelay
marks = []
marks_lock = threading.Lock()
# Session keys handed out by /new, in memory only: what the key check searches kept files for.
issued_keys = set()
KEY_ARG_RE = re.compile(rb"debug(?:Mosh|Fallback)Key[^A-Za-z0-9/+]{1,12}[A-Za-z0-9/+]{22}(?![A-Za-z0-9/+])")


def run_text(argv, timeout=20):
    """Output of a diagnostic command, or why there is none."""
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout, text=True)
        return done.stdout
    except Exception as error:  # diagnostics never fail the test run
        return "%s: %s\n" % (" ".join(argv), error)


def key_needles():
    """Every issued key as its printable text and as its 16 raw bytes."""
    needles = []
    with spawned_lock:
        keys = list(issued_keys)
    for key in keys:
        needles.append(key.encode())
        try:
            needles.append(base64.b64decode(key + "=="))
        except ValueError:
            pass
    return needles


def remove_files_with_keys(roots):
    """Deletes every file under roots that holds an issued session key or a -debugMoshKey
    argument with its value. Returns (files searched, paths removed); never the key."""
    needles = key_needles()
    searched, removed = 0, []
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for folder, _, names in os.walk(root):
            for file_name in names:
                path = os.path.join(folder, file_name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                searched += 1
                try:
                    with open(path, "rb") as f:
                        data = f.read()
                except OSError:
                    continue
                if KEY_ARG_RE.search(data) or any(n in data for n in needles):
                    os.remove(path)
                    removed.append(path)
    return searched, removed


def save_diagnostics(diag_dir, udid, bundle_id, name):
    """Copies what explains a failed UI test into diag_dir/name; returns that path and the
    files the key check removed from it.

    Nothing from the Keychain is read: on iOS the session key is not in the record. No
    command line is written: the app's arguments hold its session key."""
    target = os.path.join(diag_dir, name)
    os.makedirs(target, exist_ok=True)
    with marks_lock:
        events = list(marks)
    with open(os.path.join(target, "marks.json"), "w") as f:
        json.dump({"events": events}, f)
    container = run_text(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"]).strip()
    notes = ["data container: " + container]
    if os.path.isdir(container):
        for part in ["Documents/debug.log.1", "Documents/debug.log",
                     "Library/Application Support/session-hosts.json"]:
            source = os.path.join(container, part)
            if os.path.exists(source):
                shutil.copy2(source, os.path.join(target, os.path.basename(part)))
            else:
                notes.append("missing: " + part)
        sessions = os.path.join(container, "Library/Application Support/sessions")
        if os.path.isdir(sessions):
            shutil.copytree(sessions, os.path.join(target, "sessions"), dirs_exist_ok=True)
            with open(os.path.join(target, "sessions-ls.txt"), "w") as f:
                f.write(run_text(["ls", "-laR", "-T", sessions]))
            with open(os.path.join(target, "lsof.txt"), "w") as f:
                f.write(run_text(["lsof", "-nP", "+D", sessions], timeout=60))
        else:
            notes.append("no sessions directory")
    # comm is the program's path without its arguments (macOS ps); never "command"/"args".
    with open(os.path.join(target, "processes.txt"), "w") as f:
        lines = run_text(["ps", "-axo", "pid,ppid,stat,lstart,etime,comm"]).splitlines()
        f.write("\n".join(lines[:1] + [l for l in lines[1:] if "IOSMosh" in l or "mosh-server" in l]) + "\n")
    with open(os.path.join(target, "notes.txt"), "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n" + "\n".join(notes) + "\n")
    _, removed = remove_files_with_keys([target])
    if removed:
        with open(os.path.join(target, "notes.txt"), "a") as f:
            f.write("".join("removed, held a session key: %s\n" % os.path.relpath(p, target)
                            for p in removed))
    return target, removed


def find_mosh_server(given):
    for candidate in (given, os.environ.get("MOSH_SERVER"), "/opt/homebrew/bin/mosh-server",
                      shutil.which("mosh-server")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    sys.exit("mosh-spawner: no mosh-server found (give --mosh-server or MOSH_SERVER)")


def is_mosh_server(pid):
    """True if pid runs and is a mosh-server (guards against a reused pid)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    out = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,comm="],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return False
    stat, _, comm = out.partition(" ")
    return not stat.startswith("Z") and comm.strip().endswith("mosh-server")


# Fixed programs a test may ask for instead of /bin/sh; never a command from the request.
PROGRAMS = {
    "first-then-upper": ["/bin/sh", "-c",
                         "stty raw -echo; printf 'ready\\r\\n'; "
                         "c=$(dd bs=1 count=1 2>/dev/null); printf %s \"$c\"; "
                         "while :; do c=$(dd bs=1 count=1 2>/dev/null); [ -n \"$c\" ] || break; "
                         "printf %s \"$c\" | tr a-z A-Z; done"],
}


class DelayRelay(threading.Thread):
    """A UDP relay on 127.0.0.1 that holds each datagram `delay` seconds, both ways.

    The client's datagrams go to the server from one socket of the relay, so the server
    answers there; its answers go to the address the client last sent from (as mosh-server
    itself follows a roaming client)."""

    def __init__(self, server_port, delay):
        super().__init__(daemon=True)
        self.server = ("127.0.0.1", server_port)
        self.delay = delay
        self.front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.front.bind(("127.0.0.1", 0))
        self.back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.back.bind(("127.0.0.1", 0))
        self.port = self.front.getsockname()[1]
        self.client = None
        self.queue = []  # (due, sequence, socket, data, address)
        self.sequence = 0
        self.stopped = threading.Event()

    def run(self):
        while not self.stopped.is_set():
            now = time.monotonic()
            timeout = max(0.0, self.queue[0][0] - now) if self.queue else 0.5
            try:
                ready, _, _ = select.select([self.front, self.back], [], [], min(timeout, 0.5))
            except (OSError, ValueError):
                return
            for sock in ready:
                try:
                    data, address = sock.recvfrom(65535)
                except OSError:
                    continue
                self.sequence += 1
                due = time.monotonic() + self.delay
                if sock is self.front:
                    self.client = address
                    heapq.heappush(self.queue, (due, self.sequence, self.back, data, self.server))
                elif self.client is not None:
                    heapq.heappush(self.queue, (due, self.sequence, self.front, data, self.client))
            now = time.monotonic()
            while self.queue and self.queue[0][0] <= now:
                _, _, sock, data, address = heapq.heappop(self.queue)
                try:
                    sock.sendto(data, address)
                except OSError:
                    pass

    def stop(self):
        self.stopped.set()
        self.join(timeout=2)
        self.front.close()
        self.back.close()


def start_server(binary, program=None):
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.environ.get("HOME", "/tmp"),
        "USER": os.environ.get("USER", ""),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TERM": "xterm-256color",
        # A plain, predictable shell: no rc files, a short prompt.
        "PS1": "$ ",
        "ENV": "",
    }
    # stdin is /dev/null, so the server has no tty and starts at 80x24.
    proc = subprocess.run(
        [binary, "new", "-i", "127.0.0.1", "--"] + (PROGRAMS[program] if program else ["/bin/sh"]),
        stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=15)
    connect = CONNECT_RE.search(proc.stdout)
    pid = PID_RE.search(proc.stderr)
    if proc.returncode != 0 or not connect or not pid:
        raise RuntimeError("mosh-server exit %d, no MOSH CONNECT line or pid; stderr: %s"
                           % (proc.returncode, proc.stderr.strip()[-300:]))
    result = {"port": int(connect.group(1)), "key": connect.group(2), "pid": int(pid.group(1))}
    with spawned_lock:
        spawned.add(result["pid"])
        issued_keys.add(result["key"])
    return result


def stop_server(pid):
    with spawned_lock:
        known = pid in spawned
        spawned.discard(pid)
        relay = relays.pop(pid, None)
    if relay:
        relay.stop()
    if known and is_mosh_server(pid):
        os.kill(pid, signal.SIGKILL)
        return True
    return False


def stop_all():
    with spawned_lock:
        pids = list(spawned)
    for pid in pids:
        stop_server(pid)


# The UDP range the UI test's saved host asks mosh-server for. Outside mosh's
# default 60000-61000, so no other mosh session on this Mac uses it.
SSHD_UDP_PORTS = "62700:62799"
SSHD_UDP_LOW, SSHD_UDP_HIGH = (int(p) for p in SSHD_UDP_PORTS.split(":"))
# "-p PORT" or "-p LOW:HIGH" as a word of a mosh-server command line.
PORT_ARG_RE = re.compile(r"(?:^|\s)-p\s+(\d{1,5})(?::(\d{1,5}))?(?=\s|$)")
KEY_LINE_RE = re.compile(r"^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [\x21-\x7e][\x20-\x7e]*)?$")


def in_test_range(command):
    """True when the command line's "-p" names a port or a range inside SSHD_UDP_PORTS
    (DESIGN.md step 13: a test host may have a range of two ports)."""
    match = PORT_ARG_RE.search(command.split(" -- ", 1)[0])  # not a word of the remote command
    if not match:
        return False
    low = int(match.group(1))
    high = int(match.group(2)) if match.group(2) else low
    return SSHD_UDP_LOW <= low <= high <= SSHD_UDP_HIGH


class ThrowawaySSHD:
    def __init__(self, server_path):
        self.server_path = server_path
        self.directory = tempfile.mkdtemp(prefix="ios-mosh-sshd.")
        self.process = None
        self.port = None
        self.fingerprint = None
        self.error = None
        self.lock = threading.Lock()

    def start(self):
        d = self.directory
        try:
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ios-mosh-test-host",
                            "-f", os.path.join(d, "host_ed25519")], check=True, capture_output=True)
            out = subprocess.run(["/usr/bin/ssh-keygen", "-l", "-f", os.path.join(d, "host_ed25519.pub")],
                                 check=True, capture_output=True, text=True).stdout.split()
            self.fingerprint = out[1]
            keys = os.path.join(d, "authorized_keys")
            open(keys, "w").close()
            os.chmod(keys, 0o600)
            probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
            probe.close()
            config = os.path.join(d, "sshd_config")
            with open(config, "w") as f:
                f.write("\n".join([
                    "Port %d" % self.port,
                    "ListenAddress 127.0.0.1",
                    "HostKey %s" % os.path.join(d, "host_ed25519"),
                    "PidFile %s" % os.path.join(d, "sshd.pid"),
                    "AuthorizedKeysFile %s" % keys,
                    "AuthorizedPrincipalsFile none",
                    "StrictModes no",
                    "UsePAM no",
                    "PubkeyAuthentication yes",
                    "PasswordAuthentication no",
                    "KbdInteractiveAuthentication no",
                    "PermitRootLogin no",
                    "AllowUsers %s" % os.environ.get("USER", ""),
                    "PrintMotd no",
                    "",
                ]))
            log = open(os.path.join(d, "sshd.log"), "w")
            self.process = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", config],
                                            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            deadline = time.time() + 5
            while time.time() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("sshd exited: " + open(os.path.join(d, "sshd.log")).read()[-400:])
                try:
                    socket.create_connection(("127.0.0.1", self.port), timeout=0.5).close()
                    sys.stderr.write("mosh-spawner: sshd on 127.0.0.1:%d\n" % self.port)
                    return
                except OSError:
                    time.sleep(0.1)
            raise RuntimeError("sshd does not listen on port %d" % self.port)
        except Exception as error:
            self.error = str(error)
            sys.stderr.write("mosh-spawner: sshd: %s\n" % self.error)

    def info(self):
        return {"port": self.port, "user": os.environ.get("USER", ""), "hostKeyFingerprint": self.fingerprint,
                "udpPorts": SSHD_UDP_PORTS, "serverPath": self.server_path}

    def authorize(self, line):
        line = line.strip()
        if not KEY_LINE_RE.match(line):
            raise ValueError("not a single ssh-ed25519 public key line")
        with self.lock:
            with open(os.path.join(self.directory, "authorized_keys"), "a") as f:
                f.write(line + "\n")

    def servers(self):
        out = subprocess.run(["ps", "-U", str(os.getuid()), "-o", "pid=,command="],
                             capture_output=True, text=True).stdout
        pids = []
        for row in out.splitlines():
            pid, _, command = row.strip().partition(" ")
            if "mosh-server new" in command and in_test_range(command) \
                    and is_mosh_server(int(pid)):  # not the login shell that started it
                pids.append(int(pid))
        return pids

    def hold(self, on):
        if self.process and self.process.poll() is None:
            os.kill(self.process.pid, signal.SIGSTOP if on else signal.SIGCONT)

    def stop(self):
        if self.process and self.process.poll() is None:
            os.kill(self.process.pid, signal.SIGCONT)  # a held sshd must be able to exit
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        for pid in self.servers():
            os.kill(pid, signal.SIGKILL)
        shutil.rmtree(self.directory, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "mosh-spawner/1"
    binary = None
    sshd = None
    diag_dir = None
    key_check_dirs = []
    sim_udid = None
    # The Debug build, which the simulator tests run: the Dev app.
    bundle_id = "us.v9n.ios-mosh.dev"

    def reply(self, code, body):
        data = (json.dumps(body) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def pid_arg(self, query):
        try:
            return int(query.get("pid", [""])[0])
        except ValueError:
            return None

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/new":
            program = query.get("program", [None])[0]
            delay_text = query.get("delay_ms", [None])[0]
            if program is not None and program not in PROGRAMS:
                self.reply(400, {"error": "unknown program"})
                return
            try:
                delay_ms = int(delay_text) if delay_text is not None else 0
            except ValueError:
                delay_ms = -1
            if not 0 <= delay_ms <= 5000:
                self.reply(400, {"error": "delay_ms must be 0-5000"})
                return
            try:
                result = start_server(self.binary, program)
            except Exception as error:  # report it to the test, which fails with the text
                self.reply(500, {"error": str(error)})
                return
            if delay_ms:
                relay = DelayRelay(result["port"], delay_ms / 1000.0)
                relay.start()
                with spawned_lock:
                    relays[result["pid"]] = relay
                result["serverPort"] = result["port"]
                result["port"] = relay.port
                self.log_message("new: port %d pid %d, relay port %d delay %d ms",
                                 result["serverPort"], result["pid"], relay.port, delay_ms)
            else:
                self.log_message("new: port %d pid %d", result["port"], result["pid"])
            self.reply(200, result)
        elif url.path == "/alive":
            pid = self.pid_arg(query)
            if pid is None:
                self.reply(400, {"error": "pid missing"})
                return
            with spawned_lock:
                known = pid in spawned
            self.reply(200, {"pid": pid, "alive": known and is_mosh_server(pid)})
        elif url.path == "/stop":
            pid = self.pid_arg(query)
            if pid is None:
                self.reply(400, {"error": "pid missing"})
                return
            self.reply(200, {"pid": pid, "stopped": stop_server(pid)})
        elif url.path == "/mark":
            event = query.get("event", [""])[0]
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", event):
                self.reply(400, {"error": "event must be 1-64 letters, digits, dots, dashes"})
                return
            with marks_lock:
                marks.append(event)
            self.reply(200, {"marked": event})
        elif url.path == "/marks":
            with marks_lock:
                events = list(marks)
            self.reply(200, {"events": events})
        elif url.path == "/marks/clear":
            with marks_lock:
                marks.clear()
            self.reply(200, {"cleared": True})
        elif url.path == "/diagnostics":
            name = query.get("name", [""])[0]
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", name):
                self.reply(400, {"error": "name must be 1-128 letters, digits, dots, dashes"})
                return
            if not (self.diag_dir and self.sim_udid):
                self.reply(503, {"error": "run with --diag-dir and --sim-udid"})
                return
            path, removed = save_diagnostics(self.diag_dir, self.sim_udid, self.bundle_id, name)
            self.log_message("diagnostics saved: %s", path)
            for item in removed:
                self.log_message("key check: removed %s (held a session key)", item)
            self.reply(200, {"saved": path, "removed": removed})
        elif url.path == "/keycheck":
            searched, removed = remove_files_with_keys([self.diag_dir] + self.key_check_dirs)
            self.log_message("key check: %d files searched, %d removed", searched, len(removed))
            for item in removed:
                self.log_message("key check: removed %s (held a session key)", item)
            self.reply(200, {"files": searched, "removed": removed})
        elif url.path.startswith("/sshd"):
            if self.sshd is None or self.sshd.error:
                self.reply(503, {"error": "no sshd: " + (self.sshd.error if self.sshd else "run with --sshd")})
            elif url.path == "/sshd":
                self.reply(200, self.sshd.info())
            elif url.path == "/sshd/authorize":
                try:
                    self.sshd.authorize(query.get("key", [""])[0])
                except ValueError as error:
                    self.reply(400, {"error": str(error)})
                    return
                self.reply(200, {"added": True})
            elif url.path == "/sshd/servers":
                self.reply(200, {"pids": self.sshd.servers()})
            elif url.path == "/sshd/hold":
                on = query.get("on", [""])[0]
                if on not in ("0", "1"):
                    self.reply(400, {"error": "on=1|0 needed"})
                    return
                self.sshd.hold(on == "1")
                self.log_message("sshd hold: %s", on)
                self.reply(200, {"held": on == "1"})
            elif url.path == "/sshd/stop":
                pid = self.pid_arg(query)
                if pid is None:
                    self.reply(400, {"error": "pid missing"})
                    return
                stopped = pid in self.sshd.servers()
                if stopped:
                    os.kill(pid, signal.SIGKILL)
                self.reply(200, {"pid": pid, "stopped": stopped})
            elif url.path == "/sshd/signal":
                pid = self.pid_arg(query)
                sig = {"STOP": signal.SIGSTOP, "CONT": signal.SIGCONT}.get(query.get("sig", [""])[0])
                if pid is None or sig is None:
                    self.reply(400, {"error": "pid and sig=STOP|CONT needed"})
                    return
                signalled = pid in self.sshd.servers()
                if signalled:
                    os.kill(pid, sig)
                self.log_message("sshd signal: pid %d sig %s: %s", pid, sig.name, signalled)
                self.reply(200, {"pid": pid, "signalled": signalled})
            else:
                self.reply(404, {"error": "unknown path"})
        else:
            self.reply(404, {"error": "unknown path"})

    def log_message(self, fmt, *args):
        # Request lines carry no session key (that is only in the /new response body);
        # /sshd/authorize carries a public key, which is not secret.
        # UTC with milliseconds, as the app's debug.log, so the two can be read side by side.
        now = time.time()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + ".%03dZ" % (int(now * 1000) % 1000)
        sys.stderr.write(stamp + " mosh-spawner: " + (fmt % args) + "\n")
        sys.stderr.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file")
    parser.add_argument("--mosh-server")
    parser.add_argument("--sshd", action="store_true")
    parser.add_argument("--diag-dir")
    parser.add_argument("--sim-udid")
    parser.add_argument("--bundle-id", default=Handler.bundle_id)
    parser.add_argument("--key-check-dir", action="append", default=[],
                        help="also searched by /keycheck (repeatable)")
    args = parser.parse_args()

    Handler.diag_dir = args.diag_dir
    Handler.key_check_dirs = args.key_check_dir
    Handler.sim_udid = args.sim_udid
    Handler.bundle_id = args.bundle_id

    Handler.binary = find_mosh_server(args.mosh_server)
    if args.sshd:
        Handler.sshd = ThrowawaySSHD(Handler.binary)
        Handler.sshd.start()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True

    def finish(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, finish)
    signal.signal(signal.SIGINT, finish)

    port = httpd.server_address[1]
    if args.port_file:
        tmp = args.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d\n" % port)
        os.replace(tmp, args.port_file)
    sys.stderr.write("mosh-spawner: listening on 127.0.0.1:%d\n" % port)
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    finally:
        stop_all()
        if Handler.sshd:
            Handler.sshd.stop()
        httpd.server_close()
        if args.port_file:
            try:
                os.unlink(args.port_file)
            except OSError:
                pass


if __name__ == "__main__":
    main()
