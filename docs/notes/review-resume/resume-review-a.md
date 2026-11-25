# Resume storage review, angle A (record format, SessionStore, FileBackedGate, lock)

Reviewed on branch `cloud-work` (2026-11-13). Repo files were not changed. Scratch copy with
the tests: `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/resume-review-a`

- Confirming tests (each fails today, one per finding A-1 to A-4):
  `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/resume-review-a/Tests/MoshResumeTests/ReviewAConfirmTests.swift`
- Fuzz test (passes, see "What held"):
  `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/resume-review-a/Tests/MoshResumeTests/ReviewAFuzzTests.swift`
- Run: `scripts/dev.sh swift test --filter ReviewAConfirmTests` (4 tests, 4 failures) and
  `--filter ReviewAFuzzTests` (1 test, passes, 41 s).

No critical finding. The core of the gate (two slots, reserve ahead, dirty before send, clean
names a snapshot) held against everything I threw at it. The findings are at its edges:
public entry points that go round it, and iOS conditions nothing in the package enforces.

## Findings

### A-1 (major, confirmed) `SessionRecord.create` over an existing record resets the counters under the same key

- Where: `Sources/MoshResume/SessionStore.swift:133-146` (`create`), `Sources/MoshResume/Storage.swift:210`
  (`mkdir(...) == 0 || errno == EEXIST`), reached from `SessionRecord.create` (`SessionRecord.swift:53-69`)
  and `ResumeCoordinator.create` (`ResumeCoordinator.swift:210-237`).
- Violated: CLAUDE.md "The four hard failures N1–N4 ... must stay impossible by construction";
  RESUME.md R2 "A restart begins at the reserved limit, never below"; R11 "limits on disk never go down".
- What happens: `create` accepts an existing session directory, takes the (free) lock and replaces
  `key`, `meta` and `counters` with the initial image (limits 0, 1, 1). If the id and the key are the
  ones of a session that already sent, the next gate hands out sequence number 0 again: N1 (and N2, N4).
  Output of the test: `used [0, 1, 2, 3, 4] after second create: 0 key equal: true`.
- How it can be reached: any second `create` with the same `SessionMeta` value and key after the
  first record's holder is gone (the app keeps `meta` in its session list and calls `create` again
  after an error, a state restoration, a retry after `start()` threw and the coordinator was dropped).
  `SessionMeta.id` is a plain `var`, and the fallback hands the old `meta` (with its id) to the app
  for the new bootstrap. With a new key the reset is harmless; nothing checks that the key is new.
- Fix idea: `dir.mkdir` must fail on `EEXIST` (or `create` refuses when `counters` exists).
- Test: `ReviewAConfirmTests.testCreateOverAnExistingRecordResetsCounters`.

### A-2 (major, design gap, not testable on Linux) N1 after a restore from backup depends on an attribute nothing sets or checks

- Where: `Sources/MoshResume/Storage.swift:198-211` (the root is created with `posixPermissions` only);
  `docs/notes/wave2-resume.md:120-122` ("iOS attributes are the app's ... nothing here sets them").
- Violated: PLAN section 3 "Session record, in `Application Support/sessions/<uuid>/` (excluded from
  backup, file protection "until first unlock")" and N1 "impossible by construction".
- What happens: a Keychain item `AfterFirstUnlockThisDeviceOnly` comes back when a backup is restored
  to the same device. If the record directory is in that backup, `counters` and `snapshot` come back
  as they were at backup time: clean, with limits below numbers used since. `coldStart` resumes and
  sends under the same key from the old limit: N1; if the server still lives, N2 as well. The plan's
  rule "a record needs key, counters and meta" only covers the opposite case (key without files).
  The record has nothing that would let a cold start notice that it is older than the key's use.
- Why it is listed although it is a known gap: the notes treat it as an attribute the app sets
  later; it is the only thing between a restore and nonce reuse, and the package creates the root
  itself when the app has not (so a forgotten call fails silently).
- Fix idea: set `isExcludedFromBackup` (and the protection class) in `SessionStore.create` under
  `#if canImport(Darwin)` and fail the create if it cannot be set; a test on the simulator reads
  the resource value back after `SessionRecord.create`.

### A-3 (minor, confirmed) A second save of an unchanged clean record, killed between the rename and the clean mark, ends a resumable session

- Where: `Sources/MoshResume/SessionRecord.swift:107-115` (`save` always replaces the snapshot with a
  new id, then marks), `Sources/MoshResume/ResumeCoordinator.swift:413-422` (`runEnterBackground` saves
  again; documented "Safe to call again while in the background").
- Violated: RESUME.md R8 "A reader finds the old snapshot or the new one" holds for the file, but not
  for the record: after `snapshot.rename` the counters still say clean for the old id, and
  `loadSnapshot` answers `snapshotDoesNotMatch`. The coordinator then marks the record ended.
- Consequence: the session was clean, nothing was sent and nothing changed, yet a process death in
  that window (rename, `dir.fsync`, `counters.write`, `counters.fsync`; with `F_FULLFSYNC` tens of
  milliseconds, and the moment is the one at which iOS suspends the app) gives "Previous session
  could not be resumed". No N failure. The stage 1 crash points do not cover a save that starts clean.
- Fix idea: no save when the record is clean and nothing was accepted since; or keep the old
  snapshot until the new mark is written (snapshot file named by id).
- Test: `ReviewAConfirmTests.testSecondSaveKilledAfterRenameLosesTheCleanRecord`
  (outcome `fallback(... the stored snapshot is not the one the record is clean for ...)`).

### A-4 (minor, confirmed) After a refused save the gate marks a stale snapshot clean on its own word

- Where: `Sources/MoshResume/FileBackedGate.swift:187-192` (`snapshotStored` sets the id whatever
  passed before it), `:201-213` (`markClean`), `SessionRecord.swift:113-114`.
- Violated: RESUME.md R6 "A clean mark carries the id of a snapshot that was durably stored after
  the last datagram; there is no clean mark on the gate's own word"; notes: "the protocol's
  `markClean(ifDatagramsPassed:)` alone cannot make a record clean".
- What happens: export (token N), a datagram passes, `save` stores the snapshot, calls
  `snapshotStored(id)` and `markClean(N)` returns false. `storedSnapshotID` stays set although a
  datagram followed the export. `gate.markClean(ifDatagramsPassed: gate.datagramsPassed)` (the public
  protocol call that `MoshSession.swift:24,237` and `MoshConnection.swift:219` tell a snapshot writer
  to make) now writes "clean" for that snapshot; the next process loads it: a state list shorter
  than what the server saw, N2. Test output: `marked: true loaded epoch: Optional(1)` after 2 datagrams.
- Reach: no caller in the repo does this today (`SessionRecord.save` always stores a new snapshot
  first), so it needs a second caller of the gate. It is the "by construction" claim that is false.
- Fix idea: `markClean` clears `storedSnapshotID` when it refuses; or `snapshotStored(id:token:)`
  keeps the token and `markClean` accepts only that token.
- Test: `ReviewAConfirmTests.testStaleStoredSnapshotID`.

### A-5 (minor, confirmed) One lock object opens any number of gates

- Where: `Sources/MoshResume/FileBackedGate.swift:77-98` (public `init(store:lock:)`),
  `SessionStore.swift:106` (public `acquireLock`), `:121-123` (`check` only asks "is it held").
- Violated: RESUME.md R12 "One writer. A gate ... need the record's `flock`; a second open fails";
  the gate's comment "there is no gate without the lock, and so no second writer".
- What happens: two `FileBackedGate`s made with the same `SessionLock` each start at the limits on
  disk and each hand out the same numbers (test: both return sequence number 0); they also write
  the same generations over each other. N1/N2/N4 inside one process.
- Reach: needs code that builds a gate itself instead of using `SessionRecord` (none in the repo).
- Fix idea: `init(store:lock:)` internal, or the lock remembers that it has a gate.
- Test: `ReviewAConfirmTests.testTwoGatesOnOneLock`.

### A-6 (minor, by reading) A failed "ended" mark is erased by the coordinator's own fallback write

- Where: `Sources/MoshResume/ResumeCoordinator.swift:458-467` (`markEnded` → on error `markDirty`),
  `FileBackedGate.swift:237-247`, `:251-258`, `:281-287`.
- Violated: RESUME.md R16 / C7 "An ended session stays ended ... even if the write failed"; the
  doc comment of `shutdown()`: "never bootstrapped again by a fallback (`FallbackReason.ended`)".
- What happens: `gate.markEnded()` writes slot one ("ended"), the second write fails. In memory the
  state is not ended, so `markDirty()` runs `writeBothSlots(.dirty)`: generations g+2 and g+3 put
  "dirty" over both slots, the half-written "ended" included. After a process death the cold start
  says `.dirty` (`wantsNewSession` true): the app bootstraps a new session for one the user shut
  down, and shows "Previous session could not be resumed". Not an N failure.
- Test idea: coordinator with a hook that fails the third storage step of `markEnded` once;
  `shutdown()`, close, `coldStart`: expect `.ended`, get `.dirty`.

### A-7 (minor, by reading) "Missing" is decided with `access()`, so any error there is treated as "not a record" and the record is deleted

- Where: `Sources/MoshResume/Storage.swift:192-194` (`exists`: every errno is "no"), used at
  `SessionStore.swift:107`, `:170`, `FileBackedGate.swift:79`; `ResumeCoordinator.swift:262-280`
  deletes on `RecordError.missing`.
- Violated: RESUME.md C3 "Fallback or 'try again later', never a guess ... a failed file operation
  ... leave the record untouched"; PLAN "'Device locked' errors ... mean try again later, never dead".
- What happens: `access(F_OK)` failing with anything but `ENOENT` (`EACCES`, `EIO`, `ELOOP`, a
  sandbox denial) reads as `missing(.counters)` or `missing(.meta)`; the cold start then takes the
  lock and deletes the whole record, `meta` included, so the old server can no longer be found.
  I could not show an errno that iOS data protection returns from `access` (metadata normally stays
  readable while locked), so the trigger is unproven; the open/read paths map errors correctly.
- Fix idea: drop `exists`; open and treat only `ENOENT` as missing.
- Test idea (not as root): `chmod 000` on the session directory after `acquireLock`'s check is
  replaced by a hookable `exists`; expect `.retryLater(.storage)`.

### A-8 (minor, by reading, power loss only) A failed `F_FULLFSYNC` is silently replaced by `fsync`

- Where: `Sources/MoshResume/Storage.swift:256-263`.
- Violated: PLAN "The new limit is written with `F_FULLFSYNC` before any number in the block is
  used"; the code's own comment "on Apple platforms `fsync` alone leaves the data in the drive's cache".
- What happens: on Darwin any failure of `fcntl(F_FULLFSYNC)` (not only "not supported") falls
  through to `fsync`, whose success is reported as durable. After a power loss or panic the older
  slot content can be what is on the medium: lower limits (N1) or a stale "clean" (N2). Outside the
  stated model (process death), inside the plan's wording.
- Fix idea: fall back only for `ENOTSUP`/`ENOTTY`/`EINVAL`; otherwise throw.

## What held (checked, no finding)

- Fuzz, 3000 seeds, 5 lives each: random takes, datagrams, saves, stale saves, `markDirty`,
  `beginSending`, `markEnded`; I/O failures injected at 12% of the steps with partial writes; a
  crash (before, after, torn at a random length) at a random step of each life; one slot damaged
  at rest between lives. Never: a number at or below one handed out, a loaded snapshot that a
  datagram followed, an ended record resumed, two slots that contradict each other, an unreadable
  record. So R1, R2, R4, R5, R9, R10, R11, R15 hold also for failure-then-continue sequences, which
  the repo's crash test does not combine.
- Decoding: every part is length-, CRC-, version- and session-checked before use; a slot counts
  only in the place of its generation; a mixed pair (non-consecutive, newer with a lower limit) is
  refused. The snapshot is bound to the clean mark by a random 64-bit id, so a non-durable or
  lost rename gives a mismatch, never a stale resume.
- Overflow: `limits + block` uses `addingReportingOverflow` → `GateError.exhausted`; `next + 1`
  cannot overflow because `next < limits`.
- Lock: `flock` (not `fcntl`), so closing another descriptor of `lock` in the same process does not
  release it, and a second open in the same process is refused; every descriptor is `O_CLOEXEC`.
  The delete paths take the lock first; the race "holder unlinks `lock`, another process creates a
  new one before `rmdir`" ends in a failed `rmdir` and a second delete, not in two writers.
- A reopened "ended" record lets `willSendDatagram` pass without a write, but the first number
  needs a reservation (`next == limits` at open), which writes both slots first.
- Device locked: `open`/`pread`/`pwrite` errors become `StorageError.io` → `retryLater`; no path
  resets counters except A-1.
