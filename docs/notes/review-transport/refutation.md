# Refutation of the transport reviews (I, II, III)

Code at `cloud-work` 0b8e120 (sources as at 94e5aae). Nothing in the repo was changed except
this file.

How it was checked:

- Every mosh quote was read in `.refs/mosh/src` (line numbers below are from there).
- All three scratch test files were run in a copy of the repo
  (`/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/refute`,
  cut-down `Package.swift`, `swift test --filter 'ReviewITests|ReviewIITests|ReviewIIITests'`).
  Every reproduction the reviewers report was reproduced with the same numbers.
- Own tests (`Tests/MoshTransportTests/RefuteTests.swift` in that copy) for the points where a
  finding could fall: the II-2 window in the order `MoshConnection` uses, II-2 with a server that
  repeats, the I-1 threshold, I-1 with old input.
- The fixes recommended for M1, M2, M3, M4 and M6 below were applied in the copy (5 small edits
  to `TransportCore.swift`) and all of `MoshTransportTests` was run (142 tests, the real
  `mosh-server` suites included). Result: the reviewers' tests for those findings pass, nothing
  else breaks except `SendTimingTests.testProbeAfterASocketReplacementSendsAtOnceAndRetriesEverySecond`
  (line 259), which asserts the 150 ms probe interval that M4 changes.
- III-6 was checked by reading only (the copy has no `MoshSession` target).

No finding is refuted outright. Three severities change, and four sub-claims are wrong.

## Summary

| Merged | Ids | Verdict | Final severity | One line |
|---|---|---|---|---|
| M1 | I-1, II-5 | SURVIVES | major | Second shutdown send has `old_num` = 2^64-1, the Outbox refuses it, the core halts |
| M2 | I-2, II-4 | SURVIVES | minor | Shutdown target moves with the input window; halt with `stateContentChanged` |
| M3 | I-3, III-5 | SURVIVES | minor | The 10 s shutdown clock runs while quiesced; time-out with nothing sent |
| M4 | I-4 | SURVIVES-WITH-CHANGED-SEVERITY | note (was minor) | Probes at RTO + 100 ms are deliberate and tested; only the wording "every second" is wrong |
| M5 | I-5, II-1, III-4 | SURVIVES-WITH-CHANGED-SEVERITY (II-1) | minor (II-1 said major) | `expectedReceiverSeq` is 0 after an import; replay counts as in order |
| M6 | II-2 | SURVIVES | minor (low) | A late state after the server's shutdown takes `ack_num` back; heals on the server's next repeat |
| M7 | II-3 part 1, III-1 | SURVIVES | major (latent) | Import takes any gate; a low gate reuses sequence, state and fragment numbers silently |
| M8 | III-2, II-3 part 2 | SURVIVES-WITH-CHANGED-SEVERITY | minor (latent), to close before M6 | The clean-mark token is read apart from the export; the wrong order certifies a stale snapshot |
| M9 | III-3 | SURVIVES | minor (low), for the M6 design | Input or a shutdown accepted while quiesced after the export is not in the snapshot |
| M10 | III-6 | SURVIVES | minor | Restore makes the stored clipboard the baseline without comparing with the stored policy |

---

## M1 (I-1, II-5): shutdown based on the shutdown state halts. SURVIVES, major

**mosh.** Quotes are right. `transportsender-impl.h:212-221` (`send_empty_ack`: `new_num =
uint64_t(-1)` when `shutdown_in_progress`, then `add_sent_state`, `send_in_fragments("", new_num)`),
`:325` `inst.set_old_num( assumed_receiver_state->num )`, `:419-424` (the base goes back to the
front only under the 100/1000 byte rule). So mosh does send `old_num = new_num = 2^64-1` with an
empty diff while the shutdown state is "recent", and the full diff from the front once the
intermediate state is older than RTO + 100 ms. The server ignores the former (state held, or
base unknown: `networktransport-impl.h:88-111`).

**Swift.** As claimed: `TransportCore.swift:462-471` makes the shutdown state the assumed state,
`:613-622` puts its number in `oldNum`, `Outbox.swift:154-156` throws `.reservedStateNumber`,
`:378-380` halts. Reproduced: one datagram `3 -> SHUT, diff 0`, then
`.internalError(.reservedStateNumber)`, `isHalted`, no wake-up, no `.shutdownTimedOut`.

**Tried to refute.**
- Threshold (own test): 90 typed bytes give 16 sends, 95 and more halt. So "about 95 bytes" holds.
- Reach: the first shutdown instruction must carry or sit on 100 serialized bytes of
  unacknowledged input that is "recent". Own test with input last sent 1.5 s ago on a dead link:
  16 sends, clean time-out, no halt. So it is not "any disconnect on a dead link": it needs input
  typed or resent within RTO + 100 ms before the disconnect (always true during the first 10 s of
  an outage and for a paste followed at once by Disconnect; one second in three later, when the
  state is resent on the 3 s ack timer, which is the case II-5 measured).
- On a working link the server normally holds state 3, takes `3 -> SHUT` and acknowledges; the
  owner then sees `.internalError` followed by `.shutdownAcknowledged` (reproduced). The damage
  there is a clean disconnect reported as `.halted` (moshcli exit 5).
- Not guarded elsewhere. `MoshSession` passes `.halted` on.

Severity stays major: a legitimate path of the protocol trips the guard that is reserved for
N1 to N4, the 16 retries are lost (an orphan `mosh-server` when the one datagram is lost), and
the trigger is ordinary.

**Fix.** Keep the Outbox guard (PLAN section 1: 2^64-1 "never enters the counter logic"). In
`updateAssumedReceiverState` skip the shutdown state:
`for index in sentStates.indices.dropFirst() where sentStates[index].num != Instruction.shutdownNum`.
The base is then the newest recent ordinary state, or the front. On the wire this is mosh's
sequence with the useless `SHUT -> SHUT` repeats replaced by `3 -> SHUT` (tried: `3 -> SHUT` x 7,
then `2 -> SHUT` with the full diff x 9, `.shutdownTimedOut`). Do not force the front for every
send (II-5's direction): with a large paste pending that is 16 full diffs at once, more than mosh.

**Test (fails before, passes after).** `ReviewITests.testShutdownWithLargeUnackedInput`,
`testShutdownWithLargeUnsentInput`, `ReviewIITests.testShutdownWithALotOfUnacknowledgedInput`:
not halted, 16 shutdown instructions, none with `oldNum == Instruction.shutdownNum`,
`.shutdownTimedOut`; plus the working-link case: `ack: UInt64.max` after two ticks gives
`.shutdownAcknowledged` and no `.internalError`.

## M2 (I-2, II-4): shutdown with input beyond the window halts. SURVIVES, minor

**mosh.** `transportsender.h:140` `assert( !shutdown_in_progress )` in `get_current_state`: the
state is frozen. mosh has no input window; the window is ours (docs/notes/wave1-core.md).

**Swift.** As claimed: `TransportCore.swift:417-419` (`targetEnd` follows the front),
`Outbox.swift:167-170` (rightly) refuses new content under 2^64-1. Reproduced with limits 2 and 4:
`.internalError(.stateContentChanged(18446744073709551615))`, halted.

**Tried to refute.** Needs more than 262,144 input events (bytes) unacknowledged at the moment
of the disconnect and an ack for an earlier state during the shutdown. A paste above 256 KiB
followed at once by Disconnect: rare, and nothing unsafe is sent. Minor is right.

**Fix.** Freeze the target when the shutdown starts: `shutdownTarget = targetEnd` in
`startShutdown`, and `targetEnd` returns it while set. Input beyond the window is then not sent
at all (mosh would send everything; here that could pass the 4 MiB diff limit). Say so in the
doc comment of `startShutdown`.

**Test.** `ReviewIITests.testShutdownWithInputBeyondTheWindow` (limit 2) and the I-2 variant
(limit 4): not halted, the run ends with `.shutdownAcknowledged` or `.shutdownTimedOut`, every
shutdown instruction has the same content.

## M3 (I-3, III-5): shutdown and quiesce. SURVIVES, minor

**mosh.** `stmclient.cc:339-341` and `:485-490`: a shutdown starts only with a remote address.
`transportsender.h:136` sets `shutdown_start = timestamp()`; `transportsender-impl.h:386-391`
gives up after 16 tries or 10 s. mosh has no quiesce, so "10 s of trying" is the intent, not a
quote; the reviewers' reading is fair.

**Swift.** As claimed: `TransportCore.swift:298-303` takes the request while quiesced and starts
the clock, `:325-327` and `:679-686` report the time-out on the first tick after `unquiesce`.
Reproduced: quiesce, `startShutdown`, 11 s (or 60 s), `unquiesce`, tick: 0 datagrams,
`[.shutdownTimedOut]`, `hasEnded`. Also `startShutdown`, `quiesce`, 11 s, `unquiesce`: the same.

**Tried to refute.**
- Reach in the app: Disconnect while quiesced needs a tap between `sceneWillResignActive` and
  the resume in `sceneDidBecomeActive`, or a Disconnect from outside the foreground (a
  notification action). Disconnect and then leaving the app within one round trip is the more
  likely order; it only matters if the first datagrams were lost. Rare, and the result is an
  orphan `mosh-server`, which plan section 4 already has to handle. Minor is right.
- Sub-claim wrong: "moshcli's `shutdown()` loop has no exit" after a server shutdown.
  `ScriptedSession.shutdown()` calls `fatal()` first (`Sources/moshcli/ScriptedSession.swift:185-199, 415`),
  which stops on `serverEnded`, `internalError` and `baseLost`. What remains of part (c) is that
  `startShutdown` returns nothing when it does nothing; a doc matter for the app.

**Fix.** In `unquiesce`: `if shutdownInProgress { shutdownStart = now }` (the tries are kept).
Make `startShutdown` (and `MoshConnection.shutdown()`, `MoshSession.shutdown()`) return a
discardable `Bool`: false when the session has already ended, the server shut down or the core
halted, and say in the doc that no event follows then.

**Test.** `ReviewIIITests.testShutdownAskedWhileQuiescedIsSentAfterResume` (first tick after
`unquiesce` sends `new_num` = 2^64-1, `hasEnded` false); `startShutdown`, tick, `quiesce`, +11 s,
`unquiesce`, tick: a shutdown datagram and no `.shutdownTimedOut`; `startShutdown` after a
delivered server shutdown returns false.

## M4 (I-4): probe interval. SURVIVES-WITH-CHANGED-SEVERITY, note

**mosh.** `transportsender-impl.h:223` `next_ack_time = now + ACK_INTERVAL` for empty acks: right.
But mosh itself resends pending data at `sent_states.back().timestamp + connection->timeout() + ACK_DELAY`
(`:114-116`) for 10 s after it last heard something, which is the same rate.

**Swift.** The number is right (68 empty acks in 10 s with SRTT 10 ms, reproduced). But this is
the documented design, not a slip: docs/notes/wave1-core.md "Probing" says "RTO + 100 ms (about
1.1 s with a fresh estimator)", and `SendTimingTests.swift:259` asserts `[0, 150, 300]`. The
plan's "about every second" is in the cold-start steps, where the estimator is fresh and it holds.

**Consequence.** No protocol risk: the thinned state is never the base (N3 holds, the fuzz of
review I covers thinning), the datagram rate is what mosh uses for pending data, and it stops
after 10 s or at the first reply. Cost: up to 68 state numbers per return to the foreground
without network. Not a defect; the test name ("RetriesEverySecond") and the comment at
`TransportCore.swift:57-58` promise something the code does not do on a fast link.

**Fix (optional, last).** `nextAckTime = now + max(rtt.timeout + ackDelay, 1000)` at
`TransportCore.swift:549`, and change the expectation at `SendTimingTests.swift:259-260`
(`[0, 1000, 2000]`, `[9000, 10000, 13000]`, measured in the copy). Or leave the code and fix the
wording.

**Test.** `ReviewITests.testProbeCount` with an assertion: at most 12 instructions in the 10 s
after `unquiesce` (11 measured with the floor).

## M5 (I-5, II-1, III-4): receive sequence after an import. SURVIVES, minor

**mosh.** `network.cc:515-519`, quoted correctly; one counter for the life of the key.

**Swift.** As claimed: `TransportCore.swift:86`, not set in `init(restoring:)` (`:158-210`), not
in `TransportSnapshot`. Reproduced by both tests: `.authentic`, `lastAuthenticDatagramAt` set,
SRTT 10 -> 700 ms.

**Tried to refute.**
- It cannot happen by accident: late pre-kill datagrams go to the old source port. It needs
  someone who recorded the session and can inject towards the client's new port with the
  server's address. Such an attacker gains what mosh's comment names (timestamp and RTT skew,
  bounded by the 50..1000 ms and 20..250 ms clamps), the end of `probing`, and a false
  `.contact`. No N1 to N4, no state change (the instruction is known or its base is gone), and
  it ends with the first genuine datagram.
- Sub-claim wrong (I-5, III-4): "MoshConnection closes the previous socket". After an import the
  connection is new and has no previous socket; after an in-memory `resume()` the counter is
  kept, so the replay is out of order there.
- The echo of the stale timestamp was not shown by II's test (`next echo []`); it follows from
  `:255-261` and `:631-634` when a send happens within 1 s.
- Real for the plan: section 3 says "If no authenticated datagram arrives after a resume, the
  app ... runs the SSH probe". A replay would count as that datagram.

II-1's "major" does not hold (bounded, needs an active attacker, heals itself); I and III have
it right. The fix is one field, and mosh calls the check security-sensitive, so it is worth doing.

**Fix.** Add `receiverExpectedSequence: UInt64` to `TransportSnapshot`, export
`expectedReceiverSeq`, restore it. Exact, because `receive` ignores datagrams while quiesced.
Add the field to the snapshot row of the table in PLAN section 3.

**Test.** `ReviewIIITests.testAReplayedServerDatagramAfterImportIsOutOfOrder` and
`ReviewIITests.testReplayAfterImportIsNotInOrder`: `.authenticOutOfOrder`,
`lastAuthenticDatagramAt == nil`, `rtt.hasSample == false`, and the next client datagram has
`timestampReply == Timestamp16.none`.

## M6 (II-2): `ack_num` goes back after the server's shutdown. SURVIVES, minor (low)

**mosh.** `networktransport-impl.h:143-160`, quoted correctly: the shutdown state is in
`received_states`, so a later ordinary state is inserted before it and returns before
`set_ack_num`.

**Swift.** As claimed: `TransportCore.swift:764-770` sets `ackNum = new.num` for a state
appended after `processServerShutdown` (`:786-793`). Reproduced: 200 datagrams in 4 s with
`ack_num` 3.

**Tried to refute (own tests).**
- In the order `MoshConnection` uses (receive, tick at once) the ack of the shutdown leaves in
  the same pump unless the client sent something within the last send interval. Gap 25 ms or
  500 ms since the last send: ack sent at once, 0 further datagrams. Gap 5 or 15 ms: the flood.
  So the window is at most one send interval (20 to 250 ms) and needs the server's last frame
  to arrive after its first shutdown datagram.
- "For good" is wrong against a real server: `mosh-server` repeats the shutdown every send
  interval until acknowledged (16 tries, 10 s). One repeat heals it: 5 stray acks, then one ack
  with 2^64-1 and `.serverShutdownAcknowledged` (measured). The flood lasts only if all the
  remaining repeats are lost.

Still a real difference from mosh with a one-line fix. Minor, low priority.

**Fix.** `if !serverShutdownSeen { ackNum = new.num }` at `TransportCore.swift:769`. Keep the
state and the `.remoteStateAdvanced` (a newer screen is a newer screen).

**Test.** `ReviewIITests.testLateStateAfterServerShutdownKeepsTheShutdownAck`:
`acknowledgmentNumber == Instruction.shutdownNum`, `.serverShutdownAcknowledged`, fewer than 5
datagrams (1 measured with the fix).

## M7 (II-3 part 1, III-1): import takes any gate. SURVIVES, major (latent)

**Authority.** PLAN section 1 ("cannot send a sequence number, state number or fragment id that
is not reserved on disk"), section 3 ("A restart begins at the reserved limit"), CLAUDE.md
("must stay impossible by construction"). mosh has no resume; `network.h:86` is one counter per
key.

**Swift.** As claimed: `Outbox.swift:103-108` starts with `lastSequence`, `lastFragmentID`,
`lastIssuedStateNumber` nil; the checks at `:119-122`, `:204-206`, `:239-241` then compare with
nothing but `A`. Reproduced twice: with `A` = 0 and `InMemoryGate()`, sequence 0, state 1 and
fragment id 1 go out again with other content, no event; with `A` = 2 and a gate at
`(0, 3, 1)`, sequence 0, fragment id 1 and state 3 with "abc" + Resize, `isHalted` false.

**Tried to refute.** No caller today passes a wrong gate, and the M6 file gate will read its own
counters file, which is where "by construction" mostly lives. But the transport is the last
check before the cipher, its doc claims the checks "use only what this type recorded itself",
and after an import it has recorded nothing. A wrong argument gives N1 with no guard firing.
That is what the rule in CLAUDE.md forbids, and the check costs three numbers. Major stays, with
"latent" attached: not a live bug.

**Fix.** Add `usedCounters: GateCounters` to `TransportSnapshot` (the first unused sequence,
state and fragment numbers as the Outbox knows them; after an import that sent nothing, the
imported values, so that export of a fresh import still equals the snapshot). In
`init(restoring:)` throw a new `SnapshotError.gateBelowSnapshot` unless `gate.reservedLimits`
is at or above each, and seed the Outbox's `last…` values from them so the per-send checks also
catch a gate whose limits are right and whose next numbers are not. A gate that starts at the
old reserved limits always passes.

**Test.** `ReviewIITests.testImportWithAGateBelowTheOldNumbersIsRefused` and
`ReviewIIITests.testImportWithAGateBelowTheOldLimitsMustNotSend` (the initializer throws); a
third with a gate whose limits are high and whose counters start low (test double): the first
tick halts with `.sequenceNotIncreasing` and returns no datagram.
`testExportOfAFreshImportIsTheSnapshot` must still pass.

## M8 (III-2, II-3 part 2): the clean mark is not tied to the export. SURVIVES-WITH-CHANGED-SEVERITY, minor (latent)

**Authority.** PLAN section 3, "Quiesce before snapshot", step 4.

**Swift.** As claimed: `exportState()` returns only the snapshot (`TransportCore.swift:871-885`,
`MoshConnection.swift:216-218`, `MoshSession.swift:228-230`); `MoshConnection` stores the gate
(`:67`) and never reads it. The scratch test passes a token read after a later send and
`markClean` returns true.

**Tried to refute.** The test shows misuse, not a defect of today's code: the gate cannot know
when the token was read. With the documented order (docs/notes/wave1-core.md, "For M6": count
after `quiesce()`, write, mark clean) every interleaving is safe, including a `resume()` between
any two steps: either `exportState()` throws `.notQuiesced` or `markClean` returns false. So
"major" overstates the present state; no caller is wrong. It stays a finding because the wrong
order type-checks, the result is N2 (`user.cc:68-69`, quoted correctly), and one return value
removes the possibility. II-3's "stale snapshot" case is this same seam; checking
`gate.isDirty` in `init(restoring:)` is not the answer, because cold-start step 3 writes
`dirty = 1` before the sender is rebuilt.

**Fix.** `MoshConnection.exportState()` returns the snapshot together with
`gate.datagramsPassed`, read in the same actor call (the core is quiesced, so the pair is
consistent); `MoshSession.exportState()` passes it on. M6's writer uses only that token.

**Test.** Connection level: quiesce, export (snapshot, token), `resume()`, `type("x")`, wait for
a datagram, `gate.markClean(ifDatagramsPassed: token)` is false. (The scratch test
`testMarkCleanCannotSucceedForAStaleSnapshot` reads the token late on purpose and cannot pass;
replace it with this one.)

## M9 (III-3): changes after the export while quiesced. SURVIVES, minor (low)

**Swift.** As claimed: `type`, `resize` (`TransportCore.swift:217-237`) and `startShutdown`
(`:298-303`) are accepted while quiesced; `markClean` counts datagrams only. Reproduced.

**Tried to refute.** An inactive scene gets no touches and no key events, so the window is what
the app delivers late (a paste completion, a debounced resize, a queued "close"). The loss needs
a kill while still quiesced, and is then those events only; a foreground kill in stage 1 loses
the whole session. No protocol damage. A forgotten shutdown request means the cold start
resumes a session the user closed. Low, but real, and it is the app's M6 coordinator that has
to act, not the transport.

**Fix (with M6, not now).** The core counts accepted changes (`type`, `resize`,
`startShutdown`); the export token of M8 carries that count; the coordinator marks clean only
if it is unchanged and snapshots again when input arrives while quiesced. A shutdown asked for
while quiesced marks the record ended. Add this to "For M6" in docs/notes/wave1-core.md.

**Test.** `ReviewIIITests.testInputAfterExportIsNotCoveredByTheCleanMark`, rewritten against
the token: quiesce, export, `type`, then the clean mark with the old token is refused.

## M10 (III-6): clipboard policy one state behind. SURVIVES, minor

**Authority.** PLAN section 3, cold start step 7.

**Swift (read, not run).** `MoshSession.exportState()` (`MoshSession.swift:228-230`) takes the
transport snapshot on the connection actor and reads `clipboard` on the session actor; the
policy advances only in `reportNewestScreen` (`:329-342`), which itself awaits the connection
before `observe`. A `.remoteStateAdvanced` still in the stream, or a `reportNewestScreen`
suspended at its await, leaves `lastSeen` one state behind the snapshot. `start()` of a restored
session then calls `clipboard.baseline(...)` unconditionally (`:161-166`), and since mosh sends
the OSC only on a change (`ClipboardPolicy.swift:13-15`) the copy is never written.

**Tried to refute.** The window is the delay of one event (well under a millisecond without
load) and a kill must follow while in the background. Nothing is lost in memory. Minor is right.
Not refuted, because the plan's step 7 asks for a comparison and the code makes none.

**Fix.** In `start()` of a restored session: if the stored newest state's clipboard equals
`clipboard.lastSeen`, do nothing; otherwise run `clipboard.observe(_, live: true)` and report a
`.write` or `.invalid` (the hash check still stops a double write). The screen stays
`isLive: false`.

**Test.** `MoshSessionTests`: a `SessionSnapshot` whose newest remote state has an OSC 52
clipboard and whose policy has `lastSeen` of the state before; `MoshSession(restoring:)`,
`start()`: one `.clipboard(.write)`. Control: the same with `lastSeen` equal: no clipboard event.

---

## Fix order

1. **M1** (the only live major), then **M2** and **M3** in the same place (`startShutdown`,
   `updateAssumedReceiverState`, `unquiesce`). Three small edits, tried together in the copy.
2. **M6**: one line.
3. **M7, M5, M8** as one change to the snapshot and the export call (`usedCounters`,
   `receiverExpectedSequence`, export returns the clean token), before item 4 (M6 on Linux) fixes
   a record format. Update the snapshot row in PLAN section 3 and "For M6" in wave1-core.md.
4. **M10**: `MoshSession.start()`.
5. **M4**: optional floor or wording only; touches `SendTimingTests.swift:259-260`.
6. **M9**: no code now; a line in "For M6", done with the resume coordinator.

---

## Status

Fixes made in cloud round 5 on `cloud-work`, in the fix order above. Each test was seen to
fail on the code before its fix. Suite after the last fix: `scripts/dev.sh swift test -j 4`,
543 tests, 33 skipped, 0 failures (523 before).

| Merged | Status | Commit | Tests |
|---|---|---|---|
| M1 | fixed | `df4da95` | `ShutdownReviewTests`: `testShutdownWithRecentUnacknowledgedInputIsRepeatedAndTimesOut`, `testShutdownWithUnsentInputIsRepeatedAndTimesOut`, `testShutdownAfterALongOutageWithUnacknowledgedInput`, `testShutdownWithRecentUnacknowledgedInputIsAcknowledged` |
| M2 | fixed | `df4da95` | `ShutdownReviewTests.testShutdownStateDoesNotMoveWithTheInputWindow` (limits 2 and 4) |
| M3 | fixed | `df4da95` | `ShutdownReviewTests`: `testShutdownAskedWhileQuiescedIsSentAfterResume`, `testShutdownClockDoesNotRunWhileQuiesced`, `testStartShutdownReportsWhetherAnOutcomeFollows` |
| M4 | wording fixed, no behaviour change | `98b5da8` | none new; `SendTimingTests.testProbeAfterASocketReplacementSendsAtOnceAndRetriesAtTheRetransmissionTimeout` (renamed, same assertions) |
| M5 | fixed | `664e2c8` | `SnapshotReviewTests.testAReplayedServerDatagramAfterImportIsOutOfOrder` |
| M6 | fixed | `01e672c` | `ServerShutdownReviewTests.testLateStateAfterServerShutdownKeepsTheShutdownAck` |
| M7 | fixed | `664e2c8` | `SnapshotReviewTests`: `testImportWithANewGateIsRefused`, `testImportWithAGateBelowWhatWasUsedIsRefused`, `testAGateWithGoodLimitsAndUsedNumbersIsStoppedAtTheFirstSend`, `testExportCarriesTheFirstUnusedNumbers`, `testImportRefusesCountersThatDoNotFitTheSnapshot`, `testCountersCarryOverASecondExport` |
| M8 | fixed | `664e2c8` | `SnapshotReviewTests.testTheCleanTokenBelongsToTheExportedSnapshot`; `ConnectionIntegrationTests` now marks clean with the export's token |
| M9 | fixed in item 4's coordinator (cloud round 7), see below | `2409b46` | `ResumeCoordinatorTests`: `testInputAcceptedInTheBackgroundIsInTheRecord`, `testAResizeAcceptedInTheBackgroundIsInTheRecord`, `testAProcessDeathAtEveryStepOfBackgroundInput`, `testBackgroundInputIsRefusedWhenTheRecordCannotBeWritten`, `testAShutdownInTheBackgroundEndsTheRecord`, `testAShutdownInTheForegroundEndsTheRecord`; `ResumeCoordinatorServerTests.testALineTypedInTheBackgroundReachesTheServerAfterAColdStart` |
| M10 | fixed | `65fb952` | `RestoredClipboardTests` (3 tests) |

Where a fix differs from the recommendation above:

- **M1.** As recommended, plus: `sendToReceiver` no longer makes the shutdown state the assumed
  state after a send (it was recomputed before every use anyway). Known cost, accepted: with
  input that was typed and never sent before the disconnect, every one of the 16 shutdown
  sends carries the full diff from the acknowledged state (mosh sends it once and then
  `SHUT -> SHUT` with an empty diff, which a server that missed the first one cannot use).
- **M2.** The target is fixed in `startShutdown`. Input beyond the window at that moment is not
  sent; the doc comment of `startShutdown` says so.
- **M3.** `unquiesce` restarts the 10 s clock and keeps the tries. `startShutdown`,
  `MoshConnection.shutdown()` and `MoshSession.shutdown()` return a discardable `Bool`: true
  when a shutdown is running (also when it already was), false when no outcome event will
  follow (ended, server shut down, halted, closed).
- **M5, M7, M8.** One snapshot change, described for item 4 in `docs/notes/wave2-session.md`
  ("Snapshot changes after the transport review"): two new fields (`usedCounters`,
  `receiverExpectedSequence`), two new `SnapshotError` cases (`gateBelowSnapshot`,
  `usedCountersInvalid`), and `exportState()` of the connection and the session returns the
  snapshot with a `CleanToken`. `ResumeSeamTests.testImportWithNothingPendingSendsAnEmptyAck`
  answered an import from a fake server whose sequence numbers began again at 0; it now hands
  the old fake server over, as the other import tests do (assertions unchanged).
- **M6.** As recommended, and `remote_heard` and `set_data_ack` are skipped too, as in mosh
  (networktransport-impl.h:143-160 returns before all three).
- **M10.** `start()` of a restored session always runs `observe(_, live: true)` on the stored
  clipboard; equal to `lastSeen` gives `.unchanged`, which is the "do nothing" branch.
- **M4.** Wording only (comments in `TransportCore.swift`, "Probing" in
  `docs/notes/wave1-core.md`, the test's name). The optional 1 s floor was not added.

### M9: requirement for item 4's resume coordinator

**Met in cloud round 7** by `ResumeCoordinator` (`Sources/MoshResume/ResumeCoordinator.swift`;
`docs/RESUME.md`, "M9: closed"). The second way of point 1 was taken: the coordinator is the
only caller of `type`, `resize` and `shutdown`, and in the background it writes "dirty" (or
"ended") before the session gets the change and saves again after it. Point 4's test is
`testInputAcceptedInTheBackgroundIsInTheRecord` and, with a process death at every storage
step, `testAProcessDeathAtEveryStepOfBackgroundInput`. The requirement as it was written:

Not fixed in the transport, on purpose: the transport cannot know what the writer stored. The
coordinator of item 4 (`MoshResume`) must meet these, each with a test:

1. **A clean mark covers accepted input, not only datagrams.** `type`, `resize` and
   `shutdown` are accepted while quiesced and pass no datagram through the gate, so
   `CleanToken` (today: `datagramsPassed` only) does not see them. Either the core counts
   accepted changes and `exportState()` puts the count into `CleanToken` (the type exists so
   that a field can be added without changing a signature), with `markClean` refused when it
   moved; or the coordinator is the only caller of `type`/`resize`/`shutdown` while quiesced
   and snapshots again (export, write, mark clean) after each one. Until one of the two is in
   place, a kill while quiesced can lose input typed after the export, with a clean record.
2. **Snapshot again after input while quiesced.** If input arrives between the export and the
   kill, the stored snapshot must end up holding it, or the record must be dirty.
3. **A shutdown asked for while quiesced ends the record.** `exportState()` already throws
   `.sessionEnded` once a shutdown has started; the coordinator must mark the record ended
   (delete it, or a state that the cold start does not resume), so that a session the user
   closed is not resumed. Since the M3 fix the request itself is sent after `resume()` with
   its full 10 s.
4. Test, rewritten from `ReviewIIITests.testInputAfterExportIsNotCoveredByTheCleanMark`:
   quiesce, export, `type`, then the clean mark with the old token is refused (or a second
   snapshot holding the input exists before the record is clean).
