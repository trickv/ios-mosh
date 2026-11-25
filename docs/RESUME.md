# Resume: invariants and record format

How a mosh session survives the death of its process (stage 1, milestone M6). The design
is in `docs/PLAN.md` section 3; this file says what the code guarantees, where, and which
test checks it, and gives the stored format byte by byte.

Status: the record format, the store, the file-backed gate and the coordinator (cold start,
fallback, the lifecycle calls) exist (`Sources/MoshResume`) and are tested on Linux, with
`moshcli resume`, `--crashpoint` and `scripts/killloop.sh` against the real `mosh-server`
1.4.0. The stage 1 table of the plan has been run where it can run without `tc netem`
("Stage 1 results" below). Finding M9 of the transport review is closed. The code was
reviewed by two hostile reviewers and a refuter (`docs/notes/review-resume/`); the surviving
findings are fixed, and the invariants they changed or added are marked "(review X-n)" below
(R18 to R21, C10 to C13, and changes in R5, R6, R12, R16, C3, C4, C7). Since 2026-11-14 it is
compiled and tested on macOS and for iOS, and the app uses it ("The app" below); "Needs the
Mac or the phone" lists what is still open. Since 2026-11-23 the app holds several sessions at
once, each its own record, with no change to `Sources/` ("The app", "Several sessions").

## The pieces

| Type | File | What it does |
|---|---|---|
| `ResumeCoordinator` | `ResumeCoordinator.swift` | A session and its record together: `create`, `coldStart`, `start`, `enterBackground`, `enterForeground`, `type`, `resize`, `shutdown`, `abandon`, `close`, `deleteRecord`. What the app uses |
| `SessionRecord` | `SessionRecord.swift` | An open record: store, lock and gate together. `create`, `open`, `save(export)`, `loadSnapshot()`, `close`, `delete`. The only way to a gate and to a clean mark |
| `FileBackedGate` | `FileBackedGate.swift` | The `DurabilityGate` whose counters are the `counters` file |
| `SessionStore`, `SessionLock` | `SessionStore.swift` | The directory `<root>/<session id>/`, its files, the `flock` |
| `Storage`, `StorageHook` | `Storage.swift` | The POSIX calls, each a named step that a hook can stop at |
| `RecordProtection` | `RecordProtection.swift` | Keeps the session directory out of backups: `AppleRecordProtection` on Apple platforms, `NoRecordProtection` elsewhere |
| `CountersFile`, `CountersSlot` | `Counters.swift` | The two-slot counters format and how it is read |
| `SnapshotCodec` | `SnapshotCodec.swift` | The snapshot byte format |
| `SessionMeta`, `StoredKey`, `SessionID` | `SessionMeta.swift` | `meta`, `key`, the record's name |
| `PartFrame`, `CRC32` | `RecordFormat.swift` | Frame and checksum of `meta`, `key`, `snapshot` |

`MoshResume` depends on `MoshSession` (it stores what the facade exports), not the other
way round.

## Invariants

The hard failures N1 (a sequence number twice), N2 (a state number reused, or a state
with a shorter input list than an earlier one) and N4 (a fragment id reused) must be
impossible whenever the process dies. N3 (`throwaway_num` above `old_num`) is the
transport's and has nothing to do with storage.

Tests are in `Tests/MoshResumeTests`; "crash test" is
`FileBackedGateTests.testACrashAtEveryStepNeverReusesANumberOrResumesAStaleSnapshot`,
which kills a first process at every storage step of a script (before the step, after
it, and for a write with only part of its bytes on disk), a second process at a random
step, and checks a third.

| # | Invariant | Enforced by | Checked by |
|---|---|---|---|
| R1 | **Reserve ahead.** A sequence number, state number or fragment id is handed out only when both counters slots durably hold a limit above it | `FileBackedGate.take`: when the block is used up it raises the limit with `writeBothSlots` (two `pwrite` + fsync) and only then returns a number; `reservedLimits` changes only after both writes | `testALimitIsInBothSlotsBeforeANumberBelowItIsUsed`, crash test |
| R2 | **A restart begins at the reserved limit, never below.** A new gate's first numbers are the highest limits any valid slot holds | `FileBackedGate.init` (`next = reading.limits`), `CountersFile.read` | `testANewGateStartsAtTheReservedLimits`, `testTheScriptWithAReopenAfterEveryOperation`, crash test, `ResumeEndToEndTests.testASessionContinuesFromItsRecord` (sequence numbers of two lives against a real server) |
| R3 | **Numbers come from the stored counters, never from the snapshot.** The snapshot's `usedCounters` are only a floor the import checks the gate against | The gate has no input from a snapshot; `TransportCore.init(restoring:)` throws `gateBelowSnapshot` | `MoshTransportTests/SnapshotReviewTests.testImportWithAGateBelowWhatWasUsedIsRefused` |
| R4 | **Dirty before send.** When a datagram passes the gate, both slots say "dirty" (or "ended") | `FileBackedGate.willSendDatagram` writes both slots unless `notCleanIsDurable` | `testDirtyIsInBothSlotsBeforeADatagramPasses`, crash test |
| R5 | **Clean only if nothing was sent.** "Clean" is written only if no datagram passed since the export the snapshot came from; check and write are one critical section with R4 | `FileBackedGate.markClean(snapshotID:_:)` under the gate's lock, with the `CleanToken` of the export | `testCleanOnlyIfNothingWasSentSinceTheExport`, `ResumeEndToEndTests.testAKillAfterReturningToTheForegroundLeavesNoResumableRecord` |
| R6 | **"Clean" names a snapshot.** A clean mark carries the id of a snapshot that was durably stored after the last datagram; there is no clean mark on the gate's own word. The id and the export's token come in one call, so a refused mark leaves nothing a later call could use (review A-4) | `FileBackedGate.markClean(snapshotID:_:)`, internal and called by `SessionRecord.save` only; the protocol's `markClean(ifDatagramsPassed:)` on a `FileBackedGate` always throws `noSnapshotStored` | `testNoCleanMarkWithoutAStoredSnapshot`, `ReviewFixTests.testA4_ARefusedSaveLeavesNoSnapshotIDToMark` |
| R7 | **A stored snapshot is used only while the record is clean for exactly that snapshot.** Dirty, ended, or a snapshot file with another id: not resumable | `SessionRecord.loadSnapshot` is the only public way to a stored snapshot | `SessionStoreTests.testASnapshotThatIsNotTheOneTheCleanMarkNames`, `testSaveThenLoad`, crash test (a loaded snapshot is never older than a datagram) |
| R8 | **A snapshot is replaced whole.** A reader finds the old snapshot or the new one | `Storage.replace`: `snapshot.tmp`, fsync, rename, fsync of the directory | `SessionStoreTests.testACrashAtEveryStepOfASnapshotReplace` |
| R9 | **A torn counters write leaves the other slot valid.** A write goes to the older slot only; the slots are 4096 bytes apart | `FileBackedGate.writeOneSlot` (slot = generation mod 2), `CountersFile` | `CountersTests.testATornSlotWriteLeavesTheOldReadingOrGivesTheNewOne`, crash test |
| R10 | **One slot lost at rest is safe.** With either slot unreadable at any later time, the limits read are still above every number handed out, and "clean" is read only for a snapshot no datagram followed | Every change except "clean" goes to both slots before it is acted on (R1, R4) | `testLosingEitherSlotAfterAnyOperationIsSafe`, `CountersTests.testDamageInOneSlotFallsBackToTheOther` |
| R11 | **A failed write changes nothing that was promised.** The call throws, no number is handed out, no datagram passes; the next call writes again; limits on disk never go down; a clean mark that may be half on disk is followed by a full "dirty" before the next datagram | `written` / `limits` / `notCleanIsDurable` in `FileBackedGate` | `testAFailedStepIsRepeatedWithoutHarm`, `testAFailedCleanMarkIsFollowedByADurableDirty`, `testLimitsOnDiskNeverGoDownAfterAFailedReservation`, `testACleanMarkWhoseFsyncFailedIsStillATrueMark` |
| R12 | **One writer, one gate.** A gate, and a snapshot write, need the record's `flock`; a second open fails with `locked`. A lock serves one gate: a second gate on it would start at the same limits (review A-5) | `SessionStore.acquireLock` and `FileBackedGate.init(store:lock:)`, both internal (`SessionRecord` is the way to a gate); `SessionLock.claimForGate` (`lockHasAGate`); `SessionStore.check` | `SessionStoreTests.testOnlyOneHolderOfTheLock`, `testALockOfAnotherRecordIsRefused`, `testAClosedRecordDoesNothingMore`, `ReviewFixTests.testA5_ASecondGateOnOneLockIsRefused` |
| R13 | **A part belongs to its session.** `meta`, `key`, each counters slot and the snapshot repeat the session id; a part of another session is refused | The decoders (`wrongSession`) | `SessionStoreTests.testPartsCopiedFromAnotherSessionAreRefused`, `CountersTests.testASlotOfAnotherSessionDoesNotCount` |
| R14 | **Damage is detected.** Every part has a CRC-32; any changed byte and any truncation is refused (for one counters slot: the other slot is used). Decoding never traps | `PartFrame.unwrap`, `CountersSlot.init(encoded:)`, `SnapshotCodec.decode` | `testEveryDamagedByteIsRejected` and `testEveryTruncationIsRejected` in `RecordFormatTests` and `SnapshotCodecTests`, `SnapshotCodecTests.testDamageBehindTheChecksumNeverTraps`, `SessionStoreTests.testADamagedSnapshotFileIsRefused` |
| R15 | **Counters that contradict each other are refused.** Two valid slots must be consecutive generations, each in its own place, the newer with no lower limit | `CountersFile.read` | `CountersTests.testContradictingSlotsAreRefused` |
| R16 | **An ended record is never resumed**, and can still send (a last shutdown request). **"Ended" is final from the call on**, also if its write fails: no clean mark is possible, every later write of the gate says "ended" (so a mark that reached one slot is completed, never covered by "dirty"), and no datagram passes before both slots hold it (review A-6) | `FileBackedGate.markEnded` (state set before the write), `willSendDatagram`, `markDirty`, `take`, `beginSending` | `testAnEndedRecordIsNeverCleanAgainButStillSends`, `ReviewFixTests.testA6_AHalfWrittenEndedMarkIsCompletedNeverOverwritten`, `testA6_NoDatagramPassesWhileTheEndedMarkCannotBeWritten` |
| R17 | **A snapshot loses nothing.** Every field of `TransportSnapshot` (with `usedCounters` and `receiverExpectedSequence`), the whole terminal state of every held remote state with its row sharing, and the clipboard policy come back equal | `SnapshotCodec` | `SnapshotCodecTests.testRichSnapshotRoundTripFieldByField`, `testRowSharingIsKept`, `testCorpusRunWithAReloadBetweenEveryPairOfDiffs` |
| R18 | **A record is made once** (review A-1). `create` refuses a session directory that exists, held or not: making it again would start the counters at 0 under the same key (N1). A create that fails on the way removes what it made, so the same id can be tried again; a crash leaves a directory without `counters`, which the cold start deletes | `Storage.makeDirectory` (`EEXIST` is an error), `SessionStore.create` (`RecordError.exists`) | `ReviewFixTests.testA1_CreateOverAnExistingRecordIsRefused`, `testA1_CreateOverAHeldRecordIsRefused`, `testA1_TheCoordinatorDoesNotCreateTwice`, `testA1_AFailedCreateLeavesNothingAndCanBeRepeated`, `SessionStoreTests.testACrashAtEveryStepOfCreate` |
| R19 | **A record is not in a backup, or it is not resumed** (review A-2). The Keychain key comes back with a restore to the same device; counters that came back with it would be older than what the key was used for (N1). The session directory is excluded from backups right after it is made and before anything is in it; if that fails there is no record; a record found not excluded is refused before a gate exists and the cold start deletes it; "cannot tell now" is "try again later" | `RecordProtection` (`apply`, `verify`), `SessionStore.create` (step `dir.protect`), `SessionStore.checkProtection` in `SessionRecord.open` (`RecordError.notProtected`) | `RecordProtectionTests` (with an injected protection). The Apple implementation: needs the Mac and the phone |
| R20 | **Only "no such file" means missing** (review A-7). A part, or the directory, that cannot be looked at for any other reason is a storage error ("try again later"), never "missing", which the cold start answers with a deletion | `Storage.presence(afterErrno:)`, used by `exists` (`lstat`), `read`, `openExisting`, `SessionStore.acquireLock`; `SessionStore.exists` throws | `ReviewFixTests.testA7_OnlyNoSuchFileMeansMissing`, `testA7_ARecordThatCannotBeLookedAtIsRetriedLaterNotDeclaredMissing` |
| R21 | **A failed full sync is an error** (review A-8). `fcntl(F_FULLFSYNC)` interrupted is repeated; any other failure fails the step. The fallback to `fsync` for a file system without the call exists in the code but has no error number (`Storage.fullSyncNotSupportedErrors` is empty): on charlie the call succeeded on files and directories on APFS, MS-DOS, ExFAT and HFS+, so none was observed. It is never replaced by an `fsync` whose success would be reported as durable | `Storage.afterFullSyncFailure(errno:)`, `Storage.durableSync` | `ReviewFixTests.testA8_WhatFollowsAFailedFullSync`, `testA8_TheSyncWithPlayedCalls` (the calls are played; the real call runs in the whole suite under macOS) |

Why R1 to R5 give N1, N2 and N4: a number handed out is below a limit in both slots
(R1), a later process starts at or above that limit (R2, R10), so no number is handed
out twice. A resumed state list is as long as the server's only if no datagram left
after the snapshot; that is R4 to R7.

### Difference from the plan: two writes per change

`docs/PLAN.md` asks for one counters write per change. The gate makes two (older slot,
fsync, other slot, fsync) for limits and for "dirty", and one for "clean". With one
write, the slot written last is the only place that holds the new limit or the "dirty";
if that slot becomes unreadable later (not torn by the crash: damaged at rest), the read
falls back to the older slot, which has lower limits (N1) or says "clean" for a stale
snapshot (N2). With two writes the older slot never says anything less safe than what
the process acted on (R10). Cost: one more fsync per 65,536 datagrams, per 1,024 states
and for the first datagram after each snapshot. "Clean" stays one write: losing it only
costs a resume.

A torn write and a slot damaged at rest look the same to a reader. After a torn write
the other slot is right because the process had not yet acted (R9); after damage at rest
it is right because of the second write (R10).

## Coordinator

`ResumeCoordinator` (an actor) owns one `MoshSession` and its `SessionRecord`. The session is
private to it: input, lifecycle calls and events all pass through the coordinator, so the
rules below cannot be skipped by calling the session directly. Tests are in
`Tests/MoshResumeTests/ResumeCoordinatorTests.swift` (`ResumeCoordinatorTests` without a
server, `ResumeCoordinatorServerTests` and `GuardTests` against the real one).

| # | Invariant | Enforced by | Checked by |
|---|---|---|---|
| C1 | **Cold start in the plan's order.** Lock and counters; the snapshot only if the record is clean for it; the key; the session rebuilt; then one counters change ("dirty", new reservations); then the first datagram | `coldStart` (steps 1, 2, 4, 5: nothing is written, nothing is sent), `start()` (`gate.beginSending()`, then `session.start()`) | `testLeavingTheForegroundMakesTheRecordCleanAndAColdStartResumesIt`, `testBackgroundForegroundAndTwoColdStarts`, kill loop |
| C2 | **A fallback sends nothing.** Every outcome but "resumed" returns before a session exists; no socket is opened | `coldStart` | The fallback tests count sockets and datagrams; kill loop (sequence log unchanged, capture) |
| C3 | **Fallback or "try again later", never a guess.** A record somebody holds (`RecordError.locked`) and a failed file operation (`StorageError.io`: device locked, disk; also a record that cannot be looked at, R20, and a backup exclusion that cannot be read, R19) leave the record untouched and are reported as `retryLater`. Everything else is a fallback with its reason | `disposition(of:)`, `coldStart` | `testARecordInUseIsRetriedLater`, `testAStorageErrorAtStartIsRetriedLaterAndNeverAFallback`, `testAStorageErrorAtOpenIsRetriedLater` (not as root), `ReviewFixTests.testA7_ARecordThatCannotBeLookedAt…`, `RecordProtectionTests.testAProtectionThatCannotBeReadIsRetriedLater` |
| C4 | **A record that was given up is dead and still owes a new session** (review B-1). With lock and counters: made "dirty" (never resumed; not "ended", which would read as "closed on purpose") and kept, so that every later cold start is again a fallback that wants a new session and hands over `meta` (to kill the old server and to bootstrap again), until `deleteRecord`. The same for `abandon()`, a lost base state and a halted transport. Two fallbacks write nothing: "ended" stays ended, and a missing key leaves the record as it is (C12). Without counters, meta or a readable slot, or not excluded from backup: deleted at once, as the plan says, under its lock | `coldStart`, `giveUp` (`runAbandon`, `handle`) | `ReviewFixTests.testB1_*`, `testLeavingTheForeground…` (second and third start `.dirty`), `testAnAbandonedSessionIsNotResumed`, `testARecordWithBothCountersSlotsBadIsDeleted`, `testADirectoryThatNeverBecameARecordIsDeleted` |
| C5 | **Save in the plan's order.** Quiesce, export, store the snapshot, mark clean with the export's token | `enterBackground` → `save` → `SessionRecord.save` | `testLeavingTheForeground…`, `testReturningToTheForegroundMakesTheRecordDirtyAtOnce`, kill loop |
| C6 | **A clean record holds everything that was accepted (M9).** When `type` or `resize` returns true in the background, the record is clean for a snapshot that holds the input, or it is not clean | `runInput`: `gate.markDirty()` (both slots) before the session gets the input, then `save` again. If "dirty" cannot be written the input is refused | `testInputAcceptedInTheBackgroundIsInTheRecord`, `testAResizeAcceptedInTheBackgroundIsInTheRecord`, `testAProcessDeathAtEveryStepOfBackgroundInput`, `testBackgroundInputIsRefusedWhenTheRecordCannotBeWritten`, `testALineTypedInTheBackgroundReachesTheServerAfterAColdStart` |
| C7 | **An ended session stays ended.** A shutdown request (foreground or background) and the server's end of the session mark the record ended before the request is passed on or the event is handed to the app; the flag is set before the write, so no later save marks the record clean even if the write failed, and the gate completes a failed mark at its next write (R16). **A shutdown that cannot be recorded is refused** (review B-4): `shutdown()` first makes "not clean" durable and, if that fails, returns false with nothing changed, as input does (C6); otherwise a process death would resume a session the user closed. (A lost base state and a halted transport give the session up instead: C4) | `runShutdown` (`gate.markDirty()`, then `markEnded`), `handle`, `save` (`guard !ended`) | `testAShutdownInTheBackgroundEndsTheRecord`, `testAShutdownInTheForegroundEndsTheRecord`, `testTheServersEndOfTheSessionEndsTheRecord`, `ReviewFixTests.testB4_AShutdownThatCannotBeRecordedIsRefused`, `testB4_AnEndedMarkThatFailedIsCompletedAtTheNextWrite` |
| C8 | **One at a time, in arrival order.** Lifecycle calls, input and the handling of events run one after the other: a save finishes before a return to the foreground starts, and input cannot slip between an export and its clean mark | `inOrder` (each operation waits for the one asked for before it) | By construction; the M9 tests depend on it |
| C9 | **Dirty at the return to the foreground.** "Dirty" is written when the app returns, not only before the first datagram | `runEnterForeground` (`gate.markDirty()`; if that fails the gate still writes it before any datagram, R4). While it cannot be written no datagram passes and the record stays clean for the last snapshot: a process death then resumes the session as the server has it, without the input typed since (the server never saw it; review finding B-5, not a defect) | `testReturningToTheForegroundMakesTheRecordDirtyAtOnce` |
| C10 | **A clean record is not saved a second time** (review A-3, B-3). `enterBackground()` again while in the background, with nothing changed since a save that left the record clean, writes nothing and answers `.clean`. A second save could only lose the record: between the new snapshot's rename and its clean mark the counters name a snapshot that is gone | `runEnterBackground` (`savedClean`, reset by a return to the foreground and by input) | `ReviewFixTests.testB3_ASecondSaveNeverMakesAResumableRecordUnresumable`, `testB3_ASaveStillHappensWhenSomethingChanged` |
| C11 | **Nothing reaches the session before `start()`** (review B-2). Input is refused, a size is kept and announced at the start, `enterBackground()` leaves the record as it is (`.clean` for a restored session), and a `start()` asked for in the background happens at the return to the foreground. So no socket is opened and no datagram leaves without the cold start's counters change and a reader for the events. (`shutdown()` is the exception: it marks the record and is passed on) | `runInput`, `runResize`, `runStart`, `runEnterBackground`, `runEnterForeground` | `ReviewFixTests.testB2_InputBeforeStartSendsNothingAndKeepsTheRecord`, `testB2_AStartAskedForInTheBackgroundHappensInTheForeground` |
| C12 | **The key's source is said, never guessed** (review B-7). `coldStart(key:)` has no default: `.recordFile` or `.provided(key)`. A missing key is a fallback that writes nothing, so the right call still resumes | `ResumeCoordinator.KeySource`, `coldStart` | `ReviewFixTests.testB7_AskingARecordWithoutAKeyFileForItsKeyDoesNotEndIt`, `testARecordWithoutItsKeyFallsBack` |
| C13 | **The stored clipboard policy has seen the stored screen** (review B-6). The export shows the policy the newest state it exports before the policy is copied, so a restore does not write to the pasteboard a copy the live process already wrote | `MoshSession.exportState` | `MoshSessionTests/ExportClipboardTests` (real server, the session's reader held back), `RestoredClipboardTests` |

What a cold start can say (`ColdStartOutcome`):

| Outcome | When | What the app does |
|---|---|---|
| `.resumed(coordinator)` | The record is clean for its snapshot, the key is there, the transport accepts the snapshot | `start()`. The first event is the stored screen |
| `.fallback(reason: .dirty)` | The process died in the foreground; or the session was given up (an earlier fallback, `abandon()`, a lost base state) and the record not deleted yet | Shows `ColdStartFallback.userMessage` ("Previous session could not be resumed. Starting a new one."), bootstraps again with `meta`, kills the old server if the identity check passes, then `deleteRecord` |
| `.fallback(.ended)` | The user asked for a shutdown, or the server ended the session | `wantsNewSession` is false: no new session. The shutdown request may never have arrived (mosh-server has no timeout of its own), so the app still runs the identity check with `meta` and kills the old server if it is there; then removes the session from its list, `deleteRecord` |
| `.fallback(.missing(part))`, `.damaged`, `.snapshotDoesNotMatch`, `.snapshotRefused` | A part is gone or unreadable; the directory is not excluded from backup (it may be a restored copy; `recordDeleted` is true); the clean mark names another snapshot; the snapshot's numbers do not fit the counters | As for `.dirty` |
| `.retryLater(.inUse)` | The lock is held | Nothing; another scene or process has the session |
| `.retryLater(.storage)` | A file operation failed, or the record could not be looked at | Tries again later (after the device is unlocked). Never "dead" |

On iOS the key is not in the record. The app reads it from the Keychain and passes it as
`coldStart(key: .provided(key))`; if the Keychain says "interaction not allowed" the app does
not call `coldStart` at all and tries again later. `moshcli` passes `.recordFile`. There is no
default (C12).

Until the app has deleted the record of a session that fell back, every start gives the same
fallback again. The app's order after a fallback: show the message, bootstrap the new session,
kill the old server if the identity check passes, `deleteRecord`.

### M9: closed

Finding M9 of the transport review (`docs/notes/review-transport/refutation.md`): `type`,
`resize` and `shutdown` are accepted while the session is quiesced and pass no datagram, so
the `CleanToken`, which counts datagrams, does not see them. A record saved before such a
change stayed clean for a snapshot without it: a process death then resumed a session that had
silently lost input, or one the user had closed.

The fix is in the coordinator, not in the token (C6, C7). The alternative, a count of accepted
changes carried by the token, was not taken: the comparison of that count and the clean write
would have to be one critical section with the session accepting input, which only the
coordinator can give, and then the coordinator can as well do the whole thing. In the
background:

1. `gate.markDirty()`: both slots say "dirty" (4 steps). If this fails, the input is refused
   and the record is still clean for a snapshot that is the whole truth.
2. The session takes the input.
3. `save` again: the snapshot is replaced (5 steps), then the clean mark (2 steps).

`testAProcessDeathAtEveryStepOfBackgroundInput` kills the process before and after each of the
11 steps: one outcome is a resume without the input (death before the first write, and `type`
had not returned), three are a resume with it (the clean mark is in its slot), eighteen are
the fallback. No outcome is a resume without input that was reported as taken. A shutdown
makes the record "dirty" and then "ended" before it is passed on, and is refused if "dirty"
cannot be written (C7); `exportState` refuses a session that is shutting down, so without the
mark the record would have stayed clean. Each of these tests fails with the
steps removed (seen once, when they were written).

The cost: input in the background takes two counters writes and a snapshot write per call.
It is rare (a paste that completes late, a debounced resize).

## Stage 1 results

The table "Resume, stage 1" of `docs/PLAN.md` ("Verification"), run on 2026-11-13 in the cloud
session (Linux, root, mosh-server 1.4.0, tmux, no `sch_netem`). One command covers the rows
that can run here:

    ITEST_NO_CONTAINER=1 scripts/itest.sh killloop 260 --long     # exit 0, "killloop: PASS", about 5 min

The numbers below are from the run after the review fixes (cloud round 9, the code at
`b541716`); the run before them (round 7) differed only where a number depends on the count of
storage steps or on timing: 37 steps instead of 38, 130 crash-point runs, 1962 sequence
numbers, 1885 captured datagrams, 194 servers. `ITEST_NO_CONTAINER=1 scripts/itest.sh all`
was run with it and exits 0 (handshake, hello, script, rebind, resume-mem, soak, bootstrap
with 108 tests, bootstrap-session, killloop with 20 iterations; netem-soak skipped: needs
yellow).

260 iterations give 203 kills after a quiesce (the plan asks for 200); the others are the
rows that must fall back. `scripts/itest.sh all` runs the same with 20 iterations and without
the 42 s gap and the torn writes (also PASS, about 1 min). The script's header says what each
part does. The session runs tmux with `status off`; window 0 is `cat > log`, window 1 a shell.

| Row of the plan | Result | Numbers |
|---|---|---|
| Quiesce, `SIGKILL`, resume, 200 times | **pass** | 203 kills after a quiesce, 203 resumes: each reported "resumed session", on the mosh-server pid the record names (alive, unchanged within a session), with the shell's `$$` as before (typed `echo pid-$$` in every process; tmux's pane pid 30503 throughout). The last process exits 0. 22 of the quiesces were made by `SIGUSR1` |
| Variant: resume within 1 s | **pass** | The normal case of the loop (the next process starts at once) |
| Variant: after more than 40 s | **pass** | 1 resume 42 s after the kill (`--long`). `scripts/itest.sh resume-mem` has the same in one process |
| Variant: under 20% loss | **pass, with loss made in the client and under `tc netem`** | 25 resumes with `moshcli --loss 20` (20% of the datagrams dropped in each direction inside the client). On yellow, 2026-11-19, the whole `260 --long` run under `tc netem` on `lo` (`scripts/netem.sh --killloop 260 --long`, root, tcpdump capture): with `loss 20% delay 200ms 50ms reorder 25% 50%` "killloop: PASS" (203 resumes, 57 fallbacks, 127 screens equal, 521 lines exactly once, 132 crash-point runs, 2818 sequence numbers, 2222 captured datagrams to 116 servers, none twice); with `loss 20%` alone also "killloop: PASS" (the same counts; 2766 sequence numbers, 2130 captured datagrams, none twice; 26 min). Its 25 client-side `--loss 20` iterations ran under the netem loss too |
| Variant: with unacknowledged input | **pass** | 54 kills with the last line typed and not acknowledged; 17 of them `quiesce --after-send` |
| Variant: after a paste larger than one datagram | **pass** | 51 lines of 3000 random characters typed before the kill |
| Exactly-once input | **pass** | 521 lines typed into `cat` (one after each start, one before each kill, `END`), 260 kills between them: `log` equals the typed lines byte for byte. Every fifth clean kill uses `quiesce --after-send` |
| Liveness | **pass** | The line typed after each start was on the client's screen within 5 s in all 260 processes; 34 of the resumes had their first datagram dropped (`--drop-first 1`) |
| Quiesce, return to the foreground at once, type, `SIGKILL` | **pass** | 23 times: the record was dirty, the next start exited 3 ("fallback (the record is dirty); nothing sent"), the sequence log did not grow |
| Screen equality | **pass** | 127 comparisons after `wait-ack` and 500 ms without a new state: the client's rows equal `tmux capture-pane -p`; 21 of them after `seq 1 200` in the shell window |
| Nonce | **pass** | 116 sessions (keys) that sent anything, 2032 sequence numbers in the `--seq-log` files: strictly increasing per key over all its processes. `tcpdump` of the whole run on `lo`: 1941 client datagrams to 116 servers, no number twice per server, every one of them in the logs. State numbers and fragment ids taken from the gate (`FILE.numbers`): strictly increasing per key |
| `SIGKILL` while dirty (mid-typing) | **pass** | 34 kills at a random moment while typing: the record was dirty, the next start exited 3 and sent nothing (log and capture), and the old mosh-server was alive afterwards |
| Crash points | **pass** | "connect, type, quiesce" has 38 storage steps (`dir.protect` is new) and "resume, type, quiesce" 11. 132 runs, one for each step before and after it, for each write also after 1 and after 37 bytes, and for the step after the last: 128 processes killed themselves and 4 ended normally. Next start: 13 resumes (the record said clean; the shell was the same), 116 fallbacks with nothing sent (it said dirty, or was not a record yet), 3 with no directory at all. None anything else |
| Damaged record | **pass** | One counters slot overwritten: the other is used (slot 0 lost: it says clean, resumed; slot 1 lost, which held the clean mark: it says dirty, fallback). Both slots, the key or the snapshot gone: fallback, no datagram |
| Guard tests with a deliberately broken client | **pass** | `GuardTests`: a resume from a snapshot that a datagram followed (a shorter input list, N2) and a `throwaway_num` above every server state (N3) each end the real mosh-server within 10 s; the same runs with the dirty rule, and with `throwaway_num` at its base, leave it alive |

In the loop, the crash points and the damaged records 196 mosh-servers were started and none
ended by itself: every server is checked to be alive before the script retires it. (The guard
tests end two more on purpose.)

Also from the plan's list ("From M6, resume unit tests on a fake clock"), in `swift test`:
`ResumeSeamTests.testExportRightAfterAnAckHoldsExactlyTheInputTheServerHasNotSeen`,
`testAnAckForAnUnknownStateNumberChangesNothing`, and
`SnapshotCodecTests.testCorpusRunWithAReloadBetweenEveryPairOfDiffs`.

**Under `tc netem` (yellow, 2026-11-19):** `scripts/netem.sh --killloop 260 --long` runs the
kill loop as root in the dev container (build as uid 1000 first, then the qdisc on `lo`, then the
loop with its tcpdump capture, `--no-guards`; `NETEM_SPEC` sets the qdisc). The first tries, with
the plain loop's 500 ms of quiet before a screen comparison, failed at iteration 94 (`loss 20%`)
and 2 (the full spec): "the client's screen differs from tmux capture-pane -p". The client was
behind, not wrong: in a 40-iteration run under the full spec that took the screen twice, 2 of 20
screens taken after 500 ms differed from tmux (both still showed the shell window the script had
left for the `cat` window) and all 20 taken 7 s later equalled it (`out/yellow/exp/full-40.log`; it
ended at iteration 40 on the 5 s liveness wait of a client-side `--loss 20` iteration). The reason
is mosh's sender: a lost state is sent again only after `timeout() + ACK_DELAY`, up to 1100 ms
(`transportsender-impl.h:284`, `network.h:134`), longer than 500 ms. A longer quiet time does not
help either, since the server sends an empty ack with a new state number every 3 s. So the netem
mode waits 7 s after `wait-ack` and then the usual 500 ms of quiet (more than five resend gaps),
and gives typed lines 15 s instead of 5 s; the arithmetic is in `scripts/netem.sh`. Nothing
changed for the run without netem. Results: the 20% loss row above; logs
`out/yellow/killloop-netem-mode-{full,loss20}.log`.

Not covered by any of this: a real power loss (the model is the death of the process: a step
that returned is on disk), and iOS itself on a device (file protection, the Keychain while
locked, jetsam), which are the phone rows of the plan. The app's wiring is covered on the
simulator ("The app" below).

**On the phone (2026-11-21, builds 182 and 183, Trick's iPhone 16 and a real host of his;
`docs/MAC.md` log 2026-11-21 02:45 UTC):** a save with the phone locked works (`LOCKED PASS
VERDICT: ok`); a session resumed with the same screen and no banner after a force-quit, after an
install over it and after a phone restart; a kill on screen (an install while in the foreground)
fell back with "the record is dirty" and a new session 1.67 s after the launch. Two findings:
the app cannot read `kern.bootsessionuuid` (errno 1; it matters only to stage 2), and on that
host the app never learns the server's pid (`pid ?`), so the fallback left the old server
running (open item in `docs/CLOUD.md`). Not run: 10 minutes in the background, "Crash Now", a
killed server, a backup and restore.

## The app

How `App/IOSMosh` uses the coordinator (since 2026-11-14; several sessions at once since
2026-11-23, `docs/notes/multi-session/DESIGN.md`). The app never makes a `MoshSession` itself;
every session is a `ResumeCoordinator`, so every send passes the record's `FileBackedGate`.

| When | What the app calls | Where |
|---|---|---|
| A new session (a tap on a host row, also when the host has sessions; or a debug launch) | `SessionKeychain.store(key, for: id)` (Keychain, account = id, `AfterFirstUnlockThisDeviceOnly`, not synchronizable), the link to the saved host (`session-hosts.json`), then `ResumeCoordinator.create(root: Application Support/sessions, meta:, key:, storesKey: false, initialSize:, options:)` (`NWDatagramTransport`), then `attach`: "last looked at" set to this id, then `start()`. The key goes first: a crash in between leaves an orphan key, never a record without its key | `TerminalViewController.openSession`, `attach`, `begin` |
| Input, resizes, a network path change | `type`, `resize`, `replaceSocket`, in order through one serial command queue per screen. The queue and its slot (the screen's coordinator) are a `SessionQueue`, which outlives the screen, so a command queued before a leave still runs | `TerminalViewController` (`queue.send`), `SessionQueue` (`send`, `perform`) |
| Leaving the foreground (`sceneWillResignActive`) | In a `beginBackgroundTask`: `enterBackground()` (quiesce, export, snapshot, clean mark), for the session on screen only (`TerminalViewController.current`); every other session is already parked. Without a session yet (bootstrap in flight, a fallback's replacement, a resumed session before its first layout) the same save is queued when the session is attached, before `start()`, which is then a deferred start (C11) | `SceneDelegate` → `TerminalViewController.sceneWillResignActive`, `attach`; `SceneSavePolicy` |
| Returning (`sceneDidBecomeActive`) | `enterForeground()` ("dirty", new socket); `start()` again if it had failed (it threw, or a `.gateFailed` event came, as for a deferred start that failed) | `TerminalViewController.sceneDidBecomeActive` |
| Back ("‹ Hosts"): **the park** | Never ends the session. `.park` at the end of the screen's queue, after everything queued before it; then, in the queue's consumer: for a resumed session that was attached, `start()` again (nothing once started; completes a counters change a failed `beginSending` left half done); `enterBackground()`, once more after 300 ms if it did not leave the record clean; `close()` (lock released, nothing written); `SessionFiles.forget` only when the save answered "ended" and the record says "ended" (the server ended the session during the leave). The park sends nothing: it is the scene's save followed by a close. A record is "being saved" (row "Saving…") until the consumer has ended. Back while the first connection runs cancels it (nothing was made); back while a fallback connects cancels it and keeps the old, dirty record ("Could not be resumed") with "last looked at" cleared | `TerminalViewController.leaveScreen`, `park`; `LeaveAction.decide`, `ParkPlan.after`; `SessionQueue` |
| A tap on a session row: **the unpark** | `SessionActivity.settled()` (every park and close asked for before it has returned), then the gate (the scene is active, the list is the top screen, no terminal is open; otherwise the tap is dropped), then, with no suspension up to the push, `SessionLauncher.coldStart(root:id:keys:options:)` for that row's id: the cold start below, and `.resumed` makes a new screen with the coordinator in its slot. A dead row with a saved host is the fallback (a new session; the old record deleted once it started); without a host, the alert and the record deleted. A key or record that cannot be read now (the device locked, the record in use, a storage error: `.retryLater`): "Session Not Available Now", nothing changed. An "ended" row and the row on screen take no tap | `SessionListViewController.open`, `SessionActivity`, `OpenGate.mayOpen` |
| Cold start (scene connects) | Orphan keys and host links removed (no record directory), and "last looked at" if it names no record. Every "ended" record is finished in the background (row `.fallback(.ended)`) and skipped. Then **the launch target only**: the session looked at last (`lastLookedAt` in `session-hosts.json`), unless there is none, it is among the ended records or its record is not there; no other record is opened, written or deleted. For it: the key from the Keychain; "interaction not allowed" or any other Keychain error is "try again later" and `coldStart` is not called; no item, or an item that is not 16 bytes: the fallback with "the session key is not in the Keychain" and nothing written to the record; otherwise `coldStart(key: .provided(key), currentSize: nil)`. Without a target: the list (in a debug build, a `-debugMosh*` launch opens that session instead) | `SceneDelegate.makeRoot`, `SessionLauncher.launch`, `launchTarget`, `coldStart` |
| `.resumed` | The terminal screen, always over the host list (also for a session without a saved host and a debug session), and `start()` in `attach`; the first screen is the stored one | `SceneDelegate.terminal(for:)`, `navigation(showing:)` |
| `.fallback`, wants a new session | Shows `ColdStartFallback.userMessage` and the reason; bootstraps the saved host again (or the `-debugFallback*` server) and, after the new `mosh-server` has started, kills the old one in the same SSH connection only if the identity check passes; once the new session has started, `deleteRecord` with its key and link (`SessionFiles.forget`); "last looked at" moves to the new session in its `attach`. Without a host or debug fallback: the message as an alert, record deleted. No free UDP port in the host's range ("Failed binding to" in the failed start's output): the banner says so and names the range | `TerminalViewController.startReplacement`, `sessionStarted`; `PortRangeFull` |
| `.fallback(.ended)` (every ended record at launch, also older ones) | Silent key login, `killServer` after the identity check; no new session. The record is deleted only when the server was killed, the check failed at the record's own address (provably gone), or there is no host or no pid to ask with; host not reached, no usable answer, or a failed check at another address: the record stays "ended" for the next launch | `SessionLauncher.endedRecords`, `finishEnded`, `stopOldServer`, `OldServerOutcome.mayForget` |
| `.retryLater` | The host list with "A session is waiting: …"; at the next `sceneDidBecomeActive` the launch target is asked for again, as a tap opens (settle, gate, push), only while the list is the top screen and no terminal is open. A tap on a host or session row that is taken (none while another open is in flight), or ending or forgetting that session, drops the wait | `SceneDelegate.retryColdStart`, `SessionLauncher.retry`, `SessionActivity` |
| 15 s without the server while active | `ServerProbe.probe` (silent key login), for the session on screen only: a parked session has no coordinator and gets no events. Server gone, which only a failed check at the record's own address proves: `abandon()` (record "dirty"), then the fallback above with the probe's reason. Host unreachable: probe again in 15 s. UDP blocked, the server at another address, or an answer that proves nothing (the check failed at another machine, `ps` unreadable: `ProbeResult.unknown`): say so, keep the session | `TerminalViewController.checkHealth`, `probe`, `HealthPolicy`; `ProbeResult.from` |
| `.baseStateLost`, `.halted` | `abandon()` and the fallback | `TerminalViewController.runtimeFallback` |
| `.serverEnded` then `.serverEndAcknowledged` (Ctrl-D, `exit`) | "Session ended"; the health check, the probe and the path watcher stop (no new session by itself); `close()`, record deleted; then the screen pops itself back to the list. If the acknowledgment never gets out, the banner stays and back closes and deletes | `TerminalViewController.attach`, `sessionIsOver`, `leaveScreen` (`finishForget`) |
| "End Session" from "…" in the terminal (asks once) | "Last looked at" cleared in the alert's action, then the pop. `shutdown()` (record "ended" first), in a background task of its own; on `.shutdownFinished(acknowledged: true)`, `close()` and the record deleted; on `.shutdownFinished(acknowledged: false)` (16 sends without an answer, or 10 s) and after 11 s without either, `close()` only: the "ended" record stays for the identity-checked kill at the next launch or by "End Session" on its row (`SessionEnding.after`, review M6-4); with no saved host or no pid in the record (as on `hg`) both find nobody to ask (`.nothingToAsk`) and delete it without contacting the host. If `shutdown()` is refused (the record cannot be written, or the session is over): `close()`, the identity-checked kill, and the record deleted only when `mayForget` says so; otherwise kept as its files say, without the dot. A resumed screen left before `attach`: `close()` only. During a fallback that connects: the old server's kill, the old record deleted only by `mayForget` | `TerminalViewController.endFromMenu`, `leaveScreen`, `end`, `stopServerThenForgetIfStopped`; `LeaveAction`, `SessionEnding` |
| "End Session" on a resumable (or unreadable) row: **mosh's own shutdown** | The record is opened again (settle, cold start of that id), started, and ended by `shutdown()` once the server has shown that it is there; no pid is needed for an acknowledged shutdown (Trick's host `hg`). The stages and the four outcomes he meets: "End Session" on a row, below | `SessionEnder` (`end`, `throughMosh`, `endResumed`, `overSSH`), `SessionEndPlan.next` |
| "End Session" on a dead or ended row | Sends nothing (C2, C4) and opens no coordinator: at once the SSH way (h below): the identity-checked kill (`stopOldServer`), the record forgotten only when `mayForget`. Its outcomes: those of the SSH way in "End Session" on a row, below | `SessionEnder` (`SessionEndPlan.way`, `overSSH`), `SessionLauncher.stopOldServer` |
| "Forget" on a row | `SessionFiles.forget(id)`: `deleteRecord` under the lock, then the Keychain key, the link and "last looked at"; then the launch's wait for it is dropped. The server is not contacted. A record that cannot be deleted now (in use, or a storage error): "Session Not Forgotten", and the key and the link are kept | `SessionListViewController.confirmForget`, `SessionFiles.forget` |
| "Crash Now" (debug builds, a row in Settings; with a session open: `-debugCrashAfter N`) | `kill(getpid(), SIGKILL)` | `DebugCrash` |

### "End Session" on a row

`SessionEnder.end` (`App/IOSMosh/SessionEnder.swift`; DESIGN.md section 6; step 12). Each
decision is `SessionEndPlan.next`. "Session Not Ended: …" below is the alert the list shows, its
title, then the ender's message (`SessionListViewController.end`); it is not seen when the list is
not the visible screen or another alert is up. "The row goes" means `SessionFiles.forget` deleted
the record (it then removes its Keychain key and its link; a failure there is only logged).

**The stages, in order** (a resumable or unreadable row runs from a; a dead or ended row runs a,
then h, and sends nothing: C2, C4):

- **a.** The row reads "Ending…" until the end returns, in a background task of its own; "last
  looked at" is cleared if it names the session, and the launch's wait for it is dropped.
- **b.** The settle (G2).
- **c.** The cold start of that id (`SessionLauncher.coldStart`, the key by the id; G1): a resumed
  session goes on to d; one that is not resumable after all goes to h; one that cannot be opened
  now is kept: "Session Not Ended: It cannot be opened now (<reason>). The session is kept; try
  again later, or use Forget."
- **d.** A reader on the session's events, then `start()`; if `start()` throws: `close()`, kept:
  "Session Not Ended: It could not be started now (<reason>). The session is kept; try again
  later, or use Forget."
- **e.** Up to 10 s for proof that the server is there: `.contact`, or a live screen (the stored
  screen a resume shows first is not proof). With proof: g; without: f.
- **f.** The ordinary save (`enterBackground()`), then `close()`; then h when the session has a
  saved host and the server's pid and start time in its record, otherwise kept (outcome 2).
- **g.** `shutdown()`, the one try (nothing of it is sent before the record says "ended": C7),
  then up to 11 s for its end.
- **h.** The SSH way (`overSSH`): `SessionLauncher.stopOldServer` (a silent key login to the
  saved host and the identity-checked kill), then the record forgotten only when
  `OldServerOutcome.mayForget` allows it.

**The four outcomes he meets:**

1. **The server acknowledges** (`.shutdownFinished(acknowledged: true)`, or
   `.serverEndAcknowledged`): `close()`, then the forget: the row goes, with no message (a forget
   that fails: outcome 4). mosh-server leaves once the end is acknowledged: the server is gone.
2. **No contact within the wait** (10 s of "Ending…"): the save and `close()`; after a clean
   save a record that is kept can be resumed again. Without a saved host, or without the server's pid and
   start time in the record (`hg`): nothing is deleted, and "Session Not Ended: <Host> did not
   answer. The session is kept; try again later, or use Forget." With a saved host and a known
   pid: the SSH way follows, with the results given under outcome 3 (here `.nothingToAsk` cannot
   occur).
3. **The shutdown is not acknowledged** (`.shutdownFinished(acknowledged: false)`, after 16 sends
   without an answer or 10 s; or no end within 11 s): `close()`, then the SSH way (a forget that
   fails there: outcome 4):
   - The server stopped (`.killed`) or provably gone (`.notThere` at the record's own address):
     the row goes, with no message.
   - The host not reached (`.hostNotReached`), no usable answer (`.notAnswered`), or the check
     failed at another address (`.notThere` elsewhere): "Session Not Ended: <Host> could not be
     reached with this device's key." / "<Host> gave no usable answer." / "<Host> answered from
     another address, so its answer says nothing about the session's server.", each followed by
     "The session is kept; try again later, or use Forget." Nothing is deleted, and the server
     may still run.
   - No saved host, or no pid and start time in the record (`.nothingToAsk`; Trick's host `hg`,
     where the app does not know the server's pid): the host is not contacted, `mayForget`
     allows the forget, and **the row goes without a message, although the server may still be
     running**.
4. **The record cannot be forgotten** (it is in use, or a storage error) where outcome 1 or the
   SSH way would forget it: "Session Not Ended: The session ended, but its record is in use or
   cannot be deleted now. Try again in a few seconds." (after outcome 1) or "Session Not Ended:
   The session's server was dealt with, but its record is in use or cannot be deleted now. Try
   again in a few seconds." (after the SSH way). The Keychain key and the link are kept, and the
   record is not deleted (or, after a storage error part way through, not wholly).

The rarer outcomes (a lost base state, a halt, a snapshot that cannot be read, a save that is not
clean, a record that is already gone or already over) are decided by `SessionEnder` and
`ResumeCoordinator`, are covered by `SessionEndPlanTests` and `EndSessionUITests`, and are not
listed in this text.

### Several sessions

Each session is its own record, its own Keychain key (account = the record's id) and its own
link to a saved host. **Only the session on screen has a coordinator.** Every other one is
parked: a record on disk, clean when its save was, and nothing else (no coordinator, socket,
timer or screen), so it behaves as a session saved when the app left the foreground, and a kill
of the app leaves it as it was. Three rules (G1 to G3) and one place for the key keep the records
apart; none is new in the core:

- **G1, one coordinator per record**: the record's `flock` (R12). A second open is refused
  (`.retryLater(.inUse)`), never a second writer.
- **G2, a parked record is closed before anything else is opened**: every park (also the one a
  queue's end does for a resumed coordinator whose screen was never pushed), the close and delete
  after the server's end, the close of a resumed screen left before `attach` and the `abandon()`
  of a run-time fallback are tracked releases in `SessionActivity`; every tap (on a host row,
  which makes a new session, or on a session row), the launch's retry and every "End Session" on
  a resumable or unreadable row awaits them all (`settled()`) before it opens a record or pushes
  a screen. So G1's refusal is not something the user meets. (The SSH way of a dead or ended row
  opens no record and does not settle.)
- **G3, no session starts on a screen the scene's save cannot reach**: after the settle, in one
  main-actor turn up to the push, the scene must be active, the list the top screen with nothing
  presented over it and no terminal screen open, or the tap is dropped; every pushed screen is
  loaded first, so it is `TerminalViewController.current` before anything starts.
- **The key is read by the record's id, in one place**: `SessionLauncher.coldStart(root:id:keys:
  options:)` reads `keys.key(for: id)` and is the only caller of `ResumeCoordinator.coldStart` in
  the app (a tap, the launch, its retry and the row's "End Session" all go through it). Another
  record's key would reuse nonces (N1), which the core cannot detect.

"Last looked at" is one id in `session-hosts.json` (every read-change-write of that file under
one lock). It is set in `attach` and cleared by every "End Session" before the ending begins, by
`forget`, by `removeOrphans` and by a back during a fallback. The launch opens that session and
no other record; a session he ended, or went back from while its fallback connected, therefore
never starts anything at a later launch.

**The price of the park (design decision D5).** The park is the scene's save and sends nothing.
mosh sends new input 20 to 250 ms after a key (250 ms until the first answer of a life, which is
every new session and every unpark), and the park's quiesce cancels that timer: input younger
than that, or input whose datagram was lost and not yet repeated, is in the snapshot and goes
out, exactly once, when the session is next opened (as mosh's own client does after a laptop
slept). Nothing shows it. "End Session" on that row, while it is resumable, sends it too (its
`start()`), just before the shell ends, so a command typed just before "‹ Hosts" can run at the
moment he ends the session.
If a command is ever seen to run late, the fix is a bounded wait before the save (poll
`unacknowledgedInputCount()` for at most 1 s; DESIGN.md risk 2). Also by the park: no bell and no
activity from a parked session; a parked session whose server went away (its shell ended, or it
was killed) is found only when it is opened (with a known pid and a saved host the probe
replaces it with a new session after 15 s; on a host without a pid, as `hg`, the screen shows
"Last contact" until he ends it from "…" or forgets it; "End Session" on its row finds no server
in 10 s and keeps it, DESIGN.md section 6 f and risk 6).

The cost of an unpark, all on the simulator (`docs/MAC.md` log, steps 9 and 10); **none of it
was measured on the phone**:

- The cold start itself (the Keychain read to the decision, logged as `cold start: <id>: resumed
  in N ms`): 1.0 to 5.3 ms, median 1.5 ms, in the 27 resumes of step 10's whole run (1.4 to 1.7 ms
  in the 7 unparks of its new UI tests and their controls).
- From a resumed screen's making to its first screen: 71 to 573 ms, median 93 ms, in step 10's
  whole run (the 573 ms with the push animated, as that step's entry says); 71 to 335 ms (most 94 ms)
  without animations and 589 ms with the push animated in step 9's whole run; 79 to 95 ms
  without animations and 589 and 823 ms animated in step 9's builder's runs. The UI tests turn
  animations off; the phone animates the push, so the animated figures, 573 to 823 ms, are the
  nearer guide for the phone.
- From the tap on the row to the stored screen as XCUITest sees it (its own latency included):
  1391 and 1411 ms (step 9).

Simulator tests (`scripts/sim-test.sh`): `ResumeUITests` (killed in the background after a clean
save: same screen, same `$$`, same server; a crash in the foreground (`-debugCrashAfter`): fallback with "the
record is dirty", a new shell; the server killed while the app was away: resumed, probed,
fallback with the probe's reason, a new server over SSH), `SessionListUITests` (rows under their
host, the preview and the dot, the row's age, swipes, "End Session" from "…" and from a row,
Forget, the server's end returning to the list; also: the screen left after "End Session" while
the server is stopped with SIGSTOP keeps the "ended" record, which "End Session" or the next
launch finishes with the identity-checked kill), `SwitchUITests` (back parks and the row resumes
the same shell; ten switches between two hosts; two sessions on one host; a back swipe let go
parks nothing; a switch sends no resize; a row tapped twice opens one terminal; a silent server
at a switch; the limit of the port range), `LaunchUITests` (a kill off screen resumes the session
looked at last; a kill with the list on screen goes into the dotted session; a crash on screen
falls back and the parked one stays; after the dotted session ends, or "End Session" before its
shutdown, the launch shows the list; a fallback he left does not come back), `EndSessionUITests`
(a parked session ended through mosh with and without a pid; the server gone keeps the session;
an interrupted end starts nothing), unit tests `SessionQueueTests`, `SessionActivityTests`,
`LeaveActionTests`, `SessionEndPlanTests`, `SessionPreviewTests`, `PortRangeFullTests`,
`SessionListTests`, `SessionLinksFileTests` ("last looked at" and the links file, in
`SessionFilesTests.swift`), `SessionFilesTests` (forget and the orphans, in
`SessionResumeTests.swift`), `SessionEndingTests`, `SessionKeychainTests` (store,
read, list, delete, the accessibility class reads back), `SessionLauncherTests` (no record, a
record never saved, a record without its Keychain key, a record in use, the launch target).

## Needs the Mac or the phone

Written on Linux and not compiled or run where it matters. Do these with the first macOS
compile (`scripts/mac.sh swift build`, wave 2 item 1) and before the app wires resume.

| What | Where | Needs |
|---|---|---|
| `AppleRecordProtection` compiles (`URLResourceValues.isExcludedFromBackup`; `FileProtectionType` is under `#if os(iOS)` and waits for the iOS build) | `RecordProtection.swift`, behind `#if canImport(Darwin)` | Mac, done 2026-11-14 |
| The backup exclusion is set by `SessionRecord.create`, reads back, survives a snapshot replace in the directory, and a directory without it is refused | `RecordProtectionTests.testTheAppleProtectionReadsBack` (compiled on Apple platforms only) | Mac (`swift test`), passed 2026-11-14. Phone, 2026-11-15 (run 0014b1eee2b2, build 117 (87fbbf5), `DeviceProbe`): `excludedFromBackup` true, `verify` true |
| The protection class "until first user authentication" reads back on the directory and on `counters` and `snapshot` (files inherit it from the directory); a save works with the device locked after first unlock | `DeviceProbe` (debug builds, `scripts/phone-selftest.sh`; locked save with `--locked`) reads the class back on the directory, `meta`, `counters`, `lock`, `snapshot`; `verify` does not check it | phone (the simulator reports no class). Read-back done 2026-11-15 (run 0014b1eee2b2, build 117 (87fbbf5), `scripts/phone-selftest.sh` exit 0): `completeUntilFirstUserAuthentication` on directory, `meta`, `counters`, `lock`, `snapshot`; the same on 2026-11-21 (builds 182 and 183). Save while locked done 2026-11-21 (build 183 (1d47a30), run f7c9f68ab53a, `out/yellow/sitting/step4b-show.log`): `LOCKED PASS VERDICT: ok`, protected data and `controlCompleteReadable` false before and after, `createWhileLocked`, `saveClean` (40.09 ms), `reopen` "clean", `reopenSnapshotLoads`, `keychainReadable` true. Build 182 had failed only `reopenSnapshotLoads`, on the probe's own sample snapshot (fixed in `1d47a30`). A real session was saved clean while the phone locked (02:12:47, `debug-final.log`) |
| A backup and a restore to the same phone ends in "record deleted" and a new session, never in a resume | manual run, for the verification table of the plan | phone |
| Done 2026-11-14 on charlie (macOS 26): `fcntl(F_FULLFSYNC)` returns 0 on a file and on a directory descriptor on APFS (`~`, `/tmp`, the checkout) and on MS-DOS, ExFAT and HFS+ disk images. No error was seen anywhere (no SMB or NFS share was at hand), so `Storage.fullSyncNotSupportedErrors` is now empty | `Storage.swift`; the whole suite under macOS passes with no fallback | Mac, done |
| The cost of a save and of the first datagram after it on the phone (two to seven full syncs) | `DeviceProbe`: 20 saves of an 80x24 snapshot, `saveMs` and `firstDatagramAfterSaveMs` (min, median, p90, max) in `smoke.json` | phone, done 2026-11-15 (run 0014b1eee2b2, build 117 (87fbbf5)): 20 of 20 clean saves of a 1402-byte snapshot; `saveMs` min 8.652, median 12.013, p90 15.561, max 16.496; `firstDatagramAfterSaveMs` min 4.922, median 6.889, p90 7.957, max 8.346; `createMs` 24.849; `firstReservationMs` 4.313 |
| `lstat` and the errno rule of R20 behave on Darwin as on Linux (`ENOENT` for a missing file; what a locked device returns) | the suite under macOS; a locked-device check (`DeviceProbe` `lstatMissing`, unlocked and in the `--locked` pass) | Mac, phone. Unlocked phone, 2026-11-15 (run 0014b1eee2b2, build 117 (87fbbf5)): `lstat` of a missing file returns -1, errno 2 (`ENOENT`). Locked, 2026-11-21 (build 183, `step4b-show.log`): the same, -1 and errno 2 |
| The app's wiring: save on leaving the foreground, resume after the process was killed (same server), fallback after a death in the foreground and when the server is gone, the key in the Keychain with `AfterFirstUnlockThisDeviceOnly` | `ResumeUITests`, `SessionKeychainTests`, `SessionLauncherTests` | simulator, done 2026-11-14. Phone, 2026-11-15 (run 0014b1eee2b2, build 117 (87fbbf5)): the `DeviceProbe` Keychain probe item reads back `AfterFirstUnlockThisDeviceOnly` (matches, key reads back, item removed) |
| The plan's phone row for M6: same `$$` after 10 minutes in the background, after force-quit, after a new build installed over the old one, after a reboot; "Crash Now" lands in the same tmux after the fallback; `kill -9` of the server is noticed within about 20 s | manual, Build 1 | phone, partly done 2026-11-21 (build 182, a real host of Trick's, `out/yellow/sitting/debug-final.log`, `out/phone/sitting-*.png`). Resumed with the same screen and no banner: after force-quit (02:18:01, the screen still shows `echo $$` 4927), after an install over it (02:18:51), after a phone restart (02:27:04, the screen with `echo $$` 5640). A kill on screen (an install while in the foreground): fallback "the record is dirty", banner, new session 1.67 s after the launch. **But the fallback left the old server running** (`pgrep` showed 4926 beside 5639): every bootstrap to that host logs `pid ?`, so the app cannot stop it (`docs/CLOUD.md`). Open: 10 minutes in the background, "Crash Now", `kill -9` noticed (needs the pid on that host) |
| `kern.bootsessionuuid` readable by the app (stage 2 only, shelved) | `DeviceProbe` `device.bootIdentifier` | phone, 2026-11-21 (builds 182 and 183, every launch): refused, `sysctlbyname` errno 1 (Operation not permitted) at the size step. Stage 1 does not use it |

## Record format

A record is the directory `<root>/<session id>/`, mode 0700, files mode 0600. The
session id is 16 random bytes written as a lowercase UUID (`SessionID`). On Apple platforms
the directory is excluded from backups and, on iOS, has the protection class "until first
user authentication" (R19).

| File | Content | Written |
|---|---|---|
| `meta` | Framed `SessionMeta` | Once, by replace |
| `key` | Framed session key. Not on iOS (Keychain item, account = session id) | Once, by replace |
| `counters` | Two slots | In place, one slot per write |
| `snapshot` | Framed snapshot | By replace, at every quiesce |
| `snapshot.tmp` (also `meta.tmp`, `key.tmp`, `counters.tmp`) | A replace in progress. Never read | |
| `lock` | Empty. Its exclusive `flock` is the lock | |

A record needs `meta`, `counters` and the key. `counters` is written last when a record
is made, so a directory without it is a record that was never finished.

All integers are little-endian. `CRC-32` is the zlib one (polynomial 0xEDB88320
reflected, initial value and final XOR 0xFFFFFFFF; the CRC of `123456789` is 0xCBF43926).

"Replace" is: create `name.tmp` (truncating), write, fsync, rename over `name`, fsync
the directory. fsync is `fcntl(F_FULLFSYNC)` on Apple platforms and `fsync` elsewhere (R21
says what happens when the full sync fails).

### Frame (`meta`, `key`, `snapshot`)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic: `MRm1` (meta), `MRk1` (key), `MRs1` (snapshot) |
| 4 | 2 | Format version, 1 |
| 6 | 2 | 0 |
| 8 | 4 | `n`, length of the body |
| 12 | `n` | Body |
| 12 + n | 4 | CRC-32 of bytes 0 to 12 + n − 1 |

The file is exactly 16 + n bytes. The reader checks length, checksum, version, the
reserved field, and that the body is used up.

### `meta` body

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | Session id |
| 16 | 8 | Created, seconds since 1970 |
| 24 | 2 | UDP port (not 0) |
| 26 | 2 | Server start width (not 0) |
| 28 | 2 | Server start height (not 0) |
| 30 | 2 | 0 |
| 32 | 4 | `mosh-server` pid, 0 if unknown |
| 36 | 8 | Server process start time, 0 if unknown |
| 44 | 2 + a | Host name as the user gave it: length, UTF-8 |
| | 2 + b | Numeric address the datagrams go to (not empty) |
| | 2 + c | User |
| | 2 + d | Remote command (empty: login shell) |

Strings are at most 4096 bytes and must be valid UTF-8. The plan called this file
`meta.json`; it is binary like the other parts so that it has the same checksum and
strictness. `moshcli` can print it for scripts.

### `key` body

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | Session id |
| 16 | 16 | The AES-128 session key |

### `counters`

8192 bytes. Slot 0 is at offset 0, slot 1 at offset 4096; the rest is zero and not read.
The slots are a block apart so that a torn write of one cannot touch the other.

| Offset in slot | Size | Field |
|---|---|---|
| 0 | 4 | Magic `MRc1` |
| 4 | 2 | Format version, 1 |
| 6 | 1 | State: 0 clean, 1 dirty, 2 ended |
| 7 | 1 | 0 |
| 8 | 8 | Generation, 1 or more. A slot with generation `g` belongs in slot `g mod 2` |
| 16 | 16 | Session id |
| 32 | 8 | `seqReserved`: no sequence number at or above it has been used |
| 40 | 8 | `numReserved`: the same for client state numbers |
| 48 | 8 | `fragIdReserved`: the same for fragment ids |
| 56 | 8 | Snapshot id: not 0 when clean, 0 otherwise |
| 64 | 4 | CRC-32 of bytes 0 to 63 |

Writing: generation `g + 1` goes to slot `(g + 1) mod 2`, which is the older one, then
fsync. A new record has generations 1 and 2, both "dirty" with limits (0, 1, 1): nothing
reserved, no snapshot.

Reading (`CountersFile.read`): a slot counts if it is 68 bytes that pass the checksum
and every field check, carries this session's id, and sits in the place of its
generation. No valid slot: the record is unusable. One: it is the reading. Two: they must
be consecutive generations and the newer must hold no lower limit, or the record is
unusable; the newer one is the reading.

### `snapshot` body

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | Session id |
| 16 | 8 | Snapshot id, random, not 0. The clean mark in `counters` names it |
| 24 | 1 | Version of the terminal serialization (`TerminalSerialization.version`, 1) |
| 25 | 1 | Flags: bit 0 a terminal size is present, bit 1 clipboard writing enabled, bit 2 `lastSeen` present, bit 3 `lastWrittenHash` present; bits 4 to 7 are 0 |
| 26 | 2 | 0 |
| 28 | 8 | `acknowledgedStateNumber` (`A`) |
| 36 | 8 | `highestAckSent` |
| 44 | 8 | `usedCounters.sequence` |
| 52 | 8 | `usedCounters.state` |
| 60 | 8 | `usedCounters.fragmentID` |
| 68 | 8 | `receiverExpectedSequence` |
| 76 | 2 | Terminal size width (0 without flag bit 0) |
| 78 | 2 | Terminal size height (0 without flag bit 0) |
| 80 | 8 | Clipboard `lastWrittenHash` (0 without flag bit 3) |
| 88 | 4 + 4k | Clipboard `lastSeen`: count `k`, then `k` code points of 4 bytes (`k` = 0 without flag bit 2) |
| | 4 + … | Pending input: the number of events `e`, then items until `e` events are read |
| | 4 + … | Row table: the number of rows `r`, then `r` times (4-byte length, `Row.serialized()` bytes) |
| | 4 + … | Remote states: the number `s` (1 or more), then `s` states |

Input item:

| Bytes | Meaning |
|---|---|
| `00`, 4-byte `k` (1 or more), `k` bytes | `k` byte events |
| `01`, 2-byte width, 2-byte height (neither 0) | A resize event |

Two `00` items never follow each other, so a list of events has one encoding.

Remote state:

| Size | Field |
|---|---|
| 8 | State number (ascending from state to state, never 2^64 − 1) |
| 8 | `discardedReplyBytes` |
| 8 | `echoAckRegressions` |
| 4 + … | Length, then `TerminalState.serializedWithoutRows()` (the "skeleton": everything of the terminal but the cells) |
| 4 + 4h | The number of lines `h`, then for each line the index of its row in the row table |

The bytes of a row and of a skeleton are defined at the top of
`Sources/MoshTerminal/Serialization.swift` (version 1). Rows are stored once and shared
between lines and states, because the held states differ in a few lines and because
which lines share a row object is part of the state (the display diff's scroll shortcut
uses it). Row indices appear in order of first use, and every row of the table is used.

Beyond the shape the reader checks: the state `highestAckSent` is held;
`usedCounters.state` is above `A`; `usedCounters.sequence` is at most 2^63; `h` equals
the skeleton's height and every row has its width. A new session with a
blank 80x24 screen is 292 bytes; eight held states of a full 80x24 screen of text, 30
new lines between each, are about 15 KB.

The stage 2 journal's `CHECKPOINT` record is meant to be this body.

## Storage steps

Every change on disk is a named step, `file.operation`, that a `StorageHook` sees before
it happens (`dir` is the session directory, `root` the directory above). `moshcli
--crashpoint` uses these names.

| Operation | Steps, in order |
|---|---|
| Make a record | `root.mkdir`, `dir.mkdir` (fails if the directory exists), `dir.protect` (out of backups), then replace `key`, replace `meta`, replace `counters`, `root.fsync`. If a step after `dir.mkdir` fails: `remove` of every file and of the directory |
| Replace `X` | `X.tmp.create`, `X.tmp.write`, `X.tmp.fsync`, `X.rename`, `dir.fsync` |
| Reserve a block, or dirty before send, or `beginSending`, or `markEnded` | `counters.write`, `counters.fsync`, `counters.write`, `counters.fsync` |
| Save a snapshot (`SessionRecord.save`) | replace `snapshot`, then `counters.write`, `counters.fsync` (the clean mark) |
| `shutdown()` | `markDirty` (nothing if already durable), then `markEnded` |
| `markDirty` (return to the foreground; before input in the background) | `counters.write`, `counters.fsync`, `counters.write`, `counters.fsync`; nothing if "dirty" is already in both slots |

Whole processes, as `moshcli --step-log` shows them: "connect, type a line, quiesce" is 38
steps (19 to make the record, 12 for the first reservation of each counter, 7 for the save);
"resume, type a line, quiesce" is 11 (4 for the cold start's counters change, 7 for the save).
