# Hostile review of the stage 2 design (M9, write-ahead journal)

- Reviewed: `docs/notes/stage2/DESIGN.md` at commit `7980166` (2026-11-18). `Sources/` and
  `App/` are unchanged between the design's `30a8bc9` and `7980166`, so "the code at HEAD" is
  the code the design describes.
- mosh facts were checked in `.refs/mosh/src` (mosh 1.4.0). Nothing was built or run; every
  failing-test idea below is unwritten.
- Angles covered: all seven (1 section 1 facts, 2 write-ahead/restore/proofs, 3 torn journal,
  states, reboot, conversion, 4 compaction and sealing, 5 the 13 steps, 6 missing attacks,
  7 code described wrongly). Not covered: anything that needs a device or a run (iOS
  `kern.bootsessionuuid` behaviour, APFS rename and directory-sync semantics, timings).

**Verdict.** No critical finding. The core argument (log before apply, numbers only from
`counters`, the restored first state built on the journaled front, `open` in both slots before
the first unsynced append) held against every interleaving I tried; section 1 is accurate
where it matters. Four majors should be fixed in the design before step 3 is built. Two of
them (R2-2, R2-4) are paths to N2, a live `mosh-server` assert, that are kept closed only by
callers doing the right thing, not by construction. R2-3 depends on an iOS fact nobody has
checked yet.

## Findings

| Id | Severity | Section | One line |
|---|---|---|---|
| R2-1 | major | 4.3, 3.5, 10.4 | `dead` is not sticky in `FileBackedGate.record`: a dead mark that failed half way is overwritten by `open(b)` at the next append, and the record comes back to life |
| R2-2 | major | 3.6, 4.3, 5 (step 6), 12 (step 8) | `record` on an unconverted stage 1 `clean` record writes `open(b)` and appends to a journal that is not the authority; with a step-8 journal present the next start replays it, which can end in N2 |
| R2-3 | major | 8 | Nothing checks at run time that the boot identifier changes at a reboot. A constant or empty value makes J6 vacuous, and an open record is resumed after a power loss (N2 possible); an unreadable value kills the record and the server |
| R2-4 | major | 3.5 (`create`), 4.3 (`recorded`), 10.2 (`SessionSnapshot.initial`) | `journal.1`'s checkpoint is built apart from the core's own log. Any difference (size, server start size, initial Resize counted twice or not at all) is N2 at the first restore, or no record can ever be replayed |
| R2-5 | minor | 3.3 (`journalFull`), 7 | A full generation refuses `FRONT` too. If the checkpoint cannot shrink (pending input above 64 MiB), the front can never move again and the session is stuck for good |
| R2-6 | minor | 4.3 | "Never recorded after `SERVER_SHUTDOWN`" does not say whether the transitions are applied. If they are, the J3 check `frontNotRecorded` halts the transport while it acknowledges the server's shutdown |
| R2-7 | minor | 3.2, J12 | Which `inputWindow` a compaction writes is not defined. If it writes the configuration's value and not the larger one in force after a restore, J12 is lost after one compaction (N2 with a build that shrinks the window) |
| R2-8 | minor | 12 | Step 6 (the `counters` codec that holds the limits) is as N1-critical as steps 3 and 9, but it is not on the hostile-review list |
| R2-9 | doc | 13 (last row), 4.4, 10.7 | "A line is never split" is false for a `type` of more than 1 MiB, which 4.4 itself says becomes several `INPUT` records whose prefix can survive |
| R2-10 | doc | 11 (`ReplayTests`), 2 (L0) | `ReplayTests` asserts that the receive sequence is equal after a replay; it cannot be (a duplicate datagram moves it and leaves no record) |
| R2-11 | doc | 1 (S12, S13), conventions | S13 and the list of live asserts leave out two fragment asserts and a server echo-ack assert; the 60 s server exit is timed from state 0's timestamp, not from the last datagram (row I2) |
| R2-12 | doc | 10.4, 8 | "True means journaled" is false for a resize before `start()` and for a retired journal; `.rebooted` is also the reason when the boot identifier is unknown, and its text then says the phone restarted |
| R2-13 | doc | 12 | Step 2 misses a gate conformer (`ResumeEndToEndTests.swift`); the step 4 Resize move is already how the app works; "compaction only while open" has no meaning in step 8 |

### R2-1 (major) `dead` is not sticky: a half-written dead mark is overwritten by `open`

**Design text.** 4.3, `FileBackedGate.record`: "ended or dead is in both slots -> return /
ended was asked for, not yet in both -> write it to both slots (R16); then return / state is
not open, or open is not known to be in both slots -> write open(b) to both slots". 3.5:
"`.dead` Given up (a fallback, `abandon()`, a lost base state, a halted transport): a new session
is owed". 10.4: "`abandon()`, a lost base state, a halted transport | `markDead()`".

**Code at HEAD it builds on.** `FileBackedGate.markDirty()` (`Sources/MoshResume/FileBackedGate.swift:255-264`)
writes first and sets `state` only after both slots were written. `writeBothSlots`
(`:305-311`) clears `notCleanIsDurable` first and then writes slot by slot, so a failure on the
second slot leaves the newest slot saying the new state while the gate keeps its old intent.
`ResumeCoordinator.giveUp()` (`ResumeCoordinator.swift:566-573`) sets the coordinator's own
`ended` flag, which guards saves and input that go through the coordinator. It does not guard
the transport, which calls `gate.record` directly from `receive`. In stage 1 that was harmless
because "dirty" meant both "running" and "given up". Stage 2 splits them into `open` and
`dead`, and only `ended` gets R16's "asked for, complete it first" treatment.

**Scenario** (verified against the design text and the code, not run):

1. A session runs in the foreground; the record is `open(b)` in both slots.
2. The server is restarted under the client, and the core reports `.baseStateLost`.
   `handle(.baseStateLost)` calls `giveUp()`, and through it `markDead()`.
3. `markDead()` writes `dead` to the older slot (it is now the newest, generation k+1). The
   second slot write fails (`EIO`, or `ENOSPC` while a file is extended; or the hook's `.fail`
   in a test). It throws, and the gate's intent is still `open`, "not known in both".
4. The app has not reacted yet. The transport is still running: a datagram arrives and the core
   plans `.front` or `.remote`, then calls `record`.
5. `record`: dead is not in both slots, ended was not asked for, and open is not known in both,
   so `open(b)` goes to both slots, generations k+2 and k+3. The slot that said dead is
   overwritten. The append follows.
6. The app is killed. The next cold start reads `open(b)` in the same boot and resumes a record
   that was given up. With `.halted` that is a journal whose books disagreed. With `abandon()`
   it is the record of a session the user explicitly left, while a new one was bootstrapped
   (and `SessionLauncher` may have killed the old server).

No N1 to N4 (numbers still come from `counters`), but it breaks the state machine of 3.5 and
the promise that `dead` means "a new session is owed".

**Failing-test idea.** `Tests/MoshResumeTests/FileBackedGateTests.swift`, a new
`testADeadMarkThatFailedHalfWayIsNeverCoveredByOpen`: a gate in `open(b)`; a storage hook that
fails the second `counters.write` of `markDead()`; then `gate.record([.front(...)])`. Assert:
`record` throws or returns without writing, and `SessionStore.readCounters().state == .dead`.

**Smallest change.** Treat `dead` like `ended`. The gate takes it as final before it writes
(set `state = .dead` first, as `markEnded()` does at `:280`). In `record`, put the line "dead was
asked for, not yet in both: write it to both slots; then return (drop the transitions)" next to
the `ended` line. Every later slot write of that gate (reservations, `markOpen`) writes `dead`.
State in 3.5 that `dead`, like `ended`, is never left.

### R2-2 (major) `record` on an unconverted stage 1 record writes `open` over a journal that is not the authority

**Design text.** 3.6: a stage 1 `clean(id)` record is resumed from `snapshot`; "journal files
in the directory are not looked at", and the conversion happens in `start()`. 3.6, last
paragraph: a record made between steps 8 and 9 has "journal files that were never the
authority: the state decides, the journal files are ignored and replaced". 12, step 8: "A
record opened by a cold start has no journal to append to (its files are stale from the first
stage 1 resume on)". 5, step 6, and 10.1: "`TransportCore.init(restoring:)` keeps its
`currentSize` parameter for other callers; a size given there is recorded through the gate
like any input". 4.3, `record`: "state is not open ... -> write open(b) to both slots ...
journal.append".

**Code at HEAD.** `ResumeCoordinator.coldStart(currentSize:)` is public
(`ResumeCoordinator.swift:271-276`), and `TransportCore.init(restoring:currentSize:)` adds a
Resize when the size differs (`TransportCore.swift:231-234`). In stage 2 that Resize goes
through `gate.record`. The design says `coldStart` builds with `nil`, but nothing stops another
caller (`moshcli resume`, a test, a future app path) from passing a size to the restoring
initializer of `MoshSession`/`MoshConnection`/`TransportCore` with a `FileBackedGate`.

**Scenario** (design-level; the stale journal is the one step 8 itself creates):

1. A build of step 8 creates record R. `SessionRecord.create` writes `journal.1` and the gate
   appends to it, while stage 1 states decide.
2. R is saved (stage 1 `snapshot`, `clean(id1)`), resumed by a stage 1 cold start (its gate now
   records to nowhere: `journal.1` stops at front `A1` with input up to index `I1`) and used
   further: input `X` is typed and sent in state `N` built on `A1`. Then R is saved
   (`clean(id2)`; the snapshot's front is still `A1`, because the server's ack of `N` never
   came back) and the process dies.
3. A stage 2 build opens R: `clean(id2)`, `snapshot` read. A caller builds the session with a
   `currentSize` that differs from the snapshot's.
4. The restoring initializer records `.input([Resize])`. `FileBackedGate.record`: the state is
   not open, so it writes `open(b)` to both slots, then appends to the journal it has. If that
   is the highest generation present (`journal.1`, the natural reading of "the journal"), the
   Resize lands behind the stale records.
5. A kill before `start()` (or a throwing `start()`). The next cold start reads `open(b)` in the
   same boot, takes `journal.1` (J8) and replays front `A1` with the input up to `I1`, then the
   Resize.
6. The first datagram: `N'` on `A1`, content `A1 + [...I1] + Resize`. The server holds `N` =
   `A1 + [...I1] + X` as its newest client state. `get_remote_diff` calls
   `N'.diff_from(N)`; `statesync/user.cc:69` `assert( *i == *my_it )` fails at `X` versus the
   Resize. mosh-server aborts (N2). Verified in the source: `networktransport-impl.h:191`,
   `user.cc:61-71`.

Even without step 8's stale file, step 4 writes `open(b)` for a record whose only valid journal
(the conversion's) does not exist yet. That record then fails with `.missing(.journal)`, or
resumes from whatever generation is lying around.

**Failing-test idea.** `Tests/MoshResumeTests/ResumeCoordinatorTests.swift`,
`testRecordBeforeConversionWritesNothing`: a stage 1 `clean` fixture (version 1 writers from
the test support) with a stale `journal.1` beside it; build the restored session with a
`currentSize` that differs; assert that `counters` is byte for byte unchanged and no journal
grew. Also a `ResumeEndToEndTests` row against the real server: the scenario above; the server
pid must stay alive.

**Smallest change.** `FileBackedGate.record` throws (`notConverted`) while the record state is
`clean` (version 1) or while the gate has no journal that `loadState`/`start()` established as
the authority. It never writes `open` on its own for such a record. The restoring initializers
take no size at all (remove the parameter, or make it a precondition that it is nil when the
gate has a journal); the Resize is always the `start()` step 6 path.

### R2-3 (major, iOS behaviour not verified) The boot identifier is trusted without a run-time check

**Design text.** 8: "`BootIdentity.current() -> UInt64?`: a 64-bit FNV-1a digest (0 is mapped
to 1) of a string the system makes anew at every boot, or nil if it cannot be read"; "The design
is safe either way: if it cannot be read, `open` is written with digest 0". 12, step 0:
`DeviceProbe` reads it in two launches and after one restart. 15: "Whether an app may read
`kern.bootsessionuuid` on iOS is not known".

**What collides.** J6 is the only thing that keeps an `open` record from being resumed after a
power loss, and after a power loss the journal is not a prefix of what was acted on (renames
undone, unsynced pages lost in any order). The design guards against "cannot be read" but not
against "reads, but not per boot". That covers an empty string, an all-zero UUID, a value the
sandbox fakes, or a value a later iOS keeps across boots to stop fingerprinting (Apple already
restricts boot-time APIs). The digest of such a string is a fixed non-zero value, so `open(d)`
matches across boots. Step 0 checks this once, on one iOS version.

**Scenario:**

1. On some iOS version the sysctl returns the same string in every boot (or `""`).
2. Foreground: the record is `open(d)`. The user types `X`, it is journaled (not synced) and
   sent in state `N`; the server takes it, and `X` reaches the shell.
3. The battery dies. After the reboot the journal's last pages are lost: the file ends at an
   older size, or holds zeros.
4. Cold start: `open(d)` matches `d`, and the journal ends before `X` (or is DAMAGED, which at
   least falls back). Restored: front `A`, no `X`. The user types `Y`; `N'` on `A` holds `Y` at
   `X`'s index. `diff_from` asserts at `user.cc:69`: the server aborts (N2).

The other edge hurts too: a value that is unreadable only for a moment (for example at the
first launch after an update) marks a perfectly good same-boot record `dead` (5, step 2). The
app's fallback then kills the old server after the identity check (8, "the old server killed").

**Failing-test idea.** `Tests/MoshResumeTests/BootIdentityTests.swift`:
`testEmptyOrZeroIdentifierIsUnknown`. A `DarwinBootIdentity` with an injectable reader that
returns `""`, `"00000000-0000-0000-0000-000000000000"` and a non-UUID string; each case must
give `nil`. `ResumeCoordinatorTests`: with `FixedBootIdentity` returning nil at the cold start
of an `open(d)` record, assert that the outcome is not resumed and the record is not marked
`dead` (see the change below).

**Smallest change.** (a) `BootIdentity.current()` returns nil unless the string parses as a UUID
that is not all zeros. (b) Require a second, independent signal to match as well: store
`kern.boottime` (seconds) beside the digest. Today the field at offset 56 is 8 bytes; a version
2 slot can have a second field, or the digest can be computed over both strings. Matching both
can only lose resumes (a clock change moves `boottime`), never make one unsafe; the design's
reason for rejecting `boottime` applies only to using it alone. (c) For "current identifier
unknown", fall back without marking `dead`, so that a later launch can still resume in the
same boot. Do not let that case lead to killing the server.

### R2-4 (major) The initial checkpoint is a second copy of the core's first events

**Design text.** 3.2: "the first event of a new session (its initial Resize) has index 0". 3.5:
"`create` | `open(b)` | `journal.1` with the initial checkpoint". 10.2:
"`SessionSnapshot.initial(size:serverStartSize:clipboard:)`: the checkpoint of a session that has
done nothing; it must equal `checkpointState()` of a fresh session (a test)". 4.3: "`recorded`
... changed only where `gate.record` returned (and seeded from the result of a replay)".

**Code at HEAD.** `TransportCore.init(cipher:gate:configuration:initialSize:initialRemoteState:now:)`
(`TransportCore.swift:120-144`) appends `.resize(initialSize)` to the log directly, without the
gate. State 0 is a blank terminal of `serverStartSize` (`TerminalRemoteState.init(serverStartSize:)`).

**The gap.** The record's first checkpoint and the core's first state are built in two places
from two sets of arguments. Either way of joining them is dangerous:

- Seed nothing: a fresh core has `recorded.inputEnd = 0`, and its first datagram (`newEnd = 1`,
  the initial Resize) fails `.inputNotRecorded`. The transport halts at once (this is the
  benign case; any test sees it).
- Record the initial Resize through the gate: `journal.1` then holds the checkpoint with the
  Resize as pending input at index 0 and an `INPUT` with `firstIndex = 0`. The replay check
  (3.4, "`INPUT.firstIndex` equals the number of events so far", which is 1) refuses it: no new
  record can ever be resumed, and every one goes `.snapshotRefused`, then `dead`.
- Seed from the checkpoint, but the checkpoint was made with other values than the core. For
  example `ResumeCoordinator.create(..., initialSize: S1)` builds `journal.1` from the size the
  caller gave, while the session is built from the view's size `S2`, or the server start size
  differs. Then the live process sends `Resize(S2)` at index 0 in state 1. A process restored
  from `journal.1` sends `Resize(S1)` at index 0. The server holds state 1, and `diff_from`
  asserts at `user.cc:69` (N2). The same goes for a held state 0 that does not equal the
  server's state 0: every diff the server builds on it then applies to the wrong screen.

The equality test of 10.2 checks one set of arguments. It does not make the two paths one.

**Failing-test idea.** `Tests/MoshResumeTests/ResumeCoordinatorTests.swift`,
`testInitialCheckpointIsTheCoresOwn`: `create` a record with `initialSize` 80x24, then (through
the test seam) have the session's core start with 100x30. Kill before the first server reply,
cold start, and capture the first instruction. Assert that its diff from state `A` = 0 starts
with the same Resize the live process sent. Today's design would pass only if the coordinator
happens to pass one value to both.

**Smallest change.** Make `journal.1`'s checkpoint *from the core*. `create` first builds the
session (not started), takes `checkpointState()` and writes that as the checkpoint, and the
core's `recorded` is seeded from the same export (`inputEnd` = its log end, front 0). Drop
`SessionSnapshot.initial` as a separate constructor (keep it as a test oracle at most). State
in 4.3 that the new-session initializer seeds `recorded` from its own initial log, and that
it never calls `record` for it.

### R2-5 (minor) `journalFull` can stop the session for good

**Design text.** 3.3: "a `CHECKPOINT` at most 64 MiB. Appends are refused once a generation holds
16 MiB after its checkpoint (`journalFull`; reached only if compaction keeps failing)". 14.13:
"the session stands still and stays consistent".

**Scenario** (design-level):

1. The server is unreachable (s2c and c2s down). The user pastes large blocks. Each generation
   takes up to 16 MiB of `INPUT`, and each compaction carries all unacknowledged input into the
   next checkpoint.
2. After about 64 MiB pending, `checkpointState()` encodes to more than 64 MiB. Compaction now
   fails every time, and the generation grows to 16 MiB: `journalFull`.
3. The network comes back. The server acknowledges a state, and the core plans `.front`: the
   append is refused (`journalFull`), so the instruction is dropped. The front cannot move, so
   the pending input cannot shrink, so the checkpoint cannot shrink, so compaction keeps
   failing. That is a livelock with a live server; only `abandon()` gets out of it. (A seal
   fails the same way.)

**Failing-test idea.** `Tests/MoshTransportTests/WriteAheadTests.swift` with small limits
(`CompactionPolicy` and the checkpoint cap scaled down): fill the journal with pending input
past the cap, then deliver an ack. Assert that the front moves (today's design: it does not).

**Smallest change.** Either refuse input at `type` once the pending input would push a
checkpoint past its cap (input is refused, the session still moves), or always admit `FRONT`
and `THROWAWAY` past `journalFull` (they only shrink the next checkpoint).

### R2-6 (minor) After `SERVER_SHUTDOWN`: "not recorded" without "not applied"

**Design text.** 4.3: "Two things are never recorded: anything after a recorded
`SERVER_SHUTDOWN` (it must be the last record), and the server's ack of our own shutdown".

**Code at HEAD and source.** `TransportCore.process` runs `processAcknowledgment` for every
instruction, the server's repeated shutdown instructions included (`TransportCore.swift:767`),
and after a server shutdown the client still sends instructions with
`throwawayNum: sentStates[0].num` (`sendEmptyAck`, `:583-612`, driven by
`serverShutdownAckPending`, `:502-503`). The server repeats its shutdown at its send interval
until our ack arrives (`transportsender-impl.h:122-124`, `:214-217`), and each repeat carries
`ack_num` = its newest client state (`networktransport-impl.h:159-160`, `transportsender-impl.h:327`).

**Scenario.** (1) The server's shutdown arrives: `[FRONT?][SERVER_SHUTDOWN]` is recorded.
(2) The client's ack (a new state `M`) is on its way. (3) Before it arrives, the server's
next repeat carries `ack_num = M`. (4) The core plans `.front(M)`; "never recorded". If the
implementation still applies it (memory front `M`), `recorded.frontNumber` stays behind, and
the next ack datagram fails `Outbox.send`'s new check `.frontNotRecorded`. The transport halts,
with an `.internalError` event; the server times out after 10 s instead of exiting at once.
No N failure.

**Failing-test idea.** `Tests/MoshTransportTests/ServerShutdownReviewTests.swift`: a server
shutdown, then a repeat whose `ack_num` names a state sent after it; assert that no
`.internalError` and that the ack 2^64 - 1 goes out again.

**Smallest change.** Say it: after a recorded `SERVER_SHUTDOWN` the core neither records nor
applies `.front`/`.remote`/`.throwaway`. Or it applies them and updates `recorded` as if
recorded, since the record will be `ended` in any case.

### R2-7 (minor) The `inputWindow` a compaction writes

**Design text.** 3.2: "`inputWindow`: the `unacknowledgedInputLimit` in force when the file was
made". 5: "Input window | The larger of the configuration's and the header's (J12)".

**Problem.** After a restore, the window in force is `max(configuration, header)`. If the next
compaction or seal writes `configuration.unacknowledgedInputLimit` (the natural reading of "in
force" from the configuration's point of view), the larger value is gone after one generation.
Then: build 1 (window 256 Ki events) sends a state with 200 Ki events pending; build 2 (window
1 Ki) restores with 256 Ki and compacts, writing 1 Ki; a kill; the next restore uses 1 Ki. Its
first state holds `c + 1 Ki` events, fewer than the 200 Ki state the server holds:
`user.cc:68` `assert( my_it != actions.end() )` (N2). It is reachable only when the window
shrinks between builds, or with `moshcli` configurations that differ between processes on one
record (the kill loop could).

**Failing-test idea.** `Tests/MoshResumeTests/JournalTests.swift`: restore with header window
W, configuration W/4; compact; read the new header; assert `inputWindow == W`.

**Smallest change.** Define the header's value as the window the core actually uses (the
maximum after a restore), and keep J12 as "the header's window never decreases from one
generation to the next".

### R2-8 (minor) Step 6 belongs on the review list

**Design text.** 12: "Steps 3 and 9 are the ones to give to hostile reviewers"; step 6 is marked
[N] ("this is the file N1, N2 and N4 rest on").

**Why.** Step 6 rewrites `CountersSlot.init(encoded:)` (`Counters.swift:69-98`) to read two
versions in one file, with a new state byte and a field whose meaning depends on the state. A
mistake there (a version 2 slot whose generation is compared wrongly with a version 1 slot,
the highest-limit rule of `CountersReading` applied to the wrong slot set) hands out numbers
below a used limit: N1 directly. The stage 1 review found its majors at exactly this kind of
edge (`docs/notes/review-resume/resume-review-a.md`, A-1). Step 6 has no server in its tests.

**Smallest change.** Name step 6 next to 3 and 9, and add to `CountersTests` a mixed-version
fuzz case: random pairs of a v1 and a v2 slot; assert that the reading's limits equal the
per-counter maximum over the valid slots and that the state is the newest valid slot's.

### R2-9 (doc) "A line is never split"

13, last row: "Input whose `type` call had not returned arrives once or not at all, and a line
is never split". 4.4 says the opposite for a `type` of more than 1 MiB: "several records, and
whole ones among them would be found by a restart ... that part of the paste would then be
delivered, once". A multi-line paste cut between records runs its first lines in the remote
shell. Either correct the sentence, or make a multi-record append all-or-nothing at replay (a
"continues" flag on all but the last `INPUT` of one call; the reader drops a trailing group
without its last record as TORN). The kill loop's lines are short, so 10.7 is not affected.

### R2-10 (doc) `ReplayTests` asks for an equality that cannot hold

11, `ReplayTests`: the restored core "equals the live core in front, pending input, held states
and their numbers, `ack_num`, size, receive sequence". The expected receive sequence moves with
every in-order datagram (`TransportCore.receive`, `:277-279`). A duplicate state, a
retransmission or a datagram whose instruction is a duplicate (`:777-779`) moves it and plans
nothing, so no record holds it. 2 and 5 say so themselves ("a lower bound"). Compare the
receive sequence as `restored <= live`. The same goes for "highest throwaway seen": the
restored value can be above the live one (the lowest held number), which is the safe direction
for the detector.

### R2-11 (doc) Section 1: what the table leaves out

All of S1 to S15 check out against the source (see "What held"). Three omissions:

- S13 and the conventions list one fragment assert. `transportfragment.cc` has two more live
  ones on the same path: `:118` `assert( (int)fragments.size() <= fragments_total )` (a final
  fragment numbered below one already held for that id) and `:123`
  `assert( fragments_arrived <= fragments_total )`. N4 by unique ids covers all three; the list
  should still be complete, because the guard tests are chosen from it.
- The server's own echo ack has a live assert: `completeterminal.cc:77`
  `assert( get_echo_ack() >= existing.get_echo_ack() )`, fed by `register_input_frame(
  last_remote_num, ...)` (`mosh-server.cc:769`). It holds because client state numbers only
  grow across processes (L5); worth a line under S6 or N2.
- S12 and row I2: the 60 s exit is `!network.get_remote_state_num() && time_since_remote_state
  >= 60000` (`mosh-server.cc:914-919`). `time_since_remote_state` is measured from the newest
  client state's timestamp, which is state 0's, made when the server started
  (`networktransport-impl.h:61`). So it is 60 s from the server's start, not "60 s without a
  datagram reaching the server".

### R2-12 (doc) Two promises that are slightly off

- 10.4: "`type`, `resize` | True means journaled". `ResumeCoordinator.runResize` returns true
  before `start()` and only keeps the size (`ResumeCoordinator.swift:600-606`). When the
  journal is retired (`ended` or `dead` in both slots, 4.3), `record` returns and the input is
  "accepted" without being journaled. Both are harmless; the sentence should name them.
- 5, step 2, and 8: when the current boot identifier is unknown, the fallback is `.rebooted`,
  whose text is "the phone restarted while the session was open" (10.4, 10.5). On a device
  where the identifier cannot be read, that is what every foreground kill would say. A
  separate reason (or a text that says "could not tell whether the phone restarted") avoids a
  false message. See also R2-3 (c).

### R2-13 (doc) Section 12 details

- Step 2: the conformers of `DurabilityGate` are `InMemoryGate`, `FileBackedGate`, `moshcli`'s
  `LoggingGate`, `Tests/MoshTransportTests/GateTests.swift`'s `ScriptedGate` and
  `Tests/MoshResumeTests/ResumeEndToEndTests.swift`'s private `LoggingGate` (`:15`). The last
  one is not in the step's file list; without it the step does not build.
- Step 4, "the Resize moves to `start()`": the app already does that. `SessionLauncher.swift:92`
  passes `currentSize: nil` to `coldStart`, and the size reaches the session through
  `sizeBeforeStart` (`ResumeCoordinator.runStart`, `:461-464`). The change matters only for
  `moshcli` and tests, which is worth saying, since that is the caller R2-2 is about.
- Step 8 adds compaction, but 7 says "a compaction runs only while the record is `open` and the
  session started", and `open` does not exist before step 9. Say what triggers and permits a
  compaction in step 8 (for example "while the gate's state is dirty and the gate has a
  journal").

## What held

Attacks tried that the design survives, one line each:

- **S1 to S10, S14, S15** match the source line by line: the order in `Transport::recv`
  (`networktransport-impl.h:83-165`), erase-then-`fatal_assert` (`:171-183`), the only
  `received_states.erase` (`:178`), `set_ack_num` only for the newest (`:159-160`), ack ignored
  for an unknown state (`transportsender-impl.h:357-380`), the assumed state and the 32-state
  thinning (`:269-292`, `:227-236`), empty ack = new number (`:205-225`), out-of-order seq
  still delivered and no roaming (`network.cc:515-519`, `:555-572`), shutdown limits
  (`transportsender.h:55-56`, `mosh-server.cc:880-893`).
- **"The server applies only the difference from the newest state it holds"**: verified.
  `get_remote_diff` diffs `received_states.back()` against `last_receiver_state`
  (`networktransport-impl.h:191`), and only when the newest number changed
  (`mosh-server.cc:733-738`). `N'` is numbered above everything, so it is the newest.
- **N2 across processes**: every earlier state's end is at most `min(log end, front then + W)`,
  and the restored `N'` ends at `min(log end of S, c + W)` with the front-then at or below `c`.
  Every held client state, including the subtracted relative ones, is a prefix of `N'`.
- **The server's `subtract`** (relative states after `get_remote_diff`) does not break the
  prefix argument: `N'` is built on the server's own copy of `A`.
- **N3 at restore**: the sender holds `[A]` alone, so `old_num = throwaway_num = A`. `A` is
  held because every throwaway any process sent was at most its journaled front, which is at
  most `A`, including a `FRONT` in a poisoned tail (never applied, so never sent).
- **L4 with S8 thinning**: an ignored first ack leaves the server's front at a state the
  client still holds, because the server's throwaway is its front and never exceeds it.
- **The lost-base detector after replay**: a restored `highestThrowaway` (the lowest held
  number) is at or above the live one, so the detector fires less, never falsely.
- **Out-of-order states**: inserted, not acknowledged, recorded as `REMOTE`; the newest held
  number equals `ackNum` at every instant, so J3's ack check matches the live code.
- **Replay and the queue rule**: the apply functions do not include the quench timer, so a
  `REMOTE` accepted live after a 15 s quench is not refused at replay.
- **Parser state in checkpoints**: `Serialization.swift` stores the UTF-8 parser state and its
  pending bytes (`:533-534`), so a diff replayed after a checkpoint lands as it did live.
- **J10 poisoned tail**: whole frames left behind `end` are an L1 `p` (front acknowledged by the
  server, state sent by it, throwaway the server's, input never sent). While poisoned, no later
  append or retyped input can follow, so an `INPUT` there is delivered at most once.
- **Torn reader**: a kill always leaves a prefix. Every prefix length of a frame ends in TORN
  (rest < 8, or rest < 12 + n), and the doubled length stops a damaged `n` from looking torn.
- **Two-slot transitions**: every crash point of `open`, `sealed`, `ended` and of a reservation
  gives either a reading that names a state with nothing appended under it, or `open`. The
  alternate-slot order of `writeOneSlot` (`FileBackedGate.swift:292-301`) makes the first
  slot written the newest.
- **Seal racing input or a datagram**: the session is quiesced (`TransportCore.receive`
  returns at `:272`), and input goes through the coordinator's `inOrder` queue. Step 5's
  "end equals `p`" check catches anything else under the same lock as `record`.
- **Compaction racing appends**: copy, rename and swap are under the append lock (J9), so no
  record lands in the old file after the copy.
- **Rename and crash orders C1 to C3, D1 to D4, E1, E2, M1, M2**: each re-derived by hand, and
  each gives the old or the new state by J8.
- **Sends while sealed** (attack 17): a datagram reveals only reserved numbers and journaled
  content, and the server's answers cannot change state without an append.
- **Downgrade** (3.6): `CountersSlot.init(encoded:)` refuses version 2 (`Counters.swift:84`)
  after the checksum, so an old build makes no gate. `SessionStore.delete` ends with
  `remove(".")` (`SessionStore.swift:213-218`), as described.
- **Fragment assembly across processes**: a new id from the gate clears the server's half
  assembly (`transportfragment.cc:94-100`).
- **Two kills in a row (F3) and many restarts**: at most one new state per restart piles up at
  the server, and the 1,024 quench only slows acceptance (one per 15 s) until a front moves.
- **Actor reentrancy**: `MoshConnection.type` and `resize` are synchronous actor methods
  (`MoshConnection.swift:268-280`), so nothing interleaves between `record` and apply.

## Suspicions (not made concrete)

- **A write-back error within one boot.** On Linux a failed write-back marks pages clean, and a
  later read can return the old disk contents without a reboot. An `open` record could then
  replay a journal that is missing appended records. Whether APFS on iOS can do this is not
  known. If it can, J6 is not enough on its own; the probe "write, kill, read back" would not
  show it.
- **Many held remote states.** With c2s lost and s2c flowing for 20 s or more, the client holds
  up to 1,024+ remote states. The design's own figures (7.8 ms to encode and 6.4 ms to decode a
  full screen, debug build) suggest that a checkpoint then takes seconds to encode, on the
  coordinator queue, ahead of input, and that a restore takes seconds too. Not measured.
- **The same local port after a restart.** If the new socket gets the old ephemeral port,
  server datagrams in flight at the kill reach the new process and count as in order (the
  restored expected sequence is a lower bound). Attack 15 accepts the effect; I did not find
  anything worse than a stale RTT sample.

## Questions for the owner

1. A `.rebooted` or `dead` record leads the app to kill the old server, and the shell with it
   unless it runs in tmux. Should that also happen when the phone only failed to read its boot
   identifier (R2-3 (c)), or should the app then leave the server alone and only offer a new
   session?
2. Is it acceptable to refuse input once unacknowledged input passes some tens of MiB (the fix
   for R2-5)? Today a paste of any size is accepted.
