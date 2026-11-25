# Research: prior_art

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

Blink Shell (GPLv3 plus App Store and OpenSSL additional terms, active as of 2026-11-09) is the closest prior art. It links a prebuilt mosh.xcframework (blinksh/mosh-apple release v1.4.0+blink-18.4.5, published 2026-03-14), built from the blinksh/mosh fork at SHA 3640d366. The fork exposes a C entry point, mosh_main(FILE* in, FILE* out, winsize*, state_callback, ctx, ip, port, key, predict, encoded_state, size, predict_overwrite). Blink suspends a session by writing the mosh escape key followed by Ctrl-Z (0x1E 0x1A) into the client's stdin. The fork then serializes a Restoration::Context protobuf (crypto seq, current_state_patch, received and sent states) and calls pthread_exit. On relaunch the client is restored from that blob, which is how a mosh session survives the app being killed. Persisting the crypto seq is essential. Upstream mosh-server only roams to a new client address for packets with seq >= expected_receiver_seq (network.cc:515), and reusing a seq also reuses an AES-OCB nonce under the same key.

Upstream mosh 1.4.0 already forwards OSC 52 copy, but only the "52;c;" form, and the OSC string is capped at 16 KiB (MAXIMUM_CLIPBOARD_SIZE). Mosh keeps its own clipboard state, which caused Blink's spurious-paste bug (#1205). Blink's hterm decodes OSC 52 as Latin-1, so UTF-8 text breaks (#1026, still open).

The niche is no longer empty. Moshi, La Terminal, Spectty (MIT) and Moshpit all advertise mosh sessions that resume, including after the app is killed.

Independent implementations: there are two pure-Swift ones. wiedymi/swift-mosh (MIT) has a snapshot/restore API. Its client discards packets whose old_num is newer than the latest state, but otherwise forwards each diff's bytes no matter which state the diff was built from. It keeps no copy of earlier screen states, so it can draw the screen wrong whenever packets are lost or arrive out of order. Spectty (MIT, says it is clean-room) does not save the send seq when it persists a session. mosh-go (MIT) and mosh-rs (GPL, an admitted port) are useful as readable references. A line-by-line port is a derivative work and must stay under GPLv3, using the mosh iOS exception. A clean reimplementation from a protocol description can use any licence.

## details

## 1. Blink Shell architecture (github.com/blinksh/blink, branch `raw`, GPL-3.0, pushed 2026-11-09, about 7.0k stars)

### Mosh client build
- `xcfs/Package.swift` pulls in prebuilt SwiftPM binaryTargets:
  - `mosh`: https://github.com/blinksh/mosh-apple/releases/download/v1.4.0+blink-18.4.5/mosh.xcframework.zip, checksum d6dce766...
  - `Protobuf_C_`: blinksh/protobuf-apple v3.21.1
  - `LibSSH`: blinksh/libssh-apple v0.12.0
  - `OpenSSH`: blinksh/openssh-apple v8.9.0+blink-18.7.0
  - `openssl`: krzyzanowskim/OpenSSL 3.6.0001
  - ios_system and others
- `get_frameworks.sh` only runs `swift package resolve`.
- blinksh/mosh-apple (pushed 2026-03-14; the repo declares no licence, but its contents are GPLv3 mosh):
  - Releases: v1.4.0+blink-18.4.5 (Latest, 2026-03-14), v1.4.0+blink-17.3.0 (2024-04-08), v1.4.0, v1.3.2.
  - `Sources/build/main.swift` (FMake) clones `https://github.com/blinksh/mosh.git` at SHA `3640d36678dc415ba24f03d7f6fb20a0dac1fa6b`.
  - It runs `./autogen.sh && ./configure --disable-server --disable-client --enable-ios-controller --host=$arch-apple-darwin` with `ac_cv_path_PROTOC=/opt/homebrew/opt/protobuf@21/bin/protoc` and the deployment target set to iOS 14.0.
  - It then combines libmoshcrypto, libmoshnetwork, libmoshprotos, libmoshstatesync, libmoshterminal, libmoshiosclient and libmoshutil into libmosh.a with `libtool -static`.
  - The build needs macOS (xcrun, Homebrew). It can run on GitHub Actions macOS runners; the repo has a `.github/workflows/build.yml`.
- blinksh/mosh (GPL-3.0). Branches: ios, ios-state, ios-state-master, mosh+blink, mosh-1.4, mosh-master. The pinned commit is "Merge remote-tracking branch 'blinksh-server/mosh+blink'", dated 2026-03-14.
- The iOS files are `src/frontend/iosclient.{h,cc}`, `moshiosbridge.{h,cc}`, `mosh-ios-controller.cc`, `src/terminal/terminaldisplayinit_ios.cc` and `src/protobufs/restoration.proto`.

### Bridge API (moshiosbridge.h at 3640d366)
```c
int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
    void (*state_callback)(const void *, const void *, size_t), void *state_callback_context,
    const char *ip, const char *port, const char *key, const char *predict_mode,
    const char *encoded_state_buffer, size_t encoded_state_size, const char *predict_overwrite);
```
- The old `ios` branch has the 7-argument version without state support. Use the state-capable commit.

### Restoration protobuf (restoration.proto)
```
message Context {
  required uint64 seq = 1;
  required bytes current_state_patch = 2;
  repeated TimestampedState received_states = 3;
  repeated TimestampedState sent_states = 4;
}
message TimestampedState {
  optional uint64 num = 1;
  optional uint64 timestamp = 2;
  required bytes patch = 3;
}
```
- Timestamps are stored as offsets from now.
- On restore, `iOSClient::main_init`:
  - calls `Crypto::set_seq(context.seq())`;
  - rebuilds each received state as a `Terminal::Complete` via `apply_string(init_diff)`;
  - constructs `Network::Transport(blank, local_terminal, key, ip, port, sent_states, received_states)`. This is a constructor the fork added.

### Suspend trigger
- In iosclient.cc, after the escape key (0x1E), the byte 0x1A builds the Context, calls `network->start_shutdown()`, records `set_seq(Crypto::seq())`, invokes `state_callback(...)` and then calls `pthread_exit`.
- Blink side, `Blink/Commands/mosh/mosh.swift`:
  - `suspend()` calls `device.pauseViewOutput()`, writes `"\u{1e}\u{1a}"` and waits on a semaphore with a 2.0 s timeout.
  - `onStateEncoded` stores the blob with `sessionParams.putEncodedState`.
  - `kill()` writes ESC-. and sends `pthread_kill(tid, SIGINT)`.
  - `sigwinch()` sends `pthread_kill(tid, SIGWINCH)`.
- The mosh client runs on its own pthread with FILE* pipes. Blink's TermDevice bridges those pipes to hterm.

### Lifecycle
- `Blink/SceneDelegate.swift`:
  - `sceneWillEnterForeground` calls `machine.resume()`, but only if `isProtectedDataAvailable`.
  - `sceneDidDisconnect` calls `machine.suspend()`.
  - `suspendActiveMachines()` exists "for when the per-scene background suspend won't fire (foreground terminate, or the protected-data lock deadline)".
- `AppDelegate.m`:
  - begins a background task named "BackgroundExtension" with a grace timer;
  - suspends all machines from `applicationProtectedDataWillBecomeUnavailable` and `applicationWillTerminate`.
- `Blink/Machine.swift`: `MachineState` is JSON-encoded to one file per Machine, and session archives use NSKeyedArchiver (`suspendSession(with:)`).
- Lesson: save state before data protection locks the files, and do it within the background grace window.

### mosh-server bootstrap
- SSH is Blink's own `SSH/` Swift framework over LibSSH (blinksh/libssh-apple).
- Server arguments: `new -s -c 256 [-l LANG=..] [-p port] [-- exec]`, i.e. `mosh-server new -s -c 256 -l LANG=en_US.UTF-8`.
- Remote IP options: optionally `echo "MOSH SSH_CONNECTION $SSH_CONNECTION" && ...`. By default the IP comes from `client.clientAddressIP()`, the peer of the established SSH connection.
- Output is parsed with the regex `(?m)^MOSH CONNECT (\d+) (\S*)$`.
- `MoshBootstrap.swift` tries `UseMoshOnPath` (mosh-server on PATH) first. It falls back to `InstallStaticMosh`:
  - runs `uname && uname -m`;
  - downloads `mosh-server-1.4.0+blink-18.4.5-<platform>-<arch>` from github.com/blinksh/mosh-static-multiarch, SHA-256 pinned per platform (LinuxAmd64 01cada77..., LinuxArm64 1252d1db..., and others);
  - uploads it over SFTP to `~/.local/blink/mosh-server` and runs `chmod +x`.
- IPv6: Blink 17.2+ resolves the address through LibSSH (Happy Eyeballs) and adds IPv4/IPv6 flags (issue #269).

### Keyboard
- The terminal is hterm in WKWebView (`Resources/hterm_all.min.js`, `term.js`). Keys are handled in JS inside `KBWebView`.
- `KB/Native/Views/KBWebViewBase.m` and `KBWebView.swift` override `pressesBegan`/`pressesEnded`/`pressesCancelled`, use `UIKey.modifierFlags` and `UIKeyCommand` (`class BlinkCommand: UIKeyCommand`), and set `UITextInputTraits`.
- `Blink/SmarterKeys/SmarterTermInput.swift`:
  - On iPad the SmartKeys bar goes into `inputAssistantItem.trailingBarButtonGroups`, a `UITextInputAssistantItem` with a `UIBarButtonItemGroup`, and is cleared when a hardware keyboard is attached.
  - On iPhone it uses `inputAccessoryView`.
  - It calls `reloadInputViews` asynchronously, with the comment "Fixes crash for detaching/attaching KB".
- `Blink/KBTracker.swift`: "KBObserver class has been completely removed and replaced by UIKeyboardLayoutGuide integration".
  - It detects a hardware keyboard heuristically: `isHardwareKB = height < 150`.
- The legacy ObjC SmartKeys lives in Frameworks/SmartKeys (SKModifierButton and related).

### OSC 52
- hterm's `VT.OSC[52]` accepts `^[cps01234567]*;(.*)`, then does `atob`, `this.decode`, `copyStringToClipboard`.
- Blink overrides `copyStringToClipboard` to `postMessage('copy')`, and TermView.m sets `UIPasteboard.generalPasteboard`.
- `term_setClipboardWrite(false)` is the default at terminal ready.
- Paste-query (OSC 52 read) is not supported.

### Relevant Blink issues
| Issue | State / date | Summary |
|---|---|---|
| #2176 | open, 2026-05-05 | "Mosh restore stucked until returning to tab" |
| #2177 | closed, 2026-06-02 | iOS 26: blank shell on return from background |
| #2047 | closed | mosh unresponsive after restore |
| #1205 | closed | spurious OSC 52 paste after reconnect; mosh keeps its own clipboard state, so re-copying identical text is not re-emitted |
| #1026 | open, 2026-05-05 | OSC 52 UTF-8 decoded as Latin-1 |
| #2278 | open | iOS 26.6: copies only the last ~35 lines |
| #2293, #2289, #2296 | open | keyboard/mouse regressions |
| #2002 | open, 2026-11-10 | NoMoshServerArgs with a custom port range |
| #1122 | closed | iOS 14 background disconnects |

## 2. Upstream mosh facts that matter
- mosh 1.4.0 (released 2022-10-27; still the latest release in 2026) added OSC 52 copy, `--predict-overwrite` and true colour.
- `terminalfunctions.cc` `Dispatcher::OSC_dispatch` only accepts `52;c;` and stores the clipboard in the framebuffer.
- `terminaldisplay.cc` re-emits `\033]52;c;<b64>` when the clipboard changes.
- `terminaldispatcher.cc:45`: `MAXIMUM_CLIPBOARD_SIZE = 16*1024`. Longer OSC strings are silently truncated.
- Master (after 1.4.0) also parses OSC 8 hyperlinks.
- Receiving (`networktransport-impl.h` `Transport::recv`):
  - drops a diff unless `inst.old_num()` matches a state in `received_states`;
  - applies the diff to that old state.
- The sender (`transportsender-impl.h` `update_assumed_receiver_state`) optimistically diffs from unacked states sent less than `timeout()+ACK_DELAY` ago.
- So a correct client must keep framebuffers for multiple received states, i.e. its own emulator copies, not just a renderer.
- Roaming (`network.cc:515`): "don't use (but do return) out-of-order packets for timestamp or targeting". The server roams only when seq >= expected.
- Consequence: a relaunched client with a new UDP source port must continue the seq from where it left off, which means persisting the seq.

## 3. Other iOS apps (2026)
| App | Licence | Mosh | Resume after app kill | OSC 52 | Keys |
|---|---|---|---|---|---|
| Blink Shell | GPLv3, paid subscription | Yes | Yes, via the Restoration blob | Yes (UTF-8 bug) | Yes |
| Moshi (Moshi Tech Ltd, App Store id6757859949, v4.3.2) | Free + IAP, lifetime $249 | Yes | "Mosh Resume" from checkpoints; 3.15.0 notes "restore more reliably after restarting the app" | 3.2.1 fixes OSC 52 replaying stale data after restore | Keychain with Face ID |
| La Terminal (Xibbon, id1629902861, v2.0.10) | $4.99/mo, $19.99/yr, $99.99 lifetime | Added in 2.0, "survives device reboots or app termination, but with lower terminal fidelity" | Yes, per release notes | 2.0.4 asks for confirmation before remote clipboard reads | ed25519 generation (1.8.10), Secure Enclave |
| Prompt 3 (Panic) | Commercial | Mosh + Eternal Terminal since 3.0 (Jan 2024) | Not checked | Not checked | Not checked |
| Termius | Commercial | Free Starter plan includes Mosh; changelog fixes mosh hangs on multi-line paste | Not checked | Not checked | Not checked |
| Spectty (github.com/ocnc/spectty) | MIT, created 2026-02, pushed 2026-10-10 | Clean-room Swift mosh, Metal renderer, libghostty-vt | MoshSessionStore in Keychain | Not checked | Secure Enclave key generation |
| Moshpit (github.com/Cluas/moshpit) | GPL-3.0, pushed 2026-10-19, on the App Store | SSH/Mosh/tmux, aimed at coding agents | Claims sessions survive sleep | Not checked | Keychain |

- Prompt 3 detail: 3.1.2 (Dec 2025) stopped mosh from trying IPv6.
- Conclusion: "resume mosh after the app is killed" is already offered by Blink, Moshi, La Terminal and Spectty. Mosh-only and open-source with good OSC 52 is a differentiator, not an empty niche.

## 4. Independent implementations
| Repo | Licence | Activity | Notes |
|---|---|---|---|
| github.com/wiedymi/swift-mosh | MIT | created 2026-02-07, pushed 2026-10-20, tags v0.1.0 to v0.1.8, 15 stars | See detail below. Use as a reference for wire/OCB/protobuf, not as-is |
| github.com/ocnc/spectty | MIT | pushed 2026-10-10 | See detail below. Readable Swift reference |
| github.com/unixshells/mosh-go | MIT | created 2026-03, pushed 2026-04-05 | Pure Go client and server, WASM build, framebuffer on unixshells/vt-go, tracks receivedNums for old_num validation |
| github.com/Arunjay4213/mosh-rs | GPL-3.0 | pushed 2026-11-10, v0.1.4 pre-alpha | Explicitly "a Rust port of mosh master (decd9b7)"; wire-compatible with 1.4.0 |
| github.com/binaricat/MoshCatty | GPL-3.0 | 2026-07 | Rust |
| github.com/GlassHaven/ssp-transport | GPL-3.0 | 2026-09 | Kotlin transport |
| github.com/goodtune/gosh | MIT | 2026-11 | Go |
| github.com/bu/moshgo | no licence detected | 2026-07 | Go |

swift-mosh detail:
- Modules: MoshCore, MoshTransport (UDP), MoshWire, MoshProtoLite, MoshCryptoOCB (OCB over CommonCrypto AES), MoshCompression, MoshBootstrap.
- Requires iOS 16+ and Swift 6. Includes an E2E harness against a real mosh-server.
- API: `MoshClientSession(endpoint:)`, `start()`, `enqueue(.keystrokes)`, `hostOpStream()`, `prepareForApplicationBackground() -> MoshSnapshot`, `MoshClientSession.restore(from:)`.
- Defect (MoshClientSession.swift around lines 690-723):
  - It rejects a diff only when `oldNum > latestReceivedStateNum`.
  - Otherwise it passes `hostBytes` straight to the renderer, without checking that the diff was built from the state currently on screen.
  - It keeps no framebuffer per received state, so the screen can be drawn wrong when packets are lost or reordered.
  - It has no terminal emulator.

Spectty detail:
- Files under `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/`: MoshCrypto, MoshSSP, MoshProto, MoshNetwork, MoshBootstrap (swift-nio-ssh), STUNClient.
- Its `MoshSessionState` struct persists key, port and SSP numbers but no crypto send sequence. `MoshNetwork.sendSequence` starts at 0, so restoring after a kill risks nonce reuse and the server not roaming to the new address.

## 5. Licensing
- mosh is GPLv3 with an OpenSSL linking exception in each source file.
- `COPYING.iOS`: the mosh developers "committed not to pursue any license violation that results solely from the conflict between the GPLv3 and the Apple App Store terms of service ... as long as you comply with the GPL in all other respects, including its requirements to provide users with source code and the text of the license."
- Option (a), link upstream or the Blink fork's C++:
  - the whole app must be distributed under GPLv3 (or a compatible licence);
  - publish the corresponding source, including build scripts;
  - include the licence text and notices in the app;
  - the App Store/TestFlight conflict is covered by the COPYING.iOS non-enforcement promise.
  - Blink's own C++ changes (the iosclient restoration code) are copyright Blink and covered by Blink's COPYING additional term 2, a similar App Store promise.
  - Blink also adds term 3: no trademark use, altered versions must be marked as such.
- Option (b), line-by-line Swift port: a derivative work, so it must be GPLv3 and can rely on COPYING.iOS. mosh-rs takes this route.
- Option (c), clean reimplementation from the published protocol (mosh paper, wire format, .proto files): own copyright, any licence. Spectty and swift-mosh claim this route.
  - The .proto files are part of the GPL source; re-deriving schemas from wire behaviour or the protobuf description is safer.
  - Reading GPL code during implementation weakens a clean-room claim.
- How Blink ships under GPLv3: it publishes full source on GitHub, adds the Section 7 App Store terms in COPYING, and distributes via App Store and TestFlight.

## 6. Reuse recommendations
1. Fastest path (GPLv3 app):
   - SwiftPM-depend on `blinksh/mosh-apple` mosh.xcframework v1.4.0+blink-18.4.5 plus `blinksh/protobuf-apple` Protobuf_C_ v3.21.1.
   - Call `mosh_main` on a pthread with pipe FILE*s, and use the 0x1E 0x1A suspend protocol to get the Restoration blob.
   - Store the blob plus the key in the Keychain or in a file with NSFileProtectionCompleteUntilFirstUserAuthentication.
   - Better: rebuild the xcframework yourself in GitHub Actions from blinksh/mosh at 3640d366 using mosh-apple's FMake script, so you can publish the matching source.
2. Permissive path: write your own Swift mosh client, using swift-mosh and Spectty as references.
   - Keep a list of received states with full emulator framebuffers.
   - Persist the send seq across kills.
   - Validate with the local mosh-server 1.4.0, including packet-loss tests.
3. Bootstrap: copy Blink's approach.
   - Run `mosh-server new -s -c 256 -l LANG=...`, parse `MOSH CONNECT`, and take the IP from the SSH connection's peer address.
   - Optionally offer a static-server install from blinksh/mosh-static-multiarch, checksum-verified.
4. OSC 52:
   - Decode base64 to bytes, then UTF-8 (avoids Blink #1026).
   - Accept any selection parameter, but remember mosh only forwards `c` and caps the sequence at 16 KiB.
   - Dedupe after restore (Blink #1205, Moshi 3.2.1).
   - Gate remote clipboard reads behind confirmation (La Terminal).

## findings

### 1. Blink mosh build

**topic:** Blink mosh build

**claim:** Blink links a prebuilt mosh.xcframework from blinksh/mosh-apple, built from blinksh/mosh at a pinned SHA with --enable-ios-controller

#### evidence

blinksh/blink xcfs/Package.swift: "https://github.com/blinksh/mosh-apple/releases/download/v1.4.0+blink-18.4.5/mosh.xcframework.zip"; mosh-apple Sources/build/main.swift: moshSHA = "3640d36678dc415ba24f03d7f6fb20a0dac1fa6b", "./configure ... --disable-server --disable-client --enable-ios-controller"

**confidence:** high

### 2. Blink mosh bridge API

**topic:** Blink mosh bridge API

**claim:** mosh_main takes FILE* in/out, a winsize, a state callback and an encoded-state buffer used for restore

#### evidence

blinksh/mosh@3640d366 src/frontend/moshiosbridge.h: int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size, void (*state_callback)(const void *, const void *, size_t), void *state_callback_context, ... const char *encoded_state_buffer, size_t encoded_state_size, const char *predict_overwrite)

**confidence:** high

### 3. Survive app kill

**topic:** Survive app kill

#### claim

Blink suspends by injecting ESC-key + Ctrl-Z. The fork serializes Restoration::Context (seq, current_state_patch, received/sent states), calls the callback, then pthread_exit. On restore it calls Crypto::set_seq and rebuilds the states

#### evidence

iosclient.cc@3640d366: "else if ( the_byte == 0x1a ) { /* Suspend sequence is escape_key Ctrl-Z */ ... states.set_seq( Crypto::seq() ); ... state_callback(...); pthread_exit( &ret1 );"; main_init: "Crypto::set_seq( context.seq() );"; Blink mosh.swift suspend(): self.device.write(String("\(self.escapeKey)\u{1a}")), wait timeout 2.0

**confidence:** high

### 4. Seq persistence requirement

**topic:** Seq persistence requirement

**claim:** Upstream mosh-server only roams to a new client address on packets whose seq is >= expected, so a relaunched client must continue its seq

#### evidence

mobile-shell/mosh mosh-1.4.0 src/network/network.cc:515 "if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */"

**confidence:** high

### 5. Client must keep multiple states

**topic:** Client must keep multiple states

#### claim

The server diffs from optimistically assumed (unacked) receiver states, and the client applies each diff to the stored state named by old_num

#### evidence

transportsender-impl.h update_assumed_receiver_state: "give benefit of the doubt to unacknowledged states transmitted recently enough ago"; networktransport-impl.h recv: "now, make sure we do have the old state ... if ( inst.old_num() == reference_state->num )"

**confidence:** high

### 6. Lifecycle hooks

**topic:** Lifecycle hooks

#### claim

Blink suspends machines on sceneDidDisconnect, protected-data-will-become-unavailable, willTerminate and background-task grace expiry, and resumes on sceneWillEnterForeground when protected data is available

#### evidence

Blink/SceneDelegate.swift "iOS reclaimed this scene; preserve its Machine" machine.suspend(); AppDelegate.m applicationProtectedDataWillBecomeUnavailable -> [SceneDelegate suspendActiveMachines]; beginBackgroundTaskWithName:@"BackgroundExtension"

**confidence:** high

### 7. mosh-server bootstrap

**topic:** mosh-server bootstrap

#### claim

Blink runs '<mosh-server> new -s -c 256 [-l LANG=..] [-p port] [-- exec]' over LibSSH exec, parses MOSH CONNECT, and can upload a pinned static mosh-server to ~/.local/blink

#### evidence

mosh.swift getMoshServerStartupArgs: var args = ["new", "-s", "-c", colors ?? "256"]; MoshServerParams.swift pattern "(?m)^MOSH CONNECT (\\d+) (\\S*)$"; MoshBootstrap.swift MoshServerRemotePath = ".local/blink", download URL blinksh/mosh-static-multiarch

**confidence:** high

### 8. Upstream OSC 52

**topic:** Upstream OSC 52

**claim:** mosh 1.4.0 forwards OSC 52 copy only in the '52;c;' form, capped at 16 KiB

#### evidence

terminalfunctions.cc OSC_dispatch "handle osc copy clipboard sequence 52;c;"; terminaldispatcher.cc:45 "MAXIMUM_CLIPBOARD_SIZE = 16*1024"; release notes 1.4.0 "Support OSC 52 clipboard copy integration"

**confidence:** high

### 9. Blink OSC 52 handling

**topic:** Blink OSC 52 handling

**claim:** hterm's OSC 52 handler posts 'copy' to native code, which sets UIPasteboard. UTF-8 is broken (issue open)

#### evidence

Resources/term.js copyStringToClipboard -> _postMessage('copy', {content}); TermView.m [UIPasteboard generalPasteboard].string; blinksh/blink#1026 'OSC52 can not work with UTF8 characters' (open)

**confidence:** high

### 10. Blink keyboard

**topic:** Blink keyboard

#### claim

Blink captures keys in a WKWebView subclass using pressesBegan/UIKey/UIKeyCommand. SmartKeys go into inputAssistantItem on iPad and inputAccessoryView otherwise. Keyboard tracking uses UIKeyboardLayoutGuide with a height<150 hardware-keyboard heuristic

#### evidence

KBWebViewBase.m pressesCancelled UIKey modifierFlags; SmarterTermInput.swift 'override var inputAssistantItem' trailingBarButtonGroups; KBTracker.swift 'replaced by UIKeyboardLayoutGuide integration', 'isHardwareKB = height < 150'

**confidence:** high

### 11. swift-mosh correctness

**topic:** swift-mosh correctness

#### claim

wiedymi/swift-mosh (MIT) passes host bytes through without checking which received state the diff was built from, and keeps no per-state framebuffers

#### evidence

Sources/MoshCore/MoshClientSession.swift: 'if let oldNum = instruction.oldNum, oldNum > latestReceivedStateNum { return [] }' ... 'case .hostBytes(let bytes): return .hostBytes(bytes)'

**confidence:** high

### 12. Spectty persistence gap

**topic:** Spectty persistence gap

**claim:** Spectty's persisted MoshSessionState does not include the crypto send sequence

#### evidence

ocnc/spectty Packages/SpecttyTransport/.../Mosh/MoshSessionState.swift fields: senderCurrentNum, senderAckedNum, receiverCurrentNum, key ... (no seq); MoshNetwork.swift 'private var sendSequence: UInt64 = 0'

**confidence:** medium

### 13. Competitors

**topic:** Competitors

**claim:** Moshi and La Terminal advertise mosh resume after app restart or termination

#### evidence

apps.apple.com/app/id1629902861 La Terminal 2.0: 'Unlike native preservation, it survives device reboots or app termination'; apps.apple.com/us/app/6757859949 Moshi 3.15.0 'restore more reliably after restarting the app'

**confidence:** medium

### 14. Licensing

**topic:** Licensing

#### claim

mosh COPYING.iOS promises not to enforce GPL violations that arise solely from the App Store ToS conflict, provided the GPL is otherwise followed (source plus licence text). Blink adds the same promise as a GPLv3 s7 additional term

#### evidence

mobile-shell/mosh COPYING.iOS: 'we have committed not to pursue any license violation that results solely from the conflict between the GPLv3 and the Apple App Store terms of service'; blinksh/blink COPYING 'ADDITIONAL TERMS APPLICABLE TO BLINK' item 2

**confidence:** high

### 15. mosh-rs

**topic:** mosh-rs

**claim:** mosh-rs is an admitted port of mosh C++ and is GPL-3.0

**evidence:** Arunjay4213/mosh-rs README: 'mosh-rs is a Rust port of mosh master (decd9b7, March 2026). It is wire-compatible with mosh 1.4.0'

**confidence:** high

## recommendations

- Decide the licence first. If you accept GPLv3, reuse the blinksh/mosh fork at 3640d366, which already has state save/restore through the mosh_main state callback. Rebuild the xcframework in GitHub Actions macOS CI using mosh-apple's FMake script instead of trusting the release zip, and publish the matching source.
- If you want a permissive licence, write your own Swift client from the protocol, not from mosh C++. It must keep a list of received states with full emulator framebuffers and apply each diff to the state named by old_num. It must persist the crypto send seq, the key, the state nums and the framebuffer across a process kill.
- Persist session snapshots on scene background, sceneDidDisconnect, applicationProtectedDataWillBecomeUnavailable and willTerminate. Use a short beginBackgroundTask window and store the data with a file-protection class that is readable after first unlock, so you avoid Blink-style lock-window failures.
- Bootstrap with 'mosh-server new -s -c 256 -l LANG=en_US.UTF-8', parse '^MOSH CONNECT (\d+) (\S+)$', and use the IP of the SSH connection's peer to avoid IPv4/IPv6 mismatch. Offer a -p port-range option and an IPv4/IPv6 family override.
- OSC 52: decode base64 to bytes and then UTF-8. Dedupe clipboard state after restore. Document the 16 KiB limit and that only 'c' is forwarded. Make clipboard writes opt-in or notify the user, and require confirmation for reads.
- Use swift-mosh (MIT) as a reference for OCB/wire/protobuf-lite and its E2E harness design, and Spectty (MIT) for Swift app structure (Keychain, Secure Enclave key generation, InputAccessory). Do not adopt either as-is for transport correctness.
- Build an integration test against the local mosh-server 1.4.0 that kills the client process, restores it from the snapshot on a new UDP port, and checks that the server roams and the screen matches. Add tc/netem packet loss and reordering to exercise the multiple-state logic.

## risks

- Nonce reuse and lost roaming if the send seq is not persisted across a kill, or is persisted stale (saved before the last packets were sent). Snapshot only after the transport is frozen.
- Clients that only forward bytes (the swift-mosh style) can draw the screen wrong when packets are lost or reordered, because the server diffs from optimistically assumed states.
- GPL contamination: reading or porting mosh C++ while claiming a clean-room MIT licence. Linking the Blink fork makes the whole app GPLv3, and Blink's added terms (no trademark use, altered versions must be marked) also apply.
- iOS keyboard regressions across iOS 26.x, seen in the Blink tracker: hardware-keyboard detection heuristics, third-party keyboards, and the detach/attach crash worked around with reloadInputViews.
- Restore UX: Blink still has an open bug where a restore after several hours stalls until the user switches tabs (#2176). Blank screens appeared on iOS 26 (#2177).
- mosh-server only accepts OSC 52 with the 'c' parameter and caps it at 16 KiB. tmux or other tools sending other selection parameters may not reach the client.
- The App Store review and GPL source-offer obligations must be met for every TestFlight/App Store build. The mosh-apple repo itself has no licence file.

## unverified

- Termius, Secure ShellFish, Prompt 3, Echo and Moshi: actual behaviour when the app is force-quit, and OSC 52 support, were not confirmed from primary sources.
- Whether mosh-go keeps a full framebuffer per received state on the client side; only receivedNums tracking was seen.
- Whether Spectty restores the send sequence through some other path; only the MoshSessionState struct and an initial sendSequence = 0 were seen.
- Whether swift-mosh or Spectty are truly clean-room. Both make the claim, and their provenance was not audited.
- What the blinksh mosh-server '+blink' patches change on the server, and whether the restore mechanism works fully with stock mosh-server 1.4.0 (it should, because restore is client-side only, but this was not tested).
- Whether the mosh-apple GitHub Actions workflow builds the published release zips, or whether they are built locally.

