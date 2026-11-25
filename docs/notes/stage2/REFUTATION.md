# Refutation of the stage 2 design review, and a second review of steps 3, 6 and 9

Refuter's verdicts on `REVIEW.md` (R2-1 .. R2-13) against `DESIGN.md` (unchanged since
`f155519`), the code at HEAD `b745c72` (`Sources/MoshResume`, `Sources/MoshTransport`,
`Sources/MoshSession`) and mosh 1.4.0 in `.refs/mosh/src`, 2026-11-19. Then a second,
independent review of steps 3, 6 and 9 of the design's section 12 (findings S-1 .. S-5).

- Nothing left over: both parts are complete.
- Nothing was built or run (the build was in use). Every verdict is by reading; every test idea
  is unwritten. "Verified" below means "checked line by line against the design text, the code
  at HEAD and the mosh source", never "reproduced".
- Not covered: anything that needs a device or a run (iOS `kern.bootsessionuuid`, APFS
  behaviour, timings); the app-side changes of step 9 (10.5); sections 9 to 11 except where a
  step cites them; an implementation, since none exists.
- No file but this one was changed. `DESIGN.md` is as it was.

Severity scale (the one of `docs/notes/review-resume/refutation.md`):

- **critical**: N1-N4 reachable by the app used as the plan describes. (None.)
- **major**: N1-N4 reachable through a public call with no fault injected, or a plan requirement
  broken in normal use.
- **minor**: a session lost or mishandled, needing a second fault (storage error, a kill in a
  narrow window) or a wrong call order.
- **low**: hardening; trigger unproven or far outside normal use.
- **doc**: a sentence to correct.

## Summary

| Id | Verdict | Severity (review's, then mine) | Checked against |
|---|---|---|---|
| R2-1 | SURVIVES, lowered | major, minor | design 4.3, 3.5; `FileBackedGate.swift`, `TransportCore.swift`, `ResumeCoordinator.swift` |
| R2-2 | SURVIVES, and wider than stated | major, major | design 3.6, 5, 4.3; `ResumeEndToEndTests.swift`; `user.cc`, `user.h` |
| R2-3 | SURVIVES in part; the N2 path could not be checked | major, not settled (minor for what is confirmed) | design 8, 10.5; no iOS source here |
| R2-4 | SURVIVES | major, major | design 3.2, 4.3, 10.2; `TransportCore.swift`, `ResumeCoordinator.swift` |
| R2-5 | SURVIVES, lowered | minor, low | design 3.3; `UserInput.swift`, `TransportCore.swift` |
| R2-6 | SURVIVES; the scenario as written cannot happen, another one can | minor, minor | `mosh-server.cc`, `transportsender.h`, `TransportCore.swift` |
| R2-7 | SURVIVES | minor, minor | design 3.2, 5, 10.1, 10.3 |
| R2-8 | SURVIVES (acted on: this file's second review covers step 6) | minor, minor | design 12; `Counters.swift` |
| R2-9 | SURVIVES | doc | design 4.4, 13, 2 (L1) |
| R2-10 | SURVIVES | doc | design 11, 2; `TransportCore.swift` |
| R2-11 | SURVIVES, one reason corrected | doc | `transportfragment.cc`, `completeterminal.cc`, `mosh-server.cc` |
| R2-12 | SURVIVES | doc | `ResumeCoordinator.swift`; design 5, 10.4 |
| R2-13 | SURVIVES | doc | `ResumeEndToEndTests.swift`, `SessionLauncher.swift`, `Resume.swift` |

No finding is refuted outright. Two are lowered, one scenario is replaced, one stays open on a
fact about iOS. I agree with the review that nothing is critical.

Second review:

| Id | Severity | Step | One line | State |
|---|---|---|---|---|
| S-1 | major | 9 | `shutdown()` before a successful `start()` writes `open(b)` through `markOpen()` on a stage 1 record that has no journal of its own: R2-2's end by a door R2-2's fix leaves open | verified against text and HEAD |
| S-2 | minor | 9 | After a `sealed` slot write that failed half way, the next seal or compaction renames while a slot names the older checkpoint: the A-3/B-3 window is back. A failed `markOpen` has the mirror problem | verified against text |
| S-3 | minor | 9 | The torn-tail cut offset outlives its generation: cold start, `enterBackground()` before `start()` (which seals into a new file), then `start()` cuts the new file | not verified (depends on where the offset is kept; the design keeps it outside the journal) |
| S-4 | doc | 3, 9 | Two-frame appends other than `front+remote` have no storage tag; `THROWAWAY` has no replay check and a bad one traps; `FRONT` cannot be replayed by "the code that ran live" | verified against text and HEAD |
| S-5 | doc | 6 | The downgrade argument of 3.6 covers builds that refuse version 2. Builds of steps 6 to 8 read it and make a gate | verified against text |

---

# Part A. Refutation

## R2-1: `dead` is not sticky. SURVIVES, lowered to minor

Tried to refute: (a) the design's `markDead()` could be read as final-before-write like
`markEnded()`; (b) nothing calls `record` after a give-up.

- (a) Does not help. The pseudo-code of 4.3 has three lines: retired when ended or dead is *in
  both slots*; `ended` asked for and not in both; and "state is not open, or open is not known
  to be in both slots -> write open(b)". A gate that took `dead` as its intent and has it in one
  slot only is "not open", so the third line writes `open(b)` over it. Whichever way `markDead()`
  keeps its intent, the text overwrites the mark. Row H3 of section 6 accepts "`open(b)` or
  `dead`" for a kill; it says nothing of a write that failed with the process alive.
- (b) False at HEAD. `TransportCore.receive` (`TransportCore.swift:270-295`) checks `isQuiesced`
  only, not `isHalted`: a halted transport still processes instructions, and in stage 2 that
  means `record`. `handle(.baseStateLost / .halted)` calls `giveUp()` and leaves the session
  running (`ResumeCoordinator.swift:716-718`, `:566-573`). `runAbandon` closes the session after
  `giveUp()` (`:686-690`), with a suspension in between.

Why lowered: it needs a storage failure inside the two slot writes of `markDead()` (the scale's
"second fault"), and it ends in no N1-N4: numbers come from `counters`, and the journal that is
resumed is a true one (a halted transport's fault was in memory, and `Outbox.send` checks the
replayed books again). What is lost is the promise "a new session is owed": after `abandon()` the
app bootstraps a new session and may kill the old server, and the old record is listed as
resumable and resumes into the 15 s probe.

Smallest change: as the review says. `markDead()` sets the intent first; `record` gets the line
"dead was asked for, not yet in both -> write it to both slots; then return"; every other slot
write of that gate writes `dead`. One sentence in 3.5: `dead` and `ended` are never left.

Test: the review's `testADeadMarkThatFailedHalfWayIsNeverCoveredByOpen`. Add the reservation
form: after the failed mark, `takeStateNumber()` across a block boundary must write `dead`, not
`open`.

## R2-2: `record` on an unconverted stage 1 record. SURVIVES, major, wider than stated

Tried to refute: (a) no caller passes a size to a restoring initializer with a file gate;
(b) the gate has no journal object then, so nothing is appended.

- (a) False. `Tests/MoshResumeTests/ResumeEndToEndTests.swift:143` and `:188` build
  `MoshSession(restoring:..., gate: record.gate, currentSize: ...)` today, the second with a size
  that differs. `SessionRecord.gate` is public (`SessionRecord.swift:34`), and so is the
  initializer (`MoshSession.swift:121-129`). The design keeps the path on purpose (5, step 6:
  "a size given there is recorded through the gate like any input"). `moshcli resume` goes
  through `coldStart` (`Resume.swift:139`), which the design builds with nil, so that caller is
  safe.
- (b) Makes it no better. The pseudo-code writes `open(b)` before it appends. With no journal
  the append throws or goes nowhere; either way the record now says `open(b)` in the same boot,
  and the next cold start (5, step 3) takes "the highest `g` among the files": the stale
  `journal.1` of a step 8 build, or none (`.missing(.journal)`: a resumable record lost).
- The N2 chain holds in the source: `diff_from` asserts `my_it != actions.end()` and
  `*i == *my_it` (`statesync/user.cc:68-69`); a Resize and a byte, or two different Resizes,
  are unequal (`statesync/user.h:67`); the diff is taken against the newest held state
  (`networktransport-impl.h:191`).

Wider: the same door is unsafe on a stage 2 record. A restored session of an `open(d)` record
with a torn tail has not cut it yet (the cut is `start()`, step 1). A `record` call from the
restoring initializer then appends before the cut. If the append goes to the end of the file,
the torn frame's length field covers the new frame: the reader says TORN at the old position
(3.4, "rest < 12 + n") and drops an `INPUT` that was applied and may have been sent; the next
process sends other input at that index (N2 by the same assert). If it goes to the cut offset
and is shorter than the torn tail, bytes of the tail stay behind it: DAMAGED, a fallback.

Smallest change: the review's, stated as one rule: **the gate has no journal to append to, and
writes no `open`, until `beginSending()` has cut the tail, converted a stage 1 record and
written `open(b)`.** Before that, `record` throws. The restoring initializers lose `currentSize`
(the Resize is `start()`, step 6, always). See S-1 for the second caller of `open`.

Tests: the review's two, plus `testRecordBeforeTheTailCutIsRefused`: an `open(d)` record whose
journal ends in a torn frame of 40 bytes; build the restored session with another size; assert
that the journal's bytes are unchanged.

## R2-3: the boot identifier is trusted without a run-time check. SURVIVES in part

What I could check: the design text. `BootIdentity.current()` is nil only "if it cannot be
read" (8); nothing rejects an empty or constant string at run time, and FNV-1a of a fixed
string is a fixed non-zero digest, so J6 would then be vacuous. That part stands.

What I could not check: whether any iOS returns a value that is not per boot. There is no XNU
source in this repository. So the N2 scenario is neither confirmed nor refuted; its severity
stays open until step 0 of section 12 has run on the phone.

Two corrections to the finding:

- "Step 0 checks this once" is half right. 10.5, item 5, already has the probe assert "reads,
  is not empty, is the same in two launches, differs after a restart of the phone". The gap is
  that this is a probe on one device and one iOS, not a rule in `DarwinBootIdentity`.
- Part (c), "an unreadable value kills the record and the server", is not a regression. Stage 1
  ends every kill in the foreground that way (`docs/PLAN.md` section 3, "Fallback"). It is an
  improvement stage 2 could have and does not; the review's question 1 to the owner is the
  right place for it.

Smallest change: (a) as the review says (a UUID that parses and is not all zeros, else nil); it
costs a few lines and closes the cases that can be named. (b) a second signal that must also
match can only lose resumes; take it if step 0 shows anything odd, not before. (c) waits for
the owner.

Test: the review's `testEmptyOrZeroIdentifierIsUnknown`.

## R2-4: the initial checkpoint is a second copy of the core's first events. SURVIVES, major

Tried to refute: the coordinator passes one set of values to both, so the two copies cannot
differ.

- For the app that is true: `ResumeCoordinator.create` has one `initialSize` and one
  `meta.serverStartSize` (`ResumeCoordinator.swift:224-247`). But the design's
  `SessionRecord.create(... initial: ...)` (10.3) is public and takes a checkpoint from its
  caller, and `MoshSession.init` has its own rule for a nil `serverStartSize`
  (`MoshSession.swift:64-67`, "nil means `initialSize`"). Two callers outside the coordinator
  exist (`DeviceProbe`, tests). By the precedent of A-1 in the stage 1 refutation ("by
  construction", a public call, no fault) this is major.
- The seeding gap is real and not a matter of reading: 4.3 seeds `recorded` "from the result of
  a replay" only, and the new-session initializer appends the Resize to the log without the
  gate (`TransportCore.swift:140-143`). As written, the first datagram of every new session
  fails the new check `newEnd <= recorded.inputEnd`.

Smallest change: the review's (the checkpoint of `journal.1` is the core's own
`checkpointState()`; `recorded` of a new core is seeded from its own initial log).

Test: the review's `testInitialCheckpointIsTheCoresOwn`.

## R2-5: `journalFull` can stop the session for good. SURVIVES, lowered to low

Confirmed by reading: input is one event per byte with no cap (`UserInput.swift:56-58`;
`TransportCore.type`, `TransportCore.swift:242-246`), the checkpoint holds all pending input,
and a frame is at most 67,108,864 bytes (3.3). The loop "checkpoint too large, so no compaction,
so `journalFull`, so no `FRONT`, so nothing shrinks" follows from the text.

Lowered: it needs more than 64 MiB of input typed or pasted with no acknowledgment, the record
stays consistent, and `abandon()` gets out.

Smallest change: the review's second option (admit `FRONT` and `THROWAWAY` past `journalFull`;
they only shrink the next checkpoint). The first option changes what `type` accepts and is a
question for the owner (the review's question 2).

## R2-6: after `SERVER_SHUTDOWN`. SURVIVES, minor; the scenario is replaced

The scenario as written cannot happen. Step 3 has the server repeat its shutdown with
`ack_num = M`, where `M` is the client's acknowledgment of that shutdown, "before it arrives".
The server can name `M` only after `M` arrived, and then it never sends again: `M` carries
`ack_num` 2^64 - 1, which makes `sent_states.front().num == uint64_t(-1)`
(`network/transportsender.h:150`), and the main loop breaks at `frontend/mosh-server.cc:880-883`,
before `network.tick()` at `:921`.

A scenario that can: a client state `K` is in flight when the server starts its shutdown. The
first shutdown instruction (sent before `K` arrived) is recorded as `SERVER_SHUTDOWN`. `K`
arrives; the server's next repeat carries `ack_num = K` (`networktransport-impl.h:159-160`,
`transportsender-impl.h:327`). `K` is a sent state above the front, so the core plans
`.front(K)` after a recorded `SERVER_SHUTDOWN`. From there the review's argument holds: applied
and not recorded, the next ack fails `.frontNotRecorded`, the transport halts, and the server
gives up after 10 s or 16 sends (`transportsender.h:56-57`) instead of at once.

Smallest change: the review's first option, in one sentence of 4.3: after a recorded
`SERVER_SHUTDOWN` the core plans nothing; the only thing that still changes is the repeat of
the ack.

Test: the review's, with the repeat's `ack_num` naming a state sent *before* the shutdown was
seen.

## R2-7: the `inputWindow` a compaction writes. SURVIVES, minor

Tried to refute: "in force" (3.2) already means the larger value after a restore. It can be
read so. But the API of section 10 has no way to carry it: `TransportExport` gains `inputBase`
and `position` only (10.1), and `Journal.replace(checkpoint:id:inputBase:from:durable:)` (10.3)
takes no window. So the new header gets the configuration's value or the old header's. Each
loses the maximum in one order of builds (configuration smaller than header, or larger).

Smallest change: the review's rule, plus the field: the export carries the window the core
uses, and `replace` writes it. Test: the review's.

## R2-8: step 6 on the review list. SURVIVES

Nothing to refute; it is a judgment, and the owner has acted on it (Part B covers step 6).
The mixed-version fuzz case for `CountersTests` is worth having: `CountersFile.read`
(`Counters.swift:154-190`) compares generations and limits across the two slots, and that code
now sees slots of two versions.

## R2-9 to R2-13 (doc). All SURVIVE

- **R2-9.** Confirmed: 13 says "a line is never split"; 4.4 and L1 ("a prefix of the records of
  the append that was in progress") say that a `type` of more than 1 MiB can arrive in part.
- **R2-10.** Confirmed: `receive` moves the expected sequence for every in-order datagram
  (`TransportCore.swift:277-279`) and a duplicate instruction plans nothing (`:777-779`). The
  remark on "highest throwaway seen" is moot: the test's list in section 11 does not include it.
- **R2-11.** Confirmed in the source: `transportfragment.cc:118` and `:123`;
  `completeterminal.cc:77`; `mosh-server.cc:769`; the 60 s exit at `mosh-server.cc:914-919`
  with the timestamp of `:725` and `networktransport-impl.h:47`. One correction: the echo-ack
  assert does not rest on L5. The server registers `received_states.back().num`
  (`mosh-server.cc:733-734`, `:769`), the list is kept sorted (`networktransport-impl.h:142-160`),
  and `set_echo_ack` takes entries in push order (`completeterminal.cc:130-160`), so the value
  grows whatever numbers a client sends, as long as the list is not emptied (N3).
- **R2-12.** Confirmed: `runResize` before `start()` (`ResumeCoordinator.swift:601-606`); 5,
  step 2, makes "identifier unknown" `.rebooted`.
- **R2-13.** Confirmed: the private `LoggingGate` at `ResumeEndToEndTests.swift:15`;
  `SessionLauncher.swift:92` passes nil; `moshcli` passes a size through `coldStart`
  (`Resume.swift:139`), so step 4's move does change `moshcli`; section 7's "only while the
  record is `open`" has no meaning before step 9.

---

# Part B. Second review: steps 3, 6 and 9

Scope: step 3 (plan, record, apply; absolute indices; `recorded`; the `Outbox` checks;
`init(restoring:)`; `checkpointState()`) with sections 2, 4, 5 and 6; step 6 (the `counters`
codec) with 3.5 and 3.6; step 9 (the switch) with 3.5, 3.6, 5, 7 and 8. The question for each
instant: does a kill plus a cold start break N1-N4, lose or duplicate input, or reach a live
assert of `mosh-server`? REVIEW.md's findings are not repeated; where one of mine shares a root
with one of them it says so.

## S-1 (major, verified against text and HEAD) `shutdown()` before `start()` writes `open(b)` on a stage 1 record

**Design text.** 3.5, transitions: "`sealed(id)`, `clean(id)` | The first append is about to
happen: `start()`, a return to the foreground, input in the background | `open(b)` | Both
slots". 10.4, `shutdown()`: "`markOpen()` (refused if it fails, nothing changed; it writes only
when the record is sealed), then `markEnded()`". 3.6: a stage 1 record becomes a stage 2 record
in `start()`, and until then "journal files in the directory are not looked at".

**Code at HEAD.** `runShutdown` has no `started` guard (`ResumeCoordinator.swift:641-659`):
`markDirty()`, `markEnded()`, `session.shutdown()`. The app calls `shutdown()` when the user
leaves the screen (`App/IOSMosh/TerminalViewController.swift:373-385`), also for a session
whose `start()` threw and is to be tried again (`:106`, `:728`). `markOpen()` takes the place
of `markDirty()`.

**Scenario.**

1. A stage 1 record `clean(id)`, with a stale `journal.1` beside it from a build of step 8
   (the record of R2-2, step 1 and 2).
2. A stage 2 build: `coldStart` resumes it from `snapshot`. `start()` is not called, or throws
   before its step 2 (the conversion's journal could not be written).
3. `shutdown()`: `markOpen()` writes `open(b)` to both slots. The record is not `sealed`, but
   the transition table lists `clean(id)` with it, and the gate cannot write `clean` any more
   (version 2 has no such state), so it has nothing else to write.
4. A kill before the first slot write of `markEnded()` is complete (a window of about two full
   syncs).
5. Cold start: `open(b)`, the same boot, the highest generation present is the stale
   `journal.1`. From here it is R2-2, step 5 and 6: a state built on an old front with other
   input at an index the server already has, and `statesync/user.cc:68-69` aborts the server
   (N2). Row H1 of section 6 says "Resumes. Nothing of the shutdown was sent", which is true
   only for a record that has a journal of its own.

Without the stale file the same instants end in `.missing(.journal)`: the record is marked
`dead`, and the app bootstraps a new session for a session the user was closing.

**Why R2-2's fix does not close it.** That fix makes `record` throw on an unconverted record.
Here no `record` is called; `markOpen()` writes the state.

**Failing-test idea.** `Tests/MoshResumeTests/ResumeCoordinatorTests.swift`,
`testShutdownBeforeStartNeverLeavesAStage1RecordOpen`: a version 1 `clean` fixture with a stale
`journal.1`; `coldStart`; `shutdown()` with a storage hook that kills at the first
`counters.write` of the `ended` mark; read the record: the state is `clean(id)` or `ended`,
never `open`. And the end-to-end row of R2-2 with this call order: the server pid stays alive.

**Smallest change.** One way out of `clean(id)`: `beginSending()`, after the conversion's
generation has its name. `markOpen()` on a `clean(id)` record throws (`notConverted`), and
`runShutdown` of a restored session that was not started goes to `markEnded()` directly (a kill
inside it reads `clean` or `ended`, both true). Take `clean(id)` out of the `markOpen` row of
3.5.

## S-2 (minor, verified against text) A rename while a slot names an older checkpoint

**Design text.** 7: "A seal starts from `open` only ... So there is never a rename while a slot
names an older checkpoint: the window of reviews A-3 and B-3 does not come back." And, same
section: "If that write fails half way, a slot may say `sealed` while the gate goes on as
`open`; the next append then writes `open` to both slots first (J4)". 10.4,
`enterForeground()`: "If the mark fails ... the record stays sealed and true".

**The gap.** J4 guards appends. A rename is not an append.

1. Seal: `journal.<g+1>` renamed and synced; the slot write of `sealed(id1)` reaches the file
   and its sync reports an error. The gate goes on as `open`, "not known in both". On disk the
   newest slot may say `sealed(id1)`.
2. No append follows (the session is quiesced). `enterBackground()` is called again, or the
   compaction that was queued before the seal runs: the gate's state is `open`, so it is
   allowed. It makes `journal.<g+2>` with a new random id `id2` and renames it.
3. A kill before the slot write. Cold start: `sealed(id1)`, and the highest generation holds
   `id2`: `.snapshotDoesNotMatch`, the record is marked `dead`, the server is killed after the
   identity check. The session was intact.

The mirror case: `markOpen()` writes one slot `open(b)` (now the newest) and fails on the
second. 10.4 says the record "stays sealed". On disk it reads `open(b)`: resumable in this boot
only. A second `enterBackground()` then "writes nothing and answers sealed", and
`SaveOutcome.clean` promises a resume after a restart of the phone that will not happen.

No N1-N4 in either: a stale `sealed` never matches a journal that moved on.

**Failing-test idea.** `Tests/MoshResumeTests/JournalTests.swift`,
`testASealAfterAHalfWrittenSealedMarkNeverLeavesAMismatch`: fail the `counters.fsync` of a
seal; seal again with a kill at `journal.rename:after`; assert that the next cold start
resumes. And `testAHalfWrittenOpenMarkIsNotReportedAsSealed`.

**Smallest change.** Treat the rename like an append for J4: in step 4 of section 7, if `open`
is not known to be in both slots, write `open(b)` to both before the rename. And the gate
answers "sealed" without writing only while `sealed` is the newest slot it wrote and no later
slot write was started.

## S-3 (minor, not verified) The torn-tail cut offset outlives its generation

**Design text.** 5, `coldStart` step 3: "TORN: remember the cut offset". 10.3: `loadState()`
returns `StoredState` with `tornBytes`, so the offset lives outside the journal. 5, `start()`
step 1: "Cut the torn tail, if any (`ftruncate` to the cut offset)". 7, triggers:
"`enterBackground()` on a restored session that was not started yet" is a seal, and 10.4:
"from its replayed state (nothing is sent)". A `start()` asked for in the background is
deferred to `enterForeground()` (`ResumeCoordinator.swift:440-444`, `:514-521`).

**Scenario.** No storage fault is needed.

1. The app is killed inside an append: `journal.<g>` ends in a torn frame at offset `T`.
2. Relaunch: `coldStart` resumes and remembers `T`. The user leaves the app before `start()`
   has run (a view lays out before the app is ready; the code at HEAD has the deferred start
   for exactly this).
3. `enterBackground()` seals: `journal.<g+1>` is one synced `CHECKPOINT`; `sealed(id)`;
   `journal.<g>` is removed.
4. `enterForeground()` runs the deferred `start()`. Step 1 cuts "the" journal to `T`. The
   gate's journal is `journal.<g+1>` now. If `T` is below its size the checkpoint is cut; if
   above, `ftruncate` extends the file with zeros.
5. Step 3 writes `open(b)`; the session sends and appends behind a file that no reader accepts
   (3.4: a cut checkpoint, or `n == 0`). The next cold start is DAMAGED: a fallback, and the
   old server is killed. Until then the process runs on a record that is already lost.

No N1-N4: the damaged file is never replayed.

Not verified because the design does not say who holds the offset between `coldStart` and
`start()`; an implementation that keeps it in the `Journal` object and clears it in `replace`
does not have the problem. As written (`StoredState.tornBytes`, "the cut offset"), it does.

**Failing-test idea.** `Tests/MoshResumeTests/ResumeCoordinatorTests.swift`,
`testASealBeforeStartDoesNotLeaveACutForTheNewGeneration`: a record whose journal has a torn
tail; `coldStart`; `enterBackground()`; `enterForeground()`; `start()`; `close()`; a second
`coldStart` resumes, and the journal's first record decodes.

**Smallest change.** The cut belongs to the journal file it was found in: `Journal` holds
(generation, offset) and cuts as its first act when the gate first writes or seals;
`Journal.replace` drops it. `start()`, step 1, becomes "the journal cuts its own tail, if it
still has one". This is also the precondition R2-2 needs.

## S-4 (doc, verified against text and HEAD) Three places where step 3's text and its tests do not meet

- **Tags.** One instruction can plan `[FRONT][THROWAWAY]` and `[FRONT][SERVER_SHUTDOWN]`
  (4.3: the ack first, then the shutdown case or the throwaway), and a `type` of more than
  1 MiB is several `INPUT` frames in one append. The tags of 10.3 and 10.6 are `input`,
  `front`, `remote`, `front+remote`, `throwaway`, `server-shutdown`. `Stage2CrashTests` and
  the kill loop's "storage step" kind enumerate by tag and torn length, so the other
  two-frame appends are not reached between their frames, or an implementation splits them
  into two `pwrite` calls to fit the tags (safe by L1, but then "one `record` call, one
  `write()`" is no longer what is tested). Add the tags, or one tag per frame list.
- **`THROWAWAY` has no replay check.** 3.4 lists checks for `INPUT`, `FRONT`, `REMOTE` and
  `SERVER_SHUTDOWN`. A `THROWAWAY` above every held number empties `receivedStates`, which the
  core reads as "never empty" (`TransportCore.swift:77`, `:877`): a trap, not
  `.snapshotRefused`. It needs a record with a good checksum and a wrong value, so it is a
  robustness rule ("random bytes never trap", section 11), not a crash path. Add: a
  `THROWAWAY` must leave at least one state.
- **J11 for `FRONT`.** Live, the front's input count comes from the sent state the ack names
  (`processAcknowledgment`, `TransportCore.swift:728-732`). At replay the sender holds `[A]`
  alone, so `applyFront` cannot look the state up; it must take number and count from the
  record. Say so in 4.3 (`applyFront(number:inputCount:)` is what both call), or J11 is true
  for three record types out of four.

## S-5 (doc, verified against text) Builds of steps 6 to 8 read version 2

3.6 argues that a stage 2 record on an older build is safe because
`CountersSlot.init(encoded:)` refuses version 2 (`Counters.swift:84`), "so both slots are
invalid, no gate is made and nothing can be sent under the key". From step 6 on the codec
reads version 2, and until step 9 the code is stage 1's. Such a build, installed over a build
of step 9 or later, does make a gate. It is safe only by the half sentence in step 6 ("treats
a slot that says so like dirty"): no resume, and the limits count. That deserves a row in 3.6
and a test in step 6 (`ResumeCoordinatorTests`: a version 2 `open` and a version 2 `sealed`
record on the step 6 code both end in the fallback and send nothing; the gate's next
reservation starts at their limits).

One instant I checked because it mixes versions in one file, and that holds: a kill between the
two slot writes of the conversion leaves a version 2 `open(b)` slot (newest, new limits) and a
version 1 `clean(id)` slot. A stage 2 build reads `open(b)` and resumes from the conversion's
generation, which was renamed before the slots were written. A stage 1 build sees the version 1
slot alone, with the old limits; no number of the new block was handed out, because numbers
need the limit in both slots (`FileBackedGate.swift:303-311`).

## What held (second review)

- **L2 and the first datagram.** Every instruction any process sent carried its memory front,
  which is at or below the journal's; the server erases client states only at
  `networktransport-impl.h:171-181`. `N'` on `A` with `throwaway_num = A` finds `A` held.
- **Relative states at the server.** After `get_remote_diff` every held state has the oldest
  subtracted (`networktransport-impl.h:193-199`); `N'` is a copy of the server's own `A` plus
  the client's diff from `A`, so it is relative to the same oldest state as
  `last_receiver_state`, and `diff_from` finds its prefix.
- **Exactly once.** Input is in `J` before `type` returns true and before any state holds it;
  a compaction's checkpoint and position are read in one actor call, and `record` plus apply
  are one actor call, so no export falls between them.
- **`ack_num` after a restore** is the newest held state; out-of-order states are inserted and
  never become the ack, live and at replay alike (`TransportCore.swift:825-841`).
- **`highestAckSent` in a live checkpoint is held**: the server's throwaway is its front, which
  is at or below what the client acknowledged, so the restore's check
  (`TransportCore.swift:191-193`) passes for every checkpoint of a live session.
- **The floor in a checkpoint is stale by design** (`usedCounters` of the export, up to a
  generation old). Only the gate's limits protect N1 and N4 after a restore; they do (R1, R2),
  and `Outbox` starts above the floor and takes numbers from the gate.
- **Fragments across processes, reordered**: an old fragment that arrives between two new ones
  clears the assembly and costs one instruction; none of the three asserts of
  `transportfragment.cc:106`, `:118`, `:123` is reached, since an id never has two contents.
- **Sends while sealed** (attack 17), then a restart in another boot: the sealed checkpoint's
  front is still held by the server, because every send carried it as `throwaway_num`.
- **A reservation in every gate state** (`open`, `sealed`, `ended` asked for, `open` not known
  in both) writes a state that is at least as safe as the one on disk, with limits that only
  grow. The one exception is `dead` asked for (R2-1).

Noticed outside the scope (clipboard, step 4): a seal before `start()` writes a checkpoint
whose newest screen holds a copy that arrived in a replayed `REMOTE`, with the old policy. The
restore after it sees no replayed `REMOTE` and judges that screen against the policy: the
second write of an old OSC 52 that 5, step 9, rules out. The seal before `start()` should apply
the baseline first.

## Status

Filled after the design was changed (2026-11-19). "Closed" means closed in the text of
`DESIGN.md`; nothing is built, so every test named is still unwritten.

| Finding | State | Design change made | Status | Test |
|---|---|---|---|---|
| R2-1 | survives, minor | `dead` is an intent taken before its first slot write; every later slot write of the gate writes it; `record` completes it (J15) | closed in DESIGN section 3.5 (also 4.3, 4.5, 6 row H4, 10.4) | `testADeadMarkThatFailedHalfWayIsNeverCoveredByOpen` |
| R2-2 | survives, major | One rule, J14 "armed": a cold-started gate appends nothing, makes no generation and writes neither `open` nor `sealed` until `beginSending()` has cut, converted and marked; the restoring initializers lose `currentSize` | closed in DESIGN section 3.5 (also 4.3, 4.5, 5, 6 L6 and rows M3, M4, 10.1 to 10.4) | `testRecordBeforeConversionWritesNothing`, `testRecordBeforeTheTailCutIsRefused` |
| R2-3 | survives in part | Run-time validity: a well-formed UUID that is not all zeros and the same in two reads, else unknown; unknown is `.bootUnknown` | run-time check closed in DESIGN section 8. open: whether iOS returns a per-boot value is a device question for step 0 (section 15). for the owner: what to do when it cannot be read or trusted (section 15, question 5) | `testEmptyOrZeroIdentifierIsUnknown` |
| R2-4 | survives, major | `create` takes `makeInitial` and writes `journal.1` from the new session's own `checkpointState()`; no `SessionSnapshot.initial`; `recorded` of a new core seeded from its own log | closed in DESIGN section 10.3 (also 4.3, 6 L3 and row I0, 10.2) | `testInitialCheckpointIsTheCoresOwn` |
| R2-5 | survives, low | `FRONT` and `THROWAWAY` admitted past `journalFull` | closed in DESIGN section 3.3. for the owner: a limit on unacknowledged input (section 15, question 6) | `WriteAheadTests`, small limits |
| R2-6 | survives, minor, scenario replaced | After a recorded `SERVER_SHUTDOWN` nothing is planned and nothing applied | closed in DESIGN section 4.3 | `WriteAheadTests`, ack of a state sent before the shutdown |
| R2-7 | survives, minor | The export carries the window in use; `replace` writes it into the new header | closed in DESIGN section 7 (also 4.5 J12, 10.1 to 10.3) | `JournalTests`, header window after compaction |
| R2-8 | survives, acted on | Step 6 on the hostile-review list; mixed-version fuzz | closed in DESIGN section 12 (also 11) | mixed-version fuzz in `CountersTests` |
| R2-9 | survives, doc | "A line is never split" corrected to one `INPUT` record | closed in DESIGN section 13 | none |
| R2-10 | survives, doc | Receive sequence compared as `restored <= live` | closed in DESIGN section 11 | `ReplayTests` |
| R2-11 | survives, doc | S6 (echo-ack assert), S12 (60 s from the server's start), S13 (two more asserts); row I2 | closed in DESIGN section 1 (also 6) | none |
| R2-12 | survives, doc | The two exceptions to "true means journaled"; `.bootUnknown` beside `.rebooted` | closed in DESIGN section 10.4 (also 5, 8, 10.5) | `ResumeCoordinatorTests` |
| R2-13 | survives, doc | Step 2's conformers, step 4's callers, what permits a compaction in step 8 | closed in DESIGN section 12 (also 7) | none |
| S-1 | new, major | The same rule as R2-2 (J14): `markOpen()` throws on an unarmed gate; `shutdown()` before `start()` goes to `markEnded()` directly; `clean(id)` is left only in `beginSending()` | closed in DESIGN section 3.5 (also 5, 6 row M3, 10.4) | `testShutdownBeforeStartNeverLeavesAStage1RecordOpen` |
| S-2 | new, minor | `open(b)` in both slots before any rename (J4 widened); "sealed" answered without writing only when it is the last completed slot write | closed in DESIGN section 7 (also 4.5 J4, 6 row D5, 10.4) | `testASealAfterAHalfWrittenSealedMarkNeverLeavesAMismatch`, `testAHalfWrittenOpenMarkIsNotReportedAsSealed` |
| S-3 | new, minor | The journal owns its cut (generation, offset) and cuts when the gate is armed; no seal before `start()`, so no generation is made while a cut is pending | closed in DESIGN section 3.4 (also 5, 6 row M4, 7, 10.3) | `testASealBeforeStartDoesNotLeaveACutForTheNewGeneration`, `testEnterBackgroundBeforeStartWritesNothing` |
| S-4 | new, doc | A tag per frame list; a `THROWAWAY` must leave a state; `applyFront(number:inputCount:)` from the record | closed in DESIGN sections 10.3 and 10.6 (tags), 3.4, 4.3 | `JournalFormatTests`, `Stage2CrashTests` |
| S-5 | new, doc | A paragraph in 3.6 for builds of steps 6 to 8; the test in step 6 | closed in DESIGN section 3.6 (also 11, 12) | a version 2 record on the step 6 code |

One thing was given up to close R2-2, S-1 and S-3 with one rule: `enterBackground()` on a
restored session that was not started yet no longer seals from the replayed state; it writes
nothing and reports what the state on disk promises. An `open(d)` record left that way is
still lost to a restart of the device, as before the relaunch. That also removes the
clipboard case noticed above (a seal before `start()` under the old policy).

Order suggested for the design changes: R2-2 with S-1 and S-3 (one rule: nothing is appended
and no `open` is written before `beginSending()` has cut, converted and marked), then R2-4,
then R2-1 and S-2 (the gate's state machine), then R2-6 and R2-7, then the doc items.
