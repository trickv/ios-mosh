#!/bin/bash
# Runs ON THE MAC. The phone self-test without a smoke host: installs nothing, launches the
# installed Dev app (us.v9n.ios-mosh.dev, through mac-deploy.sh; never the TestFlight app) once with SMOKE_RUN_ID (one launch, takes over the phone's screen), waits for
# Documents/smoke.json of this run, takes a screenshot and prints the "device" part.
#   scripts/phone-selftest.sh            the device checks (DeviceProbe) while unlocked
#   scripts/phone-selftest.sh --locked   also the locked pass: after this prints, lock the phone
#                                        (within 10 min), leave it locked 60 s without
#                                        looking at it, unlock, then run
#                                        scripts/phone-selftest.sh --show (docs/MAC.md, checklist)
#   scripts/phone-selftest.sh --show     pull smoke.json again and print it (no launch)
#   scripts/phone-selftest.sh --write-kill  the device checks, then the app writes 100 records
#                                        without a sync and kills itself (SIGKILL); the next
#                                        launch of this script reads them back ("writeKill")
# With out/smoke/host.env present use the full self-test in docs/MAC.md section 2 instead.
# The phone must be unlocked for a launch; the `wait` step waits for that.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$HOME/ios-mosh-out/phone"
show() {
  /usr/bin/python3 - "$OUT/smoke.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("run", r.get("runId"), "build", r.get("build"))
for part in ("device", "locked", "writeKill"):
    if part in r:
        print(part, json.dumps(r[part], indent=1, sort_keys=True))
boot = (r.get("device") or {}).get("bootIdentifier")
if isinstance(boot, dict):
    print("BOOT ID:", boot.get("status"), "| value", boot.get("value"), "| digest", boot.get("digest"))
wk = r.get("writeKill")
if isinstance(wk, dict):
    print("WRITE-KILL VERDICT:", wk.get("verdict"))
if "writeKillWritten" in r:
    print("WRITE-KILL: wrote", r["writeKillWritten"], "records, the app killed itself; the next run reads them back")
if r.get("devicePublicKey"):
    print("DEVICE KEY:", r["devicePublicKey"])
locked = r.get("locked")
if isinstance(locked, dict):
    if locked.get("pending"):
        print("LOCKED PASS: still waiting (lock the phone, then --show after unlocking)")
    else:
        print("LOCKED PASS VERDICT:", locked.get("verdict", "no verdict (older build)"))
PY
}
case "${1:-}" in
  --show)
    scripts/mac-deploy.sh pull smoke.json
    show
    exit 0
    ;;
  --locked) locked=1 ;;
  --write-kill) locked=2 ;;
  "") locked=0 ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac
RUN_ID="$(/usr/bin/python3 -c 'import secrets; print(secrets.token_hex(6))')"
if [ "$locked" = 1 ]; then
  ENV_JSON="{\"SMOKE_RUN_ID\":\"$RUN_ID\",\"SMOKE_LOCKED_SAVE\":\"1\"}"
elif [ "$locked" = 2 ]; then
  ENV_JSON="{\"SMOKE_RUN_ID\":\"$RUN_ID\",\"SMOKE_WRITE_KILL\":\"1\"}"
else
  ENV_JSON="{\"SMOKE_RUN_ID\":\"$RUN_ID\"}"
fi
scripts/mac-deploy.sh wait launch "$ENV_JSON" poll-smoke "$RUN_ID" screenshot selftest >/dev/null
if [ "$locked" = 2 ]; then
  # smoke.json is written once before the records; wait for the write that comes after them.
  for _ in $(seq 1 24); do
    grep -q '"writeKillWritten"' "$OUT/smoke.json" && break
    sleep 5
    scripts/mac-deploy.sh pull smoke.json >/dev/null || true
  done
  grep -q '"writeKillWritten"' "$OUT/smoke.json" || echo "WRITE-KILL: no record count after 120 s" >&2
fi
show
