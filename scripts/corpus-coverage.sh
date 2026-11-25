#!/usr/bin/env bash
# Which code of the Swift terminal model does the golden corpus never reach?
#   scripts/corpus-coverage.sh
# Runs the three plain corpus tests (client states, server states, the server's diffs)
# with code coverage and prints, for each source file of the emulator and of the display
# diff, the lines that hold a code region that was never executed, and a summary.
# The result is discussed in Tools/mosh-oracle/README.md, "Coverage".
# Needs a coverage build of the package (several minutes the first time). Runs in the
# dev container (re-runs itself through scripts/dev.sh when started on the host).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d /opt/mosh-src ]; then
  exec "$ROOT/scripts/dev.sh" scripts/corpus-coverage.sh "$@"
fi
cd "$ROOT"
FILES="TerminalFunctions Emulator Framebuffer DrawState Dispatcher Parser DisplayDiff Cell Renditions"
tmp="$(mktemp -d /tmp/corpus-coverage.XXXXXX)"
trap 'rm -rf "$tmp"; rm -f "$ROOT/default.profraw"' EXIT

swift test -j 4 --enable-code-coverage \
  --filter 'MoshTerminalTests.CorpusTests/test(Client|Server)StatesEqualTheOracle$|MoshTerminalTests.CorpusDisplayTests/testServerDiffsEqualTheRecordedDiffs$' \
  > "$tmp/test.log" 2>&1 || { tail -40 "$tmp/test.log"; exit 1; }
grep -E '^corpus|Executed' "$tmp/test.log" | cut -c1-200

sources=""
for f in $FILES; do sources="$sources Sources/MoshTerminal/$f.swift"; done
# shellcheck disable=SC2086
llvm-cov export -format=text .build/debug/MoshKitPackageTests.xctest \
  -instr-profile=.build/debug/codecov/default.profdata $sources > "$tmp/export.json" 2> /dev/null

python3 - "$tmp/export.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
for f in sorted(data["data"][0]["files"], key=lambda f: f["filename"]):
    path = f["filename"]
    source = open(path, encoding="utf-8").read().split("\n")
    seen = set()
    for line, col, count, has_count, is_entry, is_gap in (s[:6] for s in f["segments"]):
        if has_count and is_entry and not is_gap and count == 0 and line not in seen:
            seen.add(line)
            print("%s:%d:%d: %s" % (path, line, col, source[line - 1].strip()[:100]))
    s = f["summary"]
    print("== %s: lines %d/%d, regions %d/%d, functions %d/%d\n" % (
        path, s["lines"]["covered"], s["lines"]["count"], s["regions"]["covered"], s["regions"]["count"],
        s["functions"]["covered"], s["functions"]["count"]))
PY
