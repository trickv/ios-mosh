# Cloud rounds

> Addresses, ports and details of the author's own network were removed before publication.

From 2026-11-12 the machine `yellow` (Docker dev container, the usual home of this
work) is offline for about a week, and so is the session that orchestrated it. Until
it is back, the Linux part of the work continues in a Claude cloud session that a
scheduled task wakes every few hours. Each wake-up is one **round**. This file is the
standing instruction for a round and the log between rounds. The owner is Trick
(GitHub `trickv`). Nobody is watching: do not ask questions, decide and write down why.

## What is and is not available here

- Available: this repository, a plain Linux machine, the network.
- Not available: Docker, the Mac `charlie`, the phone, signing, TestFlight. Do not
  work on `App/` beyond keeping it compiling in your head; nothing here can build it.
- `scripts/dev.sh` runs commands natively when there is no Docker (`DEV_NATIVE=1`
  forces it). `scripts/cloud-setup.sh` installs what the dev container had: Swift
  6.2, mosh 1.4.0 (server, and the built tree at `/opt/mosh-src`), sshd, protobuf,
  and the reference clones in `.refs/`. Run it when `swift`, `mosh-server` or
  `/opt/mosh-src/src/terminal/libmoshterminal.a` is missing. If a step fails, fix
  the script and commit the fix.
- Things that may not work in a cloud sandbox: `tc netem` (needs the kernel module
  and NET_ADMIN), `sshd` with test users (needs root), the user name `ubuntu` that
  some scripts assume. Try once. If it is impossible here, write "needs yellow" in
  the log for that test and move on. Never weaken or delete a test to get past this.

## Rules for every round

1. `git fetch origin && git checkout main && git pull --ff-only origin main`.
   All work goes straight on `main` (changed by Trick on 2026-11-14; the rounds
   up to round 10 used the branch `cloud-work`, since merged). Push after every
   unit of work: `git push origin main`. Never force-push, no pull requests, no
   tags. Never touch another repository.
2. Read `CLAUDE.md` ("Project Status", "Rules") and the log at the end of this file.
3. **Usage budget.** Trick's rule: stop when the 5-hour session usage is over 60%.
   At the start of the round, and again before each new unit of work, run
   `cd /tmp && claude -p /usage` and read the "Current session" line. At 55% or
   more: commit, push, write the log entry and end the round at once. If the
   command does not work here, do exactly one work item (or one clearly bounded
   part of a large one) per round and then end the round. Also read the weekly
   lines: if a weekly figure is over 85%, end the round and say so in the log.
4. **Model mix.** Do the work with sub-agents that have a fresh context (the Agent
   tool), at most three at a time, and keep your own context small: you launch,
   check results, run the suite, commit. Use the default model for tooling, tests
   and ordinary code. Use `model: "fable"` only for: the hostile reviews of the
   transport (item 3), and the design and review of the durability gate, counters,
   snapshot and resume logic (item 4). Those are the places where a subtle mistake
   kills a remote shell or reuses a nonce.
5. Protocol and emulator facts come from the mosh 1.4.0 source (`.refs/mosh`,
   `/opt/mosh-src`), not from memory. `docs/PLAN.md` has the design (section 3 is
   resume; the "Verification" section has the stage 1 table). The notes of the
   agents that wrote the modules are in `docs/notes/wave1-*.md`: read the relevant
   one before changing a module.
6. The suite must stay green: `scripts/dev.sh swift test -j 4` before every push
   that changes Swift code. Commit messages: short imperative subject, a body that
   says why, last line `Co-Authored-By: Claude <noreply@anthropic.com>`. No model
   names in commits or code.
7. End of round: add an entry to the log below (date and time in UTC, what was
   done with the commands that prove it, what is next, what needs yellow or the
   Mac), commit, push, stop. Do not wait or poll for anything.
8. When every item below is done or marked "needs yellow": write that in the log,
   then find the scheduled task named "ios-mosh cloud rounds" with `list_triggers`
   and disable it with `update_trigger` (enabled false). Do nothing in later rounds.

## Work items, in order

1. **Environment check.** Run `scripts/cloud-setup.sh`. Then `scripts/dev.sh swift
   test -j 4` (expect 484 tests, 0 failures, about 33 skipped) and
   `ITEST_NO_CONTAINER=1 scripts/itest.sh all`. Record what works here and what
   does not (root, sshd, netem, `claude -p /usage`).
2. **MoshSession and the real terminal in moshcli.** (a) The adapter from the
   transport's remote state to `TerminalState`: decode `HostMessage`, then `act`,
   `resize`, echo ack, exactly as mosh's `Complete::apply_string` does. (b) The
   facade the app will use: connect from a bootstrap result, input, resize, events
   (new screen state, last-contact ages, server ended, base state lost), quiesce,
   export and import; plus `ClipboardPolicy` (rules in `docs/PLAN.md` section 5,
   "OSC 52"), tested on Linux. (c) `moshcli`: `dump-screen` writes the rendered
   screen, `expect` can match screen text, a `bootstrap` subcommand that logs in
   over SSH and starts a session. (d) The soak ends by comparing the client's
   framebuffer rows with `tmux capture-pane -p` on the server side. (e) The error
   row "MOSH CONNECT seen, no UDP reply in 15 s" with a test (a server that never
   answers). `MoshTransport` and `MoshTerminal` still must not import each other.
3. **Hostile reviews of MoshTransport.** Three independent reviewers on
   `model: "fable"`, each comparing `Sources/MoshTransport` with the mosh source
   from a different angle: (i) sender timing, retransmission and the sent-states
   list; (ii) receiver, fragments, acks, throwaway and the guards N1-N4; (iii) the
   export, import and quiesce seams against `docs/PLAN.md` section 3. Each finding
   needs the mosh source lines and a failing test idea. A second agent tries to
   refute each finding. Fix what survives, each with a test.
4. **Resume, stage 1, on Linux (M6).** `MoshResume`: the session record (meta,
   two-slot counters with generation and CRC, snapshot, lock), the store, the
   coordinator for cold start and fallback; the file-backed `DurabilityGate`
   (reserve ahead, dirty before send, `fsync`); `moshcli resume`, `--crashpoint`
   and `SIGUSR1` as in `docs/PLAN.md` "Test tools"; `scripts/killloop.sh` and every
   row of the stage 1 table that can run here. Rows that need netem: "needs yellow".
   Write `docs/RESUME.md` (invariants and record format).
5. Only if items 1-4 are finished: `docs/SERVER-SETUP.md` (tmux and neovim
   clipboard lines from `docs/PLAN.md` section 5), then stop as rule 8 says.

## Log

- 2026-11-12 21:50 UTC, from yellow before it went offline: wave 1 is merged into
  `main` (484 tests, 0 failures, 33 skipped on Linux in the dev container). Nothing
  of the new code has been compiled on macOS yet. `scripts/cloud-setup.sh` and the
  native mode of `scripts/dev.sh` were written without a cloud machine to try them
  on: expect to fix them in round 1.
- 2026-11-12 (round 1, cloud): **item 1 done.** `scripts/cloud-setup.sh` worked on
  the first run (about 2 min fresh, 6 s again). Fixes pushed: `8cc6c4c` dev.sh goes
  native when the Docker daemon is unreachable (the client is installed here, the
  daemon is not); `ef4bb7d` native mode sets the UTF-8 locale (without it
  `mosh-client` would not start and two sshd tests failed); `45c758d` sshd itests run
  as the checkout's owner instead of `ubuntu` (everything is root-owned here);
  `704578e` quieter clones. Results: `scripts/dev.sh swift test -j 4` gives
  "Executed 484 tests, with 33 tests skipped and 0 failures" (the 33 are
  `SSHBootstrapIntegrationTests`); `ITEST_NO_CONTAINER=1 scripts/itest.sh all`
  passes handshake, hello, script, rebind, resume-mem, and bootstrap (108 tests,
  0 failures, the 33 sshd tests included). The oracle builds against `/opt/mosh-src`
  and `corpus-check.sh --gen` reports "38 cases pass". Works here: root (uid 0),
  sshd with test users, mosh-server 1.4.0, the oracle. **Needs yellow: `tc netem`**
  (the kernel has no `sch_netem` and no modules; NET_ADMIN works, `tbf` loads).
  `claude -p /usage` prints only cost and token totals, no percentages, so by rule 3
  each round does one work item. First `swift test` on a fresh machine takes about
  4 min (dependency build). Next round: item 2 (MoshSession), probably in bounded
  parts: (a)+(b) first, then (c)-(e).
- 2026-11-13 ~00:50 UTC (round 2, cloud): **item 2 parts (a) and (b) done; item 2
  unfinished.** Commits: `8903c11` the transport takes a remote state numbered 0 of
  the server's start size (mosh's `initial_remote`; no send or durability logic
  changed); `df22623` `TerminalRemoteState`, the adapter that decodes `HostMessage`
  and applies host bytes, resize and echo ack in order as `Complete::apply_string`
  does (the 2916 corpus instructions run through it match mosh's client state);
  `9d38066` `ClipboardPolicy` (PLAN.md section 5); `eacbd69` the `MoshSession` actor
  (start, type, resize, screen, contact ages, replaceSocket, quiesce, resume,
  export, shutdown, events), with an integration test against a real mosh-server;
  `4364085` notes in `docs/notes/wave2-session.md`. `scripts/dev.sh swift test -j 4`
  gives "Executed 518 tests, with 33 tests skipped and 0 failures". Gaps: no
  snapshot byte format (M6), no resize debounce, not compiled for Apple platforms.
  Next round: item 2 parts (c)-(e). Read the notes first: `serverStartSize` must
  equal the server's start size (80x24 for a server without a tty); `--record`
  needs `MoshConnection<TerminalRemoteState>` or a pass-through for
  `.instructionApplied`; the 15 s "no UDP reply" error is not in the facade yet.
- 2026-11-13 ~03:45 UTC (round 3, cloud): **item 2 done** (parts c-e), except the
  netem soak (needs yellow). Commits: `97aadfb` `MoshSession` reports
  `.noServerReply(.udpBlocked(port:))` when the session is still at state 0 after
  15 s (mosh's rule; the timeout can be injected, and the test uses 600 ms against a
  UDP socket that never answers); `025113a` `moshcli` runs on the facade
  (`dump-screen` renders the rows, the old raw dump is `dump-bytes`, `expect-screen`,
  `bootstrap` over SSH with the pty at the view size, `--record` through a
  pass-through event, exit codes 6 no reply and 7 bootstrap failed) and the new
  `scripts/soak.sh` (shell in tmux, ends by comparing the client's screen with
  `tmux capture-pane -p`); `7026fe1` notes in `docs/notes/wave2-session.md`.
  `scripts/dev.sh swift test -j 4`: "Executed 523 tests, with 33 tests skipped and
  0 failures". `ITEST_NO_CONTAINER=1 scripts/itest.sh all` exits 0: handshake, hello,
  script, rebind, resume-mem, soak, bootstrap (108 tests), bootstrap-session pass;
  netem-soak skipped with "needs yellow". Soak without netem: the screen equals
  `tmux capture-pane -p` (80x24, and 60x15 with 2 rebinds). **Needs yellow:**
  `scripts/netem.sh 10` (10 min under loss, with the screen check) and
  `scripts/netem.sh 3 --rebind-every 20`. Under loss the soak waits 3 s of quiet
  before it compares; if the screens differ, look at that first. Gaps:
  `moshcli bootstrap` key login (`--key-store`) has no itest; arrow keys in scripts
  always send the normal cursor-key codes; nothing compiled for Apple platforms.
  Next round: item 3 (hostile reviews of MoshTransport).
- 2026-11-13 ~07:40 UTC (round 4, cloud): **item 3 reviews and refutation done;
  fixes unfinished.** Three reviewers (sender; receiver and N1-N4; export, import
  and quiesce) wrote 16 findings, each with mosh source lines and most with a
  failing scratch test (`docs/notes/review-transport/`). None
  is critical. Two fuzz runs against a model of mosh-server's asserts found no
  N1-N4 break and no send that bypasses the gate. The refuter
  (`refutation.md`) refuted none, merged them into M1-M10, re-ran every
  reproduction, and gave a fix and a test for each survivor. Major: **M1** the
  second client shutdown send uses `old_num` 2^64-1, the Outbox refuses it and the
  core halts (with 95+ bytes of recent unacked input); **M7** (latent) import
  accepts a gate below the snapshot's limits, so sequence, state and fragment
  numbers could be reused with no error. Minor: M2 shutdown target moves with the
  input window; M3 shutdown clock runs while quiesced; M5 replay counted in order
  after import (`expectedReceiverSeq` not in the snapshot); M6 a late state resets
  `ack_num`; M8 clean-mark token not bound to the export; M9 input after export
  while quiesced; M10 clipboard baseline on restore. M4 is wording only. No Swift
  code changed this round. **Next round: fixes in the refuter's order**: M1+M2+M3,
  then M6, then M7+M5+M8 as one snapshot change (before item 4), then M10, M4;
  M9 goes to item 4's coordinator as a requirement.
- 2026-11-13 ~10:00 UTC (round 5, cloud): **item 3 done.** Fixes for the merged
  review findings, each with a test seen failing first: `df4da95` client shutdown
  with pending input and across a quiesce (M1, M2, M3); `01e672c` keep the
  shutdown ack when a state arrives after the server's shutdown (M6); `664e2c8`
  the snapshot is bound to its counters, receive sequence and clean mark (M7, M5,
  M8: import throws `gateBelowSnapshot` / `usedCountersInvalid`, the snapshot
  carries `usedCounters` and `receiverExpectedSequence`, `exportState()` returns a
  `CleanToken` for `gate.markClean`); `65fb952` clipboard baseline on restore
  (M10); `98b5da8` probe interval wording (M4); `3a21d3f` Status section in
  `docs/notes/review-transport/refutation.md`. One existing test changed with a
  reason (`ResumeSeamTests.testImportWithNothingPendingSendsAnEmptyAck` reuses the
  fake server, whose sequence never restarts, network.cc:515-519); its assertions
  are unchanged. `scripts/dev.sh swift test -j 4`: "Executed 543 tests, with 33
  tests skipped and 0 failures"; `ITEST_NO_CONTAINER=1 scripts/itest.sh all` exits
  0 (netem-soak skipped, needs yellow). **Open for item 4:** M9 (input or a
  shutdown accepted while quiesced after the export is not covered by the token:
  the coordinator must snapshot again or extend the token, and mark the record
  ended on a shutdown); the byte format must carry the two new snapshot fields;
  `shutdown()` now returns `Bool`. Accepted cost: a shutdown with never-sent input
  pending sends the full diff in all 16 tries. Details in
  `docs/notes/wave2-session.md`. Next round: item 4 (resume, M6 milestone), in
  bounded parts: first the record format, counters and file-backed gate.
- 2026-11-13 ~13:00 UTC (round 6, cloud): **item 4 part 1 done (record, store,
  file-backed gate); item 4 unfinished.** Commits: `b0a767d` the session record
  format (binary meta, two counters slots with generation and CRC, versioned
  snapshot with every `TransportSnapshot` field and the terminal and clipboard
  state, lock); `91363a1` `SessionStore` and `FileBackedGate` (reserve ahead in
  blocks, dirty before send, temp + fsync + rename + dir fsync, `flock`, restart
  from the highest valid limit, never from the snapshot); `611ca1b` end-to-end
  test: session against a real mosh-server, saved, everything dropped, reopened
  from the record, typing continues; `24c32c2` `docs/RESUME.md` (invariants R1-R17
  with code and test each, byte-by-byte format). The crash test kills a process at
  every storage step, with torn writes, across three process generations.
  `scripts/dev.sh swift test -j 4`: "Executed 608 tests, with 33 tests skipped and
  0 failures". The three code commits were pushed after one green run together.
  Deviations from the plan (noted in `docs/PLAN.md` section 3): limit and dirty
  changes go to both slots; meta is binary, not JSON; `MoshResume` depends on
  `MoshSession`. Gaps: M9 open (in `docs/RESUME.md`), no real power-loss test,
  not compiled for Apple platforms. Next round: item 4 part 2, the coordinator
  (cold start and fallback, M9), `moshcli resume`, `--crashpoint` (a
  `StorageHook` that kills the process), `SIGUSR1`, `scripts/killloop.sh`; then
  the stage 1 table and a review of the resume code on the session model. Read
  `docs/notes/wave2-resume.md` first.
- 2026-11-13 ~16:00 UTC (round 7, cloud): **item 4 part 2 done (coordinator,
  moshcli resume, kill loop, stage 1); item 4 unfinished: the review of
  `MoshResume` on the session model remains.** Commits: `2409b46` resume
  coordinator (cold start, fallback, saving) and **M9 closed** with a test that
  fails without the fix; `abf3e16` `moshcli resume`, `--crashpoint`, `SIGUSR1`,
  `--seq-log`; `5a6858a` tests that show mosh-server 1.4.0 really exits on N2 and
  N3; `62813ba` `scripts/killloop.sh` (`scripts/itest.sh killloop`); `6225656` stage
  1 results and coordinator invariants in `docs/RESUME.md`. `scripts/dev.sh swift
  test -j 4`: "Executed 634 tests, with 34 tests skipped and 0 failures" (the new
  skip is a file-permission test that cannot run as root). `ITEST_NO_CONTAINER=1
  scripts/itest.sh all` exits 0 (killloop 20 iterations; netem-soak skipped).
  Long kill loop (`scripts/itest.sh killloop 260 --long`, about 5 min, pass): 260
  kills (203 resumed after a quiesce, 57 fell back as dirty), all 521 typed lines
  arrived exactly once, 127 screens equal to `tmux capture-pane -p`; all 48 storage
  crash points, before, after and torn (130 kills); no reuse of a sequence number,
  state number or fragment id (1962 sequence numbers over 116 keys, plus a tcpdump
  of 1885 datagrams); 194 servers, none aborted. Every stage 1 row passed; the 20%
  loss row passed with `moshcli --loss`. **Needs yellow:** the kill loop and the
  loss row under `tc netem`; on yellow the tcpdump check needs root in the
  container. Gaps: crash model is process death only; nothing compiled for Apple
  platforms; app not wired. Next round: hostile review of `MoshResume` (session
  model, reviewer plus refuter), then fixes; then item 5.
- 2026-11-13 ~19:00 UTC (round 8, cloud): **item 4 review and refutation done;
  fixes unfinished.** Two reviewers on the session model (A: record, store, gate,
  lock; B: coordinator, cold start, fallback, M9) wrote 15 findings, none
  critical; neither found a path to N1, N2 or N4 in the app's designed use, and a
  3000-seed fuzz of the gate (I/O failures, crashes, torn writes, a slot lost)
  found no reused number. Reports, scratch tests and `refutation.md` are in
  `docs/notes/review-resume/`. The refuter re-ran all reproductions, refuted B-5
  (doc sentence only) and lowered A-5, A-7, A-8. Major survivors: **A-1**
  `SessionRecord.create` over an existing record resets the counters under the
  same key (N1 by misuse; refuse an existing directory); **A-2** no backup
  exclusion, so a device restore could bring back old counters with the Keychain
  key (seam and tests on Linux now, Darwin branch on the Mac, restore test on the
  phone); **B-1** a fallback left unfinished is marked "ended", so the session is
  dropped silently and the old server never killed. No Swift code changed this
  round. **Next round: fixes in the refuter's order**: A-1; B-1 with B-7; A-6+B-4;
  A-3+B-3; B-2; A-4 and A-5; A-2; A-7 and A-8; B-6; B-5. Then item 5.
- 2026-11-13 ~22:15 UTC (round 9, cloud): **item 4 done** (Linux part; the
  Darwin branches need the Mac). Fixes for the resume review, each with a test
  seen failing first: `a318632` A-1 refuse to create over an existing record;
  `b19a691` B-1, B-7 a given-up record stays dirty, the key source is explicit;
  `8732981` A-6, B-4 a shutdown writes dirty first and is refused if the ended
  mark cannot be written; `c7daed4` A-3, B-3 no second save of a clean record;
  `7d6068e` B-2 nothing reaches the session before `start()`; `d0543db` A-4, A-5
  clean mark bound to its snapshot, one gate per lock; `4f4a0cd` A-2 records kept
  out of backups and a record that is not excluded is refused; `e3a21b3` A-7, A-8
  only ENOENT means missing, a failed full sync is an error; `c3c9a85` B-6;
  `b541716` B-5 doc; `108267a` `docs/RESUME.md`, Status in
  `docs/notes/review-resume/refutation.md`, stage 1 numbers. Deviations from the
  refuter are explained there. Four existing tests changed with reasons, none
  deleted or weakened. `scripts/dev.sh swift test -j 4`: "Executed 665 tests, with
  34 tests skipped and 0 failures"; `ITEST_NO_CONTAINER=1 scripts/itest.sh all`
  exits 0 (netem-soak skipped). Long kill loop pass: 260 kills (203 resumed, 57
  fell back), 521 lines exactly once, 127 screens equal, 132 crash-point runs over
  49 steps, 2032 sequence numbers and 1941 captured datagrams over 116 keys with
  no reuse, 196 servers, none aborted. **Needs the Mac:** compile
  `AppleRecordProtection` and the `F_FULLFSYNC` branch (never compiled), run
  `RecordProtectionTests.testTheAppleProtectionReadsBack` and the whole suite,
  find the errno of an unsupported `F_FULLFSYNC` and whether it works on a
  directory. **Needs the phone:** protection class reads back, a save works while
  locked, one backup and restore ends in "record deleted", cost of a save. Next
  round: item 5 (`docs/SERVER-SETUP.md`), then rule 8.
- 2026-11-14 ~00:30 UTC (round 10, cloud): **item 5 done; all items done or
  marked "needs yellow".** `127d57e` adds `docs/SERVER-SETUP.md`. Checked here: the
  PLAN tmux line parses (tmux 3.4); with it, tmux's own copy (`set-buffer -w`)
  sends `52;c;`, which mosh accepts (without it tmux sends `52;;`, which mosh
  drops); mosh-server 1.4.0 starts with the app's command, and a missing locale
  gives the "UTF-8 native locale" error. **Open problem for Trick:** a program
  inside tmux that sends OSC 52 itself does not reach the phone: with the default
  `set-clipboard external` tmux sends nothing, with `set-clipboard on` and the
  PLAN line it sends `52;cc;`, which mosh drops. Neovim inside tmux is probably
  affected (not installed here, unconfirmed). Left "not decided" in the document:
  that fix, `set-clipboard`, `terminal-features`, `allow-passthrough`, the lowest
  working mosh-server and neovim versions.

  **End of the cloud rounds.** Summary for the return to yellow: merge
  `cloud-work` into `main` (main has not moved). Items 1-5 are done on Linux:
  `scripts/dev.sh swift test -j 4` gave 665 tests, 34 skipped, 0 failures at round
  9; `ITEST_NO_CONTAINER=1 scripts/itest.sh all` passes. **Needs yellow:**
  `scripts/netem.sh 10` and `scripts/netem.sh 3 --rebind-every 20` (round 3), the
  kill loop and the 20% loss stage 1 row under `tc netem`, and the tcpdump check of
  the kill loop with root in the container (round 7). **Needs the Mac:** first
  compile of everything new for Apple platforms (wave 2 item 1 in `CLAUDE.md` is
  still open), `AppleRecordProtection` and the `F_FULLFSYNC` branch, and
  `RecordProtectionTests.testTheAppleProtectionReadsBack` (round 9). **Needs the
  phone:** protection class, save while locked, backup and restore, cost of a save
  (round 9). Reviews and their status: `docs/notes/review-transport/` and
  `docs/notes/review-resume/`. Per rule 8 the scheduled task "ios-mosh cloud
  rounds" is disabled after this entry.
- 2026-11-21 07:30 UTC: **Several sessions at once: the design is drafted and criticised, not yet
  revised.** In `docs/notes/multi-session/`: three maps of today's code (`map-list.md`,
  `map-lifecycle.md`, `map-core.md`), `DESIGN.md` (first draft, 704 lines, twelve steps 0 to 11),
  `critique-ui.md` (finished) and `critique-lifecycle.md` (stopped by the usage rule; its top
  lists what it has not read: the mosh sources, the maps, part of the table). What the round
  settled: **no file under `Sources/` has to change**; a session off screen is a clean, closed
  record and nothing in memory (back = `enterBackground()` then `close()`; a tap on a row = the
  cold start the launch makes); "End Session" on a parked session can go through mosh's own
  shutdown (cold start, `start()`, first contact, `shutdown()`), so it also works on `hg`, once
  one new test shows a real mosh-server acknowledging it (step 0). No critique found a way to
  N1 to N4. Eight major findings wait for the revision: leftover mosh-servers fill the
  spawner's port range across UI-test runs (U1); the park and preview unit tests need a real
  server (U2); step 8 is too big for one agent (U3); the green dot after the dotted session
  ends (U4); a scene resign during a tap's wait reaches no screen (LC-1); input not yet
  acknowledged at a park is sent only at the next unpark (LC-2, the same as mosh's client while
  a laptop sleeps); "End Session" on the dotted row must clear the last looked-at id first
  (LC-3); a park whose save fails must not close the session (LC-4).
  Next, after the reset at 11:30 UTC, in this order: (1) the simulator test the tools update
  broke; (2) the rest of the lifecycle critique and the revision of `DESIGN.md`, checked by a
  second agent; (3) the steps. Usage at 07:22 UTC: session 53%, week 48%.
- 2026-11-21 12:50 UTC: **The simulator suite is green again; the design is revised; its last
  checks are half done.** `376c583` (pushed after an independent check): the size test makes its
  change with a layout hook for UI tests only (`-uiTestingBackgroundInset`, Debug builds under
  `-uiTesting 1`), the app reports a held size as a mark, and a second test shows the held size
  reaching the server in the foreground; with the hold switched off both fail on
  `background-resize`. Whole suite: 126 unit tests, 49 UI tests, 0 failures (`docs/MAC.md`).
  Several sessions: `critique-lifecycle.md` is finished (LC-1 to LC-19: 5 major, 12 minor, 2 doc;
  no way to N1 to N4 outside debug launch arguments; every mosh citation right; a value yielded
  before `finish()` is delivered, 132,000 runs on Linux, Swift 6.2.4). `DESIGN.md` is rewritten
  as one design (25 findings accepted, 4 settled by decision, none refuted; steps 0 to 14; still
  no change under `Sources/`). Two last checks stopped at the usage line; what they found so
  far is in `checks.md`: 5 must fix (the retry flag of LC-13; the endings E1, E3, E4 without a
  step or a test; the "+" shown before a host tap starts a new session; step 6's files; step 9's
  size) and 11 should fix. None of the must-fix findings touches steps 0 to 3.
  Defaults taken beyond the earlier ones (section 10.3 of the design): after a crash the
  replacement session starts by itself once, and if he goes back before it connected, later
  launches show the list (LC-11); back never ends a session, also one not yet connected (LC-12).
  Usage at 12:49 UTC: session 58%, week 56%, Fable week 64%. The Fable figure rose 13 points in
  this window. From here: implementing agents run on Opus with a set effort, the session model
  only reviews what decides how a record is saved, resumed or given up, the 85% stop is applied
  to the Fable figure too, and an agent does not start at 45% or more (three agents finishing
  at once took this window from 49% to 58%).
  Next (16:30 UTC): the fix round and the rest of both checks; beside it steps 0 to 3.
- 2026-11-21 17:15 UTC: **Several sessions, step 0: a resumed session ends through mosh's own
  shutdown against a real mosh-server, so section 6 of `DESIGN.md` holds.** Two tests in
  `Tests/MoshResumeTests/ResumeCoordinatorTests.swift` (`ResumeCoordinatorServerTests`), no
  change under `Sources/`. Both first park a session the way the app will: create, `start()`,
  a line echoed, input settled, `enterBackground()` clean, `close()`. Then a cold start
  (`isRestored`), a reader on `events`, `start()`. `testAResumedSessionEndsByMoshShutdown`: a
  `.contact` within 10 s, `shutdown()` true, the record "ended" at once, exactly one
  `.shutdownFinished(acknowledged: true)`, the server process gone within 5 s, no halted,
  base-state-lost, protocol or gate events, and a later cold start is `.fallback(.ended)`
  without a new session. `testAResumedSessionWithoutItsServerIsNotAcknowledged`: the same with
  the server killed after the park: `shutdown()` true, the record "ended", exactly one
  `.shutdownFinished(acknowledged: false)` (under 4.8 s after the request: the test takes
  14.7 s, 10 s of it the wait for a contact), and
  `.fallback(.ended)`. Controls, run once each and taken out again (logs in
  `out/yellow/ms/step0/`, not committed): without the resumed `start()` (control-1.log) there
  is no contact and no `.shutdownFinished` within 15 s ("XCTAssertEqual failed: ("[]") is not
  equal to ("[true]")", 3 failures); the server still exited, so the shutdown datagrams reach
  it but nothing reads its answer, as `map-core.md` section 5 says. With the server left
  running (control-2.log) the answer is true ("("[true]") is not equal to ("[false]")").
  Ten runs of the two in a row: 10 of 10 passed each, "Executed 2 tests, with 0 failures"
  every time (15.5 to 15.6 s). Whole suite, `scripts/dev.sh swift test -j 4`
  (`out/yellow/ms/step0/suite.log`): "Executed 768 tests, with 33 tests skipped and 0 failures
  (0 unexpected) in 963.41 (963.41) seconds", both new names passed. A second agent ran the
  two three times more and both controls again with the same failures (`check-*.log`). Next:
  steps 2 and 3 (step 1 is `7d236fb`).
- 2026-11-21 17:45 UTC: **Several sessions: the design is the one to build from.** After the
  revision (12:50) both last checks were finished, their findings answered in two fix rounds and
  one verification, and the verification's eight points corrected (rows V-1 to V-8 of "Review
  status"); `checks.md` holds every finding and report word for word. The lifecycle check found
  no must-fix finding and no way to N1 to N4; the plan check's findings were about the cut of
  the steps and the tests. Steps now: 0 to 14 with 5b (shared UI-test helpers, the run prints
  its leftover servers), 8b (the leave decisions as pure functions), 9b (a size hold during the
  pop, only if step 9's test shows a resize) and 11b (a fallback he left keeps the record). No
  change under `Sources/`. Steps 8 to 12 get a hostile review by the session model when built,
  and the diffs of steps 2 and 4 before step 8 starts and before any build is offered. Trick can
  try a build after step 6 (the new list and the "…" menu) and after step 11b (the feature).
  Built so far: step 0 (`372b38a`, entry above) and step 1 (`7d236fb`, `docs/MAC.md`).
  Builders run on Opus with effort high; each step's checker commits and pushes.
- 2026-11-22 01:05 UTC: **Several sessions: steps 4, 5 and 5b are in; step 6 is built but not
  approved; the review of steps 2 and 4 found one thing that must change.** Pushed after their
  checks: `7ffb6c4` (step 4, session rows under hosts), `f5b7be0` (step 5, preview, "last used",
  the dot), `91c2da5` (step 5b, shared UI-test helpers; `sim-test.sh` prints the servers left
  after a run). Suite after 5b: 139 unit tests, 54 UI tests, 0 failures. Entries in `docs/MAC.md`.
  Step 6 (the "…" menu, the list under every terminal) is in the working tree, uncommitted. Its
  checker refused it: the only whole run had one failure
  (`LocalEchoUITests.testAPasteReachesTheSessionAsOneInput`, 26 of 28 passes with step 6, 11 of
  11 without, cause not found), that run was not after the last change, and "End Session?" from
  the menu while a connect is still asking (host key, password) leaves the terminal on
  "Connecting…" for good.
  The session model's review of the diffs of steps 2 and 4 (`docs/notes/multi-session/
  review-steps-2-4.md`, word for word): one must fix, a sideways swipe on a row without actions
  on that side opens the row (seen under XCUITest; host rows lost their right swipe in step 4);
  seven should fix. `forget` and `removeOrphans` delete nothing today's app keeps; the lock holds.
  Dark screenshots cannot be made: charlie's simulator renders light whatever its setting.
  Not started: step 7. Usage at 01:04 UTC: session 41% (resets 02:30), week 70%, Fable week 73%.
  Next (02:30 UTC): step 6 corrected and checked; "step 4c" (the swipe, R24-S1, R24-S2) with a
  check and the reviewer's verdict; then a device build without install; then steps 7 and 8.
- 2026-11-22 18:35 UTC: **Several sessions: steps 6 to 9 are in. Back parks a session. The
  week's usage is spent, so the build pauses here.** Pushed, each after its independent check
  (entries in `docs/MAC.md`): `4e35540` step 6 ("End Session" behind the "…" button, the list
  under every terminal; the button has no `UIMenu`, decision D8 of the design, `424ae34`: any
  `UIMenu` on the bar made the simulator lose Cmd-V in 1 run of 20), `059c7f6` step 4c (a
  sideways swipe never opens a row; the review's R24-S1 and R24-S2), `41395cc` step 7 (the
  server's end returns to the list), `a5c5e92` step 8 (`SessionActivity`, `SessionQueue`; the
  hostile review found one must fix, corrected), `bff0cd4` step 8b (the leave decisions as pure
  functions), `3a10083` step 9 (back parks; a row resumes the same shell; ten switches between
  two hosts). The session model reviewed steps 4c, 8 and 9 before they were pushed; step 9 had
  no must-fix finding. Step 9b is not needed: the corrected deciding test sees no resize at a
  switch and its control fails. Suite after step 9: 153 unit tests, 69 UI tests, 0 failures.
  Builders were Opus where the design names the session model (to spare its weekly budget).
  Trick's words this round: the weekly cap is lifted ("Spend it. Use up to 100%"); a TestFlight
  build when the feature is done, with a changelog and a bumped version (`CLAUDE.md`).
  **Not built:** 10 (taps wait; a host tap always starts a new session; the "+"), 11 (the launch
  target), 11b, 12 (End Session on a parked row through mosh), 13, 14, then the TestFlight
  upload. In the app as pushed: a tap on a host that has a session resumes its newest one, and
  a launch opens the newest record, not the one looked at last.
  Usage at 18:30 UTC: week 94% (all models), 93% (Fable). A reviewed step costs about 5 points,
  so nothing more is started. The chain's saved script holds the remaining steps; it restarts
  after the weekly reset (2026-11-26 09:00 UTC) or when Trick uses his reset coupon.
- 2026-11-23 18:15 UTC: **Several sessions at once is finished and TestFlight has 0.2 (229).**
  After the weekly figures were reset on 2026-11-22 (Trick's coupon) the chain ran to the end;
  every step was built by an Opus agent, checked by a second agent that committed and pushed,
  and steps 10 to 12 and the corrections of lifecycle code were read by the session model
  before the push (entries in `docs/MAC.md`): `9fe969a` step 5c (a row with its swipe open is
  left alone by every refresh; his phone had shown it sliding in and out once a second, and the
  swipe's Delete aborted the app), `72de822` step 10 (a host tap is always a new session, the
  "+", taps wait for a park), `7fdf526` step 11 (the launch opens the session looked at last),
  `4125b39` step 11b, `0e7d461` step 12 (End Session on a parked row through mosh), `9a11c6f`
  step 13 (the port range message), `d7e2dda` step 13b (a session row says when it started:
  BRIEF item 11, asked by Trick after trying build 220), `52eaeea` step 13c (async unit tests
  run on the main actor: off it XCTest dropped failures recorded after an await, so fourteen
  tests could pass with broken code), `7798a7a` step 14 (docs; refused three times for the
  "End Session" text of `docs/RESUME.md`, which now lists the stages and four outcomes and says
  that the rarer ones are not listed). Suite: 173 unit tests, 88 UI tests, 0 failures.
  Release: `a489f08` sets the version to 0.2 (`App/Local.xcconfig`), adds `CHANGELOG.md`, and
  makes the upload wait for processing and set "What to Test" from the changelog's section;
  an independent check read the lane against pilot's source and the changelog against the
  app, then uploaded: "Successfully finished processing the build 0.2 - 229", "Successfully
  set the changelog for build" (`20cb562`). Nothing was created, deleted or distributed anew
  in his Apple account. The text could not be read back from App Store Connect: Trick checks.
  On his phone: TestFlight app as he updates it; Dev app build 220 (installed on his word on
  2026-11-23 02:10 UTC); Dev build 228 made, not installed.
  Open: design question 10.2; a notice when `hg` does not confirm an End Session (step 12's
  review, should fix); clean-ups step 13c handed over; the simulator sometimes loses a Command
  key (one test failed once in a whole run and passed alone). Usage at 18:10 UTC: week 80%.
- 2026-11-24 08:10 UTC: **The listing is filled, the app carries its licences, TestFlight has
  0.2.1 (237), and the tree is redacted for publication.** On Trick's word of 2026-11-24:
  `ce52eba` App Store listing (texts, `SUPPORT.md`, `PRIVACY.md`, 11 screenshots with demo
  data from `StoreScreenshots.swift`), uploaded with fastlane deliver and not submitted; three
  audits for going public in `docs/notes/publication/` (no secret in any commit; the working
  logs described his network; the licence review's six gaps). `0c9614c` removes the map of his
  network from the tracked files (placeholders; `redaction.md`), after one hostile audit and a
  second pass; the history is not rewritten, so the public repository will be a fresh history
  of the tree, audited once more before it is made public, on his word. `c65b342` ships the
  GPL text, `COPYING.iOS` (mosh's statement and his own section 7 permission, which he was
  shown) and the licences and notices of the twelve pinned packages under About, names the
  copyright holders, puts headers on the ported files and makes the upload refuse a dirty tree
  or other package versions. `698cf4b` adds the privacy manifest and page and keeps the bars
  over the terminal readable in light mode. Suite: 180 unit tests, 95 UI tests (one skipped),
  0 failures; Linux 768, 0 failures. `1ea56fc` is 0.2.1 with its changelog section;
  `scripts/deploy.sh --testflight` reported "Successfully finished processing the build 0.2.1
  - 237" and "Successfully set the changelog for build". Tags `v0.2.1-237` and `v0.2-229`.
  The release step was done by the main session without a second agent (usage: week 93%).
  Open: his clicks in App Store Connect; the public copy and its audit; the first build cut
  from the public repository; the theme "System" staying dark in light mode.
- 2026-11-25 01:55 UTC: **The repository is public and TestFlight has 0.2.2 (242), built from
  it.** On Trick's word ("hit it, finish the work"; "Slam it"): the final audit of the tree took
  four passes (corrections `4c1935f`, `ea67bb3`, `c9c45d4`, `fe86ef5` in the history that is not
  published): the first pass found ten things left and stopped at the weekly usage limit; after
  his reset two readers went line by line through everything it had not reached; the last look
  was clean, and the sweep for the 410 known real values found none in the 683 tracked files.
  Then: a root commit of that tree (`5131915`), the old repository renamed and kept private
  with the whole history and the old tags, a new `trickv/ios-mosh` created, pushed and made
  public. A pre-push hook in the working checkout refuses to push to the public repository
  anything that does not descend only from the root commit (tested with the old branch).
  `171c963` is release 0.2.2: the same app as 0.2.1, from the public source, with the build
  number continued by an offset on the commit count; "Successfully finished processing the
  build 0.2.2 - 242", "Successfully set the changelog for build"; tag `v0.2.2-242`. The
  listing lane now sends the support and privacy links and the version: "Successfully set the
  version to '0.2.2'", nothing submitted.
  From here every push is public: keep to `docs/notes/publication/redaction.md`.
  Left with Trick: his entries in App Store Connect (App Privacy, age rating, content rights,
  price and availability, attach build 242, Submit); the usage lines for the new week.

## After the rounds (from 2026-11-15)

The cloud session now works beside the session on charlie (`docs/MAC.md`). It owns
`Sources/` except `NWDatagramTransport.swift`, the package tests, `moshcli`,
`scripts/killloop.sh` and `scripts/itest.sh`; charlie owns `App/` and the Mac and phone
scripts. Both commit straight to `main`. The cloud session cannot read usage and cannot
be woken by a schedule any more; charlie cannot message it. It reads charlie's log and
transcript, and asks charlie for a usage reading before each start (rule in `CLAUDE.md`:
never cross 40% of a 5-hour session; one cloud agent at a time).

- 2026-11-15 14:30 UTC: Linux check of `main` at c20d16d, after the Mac session's changes
  to shared code that had only been built on Apple platforms. No fix was needed.
  `scripts/dev.sh swift test -j 4`: "Executed 677 tests, with 34 tests skipped and 0
  failures" (33 sshd tests, and one permission test that cannot run as root;
  `NWDatagramTransportTests` compiles only on macOS). `ITEST_NO_CONTAINER=1
  scripts/itest.sh all` exits 0 (netem-soak skipped). `scripts/itest.sh killloop 260
  --long` passes: 260 kills, 203 resumes, 57 fallbacks, 521 lines exactly once, 127
  screens equal, 132 crash-point kills, no number reused, no server aborted.
- 2026-11-15 14:36 UTC: `336da89` tmux copies through mosh-server settled
  (`docs/SERVER-SETUP.md`, `scripts/osc52-check.sh`). The fix is on the host, because
  mosh-server drops what it does not accept before any client sees it:
  `set -s set-clipboard on` and
  `set -as terminal-overrides ',xterm*:Ms=\E]52;c;%?%{0}%t%p1%s%;%p2%s\a'`. Proved end to
  end with stock `mosh-client` and with `moshcli` for copy mode, `set-buffer -w`, a
  program inside tmux, and neovim 0.10.4 and 0.11.5. Largest copy about 12 KB. To do: the
  tmux and neovim lines in `docs/PLAN.md` section 5 are wrong and should be replaced by
  these (the Help page in the app is in charlie's queue).
- 2026-11-15 14:59 UTC: `f155519` design for resume stage 2 (M9),
  `docs/notes/stage2/DESIGN.md`. Its section 12 has 13 steps; steps 1 to 8 change nothing
  the app uses, step 9 is the switch (one commit for package and app). Its section 15 has
  four questions for Trick and three things only the phone can answer.
- 2026-11-16 03:05 UTC: Trick set the usage cap at 40% of a 5-hour session (`76a57c7`).
  Reading on charlie at 02:51 UTC: session 15%, week (all models) 65%, week (Fable) 95%,
  weekly reset 2026-11-19 09:00 UTC. Because of the Fable figure, a hostile review of the
  design (started on Opus) and M10 (local echo, started on Opus) were both stopped after a
  few minutes with nothing written, and charlie's queue was stopped before its first
  change. Nothing is running. **Next, in this order, each only after a usage reading
  under 25%:** (1) hostile review of `docs/notes/stage2/DESIGN.md` into
  `docs/notes/stage2/REVIEW.md` (Opus now; a second review on the session model of steps
  3 and 9 after the weekly reset); (2) M10, local echo: port of mosh's
  `terminaloverlay.cc` with differential tests against mosh's own engine through
  `Tools/mosh-oracle`, `moshcli --predict` and a client-side delay, `scripts/itest.sh
  predict`; (3) stage 2 steps 1, 2, 5 and 7, then 3 and 4, 6, 8 as the review allows.
  Charlie's queue (in its transcript, 02:50 UTC): the shutdown-timeout fix, the Help
  text, step 0 of stage 2, one combined phone checklist. Waiting for Trick: the bundled
  font, one sitting with the phone, the four questions of the design.
- 2026-11-18 22:15 UTC, **yellow is back.** A session on yellow has taken over what the cloud
  session owned; the cloud session is retired (its transcript cannot be read from yellow, so this
  log is the hand-over). `main` at `7980166` builds in the dev container (Swift 6.2.4, mosh-server
  1.4.0). **The suite is red on yellow:** `scripts/dev.sh swift test -j 4` gives "Executed 677
  tests, with 33 tests skipped and 9 failures" (8 test cases; a first run had 7 failures; whole
  log in `out/yellow/suite.log`): `SessionIntegrationTests` (3), `ResumeEndToEndTests` (2),
  `ResumeCoordinatorServerTests` (2) and `GuardTests.testAResumeFromAStaleSnapshotKillsTheServer`
  (which passed when the class ran alone later). Each waits 10 s for the output row of the first
  command typed after `start()`. The screen at the failure has the command echoed before the
  shell's prompt and its output on the prompt's row (`$ before-5`): mosh-server starts the shell
  only when the first client state arrives (`mosh-server.cc:593` and `:822`), and the typed
  command travels in that state. Not explained yet: why the same commit was green in the cloud
  and on macOS. A fix of the tests is in work in the worktree `.worktrees/green`, with an
  independent check before it lands; nothing under `Sources/` is changed.
  **Needs yellow, done:** `scripts/netem.sh 10`: PASS (603 s, 242 of 242 markers, latency p50
  446 ms and max 2302 ms, 1183 datagrams sent, 544 retransmits, sequence numbers strictly
  increasing, final screen equal to `tmux capture-pane -p`). `scripts/netem.sh 3 --rebind-every
  20`: PASS (182 s, 73 of 73 markers, 8 socket replacements, screen equal). The long kill loop
  with the capture, as root in the container (`scripts/dev.sh --root`, the build as uid 1000
  first, `MOSHCLI` set, `scripts/killloop.sh 260 --long --no-guards`; the guard tests apart with
  `scripts/dev.sh swift test --filter GuardTests`: 4 tests, 0 failures): "killloop: PASS", 116
  sessions, 2041 sequence numbers, none twice; `tcpdump`: 1952 client datagrams to 116 servers,
  no number twice per server, all of them in the logs. `sch_netem` loads by itself in the
  container on yellow. **Still open:** the kill loop under `tc netem` (running; a first try
  failed at once with "build database is locked": two builds at the same time in one checkout
  do not wait for each other).
  Also done: `288d2b0`, the hostile review of the stage 2 design,
  `docs/notes/stage2/REVIEW.md`: 13 findings, 0 critical, 4 major (R2-1 a given-up record is not
  final; R2-2 `record` on a stage 1 record that is not converted yet; R2-3 nothing checks that
  the boot identifier changes at a reboot; R2-4 the first checkpoint of `journal.1` is built
  apart from the core's first state), 4 minor (among them R2-8: step 6 needs the hostile review
  as steps 3 and 9 do), 5 doc. Not refuted yet, and the design is not changed yet.
  Usage at 22:00 UTC: session 23%, week 76%, week (Fable) 98%; the week resets 2026-11-19 09:00
  UTC. Next: the suite green on yellow; the groundwork for M10 in `docs/notes/m10/` (maps of
  mosh's prediction engine, of our seams and of the test tools, then a design with a critique);
  after the weekly reset the refutation of the review and the second review of steps 3, 6 and 9
  on the session model.
- 2026-11-18 23:45 UTC: **The suite is green on yellow.** `7e84dd4` (tests only: 116 lines
  added, none removed). The cause was a race in the tests, nothing under `Sources/`. `start()`
  sends the first datagram at once with the Resize alone (measured: 1 ms), and that makes
  mosh-server start `/bin/sh`; the first typed line follows 22 to 30 ms later and races dash's
  start-up. When the line wins, the tty echoes it before the prompt and the output lands on the
  prompt's row (`$ before-5`), so a check for a row that is exactly the output fails. The guess
  of the entry above, that the line travels in the first datagram, was wrong. Measured in the dev
  container: input 0 to 2 ms after the release gives typeahead in 20 of 20 runs, from 5 ms on
  the prompt comes first; a session on an idle machine 0 of 16, with 24 busy loops 5 of 8 at
  80x24 and 1 of 8 at 100x30. Why the cloud and macOS were green is inference (load and the
  speed of an exec there; `/bin/sh` on macOS is bash, whose line editing prints typeahead again
  after the prompt). The fix: `Tests/MoshTestSupport/ShellPrompt.swift`, a wait for the prompt
  before the first typed line in every test that types into a fresh server (nine files), and the
  new `SessionIntegrationTests.testACommandTypedBeforeThePromptRunsOnce` (typed at once: it runs
  exactly once, its output is on the screen, no problem event). `scripts/dev.sh swift test -j 4`
  on the fix: "Executed 678 tests, with 33 tests skipped and 0 failures"; the four classes 10 of
  10 green and 3 of 3 under load. A second agent, told to refute it, re-ran them 5 of 5, found
  no assertion weakened and no defect hidden, and landed the commit. `main` differs from the
  tested tree only in docs. Logs: `out/yellow/green/`. Open: `test_hello` in
  `scripts/itest-mosh.sh` (lines 92-93) types at once and wants exact rows: the same race, not
  fixed yet.
  **Kill loop under `tc netem`: fails as the script is today** (first try, root in the
  container, the qdisc added after the build). With `loss 20%` alone 93 iterations passed and
  iteration 94 failed "the client's screen differs from tmux capture-pane -p"; with the soak's
  loss, delay and reordering the same check failed at iteration 2 (the client still showed the
  other tmux window). The script takes the screen 500 ms after the last state, which proves
  nothing under loss: it leaves that check out for its own `--loss` iterations, and the soak
  waits 3 s under netem. Not shown yet: that the client's screen catches up when it gets the
  time. Next: a netem mode for the kill loop (the settle time of the soak, with its reason),
  then the run. Logs: `out/yellow/keep-loss20`, `out/yellow/keep-full`.
  **M10 groundwork**, `a8067ec`, `docs/notes/m10/`: `mosh-prediction.md` (mosh's engine line by
  line, 25 quirks to reproduce), `seams.md`, `test-tools.md`, and `DESIGN.md` (10 steps:
  `PredictionEngine` as a struct in `MoshTerminal`, wired by `MoshSession`, a new event
  `.display`, a predict mode in `Tools/mosh-oracle` that links `terminaloverlay.o` with its own
  `Network::timestamp`, a seeded differential fuzz, `moshcli --predict` and `--delay-ms`,
  `scripts/itest.sh predict`). Two critiques (`critique-fidelity.md`,
  `critique-architecture.md`) gave 24 findings; both found alone the critical one: a server state
  that changes only the echo ack would have wiped the pending guesses from the app's screen. The
  revision accepted all 24 ("Review status" at the end of the design). Six deliberate deviations
  from mosh (D1 to D6) and five questions for Trick (section 9.2) are in the design. No Swift
  code yet, and the revised design has not had a second independent look.
  Usage at 23:40 UTC: session 20% (resets 03:39 UTC), week 80%, week (Fable) 100%; the week
  resets 2026-11-19 08:59 UTC. The nine Opus agents of this round (1.57 M tokens) took the week
  from 76% to 80%. Nothing more is started before the weekly reset: the proposed weekly cap of
  85% counts as the limit until Trick decides. **Next, after the reset:** (1) on the session
  model: the refutation of `docs/notes/stage2/REVIEW.md` and the second review of steps 3, 6
  and 9, then the changes to the design; (2) on Opus: a second look at the revised M10 design,
  then its steps from 1 on; (3) tooling: the kill loop's netem mode and `test_hello`;
  (4) charlie's queue (`docs/MAC.md`), started from yellow.
- 2026-11-19 10:15 UTC: first round after the weekly reset (week 3%). `42c4d11`
  `docs/notes/stage2/REFUTATION.md`: none of the 13 review findings refuted (R2-1 lowered to
  minor, R2-3's severity open until the phone probe), and a second review of steps 3, 6 and 9
  with five new findings (S-1 major: a shutdown before a successful start leaves a record that
  replays a stale journal). `38a9d56`: all 18 closed in the text of `DESIGN.md` (rule J14
  "armed", J15 "dead is final", the first journal written from the session's own state, the
  boot identifier checked at every read); steps 3, 6 and 9 are marked for hostile review; two
  new questions for Trick in its section 15, and one cost he has not confirmed (a background
  before `start()` after a cold start no longer seals). The amended text has had no independent
  look. `02dfdc5`: `test_hello` waits for the prompt; `scripts/itest.sh hello` 5 of 5.
  `6cf5f49`: **the kill loop passes under `tc netem`** with `scripts/netem.sh --killloop`. The
  client was behind, not wrong: of 20 screens taken 500 ms after the last state 2 differed, all
  20 taken 7 s later were equal (a lost state is resent only after up to 1100 ms). New settings
  `KILLLOOP_CATCHUP_MS` and `KILLLOOP_LIVENESS_MS`, reasons from the mosh source in the script;
  the run without netem is unchanged. `260 --long` with the soak's spec and with `loss 20%`:
  "killloop: PASS" both, 203 resumes, 57 fallbacks, 521 lines exactly once, 127 screens equal,
  tcpdump 2222 and 2130 client datagrams to 116 servers with no number twice. `docs/RESUME.md`
  has the row. Everything the cloud log marked "needs yellow" is now done. Next: M10, a second
  look at the revised design and then its steps; charlie's queue.
- 2026-11-19 12:45 UTC: **M10 steps 1 to 5 of 10 done** (`docs/notes/m10/DESIGN.md`, progress
  entries per step there). A second look at the revised design found all 24 findings closed and
  fixed two details (thresholds are `UInt64` as in mosh; the oracle's `shown` dump uses its own
  size). `9f55ea1` the oracle's predict mode (`corpus-check.sh` still 38 cases); `b9578e5`,
  `4c99b11` the engine in `MoshTerminal`; `8238e13` the differential test against mosh's own
  engine: no difference found, the engine needed no change, a run of 2000 cases by hand passed
  (1193 s, every coverage counter above zero), and two slips put in on purpose were caught;
  `19c7612` the transport's readings. `scripts/dev.sh swift test -j 4` after step 5: "Executed
  751 tests, with 33 tests skipped and 0 failures". In the suite the fuzz runs 100 cases, not the
  design's 200 (time). **Stopped before step 6** (the wiring in `MoshSession` and the event
  `.display`): it needs one line in `App/IOSMosh/TerminalViewController.swift` (`case .display:
  break`) or the app's switch does not compile, so it is one commit for package and app with a
  `scripts/mac.sh` build first; and usage was at 29%. Next: step 6 with that app line, then 7
  to 10; charlie's queue.
- 2026-11-19 16:00 UTC: **M10 steps 6 to 9 of 10 done** (progress entries in
  `docs/notes/m10/DESIGN.md`). `ed18287` the wiring in `MoshSession`: the engine is fed as
  stmclient feeds it, the overlaid frame goes out as the new event `.display`, nothing
  predicted reaches `.screen`, `screen()` or a snapshot; `PredictionWiringTests` (12) against a
  real `mosh-server`. The one line `case .display: break` went into
  `App/IOSMosh/TerminalViewController.swift` in the same commit, after `scripts/mac.sh
  scripts/sim-test.sh -only-testing:IOSMoshTests` built the app (79 tests, 0 failures).
  `a1bf9cd` `ResumeCoordinator.Options.prediction` and `setPrediction` (not in the record; app
  build checked again). `9e338fb` moshcli `--predict`, `--predict-overwrite`, `--delay-ms` and
  five script commands; `scripts/itest.sh predict` (parts a-f) PASS twice, `script` unchanged.
  Suite after step 8: "Executed 766 tests, with 33 tests skipped and 0 failures". Step 9 is
  this entry and the M10 text and verification rows in `docs/PLAN.md`. **Left: step 10, the
  app on charlie** (`DESIGN.md` section 5): pass the user's setting in `Options.prediction`
  at every `create` and `coldStart` and call `setPrediction` on a change; draw only `.display`
  frames while the mode is not `never`; a per-host "Local echo" setting; check that a paste
  reaches `type` as one array; then the phone check with `scripts/netem.sh` delay on yellow.
- 2026-11-19 23:35 UTC: **M10 is complete on the simulator, and charlie's queue is done**, all
  from yellow through `scripts/mac.sh` (entries per unit in `docs/MAC.md` section 5). Core:
  `ed18287` the wiring in `MoshSession` and the event `.display`, `a1bf9cd` the setting
  through `ResumeCoordinator` (not stored in the record), `9e338fb` `moshcli --predict`,
  `--delay-ms` and `scripts/itest.sh predict`, `f05eb4b` the plan; `scripts/dev.sh swift test
  -j 4`: "Executed 766 tests, with 33 tests skipped and 0 failures". App, each unit checked by
  a second agent before the push where it changed behaviour: `3838564` a shutdown that is not
  answered keeps the record "ended" (it was forgotten and the server left running); `c9a10da`
  local echo drawn in the app with a per-host setting; `48a2801` the Help page with the proved
  tmux and neovim lines (PLAN.md section 5 corrected too); `135ad00` step 0 of stage 2 (the
  probe reads `kern.bootsessionuuid` with the checks of design section 8; the app's switches
  no longer name `.dirty`); `2a9ed17` one phone sitting prepared (11 steps, 46 minutes, one
  restart) with a debug probe for stage 2's device figures. Closing check `fe737cc`: whole
  `scripts/sim-test.sh` "Executed 111 tests, with 0 failures" and "Executed 44 tests, with 0
  failures", device build "159 2a9ed17 built", nothing installed or launched on the phone.
  Seen once and not again: `KeyBarUITests.testKeysArriveAsTheRightBytes` (a stray `~` before
  Page Up).
  **Trick's decisions today** (also in `CLAUDE.md`): local echo default Adaptive, per host,
  the app offers Adaptive, Always and Never, guesses are kept across the background; follow
  mosh's defaults in general; usage limit 60% of a 5-hour window (start nothing at 45%, agents
  stop at 50%) and 85% of the week; the phone stays simulator-only until he says so; the
  bundled font is Hack Nerd Font; headless Claude runs on charlie are allowed; no colima.
  Open requests for the core: an option of `scripts/netem.sh` that puts the qdisc on a named
  container (for the phone check of local echo). Next: the bundled font; an independent look
  at the amended stage 2 design, then its steps from 1 on; the phone sitting when Trick is
  ready.
- 2026-11-20 00:05 UTC: **Resume stage 2 (M9) is shelved by Trick.** His question: how would
  the app be killed while the user types? Stage 1 saves at every trip off the screen, which
  covers the kills that happen (background, force-quit, restart); stage 2 adds only a death on
  screen (a crash of the app, a foreground memory kill, an install over the running app), and
  there the app reconnects in 2 to 3 seconds and the start command `tmux new -A -s main` lands
  in the same tmux. The plan had it under "Later, if wanted". The design, review, refutation
  and the amended text stay in `docs/notes/stage2/`; step 0 (the boot identifier in the debug
  probe, `135ad00`) stays and is read in the phone sitting. His answers for the day it is
  built after all: a resume after a kill is noted in the debug log only; no downgrade safety;
  an untrusted boot identifier simply means the fallback. Not answered: the 30 s of typed keys
  in the journal, and the cost of rule J14 (a background before `start()` no longer seals).
  Other answers: guesses are kept across the background (as built); the bundled font is Hack
  Nerd Font (in work, simulator only); headless Claude runs on charlie are allowed; no colima.
  Next: the font; then the project waits for the phone sitting (`docs/MAC.md` section 3, 46
  minutes with Trick). Small open items: `scripts/netem.sh` for a named container (phone check
  of local echo), the one-off `KeyBarUITests` failure, an exhaustive switch in
  `SessionEnding.after`.
- 2026-11-20 00:50 UTC: the bundled font is in (`b4653a0`, `266acb4`, `590f821`; entry in
  `docs/MAC.md`): Hack Nerd Font Mono 3.003 from Nerd Fonts v3.5.1, four faces unchanged with
  their hashes and 18 licence texts in `App/Fonts`, shown at the end of About. A second agent
  downloaded the release again and found the same hashes before the push. Whole simulator suite:
  "Executed 116 tests, with 0 failures" and "Executed 45 tests, with 0 failures"; device build
  "163 b4653a0 built", not installed. No existing test had to change. The commit adds about
  6.6 MB packed. Two UI tests have now failed once each and passed on the rerun:
  `KeyBarUITests.testKeysArriveAsTheRightBytes` (a stray `~` before Page Up) and
  `ResumeUITests.testASecondResumeGenerationKeepsTheSameServer` (`screenText` missing after the
  first relaunch). Neither is explained: to be looked at before the phone sitting.
- 2026-11-20 06:50 UTC: **A real resume fault found and fixed in the app; first build on the
  phone since 117.** Two UI tests had failed once each. `ResumeUITests.
  testASecondResumeGenerationKeepsTheSameServer`: the app's own log of the failing run showed
  "background, saved: clean", 0.8 s later a resize (iOS laid the view out again and the app
  sent it to the session in the background), which made the record dirty and saved it again;
  the kill fell into that window and the next start was the fallback. 10 of 126 saves in that
  log were followed by such a resize. `6145d34`: the app holds a size change while the scene is
  not active and announces it at `sceneDidBecomeActive`; a new UI test of the mechanism failed
  3 of 3 before. The natural rate of the original test was not measured. Nothing under
  `Sources/` changed: the core did what it is designed to do with input in the background.
  `KeyBarUITests.testKeysArriveAsTheRightBytes`: a race in the test (XCUITest's 33 ms swipe
  arrived as a tap on a key; 2 of 15 before), fixed in the test (`5b76502`). A first check
  refused the work because the new failure diagnostics kept the launch arguments of the test
  app, with the session key of a throwaway loopback server, in files under `out/` and in the
  Mac's result bundle (never committed or pushed). `883170d`: no argument of any process is
  kept, and a key check fails the run; the kept files were deleted and two scans found none.
  `047028a`, `116fbcc`, `d7c3a0e`; entries in `docs/MAC.md`. Whole simulator suite: "Executed
  118 tests, with 0 failures" and "Executed 47 tests, with 0 failures"; device build "173
  116fbcc built", not installed.
  **Phone:** on Trick's word build 163 (`b4653a0`, without the fix above) was installed at
  03:13 UTC, without a launch; an install needs the phone unlocked. His screenshot shows a
  session to a real host of his with that build: SSH login, mosh, input, colours, key bar.
  Seen in it: the text starts flush at the left edge (no inset). He plans the prepared
  sitting for 2026-11-20. TestFlight: skipped for now. Release build for daily use: later.
  Next before the sitting: take the stage 2 steps out of the checklist, the debug-argument
  trap of review M6-11, the exhaustive switch in `SessionEnding.after`.
- 2026-11-21 02:45 UTC: **The phone sitting** (02:06-02:41 UTC, builds 182 `ce86080` and 183
  `1d47a30`; full entry and the way to drive the phone from yellow in `docs/MAC.md`). Save while
  locked ok on 183; resumed with the same screen after force-quit, an install over it and a
  phone restart; a kill on screen fell back with the banner and a new session in 1.67 s; local
  echo Adaptive instant with a fading underline and Never lagging on a 300 ms link; the app
  cannot read `kern.bootsessionuuid` (errno 1). The phone ends on build 183. Open, first: **the
  app never learns the server's pid on Trick's host.** All 13 bootstraps in the phone's log
  (`out/yellow/sitting/debug-final.log`) say "MOSH CONNECT port N on ..., pid ?"; so the
  fallback at 02:19:22 stopped nothing (no line about the old server) and `pgrep -a mosh-server`
  there (`out/phone/sitting-pgrep.png`) showed 4926, next to the old shell 4927
  (`sitting-step8a.png`), beside the current 5639 (shell 5640). The host runs an old Debian (its release
  and kernel, seen in the sitting, not in a kept log, were removed before publication), whose
  package is mosh 1.2.x (the installed version was not read). On the simulator's
  sshd and in the Linux tests (1.4.0) the pid is found. Likely cause, not yet checked against the
  app: in 1.4.0 the parent prints `[mosh-server detached, pid = N]` before it exits
  (`src/frontend/mosh-server.cc:454-464`, tag mosh-1.4.0); in the 1.2 release that host's distribution packages, the parent `_exit(0)`s right
  after the fork and only the child prints that line (`src/frontend/mosh-server.cc` at that release's tag,
  in `out/yellow/refs/`), so it can arrive after the command has exited, when the bootstrap may
  have stopped reading. Without the pid, the fallback, "End Session" and the server probe cannot
  act on that host. Also open: M8 (step 2), Trick's checks by hand (step 6, he reports), a killed
  server noticed (step 10), Local echo Always and `read -s`.
- 2026-11-21 02:55 UTC: after the sitting Trick did the checks by hand on build 183 and reported:
  the powerline triangles show (the bundled font is loaded), the text needs no margin at the
  left edge, the key bar is good, copy and paste are fine, selection with tmux mouse mode is
  good, the settings look good. On the server pid he said: "im not concerned about mosh-server
  cleanup; this is just an artifact of mosh architecture." So the work on finding the pid on
  hosts like his (started as a workflow right after the sitting) was stopped before its
  investigation finished; nothing of it is committed. What the missing pid still means on such
  a host, for the record: a fallback and "End Session" leave the old mosh-server running, and
  the app cannot tell a dead server from a lost network, so it waits with "Last contact" as
  mosh-client does. Not to be picked up again unless he asks.
- 2026-11-21 03:05 UTC: Trick added a second host on the phone
  (build 183), tried the app's password login and "Install my key" against it, and reported that
  "Install my key" worked perfectly. The app's log has the whole path, which no automated test
  covers: the host key trusted, the device's key rejected (the password prompt), "bootstrap: key
  install: added", a first connection with the server's pid, and the next connection logged in
  with the device's key [the log lines with that host's details removed for publication]. So the
  key install and the key login after it work on a real host. And on this second host the
  server's pid IS found, while the
  two bootstraps to the first host in the same log (02:46, 02:50) still say "pid ?": the missing
  pid belongs to the first host's old mosh-server, as guessed, not to real hosts in general.
- 2026-11-21 03:45 UTC: **First TestFlight upload.** Trick created the app record ("iOS-Mosh");
  `scripts/mac.sh --no-sync scripts/mac-testflight.sh record`: "app record exists: iOS-Mosh";
  `scripts/deploy.sh --testflight` at `91942c0`: "Successfully uploaded the new binary to App
  Store Connect", "uploaded 0.1 (189)", 2 min 13 s, ipa 14.2 MB. Not done: the tester group
  (waits for his word) and the export compliance answer (his). The facts given to him for that
  answer: mosh traffic is AES-128 in OCB mode (RFC 7253), the mode in the app's own code and the
  AES block from CommonCrypto; the SSH login is swift-nio-ssh with swift-crypto and an Ed25519
  device key; nothing proprietary. He would like fastlane to run in GitHub Actions later.
  Also `9b4e1ca` (pushed with `91942c0`): the Local echo rows of the host editor no longer jump
  between the left margin and the centre (they were buttons whose checkmark was the image; now
  `OptionRow`); a UI test compares their positions; device build 188, not installed.
  And `docs/notes/multi-session/BRIEF.md`: what Trick approved for several sessions at once (his
  single-screen layout, parked sessions); the design round is scheduled for 06:33 UTC.
  **charlie:** Trick started a Command Line Tools update at about 03:40 UTC; right after the
  upload `xcodebuild -checkFirstLaunchStatus` exits 69, so simulator and device work may fail
  until he runs `sudo xcodebuild -runFirstLaunch` there. Check it before any simulator run.
- 2026-11-21 04:15 UTC: Trick answered export compliance ("exempt, no documentation needed") and
  set up the testers himself, and installed the TestFlight build 0.1 (189) on his phone; it
  replaced the debug build. He ran `sudo xcodebuild -runFirstLaunch` on charlie: first-launch
  status 0 at 04:08 UTC, simulators and the phone listed. His idea, approved in a dialog: debug
  builds become a separate app "iOS-mosh Dev" (`us.v9n.ios-mosh.dev`), fully separate (own
  hosts, own SSH key), and the app declares `ITSAppUsesNonExemptEncryption` = NO. Until that
  exists nothing can be tested on the phone without replacing his TestFlight app, so it is the
  first unit of the next round (06:33 UTC), before the design round for several sessions.
- 2026-11-21 07:12 UTC: **The debug build is its own app now, and it is on the phone beside the
  TestFlight app.** `7393bf2`, `14ba5a4` (entry in `docs/MAC.md`, "Two apps" in `docs/BUILD.md`):
  Debug is "iOS-mosh Dev", `us.v9n.ios-mosh.dev`; Release stays "iOS-mosh", `us.v9n.ios-mosh`;
  `ITSAppUsesNonExemptEncryption` is false in both. Made in Trick's Apple account by
  `scripts/mac.sh scripts/mac-signing-setup.sh devapp`: the App ID "IOSMoshDev" and the
  development profile "ios-mosh-dev-app" (existing certificate, the one registered phone);
  nothing else created, nothing deleted. `scripts/mac-deploy.sh`, the spawner and
  `scripts/sim-test.sh` name the `.dev` id, so an install or launch from here cannot hit the
  TestFlight app. A second agent read both products on charlie before the push (device build:
  `.dev`, profile `ios-mosh-dev-app`; Release archive: old id, `ios-mosh-appstore`; no upload).
  Then, from a clean worktree: "us.v9n.ios-mosh.dev 193 14ba5a4 built" and installed at 07:10
  UTC; `devicectl` lists "iOS-mosh 0.1 189" and "iOS-mosh Dev 0.1 193" on the phone. The Dev
  app starts empty: it needs its own test host and "Install my key".
  **The simulator suite is not green in today's environment:**
  `ResumeUITests.testASizeChangeInTheBackgroundLeavesTheSavedRecordClean` fails every time ("no
  row starts with size-"), also on the unchanged `b5aec27`: the simulator no longer turns to
  landscape while the app is in the background, so the test's size change never happens. It
  passed at 03:29 UTC, before the Command Line Tools update and `xcodebuild -runFirstLaunch` on
  charlie. The test has to make its size change another way; first unit of the next window,
  before any step of the several-sessions build. The other 47 UI tests and 120 unit tests pass.
