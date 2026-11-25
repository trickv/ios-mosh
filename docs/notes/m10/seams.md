# M10 seams: where a prediction engine attaches

Reader's map for the M10 design (local echo, port of mosh 1.4.0
`src/frontend/terminaloverlay.{h,cc}`). Every fact has file:line at HEAD `584c1fd`.
mosh citations are to `.refs/mosh/src`. Our paths are relative to the repository root.
No design here, only the places a design can use.

## 0. What mosh's engine touches (the target)

- Wiring in mosh's client, `frontend/stmclient.cc`:
  - `output_new_frame` (267-288): copy of the newest remote framebuffer
    (`get_latest_remote_state().state.get_fb()`, 274), `overlays.apply( new_state )` (277),
    then `display.new_frame( !repaint_requested, local_framebuffer, new_state )` (280-282),
    then `local_framebuffer = new_state` (287). The overlaid frame becomes the base of
    the next diff.
  - It runs on every pass of the main loop (442), not only when a state arrives; the
    loop's wait is `min( network->wait_time(), overlays.wait_time() )` (444).
  - `process_network_input` (290-301), after every `recv()`: `set_local_frame_acked(
    get_sent_state_acked() )` (298), `set_send_interval( send_interval() )` (299),
    `set_local_frame_late_acked( latest remote state's get_echo_ack() )` (300).
  - `process_user_input`: `set_local_frame_sent( net.get_sent_state_last() )` (322)
    *before* the bytes are pushed; a read of more than 100 bytes is a paste and calls
    `reset()` (325-328); otherwise `new_user_byte( the_byte, local_framebuffer )` per
    byte (334). It gets `local_framebuffer`, the last frame *shown* (overlaid), not
    the remote state.
  - `process_resize`: `get_prediction_engine().reset()` (418).
- `OverlayManager::apply` (terminaloverlay.cc:333-339) is not const: `predictions.cull(
  fb )` changes the engine on every frame, then `predictions.apply`, the notification
  engine and the title engine (`fb.prefix_window_title`, terminaloverlay.h:315).
- What prediction writes into the frame: cells through `fb.get_mutable_cell` (cc:61,
  67, 69), the underline attribute (cc:61, 69), the cursor through `fb.ds.move_row` /
  `move_col` (cc:155-156). Reads: `fb.get_cell`, `fb.ds.get_width/height`, cursor
  row/col, `fb.ds.get_renditions()` (cc:797), cell renditions (cc:563).
- Time: `timestamp()` is `Network::timestamp()` (network.h:53, network.cc:596-599) =
  `frozen_timestamp()`, frozen once per `select` (util/select.h:187). Used in cull
  (cc:453) and new_user_byte (cc:663).
- `send_interval` = `ceil(SRTT/2)` clamped to 20...250 ms
  (network/transportsender-impl.h:73-83, transportsender.h:52-53). The engine never
  reads SRTT itself; its "SRTT trigger" compares `send_interval` with 20/30
  (terminaloverlay.h:203-204, cc:456-467).
- Frame numbers: predictions expire at `local_frame_sent + 1` (cc:389, 424, 702, 709).
- The engine has its own `Parser::UTF8Parser parser` for user bytes (terminaloverlay.h:216,
  cc:673) and calls glibc `wcwidth( ch )` directly, without the ISO 8859-1 shortcut
  (cc:746).

## 1. MoshTerminal: framebuffer types

| Thing | Where | Facts |
|---|---|---|
| `Cell` | `Sources/MoshTerminal/Cell.swift:11-128` | `contents: [UInt8]` (UTF-8, compared byte-wise, never as `String`, 8-10), `renditions`, `wide`, `fallback`, `wrap` (12-21), all `public var` |
| Cell equality | `Cell.swift:11` (synthesized `Equatable`) | Same five fields as mosh `Cell::operator==` (terminal/terminalframebuffer.h:114-121) |
| Other cell comparisons | `Cell.swift:57-64, 116-127` | `isBlank`, `contentsMatch` (mosh `contents_match`), `compare` (mosh's verification compare, ignores `fallback`) |
| `Row` | `Cell.swift:169-223` | `final class`; `cells` and `gen` are `public internal(set)` (170, 172). Copy `init(copying:)` keeps the generation (181-184). `moshEquals` = same gen and equal cells (220-222) |
| `Framebuffer` | `Sources/MoshTerminal/Framebuffer.swift:239-528` | Value type; `rows: [Row]` is `public internal(set)` (243); `ds: DrawState` is `public var` (251); title, icon, clipboard, bell count, `titleInitialized` are `internal(set)` (244-250) |
| Cell write | `Framebuffer.swift:305-311` (`makeRowUnique`, internal), `314-318` (`resetCell`, internal) | Copy-on-write by `isKnownUniquelyReferenced`, mosh `get_mutable_row`. **No public API writes a cell**: outside the module only `getRow`/`getCell` (287-296) read |
| Equality | `Framebuffer.swift:504-516` (`==`, structural), `522-527` (`moshEquals`, row identity) | |
| `DrawState` | `Sources/MoshTerminal/DrawState.swift:44-313` | Cursor `cursorRow/Col` `internal(set)` (48-49); `moveRow` (132-142) and `moveCol` (146-166) are public; `cursorVisible` public var (72); pen `renditions` `internal(set)` (64); `originMode` public var (69); `moshEquals` (305-312) |
| `Renditions` | `Sources/MoshTerminal/Renditions.swift:12-` | `setAttribute(_:_:)` public (120), `.underlined` (16), colours public vars (24-28) |
| `TerminalState` | `Sources/MoshTerminal/TerminalState.swift:35-207` | `terminal: Emulator` `internal(set)` (51); `framebuffer` getter (74); `echoAck` (55) set by `applyEchoAck` (115-117) |
| `Emulator` | `Sources/MoshTerminal/Emulator.swift:8-24` | `fb` `internal(set)` (9); public `init(fb:dispatch:user:)` (20) and `TerminalState.init(parser:terminal:inputHistory:echoAck:)` (TerminalState.swift:66) can wrap a framebuffer built elsewhere |
| User-byte parser | `Sources/MoshTerminal/Parser.swift:421-540` | `UTF8Parser` public, `input(_:into:)` public (531), `resetInput` (538) |
| Width | `Sources/MoshTerminal/WCWidth.swift:14-33` | `WCWidth.wcwidth(_:)`: glibc 2.39 table (`WCWidthTable.swift`), -1/0/1/2. The emulator adds the ISO 8859-1 shortcut itself (Emulator.swift:70, `Cell.isPrintISO8859_1` Cell.swift:109) |

Cost of a copy of a whole framebuffer (`var f = remote.framebuffer`): one retain of
the rows array; the first write duplicates the array of `height` row references; each
row written is copied once (`Row(copying:)`, Cell.swift:181-184: `width` cells, each with
its own `[UInt8]` buffer retained). Rows held by the transport's received states are
never uniquely referenced, so writes to a copy never reach a remote state
(Framebuffer.swift:226-232, 305-311). A copied row keeps its generation, as mosh's.

Display diff and row identity: scroll detection uses `===` then `Row.moshEquals`
(`Sources/MoshTerminal/DisplayDiff.swift:175-196`), and an unchanged-row shortcut uses
`===` (DisplayDiff.swift:394). mosh's `Display::new_frame` does the same
(terminal/terminaldisplay.cc:61); its overlaid rows are copies with the same generation.

Echo ack of a server state: `TerminalState.echoAck` (TerminalState.swift:55), written by
`TerminalRemoteState.apply` (`Sources/MoshSession/TerminalRemoteState.swift:113-117`),
read as `TerminalRemoteState.echoAck` (TerminalRemoteState.swift:85-87, doc comment says
"the prediction engine's late ack") and reaching the app as `ScreenUpdate.state.echoAck`
(`Sources/MoshSession/SessionTypes.swift:42`).

## 2. MoshTransport: the quantities the engine reads

| mosh | Ours | In `TransportCore` | On `MoshConnection` / `MoshSession` |
|---|---|---|---|
| `get_sent_state_last()` (networktransport.h:115) | last sent state number | `lastSentStateNumber` (`Sources/MoshTransport/TransportCore.swift:892`) | **missing** |
| `get_sent_state_acked()` (networktransport.h:114) | acknowledged state `A` | `acknowledgedStateNumber` (TransportCore.swift:889) | `MoshConnection.acknowledgedStateNumber()` (`MoshConnection.swift:326-328`), `MoshSession` (MoshSession.swift:324), `ResumeCoordinator` (`Sources/MoshResume/ResumeCoordinator.swift:738`) |
| `send_interval()` (networktransport.h:117) | `RTTEstimator.sendInterval` (`RTTEstimator.swift:54-57`, limits 11, 13) | via `rtt` (`public private(set)`, TransportCore.swift:91) | **missing** |
| `get_SRTT()` (network.h:222) | `RTTEstimator.srtt` (RTTEstimator.swift:18, starts at 1000) | `rtt.srtt` | `smoothedRoundTripTime()` (MoshConnection.swift:300-302, MoshSession.swift:319, ResumeCoordinator.swift:734) |
| `get_sent_state_acked_timestamp()` (notification engine only, stmclient.cc:296) | `ContactTimes.acknowledgedStateSentAt` (TransportTypes.swift:159) | `contactTimes` (TransportCore.swift:923) | as ages: `contactAges()` (MoshConnection.swift:295) |
| latest remote state's echo ack (stmclient.cc:300) | `TerminalRemoteState.echoAck` | `newestRemoteState` (TransportCore.swift:876-879) | `newestRemoteState()` (MoshConnection.swift:285), `MoshSession.screen()` (309-312) |

To add: a read of the last sent state number and of the send interval through
`MoshConnection` (an actor, `MoshConnection.swift:68`) up to `MoshSession`. Timing of the
reads matters:
- mosh reads `sent_state_last` before the bytes enter the state (stmclient.cc:322).
  `MoshConnection.type` appends the bytes and then `pump()`s (MoshConnection.swift:268-272,
  417-425), which can send at once if a send timer is due (TransportCore.swift:485-488:
  `sendMinDelay` is 1 ms by default, TransportTypes.swift:11). A read made in a separate
  `await` after `type` can already see the number that carries the bytes.
- mosh feeds the acks after every received datagram (stmclient.cc:290-301). Ours signals an
  authentic datagram as `ConnectionEvent.contact` (MoshConnection.swift:55-57) and a new state
  as `.transport(.remoteStateAdvanced)` (handled in MoshSession.swift:343-344).

State numbers come from the gate (`Outbox.takeStateNumber`, `Sources/MoshTransport/Outbox.swift:137-155`),
for data states and empty acks alike (TransportCore.swift:595, 625), as in mosh. Within one
process they are consecutive (`InMemoryGate`/`FileBackedGate` hand out `next` until the
reserved limit, DurabilityGate.swift:132-136, FileBackedGate.swift:165-177); a failed send
burns a number (rolled back state, TransportCore.swift:599-602, 636-638), so a gap is
possible but numbers only grow. After an import they restart at the reserved limit
(docs/RESUME.md:52, R2), far above the old ones.

Module rule: `MoshTransport` depends on `MoshCrypto`, `MoshWire` only; `MoshTerminal` on
nothing (`Package.swift:36-37`); `TerminalRemoteState` is "the only place where a
`HostMessage` meets a `TerminalState`" (TerminalRemoteState.swift:5-7). `MonotonicClock` lives
in MoshTransport (`MoshConnection.swift:6-24`), so MoshTerminal cannot name it.
- The engine writes cells, which only code inside `MoshTerminal` can do today
  (section 1), and uses `WCWidth`, `UTF8Parser`, `Framebuffer`: **MoshTerminal can own
  it**, with frame numbers, send interval and time passed in as plain integers.
  Any other owner needs new public cell-write API in MoshTerminal.
- **MoshSession wires it** (it imports both, Package.swift:40-42).

## 3. MoshSession: input, events, screen

- `MoshSession` is an `actor` (`Sources/MoshSession/MoshSession.swift:29`). Every call into
  the connection is an `await` on another actor: `type` (291-293), `resize` (297-299),
  `screen()` (309-312), the event handler (333-368, `reportNewestScreen` 372-379). Each
  await is a suspension point; the actor is reentrant across them.
- Input: `type(_ bytes: [UInt8]) async -> Bool` (MoshSession.swift:291-293), reached from the
  app through `ResumeCoordinator.type` (ResumeCoordinator.swift:590-592, serialized by
  `inOrder`, invariant C8 docs/RESUME.md:111). Resize: MoshSession.swift:297-299,
  ResumeCoordinator.swift:597-599.
- Clock: `MoshSession` takes a `clock: any MonotonicClock` (81, 127) and hands it to the
  connection (91, 136); it keeps no clock of its own. The connection keeps it private
  (MoshConnection.swift:74). `SystemMonotonicClock` is `CLOCK_MONOTONIC` + 2^24 ms
  (MoshConnection.swift:13-23). `ResumeCoordinator.Options.clock` (ResumeCoordinator.swift:160).
  The no-reply timer uses real time, not `clock` (MoshSession.swift:71-73, 196).
- Events: `SessionEvent` (SessionTypes.swift:59-101); `.screen(ScreenUpdate)` (61) carries
  `number`, `state: TerminalState`, `isLive` (39-56). A screen is yielded only when the
  newest remote state number changes (MoshSession.swift:372-379), at restore start
  (172-176, `isLive` false) and in `exportState` (252-258). ResumeCoordinator forwards the
  session's events (ResumeCoordinator.swift:173-176, 453, 722).
- `screen()` returns the newest *remote* state (MoshSession.swift:309-312).
- Where a predicted frame could leave the session: (a) the `.screen` event (a field of
  `ScreenUpdate` or a new `SessionEvent` case), (b) `screen()` or a sibling read,
  (c) not at all: the session hands out the engine's inputs and the app or surface applies
  the overlay. Today no event fires without a new remote state, while mosh redraws on
  every loop pass and on `overlays.wait_time()` (stmclient.cc:442-444).

## 4. The surface

- `SurfaceFeed` (`Sources/MoshTerminal/SurfaceFeed.swift:66-111`): `feed(to: Framebuffer)`
  (98-111) diffs `lastShown` (69) to the given frame with `DisplayDiff` in surface mode
  (78-82, 107) and remembers it as shown (108). Any newer frame may follow any shown one
  (rule 6, 54). This is our `display.new_frame( ..., local_framebuffer, new_state )`;
  `lastShown` plays `local_framebuffer`.
- App: `SwiftTermSurface.show(_:)` (`App/SurfaceKit/TerminalSurface.swift:111-121`) refuses a
  frame of another size (113-115), feeds the bytes to SwiftTerm (116-118). One `SurfaceFeed`
  per view (79).
- The controller keeps the newest `ScreenUpdate` (`App/IOSMosh/TerminalViewController.swift:702-703`)
  and draws from a `CADisplayLink` (255) in `tick()` (937-940), **only when
  `newest.number != shownNumber`** (938). A frame that changes without a new remote number
  is not drawn by this code.
- Input from the view: `surface.onInput` -> `.input(bytes)` command (TerminalViewController.swift:243-244)
  -> `coordinator.type(bytes)` (275-276). Paste goes through SwiftTerm's `pasteText`
  (TerminalSurface.swift:168-169) and comes back as input; whether a paste arrives as one
  byte array (mosh's >100-byte rule) was not checked.
- Where an overlaid copy enters, as in mosh: between "newest remote framebuffer" and
  `SurfaceFeed.feed(to:)` — i.e. in the session before `.screen`, or in
  `show(_:)`/`tick()` on the app side. `App/` belongs to the charlie session (CLAUDE.md).

## 5. Resume

- Quiesce/resume: `MoshSession.quiesce` / `resume` (MoshSession.swift:221-236) ->
  `MoshConnection.quiesce` / `resume` (MoshConnection.swift:189, 215). Export:
  `MoshSession.exportState` (249-263) -> `MoshConnection.exportState` (230). Import:
  `MoshSession.init(restoring:...)` (121-141). Cold start: `ResumeCoordinator.coldStart`
  (ResumeCoordinator.swift:271), background/foreground (478, 506); invariants C1-C13
  (docs/RESUME.md:94-116).
- What is stored: the transport snapshot (pending input, held remote states as received,
  counters) and the clipboard policy (SessionTypes.swift:109-117; byte format
  docs/RESUME.md:370-425). Nothing displayed-only is in it.
- Must reset the engine: an import/cold start (new process; state numbers restart at the
  reserved limit, R2, so stored frame numbers would be wrong; the monotonic clock is a new
  epoch after a reboot); a resize (mosh: stmclient.cc:418); a paste (stmclient.cc:325-328).
  Quiesce/resume in one process keeps numbers but sends nothing in between; mosh has no
  equivalent, so what happens there is a design decision.
- Why predictions are never stored: they are not server state. A cold start shows the
  stored screen as `isLive` false (MoshSession.swift:172-176), built from the stored remote
  states (docs/RESUME.md:370-425); a stored guess would be shown as if the server had drawn it, and its expiry frames and timestamps mean nothing in the new
  process.

## 6. Clipboard, title, bell

- Clipboard: `ClipboardPolicy.observe(_:live:)` (`Sources/MoshSession/ClipboardPolicy.swift:87`)
  is called with the *remote* framebuffer's clipboard in `reportNewestScreen`
  (MoshSession.swift:378), at restore (176) and export (257). Must keep seeing remote
  states only, once per state (C13, docs/RESUME.md:116).
- Bell: the app counts `update.framebuffer.bellCount` (TerminalViewController.swift:705-706,
  `App/IOSMosh/BellHaptic.swift:19-27`), live updates only.
- Title: not in the feed (SurfaceFeed.swift:42-43; DisplayDiff.swift:87 and 92 skip bell and
  title when `surface`). mosh's title engine (`prefix_window_title`, our
  Framebuffer.swift:451-457) and notification bar (row 0, terminaloverlay.cc:182-207) are
  separate overlays in `OverlayManager::apply`; prediction itself writes only cells and the
  cursor (cc:43-72, 141-157), never title, clipboard or bell count.
- Mouse mode for swipe paging is read from `update.framebuffer.ds` (TerminalViewController.swift:704).

## 7. Constraints and the test tool

- iOS: `platforms: [.iOS(.v18), .macOS(.v14)]` (Package.swift:17); no `Foundation.Process`,
  no Linux-only API outside `#if` (CLAUDE.md Rules). MoshTerminal imports only Foundation
  (Cell.swift:4, for `NSLock`). Swift 5 language mode (Package.swift:67).
- moshcli reads the screen through `ScriptedSession`'s driver: `screen()`
  (`Sources/moshcli/ScriptedSession.swift:76-80`) = `MoshSession.screen()` or
  `ResumeCoordinator.screen()`; `expect-screen` polls `visibleText(of: driver.screen().framebuffer)`
  (ScriptedSession.swift:383-396; command parse ScriptCommand.swift:14, 151-156);
  `dump-screen` writes `screenRows()` (ScriptedSession.swift:533-542; ScriptCommand.swift:31, 180-181).
  Both see the remote state, never an overlay.
- Options: session tuning names `--server-size`, `--no-reply-ms`, `--loss`
  (`Sources/moshcli/SessionOptions.swift:84, 101-112`). `WireTap.open` wraps every socket
  (`Sources/moshcli/WireTap.swift:66`; loss at 92-100; used at ScriptedSession.swift:211, 520):
  the existing place where a client-side delay could sit, below the transport
  (`DatagramTransport`, `Sources/MoshTransport/DatagramTransport.swift:26-38`).
- `scripts/itest.sh` dispatches cases at 84-110 (`mosh_itest` cases at 85-87).
- Oracle: `Tools/mosh-oracle/build.sh` links libmoshstatesync, libmoshterminal,
  libmoshprotos, libmoshutil (18, 36-38). `terminaloverlay.cc` is in no library: it is
  compiled only into `mosh-client` (frontend/Makefile.am:18), and it includes
  `network.h` and `transportsender.h` (terminaloverlay.h:37-38) and calls
  `Network::timestamp()` (network.cc:596, frozen time).

## Facts the designer must not get wrong

1. No code outside MoshTerminal can write a cell today (`Framebuffer.rows`, `Row.cells`
   `internal(set)`, `makeRowUnique` internal: Framebuffer.swift:243, Cell.swift:170,
   Framebuffer.swift:305).
2. mosh's `new_user_byte` reads the last *shown* (overlaid) frame, not the remote state
   (stmclient.cc:287, 334).
3. `cull` runs inside `apply`, every displayed frame; apply is not a pure function
   (terminaloverlay.cc:333-339).
4. `local_frame_sent` is read before the bytes join the state (stmclient.cc:322);
   our `type` can send within the same call (MoshConnection.swift:268-272).
5. The engine reads `send_interval` (20...250, ceil(SRTT/2)), not SRTT
   (cc:456-467; ours RTTEstimator.swift:54-57, not exposed above TransportCore).
6. Late ack = newest remote state's echo ack; early ack = acknowledged sent state; both
   are refreshed after every received datagram (stmclient.cc:298-300).
7. MoshTransport and MoshTerminal must not import each other; `MonotonicClock` is in
   MoshTransport; time enters MoshTerminal only as a number.
8. The app draws only when the remote number changes (TerminalViewController.swift:938),
   and `SurfaceFeed.lastShown` becomes whatever was fed (SurfaceFeed.swift:108).
9. Clipboard policy and bell must keep seeing remote states only (MoshSession.swift:378,
   TerminalViewController.swift:705).
10. State numbers jump at import (RESUME.md R2); predictions and engine state are never in
    a snapshot; reset on resize and paste as mosh does (stmclient.cc:325-328, 418).
11. mosh's engine calls glibc `wcwidth` without the ISO 8859-1 shortcut (cc:746); ours is
    `WCWidth.wcwidth` (WCWidth.swift:16).
12. The oracle does not contain `terminaloverlay.cc` today (build.sh:18, 36-38).
13. A copied overlay row keeps its generation; `DisplayDiff` scroll detection depends on
    identity and generation (DisplayDiff.swift:175-196, 394).
