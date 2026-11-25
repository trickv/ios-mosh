# ios-mosh

iPhone terminal app that speaks mosh only, so a session survives iOS suspending or
killing the app. Two parts:

- `MoshKit` (this Swift package): the mosh client core. Built and tested on Linux in
  a dev container on `yellow` against the real `mosh-server` 1.4.0 and `sshd`.
- `App/`: UIKit app (SwiftTerm draws the screen). Built on the Mac `charlie` over
  SSH. Debug is the Dev app "iOS-mosh Dev" (`us.v9n.ios-mosh.dev`), installed on the
  phone with `devicectl`; Release is the TestFlight app "iOS-mosh" (`us.v9n.ios-mosh`).
  Two separate apps side by side (`docs/BUILD.md`, "Two apps"). No GitHub Actions.

`docs/PLAN.md` is the approved plan: owner summary on top, implementation reference
below (design sections 1–7, milestones M0–M10, verification tables, protocol
appendix). Read the relevant section before changing a module. Planning research is
in `docs/research/`.

## Project Status

Standing rules from Trick (2026-11-12):
- **THIS REPOSITORY IS PUBLIC** (github.com/trickv/ios-mosh, since 2026-11-24, on Trick's word: "hit
  it, finish the work"). Everything committed on `main` and pushed is published at once, the
  agents' log entries included. Its history starts at one root commit: the commits before it,
  with the unredacted docs, live only in the private repository `trickv/ios-mosh-private` (local
  branch `private-main`, remote `private`, and the old release tags there). NEVER push
  `private-main`, an old tag, or anything that descends from the old history to `origin`: a
  pre-push hook in this checkout refuses it; keep it. Keep to the redaction rules of
  `docs/notes/publication/redaction.md` in every tracked file and commit message.
- **State 2026-11-24:** several sessions at once is built; **TestFlight has 0.2.1 (237)**,
  uploaded 2026-11-24 08:05 UTC from `1ea56fc` (tags `v0.2.1-237`, `v0.2-229`): the GPL text, the
  App Store permission (`COPYING.iOS`: mosh's statement and his own GPLv3 section 7 permission)
  and the third-party licences and notices under About, a Privacy page and the privacy manifest,
  bars readable in light mode. The next upload needs his word again (changelog section, bumped
  version in `App/Local.xcconfig`). The App Store listing is filled and NOT submitted (lane
  `listing`; his to do in the web interface: App Privacy, age rating, content rights, price and
  availability, the version string, a build, Submit).
  **Publication (his plan: open source with a blog post):** the docs are redacted in the tree
  (`0c9614c`, `docs/notes/publication/redaction.md`); the old history is NOT redacted, so the
  public repository is made from the tree as a fresh history, after a final audit of exactly
  that tree, and only on his word. From now on write no address, tailnet name, port, host
  security detail, exact OS release of his hosts, or name of his other repositories into any
  tracked file: use the placeholders of `redaction.md`. Real host values live in untracked
  env files (`scripts/mac.env`, `scripts/smoke.env`).
  The Dev app on his phone has build 220. Open with him: design question 10.2; a notice when
  `hg` does not confirm an End Session; the theme "System" stays dark in light mode.
- **TestFlight, standing instructions** (Trick, 2026-11-22 01:50 UTC, his words): "when you push
  builds to TestFlight be sure to include a changelog and bump the version appropriately" and
  "Once you're done with this multi-connect feature push a build to TestFlight". So: one upload is
  asked for when the several-sessions build is complete (step 14 checked and pushed); every upload
  carries a changelog (the "What to Test" text and `CHANGELOG.md`) and a bumped version. Any other
  upload still needs his word.
- **Usage, the night of 2026-11-22** (his words): "Feel free to soak up this and the next 5-hour
  session to 100% as I will be sleeping. But keep to the usual 60% rule after that": the windows up
  to 07:30 UTC on 2026-11-22 may be used fully; from then on the 60% rule below holds again.
- **Usage, the publication push** (Trick, 2026-11-24, his words): "Slam it. I will apply a full
  reset coupon in a few minutes when I see 98%" and "Don't stop for 5h usage windows until 95%".
  For finishing the publication work: the 5-hour window may go to 95%, and the week is his to
  reset. When that work is done, ask him whether 95% stays or the 60% rule below returns.
- **Weekly cap lifted** (Trick, 2026-11-22 01:40 UTC, his words: "Spend it. Use up to 100%. I
  have a reset coupon I can use."): the 85% stop for the week in the next bullet no longer
  applies. Work may use the week up to 100%, on both the all-models and the Fable figure; agents
  stop at 97% so that none dies in the middle of a step. The 5-hour rule in the next bullet is
  unchanged until he says otherwise.
- **Usage** (Trick, 2026-11-19; replaces the 40% rule of 2026-11-15): never cross 60%
  of a 5-hour session. The figure is for the whole account: every session and
  sub-agent adds up, Trick's other projects too. Start no unit of work at 45% or
  more; an agent checks between its own steps and stops at 50%: commit what is
  green, revert the rest, report what is left. Continue in the next window. Stop all
  work on this project when the week (all models) reaches 85%. Read the figures
  with `cd /tmp && claude -p /usage < /dev/null` (yellow and charlie). `out/PAUSE`
  is a stale flag of 2026-11-12: ignore it.
- **Model mix:** the weekly Fable allowance is the tight limit (a 60% round costs
  about 15% of it). Session model for transport, resume and reviews; Opus
  (`model: 'opus'`) for tooling, app screens, UI tests and docs.
- **Keep the orchestrating session small.** With a long conversation behind it, one
  tool call of the main session costs about 1% of a window. Give merges, test runs
  and fixes to agents with a fresh context; the main session launches and collects.
- **Phone:** may be used as needed. A launch takes over its screen, so launch only
  when a test needs it; a plain install does not.

**Times:** when talking to Trick, give times in US Eastern Time (logs and commits
may stay in UTC).

**Branches:** none. All work is committed straight to `main` and pushed there
(Trick, 2026-11-14). No feature branches, no pull requests.

**yellow is back (2026-11-18).** The session on yellow owns what the cloud session
owned: `Sources/` except `NWDatagramTransport.swift`, the package tests, `moshcli`,
`scripts/killloop.sh` and `scripts/itest.sh`. The session on charlie owns `App/` and
the Mac and phone scripts (`docs/MAC.md`). The cloud session is retired. The log of
the core work continues in `docs/CLOUD.md` ("After the rounds"): read its last entry
first. The Linux suite takes about 15 minutes on yellow: write its whole output to a
file (`out/yellow/suite.log`) and grep the file, never the pipe.

Owner decisions (2026-11-19): follow mosh's defaults wherever mosh has one, and say
so instead of asking. Local echo: default Adaptive, set per host, the app offers
Adaptive, Always and Never, guesses are kept across a trip to the background.
Bundled font: Hack Nerd Font. Phone: simulator only until Trick says the phone is
free (one prepared sitting, `docs/MAC.md` section 3). Headless Claude runs on
charlie are allowed; no colima on charlie.
**Resume stage 2 (M9) is shelved** (Trick, 2026-11-19): do not build it unless he
asks. Stage 1 covers a kill off screen, a force-quit and a restart; a death on
screen reconnects in 2 to 3 seconds and lands in the same tmux with the start
command. The design, its reviews and step 0 (the probe) stay in `docs/notes/stage2/`.
The session on yellow drives charlie
over SSH (`scripts/mac.sh`); no session sits on charlie now.
**Phone (2026-11-21):** it runs build 183 (`1d47a30`); the sitting showed the save while
locked, resume after force-quit, install and restart, the fallback after a kill on screen and
local echo working, and found that on Trick's host the app never learns the server's pid, so a
fallback leaves the old server running (`docs/CLOUD.md`, last entry).

State (2026-11-12 19:40 UTC):
- M0 done (see `docs/BUILD.md`): Linux and Mac pipelines, signing, placeholder app
  on the phone, phone self-test.
- Wave 1 done and merged into `main` (M1-M4 on Linux): crypto, wire, transport,
  `moshcli`, terminal model, oracle and corpus, surface feed, keys, SSH bootstrap.
  `scripts/dev.sh swift test`: 484 tests, 0 failures, 33 skipped (the sshd tests,
  run with `scripts/itest.sh bootstrap`). Working notes of the agents, with every
  decision and known gap: `docs/notes/wave1-{core,term,boot}.md`.
- TestFlight: the app record exists ("iOS-Mosh", made by Trick on 2026-11-21) and the first
  build is uploaded: 0.1 (189), `scripts/deploy.sh --testflight` from yellow, fastlane on
  charlie. Trick answered export compliance himself ("exempt, no documentation needed": the app
  is to declare `ITSAppUsesNonExemptEncryption` = NO), set up the testers himself, and runs the
  TestFlight build on his phone (it replaced the debug build 183). Do not upload another build
  without his word. He would rather have fastlane run in GitHub Actions, as in his other iOS
  apps; that is a later task and needs his OK to put the signing material into repository
  secrets.
- Built 2026-11-21: debug builds are a separate app, "iOS-mosh Dev" (`us.v9n.ios-mosh.dev`,
  profile `ios-mosh-dev-app` from `scripts/mac-signing-setup.sh devapp`), fully separate from
  the TestFlight app (own container, hosts and SSH key; no app group, no shared keychain
  group), so that test builds never replace or disturb the app he uses. Every configuration
  declares `ITSAppUsesNonExemptEncryption` = NO. Anything that installs, launches or pulls on
  the phone or simulator names the Dev id; only the TestFlight lanes use `us.v9n.ios-mosh`.
  The Dev app on the phone starts empty: a phone test first adds its host and "Install my key"
  (`docs/MAC.md` section 3).

Next (wave 2), in this order:
1. First macOS compile: `scripts/mac.sh swift build`, then `swift test`; fix what
   only Apple platforms show (CommonCrypto `AESBlock`, the NIOTransportServices path
   in `SSHBootstrap`, Darwin sockets, `MoshServerProcess` with Homebrew's
   mosh-server). Then `scripts/itest.sh all` on Linux.
2. `MoshSession`: the adapter from the transport's remote state to `TerminalState`
   (decode `HostMessage`, then `act` / `resize` / echo ack), the facade the app uses
   (connect, resume, input, resize, events), `ClipboardPolicy`. `moshcli` with the
   real terminal (`dump-screen`, `expect` on screen text), `moshcli bootstrap`, the
   netem soak ending with the framebuffer equal to `tmux capture-pane`, and the
   "MOSH CONNECT seen, no UDP reply in 15 s" error row.
3. Independent hostile reviews of `MoshTransport` against the mosh source, then fixes.
4. M6 on Linux: `MoshResume` (record, two-slot counters, snapshot, store,
   coordinator), the file-backed `DurabilityGate`, `moshcli resume` and
   `--crashpoint`, `scripts/killloop.sh` and the stage 1 table in `docs/PLAN.md`.
5. App M5: `NWDatagramTransport`, `SwiftTermSurface` on `SurfaceFeed`, host list,
   host editor, keys screen, `KeychainKeyStore`, UI tests against
   `scripts/mosh-spawner.py` on charlie, then the phone self-test with SSH and mosh.
6. App M6 wiring and M7 (key bar, paste, OSC 52), `deploy.sh --smoke`, Build 1.

Housekeeping: the worktrees `.worktrees/{core,term,oracle,boot}` and branches
`wt/*` are merged and can be removed; their Docker build volumes
(`ios-mosh-build-{core,term,oracle,boot}`) can be deleted to free disk.

## Commands

The Swift toolchain exists only in the dev container. Everything goes through
`scripts/dev.sh`, which mounts the repo at `/work` and runs as your uid.

```
scripts/dev.sh swift build                      # whole package
scripts/dev.sh swift test                       # all tests
scripts/dev.sh swift test --filter MoshCryptoTests
scripts/dev.sh --root bash -c '...'             # root in the container (sshd, tc netem)
DEV_REBUILD=1 scripts/dev.sh true               # rebuild the image after a Dockerfile change
```

- `.build` is a Docker volume named after the checkout directory
  (`ios-mosh-build-<dirname>`), because `/home` on yellow is small. It is not
  visible on the host. Read dependency sources from `.refs/` instead (shallow
  clones of mosh 1.4.0, SwiftTerm 1.99.3, swift-nio-ssh 0.15.1; gitignored).
- Parallel work uses git worktrees under `.worktrees/<name>` (gitignored). Each
  has its own build volume. Two builds in one checkout wait on each other's lock.
- Inside a `--root` container, run anything that writes to `.build` as uid 1000
  (`runuser -u ubuntu -- swift test ...`), or the volume ends up root-owned.
- In the container: mosh 1.4.0 source, already built, is at `/opt/mosh-src`
  (authority for protocol behaviour, and what `Tools/mosh-oracle` links against).
  `mosh-server`, `sshd`, `tmux`, `vim`, `tcpdump`, `tc` are installed.
- Each `dev.sh` call is a new container. Servers started in one call are gone in the
  next, so a test starts its own `mosh-server` or `sshd` in the same call.

## Rules

- Protocol facts come from the mosh 1.4.0 source, not from memory. The appendix of
  `docs/PLAN.md` is a summary to be confirmed against it.
- The four hard failures N1–N4 in `docs/PLAN.md` section 3 (nonce reuse, state
  number reuse, `throwaway_num` above `old_num`, fragment id reuse) must stay
  impossible by construction. Sends go through `DurabilityGate`.
- Dependencies are pinned in `Package.swift`; do not add one without need.
- Code that must also build for iOS: no `Foundation.Process`, no Linux-only APIs
  outside `#if os(Linux)` / `#if canImport(Glibc)`. Linux-only test helpers live in
  test targets or `moshcli`.
- XCTest for tests. A test that needs `mosh-server` or `sshd` starts and stops its
  own, on 127.0.0.1.
- Commit messages: short imperative subject, body says why.
- Secrets (API key, keychain password, team id) live only in `charlie:~/signing/`.
  Never print or commit them.

## Build and install pipeline — things that will bite

`docs/BUILD.md` has the commands and the full list. The short version:

- Mac work goes through `scripts/mac.sh` (sync + run on charlie). App tests:
  `scripts/mac.sh scripts/sim-test.sh`. Phone (the Dev app): `scripts/deploy.sh`.
- Scripts that run on the Mac start with `#!/bin/bash`; the SSH shell there is zsh.
- After an Xcode update, `sudo xcodebuild -runFirstLaunch` (Trick) or simulators
  and `devicectl` do not work.
- The login keychain is locked over SSH: signing needs an unlock in the same command.
- SwiftTerm 1.99.3 has the 2.0 API: no `getTerminal()`; use the view's copied reads.
- UI-test launches pass `-uiTesting 1`, which turns animations off (otherwise each
  launch waits 60 s) and publishes the screen text in the `screenText` element.
  Session records and keys are wiped only with `-uiTestingResetSessions 1` (review
  M6-11): a UI test that needs to start without sessions passes it.
- Signing settings never go on the `xcodebuild` command line (they would apply to
  the Swift packages too); they live in `App/Signing.xcconfig` on charlie only.

## Repository Layout

| Path | Contents |
|---|---|
| `Package.swift` | Package `MoshKit`; all targets |
| `Sources/MoshCrypto` | AES block, OCB3, mosh cipher, base64 key |
| `Sources/MoshWire` | Protobuf messages, fragments, packet framing, zlib |
| `Sources/MoshTransport` | Sender, receiver, RTT, sockets, `MoshConnection`, `DurabilityGate` |
| `Sources/MoshTerminal` | Framebuffer, parser, applier, display diff, wcwidth, surface feed |
| `Sources/MoshResume` | Session record, counters, snapshot, resume |
| `Sources/MoshKeys` | Ed25519 keys, OpenSSH public key format, fingerprints |
| `Sources/MoshBootstrap` | SSH bootstrap, `MOSH CONNECT` parsing, known hosts, server probe |
| `Sources/MoshSession` | Facade the app uses |
| `Sources/moshcli` | Test executable driving the core against real servers |
| `Tools/mosh-oracle` | mosh's own emulator as a JSON-printing test oracle (Linux) |
| `App/` | iOS app, XcodeGen project (built on charlie) |
| `docker/`, `scripts/` | Dev image and wrappers (`dev.sh` container, `mac.sh` Mac, `deploy.sh` phone) |
| `docs/` | Plan, research, build notes, agents' working notes (`docs/notes/`) |
