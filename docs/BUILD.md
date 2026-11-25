# Building and installing

> Addresses, ports and details of the author's own network were removed before publication.

The tree is edited and core-tested on `yellow`, synced to the Mac `charlie`, built
there with `xcodebuild` and installed on the phone with `devicectl` (Debug) or
uploaded to TestFlight with fastlane (Release). No GitHub Actions. `docs/PLAN.md`
section 7 has the design; this file records what is actually set up and what was
found different.

## Two apps

Since 2026-11-21 the two configurations are two separate apps (Trick's decision: a
debug install had replaced his TestFlight app, and the other way round).

| | Dev app (Debug) | TestFlight app (Release) |
|---|---|---|
| Name on the phone | iOS-mosh Dev | iOS-mosh |
| Bundle id | `us.v9n.ios-mosh.dev` | `us.v9n.ios-mosh` |
| Built by | `scripts/sim-test.sh` (simulator), `scripts/mac-deploy.sh build` / `scripts/deploy.sh` (phone) | `scripts/mac-testflight.sh archive\|beta`, `scripts/deploy.sh --testflight` |
| Reaches the phone | `devicectl` install | TestFlight, installed by Trick |
| Profile | `ios-mosh-dev-app` (development) | `ios-mosh-appstore` (App Store) |
| Debug hooks | smoke self-test, `-debugMosh*` launches, "Crash now" | none |

- They sit side by side on the phone and share nothing: each has its own data
  container (hosts, settings, session records), its own Keychain items (the SSH
  device key, session keys) and so its own public key to install on a host. There is
  no app group and no shared keychain group; neither target has an entitlements file,
  so each app's Keychain is its own application identifier.
- A new Dev app starts empty: no hosts, a new device key. A test host must be added
  to it and its key installed there ("Install my key"), separately from the key of
  the TestFlight app.
- Both declare `ITSAppUsesNonExemptEncryption` = NO (Trick's export compliance
  answer to Apple), so a TestFlight upload asks no compliance question.
- `App/project.yml` sets `PRODUCT_BUNDLE_IDENTIFIER` and `IOSMOSH_DISPLAY_NAME`
  (read by `CFBundleDisplayName`) per configuration. The unit and UI tests run
  against the Debug app on the simulator (their own ids `us.v9n.ios-mosh.tests` and
  `.uitests` are unchanged). Scripts that address the installed or simulated app by
  id (`mac-deploy.sh`, `mosh-spawner.py --bundle-id`, `sim-test.sh`) use the Dev id;
  `App/fastlane/Fastfile` keeps `us.v9n.ios-mosh`.

## Commands (run on yellow)

| Command | Does |
|---|---|
| `scripts/mac.sh CMD…` | Writes `App/Version.xcconfig`, rsyncs the tree to `charlie:~/ios-mosh-build`, runs `CMD` there with Homebrew on `PATH`, a UTF-8 locale and `caffeinate` |
| `scripts/mac.sh --no-sync CMD…` | Same without the sync |
| `scripts/mac.sh --ssh 'raw command'` | Raw command on the Mac, no `cd` |
| `scripts/mac.sh swift test` | Package tests on macOS |
| `scripts/mac.sh scripts/sim-test.sh [-only-testing:…]` | App unit and UI tests on a simulator, with `scripts/mosh-spawner.py --sshd` running for the UI tests (URL passed as `MOSH_SPAWNER_URL`; `--sshd` adds a throwaway `sshd` on 127.0.0.1 for the SSH bootstrap test). Results in `charlie:~/ios-mosh-out/` (`build.log`, `test.log`, `spawner.log`, `result.xcresult`, `attachments/`; for each UI test that failed in `ResumeUITests` or `KeyBarUITests`, `diagnostics/<Class>.<test>-<time>/` with the app's `debug.log`, its session records, the marks, its processes (pid, start time and program path, never a command line: the app's arguments hold its session key) and `lsof` of the records, saved at the failure; at the end a key check deletes any file in `diagnostics/` or `attachments/` that holds a session key the spawner handed out or a `-debugMoshKey` value, names it and fails the run; `result.xcresult` records the launch arguments, so it holds the run's throwaway keys and stays on the Mac) |
| `scripts/deploy.sh [--wait] [--launch] [--smoke] [--no-build]` | Device build, install, optional launch or phone self-test. Results in `out/phone/` |
| `scripts/deploy.sh --logs` | Pulls the app's `debug.log` and `smoke.json` off the phone |
| `scripts/smoke-host.sh up\|down\|status` | Throwaway `sshd` + UDP echo container for the phone self-test, published on yellow's Tailscale address only |

SSH to charlie uses `~/.ssh/ios-mosh-charlie` when it exists. Otherwise the scripts
borrow a running agent through a local helper of his that finds a running ssh-agent
(its path is `SSH_AGENT_FINDER` in the untracked `scripts/mac.env`), which only works
while Trick has a login session with a forwarded agent on yellow.

## charlie as found (2026-11-12)

- macOS 26, Apple silicon, Xcode 27.2 (Swift 6.4.2), iOS SDK 27.2. The only
  simulator runtime is iOS 26.5, which is enough (deployment target 18.0).
- Homebrew has `xcodegen`, `mosh`, `rsync` (installed for this project; macOS ships
  openrsync). `fastlane` is not installed and is only needed for the API-key
  signing route.
- Derived data: `~/ios-mosh-dd`. Outputs: `~/ios-mosh-out`. Signing material:
  `~/signing` (mode 700): `udid` (the phone's hardware UDID), and either an API key
  or `login.pass`.
- Phone: iPhone 16, iOS 27, already paired with charlie, Developer Mode on. It is
  reachable over Wi-Fi (`transportType: localNetwork`) without the cable.

## Things that went wrong, and the fix

- **After an Xcode update nothing simulator- or device-related works** until
  `sudo xcodebuild -runFirstLaunch` has run. Symptoms: `xcodebuild
  -checkFirstLaunchStatus` exits 69, `devicectl` and `simctl` print "Install Failed:
  Authorization is required to install the packages", and `xcodebuild` says
  "CoreSimulator is out of date" and offers only "My Mac" as a destination. Only
  Trick can run the `sudo` line.
- **The login keychain is locked in SSH sessions.** `codesign` fails with
  `errSecInternalComponent` even though `security find-identity` lists the Apple
  Development identity. Signing needs either a keychain of our own (API-key route)
  or the login keychain unlocked in the same SSH command.
- **The remote shell is zsh.** Unquoted `$var` is not word-split and `====` is an
  error. Anything longer than a line goes into a script that starts with
  `#!/bin/bash`, as `scripts/sim-test.sh` and `scripts/mac-deploy.sh` do.
- **SwiftTerm 1.99.3 has the 2.0 API.** `TerminalView.getTerminal()` is gone. Read
  with `terminalDimensions`, `visibleRowsText(_:)`, `terminalStateSnapshot()`; write
  with `feed(byteArray:)`, `pasteText(_:)`. See
  `Sources/SwiftTerm/Documentation.docc/MigratingFrom1To2.md` in the SwiftTerm repo.
  `HeadlessTerminal` and `Terminal` are still public for tests.
- **XCUITest waited 60 s before the first keystroke** ("App animations complete
  notification not received"). UI-test launches (`-uiTesting 1`) now switch
  animations off in `SceneDelegate`; the test went from 65 s to 4 s.
- **UI tests reach Mac services at 127.0.0.1.** The simulator shares the Mac's
  network. Environment for the test runner goes through xcodebuild as
  `TEST_RUNNER_FOO` (seen by the tests as `FOO`). The spawner client in
  `SessionUITests.swift` uses a plain socket rather than URLSession, so App
  Transport Security never applies to it.
- **A throwaway sshd needs no root.** `/usr/sbin/sshd -D -e -f <own config>` runs as
  the current user with `UsePAM no`, `StrictModes no`, its own host key, `PidFile`
  and an absolute `AuthorizedKeysFile` in a temporary directory (it logs one harmless
  "BSM audit ... Operation not permitted" line per login). It can only log in the
  user it runs as. `scripts/mosh-spawner.py --sshd` does this for the UI tests; the
  device key reaches its `authorized_keys` through `/sshd/authorize`, never a real one.
- **UI tests: an empty text field reads as its placeholder.** `XCUIElement.value` of
  an empty `UITextField` is the placeholder, so "22" in a field whose placeholder is
  "22" looks empty. The tests clear a field with its own clear button
  (`clearButtonMode .whileEditing`) and then poll until the value is the typed text.
- Simulator tests run fine from a plain SSH session while Trick is logged in at the
  screen. No LaunchAgent was needed.

## Signing

Set up on 2026-11-12 with an App Store Connect Team API key that Trick placed in
`charlie:~/signing/` (key file and `issuer.txt`). Nothing in that directory is
printed, committed or copied off the Mac.

- `scripts/mac-signing-setup.sh prep|apple|verify` did the one-time work: fastlane,
  a keychain of our own (`~/Library/Keychains/ios-mosh.keychain-db`, password in
  `~/signing/kc.pass`), the App ID `us.v9n.ios-mosh`, a development certificate
  whose private key is in that keychain, and the profile `ios-mosh-dev`.
- Trick's own identities in the login keychain are not used. The API-made
  certificates show up in the developer portal as "Created via API".
- `App/Signing.xcconfig` (on charlie only) holds the team, the profile names and
  the `--keychain` flag. The identity names are in `App/project.yml`, per
  configuration and for the device SDK only: XcodeGen's target preset sets
  `CODE_SIGN_IDENTITY`, and a target setting beats an xcconfig.
- Every build unlocks the keychain in the same SSH command. The password reaches
  `security` on stdin (`security -i`), not in argv.
- `scripts/mac.sh scripts/mac-signing-setup.sh devapp` (2026-11-21) made the App ID
  `us.v9n.ios-mosh.dev` (name "IOSMoshDev") and its development profile
  `ios-mosh-dev-app` with the existing development certificate (`~/signing/cert_id`)
  and the registered phone, installed it beside the others and rewrote
  `App/Signing.xcconfig`: Debug device builds use `ios-mosh-dev-app`, Release keeps
  `ios-mosh-appstore`. It creates no certificate and uses no `force`, so a re-run
  says "App ID ... exists" and downloads the same profile. The profile lasts until
  2027-11-21. To renew it (or to add a device), delete that profile in the portal
  first or the re-run keeps the old one.
- The first development profile `ios-mosh-dev` (for `us.v9n.ios-mosh`, made
  2026-11-12 by the `apple` step) is no longer used by any build. It is left in the
  account and in `~/signing`. Do not re-run `apple` for the Dev app: it is the setup
  of the old id (and renews `ios-mosh-dev` with `force`).

## Phone

- Everything here is the Dev app "iOS-mosh Dev" (`us.v9n.ios-mosh.dev`): install,
  launch, `pull` and the self-test act on it and leave the TestFlight app beside it
  alone. The first install of the Dev app (from 2026-11-21) lands as a new icon with
  an empty host list; the earlier debug installs had the TestFlight id.
- `scripts/deploy.sh --wait --smoke` took 32 s end to end on 2026-11-12: build,
  install over Wi-Fi, launch with environment variables, TCP and UDP to the smoke
  container, `smoke.json` and a screenshot copied back to `out/phone/`.
- Environment variables given with `--environment-variables` do reach the app.
- `devicectl device capture screenshot` works, so the phone's screen can be checked
  from yellow.
- On charlie without a smoke host: `scripts/phone-selftest.sh` launches the installed app
  once with `SMOKE_RUN_ID` and prints the device part of `smoke.json` (`DeviceProbe`: record
  file protection, backup exclusion, Keychain class, cost of a save); `--locked` adds a save
  with the phone locked, `--show` reads the result again.
- A locked or sleeping phone drops off Wi-Fi: install fails with "Transport error
  ... Operation timed out". Use `--wait`, which polls until the phone is paired,
  reachable and unlocked.

## TestFlight

`scripts/deploy.sh --testflight` archives a Release build on charlie, uploads it, waits
until Apple has processed it and sets its "What to Test" text, with
`App/fastlane/Fastfile` (lanes `signing_dist`, `archive`, `beta`, `testers`, `record`).
An upload needs Trick's word (`CLAUDE.md`).

**Making a release** (since 0.2, 2026-11-23):

1. **The version.** `MARKETING_VERSION` in `App/Local.xcconfig` is the only place it is
   set; Debug and Release read it, so the Dev app shows the same version. Bump it for
   every upload (Trick: "bump the version appropriately"). `scripts/mac.sh` no longer
   writes it; it writes only the build number and the SHA into `App/Version.xcconfig`.
2. **The build number** is the commit count (`CURRENT_PROJECT_VERSION` in
   `App/Version.xcconfig`), or one above the newest upload of the same version if that is
   higher. 0.1 was 189; 0.2 gets the count of the commit it is built from.
3. **The changelog.** `CHANGELOG.md` at the top of the repository gets a section
   `## <version> (<date>)` before the upload, in plain words for a user. That section is
   the build's "What to Test": the lane cuts it out (up to the next `## `) and stops if
   it is missing, over 4000 bytes or holds a `<`. One line per item inside a section
   (TestFlight shows line breaks as they are); no emoji (pilot strips them).
4. **Commit and push**, then from yellow: `scripts/deploy.sh --testflight` (the same as
   `scripts/mac.sh scripts/mac-testflight.sh beta`). It archives, uploads, then waits for
   Apple's processing (polls every 60 s, gives up after 90 minutes with an error; the
   upload is then done and the text can be set by hand in App Store Connect), then sets
   "What to Test" on that build. It runs for as long as the processing takes, so start
   it in the background with its output to a file. `pilot` runs with
   `skip_submission: true` and `distribute_external: false`: after the text it stops, so
   nothing is submitted for review, no group or tester is made or changed, and nothing
   goes to external testers. The internal group "Internal" has access to all builds, so
   its testers get the build once it is processed.
5. **Check without uploading:** `scripts/mac.sh scripts/mac-testflight.sh archive`
   makes the Release archive and ipa only (`~/ios-mosh-out/testflight/`) and prints
   "What to Test for <version>: <n> bytes from CHANGELOG.md", which proves the section
   is there.

What reaches the terminal is a filtered, masked part of fastlane's log; the whole log
stays on charlie (`~/ios-mosh-out/testflight/fastlane-<stage>.log`). A count on
2026-11-23 found no API key id, issuer, keychain password, team id or phone id in the
fastlane logs; xcodebuild's own log there (`IOSMosh-IOSMoshDevice.log`) names the team
id in its signing lines, as every device build does: it is not printed or copied.

- One-time, done: distribution certificate in our keychain and the App Store
  profile `ios-mosh-appstore` (`scripts/mac.sh scripts/mac-testflight.sh signing`).
  This took the team's third and last distribution certificate slot.
- One-time, only a person can do it: the app record. Apple's API answers "The
  resource 'apps' does not allow 'CREATE'". App Store Connect > Apps > + > New App:
  platform iOS, any free name, English (U.S.), bundle id `us.v9n.ios-mosh`, SKU
  `ios-mosh`.
- One-time, after the record exists: `scripts/mac.sh scripts/mac-testflight.sh
  testers` makes the internal group "Internal" with access to all builds and adds
  the account holder.
- `xcodebuild -exportArchive` fails with "Copy failed" when Homebrew's rsync is
  first in `PATH`; `scripts/mac-testflight.sh` puts the system tools first.
- TestFlight builds are Release builds of `us.v9n.ios-mosh`: no smoke hooks, no
  "Crash now". The Dev app through `devicectl` stays the fast loop and never touches
  the TestFlight app (section "Two apps").
- Uploads so far: 0.1 (189), 2026-11-21, without waiting for processing and with no
  "What to Test" (`docs/CLOUD.md`, 2026-11-21 03:45 UTC); then 0.2 (229) and 0.2.1 (237),
  each with its changelog (`CHANGELOG.md`).
