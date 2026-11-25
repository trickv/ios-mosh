#!/usr/bin/env bash
# Sync this checkout to the Mac and run a command there.
#   scripts/mac.sh swift test
#   scripts/mac.sh --no-sync xcrun devicectl list devices
#   scripts/mac.sh --ssh 'echo raw command, no cd, no sync'
# Settings (optional) in scripts/mac.env: MAC_HOST, MAC_USER, MAC_DIR, SSH_AGENT_FINDER.
# SSH uses ~/.ssh/ios-mosh-charlie when it exists. Otherwise, when SSH_AGENT_FINDER is
# set, it borrows a running agent through that local helper, which finds a running
# ssh-agent and prints its socket.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/scripts/mac.env" ] && . "$ROOT/scripts/mac.env"
MAC_HOST="${MAC_HOST:-charlie}"
MAC_USER="${MAC_USER:-$(id -un)}"
MAC_DIR="${MAC_DIR:-ios-mosh-build}"
DEST="$MAC_USER@$MAC_HOST"

KEY="$HOME/.ssh/ios-mosh-charlie"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
if [ -f "$KEY" ]; then
  SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
elif [ -n "${SSH_AGENT_FINDER:-}" ] && [ -x "$SSH_AGENT_FINDER" ]; then
  SSH_AUTH_SOCK="$("$SSH_AGENT_FINDER" 2>/dev/null || true)"
  export SSH_AUTH_SOCK
fi

SYNC=1
RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-sync) SYNC=0; shift ;;
    --ssh) RAW=1; SYNC=0; shift ;;
    *) break ;;
  esac
done

# Non-interactive shells on the Mac have neither Homebrew nor a UTF-8 locale.
PRELUDE='export PATH=/opt/homebrew/bin:$PATH LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8;'

if [ "$RAW" = 1 ]; then
  exec ssh "${SSH_OPTS[@]}" "$DEST" "$PRELUDE $*"
fi

if [ "$SYNC" = 1 ]; then
  count="$(git -C "$ROOT" rev-list --count HEAD)"
  sha="$(git -C "$ROOT" rev-parse --short HEAD)"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || sha="$sha-dirty"
  mkdir -p "$ROOT/App"
  # The marketing version is not written here: App/Local.xcconfig holds it.
  printf 'CURRENT_PROJECT_VERSION = %s\nIOSMOSH_GIT_SHA = %s\n' \
    "$count" "$sha" > "$ROOT/App/Version.xcconfig"
  # Signing.xcconfig and the generated project live only on the Mac. They are
  # excluded, so --delete leaves them alone.
  rsync -az --delete \
    --exclude .git --exclude .build --exclude .refs --exclude .worktrees \
    --exclude App/Signing.xcconfig --exclude App/IOSMosh/Info.plist \
    --exclude '*.xcodeproj' --exclude .swiftpm \
    --exclude out --exclude tmp \
    --rsync-path=/opt/homebrew/bin/rsync -e "ssh ${SSH_OPTS[*]}" \
    "$ROOT/" "$DEST:$MAC_DIR/"
fi

# Keep the Mac awake for as long as builds are wanted. Redirects are needed or
# ssh does not return.
KEEP='pgrep -x caffeinate >/dev/null || (nohup caffeinate -is </dev/null >/dev/null 2>&1 &);'
printf -v CMD '%q ' "$@"
exec ssh "${SSH_OPTS[@]}" "$DEST" "$PRELUDE $KEEP cd \"\$HOME/$MAC_DIR\" && $CMD"
