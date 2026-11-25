#!/bin/bash
# Sourced by the signing scripts ON THE MAC. Expects S (~/signing) and REPO.

# App/Signing.xcconfig: team, profiles and the keychain. The identity names are in
# App/project.yml, because XcodeGen's target preset sets CODE_SIGN_IDENTITY and a
# target setting beats an xcconfig.
# Debug device builds are the Dev app (us.v9n.ios-mosh.dev) with the profile
# ios-mosh-dev-app (mac-signing-setup.sh devapp); Release is the TestFlight app
# (us.v9n.ios-mosh) with ios-mosh-appstore (mac-testflight.sh signing). The old
# development profile ios-mosh-dev (us.v9n.ios-mosh) is no longer used by a build.
write_signing_xcconfig() {
  local team p src=""
  for p in ios-mosh-dev-app ios-mosh-dev ios-mosh-appstore; do
    if [ -s "$S/$p.mobileprovision" ]; then src="$S/$p.mobileprovision"; break; fi
  done
  [ -n "$src" ] || { echo "no provisioning profile in ~/signing" >&2; return 1; }
  [ -s "$S/ios-mosh-dev-app.mobileprovision" ] || \
    echo "note: no ios-mosh-dev-app profile yet; Debug device builds need scripts/mac-signing-setup.sh devapp" >&2
  security cms -D -i "$src" 2>/dev/null > "$S/profile.plist"
  team="$(plutil -extract TeamIdentifier.0 raw -o - "$S/profile.plist")"
  {
    echo "// Written on the Mac by the signing scripts. Not synced, not committed."
    echo "DEVELOPMENT_TEAM = $team"
    echo "CODE_SIGN_STYLE = Manual"
    echo "PROVISIONING_PROFILE_SPECIFIER[config=Debug][sdk=iphoneos*] = ios-mosh-dev-app"
    if [ -s "$S/ios-mosh-appstore.mobileprovision" ]; then
      echo "PROVISIONING_PROFILE_SPECIFIER[config=Release][sdk=iphoneos*] = ios-mosh-appstore"
    fi
    echo "OTHER_CODE_SIGN_FLAGS = --keychain \$(HOME)/Library/Keychains/ios-mosh.keychain-db"
  } > "$REPO/App/Signing.xcconfig"
}

# Xcode 16 and later look in the second directory; older tools in the first.
install_profile() {
  local uuid dir
  security cms -D -i "$1" 2>/dev/null > "$S/profile.tmp.plist"
  uuid="$(plutil -extract UUID raw -o - "$S/profile.tmp.plist")"
  rm -f "$S/profile.tmp.plist"
  for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
             "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    mkdir -p "$dir" && cp "$1" "$dir/$uuid.mobileprovision"
  done
}
