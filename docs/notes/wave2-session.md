# NOTES (wave 2, MoshSession: work item 2 parts a and b, cloud round 2)

Parts (a) the adapter and (b) the facade with `ClipboardPolicy` are done. Parts (c) to (e)
(moshcli with the real terminal, the tmux capture-pane soak check, the "no UDP reply in 15 s"
row) are not started; what they need is under "For parts c to e".

## Commits

- `8903c11` Let the transport take the remote state numbered 0
- `df22623` Add the adapter from remote state to terminal state
- `9d38066` Add ClipboardPolicy for OSC 52
- `eacbd69` Add the MoshSession facade

Whole suite after the last of them: `scripts/dev.sh swift test -j 4` -> "Executed 518 tests,
with 33 tests skipped and 0 failures" (484 before, minus one placeholder, plus 35). The 33
skipped are still `SSHBootstrapIntegrationTests` (run with `scripts/itest.sh bootstrap`).
`--filter MoshSessionTests` was run three times in a row: 33 tests, 0 failures each time.

## What is where

- `Sources/MoshSession/TerminalRemoteState.swift`: `TerminalRemoteState: RemoteState` wrapping
  `TerminalState`. `apply(diff:)` decodes the `HostMessage` and applies host bytes (`act`),
  resize (`resize`) and echo ack (`applyEchoAck`) in order, as `Complete::apply_string`
  (completeterminal.cc:104-122). The order of preference inside one instruction is done by
  `HostMessage(serialized:)` (wave 1).
- `Sources/MoshSession/ClipboardPolicy.swift`: decision logic only.
- `Sources/MoshSession/SessionTypes.swift`: `SessionEndpoint`, `SessionError`, `ScreenUpdate`,
  `SessionEvent`, `SessionSnapshot`.
- `Sources/MoshSession/MoshSession.swift`: the facade actor.
- Tests: `Tests/MoshSessionTests/{TerminalRemoteStateTests,ClipboardPolicyTests,
  SessionEndpointTests,SessionIntegrationTests}.swift`, and
  `Tests/MoshTransportTests/InitialRemoteStateTests.swift`.
- `Package.swift`: `MoshSessionTests` now also depends on MoshTerminal, MoshTransport,
  MoshWire, MoshCrypto, MoshBootstrap (it imports them).

## Public API (short)

    let endpoint = try SessionEndpoint(bootstrap: result)          // or (host:port:key:)
    let session = try MoshSession(endpoint: endpoint, initialSize: size,
                                  serverStartSize: ptySize,         // nil = initialSize
                                  gate: gate, clipboard: ClipboardPolicy(isEnabled: hostSwitch),
                                  makeTransport: { try NWDatagramTransport(...) })   // nil = POSIX
    // also: MoshSession(bootstrap:initialSize:...), MoshSession(restoring:endpoint:gate:currentSize:)
    for await event in session.events { ... }   // SessionEvent
    await session.start()
    await session.type(bytes); await session.resize(size)
    await session.screen()            // ScreenUpdate(number, state: TerminalState, isLive)
    await session.contactAges()       // ContactAges, for the banner timer
    await session.replaceSocket(); quiesce(); quiesceAfterSend(); resume()
    try await session.exportState()   // SessionSnapshot(transport:, clipboard:)
    await session.shutdown(); await session.close()
    await session.setClipboardWriting(enabled:)

`SessionEvent`: `.screen(ScreenUpdate)`, `.contact(ContactAges)`,
`.clipboard(.write(text:byteCount:) | .invalid(reason))`, `.serverEnded(TerminalState?)`,
`.shutdownFinished(acknowledged:)`, `.baseStateLost(serverBase:)`, `.halted(String)`,
`.gateFailed(String)`, `.networkProblem(String)`, `.protocolProblem(String)`.

## Decisions

- **State 0 must have the server's starting size.** mosh-server builds its state 0 as
  `Complete( ws_col, ws_row )` of its tty, 80x24 without one (mosh-server.cc:411-423), and its
  first diff carries a resize only when the size changed (completeterminal.cc:83-88). mosh's
  client uses its own window size (stmclient.cc:254), which matches because the SSH pty had that
  size. `RemoteState` only had `init()`, so the transport could not hold a 100x30 state 0: the
  server's diff from its 100x30 blank would have been applied to an 80x24 blank. Fix: the
  transport takes `initialRemoteState` (mosh's `Transport( ..., initial_remote, ... )`,
  networktransport-impl.h:43-49), optional, default `Remote()`. This is the only transport
  change; no durability or send logic changed. The facade's `serverStartSize` defaults to
  `initialSize`: **the app must request the bootstrap pty with the same size as the view**
  (`SSHBootstrap.Request.columns/rows`), or pass the pty size. Servers started without a tty
  (`MoshServerProcess`, `scripts/mosh-spawner.py`) need `TerminalRemoteState.defaultServerSize`
  (80x24); the integration test uses a 100x30 view against such a server.
- **Where mosh asserts, follow the server.** A diff that does not parse throws (the transport
  drops it and reports `.peerProtocolError`); a non-empty terminal reply is discarded and
  counted (`discardedReplyBytes`); an echo ack that goes backwards is stored and counted
  (`echoAckRegressions`); a non-positive resize is ignored (TerminalState's existing rule).
  `==` of `TerminalRemoteState` compares the terminal only.
- **The client-side `UserStream` diff already existed** in MoshTransport (`InputLog`, `Outbox`:
  states are prefixes of one input log, `diff_from` is a slice). Nothing new was needed.
- **Screens are coalesced.** On `.remoteStateAdvanced` the facade reads the newest state and
  reports it if its number differs from the last reported one; intermediate states can be
  skipped (the surface only wants the newest). Numbers in `.screen` strictly increase.
- **`isLive`**: false only for the first screen of a restored session, reported by `start()`
  before any datagram. Its clipboard is observed against the stored policy (changed after the
  transport review, finding M10): no event when the policy had seen it, a `.clipboard` event
  when the snapshot caught a copy the policy had not seen. Everything from the network is live,
  also after an in-memory `quiesce()`/`resume()`.
- **ClipboardPolicy** compares the field with the last state it observed (a change is what
  mosh's display would send). Empty and `?` are ignored. A field of 16379 characters or more
  (the OSC cap 16384 minus `52;c;`, terminaldispatcher.cc:45,239) is `.invalid(.truncated)`; a
  real copy of exactly that length cannot be told apart and is refused too. Base64 is strict
  (length multiple of 4, padding only at the end, zero pad bits, no whitespace); UTF-8 is strict
  (round trip through `String(decoding:)` must not change the bytes). The hash is FNV-1a 64,
  stable across processes, so `lastWrittenHash` can be stored. The policy assumes a `.write`
  is performed: it records the hash when it returns `.write`.
- **The snapshot** is `SessionSnapshot { transport: TransportSnapshot<TerminalRemoteState>,
  clipboard: ClipboardPolicy }`, plain data. No byte format yet (M6). `TerminalState` already has
  `serialized()` / `init(serialized:)` and the shared-row variant for that.
- **Contact events** are passed on for every authentic datagram (as MoshConnection does). The app
  throttles; a banner timer uses `contactAges()`.
- No Foundation in `Sources/MoshSession`; the default transport is `POSIXDatagramTransport`,
  which compiles on Darwin. Nothing was compiled for iOS or macOS here.

## Known gaps

- No byte serialization of `SessionSnapshot` (M6, `MoshResume`).
- The facade does not debounce resizes (the app does, 100 ms, PLAN.md section 5) and does not
  replace the socket on foreground or path change by itself (the app calls `replaceSocket()`).
- `SurfaceFeed` is not wired here; the app keeps one per view and feeds `screen.framebuffer`.
  A screen whose size differs from the view (between a Resize and the server's answer) must not
  be fed (wave1-term.md, "For the app").
- No fallback logic: `.baseStateLost` and `.halted` are reported, the app (M6 coordinator)
  starts a new session.
- The policy has no rate limit and no size limit below mosh's cap.
- The adapter is checked against the oracle through the corpus (2916 instructions, size, cursor,
  every cell's contents and width, echo ack, clipboard; full equality with `TerminalState` driven
  by the ops, which the MoshTerminal corpus tests compare field by field). It is not run against
  the oracle binary directly.

## For parts c to e

- **(c) moshcli with the real terminal.** Replace `MoshConnection<OpaqueRemoteState>` in
  `ScriptedSession` with `MoshSession`, or with `MoshConnection<TerminalRemoteState>` if the
  script needs `--record` (`TransportConfiguration.reportsInstructions`; the facade does not
  expose `.instructionApplied`, so either use the connection directly or add a pass-through).
  `dump-screen`: `visibleText(of: screen.framebuffer)` gives the rows (trailing blanks cut).
  `expect` on screen text: poll `screen()` and match a row or a substring of the joined rows;
  the integration tests' `waitForRow` is the pattern. Pass `serverStartSize:
  TerminalRemoteState.defaultServerSize` for a server started without a tty (the `moshcli
  connect` path), and the pty size for `moshcli bootstrap` (use the same size for the pty and
  the view). Keep the host-bytes `expect` for the soak if markers scroll by quickly; the screen
  only shows the newest state.
- **(d) soak against `tmux capture-pane -p`.** Run the soak's shell inside tmux on the server
  side, settle (`unacknowledgedInputCount() == 0` and no new screen for a while), then compare
  `visibleText(of:)` row by row with `tmux capture-pane -p` (which also cuts trailing blanks).
  The view size must equal the tmux window size (the status line takes a row unless
  `status off`).
- **(e) "MOSH CONNECT seen, no UDP reply in 15 s".** The facade reports nothing special when no
  datagram ever arrives: `contactAges().sinceLastAuthenticDatagram` stays nil. The 15 s rule
  (mosh's client "timed out waiting for server", appendix) belongs in the caller (or a small
  timer in the facade emitting a new event); `MoshBootstrap.ConnectTimeoutPolicy` may already
  hold the threshold. A server that never answers: a UDP socket on 127.0.0.1 that reads and drops
  (`UDPTestSocket` in MoshTestSupport).

# NOTES (wave 2, item 2 parts c, d and e, cloud round 3)

Parts (c) moshcli with the real terminal and `moshcli bootstrap`, (d) the soak ending with the
client framebuffer equal to `tmux capture-pane -p`, and (e) the "`MOSH CONNECT` seen, no UDP
reply in 15 s" row are done. Item 2 is finished except for what needs yellow (below).

## What changed

- **MoshSession** (`Sources/MoshSession`): three new `SessionEvent` cases.
  - `.noServerReply(BootstrapError.udpBlocked(port:))`: mosh's client rule (stmclient.cc:532-538,
    `still_connecting()` in stmclient.h:81-85): the newest remote state is still the one
    numbered 0 more than 15 s after start. `MoshSession.init(... noReplyTimeout: UInt64? =
    MoshSession.defaultNoReplyTimeout (15_000))`, milliseconds, nil turns it off; on the
    bootstrap initializer too. A real-time `Task.sleep`, not the injected `MonotonicClock`: it is
    a user-facing wait, not protocol timing, and the transport's fake clocks do not drive sleeps.
    Reported once. While quiesced it does not fire; `resume()` starts the full wait again if still
    nothing arrived. Never for a restored session (its state is not 0 in practice; mosh has no
    such case). Unlike mosh the facade does not start a shutdown: nobody answers anyway, and the
    app decides (shows the table row, closes).
  - `.instructionApplied(AppliedInstruction)`: pass-through, only with
    `TransportConfiguration.reportsInstructions` (moshcli `--record` and the host-bytes `expect`).
  - `.serverEndAcknowledged`: our ack of the server's shutdown left (mosh's
    `counterparty_shutdown_ack_sent`); moshcli waits for it before closing so the server exits
    at once. The app can use it the same way.
- **moshcli** now drives `MoshSession` (the app's facade), not `MoshConnection<OpaqueRemoteState>`.
  `resume-mem` uses `MoshSession(restoring:)`. New/changed script commands: `dump-screen FILE`
  writes the rendered screen (`visibleText(of:)`, one line per row, trailing blanks cut: the form
  of `tmux capture-pane -p`); `dump-bytes FILE` keeps the old raw host-bytes dump;
  `expect-screen TEXT MS` matches a substring of a row of the newest screen. Options for
  connect, soak and bootstrap: `--server-size WxH` (state 0's size, default 80x24) and
  `--no-reply-ms MS` (default 15000, 0 off). Exit codes 6 (no reply from the server) and 7
  (bootstrap failed) are new.
- **`moshcli bootstrap`** (`Sources/moshcli/Bootstrap.swift`): `SSHBootstrap.run` with a pty of the
  view's size (`--width/--height`; `--server-size` must equal it), password from
  `MOSH_SSH_PASSWORD` only (never argv), optional device key from a `FileKeyStore`
  (`--key-store DIR --key-name NAME`), `--known-hosts FILE` (JSON, created if missing),
  `--accept-new-host-key`, `--server-path`, `--locale`, `--remote-command`, `--udp-ports`,
  `--print-server FILE` ("PID PORT"). Then the script runs on the session to
  `BootstrapResult.remoteAddress`.
- **Soak**: `moshcli soak --screen-out FILE [--settle-ms MS]` waits for the server's ack of all
  input and `MS` (default 500, the stage 1 table's value) without a new state, then writes the
  screen. `scripts/soak.sh [minutes] [soak options]` starts mosh-server running
  `tmux -L moshsoak-$$ new-session sh` with `status off`, runs the soak, then checks: the server
  is alive, the seq log increases, the pane is the view's size, the client's screen has exactly
  H rows, and it equals `tmux capture-pane -p` (padded with blank rows at the bottom, since
  capture-pane may leave those out) with at least one marker result on it. `SOAK_SIZE=WxH`
  changes the view. `scripts/netem.sh` now adds the qdisc, checks it took effect as before, and
  runs `scripts/soak.sh` with `SOAK_SETTLE_MS=3000` (mosh resends unacknowledged states at most
  MAX_RTO = 1 s apart, network.h:134; 500 ms of quiet under 36% loss is not proof that the
  newest state arrived). It fails at once, with that reason, when the qdisc cannot be added.
  `runuser -u ubuntu` became "the checkout's owner" there, as in itest-sshd.sh.
- **itest**: `scripts/itest.sh soak` (two 30 s soaks: 80x24, and 60x15 with `--rebind-every 10`,
  whose rows scroll), `bootstrap-session` (under itest-sshd.sh: password login to the `normal`
  sshd with a 100x30 pty, `expect-screen` on output and on `stty size` before and after a
  resize, clean `shutdown`, the server process gone afterwards, the host key remembered; a
  second run with a wrong password exits 7 with "Wrong password." and asks no host-key
  question), `netem-soak` (scripts/netem.sh, default 2 min). `all` runs all of them; for
  netem-soak it first probes `tc qdisc add dev lo root netem delay 1ms` in a `dev.sh --root`
  call and prints "SKIP netem-soak: ... needs yellow" when that fails. `hello` now also checks
  `expect-screen` and the rendered `dump-screen` (24 rows, the command row and `hello-42`).
  `script` gained `script-expect-screen` (text overwritten on the screen is not found by
  expect-screen, though `expect` found it in the host bytes; exit 1) and `script-no-reply` (the
  port of a killed server, `--no-reply-ms 1500`: exit 6 with the udpBlocked message).
  `start_server` in itest-mosh.sh now gives mosh-server `/dev/null` as standard input, so its
  state 0 is always 80x24 even when the itest is started from a terminal.
- **Tests**: `Tests/MoshSessionTests/NoServerReplyTests.swift` (a `MOSH CONNECT` line parsed by
  `ConnectLineParser` pointing at `UDPSink`, a new MoshTestSupport helper bound on 127.0.0.1
  that reads and counts every datagram and answers none; timeout 600 ms; also: reported once,
  quiesced time does not count, nil never reports, a real server is never reported).

## Decisions

- `expect` (host bytes) stays for the soak: markers scroll by, the screen shows the newest state
  only. Host bytes are mosh-server's display diffs, not the application's output, so text that
  was on the screen only between two frames may never appear in them.
- The soak's view is 80x24 by default so the tmux pane, the server's state 0 and the view agree;
  other sizes work through the client's resize (`SOAK_SIZE`).
- The bootstrap pty size and the view size are forced equal in moshcli (`--server-size` that
  differs is a usage error), as the notes for parts a/b require.

## Needs yellow

- **The netem soak**: `scripts/netem.sh 10` (or `scripts/itest.sh netem-soak 10`): the 10-minute
  soak under 20% loss, 200 ms ± 50 ms delay and reordering, now ending with the framebuffer vs
  `tmux capture-pane -p` check. Here `tc qdisc add ... netem` fails ("Specified qdisc kind is
  unknown"), so it never ran with the screen check. Also try `scripts/netem.sh 3 --rebind-every
  20`. If the screens differ under loss, look at the settle time first (3 s), not at the check.

## Known gaps

- `moshcli bootstrap` is tested with password login only; the `--key-store` path (FileKeyStore
  key, as in `SSHBootstrapIntegrationTests.testKeyLoginWithAFileKeyStoreKey`) has no itest.
- Arrow keys in scripts still send normal cursor-key mode; the terminal model now knows the
  application's mode but moshcli does not look.
- Nothing here was compiled for Apple platforms.

## Results (round 3)

- `scripts/dev.sh swift test -j 4`: "Executed 523 tests, with 33 tests skipped and 0 failures"
  (518 + 5 in `NoServerReplyTests`; the 33 skipped are still the sshd tests).
- `ITEST_NO_CONTAINER=1 scripts/itest.sh all`: exit 0. PASS handshake, hello, script, rebind,
  resume-mem (7 XCTests), soak, bootstrap (108 tests, 0 failures), bootstrap-session;
  "SKIP netem-soak: tc netem does not work here ...: needs yellow".
- Soak: 80x24, 13 markers, p50 16 ms, final screen equals `tmux capture-pane -p` (24 rows, 12
  marker results on it); 60x15 with 2 rebinds, 13 markers, equal (15 rows, 7 marker results).

## Snapshot changes after the transport review (round 5, for item 4)

Findings M7, M5 and M8 of `docs/notes/review-transport/refutation.md` changed what a snapshot
holds and how it is exported. Item 4 defines the byte format; these are the fields it must
carry. Nothing else in `TransportSnapshot` or `SessionSnapshot` changed.

Two new fields in `TransportSnapshot` (both required by its initializer, no defaults, so a
decoder cannot leave them out):

| Field | Type | Meaning |
|---|---|---|
| `usedCounters` | `GateCounters` (three `UInt64`: sequence, state, fragmentID) | The first datagram sequence number, client state number and fragment id not used when the snapshot was taken. A session that never sent has `(0, 1, 0)` |
| `receiverExpectedSequence` | `UInt64` | mosh's `expected_receiver_seq` (network.cc:515-519): the lowest sequence number a server datagram may have and still count as in order |

What the import does with them (`TransportCore.init(restoring:)`):

- Throws `SnapshotError.usedCountersInvalid` if `usedCounters.state` is not above
  `acknowledgedStateNumber` (or the sequence counter is beyond 63 bits): a damaged record.
- Throws `SnapshotError.gateBelowSnapshot(limits:used:)` if any of `gate.reservedLimits` is
  below the matching counter. Nothing is built, nothing is sent. The coordinator treats both
  errors as "fallback", like any other unusable record.
- The Outbox starts its own records from `usedCounters`, so a gate whose limits pass but whose
  next numbers are below them is stopped at the first send (`.internalError` with
  `sequenceNotIncreasing`, `stateNumberNotIncreasing` or `fragmentIDNotIncreasing`; the core
  halts, no datagram).
- `usedCounters` is a floor for checks only. Numbers still come from the gate, and the gate
  still starts at the stored reserved limits (`counters`), which are always at or above
  `usedCounters`. A file gate that restarts from `counters` passes without doing anything for
  it. Do not derive the gate's start from the snapshot: the snapshot can be older than the
  counters (dirty record), the counters never.
- An import that sent nothing exports the same snapshot again (the counters included).
- Neither check knows whether the snapshot is stale. That is still the dirty rule alone.

The export call (`MoshConnection.exportState()`, `MoshSession.exportState()`) now returns the
snapshot together with a `CleanToken` (`TransportExport`, `SessionExport`). The token is the
gate's `datagramsPassed` read in the same actor call as the snapshot. It is not stored. The
writer's order is:

    await session.quiesce()
    let exported = try await session.exportState()     // snapshot + cleanToken
    write exported.snapshot (temp file, fsync, rename)
    _ = try gate.markClean(exported.cleanToken)        // false: a datagram left since; stay dirty

The writer must not read `gate.datagramsPassed` itself. `markClean(ifDatagramsPassed:)` stays in
the `DurabilityGate` protocol as the one method a gate implements; `markClean(_:)` is an
extension on top of it.

Still open for item 4 (finding M9, see the Status section of the refutation): the token does
not cover input or a shutdown request accepted while quiesced after the export.
