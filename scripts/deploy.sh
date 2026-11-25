#!/usr/bin/env bash
# Build on the Mac and install on the phone. Run on yellow.
#   scripts/deploy.sh                 build + install
#   scripts/deploy.sh --wait          wait for the phone to be reachable and unlocked first
#   scripts/deploy.sh --launch        also start the app
#   scripts/deploy.sh --smoke         also run the phone self-test against a throwaway
#                                     container on this machine (scripts/smoke-host.sh)
#   scripts/deploy.sh --logs          only pull the app's debug log to out/phone/
#   scripts/deploy.sh --no-build      skip the build (reuse the last one)
#   scripts/deploy.sh --testflight    Release archive, upload to TestFlight, wait for Apple's
#                                     processing, set What to Test from CHANGELOG.md (nothing else)
# The phone must be unlocked for a launch. Results land in out/phone/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WAIT=0 LAUNCH=0 SMOKE=0 LOGS=0 BUILD=1 TESTFLIGHT=0
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=1 ;;
    --launch) LAUNCH=1 ;;
    --smoke) SMOKE=1 ;;
    --logs) LOGS=1 ;;
    --no-build) BUILD=0 ;;
    --testflight) TESTFLIGHT=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

fetch() {  # copy results from the Mac to out/phone/
  mkdir -p out/phone
  # shellcheck disable=SC1091
  [ -f scripts/mac.env ] && . scripts/mac.env
  local key="$HOME/.ssh/ios-mosh-charlie" opts=(-q -o BatchMode=yes)
  if [ -f "$key" ]; then opts+=(-i "$key" -o IdentitiesOnly=yes)
  elif [ -n "${SSH_AGENT_FINDER:-}" ] && [ -x "$SSH_AGENT_FINDER" ]; then
    SSH_AUTH_SOCK="$("$SSH_AGENT_FINDER" 2>/dev/null || true)"; export SSH_AUTH_SOCK
  fi
  scp "${opts[@]}" "${MAC_USER:-$(id -un)}@${MAC_HOST:-charlie}:ios-mosh-out/phone/*" out/phone/ 2>/dev/null || true
}

if [ "$TESTFLIGHT" = 1 ]; then
  # The phone is not involved: Apple processes the build and TestFlight offers it.
  exec scripts/mac.sh scripts/mac-testflight.sh beta
fi

if [ "$LOGS" = 1 ]; then
  scripts/mac.sh --no-sync scripts/mac-deploy.sh pull debug.log pull smoke.json
  fetch
  exit 0
fi

steps=()
[ "$BUILD" = 1 ] && steps+=(build)
[ "$WAIT" = 1 ] && steps+=(wait)
steps+=(install)

if [ "$SMOKE" = 1 ]; then
  scripts/smoke-host.sh up
  trap 'scripts/smoke-host.sh down >/dev/null' EXIT
  RUN_ID="$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  ENV_JSON="$(RUN_ID="$RUN_ID" python3 - <<'PY'
import json, os
env = {"SMOKE_RUN_ID": os.environ["RUN_ID"]}
for line in open("out/smoke/host.env"):
    k, _, v = line.strip().partition("=")
    if k:
        env[k] = v
print(json.dumps(env))
PY
)"
  steps+=(launch "$ENV_JSON" poll-smoke "$RUN_ID" screenshot smoke)
elif [ "$LAUNCH" = 1 ]; then
  steps+=(launch)
fi

if [ "$BUILD" = 1 ]; then
  scripts/mac.sh scripts/mac-deploy.sh "${steps[@]}"
else
  scripts/mac.sh --no-sync scripts/mac-deploy.sh "${steps[@]}"
fi
fetch
