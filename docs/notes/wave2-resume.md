# NOTES (wave 2, MoshResume part 1: record format, store, file-backed gate; cloud round 6)

Later rounds changed some of what these notes say (cloud round 9, the review fixes; see
`docs/notes/review-resume/refutation.md`, "Status", and `docs/RESUME.md`): the clean mark is
one internal call with the snapshot id and the token (`snapshotStored(id:)` is gone), a gate
and a lock are made by `SessionRecord` only, the backup exclusion and the iOS file protection
are set by the package (`RecordProtection`), a record is made once, and a given-up record says
"dirty", not "ended".

First bounded part of work item 4 (`docs/CLOUD.md`). Done: the record format, the store, the
file-backed `DurabilityGate`, their tests, an end-to-end test against a real mosh-server, and
`docs/RESUME.md` (invariants with code and test, the format byte by byte). Not started: the
coordinator, `moshcli resume`, `--crashpoint`, `SIGUSR1`, `scripts/killloop.sh`, the stage 1
table.

## Commits

- `b0a767d` Add the session record format
- `91363a1` Add the session store and the file-backed gate
- `611ca1b` Test a session resumed from its record against a real server
- then `docs/RESUME.md` and these notes

`scripts/dev.sh swift test -j 4`: "Executed 608 tests, with 33 tests skipped and 0 failures"
(543 before, minus the placeholder, plus 66 in `MoshResumeTests`; the 33 skipped are still the
sshd tests). `MoshResumeTests` alone takes about 16 s, most of it the corpus reload test (5 s)
and the crash tests (7 s).

## Public API (short)

    // New session
    let meta = SessionMeta(createdAt:, hostName:, address:, port:, user:, remoteCommand:,
                           serverStartSize:, serverPID:, serverStartTime:)      // id: random
    let record = try SessionRecord.create(root: root, meta: meta, key: key)     // key nil on iOS
    let session = try MoshSession(endpoint: meta.endpoint(key: key), ..., gate: record.gate)

    // Leaving the foreground
    await session.quiesce()
    let clean = try record.save(try await session.exportState())   // false: stays dirty

    // Cold start
    let record = try SessionRecord.open(root: root, id: id)        // RecordError.locked / .missing
    let snapshot = try record.loadSnapshot()                       // throws unless clean for it
    let session = try MoshSession(restoring: snapshot, endpoint: record.meta.endpoint(key: try record.readKey()),
                                  gate: record.gate, currentSize: size)
    try record.gate.beginSending()                                 // optional, plan's step 3
    await session.start()

    record.gate.markEnded()      // never resume this record
    record.close(); try record.delete()
    SessionStore.sessionIDs(root:)                                 // what is on disk
    record.state                 // RecordState: .clean(snapshotID:), .dirty, .ended

Errors: `RecordError` (`locked`, `missing(part)`, `notResumable(.dirty | .ended |
.snapshotDoesNotMatch)`, `lockNotHeld`, `closed`), `RecordFormatError(part, reason)`,
`StorageError` (`io(step:errno:)`, and the simulated ones), `FileGateError` (`noSnapshotStored`,
`closed`), `GateError.exhausted`.

Test and tool seam: `StorageHook = (StorageStep) -> StorageHookAction`, passed to
`SessionRecord.create/open(hook:)`. Steps are named `file.operation` (`counters.fsync`,
`snapshot.rename`, `dir.fsync`; list in `docs/RESUME.md`, "Storage steps"). Actions:
`.proceed`, `.crashBefore`, `.crashAfter`, `.tornWrite(bytes:)`, `.fail(errno:bytes:)`.

## Decisions

- **MoshResume is above MoshSession.** `Package.swift` had it the other way round, but the
  snapshot to store is `SessionSnapshot` (`TerminalRemoteState`, `ClipboardPolicy`), which lives
  in MoshSession, and MoshSession used nothing of MoshResume. The coordinator will drive a
  `MoshSession`, so this is also the direction it needs. `MoshTransport` and `MoshTerminal` still
  do not import each other.
- **Two writes per counters change, not one** (the plan says one). Limits and "dirty" go to both
  slots, each with its own fsync, before they are acted on. Reason and cost in
  `docs/RESUME.md`, "Difference from the plan". In short: with one write a slot that goes bad at
  rest hands the record back to the older slot, which has lower limits or says "clean" for a
  stale snapshot. A torn write and later damage look the same to a reader, so the reader cannot
  be the one to tell them apart. "Clean" is one write.
- **The clean mark names the snapshot.** Every snapshot gets a random 64-bit id; "clean" stores
  it; `loadSnapshot` wants the two to match. This catches a snapshot file that is not the one
  the mark was made for (a lost rename, a file put back). `FileBackedGate.markClean` throws
  `noSnapshotStored` unless `snapshotStored(id:)` was called since the last datagram, so the
  protocol's `markClean(ifDatagramsPassed:)` alone cannot make a record clean.
  `SessionRecord.save` does the three calls in order.
- **`meta` is binary, not `meta.json`.** Same frame, checksum and strictness as the other parts.
  `moshcli resume` should print the server pid from it for `killloop.sh`.
- **The key is its own part** (`key`, mode 0600), not inside `meta`, so that iOS can leave it out
  (`SessionRecord.create(key: nil)`) and use the Keychain item the plan describes.
- **A third state, `ended`**, beside clean and dirty: the fallback and "End session" need a mark
  that survives and that a later save cannot undo. An ended record still hands out numbers and
  lets datagrams pass (the shutdown request).
- **Slots 4096 bytes apart**, file 8192 bytes, so the two slots never share a block.
- **Counters that contradict each other kill the record** (generations not consecutive, a newer
  slot with a lower limit, a slot in the other's place): this code never writes that.
- **Rows are stored once** in the snapshot and shared by index. Sharing between lines and
  between states is restored as it was (`testRowSharingIsKept`), with the rows' generations.
- **The pending input is run-length coded** (runs of bytes, resizes): a 262,144-byte paste is
  its bytes plus 9, not two bytes per event.
- **The decoder repeats the import's checks** (ascending state numbers, the acknowledged state
  held, used state counter above `A`, used sequence at most 2^63), so a snapshot that the
  transport would refuse is already refused as a damaged record.
- **`TerminalRemoteState.init(terminal:discardedReplyBytes:echoAckRegressions:)`**: the two
  diagnostic counters are stored too. The only change outside MoshResume.
- **A played crash poisons the storage object**: every later step throws `afterCrash`, so a test
  cannot go on writing with a "dead" process by mistake.
- **A dropped `SessionRecord` closes its gate and releases the lock** (`deinit`). A session that
  still holds the gate then gets `FileGateError.closed` from every call: nothing is sent.

## What the tests show

- Formats: round trips; every byte of `meta`, `key`, a slot and a snapshot damaged (each bit, 0,
  0xFF) is refused, or for a slot the other one is used; every truncation refused; the checks
  behind the checksum; about 6,000 snapshots damaged with the checksum repaired never trap.
- The plan's corpus test: 2,916 instructions with every held state stored and reloaded between
  every pair of diffs end equal to the run that stayed in memory.
- Gate: a script of 19 operations (sends, resends, saves, a stale save, `beginSending`) with
  blocks of 3, 2 and 4 takes 99 storage steps. The crash test kills a process at each
  (before, after, 9 torn lengths for writes: more than 500 first processes), a second process at a random
  step, and checks a third: no number below a limit already used, no snapshot loaded that a
  datagram followed. Two mutations were tried by hand and both were caught: one slot write
  instead of two, and a clean mark that does not reset the "dirty is durable" flag.
- End to end: `ResumeEndToEndTests` (real mosh-server): three lives of one session, same shell
  pid, sequence numbers of the lives logged and strictly increasing; and the stale case.

## Known gaps

- **Not compiled for Apple platforms.** `Storage.swift` uses `open`, `pread`, `pwrite`, `fsync`,
  `fcntl(F_FULLFSYNC)` (under `#if canImport(Darwin)`), `rename`, `flock`, `mkdir`, `unlink`,
  `rmdir`, and `FileManager` for the root directory and the listing. No `Foundation.Process`.
- **iOS attributes are the app's**: file protection "until first unlock" and "excluded from
  backup" are set on the root directory by the app; nothing here sets them. The Keychain key
  store does not exist yet (the `key` file is used on Linux).
- **M9 is open** (`docs/RESUME.md`, "Open requirement for the coordinator").
- **No real power-loss test.** The crash model is: a step happens or not, a write may be cut at
  any length. Reordering of writes inside the kernel, or an fsync that lies, is not modelled.
- **A full disk while a snapshot is replaced** leaves `snapshot.tmp` behind (truncated at the
  next save). `ENOSPC` on the counters is a thrown error; the transport retries every second.
- **`SessionRecord.save` writes the snapshot even when the token is already stale** (the gate
  then refuses the clean mark). Harmless, one wasted write.
- **The lock is `flock`**, which is advisory: only code that takes it is kept out.
- **No migration**: every part has format version 1 and any other version is refused.
- **The snapshot is one file, rewritten whole** at every quiesce (about 15 KB for a full
  screen with eight held states). Fine for stage 1; stage 2's journal replaces it.

## For the next part (coordinator, moshcli resume, crash points, killloop)

- **Cold start order** (plan section 3): `SessionRecord.open` (lock, counters) → `state`: not
  clean → fallback → `loadSnapshot()` → key → `MoshSession(restoring:)` → `gate.beginSending()`
  → `start()`. Call `loadSnapshot` before `beginSending` and before `start`: after either the
  record is dirty and `loadSnapshot` refuses.
- **Everything that throws at open or load is "fallback"**, except `RecordError.locked` (someone
  else is live) and `StorageError.io` (device locked or disk trouble: try again later, never
  "dead"). `SnapshotError.gateBelowSnapshot` and `.usedCountersInvalid` from the import are
  fallback too. On fallback: `markEnded()` if the gate opened, send nothing under the old key,
  then delete the record once the new session exists.
- **A record needs key, counters and meta**; `RecordError.missing` tells which is absent. A
  directory left by a crash while a record was made has no `counters`: delete it.
- **Return to the foreground in the same process** needs no call here: the first datagram
  writes "dirty". (`beginSending()` is for the cold start; calling it there too is harmless.)
- **M9**: decide between a count in `CleanToken` and "the coordinator is the only caller while
  quiesced". With the second, after each `type`/`resize` while quiesced: `exportState()` and
  `record.save` again. A shutdown while quiesced: `markEnded()`.
- **`--crashpoint`**: pass a `StorageHook` that calls `kill(getpid(), SIGKILL)` (in moshcli, not
  in the library) when `step.description` equals the given name, or at the Nth step.
  `--crashpoint list`: the step names are in `docs/RESUME.md`; a dry run with a recording hook
  prints the exact sequence of a quiesce and of a cold start. For a torn write return
  `.tornWrite(bytes:)` and kill at the next hook call, or kill from a second thread; the
  library's own `.tornWrite` throws instead of killing.
- **`--seq-log`** across generations: `LoggingGate` in `ResumeEndToEndTests` is the pattern (wrap
  the record's gate, log `takeSequenceNumber`).
- **Blocks**: tests pass small blocks (`blocks:`) to cross boundaries quickly; the default is
  the plan's 65,536 / 1,024 / 1,024. A resume skips to the next block, so 200 kill-loop rounds
  use 200 x 65,536 sequence numbers at most: far from 2^63.
- **The stage 1 row "Damaged record"**: one torn slot → the other is used (unit tests cover the
  reading; the loop should damage a real file with `dd`); both bad, missing key, missing
  snapshot → `RecordFormatError` / `RecordError.missing` → fallback, no datagram.
- **`ServerProbe` and the identity check** want `meta.serverPID` and `meta.serverStartTime`;
  the bootstrap has to supply them (0 means unknown).


# NOTES (wave 2, MoshResume part 2: coordinator, moshcli resume, kill loop; cloud round 7)

Second part of work item 4. Done: `ResumeCoordinator` (cold start, fallback, the lifecycle
calls, M9), `moshcli resume` with `--crashpoint`, `--step-log`, `SIGUSR1`, the numbers log of
`--seq-log`, `--loss`; `scripts/killloop.sh` and `scripts/itest.sh killloop`; the stage 1
table run and recorded in `docs/RESUME.md` ("Stage 1 results"). Not done: anything under
netem (needs yellow), the app wiring, a compile for Apple platforms.

## Public API (short)

    // New session (the record is made; nothing is sent before start())
    let coordinator = try ResumeCoordinator.create(root:, meta:, key:, storesKey: true, initialSize:, options:)
    try await coordinator.start()
    for await event in coordinator.events { ... }     // SessionEvent, as MoshSession's

    await coordinator.enterBackground()                // SaveOutcome: .clean / .notResumable(reason)
    await coordinator.enterForeground()
    await coordinator.type(bytes); await coordinator.resize(size); await coordinator.shutdown()
    await coordinator.abandon()                        // ended + closed ("Start new session")
    await coordinator.close()                          // record left as it is

    switch ResumeCoordinator.coldStart(root:, id:, key: nil, currentSize:, options:) {
    case .resumed(let coordinator): try await coordinator.start()
    case .fallback(let f):          // f.reason, f.meta, f.recordDeleted, f.wantsNewSession
    case .retryLater(let why):      // .inUse, .storage(text)
    }
    try ResumeCoordinator.deleteRecord(root:, id:)

`Options`: `blocks`, `storageHook`, `configuration`, `clock`, `noReplyTimeout`, `clipboard`,
`makeTransport`, `wrapGate` (moshcli's logging gate). `FileBackedGate.markDirty()` is new.

## Decisions

- **The coordinator is the facade.** The `MoshSession` is private to it. The app (and moshcli
  with a record) calls the coordinator for input and reads `coordinator.events`. That is what
  makes M9 and "an ended session stays ended" hold by construction; a coordinator beside a
  session the app also holds could only hope to be called.
- **M9 by "dirty first, save again"**, not by a change count in `CleanToken`. Reasons in
  `docs/RESUME.md`, "M9: closed". No change to `MoshTransport`.
- **A shutdown always ends the record**, in the foreground too. Otherwise a kill during the
  shutdown exchange left a dirty record, and the fallback would bootstrap a new session for
  one the user had just closed. `FallbackReason.ended` has `wantsNewSession == false`.
- **`start()` does the cold start's counters write**, not `coldStart`. `loadSnapshot` works
  only while the record is clean, so the write has to come after it; and a failure of the
  write must leave something that can be retried (`start()` throws, the record is still clean).
- **A fallback of a record with counters marks it ended and keeps it**; the plan's "delete"
  happens through `deleteRecord` once the new session exists, because `meta` is needed until
  then. A directory that is not a record (no counters, no meta, both slots bad) is deleted in
  `coldStart`, under its lock.
- **Events pass through the coordinator in order with the lifecycle calls** (`inOrder`). An
  event can therefore reach the app late by the length of a save (milliseconds).
- **moshcli deletes the record itself on a fallback** (there is no new session to wait for)
  and prints the old server's pid; `scripts/killloop.sh` kills that server, as the app would.
- **`--crashpoint ...:after` and `:torn=N` let the storage layer play the crash** (the step is
  done or half done, every later step is refused, so no number and no datagram follows) and
  the process kills itself 50 ms later, or at its exit if that comes first. `:before` kills
  inside the hook.
- **Loss without netem**: `moshcli --loss P` drops datagrams in the tap, both directions. To
  the protocol this is a lossy path; it says nothing about delay or reordering.
- **tmux `assume-paste-time 0`** in the kill loop: tmux takes a prefix key that follows other
  keys within a millisecond for pasted text and gives it to the pane. A script types that fast.

## Known gaps

- **Needs yellow**: the loop under `tc netem` (20% loss, delay, reordering), `scripts/netem.sh`.
- **Not compiled for Apple platforms**; `SceneDelegate` wiring, the Keychain key and the
  identity check before killing the old server are the app's (M6 on the Mac).
- **No real power loss**: SIGKILL of the process only. A written step counts as on disk.
- **`setClipboardWriting` in the background** is not saved until the next save (the app holds
  the per-host switch itself).
- **Input refused in the background** (the record cannot be written) is reported as `false`
  and a `.gateFailed` event; the app has to keep or drop the keystrokes itself.
- **`moshcli resume --info` reads without the lock**; it may see a record in mid-change.
- **The kill loop's dirty kills happen after `wait-ack` of the checked line**; the keys typed
  after that (in the shell window) are the ones a kill may or may not deliver.

## For the next part

- The app: `sceneWillResignActive` → `enterBackground()` inside a background task;
  `sceneDidBecomeActive` → `enterForeground()`; launch → `coldStart` for each id in
  `SessionStore.sessionIDs(root:)`; `.fallback` → banner, bootstrap, kill the old server after
  the identity check (`meta.serverPID`, `meta.serverStartTime`), `deleteRecord`.
- The bootstrap has to put the server's pid and start time into `SessionMeta`.
- A review of `MoshResume` on the session model (CLOUD.md item 4's last step) has not been done.
