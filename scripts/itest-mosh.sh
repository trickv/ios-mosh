#!/usr/bin/env bash
# The mosh half of scripts/itest.sh: moshcli against a real mosh-server on 127.0.0.1.
# Runs where swift and mosh-server are (the dev container, or a Mac). Use scripts/itest.sh.
#   scripts/itest-mosh.sh handshake|hello|script|rebind|resume-mem|soak|predict ...
#   scripts/itest-mosh.sh bootstrap-session   (only under scripts/itest-sshd.sh: needs its sshd)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v mosh-server >/dev/null || { echo "itest: mosh-server is not in PATH" >&2; exit 1; }
# ITEST_SKIP_BUILD=1: use moshcli as it was last built and leave out the XCTest step (for a run
# under tc netem, where swift build hangs).
[ "${ITEST_SKIP_BUILD:-0}" = 1 ] || swift build -j 4 --product moshcli 2>&1 | tail -n 3 >&2
MOSHCLI="$(swift build -j 4 --show-bin-path)/moshcli"
[ -x "$MOSHCLI" ] || { echo "itest: $MOSHCLI was not built" >&2; exit 1; }

TMP="$(mktemp -d)"
SERVER_PIDS=()
cleanup() {
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

if locale -a 2>/dev/null | grep -qix 'C\.utf-\?8'; then UTF8_LOCALE=C.UTF-8; else UTF8_LOCALE=en_US.UTF-8; fi

# start_server COMMAND...: starts a detached mosh-server running COMMAND. Its standard input
# is /dev/null, so it has no tty to take a size from and starts at 80x24 (mosh-server.cc), the
# --server-size moshcli assumes by default.
# Sets PORT, MOSH_KEY (exported: moshcli reads it, so the key is not on a command line) and PID.
start_server() {
  local out
  out="$(LC_ALL=$UTF8_LOCALE LANG=$UTF8_LOCALE PS1='$ ' ENV= mosh-server new -i 127.0.0.1 -- "$@" 2>&1 < /dev/null)"
  PORT="$(printf '%s\n' "$out" | sed -n 's/^MOSH CONNECT \([0-9]*\) .*/\1/p')"
  MOSH_KEY="$(printf '%s\n' "$out" | sed -n 's/^MOSH CONNECT [0-9]* \([^[:space:]]*\).*/\1/p')"
  PID="$(printf '%s\n' "$out" | sed -n 's/.*detached, pid = \([0-9]*\).*/\1/p')"
  if [ -z "$PORT" ] || [ -z "$MOSH_KEY" ] || [ -z "$PID" ]; then
    echo "itest: mosh-server did not start: $out" >&2
    exit 1
  fi
  export MOSH_KEY
  SERVER_PIDS+=("$PID")
}

# The process with pid $PID exists and is the mosh-server we started.
server_alive() {
  kill -0 "$PID" 2>/dev/null && ps -p "$PID" -o comm= | grep -q mosh-server
}

fail() {
  echo "FAIL $TEST: $*" >&2
  exit 1
}

# run_script EXPECTED_EXIT NAME [moshcli options]: runs the script on standard input.
run_script() {
  local expected="$1" name="$2" code=0
  shift 2
  cat > "$TMP/$name.script"
  "$MOSHCLI" connect --host 127.0.0.1 --port "$PORT" --script "$TMP/$name.script" --quiet "$@" \
    > "$TMP/$name.out" 2> "$TMP/$name.err" || code=$?
  if [ "$code" != "$expected" ]; then
    cat "$TMP/$name.err" >&2
    cat "$TMP/$name.out" >&2
    fail "$name: moshcli connect exited $code, expected $expected"
  fi
  echo "  $name: $(cat "$TMP/$name.out")"
}

test_handshake() {
  start_server sh
  "$MOSHCLI" handshake --host 127.0.0.1 --port "$PORT" > "$TMP/handshake.out" 2>&1 \
    || { cat "$TMP/handshake.out" >&2; fail "moshcli handshake failed"; }
  server_alive || fail "the server is gone"
}

test_hello() {
  start_server sh
  # The prompt first: mosh-server starts the shell only when the first datagram arrives
  # (frontend/mosh-server.cc:593, :822), and a line typed at once races the shell's start-up.
  # When the line wins, the tty echoes it before the prompt and dash prints "$ hello-42" on one
  # row, so the exact-row checks below would fail (Tests/MoshTestSupport/ShellPrompt.swift).
  sed "s|@TMP@|$TMP|g" <<'SCRIPT' | run_script 0 hello --record "$TMP/hello-rec" --seq-log "$TMP/hello.seq"
expect $\s 10000
type echo hello-$((6*7))\r
expect hello-42 10000
expect-screen hello-42 10000
wait-ack
settle 300
dump-screen @TMP@/hello.screen
dump-bytes @TMP@/hello.bytes
SCRIPT
  server_alive || fail "the server is gone"
  # The rendered screen: 24 rows, the command line and its result each on a row of their own.
  [ "$(wc -l < "$TMP/hello.screen")" = 24 ] || fail "dump-screen: $(wc -l < "$TMP/hello.screen") rows, not 24"
  grep -qx '. echo hello-$((6\*7))' "$TMP/hello.screen" || fail "dump-screen: no command line row: $(cat "$TMP/hello.screen")"
  grep -qx 'hello-42' "$TMP/hello.screen" || fail "dump-screen: no row hello-42: $(cat "$TMP/hello.screen")"
  grep -q 'hello-42' "$TMP/hello.bytes" || fail "dump-bytes: no hello-42 in the host bytes"
  echo "  screen: $(grep -c . "$TMP/hello.screen") non-blank rows of 24, hello-42 among them"
  scripts/check-seq-log.sh "$TMP/hello.seq" | sed 's/^/  /' || fail "sequence log"
  [ "$(cat "$TMP/hello-rec/meta.json")" = '{"format":1,"width":80,"height":24}' ] || fail "meta.json: $(cat "$TMP/hello-rec/meta.json")"
  [ -s "$TMP/hello-rec/instructions.jsonl" ] || fail "no instruction was recorded"
  grep -q '"hostbytes_b64"' "$TMP/hello-rec/instructions.jsonl" || fail "no host bytes were recorded"
  if command -v python3 >/dev/null; then
    python3 - "$TMP/hello-rec/instructions.jsonl" <<'PY' || fail "instructions.jsonl is not in the corpus format"
import base64, json, sys
seen, text = set(), b""
for line in open(sys.argv[1]):
    entry = json.loads(line)
    assert list(entry) == ["old_num", "new_num", "diff_b64", "ops"], list(entry)
    assert entry["new_num"] not in seen, "new_num twice"
    seen.add(entry["new_num"])
    base64.b64decode(entry["diff_b64"], validate=True)
    for op in entry["ops"]:
        (kind, value), = op.items()
        assert kind in ("hostbytes_b64", "resize", "echo_ack"), kind
        if kind == "hostbytes_b64":
            text += base64.b64decode(value, validate=True)
assert b"hello-42" in text, "hello-42 is not in the recorded host bytes"
print("  record: %d instructions, %d host bytes" % (len(seen), len(text)))
PY
  fi
}

# The rest of the script language and of the exit codes, each on a server of its own.
# (The pauses around ctrl-c are needed: the tty discards input that is waiting when the
# interrupt arrives, so keys typed in the same instant as ctrl-c are lost on the server.)
test_script() {
  start_server sh
  run_script 0 script-shutdown <<'SCRIPT'
# a comment
resize 100 30
type echo size-$(stty size | tr ' ' x)
key enter
expect size-30x100 10000
type echo\smarker-\x41\t-$((2*4))\r
expect marker-A 10000
settle 300
type sleep 100
key enter
wait-ack
sleep 300
key ctrl-c
wait-ack
sleep 300
type echo after-$((1+2))\r
expect after-3 10000
shutdown
SCRIPT
  local gone=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then gone=1; break; fi
    sleep 0.1
  done
  [ "$gone" = 1 ] || fail "script-shutdown: the server is still there 5 s after a clean shutdown"

  start_server sh
  run_script 4 script-server-ended <<'SCRIPT'
type echo up-$((1+1))\r
expect up-2 10000
type exit\r
sleep 10000
SCRIPT

  start_server sh
  run_script 1 script-expect-fails <<'SCRIPT'
type echo up-$((1+1))\r
expect up-2 10000
expect this-never-arrives 300
SCRIPT
  server_alive || fail "script-expect-fails: the server is gone"

  # expect-screen looks at the rendered screen only: text that was overwritten is not found
  # there, although an earlier frame carried it in the host bytes. printf writes old-text, a
  # second later a carriage return and new-text over it.
  start_server sh
  run_script 1 script-expect-screen <<'SCRIPT'
resize 60 10
type printf 'old-%s' text; sleep 1; printf '\\rnew-%s\\n' text\r
expect old-text 10000
expect-screen new-text 10000
expect-screen old-text 500
SCRIPT
  grep -q 'expect-screen: "old-text" is not on the screen' "$TMP/script-expect-screen.err" \
    || { cat "$TMP/script-expect-screen.err" >&2; fail "script-expect-screen: not the expected failure"; }

  # A port that never answers: "MOSH CONNECT seen, no UDP reply" (shortened timeout), exit 6.
  # The port of a server that was killed: nothing listens there any more.
  start_server sh
  kill -9 "$PID"
  run_script 6 script-no-reply --no-reply-ms 1500 <<'SCRIPT'
type echo nobody-$((1+1))\r
expect nobody-2 10000
SCRIPT
  grep -q "no reply arrived on UDP port $PORT within 15 seconds" "$TMP/script-no-reply.err" \
    || { cat "$TMP/script-no-reply.err" >&2; fail "script-no-reply: no udpBlocked message"; }
}

test_rebind() {
  start_server sh
  local pid_before="$PID"
  run_script 0 rebind --seq-log "$TMP/rebind.seq" <<'SCRIPT'
type echo first-$((1+1))\r
expect first-2 10000
rebind
type echo second-$((2+2))\r
expect second-4 10000
rebind
rebind
type echo third-$((3+3))\r
expect third-6 10000
wait-ack
SCRIPT
  [ "$PID" = "$pid_before" ] && server_alive || fail "the server process changed or is gone"
  grep -q 'sockets 4;' "$TMP/rebind.out" || fail "expected four sockets"
  scripts/check-seq-log.sh "$TMP/rebind.seq" | sed 's/^/  /' || fail "sequence log"
}

# Export, discard the connection object, import into a new one (a gate that starts at the old
# reserved limits, a new socket): the preconditions of M6.
test_resume_mem() {
  # 1. The plain case, then a resume whose first datagram is lost, then quiesce --after-send.
  start_server sh
  run_script 0 resume-basic --seq-log "$TMP/resume-basic.seq" <<'SCRIPT'
type echo one-$((1+1))\r
expect one-2 10000
wait-ack
quiesce
resume-mem
type echo two-$((2+2))\r
expect two-4 5000
wait-ack
quiesce
resume-mem --drop-first 1
type echo three-$((3+3))\r
expect three-6 5000
type echo four-$((4+4))\r
quiesce --after-send
resume-mem
expect four-8 5000
type echo five-$((5+5))\r
expect five-10 5000
wait-ack
SCRIPT
  server_alive || fail "resume-basic: the server is gone"
  grep -q 'resumes 3;' "$TMP/resume-basic.out" || fail "resume-basic: expected three resumes"
  grep -q 'withheld 1;' "$TMP/resume-basic.out" || fail "resume-basic: expected one withheld datagram"
  scripts/check-seq-log.sh "$TMP/resume-basic.seq" | sed 's/^/  /' || fail "resume-basic: sequence log"

  # 2. Unacknowledged input at quiesce time must reach the server exactly once: the session
  # runs cat into a file (the tty is in cooked mode, so each \r arrives as \n).
  local file="$TMP/exactly-once.txt"
  start_server sh -c "cat > '$file'"
  run_script 4 resume-exactly-once --seq-log "$TMP/resume-exactly-once.seq" <<'SCRIPT'
type line-1 acknowledged\r
wait-ack
type line-2 typed and not sent\r
quiesce
resume-mem
type line-3 sent, perhaps not acknowledged\r
sleep 4
quiesce
resume-mem
type line-4 sent, the answer never read\r
quiesce --after-send
resume-mem
type line-5 sent, then the first datagram of the resume is lost\r
quiesce --after-send
resume-mem --drop-first 1
type line-6 two resumes in a row\r
quiesce --after-send
resume-mem
quiesce
resume-mem
type line-7 the last\r
wait-ack
key ctrl-d
sleep 10000
SCRIPT
  cat > "$TMP/exactly-once.expected" <<'TEXT'
line-1 acknowledged
line-2 typed and not sent
line-3 sent, perhaps not acknowledged
line-4 sent, the answer never read
line-5 sent, then the first datagram of the resume is lost
line-6 two resumes in a row
line-7 the last
TEXT
  cmp "$TMP/exactly-once.expected" "$file" >&2 || { diff "$TMP/exactly-once.expected" "$file" >&2 || true; fail "resume-exactly-once: the server did not get each line exactly once"; }
  scripts/check-seq-log.sh "$TMP/resume-exactly-once.seq" | sed 's/^/  /' || fail "resume-exactly-once: sequence log"

  # 3. Twenty resumes in a row in one session.
  start_server sh
  {
    for n in $(seq 1 20); do
      echo "type echo r$n-\$(($n*3))\\r"
      [ $((n % 2)) = 0 ] && echo "wait-ack"
      [ $((n % 5)) = 0 ] && echo "quiesce --after-send" || echo "quiesce"
      echo "resume-mem"
      echo "expect r$n-$((n * 3)) 5000"
    done
    echo "wait-ack"
  } > "$TMP/twenty.in"
  run_script 0 resume-twenty --seq-log "$TMP/resume-twenty.seq" < "$TMP/twenty.in"
  server_alive || fail "resume-twenty: the server is gone"
  grep -q 'resumes 20;' "$TMP/resume-twenty.out" || fail "resume-twenty: expected twenty resumes"
  scripts/check-seq-log.sh "$TMP/resume-twenty.seq" | sed 's/^/  /' || fail "resume-twenty: sequence log"

  # 4. A resume after more than 40 s of silence: the server has forgotten the client's address
  # (SERVER_ASSOCIATION_TIMEOUT in mosh's network.h) and attaches again at the first datagram.
  start_server sh
  run_script 0 resume-after-40s --seq-log "$TMP/resume-40.seq" <<'SCRIPT'
type echo before-$((1+1))\r
expect before-2 10000
wait-ack
quiesce
sleep 42000
resume-mem
type echo after-$((2+2))\r
expect after-4 5000
wait-ack
SCRIPT
  server_alive || fail "resume-after-40s: the server is gone"
  scripts/check-seq-log.sh "$TMP/resume-40.seq" | sed 's/^/  /' || fail "resume-after-40s: sequence log"

  # 5. The same variants as XCTests, with MoshConnection used directly.
  [ "${ITEST_SKIP_BUILD:-0}" = 1 ] && return 0
  swift test -j 4 --filter ResumeIntegrationTests 2>&1 | grep -E "error|failed|Executed|passed \(" | tail -n 20
  [ "${PIPESTATUS[0]}" = 0 ] || fail "ResumeIntegrationTests"
}

# The soak on a clean loopback, with the final screen compared with tmux capture-pane -p
# (scripts/soak.sh; the lossy run is scripts/netem.sh). Two sizes: the server's start size, and
# a smaller view whose rows scroll.
test_soak() {
  MOSHCLI="$MOSHCLI" scripts/soak.sh "${ITEST_SOAK_MINUTES:-0.5}" | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "soak at 80x24"
  MOSHCLI="$MOSHCLI" SOAK_SIZE=60x15 scripts/soak.sh "${ITEST_SOAK_MINUTES:-0.5}" --rebind-every 10 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "soak at 60x15 with rebinds"
}

# moshcli bootstrap against the sshd instances of scripts/itest-sshd.sh: password login, the
# server started over SSH with a 100x30 pty, a session on it, a clean shutdown.
test_predict() {
  # Local echo (docs/notes/m10/DESIGN.md 6.3) against the real server, over a slow link made
  # by moshcli itself (--delay-ms holds every datagram that long in each direction). A fresh
  # engine draws nothing in its first epoch (terminaloverlay.h:76, 298-299), so each part first
  # has one key echoed and waits for the echo ack's state: the server sends it at least 50 ms
  # after it applied the input (completeterminal.cc:130-158), plus the delay.

  # a: always, 300 ms round trip: typed keys are shown well before their echo, and nothing is
  # left drawn once the line ran.
  start_server sh
  run_script 0 predict-a --predict always --delay-ms 150 <<'SCRIPT'
expect $\s 10000
type e
expect-screen $ e 5000
settle 400
type c
type h
type o
type \s
type h
type i
expect-predicted $ echo hi 120
key enter
expect \nhi 5000
expect-display-settled 2000
SCRIPT
  grep -Eq 'displays [1-9][0-9]*;' "$TMP/predict-a.out" || fail "a: no .display event"

  # b: adaptive at a 300 ms round trip: the send interval (about 150 ms) is above 80 ms, so
  # guesses are shown (srtt_trigger) and underlined (flagging), until echoed.
  start_server sh
  run_script 0 predict-b --predict adaptive --delay-ms 150 <<'SCRIPT'
expect $\s 10000
type e
expect-screen $ e 5000
settle 400
type x
expect-underlined x 120
expect-screen $ ex 5000
expect-display-settled 2000
SCRIPT

  # c: guesses with no echo vanish once judged. The program echoes exactly one byte.
  start_server sh -c 'stty raw -echo; dd bs=1 count=1 2>/dev/null; cat >/dev/null'
  run_script 0 predict-c --predict always --delay-ms 150 <<SCRIPT
sleep 1500
type x
expect-screen x 5000
settle 400
type abc
expect-predicted xabc 120
expect-display-settled 3000
dump-display $TMP/predict-c.display
quiesce
dump-screen $TMP/predict-c.screen
SCRIPT
  grep -q '^x' "$TMP/predict-c.display" || fail "c: the echoed x is not on the display"
  if grep -q abc "$TMP/predict-c.display"; then fail "c: a wrong guess is still drawn"; fi
  if grep -q abc "$TMP/predict-c.screen"; then fail "c: a guess reached the remote screen"; fi

  # d: never: nothing predicted, not one .display event.
  start_server sh
  run_script 0 predict-d --predict never --delay-ms 150 <<'SCRIPT'
expect $\s 10000
type echo zz
expect-display-settled 1000
expect zz 5000
key enter
expect \nzz 5000
expect-display-settled 2000
SCRIPT
  grep -q 'displays 0;' "$TMP/predict-d.out" || fail "d: .display events with --predict never"

  # e: adaptive on loopback: srtt_trigger starts on (send interval 250 before the first RTT
  # sample) and goes off at 20 ms with no guess active (terminaloverlay.cc:456-462). The sleep
  # outlasts the server's 3 s heartbeat, so a cull happens with no guess active. After that a
  # typed key is never seen predicted: the wait for it runs out (exit 1).
  start_server sh
  run_script 1 predict-e --predict adaptive <<'SCRIPT'
expect $\s 10000
type e
expect-screen $ e 5000
settle 400
sleep 4000
type c
expect-predicted $ ec 500
SCRIPT
  grep -q 'expect-predicted' "$TMP/predict-e.err" || fail "e: did not stop at expect-predicted"

  # f: a socket replaced while datagrams sit in the 500 ms delay queue, then quiesce and
  # resume: the old socket's queue is emptied at its close, no number is used twice.
  start_server sh
  run_script 0 predict-f --predict always --delay-ms 500 --seq-log "$TMP/predict-f.seq" <<'SCRIPT'
expect $\s 10000
type e
rebind
type c
quiesce
resume
type ho ff
key enter
expect \nff 10000
expect-display-settled 3000
SCRIPT
  scripts/check-seq-log.sh "$TMP/predict-f.seq" | sed 's/^/  /' || fail "f: sequence log"
  server_alive || fail "the server is gone"
}

test_bootstrap_session() {
  local dir="${MOSH_SSHD_ITEST_DIR:-}"
  [ -n "$dir" ] && [ -f "$dir/env.json" ] || { echo "itest: bootstrap-session needs scripts/itest-sshd.sh" >&2; exit 2; }
  local user password port
  user="$(sed -n 's/.*"user": "\([^"]*\)".*/\1/p' "$dir/env.json")"
  password="$(sed -n 's/.*"password": "\([^"]*\)".*/\1/p' "$dir/env.json")"
  port="$(sed -n 's/.*"normal": *{"port": \([0-9]*\).*/\1/p' "$dir/env.json")"
  [ -n "$user" ] && [ -n "$password" ] && [ -n "$port" ] || fail "cannot read $dir/env.json"

  cat > "$TMP/boot.script" <<'SCRIPT'
type echo boot-$((6*7))\r
expect-screen boot-42 15000
type stty size\r
expect-screen 30 100 10000
type echo $$ > /tmp/boot-shell-pid-$PPID\r
wait-ack
resize 70 20
type stty size\r
expect-screen 20 70 10000
shutdown
SCRIPT
  local code=0
  MOSH_SSH_PASSWORD="$password" "$MOSHCLI" bootstrap --ssh-host 127.0.0.1 --ssh-port "$port" --user "$user" \
    --known-hosts "$TMP/known_hosts.json" --accept-new-host-key --width 100 --height 30 \
    --script "$TMP/boot.script" --seq-log "$TMP/boot.seq" --print-server "$TMP/boot.server" --quiet \
    > "$TMP/boot.out" 2> "$TMP/boot.err" || code=$?
  [ "$code" = 0 ] || { cat "$TMP/boot.err" "$TMP/boot.out" >&2; fail "moshcli bootstrap exited $code"; }
  echo "  $(grep 'mosh-server pid' "$TMP/boot.err" | sed 's/^moshcli //')"
  echo "  $(cat "$TMP/boot.out")"
  grep -q 'login password' "$TMP/boot.err" || fail "not a password login"
  grep -q 'unknown host key ssh-ed25519 SHA256:' "$TMP/boot.err" || fail "the host key was not shown"
  [ -s "$TMP/known_hosts.json" ] || fail "the host key was not remembered"
  scripts/check-seq-log.sh "$TMP/boot.seq" | sed 's/^/  /' || fail "sequence log"
  local pid
  pid="$(cut -d' ' -f1 "$TMP/boot.server")"
  local gone=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then gone=1; break; fi
    sleep 0.1
  done
  [ "$gone" = 1 ] || { kill -9 "$pid" 2>/dev/null || true; fail "the server $pid is still there after the shutdown"; }

  # A second run with the remembered host key: no question, and a wrong password is a
  # bootstrap failure (exit 7) with the table's text.
  code=0
  MOSH_SSH_PASSWORD="not-the-password" "$MOSHCLI" bootstrap --ssh-host 127.0.0.1 --ssh-port "$port" --user "$user" \
    --known-hosts "$TMP/known_hosts.json" --script "$TMP/boot.script" --quiet \
    > "$TMP/boot2.out" 2> "$TMP/boot2.err" || code=$?
  [ "$code" = 7 ] || { cat "$TMP/boot2.err" >&2; fail "wrong password: exit $code, expected 7"; }
  grep -q 'Wrong password' "$TMP/boot2.err" || { cat "$TMP/boot2.err" >&2; fail "wrong password: not the expected message"; }
  if grep -q 'unknown host key' "$TMP/boot2.err"; then fail "the remembered host key was asked again"; fi
  echo "  wrong password: exit 7, \"Wrong password.\""
}

[ $# -gt 0 ] || { echo "usage: scripts/itest-mosh.sh handshake|hello|script|rebind|resume-mem|soak|predict|bootstrap-session ..." >&2; exit 2; }
for TEST in "$@"; do
  case "$TEST" in
    handshake) echo "== handshake"; test_handshake ;;
    hello) echo "== hello"; test_hello ;;
    script) echo "== script"; test_script ;;
    rebind) echo "== rebind"; test_rebind ;;
    resume-mem) echo "== resume-mem"; test_resume_mem ;;
    soak) echo "== soak"; test_soak ;;
    predict) echo "== predict"; test_predict ;;
    bootstrap-session) echo "== bootstrap-session"; test_bootstrap_session ;;
    *) echo "itest-mosh: unknown test $TEST" >&2; exit 2 ;;
  esac
  echo "PASS $TEST"
done
