# iOS-mosh — plan

> Addresses, ports and details of the author's own network were removed before publication.

## Context

Trick wants a personal iPhone terminal app, **iOS-mosh**, that uses mosh only, so a
session survives iOS suspending or killing the app. This version answers his feedback
of 2026-11-12:
- **TestFlight:** gone. I build on the Mac `charlie` over SSH and install straight
  onto the phone.
- **Cycles:** two. Run 1 ends with the full daily-driver build on the phone. The
  milestones in the reference (M0–M10) are my own checkpoints, not hand-offs.
- **What I need from you:** four set-up steps on the evening you switch charlie on
  (below). Your three answers are in: look at charlie before asking for signing
  material, test against a throwaway container, charlie on for one evening.

**You only need to read down to "Implementation reference".**

## Status and next step (2026-11-12 03:10 UTC)

This plan was approved earlier today and nothing in it has changed. The session was
interrupted and restarted, so this section says where the work stands.

Done (all on yellow, pushed to the private repo `trickv/ios-mosh`, `main` = `6e9aa90`):
- repo, licence, plan and research notes, dev Docker image (Swift 6.2, mosh 1.4.0,
  `sshd`), package skeleton that builds and tests, lossy-network simulation working
- four git worktrees ready for parallel work (`.worktrees/core|term|oracle|boot`)

Next, as soon as you approve (needs only yellow):
1. **Wave 1**: one background workflow of 9 agents writes and tests the mosh core
   (crypto and wire, transport, terminal model and its test oracle, SSH bootstrap and
   keys). Each agent must pass its exit test against the real `mosh-server` or `sshd`.
   This takes several hours. Details are in "Execution notes for Run 1".
2. **Wave 2**: I merge the branches, then integration, a hostile review of the
   transport, and the resume code with its kill tests.
3. **Mac work** the moment I can log in to charlie, ahead of anything else.

Still needed from you: the SSH key from step 2 of "What I need from you". charlie and
the phone both show online on Tailscale now, but `~/.ssh/ios-mosh-charlie` does not
exist on yellow yet, so I cannot get in. The restart also stopped my watcher for that
key; I start it again on approval.

## What you get

Build 1, the first thing you are asked to try, is the full daily driver:
- connect to a host over mosh, logging in with an on-device key or a password (SSH is
  used once per session, to start `mosh-server`)
- a real terminal: tmux, vim, colours, wide characters, Wi-Fi to cellular roaming
- the session comes back after the app was suspended, force-quit or updated, or the
  phone restarted in your pocket
- key bar (Esc, sticky Ctrl and Alt, Tab, arrows, PgUp/PgDn, tmux prefix, Paste) and
  hardware keyboard
- OSC 52 copy from tmux and neovim to the iOS clipboard; paste without the iOS prompt
- key generation, Keychain storage, public key copy and share

Known gap in Build 1: if the app crashes while it is on screen, the mosh session is
lost and the app connects afresh (2–3 seconds). Each saved host has a start command;
set it to `tmux new -A -s main` (a preset) and you land back in the same tmux.

Not in Build 1: themes and a bundled font (Build 2), session states and "End
session" in the host list (Build 2), local echo prediction, key import, RSA-only
hosts, 2FA, ProxyJump, local scrollback (tmux does it), iPad layouts.

## How a build reaches your phone

I edit and test on yellow (Swift runs there in Docker, nothing to install), build on
charlie over SSH, and install with Apple's `devicectl`. Limits:
- The reliable route is the phone plugged into charlie. On charlie's Wi-Fi it usually
  works too, once the phone has been paired by cable. Tailscale is not enough for an
  install.
- The phone must be unlocked while a build installs and starts. I leave an installer
  waiting on charlie, so unlocking the phone at home is normally all you do.
- charlie must be awake, on power and logged in at its screen (locked is fine).

## What I need from you (the evening you switch charlie on)

1. **charlie on.** On power, lid open, your user logged in, Remote Login on (System
   Settings > General > Sharing). Xcode must be installed and new enough for the
   phone's iOS; if you know it is missing or old, update it from the App Store
   beforehand (a long download). From that evening I hold charlie awake with
   `caffeinate` until Build 1 is on your phone. Tell me if you want it released
   sooner; I then need a second window of a few hours for the app work.
2. **SSH key for me.** On yellow (write `USER@charlie` if your account there is not
   `trick`):
   `[ -f ~/.ssh/ios-mosh-charlie ] || ssh-keygen -t ed25519 [an option removed for publication] -C ios-mosh-agent -f ~/.ssh/ios-mosh-charlie`
   `ssh-copy-id -i ~/.ssh/ios-mosh-charlie.pub charlie`
   My sessions cannot use your agent while you are logged out. The key is a
   dedicated key, used only for charlie.
3. **Phone.** With charlie unlocked, plug the phone in with a data cable, click Allow
   if charlie asks about the accessory, unlock the phone and tap Trust. Leave it
   plugged in. I start the pairing from charlie and DM you: only then does Settings >
   Privacy & Security > Developer Mode appear. Switch it on, restart, confirm.
4. **Be on Slack for the first half hour.** I look at charlie first, as you asked,
   and send you one list of what is missing. Likely items: a signing credential (an
   App Store Connect Team API key with the Admin role: the `.p8` file and the issuer
   id, in `charlie:~/signing/`, unless I find a key already there) and one `sudo`
   line (Xcode licence or Homebrew).

Approving this plan starts the Linux work at once. The Mac work starts when the key
from step 2 lets me into charlie.

## Runs

| Run | What I do without you | What you do |
|---|---|---|
| 1 | The mosh core, tested on yellow against the real `mosh-server` (starts on approval). First evening with charlie: get in, sort out signing, put a blank app on the phone to prove the route. Then the app, tested on charlie's simulator and on the phone, and Build 1 installed | Two or three times, when I DM you: at home, Tailscale on, unlock the phone and keep it awake for about two minutes. The first time a blank test app appears. Later the app installs and opens by itself for a connect test. After my "ready" DM, use Build 1 for real work and tell me what is wrong |
| 2 | Your fixes, themes, font, session states in the host list | Unlock once, then use Build 2 |
| Later, if you want | Resume after a crash at any instant; local echo; TestFlight | |

Run 1 is many hours of work. I keep going in this session and set my own wake-ups
while I wait for charlie or the phone, so you do not need to restart me. If something
outside my control stops me (a usage limit, yellow restarting), a "continue" from you
picks it up from the notes in the repo.

Before I call Build 1 ready, everything in "What you get" that a simulator can test
has passed on charlie's simulator, and a scripted login and mosh session has passed
on your phone. I cannot test these without you, so expect rough edges: keyboard feel,
Wi-Fi to cellular roaming, the iOS paste prompt, the Local Network prompt, resume
after a phone restart. Build 1 comes with a short checklist for them.

## Decisions I made for you

- I write the mosh client in Swift and do not wrap Blink's library (Blink's is the
  fallback). Resume needs changes inside the protocol code, and Swift code can be
  tested on yellow without the Mac.
- Private GitHub repo `trickv/ios-mosh`, GPLv3 (it ports GPL mosh code), created
  when you approve.
- iOS 18 or later, iPhone only.
- Before I say a build is ready I test it on the phone itself, end to end, against a
  throwaway Docker container on yellow with its own `sshd` on a high port (your
  idea). Your hosts and `authorized_keys` are not touched; you add the app's key to
  yellow from its Keys screen.
- I send you a Slack DM when a build is waiting, or when I am blocked on charlie or
  the phone.

---

# Implementation reference

Trick can stop reading here.

## Background

Trick wants a new iOS terminal app, **iOS-mosh**, whose only remote protocol is mosh.
SSH is used once per session, to start `mosh-server`. Because the session lives on the
server and runs over stateless UDP, the app never needs background execution: when iOS
suspends or kills it, opening the app again continues the same session.

Required features (from the request):
- mosh-only transport, with resume of the same session after the app process is killed
- mobile terminal keyboard extensions (key bar, hardware keyboard)
- OSC 52 copy/paste
- SSH key generation, secure storage and public-key export

Decisions confirmed with Trick on 2026-11-11:

| Topic | Answer |
|---|---|
| Build setup | Mac `charlie` over SSH: build, simulator tests, install on the phone. No GitHub Actions |
| Distribution | Development-signed builds installed from charlie straight onto Trick's iPhone (changed 2026-11-12: no TestFlight). Personal use, so GPL mosh code may be ported or linked; the repo is GPLv3 |
| Devices | iPhone first |
| SSH login for bootstrap | On-device generated keys + password. No key import, 2FA or ProxyJump in v1 |

Two findings from research shape the plan:

1. **Stock mosh cannot resume after the client process dies.** The client must persist
   its own protocol state. If it gets this wrong it either reuses an AES-OCB nonce or
   trips an `assert()` inside `mosh-server`, which aborts the server and kills the
   remote shell. Resume correctness is therefore the core engineering problem, and it
   is tested against the real `mosh-server` before any UI exists.
2. **Other apps already do this** (Blink, Moshi, La Terminal, Spectty, Moshpit). This
   project is a personal build-your-own. Two open-source Swift implementations exist
   (Spectty, swift-mosh), and both have correctness defects found in research, so they
   serve as references and are not forked.

## Approach

**Engine: a pure-Swift mosh client core, built and tested on Linux. SwiftTerm draws the
screen. swift-nio-ssh does the one-off SSH bootstrap.**

Why this engine:
- Resume needs changes inside the transport (durable counters, snapshot, restore), so
  the protocol code has to be ours.
- The core builds and runs in Docker on `yellow` against the real `mosh-server` 1.4.0
  and `sshd`, with no Mac, so most of the work does not depend on charlie being awake.
- Spectty does not persist its send sequence (nonce reuse after a restart). swift-mosh
  keeps a single framebuffer, so it cannot apply a diff against an older acknowledged
  state. Both are MIT and stay as reading references.

Named fallback (not planned work): Blink's prebuilt `mosh.xcframework`
(`blinksh/mosh-apple` release `v1.4.0+blink-18.4.5`, usable as a SwiftPM binary target).
Switch to it if the Swift terminal applier cannot match mosh's own emulator, or the
transport cannot pass the kill tests in M6.

**Order of work: pipeline first.** A blank app is built and device-signed on charlie
on the first evening and installed on the phone as soon as the phone is in reach, so
signing and device problems show up early. The core is built on Linux (it starts on
approval and does not wait for charlie), then the app. Trick is first asked to try it
when the complete daily driver is on the phone.

**Resume in two stages.**

| Stage | Mechanism | Survives | Does not survive |
|---|---|---|---|
| 1 (v1, M6) | Snapshot written every time the app leaves the foreground | Suspend, jetsam while suspended, force-quit, app update, reboot while backgrounded | Crash or power loss while the app is in the foreground |
| 2 (M9) | Write-ahead journal | Kill at any instant | Device power loss while in the foreground |

When a session cannot be resumed, the app says so and bootstraps a new one without
being asked. With the per-host remote command set to `tmux new -A -s main`, the new
session lands in the same tmux, so the cost is a 2–3 second reconnect.

## Scope

In v1 (M0–M8; Build 1 is M0–M7, Build 2 adds M8):
- mosh sessions with stage 1 resume, roaming between Wi-Fi and cellular
- SSH bootstrap with an on-device Ed25519 key or a password, host-key pinning (TOFU)
- per-host settings: user, port, `mosh-server` path or prefix, UDP port range, remote command
- key bar, hardware keyboard, paste, local text selection
- OSC 52 copy from the remote to the iOS clipboard
- key generation, Keychain storage, public-key copy and share
- font size, theme, bell as haptic

After v1: stage 2 resume (M9), local echo prediction (M10).

Not planned: iPad layouts, key import, RSA keys or RSA-only hosts, 2FA and
keyboard-interactive login, ProxyJump, agent forwarding, saved passwords, local
scrollback (use tmux), several live sessions at once, iCloud sync, Secure Enclave keys,
QR export, OSC 8 links, sixel and kitty graphics, TestFlight (can be added later, section 7), public App
Store release.

## Repository layout

New repo `trickv/ios-mosh` at `/home/trick/src/github.com/trickv/ios-mosh`. Licence
GPL-3.0-or-later. Bundle id `us.v9n.ios-mosh` (since 2026-11-21 the Release/TestFlight
app; Debug builds are the separate app `us.v9n.ios-mosh.dev`, and the `devicectl`
commands below act on that id, `docs/BUILD.md`). Private. (GPL only requires giving
the source to people who receive the app, and that is Trick.)

| Path | Contents |
|---|---|
| `Package.swift` | Package `MoshKit`, tools 6.2. CryptoExtras is a dependency on Linux only. The test-only target `SurfaceFeedTests` depends on SwiftTerm |
| `Sources/CZlib` | SwiftPM `systemLibrary` for zlib (mosh needs real zlib framing) |
| `Sources/MoshCrypto` | `AESBlock` (CommonCrypto on Apple, CryptoExtras on Linux), `OCB3` (RFC 7253 port), `MoshCipher`, `Base64Key` |
| `Sources/MoshWire` | `ProtoLite` (hand-written protobuf, about 200 lines), `Instruction`, `UserMessage`, `HostMessage`, `Fragmenter`, `FragmentAssembly`, `Packet` |
| `Sources/MoshTransport` | `DatagramTransport` protocol, `POSIXDatagramTransport`, `NWDatagramTransport` (`#if canImport(Network)`), `TransportSender`, `TransportReceiver`, `RTTEstimator`, `MoshConnection` actor, `DurabilityGate` protocol with `InMemoryGate` (used until M6) |
| `Sources/MoshTerminal` | `Framebuffer` (copy-on-write), `Parser`, `Applier`, `DisplayDiff`, `WCWidthTable` (generated from glibc), `SurfaceFeed` (builds the byte feed for SwiftTerm from two framebuffers, rules in section 2) |
| `Sources/MoshResume` | `SessionRecord`, `Counters`, `Snapshot`, `SessionStore`, `ResumeCoordinator`; `Journal` arrives in M9 |
| `Sources/MoshKeys` | `KeyGenerator`, `OpenSSHPublicKey`, `Fingerprint`, `KeyStore` protocol, `FileKeyStore` (tests) |
| `Sources/MoshBootstrap` | `SSHBootstrap`, `MoshServerCommand`, `ConnectLineParser`, `BootstrapError`, `KnownHosts`, `ServerProbe` |
| `Sources/MoshSession` | Facade the app talks to: connect, resume, input, resize, events. Also `ClipboardPolicy` (decision logic, tested on Linux) |
| `Sources/moshcli` | Test executable, described under "Test tools" below |
| `Tools/mosh-oracle` | mosh at tag `mosh-1.4.0`, built in the dev image with its own `./autogen.sh && ./configure && make`, plus a small `main.cc` linked against the static libraries from that build. Prints framebuffers as JSON. Linux, tests only |
| `App/IOSMosh` | `SceneDelegate`, `SessionListViewController`, `HostEditorViewController`, `KeysViewController`, `TerminalViewController`, `KeyBarView`, `PasteController`, `ClipboardWriter` (UIPasteboard and toast), `AppearanceSettings`, `KeychainKeyStore` |
| `App/SurfaceKit` | `TerminalSurface` protocol and `SwiftTermSurface` (the only app file that imports SwiftTerm) |
| `App/IOSMoshTests`, `App/IOSMoshUITests` | App-hosted unit tests and XCUITests |
| `App/project.yml` | XcodeGen project, adapted from `/home/trick/src/github.com/trickv/<the author's Swift app>/ios/<App>/project.yml` (edit list in section 7) |
| `docker/Dockerfile.dev` | `swift:6.2-noble` (Ubuntu 24.04, mosh 1.4.0) plus `zlib1g-dev mosh openssh-server iproute2 locales g++ tcpdump tmux vim htop procps autoconf automake pkg-config protobuf-compiler libprotobuf-dev libncurses-dev libssl-dev` |
| `scripts/` | `dev.sh` (run anything in the container), `itest.sh`, `netem.sh`, `killloop.sh`, `gen-wcwidth.c`, `record-golden.sh`, `mosh-spawner.py` (starts a `mosh-server` per UI test on charlie), `mac.sh` (sync the tree to charlie and run a command there), `deploy.sh` (build, sign, install on the phone), `smoke-host.sh` (throwaway `sshd` and `mosh-server` container for the phone self-test) |
| `docs/` | `BUILD.md` (charlie setup and deploy commands), `RESUME.md` (invariants and record format), `SERVER-SETUP.md` (tmux and neovim clipboard lines), `research/` |
| `CLAUDE.md` | House style: Project Status, Build and install pipeline ("things that will bite"), Repository Layout, Commands |

Pinned dependencies: SwiftTerm exact `1.99.3`, swift-nio-ssh `0.15.1`, swift-crypto 5.x.

**Test tools.** The scripts behind the exit tests drive `moshcli`:

- Subcommands: `handshake`, `bootstrap`, `connect`, `resume`, `soak`.
- `connect` and `resume` take `--script FILE`, one command per line: `type TEXT`,
  `key NAME`, `resize W H`, `wait-ack`, `expect TEXT TIMEOUT`, `settle MS`,
  `dump-screen FILE`, `quiesce`, `quiesce --after-send`, `sleep MS`.
- `--record DIR` writes each received instruction (`old_num`, `new_num`, the raw
  `HostBytes` strings in arrival order, terminal size). This is the corpus format.
- `--seq-log FILE` logs every sequence number sent. `--crashpoint N` exits at a named
  write, fsync or rename (`--crashpoint list` prints them). `SIGUSR1` quiesces.
- Exit codes: 0 done, 3 fallback needed, 4 server ended.
- As built: `connect --session-root DIR` keeps a session record, and `resume --session-root
  DIR` is the cold start from it (exit 3 for the fallback, 8 for "try again later";
  `--info` prints the record's state and the server pid, which the plan had in `meta.json`).
  With a record, the script's `quiesce` also stores the snapshot. `--seq-log FILE` also
  writes `FILE.numbers`, every number taken from the gate. `--crashpoint` takes a step name
  or `#K` (the Kth step) with `:before`, `:after` or `:torn=BYTES`, and kills the process
  with SIGKILL; `--step-log FILE` lists the steps. `--loss PERCENT` drops datagrams in the
  client. `docs/RESUME.md` has the results of the stage 1 table.

`mosh-oracle` reads a recorded directory, applies each diff to its copy of state
`old_num` with mosh's own parser and emulator, and prints one framebuffer per
`new_num`, with every field listed in section 2. The Swift test does the same and
compares field by field and cell by cell.

## Design

### 1. Transport

A port of mosh's `Network::Connection`, `TransportSender` and `Transport` receive path.
Wire format and constants are in the appendix.

- `MoshConnection` is an actor that owns the sender, the receiver and one
  `DatagramTransport`. Time is injected, so tests run on a fake clock. Fake clocks
  start well above zero, because mosh's timer code uses 0 and −1 as "never".
- `DatagramTransport` has two implementations: POSIX sockets (Linux and tests) and
  `NWConnection` (iOS). Sockets are disposable. On foreground, on a better path, and on
  a non-viable or failed path, the connection opens a new one (new source port, like
  mosh's port hop) and drops the old one after the first authenticated datagram arrives
  on the new one. The server follows the client to the new address.
- Every send passes through `DurabilityGate`, which holds the rules in section 3. The
  transport cannot send a sequence number, state number or fragment id that is not
  reserved on disk. Until M6 the gate is `InMemoryGate` and no session record is
  written.
- Server shutdown (`new_num` = 2^64 − 1) is acknowledged, shown as "Session ended" and
  marks the record ended. That value never enters the counter logic.

### 2. Terminal layer

mosh sends screen states as diffs: escape sequences, produced by mosh's
`Display::new_frame`, that turn one framebuffer into another. The client must hold a
framebuffer for every state the server may use as a base.

- `Framebuffer` is a copy-on-write value type, one per received state. Its fields,
  all saved in the snapshot:
  - width, height, the cells (contents, renditions, wide, fallback) and each row's
    wrap flag
  - cursor position and visibility, reverse video
  - the pen (current rendition). A diff starts from the base state's pen and leaves
    out the colour change when the first cells already match it, so a state restored
    without its pen draws wrong colours from then on
  - bracketed paste, mouse reporting mode, mouse encoding, focus events
  - icon name, window title, clipboard, bell count, echo ack
- `Applier.apply(hostBytes:to:)` understands only what `new_frame` emits (list in the
  appendix). Unknown sequences are ignored and logged. Character widths come from a
  table generated from glibc, so client and server agree on cell positions.
- `DisplayDiff.newFrame(from:to:)` is a Swift port of `new_frame`. Property test: for
  any two framebuffers `a` and `b`, applying `newFrame(a, b)` to `a` gives `b`.
- **Drawing.** `SwiftTermSurface` keeps the last framebuffer it showed. On each display
  tick it takes the newest state, asks `SurfaceFeed` for the bytes
  (`newFrame(lastShown, newest)` plus the rules below) and passes them to SwiftTerm's
  `TerminalView.feed(byteArray:)`. Intermediate states are skipped.
  - The surface calls `changeScrollback(nil)` when it creates the view. This removes
    SwiftTerm's own 500-line scrollback and its reflow on resize, which would
    otherwise fill with partial mosh frames.
  - SwiftTerm autowrap stays on. `new_frame` relies on it for wrapped lines, and it
    keeps soft-wrap marks, so copied text has no stray newlines.
  - After each wide or combining character the feed adds an explicit cursor position,
    so a width disagreement in SwiftTerm cannot shift the rest of the row.
  - Mouse, bracketed-paste and focus modes are passed to SwiftTerm, which then
    produces mouse reports and paste wrapping itself. No app-side encoders.
  - `ESC[?1h` is sent to SwiftTerm when the view is created and again after any
    reset, so arrows go out as `ESC O A..D`. mosh-server translates them for the
    application.
  - Title, bell and OSC 52 are left out of the feed. The app reads them from
    framebuffer fields.
  - Size changes: SwiftTerm resizes its own buffer from the view bounds and then
    calls `sizeChanged`. On that callback the surface marks `lastShown` as "not
    initialised", so the next feed is a reset, clear and full repaint. The surface
    never calls `TerminalView.resize(cols:rows:)`, `softReset()` or
    `resetToInitialState()` (they reset cursor-key mode).
- The terminal view comes from SwiftTerm tag 1.99.3. `TerminalRenderView` exists only
  on SwiftTerm `main`. `TerminalSurface` keeps a later swap to it inside one file.
- A native banner shows "Last contact N s ago" when the server is late (mosh's
  thresholds: 6.5 s without a server packet, 10 s without a reply).
- Not carried by mosh at all: scrollback, alternate screen, cursor shape. Scrollback is
  tmux's job. Cursor shape is a local setting.

### 3. Resume

Hard failures. Each one is permanent, and each has a test against the real server:

| | Failure | Effect |
|---|---|---|
| N1 | A datagram sequence number is used twice under one key | AES-OCB nonce reuse |
| N2 | A state number is reused with different content, or a new state carries a shorter input list than an earlier one | `mosh-server` hits an `assert` in `UserStream` and exits. The remote shell dies |
| N3 | `throwaway_num` is above `old_num` | The server erases its reference state and then uses it: undefined behaviour, or `fatal_assert` when every state is gone |
| N4 | A fragment id is reused with different content | Assert in fragment assembly |

Soft failure: the client and server no longer share a base state. Packets are ignored
and the screen freezes, but nothing is damaged. The receiver detects it: an
instruction whose `old_num` equals its `throwaway_num` and is not held can never be
applied. That goes to the fallback.

**Session record**, in `Application Support/sessions/<uuid>/` (excluded from backup,
file protection "until first unlock"):

| Item | Content |
|---|---|
| Keychain item, account = uuid, `AfterFirstUnlockThisDeviceOnly` | 16-byte session key |
| `meta.json` | Host, numeric IP, UDP port, user, server PID and process start time, remote command, created |
| `counters` | `seqReserved`, `numReserved`, `fragIdReserved`, `dirty`. Two slots, each with a generation number and CRC, so a torn write leaves the older slot valid |
| `snapshot` | Sender: acknowledged state number `A` and the input events since `A` (keystrokes and Resizes, in order). Receiver: every held state number with its full framebuffer (field list in section 2), highest ack sent, the expected sequence number of the next server datagram. The first unused sequence number, state number and fragment id (a floor the import checks the gate against; numbers still come from `counters`). Terminal size. Hash of the last clipboard written to iOS |
| `lock` | `flock` held by the live connection. Only one writer per record |

A record needs key, counters and meta. If one is missing the record is deleted. This
covers restore from backup, which brings back the Keychain item without the files.

As built (`docs/RESUME.md` has the format byte by byte and the invariants with their
tests): `meta` is binary with a checksum like the other parts, not JSON; the key is a
file `key` where there is no Keychain; a counters slot also says "ended" and, when clean,
which snapshot it is clean for; and a change of the limits or to "dirty" is written to
both slots, not one, so that a slot lost later cannot bring back lower limits or a stale
"clean". After the review of the resume code (`docs/notes/review-resume/`): the directory's
backup exclusion is set and checked by the package itself, and a record that is not excluded
is deleted, not resumed; a record is made once (an existing directory is refused); a record
that is given up (fallback, "Start new session") says "dirty", and only a session ended on
purpose says "ended", so an unfinished fallback is repeated at the next start.

**Rules**, enforced in `DurabilityGate`:

- **Reserve ahead.** Sequence numbers are reserved in blocks of 65,536; state numbers
  and fragment ids in blocks of 1,024. The new limit is written with `F_FULLFSYNC`
  before any number in the block is used. A restart begins at the reserved limit.
- **Dirty before send.** `dirty = 1` is written with `F_FULLFSYNC` before the first
  datagram after a snapshot is taken or loaded. A snapshot is valid only while
  `dirty = 0`.
- **Quiesce before snapshot.** In this order:
  1. Stop timers and sends and close the socket.
  2. Rationalise the sender, so the input list is counted from `A` and the front
     state's own list is empty. (mosh advances the front on an ack but trims the
     lists later, on the next timer tick. A snapshot taken in between would pair the
     new `A` with events counted from the old one, and the server would get them
     twice.)
  3. Write the snapshot (temp file, `F_FULLFSYNC`, rename).
  4. Write `dirty = 0`, but only if no datagram passed the gate since step 2. The
     check and the write are one critical section. The count for the check comes
     with the exported snapshot (one call), not from a separate read of the gate.
- **Numbers come from the gate.** New state numbers and fragment ids are taken from
  the gate's counters, never from "last number + 1".
- **`throwaway_num ≤ old_num`** on every instruction (N3).
- **Unknown acks are ignored.** An ack for a state number the sender does not hold
  changes nothing. After a resume the server can ack a pre-kill state.
- **Lifecycle operations run one at a time**, in arrival order: a quiesce finishes
  before a return to the foreground starts.

**Leaving the foreground** (`sceneWillResignActive`): `beginBackgroundTask`, quiesce,
snapshot, end the task. This takes milliseconds. System alerts and the app switcher
also fire this callback, so it runs often. With no established session (bootstrap in
flight) the handler does nothing. **Returning with the process alive**
(`sceneDidBecomeActive`): write `dirty = 1`, open a new socket, continue from memory.

**Cold start with a record:**

1. Take the lock and read `counters`. If `dirty = 1`, go to the fallback.
2. Load the key and the snapshot.
3. One `counters` write with `F_FULLFSYNC`: next sequence, state and fragment numbers
   start at the old limits, new limits are reserved, `dirty = 1`.
4. Rebuild the receiver: the map of state number to framebuffer. Paint the newest.
5. Rebuild the sender. A Resize is added to the pending input if the view size
   changed.
   - With pending input: `[{num: A, events: []}, {num: nextNum, events: pending}]`,
     both with old timestamps. The first datagram has `new_num = nextNum`,
     `old_num = A`, `throwaway_num = A`, `ack_num` = the highest state in the
     snapshot, and a diff of the pending input. Retransmits reuse `nextNum`. New
     keystrokes get the next number.
   - With nothing pending: `[{num: A, events: []}]`. The first datagram is an empty
     ack numbered `nextNum` on base `A`.
   - "Last heard" is set to now, so a lost first datagram is retried about every
     second, not after the 3 s ack timer.
6. Open a socket and send at once. The server moves to the new address on the first
   authenticated datagram.
7. The first server state after a resume writes the iOS clipboard only if its hash
   differs from the one in the snapshot.

Checked against mosh 1.4.0 source: the server always still holds `A`; it accepts the
sequence jump and the new source address; a pre-kill partial fragment cannot mix with
a resumed one; late pre-kill datagrams are never applied; after a long silence the
server diffs from its oldest kept state, which the snapshot always contains.

**Fallback** (dirty, unreadable snapshot, missing key, lost base state): mark the
record dead, show "Previous session could not be resumed. Starting a new one.", and
bootstrap again over SSH with the host's remote command. Key login needs no prompt.
In the same SSH connection, kill the old `mosh-server` if the identity check in
section 4 passes. Otherwise nothing is killed.

"Device locked" errors (`errSecInteractionNotAllowed`, `EPERM`) mean try again later,
never dead. If no authenticated datagram arrives after a resume, the app keeps
retrying under the "Last contact" banner and runs the SSH probe from section 4. The
banner also has a "Start new session" button, which marks the record dead and
bootstraps again.

**Stage 2 (M9)** replaces the dirty rule with a write-ahead journal, so a kill in the
foreground is also resumable. Append-only, CRC-framed `journal.<gen>` with records
`INPUT`, `FRONT`, `REMOTE`, `REMOTE_THROWAWAY`, `CHECKPOINT`, `SERVER_SHUTDOWN`:

- An input event (keystroke or Resize) is appended as `INPUT` before any state that
  contains it is sent.
- `FRONT(num, inputCount)` records the acknowledged state and how many `INPUT`
  records it contains. Pending input = the `INPUT` records after that count. (Input
  typed between sending a state and receiving its ack sits before the `FRONT` record
  in the file, so file position alone is wrong.)
- `throwaway_num = t` is sent only after a `FRONT` with `num ≥ t` is appended.
- `ack_num = n` is sent only after `REMOTE(n)` is appended. mosh's 100 ms ack delay
  leaves room for this. A state once sent as `ack_num` is kept until a
  `REMOTE_THROWAWAY` passes it.
- `CHECKPOINT` holds every held remote state and the `FRONT` pair. Compaction writes
  `journal.<gen+1>` starting with a `CHECKPOINT`, then fsync, then rename.
- Restore replays every `REMOTE` record after the `CHECKPOINT` in append order,
  including empty diffs and states below the last `REMOTE_THROWAWAY`, and prunes
  afterwards. (A kept state's base is often below the throwaway.)
- "Appended" means `write()` returned, which survives process death. A device reboot
  while in the foreground is detected with a boot identifier and treated as dead.

The stage 1 snapshot is the stage 2 `CHECKPOINT`, so the record format carries over.

### 4. Bootstrap, keys, session health

**Bootstrap** (`SSHBootstrap`, swift-nio-ssh; NIOTransportServices on iOS, NIOPosix on
Linux):

1. Connect and check the host key against `KnownHosts` (JSON file). First contact
   shows the SHA256 fingerprint and asks. A changed key is refused. The connect
   timeout is 30 s for private and link-local addresses, so the first Local Network
   alert can be answered.
2. Log in with the device key, then with a password if the key is rejected. Passwords
   are asked for each time and never stored.
3. Request a pty at the terminal's size and run
   `<prefix> mosh-server new -c 256 -s -l LANG=<locale> [-p <range>] [-- <remote command>]`.
4. Parse `MOSH CONNECT <port> <key>` and `[mosh-server detached, pid = N]`. The pty
   merges stderr into the same stream and uses CRLF, so the parser strips CR.
5. On a second channel read the server's start time (the identity check command
   below) and keep it with the PID. Close SSH.
6. Write `meta.json`, the Keychain key and the first counter reserve. Only then send
   state 1 (a Resize) to the numeric IP the SSH connection used.

Per-host fields:
- name, host, SSH port, user, key
- server prefix or path, locale (default `en_US.UTF-8`), UDP port range
- remote command: empty by default, with presets `tmux new -A -s main` and
  `tmux new -A -s $(hostname -s)`
- allow clipboard write; swipe sends PgUp/PgDn

**Errors** (`BootstrapError`), each with a suggested fix and a Linux test:

| Signal | Shown to the user |
|---|---|
| No `MOSH CONNECT`, exit 127 or "not found" | `mosh-server` is not on the PATH of a non-login shell. Set the server path (for example `/opt/homebrew/bin/mosh-server`) |
| "needs a UTF-8 native locale" | Locale missing on the host. Try `C.UTF-8` |
| `MOSH CONNECT` seen, no UDP reply in 15 s | UDP is blocked. Set a port range or open the firewall |
| Key rejected | Shows the public key with Copy, offers password login |
| Password rejected | Wrong password |
| Host key changed | Refused. Shows old and new fingerprints |
| No shared host-key algorithm | Host offers only RSA host keys. Not supported |
| The server's method list has neither publickey nor password (swift-nio-ssh drops unknown methods) | This host needs a login method the app does not support (for example 2FA) |
| `WaitingForConnectivity` event, then connect timeout, on a private or link-local address | Local Network access is off or was not answered in time. Settings > Privacy & Security > Local Network, then retry |

**Keys** (`MoshKeys`, `KeychainKeyStore`):
- Ed25519 from CryptoKit. The 32-byte private key is a Keychain generic password,
  `WhenUnlockedThisDeviceOnly`, not synchronised. It never leaves the device.
- `KeysViewController` lists keys and shows the `ssh-ed25519 AAAA… ios-mosh@<device>`
  line, the SHA256 fingerprint, Copy and the share sheet.
- After a password login the app offers "Install my key on this host", which appends
  the line to `~/.ssh/authorized_keys` over the open SSH connection.

**Session health** (`ServerProbe`): after 15 s without an authenticated datagram, or on
request, the app logs in over SSH and runs the identity check.

**Identity check**, used by the probe and before every kill:
`LC_ALL=C ps -p PID -o user= -o lstart= -o comm=` (`comm` last, it can contain
spaces). It passes when the user is the login user, the basename of `comm` is
`mosh-server` (macOS prints the full path) and the start time is within 2 s of the
stored one. A process that fails the check is never killed.

| Result | Meaning | Action |
|---|---|---|
| SSH fails | Host unreachable | Keep waiting under the banner |
| No process passes the check | Session ended or host restarted. This includes the shell exiting while the app was away | Fallback from section 3 |
| Check passes, but SSH reached a different address than the saved IP | The server is bound to the saved IP (`-s`), which this network cannot reach | Say so and keep the session. Hint: use a name that works on every network, such as the Tailscale name |
| Check passes, same address | UDP blocked on this network | Say so and keep the session |

**Session list.** One live session at a time. Opening another host quiesces and
snapshots the current one, which stays resumable. Rows show host, state (live,
resumable, ended, dead) and last contact. Swipe actions: "End session" (kills the
remote server over SSH, after the identity check) and "Forget".

### 5. Input, clipboard, appearance

**Keys.** SwiftTerm already handles the software keyboard and hardware keys with
repeat. Its behaviour is kept, and single keys are overridden only where a test shows
them broken (known: Option-as-Meta drops Shift, SwiftTerm issue 591).

**Key bar** (`KeyBarView`, M7), pinned to `view.keyboardLayoutGuide.topAnchor`:
- Fixed part: Esc, Ctrl (sticky), Tab, four arrows with repeat, Paste (a
  `UIPasteControl` must stay fully visible to paste without a prompt).
- Scrolling part: Alt (sticky), `| / ~ - _`, PgUp, PgDn, Home, End, tmux prefix
  (configurable, default `C-b`), hide keyboard.
- Keys are at least 40 pt wide. Ctrl drives SwiftTerm's `controlModifier` and listens
  for its reset notification.
- A hardware keyboard is detected with `GCKeyboard.coalesced != nil` and the
  `GCKeyboardDidConnect` and `GCKeyboardDidDisconnect` notifications. The bar then
  collapses.
- Until M7 the app uses SwiftTerm's built-in `TerminalAccessory`. M7 sets
  `terminalView.inputAccessoryView = nil` when `KeyBarView` is installed.

**Paste** (`PasteController`): the Paste key is a `UIPasteControl`, and Cmd-V and the
edit menu also work. None of these should show the iOS paste prompt (checked on the
phone in M7). The text goes to SwiftTerm's `pasteText`, which removes ESC bytes and
adds bracketed-paste markers when the remote asked for them.

**Selection and touch.**
- Long-press (0.7 s) opens SwiftTerm's edit menu (Select, Select All, Paste), also
  while tmux or vim mouse mode is on. Selection starts from Select and is extended
  by dragging. Direct long-press-to-select is not in v1.
- Taps and pans become mouse reports only while the remote has mouse mode on.
- With mouse mode off, a vertical swipe sends PgUp or PgDn if the host has that
  option on. This is the app's own one-finger pan recogniser, installed only while
  mouse mode is off.
- Copy covers the visible screen only.

**OSC 52** (`ClipboardPolicy`). mosh-server forwards only `OSC 52 ; c ; <base64>`, and
only when the content changes. It arrives as the framebuffer's clipboard field.
- Write `UIPasteboard.general` when a live state changes the field. Never during a
  resume repaint. Skip if the hash equals the last one written.
- Strict base64 and UTF-8. Invalid or cut-off data (mosh caps it at 16 KiB) is not
  written and shows "Clipboard data from the host was invalid or truncated".
- A query (`?`) is ignored. The app never reads the iOS clipboard for the remote.
- A toast says "Copied N bytes". The per-host switch can turn writing off.
- `docs/SERVER-SETUP.md` section 6 and the in-app Help page give the two tmux lines
  (`set -s set-clipboard on` and
  `set -as terminal-overrides ',xterm*:Ms=\E]52;c;%?%{0}%t%p1%s%;%p2%s\a'`), the
  neovim `init.lua` of SERVER-SETUP.md section 6 (neovim 0.10 or newer: neovim's OSC 52
  copy, a paste that never asks the terminal; copy with `"+y`) and the known limits:
  the same text copied twice arrives once (mosh issue 1090), about 12 KB of text per
  copy (12282 bytes). Proved end to end on 2026-11-15 (docs/CLOUD.md, 14:36 UTC); the
  earlier line `Ms=\E]52;c%p1%s;%p2%s\a` and `vim.g.clipboard = 'osc52'` do not work
  (SERVER-SETUP.md's table and neovim notes).

**Appearance** (`AppearanceSettings`):
- M5: any view size change (keyboard, rotation, font size) recomputes columns and
  rows and sends a Resize, debounced by 100 ms.
- M7: font size by pinch and Cmd-plus/minus (stored), bell as a haptic.
- M8: a bundled monospace font with powerline glyphs (licence checked before
  bundling), two or three themes with 16-colour palettes, cursor style.

### 6. App shell

- UIKit, UIScene lifecycle, iOS 18 minimum, iPhone only, one scene.
- `Info.plist`: `NSLocalNetworkUsageDescription`.
- Settings has an About page with the GPL notice and the source link.

### 7. Build and install pipeline (charlie)

No TestFlight and no GitHub Actions. The tree is edited on yellow, synced to charlie
with rsync, built there and installed on the phone with `devicectl`. None of this has
been run yet (charlie was asleep during planning), so M0 proves it before anything
else. The commands below come from documentation; `docs/BUILD.md` records what M0
finds different. SSH to charlie uses
`-i ~/.ssh/ios-mosh-charlie -o IdentitiesOnly=yes`. Host and user come from
`scripts/mac.env` (gitignored; default `charlie` and yellow's login name).

**charlie, once:**
- Xcode 16 or later, with an iOS SDK (`xcodebuild -showsdks`) not older than the
  phone's iOS major version (`deviceProperties.osVersionNumber` in the device JSON).
  Only Trick can install or update Xcode. The package's Swift tools version and the
  Docker image tag follow charlie's `swift --version`.
- Licence, first launch, simulator runtime (`xcodebuild -downloadPlatform iOS`),
  Homebrew, then `brew install xcodegen mosh fastlane rsync`. macOS 15.4 and later
  ship openrsync as `/usr/bin/rsync`, so the Homebrew one is used. Anything that
  needs `sudo` goes to Trick as literal lines, for example
  `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`.
- Non-interactive SSH shells need `PATH=/opt/homebrew/bin:$PATH` and
  `LC_ALL=en_US.UTF-8` (fastlane). On Apple silicon run `arch -arm64 xcodebuild` if
  a Rosetta shell is detected.
- Trick's user must be logged in at the screen (`stat -f %Su /dev/console`).
  Simulator tests need that GUI session; a locked screen is fine.
- Awake: `pgrep -x caffeinate >/dev/null || nohup caffeinate -is </dev/null >/dev/null 2>&1 &`
  (without the redirects `ssh` does not return). Held from the first evening until
  Build 1 is installed, unless Trick asks for it to be released. When charlie cannot
  be reached, Mac work queues and Trick gets a Slack DM.

**First pairing (M0, phone on the cable):**
- Trick: charlie unlocked at its screen, phone plugged in, "Allow accessory" on
  charlie, Trust and passcode on the phone. A Mac that was locked for days can
  refuse a USB accessory until it is unlocked.
- `xcrun devicectl list devices --json-output /tmp/dev.json`, pick the entry whose
  `hardwareProperties.deviceType` is `iPhone`, then
  `xcrun devicectl manage pair --device <its identifier>`.
- Developer Mode appears in the phone's Settings only after this. DM Trick to switch
  it on (Restart, then Turn On and passcode).
- Pass: `connectionProperties.pairingState` = `paired` and
  `deviceProperties.developerModeStatus` = `enabled`.
- Keep the **hardware UDID** (`hardwareProperties.udid`, cross-checked with
  `xcrun xctrace list devices`) in `~/signing/udid`. It is the value registered with
  Apple and the one the scripts pass to `--device`. The CoreDevice identifier is a
  different value.
- Later: an iOS update needs the cable and a new pairing. Installs over Wi-Fi need
  IPv6 on the LAN.

**Signing: look first** (Trick's choice), then one Slack DM with what is missing:
1. An API key already on charlie (`~/signing`, `~/private_keys`, `~/.private_keys`,
   `~/.appstoreconnect/private_keys`): use it for the route below and say so.
2. An Apple Development identity in the login keychain
   (`security find-identity -v -p codesigning`): usable over SSH only with the login
   keychain unlocked, so ask for either the login password in `~/signing/login.pass`
   or an API key.
3. Neither: ask for an API key. Team key with the Admin role, made under Users and
   Access > Integrations > App Store Connect API > Team Keys; the `.p8` keeps its
   name `AuthKey_<key id>.p8`, and the issuer id goes in `issuer.txt`
   (`mkdir -p ~/signing && chmod 700 ~/signing`).

**Signing with an API key** (development, manual, in a keychain of its own):
- Nothing in `~/signing/` is copied off charlie or printed. The first step builds
  fastlane's `asc.json` from the `.p8` and the issuer id, and writes a random
  keychain password to `kc.pass` (both mode 600).
- Keychain, App ID, certificate, device and profile, in one SSH command:
  ```
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8; S=$HOME/signing
  KC=$HOME/Library/Keychains/ios-mosh.keychain-db; PW=$(cat $S/kc.pass)
  security create-keychain -p "$PW" "$KC" && security set-keychain-settings "$KC"
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  security unlock-keychain -p "$PW" "$KC"
  (cd $S && fastlane appid)
  CERT_KEYCHAIN_PASSWORD="$PW" fastlane run cert development:true api_key_path:$S/asc.json keychain_path:"$KC" output_path:$S
  printf 'Device ID\tDevice Name\tDevice Platform\n%s\tTrick iPhone\tios\n' "$(cat $S/udid)" > $S/devices.txt
  fastlane run register_devices api_key_path:$S/asc.json devices_file:$S/devices.txt
  fastlane run sigh development:true api_key_path:$S/asc.json app_identifier:us.v9n.ios-mosh provisioning_name:ios-mosh-dev force:true output_path:$S filename:ios-mosh-dev.mobileprovision
  ```
- `appid` is a one-lane `~/signing/fastlane/Fastfile` (`fastlane produce` cannot use
  an API key). On 403 Trick registers the App ID in the developer portal.
  ```
  lane :appid do
    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(File.expand_path('~/signing/asc.json'))
    Spaceship::ConnectAPI::BundleId.find('us.v9n.ios-mosh') ||
      Spaceship::ConnectAPI::BundleId.create(name: 'IOSMosh', platform: 'IOS', identifier: 'us.v9n.ios-mosh')
  end
  ```
- Proof, in a new SSH session:
  `security unlock-keychain -p "$PW" "$KC" && cp /usr/bin/true /tmp/t && codesign -f -s "Apple Development" --keychain "$KC" /tmp/t`,
  and `security find-identity -v -p codesigning "$KC"` lists one identity. If
  `codesign` blocks or reports `errSecInternalComponent`, run
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC"`
  once.
- If fastlane fails while importing Apple's WWDR certificate (it targets the default
  keychain, which is the locked login keychain): make the new keychain the default
  for that command (`security default-keychain -d user -s "$KC"`, restored
  afterwards) and add `skip_certificate_verification:true` to `sigh`.
- Signing settings go on the app target in `project.yml`, never on the `xcodebuild`
  command line (there they would also apply to the Swift packages):
  `CODE_SIGN_STYLE: Manual`, `"CODE_SIGN_IDENTITY[sdk=iphoneos*]": Apple Development`,
  `"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": ios-mosh-dev`,
  `OTHER_CODE_SIGN_FLAGS: --keychain $(HOME)/Library/Keychains/ios-mosh.keychain-db`
  (build settings do not expand `~`). The keychain stays in the user search list.
- Config files. `App/Local.xcconfig` is committed and holds only
  `#include? "Version.xcconfig"` and `#include? "Signing.xcconfig"`; the app target
  uses it for Debug and Release. `mac.sh` writes `App/Version.xcconfig` on yellow
  before each sync (commit count, short SHA). The signing step writes
  `App/Signing.xcconfig` on charlie (`DEVELOPMENT_TEAM = <id>`, read with
  `security cms -D -i ~/signing/ios-mosh-dev.mobileprovision 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - -`).
  Both generated files are gitignored, and rsync never touches the second.
- Every build unlocks the keychain in the same SSH command as `xcodebuild`. The
  device build uses a scheme whose build action lists only the app target.
- If the key is refused (403), ask Trick for an Admin Team key. If manual signing
  fails, try automatic signing with `-allowProvisioningUpdates
  -allowProvisioningDeviceRegistration -authenticationKeyPath …` and the same key.

**Scripts** (run on yellow):
- `scripts/mac.sh CMD…` writes `App/Version.xcconfig`, syncs the tree and runs the
  command on charlie with PATH, locale and `caffeinate` set. The About page shows
  the commit count and SHA, so Trick and the logs agree on which build is on the
  phone. The sync:
  `rsync -az --delete --exclude .git --exclude .build --exclude App/Signing.xcconfig --exclude '*.xcodeproj' --rsync-path=/opt/homebrew/bin/rsync -e 'ssh -i ~/.ssh/ios-mosh-charlie -o IdentitiesOnly=yes' ./ charlie:ios-mosh-build/`.
  Derived data lives outside the synced tree (`-derivedDataPath ~/ios-mosh-dd`).
- `scripts/deploy.sh [--wait] [--launch] [--smoke] [--logs]`. Always:
  `xcodegen generate`, unlock the keychain, `xcodebuild` for `generic/platform=iOS`,
  `xcrun devicectl device install app --device $UDID <app path>`.
  - `--wait`: every 20 s run
    `xcrun devicectl list devices --timeout 20 --json-output $TMP` and find the phone
    by `hardwareProperties.udid`. When `pairingState` is `paired`, run
    `xcrun devicectl device info lockState --device $UDID --json-output $TMP2` and
    install when it is unlocked. Retry on any failure. Do not wait for `tunnelState`
    = `connected` (an idle phone does not show it), and do not parse the text table.
  - `--launch`:
    `xcrun devicectl device process launch --device $UDID --terminate-existing us.v9n.ios-mosh`.
  - `--logs`: pull the debug log (see Phone). A live console is
    `perl -e 'alarm shift; exec @ARGV' 120 xcrun devicectl device process launch --console …`,
    because `--console` blocks until the app exits and macOS has no `timeout`.
  - `--smoke`: the phone self-test below.

**Simulator tests:** `xcodebuild build-for-testing`, then `test-without-building` on
a booted simulator (`simctl boot`, `simctl bootstatus -b`), with
`-skipPackagePluginValidation` (SwiftTerm ships a build plugin) and a fresh
`-resultBundlePath`. Screenshots are `XCTAttachment`s with lifetime `.keepAlways`,
exported with `xcresulttool export attachments` and copied to yellow. If tests
started from SSH fail (`testmanagerd` or `launchd_sim` errors), the same script is
started from a LaunchAgent in the GUI session (`launchctl bootstrap gui/<uid>`).
The LaunchAgent only ever runs simulator tests. `devicectl`, rsync and anything
else that talks to the phone or the network stays in the SSH session (launchd
agents do not get the Local Network exception, Apple TN3179).

**Phone:**
- The cable is the reliable route. The same Wi-Fi as charlie usually works once the
  phone is paired; a phone restart can need the cable once more.
- Unlocked for a launch, and to be safe for an install.
- The app keeps a rolling debug log in `Documents/`. It comes back with
  `xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier us.v9n.ios-mosh --source Documents/<file> --destination <dir>`
  (one file at a time), so a problem Trick reports can be read without him sending
  anything.

**Phone self-test** (`deploy.sh --smoke`; Trick only unlocks the phone):
- Target: a throwaway container on yellow from the dev image
  (`scripts/smoke-host.sh up|down`). Bridge network, `sshd` published on a high TCP
  port, a small UDP range published one-to-one for `mosh-server`, one user with a
  random password made for that run. Nothing else on yellow is changed and no key
  is added to Trick's `authorized_keys`.
- The script reads the container's host-key fingerprint, makes a random run id and
  launches the app with environment variables. (Single-dash app arguments after the
  bundle id are parsed as `devicectl` options.)
  `xcrun devicectl device process launch --device $UDID --terminate-existing --environment-variables '{"SMOKE_HOST":"…","SMOKE_PORT":"…","SMOKE_USER":"…","SMOKE_PASSWORD":"…","SMOKE_HOSTKEY":"…","SMOKE_UDP_RANGE":"…","SMOKE_RUN_ID":"…"}' us.v9n.ios-mosh`.
  `SMOKE_HOST` is yellow's Tailscale name. If the variables do not arrive (checked
  in M0), pass arguments after a literal `--`.
- The app (debug builds only, `ProcessInfo.processInfo.environment`) logs in with
  the password, installs a key through the "Install my key on this host" code path,
  logs in again with that key, starts mosh, runs the `hello-42` command and writes
  the run id, result and timings to `Documents/smoke.json`.
- The smoke session is kept apart from Trick's data. It never reads, replaces or
  deletes a stored session record, host, known-hosts entry or key: its record is in
  memory only, and its key is made for the run, stored in the Keychain under a
  separate service name and deleted at the end.
- The script polls every 5 s for up to 180 s with `device copy from` and accepts
  `smoke.json` only when its `runId` matches. It then pulls the debug log and
  removes the container. A failure is fixed and retried before Trick is told a
  build is ready.
- M0 runs a small version from the blank app: a TCP connect to the container's
  `sshd` port and a UDP echo, with the result in `smoke.json`. This proves the
  phone-to-yellow path, launching with environment variables and `copy from`.

**`project.yml` edits from the template:**
- Names `IOSMosh`, bundle id, iOS 18.0 in both deployment settings,
  `UIApplicationSupportsMultipleScenes: false`.
- Remove: the Sentry package and `SentryDSN`, `CODE_SIGN_ENTITLEMENTS` and the
  `.entitlements` exclude, the `PrivacyInfo.xcprivacy` source entry,
  `ITSAppUsesNonExemptEncryption`, `NSPhotoLibraryAddUsageDescription`,
  `NSAppTransportSecurity`, the target-level `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` literals, the post-build git script (the version comes
  from `Version.xcconfig`) and the header comment about CI and TestFlight.
- Add the local package (`..`), SwiftTerm, `configFiles` and the signing settings
  above.
- Rename the unit-test target and add `IOSMoshUITests` (`bundle.ui-testing`), both
  listed in the test scheme.

TestFlight can be added later from the pipeline of <the author's Swift app>
(`.github/workflows/release.yml`, `fastlane/`) if builds are wanted away from
charlie. A development build runs for a year before its profile needs renewing.

## Milestones

Core work runs in the dev container on `yellow` (`scripts/dev.sh swift test`). App work
is built and tested on charlie over SSH (`scripts/mac.sh`). Each milestone ends with its exit
test passing.

| # | Milestone | Runs on | Exit test |
|---|---|---|---|
| M0 | Repo, toolchain, pipeline proof | yellow, charlie, phone | `swift test` green on Linux and on charlie; blank app built and device-signed on charlie, UI test green on its simulator. Install and launch on the phone pass here if the phone is in reach; otherwise they stay queued (`deploy.sh --wait`) and must pass before M5's exit test |
| M1 | Crypto and wire | yellow | Test vectors pass; first server datagram decrypts and decodes |
| M2 | Transport | yellow | `hello-42` found in the received bytes; 10-minute lossy soak without a stall; roaming |
| M3 | Terminal model | yellow | Framebuffers equal mosh's own emulator on the corpus |
| M4 | Bootstrap and keys | yellow | Password and key login against a real `sshd`; every error row reproduced |
| M5 | First session in the app | charlie, phone | `hello-42` UI test green on the simulator; build installed on the phone and the phone self-test green |
| M6 | Resume, stage 1, and server probe | yellow, simulator | Kill tests green; same `mosh-server` PID after the app is killed on the simulator; probe tells server gone, host unreachable and UDP blocked apart |
| M7 | Input and clipboard | simulator, phone | Key bar, paste and OSC 52 tests green on the simulator; `deploy.sh --smoke` passes on the phone; Trick is told Build 1 is ready. **Build 1** |
| M8 | Session list and appearance | simulator, phone | List states, "End session" and "Forget" work; themes and font. **Build 2** |
| M9 | Resume, stage 2 | yellow | Kill at random instants, 500 iterations, no server abort, no lost input |
| M10 | Prediction | yellow, phone | Typed characters appear at once on a 300 ms link |

**Runs.** The milestones are grouped into runs. After the setup at the top of this
file, a run needs from Trick only the phone at home (on the cable or charlie's
Wi-Fi), unlocked, with Tailscale on, when a build is waiting: up to three times in
Run 1 (M0 blank app, M5 first connecting build, Build 1). Anything else that comes
up (a `sudo` line, a signing credential, an Xcode update) goes to him as one literal
line each.

| Run | Milestones | Ends with |
|---|---|---|
| 1 | M0–M7 | The daily driver installed on the phone, and a message to Trick |
| 2 | M8 plus fixes from Trick's use | Build 2 on the phone |
| Later, if wanted | M9, M10, TestFlight | Resume after a kill at any instant; local echo; builds away from charlie |

Order inside Run 1: the Linux part of M0 and then M1–M4 start on approval and need
only yellow. The Mac part of M0 (chores, pairing, signing, blank app on the phone,
the network probe, the simulator UI-test harness) starts as soon as charlie can be
reached and comes before Linux work while charlie's evening lasts. M5–M7 need
charlie again.

Inside a run the milestones are checkpoints for the implementing session, not
hand-offs. Work that needs charlie or the phone is queued while they are out of
reach, and the run continues with what it can do.

**M0 — Repo, toolchain, pipeline proof**
- First step: copy this plan to `docs/PLAN.md` and convert the notes from the
  planning session into `docs/research/*.md`. They are in `/tmp/claude-1000/-home-trick-src-github-com-trickv/07563a56-1fc1-5d4a-b4f8-d95210eedfb5/tasks/`
  and will not survive a reboot: `wy03nl1jh.output` (research), `w6xc1utub.output`
  (first design), `wgqm521n1.output` and `wmui2hjiy.output` (reviews, resume
  soundness), `wels4cgg0.output` (charlie pipeline facts), `wg5fdqdpa.output`
  (review of this revision). The TestFlight and GitHub Actions parts of the first
  two are superseded by section 7.
- Create the private repo, `Package.swift` with `CZlib`, `docker/Dockerfile.dev`,
  `scripts/dev.sh`, `CLAUDE.md`. Check that `tc … netem` works in the container
  (`--cap-add NET_ADMIN`; `sch_netem` is on yellow's disk but not loaded. If it
  fails, ask Trick to run `sudo modprobe sch_netem`).
- charlie: first-run chores, first pairing and signing from section 7,
  `scripts/mac.sh`, `scripts/deploy.sh`, `scripts/smoke-host.sh`.
- App shell: `App/project.yml`, a placeholder screen with a SwiftTerm view that echoes
  typed keys, a generated placeholder icon.
- UI-test harness from day one: the placeholder app has the `IOSMoshUITests` target
  with one test (type `abc`, read the `screenText` element described in M5, one
  `typeKey`, one screenshot exported with `xcresulttool`), run on charlie's simulator.
- SwiftTerm check: the placeholder builds on charlie for the simulator and the device
  SDK, and a target importing SwiftTerm builds with `swift build` in the Linux
  container.
- Pipeline proof: install the placeholder on the phone, launch it and run the small
  self-test from section 7 (TCP connect and UDP echo to the smoke container). If the
  phone is out of reach, leave `deploy.sh --wait` running and carry on; this must
  pass before M5's exit test.

**M1 — Crypto and wire.** `MoshCrypto`, `MoshWire`. RFC 7253 appendix A vectors and
the vectors in mosh's `src/tests/ocb-aes.cc`. `moshcli handshake` against a local
`mosh-server` decrypts the first datagram and decodes a `HostMessage`.

**M2 — Transport.** `MoshTransport` with `InMemoryGate`, and the `moshcli` script
commands. Unit tests on a fake clock for timers and RTT. `moshcli connect` sends
`echo hello-$((6*7))` and finds the bytes `hello-42` in the received `HostBytes`
(states are opaque byte strings until M3). Ten minutes under netem (20% loss,
200 ± 50 ms, reordering) with no stall over 30 s and the last typed marker found.
Rebinding the socket mid-session keeps the session.

**M3 — Terminal model.** `MoshTerminal`, `Tools/mosh-oracle`, the golden corpus
(`scripts/record-golden.sh`: shell, vim, tmux, htop, long wrapped lines, emoji, CJK,
combining marks, 256 and true colour, resizes).
- The Swift framebuffer equals the oracle's after every recorded diff.
- Property test for `DisplayDiff`.
- `SurfaceFeedTests` (Linux): the `SurfaceFeed` output fed into SwiftTerm's headless
  `Terminal` gives the same text grid.
- The M2 soak is run again; the final client framebuffer equals `tmux capture-pane`.
- Shell, vim and tmux cases must pass before M5. The rest of the corpus is a running
  suite.

**M4 — Bootstrap and keys.** `MoshBootstrap`, `MoshKeys`. Tests use the `sshd` in the
container: password login, key login, the generated `authorized_keys` line accepted by
OpenSSH, fingerprint equal to `ssh-keygen -lf`, changed host key refused, every row of
the error table, PID parsed, remote command attaches to tmux.

**M5 — First session on the phone.** `MoshSession`, `SwiftTermSurface`,
`NWDatagramTransport`, `SessionListViewController` as a plain host list (add, edit,
connect), host editor, keys screen with "Install my key on this host", terminal
screen, Resize on view size change, socket replacement on foreground and path
change, the rolling debug log in `Documents/` and the phone self-test hooks from
section 7 (debug builds). A cold start still means a new session.
- UI tests run in `IOSMoshUITests` with `xcodebuild build-for-testing` and then
  `test-without-building`. They run outside the app process, so:
  - **Reading the screen.** Debug builds started with `-uiTesting 1` copy the visible
    rows into the `accessibilityValue` of a hidden element `screenText` on every
    display tick. Tests assert on it with a polling expectation, never a single read.
  - **Servers.** `scripts/mosh-spawner.py` runs on charlie at 127.0.0.1 during the
    test step. `/new` starts `mosh-server new -i 127.0.0.1` and returns port, key and
    PID. `/alive?pid=` says whether it still runs. Each test asks for a server just
    before launch, because `mosh-server` exits after 60 s without a client.
  - **Debug launch arguments.** `-debugMoshPort` and `-debugMoshKey` start a session
    (skipping SSH) only when no record exists; a launch without them resumes the
    stored record. `-debugFallbackPort` and `-debugFallbackKey` replace the SSH
    bootstrap in the fallback. `-debugCrashAfter N` calls `kill(getpid(), SIGKILL)`
    N seconds after the session is up (the same code as "Crash now").
- First UI test: type the `hello-42` command and expect `hello-42` in `screenText`.
- App-hosted unit tests: `KeychainKeyStoreTests` (generate, store, load in a new
  store instance, delete), and the Keys screen's Copy action puts a line starting
  `ssh-ed25519 AAAA` on the pasteboard.
- Screenshots are saved as test attachments and exported with `xcresulttool` and
  copied to yellow, so the UI can be reviewed without a device.
- Phone: the self-test from section 7 passes (SSH bootstrap with the device key,
  mosh, `hello-42`). tmux, vim and roaming are Trick's checks on Build 1.

**M6 — Resume, stage 1, and server probe.** `MoshResume`, the file-backed
`DurabilityGate`, `SceneDelegate` wiring, fallback with automatic re-bootstrap,
`ServerProbe`, "Start new session" under the banner, and a debug-only "Crash now"
row in Settings (`kill(getpid(), SIGKILL)`). Tests are listed under Verification.

**M7 — Input and clipboard.** `KeyBarView`, `PasteController`, `ClipboardPolicy` and
`ClipboardWriter`, selection, swipe paging, font size, bell haptic, help page, About
page. Ends with `deploy.sh --smoke` on the phone, the short checklist for Trick (the
phone table under Verification) and the "Build 1 is ready" DM.

**M8 — Session list and appearance.** Session list states, "End session", "Forget",
bundled font, themes, cursor style.

**M9 — Resume, stage 2.** `Journal`, compaction, restore from journal, boot
identifier check on a device.

**M10 — Prediction.** Port of mosh's `terminaloverlay.cc` (about 930 lines). The
overlay is applied to a copy of the newest framebuffer before `DisplayDiff`. Design and
progress log: `docs/notes/m10/DESIGN.md`. `PredictionEngine` (a value type in
`MoshTerminal`, no clock) is a line-by-line port of mosh's `PredictionEngine` with its
three overlay classes, all 25 quirks of the spec kept; time comes in as a number.
`MoshSession` feeds it as stmclient does (the last sent state number on each read, the
acked number, send interval and echo ack on each reading, a reset on resize) and sends the
overlaid frame as `.display`; `.screen`, `screen()`, the snapshot and the clipboard stay
server truth. `ResumeCoordinator.Options.prediction` and `setPrediction` carry the setting
(not stored in the record). The package default is display `never`; the app's default is
mosh's `adaptive`. Not ported: mosh's notification bar and title prefix (deviation D1).
`moshcli --predict MODE --predict-overwrite --delay-ms MS` and the `expect-display`,
`expect-predicted`, `expect-display-settled`, `expect-underlined`, `dump-display` script
commands test it against the real server.

## Execution notes for Run 1

State on yellow at 2026-11-12 03:10 UTC:
- `main` = `6e9aa90`, pushed. Worktrees `.worktrees/{core,term,oracle,boot}` on
  branches `wt/{core,term,oracle,boot}`, all at `6e9aa90`.
- `.build` is a Docker volume per checkout (`ios-mosh-build-<dirname>`), not visible
  on the host. Dependency sources for reading: `.refs/{mosh,SwiftTerm,swift-nio-ssh}`.
  In the container the built mosh tree is `/opt/mosh-src` (static libs in `src/*/*.a`).
- `Package.swift` has a `MoshTestSupport` target (`Tests/MoshTestSupport`, one helper
  per file) that every test target depends on. `Sources/moshcli/main.swift` is a
  subcommand table; a subcommand is one new file plus one line in the table.
- Image has `python3 htop script protoc tmux vim tcpdump tc nc`; no `iptables` (use
  `tc netem loss 100%` to block UDP). Locales: `C.utf8`, `en_US.utf8`.

**Wave 1** (one Workflow, 9 agents, three chains that do not wait on each other):

| Agent | Worktree | After | Work | Exit test |
|---|---|---|---|---|
| `core-1` | core | – | `MoshCrypto`, `MoshWire`, `moshcli handshake`, mosh-server spawner in `MoshTestSupport` | RFC 7253 and mosh `ocb-aes.cc` vectors; protobuf bytes equal `protoc`; first server datagram decrypts and decodes |
| `core-2a` | core | core-1 | `MoshTransport`: pure state machine with injected time, `DurabilityGate` + `InMemoryGate`, quiesce / rationalise / export / import seams, `POSIXDatagramTransport`, `MoshConnection` actor | Fake-clock tests for timers, RTT, acks, fragments, N1–N4 guards |
| `core-2b` | core | core-2a | `moshcli connect` with `--script`, `--record`, `--seq-log`; `scripts/netem.sh`; `rebind`; in-memory export and import against the real server | `hello-42`; 10-minute netem soak with no stall over 30 s; rebind keeps the session; resume in a new object keeps the same server PID; no sequence number twice |
| `term-model` | term | – | `MoshTerminal`: port of mosh `Terminal::Complete` (parser, dispatcher, functions, framebuffer and draw state with every hidden field), `WCWidthTable` from glibc | Unit tests |
| `term-diff` | term | term-model | `DisplayDiff` (port of `Display::new_frame`), versioned serialization | Property test; round trip |
| `term-oracle` | oracle | – | `Tools/mosh-oracle` (C++ on mosh's own libraries), `FORMAT.md`, `scripts/record-golden.sh`, corpus | Corpus under 10 MB; oracle reproduces its own expected output |
| `term-integrate` | term | term-diff, term-oracle | Merge `wt/oracle`; corpus test Swift against oracle; fix the port | Zero mismatches; `newFrame` bytes equal the recorded diffs; reload between diffs still equal |
| `term-surface` | term | term-integrate | `SurfaceFeed`, `SurfaceFeedTests` on SwiftTerm's headless `Terminal` | Text grid, cursor and attributes equal on the corpus, also when states are skipped |
| `boot` | boot | – | `MoshKeys`, then `MoshBootstrap`, `scripts/itest.sh` | Password and key login against real `sshd`; fingerprint equals `ssh-keygen -lf`; every Linux-testable row of the error table |

Fixed across agents:
- Corpus and `--record` format. `instructions.jsonl`, one line per instruction in
  arrival order: `{"old_num", "new_num", "diff_b64" (the raw serialized
  `HostMessage`), "ops": [{"hostbytes_b64"} | {"resize":[w,h]} | {"echo_ack":n}]}`.
  `meta.json` has the format version and the first size. Each `new_num` appears once.
  The oracle's expected output is one framebuffer per instruction (row deltas, format
  in `Tools/mosh-oracle/FORMAT.md`), produced by simulating a mosh client: apply the
  diff to its copy of state `old_num` with `Complete::apply_string`.
- The corpus generator feeds real pty output to a server-side `Complete`, cuts states
  at read boundaries and sometimes diffs from an older base, as a server does when
  acks are late.
- `MoshTransport` and `MoshTerminal` do not import each other. The transport holds a
  generic remote state; the adapter that decodes `HostMessage` and drives the
  terminal lives in `MoshSession` (wave 2).
- Cell contents are compared as UTF-8 bytes, never with Swift `String ==`.
- Agent rules: work only in the given worktree, commit only on its branch, never
  push, no `git stash`, `swift … -j 4`, `runuser -u ubuntu --` in root containers,
  no new dependencies, smallest possible `Package.swift` edit (reported), no image
  rebuild. Each returns a structured result: exit tests with pass or fail, known
  gaps, deviations. An agent that follows another first re-runs the earlier exit
  tests and finishes them if they fail.

**Wave 2** (after I merge the four branches into `main`, run the whole suite, push):
`MoshSession` adapter and facade with `ClipboardPolicy`; `moshcli` with the real
terminal model and `moshcli bootstrap`; netem soak ending with the framebuffer equal
to `tmux capture-pane`; "no UDP reply in 15 s" error row; independent hostile reviews
of the transport against the mosh source, then fixes; M6 Linux core (`MoshResume`,
file-backed `DurabilityGate`, `scripts/killloop.sh` and the stage 1 table).

**Mac work** has priority from the moment `ssh -i ~/.ssh/ios-mosh-charlie charlie true`
works: `caffeinate`, chores, pairing, signing look-first, blank app on the phone,
`swift test` on charlie. A background watcher polls for the key every 60 s.

## Verification

Everything above the phone table runs without Trick. Commands are wrapped by
`scripts/dev.sh` (container on yellow) or `scripts/mac.sh` (charlie).

**Core, before every commit** (container on yellow). `swift test` and the macOS part
of `itest.sh` also run on charlie whenever it is awake, and always before a deploy:
- `swift test`: OCB3 and mosh cipher vectors, protobuf and fragment round trips, timer
  and RTT tests on a fake clock, oracle corpus, `DisplayDiff` property test, key
  format and fingerprint tests, clipboard policy tests.
- `scripts/itest.sh`: `moshcli` against the real `mosh-server` and `sshd` (handshake,
  `hello-42`, bootstrap by password and by key, the error table, the identity
  check). Linux runs all of it; macOS runs handshake, `hello-42` and the identity
  check against its own `ps`.
- From M6, resume unit tests on a fake clock:
  - deliver an ack, snapshot with no timer tick in between, resume: the pending
    input equals what the server has not seen
  - an ack for an unknown state number changes nothing
  - corpus run with the framebuffer saved and reloaded between every pair of diffs
    still equals the oracle

**Network** (yellow, on demand): `scripts/netem.sh` 10-minute soak with loss, delay
and reordering; socket rebind; server address change.

**Resume, stage 1** (`scripts/killloop.sh`, yellow). The loop runs inside tmux with `status off`. A shell inside tmux keeps its PID
through a fallback, so the pass condition is the `mosh-server` PID, not only `$$`.

| Test | Pass condition |
|---|---|
| Quiesce, `SIGKILL`, resume, 200 times | `moshcli resume` exits 0 and reports a resume; the `mosh-server` PID from `meta.json` is alive and unchanged; shell `$$` unchanged |
| Variants: resume within 1 s; after more than 40 s; under 20% loss; with unacknowledged input; after a paste larger than one datagram | Same |
| Exactly-once input: tmux window 0 runs `cat > log`; line N is typed before each kill and line N+1 after each resume. Every fifth kill uses `quiesce --after-send` (send the pending state, read nothing, snapshot) | After the loop type `END`, `wait-ack`; `log` equals the typed lines byte for byte |
| Liveness | The line typed after each resume is echoed on the client screen within 5 s. Also with the first datagram after the resume dropped |
| Quiesce, return to the foreground at once, type, `SIGKILL` | Next start takes the fallback, never a resume from the stale snapshot |
| Screen equality: every tenth iteration window 1 prints `seq 1 200` before the kill | After 500 ms without a new state, client rows with trailing spaces trimmed equal `tmux capture-pane -p` |
| Nonce: `moshcli --seq-log` plus `tcpdump` of the whole run | No client-to-server sequence number appears twice; each process generation starts above the last number of the one before |
| `SIGKILL` while dirty (mid-typing) | Next start takes the fallback, sends nothing under the old key, and the old `mosh-server` did not abort |
| Crash points: kill at each write, fsync and rename of quiesce and cold start | Each outcome is a correct resume or a clean fallback |
| Damaged record | One torn counters slot: the other slot is used, and the result is a resume or a fallback as its dirty flag says. Both slots bad, missing key or missing snapshot: fallback, no datagram sent |
| Guard tests with a deliberately broken client (shorter input list; a held `old_num` with `throwaway_num` above every server state) | The server exits, as documented. The same run with guards on does not |

**Local echo (M10)** (yellow). In `swift test`: `PredictionCrossCheckTests` runs a seeded
generator's steps through mosh's own `terminaloverlay.o` (`mosh-oracle predict`, its clock
set by the commands) and through the port and compares the engine's whole state and the
shown frame after every step (100 cases of 300 commands in the suite; 2000 once by hand
before the wiring, with coverage counters for the rare branches); `PredictionQuirkCrossCheckTests`
has one named case per quirk; `PredictionEngineTests`, `PredictionOverlayTests` the
thresholds and branches; `PredictionWiringTests` the session against a real `mosh-server`.
`scripts/itest.sh predict`:

| Part | Server | moshcli | Pass condition |
|---|---|---|---|
| a | `sh` | `--predict always --delay-ms 150` (300 ms round trip) | After one echoed and acknowledged key, `echo hi` typed key by key is on the shown frame within 120 ms and not yet on the remote screen; after the line ran, nothing is left drawn |
| b | `sh` | `--predict adaptive --delay-ms 150` | A guess is shown and underlined within 120 ms (send interval above 80 ms), and gone once echoed |
| c | a program that echoes one byte | `--predict always --delay-ms 150` | `abc` after the echoed byte is shown, then dropped once judged; neither the display at the end nor the remote screen holds it |
| d | `sh` | `--predict never --delay-ms 150` | The shown frame equals the remote screen; no `.display` event |
| e | `sh` | `--predict adaptive`, loopback | After the trigger's way down, a typed key is never shown predicted |
| f | `sh` | `--predict always --delay-ms 500` | Socket replaced and session quiesced with datagrams in the delay queue: the session goes on, no sequence number twice |

**App, on charlie's simulator** (`scripts/mac.sh`):
- `hello-42` through the real app against a `mosh-server` from the spawner.
- Resume: connect, print `$$`, press Home, poll until `app.state` is
  `.runningBackground` or `.runningBackgroundSuspended` (5 s limit), `terminate()`,
  relaunch without connect arguments, print `$$`. The values are equal and `/alive`
  reports the same server PID. (Done 2026-11-14: `ResumeUITests`, which waits for the app's
  "background-clean" report instead of the app state alone.)
- Fallback: launch with `-debugCrashAfter 5` and the fallback arguments, wait for the
  crash, relaunch. The banner shows, `$$` differs and typing works. (Done 2026-11-14 with
  the "Crash Now" button; also a server killed while the app was away: probe, fallback over
  SSH.)
- From M7: key bar keys and `typeKey` hardware keys arrive as the right bytes in
  `cat -v`; sticky Ctrl; Cmd-V with bracketed paste. The OSC 52 test prints a
  sequence on the host, expects the "Copied N bytes" toast, then pastes into `cat -v`,
  so the pasteboard content is checked and was written by the app itself.
  (Done 2026-11-14 for the key bar, paste and OSC 52: `KeyBarUITests`, `PasteUITests`,
  `ClipboardUITests` in `App/IOSMoshUITests/InputUITests.swift`. Key bar keys in `cat -v` in
  both cursor-key modes, sticky Ctrl and Alt, Ctrl-C, arrow-up history, Tab completion,
  collapse with a hardware keyboard; the Paste key bracketed and plain, Cmd-V bracketed; OSC
  52 toast then pasted back, and the invalid-data message. Not yet: `typeKey` hardware keys
  other than Cmd-V and Cmd-minus.)
  (Done 2026-11-14 for the rest of M7 on the simulator: `SettingsUITests` (Settings font size
  and tmux prefix stored and used by the next terminal; pinch and Cmd-minus change the
  columns and rows `stty size` reports on the host; Help and About pages),
  `SwipePagingUITests` (swipe down PgUp, swipe up PgDn in `cat -v`), `SelectionUITests`
  (long-press, Select All, Copy, pasted back on the host, also with mouse mode on),
  `BellUITests` (one ring per bell, counted in UI-test launches); unit tests
  `SettingsTests`. The haptic itself is a phone check.)
- M8 (done 2026-11-15 on the simulator, except the font): session list states,
  `SessionListUITests` (a saved session listed as resumable and resumed by a tap: same `$$`,
  same server; "End Session" stops the server after the identity check, its pid leaves
  `/sshd/servers`, the record is gone; "End Session" with the host unreachable keeps the
  session; "Forget" removes it and the server keeps running), unit tests `SessionListTests`;
  themes and cursor style, `AppearanceUITests` (theme colours in a screenshot, cursor style as
  the view reports it) and `SettingsTests`. Not on the simulator: the dead, ended, unreadable
  and waiting states (no way to produce them without a change to the resume core or the
  lifecycle; `docs/MAC.md` log, 2026-11-15). The bundled font (2026-11-19, Trick's choice):
  Hack Nerd Font Mono from Nerd Fonts v3.5.1, four faces in `App/Fonts` with their licences
  (`App/Fonts/README.md`), shown on the About page; `TerminalFontTests` (faces load from the
  bundle, fixed pitch, powerline U+E0B0-E0B3) and
  `AppearanceUITests.testTheTerminalDrawsWithTheBundledFont`.
- M10 local echo (done 2026-11-19 on the simulator): `LocalEchoUITests` against a server
  behind the spawner's delaying UDP relay (`/new?delay_ms=400`, 400 ms each way): in mosh's
  default mode (Adaptive) typed text is drawn while the server's screen does not have it yet,
  read from one sample of the `localEcho` element (drawn and server rows of the same display
  tick), then the server's text with no guess left; a wrong guess ("first-then-upper"
  program: `y` guessed, `Y` echoed) is replaced by the server's `Y`; in Never mode every
  sample's drawn rows are the server's; a 300-byte paste reaches `coordinator.type` as one
  input (Paste key and Cmd-V); the host editor's setting (Adaptive by default, Adaptive,
  Always, Never offered) is stored per host and the session of that host reports it. With
  Never forced, the first two fail (negative control). Unit tests `LocalEchoTests`.
- Several sessions at once (done 2026-11-23 on the simulator; `docs/notes/multi-session/`,
  `docs/RESUME.md` "The app"): `SwitchUITests` (back parks and the session row resumes the same
  `$$` and server; ten switches between two hosts; two sessions on one host through the "+" a
  host with a session shows (`testTwoSessionsOnOneHost`); a back swipe let go
  parks nothing; a switch sends no Resize with a software keyboard up; a row tapped twice opens
  one terminal; a silent server at a switch; a host with two UDP ports takes two sessions and the
  third tap says the range is full), `LaunchUITests` (a kill off screen resumes the session
  looked at last and no other record; a kill with the list on screen goes into the dotted
  session; a crash on screen falls back and the parked one stays resumable; after the dotted
  session ends the launch shows the list; "End Session" clears the dot before the shutdown; a
  fallback he went back from does not come back), `EndSessionUITests` ("End Session" on a parked
  row ends the server through mosh's shutdown, also without a pid, the shape of `hg`; with the
  server gone the session is kept and Forget removes it; an interrupted end starts nothing at the
  next launch), `SessionListUITests` (rows under their host, the preview, the dot,
  the session's age, swipes during refreshes, "End Session" from "…", Cancel, `exit` returns to
  the list). Unit tests `SessionQueueTests`, `SessionActivityTests`,
  `LeaveActionTests`, `SessionEndPlanTests`, `SessionPreviewTests`, `PortRangeFullTests`,
  `SessionListTests` (rows oldest first, the state lines), `SessionLinksFileTests` ("last looked
  at" and the links file), `SessionLauncherTests` (also the launch target). Package: step 0's
  `testAResumedSessionEndsByMoshShutdown`, `testAResumedSessionWithoutItsServerIsNotAcknowledged`
  (`Tests/MoshResumeTests`, real `mosh-server`). Every new test's negative control is in the
  `docs/MAC.md` log. The cost of an unpark, on the simulator only (none of it measured on the
  phone; `docs/RESUME.md` "Several sessions"): the cold start 1.0 to 5.3 ms (median 1.5 ms, step
  10); from a resumed screen's making to its first screen 71 to 573 ms (median 93 ms, step 10),
  573 to 823 ms with the push animated as on the phone (steps 9 and 10).
- Screenshots copied to yellow for review.
- Not testable on the simulator: Local Network privacy, the paste prompt, Keychain
  behaviour while locked. These are phone checks.

**On the phone** (Trick, <the phone's tailnet name> to yellow over Tailscale). Trick does the M5–M7
rows while using Build 1 and the M8 row with Build 2. They reach him as a short
checklist with the "ready" DM and gate nothing. Before that, the phone self-test
from section 7 has covered bootstrap, mosh and `hello-42` on the device.

| From | Check |
|---|---|
| M5 | Connect with the device key; tmux and vim usable; Wi-Fi to cellular keeps the session; the Local Network prompt appears only for LAN addresses; deny it once and confirm the error text |
| M6 | Same `$$` and no "could not be resumed" banner after 10 minutes in the background; after force-quit; after a new build is installed over the old one; after a phone reboot with the app in the background. "Crash now" (Settings, debug builds) in the foreground shows the banner and lands in the same tmux. `kill -9` the `mosh-server` on the host: within about 20 s the app says the session is gone and starts a new one. **2026-11-21 (builds 182/183, `docs/MAC.md` log 02:45 UTC):** shown: resumed, same screen, no banner after force-quit, after an install over it and after a reboot; save while locked ok; a kill on screen falls back with the banner and a new session in 1.67 s. Found: on Trick's host the app logs `pid ?`, so the fallback left the old server running. Open: 10 minutes in the background, "Crash now", `kill -9` noticed |
| M7 | Key bar feel; tmux copy-mode and neovim `"+y` reach the iOS clipboard; the Paste key, Cmd-V and edit-menu Paste each paste without the iOS prompt; text selection while tmux mouse mode is on |
| M8 | Session list states; "End session" kills the remote server; themes and font look right. **2026-11-21:** not run (no session stored before the install); open, and "End session" cannot kill the server on Trick's host until the app learns its pid there (`pid ?`); themes and font are in Trick's own checks by hand |
| Several sessions (2026-11-23) | Two hosts and two sessions on one host open at once; "‹ Hosts" and a tap on the row bring back the same shell and screen; the row's preview (with tmux `set -g set-titles on`, `docs/SERVER-SETUP.md` section 5) and its "started … · last used …"; the dot moves to the session looked at last, and opening the app goes into it (after a force-quit, an install, a restart); a kill on screen falls back for that session only, the parked ones stay; Ctrl-D returns to the list; "End Session" from "…" and from a parked row, on `hg` too (no pid: mosh's shutdown), its server gone from `pgrep` afterwards (on `hg`, from a parked row, a shutdown that is not acknowledged removes the row without a message while the server may still run; from "…" it leaves the row "Ended, server not yet stopped", which "End Session" on that row or the next launch removes, also without asking the host: `pgrep` tells; `docs/RESUME.md` "End Session" on a row); Forget. The cost of an unpark on the phone (the log line `cold start: <id>: resumed in N ms`). Not run yet: the build is made and waits for his word to install |
| M10 | With `scripts/netem.sh` delay on yellow (about 300 ms round trip) and the phone over Tailscale: typed characters appear at once, underlined while unconfirmed in Adaptive; nothing wrong is left on the screen after the echo. **2026-11-21 (build 183):** shown with 300 ms delay on the smoke container and the phone over Tailscale: Adaptive gives instant letters with a fading underline and no artifacts, vim clean; Never lags. Open: Always, `read -s` |

## Risks

| Risk | Handling |
|---|---|
| Swift applier differs from mosh's emulator | Oracle corpus from M3. Fallback to the Blink xcframework if it cannot be closed |
| A resume bug aborts `mosh-server` | Guards in one place (`DurabilityGate`), guard tests, kill loop before any build with resume goes on the phone |
| SwiftTerm draws wide characters differently | Explicit cursor position after wide cells; emoji and CJK in the corpus and screenshots |
| Xcode's Swift differs from the Linux image | `swift test` runs on both; the image tag is pinned to match charlie's `swift --version` |
| charlie asleep or the phone out of reach | Core work continues on yellow; app work and installs wait and are retried. Trick is told what is waiting |
| swift-nio-ssh lacks RSA and keyboard-interactive | Out of scope, with clear errors. yellow offers a host key type swift-nio-ssh supports (checked) |
| Password login on yellow's `sshd` may be off (not readable from this session) | Tests and the phone self-test use the container's `sshd`. Trick adds the app's key to yellow himself (Copy on the Keys screen) |
| Signing or device trouble | Found in M0 by the blank-app install, not at the end |
| The API key cannot create certificates or profiles | Ask Trick for an Admin Team key; automatic signing as the second try |
| Simulator tests do not work from an SSH session | Start them from a LaunchAgent in charlie's GUI session (simulator tests only) |
| Environment variables do not reach the app through `devicectl` | Checked in M0 with the blank app; arguments after a literal `--` as the second try |
| charlie's Xcode is older than the phone's iOS | Trick updates Xcode; Linux work continues meanwhile |

## Appendix: protocol reference (mosh 1.4.0, from source)

To be confirmed against the live server in M1 and M2; the source is the authority
(`github.com/mobile-shell/mosh`, tag `mosh-1.4.0`, also used for `Tools/mosh-oracle`).

**Datagram.** 8-byte big-endian nonce `(direction << 63) | seq` (client to server = 0),
then AES-128-OCB3 ciphertext, then a 16-byte tag. OCB nonce = 4 zero bytes + those 8
bytes. No associated data. Drop anything shorter than 24 bytes.

**Plaintext.** `u16 timestamp`, `u16 timestamp_reply` (0xFFFF = none), then one
fragment: `u64 instruction id`, `u16 (final << 15) | fragment number`, payload.
Reassembled payload = zlib `compress()` of a protobuf `TransportBuffers.Instruction`:
`protocol_version = 2` (field 1), `old_num` (2), `new_num` (3), `ack_num` (4),
`throwaway_num` (5), `diff` (6), `chaff` (7, 0–16 random bytes).

**Diff contents.** Client to server: `ClientBuffers.UserMessage` with repeated
instructions; `Keystroke.keys` (field 4, extension 2) and `ResizeMessage` width (5)
and height (6) (extension 3). Server to client: `HostBuffers.HostMessage`;
`HostBytes.hoststring` (4, extension 2), `ResizeMessage` (extension 3),
`EchoAck.echo_ack_num` (8, extension 7). Expected bytes: keystroke "a" =
`0A 05 12 03 22 01 61`; resize 80×24 = `0A 06 1A 04 28 50 30 18`.

**Constants.**

| Item | Value |
|---|---|
| Datagram budget | 1252 bytes on IPv4, 1216 on IPv6 (IP MTU 1280). Fragment payload = budget − 38 (12 header, 16 tag, 10 fragment header) |
| Retransmit timeout | 50–1000 ms; SRTT starts at 1000, RTTVAR at 500; samples of 5000 ms or more ignored |
| Send interval | `ceil(SRTT / 2)`, clamped to 20–250 ms |
| Ack delay, ack interval | 100 ms, 3000 ms |
| Port hop | Every 10 s without a reply |
| Server association timeout | 40 s |
| Sender keeps | At most 32 sent states |
| Receiver keeps | Above 1024 held states one more is accepted, then new ones are dropped for 15 s |
| Server shutdown | Gives up after 16 sends or 10 s without the client's ack (`ack_num` = 2^64 − 1) |
| Server gives up waiting for a first client | 60 s |
| Client "timed out waiting for server" | 15 s |
| Shutdown | `new_num` = 2^64 − 1 |

**Bootstrap.** `mosh-server new -c 256 -s -l LANG=en_US.UTF-8 [-p P[:P2]] [-- cmd]`
over SSH with a pty. Match `^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\s*$`, tolerate
`\r`. The key is 22 base64 characters for 16 bytes. The first client state is a Resize.

**What the server's diffs contain** (`Display::new_frame` with no terminfo). Each
item is handled by the applier and appears in the corpus:
- BEL; OSC 52 `c`; reverse video `?5`.
- Titles: OSC 0 when icon name and window title are equal, otherwise OSC 1 and
  OSC 2.
- Cursor moves (CUP, CR, LF, BS); scroll region plus LF for scrolling.
- ECH and EL, sent under the current pen, so erased cells take its background
  colour.
- SGR: each change is written as a full `ESC[0;…m` (bold, italic, underline, blink,
  inverse, invisible, 16, 256 and true colour). A diff starts from the base state's
  pen, not from a reset.
- Modes `?25`, `?2004`, `?1004`; mouse `?9` and `?1000–1003` (off is sent as
  `?1003l ?1002l ?1001l ?1000l`); mouse encodings `?1005/1006/1015`.
- A size change produces a full redraw. Wrapped lines rely on the receiver's
  autowrap.

**OSC 52 limits on the server.** Only the literal `52;c;` prefix; 16 KiB cap; sent
only when the content differs from the previous state; no read support. tmux's
default `52;;` form is dropped, which is why the `Ms` override is needed.
