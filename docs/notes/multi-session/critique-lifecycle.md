# Critique of DESIGN.md: session lifecycle and resume invariants

**Status (2026-11-21, after the second pass): FINISHED, with the limits listed under "Not
covered".** Two reviewers wrote this file. The first pass (LC-1 to LC-10, "What held" 1 to 9) was
stopped half way by the usage rule. The second pass read what the first had left and added:
LC-11 to LC-19; dated notes under LC-2, LC-3, LC-4 and LC-6 (the first pass's own text is
unchanged); three sections of answers after the findings (mosh's own behaviour, the stream, the
maps; the answer on the steps is LC-18); "What held" 10 to 22. Nothing of the package or the app
was built or run. One Swift file was compiled and run in the Linux dev container (the stream
experiment; it is in `out/yellow/scratch/asyncstream/`, which is not in git). `BRIEF.md` is not
changed by anything here; where a proposed change touches a brief item it says so in capitals.

**Line numbers.** All code references are to `b5aec27`. During the second pass other work changed
`App/IOSMosh/TerminalViewController.swift`, `UITestSupport.swift` and
`App/IOSMoshUITests/ResumeUITests.swift` (commit `376c583`, on `main` now): the command consumer
and `perform` (TVC:285-320) got a UI-test hook, and everything below TVC:140 moved by 2 to 40
lines. See LC-19.

**Covered, second pass:** mosh 1.4.0 in `.refs/mosh/src`: `network/transportsender.h` and
`transportsender-impl.h` in full, `networktransport-impl.h` 60-206, `network.cc` 255-360 (and
248-249, 623-631 by search), `network.h` 58-70 and 128-140, `frontend/mosh-server.cc` 150-409 and
596-969, `stmclient.cc` 250-260 and 510-545, `terminal/terminaldisplay.cc` 66-100. In `Sources/`:
`TransportCore.swift`, `MoshConnection.swift`, `TransportTypes.swift`, `RTTEstimator.swift`,
`NWDatagramTransport.swift`, `ResumeCoordinator.swift`, `MoshSession.swift`, `FileBackedGate.swift`,
`SessionRecord.swift`, `SessionStore.swift` (all in full), `POSIXDatagramTransport.swift` 80-199,
`Counters.swift` 60-191, `MoshTerminal/Cell.swift` 120-215, `Serialization.swift` 1-60,
`MoshBootstrap/MoshServerCommand.swift` 1-80. In `App/IOSMosh`, in full at `b5aec27`:
`TerminalViewController.swift`, `SessionListViewController.swift`, `SceneDelegate.swift`,
`SessionLauncher.swift`, `SessionFiles.swift`, `SessionList.swift`, `DebugLaunch.swift`,
`SceneSavePolicy.swift`, `SessionEnding.swift`, `SessionKeychain.swift`, `HealthPolicy.swift`;
`UITestSupport.swift` as it stood in the working tree, its `b5aec27` lines by search. Tests:
`ResumeCoordinatorTests.swift` 1-130, 250-364, 520-635, `ReviewFixTests.swift` 296-345,
`ConnectionIntegrationTests.swift` 222-246, the launch arguments of `ResumeUITests.swift` and
`SessionUITests.swift`. The three maps and `critique-ui.md` in full; of `docs/RESUME.md` the
statement of each invariant R1 to R21 and C1 to C13 (not the columns that name code and tests).
The Swift library's `AsyncStreamBuffer.swift` at the toolchain's tag. Design rows attacked: H3,
S5, S9, R3, E2 to E4, L1, L4 to L7, sections 4, 8.3 and 9, and "Not yet verified" 1.

**Covered, first pass** (code read at `b5aec27`, working tree = HEAD for all Swift sources):
`Sources/MoshResume/ResumeCoordinator.swift` 150-757 (all of the coordinator's logic),
`Sources/MoshSession/MoshSession.swift` 196-365, `Sources/MoshTransport/MoshConnection.swift`
160-262, `SessionStore.swift` 76-82 and 128-161, `SessionRecord.swift` 150-160,
`TransportCore.swift` 939-941, `docs/RESUME.md` 18-167 and 249-297, and in `App/IOSMosh`:
`TerminalViewController.swift` 60-885, 974-994, 1062-1076, `SessionLauncher.swift` 20-245,
`SceneDelegate.swift` 20-169, `SessionFiles.swift` 14-162, `SessionListViewController.swift`
160-294, `SceneSavePolicy.swift`. Design rows attacked: 2.3 (park, unpark), 2.4 (G1, G2), 2.5,
H1, H2, H4, S1-S4, S6-S8, S10, S11, B1-B6, X1, X2, E1, R1, R2, R4-R6, W1-W6, K1, L2, L3, F1,
sections 5.3, 5.6 and 6.

**Not covered** (true now, after both passes):

1. Nothing here was run on Apple's runtime. The stream experiment ran on Linux only; whether a
   datagram handed to an `NWConnection` just before `cancel()` leaves the phone (LC-2, the note's
   option A) is not known; every statement about UIKit's order of calls (`viewDidDisappear` after
   the pop's animation, the keyboard during a pop in LC-15, `attach` while the scene is inactive
   in LC-1) is read from the code's own comments or reasoned, not seen.
2. `docs/PLAN.md` section 3 was not re-read (N1 to N4 as `docs/RESUME.md:38-41` and the transport's
   comments state them), nor `docs/MAC.md` M5 to M8, nor `docs/RESUME.md` outside its two tables.
   Under `Sources/`, not opened: `Storage.swift`, `SnapshotCodec.swift`, `SessionMeta.swift`,
   `RecordProtection.swift`, `Outbox.swift`, and `MoshBootstrap` beyond the server command.
3. UI tests: only the launch arguments of `ResumeUITests` and `SessionUITests` were read.
   `SessionListUITests`, `HostUITests`, `SSHBootstrapUITests` and `LocalEchoUITests` were not, so
   the line numbers that 8.3 and `map-list.md` section 4 give for them are unchecked, and
   `scripts/mosh-spawner.py` was not opened (other work is changing it).
4. Sections 4.1 to 4.3 and 4.7 (how rows look, identifiers) only where they decide what a tap or a
   swipe acts on; the cost of the preview's decode was not measured.
5. `SessionPreview`, `SessionActivity`, `SessionEnder`, `SessionSlot` do not exist yet: what is
   said about them is said about the design's words.

**What the first pass left, and where it is answered now** (its list, kept as it wrote it; each
item is closed by the second pass unless "Not covered" above names it):

1. **No mosh source was opened.** Every mosh citation of the design is unchecked by me
   (`network.cc:304-350`, `mosh-server.cc:368-370`, 682, 890-893, 915-917, `transportsender.h:56-57`,
   `transportsender-impl.h:384-391`, `terminaldisplay.cc:74-77`). Two facts are needed for findings
   below and are marked there: whether mosh-server exits by itself when its own shutdown is never
   acknowledged (LC-6, S11), and how long the sender holds typed input before the first send (the
   size of the window in LC-2).
2. `map-core.md`, `map-lifecycle.md`, `map-list.md` were not read; assumptions A1 to A25 are
   unchecked. `docs/PLAN.md` section 3 was not re-read (N1 to N4 are taken from
   `docs/RESUME.md:38-41`), nor `docs/MAC.md` M5 to M8.
3. Not read: `FileBackedGate.swift`, `SessionRecord.save`, `TransportCore.startShutdown` and
   `sendPendingNow`, `SessionList.swift`, `DebugLaunch.swift`, `UITestSupport.swift`, and the tests
   the design cites (`ResumeCoordinatorTests.swift:341-346`, 601-632). R1 to R6 are relied on as
   `docs/RESUME.md` states them.
4. Rows not attacked beyond a first reading: H3, S5, S9, R3, E2-E4, L1, L4-L7, section 4, 8.3,
   and section 9 (whether each step is safe alone, in particular step 7's "launch by the last
   looked-at id, else the newest" before step 8 exists).
5. "Not yet verified" 1 of the design (`AsyncStream` hands out what was yielded before
   `finish()`): not checked.

## Findings

| id | severity | section | one line |
|---|---|---|---|
| LC-1 | major | 4.5, S1, S2, H2, W1 | A scene resign that falls into an open's `await settled()` reaches no screen; the screen made afterwards starts its session unsaved, and a kill off screen ends in the fallback (brief item 9) |
| LC-2 | major | 2.3, B1, 6 | The park stores input the server has not acknowledged and nothing sends it until the session is next opened: a command typed just before "‹ Hosts" can wait for hours, unseen. A price the brief does not list |
| LC-3 | major | 6, R1, W4, L3, 2.5 | "End Session" on the dotted parked row leaves the record dirty for up to 10 s while `lastLookedAt` still names it: a death in that time makes the next launch start a new session on that host by itself |
| LC-4 | major | B5, 2.3 | A park whose save fails closes the coordinator: a session that was healthy in memory is lost for good. Today a failed save costs nothing unless iOS also kills the app |
| LC-5 | minor | 2.4, 5.3, 5.6 | The coordinator of a `.resumed` screen that is left, or never shown, before `attach` is in no slot, is closed by nobody and is no "release": the next tap meets "Session Not Available Now", which G2 was to prevent |
| LC-6 | minor | B1, B4, X1 | `exit` and back before the app hears of the end: the park leaves a row "Ended, server not yet stopped" for a session the server ended itself; today that leave deletes the record |
| LC-7 | minor | 2.2, 3.4 R6, W6 | "Opening" blocks taps only: a swipe on the row being opened and the launch's retry at `sceneDidBecomeActive` both get through; the retry can put two terminals on the stack |
| LC-8 | minor | 2.5, 8.1, 8.2 | `forget` rewrites the links file only when a link was removed, so `lastLookedAt` of a session without a saved host is not cleared; and the negative control of the UI test "Only parked ones" cannot fail |
| LC-9 | minor | 3.4 R4, 6 step 5 | "End Session" on an unreadable row takes the SSH way and, on a host without a pid, forgets a record that may be clean and resumable: the rule section 6 step 5 states and R4 breaks |
| LC-10 | doc | 6 step 5 | "clean again: nothing was received, so the save is valid" gives the wrong reason; datagrams were sent in those 10 s and the save is valid by C5 and R5 |
| LC-11 | major | B3, L3, 2.5 | A fallback he backed out of, or whose bootstrap failed, comes back at every launch: `lastLookedAt` still names the dirty record, so each launch logs in by SSH and starts a mosh-server by itself. Today the first back ends that |
| LC-12 | minor | B1, 2.3, S11 | A new session that never heard its server is parked as "resumable": the 15 s "no reply" diagnosis is gone for good (a resumed session has none) and its server exits by itself after 60 s |
| LC-13 | minor | 2.3 table, B5 | "`start()` failed: clean as before" is wrong when the failed counters change wrote one slot: the park answers `.clean`, the record is dirty, and the retry that saves the session today never comes |
| LC-14 | minor | E3, E4 | "End Session" from the menu during a fallback forgets the old record whatever the kill said, and says nothing; the same record ended from its row is kept, with the reason |
| LC-15 | minor | 2.3, B1 | If the pop takes the keyboard away before `viewDidDisappear`, every park first sends a Resize and saves the screen at the other size (UIKit behaviour, not run) |
| LC-16 | minor | L1, L4, 7 (`DebugLaunch`) | Debug servers and parked records: "once per process" does not stop a second record under the same key at the next launch (the shape of N1, as A21), and L1 does not say when `-debugMosh*` starts |
| LC-17 | minor | H3, 8.1, 8.2 | The port message: the app's command has `-s`, so mosh prints five lines, not three, and only "Failed binding to" is not translated; in a fallback the old server still holds its port; right after "End Session" the port is still taken |
| LC-18 | minor | 9 | Steps 0 to 7 lose nothing that today's app keeps, with three things to write into the plan: step 7 must empty the slot in today's `endSession()`; its "Ending…" swallows the tap on the host that today starts a new session; the first launch of step 8 shows the list once |
| LC-19 | doc | 2.3, 3.1, 8.1, conventions | Citations to correct ("three times", the three lines of H3, two mosh ranges, one sentence of a map), and the terminal screen's line numbers have moved under the design |

No finding is critical: none loses a session or resumes a wrong record on a path a user reaches
in normal use. No sequence was found that sends under a record whose stored state is older than
what was sent (see "What held").

*Second pass, 2026-11-21:* that still holds with LC-11 to LC-19. Two of the new ones describe
behaviour the brief does not: LC-11 (the app starts a session by itself at every launch after he
went back) and LC-12 (a session that never connected listed as resumable). They lose nothing and
are rated like LC-2 and LC-3, which have the same character; both need the owner's word. The
most dangerous open findings, in order: LC-2 (with its note: on the phone even "sent" may not
have left), LC-11, LC-3, LC-1, LC-4.

### LC-1 (major): a resign during an open reaches no screen

**Design text.** 4.5: "'opening' set; in a main-actor task: settle, then the row's action". W1:
"the app leaves the foreground | a terminal on screen | today: `current?.sceneWillResignActive()`".
W2 and W3 say "nothing" for the list and for a park in flight. No row has "an open in flight".

**Code.** The resign goes to `TerminalViewController.current` only (SD:42-44); `current` is set in
`viewDidLoad` (TVC:202) and the design clears it at leave (5.3). A new screen has a fresh policy:
`resigned = false` (`SceneSavePolicy.swift:12`). `attach` queues the save only if
`resigned || sceneInBackground`, and `sceneInBackground` is `activationState == .background`
(`SceneSavePolicy.swift:28-30`, TVC:697). `App/IOSMosh` handles no `sceneDidEnterBackground`
(searched; only `DeviceProbe` observes the notification). Today a tap makes the screen with no
suspension in between (VC:168-189), so today the hole exists only at launch.

**Scenario.** Back from A (park in flight). Tap B: "opening", `await settled()`. He pulls down
Control Center (or starts the Home gesture): the scene resigns, `current` is nil, nobody notes
it. The settle returns, B is cold-started and pushed; its `attach` runs while the scene is
inactive but not yet "background": no save is queued, `begin` calls `start()`: "dirty", first
datagram (RC:451-466). He locks the phone from there. No second resign comes, the app has no
background callback: B is live and dirty in the background; `isAppActive` is still true (TVC:137),
so the health check also runs on. iOS kills the app: at the next launch B is the last looked-at
session and dirty: L3, the banner, a new session; with a known pid the old shell is killed.
**Wrong outcome:** a kill off screen did not resume (brief item 9). The same for H2 (a new
session's `attach`).

**Failing test.** Unit: a pure gate for `open` ("after the settle, with the scene not active: no
open") and, on today's type, `SceneSavePolicy().saveAtAttach(sceneInBackground: false)` for a
screen made after a resign: it answers false, which is the hole.

**Smallest change.** After `await settled()` and before the cold start, `open` (and the host tap)
checks that the scene is `.foregroundActive`; if not, the tap is dropped and "opening" cleared.
Nothing was opened yet, so nothing has to be undone. From the check to the push there must be no
suspension. Add the row to 3.5.

**Verified:** the code lines yes; that `viewDidAppear` and `attach` run while the scene is
inactive is UIKit behaviour I did not run.

### LC-2 (major): the park strands unacknowledged input

**Design text.** 2.3 step 2: "The consumer first runs whatever was queued before (typed bytes, a
resize) … Then, for `.park`: `await coordinator.enterBackground()`". Summary 9: "Price, as
accepted in the brief: no bell and no badge".

**Code.** `enterBackground()` calls `session.quiesce()` (RC:501-505), which "stops all sends and
closes the sockets" (`MoshConnection.swift:189-194`). The variant that first "sends the
unacknowledged input now" is `quiesceAfterSend()` (`MoshConnection.swift:196-213`), reached only
with `enterBackground(afterSend: true)`, a test seam (RC:481-484). Its comment states the model:
"A snapshot taken afterwards holds input the server may already have … a resume delivers such
input exactly once". So input that was taken (RC:596-598) and not yet acknowledged is in the
clean snapshot and is sent again only at the next `start()` of that record.

**Scenario.** On a poor link he types `./deploy.sh` and Return in session A and taps "‹ Hosts" to
watch session B. The datagram with the Return is lost (or not yet sent). A is parked clean. The
deploy does not start. He watches B for an hour. The row of A previews the screen as the park saw
it. When he taps A, or ends it from its row (section 6 step 3 calls `start()`, which sends the
stored input before the shutdown), the command runs then. **Wrong outcome:** nothing is lost by
the invariants, but typed input is delivered at an unbounded later time with no sign of it.
Today this needs Home right after typing, with the whole app away; with parking he stays in the
app and expects the session to "keep running on the server" (brief item 6).

**Failing test.** Extend the unit test "The park itself" with a real server and a held-back
datagram (the reader held back as `ExportClipboardTests` does, or netem): `type("touch M\n")`,
park at once, assert the file exists on the server within 2 s while the record stays closed.
Fails with the plain park.

**Smallest change (THIS TOUCHES BRIEF ITEM 6, "saved exactly as the app saves a session today …
only the session on screen talks to its server": IT NEEDS THE OWNER'S WORD).** In the park,
before `enterBackground()`: while `await c.unacknowledgedInputCount() > 0` (public, RC:741) wait,
at most about 1 s, then save as designed. No core change. If he says no: put the price beside
bell and badge in the summary and in `docs/RESUME.md`, and show "input not yet delivered" on the
row.

**Verified:** yes for "unacknowledged input stays in the snapshot until the next start". Not
verified: how long the sender holds input before its first send (not read; see "Not covered" 1).

**Note, 2026-11-21 (second pass): the size of the window, and what the app could call.**

*How long typed input is held.* mosh's client sets the sender's collection delay to 1 ms
(`frontend/stmclient.cc:257`; the sender's own default is 8, `network/transportsender-impl.h:64`).
New input goes out at the later of "first unsent change + 1 ms" and "last datagram + send
interval" (`transportsender-impl.h:101-107`); the send interval is half the smoothed round trip,
within 20 to 250 ms (`transportsender-impl.h:73-83`, `transportsender.h:52-53`). The port is the
same, line for line: `clientSendMinDelay = 1` (`TransportTypes.swift:11`; the app passes no other
configuration, `MoshSession.swift:108`, 158), `TransportCore.swift:485-488`,
`RTTEstimator.swift:54-57`. Before the first round-trip sample of a life the estimate is 1000 ms
(`RTTEstimator.swift:18-20`; mosh `network/network.cc:248-249`), so the interval is 250 ms: for
every new session and for **every unpark** until the server's first answer
(`TransportCore.swift:158-160`). So input is at most about 250 ms old when its first datagram is
made (more only when the gate must write: about once per 1,024 states, and 1 s per failed write,
`TransportTypes.swift:30`).

*The park cuts that short: such input is never sent, not sent late.* The send is a timer of the
connection (`MoshConnection.swift:471-482`), and `quiesce()` cancels it (189-193). In the consumer
the park's `enterBackground()` follows the queued input with no pause. What lies between a key
and the park on the phone is the pop itself (`viewDidDisappear` comes after its animation: UIKit,
not measured here). In a UI test with animations off (SD:20-25) and in the unit test proposed
above nothing lies between, so that test fails every time, not sometimes.

*Sent, not yet acknowledged.* One round trip plus the server's own wait, at most `ACK_DELAY` =
100 ms when it has nothing else to send (`transportsender.h:55`, `transportsender-impl.h:97-99`).
A lost datagram is repeated RTO + 100 ms after the last send, RTO within 50 to 1000 ms, so after
150 ms to 1.1 s (`transportsender-impl.h:114-116`, 284; `network.cc:623-631`; the port:
`TransportCore.swift:495-496`, 523), and only while a new server state arrived within the last
10 s; after that only with the 3 s acknowledgment (`TransportCore.swift:609`, 646). Stranded by a
park is therefore: all input whose last datagram was lost and whose repeat was not yet due at the
quiesce. On a fast link two or three repeats fit into a pop; on a slow link, and in the first
second after an unpark (RTO 1000), none; without a network, everything typed since the last
answer.

*On the phone "sent" is weaker still (not verified).* The core counts a datagram as sent when it
is handed to the socket. The app's socket is an `NWConnection`: `send` queues the datagram with
Network.framework (`NWDatagramTransport.swift:150-158`) and the quiesce cancels the connection in
the same actor turn (`MoshConnection.swift:189-193`, `NWDatagramTransport.swift:161-176`). The
transport's own comments say that a send still pending at the close is completed with ECANCELED
(171-172, 222-224). Whether a datagram handed over just before `cancel()` leaves the phone is
shown by no test: the Linux tests use the POSIX socket, whose `sendto` is synchronous
(`POSIXDatagramTransport.swift:111-130`). The scene's save has the same question today; the park
makes it matter. It needs a run on the simulator (the failing test above, against the spawner).

*What the app could call before the quiesce, with public calls of `ResumeCoordinator` only and
nothing changed under `Sources/`* (asked of this pass as input for a decision; it is not one):

- **A. One more send, then the quiesce:** `await c.enterBackground(afterSend: true)` in place of
  `enterBackground()` (RC:481-486, documented there as a test seam; it runs
  `MoshSession.quiesceAfterSend()`, `MoshSession.swift:267-271`, `MoshConnection.swift:200-212`,
  `TransportCore.sendPendingNow`, `TransportCore.swift:400-421`). If anything typed is
  unacknowledged, one instruction with all of it, built on the acknowledged state, is handed to the
  socket at once, whatever the three timers say; then the quiesce, with nothing read. It closes
  "never sent" and gives lost input one more try. It does nothing when that datagram is lost too,
  when there is no socket (`MoshConnection.swift:203-207`: made, counted, dropped) or when the gate
  cannot write. Cost: at most one instruction (a new state number only if that input was never
  sent, `TransportCore.swift:619-626`); no wait; no new state in the app; C10 unchanged (a record
  already clean sends nothing, RC:498-500). That such a save delivers the input exactly once after
  the resume is tested on Linux (`ResumeCoordinatorTests.swift:621`, `ResumeIntegrationTests`,
  `SendPendingNowTests`). Open: the `NWConnection` question above decides whether A does anything
  on the phone.
- **B. Wait for the acknowledgment, with a limit:** before `enterBackground()`, ask
  `await c.unacknowledgedInputCount()` (RC:741, `MoshSession.swift:400`,
  `MoshConnection.swift:327-329`, `TransportCore.swift:901`) until it is 0 or a time is up. No event
  says "acknowledged" (and `events` has one reader, the screen's), so it is a poll. Cost: the park
  lasts up to the limit longer and G2 holds every tap, every new session and every "End Session"
  that long; the row says "Saving…" meanwhile; the session sends and receives after its screen is
  gone (brief item 6, as the finding says); a death in that time leaves the record dirty where
  the plain park had saved it. **The count never reaches 0 for a session whose server does not
  answer** (one pending Resize is enough; for a new session the first Resize counts until the
  first answer, `TransportCore.swift:140-143`): every park of a silent session costs the full limit,
  unless the wait is skipped when `contactAges().sinceLastAuthenticDatagram` (RC:739) is nil or
  old. New state: the limit and that rule; nothing stored. With mosh's timing 1 s covers up to
  six repeats on a fast link, one or none on a slow one, and none in the first second after an
  unpark.
- **C. Both:** B, then A when the limit is reached.
- There is no call that makes delivery certain (it is UDP), and none that says whether pending
  input was ever sent: the coordinator shows the count, `retransmissions()`, `datagramsSent()` and
  `acknowledgedStateNumber()` (RC:741-744), not the last sent state.

The "at most about 1 s" of the smallest change above is option B; what it costs for a silent
session is not in that text.

### LC-3 (major): an interrupted "End Session" on the dotted row starts a new session at launch

**Design text.** Section 6 step 3: "`try await c.start()`"; step 4: "Wait up to 10 s". W4: "a
death before `shutdown()` leaves 'dirty' (a row)". 2.5: `lastLookedAt` is cleared by `forget` and
`removeOrphans` only. L3: a dirty last looked-at session opens "the fallback screen over the
list".

**Code.** `start()` of a restored session writes "dirty" (RC:451-453); "ended" comes only in
`runShutdown` (RC:647-665). A dirty record is `.fallback(.dirty)` with a new session wanted
(RC:397-398, LA:96-100), and the launch pushes the fallback screen (SD:94-110), which bootstraps
and kills the old server if its pid is known (TVC:496-503, 585-598).

**Scenario.** He leaves session A (dotted, parked), swipes its row, "End Session". Steps 1 to 3
run; the host answers slowly. Within those 10 s the process dies (force-quit, a crash, or the
app is suspended at the end of its background time and killed later). Next launch:
`lastLookedAt` is A, A is dirty: L3. **Wrong outcome:** the app shows "Previous session could not
be resumed. Starting a new one." and opens a new shell on the host of the session he asked to
end; on `hg` (no pid) the old server stays as well. The same if the death falls between step 8's
kill and its `forget` (the record is then clean, the server gone: resumed, probed, replaced).

**Failing test.** UI: a parked dotted session, its server stopped with SIGSTOP, swipe, End
Session, terminate the app after 3 s, launch: expect the list and the row "Could not be resumed",
no `connectProgress`. With the design as written the fallback screen opens.

**Smallest change.** `SessionEnder.end` clears `lastLookedAt` when it names the id, before the
cold start; E1's leave does the same. This follows brief item 8 ("if it cannot be resumed, the
list") and changes nothing else. Add the row to W4.

**Verified:** yes, in the code lines above; the scenario itself was reasoned, not run.

**Note, 2026-11-21 (second pass).** The same root, a dirty record that `lastLookedAt` still names,
is reached without "End Session" at all: LC-11. Two more ending paths need this finding's change.
E3 and E4 call `SessionFiles.forget` and go on when it answers false (TVC:398-402, 438-441: a
record still held by a run-time fallback's `abandon()`, or a delete that fails). And E1's "ended"
mark may not reach the disk: the flag is set, the write fails, the record stays "dirty"
(RC:560-567). So the rule should be: every leave with `endRequested`, and `SessionEnder.end`,
clears `lastLookedAt` first if it names that id. If that id is also the one the launch is waiting
for (L5), the wait and the line "A session is waiting" go with it: W6 as written would otherwise
open, at the next activation, the session he just tried to end, once the ender has closed it
"kept". The same for "Forget" on the waiting row (`forget` clears the id, nothing clears the
line).

### LC-4 (major): a failed save at a park destroys a live session

**Design text.** B5: "`enterBackground()` → `.notResumable`; `close()` | the row 'Could not be
resumed'; a tap is S4 | the safe direction (R7)".

**Code.** A save can fail on storage (`.notResumable(.failed)`, RC:549-553: disk full, a failed
full sync, R21). Today the session then simply goes on from memory at `enterForeground()`
(RC:516-533); the dirty record matters only if iOS kills the process. The park's `close()`
(RC:704-712) throws that memory away; a dirty record is never resumed (C4), and S4 starts a new
session and kills the old server.

**Scenario.** The disk is full. Back from A: the snapshot's replace fails. The park closes A.
**Wrong outcome:** A's shell and what runs in it are unreachable from the phone for good, though
the app was in the foreground with a working session a moment before. "Safe" holds for N1 to N4
only.

**Failing test.** Unit, with a `storageHook` (RC:155) that fails the snapshot write once: park,
then expect that the session can still be reached (after the change: the second try saved it
clean). As designed: dirty and closed.

**Smallest change.** In the consumer: on `.notResumable(.failed)` call `enterBackground()` once
more after a short pause (it saves again: `savedClean` is false, RC:498-507) before `close()`.
If it fails again, close as designed and log the reason for the row. Keeping the coordinator
open instead would need a re-attach path the design does not have; not proposed.

**Verified:** yes in the code; no failing write was produced.

**Note, 2026-11-21 (second pass).** LC-13 is the same class for a `start()` that failed: there
the park even answers `.clean`.

### LC-5 (minor): a `.resumed` coordinator that never reaches `attach`

**Design text.** 5.3, row 2: "no | no | — | no | `cancelStart`". 5.6: the consumer parks what "the
slot still holds". G2: every release is tracked.

**Code.** An unpark's coordinator sits in `start: .resumed(c, host)` until
`startSessionIfNeeded()` finds a view size, from `viewDidAppear` (TVC:331-335, 482-495);
`self.coordinator` is nil until `attach` (TVC:680). Today's leave returns at `guard let
coordinator` (TVC:404) and `deinit` closes only `self.coordinator` (TVC:189-193). The lock is then
freed only when the screen is deallocated (`SessionRecord.swift:157-159`,
`SessionStore.swift:80-82`).

**Scenario.** A screen pushed while the scene is not active (LC-1), or popped before its
`viewDidAppear`, or a `.resumed` result that `open` does not push because the list is no longer
the top screen after the settle. `LeaveAction` says `cancelStart`; nobody closes `c`; no release
is registered. A tap on the row at once: `.retryLater(.inUse)` (RC:388-389), "Session Not
Available Now"; "Forget" fails. The record itself stays clean (C1: nothing was written).

**Failing test.** `LeaveAction.decide` with a `.resumed` start that was not attached must give
`park`; today's table gives `cancelStart`.

**Smallest change.** The slot holds the coordinator from `init` for `.resumed`; `hasCoordinator`
reads the slot. The park then answers `.clean` with nothing written (C11, RC:490-497) and closes,
as a tracked release. Say in 4.5 what `open` does with a `.resumed` result it does not push:
`close()`.

**Verified:** yes in the code; the UIKit orderings were not run.

### LC-6 (minor): the server's end racing a park

**Design text.** B1: a session attached → park. B4 applies only when `serverEnded` is already set.

**Code.** `serverEnded` is set when the app handles `.serverEnded` (TVC:763-766, 800-801). The
coordinator marks the record ended earlier (RC:719-721), and an export of an ended session is
refused (`TransportCore.swift:939-941`, RC:545-548). After the park's `close()` no event reaches
the app (`guard !closed`, RC:717), so `finish(c, .forget)` (TVC:689-693) never runs. Today the
same leave ends in the "refused" branch, which deletes the record (TVC:432-442).

**Scenario.** `exit`, Return, and "‹ Hosts" within the round trip. (a) The end is known to the
coordinator: the park answers `.notResumable(.ended)`; the row says "Ended, server not yet
stopped" until the next launch or a swipe, though the server ended the session itself. (b) The
end has not arrived when the socket closes: the record is clean, the row "resumable"; a tap
shows the stored screen and, with a known pid, the probe replaces it with a new session after
15 s. (b) exists today for Home after `exit`; whether the server then exits by itself was not
checked in mosh's source.

**Failing test.** Unit with a real server: the server ends the session, the event reader held
back, park: expect no record left.

**Smallest change.** A park whose outcome is `.notResumable(.ended)` finishes as B4 does:
`close()`, then `SessionFiles.forget`. On the park path the app asked for no shutdown, so
"ended" there is always the server's own end.

**Verified:** (a) yes in the code; (b) reasoned.

**Note, 2026-11-21 (second pass): mosh's source answers (b), and the change needs one more
condition.**

1. *mosh-server ends itself.* When its shell ends, the server starts its shutdown
   (`frontend/mosh-server.cc:842-843`), sends the shutdown state at the frame rate
   (`network/transportsender-impl.h:121-124`, 206-225; each send is counted, 332-334) and leaves
   its loop when the client has acknowledged (`mosh-server.cc:880-883`) **or after 16 sends or
   10 s without an acknowledgment** (885-888; `transportsender-impl.h:384-395`,
   `transportsender.h:56-57`). So in both cases of this finding the server is gone at most 10 s
   after `exit`. In (a) the row "Ended, server not yet stopped" is wrong in substance every time.
   In (b) the "resumable" row points at nothing: a tap is S11, and with a known pid the probe
   then starts a new session by itself for a session he ended with `exit`, the very thing review
   M6-3 took out of the terminal screen (`HealthPolicy.swift:6-8`); on `hg` it is "Last contact"
   for good. The same is true of every parked session whose shell ends later by itself (a job
   followed by `exit`, a shell's idle logout): nothing tells the parked record.
2. *The reverse does not happen.* A server whose client never comes back stays. Its only idle
   exits are `MOSH_SERVER_NETWORK_TMOUT` and `MOSH_SERVER_SIGNAL_TMOUT`, which are off unless set
   in the server's environment (`mosh-server.cc:383-409`, 696-706, 857-878), and the 60 s rule,
   which applies only while no client state ever arrived (682, 914-919). Brief item 6, "they keep
   running on the server", holds for any length of time.
3. *Correction to the smallest change.* `.notResumable(.ended)` does not only mean "ended". It
   is also what a save answers for a record that was **given up** (RC:98-99 and 539; `giveUp()`
   sets the same flag and writes "dirty", RC:572-579, after `.baseStateLost` or `.halted`,
   RC:722-724). Such a record owes a new session and its server is alive: forgetting it on the
   park's answer would take it off the list with no fallback and no kill by identity. So: after
   the park's save, read `await c.recordState` (RC:734) before `close()` and forget only on
   `.ended`. (One more way to "ended" is not the server's end either: a save that meets a halted
   transport before the event about it is handled writes "ended", RC:545-548 with
   `TransportCore.swift:940-942`. That is an internal error; it is named so that "always the
   server's own end" is not taken as proven.)
4. For (b) nothing in the app can tell later. The one moment at which it could is the park: if
   the wait of LC-2's note (option B) is taken, the server's end normally arrives inside it and
   (b) becomes (a).

### LC-7 (minor): what "opening" does not block

**Design text.** 2.2: "While it is set the list takes no other tap." R6 withholds swipes for "on
screen, being saved, ending". W6: the retry runs "only if the list is the top screen, no screen
has a session and nothing was opened since".

**Code and scenario.** (a) A swipe on the row being opened is offered. "Forget" is then refused by
the lock (SF:82-87), which is right. On a dead row the fallback screen holds no lock: R2
(`stopOldServer`, `forget`, VC:238-259) runs beside the fallback's bootstrap of the same record;
he asked to end and still gets the new session. (b) `retryColdStart` runs in
`sceneDidBecomeActive` (SD:46-52). While an open awaits the settle all three conditions of W6
hold: two cold starts, two terminals on the stack. Only the one whose `viewDidLoad` ran last is
`current` (TVC:202) and gets the scene's save; the other talks to its server off screen and is
dirty at a kill. It needs a waiting launch, which is rare.

**Failing test.** `Busy`: with `opening` set, `maySwipe` is false and `mayRetryLaunch` is false.

**Smallest change.** `Busy.opening` also withholds swipes and the retry; the wait is dropped at
the tap, not when a screen appears.

**Verified:** the code lines yes; the scenarios reasoned.

### LC-8 (minor): clearing `lastLookedAt`, and a test that cannot fail

**Code.** `forget` writes the file only `if links.removeValue(forKey:) != nil` (SF:93-94). A
session without a saved host has no entry (`links[id] = nil`, SF:48, from TVC:648).
`removeOrphans` visits only ids with a key or a link (SF:112). Built on these lines as they are,
the id of a forgotten session without a host stays in the file for good.

**Why it matters.** It is harmless at launch: the cold start of a missing directory answers
`.fallback` with `recordDeleted` (RC:296-318), which is L7, the list. For the same reason 8.2's
control for "Only parked ones" ("clearing the id in `forget`: the launch waits on a missing
record") is wrong: a missing record is never `.retryLater`, so the test passes with the clearing
removed.

**Smallest change.** `forget` writes when either the link or `lastLookedAt` changed; the unit
test covers a session with and without a link; the UI test gets another control (for example
the launch target ignoring the ended set).

**Verified:** yes.

### LC-9 (minor): "End Session" on an unreadable row

**Design text.** R4: "End Session | unreadable | as R2". Section 6 step 5: "It is never deleted
because there is 'nobody to ask' … right for a record that cannot be resumed and wrong for one
that can."

**Code.** `stopOldServer` answers `.nothingToAsk` without a host or a pid (LA:159-162),
`mayForget` is then true (LA:238-241) and `end` forgets (VC:247-248). An unreadable row may be a
clean record whose counters cannot be read now (R20, C3: never a guess).

**Smallest change.** R4 goes through section 6: its cold start answers `.retryLater` and the
user reads "Session Not Ended: it cannot be opened now". R2 and R3 stay.

**Verified:** yes in the code.

### LC-10 (doc): the reason given in section 6 step 5

"clean again: nothing was received, so the save is valid". In those 10 s datagrams were sent
(the first at `start()`, RC:466; `MoshConnection.swift:165-176`). The save is valid because it
is the ordinary one: quiesce, export, snapshot, clean mark with the export's token (C5, R5). The
record is a new snapshot, not the old one again. Step 9's reviewer will test the sentence as
written.

### LC-11 (major): a fallback he left comes back at every launch

**Design text.** B3: "back | a fallback still connecting | the bootstrap task is cancelled. The
old record is **kept** (today: old server stopped and record deleted, TVC:390-403)". 2.5:
`lastLookedAt` is "Cleared by `SessionFiles.forget(id)` and `removeOrphans`". L3: "a dirty last
looked-at session | cold start → `.fallback`; with a saved host …: the fallback screen over the
list". Reading 3 tells the owner that back keeps the old session, reading 1 that the launch opens
the fallback. Nothing says what the two do together.

**Code.** A fallback screen connects as soon as it has a size (TVC:496-503, 508-515, 554-584: an
SSH login, then `mosh-server new`). "Last looked at" moves only in `attach` (design 2.5), which a
fallback reaches when the new session exists (TVC:611, 675). Today a back before that deletes the
old record (TVC:390-403), so the next launch finds nothing to fall back from.

**Scenario.** The app dies with A on screen. Launch: L3, the banner, "Connecting…". He does not
want that now, or the host cannot be reached (red banner), and goes back: B3, the list, A "Could
not be resumed". At every later launch `lastLookedAt` is A and A is dirty: the fallback screen
again, a login and a server start again, by themselves. If he leaves during "Starting
mosh-server…" a server is left behind each time, which exits after 60 s (TVC:605-608; mosh
`frontend/mosh-server.cc:914-919`). It ends only when a bootstrap gets through or he forgets the
row. The same after a run-time fallback (F1) that he leaves. **Wrong outcome:** the app opens a
session by itself at every launch after he went back from it; without a network at launch he
lands on an error screen instead of his sessions. Brief item 8 ends "if it cannot be resumed, the
list".

**Failing test.** UI: a session of a saved host under `-debugCrashAfter`; the test host's sshd
stopped; relaunch (the fallback screen, an error banner); "Hosts"; terminate; launch: expect the
list and no `sessionStatus`. As designed the fallback screen opens again. A pure test cannot show
it (`launchTarget` is right to answer A while the file names A): the leave has to change the file.

**Smallest change.** `keepOldRecord` (B3) clears `lastLookedAt` if it names the old record: the
session he looked at last cannot be resumed and he declined its replacement, so the next launch
is the list. The row stays and a tap on it is S4. One line each in 5.3 and 2.5. THIS DECIDES A
CASE OF QUESTION 2 (ITEM 8 AGAINST ITEM 9 AFTER A BACK): PUT IT TO THE OWNER WITH THAT QUESTION.

**Verified:** the code lines yes; the scenario follows from the design's rows and was not run.

### LC-12 (minor): a session that never connected is parked as resumable

**Design text.** B1: "a session attached → park". 2.3's table: "a started session | `.clean` |
clean, closed | resumable".

**Code.** A new session gives up waiting after 15 s without any state from the server and says
why (`.noServerReply`, `MoshSession.swift:228-250`; TVC:767-769). A session rebuilt from a record
has no such timer (`MoshSession.swift:166-167`). `attach` makes the session the screen's as soon as
its record exists, before anything has come back (TVC:675-680). A save of a session that has
heard nothing is an ordinary clean save: the snapshot holds state 0 and the first Resize as
pending input (`TransportCore.swift:140-143`, 938-954). mosh-server exits by itself 60 s after its
start if no client state ever arrived (`mosh-server.cc:682`, 914-919).

**Scenario.** A network that drops UDP (the plan's error row "MOSH CONNECT seen, no UDP reply in
15 s"). He taps a host; the SSH part works; the screen stays black. After five seconds he goes
back. The park saves: a row "Session · last used just now", resumable. Sixty seconds later its
server is gone. A tap on the row: the black stored screen; no "no reply" message, ever; "Last
contact" after 6.5 s; with a known pid the probe replaces it after 15 s, on `hg` nothing more
happens. Today that back ends the attempt (TVC:413-415; the "ended" record is finished at the
next launch, SD:147-156).

**Failing test.** `LeaveAction.decide` for a coordinator that is not restored and has heard
nothing must not answer `park`. With a transport that drops everything (as `DeadNetwork`,
`ResumeCoordinatorTests.swift:12-40`): create, `start()`, the app's leave: expect no resumable
record. As designed: `.clean`.

**Smallest change.** One more input to `LeaveAction.decide`: "a new session that has heard
nothing yet" (the screen knows: no `.contact` and no live `.screen` since the `attach` of a
coordinator that is not restored). That leave takes today's `shutdown` row: the record is
"ended", the request goes out, the server exits on it or after its own 60 s. THIS TOUCHES BRIEF
ITEM 4 ("DOES NOT END THE SESSION") FOR A SESSION THAT NEVER CAME UP: IT NEEDS THE OWNER'S WORD.
If he says no: the design says that such a row reads "resumable" and has lost its diagnosis.

**Verified:** yes in the code and in mosh's source; not run.

### LC-13 (minor): "`start()` failed: clean as before"

**Design text.** 2.3's table: "a resumed session whose `start()` has not run or failed | `.clean`,
nothing written (C11, RC:490-497) | clean as before | resumable".

**Code.** A restored session's `start()` fails only in `beginSending` (RC:451-456), which writes
the two counters slots one after the other and takes over the new state only after both
(`FileBackedGate.swift:246-248`, 305-311). If the first write got through and the second did not,
the newer slot on disk says "dirty", and the newest valid slot decides (`Counters.swift:148`). The
park's answer for a session that was not started reads the gate's state in memory, which still
says clean (RC:495, `FileBackedGate.swift:132-136`). `map-core.md` section 3 says so ("one slot may
already say 'dirty' … the next cold start then falls back"); the table does not. Today the screen
keeps the coordinator and asks again at the next return to the foreground (TVC:363-366, 729-734);
the gate then completes the same change (`FileBackedGate.swift:241-248`) and the session lives.

**Scenario.** A storage error in the middle of the counters change at an unpark. Banner: "could
not be started now … tried again when the app returns". He goes back. The park answers `.clean`,
sends the mark `park-clean`, closes. The list reads the file: "Could not be resumed". A tap is
the fallback: a new session, the old shell killed if its pid is known.

**Failing test.** Unit, with a storage hook that fails the second slot write of `beginSending`
(the hook of `ResumeCoordinatorTests.swift:305-325`): cold start, `start()` throws, the app's
park; assert that the park's answer and `readCounters()` agree. They do not.

**Smallest change.** For a restored coordinator whose `start()` threw, the park calls
`try await c.start()` once more before `enterBackground()` (it completes the change and sends,
and the park then saves as for any started session); if it throws again, close as designed. The
mark and the log are taken from `readCounters()` after the close, not from the park's answer.
The table row becomes "clean, or dirty if the failed change reached one slot". As rare as LC-4.

**Verified:** yes in the code; no failing write was produced.

### LC-14 (minor): "End Session" from the menu during a fallback forgets in silence

**Design text.** E3: "today's branch: old server stopped if the identity check passes, old
record forgotten (TVC:390-403) | the list; the row goes | deleted under its lock". E4: "kill by
identity, `forget` (TVC:432-442)".

**Code.** TVC:398-402 forgets whatever `stopOldServer` answered; so does TVC:438-441. The list's
"End Session" forgets only if `outcome.mayForget` and otherwise says "Session Not Ended" with the
reason (VC:244-257, LA:238-244). Today's comment gives the reason for the unconditional delete:
"a kept dirty record would start a new session at the next launch" (TVC:391-395). Under the
design a kept dirty record is a row.

**Scenario.** A dead session with a known pid on a host that cannot be reached now. He taps its
row (S4), sees it connect, opens "…", "End Session". `stopOldServer` answers `.hostNotReached`;
the record is forgotten all the same. The row goes; the old server, its shell and its programs
run on, and the pid that could have stopped them later is deleted. The same request from the row
(R2) answers "… could not be reached … The session is kept; try again later, or use Forget."

**Failing test.** A pure decision "what a leave during a fallback does with the old record"
from (`endRequested`, `OldServerOutcome`): for `.hostNotReached` it must say keep. Today there is
no decision; the code forgets.

**Smallest change.** `endDuringFallback` follows R2: forget if `mayForget`, otherwise keep the
row ("Could not be resumed"; there is no screen left for an alert, so the log says why). It
first waits for a run-time fallback's `abandon()` (B3 registers that as a release; without the
wait `forget` meets the lock when `stopOldServer` answers at once, LA:159-162), and it clears
`lastLookedAt` first (LC-3's note). E4 the same after its `close()`. These two rows are then no
longer "today's code": 3.3 and 5.3 should not call them that.

**Verified:** yes in the code.

### LC-15 (minor): a Resize on the way out (UIKit's order not run)

**Design text.** 2.3 step 1: at the leave "timers … stop (as TVC:378-388)". Step 2: "The consumer
first runs whatever was queued before (typed bytes, a resize)".

**Code.** The terminal is laid out above the keyboard (TVC:257). A change of its grid goes to
the server after 100 ms (TVC:974-981, 985-994) unless the scene is not active
(`SceneSavePolicy.announcesSize`, made after the flake of 2026-11-20: a resize that reaches a
saved session). The leave stops that timer, but the leave is `viewDidDisappear` (TVC:337-342),
when the pop is over.

**Scenario** (if UIKit takes the keyboard down with the pop, before `viewDidDisappear`: not
run). "‹ Hosts": the keyboard goes, the grid grows, 100 ms later a Resize is queued and sent;
tmux or vim redraws for the larger screen; then the park saves. The stored screen and the row's
preview are of the larger size, perhaps from the middle of the redraw, and the Resize is
unacknowledged input in the snapshot (LC-2). The unpark brings the keyboard back: a second Resize,
a second redraw. Every switch costs two redraws on the host, and a back swipe that is let go
(B6) may send the first with no park after it.

**Failing test.** UI: a session with the keyboard up and `trap 'echo resized' WINCH` in its
shell; back; tap the row: "resized" must not appear. It appears twice if the pop resizes.

**Smallest change.** Hold the size from `viewWillDisappear` when `isMovingFromParent`, the way
`announcesSize` holds it while the scene is not active, and announce it in `viewDidAppear` if the
pop was cancelled. Step 8 first checks by hand whether the pop changes the grid at all; if it
does not, nothing is needed.

**Verified:** the code lines yes; the order of UIKit's calls no.

### LC-16 (minor, debug builds only): debug servers beside stored records

**Design text.** Section 7, `DebugLaunch.swift`: "`takeFallbackRequest()`: the `-debugFallback*`
server is handed out once per process … a second one would make a second record with that key
and counters from 0, the shape of N1 (A21)". L1: "launch | no record | the list; or the
`-debugMosh*` session". L4: "only parked ones and no last looked-at id | the list. No cold start".

**Code.** Both requests are read from the launch arguments at every use (`DebugLaunch.swift:42-44`,
67-81) and become a new record with a new id and the arguments' key (TVC:486-488, 509-511,
638-666). R18 guards a directory, not a key. `-debugMosh*` is taken when the launch decided
`.nothing` (SD:71-73), which today means "no record but ended ones" (LA:45-60).

**Why it is new.** Today a debug session is ended when its screen is left, so its record and its
server rarely outlive the launch that made them, and the tests relaunch without the arguments on
purpose (`ResumeUITests.swift:55-56`). With parking a debug record stays, clean, with its server
running. A relaunch with the same arguments: (a) the launch has no target in L4, L6 and L7; if
"no target" is coded like today's `.nothing`, the debug session starts beside the parked record of
the same server: two records, one key, the second from sequence 0. (b) `-debugFallback*`: "once
per process" still allows once per launch, and the record of the last launch's fallback is there.

**Failing test.** A pure rule "may this request make a record?" from the request and the stored
records' `meta` (address and port): false when a record names that server. The design's test of
`takeFallbackRequest` ("the second call gives nil") passes while this one fails.

**Smallest change.** Both requests are refused when a stored record's `meta` has the request's
address and port (`readMeta()`, no lock), on top of "once per process"; and L1 says "no record at
all". A real host cannot repeat a key: its `mosh-server` makes a new one each time.

**Verified:** yes in the code; (a) depends on how `makeRoot` will be written.

### LC-17 (minor): the port message (H3)

Three things, none of them about a record.

1. **Five lines, three of them translated.** The app's server command always has `-s`
   (`MoshServerCommand.swift:50`), so mosh binds twice, to the SSH connection's address and then
   to any (`network/network.cc:268-286`). A full range prints "Failed binding to <address>:<last
   port>", "Error binding to IP …", "Failed binding to <any address>:<last port>", "Error binding
   to any interface: …" and "Network exception: bind: …" (`network.cc:273`, 283, 348-350;
   `mosh-server.cc:368-371`). The last word of the second, fourth and fifth is `strerror`
   (`network.h:65-68`): the host's language. 8.1 tests "mosh-server's three lines".
   `PortRangeFull.message` should match the literal "Failed binding to" in the output of a start
   that failed, and its test should use the five lines of a `-s` server in another language. That
   literal is printed for every bind error, so "no free port" is the likely cause, not a certain
   one; the message should keep mosh's own words beside it.
2. **In a fallback the old server still holds its port.** It is killed only after the new one
   has started (TVC:585-598, review M6-8). With a full range the new one cannot start, so S4, F1
   and L3 can never get through, and "end a session on this host" is the only way on: R2 on that
   dead row frees its port when the pid is known; on `hg` it cannot. In a fallback the banner
   should name the row to end.
3. **Right after "End Session" the port is still taken**, until the server has exited: at once
   with an acknowledgment (`mosh-server.cc:890-893`), up to 10 s later without. The UI test "after
   End Session on one, a new session starts" must wait for the server to leave `/sshd/servers`
   before it taps, or it meets H3 again.

**Verified:** mosh's lines yes. That the pty carries stderr to `BootstrapError.output` is the
design's own "Not yet verified" 2.

### LC-18 (minor): section 9, step by step

**Asked:** after each step alone, is the app safe to use (no session lost that today's app
keeps), and is step 7 safe before step 8? **Yes for steps 0 to 7**, reasoned from the code, with
(a) to (c) to be written into the plan.

| Step | Alone, against today's app |
|---|---|
| 0 | a test |
| 1 | safe: the id is written (file I/O on the main thread in `attach`), nothing reads it |
| 2 | safe: pure code |
| 3 | safe. Every record of a host becomes a row, also the leftovers that `group` hides today (SL:119-121): the first build he tries may show old "Could not be resumed" rows. What a tap on a session row does must be said (U5) |
| 4 | safe: a preview is decoded on the main thread while a session runs elsewhere; `RowGeneration` is locked ("What held" 17) |
| 5 | safe: back still ends, the launch is today's. "Nothing he has can break" holds |
| 6 | safe: the pop comes after `finish(c, .forget)` (TVC:689-694); the leave that follows takes today's "server ended" branch (TVC:405-411) and finds the record gone |
| 7 | safe with (a); not "same" in (b). With one session the record attached last is the one today's "newest first" picks in every flow found (a fallback attaches the new record; a tap on an older row attaches that one, and back ends it). "Else the newest as today" must also apply when the id names no record or an ended one, not only when there is no id (LC-8 leaves such ids behind) |
| 8 | the feature: LC-1 to LC-5 and LC-11 to LC-15 apply from here. On `hg`, "End Session" on a parked row forgets and leaves the server until step 9 (the design says so) |

(a) **Step 7 must empty the slot in today's `endSession()`.** Step 7 brings the slot and the
consumer that holds it, step 8 brings `leaveScreen`. 5.6's rule "the slot is emptied at leave
for every action but `park`" is written for step 8. If step 7's `endSession()` leaves the
coordinator in the slot, the consumer parks it at the end of the queue (5.6) beside today's
`end` (TVC:425-443), and the two meet at the coordinator in any order. `shutdown()`, then the
park: the request leaves, but the park's `close()` does not wait for the answer, and the row
stays "Ended, server not yet stopped". Save, then `shutdown()`, then the park's `close()`: the
request is never sent (nothing is sent while quiesced, `TransportCore.swift:336`), the record is
"ended", the server lives. Save, `close()`, then `shutdown()`: it answers false (RC:648), and
today's code takes its "refused" branch (TVC:432-442): the SSH kill and `forget`. On the test
hosts the pid is known, so in that order the server goes, the row goes and **the suite stays
green**; on `hg` the server is left. Write "`endSession()` empties the slot first" into step 7 and
let the reviewer of step 8 check it.

(b) **"Ending…" swallows the host tap.** Today a tap on the host right after back starts a new
session at once, because the record already reads "ended" (VC:170-175; the mark is written
before the request leaves, RC:647-665). Step 7 shows that record as "ending" for as long as
today's `end` runs, up to 11 s when the server does not answer (TVC:425-431), and `open` drops a
tap on a session that is ending (VC:176). Until step 8 makes the host row independent of its
sessions, that tap does nothing. Either the host tap of steps 3 to 7 ignores "ending", or the
step says so.

(c) **The first launch of the step-8 build shows the list once** when the record on the phone was
saved by a build older than step 1 (his TestFlight build, at the update after step 11): no id,
L4, the row resumable. Today an update resumes ("install and restart", `CLAUDE.md`, phone sitting
of 2026-11-21). Tell him with the build.

**Verified:** the lines yes; no step exists yet.

### LC-19 (doc): citations to correct, and lines that have moved

1. 2.3: "`ResumeCoordinatorTests.swift:601-632` already runs save, close, cold start, start
   three times". It runs three lives with two cold starts, on Linux, with `key: .recordFile`
   (625) and the POSIX socket. Nothing has yet run that sequence twice in one process with the
   app's parts (the Keychain key by id, `NWDatagramTransport`, the screen's queue); the UI test
   "Switching many times" will be the first. One more reason for U2.
2. H3 and 8.1: "three lines" are five (LC-17). `mosh-server.cc:368-370` is 368-371; B2's 915-917
   is 914-919. `map-core.md` section 5 gives `mosh-server.cc:889-892` for what stands at 890-893
   (the design has it right).
3. `map-lifecycle.md` 2.4 step 1: "queued commands not yet taken are dropped; a queued
   `.background` task would then never be ended". A finished stream still hands out what was
   queued (the stream section below); what skips those commands today is the weak reference
   (TVC:287-290), and that branch does end a `.background` task. The design builds on the right
   half (2.3 gives the weak reference as the reason).
4. `SessionList.swift:86-87` says the waiting reason is set "by `SceneDelegate` and by a tap on a
   row"; a tap sets nothing (VC:190-193). `map-list.md` has it right.
5. **The terminal screen has moved under the design.** Commit `376c583` (made by other work
   during this pass) adds a UI-test hook to the command consumer and to `perform`
   (`backgroundLayout`, `changeLayoutAfterTheSave`; `perform` now returns whether a background
   save was clean; `BackgroundLayoutChange` in `UITestSupport.swift`). Steps 7 and 8 rewrite
   exactly that code. The step agent starts from HEAD and keeps the hook (it reads the screen
   weakly and acts on `.background` only, so `.park` does not trigger it); every "TVC:" above 140
   in the design is 2 to 40 lines low, `UITestSupport.swift:110-128` is now 153-173, and the
   lines the design and `map-list.md` give for `ResumeUITests.swift` have moved too.
6. `BackgroundTask` (TVC:1062-1076) has no `deinit`: one that is dropped without `end()` is ended
   by nothing (its expiry handler holds it weakly, TVC:1066-1068). No path of the design drops
   one. A `deinit` that ends it would cost one line and cover a `.park` that a finished stream
   ever refuses (the stream section, row F).

## mosh's own behaviour (second pass)

Every mosh citation of DESIGN.md and of the maps, against mosh 1.4.0 in `.refs/mosh/src`.

| Cited for | Citation | Found |
|---|---|---|
| H3, reading 5: the first free port, else a failure | `network/network.cc:304-350` | right: the loop takes the first port that binds (314-338); after the last it prints "Failed binding to" and throws (339-350). The message names the last port tried, not the range |
| H3: exit status 1 | `frontend/mosh-server.cc:368-370` | right (368-371). Five lines with `-s`: LC-17 |
| "Not yet verified" 2 | `network.cc:348-350` | right; to stderr |
| B2, E2: a server without a client exits after 60 s | `mosh-server.cc:682`, 915-917 | right (the test is 914-919): only while no client state ever arrived |
| section 6 step 4: 10 s | `network/transportsender.h:57` | right |
| section 6 step 6: 16 sends or 10 s | `transportsender.h:56-57`, `transportsender-impl.h:384-391` | right (384-395); a send is counted at 332-334 |
| section 6 step 6: the server leaves once it has acknowledged | `mosh-server.cc:890-893` | right: it leaves when an instruction with the client's shutdown acknowledged has been sent (`transportsender.h:151`) |
| 4.2: a title only when initialized | `terminal/terminaldisplay.cc:74-77` | right |
| `map-core.md` 5: sent as fast as possible | `transportsender-impl.h:121-122` | right (121-124) |
| `map-list.md`: title fields; default range | `terminal/terminalframebuffer.h:451-454`; `network.cc:304-314`, 288; `network/network.h:136-137` | right |

**(a) Does mosh-server exit by itself?** After its own shutdown started (its shell ended): yes,
acknowledged or not, within 16 sends or 10 s (LC-6, note, item 1). When the client simply never
comes back: no, never, unless a timeout is set in the server's environment (same note, item 2).
When no client ever reached it: after 60 s.

**(b) How long is typed input held?** 1 ms after the first unsent change, and never less than one
send interval (20 to 250 ms; 250 ms before the first round-trip sample of a life) after the last
datagram; a repeat RTO + 100 ms after the last send. The port has the same numbers on the same
conditions. Lines and the consequence for the park: LC-2, note.

**(c) Can the app get pending input out before the park's quiesce with public calls only?** Yes,
two ways, neither certain: `enterBackground(afterSend: true)` (one more datagram, no wait; on the
phone it must first be shown that the datagram leaves), and a bounded wait on
`unacknowledgedInputCount()` (costs every park of a silent session the whole limit). LC-2, note.

**One more fact section 6 stands on.** The server takes the client's shutdown only if it holds
the state the instruction is built on (`network/networktransport-impl.h:97-111`: an instruction
whose base it does not hold is dropped). The port builds the shutdown on the newest ordinary
state sent within RTO + 100 ms, or else on the acknowledged one (`TransportCore.swift:512-529`,
583-598, 674-683). After "contact" the acknowledged state is one the server holds, and the 16
sends outlast the benefit of the doubt given to a newer one. So step 4's order is right for this
reason too. (`.contact` is also raised for an authentic datagram that arrives out of order,
`MoshConnection.swift:401-408`; on a new socket only a datagram addressed to its new port can
arrive, which the server sends only after it has heard this life. Reasoned.)

## The stream: what is yielded before `finish()` (second pass)

"Not yet verified" 1 of the design. **It holds** on Linux, by experiment, and the library's source
says why; the same source is built for Apple's platforms. The documentation alone does not
promise it, and nothing was run on Apple's runtime.

**The experiment.** One file, `out/yellow/scratch/asyncstream/yieldfinish.swift` (not in git; its
output is `result.txt` beside it), built with `swiftc -O -parse-as-library` and run in the dev
container (`scripts/dev.sh`): Swift 6.2.4 (`swift-6.2.4-RELEASE`), x86_64 Linux, 12 cores. Streams
are unbounded, as the screen's (TVC:149). "Complete" means every element arrived, in order, the
park last.

| | Scenario | Runs | Complete |
|---|---|---|---|
| A1 | another task yields the park and finishes at once; the consumer task was just made | 10,000 | 10,000 |
| A2 | the same after one `Task.yield()` | 10,000 | 10,000 |
| A3 | the same 100 µs later (the consumer waits in `next()`) | 10,000 | 10,000 |
| B | a slow consumer (200 µs on another actor per element); four inputs, the park and the finish arrive meanwhile | 6,000 | 6,000 |
| C | two inputs, the park and the finish before any consumer exists | 30,000 | 30,000 |
| D1 | the app's shape: a main-actor consumer that awaits another actor per command; the main actor yields the park and finishes with no suspension between; the input still queued | 15,000 | 15,000 |
| D2 | the same with the consumer away on the input | 15,000 | 15,000 |
| E | the owner of the continuation is freed right after, and its `deinit` finishes again (as TVC:183-197) | 30,000 | 30,000 |
| F | a yield **after** the finish | 30,000 | refused 30,000 times (`.terminated`); it never arrived |
| G | the consumer task is cancelled with the park already queued | 6,000 | the park arrived 6,000 times |
| G2 | the consumer task is cancelled while it waits; the park is yielded after that | 3,000 | the park was refused 3,000 times |

No element yielded before the finish was lost or out of order in 132,000 runs (A to E and G).

**Why it should hold on Apple's runtime too.** The toolchain's documentation (the `.swiftdoc` of
`_Concurrency` in the container) says of `yield`: "If nothing is awaiting the next value, this
method attempts to buffer the result's element"; of `.unbounded`: "Continue to add to the buffer,
without imposing a limit on the number of buffered elements"; of `finish()`: "After calling
finish, the stream enters a terminal state and doesn't produce any additional elements"; of
`.terminated`: "The stream didn't enqueue the element because the stream was in a terminal
state". That is consistent with the result but does not say in words that the buffer is handed
out after the finish. The source does. It is not in the container (the toolchain ships the
library, its interface and its documentation); it was read from the Swift repository at the tag
of this toolchain, `stdlib/public/Concurrency/AsyncStreamBuffer.swift`: `finish()` sets the
terminal flag and resumes only consumers that are waiting, and never touches the buffer
(210-232); `next` hands out a buffered element before it looks at the terminal flag (234-249);
`yield` to a waiting consumer hands the element over directly, otherwise appends it, and is
refused only once the flag is set (123-208). The only part that differs by platform is the lock
(15-53). The app runs the copy of this library that ships with its iOS, which may be an older
version of this file than the one read (older tags were not read). So the first run of the
simulator suite is still the proof on that runtime, and the design's own rule stands: the unit
test "The park itself" goes through the screen's real queue and consumer.

**Two rules the park needs, from rows F and G2.** Whatever is yielded to the queue after the
leave is refused without a trace. That is right for typed bytes (TVC:265-267 has no guard and
needs none), and today's other sources are guarded or stopped (TVC:352, 361, 387-388, 975,
1003); a command that carries something to be ended, as `.background` carries its task, must
never be yielded after the leave. And the consumer task must never be cancelled: a cancelled
consumer that is waiting finishes the stream (source 110-121, 252-260), and a park yielded after
that is refused. Nothing cancels it today (`commandTask`, TVC:106, is only assigned).

## The maps (second pass)

**`map-lifecycle.md`, A1 to A25:** each was checked against the code at `b5aec27` and holds as
written, with the line numbers given. (A26 to A30 hold as far as the terminal screen's and the
core's lines go; `BellHaptic.swift` was not opened.) Two details:

- A15: "`finishEnded` forget off main" is right for the launch's and the list's `Task`s only
  because `SessionLauncher.finishEnded` is a non-isolated `async` function of a plain `enum`
  (LA:37, 145-153) in a module built in Swift 5 mode (`App/project.yml:54` per the map; not
  re-read). The forgets of the terminal screen and of the list's "End Session" run on the main
  actor (TVC:398-402, 447-455; VC:243-248).
- A23 holds and matters for 8.2: `-debugCrashAfter` is armed by the first session that starts in
  the process (TVC:747-749), whichever is on screen when it fires. The test "A crash on screen,
  others parked" must pass it on the relaunch only.

**`map-lifecycle.md` 2.4 step 1** is half wrong (LC-19, item 3); the design does not build on it.

**`map-core.md`:** sections 1 to 7 hold against the code that was read (`Storage.swift`,
`SnapshotCodec.swift`, `SessionMeta.swift`, `RecordProtection.swift` and the app's
`StageTwoProbe.swift` were not opened), including the three facts the design leans on most:
`close()` writes nothing and releases the lock before it returns (RC:704-712,
`SessionRecord.swift:145-148`, `SessionStore.swift:71-78`); a second open in one process is
refused (`SessionStore.swift:143-161`, tested at `ResumeCoordinatorTests.swift:341-357`);
`shutdown()` before `start()` has no reader (`MoshConnection.swift:165-176`, 243-248). Its
section 3 is right where the design's table is not (LC-13). Its "three lives" is right where the
design says "three times" (LC-19, item 1).

**`map-list.md`:** sections 1 and 2 hold as far as VC, SL, SF and LA go (`HostStore.swift` and
the editor were not opened). Sections 3 to 5 were checked only where the design cites them (the
newest stored state, `RowGeneration`, the port range in mosh). The spawner's lines were not
checked.

## What held

Checked against the code unless marked "reasoned".

1. **G1.** `flock(LOCK_EX|LOCK_NB)` on a descriptor of its own (`SessionStore.swift:143-161`): a
   second open in the same process is refused. Every delete goes through `SessionFiles.forget` →
   `deleteRecord`, which takes the lock (RC:371-377) and on refusal keeps key and link
   (SF:82-87). No path was found that forgets a record under a live coordinator or gives a
   record two coordinators (R5, R2, `finish`, `sessionStarted`, `finishEnded`, the launch retry).
2. **No send under a stale clean record (N1, N2, N4).** The park is `enterBackground()` then
   `close()` in the coordinator's one queue (C8, RC:415-423), and every entry is guarded by
   `closed`. The `start()` of `begin` (TVC:725-739), which does not go through the screen's
   queue, was tried in all three orders against the park: start, park, close: dirty, quiesce,
   save; park, start, close: `.clean` with nothing written and the start deferred, never sent
   (RC:446-449, 490-497); park, close, start: nothing (RC:445). A resumed session's first
   datagram always follows `beginSending` (RC:451-466). Each record has its own key (LA:72) and
   counters; two coordinators of different records share nothing. (The gate's internals were
   not re-read.)
3. **The scene's save against the park.** `.background` then `.park` writes once (C10,
   RC:498-500); `.foreground` then `.park` saves again after "dirty" (RC:516-533).
4. **A park cannot wait on the network.** `quiesce`, `start` and `close` of the connection open
   and close sockets without waiting (`MoshConnection.swift:165-194`, 251-261). Risk 3 (a park
   that hangs) is storage only.
5. **An ended session is never saved clean** when the end is known to the transport
   (`TransportCore.swift:939-941`, RC:545-548), and E1 writes "ended" before anything is sent
   (RC:647-665).
6. **A kill between the park of A and the unpark of B** (reasoned): A is clean and closed, B is
   clean until `start()`, `lastLookedAt` is written before `start()`: every point gives L2 or L3
   as the table says.
7. **Section 6's order** start, contact, shutdown agrees with the code: `shutdown()` opens no
   socket and starts no reader (`MoshConnection.swift:165-176`, 243-248).
8. **The size** (reasoned): one command queue and one slot per screen; the ender has no view and
   the cold start passes `currentSize: nil` (LA:92); `sizeBeforeStart` is set only through the
   screen's own queue (RC:607-612). No path announces a size to another session.
9. **The background task** of a park ends itself at expiry (TVC:1066-1068).

Added by the second pass (2026-11-21):

10. **The stream hands out what was yielded before `finish()`** (the design's "Not yet verified"
    1): by experiment on Linux, and the library's source says why. Not run on Apple's runtime.
    See "The stream".
11. **A parked session's server stays.** mosh-server has no idle exit for a client that was once
    heard, unless one is set in its environment (`mosh-server.cc:383-409`, 696-706, 857-878). A
    server no client ever reached exits after 60 s (682, 914-919), as B2 and E2 say.
12. **X1 leaves no server behind, even if our acknowledgment is lost.** The app forgets when the
    acknowledgment has been handed to the socket (`TransportCore.swift:711-717`, TVC:689-693). If
    that one datagram is lost, the server repeats its shutdown and exits by itself after 16 sends
    or 10 s (`mosh-server.cc:885-888`). "Ended, server not yet stopped" is only ever true of a
    shutdown the app asked for.
13. **Section 6's protocol steps** are mosh's: 16 sends or 10 s, the server leaving on its
    acknowledgment, and a base state the server holds once it has answered. See "mosh's own
    behaviour".
14. **The gate, the record's save, `startShutdown` and `sendPendingNow`** (not read by the first
    pass) hold nothing against the design. "Clean" is written only by
    `markClean(snapshotID:_:)`, when the gate's datagram count equals the export's token and the
    record is not ended (`FileBackedGate.swift:219-231`), and only `SessionRecord.save` calls it
    (`SessionRecord.swift:113-120`). `beginSending` is one change of both slots before the first
    datagram (237-249). A closed gate refuses every call (286-289) and a lock serves one gate
    (`SessionStore.swift:62-68`, `FileBackedGate.swift:91`): a coordinator that a park has closed
    can write and send nothing afterwards, whatever task still holds it. `startShutdown` fixes
    what it asks for and sends nothing while quiesced (`TransportCore.swift:338-346`, 440-442).
    `sendPendingNow` takes its numbers from the gate like any send (400-421).
15. **The key by the record's id.** One Keychain item per id (`SessionKeychain.swift:58-66`,
    71-84); LA:72 is the only reader for a cold start, and the transport's address and port come
    from the same id's `meta` (LA:126-130; the session itself is built from the `meta` read under
    the lock, RC:332-334).
16. **The list's read of `counters` without the lock.** The newest valid slot decides
    (`Counters.swift:148-190`). A read that falls between a writer's two slot writes sees two
    generations that are not neighbours and is refused (180-182): the row reads "Cannot be read
    now" for one refresh. The only writers while the list is visible are a park and the ender,
    whose rows are "Saving…" and "Ending…" whatever the file says.
17. **A preview decoded while a session runs.** The one process-wide state under `Sources/` that
    two sessions share is the row generation counter. It is locked
    (`MoshTerminal/Cell.swift:137-159`), and a decode only raises it (`Serialization.swift:362`),
    so the generations of one session's rows stay distinct through any number of parks, previews
    and other sessions.
18. **The SSH kill (R2, R3) cannot reach a session this process has open** (reasoned). It is
    offered for a dirty or ended record on the list. A record that is dirty with a coordinator on
    it is on screen, being saved or ending, or belongs to LC-7(b)'s second terminal, during which
    the list is not on screen. A dirty record never becomes resumable again (C4), so an old swipe
    cannot turn into a kill of a live session.
19. **Rows S5, S9, R3, E2, L1, L5 to L7** against the code: S5 is VC:206-210; S9 is "deleted and
    no `meta`" (VC:195-198), while a record the cold start deleted that still had its `meta` goes
    the fallback way (VC:204-205), which is S4; R3 normally finds the server gone (LC-6, note) and
    forgets; E2 is decided at the leave, so a bootstrap that finishes while the confirmation is up
    becomes E1. Nothing found beyond LC-11, LC-14, LC-16 and LC-18 (c).
20. **Section 4.4 to 4.6.** A swipe's action and its confirmation act on the session value
    captured when the swipe was built (as today, VC:394-403), so a list that is held still cannot
    end another session than the one shown: R1 on an old value is refused by G1 if the record was
    opened meanwhile, and R2 is 18 above. One condition to write down: while reloads are held, the
    model is held with the table (today they move together, VC:101-107); a model that moved alone
    would make a tap act on another row than the one shown.
21. **Section 8.3.** The existing resume tests relaunch without the debug arguments and expect
    the stored session (`ResumeUITests.swift:55-56` and the like). With the launch by "last
    looked at" they keep passing: the id is written in `attach` from step 1 on, and
    `-uiTestingResetSessions` deletes the file that holds it (SF:138-140). Tests that end through
    the menu run today's leave code. Open there: U1, and `ResumeUITests.swift` being changed by
    other work (LC-19, item 5).
22. **A resign that falls into the pop** (reasoned; UIKit's order not run). Until
    `viewDidDisappear` the screen is still `current`, so the scene's save reaches it; the park
    that follows finds the record clean and writes nothing (C10, RC:498-500), or, if the app
    came back in between, saves again (RC:516-533). A kill in between resumes that session at the
    next launch.
