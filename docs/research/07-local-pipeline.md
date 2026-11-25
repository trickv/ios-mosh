# Research: local_pipeline

> Addresses, ports and details of the author's own network were removed before publication.

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

<the author's Cordova app> is a Cordova hybrid app (www/ JS + an Obj-C Cordova plugin), so its build steps don't carry over to a native Swift app. Its TestFlight job (release.yml job `ios-appstore`, branch `<a release branch>`; the copy read is 3 commits ahead of that branch) works like this. Runner is macos-15 with maxim-lobanov/setup-xcode 'latest-stable', which gave Xcode 26.3 on 2026-11-02. It imports the .p12 into a temporary keychain with `security`, copies the profile into place, and writes the .p8 key file. Then `bundle exec fastlane ios beta` runs update_code_signing_settings (manual signing), build_app (export_method app-store) and upload_to_testflight (API key, skip_waiting). The build number is github.run_number and the version is the tag with its suffix stripped. The steps take about 5 min in total, about 3.3 min of that in fastlane. The developer's own native-Swift repo <the author's Swift app> (XcodeGen, SPM, macos-26, release on a published GitHub Release, 8 secrets) is a better and newer template: copy it rather than <the author's Cordova app>. <the author's React Native app> (React Native) also contains docs/fastlane-testflight-guide.md, a step-by-step new-project setup guide. Seven Apple secrets are shared by the whole team and can be copied between repos. Only BUILD_PROVISION_PROFILE_BASE64 is specific to each app, plus the App ID and App Store Connect app record. GitHub secrets cannot be read back, so a new repo needs the original files. Local box: mosh-server 1.4.0, [sshd and firewall details removed for publication], Docker [release removed for publication] works (exit 0), i7-8700T with 12 threads, 15 GiB RAM, x86_64. Tailscale is up (<yellow's tailnet address>) and an iOS device `<the phone's tailnet name>` and a macOS host `charlie` are on the tailnet. So there probably is a Mac, which contradicts the 'no Mac' assumption.

## details

## 1. What <the author's Cordova app> is (what does not transfer)
- Cordova hybrid app: `cordova platform add ios`, `cordova plugin add plugin-src/<plugin>/ --nofetch`, `cordova prepare ios`. The Xcode project is generated into platforms/ios/<App>.xcworkspace. The native code is an Obj-C Cordova plugin (plugin-src/<plugin>/src/ios/*.m). Versions are injected by editing config.xml with node (`version=`, `ios-CFBundleVersion=`).
- Not transferable: Node, Cordova, CocoaPods, config.xml version editing, the package.json plugin-removal hack, and the AltStore unsigned IPA job (`zip Payload/`, altstore-source.json, `gh release create`).
- Transferable: the signing steps (keychain, profile, p8), the fastlane lane shape, the semver-stripping logic, and the job gate on a repository variable.

## 2. <the author's Cordova app> TestFlight job (release.yml, branch `<a release branch>`; the copy read, at `<a commit>`)
Triggers: `push: tags: ['v*']` and `workflow_dispatch` with input `version`. `permissions: contents: write`.
```yaml
ios-appstore:
  if: ${{ vars.IOS_BUNDLE_ID != '' }}   # secrets.* not allowed in job-level if:
  runs-on: macos-15
  steps:
  - uses: actions/checkout@v4
    with: { submodules: recursive }
  # App Store now requires iOS 26 SDK; macos-15 runners have Xcode 26 installed alongside older versions.
  - uses: maxim-lobanov/setup-xcode@v1
    with: { xcode-version: 'latest-stable' }
  - uses: ruby/setup-ruby@v1
    with: { ruby-version: '3.2', bundler-cache: true }
  - name: Import distribution certificate
    env: { BUILD_CERTIFICATE_BASE64, P12_PASSWORD, KEYCHAIN_PASSWORD }  # from secrets
    run: |
      CERT_PATH=$RUNNER_TEMP/certificate.p12
      KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
      echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o "$CERT_PATH"
      security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
      security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
      security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
      security import "$CERT_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
      security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
      security list-keychain -d user -s "$KEYCHAIN_PATH"
  - name: Install provisioning profile   # decode BUILD_PROVISION_PROFILE_BASE64 -> ~/Library/MobileDevice/Provisioning Profiles/profile.mobileprovision
  - name: Write App Store Connect API key  # ~/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8 ; echo ASC_API_KEY_PATH=... >> $GITHUB_ENV
  - name: Build & upload to TestFlight
    env: IOS_BUNDLE_ID, FASTLANE_APPLE_ID, APPLE_TEAM_ID, APPLE_CODE_SIGN_IDENTITY, APPLE_PROVISIONING_PROFILE_NAME, ASC_API_KEY_ID, ASC_API_ISSUER_ID
    run: bundle exec fastlane ios beta
  - name: Clean up keychain and profile   # if: always(); security delete-keychain; rm profile + AuthKey_*.p8
```
Version and build: `VERSION=${GITHUB_REF#refs/tags/}`, `VERSION_NUM=${VERSION#v}`. Then `cleanVersion = (VERSION_NUM.match(/^\d+(?:\.\d+){0,2}/) || ["1.0.0"])[0]`, so a release tag with a suffix after the version (`<a release tag>`) becomes the bare version. `IOS_CFBUNDLE_VERSION: ${{ github.run_number }}`.

fastlane/Fastfile `platform :ios / lane :beta`:
```ruby
api_key = app_store_connect_api_key(key_id: ENV["ASC_API_KEY_ID"], issuer_id: ENV["ASC_API_ISSUER_ID"], key_filepath: ENV["ASC_API_KEY_PATH"])
update_code_signing_settings(path: "./platforms/ios/<App>.xcodeproj", use_automatic_signing: false, team_id: team_id,
  code_sign_identity: code_sign_identity, profile_name: profile_name, bundle_identifier: bundle_id, targets: [IOS_SCHEME])
build_app(workspace: IOS_WORKSPACE, scheme: IOS_SCHEME, configuration: "Release", export_method: "app-store",
  export_options: { signingStyle: "manual", teamID: team_id, provisioningProfiles: { bundle_id => profile_name } })
upload_to_testflight(api_key: api_key, skip_waiting_for_build_processing: true, changelog: ENV["RELEASE_NOTES"] || "Bug fixes and improvements.")
```
The Appfile is driven by environment variables: `app_identifier(ENV["IOS_BUNDLE_ID"] || "<the upstream project's id>")`, apple_id and team_id are optional. The Gemfile contains only `gem "fastlane"`, and no Gemfile.lock is committed (bundler-cache resolves it). Run of 2026-11-02 used: image macos-15-arm64 20261028.0489.1, /Applications/Xcode_26.3.app, fastlane 2.241.2, Ruby 3.2.11.

### Secret names in <the author's Cordova app> (from `gh secret list`; names only)
iOS secrets:
- IOS_BUNDLE_ID: bundle id. It is also a repository variable, used as the job gate.
- FASTLANE_APPLE_ID: Apple ID email.
- APPLE_TEAM_ID: 10-character team id.
- APPLE_CODE_SIGN_IDENTITY: e.g. "Apple Distribution".
- APPLE_PROVISIONING_PROFILE_NAME: the profile's Name field.
- BUILD_CERTIFICATE_BASE64: distribution .p12, base64.
- P12_PASSWORD
- KEYCHAIN_PASSWORD: any random string.
- BUILD_PROVISION_PROFILE_BASE64: App Store .mobileprovision, base64.
- ASC_API_KEY_BASE64: .p8, base64.
- ASC_API_KEY_ID
- ASC_API_ISSUER_ID

Android secrets (not relevant here): ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD, ANDROID_PACKAGE_NAME, GOOGLE_PLAY_JSON_KEY_BASE64.

Repository variables: IOS_BUNDLE_ID and ANDROID_PACKAGE_NAME, both us.vanstaveren.<app>.

The other repos use 8 secrets: APPLE_TEAM_ID, ASC_API_ISSUER_ID, ASC_API_KEY_BASE64, ASC_API_KEY_ID, BUILD_CERTIFICATE_BASE64, BUILD_PROVISION_PROFILE_BASE64, KEYCHAIN_PASSWORD, P12_PASSWORD. <the author's Swift app> has exactly these 8. <the author's React Native app> and <another of the author's apps> have them plus Android secrets; <another of the author's apps> also has SENTRY_AUTH_TOKEN.

## 3. Better template: <the author's Swift app> (native Swift/SwiftUI, public repo)
Files:
- .github/workflows/release.yml
- .github/workflows/ios-build.yml
- fastlane/Fastfile and fastlane/Appfile
- Gemfile containing `gem "fastlane"` and `gem "multi_json"` (comment: "multi_json is not part of the bundle" failure seen on <another of the author's apps> 2026-06-05)
- ios/<App>/project.yml (XcodeGen; the .xcodeproj is gitignored: `ios/<App>/*.xcodeproj/`)
- docs/APP-STORE-RELEASE.md (1408 lines: one-time Portal and App Store Connect steps, secrets, troubleshooting)

release.yml essentials:
```yaml
on:
  release: { types: [published] }      # `git push --tags` alone does nothing
  workflow_dispatch: { inputs: { version: {required: true}, notes: {default: 'Manual build.'} } }
concurrency: { group: ios-release, cancel-in-progress: false }
jobs:
  ios-testflight:
    if: ${{ github.event_name == 'workflow_dispatch' || !contains(github.event.release.body, '[skip-ios]') }}
    runs-on: macos-26          # default Xcode 26.x, deliberately unpinned
    timeout-minutes: 60
    permissions: { contents: write }
    steps:
    - uses: actions/checkout@v4
      with: { fetch-depth: 0, persist-credentials: false }
    - run: xcodebuild -version; xcode-select -p; xcrun --sdk iphoneos --show-sdk-version   # "Show toolchain"
    - uses: ruby/setup-ruby@v1
      with: { ruby-version: '3.2', bundler-cache: true }
    - env: { HOMEBREW_NO_AUTO_UPDATE: '1' }
      run: brew install xcodegen
    - working-directory: ios/<App>
      run: xcodegen generate
    - name: Resolve version and build number   # VERSION from release tag_name or inputs.version, strip v,
      # validate ^[0-9]+(\.[0-9]+){0,2}$ else ::error; echo APP_VERSION / APP_BUILD=${GITHUB_RUN_NUMBER} >> $GITHUB_ENV
    - name: Import distribution certificate     # as <the author's Cordova app> but umask 077, -lut 3600, `-T /usr/bin/codesign -T /usr/bin/security` instead of -A, rm p12
    - name: Install provisioning profile        # copies to BOTH ~/Library/MobileDevice/Provisioning Profiles and ~/Library/Developer/Xcode/UserData/Provisioning Profiles;
      # preflight: security cms -D -i profile | PlistBuddy Print :Entitlements:<required entitlement> else ::error
    - name: Write App Store Connect API key
    - name: Compose TestFlight release notes    # RAW_NOTES via env (never inline ${{ }}); strip [skip-*]; random heredoc delimiter into RELEASE_NOTES
    - run: bundle exec fastlane ios beta        # env ASC_API_KEY_ID, ASC_API_ISSUER_ID, APPLE_TEAM_ID
    - name: Verify build outputs                # fail if no ./*.ipa
    - uses: softprops/action-gh-release@v2      # attach *.ipa, *.dSYM.zip (release events only)
    - uses: actions/upload-artifact@v4          # manual runs only
    - name: Clean up keychain, profile and API key  # if: always()
```
Fastfile lanes:
- `ios beta`: require_env!, then resolve_team_id!, resolve_version!, resolve_build_number!, preflight_release, app_store_connect_api_key, archive_ipa, then upload_to_testflight(api_key, app_identifier, ipa, skip_waiting_for_build_processing: true, changelog).
- `ios build`: signs locally without uploading.
- `preflight_release`: runs `xcodegen generate`, warns if `git status --porcelain --untracked-files=no` shows changes, hard-fails unless Info.plist has `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, warns if ITSAppUsesNonExemptEncryption is unset or AppIcon.appiconset is missing.
- `archive_ipa`: update_code_signing_settings(targets: [SCHEME]), then `build_app(project: xcodeproj_path, scheme:, configuration: "Release", export_method: "app-store", xcargs: {"MARKETING_VERSION"=>v, "CURRENT_PROJECT_VERSION"=>b}, export_options: {signingStyle: "manual", teamID:, manageAppVersionAndBuildNumber: false, provisioningProfiles: {APP_IDENTIFIER => PROFILE_NAME}}, output_directory: repo_root, output_name: "#{SCHEME}.ipa")`.
- The Fastfile comment says not to switch to "app-store-connect": gym's allow-list (fastlane 2.238.0) rejects it, even though Xcode 26.6+ prints a deprecation warning for "app-store".
- Constants: APP_IDENTIFIER "us.v9n.<app>", PROFILE_NAME "<app>", SCHEME "<App>".
- The Appfile has app_identifier and team_id, and no apple_id (API key only, so no 2FA prompts).

ios-build.yml (PRs and pushes to main or `claude/**`, paths `ios/**`):
- macos-26, timeout 30, concurrency cancel-in-progress.
- `brew install xcodegen`, `xcodegen generate`, then warns if the committed Info.plist differs.
- Picks a simulator: `xcrun simctl list devices available --json | jq -r '[.devices|to_entries[]|select(.key|test("iOS"))|.value[]|select(.name|startswith("iPhone"))]|last|.udid'`.
- Tests: `xcodebuild test -project X.xcodeproj -scheme X -configuration Debug -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath build -resultBundlePath $RUNNER_TEMP/X.xcresult | xcbeautify --renderer github-actions`, with `set -o pipefail`.
- Unsigned device build: `-configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`.
- Uploads the .xcresult when it fails.
- Comment: "macOS minutes bill at 10x"; that is why iOS is in its own paths-filtered workflow.

project.yml essentials:
- `options.deploymentTarget.iOS: "16.0"`, SPM `packages:` (Sentry from 9.15.0), explicit `schemes:`.
- `info.properties` declares CFBundleShortVersionString "$(MARKETING_VERSION)" and CFBundleVersion "$(CURRENT_PROJECT_VERSION)". XcodeGen's default writes the literals 1.0/1, so every build would ship as 1.0 (1).
- ITSAppUsesNonExemptEncryption, `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, PrivacyInfo.xcprivacy with an explicit `buildPhase: resources`.
- TARGETED_DEVICE_FAMILY "1"; DEVELOPMENT_TEAM is never committed.
- A postBuildScript stamps `git describe --always --dirty` and the build date into the built Info.plist.

## 4. Simulator screenshots (<the author's Cordova app> simulator-screenshots.yml, same on main)
- Triggers: workflow_dispatch and `cron '0 0 * * 1'`. Job ios-simulator on macos-14, timeout 30.
- Builds with `cordova build ios --emulator`.
- Boots the simulator: `SIMULATOR_UDID=$(xcrun simctl list devices available | grep "iPhone 15" | head -n 1 | grep -o "<UUID regex>")`, falls back to iPhone 14, then `xcrun simctl boot "$SIMULATOR_UDID"; sleep 10`.
- Installs and launches: `xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"`, reads the bundle id with `/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist"`, then `xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID"; sleep 10`.
- Screenshots: `xcrun simctl io "$SIMULATOR_UDID" screenshot ./screenshot-1-initial.png`, then sleep 5 and a second shot.
- Shuts the simulator down (if: always()) and uploads with `actions/upload-artifact@v4 name: ios-screenshots path: screenshot-*.png retention-days: 30`.
- Commit `<a commit>`: "The tap/swipe/home commands are not supported by simctl io on GitHub Actions macOS runners". There is no UI driving. For native Swift, use XCUITest (`XCUIScreen.main.screenshot()` / XCTAttachment exported from the .xcresult) or simctl launch arguments.
- Runtimes: roughly 4.5–6 min per run (e.g. 02:10:49 to 02:16:35; the iOS job took 3 min). Runs failed on 2026-03-02 and 2026-04-06.

## 5. Run durations
- <the author's Cordova app>: the TestFlight job takes about 5 min (2026-11-02: 22:41:56 to 22:46:59; fastlane step 3m21s; upload was done at +1m18s). The setup-ruby step takes about 40 s.
- <the author's Swift app> <a release tag> release: 6 min total, fastlane step 4m40s. Its ios-build workflow takes 5–7.5 min.
- <the author's React Native app> (React Native, private) releases take 13–20 min.

## 6. Gotchas recorded in commits and comments
1. `secrets.*` cannot be used in a job-level `if:`. Doing so makes the whole workflow file fail to parse with zero jobs (`<a commit>`). Gate on `vars.*` instead.
2. CFBundleShortVersionString must be 1–3 integers; a tag with a suffix (`<a release tag>`) was rejected (`<a commit>`). Validate before building.
3. A 1024 icon with an alpha channel is rejected (`<a commit>`, ITMS-90717).
4. The deployment target must be at least 13 ("iOS apps must target iOS version from 13 to 27.2"; `<a commit>`, 2026-10-29).
5. Don't put `${{ }}` inside a quoted shell string (an apostrophe broke it; `<a commit>`). Pass it via env. Per <the author's Swift app>, GitHub also evaluates `${{ }}` inside comments.
6. The fastlane working directory is fastlane/ for the lane body and `sh`, but the repo root for actions. Use absolute paths.
7. Don't use `setup_ci` alongside a manual keychain. Use update_code_signing_settings with `targets:`, not xcargs signing (from the guide in <the author's React Native app>).
8. On macos-26 image rotation, the linker failed with `swiftCompatibility56`. <the author's React Native app>'s fix: `echo "TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault" >> $GITHUB_ENV` (`<a commit>`).
9. macOS capacity: <the author's Cordova app> run <a run> (`<a release tag>`). Its TestFlight job (macos-15) was cancelled after exactly 15 min on all 3 attempts (2026-11-02 to 11-06) with zero steps. Annotation: "The job was not acquired by Runner of type hosted even after multiple attempts" / "Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times." No TestFlight build shipped for that release.
10. github.run_number is per workflow and is unchanged on a re-run attempt. A re-run after a successful upload reuses the CFBundleVersion and is rejected as a duplicate. <the author's Swift app>'s Fastfile says it is per workflow and resets if the workflow is renamed or recreated.
11. With the release-event trigger, the workflow is read from the tagged commit. Tagging before release.yml is on main gives zero runs and no error.
12. Validation rejections arrive by email 5–30 minutes after a green lane, because of skip_waiting_for_build_processing.
13. The distribution certificate belongs to the team (all apps). Don't create a new one, because of the per-team cap. <the author's Swift app>'s doc flags possible cert drift: <another of the author's apps>'s secret was set 2026-03-29 but the local cert was issued 2026-05-23.

## 7. House conventions for CLAUDE.md and runbooks
- Short ops projects (<three small services of the author's>; 25–75 lines) follow this pattern:
  - `# name` and a one-line purpose.
  - Data sources and file layout as terse bullets with exact paths and schemas.
  - `## Runbook` / `## Refresh` / `## Deploy` with indented or fenced copy-paste commands, using the full path `cd ~/src/github.com/trickv/<repo>`.
  - `## Verify` with commands plus an explicit "Expect ..." line, e.g. curl -w '%{http_code}' expecting 200.
  - `## Notes`: dated decisions with attribution ("Window rule (Trick, 2026-09-26): ...") and rules such as "generated; regenerate rather than edit" and "Never print the token".
  - Services run on the author's server at <subdomains of the author's domain> [deployment details removed for publication].
- App repos (<the author's Swift app>, 142 lines) follow this pattern:
  - `## Project Status`: candid status per milestone with dated validation facts (Xcode version, real-hardware results).
  - `## Release pipeline (added 2026-08-13)` with "Things that will bite if you edit blindly" as bold-lead bullets: bundle id, version injection, privacy manifest, opaque icon.
  - `## Repository Layout` with one bullet per directory or workflow.
  - `## Commands` blocks.
  - Long procedures go in docs/*.md (APP-STORE-RELEASE.md, BETA-TESTING.md, REAL-WORLD-FINDINGS.md, PARITY.md), and CLAUDE.md links to them.
- YAML and Fastfile carry long "why" comments that cite the incident and date and cross-reference sibling repos (../<another of the author's apps>, ../<the author's React Native app>).
- Bundle ids use the prefix `us.v9n.<app>`; <the author's Cordova app> used us.vanstaveren.<app>. The profile name equals the app slug.
- Commit messages: imperative subject, a body explaining the cause and the rejected-upload text verbatim, and a `Co-Authored-By: Claude ...` trailer.
- The release opt-out tag is `[skip-ios]` in the release body, the same across repos.

## 8. Local box facts (read-only)
[network details removed for publication] This section listed what a read-only look at yellow showed: its mosh-server (1.4.0, with mosh-client), its sshd and firewall state, the ports it listens on, Docker, CPU and memory, the LAN and tailnet addresses of yellow and of its tailnet peers (`charlie`, the phone, `hg`), and that the iPhone can reach yellow over Tailscale for manual mosh testing.

## 9. To create for trickv/ios-mosh (native Swift)
1. Apple Portal: register App ID (suggest `us.v9n.ios-mosh` or similar, following the us.v9n prefix) and turn on any capabilities before generating the profile. Create an App Store provisioning profile named after the app slug, using the existing Apple Distribution cert. Create the App Store Connect app record. Reuse the existing ASC API key (App Manager role).
2. GitHub secrets (8): APPLE_TEAM_ID, ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_BASE64, BUILD_CERTIFICATE_BASE64, P12_PASSWORD, KEYCHAIN_PASSWORD (all shared), plus the new BUILD_PROVISION_PROFILE_BASE64. Set them with `base64 -w 0 file | gh secret set NAME -R trickv/ios-mosh`. Values cannot be copied out of existing repos, so the original .p12, p8 and passwords are needed.
3. Repo files: Gemfile (fastlane + multi_json), fastlane/Appfile, fastlane/Fastfile (copy <the author's Swift app>'s: beta/build lanes, preflight, xcargs version injection), ios/<App>/project.yml (XcodeGen, SPM, version placeholders, ITSAppUsesNonExemptEncryption, AppIcon, PrivacyInfo.xcprivacy), and .gitignore for *.xcodeproj.
4. Workflows: release.yml (macos-26, release published + workflow_dispatch, concurrency group). ios-build.yml (paths filter, simulator test plus unsigned device build). A Linux job (ubuntu-latest, Docker) for SwiftPM core tests against sshd/mosh-server. Optionally a screenshots workflow using XCUITest attachments.
5. Docs: CLAUDE.md in house style, docs/APP-STORE-RELEASE.md (copy and adapt <the author's Swift app>'s), PRIVACY.md (privacy policy URL required by the stores), an opaque 1024 icon, and actionlint before the first push.

## findings

### 1. app technology

**topic:** app technology

#### claim

<the author's Cordova app> is a Cordova hybrid app with an Obj-C Cordova plugin. Its build steps (cordova, CocoaPods, config.xml editing, AltStore zip) don't transfer to native Swift.

#### evidence

<the author's Cordova app> release.yml: `cordova platform add ios --verbose`, `cordova plugin add plugin-src/<plugin>/ --nofetch`; plugin-src/<plugin>/src/ios/*.m

**confidence:** high

### 2. iOS signing/upload

**topic:** iOS signing/upload

#### claim

<the author's Cordova app>'s TestFlight job runs on macos-15 with setup-xcode latest-stable, imports a manual keychain, profile and p8, then runs `bundle exec fastlane ios beta` (update_code_signing_settings, build_app export_method app-store manual, upload_to_testflight skip_waiting).

**evidence:** git show <a release branch>:.github/workflows/release.yml job ios-appstore; fastlane/Fastfile lane :beta

**confidence:** high

### 3. toolchain observed

**topic:** toolchain observed

#### claim

The successful run on 2026-11-02 used image macos-15-arm64 20261028.0489.1, Xcode_26.3, fastlane 2.241.2 and Ruby 3.2.11. The TestFlight job took about 5 min.

#### evidence

gh api actions/jobs/<id>/logs for run <a run>: 'Image: macos-15-arm64', 'MD_APPLE_SDK_ROOT: /Applications/Xcode_26.3.app', 'fastlane 2.241.2 (Ruby 3.2.11, bundler)'

**confidence:** high

### 4. versioning

**topic:** versioning

**claim:** The build number is github.run_number. The marketing version comes from the tag with the v and any non-semver suffix stripped.

#### evidence

release.yml: `IOS_CFBUNDLE_VERSION: ${{ github.run_number }}`; `VERSION_NUM.match(/^\d+(?:\.\d+){0,2}/)`; <the author's Swift app> Fastfile resolve_build_number! uses APP_BUILD/GITHUB_RUN_NUMBER

**confidence:** high

### 5. secrets

**topic:** secrets

#### claim

The iOS secret names are IOS_BUNDLE_ID, FASTLANE_APPLE_ID, APPLE_TEAM_ID, APPLE_CODE_SIGN_IDENTITY, APPLE_PROVISIONING_PROFILE_NAME, BUILD_CERTIFICATE_BASE64, P12_PASSWORD, KEYCHAIN_PASSWORD, BUILD_PROVISION_PROFILE_BASE64, ASC_API_KEY_BASE64, ASC_API_KEY_ID, ASC_API_ISSUER_ID. The native template needs only 8.

**evidence:** gh secret list -R <the author's Cordova app>; gh secret list -R <the author's Swift app> (8 names); CI_SETUP.md secret table

**confidence:** high

### 6. better template

**topic:** better template

#### claim

<the author's Swift app> is a native Swift/XcodeGen app with a hardened TestFlight pipeline on macos-26. It is the closer template for ios-mosh.

#### evidence

/home/trick/src/github.com/trickv/<the author's Swift app>/.github/workflows/release.yml `runs-on: macos-26`; fastlane/Fastfile `build_app(project: xcodeproj_path, # not workspace: — no CocoaPods here, SPM only`

**confidence:** high

### 7. version injection gotcha

**topic:** version injection gotcha

#### claim

XcodeGen writes literal 1.0/1 into Info.plist unless the version keys reference build settings. <the author's Swift app> injects the versions through xcargs MARKETING_VERSION/CURRENT_PROJECT_VERSION with manageAppVersionAndBuildNumber false.

#### evidence

<the author's Swift app> CLAUDE.md: 'XcodeGen's *default* is to write literal `1.0`/`1` into the plist ... upload #1 succeeds, #2 is rejected'; Fastfile xcargs block

**confidence:** high

### 8. gate syntax

**topic:** gate syntax

**claim:** A job-level `if:` cannot reference secrets. Doing so invalidates the whole workflow, so <the author's Cordova app> gates on vars.IOS_BUNDLE_ID instead.

**evidence:** commit `<a commit>`: 'GitHub Actions does not permit secrets.* references in job-level if: conditions ... zero jobs run'

**confidence:** high

### 9. runner capacity

**topic:** runner capacity

**claim:** The macos-15 TestFlight job for one release (`<a release tag>`) was never picked up by a runner on 3 attempts (15 min each), so no build shipped.

#### evidence

check-runs/<a check run>/annotations: 'The job was not acquired by Runner of type hosted even after multiple attempts'; 'Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.'

**confidence:** high

### 10. simulator screenshots

**topic:** simulator screenshots

#### claim

The screenshots workflow boots an iPhone 15/14 simulator via simctl, installs and launches the app, takes simctl io screenshots after sleeps, and uploads them as an artifact. There is no UI interaction because simctl io cannot tap.

#### evidence

simulator-screenshots.yml ios-simulator job; commit `<a commit>` 'The tap/swipe/home commands are not supported by simctl io on GitHub Actions macOS runners'

**confidence:** high

### 11. upstream App Store rejections

**topic:** upstream App Store rejections

**claim:** Apple rejected uploads for: deployment target below 13, a non-integer short version, and an icon with alpha.

**evidence:** commits `<a commit>` ('iOS apps must target iOS version from 13 to 27.2'), `<a commit>`, `<a commit>`

**confidence:** high

### 12. local env

**topic:** local env

#### claim

mosh-server 1.4.0 is installed, [sshd and firewall details removed for publication], Docker works ([release removed for publication], exit 0), the CPU is an i7-8700T with 12 threads and 15 GiB RAM, and Tailscale is up with an iOS peer and a macOS peer.

#### evidence

mosh-server --version; [sshd and firewall details removed for publication]; docker info; tailscale status: '<the phone's tailnet name> ... iOS', 'charlie ... macOS'

**confidence:** high

### 13. Mac availability

**topic:** Mac availability

#### claim

There is evidence of a developer Mac: a macOS tailnet host 'charlie', and <the author's Swift app> docs that mention a dev Mac with Xcode 27.0 and a local keychain holding the distribution cert.

#### evidence

tailscale status 'charlie macOS'; <the author's Swift app> release.yml comment 'the dev Mac (Xcode 27.0 as of 2026-09-23)'; APP-STORE-RELEASE.md Step 3 'security find-identity -v -p codesigning'

**confidence:** medium

### 14. existing setup guide

**topic:** existing setup guide

#### claim

<the author's React Native app> contains docs/fastlane-testflight-guide.md, a step-by-step 'new project' guide. It lists the shared secrets and the one-time per-project steps: App ID, profile, ASC record, BUILD_PROVISION_PROFILE_BASE64.

#### evidence

/home/trick/src/github.com/trickv/<the author's React Native app>/docs/fastlane-testflight-guide.md '## 1. Apple Developer Portal Setup' / 'Per-project setup required'

**confidence:** high

## recommendations

- Copy <the author's Swift app>'s release.yml, ios-build.yml, Fastfile, Appfile, Gemfile and project.yml for ios-mosh rather than <the author's Cordova app>'s Cordova pipeline.
- Make trickv/ios-mosh a public repo. Standard GitHub-hosted macOS runners are free for public repos; <the author's React Native app>'s commit message mentions a '200 min/month free-tier macOS runner budget' for private repos.
- Use runs-on: macos-26 with a 'Show toolchain' step. Keep the TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault fix in mind for image rotations.
- Trigger on `release: published` plus workflow_dispatch(version, notes), with `concurrency: ios-release, cancel-in-progress: false`.
- Validate the version against ^[0-9]+(\.[0-9]+){0,2}$ before building. Inject the version via xcargs, keep $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) in project.yml, and set manageAppVersionAndBuildNumber: false.
- Set ITSAppUsesNonExemptEncryption early. ios-mosh uses SSH/mosh crypto (AES-OCB, ed25519), so the export-compliance answer may not be 'false' as in <the author's Swift app>; decide it explicitly.
- Put the SSH-bootstrap and mosh protocol core in a SwiftPM package that builds on Linux. Run its integration tests in an ubuntu-latest job, or locally in a swift Docker image, against sshd and mosh-server 1.4.0. Keep macOS minutes for UI and signing.
- Use XCUITest with XCTAttachment screenshots, extracted from the .xcresult, instead of simctl io, because simctl cannot drive the UI.
- Run actionlint before the first push, and put release.yml on main before tagging.
- Ask the developer whether 'charlie' is a usable Mac. It would allow a local `fastlane ios build` signing smoke test and Xcode debugging.

## risks

- GitHub-hosted macOS arm64 capacity: <the author's Cordova app>'s TestFlight job for `<a release tag>` never got a runner on 3 attempts in November 2026.
- Re-running a release keeps github.run_number. If the earlier attempt uploaded, the build number is a duplicate and gets rejected. Renaming release.yml resets the counter to 1.
- There may be certificate drift: <the author's Swift app> docs flag that <another of the author's apps>'s BUILD_CERTIFICATE_BASE64 (2026-03-29) may be a different cert from the local one (2026-05-23).
- No Gemfile.lock is committed, so the fastlane version floats; 2.238.0 and 2.241.2 have both been observed. export_method 'app-store' is deprecated in Xcode 26.6+ but gym still requires it.
- Apple's minimum SDK and deployment-target rules keep rising: iOS 26 SDK is required now, and the minimum deployment target was 13 per the 2026-10 rejection. Leaving the image unpinned follows the default, but then the local and CI toolchains differ.
- Docker's iptables rules could not be inspected without root. The UDP path from a container to host mosh-server (60000-61000) is unverified.
- Validation rejections arrive by email after a green run because of skip_waiting_for_build_processing.

## unverified

- Whether host 'charlie' (macOS on the tailnet) has Xcode and is available to this developer for builds. <the author's Swift app> docs suggest a dev Mac exists, but this was not checked.
- [sshd and firewall details removed for publication]
- Why the TestFlight upload of `<a release tag>` of <the author's Cordova app> failed on 2026-08-09: the logs have expired (HTTP 410).
- Whether GitHub-hosted macOS minutes are free for a public trickv/ios-mosh under the developer's current plan. This is inferred from GitHub's general policy, not checked against the account.

