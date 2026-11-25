# M10 DESIGN.md: hostile review, lens "fidelity to mosh"

Reviewer's notes on `docs/notes/m10/DESIGN.md` at the state of 2026-11-18. Every mosh
reference is to mosh 1.4.0 in `.refs/mosh/src` (`toc` = `frontend/terminaloverlay.cc`,
`toh` = `frontend/terminaloverlay.h`, `stc` = `frontend/stmclient.cc`), read for this
review, not taken from the readers' notes. Swift references are to `main` as checked out.
"Verified" means I read the lines cited. "Plausible" means the argument holds on the
source but rests on something I could not run (nothing was built or run).

## Findings

| id | sev | design section | one line |
|---|---|---|---|
| F1 | critical | 4.1 `emitDisplay`, 4.3, 5 item 2 | `.display` is skipped when the overlaid frame did not change, but the app has already replaced its frame with the `.screen` of the new state, so pending guesses vanish from the screen |
| F2 | major | 7.4 wiring tests 2 and 4, 6.3 part c | these tests expect a first guess to be drawn, but a fresh engine's first epoch is tentative and is never drawn: test 2 fails on a correct port, part c passes without testing anything |
| F3 | major | 4.1 `armPredictionTimer`, 4.5 | with no timer while `waitTime()` is `INT_MAX`, and no render on transport ticks, the 5000 ms glitch step is missed during a stall that mosh notices on its retransmit passes |
| F4 | minor | 3.3 D4 | "a longer read splits into reads also over 100" is false: 16450 bytes is 16384 + 66, and mosh predicts the 66 |
| F5 | minor | 7.1 dump `last_byte` | mosh's `last_byte` is a `char`; printed as is it is negative for bytes from 0x80, while Swift holds `UInt8`, so the first `é` fails the fuzz with no real difference |
| F6 | minor | 7.2 coverage | the coverage counters leave out branches where a port slip is likely (the cursor's full reset, renditions copied along the row, the backspace neighbour rules, `ESC O`, a kill inside the row loop) |
| F7 | minor | 4.3 `exportState` | `exportState()` sets `latest` without the three setters, giving a frame newer than `late_ack`, a pair mosh never has |
| F8 | doc | 7.1 vs 7.2 | the command grammar has `time MS` (absolute); the generator emits `time +D` |

## F1 (critical): predictions vanish between a `.screen` and a skipped `.display`

Verified: the design text and the mosh source. Plausible: the SwiftUI/CADisplayLink timing,
which I did not run.

**Design text.** 4.1: "`emitDisplay`: ... yield `.display` when `frame` differs (structural
`==`) from `lastDisplayed`". 5 item 2: "`.screen` and `.display` both replace it, in arrival
order, and `tick()` draws when that serial changed". 4.3: "Order of events: `.screen` (if
the number is new), then `.display`", and wiring test 3 (7.4) "every `.screen` is followed
by a `.display` of the same number".

**Source.** In mosh, only one thing reaches the screen: `output_new_frame` draws
`new_state` = latest remote fb + `overlays.apply` (stc:274-277), against `local_framebuffer`
(stc:280-287). The raw remote frame is never drawn while predictions are on. An echo
usually arrives *before* its echo ack, because the server sets the echo ack only after
holding the state 50 ms (statesync/completeterminal.cc:133-140, completeterminal.h:60). So
until then the guess is `Pending` (toc:90-92) and stays drawn on top of the echo.

**Scenario.** Mode `always`, epoch confirmed, the user types `cho` quickly after `e`. State
N arrives holding only the echo of `c`, with echo ack below the guesses' expiration frame.
Render: the guesses for `c`, `h`, `o` are Pending and still drawn. The overlaid frame is
structurally equal to `lastDisplayed` (the `c` cell, the guesses and the predicted cursor
are unchanged), so no `.display` is yielded. But `.screen(N)` was yielded and the
controller replaced its frame with it. Its serial changed, so `tick()` draws remote N:
`ec` with the cursor after `c`. The guessed `ho` disappears until the next state or
keystroke changes the overlaid frame. This happens on almost every echo over a slow link,
and local echo exists for exactly that case. Even without the skip, a display-link tick
that falls between the `.screen` and the `.display` of the same state draws the raw frame
for one refresh (a flicker).

**Failing test.** Wiring test 3 as written already fails (a `.screen` without a
`.display`). Add a session test with a delaying transport: confirm the epoch, type three
keys within one RTT, let the server echo the first. Assert that the last event of each
state is a `.display` whose framebuffer holds all three letters. Also add an app-model
test of the controller's rule: draw the last frame-carrying event.

**Smallest fix.** (a) `emitDisplay` also yields when `latest.number` differs from the
number of the last `.display`, which makes test 3 true. (b) The app draws from `.display`
only while the mode is not `never`. It uses `.screen` only for the bell, the mouse mode
and contact, and for drawing only in `never` mode.

## F2 (major): tests that need a first guess drawn on a fresh engine

Verified in the source.

**Design text.** 7.4 wiring test 2: "`always` with a delaying test transport: a typed
character is in a `.display` before any `.screen` shows it". Wiring test 4: "after typing
to a non-echoing program, ... `screen()` hold none of the typed text, while
`displayedScreen()` did". 6.3 part c: `stty -echo; cat >/dev/null`, "Guesses with no echo
vanish once judged".

**Source.** A fresh engine starts with `prediction_epoch = 1` and `confirmed_epoch = 0`
(toh:298-299). Every cell and cursor guess made in epoch 1 is tentative (`1 > 0`, toh:76).
`apply` returns early for tentative cells and cursors (toc:51-53, 147-149). Only a
`Correct` judgment raises `confirmed_epoch` (toc:543-544), and that needs an echo.

**Scenario.** Test 2 types one key on a new session: nothing is drawn, so the test fails on
a correct port. The temptation is then to "fix" the engine. Test 4: `displayedScreen()`
never holds the text, so the test fails. Part c: no echo means no confirmed epoch, so
nothing is ever drawn. `expect-display-settled` and the empty dump pass whether or not the
vanishing path works.

**Failing test.** Part c passes against an engine whose `IncorrectOrExpired` branch does
nothing, which shows that it proves nothing.

**Smallest fix.** Confirm an epoch first in each case. Tests 2 and 4: type one key to an
echoing program, wait for its `.screen`, then test. For the non-echoing case use a server
command that echoes exactly one byte, for example
`sh -c 'stty raw -echo; dd bs=1 count=1 2>/dev/null; cat >/dev/null'`. The first key is
echoed and confirms the epoch. Keys after it (no CR, same epoch) are drawn, then judged
`IncorrectOrExpired` while not tentative, which causes a full `reset()` (toc:528-533). That
is also a live run of a coverage item of 7.2.

## F3 (major, rare): no cull between datagrams while `waitTime()` is `INT_MAX`

Verified in the source. The reachability argument is plausible, not run.

**Design text.** 4.1: the timer runs only "if `engine.waitTime()` is 50". 4.5: "The
transport's own timers ... do not render". 9.1 risk 3: "by at most the 50 ms mosh itself
allows".

**Source.** mosh calls `output_new_frame()` (so `cull`) at the top of *every* loop pass
(stc:441-444). A pass also wakes on `network->wait_time()` (retransmits, acks), not only on
`overlays.wait_time()`. `wait_time` is `INT_MAX` when `glitch_trigger && flagging`
(toh:266-269, 287-292), yet a Pending guess older than 5000 ms still sets
`glitch_trigger = 20` at the next cull (toc:579-580). Once the guess has been judged, that
step can no longer happen.

**Scenario.** The link has send interval 150 ms, so `flagging` is on (toc:465-466). A guess
pends 250 ms, so `glitch_trigger = 10` (toc:581-583), so `waitTime()` is `INT_MAX` and the
port has no timer. Then the server stalls for 6 s with no datagrams. mosh's retransmit
passes cull at about 5 s and set 20. The port does not render until a datagram arrives. If
that datagram carries the echo, the guess is judged, not Pending, so the trigger stays 10.
When the link recovers and the send interval drops to 50 ms or less, mosh keeps
underlining (`glitch_trigger > 10`, toc:472-474) until ten quick confirmations at least
150 ms apart (toc:555-559). The port stops underlining at once. The guesses are the same;
the underline differs for about 1.5 s or more.

**Failing test.** Not reachable in the differential (it fixes the call order). Add a
`PredictionWiringTests` case with a test clock and a transport that drops inbound
datagrams for 6 s while the session retransmits: after recovery `glitch_trigger` is 20 in
the engine dump.

**Smallest fix.** While `engine.isActive`, arm the timer at 50 ms whatever `waitTime()`
says, or render after each transport tick. An extra cull is a schedule mosh also produces
(any pass culls), so neither change moves the port away from mosh.

## F4 (minor): D4's argument is wrong at the 16 KiB boundary

Verified: stc:305-309 (`buf_size = 16384`, one `read`), stc:325-334.

**Design text.** D4: "a longer read splits into reads that are also over 100: same
outcome". **Scenario:** a 16450-byte paste is read by mosh as 16384 + 66. The second read
is 100 bytes or fewer, so it is predicted (stc:325, 330-332). The port resets for the whole
read and predicts none of it. **Test:** none needed in the engine. Correct the text, or
split reads at 16384 in `newUserRead`, which makes this exact. **Fix:** the one-line
split, or reword D4 as a deliberate deviation.

## F5 (minor): `last_byte` sign in the oracle dump

Verified: toh:215 `char last_byte`, toc:652 `char the_byte`, toc:670.

On x86-64 `char` is signed. `num(last_byte)` prints -61 after the first byte of `é`
(0xC3). The Swift dump prints 195, so the first non-ASCII read fails the fuzz on a field
that does not differ in behaviour. Every use in the engine is an equality with 0x1b and
`'O'`, where sign does not matter. **Test:** the fuzz itself, on its first `é` read.
**Fix:** state in 7.1 and FORMAT.md that `last_byte` is printed as `(unsigned char)`. main.cc
already does this for `utf8_buf` (`uint8_t( c.parser.buf[ i ] )`).

## F6 (minor): coverage counters miss branches where a port slip is likely

Verified against the branch structure of toc:440-626 and 696-860.

7.2's list has no counter for: the cursor check's full `reset()` regardless of tentative
(toc:596-613); renditions copied along the row after a `Correct` (toc:561-569); the
backspace neighbour cases (next cell active and unknown / active and known / inactive,
toc:729-739) and the overwrite backspace (toc:704-714); the `ESC O` to `ESC [` rewrite
(toc:666-669); a `kill_epoch` that resets cells to the right of the current one in the
same row loop (toc:507 with toc:398-404). A generator change that stops reaching any of
these goes unnoticed. **Fix:** add them to the counters. Read them from the dumps (a
cursor list emptied together with all overlays; replacement renditions changed without a
read; and so on).

## F7 (minor): `exportState()` renders a frame newer than `late_ack`

Verified in the design text (4.3) and stc:290-300 with stc:274.

In mosh the setters and the fetched frame always come from the same newest remote state.
The setters run in `process_network_input` and the frame at the next pass, with no
`recv` in between. The design's `exportState()` path sets `latest` and renders without
`predictionReadings()`. The effect is small: guesses read as Pending one render longer.
But it is a pair of inputs the oracle never models. **Fix:** in that path, take the
numbers from the same export, or skip the render (no frame is drawn while quiesced
anyway).

## F8 (doc): `time` grammar

7.1 defines `time MS` as an absolute value; 7.2 generates `time +D`. Pick one. Absolute is
better, because the reply log then shows the clock.

## What held

Each line is a behaviour from the source that a port built exactly from DESIGN.md
reproduces.

1. Printable in the last column: `become_tentative` before the insert, then again with
   `newline_carriage_return` on the wrap (toc:758-762, 823-829); covered by "same" and a named case.
2. Wrap or CR on the last row: a blank prediction over the whole row. It erases the
   contents of a last-column guess made a moment before, and keeps the stale renditions and
   `unknown` (toc:869-895). Quirk 6 keeps `contents = []` only.
3. Backspace at column 0 still makes the row and expires nothing (toc:698-700); quirk 22.
4. Backspace with `i + 2 < W` makes every cell unknown when the width is below 3 (toc:725-742); quirk 4.
5. Wide and combining input: `init_cursor` and then only `become_tentative` (toc:689, 746-748). 0x7f is a `Print` in ground state (parserstate.cc GLGR includes 0x7F), so the backspace branch is reachable.
6. An escape sequence split across reads: the parser and `last_byte` persist across reads, and `ESC O` becomes `ESC [` (toc:666-673).
7. A paste: `set_local_frame_sent` before the paste test, `reset()`, no bytes fed, the parser left mid-sequence (stc:322-334).
8. The epoch after an unpredictable key: Execute other than CR, Esc_Dispatch, CSI other than C/D all call `become_tentative` (toc:831-859).
9. Glitch thresholds and the unsigned `now - 150` (toc:555-584): the integer rules of 2.2.
10. Flag and SRTT hysteresis (toc:456-474), with `!active()` evaluated at the top of cull.
11. A frame that arrives while guesses are tentative: render culls a fresh copy of the remote frame, not `shown` (stc:274-277). Keystrokes cull `shown` (stc:334).
12. A cell guess judged wrong while tentative calls `kill_epoch` inside the row loop and the loop continues (toc:493-508). A wrong non-tentative guess calls `reset` and returns (toc:528-533).
13. `reset_with_orig` keeps the stale `replacement`, including `wide` and `wrap` (toh:115-124), so a narrow guess can carry a stale wide flag; quirk 5 keeps it.
14. `lastSent` read before the append in one actor turn matches `get_sent_state_last()` (transportsender.h:154) before `tick` sends.
15. Cold start: the first read's guesses are tentative (`confirmed_epoch` 0), and an already-passed echo ack can only drop them. A cell cannot be `Correct`, because its original matches (toc:102-111).
16. The reentrancy argument (2.6.2) holds: an echo cannot be judged inside the `type` await, because of ECHO_TIMEOUT (completeterminal.h:60).
17. Keystroke order: `ResumeCoordinator.inOrder` (ResumeCoordinator.swift:409-417, 591) serializes `type`, so the engine sees bytes in the order the connection did.
18. Mode `never` keeps the overlays, which come back on a switch (toc:442, 654); plain stores reproduce this.
19. The oracle's clock: the engine calls `Network::timestamp()` (network.h:54); `util/timestamp.h` declares no `timestamp()`. The oracle sets `en_US.UTF-8` (main.cc:1367), so `mbrtowc` and `wcwidth` match.
20. Two renders per datagram (`.remoteStateAdvanced`, then `.contact`) give a second, nearly idempotent cull. It can only turn `srtt_trigger` off earlier, when nothing is active, which draws nothing differently.
21. D6: mosh overwrites `local_framebuffer` with the remote state 0 at the first loop pass (stc:441-442, 274), so starting `shown` from the newest remote state matches it.
