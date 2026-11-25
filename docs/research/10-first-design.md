# First design and critiques

> Addresses, ports and details of the author's own network were removed before publication.

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.
> TestFlight and GitHub Actions parts are superseded by docs/PLAN.md section 7.

## design

# iOS-mosh implementation plan

Nothing was written to disk: the hard rules forbid file creation, so this text is the whole deliverable. Items marked UNVERIFIED were not checked.

## 1. Engine decision

**Choice: pure-Swift core, repo licensed GPL-3.0-or-later** (porting from mosh source is allowed by the TestFlight-only decision).

Deciding reasons:
1. **Provable without a Mac.** The core builds and runs in `swift:6.4.2-noble` on yellow against real `mosh-server` 1.4.0 and sshd. Blink's `mosh.xcframework` needs a macOS autotools build, and charlie is often asleep.
2. **Resume needs changes inside the transport.** Durable acks, durable throwaway and reserved counter ranges must live in the SSP sender/receiver. Blink's freeze-then-snapshot is only sound if nothing is sent after the snapshot and the app is never killed in between (open Blink #2176).
3. **Both Swift forks need their core rewritten anyway.** Spectty persists no crypto send sequence (nonce reuse on resume). wiedymi/swift-mosh keeps no per-state framebuffer and applies hostbytes regardless of `old_num`. Use both as MIT reading references only.
4. **Kill-at-any-instant tests run on Linux CI** with one language and a small dependency surface (swift-crypto, swift-nio-ssh, zlib).

Switch triggers:
- If the Swift applier cannot reach cell-exact equality with mosh's own emulator (M3 oracle) within about two weeks, compile mosh C++ `src/terminal` + `src/statesync` behind the same `TerminalModel` protocol and keep the Swift transport and journal.
- If the M4 kill-loop cannot be made green against the real server, fall back to Blink's fork built in CI and accept "resume after suspend only".

## 2. Repository layout

Repo `trickv/ios-mosh` (does not exist yet; public for free macOS runners, UNVERIFIED for this account). Bundle id `us.v9n.ios-mosh`.

| Path | Content | Linux |
|---|---|---|
| `Package.swift` | Package `MoshKit`, tools-version 6.2 | yes |
| `Sources/CZlib` | systemLibrary for zlib (`zlib1g-dev`); not Apple `COMPRESSION_ZLIB` | yes |
| `Sources/MoshCrypto` | `AESBlock.swift` (CryptoExtras `AES.permute` / CommonCrypto), `OCB3.swift`, `MoshCipher.swift` (nonce = direction bit + seq), `Base64Key.swift` | yes |
| `Sources/MoshWire` | `ProtoLite.swift`, `Instruction.swift`, `UserMessage.swift`, `HostMessage.swift`, `Fragmenter.swift`, `FragmentAssembly.swift`, `Zlib.swift`, `Packet.swift` | yes |
| `Sources/MoshTransport` | `DatagramTransport.swift` (protocol), `POSIXDatagramTransport.swift`, `NWDatagramTransport.swift` (`#if canImport(Network)`), `TransportSender.swift`, `TransportReceiver.swift`, `RTTEstimator.swift`, `MoshConnection.swift` (actor), `DurabilityGate.swift` (protocol) | yes |
| `Sources/MoshResume` | `SessionRecord.swift`, `Counters.swift`, `Journal.swift`, `SessionStore.swift`, `ResumeCoordinator.swift` | yes |
| `Sources/MoshTerminal` | `Cell.swift`, `Framebuffer.swift` (CoW), `Parser.swift`, `Applier.swift`, `DisplayDiff.swift` (port of `Display::new_frame`), `WCWidthTable.swift` (generated), `InputEncoder.swift` | yes |
| `Sources/MoshKeys` | `KeyGenerator.swift`, `OpenSSHPublicKey.swift`, `Fingerprint.swift`, `KeyStore.swift` (protocol + `FileKeyStore` for tests) | yes |
| `Sources/MoshBootstrap` | `SSHBootstrap.swift` (swift-nio-ssh 0.15.1), `MoshServerCommand.swift`, `ConnectLineParser.swift`, `KnownHosts.swift` | yes |
| `Sources/MoshSession` | `MoshSession.swift`, the facade the app talks to | yes |
| `Sources/moshcli` | Test executable: `handshake`, `bootstrap`, `connect`, `resume`, `soak`, `--crashpoint N`, `--trace-nonces` | yes |
| `Tools/mosh-oracle` | 1.4.0 `src/terminal` + small `main.cc` dumping the framebuffer as JSON; test-only | Linux only |
| `App/SurfaceKit` | Package with `TerminalSurface` protocol and `SwiftTermSurface` (SwiftTerm exact 1.99.3) | tests headless |
| `App/IOSMosh` | UIKit app: `SceneDelegate`, `SessionListViewController`, `HostEditorViewController`, `KeysViewController`, `TerminalViewController`, `MoshTerminalView`, `KeyBarView`, `HardwareKeyMapper`, `PasteController`, `KeychainKeyStore`, `PrivacyInfo.xcprivacy` | no |
| `App/project.yml`, `fastlane/`, `Gemfile` | Copied from `/home/trick/src/github.com/trickv/<the author's Swift app>` | no |
| `docker/Dockerfile.dev` | `swift:6.4.2-noble` + zlib1g-dev, mosh, openssh-server, iproute2, locales, g++ | yes |
| `scripts/` | `dev.sh`, `itest.sh`, `netem.sh`, `gen-wcwidth.c`, `record-golden.sh` | yes |
| `.github/workflows/` | `core-linux.yml`, `ios-build.yml`, `release.yml` | n/a |

## 3. Resume-after-kill design

### Persisted record
Directory `Application Support/sessions/<uuid>/`, file protection `completeUntilFirstUserAuthentication`.

- **Keychain** (`AfterFirstUnlockThisDeviceOnly`, non-synchronizable): the 16-byte mosh key, account = session UUID.
- **`meta.json`** (written once): version, UUID, host label, numeric IP, UDP port, user, creation time, initial cols/rows.
- **`counters`** (fixed 40 bytes, `pwrite` + `F_FULLFSYNC`): `seqReserved`, `numReserved`, `fragIdReserved`, `bootID`, `dirty`, CRC32.
- **`journal.<gen>`** (append-only, CRC-framed, plain `write()`):
  - `INPUT{index, userEventBytes}`: one keystroke batch or resize.
  - `FRONT{A, droppedCount}`: the server acked our state A; events up to it are dropped.
  - `THROWAWAY_SENT{t}`.
  - `REMOTE{num, oldNum, wireDiff}`.
  - `REMOTE_THROWAWAY{num}`.
  - `CHECKPOINT{num, w, h, zlib(Framebuffer binary)}`. This is our own encoding, not `init_diff`, which avoids the DrawState assumption.
  - `ECHO_ACK{n}`, `CLIPBOARD_HASH{h}`.

Timestamps and RTT are not persisted.

"Durable" means `write()` has returned, which survives process death (the requirement). Power loss is covered by the dirty flag: `dirty=1` is full-synced before the first send of each foreground period. It is cleared after a journal `F_FULLFSYNC` in `sceneDidEnterBackground`. If `bootID` changed and `dirty=1`, the record is unusable. Boot identity via `kern.bootsessionuuid` or `kern.boottime` is UNVERIFIED on iOS.

### Write-ahead rules
`TransportSender` and `TransportReceiver` call `DurabilityGate` before every send.

- **W1.** A datagram with sequence `s` is sent only if `s < seqReserved` on disk. Reserve 2^16 at a time; refill when fewer than 4096 remain.
- **W2.** A state number `n` is used only if `n < numReserved` (blocks of 1024). Same rule for fragment ids.
- **W3.** A state containing user event `e` is sent only after `INPUT(e)` is durable.
- **W4.** `ack_num = n` is sent only after `REMOTE(n)` is durable. The receiver exposes `durableAckNum`; the write fits in the 100 ms ACK_DELAY.
- **W5.** `throwaway_num = t` is sent only after `FRONT{A >= t}` is durable.
- **W6.** Compaction writes `journal.<gen+1>` (checkpoint at the last received throwaway, then live records), fsyncs, renames, then deletes the old file. Counters are never part of compaction.

### Invariants
Breaking any of these aborts mosh-server (asserts are present in the distribution's 1.4.0 binary) or reuses a nonce.

- **I1.** Sequence numbers are strictly increasing over the key's lifetime. Reuse is OCB nonce reuse, and the server also ignores the packet for roaming.
- **I2.** `new_num` of any state is greater than every num ever sent, including empty acks.
- **I3.** Every sent state's event list is a prefix-extension of every earlier sent state's list relative to the same base. A shorter list after restart trips the `UserStream::diff_from` asserts.
- **I4.** `throwaway_num <= old_num`, `<=` persisted A, and never above every num the server holds (`fatal_assert(received_states.size() > 0)`).
- **I5.** A fragment id is never reused with different content. Fragments are at least 10 bytes; `fragment_num <= 0x7FFF`.
- **I6.** `echo_ack` never decreases.
- **I7 (liveness, not fatal).** The client holds a framebuffer for every `ack_num` it sent that is at or above the last received throwaway. Otherwise server diffs are silently dropped and the screen freezes.

### Resume procedure
`ResumeCoordinator.resume(record)`:

1. Read `counters` and verify CRC. Read the key. Replay the journal, truncating at the first bad CRC.
2. Check the dirty/boot rule.
3. Set `nextSeq = seqReserved`, `nextNum = numReserved`, `nextFragId = fragIdReserved`. Write the new reserves with `F_FULLFSYNC` before any packet.
4. Rebuild the receiver: load the checkpoint, re-apply `REMOTE` diffs through `Applier` at the saved sizes, set `ackNum` to the highest num.
5. Rebuild the sender: `sentStates = [{A, []}, {nextNum-1, pending}]`, where `pending` is every journaled event after A.
6. Open a new `DatagramTransport`. The server roams on the first authenticated packet with a higher seq.
7. Send `{old_num: A, new_num: nextNum, ack_num, throwaway_num: A, diff: pending}`, plus a `Resize` if the view size changed (journaled first).
8. Paint the newest framebuffer immediately, then continue normally.
9. If authenticated datagrams arrive for 2 s but none has a held `old_num`, send Resize(w, h-1) then Resize(w, h) and accept a diff containing a Resize as a full repaint. This recovery is derived from code and UNTESTED until M4.

### Fallback
Triggers:
- Key missing, counters CRC bad, dirty-after-reboot, or a failed reserve write: mark the record dead, never send from it, and offer "Start new session" (fresh SSH bootstrap).
- No authenticated datagram: keep retrying under a "last contact" banner with the same offer. A server exit cannot be told apart from an outage.

## 4. Terminal layer

- **Model.** `Framebuffer` is a CoW struct: `[Row]` of `Cell` (grapheme, width, renditions), cursor, deferred-wrap flag, scroll region, modes, title, bell count, clipboard. `Applier.apply(hostBytes:to:)` implements only the dialect `Display::new_frame` emits. `TransportReceiver` keeps one framebuffer per received state.
- **Width table.** `WCWidthTable.swift` is generated by `scripts/gen-wcwidth.c` against noble's glibc.
- **Rendering: TerminalView-feed.** Correction to the working direction: `TerminalRenderView` and `TerminalExternalFrameSource` are not in SwiftTerm 1.99.3. Verified with `gh api`: they exist only on main since commit be13b66bb (PR #832, 2026-11-09). So `SwiftTermSurface` calls `DisplayDiff.newFrame(from: lastShown, to: newest)` and passes the bytes to `TerminalView.feed(byteArray:)`.
- **Feed rules.**
  - Position with explicit CUP; never rely on SwiftTerm autowrap (`ESC[?7l` once).
  - Send `ESC[?1h` once so SwiftTerm emits `ESC O A..D`, which mosh expects (UNVERIFIED until M6).
  - Strip OSC 52, title and bell from the feed; the app handles them from framebuffer fields.
  - Frames coalesce: only the newest state is painted per display tick.
- **Why not the others.** A custom renderer would have to rebuild IME, selection and glyph caching. Revisit `TerminalRenderView` once a tagged release contains it; the `TerminalSurface` protocol makes that a one-file swap.
- **Scrollback.** None in v1: mosh carries none, so SwiftTerm scrollback is set to 0. Recommend tmux.
- **Prediction.** Out of v1 (optional M10). A native "last contact Ns" banner replaces mosh's row-0 notification bar.

## 5. Input

- **Key bar.** `KeyBarView` is pinned to `view.keyboardLayoutGuide.topAnchor` (`followsUndockedKeyboard = true`); SwiftTerm's `inputAccessoryView` is set to nil. Keys: Esc, Tab, sticky Ctrl and Alt, arrows with auto-repeat, `| / ~ -`, Paste, keyboard dismiss.
- **Hardware keys.** `MoshTerminalView` overrides `pressesBegan/Ended`, and `HardwareKeyMapper` handles Ctrl/Alt chords, function keys, Home/End/PgUp/PgDn and an app-managed repeat timer. `UIKeyCommand` is used only for app commands (Cmd-V, Cmd-N, Cmd-+/-). How much SwiftTerm 1.99.3 already handles is UNVERIFIED; plain text and IME stay on its `UITextInput` path.
- **Paste.** Cmd-V, the edit menu, or a `UIPasteControl` in the key bar; none of these prompt. `PasteController` strips `ESC[201~`, maps LF to CR, and wraps in `ESC[200~ … ESC[201~` when `fb.bracketedPaste`. No programmatic pasteboard reads.
- **Mouse.** Reports are generated only while the framebuffer's mouse mode is on: tap (press/release) and two-finger pan (wheel), in the encoding the framebuffer says (SGR 1006, 1005, X10). With mouse mode off, long-press selects and copies.
- **Focus.** `ESC[I` / `ESC[O` on scene activate/deactivate when `?1004` is set.
- **OSC 52 rules** (`ClipboardPolicy.swift`):
  - Accept any `Pc`; always target the general pasteboard.
  - Payload `?` is a query: ignore it, never read the pasteboard.
  - Strict base64 to bytes to UTF-8; on failure drop and show a toast (the server truncates at 16 KiB).
  - Write only when a live diff changes the clipboard field. Never write during resume replay or resize-repaint; dedupe by the persisted `CLIPBOARD_HASH`.
  - Per-host toggle "Allow remote clipboard write", default on; toast "Copied N bytes".
  - Document the tmux `Ms` override and neovim `vim.g.clipboard = 'osc52'`.

## 6. Keys and SSH bootstrap

- **Generation.** `Curve25519.Signing.PrivateKey()` by default; optional `SecureEnclave.P256.Signing.PrivateKey` when available. No import, no RSA.
- **Storage.** `KeychainKeyStore`, `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronizable. It holds the 32-byte raw key or the Secure Enclave blob.
- **Export UI.** `KeysViewController` shows the `ssh-ed25519 AAAA… ios-mosh@<device>` line, the `SHA256:` fingerprint, Copy, share sheet and QR code. Wire encodings live in `OpenSSHPublicKey.swift`.
- **known_hosts.** `KnownHosts.swift` stores `{host, port, keyType, base64}` as JSON. The first connection shows the fingerprint for trust-on-first-use; a mismatch is refused in `validateHostKey` with no bypass other than deleting the entry.
- **Auth order.** Public key if one is assigned, then password, prompted per connection and never stored in v1. No keyboard-interactive, so 2FA hosts fail with a clear message.
- **Exec.** Request a pty (`xterm-256color`, exactly the view's cols/rows), then run:

  `mosh-server new -c 256 -s -l LANG=en_US.UTF-8`

  Per-host options: server path or prefix (for example `MOSH_SERVER_NETWORK_TMOUT=604800 /usr/bin/mosh-server`) and `-p P[:P2]`.
- **Parse.** `^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\s*$`, tolerating `\r`. The UDP target is the numeric peer IP of the SSH connection. Close SSH, then send state 1 = Resize(cols, rows) within 60 s.

## 7. Milestones

| M | Goal | Deliverables | Where | Exit test |
|---|---|---|---|---|
| M0 | Toolchain | Repo, `Package.swift`, `Dockerfile.dev`, `scripts/dev.sh`, `core-linux.yml`, `CZlib` | yellow Docker, CI ubuntu | `scripts/dev.sh test` is green in both places; zlib round-trip passes. |
| M1 | Crypto + wire | `MoshCrypto`, `MoshWire`, `moshcli handshake` | yellow Docker, CI | mosh `ocb-aes.cc` and RFC 7253 vectors pass. A handshake against in-container `mosh-server` decrypts and decodes a HostMessage, which also confirms the hand-derived protobuf bytes. |
| M2 | SSP transport | `MoshTransport`, `moshcli connect --script` | yellow Docker (`--cap-add NET_ADMIN`), CI | Typing `echo hello-$((6*7))` yields `hello-42`. A 10-minute `netem` soak (20% loss, 200±50 ms, reorder) leaves the server alive. A socket rebind roams. |
| M3 | Terminal model | `MoshTerminal`, `Tools/mosh-oracle`, golden corpus (vim, htop, tmux, colors, wide/combining/emoji) | yellow Docker, CI | The framebuffer matches the oracle cell for cell at every state. Property test: applying `newFrame(a,b)` to `a` gives `b`. |
| M4 | Resume | `MoshResume`, crashpoints, `scripts/itest.sh kill-loop` | yellow Docker, CI (nightly, 500 iterations) | After SIGKILL at random instants and at every crashpoint, `moshcli resume` reaches the same server PID and shell `$$`, the screen matches the oracle, and the nonce trace shows no reuse. A negative run without the journal aborts the server. The resize-repaint result is recorded. |
| M5 | Keys + bootstrap | `MoshKeys`, `MoshBootstrap`, in-container sshd with password auth | yellow Docker, CI; then yellow's real sshd with key auth | Password and Ed25519 logins both reach the M2 echo test. Our fingerprint equals `ssh-keygen -lf`. A changed host key is refused. |
| M6 | App shell | `project.yml` (iOS 18, iPhone, scene lifecycle), `SurfaceKit`, `NWDatagramTransport`, `ios-build.yml` | CI macos-26; SurfaceKit tests also on Linux | Simulator tests and the unsigned device build are green. After each fed frame, SwiftTerm's headless buffer equals our framebuffer. |
| M7 | TestFlight | `release.yml`, Fastfile/Appfile adapted, icon, `docs/RELEASE.md` | CI + human | A build installs on <the phone's tailnet name>, connects to yellow over Tailscale and runs vim. |
| M8 | Input, OSC 52, key UI | Section 5 and 6 UI | CI unit tests, device | Device checklist: key bar, hardware keyboard chords and repeat, paste into vim, tmux and nvim copy to the iOS clipboard, key export accepted by yellow. |
| M9 | Resume on device | `SceneDelegate` wiring (flush on background, new socket on foreground), debug "abort now" | device | The same shell `$$` and correct screen after: 10 minutes in background, force-quit, debug abort mid-typing, Wi-Fi to cellular, and a reboot from the background. |
| M10 | Optional | Prediction engine port; `TerminalRenderView` once tagged | Linux, device | Not required for v1. |

Charlie is optional throughout; use it for interactive Xcode debugging when awake. Whether it has Xcode is UNVERIFIED.

## 8. Verification matrix

| Test | Proves | Runs |
|---|---|---|
| OCB/AES vectors | Cipher correctness | Linux CI |
| Wire encode/decode + live handshake | Protobuf, fragments and zlib match the real server | yellow, CI |
| netem soak, roam | Timers, retransmit, ack and throwaway logic | yellow, nightly CI |
| Oracle equality | Applier equals mosh's emulator | Linux CI |
| DisplayDiff property + SurfaceKit equivalence | What SwiftTerm shows equals the model | Linux CI, macOS CI |
| Kill-loop + crashpoints + nonce trace | I1–I7 and W1–W6 hold under kill at any instant | yellow, nightly CI |
| Negative no-journal run | The server asserts are live, so the tests are meaningful | yellow |
| Bootstrap against real sshd | Auth, host keys, command and parse | yellow, CI |
| Fingerprint vs `ssh-keygen` | Public key encoding | Linux CI |
| Simulator XCTest | Keychain store, key mapping, clipboard policy | macOS CI |
| Device checklist (M8, M9) | Keyboard, clipboard, real suspend/kill/roam | <the phone's tailnet name> |

## 9. Risks, v1 scope, human-only steps

**Risks**

| Risk | Mitigation |
|---|---|
| Applier divergence from mosh | M3 oracle gate; C++ switch trigger. |
| Resume bug kills the user's shell | M4 gate before any device work; reserves full-synced; dead-record fallback. |
| Power-loss tail loss | Dirty/boot rule (boot id on iOS UNVERIFIED). |
| Double emulation (width or mode drift in SwiftTerm) | Explicit CUP, autowrap off, equivalence tests. |
| Mac scarcity (charlie asleep, runner capacity failures) | Everything through M5 is Linux-only; `workflow_dispatch` re-runs. |
| Toolchain | SwiftTerm needs tools 6.2 / Xcode 26+; the Swift version in Xcode 26.6 is UNVERIFIED, so pin Xcode in the workflows. |
| Network | Tailscale avoids the Local Network prompt; add `NSLocalNetworkUsageDescription` for LAN. IPv4 literals on NAT64 cellular are UNVERIFIED. |
| Server variance | Only 1.4.0 is tested. Whether every distro build keeps asserts is UNVERIFIED; assume they do. |
| Yellow specifics | sshd `PasswordAuthentication` on yellow is UNVERIFIED (config unreadable). Container-to-host UDP 60001–60999 is UNVERIFIED, so tests run mosh-server inside the container. |

**Out of scope for v1:** iPad layouts, key import, RSA, 2FA, ProxyJump, agent forwarding, saved passwords, scrollback, prediction, OSC 8, sixel/kitty, multiple concurrent live sessions, iCloud sync, App Store release.

**Human-only steps**
- Create the GitHub repo.
- Register App ID `us.v9n.ios-mosh` and an App Store provisioning profile.
- Create the App Store Connect app record and add the internal tester.
- Set the secret `BUILD_PROVISION_PROFILE_BASE64` and confirm the seven shared secrets are set on the new repo (never print values).
- Decide the `ITSAppUsesNonExemptEncryption` export-compliance answer.
- Supply an opaque 1024 px icon.
- Wake charlie when needed.
- Confirm or enable password auth on a test sshd.
- Run the M7–M9 device checklists on <the phone's tailnet name>.

### Critical Files for Implementation
- /home/trick/src/github.com/trickv/ios-mosh/Sources/MoshTransport/TransportSender.swift (to be created)
- /home/trick/src/github.com/trickv/ios-mosh/Sources/MoshResume/ResumeCoordinator.swift (to be created)
- /home/trick/src/github.com/trickv/ios-mosh/Sources/MoshTerminal/Applier.swift (to be created)
- /home/trick/src/github.com/trickv/<the author's Swift app>/.github/workflows/release.yml (template to copy)
- /home/trick/src/github.com/trickv/<the author's Swift app>/ios/<App>/project.yml (template to copy)

## critiques

### 1. item

**lens:** protocol-resume

#### verdict

The write-ahead skeleton (W1-W5, I1-I4, reserved seq/num/frag-id ranges, durable ack before ack, durable front before throwaway) matches mosh-1.4.0 and is the right design. The pure-Swift direction does not need to change. The resume procedure itself has a defect that can silently drop keystrokes or abort mosh-server. Step 5 restores the sender's back state at nextNum-1, but step 7 sends nextNum. Mosh's sender always numbers new and resent states from sent_states.back(), so the resent number can collide with a number already used before the kill. Separately, after a kill and relaunch, the server can hold a different state under the same number than the client's sent_states records (this one is reasoned from transportsender-impl.h and the fragmenter, not verified). That reaches UserStream::subtract/diff_from asserts on the server, or the FragmentAssembly assert. The power-loss dirty flag has a gap in the background. Backup and restore can bring back old counters together with a still-valid key. The resize-repaint recovery as written can race and not repaint. The M4 test plan would not catch the most likely failures: silent keystroke loss or duplication, and a frozen screen. Its "negative no-journal run aborts the server" check is wrong per recv(): a naive restart is silently dropped, not aborted. Outside the strict lens, I verified that Display::put_row relies on the terminal's autowrap for wrapped rows. So the "ESC[?7l, never rely on autowrap" feed rule corrupts wrapped lines if DisplayDiff is a faithful port of new_frame. The per-state copy-on-write framebuffer matches mosh's receiver model and holds up under loss and reordering. One condition: the replay must rebuild every state at or above the last received throwaway, not only the newest.

#### issues

##### 1. Resume sender state is inconsistent with the num actually sent (step 5 vs step 7)

**severity:** blocker

**title:** Resume sender state is inconsistent with the num actually sent (step 5 vs step 7)

###### problem

Step 5 sets sentStates = [{A,[]},{nextNum-1,pending}], and step 7 sends new_num = nextNum. In transportsender-impl.h, send_to_receiver uses new_num = sent_states.back().num when current_state == back.state, and back.num+1 otherwise. send_empty_ack uses back.num+1. So the first ported-logic retransmit of pending goes out as nextNum-1 = old numReserved-1, which may already have been used before the kill. If it equals the server's max M, recv() drops it as a duplicate; if lower, it is inserted out of order and never processed. The first keystroke after resume then becomes back+1 = nextNum, with content (pending + new keys) that differs from the step-7 packet that used the same nextNum. The server already holds nextNum with pending only and drops the second as a duplicate (recv: inst.new_num()==i->num → return). When the server acks nextNum, the client believes the server holds pending+new keys. The new keys are then silently lost, and later diffs are computed against a state the server does not have. Fragmenter::make_fragments bumps the id only when the header fields change, not the diff, and asserts diff equality only on the client. The same id, nums and header with a different diff can therefore reach the server and trip assert(fragments.at(frag.fragment_num)==frag) if a multi-fragment instruction is half-assembled. Restored sent states without timestamps also matter. If their timestamps are 'now', update_assumed_receiver_state picks back (never received) for RTO+100 ms, and diffs against it are dropped. With last_heard=0, calculate_timers disables fast retransmit (the last_heard + ACTIVE_RETRY_TIMEOUT > now branches), so pending is resent only on the 3 s ACK_INTERVAL.

###### fix

Restore sentStates = [{A, [] , ts=0}, {nextNum, pending, ts=0}], with a fresh reserve already durable. Send exactly that state (new_num = nextNum) and let every retransmit reuse it. New keystrokes get nextNum+1. Set last_heard = now (or force immediate retransmission) at resume. Add a property test that replays the C++ TransportSender numbering against the Swift sender after a restore.

**verified:** True

##### 2. M4 kill-loop cannot detect silent keystroke loss or duplication

**severity:** major

**title:** M4 kill-loop cannot detect silent keystroke loss or duplication

###### problem

The exit test checks server PID, shell $$, oracle screen equality and the nonce trace. Lost input (a new_num ≤ M is silently dropped or inserted unacked in recv()) and duplicated input both leave the PID, $$ and nonce trace correct. The research spec explicitly asks to assert that each keystroke reaches the pty exactly once.

###### fix

Drive a numbered keystroke stream (e.g. a counter typed into `cat -v > log` or a small reader on the pty) through kills, and assert the server-side log is exactly the typed sequence with no gaps or repeats. Include kills with un-acked pending input, and a paste larger than one MTU (multi-fragment) so FragmentAssembly is exercised.

**verified:** True

##### 3. Negative 'no-journal run aborts the server' expectation is wrong

**severity:** major

**title:** Negative 'no-journal run aborts the server' expectation is wrong

###### problem

Per networktransport-impl.h recv(), a naively restarted client sends new_num ≤ M. That is dropped as a duplicate or inserted out of order and never acked, and old_num 0 is 'not found' once a throwaway > 0 was received. Per network.cc, seq ≤ expected is processed but not roamed. None of these asserts. The server stays alive and input is silently ignored, so the planned negative test will 'fail' in a misleading way, or someone will 'fix' the test.

###### fix

Write targeted negative cases. (a) Reuse nums above M with a shorter event list: expect a UserStream diff_from/subtract assert abort. (b) Send a throwaway above every held num: expect fatal_assert(received_states.size() > 0). (c) Send the same frag id with different fragment content mid-assembly: expect the FragmentAssembly assert. (d) Restart naively: expect silent drop, and check that the client detects it via the absence of acks for its new nums.

**verified:** True

##### 4. Screen oracle cannot detect a frozen client

**severity:** major

**title:** Screen oracle cannot detect a frozen client

###### problem

If 'screen matches the oracle' means mosh's emulator fed the same server diffs the client accepted, a client that drops every diff (old_num not held, I7 broken) still matches. The server keeps retransmitting diffs the client silently discards.

###### fix

After each resume, run a fresh command whose output is known (e.g. `echo resumed-$N`). Assert that it appears in the client framebuffer within a deadline. Compare against the server's actual terminal (for example a tmux capture-pane on the server side), not a replay of what the client received.

**verified:** True

##### 5. Client nonce trace does not survive SIGKILL; use cleartext seq from pcap

**severity:** major

**title:** Client nonce trace does not survive SIGKILL; use cleartext seq from pcap

###### problem

A `--trace-nonces` log written by the process being killed loses its tail, which is exactly the window where reuse would happen. The 8-byte nonce (direction bit + seq) is sent in clear at the start of each datagram (network.cc Packet), so an external capture is authoritative.

###### fix

Record UDP with tcpdump in the container across the whole kill-loop. Assert that client-to-server seq values are strictly increasing across all process generations.

**verified:** False

##### 6. Dirty-flag power-loss rule has a background gap

**severity:** major

**title:** Dirty-flag power-loss rule has a background gap

###### problem

dirty is cleared after a journal F_FULLFSYNC in sceneDidEnterBackground, but the process keeps running for a while afterwards. The socket stays open, server diffs arrive, and W4 acks them after a write() that is not synced. If power is lost while suspended (a battery dying is a common case), a REMOTE whose ack was sent is lost while dirty=0. The resume then opens normally and freezes (I7), or loses journaled input that was already sent, which trips the server's prefix asserts on the next input.

###### fix

Stop the transport (no sends, socket closed) before the final fsync and the dirty=0 write. Treat 'about to send while dirty==0' as a mandatory full-synced dirty=1 write, enforced inside DurabilityGate rather than tied to the scene lifecycle.

**verified:** False

##### 7. Backup restore can bring back stale counters with a valid key (nonce reuse)

**severity:** major

**title:** Backup restore can bring back stale counters with a valid key (nonce reuse)

###### problem

Application Support is included in device backups. Keychain ThisDeviceOnly items do not migrate to a new device, but may come back when restoring to the same device (UNVERIFIED). After such a restore, counters hold an old seqReserved, dirty is 0 (cleared on background), and the boot-id check is irrelevant when dirty is 0. mosh-server has no network timeout by default, so the old server may still be alive. Resume would then reuse seqs (OCB nonce reuse) and nums (silent drop or assert).

###### fix

Set isExcludedFromBackup on sessions/ and treat a missing directory as 'no session'. Also bind the record to a random install nonce stored in a Keychain item, and kill the record on a mismatch. Or, better, keep seqReserved/numReserved in the Keychain item alongside the key so both are restored together or neither is.

**verified:** False

##### 8. DisplayDiff feed with autowrap disabled corrupts wrapped rows

**severity:** major

**title:** DisplayDiff feed with autowrap disabled corrupts wrapped rows

###### problem

terminaldisplay.cc put_row (1.4.0, lines ~351-358 and ~466-476) handles a wrapping row by setting cursor_x=0, cursor_y++ and returning wrap=true. The next row then prints its first cell with append_cell and no cursor move, relying on the terminal's deferred autowrap. If DisplayDiff is a port of new_frame and SwiftTerm has ESC[?7l, that cell overwrites the last column of the previous row. The M6 headless-equivalence test would catch it only if the corpus contains wrapped lines.

###### fix

Keep autowrap on in SwiftTerm (mosh's own client does), or change the ported put_row to always emit an explicit CUP for the first cell of a wrapped row. Add long wrapped lines to the M3/M6 corpus.

**verified:** True

##### 9. Resize-repaint recovery can race and not repaint

**severity:** major

**title:** Resize-repaint recovery can race and not repaint

###### problem

Complete::diff_from adds a resize instruction only when the size differs from the server's assumed/front state. New_frame clears the screen and repaints all rows only on a size difference. Step 9 sends Resize(w,h-1) and then Resize(w,h) without waiting. If both land in one client state (only the last Resize reaches the pty, per research; UNVERIFIED by me), or the server computes its next diff after both arrive, the terminal is back at the front's size, no resize instruction is emitted, and the client stays frozen. Even when it works, the title/icon and clipboard checks (line ~75, using the caller's initialized=true) and reverse video (?5, checked before the size test) are not re-emitted, so those fields keep whatever the wrong base had.

###### fix

Send (w,h-1), wait until a diff containing the resize is accepted and acked, then send (w,h). Reset title, clipboard and reverse video to defaults on the substituted base rather than trusting it. Given W4, this path should be unreachable; consider keeping it only behind a debug flag (see cuts).

**verified:** True

##### 10. Receiver rebuild must reconstruct every state at or above the last received throwaway, not just the newest

**severity:** major

**title:** Receiver rebuild must reconstruct every state at or above the last received throwaway, not just the newest

###### problem

The server's front is the highest client ack that actually arrived, which with loss can be any acked num at or above the last throwaway. After a pause of more than about 1.1 s the server sends only diffs from that front (update_assumed_receiver_state). Step 4 says 'load checkpoint, re-apply REMOTE diffs, set ackNum to highest'. If only the newest framebuffer is materialized, diffs whose old_num is an earlier acked state are silently dropped. REMOTE diffs also need their own oldNum base, which is not necessarily the previous record.

###### fix

Rebuild a map num → Framebuffer for every journaled state at or above REMOTE_THROWAWAY, applying each REMOTE onto its recorded oldNum base. Mirror recv()'s rule that out-of-order states (new_num below the max held) are stored but neither acked nor displayed.

**verified:** True

##### 11. Server shutdown (new_num = UINT64_MAX) not handled; 'exit indistinguishable from outage' overstated

**severity:** minor

**title:** Server shutdown (new_num = UINT64_MAX) not handled; 'exit indistinguishable from outage' overstated

###### problem

When the shell exits, mosh-server calls start_shutdown (mosh-server.cc 755/761/843/854), and the sender then sends new_num = uint64(-1) (transportsender-impl.h). A connected client can therefore see a clean exit. The plan has no rule to ack it, mark the record dead, or keep -1 out of 'ackNum = highest num' on replay.

**fix:** On receiving num -1: journal SERVER_SHUTDOWN, ack it, and mark the record dead. Exclude -1 from reserve and highest-num logic.

**verified:** True

##### 12. Counters file torn write kills the session; reads blocked by data protection may be misread as 'missing'

**severity:** minor

**title:** Counters file torn write kills the session; reads blocked by data protection may be misread as 'missing'

###### problem

A 40-byte pwrite in place is not atomic across power loss. A torn write makes the CRC bad, and the record is declared dead. A launch before first unlock gives errSecInteractionNotAllowed or EPERM, which the fallback could treat as 'key missing' and kill a healthy record permanently.

###### fix

Use two counter slots with a generation number (write the inactive slot, then fsync). Treat a protection or locked error as 'retry later', never as dead.

**verified:** False

##### 13. No single-writer guard per session record

**severity:** minor

**title:** No single-writer guard per session record

###### problem

M9 wires 'new socket on foreground'. If ResumeCoordinator ever runs while an in-process MoshConnection for the same record is still alive (suspend without kill, a scene reconnect), two senders share counters and journals. Reserves avoid seq overlap only if each one bumps them, and the event-prefix invariant I3 breaks.

###### fix

Use an flock on sessions/<uuid>/ held by the live connection. ResumeCoordinator runs only when no live in-process connection exists; on foreground otherwise, rebind the socket only.

**verified:** False

#### missing

- A test that simulates power loss by truncating the journal to the last fsync offset (with dirty set both ways), since SIGKILL on Linux never loses page-cache writes.
- Kill-loop variants: resume within about 1 s (server still on its unacked assumed state) and after more than 40 s (SERVER_ASSOCIATION_TIMEOUT, server detached); netem loss and reorder active during the resume packet; a kill while the server is mid-assembly of a multi-fragment client instruction.
- An explicit rule that FRONT{A}.droppedCount counts per-byte UserEvents. UserStream::apply_string splits Keystroke strings into one UserByte per char, and the subtract/diff_from asserts compare per event.
- An explicit rule that the sender must not advance its front or throwaway past the durable FRONT. Mosh sets throwaway = sent_states.front().num immediately in process_acknowledgment_through, so the port must clamp it.
- Resume must restore sent-state timestamps as 'old' so update_assumed_receiver_state picks the front rather than an unreceived back.
- First-packet ordering at bootstrap: meta.json, the Keychain key and the first counters reserve must be durable before state 1 is sent. Otherwise a crash leaves a live server the app cannot resume, and it does not exit within 60 s once a state has arrived (mosh-server.cc line 688 exits only if no remote state was ever received).
- The 'only last of consecutive Resizes reaches TIOCSWINSZ' behaviour in serve() is used by the recovery but I did not verify it.

#### cuts

- ECHO_ACK journal record and invariant I6: echo_ack is produced by the server, the client cannot violate the server-side assert (Complete::diff_from runs on server-owned states), and prediction is out of v1. Keep echo_ack only as a field inside the framebuffer checkpoint.
- Resize-repaint recovery (step 9) as an automatic production path. With W4 plus a correct dirty rule it is unreachable except through bugs, and it bypasses recv()'s deliberate 'security-sensitive' old_num check. Keep it behind a debug or manual 'repaint' action until M4 shows it is needed.
- The boot-ID (kern.bootsessionuuid) dependency if dirty is enforced in DurabilityGate: dirty=1 with any unclean shutdown can simply be treated as 'power loss possible → dead record' on the next cold start after a reboot, detected by uptime < record mtime age, without an unverified sysctl.

### 2. item

**lens:** ios-build-loop

#### verdict

The toolchain direction holds up: Linux-first core, SwiftTerm 1.99.3 as a feed-only TerminalView, swift-nio-ssh 0.15.1 and the TestFlight pipeline derived from <the author's Swift app>. Several of the plan's own claims check out. TerminalRenderView/TerminalExternalFrame are absent from the v1.99.3 tag and present on main. swift-nio-ssh 0.15.1 accepts swift-crypto 1.0.0..<6.0.0, so 5.1.1 fits. swift-crypto 5.1.1 is tools 6.2 and has CryptoExtras. Homebrew ships mosh 1.4.0 for macOS. The weak point is how the development loop is drawn. Everything that differs between Linux and iOS is first exercised by a human holding <the phone's tailnet name> at M8/M9: NWDatagramTransport, the CommonCrypto AES backend, F_FULLFSYNC, Keychain, path changes and the lifecycle ordering. That is the slowest feedback loop there is: CI of about 6 min, plus TestFlight processing of 5-30 min, plus manual steps. A cheap macOS-runner integration job against a Homebrew mosh-server would catch most of that, and an XCUITest terminate/relaunch on the simulator would too. There are also concrete design gaps. The background flush does not stop the transport before clearing the dirty flag. The session directory is not excluded from backup, so a same-device restore can bring back stale counters and the key: nonce reuse. No path-change handling is specified for Wi-Fi to cellular. The Linux Swift 6.4.2 compiler is newer than whatever Xcode 26.6 ships, so code can drift. The hardware-key layer duplicates handling that SwiftTerm 1.99.3 already has. Copying the <the author's Swift app> workflows as they are would also leave iOS CI blind to changes in the core.

#### issues

##### 1. iOS-only code paths are first tested by hand at M8/M9

**severity:** major

**title:** iOS-only code paths are first tested by hand at M8/M9

###### problem

The matrix runs OCB vectors, wire, netem and the kill-loop on Linux only. On iOS the plan uses different implementations: NWDatagramTransport (#if canImport(Network)), the CommonCrypto ECB AES backend, F_FULLFSYNC (a Darwin-only fcntl, so Linux exercises a fallback), KeychainKeyStore and the SceneDelegate flush. None of these runs against a real mosh-server before a human runs the M9 device checklist, and the device round trip is the slowest loop available. local_pipeline research measures ios-build at 5-7.5 min and release at about 6 min, plus 5-30 min of TestFlight processing. Homebrew has a mosh 1.4.0 formula (Homebrew/homebrew-core Formula/m/mosh.rb; on macOS it uses CommonCrypto), so a macOS runner can host the real server.

###### fix

Add a macos-26 job that runs `swift test` on the core package (this exercises the CommonCrypto AESBlock and F_FULLFSYNC) and runs `moshcli connect/resume` against `brew install mosh` mosh-server using NWDatagramTransport. Add an XCUITest on the simulator: start mosh-server on the runner, pass port and key via launch arguments (skipping SSH), type, call XCUIApplication.terminate(), relaunch, and assert the same `$$` on screen. That gives an automated resume-after-kill test of the real app before any phone is involved.

**verified:** True

##### 2. Dirty flag cleared while the transport may still be sending

**severity:** major

**title:** Dirty flag cleared while the transport may still be sending

###### problem

Section 3 clears `dirty` after a journal F_FULLFSYNC in sceneDidEnterBackground. The process keeps running for about 5 s after that callback, longer under a background task. MoshConnection's ACK timer (3 s), retransmits and receives keep appending REMOTE/INPUT/FRONT records and sending acks that depend on them (W4/W5). Those records are written after the fsync while dirty=0, so a power loss loses them and the resume regresses ack_num or the event list (I3/I7). The plan also does not mention beginBackgroundTask, which Apple says to call early (in willResignActive), not at the end of didEnterBackground.

###### fix

In sceneWillResignActive, begin a background task. Then quiesce MoshConnection: stop timers, stop sending, close the NWConnection. Only then fsync the journal, clear dirty with F_FULLFSYNC, and end the task. Treat any later send as a new foreground period, which sets dirty=1 first. Add this ordering as a crashpoint in the M4 kill-loop.

**verified:** True

##### 3. Session directory not excluded from backup: a restore can reuse nonces

**severity:** major

**title:** Session directory not excluded from backup: a restore can reuse nonces

###### problem

Application Support is backed up by default. The plan sets file protection but never sets `isExcludedFromBackup` (ios_platform research recommends it). The mosh key is a ThisDeviceOnly Keychain item, which is not migrated to a new device but can return when a backup is restored to the same device. Restoring then brings back old `counters` together with a valid key while mosh-server is still alive. The resume reserves from the stale seqReserved, which reuses OCB nonces and also gets the packets ignored for roaming (network.cc seq check). The journal also puts screen contents into iCloud backups.

###### fix

Set isExcludedFromBackup on sessions/ and verify it at launch. Also store a random install/record nonce in the Keychain item next to the key, and refuse a record whose files do not match it.

**verified:** False

##### 4. No path or viability handling for Wi-Fi to cellular

**severity:** major

**title:** No path or viability handling for Wi-Fi to cellular

###### problem

M9 expects the same session after a Wi-Fi to cellular switch, but section 3 only opens a new socket on foreground. An NWConnection is bound to a path. When Wi-Fi drops it goes to waiting or failed and does not migrate. TN3151 and ios_platform research call for pathUpdateHandler, viabilityUpdateHandler and betterPathUpdateHandler, with a new connection started while the old one is kept until the new one receives. The Linux 'socket rebind roams' test does not cover any of this.

###### fix

Specify a MoshConnection policy: on a better path, non-viable or failed state, create a new NWDatagramTransport with a fresh source port (the same as mosh's hop_port) and drop the old one after the first authenticated receive. Unit-test it with a fake transport. Keep the device checklist only for the radio switch itself.

**verified:** False

##### 5. Linux Swift 6.4.2 is newer than the compiler in Xcode 26.6

**severity:** major

**title:** Linux Swift 6.4.2 is newer than the compiler in Xcode 26.6

###### problem

Development and Linux CI use swift:6.4.2-noble, while the iOS build uses Xcode 26.6 (17F113 is the macos-26 default per the runner-images readme). The readme does not list Xcode's Swift version, and the plan admits it is UNVERIFIED. Xcode 26.x ships an older compiler, probably 6.2 or 6.3. tools-version 6.2 does not stop 6.4-only language or stdlib features, or Linux swift-foundation behaviour, from compiling on yellow and then failing on macOS. The plan finds out only when ios-build runs.

###### fix

Run the same `swift build`/`swift test` on macos-26 for every core change. Pick the Linux image tag that matches Xcode 26.6's `swift --version`: print it in the first CI run and pin both. Alternatively, accept 6.4 only after moving the iOS build to the xcode-27 runner.

**verified:** False

##### 6. Copied ios-build paths filter would skip iOS CI on core changes

**severity:** major

**title:** Copied ios-build paths filter would skip iOS CI on core changes

###### problem

<the author's Swift app>'s ios-build.yml filters on `ios/**` and runs xcodegen in `ios/<App>` (working-directory, lines 59/105/122). Its Fastfile hard-codes ios_dir, SCHEME, APP_IDENTIFIER, PROFILE_NAME and the Info.plist path. The plan moves the app to App/project.yml and makes it depend on the root package. Copied as they are, the filters would not run iOS builds when Sources/** or Package.swift change, so iOS breakage would go unnoticed.

###### fix

In the M6 deliverables, list the exact edits: paths: [App/**, Sources/**, Package.swift, Package.resolved, project.yml], working-directory App, and the Fastfile constants and ios_dir. Run actionlint before the first push.

**verified:** True

##### 7. HardwareKeyMapper and key repeat duplicate SwiftTerm 1.99.3

**severity:** minor

**title:** HardwareKeyMapper and key repeat duplicate SwiftTerm 1.99.3

###### problem

In v1.99.3, TerminalView already has `open override func pressesBegan` (iOSTerminalView.swift:3235), `pressesEnded` (3556) and a per-key repeat timer (`keyRepeats`/`startKeyRepeat`, 3192-3221). A MoshTerminalView override that handles some keys and passes others to super risks double sends and two repeat timers. The plan marks this as UNVERIFIED but still schedules a full mapper.

###### fix

Use SwiftTerm's handler first. Add an override only for keys that are shown to be broken (issues #591 Option-Meta drops Shift, #483), and keep UIKeyCommand for app shortcuts. Treat the mapper as optional work.

**verified:** True

##### 8. Custom key bar must drive SwiftTerm's modifier state

**severity:** minor

**title:** Custom key bar must drive SwiftTerm's modifier state

###### problem

With inputAccessoryView set to nil, SwiftTerm reads `terminalAccessory?.controlModifier ?? controlModifier` (lines 938, 960, 2519, 2857) and resets it after one key. A KeyBarView keeping its own sticky Ctrl state would get out of sync. Behaviour of keyboardLayoutGuide under the iOS 26 Liquid Glass keyboard is not documented (forum 787687).

###### fix

Have KeyBarView set and observe terminalView.controlModifier (there is a reset notification, terminalViewControlModifierReset, line 79). Keep the inputAccessoryView variant behind a flag. Get simulator screenshots of the bar on iOS 26.x and on the xcode-27 preview runner through XCUITest attachments.

**verified:** True

##### 9. Mouse, bracketed-paste and focus encoding may duplicate SwiftTerm

**severity:** minor

**title:** Mouse, bracketed-paste and focus encoding may duplicate SwiftTerm

###### problem

SwiftTerm already generates mouse reports (allowMouseReporting, forwardTap) and bracketed paste (pasteText) from its own mode state. If DisplayDiff.newFrame emits the mode sequences, SwiftTerm will produce reports by itself and the app's encoder will duplicate them. If the modes are stripped, SwiftTerm's handling has to be turned off. The plan does not say which.

###### fix

Decide this explicitly. Either let modes flow into SwiftTerm and delete the app's mouse and paste encoders, or strip the modes and set allowMouseReporting=false. Add a test either way.

**verified:** False

##### 10. CryptoExtras/BoringSSL linked into the iOS binary

**severity:** minor

**title:** CryptoExtras/BoringSSL linked into the iOS binary

###### problem

AESBlock lists CryptoExtras AES.permute or CommonCrypto. Research notes that AES.permute rebuilds the key schedule on every block and pulls BoringSSL in. Unless the dependency is limited to Linux, the iOS app links it anyway.

###### fix

Declare the CryptoExtras product with `.when(platforms: [.linux])`, use CommonCrypto on Darwin, and test both backends against the RFC 7253 vectors (the second on the macOS job).

**verified:** False

##### 11. Privacy manifest required-reason APIs not identified

**severity:** minor

**title:** Privacy manifest required-reason APIs not identified

###### problem

Detecting reboots with sysctl kern.boottime falls under the System boot time required-reason category; UserDefaults and file timestamps have categories too. The plan lists PrivacyInfo.xcprivacy but no reasons. A missing declaration produces ITMS-91053 notices; whether that blocks TestFlight is unverified. Whether kern.bootsessionuuid is readable on iOS is also unverified.

###### fix

List the APIs the app uses and declare their reasons in M6. If kern.bootsessionuuid is unreadable on iOS, fall back to kern.boottime and declare reason 35F9.1.

**verified:** False

##### 12. Export compliance answer needed before M7

**severity:** minor

**title:** Export compliance answer needed before M7

###### problem

Without ITSAppUsesNonExemptEncryption, uploads stay 'Missing Compliance' until someone answers in App Store Connect. <the author's Swift app>'s project.yml sets it to false (line 157), its Fastfile preflight warns when it is unset, and Blink ships false. The plan leaves it as an open human step.

**fix:** Set it in project.yml at M6, following <the author's Swift app> and Blink, and record the reasoning in docs/RELEASE.md.

**verified:** True

##### 13. Pinning Xcode conflicts with runner image rotation

**severity:** minor

**title:** Pinning Xcode conflicts with runner image rotation

###### problem

<the author's Swift app>'s release.yml leaves Xcode unpinned on purpose (lines 50-58 comment). The research found Xcode 26.0.1 through 26.6 on the image today, and the policy is one major version per macOS image, so older minors get removed. A hard pin can break the build overnight. A float risks the swiftCompatibility56 linker failure that <the author's React Native app> hit (fixed with the TOOLCHAINS env).

###### fix

Pin with a fallback to the default (warn when missing), print `swift --version`, and add a continue-on-error xcode-27 canary for the iOS 27 UIScene and SDK changes.

**verified:** True

##### 14. netem in GitHub ubuntu CI is unverified

**severity:** minor

**title:** netem in GitHub ubuntu CI is unverified

###### problem

M2/M4 run in 'CI' with --cap-add NET_ADMIN and tc netem. Whether the hosted runner kernel provides sch_netem inside a job container, and whether the 500-iteration nightly fits the job time limit, is not checked.

###### fix

In M0, add a smoke step (`tc qdisc add dev lo root netem delay 10ms`) and size the nightly by measuring an iteration. Keep yellow as the authoritative soak host.

**verified:** False

##### 15. UI feedback loop and charlie availability unaddressed

**severity:** minor

**title:** UI feedback loop and charlie availability unaddressed

###### problem

Without an awake Mac, every UI change costs a CI run of about 6-8 min to get a screenshot, or a TestFlight cycle (6 min CI, 5-30 min processing, manual install). Whether charlie has Xcode, and whether it can be woken remotely (Tailscale does not wake a sleeping Mac), is unverified. The key bar, keyboard chrome and hardware-key checks in M8 all need a human holding the phone.

###### fix

Add an XCUITest screenshot and video workflow (XCTAttachment, simctl recordVideo) that runs on demand, and use typeKey(_:modifierFlags:) for hardware-key tests. Check in M0 whether charlie has Xcode and its pmset wake settings, or schedule awake windows. List explicitly which M8/M9 items stay human-only: Secure Enclave, radio switch, reboot, the real Local Network prompt.

**verified:** False

#### missing

- A macOS-runner integration job against Homebrew mosh-server 1.4.0 that exercises the Darwin code paths (NWDatagramTransport, CommonCrypto, F_FULLFSYNC)
- An automated resume-after-kill XCUITest on the simulator (terminate and relaunch) before any device testing
- Ordered background sequence: beginBackgroundTask in willResignActive, quiesce the transport, fsync, clear dirty, end the task
- isExcludedFromBackup on the session store, plus a guard against restored records
- NWPathMonitor and viability/better-path handling for in-foreground roaming
- Which SwiftNIO bootstrap (NIOPosix or NIOTransportServices) the SSH bootstrap uses on iOS
- Mapping between scene sessions and mosh session records, and handling of application(_:didDiscardSceneSessions:) after a swipe-away
- Required-reason entries in the privacy manifest
- Exact edits to the paths filters of <the author's Swift app> and Fastfile constants for the App/ layout
- Swift compiler version alignment between the Linux image and Xcode 26.6
- Linux fsync fallback for F_FULLFSYNC, and which branch each platform tests

#### cuts

- HardwareKeyMapper with its own repeat timer: SwiftTerm 1.99.3 already overrides pressesBegan/Ended and has per-key repeat. Keep only the fixes for keys that are shown to be broken.
- App-side mouse, bracketed-paste and focus encoders, if the mode sequences are allowed through to SwiftTerm, which already implements them.
- Optional Secure Enclave key generation in v1: it can only be tested on a device, it is not exportable, and Ed25519 covers the requirement.
- Linux-side SurfaceKit tests of SwiftTermSurface: it is UIKit-bound, so test on the simulator with TerminalView.terminalStateSnapshot/content snapshots (these exist in 1.99.3) and keep only the HeadlessTerminal check on Linux.
- The 500-iteration nightly on hosted CI until netem and runtime are confirmed there; run the full soak on yellow.

### 3. item

**lens:** scope-ux

#### verdict

The engineering is careful: the resume invariants, the SwiftTerm 1.99.3 correction (I checked it: TerminalRenderView and TerminalExternalFrame exist only on main, not in the v1.99.3 tree) and the OSC 52 rules are well grounded. But judged by how fast one tmux/vim user gets something usable on the phone, the plan is ordered wrong and over-built. The first time anything runs on <the phone's tailnet name> is M7. Before that sit four Linux milestones: hand-built OCB3, an SSP transport, a terminal applier that must match a C++ oracle cell for cell, and a 500-iteration kill-loop WAL. iOS lifecycle behaviour (EBADF sockets, file protection, jetsam) is only exercised at M9, the last milestone. Two of the four reasons given for building from scratch are weak on the evidence. (1) Blink's mosh.xcframework is published as a ready-made SwiftPM binary asset (v1.4.0+blink-18.4.5, 95 MB zip, 2026-03-14), so nothing needs to be built on a Mac to use it. (2) Blink #2176, cited as proof that freeze-then-snapshot is unsound, is really a UI bug where restore does not fire until the user switches tabs. A from-scratch Swift core is defensible as a later goal, and it is the only way to get the Linux kill-loop tests. As the v1 critical path it is disproportionate. A tmux user can make the cost of a lost session almost nothing by attaching to the same tmux session on every bootstrap. The plan also leaves out things that hurt from day one: per-host remote command (tmux new -A), font and theme, a usable iPhone key bar layout, scrolling and selection while tmux or vim mouse mode is on, mosh's own local echo (prediction), handling of orphaned and dead mosh-servers, and specific bootstrap error messages. Recommended v1: get to the device early with a TestFlight build in week 1. Bootstrap with tmux auto-attach. Feed frames into SwiftTerm. Resume after suspend, and after a kill while backgrounded, using a snapshot taken at background time plus write-ahead counter reservations. When resume is impossible, fall back to a fresh session that lands in the same tmux. The full kill-at-any-instant WAL and the cell-exact oracle gate become hardening milestones after the user has switched.

#### issues

##### 1. Nothing runs on the phone until M7; the critical path is serial and mostly Linux-only

**severity:** blocker

**title:** Nothing runs on the phone until M7; the critical path is serial and mostly Linux-only

###### problem

Milestones M0-M5 are all Linux. TestFlight is M7 and device resume is M9. The M4 exit gate is a nightly 500-iteration kill-loop, and the M3 gate is cell-for-cell equality with a C++ oracle (the plan itself budgets about two weeks just for the applier). The research lists risks that only show up on a device and are not modelled by Linux tests: sockets reclaimed while suspended (EBADF), file-protection lock windows, iOS 26/27 keyboard chrome regressions, and macOS runner capacity failures (<the author's Cordova app>'s TestFlight job never got a runner on 3 attempts in Nov 2026). Finding these at M7-M9 means rework after the expensive core is frozen. The human-only steps (App ID, App Store Connect record, provisioning profile secret) are listed separately but not scheduled, so they will gate M7 whenever they get done.

###### fix

Move a minimal TestFlight build into M0/M1, in parallel: copy <the author's Swift app>'s release.yml/Fastfile, ship a placeholder SwiftTerm app, and get the human steps done in week 1. Reorder to M1 crypto+wire, M2 transport, M3' bootstrap (swift-nio-ssh), M3'' feed frames to SwiftTerm on the device (only the simplest applier needed: mosh's dialect over a CoW framebuffer, with oracle tests running alongside but not gating), then the key bar. Do resume after that. Run the oracle and kill-loop work as continuous hardening, not as gates in front of the device.

**verified:** True

##### 2. Engine rationale relies on a wrong reading of Blink #2176 and on a build step that is not needed

**severity:** major

**title:** Engine rationale relies on a wrong reading of Blink #2176 and on a build step that is not needed

###### problem

Reason 1 says Blink's mosh.xcframework 'needs a macOS autotools build'. gh api shows blinksh/mosh-apple release v1.4.0+blink-18.4.5 with the asset mosh.xcframework.zip (95,615,854 bytes, published 2026-03-14), which can be consumed directly as a SwiftPM binaryTarget. The only GPL obligation is to publish the corresponding source, and a GitHub macOS runner can rebuild it without charlie. Reason 2 cites open Blink #2176 as proof that snapshot-then-freeze breaks when the app is killed. The issue body actually says 'Mosh won't restore the session after a few hours and it requires to move between tabs to trigger the restore': a trigger/UI timing bug, not a soundness failure. A Blink-based client also gives mosh's real emulator, Display, prediction engine and notification bar at no cost, which removes the M3 oracle risk and the M10 prediction port.

###### fix

Restate the decision honestly. Pure Swift is chosen for Linux testability and true kill-anywhere resume, not because Blink is unbuildable. Add a time-boxed spike (2-3 days) that links the prebuilt xcframework into the M0 TestFlight shell, feeds its stdout to SwiftTerm and checks suspend/kill restore on <the phone's tailnet name>. Use that as the day-one daily driver and as a behavioural reference while the Swift core matures, or as the fallback the plan already names. Patch Blink's flow to invalidate the snapshot and reserve the seq durably before the first send after restore (whether Blink clears the blob is listed as unverified in mosh_resume).

**verified:** True

##### 3. Full write-ahead journal for kill-at-any-instant is disproportionate for v1

**severity:** major

**title:** Full write-ahead journal for kill-at-any-instant is disproportionate for v1

###### problem

Section 3 journals every input batch and every remote diff, compacts with checkpoints, and adds dirty flags, boot IDs and F_FULLFSYNC. The case it covers beyond a snapshot taken at background time is the app being killed while foreground and sending: a crash or a foreground jetsam. Normal iOS kills (jetsam while suspended, force-quit from the switcher) happen after sceneDidEnterBackground, where the research says about 5 s plus a beginBackgroundTask extension are available to write a snapshot once the transport is frozen. For a user who lives in tmux, losing the mosh session in the rare foreground-kill case costs one re-bootstrap into the same tmux session, provided the remote command is set (see the next issue). The boot-id rule depends on kern.bootsessionuuid/boottime, which the plan marks UNVERIFIED.

###### fix

For v1: reserve counters ahead on disk (keep W1/W2, which are cheap and essential), freeze the transport and snapshot at background time (all held framebuffers, sent states, A), and on foreground set a durable 'consumed' flag before the first send, so a snapshot is never reused. If the app is killed while foreground, mark the record dead and auto-bootstrap into the same tmux. Defer W3-W6, compaction, CLIPBOARD_HASH journaling and the boot-id/power-loss logic to a hardening milestone once v1 is in daily use. Keep the resize-repaint recovery (step 9) as the cheap path for a stale reference state.

**verified:** False

##### 4. No per-host remote command, so a dead session costs the user their tmux context

**severity:** major

**title:** No per-host remote command, so a dead session costs the user their tmux context

###### problem

Section 6 runs `mosh-server new -c 256 -s -l LANG=en_US.UTF-8` with no `-- command`. mosh-server accepts a trailing command, and Blink's bootstrap supports `[-- exec]` (prior_art). Without `tmux new -A -s main`, every fallback to 'Start new session' lands in a bare shell, and the user must reattach by hand on a phone keyboard. For this user this one setting is worth more than most of the resume machinery.

###### fix

Add a per-host 'Remote command' field, defaulting to empty, with one-tap presets `tmux new -A -s main` and `tmux new -A -s $(hostname -s)`. Pass it after `--`. Make the dead-record path reconnect automatically with it (key auth, no prompt) rather than only offering a button.

**verified:** True

##### 5. 'Server exit cannot be told apart from an outage' is false: SSH can check; orphaned servers pile up

**severity:** major

**title:** 'Server exit cannot be told apart from an outage' is false: SSH can check; orphaned servers pile up

###### problem

I checked /usr/bin/mosh-server 1.4.0: it contains '[mosh-server detached, pid = %d]', 'You have a detached Mosh session on this server (%s)' and 'mosh-server needs a UTF-8 native locale to run.'. The bootstrap therefore learns the server PID, which it can probe over SSH later (`kill -0 PID` or `ps -p PID -o comm=`). Host rebooted means SSH works and the PID is gone. Server died means the same. A network outage means SSH also fails. The plan's fallback only retries under a 'last contact' banner. It also never kills the old server when it starts a new session, and the default setup is never told to give servers a network timeout, so each dead record leaves an orphaned mosh-server. The user then sees the 'detached Mosh session' banner on later logins.

###### fix

Parse and persist the PID from bootstrap stderr. After N seconds with no authenticated datagram (say 10-15 s), or when the user asks, run an SSH probe and show one of three states: 'Server gone (host rebooted or mosh-server exited): reconnecting into tmux…', 'Host unreachable', or 'Server alive, UDP blocked'. When replacing a session, offer to `kill PID` of the old one. Suggest MOSH_SERVER_NETWORK_TMOUT as a per-host default, not only as an example.

**verified:** True

##### 6. Bootstrap error messages are only specified for 2FA

**severity:** major

**title:** Bootstrap error messages are only specified for 2FA

###### problem

The common first-run failures are not covered. (a) mosh-server not on PATH in a non-login exec shell, e.g. Homebrew /opt/homebrew/bin on macOS: Blink handles this with UseMoshOnPath and then a static install. (b) 'mosh-server needs a UTF-8 native locale to run.' (string confirmed in the binary): -l LANG=en_US.UTF-8 fails if that locale is not generated on the host. (c) MOSH CONNECT printed but no UDP ever arrives: firewall, or a 60001+ port that is not allowed, or an IPv6/IPv4 mismatch. (d) Wrong password versus a key that is not authorized. (e) Host key changed. (f) Server offers only RSA host keys: swift-nio-ssh 0.15.1 has no RSA (swift_libs).

###### fix

Define an error table in MoshBootstrap that maps stderr patterns and exit status to user text with a suggested fix. Cover: 'command not found' (offer a server-path field and show the PATH used), locale error (offer C.UTF-8 as an alternative), no UDP within 5 s of CONNECT (suggest a -p range or firewall), auth failure split by method (show the public key with a copy button), RSA-only host key, and keyboard-interactive-only servers. Add each as a Linux integration test case in M5.

**verified:** True

##### 7. Prediction (local echo) deferred to an optional M10

**severity:** major

**title:** Prediction (local echo) deferred to an optional M10

###### problem

Local echo is mosh's main user-visible feature on cellular. The research describes the overlay engine as about 900 lines with clear inputs (mosh_terminal section 5). <the phone's tailnet name> reaches yellow over Tailscale, often on cellular, where a 100-300 ms RTT makes vim and shell typing feel laggy. Without prediction the app is a slower SSH, and the user has little reason to switch from Blink or Moshi, which both have it.

###### fix

Make prediction a v1 milestone right after the first usable device build (adaptive mode, overlay applied to a copy of the newest framebuffer before DisplayDiff). Alternatively, if the Blink-xcframework spike is adopted, prediction comes with it. Keep the native 'last contact' banner.

**verified:** False

##### 8. Selection and scrolling break under tmux/vim mouse mode, with no override

**severity:** major

**title:** Selection and scrolling break under tmux/vim mouse mode, with no override

###### problem

Section 5 sends taps and two-finger pans as mouse reports while mouse mode is on, and allows long-press selection only when it is off. Many tmux users set `mouse on` and many vim users `mouse=a`, which leaves no local way to copy visible text. With scrollback set to 0 and ?1007 not carried (mosh_terminal section 7), a swipe when mouse mode is off does nothing, so the only way to see history is tmux copy-mode through the key bar. SwiftTerm has an open issue with double tap under mouse reporting (#663, swift_libs risks).

###### fix

Add a force-local-selection gesture or key-bar toggle (e.g. long-press always selects locally; mouse reports only for taps and pans). With mouse mode off, map a vertical swipe to a configurable action: send PgUp/PgDn, or the tmux prefix plus '[' and then arrows. With mouse mode on, map it to wheel events. Document that copy works only for the visible screen.

**verified:** False

##### 9. Key bar does not fit an iPhone width, and its layout choices fit iPad more than iPhone

**severity:** minor

**title:** Key bar does not fit an iPhone width, and its layout choices fit iPad more than iPhone

###### problem

The bar has 14+ keys (Esc, Tab, Ctrl, Alt, 4 arrows, | / ~ -, Paste, dismiss). On a phone about 393 pt wide that is under 28 pt per key, well below the 44 pt touch target. `followsUndockedKeyboard` only matters for the undocked/floating iPad keyboard. Nothing says what happens when a hardware keyboard is attached: Blink hides its bar and uses a heuristic, `isHardwareKB = height < 150`. PgUp/PgDn/Home/End and a tmux-prefix key are missing from the soft bar. In M7 'runs vim' depends on SwiftTerm's default accessory still being present, because M8 removes it.

###### fix

Use a horizontally scrolling bar, or a fixed-plus-scrolling bar, with 40+ pt keys: Esc, Ctrl, Tab and arrows fixed; symbols, PgUp/PgDn, Home/End, a configurable 'prefix' key (default C-b) and Paste in the scrolling part. Collapse the bar to Esc plus arrows when a hardware keyboard is attached. Keep SwiftTerm's TerminalAccessory until M8 replaces it. Drop followsUndockedKeyboard as irrelevant on iPhone.

**verified:** False

##### 10. Font and theme are not specified at all

**severity:** minor

**title:** Font and theme are not specified at all

###### problem

Cmd-+/- is the only mention. A daily driver needs, from the start: font size that persists per device, pinch-to-zoom, a monospace choice with powerline/Nerd glyphs (tmux status lines and vim plugins use them), a dark theme with a 16-colour palette, cursor style (mosh does not carry DECSCUSR, so it has to be a local setting), and bell to haptic (the plan strips BEL but never says what it does with it).

###### fix

Add a small Appearance settings item to M8: bundled font (e.g. JetBrains Mono Nerd Font, check its OFL licence), size slider plus pinch, 2-3 palettes, cursor style, bell to haptic. Keep the cols/rows recomputation and resize path tied to font size changes.

**verified:** False

##### 11. OSC 52 known limits are only partly documented to the user

**severity:** minor

**title:** OSC 52 known limits are only partly documented to the user

###### problem

The plan documents the tmux Ms override and vim.g.clipboard='osc52'. It does not say that copying identical text twice does not propagate (mosh #1090 open, fix PR #1104 unmerged), that neovim's '*' register (52;p;) is dropped by the server, or about the 16 KiB cap and silent truncation. Without this the user will file 'copy is flaky' bugs against the app. The research also recommends keeping the trailing %p1%s in the Ms override.

###### fix

Add an in-app 'Clipboard setup' help page with the exact tmux line (`set -as terminal-overrides ',xterm*:Ms=\E]52;c%p1%s;%p2%s\a'`, then reattach), the nvim lines (use '+'), and the known limits (identical re-copy, 16 KiB). Make the 'Copied N bytes' toast distinguish truncated or invalid base64.

**verified:** True

##### 12. Feeding frames with autowrap off and explicit CUP is not a port of Display::new_frame

**severity:** minor

**title:** Feeding frames with autowrap off and explicit CUP is not a port of Display::new_frame

###### problem

Section 4 says DisplayDiff is a 'port of Display::new_frame' but also says to 'never rely on SwiftTerm autowrap (ESC[?7l once)'. new_frame conveys wrapped rows only through the receiver's autowrap, and advances by the server's cell width without moving the cursor (mosh_terminal section 2.8). With autowrap off it needs changes: per-cell or per-wide-character CUP to absorb width disagreements between SwiftTerm and the generated glibc table, and lost wrap flags make copied wrapped lines contain hard newlines. Whether SwiftTerm reflows or resizes its own buffer on view bounds change, which would fight the model, is unverified.

###### fix

Treat the SwiftTerm feed generator as a separate encoder (not new_frame): CUP after every wide or ambiguous-width cell, and hand SwiftTerm the grid size explicitly rather than letting it derive the size from bounds. Add the SurfaceKit equivalence test with emoji, CJK and wrapped lines. Accept that selection across wrapped lines inserts newlines in v1.

**verified:** False

##### 13. Multiple sessions: scope is unclear (Cmd-N listed while concurrent sessions are out of scope)

**severity:** minor

**title:** Multiple sessions: scope is unclear (Cmd-N listed while concurrent sessions are out of scope)

###### problem

Section 5 lists Cmd-N as an app command, but section 9 puts multiple concurrent live sessions out of scope. Nothing says what happens to session A's record when the user opens host B: whether it is snapshotted and kept for later resume, or discarded. The session list UI is named (SessionListViewController) but its contents are not defined: live, suspended, dead, last contact.

###### fix

State the v1 rule: one live session, others suspended (snapshot written, socket closed) and resumable from the list. List rows show host, state (live, resumable, dead, server gone) and last contact, with swipe actions to 'kill remote server' and 'forget'. Drop Cmd-N or make it open the host list.

**verified:** True

##### 14. Over-built extras on the v1 path

**severity:** minor

**title:** Over-built extras on the v1 path

###### problem

The plan includes a QR-code key export, an optional Secure Enclave P-256 key (device-bound, cannot be simulated, adds an ecdsa code path), mouse encodings 1005/1015/X10 (which modern tmux and vim do not need beyond 1006), focus events, and a 500-iteration nightly kill-loop plus a negative no-journal run on CI. These are fine eventually but each costs effort before the user can switch.

###### fix

For v1 keep Ed25519 only, copy plus share sheet, SGR 1006 and X10 mouse only, and a 50-iteration kill-loop run on demand. Move Secure Enclave, QR, 1005/1015, focus events and nightly soak runs to later milestones.

**verified:** False

#### missing

- Per-host remote command after '--' (tmux new -A -s main), plus automatic reconnect into it when the session record is dead
- Capture the mosh-server PID from bootstrap stderr ('[mosh-server detached, pid = %d]') and probe it over SSH to tell 'server gone' from 'network down'; offer to kill the old server
- An error table for bootstrap failures: mosh-server not on PATH (non-login shell, Homebrew), UTF-8 locale missing, no UDP after MOSH CONNECT, auth failure by method, RSA-only host key, keyboard-interactive-only
- Appearance settings: font with powerline glyphs, size and pinch zoom, palette, cursor style (DECSCUSR is not carried by mosh), bell to haptic
- A gesture to force local selection while tmux/vim mouse mode is on, and a swipe-to-scroll mapping (tmux copy-mode or PgUp) when mouse mode is off
- Hardware-keyboard-attached behaviour for the key bar (collapse or hide), and a configurable tmux prefix key
- A session list definition: states, last contact, kill-remote and forget actions; what happens to session A when host B is opened
- Scheduling of the human-only App Store Connect steps in week 1, and an early TestFlight smoke build to de-risk signing and runner capacity
- An on-device resume smoke test early (background, then jetsam simulation via the debug abort) instead of only at M9
- In-app clipboard help covering tmux Ms, nvim '+', and the known server limits (identical re-copy #1090, '*' dropped, 16 KiB)
- A GPL source-publication and licence-notice screen in the app (required by COPYING.iOS) if porting mosh code or linking Blink's fork
- A one-time onboarding step that copies the public key and shows the exact authorized_keys line, so password auth is needed only once

#### cuts

- Move the full write-ahead journal (W3-W6, compaction, REMOTE/INPUT journaling) to after v1; ship counter reservations plus a snapshot taken at background time plus a consumed flag
- Drop the boot-id / power-loss dirty rule (depends on unverified iOS sysctls; rare case)
- Make the M3 cell-exact oracle a running test suite, not a gate in front of device work
- Cut the nightly 500-iteration kill-loop and the negative no-journal CI run to an on-demand 50-iteration run
- Defer the Secure Enclave P-256 key option and the QR-code export
- Drop mouse encodings 1005 and 1015 and focus events (?1004) from v1; keep SGR 1006 and X10
- Drop followsUndockedKeyboard (iPad-only) and Cmd-N (contradicts single-session scope)
- Defer the custom CRC-framed journal format and the CLIPBOARD_HASH record; dedupe the clipboard in memory plus 'ignore the clipboard in the first diff after a cold resume'

