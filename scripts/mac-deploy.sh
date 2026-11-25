#!/bin/bash
# Runs ON THE MAC, started by scripts/deploy.sh. Steps, in the order given:
#   build            xcodegen + xcodebuild for the device
#   wait             until the phone is paired, reachable and unlocked
#   install          devicectl install
#   launch [JSON]    launch, optionally with environment variables (a JSON object)
#   pull FILE        copy Documents/FILE from the app container to ~/ios-mosh-out/phone/
#   poll-smoke RUNID wait up to 180 s for Documents/smoke.json with that run id
#   screenshot NAME  phone screenshot to ~/ios-mosh-out/phone/NAME.png
# Signing material is in ~/signing (see docs/BUILD.md). Nothing in it is printed.
# The Debug build is the Dev app "iOS-mosh Dev" (us.v9n.ios-mosh.dev): install, launch
# and pull act on it, never on the TestFlight app us.v9n.ios-mosh beside it.
set -euo pipefail
cd "$(dirname "$0")/../App"
S="$HOME/signing"
DD="$HOME/ios-mosh-dd"
OUT="$HOME/ios-mosh-out"
BUNDLE=us.v9n.ios-mosh.dev
APP="$DD/Build/Products/Debug-iphoneos/IOSMosh.app"
mkdir -p "$OUT/phone"
UDID="$(cat "$S/udid")"

# The keychain that holds the signing identity is locked in an SSH session.
# `security -i` reads the command from stdin, so the password is not in argv.
unlock_keychain() {
  local kc pw
  if [ -f "$S/kc.pass" ]; then
    kc="$HOME/Library/Keychains/ios-mosh.keychain-db"; pw="$S/kc.pass"
  elif [ -f "$S/login.pass" ]; then
    kc="$HOME/Library/Keychains/login.keychain-db"; pw="$S/login.pass"
  else
    return 0
  fi
  /usr/bin/python3 - "$kc" "$pw" <<'PY' | security -i >/dev/null
import sys
kc, pwfile = sys.argv[1], sys.argv[2]
pw = open(pwfile).read().rstrip("\n")
q = lambda s: '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
print("unlock-keychain -p %s %s" % (q(pw), q(kc)))
PY
}

phone_json() {
  xcrun devicectl list devices --timeout 20 --json-output "$OUT/devices.json" >/dev/null 2>&1 || return 1
  /usr/bin/python3 - "$OUT/devices.json" "$UDID" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d.get("hardwareProperties", {}).get("udid") == sys.argv[2]:
        c = d.get("connectionProperties", {})
        print(c.get("pairingState", "?"), c.get("tunnelState", "?"), c.get("transportType", "none"))
        sys.exit(0)
print("absent ? none")
PY
}

phone_unlocked() {
  xcrun devicectl device info lockState --device "$UDID" --timeout 20 \
    --json-output "$OUT/lock.json" >/dev/null 2>&1 || return 1
  /usr/bin/python3 -c '
import json, sys
r = json.load(open(sys.argv[1])).get("result") or {}
sys.exit(0 if r.get("passcodeRequired") is False else 1)' "$OUT/lock.json"
}

pull() {
  rm -f "$OUT/phone/$1"
  xcrun devicectl device copy from --device "$UDID" --timeout 30 \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/$1" --destination "$OUT/phone/$1" >/dev/null 2>&1
}

while [ $# -gt 0 ]; do
  step="$1"; shift
  case "$step" in
    build)
      xcodegen generate >/dev/null
      unlock_keychain
      echo "== build for device"
      # shellcheck disable=SC2086
      if ! xcodebuild build -project IOSMosh.xcodeproj -scheme IOSMoshDevice \
           -destination generic/platform=iOS -derivedDataPath "$DD" \
           -skipPackagePluginValidation ${XCODEBUILD_EXTRA:-} >"$OUT/device-build.log" 2>&1; then
        grep -E "error:|\*\* " "$OUT/device-build.log" | grep -v CoreSimulator | head -40
        echo "build failed; full log on the Mac: $OUT/device-build.log" >&2
        exit 1
      fi
      /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleVersion" -c "Print :IOSMoshGitSHA" "$APP/Info.plist" | tr '\n' ' '
      echo "built"
      ;;
    wait)
      echo "== waiting for the phone (paired, reachable, unlocked)"
      n=0
      until state="$(phone_json)" && [ "${state%% *}" = paired ] && phone_unlocked; do
        n=$((n + 1))
        [ $((n % 15)) -eq 1 ] && echo "   phone: ${state:-unknown} (still waiting)"
        sleep 20
      done
      echo "   phone ready: $state"
      ;;
    install)
      echo "== install"
      xcrun devicectl device install app --device "$UDID" --timeout 180 "$APP" 2>&1 | tail -4
      ;;
    launch)
      echo "== launch"
      if [ $# -gt 0 ] && [ "${1:0:1}" = "{" ]; then
        env_json="$1"; shift
        xcrun devicectl device process launch --device "$UDID" --timeout 60 --terminate-existing \
          --environment-variables "$env_json" "$BUNDLE" 2>&1 | tail -2
      else
        xcrun devicectl device process launch --device "$UDID" --timeout 60 --terminate-existing \
          "$BUNDLE" 2>&1 | tail -2
      fi
      ;;
    pull)
      pull "$1" && echo "pulled $1" || echo "could not pull $1"
      shift
      ;;
    poll-smoke)
      run_id="$1"; shift
      echo "== waiting for smoke.json with run id $run_id"
      ok=1
      for _ in $(seq 1 36); do
        if pull smoke.json && grep -q "\"runId\" *: *\"$run_id\"" "$OUT/phone/smoke.json"; then ok=0; break; fi
        sleep 5
      done
      pull debug.log || true
      [ "$ok" = 0 ] || { echo "no smoke.json for this run after 180 s" >&2; exit 1; }
      cat "$OUT/phone/smoke.json"
      ;;
    screenshot)
      name="$1"; shift
      xcrun devicectl device capture screenshot --device "$UDID" --timeout 30 \
        --destination "$OUT/phone/$name.png" >/dev/null 2>&1 && echo "screenshot $name.png" \
        || echo "screenshot failed"
      ;;
    *)
      echo "unknown step: $step" >&2
      exit 2
      ;;
  esac
done
