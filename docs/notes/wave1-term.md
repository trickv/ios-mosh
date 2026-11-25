# NOTES (wt/term)

Read this first if you continue after an interruption. The integrator removes this file when merging.

Four tasks on this branch, all finished: term-model (the port of `Terminal::Complete`,
8b83c8a), term-diff (`DisplayDiff` and the serialization, bb590cb), term-integrate (the
golden corpus against the port, 5326f49) and term-surface (`SurfaceFeed` and its tests
against SwiftTerm, next section).

## term-surface status (round 4, 2026-11-12): FINISHED

Task: `SurfaceFeed`, the bytes the app feeds to SwiftTerm, and `SurfaceFeedTests` against
SwiftTerm 1.99.3's `Terminal`. Nothing is in progress. `Package.swift` is unchanged.

Before starting, the earlier exit tests were re-run: `scripts/dev.sh swift test -j 4` ->
110 tests, 0 failures.

Delivered:
- `Sources/MoshTerminal/SurfaceFeed.swift`: `SurfaceFeed` (`init()`, `feed(to:)`,
  `invalidate()`, `needsFullRepaint(to:)`, `lastShown`, `isInitialized`,
  `fullRepaintPrefix`, `trustedNarrowRanges`, `isTrustedNarrow`), `visibleText(of:)`
  (global and `SurfaceFeed.visibleText(of:)`). The rules are listed at the top of the file.
- `Sources/MoshTerminal/DisplayDiff.swift`: an internal flag `surface` on `DisplayDiff`.
  Off (the default, and all that is public) the output is mosh's, byte for byte; the
  DisplayDiff tests against mosh still pass unchanged.
- `Tests/SurfaceFeedTests/`: `SwiftTermScreen.swift` (SwiftTerm `Terminal` set up as the
  app must), `SurfaceWalk.swift` (corpus walk and comparison), `SurfaceFeedCorpusTests`,
  `SurfaceFeedRuleTests`, `SurfaceFeedRandomTests`, `WidthScan.swift`,
  `WidthDisagreementTests`. Placeholder deleted.

Checks (all from the worktree; figures are printed by the tests with the prefixes
SURFACE, RANDOM, WIDTHS, DISPUTED, TRUSTED):
- [x] `scripts/dev.sh swift test -j 4 --filter SurfaceFeedCorpusTests` (74 s): 38 of 38
      cases equal in each of four modes. After every feed: characters, width and right
      half of wide characters, foreground, background, style of every cell; cursor
      position and visibility; mouse mode and encoding, bracketed paste, focus events,
      reverse video, application cursor keys, no scrollback; SwiftTerm sent nothing,
      rang no bell, set no title, wrote no clipboard.
      - every state: 2900 feeds (85 full repaints, 666 empty), 115,707 bytes,
        2,836,946 cells, 14,221,535 comparisons.
      - every 3rd state: 977 feeds, 950,042 cells, 4,762,633 comparisons.
      - every 7th state: 432 feeds, 422,160 cells, 2,116,314 comparisons.
      - invalidate before random feeds (seeded, about one in four): 2900 feeds, 769 full
        repaints, 476,771 bytes, 14,221,535 comparisons.
      Exclusions, all counted and printed per case (every-state figures):
      - 16 states of rec-resize-bash (10) and syn-resize (6) are one column wide and are
        not fed: SwiftTerm's minimum is two columns.
      - 89 cells in syn-utf8 (49) and syn-wide (40): U+200B, U+FEFF or U+E0001 in a cell.
        SwiftTerm does not store a zero-width format character
        (Grapheme_Cluster_Break=Control). Invisible. The rest of the cell is compared.
      - 76 cells in rec-unicode (36) and syn-wide (40): the feed leaves U+FE0F out of a
        one-column cell (SwiftTerm would widen the cell to two columns; the server
        counts one). The cell is compared without it.
      - 2 states (rec-modes, syn-modes) with mouse mode 1001: SwiftTerm has no highlight
        tracking; the feed gives it "off" and that is what is compared.
      rec-vim, rec-tmux, rec-bash, rec-htop: no exclusion (asserted).
      Not an exclusion: 6 feeds switch focus events on and SwiftTerm answers `ESC [ I`
      (see "For the app").
- [x] `--filter SurfaceFeedRuleTests` (19 tests, 5 s): one test per rule; the comparison
      itself is tested (14 kinds of damage are each noticed); skipping: all 780 pairs of
      40 states.
- [x] `--filter SurfaceFeedRandomTests` (15 s): 240 random sessions of wide, combining
      and emoji-sequence characters with erases, insertions, scrolls, on 16x5, 9x4, 2x3
      and 31x3: 13,480 feeds, 3,664,237 comparisons, 0 differences.
      `scripts/dev.sh bash -c 'SURFACE_RANDOM_RUNS=3000 swift test -j 4 --filter SurfaceFeedRandomTests'`
      was run once (182 s): 167,905 feeds, 45,478,424 comparisons, 0 differences.
      This test found three bugs the corpus did not (commit 578272e).
- [x] `--filter WidthDisagreementTests` (5 tests, 24 s).
- [x] Whole suite `scripts/dev.sh swift test -j 4`: 138 tests, 0 failures, 0 skipped,
      about 295 s. Run twice: on the tree of 62f25d7, and again after the last change to
      `Sources/` (comments in SurfaceFeed.swift); only NOTES.md changed after that.

### Decisions
- **Own writer, not post-processing.** The rules are applied inside `DisplayDiff`
  (flag `surface`), so all code is shared with the port of `new_frame`. Rewriting
  `new_frame`'s output would need a second terminal model to know where the cursor is and
  what the writer relies on next (autowrap, CR, backspaces).
- **Trusted and guarded cells.** SwiftTerm joins characters into grapheme clusters by
  its own rules and a cursor movement is what makes it start a new cluster, so "an
  explicit cursor position after every wide or combining character" is needed for more
  than widths. A cell is trusted if it is empty or holds one narrow character from
  `SurfaceFeed.trustedNarrowRanges` (ASCII, Latin, Greek, Cyrillic, punctuation, arrows,
  box drawing, blocks, Braille, Powerline: 1785 scalars, each checked against SwiftTerm
  for width 1 and for never joining). Every other cell, so every wide and every
  combining one, is guarded: cursor position before and after, its columns erased
  first, the next cell always redrawn, autowrap off around it at the right margin, no
  autowrap after it.
- **U+FE0F / U+FE0E.** Left out where SwiftTerm would change the cell's width against
  mosh's (FE0F in a one-column cell, FE0E in a two-column cell).
- **A wide character in the last column** (mosh can hold one) is drawn as a blank.
  mosh's own client lets the real terminal wrap it, which on the bottom row scrolls.
- **Focus mode** is written only when it changes, also in a full repaint: SwiftTerm
  answers every `?1004h` with a focus report for the host.
- **Mouse mode 1001** is "off" for SwiftTerm and `?1001` is never written (SwiftTerm
  prints a log line for each).
- **Full repaint prefix** `ESC[?1h ESC[?7h`, then new_frame's own reset.
- **Application cursor keys** are always on in SwiftTerm. The task text says the state
  should equal the framebuffer's; the plan's rule (and mosh's `Display::open`) says
  always on, and the client framebuffer's field is never transmitted. The test asserts
  "always on".
- The test terminal is SwiftTerm's `Terminal` class, not `HeadlessTerminal` (which does
  not exist on iOS and always owns a process). Only public API is used.

### Width disagreements (SwiftTerm 1.99.3 against glibc 2.39), from the scan
287,279 scalars have glibc width 0, 1 or 2 (what mosh can put on the screen); SwiftTerm
disagrees on 584, with `regionalIndicatorWidth: .narrow` (610 with its default, which
makes the 26 regional indicators two columns):
- glibc 1, SwiftTerm 2: 124 (U+2630..2637, U+268A..268F, U+1D300.., U+1D360..). The
  redraw of the next cell blanks the character. Shown as a blank.
- glibc 1, SwiftTerm 0: 448 spacing combining marks, mostly Indic vowel signs (U+0903,
  U+093E, ...). SwiftTerm joins the character to the cell on its left; for 403 it
  widens that cell over the character's own column (which is where mosh has it), 14 stay
  joined in one column, 31 are not stored after a Latin letter.
- glibc 2, SwiftTerm 1: 8 (U+3248..324F): shown, second column blank.
- glibc 2, SwiftTerm 0: 4 (U+302E, U+302F, U+16FF0, U+16FF1): joined to the left cell.
- glibc 0, SwiftTerm 1 or 2: none.
For every one of the 584, as a full repaint and as a diff, mid-row and at the right
margin of the bottom row: every cell other than the character's own and its left
neighbour equals the framebuffer, the cursor too, nothing scrolls. Scalars with glibc
width -1 never reach a framebuffer (SwiftTerm gives 763,968 of them one column and
60,649 two; measured once over all 1,111,999 values, not part of the committed test).

### For the app (SwiftTermSurface)
- Create the view with `TerminalOptions(regionalIndicatorWidth: .narrow)` and call
  `changeScrollback(nil)`. Without the option a regional indicator is shown as a blank
  (nothing else breaks; tested).
- One `SurfaceFeed` per SwiftTerm view; a new view needs a new `SurfaceFeed`.
  `invalidate()` on `sizeChanged`, and after anything else that changed SwiftTerm
  behind the feed's back.
- Do not feed a framebuffer whose size is not SwiftTerm's size (between the app's
  Resize and the server's answer): rows longer than the view wrap and scroll. Wait for
  the state of the right size; the feed for it is a full repaint by itself.
- A framebuffer one column wide cannot be shown (SwiftTerm's minimum is two columns).
- SwiftTerm sends `ESC [ I` or `ESC [ O` to the host when the feed switches focus events
  on. Pass it on like keyboard input.
- `needsFullRepaint(to:)` tells a resume or resize repaint from a live diff.
- Title, bell, clipboard: read `windowTitle`, `iconName`, `bellCount`, `clipboard` from
  the framebuffer; the feed never contains them.

### Known gaps
- A soft-wrapped row that ends in a guarded cell (a wide or combining character, or a
  narrow one outside the trusted ranges), or whose next row starts with one, passes no
  soft-wrap mark to SwiftTerm: copied CJK text has a newline at each wrap. Trusting
  verified wide ranges too would fix it for CJK, at the price of the literal rule
  "position after every wide character".
- The 584 disputed characters are contained, not shown correctly (see above). When only
  the cell left of a disputed spacing mark is redrawn and that cell is a trusted one,
  SwiftTerm loses the mark until its own cell is redrawn.
- A guarded cell SwiftTerm does not store (a disputed character at the right margin)
  can leave its combining characters on the cell to its left. (Reasoned from SwiftTerm's
  code; no test builds this case.)
- Zero-width format characters (U+200B, U+FEFF, tags) are not stored by SwiftTerm, so
  text copied from SwiftTerm lacks them. `visibleText(of:)` has them.
- Nothing was compiled for macOS or iOS. `SurfaceFeed.swift` uses the standard library
  only; the tests use Foundation, XCTest and SwiftTerm's public API.
- The corpus has no wide character in the last column on the client side; that rule is
  covered by a rule test and by the random test (713 cells).

## term-integrate status (round 4, 2026-11-12): FINISHED

Task: milestone M3 exit. Merge `wt/oracle`, corpus test Swift against the oracle, fix the
port, reload test, newFrame byte equality, performance, coverage. Nothing is in progress.

Result: the port equals mosh 1.4.0's emulator on the whole corpus, client side and server
side, 38 cases, 2916 instructions, 0 differences; no change to `Sources/` was needed in
this task. All numbers below are for the 38-case corpus and are printed by the tests.

- [x] Step 1. `git merge wt/oracle` (a9509f4; only NOTES.md conflicted, ours kept).
      `scripts/dev.sh bash -c 'Tools/mosh-oracle/build.sh; scripts/corpus-check.sh --gen'`
      -> "corpus-check: 38 cases pass", check_format 5832 states (after step 5; 34 cases
      and 5446 states before); `mosh-oracle selftest` 80 probes 0 failures (round 3,
      main.cc unchanged since).
- [x] Step 2. Loader `Tests/MoshTestSupport/GoldenCorpus.swift` (own JSON reader, no
      MoshTerminal import, so SurfaceFeedTests can use it too) and
      `Tests/MoshTerminalTests/CorpusTests.swift` (client run = `mosh-oracle apply`, server
      run = `mosh-oracle server`, comparison of all 34 keys and 7 fields of every cell,
      first difference per case with instruction, field, row, column, both values and the
      diff bytes).
- [x] Step 3. `testClientStatesEqualTheOracle`, `testServerStatesEqualTheOracle`: 38 cases,
      2916 states each, 99,144 keys and 2,839,024 cells (19,972,312 fields) per side, 0
      differences. The comparison itself is tested: `testTheComparisonNoticesEveryField`
      (757 wrong keys and 480 wrong cells, each reported with the right field, row and
      column), `testEveryKeyAndCellFieldVariesInTheCorpus`.
- [x] Step 4a. Reload: the same two runs with every state through `serialized()` /
      `init(serialized:)` before each use: 0 differences
      (`test...WhenEveryStateIsReloaded`).
- [x] Step 4b. `Tests/MoshTerminalTests/CorpusDisplayTests.swift`.
      - `testServerDiffsEqualTheRecordedDiffs`: from the server's states (built from
        session.jsonl as one history) `diff(from:)` equals the recorded ops for 2916 of
        2916 instructions (497 empty, 10 echo ack, 82 resize, 2414 hostbytes, 219,060
        bytes) and `DisplayDiff.newFrame(initialized: true, ...)` equals the recorded
        hostbytes for all 2331 single-hostbytes instructions. No exception.
      - `...WhenStatesAreReloadedWithSharedRows`: the same, states reloaded through
        `serializedWithoutRows()` + a table of distinct `Row.serialized()`: no exception.
      - `testServerDiffsWhenEveryStateIsItsOwnBlob`: `newFrame` still equal for all 2331;
        `diff(from:)` differs in exactly 6 instructions (syn-invisible 29, 31; syn-osc 2,
        16, 26, 29), the one class: only the icon name changed, mosh's `operator==`
        (row pointers, icon name ignored) held, mosh sent nothing; separately decoded
        states share no rows, so the port sends the two titles. Asserted as: count ==
        number of instructions where the icon name changed and mosh sent no hostbytes.
      - `testNewFrameBetweenClientStates` (the task's wording, client states): 2235 of
        2331 byte-equal; 96 differ, 0 unexplained: 16 row identity and generation, 33
        cells (27 empty versus space, 4 that plus soft-wrap bit, 2 wide character in the
        last column), 47 cursor one column left. Each is proved by putting the server's
        information back and getting the recorded bytes. Each frame applied to the
        client's old state gives the client's new state (2284) or that with the cursor
        one further column left (47): SurfaceFeed must end with an explicit cursor
        position, as the term-diff notes below already say.
      - `testFiguresOfTheCorpus` prints the figures quoted in Tools/mosh-oracle/README.md.
- [x] Step 4c. `Tests/MoshTerminalTests/CorpusPerformanceTests.swift`, debug build: client
      applies the whole corpus in 0.76 s (260 us per instruction, 3.5 us per byte, 2954
      states kept); server reads it in 0.40 s; all 2916 `diff(from:)` 0.56 s. State copy
      0.9 us (272 bytes inline, rows shared); copy + first write 23 us (30 row references
      and one row of 100 cells = 2400 bytes); full 100x30 screen serialized 6071 bytes,
      encode 7.8 ms, decode 6.4 ms (debug). Asserted bounds: 5 s per run, 20 us per copy.
- [x] Step 5. `scripts/corpus-coverage.sh` (llvm-cov regions of the port under the three
      plain corpus tests). Found reachable code no case reached; added `syn-del`,
      `syn-dcs`, `syn-margins`, `syn-blanks` in `Tools/mosh-oracle/synthetic.py`
      (`scripts/corpus-check.sh --regen`; the 34 older cases did not change by a byte).
      What was missing and what is still not reached, with reasons: Tools/mosh-oracle/
      README.md, "Coverage". After: TerminalFunctions 242/247 regions, DrawState 102/105,
      Dispatcher 80/82, DisplayDiff 225/234; every remaining region is unreachable in
      mosh too, needs a Display without BCE, or is not driven by host bytes.
- [x] Whole suite: `scripts/dev.sh swift test -j 4` -> 110 tests, 0 failures, 0 skipped,
      178 s (the four reload tests are 57 s of it).

Decisions:
- The loader lives in MoshTestSupport, not in CorpusTests.swift as the task text says, so
  the next task (SurfaceFeedTests, another test target) can load the corpus.
- Server echo_ack steps are applied as the oracle's `session_step` does
  (registerInputFrame, clock +1000, setEchoAck, clock +1000).
- FORMAT.md and the oracle needed no correction. Only synthetic.py and the README changed.
- `swift test --enable-code-coverage` leaves a `default.profraw` in the worktree;
  corpus-coverage.sh removes it. Do not commit one.

## term-diff status: finished (round 3, 2026-11-12)
Nothing is in progress. Everything below is committed.

- [x] `Sources/MoshTerminal/DisplayDiff.swift`: port of `Display::new_frame`, `put_row`,
      `FrameState`; `DisplayDiff.newFrame(initialized:from:to:)`; the server's
      configuration (`Display( false )`: ECH, BCE, titles on) is the default, the three
      flags can be changed; `TerminalState.diff(from:)`, `initDiff()`, `apply(_:)` mirror
      `Complete::diff_from`, `init_diff`, `apply_string`.
- [x] `Sources/MoshTerminal/Serialization.swift`: `TerminalState.serialized()`,
      `init(serialized:)`, `serializedWithoutRows()`, `init(serializedWithoutRows:rows:)`,
      `Row.serialized()`, `Row(serialized:width:)`. Format description at the top of the file.
- [x] Tests: `DisplayDiffTests` (examples, properties), `DisplayDiffCrossCheckTests`
      (bytes against mosh, Linux), `SerializationTests`. Support: `DiffScenario.swift`
      (history generator), `TerminalFuzz.swift` (moved out of MoshCrossCheckTests.swift so
      it also builds on a Mac), moshref commands `diff` and `applydiff`.

## Checks that passed (commands from the worktree)
- `scripts/dev.sh swift test -j 4 --filter MoshTerminalTests.DisplayDiffCrossCheckTests`
  new_frame bytes identical to mosh 1.4.0 for 4926 of 4926 pairs (both `initialized`
  values), 1536 of 1536 with other capability flags, 14 of 14 hand-worked examples;
  applied results (complete dumps) identical too.
- `scripts/dev.sh swift test -j 4 --filter MoshTerminalTests.DisplayDiffTests`
  0 unexplained differences in 13,166 pairs; see the printed tallies.
- `scripts/dev.sh swift test -j 4 --filter MoshTerminalTests.SerializationTests`
  round trip, continuation, 10,000 damaged blobs.
- `scripts/dev.sh swift test -j 4` whole package: 93 tests, 0 failures, 0 skipped (about 100 s; 110 tests after term-integrate).
- term-model's checks were re-run first: 72 tests passed, width table regenerates identically.

## What new_frame does not reproduce (all confirmed as mosh's own behaviour)
Limits, visible on the receiving terminal:
- A wide character in the last column (autowrap off, a resize, ICH/DCH can leave one):
  the receiver wraps before printing it.
- After the bottom-right cell is drawn, a cursor that belongs on the bottom row within
  four columns of the right margin ends one column short (backspaces counted from the
  column past the margin). SurfaceFeed should end with an explicit cursor position.
- A soft-wrap mark on the bottom row; a soft-wrap mark whose last column is hidden under
  a wide character when that character is not redrawn; soft-wrap marks on a terminal one
  column wide.
- `diff(from:)` only: an icon name that changes alone is not sent (mosh's
  `Framebuffer::operator==` ignores it), until the window title changes.
- A fallback cell at the 32-byte limit loses its last combining character; a title of 255
  characters (only possible with `OSC ;`) loses its last one. (Not hit by the generator.)
Hidden differences (never on screen): row identity and generation; bell count (one BEL
per diff); ?1007; fallback cells come back as NBSP + combining characters; empty cells
can come back as a space; the cell under the right half of a wide character; wrap bits
outside the last column; origin, insert and autowrap mode, scrolling region, tabs, saved
cursor, pending wrap, combining position, application cursor keys; the parser state.

## Decisions
- The property tests give the diff to a "receiver copy" of the base: same screen, the
  modes new_frame never sends at their defaults, parser at Ground. A raw copy of a server
  state can be in origin mode or inside an escape sequence, and then no diff applies.
- Serialization keeps `Row.gen` and row sharing between lines; decoding calls
  `RowGeneration.reserve`. With that, newFrame between two reloaded states gives the same
  bytes as between the originals (tested).
- Decoder limits: width and height up to 32767, at most 2^20 cells in distinct rows, cell
  contents up to 64 bytes. Above that it throws.
- No checksum in the blob: the snapshot file has to carry its own.

## From term-model (unchanged)
- Rows are reference objects shared between framebuffer copies, copied on write, like
  mosh's `shared_ptr<Row>`; structural `==` ignores identity and gen, `moshEquals` uses them.
- UTF-8 decoding ports glibc 2.39 `mbrtowc`.
- Cross-check against mosh's own `Terminal::Complete`: 110 curated, 400 + 200 random cases,
  all identical (`--filter MoshCrossCheckTests`).
