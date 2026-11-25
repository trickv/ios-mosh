# M10 design: hostile review, fit and risk

Review of `docs/notes/m10/DESIGN.md` against `main` at `584c1fd` and mosh 1.4.0 in
`.refs/mosh/src` (abbreviations as in the design: `toc`, `toh`, `stc`). Lens: layering, actor
isolation, cost, resume paths, clipboard/title/bell, iOS build, oracle buildability, the plan's
steps. Nothing was built or run except one read-only look inside the dev container
(`nm -C -u /opt/mosh-src/src/frontend/terminaloverlay.o`).

## Findings

| id | sev | design section | one line |
|---|---|---|---|
| A1 | critical | 4.1 `emitDisplay`, 5.2 | `.display` is deduplicated against the last `.display`, but the app also draws every `.screen`; an echo-ack-only server state erases pending guesses from the phone screen until the next change |
| A2 | major | 4.3, 4.6 export, 2.6 rule 2 | `latest` (and `.screen`) can go backwards: a `.contact`/advance handler suspended in `predictionReadings()` resumes after `exportState()` stored a newer state |
| A3 | major | 4.7, 5.2 | `.screen` and its `.display` reach the app as separate main-actor jobs (two actor hops each); a display-link tick between them draws the remote frame: pending guesses flicker off at every server state |
| A4 | major | 3.3 D2, 2.2 asserts | `assert(!originMode)` traps in every debug build (moshcli in itest, PredictionWiringTests, a Debug app on the phone) when a confirmed cursor guess meets a server in DECOM |
| A5 | major | 7.2 | a full `shown` dump after every one of 300 commands in 200 cases is gigabytes of JSON at 132x50; the suite (already ~15 min) cannot absorb it |
| A6 | major | 4.1, 4.6 quiesce | "if the session is not quiesced" has no synchronous source: MoshSession has no quiesced flag, only `await connection.isQuiesced()`; a 50 ms timer can tick forever in the background |
| A7 | minor | 2.4, 8 step 6 | `SessionEvent` is `Equatable` (SessionTypes.swift:59); `DisplayFrame` is declared only `Sendable`: step 6 does not compile as written |
| A8 | minor | 4.6, 4.8 | after `.serverEnded`, `.halted`, `.baseStateLost`, `shutdownFinished` the last `.display` keeps its guesses forever (no echo ack will come) and the timer keeps running |
| A9 | minor | 6.1 `--delay-ms` | the delay queue in `TappedTransport` must be dropped on `close()`: the `DatagramTransport` contract forbids handler calls after close (DatagramTransport.swift:27-36); quiesce/resume runs would see late sends |
| A10 | minor | 8 steps 1, 6 | step files omit what the steps' tests need: PredictionWiringTests itself and a delaying test transport (step 6); step 1's test cannot use `PredictionDump` (step 3) |
| A11 | minor | 7.1, 7.4 | cross-check test files are not said to be `#if os(Linux)`; if only `PredictOracle.swift` is guarded, `MoshTerminalTests` stops compiling on the Mac |
| A12 | minor | 7.1 dump | `last_byte` is `char` (toh:215), signed on x86; the dump must print `(unsigned char)` or every non-ASCII byte is a false mismatch against Swift's `UInt8` |
| A13 | doc | 3.3 D3 | "return without change" is impossible for toc:751-754: the parser has consumed the byte and `last_byte`, `cull` already ran |
| A14 | doc | 3.3 D4 | the claim that a >16384 read splits into pieces all over 100 bytes is false (16400 = 16384 + 16) |
| A15 | doc | 6.3 a | "wait for its echo on the remote screen (confirms the epoch)": the echo is not the confirmation; the echo ack comes about 50 ms later (completeterminal.cc:130-158) |
| A16 | doc | 7.1 | `CorpusTests.firstDifference` is `CorpusComparison.firstDifference` (CorpusTests.swift:105, 115) |

## A1 (critical): a deduplicated `.display` loses to an undeduplicated `.screen`

Verified in source.

Attacked text. 4.1: "yield `.display` when `frame` differs (structural `==`) from
`lastDisplayed`". 5.2: "`.screen` and `.display` both replace it, in arrival order, and `tick()`
draws when that serial changed". 4.3: "so every `.screen` is followed by its `.display` while
prediction is on".

Collides with. mosh's server makes a new state when only the echo ack changes:
`Complete::operator==` includes `echo_ack` (statesync/completeterminal.cc:124-128), and
`set_echo_ack` returns true on a change (:130-158) 50 ms after input. Such a state has the same
framebuffer. `reportNewestScreen` yields `.screen` for every new number
(MoshSession.swift:372-379); the app draws `.screen` whenever the number is new
(TerminalViewController.swift:701-703, 938).

Scenario. Adaptive on a 300 ms link, flagging on. User types `ab`. State S1 echoes `a`; app
draws `.screen` S1 then `.display` S1 (`a` real, `b` guessed, underlined). 50 ms later S2
arrives, framebuffer equal to S1, echo ack now covers the `a` input state. `.screen` S2 replaces
the app's frame (no `b`). `render`: `a` judged correct (cell inactive), `b` still pending, the
overlaid frame equals `lastDisplayed`, so no `.display`. The phone shows the line without `b`
for a further round trip although the guess is still live. Wrong text on screen in the designed
use, on every keystroke burst.

Failing test. The design's own wiring test (3) ("every `.screen` is followed by a `.display` of
the same number") with a test transport that delays 150 ms and a server line discipline in
echo mode; type two keys 30 ms apart. It fails on the echo-ack-only state.

Smallest change. Reset `lastDisplayed = nil` whenever a `.screen` is yielded (in
`reportNewestScreen`, `start()` and `exportState()`), so a `.display` always follows; and in
the app, while the mode is not `never`, draw only from `.display` (keep `.screen` for bell,
mouse mode, contact). See A3 for the second half.

## A2 (major): `latest` and `.screen` can go backwards

Verified in source (the race window); the reordering itself depends on actor scheduling.

Attacked text. 2.6 rule 2 ("Reentrancy across that one await is allowed"); 4.3
`latest = (r.newest.number, ...)`; 4.3 "`exportState()` ... also sets `latest` and renders".

Collides with. `handle` runs on the reader task and today already suspends in
`reportNewestScreen` (MoshSession.swift:373); the design adds a suspension on every `.contact`
(MoshConnection.swift:386-387 yields one per authentic datagram). `exportState()` sets
`lastScreenNumber` from its own await (MoshSession.swift:249-258). The duplicate guard is
`newest.number == last` (:374), not `<=`.

Scenario. Handler H awaits `predictionReadings()` and gets S5. Before H resumes, the app calls
`exportState()` (user-initiated priority), which gets S6, yields `.screen` S6, sets `latest = S6`,
renders. H resumes: `latest = S5`, `5 != 6` so `.screen` S5 is yielded, `.display` S5 follows.
The app draws an older screen than the server's newest, with guesses judged against it, until
the next state. The window grows from today's one await per state to one per datagram.

Failing test. `setBeforeEventForTesting` (MoshSession.swift:329) hook that, on the first
`.contact`, calls `exportState()` from a high-priority task before returning; assert the
sequence of `.screen`/`.display` numbers is non-decreasing.

Smallest change. Apply readings only if `r.newest.number > latest.number` (the setters may still
run: they are monotone in mosh), and make the `.screen` guard `newest.number <= last`.

## A3 (major): `.screen` and `.display` drawn in different display-link frames

Plausible; event path verified, tick timing not observed.

Attacked text. 4.7 "goes through the session's one event stream, after the `.screen` of the same
number"; 5.2.

Collides with. `ResumeCoordinator` forwards each session event through
`inOrder { await self.handle(event) }` (ResumeCoordinator.swift:455-458, 710-722); the app's
loop handles each event as its own main-actor job (TerminalViewController.swift:638-648).
CADisplayLink callbacks run between main-actor jobs.

Scenario. Guess pending, S7 arrives with unrelated output. `.screen` S7 handled, tick draws S7
without the guess, next job `.display` S7, next tick draws it again. Guessed characters blink off
for 16 ms on every server frame while typing on a slow link.

Failing test. Not on Linux. On the Mac: a sim UI test that counts surface feeds whose frame lacks
a guessed character between two that have it.

Smallest change. While prediction is on, the app draws only `.display` (A1). Alternatively carry
the overlaid frame inside `ScreenUpdate` and drop the second event.

## A4 (major): the origin-mode assert traps debug builds

Verified in source (toc:151-153; design 2.2 "`assert` (debug builds trap)").

Attacked text. D2 "An app must not crash on a server's DECOM. Release does what mosh does after
the assert".

Collides with. moshcli and the package tests run debug builds; the itest runs debug moshcli
against real programs; whether the phone install is Debug is not pinned anywhere I could find in
`scripts/deploy.sh` (no `-configuration`).

Scenario. `--predict always` in moshcli against a program that sets DECSTBM + DECOM (dialog-style
TUIs). User presses an arrow after a confirmed epoch: `ConditionalCursorMove.apply` asserts,
moshcli dies mid-itest; a Debug app on the phone crashes.

Failing test. Unit test: confirmed active cursor move, `fb.ds.originMode = true`, call `apply` in
a debug test build: it traps today's design.

Smallest change. No `assert` for origin mode in the port; always take the release path, pinned by
a unit test. The fuzz keeps DECOM off so the oracle never aborts.

## A5 (major): dump volume of the fuzz

Verified by arithmetic, not run.

Attacked text. 7.2 "a `dump` after every command", 200 cases of 300 commands; `dump` prints the
whole `shown` frame (7.1).

Collides with. FORMAT state lines dump every cell; at 132x50 that is 6600 cells of about 70 bytes,
around 460 KB per line. One case in seven at 132x50 gives about 28 x 300 x 460 KB, roughly 4 GB to
print and parse per suite run, on a suite already taking 15 minutes (CLAUDE.md).

Scenario. Step 4 adds an hour to `scripts/dev.sh swift test`; "passes the whole suite" in step 4
holds only by lowering the count, losing the coverage counters.

Failing test. Time `PredictionCrossCheckTests` alone; budget 60 s.

Smallest change. `shown` changes only on `frame`, `reset`, `new`: dump the engine after every
command but `shown` only after those, or emit the frame as a delta line (FORMAT already has
`delta_line`, main.cc). Cap large sizes at 30 steps.

## A6 (major): no synchronous "quiesced" for the timer

Verified in source: MoshSession has `started`, `closed`, no quiesce state
(MoshSession.swift:38-50); `quiesce()` and `quiesceAfterSend()` only forward (:221-228).

Attacked text. 4.1 "if `engine.waitTime()` is 50 ... and the session is not quiesced";
4.6 "`quiesce()`: cancel the timer".

Scenario. `quiesce()` cancels the timer, then `exportState()` (4.3) renders and `armPredictionTimer`
re-arms it, since nothing says quiesced. With guesses pending and no acks possible, `waitTime()`
stays 50 and the session wakes 20 times a second until iOS suspends the process, and again
after any background wake.

Failing test. Session test: type to a non-echoing program, `quiesce()`, `exportState()`, then
count renders over 1 s: expect 0.

Smallest change. A session flag set in `quiesce()`/`quiesceAfterSend()` before the await, cleared
in `resume()` after it; `armPredictionTimer` and `render` check it.

## A7 (minor): `DisplayFrame` must be `Equatable`

Verified: `public enum SessionEvent: Equatable, Sendable` (SessionTypes.swift:59). Step 6 fails to
compile. Change: `DisplayFrame: Equatable, Sendable` (Framebuffer is Equatable).

## A8 (minor): guesses left on a dead session

Verified in source that nothing renders after these events (MoshSession.swift:345-357). Scenario:
user types `exit` and Return on a 300 ms link; `.serverEnded` arrives; the last `.display` still
shows guessed text (and a predicted new line) on the final screen, the timer still fires. Test:
after `.serverEnded`, the last frame the app would draw equals the final remote framebuffer.
Change: on `.serverEnded`, `.shutdownFinished`, `.halted`, `.baseStateLost`: `engine.reset()`,
render once, cancel the timer.

## A9 (minor): `--delay-ms` queue outlives `close()`

Verified contract (DatagramTransport.swift:27-36). A queued receive delivered after `close()` (or a
send after it) breaks the contract that `MoshConnection` relies on for replaced sockets, and makes
`datagramsSent()`/WireTap counts differ from the wire under `quiesce`. Test: `--delay-ms 500`,
`replace-socket` in a script, check no handler call for the old id. Change: `close()` cancels the
delay task and empties the queue.

## A10 (minor): step file lists

Step 6's "Proved by" names `PredictionWiringTests` but its Files column has no test file and no
delaying `DatagramTransport` for test (2) (one exists only in moshcli from step 8). Step 1's test
must read epochs from the raw JSON, since `PredictionDump` arrives in step 3. Change: list them.

## A11 (minor): Mac build of the test target

`MoshRef.swift` is wholly `#if os(Linux)` (MoshRef.swift:5, 197). If `PredictOracle` is too, the
harness and cross-check files that call it must be guarded as well, or `scripts/mac.sh swift test`
breaks. Change: guard them, or give `PredictOracle` a non-Linux stub that throws `XCTSkip`.

## A12 (minor): signed `last_byte`

Verified: `char last_byte;` (toh:215), set from `char the_byte` (toc:652, 671). Test: a named
case typing `é`; the dump differs at `last_byte` (-87 vs 169). Change: FORMAT says
`(unsigned char)last_byte`.

## A13-A16 (doc)

A13: D3 should say what state a release build keeps after an early return in the middle of
`newUserByte` (parser, `lastByte`, the cull already done), or use the release semantics "skip this
action, continue the loop". A14: D4's argument is wrong; the deviation is still harmless because
mosh's split depends on what `read` returns. A15: 6.3 (a) must wait for the confirmation (e.g.
`expect-predicted` on a second key with a longer budget, or a `settle 200` after the echo).
A16: name fix.

## What held

- Layering: the engine in `MoshTerminal`, the two reads in `MoshTransport`, wiring in
  `MoshSession` (which already imports both); no new import between transport and terminal.
- Copy-on-write: `var f = remote` shares the row array, so `makeRowUnique` always copies a remote
  row (Framebuffer.swift:82-88, Cell.swift:181-184); no overlay reaches a held state.
- Stored and exported state stay clean: `SessionSnapshot` and the snapshot format have no field for
  engine, `shown` or `latest`; clipboard policy and bell stay on the remote framebuffer.
- Title, bell, clipboard are not in the surface feed (SurfaceFeed.swift rule 3), so a predicted
  frame cannot ring or copy.
- `DisplayDiff` with overlaid rows: same generation, new identity, `moshEquals` compares cells
  (DisplayDiff.swift:181, 394), so going between overlaid and remote frames redraws correctly.
- Reading `lastSentStateNumber` before `core.type` in one actor turn matches `get_sent_state_last()`
  (TransportCore.swift:892; stc:322) even when `type` sends at once (MoshConnection.swift:268-272).
- Send interval formula equals tsi:73-83 (RTTEstimator.swift:54-57), starts at 250 as mosh.
- Refused input never reaches the engine, as stc:319-321.
- Oracle link: `terminaloverlay.o` needs only `Network::timestamp()`, `Terminal::Cell`/`DrawState`/
  `Renditions` symbols, Parser typeinfo and libc (nm, checked); no network or crypto object, so
  way A links; `setlocale(en_US.UTF-8)` is already in `main` (main.cc:1367) for `wcwidth`.
- iOS build: the engine is pure Swift in `MoshTerminal` with no Process or Linux API.
- Cold start: a fresh engine has `confirmedEpoch = 0`; guesses judged early against an old echo ack
  are tentative and are dropped, not drawn.
