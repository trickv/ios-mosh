#!/bin/bash
# Runs ON THE MAC. Builds the app and runs its tests on a simulator. Tests run against
# the Debug build, the Dev app us.v9n.ios-mosh.dev (its container holds the diagnostics).
#   scripts/mac.sh scripts/sim-test.sh                      # all app tests
#   scripts/mac.sh scripts/sim-test.sh -only-testing:IOSMoshUITests/PlaceholderUITests
# Env: SIM_NAME (default "iPhone 17"). Output: ~/ios-mosh-out/{result.xcresult,attachments,*.log}
# Runs scripts/mosh-spawner.py for the test step (log: ~/ios-mosh-out/spawner.log),
# with its throwaway sshd on 127.0.0.1 for the SSH bootstrap UI test (--sshd: the
# system's sshd as this user, own config, host key and authorized_keys in a temp dir).
# A UI test that fails asks the spawner for diagnostics before it ends (the app's
# debug.log, its session records, the marks, its processes and open files):
# ~/ios-mosh-out/diagnostics/<Class>.<test>-<time>/. Copy them off before the next run.
# Key check: at the end the spawner searches diagnostics/ and attachments/ for the
# session keys it handed out and for "-debugMoshKey <key>"; a file that holds one is
# deleted and named, and the run fails ("KEY CHECK FAILED"). result.xcresult is not
# searched: XCTest records the launch arguments there, so it holds the keys of the
# run's throwaway servers. It stays on the Mac and the next run replaces it.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPTS/../App"
DD="$HOME/ios-mosh-dd"
OUT="$HOME/ios-mosh-out"
SIM_NAME="${SIM_NAME:-iPhone 17}"
mkdir -p "$OUT"

xcodegen generate >/dev/null

UDID="$(xcrun simctl list devices available -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
# Newest runtime first.
for runtime in sorted(devices, reverse=True):
    for d in devices[runtime]:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
sys.exit(1)
' "$SIM_NAME")" || { echo "no available simulator named $SIM_NAME" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

COMMON=(-project IOSMosh.xcodeproj -scheme IOSMosh -destination "id=$UDID"
        -derivedDataPath "$DD" -skipPackagePluginValidation)

echo "== build-for-testing"
if ! xcodebuild build-for-testing "${COMMON[@]}" >"$OUT/build.log" 2>&1; then
  grep -E "error:|warning: unre|\*\* " "$OUT/build.log" | head -60
  echo "build failed; full log: $OUT/build.log" >&2
  exit 1
fi

rm -rf "$OUT/result.xcresult" "$OUT/attachments" "$OUT/diagnostics"

# mosh-server sessions for the UI tests (docs/PLAN.md M5): scripts/mosh-spawner.py
# on 127.0.0.1, a port the system picks. The simulator shares the Mac's network, so
# the UI test runner reaches it at 127.0.0.1. xcodebuild passes TEST_RUNNER_FOO to
# the test runner as FOO, so the tests read MOSH_SPAWNER_URL.
SPAWNER_PORT_FILE="$OUT/spawner.port"
rm -f "$SPAWNER_PORT_FILE"
/usr/bin/python3 "$SCRIPTS/mosh-spawner.py" --port-file "$SPAWNER_PORT_FILE" --sshd \
  --diag-dir "$OUT/diagnostics" --key-check-dir "$OUT/attachments" --sim-udid "$UDID" \
  --bundle-id us.v9n.ios-mosh.dev \
  2>"$OUT/spawner.log" &
SPAWNER_PID=$!
trap 'kill "$SPAWNER_PID" 2>/dev/null || true; wait "$SPAWNER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 100); do [ -s "$SPAWNER_PORT_FILE" ] && break; sleep 0.1; done
[ -s "$SPAWNER_PORT_FILE" ] || { echo "mosh-spawner did not start; see $OUT/spawner.log" >&2; exit 1; }
export TEST_RUNNER_MOSH_SPAWNER_URL="http://127.0.0.1:$(cat "$SPAWNER_PORT_FILE")"

echo "== test-without-building"
status=0
xcodebuild test-without-building "${COMMON[@]}" -resultBundlePath "$OUT/result.xcresult" "$@" \
  >"$OUT/test.log" 2>&1 || status=$?
# The app's own os_log lines ("2026-... IOSMosh[pid:tid] ...") are dropped: the
# simulator logs harmless "Error Domain=..." noise (haptics) that matched "error:".
grep -E "Test Case .*(passed|failed)|error:|Executed [0-9]+ tests?,|\*\* TEST" "$OUT/test.log" \
  | grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.+-]+ [A-Za-z]+\[[0-9]+:[0-9]+\]' | tail -60

# Screenshots are XCTAttachments with lifetime keepAlways.
xcrun xcresulttool export attachments --path "$OUT/result.xcresult" \
  --output-path "$OUT/attachments" >/dev/null 2>&1 || echo "note: no attachments exported"
ls "$OUT/attachments" 2>/dev/null | head -20
echo "== servers left after the run: $(curl -fsS --max-time 10 "$TEST_RUNNER_MOSH_SPAWNER_URL/sshd/servers")"
# No kept file may hold a session key (names and counts only, never the key).
if ! keycheck="$(curl -fsS --max-time 120 "$TEST_RUNNER_MOSH_SPAWNER_URL/keycheck" | /usr/bin/python3 -c '
import json, sys
answer = json.load(sys.stdin)
print("== key check: %d kept files searched, %d held a session key" % (answer["files"], len(answer["removed"])))
for path in answer["removed"]:
    print("removed (held a session key): " + path)
sys.exit(1 if answer["removed"] else 0)
')"; then
  echo "$keycheck"
  echo "KEY CHECK FAILED: a kept file held a session key (deleted, named above), or the spawner did not answer" >&2
  [ "$status" != 0 ] || status=1
else
  echo "$keycheck"
fi
if [ -d "$OUT/diagnostics" ]; then
  echo "== diagnostics of failed UI tests in $OUT/diagnostics:"
  ls "$OUT/diagnostics"
fi
exit "$status"
