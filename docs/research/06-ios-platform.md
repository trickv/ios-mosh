# Research: ios_platform

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

Current state (Nov 11, 2026): iOS/iPadOS 27 shipped Sept 14, 2026. App Store Connect has required Xcode 26+ and the iOS 26 SDK since Apr 28, 2026. On GitHub Actions, `macos-26` (= `macos-latest`, arm64) defaults to Xcode 26.6 (iOS SDK 26.5). Xcode 27.0, 27.1 (default) and 27.2 run only on the preview label `xcode-27`, which uses a macOS 27 base. macOS 14 images were retired Nov 2, 2026. GitHub billing is now dollar-based: Free plan $12/month, Pro/Team $18. A standard macOS runner costs $0.062/min, about 193 macOS minutes/month on Free. Standard runners are free for public repos. Swift 6.4.2 is current (Oct 30, 2026), with Docker image `swift:6.4.2-noble`.

Key constraints:
- Apps built with the iOS 27 SDK must use the UIScene lifecycle or they will not launch (TN3187).
- After didEnterBackground, about 5 s plus a beginBackgroundTask extension. No callback fires on jetsam or on force-quit of a suspended app.
- Socket resources can be reclaimed while the app is suspended, and calls then fail, often with EBADF (TN2277). Recreate the UDP flow on every foreground.
- Unicast UDP to a LAN address triggers the Local Network prompt. VPN or cellular paths (Tailscale) do not.
- Programmatic UIPasteboard reads prompt; writes and Cmd-V or edit-menu paste do not.
- No legitimate background mode fits.

Mosh-critical finding: the mosh nonce is a direction bit plus a process-global counter (`Crypto::unique`). A resumed client must persist and advance its outgoing sequence number, or it reuses OCB nonces under the same key. Also, the server ignores packets whose seq is below `expected_receiver_seq`, so they do not update the roaming address.

Recommendations:
- iOS 18.0 minimum deployment target, UIScene-only lifecycle.
- XcodeGen plus a local SwiftPM core package.
- Automatic signing in CI with an App Store Connect API key, then upload through `altool --upload-package` or `-exportArchive` destination=upload.
- Network.framework UDP in the app, with a protocol-level transport abstraction and a POSIX implementation for Linux tests.
- A UIView adopting UITextInput, plus pressesBegan with app-implemented key repeat, plus a keyboardLayoutGuide-pinned key bar.

## details

## 0. Current versions (verified 2026-11-11)
- **iOS:** iOS 27 / iPadOS 27 released Sept 14, 2026 (MacRumors 2026-09-14). Runner image lists iOS 27.0, 27.1, 27.2 SDKs and simulators.
- **Xcode:**
  - GA on GitHub `macos-26` arm64 image 20261102: Xcode 26.6 (17F113) default. Also installed: 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1. iOS SDKs 26.0 to 26.5. Simulators for iOS 26.2, 26.4 and 26.5.
  - `xcode-27` / `xcode-27-xlarge` (preview, issue actions/runner-images#14404): macOS 27.0.1. Xcode 27.0, 27.1 (default) and 27.2 (27B52). iOS SDK and simulators 27.0 to 27.2.
- **App Store Connect minimum:** "Begins April 28, 2026": uploads must be built with Xcode 26+ against the iOS 26 SDK (developer.apple.com/news/upcoming-requirements). The next bump (Xcode 27 / iOS 27 SDK, probably around April 2027) is unverified.
- **Runner labels (actions/runner-images README):**
  - `macos-latest` = `macos-26` (arm64; also `macos-26-xlarge`).
  - `macos-26-intel` / `macos-26-large` / `macos-latest-large` (x64).
  - `macos-15` (arm64), `macos-15-intel`.
  - `macos-14` retired Nov 2, 2026.
  - Policy: "only one major version of Xcode will be supported per macOS version".
  - Preinstalled: fastlane 2.241.2, xcbeautify 3.2.1, Ruby 3.4.12. XcodeGen and Tuist are not preinstalled.
- **Billing (docs.github.com billing/reference/actions-runner-pricing and concepts/product-billing/github-actions):**
  - Per minute: macOS 3/4-core $0.062; macOS 12-core (large) $0.077; macOS M2 Pro 5-core (xlarge) $0.102; Linux 2-core x64 $0.006, arm64 $0.005.
  - Included compute is now "expressed as a monetary amount": Free $12/month, Pro $18, Team $18. There is no longer a published 10x multiplier; the price ratio is about 10x.
  - "Standard GitHub-hosted runners in public repositories are free"; "Larger runners are not free for public repositories."
- **Xcode Cloud:** 25 compute hours/month included with the Apple Developer Program (Apple news id=ik9z4ll6, Jan 2024). Unused hours do not roll over. Paid tiers: 100h $49.99/month and up.
- **Swift:** 6.4.0 (2026-09-15), 6.4.1, 6.4.2 (2026-10-30). Docker Hub `swift:6.4.2-noble`, `-noble-slim`, `amazonlinux2023`, `rhel-ubi9/10`; 6.3.3 is also available.
- **Library and tool versions:**
  - swift-testing tag swift-6.4.2-RELEASE.
  - swift-nio 2.105.0 (2026-11-03); swift-nio-transport-services 1.28.0 (2026-04-23); swift-crypto 5.1.1 (2026-11-03).
  - XcodeGen 2.46.0 (2026-07-16); Tuist 4.216.1 (2026-11-11); fastlane 2.241.2.

## 1. Lifecycle
**Background time**
- Apple: "When your app moves to the background, the system calls your app delegate's … method. That method has five seconds to perform any tasks and return. Shortly after that method returns, the system puts your app into the suspended state."
- beginBackgroundTask buys extra time; check `backgroundTimeRemaining`, typically about 30 s, which is not documented.
- "Call this method as early as possible … don't call this method at the very end of your [didEnterBackground] … If the system is unable to grant the task assertion, it calls your expiration handler … If you don't call [endBackgroundTask] … the system kills the app."
- Recommended pattern:
  - Begin a background task in `sceneWillResignActive`.
  - Flush state synchronously.
  - Optionally send one final mosh ACK.
  - End the task.
  - Close the UDP socket in `sceneDidEnterBackground`.

**Scenes**
- `sceneDidEnterBackground` replaces the app-delegate callback when scenes are enabled. "Shortly after this method returns, UIKit takes a snapshot … Make sure your interface doesn't contain sensitive user information."
- `sceneDidDisconnect`: "UIKit disconnects a scene when the user explicitly closes it in the app switcher. UIKit may also disconnect a scene in order to reclaim memory … does not automatically disconnect a scene when the user switches to another app."
- `application(_:didDiscardSceneSessions:)`: "If your app isn't running, UIKit calls this method the next time your app launches … doesn't call it when the system disconnects a scene to free up memory … preserves the sessions."
- So a swipe-away of a suspended app gives no callback in that process. Discard is reported at the next launch. Treat it as "user closed this window", and optionally offer to keep the mosh session.

**Termination**
- `applicationWillTerminate`: "approximately five seconds … generally not called when the user quits the app … may be called … where the app is running in the background (not suspended)".
- Jetsam (killing a suspended app) gives no callback.
- Design rule: everything needed to resume must already be on disk before suspension.

**UIScene mandatory**
- TN3187: "In the next major release following iOS 26, UIScene lifecycle will be required when building with the latest SDK; otherwise, your app won't launch." That release is iOS 27.
- Use a scene-only lifecycle from day 1: an Info.plist `UIApplicationSceneManifest` with `UISceneDelegate`. Set `UIApplicationSupportsMultipleScenes=YES` for iPad multi-window, with one mosh session per scene, keyed by a sessionID stored in `UISceneSession.userInfo` or `stateRestorationActivity`.

**State restoration**
- `stateRestorationActivity(for:)` returns an NSUserActivity "to restore that state again after UIKit disconnects and then reconnects the scene".
- Use it only to map scene to session UUID. Keep the authoritative session state in the app's own file store, because swipe-away discards the scene session.

**Atomic persistence**
- Small Codable blob per session: host, port, mosh key (16 bytes, base64 22 chars), outgoing seq high-water mark, last-received state number, terminal size, and optionally a framebuffer snapshot.
- Write with `Data.write(to:options:[.atomic, .completeFileProtectionUntilFirstUserAuthentication])` in Application Support, excluded from backup (`isExcludedFromBackup`).
- Alternative: keep the session key in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Apple: "remains accessible until the next restart … recommended for items that need to be accessed by background applications … do not migrate to a new device".
- Do not use `.complete` protection: writes at lock time can fail.

**Mosh resume hazard (verified in mobile-shell/mosh master)**
- network.cc:88: `direction_seq = (uint64_t(direction == TO_CLIENT) << 63) | (seq & SEQUENCE_MASK)` is the AES-OCB nonce.
- seq comes from `Crypto::unique()`, a static counter starting at 0 (crypto.cc:64-71).
- Server recv (network.cc:482-486): `if (p.seq < expected_receiver_seq) { /* don't use (but do return) … */ return p.payload; }`. Remote-address roaming is updated only after that check.
- So a resumed client must:
  - persist the next send seq;
  - on every save, reserve a block, for example persist seq+N and skip ahead on resume, so a crash between send and save never reuses a nonce;
  - also persist Transport state numbers (sent and acked states).
- Constants:
  - `SERVER_ASSOCIATION_TIMEOUT = 40000` ms. The server "detaches", but the session survives.
  - The client hops port when there is no round trip for `PORT_HOP_INTERVAL = 10000` ms.
  - `ACK_INTERVAL = 3000` ms empty acks; `SEND_INTERVAL_MIN/MAX` 20/250 ms.
  - MTU 1280 for IPv4 and IPv6, with app datagram fallback 500.

**Background modes**
- None fits. `BGContinuedProcessingTask` (iOS 26) is "a task that starts in the foreground … The system displays the progress … in a Live Activity", so it is for user-visible progress work and is not a keepalive.
- Audio or VoIP keepalive hacks violate App Review (guideline 2.5.4; not re-verified here).
- Plan for zero background execution, matching the stated intent.

## 2. UDP networking
**Network.framework vs BSD sockets**
- TN3151: "For UDP flows … unicast datagrams flowing between two peers—Network framework is the best choice. If you use BSD Sockets for this case, you'll have to do a bunch of extra work."
- BSD sockets need you to "implement Happy Eyeballs yourself … incompatible with VPN On Demand … use [NWPathMonitor] to monitor its viability."

**Suspend invalidation**
- TN2277: "while the app is suspended the system may choose to reclaim resources out from underneath a network socket … the only thing you can do with the socket at this point is to close it … in many cases the error will be EBADF."
- Rule: on `sceneWillEnterForeground` / `didBecomeActive`, always create a fresh `NWConnection(host:port:using: .udp)` and immediately send a mosh packet with a fresh timestamp. Mosh roaming tolerates a new source port; that is the same mechanism as hop_port.

**Roaming**
- Monitor `pathUpdateHandler`, `viabilityUpdateHandler` and `betterPathUpdateHandler`.
- On a better path, or a failed / `.waiting` state, start a new NWConnection and keep the old one until the new one receives.
- The protocol is stateless, so swapping is cheap.
- Set `parameters.prohibitedInterfaceTypes` only if the user opts out of cellular.
- Low Data Mode: `NWParameters.allowConstrainedNetworkAccess` (default true); `path.isConstrained` and `isExpensive` can be shown in the UI. Mosh traffic is tiny.

**IPv6, NAT64 and App Review**
- Apple's IPv6 transition doc: "The ability to synthesize IPv6 addresses was added to getaddrinfo in iOS 9.2"; "Don't Use IP Address Literals". The App Review network is "IPv6 DNS64/NAT64 … allow for direct IPv6-to-IPv6".
- For mosh: connect UDP to the exact address the SSH TCP connection used (`connection.currentPath?.remoteEndpoint`), not an IPv4 literal echoed by the server.
- If the user types an IPv4 literal, pass it through `NWEndpoint.Host` (Network.framework synthesizes the NAT64 address) or `getaddrinfo` with AI_DEFAULT.

**Local Network privacy (TN3179)**
- "Sending a UDP unicast: yes; Connecting a UDP socket: yes; Receiving an incoming UDP unicast: no".
- "A local network is an IP network associated with a broadcast-capable network interface … Wi-Fi and Ethernet, but not cellular (WWAN) or VPN."
- So a LAN host such as 192.168.x or a .local name triggers the prompt; Tailscale 100.x, WireGuard utun and Internet hosts do not.
- "it may deny the operation immediately, before the user has responded … use an API that supports waiting for connectivity, like Network framework."
- "If an iOS app is in the background … the system denies that operation without presenting the local network alert."
- Include `NSLocalNetworkUsageDescription`. The multicast entitlement is not needed.

**VPN and MTU**
- Tailscale and WireGuard use a 1280-byte inner MTU (Tailscale value from general knowledge). Mosh caps IP datagrams at 1280 (`DEFAULT_IPV4_MTU = 1280`, `DEFAULT_IPV6_MTU = 1280`), so it fits.

**NAT timeouts**
- Mosh sends empty ACKs every 3 s while running, so carrier NAT timeouts (often 30-120 s) matter only while suspended.
- After resume the client sends from a new port, so the server re-learns the address. The server never needs to reach the old mapping.

**SwiftNIO**
- NIOTransportServices has `NIOTSDatagramConnectionBootstrap` / `NIOTSDatagramListenerBootstrap` (Sources/NIOTransportServices/Datagram/). NIOPosix has `DatagramBootstrap` for Linux.
- Feasible, but heavy for one UDP flow plus an SSH bootstrap.
- Recommendation: define a tiny `DatagramTransport` protocol (`send(Data)`, `AsyncStream<Data>` receive, `close()`) in the core package. Implementations:
  - `NWDatagramTransport` (iOS).
  - `POSIXDatagramTransport` (Glibc/Darwin, used for Linux integration tests against the real mosh-server 1.4.0).
- Use SwiftNIO only if the chosen SSH library (for example swift-nio-ssh) already pulls it in; then NIOTS UDP is reasonable to share.

## 3. Keyboard and input architecture
**Input view**
- Use a custom `UIView` (or `UIScrollView`) that adopts `UITextInput` (which includes `UIKeyInput`) and `UITextInputTraits`. `UITextInput` is required for IME marked text (CJK), dictation and the inline candidate bar.
- SwiftTerm does exactly this: `TerminalView: UIScrollView, UITextInputTraits, UIKeyInput …` plus `extension TerminalView: UITextInput`, with `setMarkedText` and `insertDictationResultPlaceholder` (Sources/SwiftTerm/iOS/iOSTerminalView.swift:109, iOSTextInput.swift:72).
- Traits: `autocorrectionType = .no`, `spellCheckingType = .no`, `smartQuotesType = .no`, `smartDashesType = .no`, `smartInsertDeleteType = .no`, `autocapitalizationType = .none`, `keyboardType = .default` (or `.asciiCapable` as an option). Also disable `inlinePredictionType` (iOS 17) and writingTools behavior (iOS 18); those two are not verified in SwiftTerm.
- Handle the auto-period ". " replacement (SwiftTerm `isAutoPeriodReplacement`).

**Hardware keyboard**
- Override `pressesBegan`, `pressesEnded` and `pressesCancelled` and read `UIPress.key` (`keyCode: UIKeyboardHIDUsage`, `modifierFlags`, `charactersIgnoringModifiers`). Map Ctrl, Alt (as Meta, optional), Esc, arrows and F-keys to escape sequences.
- Let plain text come through `insertText` so IME works. Skip `insertText` when a press was consumed.
- Key repeat is not delivered to `pressesBegan`. Implement a timer per key, like SwiftTerm (`startKeyRepeat`, `keyRepeats: [UIKeyboardHIDUsage: Timer]`).
- Use `UIKeyCommand` only for app commands (Cmd+T new session, Cmd+W, Cmd+V paste, Cmd+K) so they appear in the iPadOS 26 menu bar (UIMainMenuSystem). Set `wantsPriorityOverSystemBehavior = true` only where needed. Doc: "In iOS 15 and later, the system delivers physical keyboard events to the text input or focus systems first … If [true], the system reverses that order."
- System-reserved: Cmd+Tab, Cmd+Space, Cmd+H, Globe shortcuts, and Ctrl+Space (input switching). Apps cannot remap Caps Lock; the user sets Settings > General > Keyboard > Hardware Keyboard > Modifier Keys. You can offer an in-app "Caps Lock as Esc/Ctrl" only via `pressesBegan` keyCode `.keyboardCapsLock`, which is unreliable; not verified.

**Accessory key bar**
- iOS 26 changed keyboard chrome. Forum thread 787687 reports that `inputAccessoryView` no longer sits flush, now has a margin and rounded corners, and toolbars get a Liquid Glass wrapper.
- Preferred: a key bar view in the view hierarchy, pinned with `view.keyboardLayoutGuide.topAnchor` and `followsUndockedKeyboard = true` ("To follow all keyboard anchors even when undocked or floating"). That gives full control and also works with a hardware keyboard, where the bar stays at the bottom safe area.
- Keep an `inputAccessoryView` variant behind a flag for comparison.
- Resize the terminal grid from the guide's layout (`viewDidLayoutSubviews`), then send a mosh resize. Debounce for 100 ms, because frame notifications are noisy in windowed apps (forum 800310).

**Multi-window**
- Stage Manager / windowed iPad: compute cols and rows from the scene's bounds, not the screen.
- Treat floating or split keyboards via `followsUndockedKeyboard`: the terminal should not shrink for a floating keyboard.

**Pointer and scroll (as in SwiftTerm, iOSTerminalView.swift:1533-1564)**
- Pan gesture with `allowedScrollTypesMask` `.continuous` / `.discrete` for trackpad and wheel, mapped to mouse wheel reports when the app has mouse mode on.
- `UIHoverGestureRecognizer` for motion reports.
- `UIPointerInteraction` for the I-beam cursor.
- `buttonMask = .secondary` tap for right click.

## 4. Clipboard
- UIPasteboard doc: "Starting in iOS 14, the system notifies the user when an app gets general pasteboard content that originates in a different app without user intent … such as tapping a system-provided control or pressing Command-V." UIPasteControl doc: "In iOS 16 and later, programmatic pasting raises a user alert that prompts the user for approval."
- **OSC 52 write (remote to iOS):** `UIPasteboard.general.string = decoded` does not prompt. Additional rules:
  - Apply only while foreground-active.
  - Size-limit it, for example 1 MiB.
  - Optionally require a per-host "allow remote clipboard writes" setting and show a toast.
  - Use `setItems(_:options:[.localOnly: true])` to keep it off Universal Clipboard if the user wishes, and `.expirationDate` for secrets.
- **OSC 52 read (`?` query, iOS to remote):** reading programmatically would trigger the system "Allow Paste" alert on every query, and would leak clipboard contents. Reply with empty data, or only after an explicit in-app confirmation that is followed by a user-initiated paste.
- **Paste (iOS to remote):** handle Cmd-V via `UIResponder.paste(_:)`, `canPerformAction` and the edit menu (`UIEditMenuInteraction`). Also add a `UIPasteControl` button in the key bar. All of these are prompt-less, and the text is wrapped in bracketed paste (`ESC[200~ … ESC[201~`) when DECSET 2004 is on.
- Use `hasStrings` to enable or disable the paste UI without triggering the prompt.

## 5. No-Mac build pipeline
**Project definition**
- Recommend XcodeGen 2.46: a single `project.yml` with the app target, a UI test target and a unit test host. Install with `brew install xcodegen` or the pinned release zip. The generated `.xcodeproj` is gitignored.
- Put all logic in a local SwiftPM package (`Packages/MoshCore`) that the app depends on. The thin app target holds only UIKit glue.
- Tuist 4.x is more powerful but moves fast (canary releases daily) and adds its own CLI and runtime surface.
- Plain SwiftPM cannot produce an iOS `.app` with entitlements, Info.plist and signing, so an Xcode project generator is still needed.

**Signing**
- Use automatic signing with an App Store Connect API key (Admin or App Manager role):
  `xcodebuild archive -scheme App -destination 'generic/platform=iOS' -allowProvisioningUpdates -authenticationKeyPath $KEY_P8 -authenticationKeyID $KID -authenticationKeyIssuerID $ISS`
  then `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` with the same flags. ExportOptions: `method=app-store-connect`, `destination=upload` or `export`, `teamID`, `signingStyle=automatic`.
- Cloud-managed distribution certificates make this work with no exported .p12. Forum reports of "No Accounts with App Store Connect Access" with individual keys mean you should use a Team key.
- Fallback: manual secrets, that is a base64 .p12 plus provisioning profile imported into a temporary keychain (`security create-keychain`, `import`, `set-key-partition-list`), with `CODE_SIGN_STYLE=Manual`.
- fastlane match is overkill for one developer.

**Upload**
- Apple's upload-tools page lists Xcode, `xcrun altool --upload-app` / `--upload-package` (`--upload-app` is deprecated in favor of `--upload-package`), Transporter (Mac app and CLI with JWT), and the App Store Connect API `POST /v1/buildUploads`.
- Use `xcrun altool --upload-package App.ipa --apiKey $KID --apiIssuer $ISS` with `AuthKey_$KID.p8` in `~/.appstoreconnect/private_keys`, or `-exportArchive` with `destination=upload`.
- fastlane `pilot` / `upload_to_testflight` 2.241.2 is preinstalled on the runner and also works with `app_store_connect_api_key`.

**Build numbers**
- `CFBundleVersion = $GITHUB_RUN_NUMBER` plus an offset, or a timestamp `YYYYMMDDHHmm`. It must be unique and increasing per marketing version.
- Set it with `xcodebuild … CURRENT_PROJECT_VERSION=$N`. `MARKETING_VERSION` lives in project.yml.

**Export compliance**
- Without the plist key, App Store Connect "walks you through an export compliance questionnaire every time you upload". TestFlight builds stay "Missing Compliance" until it is answered.
- Set `ITSAppUsesNonExemptEncryption` explicitly. Apple: "Typically, the use of encryption that's built into the operating system … is exempt … whereas the use of proprietary encryption is not … If your app uses exempt forms of encryption, you might alternatively be required to submit a year-end self-classification report."
- An SSH plus AES-OCB mosh client uses standard, non-proprietary algorithms for data confidentiality. That is generally mass-market 5D992 under License Exception ENC (not legal advice).
- Precedent: Blink Shell ships `<key>ITSAppUsesNonExemptEncryption</key><false/>` (blinksh/blink Blink/Info.plist).
- The requirement is the same for TestFlight (internal and external) and the App Store: answer once per version, or set the key.
- France: Apple notes ANSSI controls "Secure Communications" apps; exclude France from distribution or file an ANSSI declaration.

**CI workflow outline (.github/workflows/ci.yml)**
1. `linux-core` on `ubuntu-24.04`, container `swift:6.4.2-noble`: `swift build`, then `swift test --parallel` on the core package.
   - Optional integration job: install mosh 1.4 (`apt-get install mosh openssh-server`), start sshd, and run the client core against mosh-server.
   - Cost: about $0.006/min, or free on public repos.
2. `ios-test` on `macos-26`:
   - `sudo xcode-select -s /Applications/Xcode_26.6.app`, `brew install xcodegen`, `xcodegen`.
   - `xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath out.xcresult | xcbeautify`.
   - Add an iPad Pro 11-inch (M5) destination.
   - UI tests call `XCUIScreen.main.screenshot()` and `XCTAttachment(lifetime: .keepAlways)`.
   - Extract with `xcrun xcresulttool export attachments --path out.xcresult --output-path shots/`, and record with `xcrun simctl io booted recordVideo --codec h264 run.mp4 &` around the UI tests.
   - `actions/upload-artifact` for shots, video and `out.xcresult.zip`.
3. `ios-27-canary` on `xcode-27` (continue-on-error) to catch iOS 27 SDK issues, for example the UIScene enforcement.
4. `testflight` (on tag or main) on `macos-26`: write the .p8 key from a secret, then archive, export and upload.
- UI tests can send hardware keys with `XCUIElement.typeKey(_:modifierFlags:)`, which lists iOS (XCUIAutomation, Xcode 16.3 docs).

**Simulator limitations**
- `SecureEnclave.isAvailable` is false on the simulator (general knowledge), so gate it and test on device via TestFlight.
- Keychain works in the simulator for app-hosted tests (not for bare logic tests).
- UDP to external hosts works from the simulator (host networking), but there is no cellular, NAT64 or Wi-Fi roaming.
- Local Network prompt behavior differs from devices.

**Duration and cost**
- Estimate: a cold build plus unit and UI tests on a small app takes about 8-15 min on `macos-26`, so $0.50-$0.95 per run on a private repo. The included $12 (Free) covers about 193 macOS minutes/month.
- Make the repo public, or use Xcode Cloud's 25 h/month for TestFlight builds. Xcode Cloud setup normally requires Xcode once; unverified.
- Cache `~/Library/Developer/Xcode/DerivedData/SourcePackages` and SwiftPM.

## 6. Swift on Linux
**Toolchain:** Swift 6.4.2, Docker `swift:6.4.2-noble`. Use `swift-tools-version: 6.2` (or the lowest version that matches Xcode 26.6's Swift) so the package builds with both Xcode 26.x and Linux 6.4.

**Unavailable on Linux, and replacements:**

| Unavailable | Replacement |
|---|---|
| CryptoKit | swift-crypto (`import Crypto` re-exports the CryptoKit API on Apple platforms) |
| `SecureEnclave` | iOS only, behind `#if canImport(CryptoKit)` |
| Network.framework | POSIX or NIOPosix |
| Security / Keychain | protocol `KeyStore` with an in-memory or file implementation for Linux |
| UIKit, Combine, os.Logger | swift-log |

- AES-128-OCB (the mosh cipher) is not in CryptoKit or swift-crypto. Use a vendored C implementation or another OCB source.

**Testing:** the swift-testing `@Test` macro and XCTest both run under `swift test` on Linux in 6.x. Prefer Swift Testing for new tests.

**Package layout:**
- `MoshProtocol` (protobuf wire format, transport, SSP state sync, OCB crypto): pure Swift and C, Linux-tested.
- `TerminalCore` (VT parser, screen model, OSC 52 parser emitting events): pure Swift. Or adopt SwiftTerm's core, which is cross-platform.
- `SSHBootstrap` (run `mosh-server new -s -c 256 -l LANG=…`, parse `MOSH CONNECT <port> <key>`).
- `KeyManagement` (Ed25519 and P-256 generation via swift-crypto, OpenSSH public key and private key formatting).
- `Platform` protocols: `DatagramTransport`, `KeyStore`, `Clipboard`, `Clock`.
- The iOS app target supplies the NW, Keychain and UIPasteboard implementations.

## Concrete recommendations summary
- **Deployment target:** iOS/iPadOS 18.0. iOS 17 is possible; nothing needed is newer than iOS 16 (UIPasteControl) and iOS 15 (keyboardLayoutGuide).
- **Build:** Xcode 26.6 on `macos-26`, with an `xcode-27` canary.
- **Lifecycle:** scene-only.
- **Platform:** iPhone plus iPad with multiple scenes.
- **Background modes:** none.
- **Entitlements:** none special. Info.plist: `NSLocalNetworkUsageDescription`, `ITSAppUsesNonExemptEncryption=false` (after your own review), `UIApplicationSceneManifest`.

## findings

### 1. App Store SDK minimum

**topic:** App Store SDK minimum

**claim:** Since Apr 28, 2026, App Store Connect uploads must be built with Xcode 26+ against the iOS 26 SDK.

**evidence:** developer.apple.com/news/upcoming-requirements: 'Begins April 28, 2026 … built with Xcode 26 or later … iOS 26 … SDK'

**confidence:** high

### 2. Current iOS

**topic:** Current iOS

**claim:** iOS/iPadOS 27 was released Sept 14, 2026.

**evidence:** macrumors.com/2026/09/14/apple-releases-ios-27/

**confidence:** high

### 3. GitHub runners

**topic:** GitHub runners

#### claim

macos-latest = macos-26 (arm64), with Xcode 26.6 default and iOS SDK up to 26.5. Xcode 27.0, 27.1 (default) and 27.2 are only on the preview label xcode-27 (macOS 27.0.1 base). macOS 14 was retired Nov 2, 2026.

#### evidence

actions/runner-images README table and images/macos/macos-26-arm64-Readme.md lines 159-184 ('26.6 (default) | 17F113'); xcode-27-arm64-Readme.md lines 159-173; issue #14404

**confidence:** high

### 4. Actions pricing

**topic:** Actions pricing

#### claim

macOS standard runner $0.062/min, macOS 12-core $0.077, M2 Pro xlarge $0.102, Linux 2-core $0.006. Included compute is a dollar amount ($12 Free, $18 Pro/Team). Standard runners are free in public repos; larger runners are not.

#### evidence

docs.github.com/en/billing/reference/actions-runner-pricing; docs.github.com/en/billing/concepts/product-billing/github-actions ('included compute usage is expressed as a monetary amount')

**confidence:** high

### 5. UIScene mandate

**topic:** UIScene mandate

**claim:** Apps built with the SDK after iOS 26 (i.e. iOS 27) must adopt the UIScene lifecycle or they will not launch.

#### evidence

TN3187: 'In the next major release following iOS 26, UIScene lifecycle will be required when building with the latest SDK; otherwise, your app won't launch.'

**confidence:** high

### 6. Background time

**topic:** Background time

**claim:** didEnterBackground has about 5 s. beginBackgroundTask must be requested early; it is granted asynchronously and may be refused.

#### evidence

developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time: 'That method has five seconds to perform any tasks and return'; beginBackgroundTask doc: 'don't call this method at the very end of your … method'

**confidence:** high

### 7. Force quit / discard

**topic:** Force quit / discard

#### claim

Swiping away a scene of a non-running app produces didDiscardSceneSessions at the next launch. Memory reclamation preserves sessions. applicationWillTerminate is generally not called for background-capable apps.

#### evidence

application(_:didDiscardSceneSessions:) doc: 'If your app isn't running, UIKit calls this method the next time your app launches'; applicationWillTerminate doc: 'generally not called when the user quits the app'

**confidence:** high

### 8. Socket reclaim

**topic:** Socket reclaim

**claim:** Sockets of a suspended app may be reclaimed; afterwards calls fail (often EBADF) and the socket must be closed and recreated.

**evidence:** TN2277: 'the system may choose to reclaim resources out from underneath a network socket … in many cases the error will be EBADF'

**confidence:** high

### 9. Mosh nonce / resume

**topic:** Mosh nonce / resume

#### claim

The mosh packet nonce is a direction bit plus a process-global counter starting at 0, and the server ignores seq below expected_receiver_seq for roaming/timestamps. A resumed client must persist and advance its send seq to avoid OCB nonce reuse and to keep roaming working.

#### evidence

mobile-shell/mosh src/crypto/crypto.cc:64-71 'static uint64_t counter = 0'; src/network/network.cc:88 nonce construction, :482-486 'don't use (but do return) out-of-order packets'

**confidence:** high

### 10. Mosh timing constants

**topic:** Mosh timing constants

**claim:** SERVER_ASSOCIATION_TIMEOUT 40000 ms, PORT_HOP_INTERVAL 10000 ms, ACK_INTERVAL 3000 ms, MTU 1280.

**evidence:** mosh src/network/network.h:135-146; src/network/transportsender.h:49-54

**confidence:** high

### 11. Local Network privacy

**topic:** Local Network privacy

#### claim

Sending or connecting unicast UDP to a local-network address requires permission; cellular and VPN interfaces are not 'local network'. In the background the operation is denied silently, and the first access may fail before the user answers.

**evidence:** TN3179 tables: 'Sending a UDP unicast yes … Connecting a UDP socket yes'; 'Wi-Fi and Ethernet, but not cellular (WWAN) or VPN'

**confidence:** high

### 12. UDP API choice

**topic:** UDP API choice

#### claim

Apple recommends Network.framework for unicast UDP flows. BSD sockets require your own connect-by-name / Happy Eyeballs and do not work with VPN On Demand.

**evidence:** TN3151: 'For UDP flows … Network framework is the best choice. If you use BSD Sockets … a bunch of extra work'

**confidence:** high

### 13. NAT64

**topic:** NAT64

#### claim

getaddrinfo synthesizes IPv6 for IPv4 on NAT64 since iOS 9.2. Apple says not to use IPv4 literals, and App Review uses a DNS64/NAT64 network.

#### evidence

Apple NetworkingOverview 'UnderstandingandPreparingfortheIPv6Transition': 'ability to synthesize IPv6 addresses was added to getaddrinfo in iOS 9.2'

**confidence:** high

### 14. NIO UDP

**topic:** NIO UDP

**claim:** swift-nio-transport-services has a UDP bootstrap (NIOTSDatagramConnectionBootstrap) on Network.framework.

**evidence:** apple/swift-nio-transport-services Sources/NIOTransportServices/Datagram/NIOTSDatagramConnectionBootstrap.swift; release 1.28.0

**confidence:** high

### 15. Key command priority

**topic:** Key command priority

**claim:** Since iOS 15, hardware key events go to text input/focus first; wantsPriorityOverSystemBehavior=true reverses that for a UIKeyCommand.

**evidence:** UIKeyCommand.wantsPriorityOverSystemBehavior doc

**confidence:** high

### 16. Terminal input reference impl

**topic:** Terminal input reference impl

#### claim

SwiftTerm's iOS view adopts UITextInput/UIKeyInput, disables autocorrect and smart quotes/dashes/insert-delete, handles special keys in pressesBegan, and implements its own key-repeat timers.

**evidence:** migueldeicaza/SwiftTerm Sources/SwiftTerm/iOS/iOSTerminalView.swift:109, 2395-2399, 3207-3236, 3250; iOSTextInput.swift:72

**confidence:** high

### 17. Keyboard layout guide

**topic:** Keyboard layout guide

**claim:** keyboardLayoutGuide tracks only a docked keyboard by default; followsUndockedKeyboard=true tracks floating or undocked keyboards.

**evidence:** UIKeyboardLayoutGuide.followsUndockedKeyboard doc

**confidence:** high

### 18. iOS 26 accessory view regression

**topic:** iOS 26 accessory view regression

**claim:** On iOS 26, inputAccessoryView no longer sits flush with the system keyboard (rounded margin, Liquid Glass wrapper).

**evidence:** developer.apple.com/forums/thread/787687 'inputAccessoryView no longer integrates seamlessly with system keyboard'

**confidence:** medium

### 19. Pasteboard

**topic:** Pasteboard

#### claim

Programmatic reads of the general pasteboard from another app raise an approval alert (iOS 16+). Cmd-V and system controls count as user intent. UIPasteControl pastes without a prompt.

#### evidence

UIPasteboard doc ('system-provided control or pressing Command-V'); UIPasteControl doc ('In iOS 16 and later, programmatic pasting raises a user alert')

**confidence:** high

### 20. Export compliance

**topic:** Export compliance

#### claim

Without ITSAppUsesNonExemptEncryption, App Store Connect asks the compliance questionnaire on each upload. NO means no encryption or only exempt encryption. Blink Shell (SSH/mosh) ships with false.

#### evidence

ITSAppUsesNonExemptEncryption doc; complying-with-encryption-export-regulations doc; blinksh/blink Blink/Info.plist '<key>ITSAppUsesNonExemptEncryption</key><false/>'

**confidence:** medium

### 21. Upload tools

**topic:** Upload tools

#### claim

Apple lists Xcode, altool, Transporter and the App Store Connect API (POST /v1/buildUploads) as upload methods; Transporter can use the API JWTs.

**evidence:** developer.apple.com/help/app-store-connect/reference/upload-tools

**confidence:** high

### 22. Secure Enclave

**topic:** Secure Enclave

#### claim

The Secure Enclave supports only NIST P-256 keys, generated inside the enclave and never exported. Ed25519 SSH keys therefore cannot be in the Secure Enclave; ecdsa-sha2-nistp256 can.

#### evidence

developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave: 'Works only with NIST P-256 elliptic curve keys … Can't encode preexisting keys'

**confidence:** high

### 23. Keychain accessibility

**topic:** Keychain accessibility

**claim:** kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly items are accessible after first unlock until reboot and do not migrate to a new device.

**evidence:** kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly doc

**confidence:** high

### 24. Swift toolchain

**topic:** Swift toolchain

**claim:** Swift 6.4.2 (2026-10-30) is current; official Docker tags include 6.4.2-noble.

**evidence:** github.com/swiftlang/swift releases; hub.docker.com library/swift tags '6.4.2-noble 2026-10-30'

**confidence:** high

### 25. Tooling versions

**topic:** Tooling versions

**claim:** XcodeGen 2.46.0 (2026-07-16), Tuist 4.216.1, fastlane 2.241.2 (preinstalled on macos-26), xcbeautify 3.2.1 preinstalled.

**evidence:** GitHub releases APIs; macos-26-arm64-Readme.md lines 82-84

**confidence:** high

### 26. Xcode Cloud

**topic:** Xcode Cloud

**claim:** 25 Xcode Cloud compute hours/month are included with the Apple Developer Program.

**evidence:** developer.apple.com/news?id=ik9z4ll6

**confidence:** medium

## recommendations

- Minimum deployment target: iOS/iPadOS 18.0. Build with Xcode 26.6 on runs-on: macos-26 and pin it with xcode-select. Add a continue-on-error canary job on runs-on: xcode-27 to catch iOS 27 SDK breakage before Apple raises the upload minimum (expected around spring 2027).
- Use a scene-only lifecycle from day 1 (UIApplicationSceneManifest plus UISceneDelegate, UIApplicationSupportsMultipleScenes=YES). Map each scene to a mosh session UUID through stateRestorationActivity or session.userInfo, but keep the authoritative session state in the app's own atomic file.
- Persist mosh resume state (host, port, key, next send seq with a reserved block of say 1024, state numbers, terminal size) on every state change with a rate limit, and again in sceneWillResignActive under beginBackgroundTask. Write with .atomic and .completeFileProtectionUntilFirstUserAuthentication. Put the key in Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
- On each foreground transition, throw away any old socket and create a new NWConnection UDP to the address SSH actually connected to (supports NAT64), then send immediately. Use pathUpdate, viability and betterPath handlers to re-create the connection when roaming.
- Define a DatagramTransport protocol in the core package, implemented with NWConnection on iOS and POSIX sockets on Linux. Adopt SwiftNIO (NIOTS datagram) only if the SSH library already depends on NIO.
- Add NSLocalNetworkUsageDescription. Expect the first UDP send to a LAN host to fail while the prompt is showing, and retry. Hosts reached over Tailscale or cellular will not prompt.
- Input view: a UIView adopting UITextInput, with all smart and autocorrect traits off. Handle Esc, Ctrl, Alt, arrows and F-keys in pressesBegan with app-managed repeat timers; use UIKeyCommand only for app shortcuts. Pin the key bar to keyboardLayoutGuide with followsUndockedKeyboard=true instead of relying on inputAccessoryView, given the iOS 26 styling regression. Recompute the grid from scene bounds for Stage Manager.
- Clipboard: honor OSC 52 writes only while foreground-active, with a size cap and an optional per-host toggle. Do not answer OSC 52 read queries silently. Paste via UIResponder.paste(_:) / Cmd-V / UIPasteControl, wrapped in bracketed paste when mode 2004 is set.
- Project tooling: XcodeGen project.yml plus a local SwiftPM package holding all logic. Gitignore the .xcodeproj and run `brew install xcodegen && xcodegen` in CI.
- Signing: automatic signing with a Team App Store Connect API key (.p8 in a secret) using -allowProvisioningUpdates and the -authenticationKey* flags for both archive and exportArchive. Upload with `xcrun altool --upload-package --apiKey --apiIssuer`, or ExportOptions destination=upload. Keep a manual .p12/profile path documented as the fallback.
- Build number: CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER plus an offset; marketing version in project.yml.
- Set ITSAppUsesNonExemptEncryption explicitly after the owner reviews EAR (Blink precedent is false). Consider excluding France or filing an ANSSI declaration.
- CI artifacts for the Linux developer: XCUIScreen screenshots as XCTAttachment(.keepAlways), exported with `xcrun xcresulttool export attachments`, plus `simctl io booted recordVideo`, uploaded with actions/upload-artifact. Run on an iPhone 17 and an iPad Pro 11-inch (M5) simulator.
- Keep the repo public if acceptable, so standard macOS minutes are free. Otherwise budget about $0.06/min and run iOS jobs only on PRs and main, with all logic tests in the Linux swift:6.4.2-noble container.
- For keys: generate Ed25519 (swift-crypto Curve25519.Signing) stored in Keychain, and optionally Secure Enclave P-256 (ecdsa-sha2-nistp256) keys on device only. Gate the Secure Enclave on SecureEnclave.isAvailable, which is false on the simulator.

## risks

- Resuming a mosh session from a freshly launched process is not supported by stock mosh client semantics. A wrong or lost send-seq persistence reuses AES-OCB nonces under the same key, a catastrophic confidentiality failure, and the server ignores the address of old-seq packets, which breaks roaming.
- iOS 26/27 keyboard chrome changes (Liquid Glass wrapper, accessory margins, noisy keyboard frame notifications in windowed apps) may need per-version layout hacks; open forum reports have no Apple fix.
- xcodebuild cloud signing and upload with API keys has a history of forum-reported failures ('No Accounts with App Store Connect Access', missing profiles). Keep a manual-signing fallback.
- The Xcode 27 runner is preview-only (capacity and queueing issues). When Apple raises the upload minimum to the iOS 27 SDK, the release job must move to it.
- The App Store upload minimum will likely move to Xcode 27 / iOS 27 SDK around April 2027 (not verified).
- Export compliance is a legal determination. Setting ITSAppUsesNonExemptEncryption=false for an SSH/mosh app follows community practice, not Apple's explicit guidance, and France has separate controls.
- OSC 52 read support would trigger iOS paste prompts and is a data-exfiltration vector; silent writes from a compromised server can also overwrite the clipboard, and Universal Clipboard propagates it to other devices.
- The simulator cannot exercise the Secure Enclave, cellular, NAT64, Wi-Fi roaming or real Local Network prompts, so on-device TestFlight testing is mandatory for networking and lifecycle behavior.
- AES-128-OCB, the mosh cipher, is not available in CryptoKit or swift-crypto and needs a vendored implementation.

## unverified

- Exact backgroundTimeRemaining granted by beginBackgroundTask on iOS 26/27 (commonly about 30 s); Apple does not document a number.
- Date and contents of the next App Store Connect SDK minimum (presumably Xcode 27 / iOS 27 SDK around April 2027).
- Swift compiler version bundled with Xcode 26.6 and Xcode 27.x; this decides the lowest swift-tools-version to declare.
- Whether `xcodebuild -exportArchive` with ExportOptions destination=upload and -authenticationKey* flags reliably uploads to TestFlight with Xcode 26.6; forum reports are mixed.
- Status of `xcrun altool --upload-package` with --apiKey in Xcode 26.6/27, and current CLI syntax for Transporter (iTMSTransporter) and the new POST /v1/buildUploads flow.
- Whether Xcode Cloud workflows can be created without ever opening Xcode on a Mac.
- That `xcrun xcresulttool export attachments` exists with that exact syntax on Xcode 26.6.
- Typical CI duration (8-15 min) and per-run cost; these are estimates, not measurements.
- App Review guideline 2.5.4 wording against misuse of background audio or VoIP; not re-fetched.
- Whether disabling inlinePredictionType (iOS 17) and Writing Tools (iOS 18) traits is needed or sufficient for a terminal input view.
- SecureEnclave.isAvailable returning false on the simulator (general knowledge, not quoted from the docs).
- Tailscale's 1280-byte tunnel MTU (general knowledge).
- Whether UIPasteboard writes are allowed or silently dropped while the app is in the background.

