# Hostile review (ii): receiver, fragments, acks, throwaway, N1-N4 guards

Scope: `Sources/MoshTransport` and the parts of `Sources/MoshWire` it uses, against mosh 1.4.0
(`.refs/mosh/src/network`). Branch `cloud-work`, working tree clean, nothing in the repo changed.

All five findings were reproduced with scratch tests. They are in
`/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/review-ii/Tests/MoshTransportTests/ReviewIITests.swift`
(a copy of the repo with a cut-down `Package.swift`: MoshCrypto, MoshWire, MoshTransport only;
run there with `swift test --filter ReviewIITests`). Each test fails today and states the wanted
behaviour, so they can be moved into `Tests/MoshTransportTests` as they are (they use `Harness`
and `FakeServer` from `TestPeer.swift`).

| id | severity | summary |
|---|---|---|
| II-1 | major | After an import the receive sequence check starts at 0: any old server datagram is taken as in-order |
| II-2 | minor | A late ordinary state after the server's shutdown takes `ack_num` back; acks then repeat every send interval and never acknowledge the shutdown |
| II-3 | major | N1, N2, N4 across import rest on an unchecked caller contract; with a wrong gate and `A` = 0, sequence 0, state 1 and fragment id 1 go out twice with different content |
| II-5 | major | A client shutdown with 100 or more bytes of unacknowledged input halts the transport on the second shutdown send (`old_num` = 2^64 - 1 trips the Outbox guard) |
| II-4 | minor | A client shutdown with more pending input than the input window halts with `stateContentChanged` when an older state is acknowledged |

---

## II-1 (major): replayed server datagrams are "in order" after an import

**Swift**
- `Sources/MoshTransport/TransportCore.swift:86` `private var expectedReceiverSeq: UInt64 = 0`
- `TransportCore.swift:252-267` (the in-order branch of `receive`)
- `TransportCore.swift:158-210` (`init(restoring:)` does not set it)
- `Sources/MoshTransport/TransportTypes.swift:187-197` (`TransportSnapshot` has no field for it),
  `TransportCore.swift:871-885` (`exportState`)

**mosh** `src/network/network.cc:515-519`

```
  if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */
    return p.payload;
  }
  expected_receiver_seq = p.seq + 1; /* this is security-sensitive because a replay attack could otherwise
					screw up the timestamp and targeting */
```

**Difference.** In mosh the counter lives as long as the key. Here it is not part of the
snapshot, so a core made by `init(restoring:)` starts at 0 under the same key. Until the first
genuine datagram arrives, every server datagram ever captured for this session passes the check.

**Consequence** (measured in the scratch test, replay of one datagram 100 ms after the import):
- `receive` returns `.authentic`; `lastHeard` is set, so `MoshConnection` reports `.contact` with
  `sinceLastAuthenticDatagram` = 0 although the server may be unreachable or gone. Anything in M6
  that takes "an authentic datagram arrived" as proof that the resume worked is fooled.
- `probing` is cleared (`TransportCore.swift:266`): the retry of the first resume datagram falls
  back from RTO + 100 ms to the 3 s ack interval.
- The stale `timestamp_reply` becomes the first RTT sample of the fresh estimator. The sample is
  the difference of two unrelated clocks; the attacker picks a captured datagram that lands below
  5000. In the test SRTT went from 10 ms to 700 ms (send interval 250 ms, RTO 1000 ms).
- The stale `timestamp` is saved and echoed to the server in the next datagram, which gives the
  server a wrong RTT sample as well (this is the "screw up the timestamp" case mosh names).
- The instruction itself is harmless (already held or base gone), as in mosh.

It ends with the first genuine in-order datagram. The attacker needs only to have recorded
traffic; no key.

**Failing test** (`testReplayAfterImportIsNotInOrder`): `connectAndSettle()`; build one server
datagram with `FakeServer.datagrams(old: 2, new: 3, ack: 2, throwaway: 1, ..., timestampReply: x)`
and deliver it (`.authentic`); deliver it again (`.authenticOutOfOrder`, as today); tick, quiesce,
export; `Harness(restoring:gate: InMemoryGate(startingAt: old.reservedLimits))`; tick; deliver
the same bytes to the new core. Expect `.authenticOutOfOrder`, `contactTimes.lastAuthenticDatagramAt
== nil`, `rtt.hasSample == false`. Today: `.authentic`, a contact time, SRTT 700.

**Fix direction.** Put `expectedReceiverSeq` into `TransportSnapshot` and restore it. (It only
needs to be a lower bound, so it does not need the gate's durability.)

---

## II-2 (minor): `ack_num` goes back from 2^64 - 1 to an ordinary number

**Swift**
- `TransportCore.swift:764-770`: every appended state does `ackNum = new.num`
- `TransportCore.swift:786-793`: `processServerShutdown` sets `ackNum = Instruction.shutdownNum`
  but keeps the shutdown state out of `receivedStates`
- `TransportCore.swift:450-451`: while `serverShutdownAckPending`, `nextAckTime = back.timestamp + rtt.sendInterval`
- `TransportCore.swift:650-656`: the pending flag is cleared only by a send whose `ackNum` is 2^64 - 1

**mosh** `src/network/networktransport-impl.h:143-160`

```
    for ( ... i = received_states.begin(); i != received_states.end(); i++ ) {
      if ( i->num > new_state.num ) {
	received_states.insert( i, new_state );
	...
	return;
      }
    }
    ...
    received_states.push_back( new_state );
    sender.set_ack_num( received_states.back().num );
```

In mosh the shutdown state (number 2^64 - 1) is in the list, so every later ordinary state is
inserted before it and returns without touching `ack_num`.

**Difference.** Here the shutdown state is not in the list. An ordinary state that arrives after
the shutdown instruction (reordering of the server's last screen update and its first shutdown
datagram) is appended and sets `ackNum` back to its own number.

**Consequence.** If that happens before our ack of the shutdown left, the next sends carry the
ordinary number, `serverShutdownAckPending` stays true, and `calculateTimers` asks for an ack
every send interval for good: in the scratch test 200 datagrams in 4 s, all with `ack_num` 3,
no `.serverShutdownAcknowledged`, plus a `.remoteStateAdvanced` after `.serverShutdown`. Each
datagram also burns a state number. It heals only if another copy of the server's shutdown
arrives (the server sends up to 16 in 10 s, then exits). `moshcli` waits for
`.serverEndAcknowledged` before closing (docs/notes/wave2-session.md:165).
If the late state arrives after our ack left, only the stored `ackNum` is wrong (nothing is sent).

**Failing test** (`testLateStateAfterServerShutdownKeepsTheShutdownAck`): `connectAndSettle()`;
build (do not deliver) `datagrams(old: 2, new: 3, ack: 2, throwaway: 2, diff: "bye")`; deliver
`old: 2, new: 2^64-1`; then `core.receive` the held datagram; advance 200 times by 20 ms.
Expect `acknowledgmentNumber == Instruction.shutdownNum`, `.serverShutdownAcknowledged` in the
events and fewer than 5 datagrams. Today: 3, no event, 200 datagrams.

**Fix direction.** Once `serverShutdownSeen`, an appended state must not change `ackNum` (and
arguably should not report `.remoteStateAdvanced`).

---

## II-3 (major): N1, N2 and N4 across import are a caller contract, not a construction

**Swift**
- `TransportCore.swift:158-210`: `init(restoring:)` takes any gate; the only checks are on the
  snapshot's remote states
- `Sources/MoshTransport/Outbox.swift:86-90, 103-108`: a new `Outbox` has `lastSequence`,
  `lastFragmentID`, `lastIssuedStateNumber` = nil, so its first numbers are accepted whatever
  they are (`Outbox.swift:204, 239`); the state number check has only `known.last` = `A` to
  compare with (`Outbox.swift:119-122`)
- `TransportTypes.swift:187-197`: the snapshot carries no counters and no link to the gate
- `Sources/MoshSession/MoshSession.swift:110-112` says it outright: "this type does not check either"

**mosh** has no resume; the rule comes from `docs/PLAN.md:357-360` (N1 "A datagram sequence
number is used twice under one key", N2, N4) and CLAUDE.md ("must stay impossible by
construction"). The mosh side of N1 is `src/network/network.h:86`
`: seq( Crypto::unique() ), direction( s_direction ),`, one counter for the life of the key.

**Difference.** Inside one process the Outbox makes N1-N4 impossible. Across export/import
nothing in MoshTransport ties a snapshot to the gate it is used with:

1. *Wrong gate.* With `A` > 0 a gate that starts too low is caught by luck: its first state
   number is not above `A`, the core halts before a datagram is built. With `A` = 0 (a snapshot
   taken before the first reply, the shape of `testExportBeforeTheFirstReply`) nothing catches
   it. Scratch test output: first process sent `seq [0], new_num 1, fragment id 1` (Resize
   80x24); the restored one sent `seq [0], new_num 1, fragment id 1` with other content (Resize
   80x24 + Resize 100x30). That is OCB nonce reuse with two plaintexts, and N2 and N4 in the same
   datagram. Sequence numbers and fragment ids are never checked against anything on import,
   whatever `A` is: a gate with the right state counter and a stale sequence counter (a bug in
   the M6 two-slot file) reuses nonces silently.
2. *Stale snapshot.* `init(restoring:)` does not look at the gate's dirty flag, and
   `unquiesce()` after `exportState()` does not invalidate the value. A snapshot older than the
   last send, imported with a correct gate, gives a new highest state that is shorter than one
   the server holds: N2, `src/statesync/user.cc:68-69`
   ```
       assert( my_it != actions.end() );
       assert( *i == *my_it );
   ```
   in `UserStream::diff_from`, and the remote shell dies.

Today's callers (`moshcli resume-mem`, tests) pass the right gate, so this is not a live bug; it
is the place where an M6 mistake turns into a hard failure without any guard firing.

**Failing test** (`testImportWithAGateBelowTheOldNumbersIsRefused`): `Harness()`; one `tick()`
(sequence 0 leaves); quiesce; export; `Harness(restoring: snapshot, gate: InMemoryGate(),
currentSize: 100x30)`; expect the initializer to throw, or the first tick to send nothing and
report `.internalError`. Today it sends sequence 0 again.

**Fix direction.** Export the Outbox's floors with the snapshot (`lastSequence + 1`,
`lastIssuedStateNumber + 1` or `A + 1`, `lastFragmentID + 1`) and make `init(restoring:)` throw
unless `gate.reservedLimits` is at or above each of them; seed the new Outbox's `last…` values
from them so the per-send checks cover the first datagram too. For the stale case, give the
snapshot the gate's `datagramsPassed` at export and let the gate (not the caller) confirm it on
import.

---

## II-5 (major): client shutdown with >= 100 bytes unacknowledged halts the transport

**Swift**
- `TransportCore.swift:525-535`: `sendEmptyAck` in a shutdown re-sends number 2^64 - 1
- `TransportCore.swift:614-622`: `oldNum: assumed.num` (the assumed state is now the shutdown state)
- `TransportCore.swift:506-522`: the prospective resend moves the base back to the front only if
  the diff from the front is under 100 bytes longer
- `Outbox.swift:154-156`: `guard request.oldNum != Instruction.shutdownNum ... else { throw .violation(.reservedStateNumber) }`
- `TransportCore.swift:378-380`: a violation sets `isHalted`; `checkShutdownTimeout` is skipped
  once halted (`TransportCore.swift:325-327, 390-392`)

**mosh** `src/network/transportsender-impl.h:212-221` and `:325`

```
  uint64_t new_num = sent_states.back().num + 1;

  /* special case for shutdown sequence */
  if ( shutdown_in_progress ) {
    new_num = uint64_t( -1 );
  }
  ...
  add_sent_state( now, new_num, current_state );
  send_in_fragments( "", new_num );
```
```
  inst.set_old_num( assumed_receiver_state->num );
```

mosh repeats the shutdown as `old_num` = `new_num` = 2^64 - 1 with an empty diff, 16 times, then
gives up (`shutdown_ack_timed_out`).

**Difference.** The port follows mosh up to the instruction and then refuses it in the Outbox.
With little pending input the prospective-resend rule happens to move the base to the front, so
the existing tests pass. With 100 bytes or more of unacknowledged input it does not.

**Consequence** (scratch test: 150 typed bytes never acknowledged, shutdown 30 s later): exactly
one shutdown datagram leaves (`old_num` 3, an unacknowledged state the server may not hold, empty
diff), the second attempt throws, the core reports `.internalError(.reservedStateNumber)` and
halts. No retry, no `.shutdownAcknowledged`, no `.shutdownTimedOut`; MoshSession reports
`.halted`. If that one datagram is lost or its base is not held, `mosh-server` and the shell
stay alive. The trigger is ordinary: type or paste a long line while the link is down, then
close the session. With 3 bytes pending the same test sends 16 shutdowns and times out cleanly.

**Failing test** (`testShutdownWithALotOfUnacknowledgedInput`): `connectAndSettle()`; type 150
bytes; `advanceToWakeup()`; advance 30 x 1000 ms with no server reply; `startShutdown`; tick,
then advance 600 x 20 ms. Expect `isHalted == false`, 16 shutdown instructions, each with a base
below 2^64 - 1, and `.shutdownTimedOut`. Today: 1 instruction, halted.

**Fix direction.** In a shutdown, never use the shutdown state as the base: send every
shutdown instruction from the acknowledged state (`assumedIndex = 0`). That is also better than
mosh, whose repeats (`old_num` = 2^64 - 1) are useless to a server that missed the first one.

---

## II-4 (minor): shutdown with more pending input than the window halts

**Swift**
- `TransportCore.swift:417-419`: `targetEnd = min(log.end, sentStates[0].end + limit)` grows when
  an ack moves the front
- `TransportCore.swift:529-535` and `:562-574`: the shutdown state is re-sent with the new `target`
- `Outbox.swift:167-170`: `if let shutdownEnd, shutdownEnd != request.newEnd { throw .violation(.stateContentChanged) }`

**mosh** has no input window: `transportsender-impl.h:249-257`

```
  if ( shutdown_in_progress ) {
    new_num = uint64_t( -1 );
  }

  if ( new_num == sent_states.back().num ) {
    sent_states.back().timestamp = timestamp();
  } else {
    add_sent_state( timestamp(), new_num, current_state );
  }
```
The shutdown state is always the whole `current_state`.

**Difference and consequence.** If more than `unacknowledgedInputLimit` (262,144) events are
pending when the shutdown starts, the shutdown state holds only the window. When the server then
acknowledges an older state, the window moves, the next shutdown send wants number 2^64 - 1 with
more input, the guard fires (correctly, it would be N2) and the transport halts with
`.internalError(.stateContentChanged)`. Input beyond the window is dropped without notice in
either outcome. Needs a very large paste followed at once by a close; rare.

**Failing test** (`testShutdownWithInputBeyondTheWindow`): `Harness(configuration:
Harness.configuration(limit: 2))`; `connectAndSettle()`; type "abcdef"; `advanceToWakeup()`
(state 3 = "ab"); `startShutdown`; advance 30 ms (shutdown state = "ab"); deliver
`old: 2, new: 3, ack: 3, throwaway: 2`; advance 20 x 30 ms. Expect `isHalted == false`. Today:
halted.

**Fix direction.** Freeze the shutdown state's end at the first shutdown send (`shutdownEnd`)
and use it as the target for every later one.

---

## Checked, no finding

- `FragmentAssembly` against `transportfragment.cc:91-149`: new id resets (lower ids too), same
  id in any order, completion on `arrived == total`, the id stays after `get_assembly`, a
  retransmission under the same id completes again and is dropped by `new_num`. The inputs that
  hit mosh's asserts (conflicting duplicate, final below fragments held, hole below the final)
  throw and are reported; no mixing of instructions is possible.
- `Transport::recv` order against `networktransport-impl.h:76-165`: version check, ack, round
  trip time, "already have", "old state missing" (ignored), throwaway before the 1024 quench,
  sorted insert without ack for out-of-order states. The same. The extra guard
  `throwaway_num <= old_num` only rejects what makes mosh erase its reference.
- Acks name only held states: `ackNum` is the newest held number; the newest state cannot be
  thrown away (`throwaway_num <= old_num`, and `old_num` is held); `highestAckSent` is held at
  export because an honest server's `throwaway_num` never exceeds an ack it received.
- Diff base after import: the server's front is an ack we sent, and every state at or above the
  last `throwaway_num` we acted on is in the snapshot.
- Direction bit, 63-bit sequence, `seq + 1`, timestamp echo once per instruction within 1000 ms,
  the 5000 ms sample limit, `timestamp16` never 0xFFFF: as `network.cc:70-115, 511-556, 601-621`.
- Send-side N1-N4 inside one process: every number comes from the gate through `Outbox`, a
  failed send is undone without reuse, `throwaway_num` is the front and the base is in the list.
- Known and documented, not repeated as findings: no ECN read in `POSIXDatagramTransport`
  (docs/notes/wave1-core.md:197); the server's shutdown is acknowledged even when its base is
  not held (wave1-core.md:175-179; in practice better than mosh, whose repeats carry
  `old_num` = 2^64 - 1).
