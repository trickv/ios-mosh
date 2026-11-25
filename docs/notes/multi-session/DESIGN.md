# Several sessions at once: design

**Both halves of the checks and the final verification (2026-11-21): answered.** Every finding of
the first half, of the second half (L2-O1, L2-S1 to L2-S8, P2-O1, P2-M1 to P2-M4, P2-S1 to P2-S9)
and of the final verification (V-1 to V-8) is answered in this text as of 2026-11-21 and has a row
in "Review status"; steps 0 to 3 are unchanged. Steps 8 to 12 still get their hostile reviews when
they are built.

**Checks (2026-11-21): answered.** Every finding of the two last checks in `checks.md` (CL-1, CL-2,
CL-S1 to CL-S7, CP-1 to CP-3, CP-S1 to CP-S4) is answered in this text and has a row in "Review status".

**Status (2026-11-21, revised three times): this is the design to build from, with the caveats of
"Not yet verified".** It replaces the first draft and answers both critiques beside it,
`critique-ui.md` (U1 to U10) and `critique-lifecycle.md` (LC-1 to LC-19, two reviewers), and both
halves of the checks (`checks.md`) and the final verification (V-1 to V-8). Every finding has a
row in "Review status" at the end, 76 in all: 72 accepted, two of them in part refuted (CL-S1: its failure path does not happen; CL-2: its
fix is placed in step 11b, not 9), 4 settled by a decision, none refuted whole, none left
untaken. Reviewed against `BRIEF.md` (nothing in it is changed), the code at `b5aec27` and HEAD,
mosh 1.4.0 in `.refs/mosh/src`, and the decisions D1 to D7 (listed with the review status). Only
the lines that decide a finding were read again (item 7 at the end says which); every other
line number is as the maps and critiques give it, the two checks stopped before they had read
everything (item 9), and the file has not been read back in full by a second reader (item 8).
Neither critique nor check found a way to break N1 to N4 except through debug launch arguments
(LC-16, closed in step 2). Nothing here is built or run.

Contents: readings of the brief, 1 summary, 2 the model, 3 the table, 4 the list screen, 5 the
terminal screen, 6 "End Session" on a parked session, 7 changes per file and the core, 8 tests,
9 steps, 10 risks, the question and the defaults, review status, not yet verified.

Conventions:

- Code references are to `main` at `b5aec27`. `TVC` = `App/IOSMosh/TerminalViewController.swift`,
  `VC` = `SessionListViewController.swift`, `SL` = `SessionList.swift`, `SF` = `SessionFiles.swift`,
  `LA` = `SessionLauncher.swift`, `SD` = `SceneDelegate.swift` (all in `App/IOSMosh/`),
  `RC` = `Sources/MoshResume/ResumeCoordinator.swift`. mosh references are to mosh 1.4.0. "R" and
  "C" numbers are the invariants of `docs/RESUME.md`; "A" numbers are the assumptions in
  `map-lifecycle.md` section 9.
- **A step starts from HEAD, not from these line numbers.** Commit `376c583` moved everything
  below TVC:140 by 2 to 38 lines (the command consumer is at 287, `endSession()` at 414,
  `attach` at 717) and added a UI-test hook to the consumer and to `perform`; that hook is kept.
- *Record*: `Application Support/sessions/<id>/`. *Open*: a `ResumeCoordinator` holds the
  record's `flock`. *Park*: save, then close (2.3). *Unpark*: a cold start of that record, the
  call the launch makes.
- **[!]** marks a place where a subtle mistake loses a session or opens a record twice.

## Where this design reads the brief one way

Nothing in `BRIEF.md` is changed. Nine places needed a reading:

1. **Items 8 and 9 meet at a launch whose last looked-at session is dirty** (the app died with it
   on screen). Item 9 wins (D2): the launch opens the replacement session with the banner, as
   today. As today, that is offered once: after he went back from it the next launch shows the
   list (reading 3). Every other reason the session cannot be opened shows the list.
2. **Item 6, "only the session on screen talks to its server", has one exception that the brief
   itself asks for:** "End Session" on a parked session resumes it to say goodbye, for at most
   about 21 s, while another session may be on screen.
3. **Back no longer means "not wanted".** Today, leaving the screen while a replacement is still
   connecting deletes the old record (TVC:390-403). With item 4 a back gives nothing up: the
   attempt is cancelled and the old session stays, listed as "Could not be resumed", without the
   dot.
4. **Item 8, "opening the app goes straight into that session", is read as written (D1):** also
   when the list was on screen when the app went away. This is the one open question (10.2);
   it is decided in one place (2.5).
5. **Item 10:** the app does not count sessions. mosh-server takes the first free port of the
   range and fails when there is none; the app says that in words.
6. **Item 8, the dot (D4):** after the session with the dot ends, no session has the dot until he
   opens one, and a launch then shows the list.
7. **Item 1, "a row as today":** the host row keeps its name and address. Its state line and its
   leading swipe ("End Session", "Forget") move to the session rows, where item 5 puts them.
8. **Item 4, "does not end the session", holds for every session**, also one that never heard its
   server (risk 7).
9. **Item 6, "saved exactly as the app saves a session today" (D5):** the park is that save and
   sends nothing. Input the server has not acknowledged goes out when the session is next opened.

## 1. Summary

1. **A session that is not on screen is a clean record on disk and nothing else.** Back runs
   today's save (`enterBackground()`: quiesce, snapshot, clean mark), then `close()`. No
   coordinator, socket, timer or terminal screen stays in memory.
2. **A tap on a session row is a cold start of that record**, the call the launch and today's
   list already make (`SessionLauncher.coldStart(root:id:keys:options:)`, LA:66-105). A session
   resumed after a switch and one resumed after iOS killed the app are the same case.
3. **One screen.** Every saved host is a row; its sessions are rows indented under it, each with
   what is on its screen and when it was last used. A tap on a host always starts a new session.
4. **The last looked-at session** is one id in `session-hosts.json`. It gets the green dot, and
   the launch opens it and no other record.
5. **Ending is separate:** the server's own end (Ctrl-D, `exit`) returns to the list; "End
   Session" behind "…" in the terminal is today's leave-the-screen code; "End Session" on a
   parked row uses mosh's own shutdown (the core allows it, section 6).
6. **Order is kept by two small objects in the app.** `SessionQueue` holds a screen's command
   queue and its coordinator and outlives the screen. `SessionActivity` lets nothing be opened or
   created until every park asked for before it has returned from `close()`. The record's lock
   (R12) stays the backstop: a second open of a record is refused, never two writers.
7. **The core does not change.** `Sources/` is not touched; two tests are added under `Tests/`.
8. What does not change: how a record is saved, resumed and given up (C1 to C13, R1 to R21), the
   scene's save when the app leaves the foreground, the fallback, the health check and probe,
   "Forget", the host editor, Keys, Settings, the terminal's drawing and input.
9. Prices: no bell and no badge from a parked session (accepted in the brief); input not yet
   acknowledged at a back waits until the session is opened again (D5, risk 2); a resume costs
   one cold start on the main thread, never timed (risk 1).
10. Nineteen steps (section 9): 0 to 14, and 5b, 8b, 9b, 11b; 9b is skipped only if step 9's UI
    test `testASwitchSendsNoResize` shows no resize at a switch with a software keyboard up and
    its control fails. Steps 0 to 7 do not touch the
    park or the launch, but steps 2 and 4 decide which records are deleted (`forget`,
    `removeOrphans` at every launch) and which one a tap resumes or a swipe ends, and step 6 gives
    sessions without a saved host a back that ends them: the diffs of steps 2 and 4 get a hostile
    review before step 8 starts and before any build is offered. The owner can try a build after
    steps 6, 11b and 14.

## 2. The model

### 2.1 What a session is

A session is one record and three things keyed by the record's id:

| Thing | Where | Made | Removed |
|---|---|---|---|
| Record (`meta`, `counters`, `snapshot`, `lock`) | `sessions/<id>/` | `ResumeCoordinator.create` (TVC:663) | `SessionFiles.forget` → `deleteRecord`, under the lock (SF:80-97, RC:371-377) |
| Session key | Keychain, account = id | before the record (TVC:642) | `forget`, `removeOrphans` |
| Link to a saved host | `session-hosts.json`, `links[id] = host UUID` (SF:46-50) | before the record (TVC:648) | `forget`, `removeOrphans` |
| "Last looked at" (new) | `session-hosts.json`, `lastLookedAt = id` | in `attach` (TVC:679) | 2.5 |

A session belongs to the host its link names. A session whose link is missing or names a deleted
host is "without a saved host" (section 1 of the list, as today, SL:119-123). Any number of
sessions may link to one host.

**[!] The key is read by the record's id and nowhere else.** `SessionLauncher.coldStart(root:id:
keys:options:)` reads `keys.key(for: id)` (LA:72) and is the only caller of
`ResumeCoordinator.coldStart` in the app. Every unpark (a tap, the launch, "End Session" on a
parked row) goes through that one function. Passing another record's key would reuse nonces (N1)
and the core cannot detect it (`map-core.md` section 7).

### 2.2 The states, as the app sees them

A session's state is read from its files without the lock (`readCounters`, as today, SL:98-106),
overridden by what this process is doing to it. One pure function decides
(`ListedSessionState.derive`, extended); the order below is its precedence.

| State (identifier) | When | Row says | Tap | Swipe |
|---|---|---|---|---|
| On screen (`live`) | a terminal screen holds its coordinator and has not been left | "Connected" | none (the list is covered) | none |
| Ending (`ending`) | a shutdown this process started is in flight | "Ending…" | none | none |
| Being saved (`parking`) | its park is in flight (2.3) | "Saving…" | waits for the park, then as its new state | none |
| Parked and resumable (`resumable`) | counters clean | preview, "last used …" | unpark | End Session, Forget |
| Ended (`ended`) | counters ended: ended on purpose, server not known to be stopped | "Ended, server not yet stopped" | none | End Session, Forget |
| Could not be resumed (`dead`) | counters dirty (any state that is not clean or ended, SL:40-45) | "Could not be resumed" | the fallback: a new session on its host | End Session, Forget |
| Unreadable (`unreadable`) | counters cannot be read now | "Cannot be read now" | asks the coordinator; normally "Session Not Available Now" | End Session, Forget |

Two more facts are not row states; both live in `SessionActivity`:

- **Waiting** belongs to the launch, as today: the launch asked for the last looked-at session,
  the answer was "try again later" (`.retryLater`), and the app asks again when it next becomes
  active (SD:46-52). The list shows today's line "A session is waiting: …"; the row shows its
  file state. The wait and the line are dropped when any tap is accepted and when that session is
  ended or forgotten.
- **Opening**: a tap was accepted and has not yet produced a screen. While it is set the list
  takes no other tap, offers no swipe, and the launch's retry does not run.

The label is a hint. As today, what a tap does is decided by the coordinator (SL:7-10).

### 2.3 Park and unpark

**Park** (the one new lifecycle sequence). The screen was left by the back button and
`LeaveAction` said `park` (5.3). On the main thread, at once: a `BackgroundTask` is begun,
`.park(task, attachedRestored:)` is put at the end of the screen's command queue, the queue is
finished, and `SessionActivity` is told "`id` is being saved until the queue's consumer ends".
`attachedRestored` is true when the slot's coordinator came from a cold start (`.resumed`) and
`attach` has run; both are known at the leave, so the flag never waits for an answer that comes
later. The consumer first runs whatever was queued before (typed bytes, a resize), in order, as
today (TVC:285-295). Then, with the coordinator `c` of its slot:

1. If `attachedRestored`: `try? await c.start()`. `begin`'s own `start()` may still be in flight
   at the leave and its failure is reported only after it threw (TVC:726-733), or through the
   event task for a deferred start (TVC:777-785), so the park does not ask whether it failed: it
   calls `start()` again in every case. That does nothing once the session has started
   (RC:445) and runs after `begin`'s call in the coordinator's order. After a failed
   `beginSending` the gate completes the counters change it began
   (`Sources/MoshResume/FileBackedGate.swift:237-249`, 305-311) and the session is saved like
   any started one. Without this the park would answer `.clean` from memory (RC:490-495) while
   one slot on disk says "dirty". A coordinator that was not attached gets no `start()` (C11:
   its record stays as it was).
2. `await c.enterBackground()` (RC:484-508, 538-555: quiesce, export, snapshot replaced, clean
   mark; C5). `ParkPlan.after` decides on its answer: `.clean`: on. `.notResumable(.failed)` or
   `.notResumable(.datagramSentSinceExport)`: 300 ms, then once more; the second call saves
   again because the first left `savedClean` false (RC:498-507, 544). `.notResumable(.closed)`: the event task's
   `finish` closed and forgot it first (RC:489); nothing more to do, the row is gone.
3. `await c.recordState` (RC:734), then `await c.close()` (RC:700-712: writes nothing, releases
   the lock).
4. `ParkPlan.after(outcome, state)`: for `.notResumable(.ended)` **with the record in state
   `.ended`**, `SessionFiles.forget(id)`: the server ended the session during the leave (as B4).
   The same answer with a dirty record is a session that was given up (RC:98-99, 572-579): kept.
   Every other answer: kept, as its files say.
5. The UI-test mark (`park-clean`, `park-not-resumable`) and the log line from `readCounters()`
   after the close, then `task.end()`. `SessionActivity` drops the id; the list reads the records.

This is the scene's save (TVC:306-311) followed by a close, in the same queue.
`map-core.md` section 2 shows that nothing in the core asks whether the app is really in the
background; `ResumeCoordinatorTests.swift:601-632` runs three lives of one record (two cold
starts) in one process on Linux, with the record's key file and the POSIX socket. The app's
parts (the Keychain key, `NWDatagramTransport`, this queue) first run it in step 9.

**The park sends nothing (D5).** Input the server has not acknowledged is in the snapshot and
goes out at the next `start()` of that record, exactly once
(`Tests/MoshTransportTests/ResumeIntegrationTests.swift:188-191`,
`Tests/MoshResumeTests/ResumeCoordinatorTests.swift:533-561`), as mosh's own client does after a
laptop slept. Risk 2 has the size of that window. One exception: when an earlier `start()` of a
resumed session failed, step 1's second `start()` can succeed, and then `beginSending`, the first
datagram and the stored input go out at the park (RC:451-466), as they would have at the start
that failed.

What a park leaves:

| It met | Record afterwards | Row |
|---|---|---|
| a started session | clean, closed | resumable |
| a save that failed twice | dirty, closed | "Could not be resumed"; a tap is S4 |
| the server's end, known to the coordinator | deleted | gone |
| a session given up (lost base state, halted) not yet handled by the screen | dirty | "Could not be resumed" |
| a resumed session that was not attached (also one whose screen never appeared) | clean as before, nothing written (C11, RC:490-497) | resumable |
| a resumed session whose `start()` failed again in step 1 (also when the park's call came before `begin`'s failure was reported) | clean, or dirty if the failed change reached one slot | as its files say |
| the same, with a `.background` queued before the park (the scene resigned during the pop) | the park's `start()` is deferred (RC:446-449) and the half-written change is not completed; the park answers `.clean` from memory (RC:490-495) while one slot may say dirty: LC-13's outcome. Needs a storage failure and a resign inside the pop: not engineered for (D7) | as its files say |
| a record the event task closed and forgot first (`.closed`) | gone | gone |
| a new session whose `start()` has not run | dirty, no snapshot | "Could not be resumed" |
| a record already saved clean (the scene resigned just before) | clean, nothing written (C10, RC:498-500) | resumable |
| a new session that never heard its server | clean (state 0 and the first Resize) | resumable (risk 7) |

**[!] Three rules of the queue** (`SessionQueue`, section 7):

- **The consumer holds the slot strongly and outlives the screen.** Today it reads
  `self?.coordinator` weakly (TVC:287) and the screen is freed right after the pop, so a queued
  command would be skipped.
- **The slot holds a coordinator from the moment the screen has one**: from `init` for a resumed
  one (today it sits in `start` until `attach`, TVC:493-495, and nobody closes it if the screen
  is left before, TVC:404, 189-193), from `openSession` for a new one. Commands other than the
  park run only once it is attached, as today. **Two questions, never mixed:** every read of
  `coordinator` becomes `isAttached` (`attach` has run), except the three that become `held`,
  named at the end of this rule. The `isAttached` reads are all the others, for example the
  scene's resign and return (TVC:352, 361), the health check, the probe, the path watcher,
  `announceSize` (TVC:986, HEAD 1024), `liveSessionID` (176) and `runtimeFallback`'s guard (530).
  `announceSize` is the one that bites if it reads `held`: on a resumed screen pushed with animation its 100 ms timer fires before `attach`, sets
  `announcedSize`, the consumer drops the `.resize` (not attached), and `attach` then announces
  nothing, so a size changed between park and unpark never reaches the server. A resign before `attach` queues
  nothing and `attach` saves at once because the policy noted the resign
  (`SceneSavePolicy.swift:15-18`, 28-30). `held` (the slot is filled) is read only by the leave
  decision (5.3), the queue's end (5.6) and `openSession`'s guard (637), which asks whether the
  slot is empty: a coordinator in the slot that is not yet attached must not get a new session
  beside it.
- **Nothing that must be ended is put into the queue after the leave, and the consumer task is
  never cancelled.** A yield after `finish()` is refused without a trace, and a cancelled
  consumer that is waiting finishes the stream (the critique's stream experiment, rows F and
  G2). `BackgroundTask` gets a `deinit` that ends it (today none, TVC:1062-1076).

**Unpark**: `await SessionActivity.settled()` (every release asked for so far has returned),
then the gate of G3, then on the main thread with no suspension:
`SessionLauncher.coldStart(root:id:keys:options:)` (the Keychain key of that id;
`ResumeCoordinator.coldStart(key: .provided)`: lock, counters, the snapshot only if the record
is clean for it; nothing written, nothing sent: C1, C2). On `.resumed(c)` a new
`TerminalViewController(start: .resumed(c, host:))` is made with `c` in its slot, its view is
loaded (`loadViewIfNeeded()`, so `viewDidLoad` has made it `current`, TVC:202) and it is pushed.
Its `attach` stores "last looked at" and calls `c.start()` (`beginSending`: "dirty" and new
reservations in one change, then the first datagram; RC:451-466). The first screen is the stored
one. A `.resumed` result that is not pushed after all is closed, as a tracked release. **Every
screen that `open` (4.5) or the launch's retry (W6) pushes is loaded the same way before the
push**: the new session of H1, the fallback screen of S4, the resumed or fallback screen of the
retry. So `current` is set before anything can start, never whenever UIKit loads the view.

### 2.4 The three guarantees

**G1. At most one coordinator holds a record.** By the core: the record's `flock`
(`LOCK_EX` with `LOCK_NB`, `Sources/MoshResume/SessionStore.swift:143-161`, R12). A second open
in the same process fails with `RecordError.locked`: a cold start answers `.retryLater(.inUse)`
(RC:388-389) and `deleteRecord` throws (RC:371-377). The app never works around it.

**G2. A parked record is clean and closed before anything else is opened.** By the app:
`SessionActivity` keeps the tail of all releases in flight: a park; the close after the server's
end (`finish`); the `abandon()` of a run-time fallback; the close of a resumed coordinator that
was not pushed. Every tap, every new session and every "End Session" on a row awaits that tail
before it calls `coldStart` or pushes a screen. Only `SessionRecord.save` can write a clean mark
(R5, R6), and the park's `close()` runs after it in the coordinator's own order (C8, RC:415-423).
G2 is what makes G1's refusal something the user does not meet ("Session Not Available Now").

**G3. No session starts on a screen the scene's save cannot reach.** The resign goes to
`TerminalViewController.current` only (SD:42-44); `current` is set in `viewDidLoad` (TVC:202); a
new screen's policy starts with `resigned = false` (`SceneSavePolicy.swift:12`) and `attach`
saves at once only when the scene already says background (28-30, TVC:697). A resign that fell
into an open's wait for G2 would reach nobody, the screen made afterwards would start its
session unsaved, and a kill off screen would end in the fallback. So after the settle and before
the cold start, in one main-actor turn through to the push: the scene is `.foregroundActive` and
the list is the top screen, or the tap is dropped and "opening" cleared. Nothing was opened, so
nothing is undone.

"End Session" in flight is not a release: it can take 21 s, holds only its own record, and other
sessions may be opened meanwhile (two coordinators of different records share nothing,
`map-core.md` section 4). Its row is "Ending…" and takes no tap and no swipe.

### 2.5 Last looked at, and the launch target

- **Stored** as `lastLookedAt` (a session id, optional) in `session-hosts.json`, beside the links
  (the version stays 1: an old file decodes as "none", an old build ignores the key). The list
  reads that file at every refresh and `-uiTestingResetSessions` deletes it (SF:138-140).
- **Written** in `attach` (TVC:679), the one place where a coordinator becomes a screen's
  session: a new session, a resumed one, the new session after a fallback.
- **Cleared**, by one function `SessionFiles.clearLastLookedAt(ifNamed:)`, when it names the id:
  by `forget` and `removeOrphans` (which today rewrite the file only when a link went, SF:94,
  112: they now also write when the id went, and `removeOrphans` also visits it); by a back
  during a fallback (B3); and first of all by every "End Session": in the terminal by the
  alert's action, before the pop (5.2; E1, E3, E4), on a row as the ender's first stage
  (section 6 a). So a
  session he ended or declined never starts anything at the next launch, whatever interrupts
  the ending. It is not moved to another session (D4).
- **Read** by the list (the dot) and by the launch.
- **[!]** `session-hosts.json` is read, changed and written back with no lock, and one writer
  runs off the main thread (`finishEnded` → `forget`, LA:145-153; A15). Every read-change-write
  of the file goes under one process-wide lock.

**The launch target is decided in one place (D1).** One stored value, `lastLookedAt`; one
function, `SessionLauncher.launchTarget(last:ended:)`, called by `makeRoot` and by the launch's
retry and by nothing else. It answers that id unless there is none or it is among the ended
records. So a launch goes into the dotted session also when the list was on screen when the app
went away. If the owner answers "the list" (10.2): `SessionFiles` stores one flag beside the id
(set at the leave, cleared in `attach`), `launchTarget` takes it as a third argument, and the UI
test `testAKillWithTheListOnScreenGoesIntoTheDottedSession`, the one test that encodes this
decision, flips its last check. Nothing else changes.

## 3. The table

Each row: what happens, what it meets, the calls in order, what the user sees, what keeps the
record safe. "settle" is `await SessionActivity.settled()` (G2); "gate" is G3; "cold start" is
`SessionLauncher.coldStart(root:id:keys:options:)` (key by id, then lock; G1). "today" means the
code at `b5aec27` is kept as it is.

### 3.1 The list: a tap on a host

| # | Meets | Calls, in order | The user sees | Record safety |
|---|---|---|---|---|
| H1 | nothing in flight | "opening"; gate; `TerminalViewController(.host)` loaded, pushed; SSH bootstrap (TVC:554-631); `openSession`: Keychain key for a new random id, link, `ResumeCoordinator.create`, slot, `attach` (last looked at, `start()`) | "Connecting…", then the shell. Back later shows a new row under the host | a new record: `create` refuses a directory that exists (R18) |
| H2 | a release in flight (**a new session while another is being parked**) | "opening"; settle; gate; then H1 | the same; the parked row says "Saving…" for a moment | G2: the SSH connection is not started before the park has closed |
| H3 | no free UDP port in the host's range | the app's server command has `-s` (`MoshServerCommand.swift:50`), so mosh-server tries two binds, prints "Failed binding to …" for each and exits 1 (`network/network.cc:268-286`, 339-350; `frontend/mosh-server.cc:368-371`); `BootstrapError.serverStartFailed` | red banner: "No free UDP port on <host> in <range>. Each session uses one: end a session on this host, or widen UDP ports in the host's settings.", then mosh's own lines. In a fallback (S4, F1, L3) the old server still holds its port (it is killed only after the new one started, TVC:585-598): the banner adds which row to end | nothing was made: no key, no link, no record |
| H4 | "opening" set, or a screen with a session not yet left | nothing (guard, as VC:169) | nothing | — |
| H5 | **the scene is no longer active when the settle returns** (Control Centre, the Home gesture) | the tap is dropped, "opening" cleared | the list | G3: nothing was opened |

A host with sessions and a host with an ended or dead session behave the same: a tap is a new
session (brief item 2). Today a tap on a host resumes its record (VC:168-178); that moves to the
session row.

### 3.2 The list: a tap on a session row

| # | Meets | Calls, in order | The user sees | Record safety |
|---|---|---|---|---|
| S1 | resumable | "opening"; settle; gate; cold start → `.resumed(c)`; screen with `c` in its slot, loaded, pushed; `attach`: last looked at, `c.start()` | the stored screen at once, live when the server answers; the dot moves to this row | G1, G2, G3 |
| S2 | being saved (**the row of the session just left**) | as S1; settle is what waits | as S1, a few tens of ms later | G2. Without it: `.inUse` |
| S3 | **the same row tapped twice quickly** | the first tap sets "opening"; the second is dropped | one terminal | the guard; behind it G1: a second cold start gets `.retryLater(.inUse)`, never a second coordinator |
| S4 | dead, with a saved host | cold start → `.fallback` (dirty; nothing sent, C2); the `.fallback` screen loaded, pushed: banner, bootstrap, old server killed after the identity check if its pid is known, old record forgotten once the new session started (today, TVC:496-503, 585-598, 742-746) | "Previous session could not be resumed. Starting a new one." and a new shell; one row replaces the other | the old record is never resumed (C4); the new one is a new id |
| S5 | dead, no saved host | cold start → `.fallback`; `forget`; alert (today, VC:206-210) | "Previous session could not be resumed." | deleted under its lock |
| S6 | ended | not selectable. (A row that read otherwise and turns out ended at the cold start: `finishEnded` in the background, no new session) | nothing | — |
| S7 | unreadable, or the Keychain cannot be read now | cold start → `.retryLater` (LA:77-79, 101-103) | alert "Session Not Available Now" (today, VC:190-193) | the record is untouched (C3) |
| S8 | ending, on screen, or "opening" set | nothing | nothing | — |
| S9 | the directory is not a record | cold start deleted it; `forget` (today, VC:195-198) | the row goes | under its lock |
| S10 | **the network is gone during a switch** (back from A, tap B) | A's park needs no network. B: S1; `c.start()` writes "dirty" and sends; sends fail and are tried again every second | B's stored screen; "Last contact N s ago" after 6.5 s; it goes on when the network is back. Back meanwhile: B is saved clean again | no fallback and no loss in either direction |
| S11 | resumable, but its server is gone (killed on the host; or its shell ended while it was parked: mosh-server then leaves by itself within 16 sends or 10 s, `mosh-server.cc:842-843`, 885-888, and nothing tells the record) | S1; no answer; with a known pid the probe after 15 s finds it gone: run-time fallback (today, TVC:829-864). With no pid (host `hg`): no probe (TVC:835-839) | a new session with the banner; on `hg`: "Last contact" until he ends or forgets it (risk 6) | as today |

### 3.3 The terminal: the back button, the server's end, "End Session"

| # | Event | Meets | Calls, in order | The user sees | Record safety |
|---|---|---|---|---|---|
| B1 | back ("‹ Hosts") | a session attached | park (2.3) | the list at once; the row "Saving…", then its preview, with the dot | the record is clean before its lock is released; G2 for whatever is tapped next |
| B2 | back | first connection still running (nothing in the slot, no old record) | the bootstrap task is cancelled (today, TVC:379, 605-608) | the list; no new row. A server that had started exits by itself after 60 s without a client (`mosh-server.cc:682`, 914-919) | nothing was made |
| B3 | back | a fallback still connecting (old record dirty, nothing in the slot) | the bootstrap task is cancelled; `clearLastLookedAt(ifNamed: old)`; the old record is **kept** (today: old server stopped, record deleted, TVC:390-403). A run-time fallback's `abandon()` still running is a tracked release | the list; the row "Could not be resumed", no dot; later launches show the list | the old record is dirty and closed; a later tap is S4 |
| B4 | back | the server had ended the session, our acknowledgment not yet out | `finish(c, .forget)`: `close()`, `forget` (today, TVC:405-411), a tracked release | the list; the row goes | the record is "ended" (C7) and deleted under its lock |
| B5 | back | the park's save fails | tried once more (2.3 step 2); then `close()` | resumable; or, after two failures, "Could not be resumed" | a storage error no longer ends a healthy session at the first failure |
| B6 | a back swipe that is let go half way | — | nothing: the leave runs only in `viewDidDisappear` with `isMovingFromParent` (TVC:337-342) | the terminal stays | — |
| B7 | back | a resumed screen before its `attach` (or one that never appeared) | park: `.clean`, nothing written (C11), `close()`, tracked | the row as before | the lock is released; today nobody closes it |
| B8 | back | **the server's end is on its way** (`exit`, then back within the round trip) | the end reached the coordinator: the park forgets the record (2.3 step 4). It did not: clean record, and the server exits by itself within 10 s | the row goes; or a resumable row without a server (S11, risk 6) | an ended record is never saved clean (`TransportCore.swift:939-941`) |
| X1 | **the server ends the session** (Ctrl-D, `exit`) | on screen | the coordinator marks the record ended before the app hears of it (RC:719-721); `.serverEnded`: banner "Session ended"; `.serverEndAcknowledged`: the event task runs `finish(c, .forget)` (today, TVC:689-693), then (new) the screen pops itself | the list, without that session; no dot | ended first, then deleted under its lock; never resumed (R16) |
| X2 | the same | our acknowledgment never gets out | as today: the banner stays; back is B4. The server leaves by itself within 10 s | "Session ended" until he goes back | as B4 |
| E1 | "…" → "End Session" → confirm | a session attached | `clearLastLookedAt` in the alert's action; the screen pops; the slot is emptied; today's `end` (TVC:425-443) inside a `BackgroundTask` (W4): `c.shutdown()` (record "ended" first, C7), on `.shutdownFinished(true)` `close()` and `forget`; on `false` or after 11 s `close()` only. The id is "ending" in `SessionActivity` until that returns | the list; the row "Ending…", then gone; without an answer "Ended, server not yet stopped" | an ended record is never resumed; it is finished at the next launch or from its row (today) |
| E2 | the same | first connection still running | as B2. Decided at the leave: a bootstrap that finished while the alert was up is E1 | the list | nothing was made |
| E3 | the same | a fallback still connecting | `clearLastLookedAt` (the old session's id) in the alert's action; a run-time fallback's `abandon()` is awaited; `stopOldServer`; `forget` **only if `mayForget`** (LA:238-244), as R2. Today the record is forgotten whatever the answer (TVC:398-402) | the list; the row goes, or stays "Could not be resumed" when the host could not be asked (the log says why) | the pid that can stop the old server later is not thrown away |
| E4 | the same | `shutdown()` answers false: the record could not be made dirty (only while it is still clean: a resumed session whose `start()` failed, or a return whose dirty mark failed, RC:647-659), or the session is already over (`MoshConnection.swift:237-241`) | `end`'s refused branch, changed: `close()`, `stopOldServer`, `forget` only if `mayForget` (today unconditional, TVC:432-441) | the list; the row goes, or stays as its files say | kept as its files say (resumable, ended or dirty), without the dot; never resumed by itself |

E3 and E4 keep a record that is not deleted (E3 a dirty one), which is safe only once the launch
reads "last looked at" (step 11): until then the launch takes the newest record (LA:45-60) and
would resume or fall back into it. So they are built in step 11b, with B3, which keeps a dirty
record for the same reason.

### 3.4 The list: "End Session" and "Forget" on a session row (swipe, then confirm)

| # | Action | Meets | Calls, in order | The user sees | Record safety |
|---|---|---|---|---|---|
| R1 | End Session | resumable | section 6 | "Ending…", then the row goes; or "Session Not Ended" and the row as before | G1; the one shutdown try is spent only after the server answered |
| R2 | End Session | dead | today's `end` (VC:238-259): `stopOldServer` (SSH, identity check, kill), `forget` if `mayForget` | "Ending…", then gone; or "Session Not Ended" with the reason | no coordinator; mosh's shutdown is impossible here: a dirty record must send nothing (C2, C4) |
| R3 | End Session | ended | as R2 | as R2 | as R2 |
| R4 | End Session | unreadable | section 6: its cold start answers `.retryLater` | "Session Not Ended: it cannot be opened now (<reason>)" | nothing is forgotten. The SSH way would forget a record that may be clean when the host has no pid (LA:159-162, 238-241) |
| R5 | Forget | resumable, dead, ended, unreadable | `SessionFiles.forget(id)`: `deleteRecord` under the lock, Keychain key, link, last looked at, the launch's wait (today, VC:274-290) | the row goes; the server is not contacted | `RecordError.locked` if anything holds it: "Session Not Forgotten" |
| R6 | either | on screen, being saved, ending, or "opening" set | not offered | no swipe actions | — |

On a host row the leading swipe goes (reading 7); the trailing "Delete" and "Edit" stay. Deleting
a host with sessions moves them to "Sessions Without a Saved Host", as today.

### 3.5 Background, return, launch, and what iOS does

| # | Event | Meets | Calls, in order | The user sees | Record safety |
|---|---|---|---|---|---|
| W1 | the app leaves the foreground | a terminal on screen | today: `current?.sceneWillResignActive()` → the save in a background task (SD:42-44, TVC:349-354) | — | clean record, lock held, as today |
| W2 | the same | the list on screen, nothing in flight | nothing | — | every other session is already clean and closed |
| W3 | the same | a park in flight | nothing more: the park has its own background task | — | finishes, or dies dirty (a row; L3 if it had the dot) |
| W4 | the same | "End Session" in flight (R1, E1) | it runs in its own background task: the ender's (section 6); for E1 the leave wraps today's `end`, a plain `Task` today (TVC:415), in a `BackgroundTask` that ends when `end` returns | — | the dot was cleared first: a death before `shutdown()` leaves a dirty row, after it "ended" (L6); the launch shows the list |
| W5 | the app returns | a terminal on screen | today: `.foreground` ("dirty", new socket), the held size (TVC:357-369) | the session goes on | as today |
| W6 | the app returns | the list, a launch waiting | L5 again, only if the list is the top screen, no screen has a session, "opening" is not set and the wait was not dropped; the screen it makes is loaded before the push (2.3) | the session, or the list | as L2 to L5 |
| W7 | the app leaves the foreground | an open waiting for its settle | H5 | the list when he returns | G3 |
| K1 | iOS kills the app | one on screen, others parked | — | next launch: L2 if it was saved (off screen), L3 if it died on screen. The parked ones are rows as before | parked records were clean and closed before the kill |
| L1 | launch | no record at all | the list; or the `-debugMosh*` session, pushed over the list | the list | a debug request makes a record only when no stored record names its server (section 7) |
| L2 | launch | **a clean last looked-at session** | orphans removed; ended records finished in the background (today); cold start of that id only → `.resumed`; root = list, terminal pushed without animation | the session, stored screen first | G1. No other record is opened, written or deleted |
| L3 | launch | **a dirty last looked-at session** | cold start → `.fallback`; with a saved host (or an allowed `-debugFallback*`): the fallback screen over the list (today, SD:94-110). With neither: `forget`, alert, list | the banner and a new session; or the alert | the old record is never resumed; deleted once the new session started |
| L4 | launch | **only parked ones** and no last looked-at id (it ended; he went back from a fallback; the records are older than step 2) | the list. No cold start | the list, every row as its files say, no dot | nothing is opened |
| L5 | launch | the last looked-at session cannot be decided now | cold start → `.retryLater`; the waiting line; asked again at W6 | the list with "A session is waiting: …" | the record is untouched (C3) |
| L6 | launch | "ended" records of any age | today: `finishEndedSessions` (SD:147-156); the last looked-at one among them: the list | the list | as today |
| L7 | launch | the last looked-at directory is not a record | cold start deleted it; `forget`; the list | the list | under its lock |
| F1 | **a fallback at run time** (probe: server gone; lost base state; halted) | on screen only: a parked session has no coordinator and gets no events | today: `runtimeFallback` (TVC:529-549): the slot is emptied, `abandon()` (a tracked release), banner, bootstrap, old record forgotten when the new session started; "last looked at" moves to the new id in `attach` | the banner and a new session | as today (C4) |

## 4. The list screen

### 4.1 Sections and rows

- Section 0: the saved hosts in the order of `hosts.json`, as today. Each host row is followed by
  its session rows. With no host: today's "No hosts yet" row.
- Section 1, "Sessions Without a Saved Host": as today, only when there are any.
- The rows come from one pure function, `SessionList.rows(hosts:sessions:last:)`, which returns
  `ListRow` values: `.noHosts`, `.host(SavedHost, sessions: Int)`,
  `.session(ListedSession, host: SavedHost?, number: Int, isLast: Bool)`. It replaces `group`,
  which keeps only the newest record of a host (SL:114-126, A13).

**Host row.** The name, then `user@host[:port]`, without the state line. Identifier
`host-<display name>` as today. Accessibility value: `none` without sessions (as today),
`sessions=N` with. Without sessions the row is exactly today's (accessory `.detailButton`). With
sessions the accessory is a small view: a "+" image (identifier `hostPlus`) and, right of it, an
info button that opens the editor (a `UIButton`, so the UI tests still reach it as the cell's
first button). The "+" comes in step 10, together with the tap that always starts a new
session: before that a host row keeps today's accessory and today's tap, so the "+" never
promises what the tap does not do.

**Session row.** Indented by 20 points. Leading image: a 10-point filled circle, green for the
last looked-at session, clear otherwise (same width, so the texts line up). First line: the
preview (4.2). Second line: the state line (4.3), grey; the dot is the only green on the screen.
Identifier: `session-<host display name>-<n>` under a host, `n` counting from 1 in row order;
`session-<id>` without a saved host (as today, VC:367). Accessibility value: the state's
identifier. `n` is the row's place now: when a row above it goes, the rows below renumber, so a
UI test names a row by number only while no session of that host has ended since it read the
list, and checks a surviving row by its `$$`.

**Order (D3).** A host's sessions are listed oldest first by `meta.createdAt` (ties by id; a
record without `meta` last). A row keeps its place while its session lives; a new session
appears below the others.

**The dot** for UI tests: in UI-test launches the list publishes an element `lastSession` whose
value is the identifier of the dotted row, or `none` (the pattern of `liveTerminals`,
`UITestSupport.swift:109-128`).

### 4.2 What a session row shows, and where it comes from

- **The window title, if the host set one:** the framebuffer's `windowTitle` when
  `titleInitialized` is true and the title is not blank (mosh's own display writes a title only
  when it is initialized, `terminal/terminaldisplay.cc:74-77`). Control characters removed, at
  most 80 characters.
- **Otherwise the last line on the screen that is not empty**, trimmed. Otherwise, and whenever
  no preview can be read: "Session". The choice is one pure function on plain values,
  `SessionPreview.text(title:rows:)`.
- **The source** is the record's `snapshot` file, read without the lock: its bytes (a file above
  1 MiB gives no preview), `SnapshotCodec.decode(_:expecting:)` (public,
  `SnapshotCodec.swift:143-146`; it needs the id only, no key), then
  `.snapshot.transport.remoteStates.last` (the screen a resume shows first) and its framebuffer.
  The file is replaced whole (R8), so an unlocked reader finds the old or the new snapshot.
- **[!] A preview never says anything about a state.** Any failure (no file, damaged, another
  session's) is "no preview". States come from the counters only (R7).
- **Cache:** `SessionPreviewCache`, by session id, with the file's modification date and size;
  the snapshot is decoded again only when they change. Entries of ids that are gone are dropped.
- **"Last used"** is the newest modification time of the record's files, as today (SL:128-135):
  for a parked session, the moment of its park.

### 4.3 The state line

| State | Second line |
|---|---|
| resumable | "last used 5 min ago"; under a minute "last used just now" |
| dead | "Could not be resumed · last used …" (the brief's wording; today "Cannot be resumed") |
| ended | "Ended, server not yet stopped" |
| unreadable | "Cannot be read now" |
| being saved, ending, on screen | "Saving…", "Ending…", "Connected" |

One pure function, `SessionList.stateLine(_:now:)`. The relative time is in whole minutes, so
its text changes at most once a minute. From step 13b (`BRIEF.md` item 11) the resumable and dead
lines say the start first, from `meta.createdAt` in the same words: "started 2 h ago · last used
just now", "Could not be resumed · started 2 h ago · last used …"; the other states keep theirs.

### 4.4 Refresh

- As today: `reload()` when the list appears and after the editor; a 1 s timer reads the records
  again (VC:69-76). New, from step 8 (which brings `SessionActivity`; step 5's refresh has the
  timer only): `SessionActivity.onChange` (a park, a close or an end finished) reads them at
  once, so "Saving…" does not wait for the timer.
- When the rows are the same rows in the same order and only their texts changed, the visible
  cells are reconfigured in place (`reconfigureRows(at:)`; the app's target is iOS 18,
  `App/project.yml:13-14`). Step 5c: while a row's swipe actions are open nothing reads,
  reconfigures or reloads the table, on any path (the tick, `onChange`, an end, "Forget", "Delete",
  the editor, `viewWillAppear`); what wants it waits and is done once after the swipe has closed,
  from the main queue after UIKit's own `didEndEditingRowAt` has returned (a reconfigure of the
  open row slid its actions shut and open at every tick, and a reload from inside UIKit's reset of
  the swipe aborted the app), so a "Saving…" or "Ending…" elsewhere is drawn when the swipe closes.
- When rows came or went, the reload is held while a swipe is open or one of the list's alerts is
  up (a `reloadData()` closes a swipe), and the model is held with the table, so that a tap
  always acts on the row that is shown. It is done when that ends.
- Cost per second while the list is visible, per record: one counters read, one `meta` read, one
  directory listing with a stat per file (as today), and one stat for the cache.

### 4.5 Taps

One function `open(row)`: the guard (`Busy` allows a tap; no screen with a session that has not
been left, as VC:169); "opening" set and the launch's wait dropped; in a main-actor task: settle,
the gate, then the row's action (3.1, 3.2) with no suspension up to the push; every screen it
makes is loaded before the push (2.3). "Opening" is
cleared when the action produced no screen (an alert, a dropped tap) and in the list's
`viewDidAppear`.

### 4.6 Swipe actions

Table 3.4. Titles and alert titles stay ("End Session", "Forget", "End Session?", "Forget
Session?", "Session Not Ended", "Session Not Forgotten"). The "End Session?" text for a
resumable or unreadable row, from step 12 (with the ending it describes; until then today's
text): "Ends the session on <host>: its shell and the programs in it stop.
Then the session is removed from this phone." For dead and ended rows today's text (SSH and the
identity check) stays true and stays. An action acts on the session captured when the swipe was
built, as today (VC:394-403).

### 4.7 Accessibility identifiers

Kept: `host-<name>`, `session-<id>` (section 1), `noHosts`, `addHost`, `keysButton`,
`settingsButton`, `sessionWaiting`, `screenText`, `sessionStatus`, `connectProgress`,
`contactBanner`, `liveTerminals`. New: `session-<host>-<n>`, `hostPlus`, `lastSession`,
`sessionMenu`.

## 5. The terminal screen

### 5.1 The back button

"‹ Hosts" is already the list's `backButtonTitle` (VC:41). New: the list is under every
terminal. `SceneDelegate.navigation(showing:)` always builds `[list, terminal]`, also for a
session without a saved host and for a `-debugMosh*` session (today those are the root with no
back button, SD:116-123; A10); `retryColdStart` only pushes.

### 5.2 The "…" menu

`navigationItem.rightBarButtonItem`: image `ellipsis.circle`, identifier `sessionMenu`,
accessibility label "Session", a plain button with **no `UIMenu`**: a tap asks at once, and
once: alert "End Session?", "Ends the session on <host>: its shell and the programs in it
stop.", Cancel and End Session. (Decided 2026-11-22, row D8 of "Review status": with any `UIMenu`
on the bar, as a bar item's menu, on a button or deferred, the simulator lost the Cmd-V of
`LocalEchoUITests.testAPasteReachesTheSessionAsOneInput` in about 1 run of 20, because the app's
key commands were then not registered; the plain button lost 0 of 80. The brief asks for "End
Session" behind a "…" button, asking once: that is what this is. Wherever this text says "the
menu", it means this button and its question.) The action, in this order: `SessionFiles.clearLastLookedAt(ifNamed:)`
for the slot's session and for the old session of a fallback that is connecting (the ids of
`LeaveAction.idsToClear(slot:old:)`, a pure function), then `endRequested = true`, then the
pop. So the id is gone before anything of the ending can be interrupted.

### 5.3 What it does when it disappears

`viewDidDisappear` with `isMovingFromParent` (TVC:337-342) calls `leaveScreen()`. First, in every
case, what `endSession()` does first today (TVC:378-388): `ended = true`, the bootstrap task
cancelled, display link, timers and path watcher stopped; and `current = nil` if it is this
screen. Then one pure decision, `LeaveAction.decide(endRequested:slotFilled:attached:
serverEnded:fallbackInFlight:)`:

| End requested | Slot filled | Server ended | Fallback connecting | Action | Table |
|---|---|---|---|---|---|
| no | yes | no | — | `park` | B1, B5, B7, B8 |
| no | no | — | no | `cancelStart` | B2 |
| no | no | — | yes | `keepOldRecord` | B3 |
| either | yes | yes | — | `finishForget` (today, TVC:405-411) | B4 |
| yes | yes, attached | no | — | `shutdown`: today's `end` (TVC:425-443) in a `BackgroundTask`, its refused branch changed (E4) | E1, E4 |
| yes | yes, not attached | no | — | `closeOnly`: `close()`, nothing else; the record stays as it was (C11) | E1 before `attach` (as B7) |
| yes | no | — | no | `cancelStart` | E2 |
| yes | no | — | yes | `endDuringFallback` | E3 |

Leaving ends a session only when "End Session" asked for it. "Last looked at" was cleared
already by the alert's action (5.2). `end`'s refused branch (TVC:432-441) and the old record's end
of E3 both decide by one pure function,
`LeaveAction.afterStop(_ outcome: OldServerOutcome)`: forget only when `mayForget` (LA:238-244).
A resumed coordinator taken from the slot before `attach` never reaches `end`: `shutdown()`
would mark a clean session that never started "ended" (RC:647-663).

**[!] The slot is emptied at the leave for every action but `park`.** `shutdown` and
`finishForget` hand the coordinator to today's ending code; if the consumer still found it in
the slot at the end of the queue it would park it, and the park's `close()` would cut the
shutdown short (on a host with a known pid the SSH kill then hides the mistake and the tests
stay green; on `hg` the server is left). A run-time fallback empties the slot too, as it sets
`coordinator = nil` today (TVC:532).

**The size during the pop.** If UIKit takes the keyboard down before `viewDidDisappear`, the
grid grows and a Resize goes out before the park (TVC:974-994), and again at the unpark. Step 9's
UI test `testASwitchSendsNoResize`, with animations on and a software keyboard on screen, checks
this. If it happens, or the test cannot show it (no software keyboard up, or a control that does
not fail), step 9b holds the size from `viewWillDisappear` with
`isMovingFromParent`, as `SceneSavePolicy.announcesSize` holds it while the scene is not active,
and announces it in `viewDidAppear` if the pop was cancelled.

### 5.4 The server's end

On `.serverEndAcknowledged`, after `sessionIsOver()` (TVC:788-789): if the screen has not been
left and is the navigation's top, it pops itself. The event task has closed and forgotten the
session before `handle` runs (TVC:689-694), so the list no longer has its row; the leave that
follows is `finishForget` and finds the record gone. On `.serverEnded` alone nothing new
happens: the banner "Session ended" stays until the acknowledgment is out (normally the same
moment), and for good if it never gets out (X2).

### 5.5 What stays

The scene's calls through `current` (set in `viewDidLoad` as today), `SceneSavePolicy`, the
health check, probe and path watcher, both fallbacks, the prompts, drawing, the key bar, local
echo. A screen is never used twice: every unpark is a new screen (A7), and a left screen is
freed, so `liveTerminals` is 0 on the list (A25) and nothing of a parked session ticks (A5).

### 5.6 A screen freed without being left

Today `deinit` closes without a save, which leaves a started session dirty (TVC:189-193, A6).
New: when the queue ends and the slot still holds a coordinator, the consumer parks it (save,
then close). Only tests and a resumed screen that never appeared reach this.

## 6. "End Session" on a parked session, through mosh's own shutdown

**The core allows it, with no change** (`map-core.md` section 5), and the protocol steps are
mosh's own (checked in its source by the second reviewer). The brief's "To confirm" is answered
yes, on one condition that step 0 must show: no test has yet seen a real server acknowledge the
shutdown of a resumed coordinator. If step 0 fails, this section does not hold and the owner is
asked.

`SessionEnder.end(id:host:)` (new, app only), in its own `BackgroundTask`, the id "ending":

- **a.** `SessionFiles.clearLastLookedAt(ifNamed: id)`, and the launch's wait for that id is
  dropped. From here on a death of the process leaves a row, never a launch that starts a
  session by itself.
- **b.** Settle (G2).
- **c.** Cold start (key by id; G1). `.retryLater`: kept, "Session Not Ended: it cannot be
  opened now (<reason>)" (this is where an unreadable row ends, R4). `.fallback`: it was not
  resumable after all: h. Not a record: `forget`.
- **d.** `.resumed(c)`: a reader on `c.events`, then `try await c.start()`.
  **[!] `start()` must come before `shutdown()`.** `shutdown()` is accepted before it, but then
  nothing reads the server's answer (`MoshConnection.swift:165-176`, 243-248). If `start()`
  throws: `close()`, kept.
- **e.** Wait up to 10 s for proof that the server is there: `.contact`, or `.screen` with
  `isLive`. **[!] Why:** `shutdown()` marks the record "ended" before anything is sent (C7) and
  an ended record is never resumed (R16), so there is exactly one try. Spent while the network
  is down, it would leave a server that the app can never end on a host where it does not know
  the pid. After contact the request is also built on a state the server holds, without which
  mosh-server drops it (`network/networktransport-impl.h:97-111`). 10 s is mosh's own patience
  for a shutdown (`ACTIVE_RETRY_TIMEOUT`, `network/transportsender.h:57`).
- **f.** No proof in 10 s: `await c.enterBackground()`, `await c.close()`. The record is clean
  again by the ordinary save (quiesce, export, snapshot, clean mark with the export's token: C5,
  R5); datagrams were sent in those 10 s, so it is a new snapshot, not the old one. Then, with a
  saved host and a known server identity (LA:133-137): h, and the record stays resumable if that
  does not end it. Without (host `hg`; a session without a saved host): kept, "<host> did not
  answer. The session is kept; try again later, or use Forget." It is never deleted because
  there is "nobody to ask": `.nothingToAsk` may forget (LA:238-244), which is right for a record
  that cannot be resumed and wrong for one that can.
- **g.** Proof: `await c.shutdown()`. The record, dirty since `start()`, is now "ended"
  (RC:647-665). mosh's shutdown state is sent until it is acknowledged, at most 16 times or 10 s
  (`TransportCore.swift:733-747`; mosh `transportsender.h:56-57`,
  `transportsender-impl.h:384-395`); mosh-server leaves its loop once it has acknowledged
  (`frontend/mosh-server.cc:890-893`). The end, by `SessionEnding.after` (unchanged):
  `.shutdownFinished(acknowledged: true)` or `.serverEndAcknowledged`: `close()`, `forget`,
  done. `.shutdownFinished(acknowledged: false)`, or 11 s with neither (today's limit, TVC:427):
  `close()`, the record is "ended": h. Also: `.serverEnded` during e, or `shutdown()` answering
  false (already over): wait for `.serverEndAcknowledged` as here. `.baseStateLost` or
  `.halted`: the coordinator gave the record up (dirty): `close()`, h.
- **h.** The SSH way, today's `end` (VC:238-259): `stopOldServer(meta:host:)`; `forget` if
  `mayForget`; otherwise "Session Not Ended" with today's reason and the row as its files say.

The user sees "Ending…" on the row, normally for well under a second, for about 10 s when the
server does not answer. On `hg`, a to g need no pid: that is the case the brief asks for. A
session on `hg` whose server is gone ends at f, "kept": "Forget" removes it. The decisions of c
to h are one pure function (`SessionEndPlan`: phase and input give the next step), tested
without a server.

## 7. Changes per file

| File | Change |
|---|---|
| `App/IOSMosh/SessionActivity.swift` (new) | `@MainActor final class` with `shared`. A pure `Busy` value (`parking`, `ending`, `opening`, `waiting`) that answers: may this row take a tap, a swipe; may the launch retry. `track(release:until:)` chains the tail; `settled()`; `beginEnd`/`endFinished`; `beginOpen`/`openFinished`; `onChange` |
| `SessionQueue.swift` (new) | a screen's command stream, its slot (`held`: the coordinator to release; `isAttached`) and the consumer, moved out of the screen as they are at HEAD with the UI-test hook; the screen's three callbacks (input counted, local echo read, the hook) hold the screen weakly. `take()` empties the slot. From step 9: `.park` and the park at the queue's end (2.3, 5.6) |
| `LeaveAction.swift` (new) | `LeaveAction.decide` (5.3), `LeaveAction.idsToClear` (5.2), `LeaveAction.afterStop` (5.3), `ParkPlan.after` (2.3 steps 2 and 4), the open gate of G3 as a pure function |
| `SessionFiles.swift` | `LinksFile.lastLookedAt`; `lastLookedAt()`, `setLastLookedAt(_:)`, `clearLastLookedAt(ifNamed:)`; `forget` and `removeOrphans` clear it and write when either the link or the id changed; one `NSLock` around every read-change-write of the file (A15) |
| `SessionList.swift` | states `parking` and `ending`; `derive(_:isLive:isEnding:isParking:)`; "Could not be resumed"; oldest first; `rows(hosts:sessions:last:)` replaces `group`; `stateLine(_:now:)` |
| `SessionPreview.swift` (new) | `SessionPreview.text(title:rows:)`, `read(root:id:)`, `SessionPreviewCache` |
| `SessionListViewController.swift` | draws `ListRow`s (4.1); `open(row)` (4.5); swipes on session rows; its `ending` set moves to `SessionActivity`; refresh (4.4); `end` takes R1, R4 (section 6) or R2, R3 by state; the `lastSession` element |
| `SessionEnder.swift` (new) | section 6; `SessionEndPlan` |
| `TerminalViewController.swift` | uses `SessionQueue`; `leaveScreen()` (5.3); the "…" menu (5.2); the pop on the server's end (5.4); `attach` stores last looked at; the alert's action clears it (5.2); `finish` and `abandon()` are tracked releases (step 10); every read of the slot except the leave decision, the queue's end and `openSession`'s guard (which read `held`) reads `isAttached` (2.3, rule 2); `end` runs in a `BackgroundTask` and **its refused branch changes** (TVC:432-441): like `endDuringFallback` it forgets only by `LeaveAction.afterStop` (E3, E4, step 11b); the port message (H3); `BackgroundTask.deinit`. Unchanged bodies: the rest of `end` (the shutdown and its 11 s), `finish`, `begin`, `runtimeFallback`, the order inside `attach` |
| `SessionLauncher.swift` | `launchTarget(last:ended:)` (pure, 2.5); the launch decides for that one id (the newest-first loop, LA:45-60, goes) |
| `SceneDelegate.swift` | `makeRoot` by the launch target; the list always the root (5.1); the wait in `SessionActivity`; `retryColdStart` by the rule of W6; with `-uiTestingAnimations 1` a UI-test launch keeps animations on (no `setAnimationsEnabled(false)`, no `layer.speed = 100`; SceneDelegate.swift:20-24 at HEAD) |
| `DebugLaunch.swift` | a debug request (`-debugMosh*`, `-debugFallback*`) makes a record only when no stored record's `meta` names its address and port, and the fallback request is handed out once per process. Today both are read again at every use (`DebugLaunch.swift:42-44`, 67-81); with parked debug records a second record under the same key would start from sequence 0, the shape of N1 (A21). Debug builds only; a real host cannot repeat a key |
| `PortRangeFull.swift` (new) | `message(output:host:range:)` (pure): matches the literal "Failed binding to" in the output of a start that failed (the other lines end in the host's own language, `network/network.h:65-68`) |
| `UITestSupport.swift` | `LastSessionElement`; marks `park-clean`, `park-not-resumable`; `keepsAnimations` (`-uiTestingAnimations 1`, step 9) |
| `scripts/sim-test.sh` | one line before the key check (step 5b): `== servers left after the run:` and the spawner's answer to `/sshd/servers`. Today nothing asks before the EXIT trap (line 66) stops the spawner, whose `finally` kills the servers (`mosh-spawner.py:636-641`) |
| `scripts/mosh-spawner.py` | `/sshd/servers`, `/sshd/stop`, `/sshd/signal` accept a server whose `-p` range lies inside `62700:62799`, not only that exact text (mosh-spawner.py:418-427), so a test host can have a range of two ports |
| `App/project.yml` | none: its `sources` are folders |
| `Tests/MoshResumeTests` | two tests (step 0) |
| `docs/RESUME.md`, `docs/PLAN.md`, `docs/SERVER-SETUP.md`, `docs/MAC.md` | step 14 |

### The core

**No change in `Sources/`.** Four rules that the core does not enforce (`map-core.md`, "Missing"
2), and where this design keeps each:

| Rule | Kept by |
|---|---|
| `await close()` before the same record's cold start | G2 (`SessionActivity`); behind it G1, which refuses instead of harming. Test: step 10's `testAnOpenAfterALeaveFindsTheRecordFree` |
| `start()` before `shutdown()` | section 6 d; E1 is today's code on a session the screen attached and started. One exception, as today (TVC:426): a resumed session whose `start()` failed (storage) and was not yet tried again gets `shutdown()` with no reader; its record is "ended" and finished at the next launch (L6). Not engineered for (D7) |
| The key is read by the record's id | 2.1: one function reads keys and calls the cold start. Evidence of steps 9 to 12: `ResumeCoordinator.coldStart(` occurs once under `App/IOSMosh` |
| Contact before the shutdown of a resumed session | section 6 e |

Not taken: a public `SessionStore.readSnapshot()`. The app can read the file with public calls.
Not taken either: `enterBackground(afterSend: true)` in the park (risk 2).

**Hostile review all the same** for steps 8 to 12 and 11b (8b is read by step 9's), and of the
diffs of steps 2 and 4 before step 8 starts and before any build is offered to the owner (step 2 rewrites `forget` and
`removeOrphans`, which delete keys and records at every launch; step 4 decides which record a
tap resumes and a swipe ends, also for the leftovers `group` hides today): no line of `Sources/` moves, but they decide
in the app how a record is saved (the queue, the park), resumed (which record, after what) and
given up (the leave decisions, the launch target, the end of a parked session). The reviewer
gets this file, the three maps, `docs/RESUME.md` and the step's diff, and is asked for a
sequence of taps, kills, resigns and network losses that resumes a stale snapshot, opens a
record twice, uses a key for another record, starts a session by itself, or ends or deletes a
session the user did not end.

## 8. Tests: where they run and their rules

- **Unit tests** are in `App/IOSMoshTests` and need no server. A test that needs a started
  session makes its coordinator with `Options.makeTransport` (public, RC:165) set to a transport
  in the test target that drops every datagram; such a session saves clean (state 0 and the
  first Resize). A test that needs a failing write uses `Options.storageHook` (public, RC:155).
  So the park is tested through the real `SessionQueue` and its consumer on Apple's runtime,
  which is also the proof there that a stream hands out what was queued before `finish()`.
- **UI tests** run on the simulator against the spawner's sshd unless said. A flow that needs a
  resumable record before step 9 makes it as the resume tests do: Home, the mark
  `background-clean`, terminate, a launch with `-uiTestingSkipColdStart`.
- **Animations.** `-uiTesting` turns them off (SceneDelegate.swift:20-24 at HEAD). Only the two UI
  tests of step 9 that need UIKit's own transitions (a back swipe let go, the keyboard during
  the pop) add `-uiTestingAnimations 1`. With animations on, XCUITest may wait out its idle
  timeout before each action (up to 60 s, the reason `-uiTesting` turns them off), so those two
  tests keep to the few actions they need. There is nobody to check anything by hand: no person
  sits at the simulator.
- **No server is left over.** One spawner runs per suite run (`scripts/sim-test.sh:59-65`); the
  script's EXIT trap stops it (line 66) and its `finally` kills its servers
  (`mosh-spawner.py:429-437`, 636-641), but within a run every parked session leaves a
  mosh-server. From step 1 on, `openSession` registers a teardown that stops every server of
  the test range, and its check "no servers left from an earlier run"
  (`SessionListUITests.swift:299` at HEAD) stays. From step 5b on `openSession`,
  `startSavedSession` and `relaunchShowingTheList`, with that teardown, are in the shared
  `extension XCTestCase` of `SessionUITests.swift`, and every new UI test (of step 5b and later)
  that starts a session on the spawner's sshd starts it through them: XCTest runs the classes in
  alphabetical order, so `EndSessionUITests` and `LaunchUITests` run before `LocalEchoUITests`,
  `ResumeUITests` and `SSHBootstrapUITests`, which each check that no server is left. Those three
  existing classes keep their own start of a session, with their own "no servers left" checks;
  step 5b does not move them. From step
  5b on `sim-test.sh` prints what `/sshd/servers` answers before the spawner stops. Counts of
  servers in a test are sets of new pids.
- **Negative control:** each new test names the one change that, undone, makes it fail. It is
  undone once when the test is written, and the failing check is logged in `docs/MAC.md`.
- **Tests that exist and change:** every test that ends a session with the back button
  (`SessionListUITests`, `ResumeUITests`, `SSHBootstrapUITests`, `LocalEchoUITests`) ends it
  through one helper in `SessionUITests.swift`: step 5b brings the helper with today's back as
  its body and moves `SSHBootstrapUITests` and `LocalEchoUITests` onto it; step 6 makes its body
  the menu and moves `SessionListUITests` and `ResumeUITests` (as `376c583` left it) onto it,
  while back still ends too; so step 9 changes back without touching them. `SessionListUITests` reads the state from `session-<name>-1`
  instead of `host-<name>` from step 4 on. The resume tests keep passing with the launch by
  "last looked at": the id is written from step 2 on. `-debugCrashAfter` is armed by the first
  session that starts in the process (A23): a test passes it on the relaunch only.

## 9. Steps

Each step builds, passes the whole simulator suite (`scripts/mac.sh scripts/sim-test.sh`, 19
minutes today) and is one commit; after each, the app loses no session that today's app keeps.
A step is cut for one agent (about 25 points of a usage window): the agent runs its own tests
with `-only-testing:` first and the whole suite once, stops at 50% of the window, commits only
what is green and reports the rest. Models as in `CLAUDE.md`: Opus for screens, UI tests,
tooling and docs; the session model plus a hostile review (section 7) where marked.

**Evidence the checking agent must see before it pushes, for every step:** the suite's whole
output in a file, with its total, 0 failures and each new test passed by name; for each new test
its control's failing check in `docs/MAC.md`; `git status` naming only the step's files; from
step 5b on, the line `== servers left after the run:` of `sim-test.sh` with an empty list (steps
0 to 5 log "servers left after the run: not available yet": nothing asks `/sshd/servers` before
the script's EXIT trap stops the spawner). For steps 9 to 12 and 11b also: `grep -rn
'ResumeCoordinator.coldStart(' App/IOSMosh` finds one line (rule 3 of section 7). Steps add their
own below.

**Step 0. The core can end a resumed session** (yellow, Linux; session model).
Files: `Tests/MoshResumeTests/ResumeCoordinatorTests.swift`. Behaviour: none (tests).
- `testAResumedSessionEndsByMoshShutdown`: cold start, `start()`, contact, `shutdown()`,
  `.shutdownFinished(acknowledged: true)` from a real mosh-server, the server gone afterwards.
  Control: without `start()` no answer is read.
- `testAResumedSessionWithoutItsServerIsNotAcknowledged`: the same with the server stopped:
  `false`. Control: with the server left running the answer is `true`.
Evidence: both names passed in `out/yellow/suite.log`. If the first fails: stop, section 6 does
not hold, ask the owner.

**Step 1. Test hygiene** (Opus). Files: `App/IOSMoshUITests/SessionUITests.swift`
(`MoshSpawner.stopLeftoverServers()`), `SessionListUITests.swift` (`openSession` registers it).
Behaviour: none.
- `testServersATestLeftAreStopped`: a session, Home, the helper, then `sshdServers()` is empty.
  Control: the helper's body removed.

**Step 2. "Last looked at" is stored; debug requests are guarded** (Opus; the `DebugLaunch` rule
is read again by step 9's review). Files: `SessionFiles.swift`, `DebugLaunch.swift`, one line in
`attach`, the two places that take a debug request (SD:71-73, 101; TVC:486-488), new
`App/IOSMoshTests/SessionFilesTests.swift`, `DebugLaunchTests.swift`. Behaviour: same; nothing
reads the id yet.
- `testForgetClearsLastLookedAtWithAndWithoutALink`. Control: the write only when a link went
  (SF:94).
- `testRemoveOrphansClearsAnIdWithoutARecord`. Control: the id not among the visited ones.
- `testAFileWithoutTheKeyDecodes`. Control: the field not optional.
- `testLinkAndForgetFromTwoThreadsLoseNothing` (200 pairs). Control: without the lock, ten runs,
  the number that failed is logged and is not 0.
- `testADebugRequestIsRefusedWhenARecordNamesItsServer`,
  `testTheFallbackRequestIsHandedOutOnce`. Control: the rule answering yes.

**Step 3. The list's model** (Opus). Files: `SessionList.swift`,
`App/IOSMoshTests/SessionListTests.swift`. Behaviour: same; the screen still uses `group`.
- `testEverySessionOfAHostIsARowOldestFirst` (replaces
  `testANewerSessionOfTheSameHostIsTheOneShown`). Control: `group`'s rule.
- `testOnScreenBeatsEndingBeatsParkingBeatsTheFiles`. Control: two of them swapped.
- `testOnlyTheLastLookedAtRowHasTheDot`. Control: the dot by host.
- `testTheStateLineMovesOncePerMinute`. Control: seconds in the text.

**Step 4. Session rows under hosts** (Opus). Files: `SessionListViewController.swift`,
`SessionListUITests.swift`, `HostUITests.swift` where it reads a host row's state. Behaviour:
the screen changes. A tap on a session row is today's `openRecord`; a tap on a host row is
today's `open` for its newest session (resume it, or a new session if there is none or it is
ended); the swipes move to the session rows. Every record becomes a row, also leftovers that
`group` hides today. **No "+" yet:** a host row keeps today's accessory and today's tap until
step 10 (4.1); only its state line and its swipes move to its session rows (reading 7).
- `testASessionIsARowUnderItsHost`: the row's value `resumable`, the host's `sessions=1` and no
  `hostPlus`; a host without sessions reads `none`. Control: `rows` given no sessions.
- UI `testEndSessionOnOneHostLeavesTheOther`: two hosts, a resumable session on each (made as
  section 8 says: Home, `background-clean`, terminate, a launch with `-uiTestingSkipColdStart`,
  then the second host); `openSession` wipes sessions and hosts (`-uiTestingResetSessions`,
  `-uiTestingReset`), so the second host comes from a new helper in `SessionListUITests.swift`,
  `openSessionOnAnotherHost(_:spawner:name:)`: no reset, a host with the same sshd fields
  (127.0.0.1 and the same port) under another name, a tap, no Trust prompt (known hosts are
  keyed by host and port, so the first host's trust covers it), the `pid-$$` line and the new
  server's pid returned; "End Session" on the second host's session row: its server leaves
  `/sshd/servers`, the first host's server stays, and its row resumes the same `$$`. Control:
  the swipe acting on the first session row of the section (the row index without the host's
  offset).
- The existing swipe tests swipe the session row.
Evidence: screenshots of the list with zero, one and two sessions, light and dark.

**Step 5. Preview, "last used", the dot, refresh** (Opus). Files: `SessionPreview.swift`,
`SessionListViewController.swift`, `UITestSupport.swift`, new `SessionPreviewTests.swift`,
`SessionListUITests.swift`. Behaviour: the screen. The refresh is the 1 s timer and the
reconfigure in place of 4.4; `SessionActivity.onChange` does not exist yet and is wired in step 8.
- `testATitleWinsElseTheLastLine`. Control: the title check removed.
- `testReadGivesNoPreviewAndNeverWrites`: garbage, a missing file and another session's
  snapshot give nil; the counters are byte-equal before and after; it works while a coordinator
  holds the record. Control: the id check of `decode` skipped.
- `testTheCacheDecodesAgainOnlyWhenTheFileChanged`. Control: the cache keyed by id alone.
- UI `testARowShowsTheTitleAndTheDot`: `printf '\033]2;build box\007'`, a saved session: the
  row shows "build box" and "last used", `lastSession` names it. Control: the read removed.
- UI `testAnOpenSwipeSurvivesARefresh`: a saved session (made as section 8 says), its row swiped
  open, then a wait of 3 s (longer than the list's 1 s refresh): "End Session" and "Forget" of
  that swipe are still on screen. Control: the refresh reloading the table (`reloadData()`)
  instead of reconfiguring the rows: the swipe closes and the test fails.

**Step 5b. The UI tests share their session helpers; the run reports its servers** (Opus).
Files: `App/IOSMoshUITests/SessionUITests.swift`, `SessionListUITests.swift`,
`SSHBootstrapUITests.swift`, `LocalEchoUITests.swift`, `scripts/sim-test.sh`. Behaviour: none
(tests and tooling).
- The helper `endSessionFromTerminal(_:)` in the shared `extension XCTestCase` of
  `SessionUITests.swift`, whose body is today's tap on "Hosts" and the wait for the list. Every
  place in `SSHBootstrapUITests.swift` and `LocalEchoUITests.swift` where the back button ends a
  session calls it; a tap on "Hosts" from another screen (the editor, Settings) stays as it is.
- `openSession`, `startSavedSession`, `relaunchShowingTheList` and step 4's
  `openSessionOnAnotherHost` move from `final class SessionListUITests` into the same
  extension, with the teardown `openSession` registers (step 1), so that every UI-test class of
  the later steps (`SwitchUITests`, `LaunchUITests`, `EndSessionUITests`) uses them and stops
  what it leaves (section 8). The moved helpers read the screen through a new `screenRows(_:)`
  in the extension: `AppearanceUITests`, `BannerLayoutUITests` and `ResumeUITests` declare their
  own `rows(_:)`, which a method of the same name in an extension of `XCTestCase` would clash
  with.
- `scripts/sim-test.sh`, one line before the key check: `echo "== servers left after the run:
  $(curl -fsS --max-time 10 "$TEST_RUNNER_MOSH_SPAWNER_URL/sshd/servers")"`.
- No new test. Control: the helper's body without the tap: the moved tests fail at their wait
  for the list, logged in `docs/MAC.md`.
Evidence: the suite's total as before step 5b, 0 failures; `git grep 'buttons\["Hosts"\]'` in the
two files shows only the taps that do not leave a terminal; `git grep -n 'func openSession('
App/IOSMoshUITests` finds it once, in `SessionUITests.swift`; the line `== servers left after
the run:` in the output, with an empty list.

**Step 6. The "…" menu; the list under every terminal** (Opus). Builds on HEAD as it is after
`376c583` (that commit's rewrite of `ResumeUITests.swift` and its UI-test layout hook in
`TerminalViewController.swift` and `UITestSupport.swift` are kept) and after step 5b. Files:
`TerminalViewController.swift`, `SceneDelegate.swift`, the helper's body in
`SessionUITests.swift` (now the menu), `SessionListUITests.swift` and `ResumeUITests.swift` (moved
onto the helper). Behaviour: "End Session" exists; back still ends.
- `testEndSessionFromTheMenu`: the list, the server gone, the row gone. Control: the confirm
  doing nothing. (From step 9 on its control is the confirm as a plain pop: the server stays.)
- `testCancelLeavesTheSession`. Control: Cancel wired to the end.
- `testADebugSessionHasTheListUnderIt`. Control: today's `navigation(showing:)`.
**The owner can try a build:** nothing he has can break, offered only after the hostile review by
the session model of the diffs of steps 2 and 4 (section 7; it runs before step 8 starts and
before any build is offered) has reported and each finding is fixed or answered. Tell him: old
leftover records may show as "Could not be resumed" rows; and what is temporary: "‹ Hosts" still
ends the session, a tap on a host resumes its newest session, and there is no "+" yet.

**Step 7. The server's end returns to the list** (Opus). Files: `TerminalViewController.swift`,
`SessionListUITests.swift`.
- `testExitReturnsToTheList`: the list by itself, row and server gone, a relaunch resumes
  nothing. Control: without the pop `screenText` stays.

**Step 8. `SessionActivity` and `SessionQueue`** (session model; hostile review of the diff: can
a command now run that today is skipped, or the reverse). Files: the two new files,
`TerminalViewController.swift`, `SessionListViewController.swift`, new
`SessionActivityTests.swift`, `SessionQueueTests.swift`. Behaviour: same with one session,
except that the row of a session ended from the terminal reads "Ending…" while its shutdown
runs. **Today's `endSession()` empties the slot first** (5.3). Until step 9 a taken coordinator
that was not attached (a resumed screen left before `attach`) is closed and nothing else, as
today's leave leaves it (TVC:404) except that it is now closed: it never reaches `end`, whose
`shutdown()` would mark a clean session that never started "ended" (RC:647-663). Every read of
the slot except the leave decision, the queue's end and `openSession`'s guard reads `isAttached`
(2.3, rule 2: the scene's resign and return, health, probe, path watcher, `announceSize`,
`liveSessionID`, `runtimeFallback`'s guard); the review lists every read of the slot and what it
asks, and checks that `openSession`'s guard tests for an empty slot (`held`), not `isAttached`. The list reads the records again at `SessionActivity.onChange` (4.4). **A tap on a host
ignores "ending"**: today it starts a new session at once because the record already reads
"ended" (VC:170-176). So between steps 8 and 10 a host tap whose newest session is "Ending…"
starts a new session on that host and never opens the ending record; a tap in the moment before
`shutdown()` has marked it "ended" goes to the cold start, which meets the held lock (G1):
"Session Not Available Now". A coordinator still in the slot when the queue ends is closed, as
`deinit` does today.
- `testSettledWaitsForATrackedRelease`. Control: `settled()` not awaiting the tail.
- `testBusyDecidesTapSwipeAndRetry`. Control: swipes ignoring "opening".
- `testQueuedCommandsRunAfterTheScreenIsGone`. Control: the slot read weakly.
- `testATakenCoordinatorIsNotClosedByTheQueue`. Control: `take()` left out of `endSession()`.
- `testALeaveBeforeAttachClosesAndKeepsTheRecordClean`: a resumed coordinator in the slot, the
  screen left before `attach`: the lock is free, the counters clean and byte-equal. Control: the
  taken coordinator handed to `end`: the record reads "ended".
- `testAResignBeforeAttachIsSavedAtAttach`: a resign with the slot filled and not attached
  queues nothing; `attach` then queues the save. Control: `attach` not asking the policy.

**Step 8b. The leave decisions as pure functions** (session model; no behaviour change; read
again by step 9's hostile review, which wires them). Files: new `LeaveAction.swift`
(`LeaveAction.decide` of 5.3, `ParkPlan.after` of 2.3 steps 2 and 4), new
`App/IOSMoshTests/LeaveActionTests.swift`. Behaviour: none; nothing calls them yet.
- `testTheLeaveDecisions`: the rows of 5.3, and a resumed coordinator that is not attached
  gives `park` (and `closeOnly` with an end requested). Control: `slotFilled` taken from
  `attached`: such a coordinator gives `cancelStart`.
- `testOnlyAnEndedRecordIsForgottenByThePark`: every row of `ParkPlan.after` (2.3 steps 2 and
  4): `.clean`; `.ended` with an ended and with a dirty record; `.closed`;
  `.datagramSentSinceExport` and `.failed` (once more after 300 ms, then final). Control:
  forgetting on the save's answer alone.

**Step 9. Back parks** (session model; **hostile review before it is pushed**). Files:
`SessionQueue.swift`, `TerminalViewController.swift` (it calls step 8b's `LeaveAction`),
`UITestSupport.swift`, `SceneDelegate.swift` (`-uiTestingAnimations`), `SessionQueueTests.swift`,
new UI file `SwitchUITests.swift`.
Behaviour: back parks; a row resumes its session. Until step 10 a tap does not wait for a park
(a tap inside those tens of ms meets "Session Not Available Now", G1) and a host tap still
resumes the host's newest session; until step 11 the launch is today's (the newest record);
until step 11b a back during a fallback is today's (`keepOldRecord` runs today's branch, the
record deleted) and E3, E4 forget as today. "End Session" from the menu runs today's `end` in a
`BackgroundTask` (W4). The review also reads `LeaveAction.swift` (8b) and checks that
`DebugLaunch.fallbackRequest` has no reader outside step 2's rule (it is read at TVC:547 at
b5aec27, HEAD 585, in `runtimeFallback`, besides SD:101): a reader outside it would make a second
record under the fallback key from sequence 0 in a debug build.
- `testAParkSavesCleanAndFreesTheRecordThreeTimes`: three lives of one record through the
  queue: counters clean, the lock free, a cold start resumes. Control: no `enterBackground()`.
- `testAFailedSaveIsTriedOnceMore`. Control: one call only: the record is dirty.
- `testAFailedStartIsTriedAgainByThePark`: the second slot write of `beginSending` fails once
  and is slowed (`Options.storageHook`); the screen is left while `begin`'s `start()` is still in
  flight, before its throw; afterwards the mark and the counters agree. Control: step 1 of the
  park only when `startFailed` is set at the leave: one slot says dirty.
- UI `testBackParksAndTheRowResumesTheSameShell`: `echo pid-$$`, back, the row resumable, the
  server still runs; the row: the same `$$`, no banner. Control: back as today.
- UI `testSwitchingTenTimesBetweenTwoHosts`: no banner ever, the same two server pids,
  `liveTerminals` 0 on the list. Control: the park without its save.
- In both: until step 10 a tap during a park meets `.inUse`, so before every tap on a row the
  test waits for the row's value `resumable` (the park has closed).
- UI `testABackSwipeLetGoHalfWayParksNothing` (B6; `-uiTestingAnimations 1`): from the
  terminal's left edge a press, a slow drag to 40% of the width, a hold, the release
  (`XCUICoordinate.press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`): the
  terminal stays, no `park-*` mark, `echo still-$$` prints the same `$$`. Control: the leave run
  in `viewWillDisappear`: the cancelled swipe parks.
- UI `testASwitchSendsNoResize` (5.3; `-uiTestingAnimations 1`): `trap 'echo resized' WINCH`,
  `echo armed`; **before the back it asserts that a software keyboard is on screen**
  (`XCTAssertTrue(app.keyboards.count > 0)`), so that on a simulator with a hardware keyboard
  connected and no software keyboard up it fails instead of passing with nothing tested; back,
  the row `resumable`, a tap on it, `echo after-$$` on the screen. **The deciding assertion is
  its last line, `XCTAssertFalse(rows.contains("resized"))` on `screenText`** (a line printed
  before the park reaches the screen with the server's next frame). Control:
  `view.endEditing(true)` in `viewWillDisappear` (the keyboard down before the park): the
  deciding assertion fails. It passes and its control fails: step 9b is skipped. **Step 9b is
  built before step 10 in each of three cases:** the deciding assertion fails (the step commits
  the test with that one assertion inside `XCTExpectFailure("a Resize at a switch: step 9b")`);
  the test cannot be made to run with a software keyboard up (the keyboard check fails, or
  XCUITest's idle wait, section 8, keeps it from finishing; the step commits it inside
  `XCTSkip` with the reason); or its control does not fail (the test cannot see a Resize, so its
  pass proves nothing). The step logs which case in `docs/MAC.md`.
Evidence: the log's time from tap to first screen (risk 1); the review's report, each finding
fixed or answered.

**Step 9b. The size is held during the pop** (Opus; **built if step 9's
`testASwitchSendsNoResize` failed its deciding assertion, could not be made to run with a
software keyboard up, or had a control that did not fail** (step 9's three cases); skipped and
logged as not needed in `docs/MAC.md` only when that test passed with a software keyboard up and
its control failed).
Files: `TerminalViewController.swift` (`viewWillDisappear` with `isMovingFromParent` holds the
size, `viewDidAppear` announces it when the pop was cancelled), `SceneSavePolicy.swift`
(`announcesSize` takes the pop as a third reason to hold), `App/IOSMoshTests/SceneSavePolicyTests.swift`
(it exists; one test added), `SwitchUITests.swift` (the `XCTExpectFailure` of step 9 removed, in
the first case). Behaviour: no Resize at a back or at a tap on a row.
- `testASizeIsHeldWhileThePopRuns`: `announcesSize` answers no while a pop runs and yes after a
  cancelled one. Control: the pop ignored.
- In the first case only: UI `testASwitchSendsNoResize` (step 9's) now passes with its deciding
  assertion unwrapped. Control: the hold removed: that assertion fails.
Evidence, in every case: `testASizeIsHeldWhileThePopRuns` passed by name and its control's
failing check in `docs/MAC.md`; `grep -n 'isMovingFromParent' App/IOSMosh/TerminalViewController.swift`
shows the hold in `viewWillDisappear`. In the first case also: `testASwitchSendsNoResize` passed
by name, with no expected failure recorded. In the second and third cases instead: the test
stays in `SwitchUITests.swift` as step 9 committed it (`XCTSkip` with its reason, or passing
without a failing control), and `docs/MAC.md` names the case and says that the hold is built
without a UI test that can see a Resize.

**Step 10. Taps wait; a host tap is always a new session; the "+"** (session model; hostile
review of the diff). Files: `SessionListViewController.swift` (the gate, the host tap, the "+"
accessory of 4.1), `LeaveAction.swift` (the gate), `TerminalViewController.swift` (`finish` and
`abandon()` become tracked releases, G2), `SessionActivityTests.swift`,
`SwitchUITests.swift`. Behaviour: a tap on a host always starts a new session (3.1), and a host
with sessions shows the "+" from this step on, not before.
- `testATapIsDroppedWhenTheSceneIsNotActiveAfterTheSettle`. Control: the gate answering yes.
- `testAnOpenAfterALeaveFindsTheRecordFree` (rule 1 of section 7): through the real
  `SessionQueue` with a save slowed by `Options.storageHook`: the leave, `await settled()`, then
  the cold start answers `.resumed`. Control: the leave without `track`: `.retryLater(.inUse)`.
- UI `testTwoSessionsOnOneHost`: the host without sessions has no `hostPlus`; the host, back:
  its row has `hostPlus` and `sessions=1`; the host again: a second shell with another `$$`, two
  servers, `sessions=2`; row 1 resumes the first. Control: the host tap as before.
- UI `testARowTappedTwiceOpensOneTerminal`. Control: no "opening" guard: an alert.
- UI `testASilentServerAtASwitch`: SIGSTOP a parked session's server, tap, `contactBanner`,
  back, SIGCONT, tap: the stored screen, no fallback, the same `$$`, and `echo after-$$` typed
  then appears (the session is live, not only its stored screen). It would pass from step 9 on;
  it is here to keep step 9 small. Control: the park without its save: the second tap falls back.
Evidence also: `finish` and `abandon()` of `TerminalViewController.swift` each run inside
`SessionActivity.track(` (grep).

**Step 11. The launch target** (session model; **hostile review**).
Files: `SessionLauncher.swift`, `SceneDelegate.swift`, `SessionActivity.swift` (the wait),
`SessionListViewController.swift` (a tap drops the launch's wait, 4.5, 2.2),
`SessionResumeTests.swift`, new UI file `LaunchUITests.swift`. Behaviour: the launch goes into
the last looked-at session only (2.5); a back during a fallback and E3, E4 are still today's
(they delete the old record) until step 11b.
- `testTheLaunchTargetIsTheLastLookedAtSession`, `testNoLaunchTargetWithoutAnIdOrForAnEndedOne`.
  Control: the newest-first rule; the ended set ignored.
- UI `testAKillOffScreenResumesTheLastLookedAtSession`: A, B parked, A opened (the older one),
  Home, `background-clean`, terminate, launch: A's `$$`; B resumable. Control: the old rule.
- UI `testAKillWithTheListOnScreenGoesIntoTheDottedSession`: A opened, back (the list on
  screen), the mark `park-clean` awaited (a kill inside the park leaves the record dirty and
  the launch falls back), Home, terminate, launch: A's `$$`. **Encodes D1; it follows his answer to 10.2.**
  Control: `launchTarget` answering none when the list was on screen (the change 2.5 names for
  the other answer): the launch shows the list. So a flip of his answer is the only thing it
  encodes.
- UI `testACrashOnScreenFallsBackAndTheParkedOneStays`: B made first, A second (the newest
  record) and parked; a relaunch with `-debugCrashAfter` and `-uiTestingSkipColdStart` (the
  list, nothing started); B opened (the first session started in
  that process, so it is armed, A23) and crashed on screen; launch: the fallback banner on B's
  host, A's row resumable with its `$$`. Control: `launchTarget` by the newest-first rule: the
  launch resumes A, no banner.
- UI `testAfterTheDottedSessionEndsTheLaunchShowsTheList` (D4): A parked; B opened, `exit`;
  terminate; launch: the list, `lastSession` is `none`, A resumable. Control: a launch that
  takes the newest record when the id names none.

**Step 11b. A fallback he left, and an end that could not stop its server, keep the record**
(session model; **hostile review**). Needs step 11: each of these keeps a dirty record, which
the launch before step 11 (the newest record, LA:45-60) would fall back into. Files:
`TerminalViewController.swift` (`keepOldRecord` of B3; `endDuringFallback` of E3; `end`'s
refused branch, E4; the alert's action of 5.2), `LeaveAction.swift` (`afterStop`,
`idsToClear`), `LeaveActionTests.swift`, `LaunchUITests.swift`. Behaviour: B3, E3, E4 as in
3.3.
- `testAStopThatDidNotReachTheHostKeepsTheRecord` (LC-14): `LeaveAction.afterStop` keeps for
  `.hostNotReached`, `.notAnswered`, `.notThere(atSessionAddress: false)` and forgets for
  `.killed`, `.nothingToAsk`, `.notThere(atSessionAddress: true)`; `end`'s refused branch and
  `endDuringFallback` call it. Control: `afterStop` answering forget (today's rule).
- `testAnEndRequestClearsTheSessionAndTheOldOne`: `idsToClear` for a slot only, an old session
  only, both, neither. Control: the old session left out.
- UI `testEndSessionClearsTheDotBeforeTheShutdown`: a session, its server SIGSTOPped
  (`/sshd/signal`), "…" → End Session: on the list the row reads "Ending…" and `lastSession` is
  `none`; SIGCONT. Control: the clearing left out of the alert's action: `lastSession` names
  the row.
- UI `testAFallbackHeLeftDoesNotComeBack` (B3): a crash on screen; the host's port edited to a
  closed one under `-uiTestingSkipColdStart`; launch (the fallback's error banner); "Hosts";
  terminate; launch: the list, the row "Could not be resumed". Control: B3 without clearing the
  id.
Evidence also: in `TerminalViewController.swift`, `SessionFiles.forget` in `end`'s refused
branch and in `endDuringFallback` is reached only through `LeaveAction.afterStop` (grep and the
review), since `testAStopThatDidNotReachTheHostKeepsTheRecord` is pure and passes without it.
**The owner can try a build: the feature.** Tell him: the first launch shows the list once (the
record on his phone has no "last looked at" yet); until step 12, "End Session" on a parked row
on a host where the app does not know the server's pid (his `hg`) removes the session from the
phone and leaves its server and its shell running; question 10.2; the defaults of 10.3.

**Step 12. "End Session" on a parked row through mosh** (session model; **hostile review**).
Files: `SessionEnder.swift`, `SessionListViewController.swift`, new `SessionEndPlanTests.swift`,
new UI file `EndSessionUITests.swift`. Until this step, "End Session" on a parked row is today's
SSH kill: on `hg` it removes the session from the phone and leaves its server. This step also
brings the "End Session?" text of 4.6 for resumable and unreadable rows.
- `testTheEndPlan`: contact then shutdown; no contact with and without an identity;
  acknowledged; not acknowledged; the server's own end; a lost base state; `.retryLater` keeps.
  Control: the shutdown without contact.
- UI `testEndSessionOnAParkedSessionWithoutAPid` (a `-debugMosh*` session: no pid, no host, the
  shape of `hg`): the server exits and no `old-server-*` mark appears. Control: stage g removed.
- UI `testEndSessionWhenTheServerIsGoneKeepsTheSession`: a `-debugMosh*` session (no pid, no
  saved host), parked, its server stopped with the spawner's `/stop`; "End Session" on its row:
  "Session Not Ended" after about 10 s, the row still resumable; Forget removes it. (With a known
  pid, f would go on to h, which finds the server gone, `.notThere`, and forgets, LA:238-244.
  No test here covers that case: `testEndSessionOnAParkedSessionOfAHost` has its server
  running and ends it, so it is not a "server gone" case; this test, a debug session without a
  pid whose server is stopped, is the only "server gone" one.) Control: stage e removed: the
  shutdown goes out without contact, h finds nobody to ask (`.nothingToAsk` may forget), and the
  row goes.
- UI `testEndSessionOnAParkedSessionOfAHost`: the server leaves `/sshd/servers`, no
  `old-server-killed` mark. Control: stage g removed.
- UI `testAnInterruptedEndDoesNotStartASession`: the dotted row's server SIGSTOPped, End
  Session, terminate after 3 s, launch: the list, no `connectProgress`. Control: stage a removed.

**Step 13. The port message** (Opus). Files: `PortRangeFull.swift`,
`TerminalViewController.swift`, `scripts/mosh-spawner.py`, new `PortRangeFullTests.swift`,
`SwitchUITests.swift`.
- `testFiveLinesOfAFullRangeGiveTheMessage` (a `-s` server, the error words in another
  language), `testAnotherStartFailureGivesNoMessage`. Control: matching a translated line.
- UI `testTheLimitOfThePortRange`: a host with two ports, two sessions, a third tap: the banner
  names the range, no third server; after "End Session" on one **and its server gone from
  `/sshd/servers`** a new session starts. Control: a range of three ports.

**Step 14. Docs and the device build** (Opus). Files: `docs/RESUME.md` ("The app": leaving the
screen, the server's end, the cold start, End Session, the price of D5), `docs/PLAN.md`
(verification rows), `docs/SERVER-SETUP.md` (`set -g set-titles on`; a plain shell's preview is
its prompt), `docs/MAC.md` (the log), `CLAUDE.md` (status). Evidence: the device build's log.
**The build for his phone, installed on his word.**

## 10. Risks, the question, the defaults

### 10.1 Risks

1. **The cost of an unpark is not known.** A cold start is a Keychain read, a lock, two counters
   reads and a snapshot decode on the main thread, and `start()` adds four storage steps; the
   parts were measured on the phone (12 ms a save, 4 ms a reservation, `docs/RESUME.md:293`), the
   whole never. Step 9 logs it. Above about 100 ms the cold start moves off the main thread,
   which the design allows (it is already behind an `await`) with one more rule: G3 needs no
   suspension from the gate to the push, so after the cold start returns the gate is asked
   again on the main thread, and a `.resumed` result that it turns away is closed as a tracked
   release (G2) and the tap dropped as in H5.
2. **Input at a back (D5).** mosh sends new input at the later of 1 ms after the first unsent
   change and one send interval after the last datagram: 20 to 250 ms, 250 ms until the first
   answer of a life, which is every new session and every unpark
   (`network/transportsender-impl.h:73-83`, 101-107; the port: `TransportCore.swift:485-496`,
   `RTTEstimator.swift:18-20`, 54-57). The park's quiesce cancels that timer
   (`MoshConnection.swift:189-193`), so input younger than that, and input whose datagram was
   lost and not yet repeated, waits in the record until the session is opened again; nothing
   shows it. "End Session" on that row sends it too: section 6 d calls `start()`, which sends the
   stored input, and g ends the shell right after, so a command typed just before "‹ Hosts" can
   run at the moment he ends the session. On the phone the pop's animation lies between a key and the park. If he ever sees a
   command run late, build the bounded wait: before the save, poll `unacknowledgedInputCount()`
   (RC:741) for at most 1 s, skipped when the server is silent. The cheaper call,
   `enterBackground(afterSend: true)` (RC:481-486, a test seam: one more datagram, no wait), is
   not used now: it would make the park a different save from the scene's, and whether a
   datagram handed to an `NWConnection` leaves when the connection is cancelled in the same turn
   is not known (`NWDatagramTransport.swift:150-176`).
3. **The park depends on the consumer outliving the screen** (`SessionQueue`). It is the one new
   piece of lifecycle code and the first thing the hostile review should attack.
4. **A park that hangs blocks every open** (G2 has no timeout, on purpose: a timeout would open
   a record whose save is still running). Only storage can hang it; a park never waits on the
   network (`MoshConnection.swift:165-194`, 251-261).
5. **A copy (OSC 52) that arrives in the last milliseconds before back is not written to the
   pasteboard.** Not engineered for.
6. **A parked session whose server is gone** (its shell ended while it was parked; `exit` and
   back within the round trip; killed on the host). Nothing can tell the record. Opened, it
   shows the stored screen; with a known pid the probe replaces it with a new session after
   15 s; on `hg` it shows "Last contact" until he ends it from the menu or forgets it.
7. **A new session that never heard its server** (a network that drops UDP) is parked as
   resumable when he goes back, because back never ends (brief item 4). It has lost the 15 s "no
   reply" message for good (a resumed session has no such timer, `MoshSession.swift:167`), and
   its server exits by itself after 60 s. Not engineered for (D7).
8. **UIKit behaviour no unit test reaches:** a back swipe let go and the keyboard during the pop
   (step 9's two UI tests with animations on), and an open swipe during a refresh (step 5's UI
   test `testAnOpenSwipeSurvivesARefresh`).
9. **Previews.** With tmux the preview is tmux's status line unless tmux sets titles
   (`set -g set-titles on`). With a plain shell it is the prompt, so two sessions on one host
   read the same. That is what brief item 7 asks for; step 14 writes both into
   `docs/SERVER-SETUP.md` so that it is not taken for a bug.
10. **A full port range blocks every fallback on that host**, because the old server holds its
    port until the new one started. On `hg` the dead row's port cannot be freed from the phone.
11. **Other work changes the same files.** The work on the terminal screen, `UITestSupport.swift`
    and `ResumeUITests.swift` has landed as `376c583`; step 6 builds on it. Steps 0 to 3 are
    being built while later steps are planned. Each step starts from HEAD and keeps what it
    finds.
12. **The suite grows** by about twenty UI tests of 30 to 120 s each, to roughly 40 minutes.
13. **"End Session" from the menu on a session that never had contact** (opened without network,
    "Last contact" showing) spends the one shutdown try (C7, R16): on `hg` that server can then
    never be ended from the phone, while the same request on its row keeps the session (6 e, f).
    That is today's behaviour for leaving the screen. Not engineered for (D7).

### 10.2 The one question for the owner

**You were on the Hosts list when iOS killed the app. Should opening it show the list, or go
into the session with the dot?** The design goes into the dotted session (brief item 8 as
written). "The list" costs one small change (2.5).

### 10.3 Defaults taken for you (say no to any)

1. A host's sessions are listed oldest first, so a row never moves (D3).
2. After the session with the dot ends, no session has the dot until you open one, and opening
   the app then shows the list (D4).
3. "‹ Hosts" saves at once and sends nothing. What you typed in the last moment before it, if
   the server has not confirmed it, is sent when you open that session again, as mosh does while
   a laptop sleeps (D5). If you end that session from its row instead, it is sent just before
   the session ends, so that last command can still run.
4. After a crash the app starts the replacement session by itself once. If you go back from it
   before it connected, the old session stays in the list as "Could not be resumed" and later
   launches show the list.
5. "‹ Hosts" never ends a session, also one that has not connected yet: it stays in the list.

## Review status

Decisions referred to: **D1** the launch target as brief item 8 is written, open question, one
place. **D2** brief item 9 wins at a dirty last looked-at session. **D3** oldest first. **D4** no
dot after the dotted session ends. **D5** a park is today's save and sends nothing. **D6** the
draft's step 8 is split. **D7** no engineering for cases that do not happen to him, no concern
about servers left running, no core change without a hostile review.

| Finding | Decision | Reason | Changed |
|---|---|---|---|
| U1 | accepted, corrected in one part | parked sessions do leave servers and the next `openSession` fails on them; they do not pile up across runs, the spawner kills them when a run ends (`mosh-spawner.py:429-437`, 621-640) | 8, step 1 |
| U2 | accepted | the two tests need a started session; a dropping transport and the storage hook are public options (RC:155, 165) | 8, 7 (`SessionQueue`), steps 5, 9 |
| U3 | decided D6 | step 8 of the draft is steps 8 to 11 | 9 |
| U4 | decided D4 | — | readings 6, 2.5, 10.3 |
| U5 | accepted | today's `open` has no answer for a session row (VC:168-178) | step 4 |
| U6 | accepted | a number is a place, not a name | 4.1 |
| U7 | accepted | with D1 | 2.5, step 11 |
| U8 | accepted | texts are reconfigured in place; only a change of rows is held | 4.4 |
| U9 | accepted | — | reading 7 |
| U10 | accepted | — | risk 9, step 14 |
| LC-1 | accepted | the resign reaches `current` only (SD:42-44, TVC:202, `SceneSavePolicy.swift:12`, 28-30) | 2.4 G3, H5, W7, 4.5 |
| LC-2 | decided D5 | no call makes delivery certain; the seam is not known to work on the phone | 2.3, risk 2, 10.3 |
| LC-3 | accepted | a dirty record the id still names starts a session at launch (RC:451-456, SD:94-110) | 2.5, 6 a, E1, W4 |
| LC-4 | accepted | a second `enterBackground()` saves again (RC:498-507, 549-553) | 2.3 step 2, B5 |
| LC-5 | accepted | nobody closes a resumed coordinator before `attach` (TVC:404, 189-193, 493-495) | 2.3 rules, 5.3, B7 |
| LC-6 | accepted, with the second pass's condition | forget only an ended record; "ended" as an answer also means given up (RC:98-99) | 2.3 step 4, B8, risk 6 |
| LC-7 | accepted | — | 2.2, R6, W6 |
| LC-8 | accepted | `forget` writes only when a link went (SF:94); the old control could not fail | 2.5, step 2, step 11 |
| LC-9 | accepted | `.nothingToAsk` may forget (LA:159-162, 238-241) | R4, 6 c |
| LC-10 | accepted | — | 6 f |
| LC-11 | accepted | as today, the replacement is offered once (TVC:390-403); follows D2 | reading 1, B3, 2.5, 10.3 |
| LC-12 | decided D7 | the change would end a session at a back, against brief item 4 | reading 8, risk 7, 10.3 |
| LC-13 | accepted | the gate writes two slots one after the other (`FileBackedGate.swift:237-249`, 305-311; RC:495) | 2.3 step 1 and table |
| LC-14 | accepted | today both forget whatever the kill said (TVC:398-402, 438-441) | E3, E4 |
| LC-15 | accepted as a check, the fix named | UIKit's order cannot be read from the code | 5.3, step 9 |
| LC-16 | accepted | both requests are read again at every use (`DebugLaunch.swift:42-44`, 67-81; SD:71-73) | L1, 7, step 2 |
| LC-17 | accepted | `-s` gives two binds and five lines (`network.cc:268-286`, 348; `mosh-server.cc:368-371`) | H3, 7, step 13, risk 10 |
| LC-18 | accepted | (a) and (b) are in step 8, (c) is told with step 11b's build | 5.3, steps 8, 11b |
| LC-19 | accepted | items 3 and 4 concern a map and a code comment, which this file does not change | conventions, 2.3, H3, B2, 6 g |
| CL-1 | accepted | `startFailed` is set only after `start()` threw (TVC:726-733, 777-785), so a flag fixed at the leave can be false; a second `start()` is a no-op once started (RC:445) | 2.3 step 1 and its table, step 9 (the test leaves while `start()` is in flight) |
| CL-2 | accepted; its placement in step 9 refuted, placed in step 11b | 5.3 and 7 kept `end`'s body, whose refused branch forgets whatever the kill said (TVC:432-441). E3, E4 and B3 keep a dirty record, and until step 11 the launch takes the newest record (LA:45-60) and would fall back into it | 3.3 E1, E3, E4, 5.2, 5.3, 7, step 11b (LC-14's pure test, the clearing tests) |
| CL-S1 | accepted, its failure path refuted | the finding's outcome does not happen (`sceneResigned` notes the resign whatever it answers, `SceneSavePolicy.swift:15-18`, so `attach` saves), but which reads mean "attached" must be said | 2.3 rule 2, 7, step 8 (`testAResignBeforeAttachIsSavedAtAttach`) |
| CL-S2 | accepted | cheap; only the unpark said `loadViewIfNeeded()` | 2.3, H1, S4, W6, 4.5, risk 1 |
| CL-S3 | accepted | rule 1 had no failing test, rule 3 no check; rule 2's exception is today's code (TVC:426) on a storage failure only (D7), said, not engineered | 7 (the core), 9 (evidence), step 10 |
| CL-S4 | accepted | steps 2 and 4 delete and choose records with no hostile review before the owner's first build | summary 10, 7, step 4, step 6 |
| CL-S5 | accepted | a resumed coordinator taken before `attach` must not reach `shutdown()` (RC:647-663) | 5.3 (`closeOnly`), step 8 |
| CL-S6 | accepted | true and one sentence | risk 2, 10.3 item 3 |
| CL-S7 | accepted | (a) RC:489, 496, 544; (b) TVC:415; (c) the clearing moves before the pop | 2.3 step 2 and its table, W4, E1, 5.2, step 9 |
| CP-1 | accepted: the "+" in step 10 | the "+" promises the tap of brief item 2, which comes in step 10 | 4.1, step 4, step 10 |
| CP-2 | accepted | `376c583` has landed (ResumeUITests.swift, TVC, UITestSupport.swift); the two other files move to a helper first | 8, step 5b, step 6, risk 11 |
| CP-3 | accepted | the size hold is needed only if step 9's test shows a resize | 5.3, step 9, step 9b |
| CP-S1 | accepted | the old control did not touch D1 | step 11 |
| CP-S2 | accepted | between steps 8 and 10 the host tap on an "Ending…" newest session was not said | step 8 |
| CP-S3 | accepted | the Status overstated what was read | Status |
| CP-S4 | accepted | B3's test moves with B3's fix to step 11b | steps 11, 11b |
| L2-O1 | accepted: the sentence struck, the 300 ms wait kept (D7) | the other change would not help: a new session's unrun `start()` was deferred by the resign (RC:446-449, 494), so the park's call is deferred too; `ParkPlan.after` loses its "attached" input | 2.3 step 2, step 8b |
| L2-S1 | accepted | until step 12 the swipe is VC:238-259, and on `hg` `.nothingToAsk` forgets (LA:159-162, 238-244) | step 11b ("Tell him"), 4.6, step 12 |
| L2-S2 | accepted | `announceSize` reads `coordinator` (TVC:986) and would set `announcedSize` before `attach` | 2.3 rule 2, 7, step 8 |
| L2-S3 | accepted | `runtimeFallback` reads `DebugLaunch.fallbackRequest` (TVC:547; HEAD 585); step 2 is not changed, step 9's review checks it | step 9 |
| L2-S4 | accepted | steps 8 to 12 build on `forget`, `removeOrphans` and step 4's choice of record | summary 10, 7, step 6 |
| L2-S5 | accepted | `shutdown()` is refused for storage only while the record is clean (RC:647-659), and false when already over (`MoshConnection.swift:237-241`) | 3.3 E4 and the text under the table |
| L2-S6 | accepted, as a sentence (D7) | a queued `.background` defers the park's `start()` (RC:446-449) | 2.3 table |
| L2-S7 | accepted | (a) the tap drops the wait in the list; (b) no step named the tracking; (c) the pure test passes without the call | steps 10, 11, 11b |
| L2-S8 | accepted, as a risk (D7) | the menu's end on a session without contact is today's behaviour for back | 10.1 risk 13 |
| P2-O1 | accepted | the pure decisions build and pass alone | step 8b (new), step 9 |
| P2-M1 | accepted | `openSession`, `startSavedSession`, `relaunchShowingTheList` are methods of `final class SessionListUITests` (HEAD 296-357); the other classes' `rows(_:)` would clash with an extension method of that name | 8, step 5b |
| P2-M2 | accepted | the EXIT trap (sim-test.sh:66) stops the spawner, whose `finally` kills the servers (`mosh-spawner.py:636-641`), and nothing asks before | 7, 8, 9 (evidence), step 5b |
| P2-M3 | accepted | with a known pid f goes on to h, `.notThere` forgets (LA:238-244) | step 12 |
| P2-M4 | accepted | no person sits at the simulator; `-uiTesting` turns animations off (SceneDelegate.swift:20-24 at HEAD) | 5.3, 7, 8, step 9, step 9b, risk 8, not yet verified 2 |
| P2-S1 | accepted | until step 10 a tap during a park meets `.inUse` | step 9 |
| P2-S2 | accepted | a kill inside the park leaves the record dirty | step 11 |
| P2-S3 | accepted | `openSession` resets hosts and sessions (HEAD SessionListUITests.swift:304) | step 4 |
| P2-S4 | accepted | both controls changed the test, not the app | steps 10, 11 |
| P2-S5 | accepted | the second `start()` can succeed and send (RC:451-466) | 2.3 ("The park sends nothing") |
| P2-S6 | accepted | `MoshConnection.swift:196-213` is `quiesceAfterSend`; the proof is in the resume tests | 2.3, 8 |
| P2-S7 | accepted | three things in the step-6 build are temporary | step 6 |
| P2-S8 | accepted | `SessionActivity` comes in step 8 | 4.4, step 5, step 8 |
| P2-S9 | accepted | CL-S1 and CL-2 were in part refuted | Status, rows CL-S1 and CL-2 |
| V-1 | accepted | with a hardware keyboard and no software keyboard up the test passed with nothing tested; it now asserts a software keyboard first, and a control that does not fail means 9b is built | step 9, 5.3, summary 10 |
| V-2 | accepted | step 9 and 9b disagreed on when 9b is built, and 9b's evidence could not be met when the test cannot run | step 9, step 9b, 5.3, summary 10 |
| V-3 | accepted | at HEAD `ResumeUITests`, `LocalEchoUITests` and `SSHBootstrapUITests` start their own sessions and step 5b does not move them | 8 |
| V-4 | accepted | `func openSession` also matches `openSessionOnAnotherHost` | step 5b |
| V-5 | accepted | the list after "except the two named below:" read as the exceptions; `openSession`'s guard asks for an empty slot (V-7) | 2.3 rule 2, 7, step 8 |
| V-6 | accepted | the host-session test has its server running; the server-gone test is the debug session without a pid | step 12 |
| V-7 | accepted | `openSession`'s guard asks whether the slot is empty, which `isAttached` does not answer for a resumed coordinator before `attach` | step 8, 2.3 rule 2, 7 |
| V-8 | accepted | nobody sits at the simulator; the check by hand becomes a UI test with a control | step 5, risk 8 |
| D8 | decided (2026-11-22, the session that runs the build) | the "…" button has no `UIMenu` and asks "End Session?" at once: a `UIMenu` on the bar made the simulator lose Cmd-V in 1 run of 20 (step 6, objection B); the brief's item 5 is kept; told to the owner | 5.2 |

## Not yet verified

1. **Apple's runtime.** That a stream hands out what was queued before `finish()` was shown on
   Linux (132,000 runs) and read in the library's source; step 9's unit tests are the proof on
   the simulator. If it does not hold there, the park is handed to the consumer through the slot
   instead of the queue; nothing else changes.
2. **UIKit:** that `reconfigureRows(at:)` leaves an open swipe alone (step 5); that the keyboard
   does not go down before `viewDidDisappear`, and that a cancelled back swipe calls no
   `viewDidDisappear` (step 9's two UI tests with animations on); that such a test finishes in a
   usable time despite XCUITest's idle wait (step 9).
3. **mosh-server's words at a full port range reach `BootstrapError.output`** (stderr through
   the pty): step 13's UI test.
4. **No UI test depends on a `-debugMosh*` session being the navigation's root:** step 6's suite.
5. **How the indent, the dot and the "+" look:** the screenshots of steps 4 and 5.
6. **The time of an unpark** (risk 1).
7. **Line numbers.** Read again for this revision, at `b5aec27`: TVC 104-108, 145-150, 183-203,
   262-312, 329-457, 480-503, 527-534, 636-700, 722-802, 1060-1076; RC 94-100, 441-468, 476-510,
   536-556, 570-580, 644-668, 698-745; SF 40-50, 78-116, 136-141; LA 37-62, 143-165, 232-246;
   SD 38-56, 62-125, 145-158; VC 166-180, 238-259; `SceneSavePolicy.swift` 1-40;
   `DebugLaunch.swift` 40-45, 66-82; `FileBackedGate.swift` 237-249, 303-312;
   `mosh-spawner.py` 328-342, 416-440, 556-572, 612-642; `SessionListUITests.swift` 277-310;
   of mosh, `mosh-server.cc` 366-371, 682, 838-894, 912-919 and the bind messages of
   `network.cc`. Every other line number is as the maps and the two critiques give it (the
   second reviewer checked each mosh citation and A1 to A25). Read again for the answers to
   `checks.md`: TVC 330-450, 480-505, 636-800 at `b5aec27`; RC 86-115, 440-510, 536-580, 640-668;
   LA 30-64, 125-170, 225-250; VC 160-215, 330-380 and `SceneSavePolicy.swift` at HEAD;
   `git show --stat 376c583`; the "Hosts" taps of the UI tests at HEAD. Read again for the
   second half: at `b5aec27` RC 440-510, 636-668, LA 125-245, `MoshConnection.swift` 150-265,
   every read of `coordinator` in TVC, `ResumeIntegrationTests.swift` 186-196; at HEAD
   `sim-test.sh` 40-103, `mosh-spawner.py` 410-445 and 610-645, `SessionListUITests.swift` 1-20
   and 270-357, the declarations of every UI-test file, `SceneDelegate.swift` 15-35,
   `UITestSupport.swift`'s flags, the readers of `DebugLaunch.fallbackRequest`.
8. **This file was revised in passes and not read back in full by a second reader.** The first
   step's agent should report any place where two sections disagree.
9. **What the checks did not reach.** The second half (`checks.md`) covered what the first had
   left: the second `start()` (FileBackedGate 237-249, 292-311), LC-8, LC-16, LC-17,
   `SceneSavePolicy`, N1 to N4 against the gate and PLAN section 3, the C and R numbers, the
   tooling for two hosts and a two-port range, about forty citations, the U scenarios. Still not
   read by any check: the three maps, `MoshSession.swift` and `TransportCore.swift` beyond the
   cited lines; that `TerminalSerialization` stores `windowTitle` (step 5); the `HostUITests`
   reads of step 4; the scheme's test order (alphabetical is assumed, XCTest's default). The
   hostile reviews of steps 8 to 12 are asked to cover the lifecycle parts.
