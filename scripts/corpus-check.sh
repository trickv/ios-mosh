#!/usr/bin/env bash
# Check the golden corpus of the terminal model against mosh's own emulator.
#   scripts/corpus-check.sh           # for every case: `mosh-oracle apply` must print
#                                     # exactly the committed expected.jsonl, and
#                                     # `mosh-oracle server` the committed server.jsonl
#   scripts/corpus-check.sh --gen     # also: `mosh-oracle gen` on the committed
#                                     # session.jsonl, run twice, must give the committed
#                                     # meta.json, instructions.jsonl, server.jsonl and
#                                     # expected.jsonl both times (gen is deterministic);
#                                     # and check_format.py: a loader written from
#                                     # FORMAT.md rebuilds every state exactly
#   scripts/corpus-check.sh --regen   # rewrite: syn-*/session.jsonl from synthetic.py,
#                                     # then gen for every case, in place
#   scripts/corpus-check.sh --sizes   # print the size of each case and the total
# Builds the oracle first if it is missing or older than its source. Exit status 0 only
# if every case passes. Runs in the dev container (re-runs itself through
# scripts/dev.sh when started on the host).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d /opt/mosh-src ]; then
  exec "$ROOT/scripts/dev.sh" scripts/corpus-check.sh "$@"
fi
cd "$ROOT"
CORPUS=Tests/MoshTerminalTests/Corpus
ORACLE="$ROOT/.build/mosh-oracle/mosh-oracle"
MODE="${1:-}"

if [ "$MODE" = "--sizes" ]; then
  total=0
  for dir in "$CORPUS"/*/; do
    [ -f "$dir/meta.json" ] || continue
    bytes=$(cat "$dir"/* | wc -c)
    states=$(wc -l < "$dir/instructions.jsonl")
    printf '%-18s %4d states %9d bytes\n' "$(basename "$dir")" "$states" "$bytes"
    total=$((total + bytes))
  done
  printf '%-18s %21d bytes (%d.%02d MB of 10 MB)\n' total "$total" $((total / 1048576)) $((total % 1048576 * 100 / 1048576))
  [ "$total" -lt 10485760 ]
  exit
fi

if [ ! -x "$ORACLE" ] || [ Tools/mosh-oracle/main.cc -nt "$ORACLE" ] || [ Tools/mosh-oracle/predict.cc -nt "$ORACLE" ] \
  || [ Tools/mosh-oracle/oracle.h -nt "$ORACLE" ] || [ Tools/mosh-oracle/build.sh -nt "$ORACLE" ]; then
  Tools/mosh-oracle/build.sh
fi

if [ "$MODE" = "--regen" ]; then
  python3 Tools/mosh-oracle/synthetic.py "$CORPUS" > /dev/null
  for dir in "$CORPUS"/*/; do
    [ -f "$dir/session.jsonl" ] || continue
    "$ORACLE" gen --session "$dir/session.jsonl" --out "${dir%/}"
  done
  exit 0
fi

tmp="$(mktemp -d /tmp/corpus-check.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
fail=0
count=0
for dir in "$CORPUS"/*/; do
  [ -f "$dir/meta.json" ] || continue
  name="$(basename "$dir")"
  count=$((count + 1))
  if ! "$ORACLE" apply "${dir%/}" > "$tmp/expected.jsonl"; then
    echo "FAIL $name: apply failed"; fail=1; continue
  fi
  if ! cmp -s "$tmp/expected.jsonl" "$dir/expected.jsonl"; then
    echo "FAIL $name: apply output differs from expected.jsonl"; fail=1; continue
  fi
  if [ -f "$dir/server.jsonl" ]; then
    if ! "$ORACLE" server "${dir%/}" > "$tmp/server.jsonl" || ! cmp -s "$tmp/server.jsonl" "$dir/server.jsonl"; then
      echo "FAIL $name: server output differs from server.jsonl"; fail=1; continue
    fi
  fi
  if [ "$MODE" = "--gen" ]; then
    ok=1
    for run in 1 2; do
      rm -rf "$tmp/gen$run"; mkdir "$tmp/gen$run"
      if ! "$ORACLE" gen --session "$dir/session.jsonl" --out "$tmp/gen$run" 2> "$tmp/gen.log"; then
        cat "$tmp/gen.log"; ok=0; break
      fi
      for f in meta.json instructions.jsonl server.jsonl expected.jsonl; do
        cmp -s "$tmp/gen$run/$f" "$dir/$f" || { echo "FAIL $name: gen run $run gives a different $f"; ok=0; }
      done
    done
    [ "$ok" = 1 ] || { fail=1; continue; }
  fi
  echo "ok   $name"
done
if [ "$count" = 0 ]; then
  echo "corpus-check.sh: no cases under $CORPUS" >&2
  exit 1
fi
if [ "$MODE" = "--gen" ] && [ "$fail" = 0 ]; then
  python3 Tools/mosh-oracle/check_format.py "$ORACLE" "$CORPUS" || fail=1
fi
if [ "$fail" = 0 ]; then
  echo "corpus-check: $count cases pass"
else
  echo "corpus-check: FAILED"
fi
exit "$fail"
