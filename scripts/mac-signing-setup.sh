#!/bin/bash
# Runs ON THE MAC. One-time signing setup with an App Store Connect API key.
#   scripts/mac.sh scripts/mac-signing-setup.sh prep     # tools, keychain of our own
#   scripts/mac.sh scripts/mac-signing-setup.sh apple    # App ID, certificate, device, profile
#   scripts/mac.sh scripts/mac-signing-setup.sh devapp   # App ID + profile of the Dev app
#   scripts/mac.sh scripts/mac-signing-setup.sh verify   # sign a test binary
# Needs in ~/signing: AuthKey_<key id>.p8, issuer.txt (the issuer id), udid.
# Writes there: kc.pass, asc.json, the certificate and profile; and App/Signing.xcconfig.
# "apple" made the App ID us.v9n.ios-mosh, the development certificate, the device and
# the profile ios-mosh-dev (2026-11-12). Debug builds are now the separate app
# "iOS-mosh Dev" (us.v9n.ios-mosh.dev): "devapp" registers that App ID and makes (or
# fetches, when it exists) its development profile ios-mosh-dev-app with the existing
# certificate (~/signing/cert_id) and the registered phone. It creates no certificate,
# deletes nothing and leaves us.v9n.ios-mosh alone, so it can be run again at any time.
# Nothing in ~/signing is printed or copied off the Mac.
set -euo pipefail
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_OPT_OUT_USAGE=1 CI=1
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$HOME/signing"
KC="$HOME/Library/Keychains/ios-mosh.keychain-db"
PROFILE_NAME=ios-mosh-dev
DEVAPP_PROFILE_NAME=ios-mosh-dev-app
# shellcheck source=scripts/mac-signing-lib.sh
. "$REPO/scripts/mac-signing-lib.sh"

# Run a `security` command that takes the keychain password without putting the
# password in argv: `security -i` reads commands from stdin.
security_with_password() {  # usage: security_with_password <subcommand> args...; @PW@ stands for the password
  /usr/bin/python3 - "$S/kc.pass" "$@" <<'PY' | security -i >/dev/null
import re, sys
pw = open(sys.argv[1]).read().strip()
def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
out = []
for a in sys.argv[2:]:
    if a == "@PW@":
        out.append(q(pw))
    elif re.fullmatch(r"[A-Za-z0-9_./-]+", a):
        out.append(a)
    else:
        out.append(q(a))
print(" ".join(out))
PY
}

# ~/signing/fastlane/Fastfile, run with the working directory ~/signing.
write_fastfile() {
  mkdir -p "$S/fastlane"
  cat > "$S/fastlane/Fastfile" <<'RUBY'
# Written by scripts/mac-signing-setup.sh. No secrets in this file.
S = File.expand_path("~/signing")
KC = File.expand_path("~/Library/Keychains/ios-mosh.keychain-db")
BUNDLE = "us.v9n.ios-mosh"

lane :setup do
  key = "#{S}/asc.json"
  Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(key)
  if Spaceship::ConnectAPI::BundleId.find(BUNDLE)
    UI.message("App ID #{BUNDLE} exists")
  else
    Spaceship::ConnectAPI::BundleId.create(name: "IOSMosh", platform: "IOS", identifier: BUNDLE)
    UI.success("registered App ID #{BUNDLE}")
  end

  # Our own certificate, with its private key in our own keychain. The identity in
  # the login keychain cannot be used over SSH. force: true, or cert would settle
  # for that one. A certificate id from an earlier run is reused.
  cert_id_file = "#{S}/cert_id"
  if File.exist?(cert_id_file)
    cert_id = File.read(cert_id_file).strip
    UI.message("reusing certificate from an earlier run")
  else
    cert(development: true, force: true, api_key_path: key, keychain_path: KC,
         keychain_password: File.read("#{S}/kc.pass").strip, output_path: S)
    cert_id = lane_context[SharedValues::CERT_CERTIFICATE_ID]
    File.write(cert_id_file, cert_id)
  end

  register_devices(api_key_path: key, devices: { "Trick iPhone" => File.read("#{S}/udid").strip })

  sigh(development: true, api_key_path: key, app_identifier: BUNDLE,
       provisioning_name: "ios-mosh-dev", cert_id: cert_id, force: true,
       output_path: S, filename: "ios-mosh-dev.mobileprovision")
end

# The Dev app: Debug builds, beside the TestFlight app on the phone. Reuses the
# certificate of :setup and the phone it registered; never creates a certificate.
# No force: an existing valid profile of this name is downloaded, not replaced.
DEV_BUNDLE = "us.v9n.ios-mosh.dev"
DEV_PROFILE = "ios-mosh-dev-app"

lane :devapp do
  key = "#{S}/asc.json"
  Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(key)
  if Spaceship::ConnectAPI::BundleId.find(DEV_BUNDLE)
    UI.message("App ID #{DEV_BUNDLE} exists")
  else
    Spaceship::ConnectAPI::BundleId.create(name: "IOSMoshDev", platform: "IOS", identifier: DEV_BUNDLE)
    UI.success("registered App ID #{DEV_BUNDLE} (IOSMoshDev)")
  end
  cert_id_file = "#{S}/cert_id"
  UI.user_error!("no ~/signing/cert_id: run the apple step first") unless File.exist?(cert_id_file)
  cert_id = File.read(cert_id_file).strip
  udid = File.read("#{S}/udid").strip
  phone = Spaceship::ConnectAPI::Device.all.find { |d| d.udid.casecmp?(udid) }
  UI.user_error!("the phone is not registered: run the apple step first") unless phone
  sigh(development: true, api_key_path: key, app_identifier: DEV_BUNDLE,
       provisioning_name: DEV_PROFILE, cert_id: cert_id, force: false,
       output_path: S, filename: "#{DEV_PROFILE}.mobileprovision")
end
RUBY
}

case "${1:-}" in
  prep)
    chmod 700 "$S"
    chmod 600 "$S"/AuthKey_*.p8
    command -v fastlane >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install fastlane 2>&1 | tail -2
    fastlane --version 2>/dev/null | tail -1
    [ -f "$S/kc.pass" ] || (umask 077; openssl rand -hex 24 > "$S/kc.pass")
    if [ ! -f "$KC" ]; then
      security_with_password create-keychain -p @PW@ "$KC"
      # No auto-lock: builds unlock it in the same SSH command anyway.
      security set-keychain-settings "$KC"
      # Keep it in the search list, after the existing keychains.
      # shellcheck disable=SC2046
      eval security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') "\"$KC\""
      echo "created keychain ios-mosh"
    fi
    security list-keychains -d user | sed "s|$HOME|~|"
    ;;

  apple)
    test -s "$S/issuer.txt" || { echo "missing ~/signing/issuer.txt (the issuer id)" >&2; exit 1; }
    test -s "$S/udid" || { echo "missing ~/signing/udid" >&2; exit 1; }
    /usr/bin/python3 - "$S" <<'PY'
import glob, json, os, sys
s = sys.argv[1]
keys = glob.glob(os.path.join(s, "AuthKey_*.p8"))
assert len(keys) == 1, "expected exactly one AuthKey_*.p8 in ~/signing"
key_id = os.path.basename(keys[0])[len("AuthKey_"):-len(".p8")]
doc = {"key_id": key_id, "issuer_id": open(os.path.join(s, "issuer.txt")).read().strip(),
       "key": open(keys[0]).read(), "in_house": False}
path = os.path.join(s, "asc.json")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(doc).encode()); os.close(fd)
PY
    write_fastfile
    security_with_password unlock-keychain -p @PW@ "$KC"
    (cd "$S" && fastlane setup 2>&1) | grep -v -E "^\s*$" | sed -E 's/[A-Z0-9]{10}/XXXXXXXXXX/g; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/UUID/g' | tail -40

    PROFILE="$S/$PROFILE_NAME.mobileprovision"
    test -s "$PROFILE" || { echo "no profile was written" >&2; exit 1; }
    install_profile "$PROFILE"
    write_signing_xcconfig
    echo "profile installed; App/Signing.xcconfig written; devices in profile: $(plutil -extract ProvisionedDevices raw -o - "$S/profile.plist")"
    ;;

  devapp)
    test -s "$S/asc.json" || { echo "missing ~/signing/asc.json: run the apple step first" >&2; exit 1; }
    test -s "$S/cert_id" || { echo "missing ~/signing/cert_id: run the apple step first" >&2; exit 1; }
    write_fastfile
    security_with_password unlock-keychain -p @PW@ "$KC"
    (cd "$S" && fastlane devapp 2>&1) | grep -v -E "^\s*$|^[|+]" \
      | sed -E 's/[A-Z0-9]{10}/XXXXXXXXXX/g; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/UUID/g; s/[0-9A-F]{8}-[0-9A-F]{16}/UDID/g; s/[0-9a-f]{40}/UDID/g' \
      | tail -40
    PROFILE="$S/$DEVAPP_PROFILE_NAME.mobileprovision"
    test -s "$PROFILE" || { echo "no Dev app profile was written" >&2; exit 1; }
    install_profile "$PROFILE"
    write_signing_xcconfig
    # Names, the bundle id without the team prefix, counts and dates; no identifiers.
    security cms -D -i "$PROFILE" 2>/dev/null > "$S/devapp.tmp.plist"
    /usr/bin/python3 - "$S/devapp.tmp.plist" "$S/udid" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
udid = open(sys.argv[2]).read().strip().lower()
appid = p["Entitlements"]["application-identifier"].split(".", 1)[1]
devices = [d.lower() for d in p.get("ProvisionedDevices", [])]
print("profile %s: app %s, %d device(s), the phone in it: %s, %d certificate(s), expires %s"
      % (p["Name"], appid, len(devices), udid in devices, len(p.get("DeveloperCertificates", [])),
         p["ExpirationDate"].date()))
PY
    rm -f "$S/devapp.tmp.plist"
    echo "Dev app profile installed; App/Signing.xcconfig written (Debug: $DEVAPP_PROFILE_NAME)"
    ;;

  verify)
    security_with_password unlock-keychain -p @PW@ "$KC"
    echo "identities in our keychain: $(security find-identity -v -p codesigning "$KC" | grep -c 'Apple Development')"
    cp /usr/bin/true /tmp/ios-mosh-sign-test
    HASH="$(security find-identity -v -p codesigning "$KC" | awk '/Apple Development/{print $2; exit}')"
    if codesign -f -s "$HASH" --keychain "$KC" /tmp/ios-mosh-sign-test 2>&1 | sed -E 's/[A-Z0-9]{10}/XXXXXXXXXX/g'; then
      echo "codesign works over SSH"
    fi
    rm -f /tmp/ios-mosh-sign-test
    ;;

  *)
    echo "usage: $0 prep|apple|devapp|verify" >&2
    exit 2
    ;;
esac
