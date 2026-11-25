# Review of the first plan

> Addresses, ports and details of the author's own network were removed before publication.

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## reviews

### 1. item

**lens:** ios-swiftterm-claims

#### verdict

The library and iOS mechanics the plan relies on mostly exist as stated: every SwiftTerm 1.99.3 and swift-nio-ssh 0.15.1 API the plan names is present at those tags, and Apple's documentation supports the stage 1 resume hook, the Keychain and file-protection classes and the prompt-free paste paths. Stage 1 is sound without the journal. The most important correction is the section 7 template edit list: as written, every release run exits 1 on an entitlement preflight in release.yml, and several other hard-coded names and one missing xcodebuild flag would break the first CI builds. The second is that SwiftTerm keeps its own 500-line scrollback, local one-finger scrolling and reflow unless the plan turns them off, which contradicts "scrollback is tmux's job" and "copy covers the visible screen only".

#### issues

##### 1. release.yml needs more than working-directory: an entitlement preflight fails every release

**severity:** major

**title:** release.yml needs more than working-directory: an entitlement preflight fails every release

###### problem

Section 7 says of release.yml: "`working-directory: App`; nothing else." I read /home/trick/src/github.com/trickv/<the author's Swift app>/.github/workflows/release.yml in full. Its "Install provisioning profile" step runs PlistBuddy `Print :Entitlements:<required entitlement>` on the decoded profile and does `exit 1` with an `::error::` message when the entitlement is absent. The plan drops that entitlement and uses a new profile for us.v9n.ios-mosh, so this step fails on every run before the build starts. The same file also hard-codes `PP_NAME="<app>.mobileprovision"` (install step plus two `rm -f` cleanup lines) and the artifact name `<App>-ipa`.

###### fix

Replace the release.yml row in the section 7 table with: "`working-directory: App`; delete the `<required entitlement>` PlistBuddy check in the 'Install provisioning profile' step (keep the Name and Expires prints); rename `PP_NAME` and the two cleanup `rm -f` paths from `<app>.mobileprovision` to `ios-mosh.mobileprovision`; artifact name `IOSMosh-ipa`."

**verified:** True

##### 2. SwiftTerm 1.99.3 ships a build-tool plugin; neither template build passes -skipPackagePluginValidation

**severity:** major

**title:** SwiftTerm 1.99.3 ships a build-tool plugin; neither template build passes -skipPackagePluginValidation

###### problem

SwiftTerm v1.99.3 Package.swift (lines 91-92) attaches `plugins: [.plugin(name: "SwiftTermBuildInfoPlugin")]` to the SwiftTerm target unconditionally; Plugins/SwiftTermBuildInfoPlugin/plugin.swift is a BuildToolPlugin that generates two Swift files. Package plugins must be trusted before xcodebuild will run them; on a clean CI runner the documented fix is `-skipPackagePluginValidation` (Bitrise support article, error text `"<Plugin>" must be enabled before it can be used`). The two xcodebuild calls in /home/trick/src/github.com/trickv/<the author's Swift app>/.github/workflows/ios-build.yml do not pass it, and build_app in /home/trick/src/github.com/trickv/<the author's Swift app>/fastlane/Fastfile uses `xcargs` as a Hash, which cannot carry a bare flag (gym's options.rb has no plugin option; xcargs is a shell_string). I read all of these sources but did not reproduce the failure for this package. Related: SwiftTerm's own CI at this tag (.github/workflows/xcode.yml) builds only with Xcode 27.1 and has no Linux job, while the plan's runner is macos-26 and M3 depends on SwiftTerm's headless Terminal building on Linux.

###### fix

Add to section 7: "ios-build.yml: add `-skipPackagePluginValidation` to both xcodebuild calls. Fastfile: change build_app's xcargs from the Hash to the String `"-skipPackagePluginValidation MARKETING_VERSION=#{options[:version].shellescape} CURRENT_PROJECT_VERSION=#{options[:build_number].shellescape}"`." Add to M0: "M0 is done only when the placeholder SwiftTerm screen builds on the macos-26 runner for the simulator and the device SDK, and a target that imports SwiftTerm builds with `swift build` in the Linux container. If the runner's default Xcode cannot build the tag, select a newer Xcode in the workflow before changing the pin."

**verified:** True

##### 3. Section 7 edit list misses other hard-coded paths, scheme names and bundle ids

**severity:** major

**title:** Section 7 edit list misses other hard-coded paths, scheme names and bundle ids

###### problem

Read in the template at /home/trick/src/github.com/trickv/<the author's Swift app>: (1) .github/workflows/ios-build.yml hard-codes `-project <App>.xcodeproj -scheme <App>` in both xcodebuild calls, plus `<App>.xcresult` and artifact `<App>-xcresult`. (2) fastlane/Fastfile: the `repo_root` non-git fallback probes `ios/<App>/project.yml`; `xcodeproj_path`, `source_info_plist_path`, the icon check and `update_code_signing_settings(targets: [SCHEME])` all derive from SCHEME, so the project name, the app target and the source directory must all be `IOSMosh`. (3) ios/<App>/project.yml: an explicit `schemes:` block, test target bundle id `us.v9n.<app>.tests` and `TEST_HOST` naming <App>.app, `CODE_SIGN_ENTITLEMENTS`, `PRODUCT_NAME`, `info.path`, sources and excludes, iOS 16.0 in two places (`options.deploymentTarget` and `IPHONEOS_DEPLOYMENT_TARGET`), the Sentry package and `SentryDSN`, `NSPhotoLibraryAddUsageDescription`, `NSAppTransportSecurity`, `CFBundleDisplayName`, the `NSLocalNetworkUsageDescription` text, `UIApplicationSupportsMultipleScenes: true` (the plan has one scene), and a postBuildScripts step using `git -C "$SRCROOT/../.."`, which is one level too high once the project is at App/. There is no UI-test target, and the plan's CI tests are XCUITests. (4) .gitignore has four `ios/<App>/...` lines. (5) .github/workflows/ci.yml is Android and mock-server only. (6) xcodebuild resolves packages into a Package.resolved inside the generated, gitignored xcodeproj, so the root Package.resolved in the plan's paths filter does not pin the app build.

###### fix

Extend the section 7 table. ios-build.yml: "also `-project IOSMosh.xcodeproj -scheme IOSMosh` in both xcodebuild calls, the xcresult path and the artifact name". Fastfile: "also the `repo_root` fallback probe (`App/project.yml`) and the message texts; the project `name:`, the app target and the source folder must all equal SCHEME (`App/IOSMosh/`)". project.yml: "also the `schemes:` block, test target name, bundle id and `TEST_HOST`, `CODE_SIGN_ENTITLEMENTS`, `PRODUCT_NAME`, `info.path`, sources and excludes; both iOS 16.0 settings to 18.0; remove Sentry, `SentryDSN`, the Photos and ATS keys; rewrite `CFBundleDisplayName` and `NSLocalNetworkUsageDescription`; set `UIApplicationSupportsMultipleScenes: false`; change the postBuildScripts git path to `$SRCROOT/..` or delete the step; add a `bundle.ui-testing` target and list it in the scheme's test targets". New rows: ".gitignore: `ios/<App>/` prefixes become `App/`" and "ci.yml: not copied; core.yml replaces it". Add a step: "After copying, `grep -rni <the author's Swift app> .` returns nothing." Add: "Dependency pins for the app build: the local package's exact pins for SwiftTerm and swift-nio-ssh; transitive versions float, because Xcode's Package.resolved is inside the generated project."

**verified:** True

##### 4. SwiftTerm keeps its own scrollback, local scrolling and reflow unless the plan turns them off; its resize() resets cursor-key mode

**severity:** major

**title:** SwiftTerm keeps its own scrollback, local scrolling and reflow unless the plan turns them off; its resize() resets cursor-key mode

###### problem

SwiftTerm v1.99.3: TerminalOptions defaults to `scrollback: 500`. mosh never switches the client to the alternate screen, so every scroll in a mosh diff pushes rows into that buffer. iOS/iOSTerminalView.swift: the `allowMouseReporting` doc comment says that when the application has not requested mouse events "selection and scrolling are handled locally either way", and `disableMousePanGesture()` sets the scroll view's `panGestureRecognizer.minimumNumberOfTouches = 1`. So with mouse mode off a one-finger swipe scrolls a local history of partial mosh frames, which conflicts with "Scrollback is tmux's job", "Copy covers the visible screen only" and the PgUp/PgDn swipe. Buffer.swift: `isReflowEnabled` returns `hasScrollback`, so with scrollback on SwiftTerm also reflows on resize. Resize ordering: `layoutSubviews` -> `processSizeChange` resizes the buffer itself and then calls the delegate's `sizeChanged`; the plan's "clears SwiftTerm" names no mechanism. Apple/AppleTerminalView.swift lines 4768-4781: the public `resize(cols:rows:)` calls `terminal.softReset()`, and the soft-reset body in Terminal.swift sets `applicationCursor = false`, which undoes the plan's one-time `ESC[?1h`.

###### fix

Add under Drawing: "`SwiftTermSurface` calls `changeScrollback(nil)` when it creates the view. This removes local scrollback and turns reflow off (`Buffer.isReflowEnabled` is `hasScrollback`; `changeHistorySize(nil)` sets it false). The PgUp/PgDn swipe is the app's own one-finger pan recogniser, installed only while mouse mode is off." Replace "On a size change the surface clears SwiftTerm and repaints in full" with "SwiftTerm resizes its own buffer from the view bounds and then calls `sizeChanged`. On that callback the surface sets `lastShown` to 'not initialised', so the next `newFrame` emits its own reset, clear and full repaint. The surface never calls `TerminalView.resize(cols:rows:)`, `softReset()` or `resetToInitialState()`." Replace "`ESC[?1h` is sent to SwiftTerm once" with "`ESC[?1h` is sent when the view is created and again after any reset".

**verified:** True

##### 5. The simulator tests cannot read the screen or control the kill as written

**severity:** major

**title:** The simulator tests cannot read the screen or control the kill as written

###### problem

(a) M5 and the CI app tests assert on `terminalStateSnapshot()`, but tests that call `XCUIApplication.terminate()` run in the UI-test runner process, where that in-process API is unreachable. In iOS/iOSTerminalView.swift the view sets `isAccessibilityElement = true` and adopts `UIAccessibilityReadingContent` (`accessibilityContent(forLineNumber:)`, `accessibilityPageContent()`), with no `accessibilityValue` or `accessibilityLabel` carrying the screen text; that XCUIElement cannot read reading-content is general knowledge, not checked here. `feed(byteArray:)` is asynchronous, so a one-shot read is racy. (b) Resume test: nothing waits for the snapshot between "press Home" and `terminate()`. (c) Fallback test: Apple documents `terminate()` only as "an appropriate platform-specific mechanism terminates the process" (xcuiautomation/xcuiapplication/terminate()); it does not promise SIGKILL or say whether lifecycle callbacks run. If `sceneWillResignActive` ran first, the test would see a resume, not the fallback.

###### fix

Add to M5: "Debug builds started with the launch argument `-uiTestBridge` copy `visibleRowsText` into the `accessibilityValue` of a hidden element with identifier `screenText` on every display tick. UI tests read that element and assert with a polling expectation (`XCTNSPredicateExpectation`), never with a single read." Change the Resume line to: "connect, print `$$`, press Home, poll until `app.state` is `.runningBackground` or `.runningBackgroundSuspended` (5 s limit), `terminate()`, relaunch, print `$$`." Change the Fallback line to: "a debug launch argument makes the app call `kill(getpid(), SIGKILL)` two seconds after the session is up, while in the foreground (the same code as 'Crash now'); relaunch. The banner shows and a new session starts."

**verified:** True

##### 6. Error table: no signal for Local Network denial, and keyboard-interactive is not visible as a named method

**severity:** minor

**title:** Error table: no signal for Local Network denial, and keyboard-interactive is not visible as a named method

###### problem

(1) TN3179: LAN connections trigger the Local Network alert, the system "may deny the operation immediately, before the user has responded", and denial shows as `NWConnection.State.waiting` with `NWPath.UnsatisfiedReason.localNetworkDenied`. In swift-nio-transport-services (StateManagedNWConnectionChannel.swift) a waiting connection with `waitForActivity` on only fires the user event `NIOTSNetworkEvents.WaitingForConnectivity(transientError:)`; NIOTSConnectionBootstrap then fails with `ChannelError.connectTimeout` after its default 10 s. Without handling, a denied or slowly answered alert looks like "host unreachable". The error table has no row for it. (2) The alert itself fires `sceneWillResignActive` (Apple: called "for temporary interruptions, such as when displaying system alerts"), and the plan's handler quiesces and closes sockets. (3) swift-nio-ssh 0.15.1: `NIOSSHAvailableUserAuthenticationMethods` has only `.publicKey`, `.password` and `.hostBased`, so a server offering only keyboard-interactive appears as a set without `.publicKey` and `.password`, not as a named method. (4) With a pty requested, the remote's stderr arrives on the `.channel` stream with CRLF line ends. (5) TN3179: "The simulator doesn't support local network privacy", so none of this is testable in CI.

###### fix

Add an error-table row: "`WaitingForConnectivity` event seen and then connect timeout, target address is private or link-local | Local Network access is off or was not answered in time. Settings > Privacy & Security > Local Network, then retry". Change the last row's signal to "Server's method list contains neither publickey nor password (swift-nio-ssh drops unknown methods)". Add to bootstrap step 1: "Connect timeout is 30 s for private and link-local addresses, so the first Local Network alert can be answered." Add to step 4: "The pty merges stderr into the same stream and uses CRLF; the parser strips CR." Add to 'Leaving the foreground': "With no established session (bootstrap in flight) the handler does nothing, because system alerts also fire `sceneWillResignActive`." Add to the phone checks: "Deny Local Network once and confirm the error row; this cannot be tested on the simulator."

**verified:** True

##### 7. Long-press does not select directly at this tag

**severity:** minor

**title:** Long-press does not select directly at this tag

###### problem

The plan says "Long-press always selects locally, also while tmux or vim mouse mode is on." In SwiftTerm v1.99.3 iOS/iOSTerminalView.swift, `setupGestures()` installs a 0.7 s `UILongPressGestureRecognizer` whose handler shows the edit menu (Select, Select All, Paste) through `UIMenuController.shared`; selection starts only after "Select" is chosen, and `panSelectionGesture` is enabled only then. The recogniser is not gated on mouse mode, so that half of the claim holds.

###### fix

Replace the sentence with: "Long-press (0.7 s) opens SwiftTerm's edit menu (Select, Select All, Paste), also while tmux or vim mouse mode is on. Selection starts from Select and is extended by dragging. Direct long-press-to-select is not in v1."

**verified:** True

##### 8. Key bar: no mechanism named for hardware-keyboard detection, and the built-in accessory stays unless removed

**severity:** minor

**title:** Key bar: no mechanism named for hardware-keyboard detection, and the built-in accessory stays unless removed

###### problem

The plan says "With a hardware keyboard attached the bar collapses" but names no signal. Apple's `UIView.keyboardLayoutGuide` documentation describes position tracking only. `GCKeyboard.coalesced` (GameController, iOS 14+) is documented as "The keyboard currently connected to the device". SwiftTerm's iOS setup calls `setupAccessoryView()` (iOSTerminalView.swift, line 512), which installs `TerminalAccessory` as `inputAccessoryView`; the property is settable. If M7 adds `KeyBarView` without clearing it, both bars show. Not verified here: whether a `UIPasteControl` in the scrolling part of the bar still pastes without a prompt when partly clipped (the system requires the control to be visible), and that the edit-menu Paste item is prompt-free.

###### fix

Replace the hardware-keyboard bullet with: "A hardware keyboard is detected with `GCKeyboard.coalesced != nil` and the `GCKeyboardDidConnect` and `GCKeyboardDidDisconnect` notifications; the bar then collapses." Replace "Until M7 the app uses SwiftTerm's built-in `TerminalAccessory`" with "Until M7 the app uses SwiftTerm's built-in `TerminalAccessory`. M7 sets `terminalView.inputAccessoryView = nil` when `KeyBarView` is installed." In the key bar list, move Paste from the scrolling part to the fixed part, and add to the M7 phone checks: "Paste key, Cmd-V and edit-menu Paste each paste without the iOS prompt."

**verified:** True

#### confirmed

- SwiftTerm tag v1.99.3 exists; swift-tools-version 6.2, iOS 14 minimum, consistent with the plan's tools 6.2 and iOS 18 target.
- SwiftTerm `TerminalView.feed(byteArray:)` exists and is nonisolated, so the display tick can call it as planned.
- SwiftTerm delegate methods `send(source:data:)`, `sizeChanged(source:newCols:newRows:)` and `clipboardCopy(source:content:)` exist.
- SwiftTerm `pasteText(_:)` adds bracketed-paste markers when the remote enabled them and replaces ESC bytes, so the plan's own `ESC[201~` stripping is redundant but harmless.
- SwiftTerm `controlModifier` with `Notification.Name.terminalViewControlModifierReset` exists (and the `metaModifier` equivalent), as the key bar's sticky Ctrl needs.
- SwiftTerm `terminalStateSnapshot()` and `visibleRowsText(_:)` exist (in-process only).
- SwiftTerm `allowMouseReporting` exists; taps and one-finger pans become mouse reports only while the remote has mouse mode on, as the plan states.
- SwiftTerm `pressesBegan` handles hardware keys with repeat; Command-modified keys are left to the responder chain, so Cmd-V reaches `paste(_:)`.
- After `ESC[?1h`, SwiftTerm sends arrows as `ESC O A..D` (`applicationCursor ? moveUpApp : moveUpNormal`).
- SwiftTerm `changeScrollback(nil)` exists and disables scrollback (`Buffer.changeHistorySize` sets `hasScrollback = false`).
- SwiftTerm `HeadlessTerminal` and `Terminal` are compiled for Linux in the package (guarded only against iOS, Windows, WASI, Android), which M3's Linux grid comparison needs; upstream has no Linux CI job at this tag.
- `TerminalRenderView` is not needed at 1.99.3; `TerminalView` is the iOS view, a `UIScrollView` subclass.
- swift-nio-ssh 0.15.1: Ed25519 keys through `NIOSSHPrivateKey(ed25519Key:)`, password offers, and key-then-password through repeated `nextAuthenticationType(availableMethods:nextChallengePromise:)` calls.
- swift-nio-ssh 0.15.1: `validateHostKey(hostKey:validationCompletePromise:)`; the key serialises with `String(openSSHPublicKey:)`, so the SHA256 fingerprint is the hash of the base64-decoded second field.
- swift-nio-ssh 0.15.1: `PseudoTerminalRequest` with size, `ExecRequest`, `ExitStatus`, and separate `.channel` and `.stdErr` data types exist.
- swift-nio-ssh 0.15.1 depends on NIOCore only, so it runs over NIOTransportServices on iOS and NIOPosix on Linux; its swift-crypto range (1.0.0 up to 6.0.0) admits 5.x.
- swift-nio-ssh supports Ed25519 and ECDSA host keys only, so the 'only RSA host keys' error row is correct; `NIOSSHError` has `keyExchangeNegotiationFailure` to detect it.
- Apple docs: `sceneWillResignActive` is called before the transition to the background and is the documented place to save unsaved data, so the stage 1 snapshot hook is sound without the journal.
- Apple docs: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` items stay readable after the first unlock and do not migrate to a new device; `completeUntilFirstUserAuthentication` files stay readable while locked. The plan's rule 'a record needs key, counters and meta' is consistent with both.
- Apple docs: `UIPasteControl` pastes without the iOS 16 prompt, and Command-V counts as user intent.
- Apple docs: `XCUIElement.typeKey(_:modifierFlags:)` is listed for iOS and iPadOS; `XCUIApplication.wait(for:timeout:)` exists.
- TN3179: VPN and cellular interfaces are not local networks, so connecting to yellow over Tailscale raises no Local Network prompt, and LAN addresses do.
- Template: `runs-on: macos-26`, concurrency group `ios-release`, temporary keychain with `if: always()` cleanup, the eight secret names, and `bundle exec fastlane ios beta` match what the plan carries over.
- Template: version injection through `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` xcargs, `TARGETED_DEVICE_FAMILY "1"`, the AppIcon setting and the privacy manifest resource phase are present in the template's project.yml and Fastfile as the plan says.
- Template: Appfile needs only `app_identifier` changed (same team); Gemfile contains no app identifier and needs no change.
- Fastfile paths derived from SCHEME match the plan's `App/IOSMosh` layout once `ios_dir` points at `App`.

### 2. item

**lens:** executability

#### verdict

The architecture and the staged resume are sound: I reasoned the stage 1 cold start through against mosh 1.4.0's server rules and it does not need the journal in v1. The plan is not yet executable as written, because several exit tests cannot run, or would pass when the feature is broken. The single most important correction is the simulator test harness: the M5 to M7 tests need an XCUITest target, an out-of-process way to read the screen, and a fresh mosh-server per test (it exits after 60 s without a client), none of which the plan or the template provides. After that, fix the milestone order (M2 needs M3's screen model, M6 needs M8's probe) and the kill-loop rows that pass on a failed resume.

#### issues

##### 1. Simulator tests (M5, M6, M7) cannot run as written

**severity:** major

**title:** Simulator tests (M5, M6, M7) cannot run as written

###### problem

M5 passes port and key as launch arguments, types a command and asserts on `terminalStateSnapshot()`; the M6 and M7 rows use Home, `XCUIApplication.terminate()` and `typeKey`. Those are XCUITest calls, and an XCUITest runs outside the app process. `terminalStateSnapshot()` is an instance method of the in-process view (SwiftTerm v1.99.3, `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1785`), so such a test cannot call it. The template has only a `bundle.unit-test` target (`/home/trick/src/github.com/trickv/<the author's Swift app>/ios/<App>/project.yml:252`). Second, `mosh-server` exits when no client connects within 60 s (mosh-1.4.0 `src/frontend/mosh-server.cc:682`, `timeout_if_no_client = 60000`), so a server started by a workflow step does not survive the build and each test needs its own. Third, the plan does not say what a relaunch with the same launch arguments does (new session or resume), and the Fallback row needs a new session although the debug path skips SSH. Not verified: whether `terminate()` in the foreground delivers `sceneWillResignActive` first (if it does, the app snapshots and the Fallback test resumes instead), and whether `typeKey` works on the iOS simulator.

###### fix

Replace the first M5 bullet with: 'Simulator tests live in a new XcodeGen target `IOSMoshUITests` (`bundle.ui-testing`), run with `xcodebuild build-for-testing` then `test-without-building`. Reading the screen: with launch argument `-uiTesting 1` (debug builds) the app keeps a hidden accessibility element `terminal-text` whose value is the visible rows joined by newlines; UI tests assert on it, and `terminalStateSnapshot()` is used only by app-hosted unit tests. Servers: `scripts/mosh-spawner.py` runs on the runner at 127.0.0.1 during the test step; `/new` starts `mosh-server new -i 127.0.0.1` and returns port, key and PID, `/alive?pid=` says whether it still runs; each test asks for a server just before launch, because mosh-server exits after 60 s without a client. Debug launch arguments: `-debugMoshPort` and `-debugMoshKey` start a session only when no record exists; a launch without them resumes the stored record; `-debugFallbackPort` and `-debugFallbackKey` replace the SSH bootstrap in the fallback; `-debugCrashAfter N` aborts the process N seconds after it becomes active. First test: type the `hello-42` command and expect `hello-42` in `terminal-text`.' Add to M0: 'The placeholder app gets the UI-test target with one test (type `abc`, read `terminal-text`, one `typeKey`, one screenshot exported with `xcresulttool`), so harness problems show in week 1.' In Verification replace the Resume and Fallback rows with: 'Resume: connect, print `$$`, press Home, wait for `.runningBackground`, `terminate()`, relaunch without connect arguments, print `$$`. The values are equal and `/alive` reports the same server PID.' and 'Fallback: launch with `-debugCrashAfter 5` and the fallback arguments, wait for the crash, relaunch. The banner shows, `$$` differs and typing works.' In the M7 row add: 'The OSC 52 test runs first and then pastes into `cat -v`, so the pasteboard content is checked and was written by the app itself.'

**verified:** True

##### 2. Milestones depend on work scheduled in later milestones

**severity:** major

**title:** Milestones depend on work scheduled in later milestones

###### problem

All read in `/home/trick/.claude/plans/new-project-call-it-harmonic-moon.md`. (a) M2's exit ('sees `hello-42`', 'final screen correct', lines 439-441) needs `Applier` and `Framebuffer`, which are M3; `InputEncoder` is an M2 deliverable but sits in the M3 module `MoshTerminal` (line 102). (b) Section 1 says every send passes through `DurabilityGate` (line 134) and bootstrap step 5 writes the session record (line 275), but the gate's rules and `MoshResume` are M6, while M5 says a cold start means a new session. (c) M5 builds the host editor, keys and terminal screens; the list screen that leads to them (`SessionListViewController`) is M8. (d) Sending a Resize when the view size changes appears only under Appearance (M7, line 358), but the keyboard changes the row count from M5 on, and M5's exit test is tmux and vim on the phone. (e) Section 3 (M6) 'offers the SSH probe from section 4' (line 243); `ServerProbe`, 'End session' and 'Forget' are M8. Between M6 and M8 a session whose server is gone (host reboot) retries for ever with no way to discard it, and M7 is the 'daily driver' mark. (f) 'Install my key on this host' has no milestone, yet human step 6 uses it at M5.

###### fix

M2: replace 'sees `hello-42`' with 'finds the bytes `hello-42` in the received `HostBytes` (receiver states are opaque byte strings until M3)', and replace 'with the final screen correct' with 'with no stall over 30 s and the last typed marker found in the received bytes'. Add to M2: '`DurabilityGate` is implemented by `InMemoryGate` until M6; no session record is written before M6.' Add to M3: 'Re-run the M2 soak; the final client framebuffer equals `tmux capture-pane`.' Add to M5: '`SessionListViewController` as a plain host list (add, edit, connect); view size changes (keyboard, rotation) send a Resize debounced by 100 ms; "Install my key on this host".' Move `ServerProbe` and its exit test from M8 to M6, and add to M6: 'Under the "Last contact" banner a "Start new session" button marks the record dead and bootstraps again.' M8 becomes: 'Session list states, "End session", "Forget".'

**verified:** True

##### 3. Kill-loop rows pass on a failed resume or fail on a correct one

**severity:** major

**title:** Kill-loop rows pass on a failed resume or fail on a correct one

###### problem

Plan lines 516-528. (a) 'Same shell PID' does not prove a resume: the liveness row uses `tmux capture-pane`, so the loop runs in tmux, and a shell inside tmux keeps its PID when the client falls back to a new `mosh-server`. The same holds for the M6 phone row when the host uses the recommended `tmux new -A -s main`. (b) Exactly-once and liveness cannot share a session as written: while `cat > log` holds the foreground, a typed `echo resumed-$N` goes into the log and never runs. There is no sync point before the log is compared. The duplicate hazard (input delivered to the server, ack not seen, then resume) almost never occurs on loopback, so the row does not exercise it. (c) 'client screen equals `tmux capture-pane`' fails on a correct client: the client screen includes tmux's status line, and `capture-pane` drops trailing spaces unless `-N` is given (tmux man page on yellow). (d) 'strictly increase' is not the N1 property (uniqueness is), and in the reordering variants a capture taken after the netem qdisc is out of order for a correct client (capture point not verified). (e) 'torn counters slot: Fallback' contradicts the record design, where a torn write leaves the older slot valid (line 195). (f) The CI short run includes a loss variant; netem on GitHub's Ubuntu runner is not verified. On yellow `sch_netem` is on disk but not loaded (`lsmod`).

###### fix

Replace the matching table rows with: '| Quiesce, `SIGKILL`, resume, 200 times | `moshcli resume` exits 0 and reports a resume; the `mosh-server` PID from `meta.json` is alive and unchanged; shell `$$` unchanged |', '| Exactly-once input: tmux window 0 runs `cat > log`; line N is typed before each kill and line N+1 after each resume. Every fifth kill uses `quiesce --after-send` (send the pending state, read nothing, snapshot) | After the loop type `END`, `wait-ack`, then `log` equals the typed lines byte for byte |', '| Liveness | The line typed after each resume is echoed on the client screen within 5 s |', '| Screen equality: tmux `status off`; every tenth iteration window 1 prints `seq 1 200` before the kill | After 500 ms without a new state, client rows with trailing spaces trimmed equal `tmux capture-pane -p` |', '| Nonce: `moshcli --seq-log` plus `tcpdump` of the whole run | No client-to-server sequence number appears twice, and each process generation starts above the last number of the one before |', '| Damaged record | One torn slot: the other slot is used and the result is a correct resume or a clean fallback, as its dirty flag says. Both slots bad, missing key or missing snapshot: fallback, no datagram sent |'. Change the heading to '(`scripts/killloop.sh`, yellow; 20 iterations without netem in CI)'. In the M6 phone row add 'and no "could not be resumed" banner'.

**verified:** True

##### 4. release.yml needs more than one edit, and a pushed tag does not trigger it

**severity:** major

**title:** release.yml needs more than one edit, and a pushed tag does not trigger it

###### problem

Section 7 says the only edit to `release.yml` is `working-directory: App` ('nothing else', plan line 376). In `/home/trick/src/github.com/trickv/<the author's Swift app>/.github/workflows/release.yml`, lines 188-200 decode the provisioning profile and `exit 1` when it lacks `<required entitlement>`. The plan drops that entitlement, so the first release fails at this step. Lines 179, 289 and 303-304 carry `<app>.mobileprovision` and `<App>-ipa`. The trigger (lines 8-16) is `release: types: [published]` plus `workflow_dispatch` with a `version` input, so M0's 'Then tag `0.0.1`' (plan line 430) starts nothing. The version step strips an optional leading `v` (line 123).

###### fix

Replace the Edits cell of the `release.yml` row with: '`working-directory: App`; delete the `<required entitlement>` preflight block; rename `PP_NAME` and the two cleanup paths to `ios-mosh.mobileprovision`; artifact name `IOSMosh-ipa`. Keeps `macos-26`, the `ios-release` concurrency group, the version check, `APP_BUILD = run number`, the temporary keychain, and cleanup with `if: always()`'. Replace 'Human steps 1-5 below. Then tag `0.0.1`.' with: 'Human steps below. Then publish GitHub Release `0.0.1` (`gh release create 0.0.1 --title 0.0.1 --notes "TestFlight placeholder"`). `release.yml` runs on a published release or on `workflow_dispatch` with a `version` input; a pushed tag alone does nothing.'

**verified:** True

##### 5. moshcli test interface, corpus format and oracle build are not specified

**severity:** major

**title:** moshcli test interface, corpus format and oracle build are not specified

###### problem

The `moshcli` row (plan line 107) lists `handshake`, `bootstrap`, `connect`, `resume`, `soak`, `--crashpoint N`. `killloop.sh`, `netem.sh`, `itest.sh` and `record-golden.sh` must type input, wait for an acknowledgement, quiesce on demand, print the screen and record received diffs. None of that is defined, so the harness behind the M2, M3 and M6 exit tests has to be invented. The corpus format and the oracle's input are not stated. `Tools/mosh-oracle` as 'mosh 1.4.0 `src/terminal` plus a small `main.cc`' does not compile alone: at tag mosh-1.4.0, `src/terminal/terminalframebuffer.h` includes `shared.h` (from `src/util`), `src/terminal/terminaldisplayinit.cc` includes `config.h` and calls `setupterm` and `tigetstr` (curses), and `src/statesync/completeterminal.cc` includes `hostinput.pb.h` (protoc output). `docker/Dockerfile.dev` (line 112) lists none of the packages for that, and no `vim` or `htop` although the corpus records them. Not verified: whether the base image already has `procps` for the `ps -p PID -o comm=` check, and the package list below has not been built.

###### fix

Replace the `Sources/moshcli` row with: 'Test executable. `handshake`; `bootstrap`; `connect` and `resume` with `--script FILE` (one command per line: `type TEXT`, `key NAME`, `resize W H`, `wait-ack`, `expect TEXT TIMEOUT`, `settle MS`, `dump-screen FILE`, `quiesce`, `quiesce --after-send`, `sleep MS`), `--record DIR` and `--seq-log FILE`; `soak`; `--crashpoint N` (`--crashpoint list` prints the points). `SIGUSR1` quiesces. Exit codes: 0 done, 3 fallback needed, 4 server ended.' Add to M3: 'Corpus format: `--record DIR` writes, per received instruction, `old_num`, `new_num` and the raw `HostBytes` strings in arrival order, plus the terminal size. `mosh-oracle` reads the same files, applies each diff to its copy of state `old_num` through mosh's parser and emulator, and prints one framebuffer JSON per `new_num`. The Swift test does the same and compares cell by cell.' Replace the `Tools/mosh-oracle` row with: 'mosh at tag `mosh-1.4.0` built in the image with its own `./autogen.sh && ./configure && make`, plus a small `main.cc` linked against the static libraries that build produces. Linux, tests only.' In the `docker/Dockerfile.dev` row add: `vim htop procps autoconf automake pkg-config protobuf-compiler libprotobuf-dev libncurses-dev libssl-dev`.

**verified:** True

##### 6. Human-only list: export compliance is decided silently; release publishing and the certificate are not covered

**severity:** major

**title:** Human-only list: export compliance is decided silently; release publishing and the certificate are not covered

###### problem

Section 6 (plan line 364) sets `ITSAppUsesNonExemptEncryption = false` and the human list (lines 483-499) has no step for it. The template sets `false` with this comment (`/home/trick/src/github.com/trickv/<the author's Swift app>/ios/<App>/project.yml:151-157`): the only crypto is OS-provided TLS, 'Revisit if custom crypto is ever added — this is a regulatory declaration attached to the binary.' iOS-mosh ships its own OCB3 mode and an SSH client, so the template's reason does not carry over, and the declaration is Trick's to make. The earlier design had this as a human step. Also missing: who publishes releases (each one uploads a build to TestFlight; M6's 'after a TestFlight update' check needs a second one); step 2 does not say the profile must be made with the distribution certificate already stored in `BUILD_CERTIFICATE_BASE64`, without which signing fails in M0; and a root step on yellow if netem does not autoload (`sch_netem` exists for the running kernel but is not loaded).

###### fix

Add under 'Needed for M0': 'Decide the export-compliance answer. The app contains its own AES-OCB mode and an SSH client. Either confirm `ITSAppUsesNonExemptEncryption = false` (exempt), or leave the key out and answer the question in App Store Connect for each build.' and 'Say whether this session may publish GitHub Releases (each one uploads a build to TestFlight), or publish them yourself: `0.0.1` in M0, one per milestone from M5, two in M6 for the update check.' and 'Only if the M0 netem check fails: run `sudo modprobe sch_netem` on yellow.' In step 2 append: 'using the same Apple Distribution certificate as the other apps (the one behind `BUILD_CERTIFICATE_BASE64`); download the profile for step 4.' In section 6 change the Info.plist line to '`NSLocalNetworkUsageDescription`; `ITSAppUsesNonExemptEncryption` as decided in the human steps'. Renumber the M0 reference 'Human steps 1-5'.

**verified:** True

##### 7. Misplaced components, tests without a home, and requested features without an automated test

**severity:** minor

**title:** Misplaced components, tests without a home, and requested features without an automated test

###### problem

(a) `ClipboardPolicy` is listed under `App/IOSMosh` (plan line 109), but M7 puts its logic in `MoshSession` so Linux tests cover it, and Verification runs 'clipboard policy tests' in `swift test`. (b) M3's Linux test 'DisplayDiff output fed into SwiftTerm's headless Terminal' has no target: `App/SurfaceKit` is 'the only file that imports SwiftTerm', and the feed rules worth testing (cursor position after wide cells, modes passed through, title, bell and OSC 52 left out) live in `SwiftTermSurface`, which is app code. SwiftTerm v1.99.3's `Package.swift` does exclude its Apple, Mac and iOS directories on Linux, so a Linux test target is possible. (c) `InputEncoder` has no stated job: section 2 says 'No app-side encoders' and section 5 says SwiftTerm produces the key bytes. (d) Verification says `itest.sh` bootstrap and error-table tests run on 'Linux and macOS'; the macOS runner has no test sshd, and section 7 says the macOS job only runs `moshcli` against Homebrew's `mosh-server`. (e) Keychain storage (`KeychainKeyStore`) and public-key export, both requested features, have no automated test; their first run is Trick on the phone in M5. (f) Themes, a bundled powerline font with a licence check, and cursor style are unrequested and sit in M7, before the daily-driver mark.

###### fix

Layout: move `ClipboardPolicy` to the `Sources/MoshSession` row and name `ClipboardWriter` (UIPasteboard and toast) in `App/IOSMosh`. Add `SurfaceFeed` to `Sources/MoshTerminal` ('builds the byte feed for SwiftTerm from two framebuffers, with the rules in section 2'), add to the `Package.swift` row 'test-only target `SurfaceFeedTests` depends on SwiftTerm exact 1.99.3', and reword the SurfaceKit row to 'the only app file that imports SwiftTerm'. Delete `InputEncoder` from the layout and from M2, or move it to `Sources/moshcli` as 'key names to bytes for scripts'. Verification: change the `itest.sh` line to end '(Linux: all of it. macOS: handshake and `hello-42` only)'. Add to M5: 'App-hosted unit test `KeychainKeyStoreTests` (generate, store, load in a new store instance, delete) and a test that the Keys screen's Copy action puts a line starting `ssh-ed25519 AAAA` on the pasteboard.' In M7 replace '`AppearanceSettings`' with 'font size and bell haptic', and add after M8: 'Themes, bundled font, cursor style.'

**verified:** True

##### 8. Template edits the plan misses, CI image details, and length

**severity:** minor

**title:** Template edits the plan misses, CI image details, and length

###### problem

Read in the template at `/home/trick/src/github.com/trickv/<the author's Swift app>`: `ios/<App>/project.yml` has a Sentry package, target dependency and `SentryDSN` key (lines 47-48, 106-107, 197), a `CODE_SIGN_ENTITLEMENTS` setting (line 202) and a post-build script using `git -C "$SRCROOT/../.."` (line 243), which points above the repo once the project is at `App/project.yml`. `fastlane/Fastfile` finds the repo root by probing `ios/<App>/project.yml` (line 67). `.github/workflows/ios-build.yml` uploads the xcresult only `if: failure()` (line 135), so the screenshots the plan wants never appear on green runs, and its paths filter includes the workflow file itself (lines 17-24), which the plan's filter drops. The plan does not say how `core.yml` gets 'the dev image' or that it needs `NET_ADMIN`. The official `swift:6.2` tag is Ubuntu 24.04, whose mosh is 1.4.0; a different base could change the mosh version silently. Length: the plan is 614 lines; the stage 2 journal rules (lines 245-260) are not needed to approve v1, and 'Known traps' (lines 390-394) and 'Per-host fields' (lines 278-281) are long sentences that hide separate items.

###### fix

`project.yml` row, Edits: add 'drop the Sentry package, its dependency and `SentryDSN`; drop `CODE_SIGN_ENTITLEMENTS` and the entitlements file; change the post-build `git -C "$SRCROOT/../.."` to `"$SRCROOT/.."`; add the `IOSMoshUITests` target'. `Fastfile` row: add '`repo_root` probe path `App/project.yml`'. `ios-build.yml` row: add '`.github/workflows/ios-build.yml` and `scripts/mosh-spawner.py` in the paths filter; upload the xcresult and exported screenshots with `if: always()`'. `core.yml` paragraph: add 'The Linux job builds `docker/Dockerfile.dev` with the Actions layer cache and runs it with `--cap-add NET_ADMIN`. The base image is a `-noble` tag, and `itest.sh` first checks that `mosh-server --version` prints 1.4.0.' Replace plan lines 245-260 with: 'Stage 2 (M9) replaces the dirty rule with a write-ahead journal, so a kill in the foreground is also resumable. The design is kept in `docs/RESUME.md`. The stage 1 snapshot is the stage 2 checkpoint, so the record format carries over.' Turn 'Known traps' and 'Per-host fields' into bullet lists.

**verified:** True

#### confirmed

- Every requested feature maps to a named milestone: mosh-only transport (M2) with resume (M6), keyboard extensions (SwiftTerm accessory from M5, key bar and hardware keys in M7), OSC 52 (M7), key generation (M4), Keychain storage and public-key export (M5). All have a test except Keychain storage and export (see issues).
- Stage 1 resume is sound without the journal. Reasoned through, not tested: the rebuilt sender `[{A, []}, {nextNum, pending}]` keeps every earlier server-held input list as a prefix, the client still holds every state the server may diff against, and the dirty flag plus reserve-ahead counters turn every crash window into a resume or a clean fallback.
- Template facts in section 7 match `/home/trick/src/github.com/trickv/<the author's Swift app>`: `macos-26`, the `ios-release` concurrency group, the version check, build number from the run number, temporary keychain, `if: always()` cleanup; Fastfile constants `APP_IDENTIFIER`, `PROFILE_NAME`, `SCHEME` and `ios_dir`; `TARGETED_DEVICE_FAMILY "1"`, the AppIcon setting, version placeholders and the privacy manifest resource phase in `project.yml`.
- The eight GitHub secret names in the plan are exactly the ones `release.yml` in the template reads.
- SwiftTerm tag `v1.99.3` exists, uses tools 6.2 and excludes its Apple, Mac and iOS directories on Linux. It has `feed(byteArray:)`, `terminalStateSnapshot()`, `controlModifier` with a reset notification, `TerminalAccessory`, `pasteText` and hardware-key handling with repeat, as the plan assumes.
- swift-nio-ssh `0.15.1` exists (tools 6.1, iOS 13+) and accepts swift-crypto `1.0.0..<6.0.0`; swift-crypto `5.0.0` exists and the package has a `CryptoExtras` product (seen at 4.0.0). The pinned set can resolve.
- mosh-server 1.4.0 (`src/frontend/mosh-server.cc`): `MOSH CONNECT <port> <key>` goes to stdout (line 441), `[mosh-server detached, pid = N]` to stderr (line 464), the UTF-8 locale error text is as quoted (line 355), the remote command is exec'd (line 601), and the 60 s wait for a first client in the appendix is right (line 682).
- yellow can host the core work: x86_64, Docker [release removed for publication] [account details removed for publication], `/usr/bin/mosh-server` 1.4.0, `tc`, `tcpdump` and `tmux` present, `sch_netem` module on disk for the running kernel (not loaded yet). `swift` is not on the host, so the dev container is required, as the plan says.
- The official `swift:6.2` image is Ubuntu 24.04 (docker-library official-images). yellow's mosh-server is 1.4.0.
- tmux `capture-pane` drops trailing spaces unless `-N` is given (man page on yellow), which the screen-equality fix relies on.
- The plan's phone-first order holds for M0: the placeholder release exercises signing, the runner and App Store Connect before any protocol code, once the release.yml edits and trigger are corrected.

