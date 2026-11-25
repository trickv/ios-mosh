#!/usr/bin/env bash
# Record the "rec-*" cases of the golden corpus and generate their oracle files.
#   scripts/record-golden.sh              # record every case
#   scripts/record-golden.sh vim tmux     # record only these
#   scripts/record-golden.sh --list
# Runs in the dev container (it re-runs itself through scripts/dev.sh when started on
# the host). For each Tools/mosh-oracle/recordings/NAME.rec it runs bash in a pty with
# scripts/pty-record.py, writes Tests/MoshTerminalTests/Corpus/rec-NAME/session.jsonl,
# and runs `mosh-oracle gen` on it.
#
# A new recording is a new session: timing, process lists and clocks differ from run
# to run, so the committed files change. What is fixed is the environment (see
# pty-record.py). To regenerate the oracle files from the committed session files
# without recording, use scripts/corpus-check.sh --regen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d /opt/mosh-src ]; then
  # a fixed host name: tmux shows it in its status line
  DEV_DOCKER_ARGS="${DEV_DOCKER_ARGS:-} --hostname golden" exec "$ROOT/scripts/dev.sh" scripts/record-golden.sh "$@"
fi
cd "$ROOT"
REC=Tools/mosh-oracle/recordings
CORPUS=Tests/MoshTerminalTests/Corpus
ORACLE="$ROOT/.build/mosh-oracle/mosh-oracle"

if [ "${1:-}" = "--list" ]; then
  for f in "$REC"/*.rec; do basename "$f" .rec; done
  exit 0
fi

if [ ! -x "$ORACLE" ] || [ Tools/mosh-oracle/main.cc -nt "$ORACLE" ]; then
  Tools/mosh-oracle/build.sh
fi

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  for f in "$REC"/*.rec; do cases+=("$(basename "$f" .rec)"); done
fi

for name in "${cases[@]}"; do
  script="$REC/$name.rec"
  [ -f "$script" ] || { echo "record-golden.sh: no $script" >&2; exit 1; }
  home="$(mktemp -d /tmp/golden-home.XXXXXX)"
  # Fixture files the recorded commands use. No dot files: programs run with defaults.
  cp "$REC"/fixtures/* "$home"/
  for i in $(seq 1 300); do echo "line $i: the quick brown fox jumps over the lazy dog"; done > "$home/long.txt"
  {
    printf '%060d\n' 60; printf '%061d\n' 61; printf '%059d\n' 59; printf '%0120d\n' 120
    printf 'short\n'; printf '%0121d\n' 121
  } > "$home/wrap.txt"
  out="$CORPUS/rec-$name"
  mkdir -p "$out"
  python3 scripts/pty-record.py --script "$script" --out "$out/session.jsonl" --home "$home" --oracle "$ORACLE"
  "$ORACLE" gen --session "$out/session.jsonl" --out "$out"
  rm -rf "$home"
done
