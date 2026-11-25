# Review (i): sender timing, retransmission, sent-states list

Scope: `Sources/MoshTransport` (`TransportCore.swift`, `Outbox.swift`, `RTTEstimator.swift`,
`UserInput.swift`, `MoshConnection.swift`, `DurabilityGate.swift`) and the sender's use of
`MoshWire`, against mosh 1.4.0 in `.refs/mosh/src` (`network/transportsender-impl.h`,
`transportsender.h`, `networktransport-impl.h`, `network.cc`, `transportfragment.cc`,
`statesync/user.cc`, `frontend/stmclient.cc`). Branch `cloud-work`, working tree clean, nothing
in the repo was changed.

How it was checked: line-by-line reading, plus scratch tests run in a copy of the repo
(`swift test --filter ReviewI...`). The test sources are kept in
`/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/review-i/ReviewITests.swift`
and
`/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/review-i/ReviewIFuzzTests.swift`
(drop them into `Tests/MoshTransportTests/`; they use the existing `Harness`). Findings I-1 to
I-4 were reproduced with them; I-5 is from reading only.

## Summary

| Id | Severity | One line |
|---|---|---|
| I-1 | major | Client shutdown with 100 bytes or more of recent unacknowledged input halts the transport on the second shutdown send (`old_num` = shutdown state is refused by the Outbox) |
| I-2 | minor | Client shutdown with more input pending than the input window halts when an ack moves the window (`stateContentChanged` on the shutdown state) |
| I-3 | minor | A shutdown started or continued while quiesced never finishes, or "times out" without a single shutdown datagram sent; `startShutdown` after a server shutdown gives no outcome at all |
| I-4 | minor | Probe acks after `unquiesce` / `socketReplaced(probe: true)` repeat at RTO + 100 ms: 68 datagrams and 68 state numbers in 10 s on a fast link, not "about every second" |
| I-5 | minor | `expectedReceiverSeq` is not carried over a restore: replayed old server datagrams count as in order and feed RTT, the timestamp echo and `probing` |

What was compared and found equal (no finding): `calculate_timers` (all four branches, the
`pending_data_ack` rule, the shutdown speed-up), `tick` (early return, empty-ack and send
branches, `mindelay_clock`), `update_assumed_receiver_state`, the prospective resend rule
(`<=`, `< 1000`, `< 100`), `send_to_receiver` numbering, the thinning position (16th from the
end above 32), `process_acknowledgment_through` (culled acks ignored), `shutdown_ack_timed_out`
(16 sends or 10 s), SRTT/RTTVAR/RTO/send interval and their clamps, the timestamp echo (once,
under 1 s, corrected), out-of-order datagrams, the port hop condition, `throwaway_num` =
front, `ack_num` = newest in-order remote state, constants (3000, 100, 1, 16, 10000, 20/250,
50/1000).

A randomized test (`ReviewIFuzzTests`, 400 seeds x 600 steps: typing up to 1500 bytes at a
time, resizes, 0 to 100 % loss towards the server, a server that goes silent, gate failures,
`socketReplaced`, quiesce, `sendPendingNow`, export and restore into a new core with a new
gate) with a model of mosh-server's state list and its `UserStream` asserts found, without
shutdown: no halt, no N1 (sequence numbers strictly increasing across restores), no N2 (every
state the model server stored extends every lower-numbered one), no N3, no N4, the sent-states
list never above 32, no wake-up that stays due, and all input delivered exactly once in order.
With shutdown it found only I-1.

---

## I-1 (major): shutdown with recent unacknowledged input of 100 bytes or more halts the transport

Swift:
- `Sources/MoshTransport/TransportCore.swift:462-471` (`updateAssumedReceiverState` makes the
  shutdown state the assumed state once it is the newest recent state),
- `:506-522` (the prospective-resend rule moves the base back to the front only when the diff
  from the front is under 100 bytes),
- `:525-535` (`sendEmptyAck` in a shutdown) and `:613-622` (`oldNum: assumed.num`),
- `Sources/MoshTransport/Outbox.swift:154-156`:
  `guard request.oldNum != Instruction.shutdownNum ... else { throw OutboxError.violation(.reservedStateNumber) }`.

mosh, `src/network/transportsender-impl.h`:
- 189-193: `if ( diff.empty() ) { if ( (now >= next_ack_time) ) { send_empty_ack(); ...`
- 212-221: `uint64_t new_num = sent_states.back().num + 1; /* special case for shutdown sequence */ if ( shutdown_in_progress ) { new_num = uint64_t( -1 ); } ... add_sent_state( now, new_num, current_state ); send_in_fragments( "", new_num );`
- 325: `inst.set_old_num( assumed_receiver_state->num );` (no restriction: mosh sends
  `old_num = new_num = 2^64-1` here; the server ignores it or already has the state),
- 419-424: the base goes back to the front only `if ( (resend_diff.size() <= proposed_diff.size()) || ( (resend_diff.size() < 1000) && (resend_diff.size() - proposed_diff.size() < 100) ) )`.

What differs: in mosh the second and later shutdown instructions may be based on the shutdown
state itself; mosh keeps sending, and once the first shutdown state is older than RTO + 100 ms
the base falls back to the front and the full diff goes out with `new_num` = 2^64-1. The Swift
sender computes the same base, but the Outbox refuses `old_num` = 2^64-1 as an invariant
violation, so the core sets `isHalted` and never sends again.

When: `startShutdown` while the input not yet acknowledged serializes to 100 bytes or more
(about 95 typed bytes; or 1000 events) and every state after the front was sent within
RTO + 100 ms (150 to 1100 ms) or is still unsent. Typical: paste or type a line and disconnect
at once; `moshcli` `type <long text>` followed by `shutdown`. The second shutdown tick comes
one send interval (SRTT / 2) after the first, so the server's ack (one RTT) practically never
arrives before it.

Reproduced (`ReviewITests.testShutdownWithLargeUnackedInput`, `...UnsentInput`,
`...OnAWorkingLink`):
- state 3 (200 bytes) sent, shutdown: one datagram `3 -> SHUT, diff 0`, then
  `.internalError(.reservedStateNumber)`, `isHalted == true`, `nextWakeup == nil`; 1 shutdown
  send instead of 16, no `.shutdownTimedOut`.
- With 20 bytes pending the same sequence sends 16 times and ends with `.shutdownTimedOut`.

Consequence:
- Working link: the owner gets `.internalError` (MoshSession: `.halted`, moshcli exit 5) and
  then, when the ack of the first shutdown datagram arrives, `.shutdownAcknowledged`. A clean
  disconnect is reported as a broken transport.
- First shutdown datagram lost, or the state it builds on lost (in the reproduced case the
  only shutdown datagram is `3 -> SHUT`, which the server ignores if it never got state 3):
  nothing is retried, the server never learns of the shutdown, `mosh-server` and the remote
  shell keep running, and neither `.shutdownAcknowledged` nor `.shutdownTimedOut` is ever
  reported (`checkShutdownTimeout` runs only while `canSend`).

Failing test (fake clock, `Harness`):
```
var h = Harness(); h.connectAndSettle()
h.type(String(repeating: "x", count: 200)); h.advanceToWakeup()   // state 3 sent, not acked
h.core.startShutdown(now: h.now)
var sends = h.tick().count
while h.lastWakeup != nil, h.now < start + 20_000 { sends += h.advanceToWakeup().count }
XCTAssertFalse(h.core.isHalted)
XCTAssertFalse(h.events.contains { if case .internalError = $0 { true } else { false } })
XCTAssertEqual(sends, 16); XCTAssertTrue(h.events.contains(.shutdownTimedOut))
// and: at least one of the 16 has oldNum == 2 (the acknowledged state) and the 200 bytes
```
Second case: the same with the 200 bytes typed but not ticked before `startShutdown`. Third
case: deliver `ack: UInt64.max` after two ticks and expect `[.shutdownAcknowledged]` with no
`.internalError`.

Direction for the fix (not applied): while a shutdown is in progress never use the shutdown
state as the base (fall back to the newest earlier assumed state or to the front, which also
puts the diff into every shutdown datagram), instead of loosening the Outbox guard.

## I-2 (minor): shutdown with more pending input than the input window halts

Swift: `Sources/MoshTransport/TransportCore.swift:417-419` (`targetEnd` is capped at
`front.end + unacknowledgedInputLimit` and so grows when an ack moves the front), `:562-574`
(`sendToReceiver` keeps the shutdown entry and only refreshes its timestamp, then sends with
the new `target`), `Sources/MoshTransport/Outbox.swift:167-170`
(`if let shutdownEnd, shutdownEnd != request.newEnd { throw ...stateContentChanged }`).

mosh: `src/network/transportsender.h:140-146`
`MyState &get_current_state( void ) { assert( !shutdown_in_progress ); return current_state; }`:
the current state is frozen once a shutdown begins, so every shutdown instruction has the same
content (`transportsender-impl.h:248-257`). mosh has no input window.

What differs: the window is a Swift addition, and it is the only thing that can change the
target during a shutdown. If more than `unacknowledgedInputLimit` (262,144) events are pending
when the shutdown starts, the shutdown state is first sent with the capped input; an ack for an
earlier state then moves the front, the cap moves, and the next shutdown instruction would
carry more input under the same number. The Outbox (rightly) refuses, and the core halts.

Reproduced with `limit: 4` (`ReviewITests.testShutdownWithInputBeyondTheWindow`): type 10
bytes, state 3 (4 bytes) sent, `startShutdown`, one shutdown send, deliver `ack: 3`, tick:
`.internalError(.stateContentChanged(number: 18446744073709551615))`, halted.

Consequence: a paste above 256 KiB followed by a disconnect ends as `.halted` instead of a
shutdown outcome; if the shutdown datagrams sent so far were lost the server keeps running.
Nothing unsafe reaches the wire.

Failing test: as reproduced; assert `!isHalted` and that the run ends with
`.shutdownAcknowledged` or `.shutdownTimedOut`. Fix direction: freeze the target when the
shutdown starts (what mosh's assert amounts to).

## I-3 (minor): shutdown and quiesce do not combine; some shutdown calls have no outcome

Swift: `Sources/MoshTransport/TransportCore.swift:298-303` (`startShutdown` does not look at
`isQuiesced` and returns silently when `serverShutdownSeen`, `hasEnded` or `isHalted`),
`:322-327` and `:394-395` (no timeout check and no wake-up while quiesced), `:679-686`
(the 10 s are counted from `shutdownStart`, quiesced time included),
`Sources/MoshTransport/MoshConnection.swift:222-226` (`shutdown()` has no quiesced guard; its
doc promises "The outcome arrives as `.shutdownAcknowledged` or `.shutdownTimedOut`").

mosh: `src/frontend/stmclient.cc:339-341`
`if ( net.has_remote_addr() && (!net.shutdown_in_progress()) ) { ... net.start_shutdown();`
(a shutdown starts only when the client can send), and `transportsender-impl.h:386-391`
`if ( shutdown_tries >= SHUTDOWN_RETRIES ) { return true; } else if ( timestamp() - shutdown_start >= uint64_t( ACTIVE_RETRY_TIMEOUT ) ) { return true; }`
where the 10 s are 10 s of trying.

What differs and consequence (reproduced in `ReviewITests.testShutdownWhileQuiesced`,
`testShutdownThenQuiesce`):
- `shutdown()` while quiesced: nothing is sent, `nextWakeup` is nil, no event, for as long as
  the session stays quiesced (60 s checked). After `unquiesce` more than 10 s later the first
  tick reports `.shutdownTimedOut` with zero shutdown datagrams sent.
- `shutdown()` and then `quiesce()` (the user taps Disconnect and leaves the app;
  `sceneWillResignActive` quiesces): the same after a return more than 10 s later. The server
  was never (or hardly) told and keeps running, while the app has a "finished" shutdown;
  `exportState()` throws `.sessionEnded` in between, so there is no snapshot either.
- `shutdown()` after `.serverShutdown`, or on a halted or ended core: returns silently; a
  caller that waits for `.shutdownFinished` waits forever (moshcli's `shutdown()` loop,
  `Sources/moshcli/ScriptedSession.swift:414-424`, has no exit for it).

Failing tests: (a) `quiesce(); startShutdown(now)`; advance 60 s; `unquiesce`; tick until no
wake-up: expect 16 shutdown instructions (or an ack), not zero. (b) `startShutdown`; tick;
`quiesce`; +11 s; `unquiesce`; tick: expect a shutdown datagram, not an immediate
`.shutdownTimedOut`. (c) deliver a server shutdown, then `MoshConnection.shutdown()`: expect an
event or a documented return value.

## I-4 (minor): probe acks repeat at RTO + 100 ms, up to 68 in 10 s

Swift: `Sources/MoshTransport/TransportCore.swift:547-552`
(`if probing, activeRetry { nextAckTime = now + rtt.timeout + TransportConstants.ackDelay }`),
entered from `:278-288` (`socketReplaced(probe: true)`), `:313-317` (`unquiesce`), `:200-201`
(restore).

mosh: `src/network/transportsender-impl.h:223` `next_ack_time = now + ACK_INTERVAL;` (3000 ms,
always).

What differs: deliberate (docs/notes/wave1-core.md, "Probing"), and described there and in
docs/PLAN.md section 3 as "about every second". That holds only with a fresh estimator (after a
restore). After `unquiesce` or `replaceSocket()` the estimator keeps the session's RTT, so on a
link with SRTT 10 ms the interval is 150 ms.

Measured (`ReviewITests.testProbeCount`): 68 empty acks in the 10 s after `unquiesce` with no
answer; each is a new state number (state 70 reached) and a new entry in the sent-states list,
which fills to 32 and is thinned from then on. mosh would have sent 4.

Consequence: 6 to 7 datagrams per second into a dead path on every return to the foreground
without network, 68 state numbers used per attempt (a 1,024 block of the file-backed gate, one
`F_FULLFSYNC`, lasts 15 such attempts), and the sent-states list is cycled through thinning,
which the mosh design reserves for long one-way outages. No protocol error. A floor of about
1 s on the probe interval would match the plan.

Failing test: as measured; assert at most about 12 instructions in the 10 s and an interval of
at least 1000 ms between probes.

## I-5 (minor): replay window for old server datagrams after a restore

Swift: `Sources/MoshTransport/TransportCore.swift:86` (`expectedReceiverSeq` starts at 0),
`:158-210` (the restoring initializer does not set it), `:252-267` (an "in order" datagram
gives an RTT sample, the timestamp to echo, `lastHeard`, `probing = false`);
`Sources/MoshTransport/TransportTypes.swift:187-198` (the snapshot has no field for it).

mosh: `src/network/network.cc:515-519`
`if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */ return p.payload; } expected_receiver_seq = p.seq + 1; /* this is security-sensitive because a replay attack could otherwise screw up the timestamp and targeting */`
(one counter for the life of the key).

What differs: after a cold resume the counter is 0 again under the same key, so any server
datagram recorded earlier in the session is accepted as in order. Its instruction is harmless
(known `new_num` or unknown base), but it (1) gives an RTT sample from an unrelated
`timestamp_reply` (accepted when under 5000 ms), which can push the RTO to its 1000 ms cap and
the send interval to 250 ms; (2) makes the client echo an old server timestamp, which distorts
the server's own RTT the same way; (3) clears `probing` and returns `.authentic`, so the fast
retries after the resume stop, `MoshConnection` closes the previous socket and the "last
contact" time is refreshed without any contact. Effects are bounded by mosh's clamps; no nonce,
state number or fragment id is involved. Not reproduced by a test.

Failing test: record a server datagram (seq 5) before `quiesce` / `exportState`; restore;
feed that datagram: expect `.authenticOutOfOrder`, `rtt.hasSample == false`, and the next
client datagram's `timestampReply == Timestamp16.none`. Needs the highest server sequence
number in the snapshot (touches review angles on the receiver and on resume as well).

---

## Checked for the hard failures (no finding)

- N1: every datagram's sequence number comes from `gate.takeSequenceNumber()` in
  `Outbox.send` (`Outbox.swift:231-247`), one per fragment, checked increasing and below the
  reserved limit; `gate.willSendDatagram()` runs before the datagram is built. The only other
  `encrypted(with:)` in `Sources` is `moshcli/Handshake.swift:276` (a test tool with its own
  `--first-seq`).
- N2: new numbers only from `outbox.takeStateNumber()`; a retransmission reuses the number only
  when `target == back.end`; a failed send is rolled back and the retry takes a new number.
  States are `(num, end)` over one append-only log, and the Outbox refuses a new state shorter
  than the newest. Checked against a model of `UserStream::subtract` / `diff_from`
  (`statesync/user.cc:51-58, 65-70`) in the fuzz test, restores included.
- N3: `throwaway_num` is `sentStates[0].num`, the base is `sentStates[assumedIndex]`; after
  `calculateTimers` the assumed state is the front or the newest state (timestamps in the list
  never decrease), so the thinned entry (index count - 16) is never the base.
- N4: a fresh fragment id from the gate for every instruction, retransmissions included.
- Send without the gate: none found in `MoshTransport`.
