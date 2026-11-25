# Refutation of the two MoshResume reviews

Refuter's verdicts on `resume-review-a.md` (A-1 .. A-8) and `resume-review-b.md` (B-1 .. B-7),
against `cloud-work` at `0c923af` (code as at `c7ddc83`), 2026-11-13. No repo file was changed
except this one.

How it was checked: a copy of the repo at
`/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/refute-resume`
with the reviewers' `ReviewAConfirmTests.swift` and `ReviewBTests.swift` and my own
`Tests/MoshResumeTests/RefuterTests.swift` (4 tests: A-1 through the coordinator, A-1 on a held
record, A-6, B-7). `scripts/dev.sh swift test --filter 'RefuterTests|ReviewAConfirmTests|ReviewBTests'`:
14 tests, 19 failed assertions. Every reviewer test fails as its report says. `ReviewAFuzzTests`
was not run again. B-6, A-7 and A-8 were judged by reading only.

Severity scale used here:

- **critical**: N1-N4 reachable by the app used as PLAN section 3 describes. (None.)
- **major**: N1-N4 reachable through a public call with no fault injected, or a plan requirement
  broken in normal use.
- **minor**: a session lost or mishandled, needing a second fault (storage error, a kill in a
  narrow window) or a wrong call order.
- **low**: hardening; trigger unproven or outside the stated crash model.

## Summary

| Id | Verdict | Severity | Reproduced |
|---|---|---|---|
| R1 = A-1 | SURVIVES | major | yes, also through `ResumeCoordinator.create` |
| R2 = A-2 | SURVIVES | major (open requirement, not a bug in written code) | not on Linux |
| R3 = A-3 + B-3 | SURVIVES | minor | yes (both tests) |
| R4 = A-4 | SURVIVES | minor | yes |
| R5 = A-5 | SURVIVES-WITH-CHANGED-SEVERITY | low | yes |
| R6 = A-6 + B-4 | SURVIVES | minor | yes (A-6 by my test, B-4 by B's) |
| R7 = A-7 | SURVIVES-WITH-CHANGED-SEVERITY | low | no (trigger unproven) |
| R8 = A-8 | SURVIVES-WITH-CHANGED-SEVERITY | low | no (Darwin only) |
| R9 = B-1 | SURVIVES | major | yes |
| R10 = B-2 | SURVIVES | minor | yes |
| R11 = B-5 | REFUTED | none (one doc sentence) | behaviour yes, defect no |
| R12 = B-6 | SURVIVES | minor | no (by reading) |
| R13 = B-7 | SURVIVES | minor | yes (my test) |

No finding is critical: the app used as the plan describes cannot reach N1-N4 through any of
them. R1 and R4/R5 reach N1/N2 only through a call the app has no reason to make, but CLAUDE.md
asks for "impossible by construction", and each of the three is closed by a few lines.

---

## R1 (A-1): `create` over an existing record resets the counters. SURVIVES, major

Tried to refute: (a) the lock stops it; (b) the app cannot get there.

- (a) Only while the first holder lives. `Storage.swift:210` accepts `EEXIST`,
  `SessionStore.swift:138-143` then takes the free lock and replaces `key`, `meta` and
  `counters` with the initial image. On a held record the second create throws `locked`
  (`RefuterTests.testA1_CreateOverAHeldRecordIsRefused` passes).
- (b) The app's own entry point does it: `RefuterTests.testA1_CoordinatorCreateTwice`
  (`ResumeCoordinator.create` twice with the same `meta` and key, the first closed) makes the
  second record. Reviewer's test: `used [0, 1, 2, 3, 4] after second create: 0 key equal: true`.

Reach: a new bootstrap gives a new key (mosh-server makes one per start), and
`SessionMeta.init` defaults to a random id, so the designed flow never repeats the pair. It needs
an app that calls `create` with a stored `meta` and the Keychain key of that id, for example
"no coordinator in memory, so create one" after a relaunch. That is a bug in the app, and the
result is N1 with nothing to notice it. Severity stays major because the rule is "by
construction" and the fix is one condition.

Fix: `SessionStore.create` fails if the session directory exists (`mkdir` returning `EEXIST`
is `RecordError.exists`, a new case; only the root may exist). If a later step of the create
fails, remove what was made (the lock is held), so that a retry with the same id is possible
before anything was sent. `ResumeCoordinator.create` needs no change.

Test (fails now, passes after): `ReviewAConfirmTests.testCreateOverAnExistingRecordResetsCounters`
rewritten to expect `XCTAssertThrowsError` from the second `SessionRecord.create`, plus the
coordinator form (`testA1_CoordinatorCreateTwice`). Keep
`testADirectoryThatNeverBecameARecordIsDeleted` green.

## R2 (A-2): nothing sets or checks "excluded from backup". SURVIVES, major (open requirement)

Tried to refute: "the notes already give this to the app". True (`wave2-resume.md:120-122`), and
no app code exists yet, so nothing written is wrong. But the reasoning of the finding holds: an
`AfterFirstUnlockThisDeviceOnly` item is restored to the same device, the plan's rule "key
without files deletes the record" covers only an excluded directory, and a restored `counters`
with old limits and a clean mark resumes under the old key (N1; N2 if the server lives). The
package creates the root itself (`Storage.swift:200-208`), so an app that forgets the attribute
gets no error. The single protection against N1 after a restore must not be a line in a doc.

What can be written and tested on Linux now:

- A seam in `MoshResume`, for example `RecordProtection { apply(directory:) throws;
  verify(directory:) throws -> Bool }`, given to `SessionStore`. `create` calls `apply` on the
  session directory right after `dir.mkdir` (as a named storage step, so the crash test covers
  it) and fails the create, leaving nothing, if it throws. `SessionRecord.open` calls `verify`
  and a false answer is a fallback (`.damaged("not excluded from backup")`), never a resume.
- Linux tests with an injected protection: create fails and leaves no directory when `apply`
  throws; a clean record whose `verify` says false falls back and sends nothing; a throwing
  `verify` is `retryLater`.
- The Darwin implementation behind `#if canImport(Darwin)`: `URLResourceValues.isExcludedFromBackup
  = true` with `setResourceValues` in `apply`, read back with `resourceValues(forKeys:)` in
  `verify`; under `#if os(iOS)` also `FileAttributeKey.protectionKey =
  .completeUntilFirstUserAuthentication`. It can be written now and compiled later.
  Note for whoever writes it: on Linux the same Foundation calls compile, `setResourceValues`
  returns without error and the value reads back nil (tried here), so the Linux default must be
  an explicit no-op, not the Darwin code. The Linux default `verify` answers true.

What needs the Mac (charlie): compiling the Darwin branch; a macOS `swift test` that reads the
attribute back after `SessionRecord.create` and after a snapshot replace (the attribute is on the
directory; check that replacing files inside does not clear it). What needs the simulator or
the phone: the protection class reads back; a real backup and restore to the same phone ends in
"record deleted", not in a resume (one manual run, for the verification table).

## R3 (A-3 + B-3): a second save of a clean record can only lose it. SURVIVES, minor

Same defect seen from the record (A) and from the coordinator (B). Confirmed by both tests:
after `snapshot.rename` of the second save and before its clean mark, the counters name S1 and
the file is S2; `loadSnapshot` answers `snapshotDoesNotMatch` (4 of 14 kill points).

Tried to refute by reach: `sceneWillResignActive` always pairs with `sceneDidBecomeActive`, and
`enterForeground` makes the record dirty, so resign/active/resign never saves a clean record
twice. A double call needs an app that also saves in `sceneDidEnterBackground`, which the plan
does not ask for. But the coordinator's doc says "Safe to call again while in the background"
(`ResumeCoordinator.swift:405-406`), and that sentence is false. Also real: when the second
mark's write fails, `recordState` keeps saying `.clean(S1)` while a cold start falls back. No N
failure. Minor stands.

Fix: in `runEnterBackground`, if `inBackground` is already true and `record.state` is clean,
return `.clean` without exporting or saving (`ResumeCoordinator.swift:415-425`). Background
input is unaffected: it makes the record dirty first. `SessionRecord.save` stays as it is.

Test: `ReviewBTests.testB3_ASecondSaveNeverMakesAResumableRecordUnresumable` (fails now with 4
lost; after the fix the second call makes no storage step, so `lost == []`). A's
`testSecondSaveKilledAfterRenameLosesTheCleanRecord` calls `SessionRecord.save` directly and
will still fail; drop it or move it to the coordinator.

## R4 (A-4): a stale snapshot id can be marked clean. SURVIVES, minor

Confirmed (`marked: true loaded epoch: Optional(1)` after 2 datagrams).
`FileBackedGate.swift:187-192` sets `storedSnapshotID` without the token, and the refused
`markClean` at `:205` leaves it set.

Tried to refute by reach: with the export's own token the second call is refused too; the
exploit reads `gate.datagramsPassed` afresh, or marks with a newer export's token without
storing that export. No code in `Sources` does either (`SessionRecord.save` is the only caller
of both calls). So it takes a second snapshot writer that skips `SessionRecord`. The claim R6
of RESUME.md ("no clean mark on the gate's own word") is nevertheless false as written, the
result would be N2, and the fix is small.

Fix: one call instead of two. `FileBackedGate.markClean(snapshotID:ifDatagramsPassed:)`
(internal, used by `SessionRecord.save`) checks the token and writes the mark for that id;
`snapshotStored(id:)` and the stored id go away; the protocol's
`markClean(ifDatagramsPassed:)` on a `FileBackedGate` always throws `noSnapshotStored`.

Test: `ReviewAConfirmTests.testStaleStoredSnapshotID` (after the fix the second call throws;
assert that and `XCTAssertNil(loaded)`). `testNoCleanMarkWithoutAStoredSnapshot` and the crash
test stay green.

## R5 (A-5): two gates on one lock. SURVIVES-WITH-CHANGED-SEVERITY, low

Confirmed (both gates hand out 0). But nothing outside `SessionRecord` builds a gate (grep: two
call sites, both in `SessionRecord.swift`), `moshcli` wraps the record's gate, and the app is
to use the coordinator only. It is a visibility mistake, not a path.

Fix: `FileBackedGate.init(store:lock:blocks:)` and `SessionStore.acquireLock()` become internal
(tests use `@testable import`). Optionally the lock remembers that a gate was made from it.

Test: `testTwoGatesOnOneLock` with the optional part (second init throws); with visibility
alone there is nothing to run, a test without `@testable` no longer compiles.

## R6 (A-6 + B-4): a failed "ended" mark. SURVIVES, minor

Two faces of `ResumeCoordinator.markEnded` (`:464-473`) treating a failed write as done:

- A-6, confirmed by `RefuterTests.testA6_HalfWrittenEndedIsOverwrittenByDirty`: first slot
  "ended", second write fails, memory stays "dirty" (`FileBackedGate.swift:255-256` sets the
  state after the writes), then `markDirty` puts "dirty" over both slots. Disk before: `ended`;
  after: `dirty`. Next start: `.fallback(.dirty)`, a new session for one the user closed.
- B-4, confirmed by B's test: in the background both "ended" and "dirty" fail, `ended = true`
  is set all the same, the shutdown is passed on and returns true; the record is still clean and
  the next start resumes the closed session. Found on the way: with `ended` set, later
  background input skips the M9 path (`:495`, `guard inBackground, !ended`), so it is accepted
  with the record still clean. That is the M9 hole again, behind a storage failure.

Tried to refute by reach: both need a counters write to fail (disk full on a copy-on-write
file system, or the device before first unlock), and B-4 also needs a shutdown asked for in
the background. Rare, no N failure. Minor stands; C7's words "even if the write failed" are
not met.

Fix:
1. Gate: `markEnded` sets `state = .ended` (and `notCleanIsDurable = false`) before it writes;
   `willSendDatagram` and `markDirty` write "ended", not "dirty", when the state is ended and
   not yet durable. A later successful write of any kind then completes the mark, and nothing
   can write "dirty" over it.
2. Coordinator: `runShutdown` sets `ended` and passes the request on only if the record is
   durably not clean afterwards (ask the gate); otherwise it yields `.gateFailed`, returns
   false and changes nothing, as input does in C6.

Tests: `RefuterTests.testA6_...` (expects `ended` on disk after the retry; fails now) and
`ReviewBTests.testB4_AShutdownThatCannotBeRecordedIsNotResumed` (fails now). Add: after a
refused background shutdown, `type()` still takes the M9 path.

## R7 (A-7): `access()` decides "missing". SURVIVES-WITH-CHANGED-SEVERITY, low

By reading, the code is as described: `Storage.swift:192-194` maps every errno to "no", and
`coldStart` deletes the record on `.missing` (`ResumeCoordinator.swift:262-280`). Refutation
attempt: no errno other than `ENOENT` is shown to occur. `access(F_OK)` is a metadata call; data
protection "until first unlock" blocks reading content, not `stat`; the app has no background
mode that starts it before the first unlock; as root nothing but `ELOOP`/`ENOTDIR` can be
produced, and those are damaged records. The reviewer says the same. What remains is that the
one destructive action of the cold start hangs on a call that cannot report an error. Low.

Fix: `exists` goes; `openExisting` and `read` map `ENOENT` to missing and everything else to
`StorageError.io` (so `retryLater`). `store.exists` for the directory uses `stat` with the
same rule.

Test (not as root, like `testAStorageErrorAtOpenIsRetriedLater`): session directory mode 000
after a clean save; `coldStart` must be `.retryLater(.storage)` and the directory must still be
there. Fails now only if the reviewer's reading is right for `EACCES`, which the test settles.

## R8 (A-8): any `F_FULLFSYNC` failure falls back to `fsync`. SURVIVES-WITH-CHANGED-SEVERITY, low

By reading: `Storage.swift:256-263`. Against it: power loss is outside the stated model
(RESUME.md, "Not covered"); SQLite does the same fallback; for most errors (`EIO`, `EBADF`)
`fsync` fails as well and the error is thrown. One real case: `EINTR` from `fcntl` silently
becomes a plain `fsync`. The phone has a battery, but a kernel panic is a power loss for this
purpose, and the plan names `F_FULLFSYNC` for every limit and every "dirty".

Linux now: move the decision into a pure function, for example
`Storage.afterFullSyncFailure(errno:) -> .retry | .fallBackToFsync | .fail`, with `EINTR` →
retry and everything else → fail unless the errno is one the Mac run shows for "not supported";
unit-test the table on Linux. The call itself stays under `#if canImport(Darwin)`.

Needs the Mac: which errno Darwin returns where `F_FULLFSYNC` is not supported (do not guess;
if the app's container and the test directory are APFS, the simplest rule is no fallback at all
on Darwin), that the whole suite passes with it, and the cost of a save on the phone (two to
seven full syncs per operation).

## R9 (B-1): "ended" hides "given up, new session owed". SURVIVES, major

Confirmed by both tests: after `.fallback(.dirty)` the second cold start says `.ended` with
`wantsNewSession == false`; the same after `abandon()`.

Tried to refute: (a) the app can remember the debt in its own list; (b) nothing is damaged.
(a) is possible but is exactly what the record is for, and RESUME.md tells the app to delete
on `.ended`. (b) is true: no N failure and the session was already unresumable. What is lost
is the plan's fallback itself (banner, new session, kill of the old `mosh-server`), in normal
use with no fault but a process death in a window that lasts until the new bootstrap succeeds,
which needs the network. The old server and its shell then stay for good
(`mosh-server.cc:384`: no timeout unless `MOSH_SERVER_NETWORK_TMOUT`). It is the only finding
besides R2 that the app reaches as designed, so major stands, as "plan requirement broken",
not as a protocol failure.

Fix (no format change): a record that is given up is written "dirty", not "ended".
- `coldStart` fallback (`:305-311`): `try? record.gate.markDirty()` instead of `markEnded()`
  (nothing to write if it already says dirty).
- `runAbandon` and `handle` for `.baseStateLost` / `.halted`: set the coordinator's `ended`
  flag (no more saves) and make "dirty" durable. Only `shutdown()`, `.serverEnded` and
  `.shutdownFinished` write "ended".
- "Dirty" is never resumed (R7 of RESUME.md) and no coordinator is built on it, so the next
  start repeats `.fallback(.dirty)` with `meta` until the app calls `deleteRecord`.
- For "ended": `ColdStartFallback.meta` is already returned. Change RESUME.md's row to: run the
  identity check and kill the server if it is still there (a shutdown request that never
  arrived), then `deleteRecord`. Correct the comment "The server is normally gone" (`:15`).

Tests: `ReviewBTests.testB1_AFallbackThatTheAppDidNotFinishStillWantsANewSession` and
`testB1_AnAbandonedSessionStillWantsANewSession` (fail now). The existing
`testLeavingTheForeground…` (third start `.ended`) and `testAnAbandonedSessionIsNotResumed`
must be changed to the new meaning; C4 in RESUME.md too.

## R10 (B-2): input before `start()`. SURVIVES, minor

Confirmed, six assertions: a socket is opened and a datagram leaves before `start()`, the
record is dirty, `enterBackground()` answers "not started" without quiescing, one more datagram
1.5 s later, the next cold start falls back.

Tried to refute: it is a wrong call order, and the gate still wrote "dirty" first, so no number
is reused (true, and why this is not major). But the order is likely (a terminal view reports
its size at first layout; `start()` may have thrown its documented storage error), the docs say
"Nothing is sent before `start()`", and the coordinator exists so that the order cannot be got
wrong. A resumable session is lost.

Fix: `runInput` before `started` does not reach the session: `resize` keeps the latest size and
applies it in `runStart`; `type` returns false. `runEnterBackground` before `started` quiesces
and returns what the record says (`.clean` for an unstarted restored session, whose snapshot
is still the truth). Optionally `MoshConnection.pump()` opens no socket before `start()`.

Test: `ReviewBTests.testB2_InputBeforeStartSendsAndTheSessionIsThenLost` (fails now).

## R11 (B-5): input in the foreground while the gate cannot write. REFUTED

The behaviour is as described (test: 4 pending events after the resume, 13 bytes missing). It
is not a defect:

- C6 and M9 are about a record that was saved as clean and then silently lacks accepted input.
  They promise it for the background, and `type()`'s doc promises the snapshot only "in the
  background". In the foreground `true` never meant durable: every foreground death loses
  input, and by design it loses the whole session (fallback).
- Here the gate let no datagram pass, so the server never saw the bytes, the user saw no echo,
  and the app got `.gateFailed` every second. A process death then resumes the session as the
  server has it. That is a better outcome than the designed one for a death in the foreground,
  with no protocol damage and nothing the server and client disagree on.
- The proposed fix (refuse input, or stay "in the background" until "dirty" is written) trades
  this for refused keystrokes during a storage fault. Arguable either way; not required.

Action: one sentence at `type()` and in C9 that a resume after a failed "dirty" continues
without input typed since. No code, no test.

## R12 (B-6): a clipboard copy at the save is written twice. SURVIVES, minor

Not reproduced; read in `MoshSession.swift`. `exportState()` (`:238-244`) awaits the connection
and then reads `clipboard` on the session actor; `reportNewestScreen()` (`:348-355`) awaits the
connection and then observes. Both are suspended on the same actor hop, the session actor is
re-entrant, and nothing orders the two continuations. If the export's runs first, the snapshot
pairs a transport state that has the copy with a policy that has not seen it; the live process
then emits `.clipboard(.write)`, and after a kill `start()` (`:170-175`) observes the stored
screen against the stored policy and emits it again. The comment at `:160-166` ("that copy was
never written") assumes the process died before the event was handled, which it need not.

Could not refute. The window is one actor hop wide and needs a copy on the host within it, then
a kill in the same background period (the next save stores the updated policy). The effect is a
pasteboard overwritten with an old copy at the next launch. Minor, last in the order.

Fix: `exportState()` brings the policy up to the exported newest state before it builds the
snapshot: after the await, with no further suspension, do what `reportNewestScreen` does for
the newest state of the exported snapshot (yield `.screen` if new, `report(clipboard.observe(...))`),
then put `clipboard` into the snapshot. Policy and transport then describe one state; the later
event finds `lastScreenNumber` equal and does nothing.

Test: the one B sketches. It needs a seam that holds back the session's reader: deliver a state
with a clipboard, `quiesce()`, `exportState()`, release the reader, expect exactly one
`.clipboard(.write)`; restore from the snapshot, `start()`, expect none.

## R13 (B-7): `coldStart(key: nil)` on a record without a key file ends it. SURVIVES, minor

Confirmed by `RefuterTests.testB7_NilKeyOnARecordWithoutKeyFile`: `create(storesKey: false)`,
clean save, `coldStart(key: nil)` → `fallback(the record has no key)`, then
`coldStart(key: key)` → `fallback(the session was ended)`.

Tried to refute: the doc comment forbids the call (`:243-245`). A rule in a comment, with nil as
the default argument, on the platform where the key is always external, and a permanent loss as
the price: `try? keychain.read(...)` on a locked device is the obvious way to get there, and
the plan says locked means "try again later, never dead". Not an N failure.

Fix: no default and no optional. `coldStart(root:id:key: KeySource, ...)` with
`enum KeySource { case recordFile; case provided(Base64Key) }`. The app passes `.provided`;
`moshcli` passes `.recordFile`. A nil key can then not be written by accident. With R9's fix a
`.missing(.key)` fallback also no longer writes "ended", so even the wrong case is repeatable.
(The stronger form, a flag in `meta`'s reserved field saying the key is external, is a format
change and not needed for this.)

Test: `testB7_...` adapted: `.recordFile` on a record made with `storesKey: false` gives
`.fallback(.missing(.key))`, and a following `.provided(key)` resumes (needs R9's fix).

---

## Fix order

1. **R1** (A-1): refuse `create` over an existing directory. One condition, closes N1 by misuse.
2. **R9** (B-1) with **R13** (B-7): both change what the cold-start fallback writes and the
   `coldStart` signature; do them in one change with the test and RESUME.md updates (C4, the
   outcome table).
3. **R6** (A-6 + B-4): "ended" intent in the gate, refused shutdown in the coordinator.
4. **R3** (A-3 + B-3): no second save of a clean record.
5. **R10** (B-2): nothing reaches the session before `start()`.
6. **R4** and **R5** (A-4, A-5): one clean-mark call with the snapshot id; internal gate init
   and lock.
7. **R2** (A-2): the `RecordProtection` seam and its Linux tests now; the Darwin branch with the
   first macOS compile; read-back on charlie, restore test on the phone. Must be in before the
   app wires resume (wave 2, item 6).
8. **R7**, **R8** (A-7, A-8): errno handling of `exists` and of the full sync; the pure
   decision function now, the errno facts from charlie.
9. **R12** (B-6): clipboard policy in the export.
10. **R11** (B-5): one doc sentence.

Items 1 to 6 and the Linux half of 7 and 8 are Linux work. Needs the Mac: Darwin branches of R2
and R8. Needs the phone: file protection read-back and the backup/restore run of R2.

---

## Status

Fixes made in cloud round 9 (2026-11-13), in the order above, one commit per group. Every test
named here was seen failing on the code before its fix (for new seams: with the old rule behind
the new name, or with the new calls removed) and passes after. Tests are in
`Tests/MoshResumeTests/ReviewFixTests.swift` unless another file is named. The reviewers'
scratch tests in this folder are kept as they were written; they no longer compile against the
package (`coldStart` takes a key source, the gate's init is internal).

| Finding | State | Commit | Tests |
|---|---|---|---|
| R1 = A-1 | fixed | `a318632` | `testA1_CreateOverAnExistingRecordIsRefused`, `testA1_CreateOverAHeldRecordIsRefused`, `testA1_TheCoordinatorDoesNotCreateTwice`, `testA1_AFailedCreateLeavesNothingAndCanBeRepeated` |
| R9 = B-1 | fixed | `b19a691` | `testB1_AFallbackThatTheAppDidNotFinishStillWantsANewSession`, `testB1_AFallbackForADamagedSnapshotStillWantsANewSessionLater`, `testB1_AnAbandonedSessionStillWantsANewSession`, `testB1_AShutDownSessionSaysEndedWithMeta` |
| R13 = B-7 | fixed | `b19a691` | `testB7_AskingARecordWithoutAKeyFileForItsKeyDoesNotEndIt` |
| R6 = A-6 + B-4 | fixed, in a different order than proposed (below) | `8732981` | `testA6_AHalfWrittenEndedMarkIsCompletedNeverOverwritten`, `testA6_NoDatagramPassesWhileTheEndedMarkCannotBeWritten`, `testB4_AShutdownThatCannotBeRecordedIsRefused`, `testB4_AnEndedMarkThatFailedIsCompletedAtTheNextWrite` |
| R3 = A-3 + B-3 | fixed in the coordinator; `SessionRecord.save` unchanged, as proposed | `c7daed4` | `testB3_ASecondSaveNeverMakesAResumableRecordUnresumable`, `testB3_ASaveStillHappensWhenSomethingChanged` |
| R10 = B-2 | fixed in the coordinator; the transport is unchanged | `7d6068e` | `testB2_InputBeforeStartSendsNothingAndKeepsTheRecord`, `testB2_AStartAskedForInTheBackgroundHappensInTheForeground` |
| R4 = A-4 | fixed | `d0543db` | `testA4_ARefusedSaveLeavesNoSnapshotIDToMark` |
| R5 = A-5 | fixed, with the optional part | `d0543db` | `testA5_ASecondGateOnOneLockIsRefused` |
| R2 = A-2 | Linux half fixed; Darwin branch written, not compiled | `4f4a0cd` | `RecordProtectionTests` (7 on Linux; `testTheAppleProtectionReadsBack` is compiled on Apple platforms only) |
| R7 = A-7 | fixed | `e3a21b3` | `testA7_ARecordThatCannotBeLookedAtIsRetriedLaterNotDeclaredMissing`, `testA7_OnlyNoSuchFileMeansMissing` |
| R8 = A-8 | decision and sync loop fixed and tested with played calls; Darwin checked on charlie 2026-11-14: the call succeeds on files and directories on APFS, MS-DOS, ExFAT and HFS+, no "not supported" errno was seen, the list is empty (no fallback) | `e3a21b3` | `testA8_WhatFollowsAFailedFullSync`, `testA8_TheSyncWithPlayedCalls` |
| R12 = B-6 | fixed, and reproduced first | `c3c9a85` | `MoshSessionTests/ExportClipboardTests.testACopyThatArrivesRightBeforeTheSaveIsWrittenOnceNotAgainAfterARestore` |
| R11 = B-5 | refuted; the doc sentence is written (`type()`, C9 of RESUME.md) | `b541716` | none (no code) |

Where a fix differs from what is proposed above, and why:

- **R6.** Proposed: mark "ended", then let the coordinator ask the gate whether the record is
  durably not clean, and refuse the shutdown if not. With the gate keeping "ended" as its intent
  (part 1 of the fix), a refused shutdown would leave a gate set on ending a record whose
  session lives on: the next write of any kind would put "ended" on disk for a session the user
  is still using, and a later process death would drop it. Built instead: `shutdown()` first
  calls `markDirty()` (nothing to write in the foreground), which either makes "not clean"
  durable or changes nothing, and refuses on failure; only then `markEnded()`. Cost: four more
  storage steps for a shutdown asked for in the background. Neither order can reuse a number.
- **R9.** The cold-start fallback writes "dirty" for every reason except two: an ended record
  stays ended, and `.missing(.key)` writes nothing (the refuter's R13 asks for exactly that, so
  that the right key source still resumes). `giveUp()` (abandon, lost base state, halted) in
  the background with every write failing leaves the record clean; a later start then resumes
  a session the user gave up but that is still valid on the server. That is the safe direction,
  and a `.gateFailed` event says so.
- **R3.** The shortcut needs more than "in the background and the gate says clean": the gate
  also says clean when "dirty" could not be written at a return to the foreground and a later
  save failed after its rename. The coordinator therefore remembers that its last save left the
  record clean (`savedClean`, reset by a return to the foreground and by input).
- **R10.** Beyond the proposal: a `start()` asked for while in the background is deferred to
  `enterForeground()` (a session that began to send there would be dirty and never saved), and
  `enterBackground()` before `start()` does not call `quiesce()` on the session, because nothing
  has reached it. `shutdown()` before `start()` is still passed on (it marks the record first).
  The optional transport change (no socket before `start()` in `MoshConnection.pump()`) was not
  made.
- **R2.** `verify` checks the backup exclusion only, not the protection class: a wrong class
  cannot reuse a number, the simulator reports none, and a false "no" costs a session. The
  protection is a storage step of its own (`dir.protect`), so making a record is 19 steps.
- **R7.** `ENOTDIR` and `ELOOP` are "cannot tell" like every errno but `ENOENT`, although they
  are permanent: a root that is not a directory gives "try again later" for ever instead of a
  fallback. Chosen because the other reading deletes on a guess.
- **R8.** `Storage.fullSyncNotSupportedErrors` is `ENOTSUP` and `ENOTTY`, by what the names
  mean. The refuter said not to guess; the alternative on Linux was an empty list, which would
  fail every sync on a Mac file system without the call. Marked "confirm on the Mac" in the
  code and in RESUME.md. Confirmed on charlie 2026-11-14: no error was seen on any file system
  tried, so the list is empty now.

Existing tests that were changed (reasons also in the commit bodies): every `coldStart` call
names its key source; `testLeavingTheForeground…` and `testAnAbandonedSessionIsNotResumed`
expect `.dirty` where they expected `.ended` (B-1's new meaning; both still assert no resume);
`ResumeEndToEndTests.testAKillAfterReturningToTheForeground…` expects the direct gate call to
throw and `SessionRecord.save` with the old export to return false; `SessionStoreTests.testDelete`
reads `exists` with `try`. No test was deleted.

Needs the Mac (charlie): compile `AppleRecordProtection` and the Darwin branch of
`Storage.fullSync`; `RecordProtectionTests.testTheAppleProtectionReadsBack`; which errno
`F_FULLFSYNC` returns where it is not supported, and whether it works on a directory descriptor;
the whole suite, now that a failed full sync is an error. Needs the phone: the protection class
reads back and a save works on a locked device after first unlock; one backup and restore to
the same phone ends in "record deleted"; the cost of a save. The list with places is in
`docs/RESUME.md`, "Needs the Mac or the phone".
