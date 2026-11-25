# M10 local echo: a faithful port of mosh's prediction engine

Design for milestone M10 of `docs/PLAN.md` ("Port of mosh's `terminaloverlay.cc` ... The
overlay is applied to a copy of the newest framebuffer before `DisplayDiff`", PLAN.md:973-974;
exit row "Typed characters appear at once on a 300 ms link", PLAN.md:849). Design only:
nothing in this file is built or run.

Conventions:

- Code references are to `main` at `584c1fd`. mosh references are to mosh 1.4.0 in
  `.refs/mosh/src`, written `file:line`, with the abbreviations of
  `docs/notes/m10/mosh-prediction.md` (`toh` = `frontend/terminaloverlay.h`, `toc` =
  `frontend/terminaloverlay.cc`, `stc` = `frontend/stmclient.cc`, `sth` =
  `frontend/stmclient.h`, `tfb`/`tfbc` = `terminal/terminalframebuffer.{h,cc}`).
- "The spec" is `docs/notes/m10/mosh-prediction.md`; its section numbers are written
  "spec 6.5". "Seams" is `seams.md`, "tools" is `test-tools.md`, both in this folder.
- "Shown" is mosh's `local_framebuffer`: the last frame drawn, with predictions
  (stc:287). "Remote" is the newest server state's framebuffer.
- **[!]** marks a place where a subtle mistake puts wrong text on the screen.

Contents: 1 summary, 2 Swift design, 3 port map and deviations, 4 wiring in MoshSession,
5 the app, 6 moshcli and itest, 7 tests, 8 implementation plan, 9 risks and open questions,
appendix A what the readers left unclear, then the review status.

## 1. Summary

1. **The engine is a value type in `MoshTerminal`.** `PredictionEngine` (a `struct`, no
   clock, no actor, no I/O) is a line-by-line port of `Overlay::PredictionEngine` and its
   three overlay classes (toh:52-308, toc:43-157, 347-932). Time, frame numbers and the send
   interval come in as plain integers. It lives in `MoshTerminal` because it writes cells,
   and only code in `MoshTerminal` can (`Framebuffer.rows` and `Row.cells` are
   `internal(set)`, `makeRowUnique` is internal: Framebuffer.swift:82, Cell.swift:170).
2. **`MoshSession` wires it**, as stmclient does (stc:267-334, 418): it imports both
   `MoshTransport` and `MoshTerminal` (Package.swift:40-42), which do not import each other.
   Two small reads are added to `MoshConnection`: the last sent state number taken in the
   same actor turn as the bytes are appended, and the acknowledged number, send interval and
   newest remote state in one call.
3. **A predicted frame reaches the surface as a new event `.display(DisplayFrame)`**, the
   remote framebuffer with the predictions drawn. `.screen` keeps its meaning (once per
   remote state, remote only), and so do `screen()`, `exportState()`, the snapshot, the
   clipboard policy and the bell. A prediction never enters stored or exported state.
4. **Proof is differential**: a new mode `mosh-oracle predict` links mosh's own
   `terminaloverlay.o`, gets its time from the command stream (its own
   `Network::timestamp()`), and prints the engine's whole state and the shown frame after
   every step. A seeded generator feeds the same steps to mosh and to the port; every dump
   must be equal.
5. **Live proof**: `moshcli --predict MODE` and `--delay-ms MS` (a client-side delay in
   `WireTap`), new script commands that read the shown frame, and `scripts/itest.sh predict`
   against the real `mosh-server`.

What does not change: the transport's numbers, sends and timers (N1-N4 are not touched: the
engine only reads numbers), `DurabilityGate`, the snapshot format and `docs/RESUME.md`
invariants C1-C13, `.screen` events, `screen()`, `TerminalRemoteState`, `SurfaceFeed`,
`DisplayDiff`. With the display mode `never` (the package default, 2.4) the session behaves
exactly as today: no `.display` event is ever sent.

Not ported: mosh's `NotificationEngine` (the blue bar on row 0) and `TitleEngine` (the
`[mosh] ` title prefix). They are separate overlays in `OverlayManager::apply`
(toc:333-340) and do not touch prediction state (spec 2.7, 2.8); the app has its own banner
(docs/research/03-mosh-terminal.md:505). Deviation D1 in section 3.3 says what that changes.

## 2. The Swift design

### 2.1 Modules

| Module | Gets | Imports |
|---|---|---|
| `MoshTerminal` | `PredictionEngine`, the overlay types, `PredictionSettings`, `PredictionDisplay`, one internal cell-write helper on `Framebuffer`, an internal dump for tests | Foundation only, as now |
| `MoshTransport` | `MoshConnection.typeNotingLastSent(_:)`, `MoshConnection.predictionReadings()`, two small structs | unchanged (`MoshCrypto`, `MoshWire`) |
| `MoshSession` | the engine instance, the shown frame, the render step, the 50 ms timer, `DisplayFrame`, `SessionEvent.display`, settings API | unchanged (both) |
| `MoshResume` | `ResumeCoordinator` passes settings and the new event through | unchanged |
| `moshcli` | options and script commands (section 6) | unchanged |

### 2.2 MoshTerminal: types

File `Sources/MoshTerminal/Prediction.swift` (overlay types and engine; about 650 lines,
the size of toc) and `Sources/MoshTerminal/PredictionDump.swift` (internal, tests only).

```swift
/// mosh `PredictionEngine::DisplayPreference` (toh:253-258); names as MOSH_PREDICTION_DISPLAY (sth:109-125).
public enum PredictionDisplay: String, CaseIterable, Sendable {
    case always, never, adaptive, experimental
}

public struct PredictionSettings: Equatable, Sendable {
    public var display: PredictionDisplay          // mosh default .adaptive (toh:261)
    public var overwrite: Bool                     // MOSH_PREDICTION_OVERWRITE == "yes" (sth:121-124)
    public init(display: PredictionDisplay = .adaptive, overwrite: Bool = false)
    public static let off = PredictionSettings(display: .never)
}

/// toh:52-58.
enum PredictionValidity: Sendable { case pending, correct, correctNoCredit, incorrectOrExpired, inactive }

/// toh:60-95. mosh's base class ConditionalOverlay is folded into both structs (same fields).
struct ConditionalCursorMove: Equatable, Sendable {
    var expirationFrame: UInt64
    var col: Int
    var active: Bool = false                      // toh:70
    var tentativeUntilEpoch: UInt64
    var predictionTime: UInt64 = .max              // toh:71
    var row: Int
    init(expirationFrame: UInt64, row: Int, col: Int, tentativeUntilEpoch: UInt64)
    func tentative(_ confirmedEpoch: UInt64) -> Bool                     // toh:76
    mutating func reset()                                                 // toh:77
    mutating func expire(_ exp: UInt64, now: UInt64)                      // toh:78-81
    func validity(_ fb: Framebuffer, lateAck: UInt64) -> PredictionValidity   // toc:116-139
    func apply(_ fb: inout Framebuffer, confirmedEpoch: UInt64)           // toc:141-157
}

/// toh:97-125.
struct ConditionalOverlayCell: Equatable, Sendable {
    var expirationFrame: UInt64, col: Int, active = false, tentativeUntilEpoch: UInt64, predictionTime: UInt64 = .max
    var replacement = Cell(backgroundColor: 0)     // Cell(0), toh:110
    var unknown = false
    var originalContents: [Cell] = []
    mutating func reset()                          // toh:115: replacement NOT cleared
    mutating func resetWithOrig()                  // toh:116-124
    func validity(_ fb: Framebuffer, row: Int, lateAck: UInt64) -> PredictionValidity   // toc:74-114
    func apply(_ fb: inout Framebuffer, confirmedEpoch: UInt64, row: Int, flag: Bool)   // toc:43-72
}

/// toh:127-137.
struct ConditionalOverlayRow: Equatable, Sendable {
    var rowNum: Int
    var cells: [ConditionalOverlayCell]
}

public struct PredictionEngine: Equatable, Sendable {
    // toh:203-213: all `static const uint64_t` in mosh, so every comparison with them is on UInt64
    static let srttTriggerLow: UInt64 = 20, srttTriggerHigh: UInt64 = 30
    static let flagTriggerLow: UInt64 = 50, flagTriggerHigh: UInt64 = 80
    static let glitchThreshold: UInt64 = 250, glitchRepairCount: UInt64 = 10
    static let glitchRepairMinInterval: UInt64 = 150, glitchFlagThreshold: UInt64 = 5000
    /// stc:325: a read longer than this is a paste.
    public static let pasteThreshold = 100

    public init(settings: PredictionSettings = PredictionSettings())       // toh:294-307
    public private(set) var settings: PredictionSettings

    public mutating func setDisplayPreference(_ display: PredictionDisplay)  // toh:272
    public mutating func setPredictOverwrite(_ on: Bool)                     // toh:273
    public mutating func setLocalFrameSent(_ n: UInt64)                      // toh:281
    public mutating func setLocalFrameAcked(_ n: UInt64)                     // toh:282
    public mutating func setLocalFrameLateAcked(_ n: UInt64)                 // toh:283
    public mutating func setSendInterval(_ ms: UInt32)                       // toh:285 (unsigned int)

    public mutating func newUserByte(_ byte: UInt8, _ fb: Framebuffer, now: UInt64)   // toc:652-862
    public mutating func cull(_ fb: Framebuffer, now: UInt64)                         // toc:440-626
    public func apply(_ fb: inout Framebuffer)                                        // toc:356-376 (const)
    public mutating func reset()                                                      // toc:410-417
    public func waitTime() -> Int                                                     // toh:287-292
    public var isActive: Bool { get }                                                 // toc:913-932

    /// stc:322-334 without the escape-key logic: setLocalFrameSent(lastSent), then a paste
    /// (count > 100) resets, otherwise newUserByte per byte, all with the same fb and now.
    public mutating func newUserRead(_ bytes: [UInt8], lastSent: UInt64, _ fb: Framebuffer, now: UInt64)
    /// stc:274-277 without notifications and title: a copy of `remote`, culled, then drawn on.
    public mutating func overlay(_ remote: Framebuffer, now: UInt64) -> Framebuffer
}
```

Private engine state, field for field toh:215-262, with the same initial values (spec 2.6):
`lastByte: UInt8 = 0`, `parser = UTF8Parser()`, `overlays: [ConditionalOverlayRow]`,
`cursors: [ConditionalCursorMove]`, `localFrameSent/Acked/LateAcked: UInt64 = 0`,
`predictionEpoch: UInt64 = 1`, `confirmedEpoch: UInt64 = 0`, `flagging = false`,
`srttTrigger = false`, `glitchTrigger: UInt32 = 0`, `lastQuickConfirmation: UInt64 = 0`,
`sendInterval: UInt32 = 250`, `lastHeight = 0, lastWidth = 0`. Private methods as mosh:
`getOrMakeRow`, `becomeTentative`, `newlineCarriageReturn(fb, now)`, `killEpoch(_:fb)`,
`initCursor(fb)`, `cursor` (last element; mosh asserts non-empty, toh:242),
`timingTestsNecessary`.

Rules of the port, binding for the implementer:

- **Unsigned arithmetic as in C++.** Every `uint64_t` subtraction in toc is `&-` on
  `UInt64` (quirk 17: `now - 150` wraps for `now < 150`, toc:556; `now - UINT64_MAX` gives
  `now + 1`, toc:555, 577). Comparisons mixing `int` constants with `uint64_t` are done on
  `UInt64`, as C++'s usual conversions do.
- **List order is array order**, and the loops of `cull` and `kill_epoch` run by index over
  the arrays as they are at that moment, with erasure where mosh erases (toc:482-486,
  380-387, 618-625). `kill_epoch` called inside the row loop of `cull` (toc:507) resets
  cells of every row, including the current row and cells already visited; the loop then
  continues with the next cell (toc:508). **[!]**
- **`wcwidth` is `WCWidth.wcwidth`** (WCWidth.swift:16), the glibc 2.39 table, *without* the
  ISO 8859-1 shortcut the emulator adds (toc:746 calls `wcwidth` directly; seams 11).
- **The engine's parser is `UTF8Parser`** (Parser.swift:421-540), the same port of mosh's
  `Parser::UTF8Parser` the emulator uses; only actions of kind `.print`, `.execute`,
  `.escDispatch`, `.csiDispatch` are acted on (toc:685-860), with `ParserAction.ch`.
- **Cell helpers are the existing ones**: `Cell.isBlank`, `contentsMatch`, `==`
  (synthesized, the five fields of tfb:114-121), `Cell.appendUTF8` for `append`
  (tfb:170-182), `contents = []` for `clear()` (tfb:131).
- **Cursor writes are `DrawState.moveRow(_, relative: false)` and
  `moveCol(_, relative: false, implicit: false)`** (DrawState.swift:131-166, which match
  tfbc:134-168 line for line; checked).
- **Cell writes** go through one new internal helper
  `Framebuffer.withMutableCell(_ row: Int, _ col: Int, _ body: (inout Cell) -> Void)`
  built on `makeRowUnique` (Framebuffer.swift:82): mosh's `get_mutable_cell`, a copy of the
  row that keeps its generation (Cell.swift:181-184), as mosh's copy-on-write row does. Rows
  of the transport's held states are never uniquely referenced, so an overlay never reaches
  a remote state (seams 1; Framebuffer.swift copy-on-write). **[!]**
- **Asserts.** mosh's bound asserts in the engine (toc:151-152, 751-754, toh:242) become
  `assert` (debug builds trap; the fuzz runs in debug); D3 in 3.3 says what release builds
  do. The origin-mode assert (toc:153) is **not** ported as an assert in any build: a
  server can set DECOM, and moshcli, the package tests and a Debug app are debug builds
  (D2).

### 2.3 MoshTransport: two reads

In `TransportTypes.swift`:

```swift
public struct TypeReceipt: Sendable, Equatable {
    public var accepted: Bool
    /// `lastSentStateNumber` read before the bytes were appended: mosh's
    /// set_local_frame_sent( get_sent_state_last() ) (stc:322, tsh:154).
    public var lastSentStateNumber: UInt64
}

public struct SenderReadings: Sendable, Equatable {
    public var acknowledgedStateNumber: UInt64   // get_sent_state_acked() (stc:298, tsh:153)
    public var sendInterval: UInt32              // send_interval() (stc:299, tsi:73-83)
}
```

In `MoshConnection` (an actor, MoshConnection.swift:68):

```swift
/// type(_:) with the number mosh reads first. One actor turn: read, append, pump.
public func typeNotingLastSent(_ bytes: [UInt8]) -> TypeReceipt
/// What stmclient reads after every recv (stc:298-300), in one turn.
public func predictionReadings() -> (sender: SenderReadings, newest: NumberedRemoteState<Remote>)
```

`type(_:)` becomes `typeNotingLastSent(bytes).accepted`. The number is
`core.lastSentStateNumber` (TransportCore.swift:892); the interval is
`core.rtt.sendInterval` (RTTEstimator.swift:54-57: `ceil(SRTT/2)` within 20...250, the
formula of tsi:73-83), narrowed to `UInt32` (it is at most 250). The read must come before
`core.type(bytes)` in the same turn, because `type` can send at once (seams 2, "Timing of
the reads"; MoshConnection.swift:268-272, 417-425) and a later read would see the number of
the state that carries the bytes.

### 2.4 MoshSession: state and API

```swift
public struct DisplayFrame: Equatable, Sendable {   // SessionEvent is Equatable (SessionTypes.swift:59)
    public let serial: UInt64            // 1, 2, 3 ... per session, one per .display event
    public let number: UInt64            // the remote state the frame is drawn on
    public let framebuffer: Framebuffer  // the remote framebuffer with the predictions drawn
    public let hasPredictions: Bool      // framebuffer != the remote framebuffer
}

public enum SessionEvent { ...; case display(DisplayFrame) }   // new case

// MoshSession, every initializer:
    prediction: PredictionSettings = .off,
public func setPrediction(_ settings: PredictionSettings)   // set_display_preference + set_predict_overwrite, then render
public func predictionSettings() -> PredictionSettings
public func displayedScreen() -> Framebuffer               // the shown frame (moshcli, tests)
```

New private state of the actor: `engine: PredictionEngine`, `shown: Framebuffer` (mosh's
`local_framebuffer`), `latest: (number: UInt64, framebuffer: Framebuffer)` (the newest
remote state this actor has read; it only moves forward, 4.3), `displaySerial: UInt64`,
`lastDisplayed: (number: UInt64, framebuffer: Framebuffer)?`,
`predictionTimer: Task<Void, Never>?`, `quiesced: Bool` and `ended: Bool` (4.6; MoshSession
has no synchronous quiesce state today, MoshSession.swift:36-50, 221-228), and `clock: any MonotonicClock` (the session already
takes the clock and hands it on, MoshSession.swift:81, 127; it now keeps a reference too;
the bootstrap initializer gets a `clock:` parameter with the same default).

The package default is `.off` (display `never`), not mosh's `adaptive`: every existing
caller (moshcli, the tests, the app before its M10 change) keeps today's behaviour, and the
app sets the user's choice, whose default is `adaptive` (section 5). This is D5.

### 2.5 The clock

mosh's engine reads `Network::timestamp()`, a millisecond value frozen once per main-loop
pass (spec 4; util/select.h:187, util/timestamp.cc:61-130). The port takes `now: UInt64`
(milliseconds) on every entry that reads time (`cull`, `newUserByte`, and through them
`newlineCarriageReturn`, toc:453, 663, 866). The session reads
`clock.nowMilliseconds()` (MoshConnection.swift:6-9) **once per entry** (one `type` call,
one render) and passes the same value to every byte of that read, so all engine calls of
one step see one time, as mosh's frozen time gives. The same clock drives the transport,
so `prediction_time` ages and the send interval share a time base. The 50 ms wake
(`waitTime`) is a real-time `Task.sleep`; it only decides *when* the next render happens,
and the render reads the clock.

### 2.6 Actor rules

1. The engine, `shown` and `latest` are touched only inside `MoshSession`'s actor, and
   only in **synchronous** sections: each entry point does at most one `await` on the
   connection first (to get numbers or to hand over bytes), then reads the clock, feeds the
   engine, renders and yields, with no suspension in between. So no two engine steps
   interleave, and a frame is never rendered from half-updated inputs.
2. Reentrancy across that one `await` is allowed and matches mosh's order: a state event
   handled while `type` waits on the connection is applied first, as mosh handles network
   input before user input in one loop pass (stc:480-484). The echo of the bytes being
   typed cannot be judged in that gap: a guess is judged only when the echo ack reaches its
   state, and the server sets the echo ack only after holding the state 50 ms
   (statesync/completeterminal.cc:138, completeterminal.h:60).
3. The engine is a value: no reference to it leaves the actor. `.display` carries a copy of
   a frame.

## 3. Port map

### 3.1 Functions

Every function and rule of the spec, against the Swift that holds it. "Same" means a
statement-by-statement translation with no change of order or condition.

| mosh (spec section) | Swift | Notes |
|---|---|---|
| `Validity` (2.1, toh:52-58) | `PredictionValidity` | same |
| `ConditionalOverlay` ctor, `tentative`, `reset`, `expire` (2.2, toh:60-82) | fields and methods on both structs | same; `reset` leaves `col`, `predictionTime` (toh:77) |
| `ConditionalCursorMove` ctor (2.3, toh:84-95) | `ConditionalCursorMove.init` | inactive, `predictionTime = .max` until a caller sets `active` |
| `ConditionalCursorMove::get_validity` (toc:116-139) | `.validity(_:lateAck:)` | `early_ack` unused in mosh (toc:117), so not passed (quirk 23). Order of the four tests same |
| `ConditionalCursorMove::apply` (toc:141-157) | `.apply(_:confirmedEpoch:)` | asserts: D2 |
| `ConditionalOverlayCell` ctor, `reset`, `reset_with_orig` (2.4, toh:97-125) | `ConditionalOverlayCell` | `reset` does not clear `replacement` (quirk 5) **[!]** |
| `ConditionalOverlayCell::get_validity` (toc:74-114) | `.validity(_:row:lateAck:)` | seven tests in mosh's order; `contentsMatch` on bytes |
| `ConditionalOverlayCell::apply` (toc:43-72; spec 8) | `.apply(_:confirmedEpoch:row:flag:)` | blank-on-blank clears `flag`; unknown: underline unless last column; else full `!=` then write and underline (checked against toc:43-72) **[!]** |
| `ConditionalOverlayRow::apply` (toc:347-354) | loop inside `PredictionEngine.apply` | column order |
| `get_or_make_row` (toc:628-650) | `getOrMakeRow(_ rowNum:, _ width:) -> Int` (index) | first match by `rowNum`; new row of `width` cells `(0, i, predictionEpoch)` appended |
| `PredictionEngine` ctor (toh:294-307) | `init(settings:)` | initial values of 2.2 |
| `set_display_preference`, `set_predict_overwrite` (toh:272-273) | same names | plain stores |
| `set_local_frame_sent/acked/late_acked`, `set_send_interval` (toh:281-285) | same names | plain stores |
| `wait_time` (toh:287-292) | `waitTime()` | 50 or `Int(Int32.max)` (mosh `INT_MAX`), so dumps compare as numbers |
| `timing_tests_necessary` (toh:266-269) | private | `!(glitchTrigger > 0 && flagging)` |
| `active` (toc:913-932) | `isActive` | same |
| `become_tentative` (toc:901-911) | private | no-op in experimental |
| `kill_epoch` (toc:378-408; spec 5.3) | private `killEpoch(_:fb)` | four steps, same order; new cursor `(localFrameSent + 1, fb cursor)` **[!]** |
| `reset` (toc:410-417; spec 10.1) | `reset()` | clears `cursors`, `overlays`, then `becomeTentative()`; keeps parser, `lastByte`, triggers |
| `init_cursor` (toc:419-438; spec 6.2) | private `initCursor(fb)` | three cases |
| `cull` (toc:440-626; spec 7) | `cull(_:now:)` | nine steps, early returns at toc:442, 532, 611 **[!]** |
| `new_user_byte` (toc:652-862; spec 6.1, 6.4) | `newUserByte(_:_:now:)` | preamble order: never-return, experimental epoch, cull, now, `ESC O` rewrite, `lastByte`, parse **[!]** |
| printable prediction (toc:750-830; spec 6.5) | inside `newUserByte` | last column tentative; insert-shift loop descending; typed cell renditions from pen or left neighbour; advance or wrap **[!]** |
| backspace (toc:698-744; spec 6.5) | inside `newUserByte` | `getOrMakeRow` even at col 0 (quirk 22); overwrite uses `fb.getCell()` = the frame cursor's cell (quirk 3); insert loop ascending with `i + 2 < W` (quirk 4) **[!]** |
| unknown print (toc:746-748) | inside `newUserByte` | `ch < 0x20 \|\| wcwidth(ch) != 1` → tentative after `initCursor` |
| `Execute` CR / other, `Esc_Dispatch`, `CSI_Dispatch` C/D/other (toc:832-859) | inside `newUserByte` | CSI parameters ignored (quirk 8) |
| `newline_carriage_return` (toc:864-899; spec 6.6) | private `newlineCarriageReturn(_:now:)` | no `expire` of the cursor (quirk 7); blank last row in place with `contents = []` only (quirk 6) **[!]** |
| `PredictionEngine::apply` (toc:356-376; spec 8) | `apply(_:)` | trigger test, cursors in order, rows in order |
| `OverlayManager::apply` (toc:333-340) | `overlay(_:now:)` | `cull` then `apply`; notifications and title not ported (D1) |
| stmclient `process_user_input` (stc:303-398; spec 9.2) | `newUserRead` + `MoshSession.type` | one `type` call is one `read()`; paste rule; refused input (shutdown, stc:319-321) does not reach the engine |
| stmclient `process_network_input` (stc:290-301; spec 9.3) | `MoshSession` on `.contact` and `.remoteStateAdvanced` | the three setters, in mosh's order |
| stmclient `output_new_frame` (stc:267-288; spec 9.5) | `MoshSession.render(now:)` | copy of remote, `overlay`, shown := result, `.display` |
| stmclient `process_resize` (stc:400-421) | `MoshSession.resize` | `reset()` after the resize is handed to the connection (stc:418) |
| stmclient `main_init` local framebuffer (stc:245) | `MoshSession.shown` initial value | D6 |
| `STMClient` mode parsing (sth:109-125), mosh.pl `--predict` (mosh.pl:143-193) | `PredictionDisplay(rawValue:)`, moshcli `--predict` | unknown name: moshcli exits 2 with a usage error (mosh exits 1, sth:116-119); the app has a picker, no strings |
| `Cell::is_blank`, `contents_match`, `==`, `clear`, `append` (tfb:114-182) | existing `Cell` API | already ported and proved by the corpus |
| `DrawState::move_row`, `move_col` (tfbc:134-168) | existing `DrawState.moveRow`, `moveCol` | checked equal |
| `Renditions::set_attribute(underlined)` | existing `Renditions.setAttribute(.underlined, true)` (Renditions.swift:120) | |
| `fb.ds.get_renditions()` (toc:797) | `fb.ds.renditions` (DrawState.swift:64, readable) | the shown frame's pen |
| `UTF8Parser`, X.364 parser (spec 6.3) | existing `UTF8Parser` | the engine owns its own instance |

### 3.2 The quirks of spec 11

All 25 are reproduced; none is "fixed". Each has a named differential case (7.3). Those
that depend on wiring rather than on the engine:

- Quirk 1 (keystroke judged against the stale shown frame) and quirk 24 (`kill_epoch`'s
  cursor from the shown frame): `newUserRead` gets `shown`, never the remote frame
  (stc:334; seams fact 2). In the session a new remote state is rendered as soon as its
  event is handled, so the stale-frame case needs a state and a keystroke in the same mosh
  loop pass; the session produces only schedules in which they fell into consecutive
  passes, which mosh also produces. The engine is still tested on both schedules (7.3).
- Quirk 2 (originals and neighbours from the shown frame): the same `shown`.
- Quirk 11 (a paste leaves the parser mid-sequence) and 25 (one `local_frame_sent` per
  read): `newUserRead`.
- Quirk 12 (escape key bytes predicted): the app has no escape key; nothing to do.

### 3.3 Deviations

| # | What | Why |
|---|---|---|
| D1 | No notification bar and no title prefix in the shown frame | The app shows its own banner (research 03:505) and the surface carries no title (SurfaceFeed.swift:42-43). Effect on prediction: in mosh, while the bar is up (6.5 s without contact, or a message), row 0 of the shown frame holds the bar, and guesses on row 0 copy neighbours and originals from it (quirk 2) and the bar covers guesses there (spec 2.7). The port sees the remote row 0. Identical whenever mosh's bar is not shown; the oracle drives `PredictionEngine` directly, without the bar, so the differential test compares like with like |
| D2 | `assert(!fb.ds.origin_mode)` in `ConditionalCursorMove::apply` (toc:153) is not ported as an assert, in debug or release | mosh-client aborts (asserts are live in 1.4.0 builds, stage2/DESIGN.md conventions). An app must not crash on a server's DECOM, and moshcli in itest, the package tests and a Debug app on the phone are debug builds, where an `assert` would trap. Every build does what mosh does after the assert: `moveRow(row)` and `moveCol(col)`, which in origin mode count from the scroll region top. The generator keeps DECOM off (7.2) so the oracle never aborts; a unit test pins the behaviour |
| D3 | The bound asserts (toc:151-152, 751-754; toh:242) | `assert` in debug. In release a failing check skips only the action it guards and the step goes on: in `ConditionalCursorMove.apply` the cursor is not moved; in the printable branch of `newUserByte` (toc:751-754) the byte is not predicted, while what already happened stays (the parser consumed it, `lastByte` is set, the preamble's cull ran), and the loop goes on with the next parser action; `cursor` on an empty list (toh:242) calls `initCursor` first. No out-of-range index in any build. The fuzz runs in debug and would trap; by the arguments in mosh they cannot fire (the cursor is clamped by `cull`'s size reset and the advance rules) |
| D4 | Reads above 16384 bytes are not split (stc:305-309) | One `type` call is one read whatever its length, and any read over 100 bytes resets and is not predicted. mosh reads at most 16384 bytes per `read`, so a 16450-byte paste can be read as 16384 + 66 and the 66 are predicted (stc:325-334); the port predicts none of it. Deliberate: where mosh splits depends on what the pty's `read` returns, which mosh does not control either, and predicting the tail of a paste is not a behaviour worth copying. Not reachable in the differential (the oracle's `read` command is one read too) |
| D5 | Package default display mode `never` | Keeps every existing caller unchanged. The app's default is mosh's `adaptive` |
| D6 | The first shown frame is the newest remote state's framebuffer (state 0 of `serverStartSize`, or the stored screen after a restore), not a blank frame of the window size (stc:245) | Equal for a new session whose server size equals the view size, the normal case. After a restore the stored screen is what the user sees, so predictions are made on it, as mosh would after its first frame |

Not a deviation, but worth knowing: after an import (cold start), state numbers restart at
the reserved limit (docs/RESUME.md R2), while the sender starts with only the front
(TransportCore.swift:217). The first read after a cold start therefore gets
`localFrameSent + 1 = front + 1`, below the number the state will really get, exactly as
mosh's rule computes it. If the server still holds states above the front, its echo ack
already passes `front + 1` and that first read's guesses are judged at once: they are
tentative (a fresh engine has `confirmedEpoch = 0`), so they are dropped, never drawn. From
the first new state on, `lastSentStateNumber` is right again. A burned state number
(TransportCore.swift:599-602) is harmless: the server never sees it, so its echo ack jumps
past it only when it has had the next state 50 ms, which is the state carrying the bytes.

## 4. Wiring in MoshSession

### 4.1 Render: mosh's `output_new_frame`

```swift
private func render(now: UInt64) {           // synchronous
    guard started, !closed else { return }
    let frame = engine.overlay(latest.framebuffer, now: now)   // copy, cull, apply (stc:274-277)
    shown = frame                                              // stc:287
    emitDisplay(frame)
    armPredictionTimer()
}
```

`emitDisplay`: while `settings.display != .never`, yield `.display` when `frame` differs
(structural `==`) from `lastDisplayed.framebuffer` **or** `latest.number` differs from
`lastDisplayed.number`, with the next serial, `number = latest.number`,
`hasPredictions = frame != latest.framebuffer`. So every new remote state gets its
`.display`, also one whose overlaid frame equals the previous one: a server state that
changes only the echo ack has the same framebuffer (`Complete::operator==` includes
`echo_ack`, statesync/completeterminal.cc:124-128, 130-158), and pending guesses stay drawn
on top of an echo until the echo ack arrives 50 ms later (toc:90-92). After a switch to
`never`, one more `.display` whose framebuffer is the remote one (so the app drops what was
drawn), then `lastDisplayed = nil` and no more. Within one remote state the skip of an
unchanged frame matches mosh's `Display::new_frame`, which writes nothing for it
(stc:280-283); the app draws only `.display` while the mode is not `never` (5 item 2), so a
`.screen` never replaces a drawn guess.

`armPredictionTimer`: cancel the old task; no timer when `quiesced`, `ended` or `closed`.
Otherwise, if `engine.waitTime()` is 50 (mosh's loop waits at most that, stc:444), a task
sleeps 50 ms real time and then calls `render(now: clock.nowMilliseconds())` on the actor;
if `waitTime()` is `INT_MAX` but `engine.isActive`, the same with 250 ms; else no timer. The
50 ms timer is what moves `glitch_trigger` on a guess that stays pending (toc:576-586) and so
turns on display in adaptive mode within 50 ms of the 250 ms mark, as in mosh. The 250 ms
timer stands in for mosh's loop passes on `network->wait_time()` (stc:441-444): mosh culls
on every pass, including the retransmit and ack passes during a stall, so a guess pending
5000 ms sets `glitch_trigger = 20` (toc:579-580) even while `wait_time()` is `INT_MAX`
(`glitch_trigger && flagging`, toh:266-269, 287-292). An extra cull is a schedule mosh also
produces (any pass culls; a second cull with unchanged inputs judges nothing new).

### 4.2 On input

```swift
public func type(_ bytes: [UInt8]) async -> Bool {
    let receipt = await connection.typeNotingLastSent(bytes)
    guard receipt.accepted else { return false }               // stc:319-321: engine untouched
    let now = clock.nowMilliseconds()
    engine.newUserRead(bytes, lastSent: receipt.lastSentStateNumber, shown, now: now)  // stc:322-334
    render(now: now)
    return true
}
```

The engine sees the bytes after the connection has them; nothing in the engine depends on
that order except `lastSent`, which was read before the append (2.3). The paste rule runs in
every mode, as in mosh (stc:325-328 is outside the mode test; `reset` with `never` is
harmless).

### 4.3 On a new server state and on contact

Both `.contact` and `.transport(.remoteStateAdvanced)` (MoshSession.swift:337-344) do:

```swift
let r = await connection.predictionReadings()
guard r.newest.number >= latest.number else { return }         // a newer reading was applied while this one waited
engine.setLocalFrameAcked(r.sender.acknowledgedStateNumber)     // stc:298
engine.setSendInterval(r.sender.sendInterval)                   // stc:299
engine.setLocalFrameLateAcked(r.newest.state.echoAck)           // stc:300 (TerminalRemoteState.swift:85-87)
latest = (r.newest.number, r.newest.state.framebuffer)
// remoteStateAdvanced only: the existing reportNewestScreen body, fed from r.newest (yield .screen, clipboard)
render(now: clock.nowMilliseconds())
```

`reportNewestScreen` (MoshSession.swift:372-379) uses `r.newest` instead of its own
`newestRemoteState()` call, so one await serves both, and its duplicate guard becomes
`newest.number <= last` (today `==`, :374), so a handler that resumes after a newer state was
reported cannot yield an older `.screen`. Order of events from the reader: `.screen` (if the
number is new), then `.display`. The setters, `latest` and the frame always come from one
reading, as in mosh, where the setters (stc:298-300) and the next pass's frame (stc:274) read
the same newest state.

`exportState()` (MoshSession.swift:249-263) keeps its `.screen` and clipboard step but does
**not** set `latest` and does not render: it runs after `quiesce()`, when nothing is drawn,
and its export carries no sender readings, so a render there would pair a frame with an
older `late_ack` than mosh ever has. The state's own event, still in the stream, brings
`latest` and the `.display` later (or `resume()` does, 4.6).

### 4.4 On resize

`resize` awaits `connection.resize(size)`, then `engine.reset()` and `render` (stc:418). The
new size reaches `cull` with the server's next frame, which resets again (toc:446-451), as
in mosh.

### 4.5 On a transport tick

The transport's own timers (sends, acks, retransmissions) do not render: in mosh they change
nothing the engine reads except through a received datagram, which arrives here as
`.contact`. What their loop passes do in mosh besides, a cull at a later time, is done by the
timers of 4.1 (50 ms, or 250 ms while a guess is active and `waitTime()` is `INT_MAX`).

### 4.6 Quiesce, resume, cold start, close

- `quiesce()` and `quiesceAfterSend()`: set `quiesced = true` *before* the await on the
  connection, cancel the timer; the engine and `shown` stay. `render` still runs while
  quiesced (an event may still arrive) but `armPredictionTimer` arms nothing, so no timer
  wakes the process in the background. Nothing is sent while quiesced, so no ack can judge
  a guess; mosh has no equivalent (seams 5), and the nearest case, a client whose network
  stops, keeps its guesses. (Open question 4.)
- `resume()`: after `connection.resume()`, `quiesced = false`, then one
  `predictionReadings()` applied as in 4.3, then `render` with a fresh `now`. Pending guesses are
  now old, so the first cull may set `glitch_trigger` to 10 or 20 (toc:579-583): in mosh too
  a long stall makes guesses show, underlined.
- Cold start (`init(restoring:)`): a fresh `PredictionEngine(settings:)`, `latest` and
  `shown` from the snapshot's newest remote state, synchronously in the initializer.
  `start()` yields the stored screen (`isLive` false, MoshSession.swift:172-176) and then
  renders: the first cull sees size 0x0 and resets (toc:446-451), so the first `.display`
  has no predictions.
- `close()`: cancel the timer.
- End of the session (`.serverEnded`, `.shutdownFinished`, `.halted`, `.baseStateLost`,
  MoshSession.swift:345-357): no echo ack will come, so before the event is yielded:
  `ended = true`, `engine.reset()`, one `render` (the last `.display` is the remote frame,
  with no guess), timer cancelled. mosh-client exits at that point, so it shows no guess
  afterwards either.

### 4.7 How a frame reaches the surface

`.display(DisplayFrame)` goes through the session's one event stream, after the `.screen`
of the same number. `ResumeCoordinator` forwards it as it forwards every session event
(ResumeCoordinator.swift:173-176, 712-722). The app feeds `framebuffer` to
`SurfaceFeed.feed(to:)` (SurfaceFeed.swift:98-111); any frame may follow any shown one (its
rule 6), and an overlaid row keeps its generation, so `DisplayDiff`'s identity and scroll
tests (DisplayDiff.swift:175-196, 394) behave as for mosh's overlaid copy.

### 4.8 What never contains a prediction

| Output | Source | Why it is clean |
|---|---|---|
| `.screen(ScreenUpdate)`, `screen()` | `connection.newestRemoteState()` | unchanged code; the overlay writes only to a copy |
| `exportState()`, `SessionSnapshot` | the connection's snapshot and the clipboard policy | the session's engine, `shown`, `latest` are not in `SessionSnapshot` (SessionTypes.swift:109-117) and the snapshot format (RESUME.md:370-425) has no field for them |
| clipboard policy | `ClipboardPolicy.observe` on the remote framebuffer (MoshSession.swift:378) | unchanged; prediction writes no clipboard (toc:43-72, 141-157) |
| bell, mouse mode | `ScreenUpdate.framebuffer` in the app | unchanged; prediction writes no bell count |
| transport input | `connection.type` | the engine only reads |

The remote rows are shared with the transport's held states and are never uniquely
referenced, so `withMutableCell` copies them (2.2). A test proves it (7.4, wiring test 4).

## 5. What the app needs (for the session on the Mac)

1. **API.** `ResumeCoordinator.Options` gains `prediction: PredictionSettings` (default
   `.off`), passed to every `MoshSession` the coordinator makes (new, restored, fallback),
   and `ResumeCoordinator.setPrediction(_:)` forwards to the live session and is kept for the
   next one. Input stays `coordinator.type(bytes)`.
2. **The new event.** `handle(_:from:)` (TerminalViewController.swift:699-703) gets
   `case .display(let frame)`. The controller keeps one "frame to draw" and a serial of its
   own, and `tick()` draws when that serial changed (today it compares
   `newest.number != shownNumber`, TerminalViewController.swift:938, which never sees a
   frame without a new number). **While the mode it set is not `never`, only `.display`
   replaces the frame to draw**; `.screen` replaces it only in `never` mode. Otherwise a
   `.screen` drawn before its `.display` (each event is its own main-actor job,
   TerminalViewController.swift:638-648, and a display-link tick can fall between them)
   shows the remote frame without the guesses for a refresh, on every server state. As in
   mosh, only the overlaid frame ever reaches the screen while prediction is on
   (stc:274-287). Bell, mouse mode, `lastContact` stay on `.screen` in every mode. Until this change is made the app must at
   least have `case .display: break`, because the switch is exhaustive: that one line goes in
   the same commit as the event (step 6 of section 8).
3. **The setting.** "Local echo", per host in the host editor (as mosh's `--predict` is per
   connection; open question 2), with mosh's four modes and mosh's words: Adaptive (default:
   shown only on a slow or glitchy link), Always, Never, Experimental; and "Overwrite
   instead of insert" (`--predict-overwrite`). Changing it on a live session calls
   `setPrediction`.
4. **Underline of unconfirmed cells.** Nothing to build: when `flagging` is on (send
   interval above 80 ms, about SRTT above 160 ms, or a long glitch; toc:465-474) the engine
   sets the underline attribute in the frame itself (toc:59-71), and SwiftTerm draws it
   from the SGR the surface feed emits. A predicted underline looks like a real one, as in
   mosh.
5. **Paste.** mosh's rule is "one read over 100 bytes". Check on the Mac that a paste
   through SwiftTerm's `pasteText` (TerminalSurface.swift:168-169) reaches `coordinator.type`
   as one array (seams 4 left this open). If it arrives in pieces of 100 or fewer, the
   pieces are predicted, which mosh would not do.
6. **Phone check** (PLAN.md:849): needs a slow link. moshcli's delay does not exist on the
   phone; use `scripts/netem.sh` on yellow (delay on the server's side) with the phone
   connected over Tailscale.

## 6. moshcli and scripts/itest.sh predict

### 6.1 Options (`SessionTuning`, SessionOptions.swift:84-114; so `connect`, `soak`, `bootstrap` get them)

- `--predict MODE`: `always`, `never`, `adaptive`, `experimental` (mosh.pl:157-161). Default
  `never`. Unknown values are a usage error (mosh.pl:143-153 rejects them too).
- `--predict-overwrite` (mosh.pl:158).
- `--delay-ms MS` (0...2000): every datagram is held `MS` ms in each direction, in
  `TappedTransport` (WireTap.swift:66-110): `send` queues the datagram with its due time and
  a single task sends them in order; the receive handler does the same before calling the
  session's handler. Order is kept, nothing is dropped, `--loss` still applies (before the
  delay). The round trip grows by `2 * MS`, so `--delay-ms 150` is the plan's 300 ms link.
  `close()` cancels the delay task and empties both queues before it returns: the
  `DatagramTransport` contract allows no handler call and no send after `close()`
  (DatagramTransport.swift:27-36), which `MoshConnection` relies on for replaced sockets
  and quiesce.

### 6.2 Script commands (ScriptCommand.swift:55-191)

- `expect-display TEXT MS`: like `expect-screen` but on `displayedScreen()`.
- `expect-predicted TEXT MS`: within `MS`, one sample in which the shown frame contains
  TEXT and the remote screen does not. This is the property local echo is for.
- `expect-display-settled MS`: within `MS`, shown frame `==` remote framebuffer (no guess
  left drawn).
- `expect-underlined TEXT MS`: within `MS`, TEXT is in the shown frame and every cell of it
  has the underline attribute.
- `dump-display FILE`: as `dump-screen`, from the shown frame.

`SessionDriver.screen()` (ScriptedSession.swift:76-80) gets a sibling `displayed()` for both
drivers (session and coordinator).

### 6.3 `test_predict` in scripts/itest-mosh.sh (plus the four places in scripts/itest.sh: header, case pattern at :85, `all` at :102, usage at :109)

| Part | Server | moshcli | Proves |
|---|---|---|---|
| a | `sh` | `--predict always --delay-ms 150` | Type `e`, wait for its echo on the remote screen, then `settle 400`: the echo alone does not confirm the epoch; the echo ack that does comes in a later state, at least 50 ms after the server got the input (completeterminal.cc:130-158, completeterminal.h:60), plus 150 ms of delay. Then type `cho hi` one key at a time: `expect-predicted "echo hi" 120` (well under the 300 ms round trip). Return; `expect-screen hi`; `expect-display-settled 2000`. End to end: numbers, echo acks from the real server (ECHO_TIMEOUT), epochs |
| b | `sh` | `--predict adaptive --delay-ms 150` | send interval 150 > 80: `srtt_trigger` and `flagging` on; after the confirming keystroke, `expect-underlined` on the next guess, and the underline goes once echoed (`expect-display-settled`). The send interval reaches the engine |
| c | `sh -c 'stty raw -echo; dd bs=1 count=1 2>/dev/null; cat >/dev/null'` | `--predict always --delay-ms 150` | Guesses with no echo vanish once judged. A fresh engine's epoch 1 is tentative (toh:76, 298-299) and tentative guesses are never drawn (toc:51-53, 147-149), so the program echoes exactly the first byte: type `x`, wait for it on the remote screen, `settle 400` (epoch confirmed, toc:543-544). Then type `abc`: `expect-predicted "abc" 120`, then `expect-display-settled 3000` and the dumped display has no `abc` (judged `IncorrectOrExpired` while not tentative: full `reset()`, toc:528-533). Then `quiesce`, `dump-screen`: the remote screen holds no guess (4.8) |
| d | `sh` | `--predict never --delay-ms 150` | Nothing predicted: during the round trip the display equals the remote screen; no `.display` event (counted by moshcli's event log) |
| e | `sh` | `--predict adaptive` (no delay) | `srtt_trigger` starts on (the send interval is 250 until the first RTT sample, network.cc:248, toc:456-457) and turns off only at 20 ms with no guess active (toc:458-462). After `settle 2000` and a confirmed keystroke, typed keys are never seen predicted on loopback: the trigger's way down works |
| f | `sh` | `--predict always --delay-ms 500` | `replace-socket` while datagrams sit in the delay queue, then `quiesce` and `resume`: no handler call for the old socket after its `close()` and no late send (6.1) |

These prove the wiring against the real server; they do not prove exactness, which is the
differential test's job. `scripts/soak.sh` passes extra arguments to `moshcli soak`
(soak.sh:6, 63), so a soak with `--predict always --delay-ms 50` can show that the remote
screen still equals `tmux capture-pane` with prediction on (the soak compares the remote
screen, which prediction must not touch).

## 7. Tests

### 7.1 The oracle: `mosh-oracle predict`

Built into the existing tool (tools 1.1: `Tools/mosh-oracle` is what the task names, and its
JSON state lines already have a complete Swift reader, `GoldenState`, and comparison,
`CorpusComparison.firstDifference`, CorpusTests.swift:105, 115). Changes:

- `Tools/mosh-oracle/predict.cc` (new): `uint64_t Network::timestamp(void)` returning a
  global set by the `time` command (way A of tools 3: then `network.o` is never pulled, so
  no crypto link; a later duplicate would fail the link, not pick silently), the command
  loop, the engine dump. Compiled with build.sh's flags plus `-I$MOSH_SRC/src/network
  -I$MOSH_SRC/src/crypto` (headers that `terminaloverlay.h` needs, tools 2).
- `build.sh`: link `$MOSH_SRC/src/frontend/terminaloverlay.o` as built for `mosh-client`
  (the very object mosh-client runs; same flags, tools 2) and `predict.o`; fail with a clear
  message if the object is missing.
- `main.cc`: dispatch `predict` to `predict_main()`; `make_dump` (main.cc:558) and
  `full_line` (main.cc:676) are shared (made non-static or declared in a small header).
- `FORMAT.md`: a section "predict" with the grammar below; `README.md`: one line.

Command stream on stdin, one command per line, tokens separated by one space, numbers in
decimal, `HEX` lowercase hex of bytes (may be empty). Each command prints exactly one line
on stdout, so a reply belongs to its command by position. Errors print `{"error":"..."}`
and exit 65.

| Command | Does (mosh source it mirrors) | Reply |
|---|---|---|
| `new W H` | `server = Complete(W, H)`; `shown = Framebuffer(W, H)` (stc:245); `engine = PredictionEngine()` (toh:294) | `{"ok":"new"}` |
| `display NAME` | `set_display_preference` with `always`/`never`/`adaptive`/`experimental` (sth:109-120) | `{"ok":"display"}` |
| `overwrite B` | `set_predict_overwrite(B == 1)` | ok |
| `time MS` | the value `Network::timestamp()` returns from now on; absolute, never relative, so the command log shows the clock | ok |
| `host HEX` | `server.act(bytes)` (the server's terminal; what `apply_string` does) | ok |
| `hostresize W H` | `server.act(Parser::Resize(W, H))` | ok |
| `echoack N` | `server.echo_ack = N` (the field of the newest server state, completeterminal.h:58) | ok |
| `recv ACKED SI` | `set_local_frame_acked(ACKED)`, `set_send_interval(SI)`, `set_local_frame_late_acked(server.get_echo_ack())` (stc:298-300) | ok |
| `read SENT HEX` | `set_local_frame_sent(SENT)`; if `len > 100` `reset()`, else `new_user_byte(b, shown)` per byte (stc:322-334) | ok |
| `frame` | `f = server.get_fb()` (copy); `cull(f)`; `apply(f)`; `shown = f` (stc:274-287 without notifications, title, display) | ok |
| `reset` | `reset()` (stc:418) | ok |
| `dump` | see below | one JSON object |

`dump` prints
`{"dump":K,"engine":E,"shown":S}` where `K` counts dumps from 1, `S` is `null` unless a
`new` or `frame` command came since the previous dump (only those change `shown`, as only
`output_new_frame` writes `local_framebuffer` in mosh, stc:287; a full frame at 132x50 is
some 460 KB, and one after every command would be gigabytes per suite run), and otherwise
`full_line(K, make_dump(wrap))` (FORMAT.md state line, every key) of a `Complete` of
`shown`'s own width and height (after a `hostresize` and a `frame` it is no longer the `new`
size) whose `terminal.fb` is replaced by `shown` (private members are reachable under
`-fno-access-control`; `Complete::terminal` completeterminal.h:48, `Emulator::fb`
terminal.h:64), and `E` is:

```
{"prediction_epoch":"U","confirmed_epoch":"U","flagging":B,"srtt_trigger":B,
 "glitch_trigger":N,"last_quick_confirmation":"U","send_interval":N,
 "last_height":N,"last_width":N,"local_frame_sent":"U","local_frame_acked":"U",
 "local_frame_late_acked":"U","last_byte":N,"parser_state":"NAME","parser_buf":"HEX",
 "display":"NAME","overwrite":B,"active":B,"wait_time":N,
 "cursors":[["U exp",row,col,B active,"U tentative","U prediction_time"],...],
 "overlays":[{"row":R,"cells":[[col,B active,"U exp","U tentative","U prediction_time",
              B unknown,CELL,[CELL,...]],...]},...]}
CELL = {"c":"base64 contents","r":RENDITIONS,"w":B wide,"f":B fallback,"x":B wrap}
```

`"U"` is a `uint64_t` written as a decimal string (values such as `UINT64_MAX` do not fit a
double), `RENDITIONS` is FORMAT.md's pen object (`rend_object`, main.cc:480), `parser_state`
uses `parser_state_name` (main.cc:449). `last_byte` is printed as
`(unsigned char)last_byte`: it is a `char` (toh:215, set from `char the_byte`, toc:652),
signed on x86-64, while the Swift field is `UInt8`; every use in the engine is an equality
with 0x1b or `'O'`, where sign does not matter (main.cc:616 does the same for `utf8_buf`).
FORMAT.md says so. Every cell of every row is dumped, active or not,
because an inactive cell's stale `replacement` still matters (quirk 5).

The Swift side: `Tests/MoshTerminalTests/PredictOracle.swift` (`#if os(Linux)`), modelled on
`MoshRef.swift:48-104`: `XCTSkip` when `$MOSH_SRC/src/frontend/terminaloverlay.o` or the
libraries are missing; otherwise build once per process with `ORACLE_OUT` set to a temp dir
(build.sh:5, 16), a build failure being a test failure; run one script from a temp file and
read all reply lines. Its twin `PredictHarness` (in the test target) executes the same
commands with `TerminalState` as the server, a `Framebuffer` as `shown`, and the Swift
engine. Comparison per `dump`: the `shown` line through `GoldenState(width:height:).apply(line:)`
and `CorpusComparison.firstDifference` against `TerminalState(parser: UTF8Parser(), terminal:
Emulator(fb: shown, ...), ...)` with a fresh parser and echo ack 0, matching the oracle's
fresh `Complete`; the engine object parsed into `PredictionDump` (internal,
`@testable import MoshTerminal`) and compared with `==`, reporting the first differing
field; a `null` `shown` is compared as "the harness's `shown` did not change either".

`PredictOracle.swift`, `PredictHarness.swift`, `PredictionFuzz.swift`,
`PredictionCrossCheckTests.swift` and `PredictionQuirkCrossCheckTests.swift` are each wholly
inside `#if os(Linux)`, as `MoshRef.swift` is (MoshRef.swift:5, 197), so `MoshTerminalTests`
still compiles on the Mac; the unit tests of 7.4 are not guarded.

### 7.2 The differential fuzz: `PredictionCrossCheckTests`

A seeded generator (`PredictionFuzz.swift`, on `TerminalFuzz`'s generator,
TerminalFuzz.swift:1-3, 39; case count `MOSH_FUZZ_CASES`, default 200 cases of 300
commands). Each case:

- **Setup**: size from {1x1, 2x2, 3x3, 5x2, 10x3, 80x24, 132x50}, weighted to small sizes so
  that last column and last row are frequent; mode (adaptive 40%, always 30%, experimental
  20%, never 10%), overwrite 30%; start time `2^24 + r` mostly, below 150 in 10% of cases
  (quirk 17); server content from `TerminalFuzz` host bytes (prompts, SGR colours, wide and
  combining characters), followed by `ESC [ ? 6 l` whenever the server ends in origin mode
  (D2: mosh's assert must not fire).
- **Steps**, drawn with weights; a `dump` after every command:
  - `read`: 1-4 bytes from the classes of tools 7 item 4 (printable ASCII, `é`, a wide
    `語`, a combining mark, split UTF-8, 0x7f, CR, LF, Tab, `ESC [ C`, `ESC [ D`, `ESC O C`,
    `ESC [ 5 C`, `ESC [ A`, `ESC [ 3 ~`, bare ESC then a letter, `ESC O h`, Ctrl-C), escape
    sequences sometimes cut across reads; 3% pastes of 101-150 bytes; `SENT` is the
    generator's current sent number;
  - `send`: the generator's sent number grows by 1 (sometimes 2: a burned number), and the
    typed bytes since the last send belong to it;
  - `host`: the server's reaction to a sent state: echo (printables as typed, 0x7f as
    `\b \b`, CR as `\r\n` plus a prompt, arrows as `ESC [ C`/`D`), a wrong echo (another
    character), a partial echo, or unrelated output (a clock line, a scroll);
  - `echoack N` with N a sent number at or below the newest, never going down;
  - `recv ACKED SI` with SI from {20, 21, 30, 31, 50, 51, 80, 81, 150, 250};
  - `time T` with `T` the previous time plus D, D from {0, 1, 49, 50, 51, 149, 150, 151,
    249, 250, 251, 4999, 5000, 5001} and random (the command carries the absolute value);
  - `frame`, at least every few steps, sometimes several reads between frames (quirk 1);
  - `hostresize` followed by `reset` (a window resize), rarely; a `frame` then sees the new
    size;
  - `display` and `overwrite` changes mid-case, rarely.
- **Compared**: every `dump` (engine state and the full shown frame). The first difference
  fails the test with the seed, the step number, the command list up to it and the field.
- **Coverage**, summed over all cases and asserted non-zero, read from the dumps: an epoch
  confirmed, an epoch killed (`prediction_epoch` jumps with the cursor list replaced), a
  full reset after a wrong confirmed guess, `glitch_trigger` reaching 10 and 20 and being
  decremented, `flagging` and `srtt_trigger` each turned on and off, an unknown cell
  underlined, a last-column wrap, a blank last-row prediction, a paste reset, an experimental
  single-cell reset; and, where a port slip is likely: the cursor check's full `reset()`
  (toc:596-613; the cursor list and all overlays emptied in one step), renditions copied
  along the row after a `Correct` (toc:561-569; replacement renditions changed by a `frame`
  without a `read`), each backspace neighbour case (next cell active and unknown, active and
  known, inactive, toc:729-739) and the overwrite backspace (toc:704-714), the `ESC O` to
  `ESC [` rewrite (toc:666-669; a `read` holding `ESC O C` that moves the predicted cursor),
  and a `kill_epoch` inside the row loop that resets cells to the right of the one being
  judged (toc:507 with toc:398-404). A generator change that loses one of them fails.
- **Volume**: the engine object after every command, `shown` only after `new` and `frame`
  (7.1). Sizes 80x24 and 132x50 are drawn rarely and their cases are cut to 30 commands;
  `PredictionCrossCheckTests` at the suite's default count has a budget of 60 s, checked
  when step 4 lands.

Time is entirely the commands' `time`: the oracle's `Network::timestamp()` and the Swift
`now:` both read the same number, and nothing else in either engine reads a clock (tools 2:
no other clock symbol; the Swift engine has no clock).

### 7.3 Named cases: `PredictionQuirkCrossCheckTests`

Short hand-written command lists, each run against the oracle and the port: the worked
example of spec 5.4, and one case per quirk 1-25 of spec 11 that the engine can show (all
but 12 and 18, which are wiring and D2), each with the step where the quirk acts. They
document the quirks and fail with a readable name. Expected values are not written by hand:
the oracle is the expectation.

### 7.4 Unit tests (no oracle; run on the Mac too)

- `PredictionOverlayTests`: `validity` of cells and cursors, every branch in mosh's order;
  `apply` of a cell (blank on blank, unknown, last column, equal cell not underlined);
  `reset` keeps `replacement`; `resetWithOrig`.
- `PredictionEngineTests`: thresholds at 20/21/30/31 and 50/51/80/81; glitch at 249/250 and
  4999/5000; the decrement's 150 ms spacing and the wrap below 150; `waitTime`; each row of
  the decision table of spec 6.4; D2 (a confirmed active cursor move on a frame in origin
  mode moves the cursor and does not trap, in the debug test build); D3 in release
  semantics (the test calls the release path through an internal switch, since `assert`
  traps in debug).
- `PredictionWiringTests` (MoshSessionTests, real `mosh-server` on 127.0.0.1, as the existing
  session tests). A fresh engine draws nothing in epoch 1 (toh:76, 298-299; toc:51-53,
  147-149), so every test that needs a guess drawn first types one key to a program that
  echoes it and waits for the echo ack's state. (1) `never`: no `.display` event, events
  otherwise unchanged; (2) `always` with a delaying test transport, epoch confirmed: a typed
  character is in a `.display` before any `.screen` shows it; after the echo, the last
  `.display` equals the remote framebuffer; (3) every `.screen` from the reader is followed
  by a `.display` of the same number while prediction is on, including a state that changes
  only the echo ack: type three keys within one round trip, let the server echo the first,
  and the last `.display` of each state holds all three letters; (4) with the one-byte echo
  program of 6.3 part c: after typing, `exportState()`'s newest remote state and `screen()`
  hold none of the typed text, while `displayedScreen()` did; (5) a resize resets (no guess
  drawn after it); (6) a restored session's first `.display` has no predictions;
  (7) refused input (after `shutdown()`) does not change the engine; (8) a test transport
  that drops inbound datagrams for 6 s while a guess pends with `flagging` on: after
  recovery the engine dump has `glitch_trigger` 20 (4.1, 250 ms timer); (9) through
  `setBeforeEventForTesting` (MoshSession.swift:329), an `exportState()` from a
  high-priority task while a handler waits in `predictionReadings()`: the `.screen` and
  `.display` numbers never go down; (10) guesses pending, `quiesce()`, `exportState()`: no
  render for 1 s; (11) after `.serverEnded` the last `.display` equals the final remote
  framebuffer and no timer runs.
- `MoshConnectionTests`: `typeNotingLastSent` returns the number from before the append even
  when the bytes are sent in the same call (`sendMinDelay` 0).

### 7.5 What cannot be tested on Linux

SwiftTerm's drawing of the underline and of a predicted cell; the controller's frame serial
and `CADisplayLink` cadence; how SwiftTerm hands over a paste (5, item 5); the iOS keyboard
(autocorrect replacing a word sends backspaces and text in one or several calls); the
setting's screen; the iOS monotonic clock across suspension; `NWDatagramTransport`. The
differential test needs the Linux mosh tree and skips elsewhere.

## 8. Implementation plan

Each step builds, passes the whole suite (`scripts/dev.sh swift test` into
`out/yellow/suite.log`) and can be committed alone. Nothing is visible to a user before
step 6, and with the package default `never` nothing changes for the app until step 10.

| # | Step | Files | Proved by | |
|---|---|---|---|---|
| 1 | Oracle `predict` mode, build changes, format text | `Tools/mosh-oracle/{predict.cc,main.cc,build.sh,FORMAT.md,README.md}`, `Tests/MoshTerminalTests/{PredictOracle,PredictOracleTests}.swift` | `scripts/corpus-check.sh` unchanged (old modes intact); `PredictOracleTests.testWorkedExample` runs spec 5.4 through the oracle and checks the epochs of each step, read from the raw JSON (`PredictionDump` arrives in step 3), against the spec's text | |
| 2 | `Framebuffer.withMutableCell`; overlay types with `validity` and `apply` | `Sources/MoshTerminal/{Framebuffer.swift,Prediction.swift}` | `PredictionOverlayTests`; a test that writing through `withMutableCell` on a copy leaves the original rows untouched | **[!]** |
| 3 | `PredictionEngine`: state, setters, `reset`, `becomeTentative`, `killEpoch`, `cull`, `apply`, `waitTime`, `initCursor`, `newlineCarriageReturn`, `newUserByte`, `newUserRead`, `overlay`; `PredictionDump` | `Sources/MoshTerminal/{Prediction.swift,PredictionDump.swift}` | `PredictionEngineTests` | **[!]** |
| 4 | Differential: harness, fuzz, named cases | `Tests/MoshTerminalTests/{PredictHarness,PredictionFuzz,PredictionCrossCheckTests,PredictionQuirkCrossCheckTests}.swift` | the fuzz at `MOSH_FUZZ_CASES=2000` once by hand, 200 in the suite; coverage counters | **[!]** (it is the proof of 2-3) |
| 5 | Transport reads | `Sources/MoshTransport/{MoshConnection.swift,TransportTypes.swift}` | `MoshConnectionTests` addition; every transport test unchanged | |
| 6 | Session wiring: engine, `shown`, `latest`, render, timer, `.display`, settings API, clock kept; `case .display` added to `ResumeCoordinator`'s switch, moshcli's `ScriptedSession` switch and, one line `case .display: break`, `App/IOSMosh/TerminalViewController.swift` | `Sources/MoshSession/{MoshSession.swift,SessionTypes.swift}`, `Sources/MoshResume/ResumeCoordinator.swift`, `Sources/moshcli/ScriptedSession.swift`, the app line; `Tests/MoshSessionTests/PredictionWiringTests.swift` and a delaying, dropping test `DatagramTransport` in that test target (moshcli's `--delay-ms` comes only in step 8) | `PredictionWiringTests`; the whole suite; `scripts/mac.sh` app build (the app line; see below) | **[!]** |
| 7 | Coordinator: `Options.prediction`, `setPrediction`, kept across new sessions | `Sources/MoshResume/ResumeCoordinator.swift` | `ResumeCoordinatorTests` addition (setting survives a cold start and a fallback) | |
| 8 | moshcli options, `--delay-ms` in `WireTap`, script commands; `test_predict`; itest.sh lines | `Sources/moshcli/{SessionOptions,WireTap,ScriptCommand,ScriptedSession}.swift`, `scripts/itest-mosh.sh`, `scripts/itest.sh` | `scripts/itest.sh predict`; `scripts/itest.sh script` unchanged | |
| 9 | Docs: PLAN M10 text and verification rows (the table of 6.3 and 7.2), the CLOUD log | `docs/PLAN.md`, `docs/CLOUD.md` | review | |
| 10 | App (charlie): the setting, drawing from `.display`, the paste check | `App/IOSMosh/*` | `scripts/sim-test.sh`; phone with netem on yellow | **[!]** |

Step 6 is the one commit that touches `App/`: the exhaustive switch in
`TerminalViewController.handle` would not compile otherwise. It is one line, but `App/`
belongs to the charlie session (CLAUDE.md), so the step is made with its agreement and
pushed only after `scripts/mac.sh` has built the app (as stage2 DESIGN step 9). Steps 2, 3
and 6 go to hostile reviewers against toc and stc before step 10 reaches the phone.

## 9. Risks and open questions

### 9.1 Risks

1. **Engine mistakes that the generator never reaches.** The fuzz only proves the
   schedules it generates. Mitigation: the coverage counters of 7.2, the named quirk cases,
   and a long run (`MOSH_FUZZ_CASES=20000`) before step 6 is pushed.
2. **Width tables.** The oracle uses the container's glibc `wcwidth` in `en_US.UTF-8`; the
   port uses the glibc 2.39 table. An image update to another glibc makes the fuzz fail on
   wide or combining input (quirk 20). The failure is loud, not silent.
3. **Render cadence differs from mosh's loop.** mosh culls on every loop pass; the session
   culls on events, input and the timers of 4.1 (50 ms, or 250 ms while a guess is active
   and `waitTime()` is `INT_MAX`). Only *when* a timing threshold is noticed can differ: by
   at most 50 ms where mosh's own wait is 50 ms, and by at most 250 ms against mosh's
   network-driven passes. Not covered by the differential
   test (it fixes the call order by construction); covered loosely by itest.
4. **Event volume.** While guesses are pending a render every 50 ms; `.display` only when
   the frame changed, so a quiet screen sends nothing. The stream is unbounded (as today);
   the app keeps only the newest frame.
5. **Battery and CPU.** A frame copy plus a cull per render; cull is O(rows predicted x
   width). Small next to `DisplayDiff`; to be measured on the phone in step 10.
6. **Deviation D1 shows a different screen than mosh** while mosh's bar would be up: only
   then, and only on row 0.
7. **Exhaustive switch in the app**: step 6 needs both builds green before the push.

### 9.2 Open questions for the owner

1. **Default mode in the app**: mosh's `adaptive` (shows guesses only when the link is slow,
   round trip above about 60 ms, or a guess stays unanswered 250 ms), or `always`?
2. **Scope of the setting**: per host (like mosh's command-line flag) or one switch for the
   whole app?
3. **Show `experimental` and "overwrite" in the app**, or keep them for moshcli only?
4. **Guesses across a trip to the background**: keep them (as a mosh client whose network
   paused would; they show underlined on return until answered), or drop them at
   `quiesce()` so the screenshot iOS takes never holds a guess?
5. **The phone check** needs about 15 minutes with netem on yellow and the phone on the
   screen. When?

## Appendix A. What the readers left unclear, checked against the source

- **Which oracle** (tools 1): both `Tools/mosh-oracle` (batch) and `moshref` (stdin) link
  mosh. Chosen: a stdin mode of `Tools/mosh-oracle`, because the task names it, it already
  has `ORACLE_OUT` for a per-process build (build.sh:5, 16) and its state-line JSON
  (`make_dump` main.cc:558, `full_line` main.cc:676) has a complete Swift reader and
  comparison (`GoldenState`, GoldenCorpus.swift:427-500; `CorpusComparison.firstDifference`,
  CorpusTests.swift:105, 115). `moshref` prints `debugDump()` text, for which the engine has no
  counterpart.
- **Seams' line numbers for `Framebuffer.swift`** (seams 1: 239-528, `ds` at 251,
  `makeRowUnique` at 305) do not match `584c1fd`: the file has 305 lines; `struct
  Framebuffer` is at :16, `ds` at :28, `getRow`/`getCell` at :64-69, `makeRowUnique` at :82,
  `resetCell` at :91. The facts (no public cell write, copy-on-write rows) hold.
- **Glitch decrement** (spec 7 step 7.2): toc:555-559 reads
  `now - j->prediction_time < GLITCH_THRESHOLD && ( glitch_trigger > 0 && now -
  GLITCH_REPAIR_MININTERVAL >= last_quick_confirmation )`, all in `uint64_t`; as the spec
  says.
- **`ConditionalOverlayCell::apply`** (spec 8): toc:43-72 checked; the blank test uses the
  frame cell, the unknown branch underlines without writing, the write uses full `!=`.
- **`move_row`/`move_col`**: tfbc:134-168 and DrawState.swift:131-166 are the same code.
- **`Complete`'s framebuffer for the dump**: `Complete::terminal` is private
  (completeterminal.h:46-48) and `Emulator::fb` too (terminal.h:64); `-fno-access-control`
  (build.sh) reaches both without changing layouts.
- **`ParserAction`** has `kind`, `ch`, `charPresent` (Parser.swift:53-64), which is what
  toc:685-760 uses (`typeid`, `act.ch`, `assert(act.char_present)`).

## Review status

Findings of `critique-fidelity.md` (F) and `critique-architecture.md` (A), each checked
against the lines it cites before deciding.

| Id | Decision | Reason |
|---|---|---|
| F1 | accepted | Verified (stc:274-287, completeterminal.cc:124-158): `.display` now also yields on a new remote state (4.1), and the app draws only `.display` while the mode is not `never` (5 item 2) |
| F2 | accepted | Verified toh:76, 298-299, toc:51-53, 147-149: wiring tests confirm an epoch first (7.4); itest part c uses a one-byte echo program (6.3) |
| F3 | accepted | Verified stc:441-444, toh:266-292, toc:579-580: a 250 ms timer while a guess is active and `waitTime()` is `INT_MAX` (4.1), wiring test 8 |
| F4 | accepted | Verified stc:305-334: D4 reworded as a deliberate deviation, the false "same outcome" claim removed |
| F5 | accepted | Verified toh:215, toc:652: `last_byte` printed as `unsigned char` (7.1) |
| F6 | accepted | The listed branches (toc:507, 561-569, 596-613, 666-669, 704-739) get coverage counters (7.2) |
| F7 | accepted | `exportState()` no longer sets `latest` or renders; setters and frame come from one reading (4.3) |
| F8 | accepted | `time` is absolute in both 7.1 and 7.2 |
| A1 | accepted | Same defect as F1; closed by the same change |
| A2 | accepted | Verified MoshSession.swift:249-258, 372-379: readings apply only if not older than `latest`, `.screen` guard `<=`, export does not touch `latest` (4.3), wiring test 9 |
| A3 | accepted | Event path verified (TerminalViewController.swift:638-648): the app draws only `.display` while prediction is on (5 item 2) |
| A4 | accepted | Verified toc:153: the origin-mode check is not an `assert` in any build (2.2, D2) |
| A5 | accepted | `shown` dumped only after `new`/`frame` (the only commands that change it), large sizes cut to 30 commands, 60 s budget (7.1, 7.2) |
| A6 | accepted | Verified MoshSession.swift:36-50, 221-228: a synchronous `quiesced` flag gates the timer (2.4, 4.6), wiring test 10 |
| A7 | accepted | Verified SessionTypes.swift:59: `DisplayFrame` is `Equatable` |
| A8 | accepted | Verified MoshSession.swift:345-357: on the end events reset, render once, stop the timer (4.6), wiring test 11 |
| A9 | accepted | Contract DatagramTransport.swift:27-36: `close()` empties the delay queue (6.1), itest part f |
| A10 | accepted | Step 1 and step 6 file lists completed (8) |
| A11 | accepted | The oracle-based test files are wholly `#if os(Linux)` (7.1) |
| A12 | accepted | Same as F5 |
| A13 | accepted | D3 now says what a release build keeps when a guarded action is skipped |
| A14 | accepted | Same as F4 |
| A15 | accepted | Verified completeterminal.cc:130-158, .h:60: part a waits for the echo ack's state, not the echo (6.3) |
| A16 | accepted | Verified CorpusTests.swift:105, 115: renamed to `CorpusComparison.firstDifference` |

Second look (2026-11-19, before step 1), each accepted finding read again against the
critique and the mosh lines it cites: F1-F8 and A1-A16 are closed by the text as it
stands; the revision broke no row of the port map. Two small corrections: the constants of
toh:203-213 are `uint64_t` in mosh, so 2.2 now declares them `UInt64` (it had `UInt32` for
four of them, against its own rule on mixed comparisons); and the oracle's `shown` dump is
wrapped in a `Complete` of `shown`'s size, not of the `new` size (7.1). Step 1 checked as
buildable: `terminaloverlay.o` is in the container's tree and needs only
`Network::timestamp()`, `Terminal::*` symbols from `libmoshterminal.a`, parser typeinfo
and libc (`nm -C -u`); the frontend Makefile's include path adds `network` and `crypto`.

### Progress

- **Step 1** (commit "Add a predict mode to mosh-oracle"): `Tools/mosh-oracle/predict.cc`
  and `oracle.h`, `predict` in `main.cc`, `build.sh` compiles `predict.cc` with the
  network, crypto and frontend include dirs and links `terminaloverlay.o` (failing clearly
  if it is missing); FORMAT.md section 11, README row; `scripts/corpus-check.sh` also
  rebuilds the oracle when `predict.cc`, `oracle.h` or `build.sh` is newer. Tests:
  `PredictOracleTests` (worked example of spec 5.4 step by step, from the raw JSON; a bad
  command exits 65). `scripts/corpus-check.sh`: 38 cases pass. Suite: "Executed 680 tests,
  with 33 tests skipped and 0 failures". Decisions where the design was silent: every
  command but `dump` replies `{"ok":"<command>"}`; the first command must be `new`; `HEX`
  may be left out for an empty byte string; the oracle is built once per test process
  (about 30 s, inside the existing suite time).
- **Step 2** (commit "Add the prediction overlay types"; step 1 is 9f55ea1):
  `Framebuffer.withMutableCell` and `Sources/MoshTerminal/Prediction.swift` with
  `PredictionValidity`, `ConditionalCursorMove`, `ConditionalOverlayCell`,
  `ConditionalOverlayRow` (validity, apply, reset, resetWithOrig, expire). Tests:
  `PredictionOverlayTests` (17). Suite: "Executed 697 tests, with 33 tests skipped and 0
  failures". Decisions: the D3 checks are one helper, `PredictionBounds.check`, whose
  `trapsOnFailure` (default true) lets a test run the release path in a debug build; a
  negative row or column, where mosh's `.at()` would throw, is handled like an out-of-range
  one by the same check (in `validity` it answers `IncorrectOrExpired`).
- **Step 3** (commit "Port mosh's prediction engine"; step 2 is b9578e5): `PredictionEngine`,
  `PredictionDisplay`, `PredictionSettings` appended to `Prediction.swift`;
  `PredictionDump.swift` (internal, with `firstDifference` for readable failures). Tests:
  `PredictionEngineTests` (24). Suite: "Executed 721 tests, with 33 tests skipped and 0
  failures". Decisions: `newlineCarriageReturn` takes the caller's `now` (mosh reads
  `timestamp()` again, the same frozen value within a step); the insert and backspace loops
  copy a cell, change it and store it back (no reference into the array, mosh's `&cell`
  aliasing only matters for `prev`/`next`, which are read before the store, as in mosh's
  loop order); the printable branch's bound asserts (toc:751-754) are shown unreachable by
  `testOutOfRangeCursorIsResetByThePreamblesCull` (the preamble's cull resets an
  out-of-range last cursor), so D3's release path there is not unit-tested; the backspace
  path also checks the row it reads (mosh's `.at()` would throw), under the same D3 rule.
- **Step 4** (commit "Prove the prediction port against mosh's engine"; step 3 is 4c99b11):
  `PredictHarness.swift` (the Swift twin of the oracle's commands and the per-dump
  comparison), `PredictionFuzz.swift` (generator and coverage counters),
  `PredictionCrossCheckTests`, `PredictionQuirkCrossCheckTests` (worked example, quirks 1-25
  but 12 and 18, glitch timer, resize; 26 cases). No difference found and no engine change
  needed. `MOSH_FUZZ_CASES=2000` once by hand (`scripts/dev.sh env MOSH_FUZZ_CASES=2000 swift
  test --filter PredictionCrossCheckTests`): 0 failures in 1193 s, every coverage counter
  non-zero (rarest: renditions copied along the row 21, unknown cell underlined 99, glitch
  decremented 127, epoch confirmed 148). Two deliberate slips (ESC O rewrite, the left
  neighbour's renditions) were caught by the named cases and the fuzz, then removed. Suite:
  "Executed 748 tests, with 33 tests skipped and 0 failures"; the fuzz there takes 67 s.
  Decisions where the design was silent or over budget:
  - **Suite default 100 cases of 300 commands, not 200**: 200 took about 100 s beyond the
    oracle's one-time build (about 30 s, shared with `PredictOracleTests` in one process);
    100 takes about 40-65 s. The 2000-case run is the long run of risk 1.
  - The engine dump is compared as text first: the port's dump is written in the oracle's
    exact JSON (`PredictionDump.oracleJSON`, test code) and only a mismatch is parsed for a
    readable field-by-field report. The shown frame always goes through `GoldenState` and
    `CorpusComparison.firstDifference`, its rows array rewritten as the delta form's object.
  - Generator details the design left open: printable letters are 40% of keys (the rest the
    classes of 7.2, plus a double backspace); a host reaction echoes 45%, echoes in a colour
    20% (so a `Correct` recolours the row), echoes a wrong letter 10%, half an echo 10%,
    unrelated output otherwise, and 60% of answers are followed by the echo ack, a time step
    below 80 ms and a `recv`; sizes 10x3 and 5x2 weighted up; 80x24 or 132x50 in 4% of cases
    (cut to 30 commands); a rare "cursor-only" episode (reset, one arrow key, a server that
    does not move) reaches the cursor check's full reset, which random typing almost never
    did (0 in 100 cases without it).
  - Coverage counters are read from consecutive port dumps; "cursor check full reset" is
    decided by re-judging the newest cursor and the cells with the overlay types on the
    server frame, the others by dump differences (approximations documented in
    `PredictionFuzz.swift`).
- **Step 5** (commit "Add the transport reads local echo needs"; step 4 is 8238e13):
  `TypeReceipt`, `SenderReadings`, `MoshConnection.typeNotingLastSent(_:)` (`type(_:)` now
  calls it) and `predictionReadings()`; nothing in how numbers are taken changed. Tests:
  `Tests/MoshTransportTests/PredictionReadingsTests.swift` (3; there is no
  `MoshConnectionTests` file, so the design's "addition" is a new file). Suite: "Executed 751
  tests, with 33 tests skipped and 0 failures". Decisions: a refused `type` still reports
  the number it read (the session ignores it, stc:319-321); the send interval is narrowed
  with `UInt32(clamping:)` (it is at most 250).
- **Step 6** (commit "Wire local echo into the session"; step 5 is 19c7612): `MoshSession`
  keeps the engine, `shown`, `latest`, the clock, the 50/250 ms timer and the `quiesced` and
  `ended` flags; `type`, `resize`, `.contact`, `.remoteStateAdvanced`, `resume`, the end
  events and `setPrediction` feed and render as section 4 says. `SessionEvent.display` and
  `DisplayFrame` in `SessionTypes.swift`; every initializer takes `prediction:` (default
  `.off`), the bootstrap one also `clock:`; `setPrediction`, `predictionSettings`,
  `displayedScreen`. `ResumeCoordinator` needed no change (its switch has a `default`);
  moshcli's switch and the app's (`case .display: break`) got the case. Tests:
  `PredictionWiringTests` (12: the eleven of 7.4 and the switch to `never`) with
  `DelayingTransport` (delay each way, inbound drop). Suite: "Executed 763 tests, with 33 tests skipped and 0 failures". App:
  `scripts/mac.sh scripts/sim-test.sh -only-testing:IOSMoshTests` built the app and ran 79
  tests, 0 failures ("TEST EXECUTE SUCCEEDED").
  Decisions where the design was silent:
  - A new session renders only from its first input or reading (no `.display` at
    `start()`); a restored one renders right after its stored `.screen` (4.6).
  - `resize` resets and renders whether or not the connection took the resize (mosh resets
    unconditionally, stmclient.cc:418).
  - A `.screen` from the reader always gets a `.display` after it, also when `resume()`
    already rendered that state (`lastDisplayed` is cleared before that render), so the
    ordering of 7.4 test 3 holds against every interleaving.
  - On an end event the session first takes one more reading (so the last `.display` is
    the newest remote frame), then resets and renders. The final state of a server end
    (`finalRemoteState`, which has no number) is not drawn into `.display`; the app has it
    in `.serverEnded`.
  - Test 9 holds the reader in `setBeforeEventForTesting` across a quiesce, export and
    resume, rather than inside `predictionReadings()`, which a test cannot stop at.
- **Step 7** (commit "Pass local echo through the coordinator"; step 6 is ed18287):
  `ResumeCoordinator.Options.prediction` (default `.off`), passed to the session of `create`
  and of `coldStart`; `setPrediction(_:)` and `predictionSettings()` forward to the live
  session. Nothing else in `MoshResume` changed: the setting is not in the record, the store,
  the counters or the snapshot. Tests: `CoordinatorPredictionTests` (3: default off; a new
  session gets the setting and `setPrediction` reaches it, with a forwarded `.display`; a
  cold start takes the setting from its own options, not from the record, and the new
  session after a fallback gets it from the same options). Suite: "Executed 766 tests, with
  33 tests skipped and 0 failures". App unchanged: `scripts/mac.sh scripts/sim-test.sh
  -only-testing:IOSMoshTests` 79 tests, 0 failures ("TEST EXECUTE SUCCEEDED"). Decision: a
  coordinator holds one session for its life, so "kept for the next session" is the app's
  part: it passes the user's setting in `Options.prediction` at every `create` and
  `coldStart` (a fallback is a new `create`).
- **Step 8** (commit "Give moshcli local echo and test it against the server"; step 7 is
  a1bf9cd): `--predict MODE`, `--predict-overwrite`, `--delay-ms MS` in `SessionTuning` (so
  `connect`, `soak` and `bootstrap`; with `--session-root` through `Options.prediction`);
  the delay in `TappedTransport` (one serial queue per socket, after `--loss`, emptied at
  `close()`); script commands `expect-display`, `expect-predicted`, `expect-display-settled`,
  `expect-underlined`, `dump-display`; the summary line ends in `displays N;` (the count of
  `.display` events). `test_predict` parts a-f in `scripts/itest-mosh.sh`, `predict` in
  `scripts/itest.sh` (header, case, `all`, usage). `scripts/itest.sh predict`: PASS twice;
  `scripts/itest.sh script`: PASS. Suite: "Executed 766 tests, with 33 tests skipped and 0 failures". Decisions where the design was silent:
  - With a record, `displayed()` is the frame of the newest `.display` the coordinator
    forwarded (the remote screen before the first one): the coordinator has no reader of
    the shown frame and step 7 added none.
  - Part c waits 1.5 s instead of a prompt (the program prints none); part d samples
    `expect-display-settled 1000` during the round trip, because the shown frame follows
    the session's readings and can be a moment behind `screen()`.
  - Part e sleeps 4 s after the confirming key, longer than the server's 3 s heartbeat, so a
    cull with no guess active turns `srtt_trigger` off; then `expect-predicted` must run out
    (exit 1).
  - Part f types a key, replaces the socket and quiesces while the 500 ms queue still holds
    datagrams; what it shows from outside is that the session goes on and no number repeats
    (`check-seq-log.sh`).
  - `moshcli resume` keeps no `--predict` (not needed by any test); `ResumeSupport`'s
    options take a `prediction:` that defaults to off.
- **Step 9** (commit "Describe local echo in the plan"; step 8 is 9e338fb): `docs/PLAN.md`
  M10 text (what was built, where the design is), a "Local echo (M10)" block under
  Verification (the differential, named and wiring tests, and the table of 6.3 with pass
  conditions), an M10 row in the phone table; the log entry in `docs/CLOUD.md`. Suite:
  "Executed 766 tests, with 33 tests skipped and 0 failures". Docs only.
- **Step 10, simulator part** (commit "Draw local echo in the app"): the per-host "Local
  echo" setting (Adaptive by default, Trick 2026-11-19), `Options.prediction` at every
  `create` and cold start, `setPrediction` on a change saved while the session is open,
  drawing from `.display` (`FrameToDraw`), the paste check (one input of 300 bytes). Details,
  decisions and test lines in the `docs/MAC.md` log (2026-11-19). Open: the phone check with
  netem (5 item 6), and open questions 3 (Experimental, overwrite; one constant each in
  `App/IOSMosh/LocalEcho.swift`) and 4 (guesses across the background: kept, as the core does).
