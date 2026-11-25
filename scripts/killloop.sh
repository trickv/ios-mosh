#!/usr/bin/env bash
# The kill loop: resume, stage 1 (docs/PLAN.md "Verification", "Resume, stage 1"; results in
# docs/RESUME.md). A moshcli client with a session record on disk is killed with SIGKILL again
# and again, and every time the next process must continue the session from the record or fall
# back cleanly, without ever using a sequence number, state number or fragment id twice and
# without the mosh-server aborting.
#
#   scripts/killloop.sh [iterations] [--long] [--no-crashpoints] [--no-damage] [--no-guards]
#   scripts/killloop.sh              20 iterations of the loop, every crash point, damaged records
#   scripts/killloop.sh 260 --long   the plan's 200 resumes and more, with the 42 s gap and torn
#                                    writes as well (about 5 minutes)
#
# Parts:
#   loop         The session runs tmux (status off): window 0 is `cat > log`, window 1 a shell.
#                Each iteration is one client process: it resumes (or connects, after a
#                fallback), types a line into cat and waits to see it echoed within 5 s
#                (liveness), checks the shell's $$, types a second line, and is then killed:
#                  clean     quiesce (the snapshot is stored), SIGKILL: the next process must
#                            resume, on the same mosh-server pid. Variants: the last line not
#                            yet acknowledged; quiesce --after-send (every 5th); a 3000-byte
#                            paste (every 4th); the first datagram of the resume dropped (every
#                            6th); 20% loss in both directions, made in the client (every 8th);
#                            seq 1 200 in the shell before the kill (every 10th); quiesced by
#                            SIGUSR1 instead of by the script (every 9th); with --long one
#                            resume after 42 s
#                  dirty     SIGKILL in mid-typing (every 7th): the next start must be the
#                            fallback, send nothing, and leave the old mosh-server alive
#                  fgreturn  quiesce, return to the foreground at once, type, SIGKILL (every
#                            11th): fallback, never a resume from the stale snapshot
#                Before each clean kill with everything acknowledged, the client's screen (after
#                500 ms without a new state; under netem first KILLLOOP_CATCHUP_MS) must equal
#                `tmux capture-pane -p`.
#                At the end END is typed, and the log must hold every typed line exactly once.
#   crashpoints  The client kills itself at every storage step (before it, after it; with
#                --long also in the middle of each write) of "connect, type, quiesce" and of
#                "resume, type, quiesce". The next start must be a resume if the record says
#                clean and a fallback otherwise, and must work.
#   damage       One counters slot destroyed (either one), both, the key missing, the snapshot
#                missing: a resume or a fallback as the surviving slot says; fallback with no
#                datagram for the rest.
#   guards       The two XCTests that show what the guards prevent (a resume from a stale
#                snapshot, a throwaway number above the base): the real server exits.
#   numbers      For every session key: the sequence numbers on the wire (--seq-log) only go
#                up across all its client processes, and so do the sequence numbers, state
#                numbers and fragment ids taken from the gate. A tcpdump of the whole run must
#                show no client datagram number twice per server, and none that is not in the log.
#
# Loss here is made in the client (moshcli --loss). The same under tc netem needs the sch_netem
# kernel module: `scripts/netem.sh --killloop 260 --long`, on yellow, which sets the waits below.
#
# Runs where swift, mosh-server and tmux are. Env: MOSHCLI (a built moshcli), KILLLOOP_KEEP (a
# directory that gets the logs of a failed run), KILLLOOP_SEED, and for a run under tc netem
# (set by scripts/netem.sh --killloop, which says why): KILLLOOP_CATCHUP_MS (a wait after
# wait-ack and before the 500 ms of quiet that precede a screen comparison, default 0) and
# KILLLOOP_LIVENESS_MS (how long a typed line may take to appear, default 5000).
set -euo pipefail
cd "$(dirname "$0")/.."

ITERATIONS=20
LONG=0
DO_CRASHPOINTS=1
DO_DAMAGE=1
DO_GUARDS=1
for arg in "$@"; do
  case "$arg" in
    --long) LONG=1 ;;
    --no-crashpoints) DO_CRASHPOINTS=0 ;;
    --no-damage) DO_DAMAGE=0 ;;
    --no-guards) DO_GUARDS=0 ;;
    ''|*[!0-9]*) echo "usage: scripts/killloop.sh [iterations] [--long] [--no-crashpoints] [--no-damage] [--no-guards]" >&2; exit 2 ;;
    *) ITERATIONS="$arg" ;;
  esac
done
RANDOM="${KILLLOOP_SEED:-$$}"
CATCHUP_MS="${KILLLOOP_CATCHUP_MS:-0}"
LIVENESS_MS="${KILLLOOP_LIVENESS_MS:-5000}"

command -v mosh-server >/dev/null || { echo "killloop: mosh-server is not in PATH" >&2; exit 1; }
command -v tmux >/dev/null || { echo "killloop: tmux is not in PATH" >&2; exit 1; }
if [ -z "${MOSHCLI:-}" ]; then
  swift build -j 4 --product moshcli 2>&1 | tail -n 2 >&2
  MOSHCLI="$(swift build -j 4 --show-bin-path)/moshcli"
fi
[ -x "$MOSHCLI" ] || { echo "killloop: $MOSHCLI was not built" >&2; exit 1; }

TMP="$(mktemp -d)"
SOCKET="moshkill-$$"
SERVER_PIDS=()
CPID=""
TCPDUMP_PID=""
cleanup() {
  local status=$?
  [ -n "$CPID" ] && kill -9 "$CPID" 2>/dev/null || true
  [ -n "$TCPDUMP_PID" ] && kill "$TCPDUMP_PID" 2>/dev/null || true
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  if [ "$status" != 0 ] && [ -n "${KILLLOOP_KEEP:-}" ]; then
    mkdir -p "$KILLLOOP_KEEP" && cp -r "$TMP"/. "$KILLLOOP_KEEP"/ 2>/dev/null || true
    echo "killloop: logs kept in $KILLLOOP_KEEP" >&2
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "killloop: FAIL: $*" >&2
  exit 1
}

if locale -a 2>/dev/null | grep -qix 'C\.utf-\?8'; then UTF8_LOCALE=C.UTF-8; else UTF8_LOCALE=en_US.UTF-8; fi
# assume-paste-time 0: the scripts type faster than a person, and tmux would take a prefix key
# that follows other keys within a millisecond for pasted text and hand it to the pane.
printf 'set -g status off\nset -g assume-paste-time 0\n' > "$TMP/tmux.conf"

# ---------------------------------------------------------------------------------------------
# Servers. Every mosh-server gets a port of its own, so that the capture can tell them apart
# (each has its own key, and sequence numbers are per key). An "epoch" is one server, one key,
# one session record and one pair of logs.
EPOCH=0
NEXT_PORT=$((61100 + RANDOM % 200))
PORT_LOW=$NEXT_PORT
PORT=""
SPID=""
ROOT_DIR=""
SEQ=""

# new_server COMMAND...: sets EPOCH, PORT, MOSH_KEY (exported), SPID, ROOT_DIR, SEQ.
new_server() {
  local out tries=0
  while :; do
    out="$(env -u TMUX LC_ALL=$UTF8_LOCALE LANG=$UTF8_LOCALE PS1='$ ' ENV= \
      mosh-server new -i 127.0.0.1 -p "$NEXT_PORT" -- "$@" 2>&1 < /dev/null)" || true
    PORT="$(printf '%s\n' "$out" | sed -n 's/^MOSH CONNECT \([0-9]*\) .*/\1/p')"
    MOSH_KEY="$(printf '%s\n' "$out" | sed -n 's/^MOSH CONNECT [0-9]* \([^[:space:]]*\).*/\1/p')"
    SPID="$(printf '%s\n' "$out" | sed -n 's/.*detached, pid = \([0-9]*\).*/\1/p')"
    NEXT_PORT=$((NEXT_PORT + 1))
    [ -n "$PORT" ] && [ -n "$MOSH_KEY" ] && [ -n "$SPID" ] && break
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || fail "mosh-server did not start: $out"
  done
  export MOSH_KEY
  SERVER_PIDS+=("$SPID")
  EPOCH=$((EPOCH + 1))
  ROOT_DIR="$TMP/root.$EPOCH"
  SEQ="$TMP/seq.$EPOCH"
  echo "$PORT $EPOCH" >> "$TMP/ports"
}

server_alive() {
  kill -0 "$1" 2>/dev/null && ps -p "$1" -o comm= | grep -q mosh-server
}

# The server must have survived everything the clients did to it; then it is killed, as the
# app kills the old server after a fallback.
retire_server() {
  server_alive "$SPID" || fail "$1: mosh-server pid $SPID (epoch $EPOCH) is gone: it aborted or dropped the session"
  kill -9 "$SPID" 2>/dev/null || true
}

info() {
  "$MOSHCLI" resume --session-root "$ROOT_DIR" --info 2>/dev/null | sed -n "s/^$1=//p"
}

# A value that is "none" when the record directory does not hold exactly one record.
record_state() {
  local state
  state="$(info state)"
  echo "${state:-none}"
}

lines_of() {
  [ -e "$1" ] && wc -l < "$1" || echo 0
}

# wait_marker FILE NAME: until the background client wrote FILE; fails if the client ends first.
wait_marker() {
  local n=0
  while [ ! -s "$1" ]; do
    if ! kill -0 "$CPID" 2>/dev/null; then
      wait "$CPID" 2>/dev/null || true
      [ -s "$1" ] && break
      cat "$TMP/$2.err" >&2 || true
      fail "$2: the client ended before it reached its marker"
    fi
    n=$((n + 1))
    [ "$n" -lt 900 ] || { cat "$TMP/$2.err" >&2 || true; fail "$2: no marker after 90 s"; }
    sleep 0.1
  done
}

kill_client() {
  kill -9 "$CPID" 2>/dev/null || true
  wait "$CPID" 2>/dev/null || true
  CPID=""
}

# ---------------------------------------------------------------------------------------------
# The capture of the whole run.
if command -v tcpdump >/dev/null && [ "$(id -u)" = 0 ]; then
  tcpdump -i lo -U -w "$TMP/run.pcap" "udp and dst portrange $PORT_LOW-$((PORT_LOW + 4000))" > "$TMP/tcpdump.err" 2>&1 &
  TCPDUMP_PID=$!
  sleep 1
  kill -0 "$TCPDUMP_PID" 2>/dev/null || { TCPDUMP_PID=""; echo "killloop: tcpdump did not start: $(cat "$TMP/tcpdump.err")"; }
fi
[ -n "$TCPDUMP_PID" ] || echo "killloop: no tcpdump capture (needs root and tcpdump): the numbers are checked from the logs only"

# ---------------------------------------------------------------------------------------------
# Part 1: the loop.
LOG="$TMP/cat.log"
EXPECTED="$TMP/expected.log"
: > "$EXPECTED"
SHELL_PID=""
RESUMES=0
FALLBACKS=0
SCREENS=0
COUNT_CLEAN=0
COUNT_DIRTY=0
COUNT_FGRETURN=0
COUNT_UNACKED=0
COUNT_AFTERSEND=0
COUNT_PASTE=0
COUNT_DROP=0
COUNT_LOSS=0
COUNT_SEQ200=0
COUNT_GAP=0
COUNT_USR1=0

tmux_server() {
  if tmux -L "$SOCKET" has-session -t k 2>/dev/null; then
    new_server tmux -L "$SOCKET" attach -t k
  else
    new_server tmux -L "$SOCKET" -f "$TMP/tmux.conf" new-session -s k "cat > '$LOG'" ';' new-window sh
  fi
}

# typed_line TAG N [paste]: a line for cat; appended to the expected log.
typed_line() {
  local text
  if [ "${3:-}" = paste ]; then
    text="$1$2-$(head -c 6000 /dev/urandom | base64 -w0 | tr -d '+/=' | head -c 3000)"
  else
    text="$1$2-line $2 of the kill loop"
  fi
  printf '%s\n' "$text" >> "$EXPECTED"
  printf '%s' "$text"
}

window() {
  printf 'key ctrl-b\ntype %s\n' "$1"
}

compare_screen() {
  local name="$1" height=24
  tmux -L "$SOCKET" capture-pane -p -t k > "$TMP/$name.server"
  awk -v h="$height" '{ print } END { for (i = NR; i < h; i++) print "" }' "$TMP/$name.server" > "$TMP/$name.padded"
  if ! cmp -s "$TMP/$name.screen" "$TMP/$name.padded"; then
    diff "$TMP/$name.screen" "$TMP/$name.padded" >&2 || true
    fail "$name: the client's screen differs from tmux capture-pane -p (< client, > server)"
  fi
  SCREENS=$((SCREENS + 1))
}

echo "== killloop: loop, $ITERATIONS iterations$([ "$LONG" = 1 ] && echo ' (long)'); screens after $([ "$CATCHUP_MS" != 0 ] && echo "$CATCHUP_MS ms and ")500 ms without a new state, typed lines within $LIVENESS_MS ms"
NEED_CONNECT=1
DROP_NEXT=0
for i in $(seq 1 "$ITERATIONS"); do
  name="it$i"
  kind=clean
  [ $((i % 7)) = 0 ] && kind=dirty
  [ $((i % 11)) = 0 ] && kind=fgreturn
  settled=1
  quiesce="quiesce"
  paste=""
  seq200=0
  usr1=0
  loss=0
  if [ "$kind" = clean ]; then
    [ $((i % 3)) = 0 ] && settled=0
    [ $((i % 5)) = 0 ] && { quiesce="quiesce --after-send"; settled=0; }
    [ $((i % 4)) = 0 ] && paste=paste
    [ $((i % 10)) = 0 ] && { seq200=1; settled=1; quiesce="quiesce"; }
    [ $((i % 9)) = 0 ] && { usr1=1; settled=1; quiesce="quiesce"; }
  fi
  [ $((i % 8)) = 0 ] && loss=20

  # The script of this process.
  {
    window 0
    printf 'type %s\\r\n' "$(typed_line A "$i")"
    echo "expect-screen A$i-line $LIVENESS_MS"
    window 1
    echo "type echo pid-\$\$-$i\\r"
    if [ -n "$SHELL_PID" ]; then echo "expect-screen pid-$SHELL_PID-$i $LIVENESS_MS"; else echo "expect-screen -$i $LIVENESS_MS"; fi
    window 0
    case "$kind" in
      clean)
        printf 'type %s\\r\n' "$(typed_line B "$i" $paste)"
        if [ "$seq200" = 1 ]; then
          window 1
          echo "type seq 1 200; echo seq-\$((1000+$i))-done\\r"
          echo "expect-screen seq-$((1000 + i))-done $((2 * LIVENESS_MS))"
        fi
        if [ "$settled" = 1 ]; then
          echo wait-ack
          [ "$CATCHUP_MS" = 0 ] || echo "sleep $CATCHUP_MS"
          echo 'settle 500'
        fi
        # With usr1 the script does not quiesce: the loop sends SIGUSR1 after the marker.
        [ "$usr1" = 1 ] || echo "$quiesce"
        echo "dump-screen $TMP/$name.screen"
        echo "sleep 600000"
        ;;
      fgreturn)
        printf 'wait-ack\nquiesce\nresume\n'
        printf 'type %s\\r\n' "$(typed_line F "$i")"
        printf 'wait-ack\n'
        echo "dump-screen $TMP/$name.screen"
        echo "sleep 600000"
        ;;
      dirty)
        printf 'type %s\\r\n' "$(typed_line D "$i")"
        printf 'wait-ack\n'
        echo "dump-screen $TMP/$name.screen"
        window 1
        for n in $(seq 1 300); do printf 'type : noise %s\\r\nsleep 15\n' "$n"; done
        ;;
    esac
  } > "$TMP/$name.script"

  # The process: a new session after a fallback, otherwise a resume from the record.
  if [ "$NEED_CONNECT" = 1 ]; then
    tmux_server
    "$MOSHCLI" connect --host 127.0.0.1 --port "$PORT" --session-root "$ROOT_DIR" --server-pid "$SPID" \
      --seq-log "$SEQ" --script "$TMP/$name.script" --quiet > "$TMP/$name.out" 2> "$TMP/$name.err" &
    CPID=$!
  else
    [ "$(record_state)" = clean ] || fail "$name: the record is $(record_state) before a resume that must work"
    [ "$(info server_pid)" = "$SPID" ] || fail "$name: the record names server pid $(info server_pid), not $SPID"
    server_alive "$SPID" || fail "$name: mosh-server pid $SPID is gone"
    options=()
    [ "$DROP_NEXT" = 1 ] && { options+=(--drop-first 1); COUNT_DROP=$((COUNT_DROP + 1)); }
    [ "$loss" != 0 ] && { options+=(--loss "$loss"); COUNT_LOSS=$((COUNT_LOSS + 1)); }
    "$MOSHCLI" resume --session-root "$ROOT_DIR" --seq-log "$SEQ" --script "$TMP/$name.script" --quiet \
      "${options[@]}" > "$TMP/$name.out" 2> "$TMP/$name.err" &
    CPID=$!
  fi
  wait_marker "$TMP/$name.screen" "$name"
  if [ "$NEED_CONNECT" = 0 ]; then
    grep -q 'moshcli resume: resumed session' "$TMP/$name.err" || { cat "$TMP/$name.err" >&2; fail "$name: no resume was reported"; }
    RESUMES=$((RESUMES + 1))
  fi
  if [ -z "$SHELL_PID" ]; then
    SHELL_PID="$(tmux -L "$SOCKET" display-message -p -t k:1 '#{pane_pid}')"
    [ -n "$SHELL_PID" ] || fail "$name: no shell pid from tmux"
  fi
  [ "$(tmux -L "$SOCKET" display-message -p -t k:1 '#{pane_pid}')" = "$SHELL_PID" ] || fail "$name: the shell changed"

  case "$kind" in
    clean)
      COUNT_CLEAN=$((COUNT_CLEAN + 1))
      [ "$settled" = 0 ] && COUNT_UNACKED=$((COUNT_UNACKED + 1))
      [ "$quiesce" != quiesce ] && COUNT_AFTERSEND=$((COUNT_AFTERSEND + 1))
      [ -n "$paste" ] && COUNT_PASTE=$((COUNT_PASTE + 1))
      [ "$seq200" = 1 ] && COUNT_SEQ200=$((COUNT_SEQ200 + 1))
      if [ "$usr1" = 1 ]; then
        kill -USR1 "$CPID"
        n=0
        until grep -q 'SIGUSR1: quiesced; the record is clean' "$TMP/$name.err"; do
          n=$((n + 1))
          [ "$n" -lt 100 ] || { cat "$TMP/$name.err" >&2; fail "$name: SIGUSR1 did not quiesce the client within 10 s"; }
          sleep 0.1
        done
        COUNT_USR1=$((COUNT_USR1 + 1))
      fi
      [ "$settled" = 1 ] && [ "$loss" = 0 ] && compare_screen "$name"
      kill_client
      [ "$(record_state)" = clean ] || fail "$name: killed after a quiesce, but the record is $(record_state)"
      NEED_CONNECT=0
      DROP_NEXT=0
      [ $((i % 6)) = 0 ] && DROP_NEXT=1
      if [ "$LONG" = 1 ] && [ "$COUNT_GAP" = 0 ] && [ "$i" -ge 2 ]; then
        echo "  $name: 42 s before the next resume (the server forgets the client's address after 40 s)"
        sleep 42
        COUNT_GAP=1
      fi
      ;;
    dirty|fgreturn)
      [ "$kind" = dirty ] && { COUNT_DIRTY=$((COUNT_DIRTY + 1)); sleep "0.$((RANDOM % 4))$((RANDOM % 10))"; } \
        || COUNT_FGRETURN=$((COUNT_FGRETURN + 1))
      kill_client
      [ "$(record_state)" = dirty ] || fail "$name ($kind): the record is $(record_state), not dirty"
      before="$(lines_of "$SEQ")"
      echo 'sleep 1' > "$TMP/$name.fb.script"
      code=0
      "$MOSHCLI" resume --session-root "$ROOT_DIR" --seq-log "$SEQ" --script "$TMP/$name.fb.script" --quiet \
        > "$TMP/$name.fb.out" 2> "$TMP/$name.fb.err" || code=$?
      [ "$code" = 3 ] || { cat "$TMP/$name.fb.err" >&2; fail "$name ($kind): the next start exited $code, not 3 (fallback)"; }
      grep -q 'fallback (the record is dirty); nothing sent' "$TMP/$name.fb.out" || fail "$name ($kind): $(cat "$TMP/$name.fb.out")"
      [ "$(lines_of "$SEQ")" = "$before" ] || fail "$name ($kind): the fallback sent a datagram under the old key"
      retire_server "$name ($kind)"
      FALLBACKS=$((FALLBACKS + 1))
      NEED_CONNECT=1
      DROP_NEXT=0
      ;;
  esac
  [ $((i % 10)) = 0 ] && echo "  $i iterations: $RESUMES resumes, $FALLBACKS fallbacks, $SCREENS screens compared"
done

# The end: one more process types END; then the log must hold every line once, in order.
{
  window 0
  echo 'type END\r'
  echo "expect-screen END $LIVENESS_MS"
  echo 'wait-ack'
  echo 'settle 300'
  echo 'quiesce'
} > "$TMP/end.script"
echo END >> "$EXPECTED"
code=0
if [ "$NEED_CONNECT" = 1 ]; then
  tmux_server
  "$MOSHCLI" connect --host 127.0.0.1 --port "$PORT" --session-root "$ROOT_DIR" --server-pid "$SPID" \
    --seq-log "$SEQ" --script "$TMP/end.script" --quiet > "$TMP/end.out" 2> "$TMP/end.err" || code=$?
else
  "$MOSHCLI" resume --session-root "$ROOT_DIR" --seq-log "$SEQ" --script "$TMP/end.script" --quiet \
    > "$TMP/end.out" 2> "$TMP/end.err" || code=$?
  [ "$code" = 0 ] && RESUMES=$((RESUMES + 1))
fi
[ "$code" = 0 ] || { cat "$TMP/end.err" >&2; fail "the last process exited $code"; }
if ! cmp -s "$EXPECTED" "$LOG"; then
  diff <(cut -c1-60 "$EXPECTED") <(cut -c1-60 "$LOG") >&2 || true
  fail "exactly-once: the lines cat got differ from the lines typed (< typed, > got; first 60 characters)"
fi
[ "$(tmux -L "$SOCKET" display-message -p -t k:1 '#{pane_pid}')" = "$SHELL_PID" ] || fail "the shell changed"
retire_server "end of the loop"
tmux -L "$SOCKET" kill-server 2>/dev/null || true
LOOP_EPOCHS=$EPOCH
echo "  loop: $ITERATIONS kills ($COUNT_CLEAN after a quiesce, $COUNT_DIRTY in mid-typing, $COUNT_FGRETURN after returning to the foreground);"
echo "        $RESUMES resumes, $FALLBACKS fallbacks, each as the record said; $LOOP_EPOCHS servers, none aborted; shell pid $SHELL_PID throughout"
echo "        variants: $COUNT_UNACKED with unacknowledged input, $COUNT_AFTERSEND quiesce --after-send, $COUNT_PASTE pastes of 3000 bytes,"
echo "        $COUNT_USR1 quiesced by SIGUSR1, $COUNT_DROP resumes with the first datagram dropped, $COUNT_LOSS under 20% loss (client-side), $COUNT_GAP after 42 s"
echo "        screens: $SCREENS equal to tmux capture-pane -p ($COUNT_SEQ200 after seq 1 200); exactly-once: $(wc -l < "$LOG") lines, byte for byte"
echo "PASS killloop loop"

# ---------------------------------------------------------------------------------------------
# Parts 2 and 3 use plain shells, one server per record.
cat > "$TMP/first.script" <<SCRIPT
type echo c-\$((40+2)); echo pid-\$\$\\r
expect-screen c-42 $LIVENESS_MS
wait-ack
quiesce
SCRIPT
cat > "$TMP/second.script" <<SCRIPT
type echo r-\$((1+1)); echo pid-\$\$\\r
expect-screen r-2 $LIVENESS_MS
wait-ack
quiesce
SCRIPT
cat > "$TMP/third.script" <<SCRIPT
type echo s-\$((2+1)); echo pid-\$\$\\r
expect-screen s-3 $LIVENESS_MS
wait-ack
dump-screen $TMP/third.screen
quiesce
SCRIPT

run_connect() {
  local name="$1" code=0
  shift
  # In the background and waited for, so that the shell does not report each SIGKILL.
  "$MOSHCLI" connect --host 127.0.0.1 --port "$PORT" --session-root "$ROOT_DIR" --server-pid "$SPID" \
    --seq-log "$SEQ" --script "$TMP/first.script" --quiet "$@" > "$TMP/$name.out" 2> "$TMP/$name.err" &
  wait $! 2> /dev/null || code=$?
  echo "$code"
}

run_resume() {
  local name="$1" script="$2" code=0
  shift 2
  "$MOSHCLI" resume --session-root "$ROOT_DIR" --seq-log "$SEQ" --script "$script" --quiet "$@" \
    > "$TMP/$name.out" 2> "$TMP/$name.err" &
  wait $! 2> /dev/null || code=$?
  echo "$code"
}

CP_RESUMED=0
CP_FALLBACK=0
CP_NORECORD=0

# After a client died at a crash point: the next start is a resume if the record says clean and
# a fallback (exit 3, nothing sent) otherwise; a resume must work, on the same shell.
check_next_start() {
  local name="$1" state before code
  state="$(record_state)"
  before="$(lines_of "$SEQ")"
  rm -f "$TMP/third.screen"
  if [ "$state" = none ]; then
    # The process died before there was a directory: nothing to resume, nothing to fall back from.
    [ "$before" = 0 ] || fail "$name: no record, but datagrams were sent"
    CP_NORECORD=$((CP_NORECORD + 1))
    return 0
  fi
  code="$(run_resume "$name.next" "$TMP/third.script")"
  if [ "$state" = clean ]; then
    [ "$code" = 0 ] || { cat "$TMP/$name.next.err" >&2; fail "$name: the record is clean but the next start exited $code"; }
    grep -q 'resume: resumed; exit 0' "$TMP/$name.next.out" || fail "$name: $(cat "$TMP/$name.next.out")"
    [ "$(grep -c '^pid-' "$TMP/third.screen" | tr -d ' ')" -ge 2 ] && [ "$(grep '^pid-' "$TMP/third.screen" | sort -u | wc -l | tr -d ' ')" = 1 ] \
      || fail "$name: not the same shell after the resume: $(grep '^pid-' "$TMP/third.screen" | tr '\n' ' ')"
    [ "$(record_state)" = clean ] || fail "$name: the record is $(record_state) after the resumed process quiesced"
    CP_RESUMED=$((CP_RESUMED + 1))
  else
    [ "$code" = 3 ] || { cat "$TMP/$name.next.err" >&2; fail "$name: the record is $state but the next start exited $code, not 3"; }
    grep -q 'nothing sent' "$TMP/$name.next.out" || fail "$name: $(cat "$TMP/$name.next.out")"
    [ "$(lines_of "$SEQ")" = "$before" ] || fail "$name: the fallback sent a datagram under the old key"
    [ "$(record_state)" = none ] || fail "$name: the record is still there after the fallback"
    CP_FALLBACK=$((CP_FALLBACK + 1))
  fi
}

if [ "$DO_CRASHPOINTS" = 1 ]; then
  echo "== killloop: crash points"
  # How many storage steps each of the two processes takes, and which are writes.
  new_server sh
  [ "$(run_connect steps1 --step-log "$TMP/steps.connect")" = 0 ] || { cat "$TMP/steps1.err" >&2; fail "crash points: the plain connect failed"; }
  [ "$(run_resume steps2 "$TMP/second.script" --step-log "$TMP/steps.resume")" = 0 ] || { cat "$TMP/steps2.err" >&2; fail "crash points: the plain resume failed"; }
  retire_server "crash points, counting"
  STEPS_CONNECT="$(lines_of "$TMP/steps.connect")"
  STEPS_RESUME="$(lines_of "$TMP/steps.resume")"
  [ "$STEPS_CONNECT" -ge 30 ] && [ "$STEPS_RESUME" -ge 10 ] || fail "crash points: $STEPS_CONNECT and $STEPS_RESUME steps: fewer than a record takes"
  echo "  connect, type, quiesce: $STEPS_CONNECT steps; resume, type, quiesce: $STEPS_RESUME steps"

  CP_RUNS=0
  CP_NOT_REACHED=0
  modes_for() {   # the modes for step K of a step log
    local modes="before after"
    if [ "$LONG" = 1 ] && sed -n "${2}p" "$1" | grep -q '\.write$'; then modes="$modes torn=1 torn=37"; fi
    echo "$modes"
  }

  # (a) The first process of a session: making the record, the first reservations, the save.
  for k in $(seq 1 $((STEPS_CONNECT + 1))); do
    for mode in $(modes_for "$TMP/steps.connect" "$k"); do
      name="cpA-$k-$mode"
      new_server sh
      code="$(run_connect "$name" --crashpoint "#$k:$mode")"
      case "$code" in
        137) ;;
        0) CP_NOT_REACHED=$((CP_NOT_REACHED + 1)) ;;
        *) cat "$TMP/$name.err" >&2; fail "$name: the client exited $code, not by SIGKILL" ;;
      esac
      check_next_start "$name"
      scripts/check-seq-log.sh "$SEQ" > /dev/null 2>&1 || [ ! -s "$SEQ" ] || { scripts/check-seq-log.sh "$SEQ" >&2 || true; fail "$name: numbers"; }
      retire_server "$name"
      CP_RUNS=$((CP_RUNS + 1))
    done
  done
  # (b) A later process: the cold start's counters change, then the save.
  for k in $(seq 1 $((STEPS_RESUME + 1))); do
    for mode in $(modes_for "$TMP/steps.resume" "$k"); do
      name="cpB-$k-$mode"
      new_server sh
      [ "$(run_connect "$name.first")" = 0 ] || { cat "$TMP/$name.first.err" >&2; fail "$name: the first process failed"; }
      code="$(run_resume "$name" "$TMP/second.script" --crashpoint "#$k:$mode")"
      case "$code" in
        137) ;;
        0) CP_NOT_REACHED=$((CP_NOT_REACHED + 1)) ;;
        *) cat "$TMP/$name.err" >&2; fail "$name: the client exited $code, not by SIGKILL" ;;
      esac
      check_next_start "$name"
      scripts/check-seq-log.sh "$SEQ" > /dev/null || { scripts/check-seq-log.sh "$SEQ" >&2 || true; fail "$name: numbers"; }
      retire_server "$name"
      CP_RUNS=$((CP_RUNS + 1))
    done
  done
  echo "  $CP_RUNS kills at a storage step ($((STEPS_CONNECT + STEPS_RESUME)) steps, before and after$([ "$LONG" = 1 ] && echo ', writes also torn'));"
  echo "  next start: $CP_RESUMED resumes, $CP_FALLBACK fallbacks with nothing sent, $CP_NORECORD with no record yet; $CP_NOT_REACHED runs ended before their step"
  [ "$CP_RESUMED" -gt 0 ] && [ "$CP_FALLBACK" -gt 0 ] || fail "crash points: expected both resumes and fallbacks"
  echo "PASS killloop crashpoints"
fi

if [ "$DO_DAMAGE" = 1 ]; then
  echo "== killloop: damaged records"
  for damage in slot0 slot1 both key snapshot; do
    name="damage-$damage"
    new_server sh
    [ "$(run_connect "$name.first")" = 0 ] || { cat "$TMP/$name.first.err" >&2; fail "$name: the first process failed"; }
    [ "$(record_state)" = clean ] || fail "$name: the record is $(record_state) after a quiesce"
    dir="$ROOT_DIR/$(info session)"
    tear() {   # a write of a slot that stopped after 20 bytes of something else
      head -c 20 /dev/urandom | dd of="$dir/counters" bs=1 seek="$1" conv=notrunc 2> /dev/null
    }
    case "$damage" in
      slot0) tear 0 ;;
      slot1) tear 4096 ;;
      both) tear 0; tear 4096 ;;
      key) rm "$dir/key" ;;
      snapshot) rm "$dir/snapshot" ;;
    esac
    state="$(record_state)"
    before="$(lines_of "$SEQ")"
    rm -f "$TMP/third.screen"
    code="$(run_resume "$name" "$TMP/third.script")"
    case "$damage" in
      slot0|slot1)
        # The other slot decides: the one with the clean mark, or the "dirty" before it.
        if [ "$state" = clean ]; then
          [ "$code" = 0 ] || { cat "$TMP/$name.err" >&2; fail "$name: the surviving slot says clean, but the start exited $code"; }
          result="the surviving slot says clean: resumed"
        else
          [ "$state" = dirty ] || fail "$name: the surviving slot says $state"
          [ "$code" = 3 ] || fail "$name: the surviving slot says dirty, but the start exited $code"
          [ "$(lines_of "$SEQ")" = "$before" ] || fail "$name: the fallback sent a datagram"
          result="the surviving slot says dirty: fallback, nothing sent"
        fi
        ;;
      *)
        [ "$code" = 3 ] || { cat "$TMP/$name.err" >&2; fail "$name: the start exited $code, not 3"; }
        grep -q 'nothing sent' "$TMP/$name.out" || fail "$name: $(cat "$TMP/$name.out")"
        [ "$(lines_of "$SEQ")" = "$before" ] || fail "$name: the fallback sent a datagram"
        result="fallback ($(sed -n 's/.*fallback (\(.*\)); nothing sent.*/\1/p' "$TMP/$name.out" | cut -c1-70)), nothing sent"
        ;;
    esac
    echo "  $damage: $result"
    retire_server "$name"
  done
  echo "PASS killloop damage"
fi

# ---------------------------------------------------------------------------------------------
# The numbers of every session key, over all its processes.
echo "== killloop: numbers"
TOTAL_SEQ=0
CHECKED=0
for epoch in $(seq 1 "$EPOCH"); do
  log="$TMP/seq.$epoch"
  [ -s "$log" ] || continue   # a client that died before its first datagram
  scripts/check-seq-log.sh "$log" > "$TMP/check.$epoch" 2>&1 || { cat "$TMP/check.$epoch" >&2; fail "numbers: session $epoch"; }
  TOTAL_SEQ=$((TOTAL_SEQ + $(wc -l < "$log")))
  CHECKED=$((CHECKED + 1))
done
echo "  $CHECKED sessions with datagrams, $TOTAL_SEQ sequence numbers logged: none twice, each process above the one before;"
echo "  state numbers and fragment ids taken from the gate: none twice"
if [ -n "$TCPDUMP_PID" ]; then
  sleep 1
  kill -INT "$TCPDUMP_PID" 2>/dev/null || true
  wait "$TCPDUMP_PID" 2>/dev/null || true
  TCPDUMP_PID=""
  python3 -I - "$TMP/run.pcap" "$TMP/ports" "$TMP" <<'PY' || fail "numbers: the capture"
import struct, sys
pcap, ports_file, tmp = sys.argv[1:4]
epoch_of = {}
for line in open(ports_file):
    port, epoch = line.split()
    epoch_of[int(port)] = int(epoch)
logged = {}
def log_of(epoch):
    if epoch not in logged:
        try:
            logged[epoch] = set(int(line) for line in open("%s/seq.%d" % (tmp, epoch)))
        except FileNotFoundError:
            logged[epoch] = set()
    return logged[epoch]
data = open(pcap, "rb").read()
magic = struct.unpack("<I", data[:4])[0]
assert magic in (0xa1b2c3d4, 0xa1b23c4d), "not a little-endian pcap file"
linktype = struct.unpack("<I", data[20:24])[0]
offset, seen, count = 24, {}, 0
while offset + 16 <= len(data):
    caplen = struct.unpack("<I", data[offset + 8:offset + 12])[0]
    frame = data[offset + 16:offset + 16 + caplen]
    offset += 16 + caplen
    if linktype == 1:      # Ethernet
        ip = frame[14:]
    elif linktype == 0:    # BSD loopback
        ip = frame[4:]
    elif linktype == 113:  # Linux cooked
        ip = frame[16:]
    else:
        raise SystemExit("link type %d is not handled" % linktype)
    if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 17:
        continue
    udp = ip[(ip[0] & 15) * 4:]
    if len(udp) < 16:
        continue
    port = struct.unpack(">H", udp[2:4])[0]
    if port not in epoch_of:
        continue
    number = struct.unpack(">Q", udp[8:16])[0]
    if number >> 63:
        raise SystemExit("a datagram to port %d has the server's direction bit" % port)
    count += 1
    key = (port, number)
    if key in seen:
        raise SystemExit("sequence number %d was sent twice to the server on port %d" % (number, port))
    seen[key] = True
    if number not in log_of(epoch_of[port]):
        raise SystemExit("sequence number %d to port %d is on the wire but not in the log" % (number, port))
print("  tcpdump: %d client datagrams to %d servers: no sequence number twice per server, all of them in the logs"
      % (count, len(set(port for port, _ in seen))))
PY
fi
echo "PASS killloop numbers"

if [ "$DO_GUARDS" = 1 ]; then
  echo "== killloop: guards (what a client without them does to the real server)"
  swift test -j 4 --filter GuardTests 2>&1 | grep -E "error|failed|Executed|passed \(" | tail -n 12 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "GuardTests"
  echo "PASS killloop guards"
fi

echo "killloop: PASS"
