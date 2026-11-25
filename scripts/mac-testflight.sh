#!/bin/bash
# Runs ON THE MAC. TestFlight through fastlane with the API key in ~/signing.
#   scripts/mac.sh scripts/mac-testflight.sh signing   # once: distribution cert + App Store profile
#   scripts/mac.sh scripts/mac-testflight.sh archive   # Release archive + ipa, no upload
#   scripts/mac.sh scripts/mac-testflight.sh record    # does the app record exist?
#   scripts/mac.sh scripts/mac-testflight.sh testers   # once: internal group, account holder added
#   scripts/mac.sh scripts/mac-testflight.sh beta      # archive, upload, wait for Apple's processing,
#                                                      # set What to Test (CHANGELOG.md); internal only
#   scripts/mac.sh scripts/mac-testflight.sh listing   # App Store texts + screenshots; no build, no submit
#   scripts/mac.sh scripts/mac-testflight.sh check     # what beta checks first, nothing else
# Output: ~/ios-mosh-out/testflight/. Nothing from ~/signing is printed.
# GPLv3 section 6: every build given to anyone must come with the source of exactly that build.
# So `beta` refuses a tree with uncommitted changes (scripts/mac.sh rsyncs the working tree and
# marks it "<sha>-dirty" in App/Version.xcconfig), and `archive` and `beta` build with exactly the
# packages of the tracked Package.resolved (installed into the generated project; a release whose
# packages would resolve otherwise is refused), so the release commit records its versions.
# Release only: the TestFlight app us.v9n.ios-mosh ("iOS-mosh", profile ios-mosh-appstore).
# The Dev app us.v9n.ios-mosh.dev (Debug) is never archived or uploaded here.
set -euo pipefail
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_OPT_OUT_USAGE=1 CI=1 FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT=120
# System tools first: xcodebuild -exportArchive calls `rsync` with Apple-only flags
# and fails with "Copy failed" when Homebrew's rsync comes first.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$HOME/signing"
KC="$HOME/Library/Keychains/ios-mosh.keychain-db"
mkdir -p "$HOME/ios-mosh-out/testflight"

unlock() {
  /usr/bin/python3 - "$S/kc.pass" "$KC" <<'PY' | security -i >/dev/null
import sys
pw = open(sys.argv[1]).read().strip()
print('unlock-keychain -p "%s" "%s"' % (pw, sys.argv[2]))
PY
}

# Hide identifiers (team id, key id, UUIDs) in what reaches the terminal.
mask() {
  sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/UUID/g; s/[[:<:]][A-Z0-9]{10}[[:>:]]/XXXXXXXXXX/g'
}

# shellcheck source=scripts/mac-signing-lib.sh
. "$REPO/scripts/mac-signing-lib.sh"

# Refuses unless the tree is a commit as it is: no "-dirty" build SHA and, in a git checkout,
# nothing uncommitted.
clean_tree() {
  local sha
  sha="$(sed -n 's/^IOSMOSH_GIT_SHA = //p' "$REPO/App/Version.xcconfig" 2>/dev/null || true)"
  case "$sha" in
    "") echo "refused: App/Version.xcconfig has no build SHA (scripts/mac.sh writes it)" >&2; return 1 ;;
    *-dirty) echo "refused: the tree has uncommitted changes ($sha); commit and push, then upload" >&2; return 1 ;;
  esac
  if [ -d "$REPO/.git" ] && [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    echo "refused: git status shows uncommitted changes; commit and push, then upload" >&2
    return 1
  fi
  echo "clean tree: $sha"
}

# Installs the tracked Package.resolved into the generated project, resolves the release build's
# packages from it alone, and refuses when what Xcode resolved differs from it in any pin.
# Needs the project (xcodegen generate) and runs in App/.
pin_packages() {
  local dd="$HOME/ios-mosh-dd-release" swiftpm="IOSMosh.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$swiftpm"
  cp "$REPO/Package.resolved" "$swiftpm/Package.resolved"
  if ! xcodebuild -resolvePackageDependencies -project IOSMosh.xcodeproj -scheme IOSMoshDevice \
      -derivedDataPath "$dd" -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
      > "$HOME/ios-mosh-out/testflight/resolve.log" 2>&1; then
    echo "refused: the packages do not resolve from Package.resolved alone (testflight/resolve.log)" >&2
    return 1
  fi
  /usr/bin/python3 - "$REPO/Package.resolved" "$dd/SourcePackages/workspace-state.json" <<'PY'
import json, sys
pins = {p["identity"]: (p["state"].get("version"), p["state"]["revision"])
        for p in json.load(open(sys.argv[1]))["pins"]}
got = {d["packageRef"]["identity"]: (d["state"]["checkoutState"].get("version"),
                                     d["state"]["checkoutState"]["revision"])
       for d in json.load(open(sys.argv[2]))["object"]["dependencies"]
       if d["state"].get("name") == "sourceControlCheckout"}
if got != pins:
    for k in sorted(set(pins) | set(got)):
        if pins.get(k) != got.get(k):
            print("refused: %s is %s in the build, %s in Package.resolved" % (k, got.get(k), pins.get(k)),
                  file=sys.stderr)
    sys.exit(1)
print("packages: %d, exactly as in Package.resolved" % len(pins))
PY
}

stage="${1:-}"
cd "$REPO/App"
case "$stage" in
  signing)
    unlock
    fastlane signing_dist 2>&1 | grep -E "error|Error|Success|success|finished|Creating|Using|reusing|limit" | mask | tail -15
    test -s "$S/ios-mosh-appstore.mobileprovision" || { echo "no App Store profile was written" >&2; exit 1; }
    install_profile "$S/ios-mosh-appstore.mobileprovision"
    write_signing_xcconfig
    echo "App Store profile installed; Signing.xcconfig covers Debug and Release"
    ;;
  check)
    status=0
    clean_tree || status=1
    xcodegen generate >/dev/null
    pin_packages || status=1
    exit "$status"
    ;;
  archive|beta)
    if [ "$stage" = beta ]; then clean_tree || exit 1; fi
    xcodegen generate >/dev/null
    pin_packages || exit 1
    write_signing_xcconfig
    unlock
    status=0
    fastlane "$stage" > "$HOME/ios-mosh-out/testflight/fastlane-$stage.log" 2>&1 || status=$?
    grep -E "error:|Error|\*\* |Successfully|uploaded|finished|no app record|Could not|invalid|ITMS|What to Test|CHANGELOG|timeout|exceeded" \
      "$HOME/ios-mosh-out/testflight/fastlane-$stage.log" | mask | tail -25
    ls -la "$HOME/ios-mosh-out/testflight/"*.ipa 2>/dev/null | awk '{print $5, $9}' | sed "s|$HOME|~|"
    exit "$status"
    ;;
  listing)
    # App Store texts and screenshots only (Fastfile lane "listing"); no signing needed.
    status=0
    fastlane listing > "$HOME/ios-mosh-out/testflight/fastlane-listing.log" 2>&1 || status=$?
    mask < "$HOME/ios-mosh-out/testflight/fastlane-listing.log"
    exit "$status"
    ;;
  record|testers)
    fastlane "$stage" 2>&1 | grep -E "error|Error|exists|no app record|ready|finished" | mask | tail -8
    ;;
  *)
    echo "usage: $0 signing|archive|record|testers|beta|listing|check" >&2
    exit 2
    ;;
esac
