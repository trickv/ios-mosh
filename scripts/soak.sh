#!/usr/bin/env bash
# The soak (docs/PLAN.md, "Verification", Network and M2): moshcli soak against a real
# mosh-server whose session runs a shell inside tmux (status off), then the client's final
# framebuffer is compared row by row with `tmux capture-pane -p` on the server side.
#
#   scripts/soak.sh [minutes] [extra moshcli soak options]
#   scripts/soak.sh 0.5
#
# This script does not touch the network: on a clean loopback it is the itest `soak`
# (scripts/itest.sh soak). scripts/netem.sh runs it under tc netem (20% loss and more), which is
# the real soak of the plan; that needs the sch_netem kernel module.
#
# Runs where swift, mosh-server and tmux are (the dev container, or natively). Env:
#   MOSHCLI         a built moshcli; otherwise it is built here
#   SOAK_SETTLE_MS  quiet time before the screen is taken (default 500, as the stage 1 table)
#   SOAK_SIZE       the view and server size, WxH (default 80x24)
# Exits non-zero if a marker took more than 30 s, the server died, a sequence number was not
# above the one before it, or the screens differ.
set -euo pipefail
cd "$(dirname "$0")/.."
MINUTES="${1:-1}"
[ $# -gt 0 ] && shift
SETTLE="${SOAK_SETTLE_MS:-500}"
SIZE="${SOAK_SIZE:-80x24}"
WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"

command -v mosh-server >/dev/null || { echo "soak: mosh-server is not in PATH" >&2; exit 1; }
command -v tmux >/dev/null || { echo "soak: tmux is not in PATH" >&2; exit 1; }
if [ -z "${MOSHCLI:-}" ]; then
  swift build -j 4 --product moshcli 2>&1 | tail -n 2 >&2
  MOSHCLI="$(swift build -j 4 --show-bin-path)/moshcli"
fi
[ -x "$MOSHCLI" ] || { echo "soak: $MOSHCLI was not built" >&2; exit 1; }

TMP="$(mktemp -d)"
SOCKET="moshsoak-$$"
PID=""
cleanup() {
  [ -n "${SOAK_KEEP:-}" ] && cp "$TMP"/*.screen "$SOAK_KEEP"/ 2>/dev/null || true
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if locale -a 2>/dev/null | grep -qix 'C\.utf-\?8'; then UTF8_LOCALE=C.UTF-8; else UTF8_LOCALE=en_US.UTF-8; fi
printf 'set -g status off\n' > "$TMP/tmux.conf"

# Standard input is /dev/null: mosh-server then has no tty to read a size from and starts at
# 80x24 (mosh-server.cc), which is what --server-size says.
OUT="$(env -u TMUX LC_ALL=$UTF8_LOCALE LANG=$UTF8_LOCALE PS1='$ ' ENV= \
  mosh-server new -i 127.0.0.1 -- tmux -L "$SOCKET" -f "$TMP/tmux.conf" new-session -s soak sh 2>&1 < /dev/null)"
PORT="$(printf '%s\n' "$OUT" | sed -n 's/^MOSH CONNECT \([0-9]*\) .*/\1/p')"
KEY="$(printf '%s\n' "$OUT" | sed -n 's/^MOSH CONNECT [0-9]* \([^[:space:]]*\).*/\1/p')"
PID="$(printf '%s\n' "$OUT" | sed -n 's/.*detached, pid = \([0-9]*\).*/\1/p')"
[ -n "$PORT" ] && [ -n "$KEY" ] && [ -n "$PID" ] || { echo "soak: mosh-server did not start: $OUT" >&2; exit 1; }
echo "soak: mosh-server pid $PID on port $PORT running tmux; $MINUTES min at ${WIDTH}x${HEIGHT} $*"

STATUS=0
env MOSH_KEY="$KEY" "$MOSHCLI" soak --host 127.0.0.1 --port "$PORT" --minutes "$MINUTES" \
  --width "$WIDTH" --height "$HEIGHT" --server-size 80x24 \
  --seq-log "$TMP/seq.log" --screen-out "$TMP/client.screen" --settle-ms "$SETTLE" "$@" || STATUS=$?

FAILED=0
[ "$STATUS" = 0 ] || { echo "soak: FAIL: moshcli soak exited $STATUS" >&2; FAILED=1; }
if kill -0 "$PID" 2>/dev/null && ps -p "$PID" -o comm= | grep -q mosh-server; then
  echo "soak: mosh-server pid $PID is alive"
else
  echo "soak: FAIL: mosh-server pid $PID is gone" >&2
  FAILED=1
fi
scripts/check-seq-log.sh "$TMP/seq.log" || { echo "soak: FAIL: sequence log" >&2; FAILED=1; }

if [ "$STATUS" = 0 ]; then
  # The pane must be the size of the client's view (status off: the whole window).
  PANE="$(tmux -L "$SOCKET" display-message -p -t soak '#{pane_width}x#{pane_height}')"
  [ "$PANE" = "${WIDTH}x${HEIGHT}" ] || { echo "soak: FAIL: the tmux pane is $PANE, the view ${WIDTH}x${HEIGHT}" >&2; FAILED=1; }
  tmux -L "$SOCKET" capture-pane -p -t soak > "$TMP/server.screen"
  CLIENT_ROWS="$(wc -l < "$TMP/client.screen")"
  [ "$CLIENT_ROWS" = "$HEIGHT" ] || { echo "soak: FAIL: the client screen has $CLIENT_ROWS rows, not $HEIGHT" >&2; FAILED=1; }
  # capture-pane -p cuts trailing blanks of each row, as the client's dump does; it may also
  # leave out blank rows at the bottom, so those are padded back to the pane height.
  awk -v h="$HEIGHT" '{ print } END { for (i = NR; i < h; i++) print "" }' "$TMP/server.screen" > "$TMP/server.padded"
  if cmp -s "$TMP/client.screen" "$TMP/server.padded"; then
    MARKERS="$(grep -c '^soak-[0-9]*-[0-9]*$' "$TMP/client.screen" || true)"
    [ "$MARKERS" -gt 0 ] || { echo "soak: FAIL: no marker result on the final screen" >&2; FAILED=1; }
    echo "soak: final screen equals tmux capture-pane -p ($HEIGHT rows, $MARKERS marker results on it)"
  else
    echo "soak: FAIL: the client's final screen differs from tmux capture-pane -p (< client, > server):" >&2
    diff "$TMP/client.screen" "$TMP/server.padded" >&2 || true
    FAILED=1
  fi
fi

[ "$FAILED" = 0 ] && echo "soak: PASS" || echo "soak: FAIL"
exit "$FAILED"
