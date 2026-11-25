# charlie pipeline facts (devicectl, signing)

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## results

### 1. item

**key:** device-install

#### r

##### facts

###### 1. item

###### claim

On iOS 18/26 the first pairing needs a cable: `devicectl manage pair` pairs cable-connected devices from Terminal without Xcode running, with the phone unlocked and Trust tapped; wireless iPhone pairing needs iOS 27 plus the Device Hub GUI.

**confidence:** high

###### source

https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line ; https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub

###### 2. item

###### claim

Developer Mode only appears in Settings > Privacy & Security once pairing has been initiated; it needs the toggle, Restart, then Enable plus passcode after reboot, and Apple's devmodectl can only auto-enable it on passcode-less devices.

**confidence:** high

###### source

https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device ; https://developer.apple.com/videos/play/wwdc2022/110344/

###### 3. After cable pairing the cable can be removed and the phone is reachable over Wi-Fi with IPv6 on the same network as the Mac.

**claim:** After cable pairing the cable can be removed and the phone is reachable over Wi-Fi with IPv6 on the same network as the Mac.

**confidence:** high

**source:** https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub

###### 4. item

###### claim

CoreDevice does not reach the phone over Tailscale natively: discovery is Bonjour (_remotepairing._tcp) and remotepairingd binds to the discovering interface, so it shows unavailable; only Bonjour-spoof plus relay hacks work.

**confidence:** medium

**source:** https://dev.to/kvnpt/how-to-remotely-iterate-deploy-your-sideloaded-ios-apps-over-tailnet-jak ; https://github.com/saimskywalker/RoamRun

###### 5. item

###### claim

Apple says to unlock the device before devicectl commands; launching on a locked phone fails with FBSOpenApplicationErrorDomain error 7 (BSErrorCodeDescription = Locked).

**confidence:** medium

###### source

https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line ; https://github.com/appandflow/stim/pull/1020

###### 6. item

###### claim

Whether install succeeds on a locked or sleeping phone is unconfirmed; idle Wi-Fi devices list tunnelState disconnected, installs have succeeded from that state, and others failed with CoreDeviceError 4000 until retried.

**confidence:** low

**source:** https://github.com/appandflow/stim/pull/1020 ; https://github.com/tophatch/swift-pwa/issues/260

###### 7. item

###### claim

`devicectl device install app` is reported working from a plain SSH session with a GUI user apparently logged in; nothing found confirms it with nobody logged in at the Mac console.

**confidence:** low

**source:** https://www.cwfrazier.com/blog/shipping-an-ios-build-headlessly-over-ssh ; https://github.com/bogusyogi/rightkit/issues/1228

###### 8. item

###### claim

Over SSH codesign fails with errSecInternalComponent because the login keychain is locked; Apple DTS says to run `security unlock-keychain` (plus set-key-partition-list for imported keys) in that session.

**confidence:** high

**source:** https://developer.apple.com/forums/thread/712005

###### 9. item

###### claim

xcodebuild takes -allowProvisioningUpdates -allowProvisioningDeviceRegistration with -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID to use an API key instead of an Xcode account; provisioning needs a Team key, and headless reliability is mixed in forum reports.

**confidence:** medium

###### source

https://keith.github.io/xcode-man-pages/xcodebuild.1.html ; https://docs.fastlane.tools/app-store-connect-api/ ; https://developer.apple.com/forums/thread/764554

###### 10. item

###### claim

`devicectl device process launch --console` (Xcode 16+) captures the app's stdout/stderr and waits for exit; appDataContainer file commands take the bundle ID as --domain-identifier.

**confidence:** high

###### source

https://developer.apple.com/forums/thread/756393 ; https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line

###### 11. item

###### claim

`xcodebuild test -destination 'id=<hardware UDID>'` against the phone from SSH is unconfirmed; it should need the same keychain unlock and provisioning flags as a build.

**confidence:** low

**source:** https://keith.github.io/xcode-man-pages/xcodebuild.1.html ; https://developer.apple.com/forums/thread/765060

###### 12. item

###### claim

On the phone XCUITest needs Developer Mode, Settings > Developer > Enable UI Automation, an unlocked screen, and a recurring passcode prompt that Apple says cannot be automated.

**confidence:** medium

**source:** https://appium.github.io/appium-xcuitest-driver/latest/getting-started/device-setup/ ; https://developer.apple.com/forums/thread/709275

##### recommended_recipe

# NOT RUN. One ssh invocation on charlie; project/scheme/paths are placeholders; $P8 absolute
security unlock-keychain -p "$KEYCHAIN_PW" ~/Library/Keychains/login.keychain-db
xcrun devicectl list devices
xcodebuild -project ios-mosh.xcodeproj -scheme ios-mosh -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$P8" -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" build
xcrun devicectl device info details --device "$UDID"   # wakes idle tunnel
xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/ios-mosh.app
xcrun devicectl device process launch --device "$UDID" --console --terminate-existing us.v9n.ios-mosh
xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier us.v9n.ios-mosh
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
  --domain-identifier us.v9n.ios-mosh --source Documents/app.log --destination ./app.log
# XCUITest: same xcodebuild flags with action "test" instead of "build"

##### human_setup_steps

- Once: plug the iPhone into charlie by USB, unlock it, tap Trust and enter the passcode (the agent can run `xcrun devicectl manage pair` over SSH meanwhile).
- On the iPhone: Settings > Privacy & Security > Developer Mode on, tap Restart, then Enable and enter the passcode after reboot.
- Keep a user logged in at charlie's console with Remote Login on (need unconfirmed), and give the agent the login-keychain password or a dedicated build keychain.
- Put the Team API key .p8, key ID and issuer ID on charlie.
- Keep the phone on the same Wi-Fi as charlie, awake and unlocked whenever the agent installs or launches.
- For XCUITest: turn on Settings > Developer > Enable UI Automation and enter the passcode when prompted.

##### risks

- Nothing here was run, and no source confirms devicectl from SSH with no console user logged in; test `xcrun devicectl list devices` over SSH first.
- Off-LAN or Tailscale use depends on unsupported relay hacks over private protocols; two community reports say a phone reboot may need a brief USB reconnect.
- A locked phone blocks launch and idle Wi-Fi tunnels cause intermittent install failures; wake with a cheap devicectl call and retry.
- API-key automatic signing may fail headless ('No Accounts', profile/certificate mismatch) and the required key role is unconfirmed; fallback is manual signing via fastlane match or cert+sigh.
- `devicectl device copy from` reportedly fails on directories, so copy file by file; `--terminate-existing` is from community usage, not Apple docs.
- Could not confirm that a paid-team development build skips the on-device 'trust developer' step, or behaviour differences in Xcode 26/27.

### 2. item

**key:** headless-signing

#### r

##### facts

###### 1. item

###### claim

Xcode 13+ xcodebuild accepts an App Store Connect API key for headless automatic signing; -allowProvisioningUpdates creates profiles, app IDs and certificates, -allowProvisioningDeviceRegistration registers the destination device.

**confidence:** high

**source:** https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes ; man xcodebuild

###### 2. Cloud-managed certificates are distribution-only, so development signing always needs a private key in a keychain on the Mac.

**claim:** Cloud-managed certificates are distribution-only, so development signing always needs a private key in a keychain on the Mac.

**confidence:** high

**source:** https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes

###### 3. Individual API keys cannot use provisioning endpoints; certificates, devices and profiles need a Team key.

**claim:** Individual API keys cannot use provisioning endpoints; certificates, devices and profiles need a Team key.

**confidence:** high

**source:** https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api

###### 4. item

###### claim

Apple's role table: Admin has full rights over development certificates, profiles, App IDs and UDIDs; App Manager needs added Certificates, Identifiers & Profiles access; Developer gets profiles, App IDs and UDIDs only through Xcode automatic signing.

**confidence:** high

**source:** https://developer.apple.com/help/account/access/roles/

###### 5. item

###### claim

How roles map onto API keys is anecdotal and conflicting (forum: Admin needed; Codemagic: App Manager; Bitrise: Developer for development builds); Admin is the safe choice.

**confidence:** low

**source:** https://developer.apple.com/forums/thread/690676 ; docs.codemagic.io ; docs.bitrise.io

###### 6. item

###### claim

SSH login does not unlock keychains, so codesign fails with errSecInternalComponent; unlocking (security unlock-keychain) and key access (set-key-partition-list) are separate requirements.

**confidence:** high

**source:** https://developer.apple.com/forums/thread/712005

###### 7. item

###### claim

A dedicated keychain has its own password, so unlocking it from a password file never needs the Mac login password; fastlane cert imports into keychain_path and sets the partition list.

**confidence:** medium

**source:** man security ; fastlane cert/keychain_importer source (github.com/fastlane/fastlane)

###### 8. item

###### claim

Automatic signing keeps its development private key in the user's keychain (reportedly the default login keychain), which stays locked over SSH and after reboot until unlocked with the login password.

**confidence:** low

**source:** Xcode Help 'signing certificate' plus secondary reports; exact keychain not confirmed by Apple

###### 9. item

###### claim

xcodebuild with an API key is reported to mint 'Created via API' certificates, then fail with 'private key is not installed in your keychain' when that key is not visible.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/695759

###### 10. item

###### claim

An Apple ID signed into Xcode needs re-authentication 'from time to time' (Apple DTS); SSH builds are reported failing with 'Your session has expired'.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/764554 ; https://developer.apple.com/forums/thread/713606

###### 11. Apple DTS knows of no limit on Apple Development certificates in a paid team; Apple Distribution and Developer ID certificates are capped.

**claim:** Apple DTS knows of no limit on Apple Development certificates in a paid team; Apple Distribution and Developer ID certificates are capped.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/792610

###### 12. item

###### claim

fastlane cert, sigh and register_devices accept api_key_path; produce does not, so the App ID must already exist or be created through the API.

**confidence:** high

**source:** https://docs.fastlane.tools/app-store-connect-api/

##### recommended_recipe

# Route (b): fastlane + dedicated keychain + manual signing. On charlie over SSH; set S, KC, UDID, TEAMID in every session.
S=$HOME/signing; KC=$HOME/Library/Keychains/agent.keychain-db
openssl rand -hex 24 > $S/kc.pass; chmod 600 $S/kc.pass $S/asc.json
security create-keychain -p "$(cat $S/kc.pass)" "$KC"
security set-keychain-settings "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security unlock-keychain -p "$(cat $S/kc.pass)" "$KC"
fastlane run cert development:true api_key_path:$S/asc.json keychain_path:"$KC" keychain_password:"$(cat $S/kc.pass)" output_path:$S
xcrun xctrace list devices   # note iPhone UDID
printf 'Device ID\tDevice Name\tDevice Platform\n%s\tiPhone\tios\n' "$UDID" > $S/devices.txt
fastlane run register_devices devices_file:$S/devices.txt api_key_path:$S/asc.json
fastlane run sigh development:true force:true app_identifier:us.v9n.ios-mosh provisioning_name:ios-mosh-dev api_key_path:$S/asc.json output_path:$S
# every build, in ONE ssh invocation (unlock reportedly does not persist across separate ssh commands):
security unlock-keychain -p "$(cat $S/kc.pass)" "$KC" &&
xcodebuild -scheme ios-mosh -configuration Debug -destination generic/platform=iOS -derivedDataPath build CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAMID CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER=ios-mosh-dev OTHER_CODE_SIGN_FLAGS="--keychain $KC" build &&
xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/ios-mosh.app

##### human_setup_steps

- Put a Team API key with Admin role on charlie as ~/signing/asc.json (key_id, issuer_id, key); reuse the GitHub Actions key only if it is a Team key and the .p8 was kept.
- Cable the iPhone to charlie, tap Trust and enter the passcode (the agent can start pairing with xcrun devicectl manage pair).
- On the iPhone turn on Settings > Privacy & Security > Developer Mode, restart, confirm; the switch appears only once pairing has started.
- Keep the iPhone unlocked and connected during installs.
- Confirm Xcode's licence is accepted and the iOS platform is installed; the agent installs fastlane (2.230+ for Xcode 16 profile paths).
- After a Mac reboot with FileVault on, unlock the disk; macOS 26 on Apple silicon allows this over SSH.

##### risks

- Nothing was run on a Mac: devicectl over SSH with no GUI session, and xcodebuild finding the identity in a custom keychain, are unverified.
- A weaker key role returns 403 on certificates, profiles or devices; behaviour for individual (non-organisation) enrolments is unconfirmed.
- Command-line signing settings apply to every target; with Swift packages or extensions set them on the app target instead.
- The password file, .p8 and the private key fastlane leaves in output_path sit on charlie's disk; anyone with that account can sign as the team.
- If the App ID is missing sigh fails; register it in the portal or POST /v1/bundleIds (Spaceship::ConnectAPI::BundleId.create, untested).
- Route (a) is the fallback but probably needs the Mac login password to unlock the login keychain and can accumulate certificates.

### 3. item

**key:** sim-tests-ssh

#### r

##### facts

###### 1. item

###### claim

Apple's testing guide says Simulator tests need an Aqua session; an SSH login gets one only while a user is logged in to the Mac's GUI, after which xcodebuild over SSH 'works for all types of tests'.

**confidence:** high

**source:** https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/08-automation.html

###### 2. item

###### claim

Apple DTS (Oct 2024) said the session rules are unchanged, could not confirm xcodebuild UI tests are reliable over SSH, and advised starting from a LaunchAgent bootstrapped into gui/<UID>; `launchctl asuser` is unverified for this.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/765060

###### 3. item

###### claim

Buildkite requires GUI auto-login plus a LaunchAgent for Xcode and Simulator; Apple says automatic login is unavailable with FileVault on; a locked screen reportedly keeps the GUI session alive.

**confidence:** medium

###### source

https://buildkite.com/docs/agent/self-hosted/aws/self-serve-install/ec2-mac ; https://support.apple.com/en-us/102316 ; https://aahlenst.dev/blog/accessing-the-macos-gui-in-automation-contexts/

###### 4. item

###### claim

Reported SSH failures: 'com.apple.testmanagerd.control was invalidated ... No such process' and 'Failed to install or launch the test runner (Underlying Error: Invalid device state)'; one cause was Rosetta, fixed with `arch -arm64 xcodebuild`.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/727333 ; https://developer.apple.com/forums/thread/663228

###### 5. item

###### claim

`xcrun simctl io <udid> screenshot f.png` captures a booted simulator unless FramebufferServerRendererPolicy is 'none' (Xcode 11 release note); I found no source confirming it specifically over SSH.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/125778 ; https://nshipster.com/simctl/

###### 6. item

###### claim

Current xcresulttool has `export attachments --path X.xcresult --output-path DIR [--test-id] [--only-failures]` and `get test-results summary|tests`; attachments survive passing tests only with XCTAttachment lifetime `.keepAlways`.

**confidence:** high

###### source

https://keith.github.io/xcode-man-pages/xcresulttool.1.html ; https://developer.apple.com/documentation/xctest/xctattachment/lifetime-swift.enum

###### 7. item

###### claim

`xcodebuild -license accept` 'must be run as a privileged user'; `-runFirstLaunch` installs system components and agrees to the license; Apple shows it without sudo, community guides use sudo, and non-sudo behaviour over SSH is unconfirmed.

**confidence:** medium

###### source

https://keith.github.io/xcode-man-pages/xcodebuild.1.html ; https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components

###### 8. item

###### claim

`xcodebuild -downloadPlatform iOS [-buildVersion 18.0]` downloads and installs a simulator runtime of several GB; one community guide says it needs no sudo.

**confidence:** medium

###### source

https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components ; https://mehmetbaykar.com/posts/how-to-install-simulator-runtimes-via-terminal/

###### 9. item

###### claim

Homebrew's initial install needs elevated rights (NONINTERACTIVE=1 only suppresses prompts); afterwards formula installs such as `brew install xcodegen mosh` need no sudo; the Apple silicon prefix is /opt/homebrew.

**confidence:** medium

**source:** https://docs.brew.sh/Installation

###### 10. item

###### claim

`caffeinate -i` prevents idle sleep and `-s` system sleep on AC power only; pmset changes need root; lid-close sleep reportedly ignores caffeinate, and `pmset disablesleep` is undocumented.

**confidence:** medium

**source:** https://ss64.com/mac/caffeinate.html ; https://www.dssw.co.uk/reference/pmset/

###### 11. item

###### claim

Tailscale cannot wake a sleeping device; Wake-on-LAN (`womp`, 'Wake for network access') needs a magic packet from an always-on machine on the same LAN, preferably over Ethernet.

**confidence:** medium

**source:** https://tailscale.com/blog/wake-on-lan-tailscale-upsnap ; https://support.apple.com/guide/mac-help/mh27905

###### 12. item

###### claim

Apple DTS showed a simulator app's request to http://localhost:8081 arriving at `nc -l 8081` on the Mac, so 127.0.0.1 TCP works; UDP for mosh is inferred, not confirmed.

**confidence:** medium

**source:** https://developer.apple.com/forums/thread/762849

##### recommended_recipe

# Untested: no Mac was available. "App" is a placeholder scheme name.
# One-time; sudo needs the owner's password (ssh -t)
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
/opt/homebrew/bin/brew install xcodegen mosh
# Every session, plain SSH
export PATH=/opt/homebrew/bin:$PATH
[ "$(stat -f %Su /dev/console)" = "$USER" ] || echo "no GUI login: stop"
nohup caffeinate -is -t 14400 >/dev/null 2>&1 &
UDID=$(xcrun simctl list devices available | grep -m1 iPhone | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b
xcodegen generate
xcodebuild build-for-testing -scheme App -destination "id=$UDID" -derivedDataPath build
rm -rf out/run.xcresult
xcodebuild test-without-building -scheme App -destination "id=$UDID" -derivedDataPath build -resultBundlePath out/run.xcresult
xcrun simctl io "$UDID" screenshot out/screen.png
xcrun xcresulttool get test-results summary --path out/run.xcresult
xcrun xcresulttool export attachments --path out/run.xcresult --output-path out/attachments
# Fallback if SSH-run tests fail: run the same script from a LaunchAgent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/us.v9n.xctest.plist

##### human_setup_steps

- Log in at charlie's screen as the SSH user after every reboot, or enable automatic login (requires FileVault off); locking the screen afterwards is fine.
- Enter the sudo password once for xcode-select, license accept and runFirstLaunch, or run those three yourself.
- Install Homebrew if it is missing (needs an admin password).
- Keep charlie on power with the lid open; set sleep to never on the power adapter and enable 'Wake for network access'.
- Wake it by hand if it sleeps, unless an always-on machine on the same LAN can send Wake-on-LAN.
- Watch the first test run on screen and dismiss any first-time prompts (unconfirmed whether any appear).

##### risks

- Apple DTS does not vouch for SSH-launched XCUITest on current Xcode; if it fails with testmanagerd or launchd_sim errors, the LaunchAgent route is the supported fallback.
- Any reboot or OS update logs the GUI user out, and simulator tests then fail until a human logs in; FileVault blocks auto-login.
- Closing a MacBook lid or running on battery lets it sleep despite caffeinate; once asleep it cannot be woken over Tailscale.
- An unanswered Xcode 26.6 forum report shows 'Failed to start launchd_sim: could not bind to session' with the iOS 26.5 runtime, with no SSH link confirmed; an older runtime was the only workaround.
- Not confirmed by any source: non-sudo runFirstLaunch over SSH, simctl screenshots over SSH, UDP loopback from the simulator, and the recipe's console-login check.
- The runtime download is several GB; non-interactive SSH shells lack /opt/homebrew/bin on PATH; -resultBundlePath errors if the path already exists.

