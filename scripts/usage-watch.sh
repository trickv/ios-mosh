#!/usr/bin/env bash
# Watch the Claude usage of the current 5-hour window and raise the pause flag.
#   scripts/usage-watch.sh [threshold-percent] [interval-seconds] [max-runtime-seconds]
# Writes out/usage ("<percent> <reset text>") on every poll. When the session usage
# reaches the threshold it creates out/PAUSE and exits. Agents working on this
# project look for out/PAUSE between units of work and wind down when it exists.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${1:-57}"
INTERVAL="${2:-240}"
MAXRUN="${3:-6600}"   # background commands are stopped after two hours: leave first, and say so
START="$(date +%s)"
mkdir -p "$ROOT/out"
while true; do
  line="$(cd /tmp && timeout 60 claude -p "/usage" 2>/dev/null | grep -m1 'Current session:')"
  pct="$(printf '%s' "$line" | sed -nE 's/.*Current session: *([0-9]+)% used.*/\1/p')"
  reset="$(printf '%s' "$line" | sed -nE 's/.*resets *(.*)$/\1/p')"
  if [ -n "$pct" ]; then
    printf '%s %s (checked %s UTC)\n' "$pct" "$reset" "$(date -u +%H:%M)" > "$ROOT/out/usage"
    if [ "$pct" -ge "$THRESHOLD" ]; then
      touch "$ROOT/out/PAUSE"
      echo "usage $pct% reached the threshold $THRESHOLD%: pause flag set at $(date -u +%H:%M) UTC; window resets $reset"
      exit 0
    fi
  fi
  if [ $(( $(date +%s) - START )) -ge "$MAXRUN" ]; then
    echo "watcher expiring at $(date -u +%H:%M) UTC with usage at ${pct:-unknown}%: start it again"
    exit 0
  fi
  sleep "$INTERVAL"
done
