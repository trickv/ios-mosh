# Review III: export, import, quiesce and DurabilityGate against PLAN section 3

Code at `cloud-work` 94e5aae. Nothing in the repo was changed. Scratch tests are in a copy:

- `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/review-iii/Tests/MoshTransportTests/ReviewIIITests.swift`
  (one test per finding III-1 to III-5, each asserts the wanted behaviour and fails today)
- `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/review-iii/Tests/MoshTransportTests/ReviewIIIFuzzTests.swift`
  (a model of mosh-server's receive side with its asserts, see "What held")

Run there with `swift test --filter ReviewIIITests` (about 1 s) and
`swift test --filter ReviewIIIFuzzTests` (about 4 min).

## Summary

No critical finding. With the seams used as the notes describe (quiesce, read the gate's
count, export, write, mark clean; a new gate from the old limits) I could not make the client
break N1 to N4 or lose or repeat input. The findings are places where that correct use is
not enforced by the code, and three small defects.

| Id | Severity | One line |
|---|---|---|
| III-1 | major | Import takes any gate: one that starts below the old limits reuses nonces and state numbers and nothing notices |
| III-2 | major | The clean mark is not tied to the snapshot: a token read after the export marks a stale snapshot clean (N2 on the next cold start) |
| III-3 | minor | Input and a shutdown request accepted while quiesced, after the export, are not in the snapshot and the record still goes clean |
| III-4 | minor | The receiver's expected sequence number is not in the snapshot: after an import any recorded server datagram counts as in order |
| III-5 | minor | A shutdown asked for while quiesced times out on resume without one datagram sent |
| III-6 | minor | The session snapshot pairs the transport state with a clipboard policy that may be one state behind; restore then drops that copy |

## What held (so nobody re-checks it)

- Reading: export pairs `A` with `log[front.end...]` (TransportCore.swift:876-877), which is
  right also between an ack and the next tick. Import's first instruction is
  `old = throwaway = A`, `new` = gate's next number, `ack` = newest held state. The server
  still holds `A` (the client never sent a `throwaway_num` above its front) and the client
  holds the server's front (it only drops below a `throwaway_num` the server sent, and that
  is a number the client acknowledged).
- Quiesce: `tick`, `sendPendingNow` and `receive` all check `isQuiesced`; a timer task that
  fires after `quiesce()` runs `pump()`, which sends nothing and opens no socket
  (MoshConnection.swift:381); inbox events of closed sockets are dropped by socket id
  (MoshConnection.swift:349). `POSIXDatagramTransport.send` holds the lock across `sendto`,
  so a closed descriptor is not reused.
- A failed gate call drops every datagram of the instruction and undoes the sent state
  (TransportCore.swift:526-545, 558-581); the retry takes a new state number.
- Fuzz: 900 seeds, 21,471 cold imports plus in-memory resumes, with 25% loss, duplicates,
  reordering (pre-kill datagrams arriving after a resume, in both directions), quiesce right
  after `sendPendingNow`, input typed between quiesce and export, a gate that fails 10% of
  its calls, an input window of 16 events, and 3000-byte instructions in several fragments.
  Checked on the wire: no sequence number twice, no state number with two contents, no
  fragment id with two contents, `throwaway_num <= old_num`. Checked in the model server:
  `UserStream::diff_from`'s and `subtract`'s prefix asserts (user.cc:55-56, 68-69) and
  `process_throwaway_until` (networktransport-impl.h:183) never fire; after settling the
  server applied exactly the typed events in order and the client's newest remote state is
  the server's. 0 failures. The same fuzz with one send after the export (a stale snapshot)
  trips the `diff_from` assert in 60 of 60 seeds, so the model does see N2.

## III-1 (major) Import accepts a gate that does not start at the old limits

**Where.** `TransportCore.init(restoring:)`, Sources/MoshTransport/TransportCore.swift:158-210:
the gate is taken as given (comment at :155 "a gate that starts at the old reserved
limits"). `Outbox.init`, Sources/MoshTransport/Outbox.swift:103-108: after an import
`lastSequence`, `lastFragmentID` and `lastIssuedStateNumber` are nil and `known` is
`[(A, 0)]`, so the N1/N2/N4 checks (Outbox.swift:119-122, 204-206, 239-241) compare with
nothing from the old process except `A`. `TransportSnapshot`
(Sources/MoshTransport/TransportTypes.swift:187-198) carries no counter. The facade says so:
Sources/MoshSession/MoshSession.swift:110-112 "The gate must start at or above the old
session's reserved limits ... this type does not check either."

**Plan.** Section 1: "The transport cannot send a sequence number, state number or fragment
id that is not reserved on disk." Section 3, Reserve ahead: "A restart begins at the reserved
limit." CLAUDE.md: N1 to N4 "must stay impossible by construction".

**What differs.** The only thing caught is a gate whose state counter is at or below `A`
(`stateNumberNotIncreasing`, at the first tick). A state counter in `(A, last sent]`, and any
sequence or fragment counter at all, passes every check. The old limits are an argument the
caller copies by hand (`InMemoryGate(startingAt: old.reservedLimits)` in moshcli
ScriptedSession.swift:360-367 and in the tests); M6's cold start will do the same from the
counters file.

**Consequence.** Confirmed by `testImportWithAGateBelowTheOldLimitsMustNotSend`: old session
used sequences 0, 1, 2 and sent state 3 = "abc" unacknowledged (`A` = 2). Import with
`InMemoryGate(startingAt: GateCounters(sequence: 0, state: 3, fragmentID: 1))` and a changed
view size sends, with no event and `isHalted` false: sequence 0 again (N1: a second
plaintext under a used OCB nonce), fragment id 1 again (N4), and state 3 again with the
content "abc" + Resize (N2). On mosh-server the datagram is below `expected_receiver_seq`, so
it is used but the server does not move to the new address (network.cc:515 "don't use (but
do return) out-of-order packets for timestamp or targeting"), and the instruction is dropped
because the number is held (networktransport-impl.h:88 "first, make sure we don't already
have the new state"): the Resize never arrives and the session hangs, after the nonce was
already reused. If the server does not hold the reused number any more, it gets a second
content under it.

**Test idea.** As the scratch test: export from a session with an unacknowledged state, then
`TransportCore(restoring:gate:)` with a gate whose counters are below
`oldGate.reservedLimits`; expect either the initializer to throw or the first `tick` to halt
with `.internalError` and return no datagram. One way to make it hold by construction: put
the used floors (last sequence, last fragment id, last issued state number, or simply the old
`reservedLimits`) into `TransportSnapshot`, seed `Outbox` with them, and refuse a gate whose
`reservedLimits` are below them at import.

## III-2 (major, latent) The clean mark is not bound to the snapshot it certifies

**Where.** `exportState()` returns only the snapshot (TransportCore.swift:871-885,
MoshConnection.swift:216-218, MoshSession.swift:228-230). The token for
`markClean(ifDatagramsPassed:)` (Sources/MoshTransport/DurabilityGate.swift:63-71) is read
by the caller from the gate in a separate step. `MoshConnection` stores the gate
(MoshConnection.swift:67, 146) and never uses it. `quiesce()`, `exportState()` and `resume()`
are three actor calls; on `MoshSession` each suspends (`await connection...`), so other
lifecycle calls run in between.

**Plan.** Section 3, Quiesce before snapshot, step 4: "Write `dirty = 0`, but only if no
datagram passed the gate since step 2. The check and the write are one critical section."
And: "Lifecycle operations run one at a time, in arrival order: a quiesce finishes before a
return to the foreground starts." The plan notes that `sceneWillResignActive` "runs often".

**What differs.** "Since step 2" holds only if the caller reads `datagramsPassed` before the
export. The order `quiesce, export, read token, write, markClean` type-checks and passes
every existing test, and is wrong: a `resume()` between the export and the token read (the
scene became active again) sends, the token is read after that send, and `markClean`
succeeds. Confirmed by `testMarkCleanCannotSucceedForAStaleSnapshot`: export with nothing
pending, `unquiesce`, type "x" (sent as a new state), read token, `markClean` returns true.
Until the next datagram sets `dirty` again (up to the 3 s ack interval) the record says
clean for a snapshot that lacks "x".

**Consequence.** A kill in that window, then a cold start: the client's first state is `A`
plus the snapshot's pending input, shorter than the state the server already has. The server
makes it its newest state and `get_remote_diff` runs
`received_states.back().state.diff_from( last_receiver_state )`
(networktransport-impl.h:191) into `assert( my_it != actions.end() )` (user.cc:68): N2,
mosh-server exits and the shell is gone. The fuzz's stale variant reaches that assert in 60
of 60 seeds. No current caller uses the wrong order (ConnectionIntegrationTests.swift:156-163
reads the token first); M6 has to get it right from a note in docs/notes/wave1-core.md:230-233.

**Test idea.** Core level, as the scratch test. The fix that makes the test meaningless in a
good way: `MoshConnection.exportState()` returns the snapshot together with
`gate.datagramsPassed` read inside the same actor call (the core is quiesced there, so the
pair is consistent), or the gate gets `markClean(for: token)` where the token can only come
from an export. Then test: quiesce, export (snapshot, token), resume, type, wait for a send,
`markClean(token)` must be false.

## III-3 (minor) State that changes without a datagram is invisible to the clean mark

**Where.** `type`, `resize` and `startShutdown` are accepted while quiesced
(TransportCore.swift:217-237 "Input is still accepted while quiesced", :298-303 has no
`isQuiesced` check). `markClean` counts datagrams only.

**Plan.** Section 3: the snapshot holds "the input events since `A`"; "A snapshot is valid
only while `dirty = 0`."

**What differs.** After `exportState()` the exported state can still change (more input, a
shutdown request) and `markClean(token)` still succeeds, because nothing passed the gate.
Confirmed by `testInputAfterExportIsNotCoveredByTheCleanMark`.

**Consequence.** If the process is killed while quiesced: keystrokes or a paste accepted
after the export are gone without a trace, and a `shutdown()` asked for after the export is
forgotten, so the cold start resumes a session the user ended. No protocol damage (the
snapshot is a prefix of what the client knew). Reachable when the UI still delivers input
or a "close session" action between `sceneWillResignActive` and suspension.

**Test idea.** Quiesce, token, export, `type("x")`, `startShutdown`, then
`markClean(token)`: expect false, or expect `type`/`startShutdown` to be refused or to
invalidate the export (for example a generation number in the core that export records and
the clean mark checks).

## III-4 (minor) `expectedReceiverSeq` is not carried over an import

**Where.** TransportCore.swift:86 (`expectedReceiverSeq = 0`), not set in
`init(restoring:)` (:180-209), not in `TransportSnapshot` (TransportTypes.swift:187-198);
used at :252-267.

**mosh.** network.cc:515-519: "don't use (but do return) out-of-order packets for timestamp
or targeting" and "this is security-sensitive because a replay attack could otherwise screw
up the timestamp and targeting". The server process lives on across the client's restart, so
its sequence numbers continue; only the client forgets them.

**What differs.** After a cold start every server datagram ever recorded on the path is "in
order" once. Confirmed by `testAReplayedServerDatagramAfterImportIsOutOfOrder`: a datagram
the old core returned `.authenticOutOfOrder` for is `.authentic` in the restored core and
sets `lastAuthenticDatagramAt`.

**Consequence.** With one replayed old datagram: `probing` ends (:266), so a lost first
datagram after the resume is retried after 3 s and not after about 1 s as the plan's step 5
wants; `MoshConnection` yields `.contact` and drops the previous socket
(MoshConnection.swift:355-361), so the "Last contact" banner is reset though the server was
not heard; the stale `timestamp_reply` is fed to the RTT estimator (:262-264, accepted when
the 16-bit difference is below 5000) and the stale timestamp is echoed to the server
(:255-261), which skews both sides' RTT. The instruction itself stays harmless (state numbers
decide that).

**Test idea.** As the scratch test: deliver server datagrams 2, 3, 4 to the old core, export,
import, deliver datagram 2 again; expect `.authenticOutOfOrder`, no change of
`contactTimes.lastAuthenticDatagramAt` and of `rtt.srtt`. Fix: add the receiver's expected
sequence number to the snapshot.

## III-5 (minor) A shutdown asked for while quiesced is never sent

**Where.** `startShutdown` sets `shutdownStart = now` also when quiesced
(TransportCore.swift:298-303); the first `tick` after `unquiesce` runs
`checkShutdownTimeout` before the sender (:325-327, :679-686).

**mosh.** transportsender.h:136 `start_shutdown` starts the clock when the sender can send;
the 10 s (`ACTIVE_RETRY_TIMEOUT`) and the 16 tries count attempts to tell the server.

**What differs.** Time spent quiesced counts. Confirmed by
`testShutdownAskedWhileQuiescedIsSentAfterResume`: quiesce, `startShutdown`, 11 s later
`unquiesce` and `tick`: no datagram, events `[.shutdownTimedOut]`, `hasEnded` true.

**Consequence.** `MoshSession` reports `.shutdownFinished(acknowledged: false)` at once and
the app closes the session; mosh-server and the shell were never told and stay running (an
orphan that the identity check in plan section 4 has to find later). Also, while this
request is pending `exportState()` throws `.sessionEnded`, so no snapshot can be taken.

**Test idea.** As the scratch test: expect the first tick after `unquiesce` to send
`new_num = 2^64 - 1` and `hasEnded` to be false. Fix: start (or restart) `shutdownStart` and
`shutdownTries` at `unquiesce`, or refuse `startShutdown` while quiesced.

## III-6 (minor) The session snapshot can pair remote states with an older clipboard policy

**Where.** `MoshSession.exportState()`, Sources/MoshSession/MoshSession.swift:228-230: the
transport snapshot is taken on the connection actor, then `clipboard` is read on the session
actor. The policy only advances in `reportNewestScreen` (:329-342), driven by the event
stream, so a `.remoteStateAdvanced` that is still queued is in the transport snapshot and
not in the policy. `start()` of a restored session then calls
`clipboard.baseline(newest.state.framebuffer.clipboard)` unconditionally (:161-166).

**Plan.** Section 3, cold start step 7: "The first server state after a resume writes the
iOS clipboard only if its hash differs from the one in the snapshot."

**What differs.** The restore does not compare anything with the stored policy: whatever
clipboard the stored newest state has becomes the baseline. If that state's OSC 52 change
was not observed before the export (`lastSeen` in the snapshot differs from the newest
state's field), it is never written after a cold start.

**Consequence.** A copy made in the terminal right before leaving the app (the usual reason
to leave: paste somewhere else) is lost if the process dies before the queued event is
handled. The window is small (the event is normally handled within a millisecond), which is
why this is minor; in memory nothing is lost.

**Test idea.** Unit level with `MoshConnection<TerminalRemoteState>` and a fake transport:
deliver a state with an OSC 52 clipboard, and build a `SessionSnapshot` whose `clipboard`
policy has `lastSeen` = the previous state's field (what `exportState()` returns when the
event is still queued). `MoshSession(restoring:)`, `start()`: expect a `.clipboard(.write)`
for the stored newest state (or expect `exportState()` to drain the event stream first so
that the two parts agree). Today: no clipboard event.
