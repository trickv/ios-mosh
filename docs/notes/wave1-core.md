# NOTES (wt/core, milestones M1 "Crypto and wire" and M2 part 1 "MoshTransport")

Working notes for whoever continues this branch. The integrator removes this file when merging.

## State

M1 is done (core-1). M2 part 1, module MoshTransport, is done (core-2a). Everything is committed;
`scripts/dev.sh swift test -j 4` is green for the whole package (227 tests, none skipped; it
takes about 65 s of test time, 42 s of which is one resume test that waits out the server's
association timeout).
core-2b (M2 part 2) is described under "core-2b (M2 part 2)" below.

- MoshCrypto: `AESBlock`, `OCB3`, `MoshCipher`, `Base64Key`.
- MoshWire: `ProtoLite` (`ProtoReader`, `ProtoWriter`), `Instruction`, `UserMessage`,
  `HostMessage`, `Compressor`, `Fragment`, `Fragmenter`, `FragmentAssembly`, `Packet`,
  `Timestamp16`, `WireConstants`.
- MoshTransport (Sources/MoshTransport, one type per file):
  - `TransportCore<Remote>` (TransportCore.swift): the pure state machine. Port of
    `Connection` (client side), `TransportSender<UserStream>` and `Transport::recv`.
  - `RemoteState` protocol and `OpaqueRemoteState` (RemoteState.swift).
  - `UserEvent`, `TerminalSize`, internal `InputLog` (UserInput.swift).
  - `RTTEstimator` (RTTEstimator.swift).
  - `DurabilityGate`, `GateCounters`, `InMemoryGate` (DurabilityGate.swift).
  - internal `Outbox`, public `InvariantViolation` (Outbox.swift): the one send point, N1 to N4.
  - `TransportConfiguration`, `TransportEvent`, `TransportOutput`, `ReceiveResult`,
    `ContactTimes`, `TransportSnapshot`, `SnapshotError`, `TransportConstants`, `AddressFamily`
    (TransportTypes.swift).
  - `DatagramTransport`, `DatagramTransportEvent` (DatagramTransport.swift),
    `POSIXDatagramTransport` (POSIXDatagramTransport.swift).
  - `MoshConnection<Remote>` actor, `ConnectionEvent`, `ContactAges`, `MonotonicClock`,
    `SystemMonotonicClock` (MoshConnection.swift).
- Tests/MoshTestSupport: `MoshServerProcess` (MoshServer.swift), `UDPTestSocket`.
- Tests/MoshTransportTests: `TestPeer.swift` (a scripted fake server and a fake-clock harness),
  then one file per exit test.
- moshcli: `handshake` subcommand (Sources/moshcli/Handshake.swift, one line in main.swift).

## core-2b (M2 part 2): moshcli connect, soak, netem, in-memory resume

Written in round 4. See "Checks" for what was run.

- `Sources/moshcli/`: `Connect.swift` (`moshcli connect`), `Soak.swift` (`moshcli soak`),
  `ScriptCommand.swift` (the script language and its parser), `ScriptedSession.swift` (one
  session driven step by step; both commands use it), `WireTap.swift` (datagram counts,
  `--seq-log`, withheld datagrams), `Recorder.swift` (`--record`), `SessionOptions.swift`.
- `scripts/itest.sh` (`handshake`, `hello`, `script`, `rebind`, `resume-mem`, `all`): a plain case
  statement that runs `scripts/itest-mosh.sh <tests>` in one `scripts/dev.sh` call. wt/boot has
  an itest.sh with the same first lines and a `bootstrap` case: keep both sets of cases.
- `scripts/netem.sh [minutes] [soak options]`, `scripts/check-seq-log.sh FILE`.
- `Tests/MoshTransportTests/ResumeIntegrationTests.swift` (real server),
  `SendPendingNowTests.swift` (fake clock).
- MoshTransport additions: `TransportCore.sendPendingNow(now:)`, `TransportCore.retransmissions`,
  `MoshConnection.quiesceAfterSend()`, `unacknowledgedInputCount()`, `retransmissions()`,
  `acknowledgedStateNumber()`.

Decisions:

- **`expect` and the soak read host bytes, not a screen.** moshcli keeps every host-bytes string
  of every applied instruction in arrival order and searches from the end of the previous match.
  Host bytes are a display diff: a row is written whole when it was blank or scrolled in, which
  is what a shell does with a line of output. Markers must be unique. If the server ever diffs
  from a base more than a screen of scrolling old, a marker need not be contiguous; that needs a
  stall of 24 marker lines, which the soak already counts as a failure. `dump-screen` writes the
  same bytes with a header line saying they are not a screen (the terminal model is wave 2).
- **The accumulated host bytes repeat text.** When the server sends two states as diffs from the
  same base (the first was not acknowledged yet), both carry the same output, and moshcli keeps
  both. `expect` is therefore "appears at least once after the previous match", never a count.
- **Keys typed in the same instant as ctrl-c are lost on the server**: the tty discards waiting
  input when the interrupt arrives. A script puts `wait-ack` and a short `sleep` around
  `key ctrl-c` (see `test_script` in scripts/itest-mosh.sh). This is the tty, not the transport.
- **Script commands beyond the task's list**: `resume` (same object, `MoshConnection.resume()`),
  `resume-mem [--drop-first N]` (export, close and drop the connection, new
  `InMemoryGate(startingAt: old.reservedLimits)`, `MoshConnection(restoring:)`, new socket; the
  first N datagrams of the new connection are logged but not sent), `wait-ack [TIMEOUT_MS]`
  (default 30 s, exit 1 when it runs out), escape `\s` for a space.
- **Exit codes**: 0, 1 (expect, wait-ack, settle or shutdown ran out of time), 2 usage,
  3 `.baseStateLost`, 4 `.serverShutdown` (every wait ends early with it; the client first gives
  its acknowledgment up to 3 s to leave, so the server exits at once), 5 the transport halted
  (`.internalError`) or export/import failed. 2 and 5 are not in the plan.
- **`--seq-log` appends** and never truncates (M6 runs several process generations into one
  file). A datagram withheld by `--drop-first` is logged too: its number is used up.
- **`quiesce --after-send`** is `core.sendPendingNow` followed by `quiesce()` inside one actor
  method. It sends the whole unacknowledged input from the acknowledged state (not from the
  assumed state), also when a state was sent a moment ago and nothing new was typed.
- **`key up` and friends send `ESC [ A`** (normal cursor mode); without the terminal model
  moshcli cannot know that an application asked for `ESC O A`.
- **netem**: the qdisc on `lo` applies to each direction, so a ping sees about 36% loss and,
  because a reordered packet is not delayed, about 300 ms. `netem.sh` accepts 10 to 70% loss and
  at least 150 ms average from 50 pings.
- The 42 s test (`testResumeAfterTheServersAssociationTimeout`) is not skipped or gated: the
  whole suite takes that much longer.

Facts confirmed in the mosh source:

- `SERVER_ASSOCIATION_TIMEOUT` = 40000 ms (network.h:139). In `Connection::send` (network.cc:419)
  a server that has not heard from the client for that long sets `has_remote_addr = false` and
  stops sending; the next authentic datagram from the client attaches it again (network.cc:555).
- Why a resume delivers input exactly once: the resumed client sends state N' (above every
  number used before) as a diff from `A`. If the server already has a state with that input,
  `UserStream::diff_from` between the two is empty (the new state is not longer), so nothing is
  written to the pty twice.

## Checks

M1 (last run in round 3 at e836c78, and again as part of the whole suite at the end of M2):
exit tests a to e by filter (`OCB3Tests|OCB3LongTextTests`, `Base64KeyTests|MoshCipherTests`,
`ProtocVectorTests`, `FragmentTests|CompressorTests`, `HandshakeIntegrationTests`); f by hand
(`moshcli handshake` against `mosh-server new -i 127.0.0.1 -p 60101`, exit 0).

M2 part 1, each `scripts/dev.sh swift test -j 4 --filter <name>`:

| Exit test | Filter | Tests |
|---|---|---|
| RTT and RTO | `RTTEstimatorTests` | 9 |
| Send timing | `SendTimingTests` | 15 |
| Diff content, sent_states cap | `DiffContentTests` | 11 |
| Receiver | `ReceiverTests` | 20 |
| Gate, N1 to N4 guards | `GateTests` | 24 |
| Resume seams | `ResumeSeamTests` | 14 |
| Real mosh-server (hello-42 and more) | `ConnectionIntegrationTests` | 7 |

M2 part 2 (round 4; the transport last changed in 04bd7bc, all of these ran after it):

| Exit test | Command | Result |
|---|---|---|
| itest | `scripts/itest.sh all` | PASS handshake, hello, script, rebind, resume-mem |
| Soak, 10 min | `scripts/netem.sh 10` | ok; 601 s; 238 of 238 markers; p50 451 ms, max 2020 ms; 1205 datagrams sent, 634 received; 572 retransmits; no socket replacement; ping before the run: 44% loss, 376 ms average; sequence log 1205 numbers strictly increasing; mosh-server alive |
| Soak with rebinds | `scripts/netem.sh 3 --rebind-every 20` | ok; 72 of 72 markers; p50 462 ms, max 1350 ms; 345 datagrams sent, 172 received; 144 retransmits; 8 socket replacements; sequence log strictly increasing |
| Resume variants (XCTest) | `scripts/dev.sh swift test -j 4 --filter ResumeIntegrationTests` | 7 tests, 0 failures |
| Resume variants (moshcli) | `scripts/itest.sh resume-mem` | PASS (basic, drop-first, after-send, exactly-once with cat, twenty in a row, after 42 s) |
| sendPendingNow, retransmit counter | `scripts/dev.sh swift test -j 4 --filter SendPendingNowTests` | 6 tests, 0 failures |
| Whole suite | `scripts/dev.sh swift test -j 4` | 227 tests, 0 failures |

Also run by hand, twice: `rebind` and the moshcli resume variants under
`tc netem loss 20% delay 20ms 10ms` (build first, then the qdisc, then
`ITEST_SKIP_BUILD=1 scripts/itest-mosh.sh rebind resume-mem` as the ubuntu user). All passed,
the byte-for-byte file comparison included.

No transport bug was found in round 4: every resume variant passed on its first run. One thing
looked like a bug and is not: under netem the soak shows about two retransmissions per marker,
190 ms apart (the send interval, SRTT / 2), not one per lost datagram at the retransmission
timeout. A trace showed why. After an exchange the client's last datagram is an empty ack,
which is a state of its own, and the server acknowledges it only with its next datagram (up to
3 s later, `ACK_INTERVAL`). While that old unacknowledged state sits in the list,
`update_assumed_receiver_state` stops at it and never reaches the state just sent, so
`calculate_timers` takes the "assumed receiver state differs" branch and repeats the new state
every send interval until an ack arrives. transportsender-impl.h lines 101 to 119 and 270 to 292
do exactly this; the port is the same, so mosh's own client has this behaviour too. Left as it
is.

Also run once by hand: the real-server tests under `tc netem loss 25% delay 40ms 20ms reorder 20%`
on `lo`, three times; all five mosh-server tests passed each time (the raw UDP echo test of the
POSIX transport fails there, as it must: it has no retransmission).

## MoshTransport: decisions

- **States are indices into one input log.** mosh copies the whole `UserStream` into every sent
  state. All copies are prefixes of one append-only stream, so a state here is `(num, end)` with
  `end` the number of input events it contains. `==` is equal ends, `diff_from` is a slice,
  `subtract` (rationalise) drops the acknowledged prefix. The snapshot hazard in the plan (new `A`
  paired with input counted from the old front) cannot occur: pending input is always
  `log[front.end...]`. `exportState()` needs no explicit rationalise step.
- **Outbox is the single send point.** The sender hands it `(old_num, old_end, new_num, new_end,
  ack_num, throwaway_num)`; the Outbox builds the diff from the log itself, takes the fragment id
  and one sequence number per datagram from the gate, and keeps its own list of what the server
  may hold (`known`). So a state number and its content cannot drift apart, and the checks do
  not rely on what the sender believes. A violation throws; the core drops every datagram of that
  instruction, reports `.internalError`, and never sends again (`isHalted`).
- **A fresh fragment id for every instruction**, retransmissions included (mosh reuses the id
  only when the instruction is byte-identical, chaff included). N4 is then "ids strictly
  increase".
- **A failed send is undone.** If the gate throws (not a violation), the state that was about to
  be sent is taken out of the list again, `.gateFailed` is reported and the send is retried after
  1 s. For that reason the thinning of the sent-state list happens after the send, not before as
  in mosh; the datagrams are the same.
- **Server shutdown** (`new_num` = 2^64 - 1) is kept out of the state list: `ack_num` becomes
  2^64 - 1, `.serverShutdown` is reported, the final state is in `finalRemoteState`. One ack per
  shutdown instruction received (the server repeats it if the ack is lost), then silence. It is
  acknowledged even if its base state is not held (mosh would ignore it and let the server time
  out after 10 s).
- **baseStateLost** is reported when `old_num == throwaway_num`, the state is not held, and
  `throwaway_num` is not below the highest `throwaway_num` acted on. The last condition is not in
  the plan: without it a delayed old datagram whose base has been thrown away since would look
  like a lost base (test `testALateInstructionOnADroppedBaseIsNotALostBase`).
- **Import rebuilds the sender as `[{A, no input}]` with an old timestamp**, and the pending
  input as the current state. The first tick then creates state `nextNum` and sends exactly the
  plan's first datagram. The plan lists two entries (`A` and `nextNum`); creating the second at
  the first tick gives the same bytes and does not need a gate call in the initializer.
- **Probing** (not in mosh): after an import, `unquiesce` or `socketReplaced(probe: true)`, and
  until an in-order authentic datagram arrives, empty acks repeat at RTO + 100 ms (about 1.1 s
  with a fresh estimator) while less than 10 s have passed, instead of every 3 s. Without it the
  "nothing pending" shape would retry a lost first datagram only after 3 s. The periodic port hop
  (`probe: false`) keeps mosh's timing. "About every second" is true only for a fresh estimator
  (a new session, an import). After `unquiesce` or a socket replacement in a session with
  measured round trips the interval is the measured RTO + 100 ms, down to 150 ms: up to 68 empty
  acks (and state numbers) in the 10 s when the server stays silent. That is the rate mosh uses
  for pending data (transportsender-impl.h:114-116) and was left as it is (transport review,
  finding M4: wording only).
- **Input window** (not in mosh): at most `unacknowledgedInputLimit` (262,144) input events
  beyond the acknowledged state are put into states; the rest waits for an ack. That keeps every
  diff below the 4 MiB an mosh peer can expand. `TerminalSize` is two `UInt16` for the same
  reason (a resize is at most 12 bytes).
- **No ECN.** `receive(datagram:now:congestionExperienced:)` has the parameter and applies
  mosh's 500 ms penalty, but `POSIXDatagramTransport` does not read the TOS byte.
- **Out-of-order datagrams**: as in mosh, a datagram numbered below one already seen is fully
  processed (fragment, ack, state), but gives no RTT sample, no timestamp to echo and no "last
  heard". `receive` returns `.authenticOutOfOrder` for it; `MoshConnection` drops the old socket
  only on `.authentic`.
- **mosh's `last_heard = 0`**: the sender's "heard in the last 10 s" test is false until the
  first server state arrives, so an unanswered first datagram is repeated every 3 s (mosh on a
  machine that has been up for more than 10 s behaves the same).
- `MoshConnection` keeps one old socket (mosh keeps up to ten for 60 s). Its event stream is
  unbounded so that a shutdown or lost-base event cannot be pushed out; the owner must read it.

## For core-2b (moshcli connect, bad-network tests)

- Drive a session with `MoshConnection<OpaqueRemoteState>`: `init(key:gate:configuration:
  initialSize:clock:makeTransport:)`, `start()`, `type(_:)`, `resize(_:)`, `events`,
  `newestRemoteState()`, `replaceSocket()` (rebind), `quiesce()`, `exportState()`, `resume()`,
  `shutdown()`, `close()`. `Tests/MoshTransportTests/ConnectionIntegrationTests.swift` shows all
  of them against a real server, including export and import into a new object with
  `InMemoryGate(startingAt: old.reservedLimits)`.
- `--record`: set `configuration.reportsInstructions = true`; every applied server instruction
  then arrives as `.transport(.instructionApplied(AppliedInstruction(oldNum, newNum, diff)))`,
  in arrival order, once per `new_num`.
- `--seq-log`: wrap the `DatagramTransport` that `makeTransport` returns in a decorator; the
  first 8 bytes of every datagram passed to `send` are the big-endian sequence number (top bit 0
  for client to server).
- **Build before `tc netem` on `lo`.** With loss on the loopback device `swift build` hangs in
  SwiftTerm's build tool (`SwiftTermBuildInfoGenerator-tool`), for more than ten minutes. Run
  `swift build --build-tests` first, then add the qdisc, then `swift test --skip-build`.
- `swift test` prints whole arrays on a failed `XCTAssertEqual`: do not compare datagrams with it.

## For M6 (file-backed gate, resume)

- Implement `DurabilityGate`. The transport calls `take…` and `willSendDatagram()` from the
  connection's actor. The snapshot writer does not read `datagramsPassed` itself (changed after
  the transport review, finding M8): `quiesce()`, then `exportState()`, which returns the
  snapshot and a `CleanToken` taken in the same actor call; write the snapshot; then
  `gate.markClean(token)`.
- `TransportSnapshot` is plain data with public fields: `acknowledgedStateNumber`,
  `pendingInput`, `remoteStates`, `highestAckSent`, `terminalSize`, and since the review
  `usedCounters` and `receiverExpectedSequence` (docs/notes/wave2-session.md, "Snapshot changes
  after the transport review"). `init(restoring:)` refuses a snapshot whose remote states are
  empty or unordered, or that lacks the state numbered `highestAckSent`, and a gate whose
  reserved limits are below `usedCounters`.
- The transport cannot tell a stale snapshot from a fresh one. If datagrams were sent after the
  snapshot, a resumed state can be shorter than one the server already has (N2). Only the dirty
  rule prevents that.
- A gate error is retried every second and reported as `.gateFailed`; an invariant violation is
  final.

## How the pieces fit (what the transport will call)

Sending one instruction:

    let instruction = Instruction(oldNum:, newNum:, ackNum:, throwawayNum:, diff:, chaff: Instruction.makeChaff())
    let budget = WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU)   // 1214
    for fragment in try Fragmenter.makeFragments(instruction: instruction, id: id, contentsBudget: budget) {
        let packet = Packet(seq: seq, direction: .toServer, timestamp: Timestamp16.now(milliseconds: now),
                            timestampReply: reply, payload: fragment.serialized())
        send(try packet.encrypted(with: cipher))       // seq: a new one for every datagram
    }

Receiving:

    let packet = try Packet(decrypting: datagram, with: cipher)     // throws on anything not authentic
    guard packet.direction == .toClient else { drop }
    if try assembly.add(try Fragment(serialized: packet.payload)) {
        let instruction = try assembly.takeInstruction()
        let message = try HostMessage(serialized: instruction.diff)  // an empty diff is an empty message
    }

`Tests/MoshWireTests/HandshakeIntegrationTests.swift` is this, against a real server.

## Decisions

- RFC 7253 appendix A vectors were copied from the RFC text (rfc-editor.org), not from memory.
  mosh's ocb-aes.cc uses the vectors and the iterative test of draft-krovetz-ocb-03, which differ
  from the final RFC (other nonces, another iterative algorithm; the cipher is the same for
  128-bit tags). Both sets are tested.
- Tests/MoshCryptoTests/MoshOCBVectors.swift was generated by a throwaway script from
  src/tests/ocb-aes.cc (21 vectors). Not hand-typed.
- OCB3LongTextTests: known answers for texts up to 70001 bytes from OpenSSL 3.0.13 in the dev
  container (a one-off C program on `EVP_aes_128_ocb`). The RFC and mosh vectors stop at 512
  bytes; a full datagram is longer and uses one more value of the offset table.
- base64 vectors: mosh generates base64_vector.cc at build time with genbase64.pl; the 8 rows in
  Base64KeyTests are that script's output in the dev container.
- protoc vectors in Tests/MoshWireTests/ProtocVectorTests.swift: made once in the container with
  `protoc --encode` from /opt/mosh-src/src/protobufs (libprotoc 3.21.12); the text-format message
  is in the comment above each test. zlib vectors: Python's zlib.compress in the container.
- MoshCipher has no sequence counter. The caller passes the sequence number of every datagram and
  must never repeat one per direction and key (N1 in the plan). `encrypt` throws for a number
  above 63 bits; mosh would mask it.
- AESBlock on Linux goes through CryptoExtras' `AES.permute`, which runs the key schedule for
  every block. That is slow but only the Linux tests use it. The Apple branch (CommonCrypto) has
  never been compiled; it is short and written to the documented `CCCrypt` signature.
- Instruction.serialized() always writes all seven fields (mosh's sender sets all seven; proto2
  writes a set field even when it is 0 or empty). Decoding fills missing fields with defaults.
- HostMessage / UserMessage instructions are enums. Decoding follows the order of preference in
  mosh's apply_string (hostbytes, then resize, then echoack; keystroke, then resize) and drops an
  instruction with no known extension, as mosh ignores it.
- Fragmenter has no state: the caller supplies the instruction id (the transport will take ids
  from the durability gate; N4 in the plan). mosh's own rule for when to take a new id is in the
  doc comment; mosh's first id is 1.
- FragmentAssembly is a literal port, including two quirks: a fragment with another id always
  restarts the assembly (lower ids too), and the id stays current after a completed instruction is
  taken, so a full retransmission completes again (the transport must discard it by new_num, as
  mosh does). Where mosh asserts, add() throws and leaves the state alone.
- Compressor.compress refuses input over 4 MiB (mosh's buffer): mosh itself would compress it if
  the result fits, but no mosh peer can expand more than 4 MiB, so the instruction would be
  retransmitted forever. The transport must keep a diff below that (large pastes).
- MoshServerProcess does not call Process.waitUntilExit(): on Linux, Foundation learns that a
  process ended when a socket inherited by the child is closed, and the detached mosh-server
  inherits and keeps that socket, so waitUntilExit() blocks until the server itself ends (60 s
  with no client). It reads stdout and stderr only up to the lines it needs. Anyone who spawns a
  daemonizing program with Foundation.Process on Linux (sshd without -D, for one) hits the same.
- MoshServerProcess.locate() looks in PATH and then in /opt/homebrew/bin, /usr/local/bin and
  /opt/local/bin, because a command run over SSH on the Mac does not have Homebrew in PATH and the
  server tests would be skipped there without notice. `MOSH_SERVER=/path` overrides.
- The tests of MoshServerProcess live in Tests/MoshWireTests (MoshTestSupport has no test target
  of its own, and adding one would have meant editing Package.swift).

## Facts learned from the real server (mosh 1.4.0)

- mosh-server starts the session command only when the first client datagram arrives, so the
  command's output is not in the server's first datagram.
- The first server datagram: sequence number 0, fragment id 1, one final fragment, old_num 0,
  new_num 1, ack_num 1, throwaway_num 0, timestamp_reply = our timestamp (plus the time held).
- If the client announces 80x24 (the server's own default), that first instruction has an empty
  diff: zero bytes, a HostMessage with no instructions. With another size it carries a Resize and
  host bytes for a full repaint. The integration test announces 100x30 for that reason.
- The second instruction is based on state 1 without waiting for our ack (the server assumes the
  first arrived), and carries `echoack 1` and the command's output.
- A datagram under a wrong key gets no answer at all.
- A server with no client exits after 60 s. Datagrams numbered below one it has already seen are
  processed but do not update the address it replies to, so `moshcli handshake` works once per
  server unless `--first-seq` is raised.

## MTU (network.h, network.cc)

- `DEFAULT_SEND_MTU` = 500 is the value in the constructor's initializer list and the fallback.
- A client's constructor calls `set_MTU(family of the server address)` before it returns, so a
  client sends with 1280 - 28 = 1252 (IPv4) or 1280 - 64 = 1216 (IPv6) from its first datagram.
- When `sendto` fails with EMSGSIZE the MTU becomes 500 and nothing raises it again for the life
  of that Connection (a port hop makes a new socket but keeps the MTU).
- Fragment contents per datagram = MTU - 12 (Connection::ADDED_BYTES) - 16 (Session::ADDED_BYTES)
  - 10 (frag_header_len): 1214, 1178, or 462. The plan appendix's numbers are right.
