# Map: the host list screen and what it shows

Map for the multi-session design (`BRIEF.md` beside this file). Facts only, from `main` at
`b5aec27` (2026-11-21), each with file:line. No design. Covered: all sections listed below; not
covered: the rest of `TerminalViewController` beyond what the list depends on, and
`ResumeCoordinator` internals (separate maps).

Paths: `VC` = `App/IOSMosh/SessionListViewController.swift`, `SL` = `App/IOSMosh/SessionList.swift`,
`SF` = `App/IOSMosh/SessionFiles.swift`, `HS` = `App/IOSMosh/HostStore.swift`,
`LA` = `App/IOSMosh/SessionLauncher.swift`, `SD` = `App/IOSMosh/SceneDelegate.swift`,
`TVC` = `App/IOSMosh/TerminalViewController.swift`, `ST` = `Sources/MoshResume/SessionStore.swift`.

## 1. The screen (`SessionListViewController`)

### Shape

- `UITableViewController`, style `.insetGrouped` (VC:37). Title "Hosts" and
  `navigationItem.backButtonTitle = "Hosts"` set in `init`, not `viewDidLoad`, because a resumed
  terminal is pushed over the list before the list loads (VC:38-41).
- State: `hosts: [SavedHost]` (VC:22), `sessionsByHost: [UUID: ListedSession]`, one record per
  host (VC:23), `otherSessions: [ListedSession]` (VC:24), `refreshTimer` (VC:25), `ending:
  Set<SessionID>` for End Session in flight (VC:27), `waitingLabel` (VC:28).
- Bar buttons: right "+" `addHost` (VC:51-54); left "Keys" `keysButton` and gear
  `settingsButton` (VC:55-61). Both push their screen (VC:140-146).
- Sections: 1, or 2 when `otherSessions` is not empty (VC:319-321). Section 0 = one row per saved
  host, or one "No hosts yet. Tap + to add one." row (`noHosts`, not selectable) when there are
  no hosts (VC:327-328, 342-351). Section 1 header "Sessions Without a Saved Host" (VC:323-325),
  one row per record of no saved host (VC:328).
- `session(at:)` maps an index path to `(host?, session?)`: section 0 gives the host and
  `sessionsByHost[host.id]`; section 1 gives `(nil, otherSessions[row])` (VC:309-317).

### Rows (`cellForRowAt`, VC:341-376)

- A fresh `UITableViewCell(style: .subtitle)` every time, not dequeued (VC:352).
- Host row: text `host.displayName` (name, or host when the name is empty, HS:71); secondary text
  `user@host[:port]` (port only if not 22), plus a second line `stateLine(session)` if the host has
  a record (VC:357-360); accessory `.detailButton` (VC:361); identifier `host-<displayName>`
  (VC:362), not unique if two hosts share a display name.
- Other-session row: text `user@hostName` from `meta` (`hostName` alone if user empty), or
  "Unknown host" without `meta` (VC:364-365); secondary `stateLine` (VC:366); identifier
  `session-<session id>` (VC:367), the lowercase UUID (`SF` links use `id.description`, SF:26).
- Colour: secondary text green for `.resumable`, grey otherwise; left default for `.live`
  (VC:369-371).
- `accessibilityValue` = `"ending"` while End Session runs, else `state.identifier`, else `"none"`
  for a host without a record (VC:373-374). The UI tests read this.
- `stateLine` (VC:332-339): "Ending…" while ending; otherwise `state.label`, plus
  " · last used <relative>" (`RelativeDateTimeFormatter`, `.short`, VC:29-33) when `lastUsed` is
  known and the state is not `.live`.

### Refresh

- `viewWillAppear`: `reload()` and a 1 s repeating `Timer` calling `reloadSessions()`
  (VC:69-76); `viewWillDisappear` stops it (VC:83-87). So nothing refreshes while the terminal
  (or Keys, Settings, the editor) is on top.
- `reload()` (VC:89-98): `store.load()` (hosts.json; on error an empty list and an alert), then
  `readSessions()`, then `reloadData()`. Called at appear, after the editor finishes (VC:150-154),
  after End Session (VC:256), Forget (VC:287) and host Delete (VC:292-299).
- `reloadSessions()` (VC:101-107): reads the records again and calls `reloadData()` only when
  `sessionsByHost`, `otherSessions` or `SessionList.waitingReason` changed. The relative
  "last used" text is therefore not redrawn while nothing else changes.
- `readSessions()` (VC:109-113): `SessionList.load(liveID: TerminalViewController.current?.liveSessionID)`,
  then `SessionList.group(_, hosts:)`, then `updateWaitingLine()`. Hosts are not re-read every
  second, only records.

### The "waiting" header

- `SessionList.waitingReason` (static, SL:88) is set by `SceneDelegate.terminal(for:)`: the
  reason on `.retryLater`, nil on every other decision (SD:81-85). A tap's `.retryLater` does not
  set it, only shows an alert (VC:190-193).
- `updateWaitingLine()` (VC:116-132): with a reason, a table header view holding `waitingLabel`
  (identifier `sessionWaiting`, VC:66), text `"A session is waiting: <reason>. It is tried again
  when the app becomes active."` (SL:90-92); without, the header is removed. Re-laid out on width
  change from `viewDidLayoutSubviews` (VC:78-81).
- The retry: `SceneDelegate.sceneDidBecomeActive` → `retryColdStart()` when `coldStartPending`
  (SD:46-52); it does nothing while a `TerminalViewController.current` exists and stays pending
  (SD:125-133); otherwise it pushes the decided terminal (SD:134-140).

### A tap on a row, step by step

1. `didSelectRowAt` deselects, resolves `(host, session)` and calls `open` (VC:378-382). The
   info button instead opens the editor (VC:384-387).
2. `open(host:session:)` (VC:168-178):
   - returns if `TerminalViewController.current?.liveSessionID != nil` ("one live session at a
     time", VC:166-169);
   - no record, or a record whose listed state is `.ended`: `connect(host)` = push
     `TerminalViewController(start: .host(host))` (VC:158-164, 170-175). An ended record is left
     where it is (stopped at the next launch or by End Session, VC:171-172). An other-session row
     (no host) does nothing here;
   - `.live` or being ended: nothing (VC:176);
   - any other state (resumable, dead, unreadable): `openRecord(id, host:)` (VC:177). The listed
     state never decides the outcome (SL:7-10).
3. `openRecord` (VC:182-213), on the main thread, synchronously:
   `SessionLauncher.coldStart(root: SessionFiles.root, id:, keys: .shared, options:
   SessionLauncher.coldStartOptions(root:id:))` (VC:183-184).
   - `coldStartOptions` reads `meta` without the lock for the transport's address and port, and
     local echo from the linked saved host (LA:126-130).
   - `coldStart(root:id:keys:options:)` (LA:66-105): Keychain key first; a Keychain error other
     than "malformed" is `.retryLater` (LA:77-79); no key is a fallback without touching the
     record (LA:81-91); otherwise `ResumeCoordinator.coldStart(..., key: .provided(key),
     currentSize: nil, options:)` (LA:92), which takes the record's lock and loads the snapshot
     (`ResumeCoordinator.swift:276`, 326).
   - `.nothing` → `connect(host)` (VC:186-187).
   - `.resumed(coordinator)` → push `TerminalViewController(start: .resumed(coordinator, host:))`
     (VC:188-189).
   - `.retryLater(reason)` → alert "Session Not Available Now" (VC:190-193).
   - `.fallback`: not a record → `SessionFiles.forget`, then `connect` (VC:195-198); ended on
     purpose (`!wantsNewSession`) → `finishEnded` in a Task and a new session (VC:199-203); with a
     host → push `.fallback(fallback, host:, debug: nil)` (VC:204-205); without a host → forget
     and alert `ColdStartFallback.plainMessage` (VC:206-210). Then `reloadSessions()` (VC:211).
4. The terminal: `init(start:)` sets `host`, `title = host?.displayName ?? "Session"`
   (TVC:145-169). `viewDidLoad` sets `TerminalViewController.current = self` (TVC:202, a `static
   weak var`, TVC:62). `viewDidAppear` → `startSessionIfNeeded()` once the view has a size
   (TVC:331-335, 482-504):
   - `.host`: `bootstrap` (SSH, host key prompt, password, `mosh-server new`, TVC:554-631), then
     `openSession`: Keychain key (TVC:642), `SessionFiles.link(id, to: host?.id)` (TVC:648),
     `ResumeCoordinator.create(... storesKey: false ...)` (TVC:663-666), `attach` (TVC:675).
   - `.resumed`: `attach(coordinator)` (TVC:493-495).
   - `.fallback`: status banner, `startReplacement` (TVC:496-503).
   - `attach` (TVC:679-721) starts the event task, the save-at-attach rule, `begin` →
     `coordinator.start()` (TVC:725-739), the path watcher and the 1 s health timer.

### Navigation and the back button today

- The list pushes the terminal itself (`push`, VC:162-164) with
  `navigationController?.pushViewController(_:animated: true)`.
- At launch `SceneDelegate.navigation(showing:)` builds `[list, terminal]` when the terminal has a
  saved host, or makes the terminal the root (no back button) for a debug session (SD:116-123).
  With `-uiTestingSkipColdStart` the list is the root (SD:64-66).
- The terminal has no custom back item; the list's `backButtonTitle` gives "‹ Hosts".
- Back today ends the session: `viewDidDisappear` with `isMovingFromParent` (or a dismissal) →
  `endSession()` (TVC:337-342) → `shutdown()` (record "ended" first), then close and delete on an
  acknowledged shutdown, or keep the "ended" record (TVC:376-455; docs/RESUME.md "The app", row
  "Leaving the screen").
- The server ending the session (Ctrl-D, `exit`): `.serverEnded` shows "Session ended" and calls
  `sessionIsOver()` (TVC:763-766, 800-807); the screen stays, nothing pops. The record is removed
  by the event task on `.serverEndAcknowledged` (`SessionEnding.after`, TVC:689-693).
- Leaving to the background is not a list concern: `SceneDelegate.sceneWillResignActive` →
  `TerminalViewController.current?.sceneWillResignActive()` (SD:42-44) → `enterBackground()` in a
  background task (TVC:349-354, 306-311).

### Swipe actions

- Leading swipe (VC:391-407), only on a row with a record that is not `.live` and not being
  ended; two actions, no full-swipe action (VC:405):
  - **"End Session"** (destructive) → alert "End Session?" (VC:221-231) → `end(session, host:)`
    (VC:238-259): adds the id to `ending`, `reloadData`; in a Task:
    `SessionLauncher.stopOldServer(meta: session.meta, host:)` (LA:158-190): silent key login to the
    saved host, `connection.killServer(pid:expectedStartTime:)` after the identity check. Then if
    `outcome.mayForget` (LA:238-244: `.nothingToAsk`, `.killed`, `.notThere(atSessionAddress:
    true)`) → `SessionFiles.forget(id)`; a false return is an alert "record is in use"
    (VC:247-250). Otherwise alert "Session Not Ended" with `notEnded(_:host:)` (VC:251-253,
    261-272). Always `ending.remove`, `reload()` (VC:255-257).
    - Without a saved host, or with `meta.serverPID == 0` / `serverStartTime == 0`,
      `serverIdentity` is nil (LA:133-137) and the outcome is `.nothingToAsk` with no SSH at all
      (LA:159-162), which `mayForget`: the record is deleted and the server is not contacted. This
      is the case of a host where the app never learns the server's pid (BRIEF.md, "To confirm").
    - The record is not opened or locked by End Session; mosh's own shutdown is not used here.
  - **"Forget"** (normal) → alert "Forget Session?" (VC:274-290) → `SessionFiles.forget(id)`
    (SF:79-97): `ResumeCoordinator.deleteRecord` (takes the lock, `RecordError.locked` if held,
    `ResumeCoordinator.swift:371-377`), then the Keychain key, then the link. False → alert
    "Session Not Forgotten".
- Trailing swipe (VC:409-423), host rows only: "Delete" (`store.delete(id:)`, no confirmation,
  VC:292-299; the host's records stay and move to section 1 because their link no longer matches
  a saved host, SL:119-123) and "Edit" (editor).

## 2. The model behind it

### `SavedHost`, `HostStore` (HS)

- Fields (HS:5-25): `id`, `name`, `host`, `port`, `user`, `keyName`, `serverPath`, `locale`,
  `udpPortRange` (`"60001"` or `"60001:60010"`, empty = server default), `remoteCommand`,
  `allowClipboardWrite`, `swipeSendsPaging`, `localEcho`.
- `HostStore` = `Application Support/hosts.json`, `{version: 1, hosts: [...]}`, written atomically
  (HS:117-190, 198). An unreadable file throws, never an empty list (HS:141-158). `upsert` posts
  `LocalEcho.hostSaved` (HS:182), which an open terminal observes (TVC:168).

### Links: how a session belongs to a host (SF)

- `Application Support/session-hosts.json`, `{version: 1, links: {"<session id>": <host UUID>}}`
  (SF:19, 23-27). Written when a new session's record is made (`link(id, to: host?.id)`,
  TVC:648; SF:46-50), removed by `forget` (SF:93-94) and `removeOrphans` (SF:102-119). A debug
  session has no link (SF:13).
- `links()` (SF:58-64) is what the list reads; `host(of:)` (SF:67-70) re-reads hosts.json for one
  id (used by SceneDelegate and `coldStartOptions`).
- `SessionMeta` holds only host name, address, port, user, remote command, start size, server pid
  and start time (TVC:649-660); the host's other settings come only through the link (SF:10-13).

### Finding the records (`SessionList.load`, SL:95-110)

- `SessionStore.sessionIDs(root:)`: directory names under `Application Support/sessions` that
  parse as session ids, nothing read (ST:128-131).
- Per id, without the coordinator and without the record's lock (SL:83-84):
  - `store.readCounters()`: opens `counters`, reads both slots with `pread` and picks the newest
    valid one (ST:233-245; slots are CRC-checked, `Counters.swift:65`, 83). Any throw (missing,
    EACCES on a locked device, damaged) → `.unreadable` (SL:101-105).
  - `store.readMeta()`: whole `meta` file, up to 1 MiB (ST:222-225); a failure gives `meta: nil`.
  - `lastModified(directory:)`: directory listing and a `stat` of each file, the newest
    modification date (SL:128-135). `counters` is written in place on every reservation and
    `snapshot` on every save, so for a live session it moves while sending; for a parked one it is
    the last save.
  - `links[id]` for `hostID`.
- Sorted newest first by `meta.createdAt`; a record without `meta` sorts first (`?? .max`,
  SL:109).
- Cost: one links read, one directory listing, and per record one open+2 preads, one meta read,
  one listing+stats; every second while the list is visible (VC:73-75), plus on every `reload()`.

### States a row can show (`ListedSessionState`, SL:11-70)

| State | Derived from (SL:31-47) | Label (SL:61-69) | Identifier |
|---|---|---|---|
| `live` | `id == liveID`, whatever the counters say | "Connected" | `live` |
| `resumable` | counters `.clean(_)` | "Resumable" | `resumable` |
| `ended` | counters `.ended` | "Ended, server not yet stopped" | `ended` |
| `dead` | any other counters state (stage 1: `.dirty`) | "Cannot be resumed" | `dead` |
| `unreadable` | counters could not be read | "Cannot be read now" | `unreadable` |

- `liveID` is `TerminalViewController.current?.liveSessionID`, which is the coordinator's id while
  the screen has not been left (`ended ? nil : coordinator?.id`, TVC:176). Since the list's timer
  runs only while the list is visible, and leaving the terminal sets `ended`, "live" is seen at
  most during the pop.
- The brief's wording "Could not be resumed" (BRIEF.md item 7) is today "Cannot be resumed"
  (SL:66).
- Plus two UI-only values: "Ending…"/`ending` (VC:333, 374) and `none` (no record, VC:374).

### Grouping (`SessionList.group`, SL:114-126)

- A record whose `hostID` is a saved host goes to `byHost[hostID]` only if that slot is empty:
  as the input is newest first, each host keeps its **newest** record and **every older record of
  that host is dropped from the list** (not shown in section 1 either; SL:119-121). Unit test
  `testANewerSessionOfTheSameHostIsTheOneShown` (`App/IOSMoshTests/SessionListTests.swift:99`).
- A record with no link, or a link to a host that is no longer saved, goes to `other` (SL:121-123).

### Elsewhere, "one session" is assumed by the launch

- `SessionLauncher.coldStart(root:keys:skipping:)` takes the newest record by `meta.createdAt`
  (LA:40-60, comment "normally at most one record"); records without `meta` are deleted and the
  next is tried (LA:52-56). Every `.ended` record is finished in the background and skipped
  (`finishEndedSessions`, SD:147-156; `endedRecords`, LA:202-209). Nothing records which session
  was looked at last.

## 3. What a session row could show from a parked record

### Where the data is

- `snapshot` file in the record directory, `StoredSnapshot` (`Sources/MoshResume/SnapshotCodec.swift:7-16`),
  format SnapshotCodec.swift:18-55: the transport's held remote states, each a
  `TerminalState` skeleton plus row indices into a shared row table.
- `StoredSnapshot.snapshot.transport.remoteStates` (`Sources/MoshTransport/TransportTypes.swift:222`),
  ascending by number; the screen a resume shows first is `remoteStates.last`
  (`Sources/MoshSession/MoshSession.swift:163-168`, "the newest is the last").
- `TerminalRemoteState.framebuffer` (`Sources/MoshSession/TerminalRemoteState.swift:83`) →
  `Framebuffer` (`Sources/MoshTerminal/Framebuffer.swift:16-28`): `rows`, `windowTitle` and
  `iconName` (`[UInt32]` code points), `titleInitialized`, `ds.height`. All publicly readable.
- Titles are serialized in the skeleton (`Sources/MoshTerminal/Serialization.swift:490`, 522-523).
  OSC 0 sets both, 1 the icon name, 2 the window title, at most 256 code points, and sets
  `titleInitialized` (`Sources/MoshTerminal/Dispatcher.swift:190-209`; mosh
  `.refs/mosh/src/terminal/terminalframebuffer.h:451-454`). mosh's display writes a title only
  when `is_title_initialized()` (`.refs/mosh/src/terminal/terminaldisplay.cc:74-95`).
- A row's text: `Framebuffer.rowText(y)` (public, UTF-8, one grapheme per cell, blank for empty,
  `Sources/MoshTerminal/DebugDump.swift:107-111`); `LocalEchoElement.rows(_:)` already turns a
  framebuffer into trimmed row strings (`App/IOSMosh/UITestSupport.swift:99-105`).
- The app never reads `windowTitle` or `iconName` today (no use in `App/`).

### Which existing call reads a snapshot

- `SessionRecord.loadSnapshot()` (public, `Sources/MoshResume/SessionRecord.swift:128-142`): needs
  an open `SessionRecord`, i.e. `SessionRecord.open`, which **takes the record's lock**
  (SessionRecord.swift:79-97, ST:143-161), and it throws unless the record is clean for that
  snapshot. Called by `ResumeCoordinator.coldStart` (`ResumeCoordinator.swift:326`) and the device
  probe (`App/IOSMosh/DeviceProbe.swift:488`).
- `SessionStore.readSnapshot()` reads without the lock but is **internal** to MoshResume
  (ST:247-252).
- `SnapshotCodec.decode(_:expecting:)` is public (SnapshotCodec.swift:143) and works on bytes, so
  the app could read `<record dir>/snapshot` itself (`SessionStore.directory` is public, ST:103)
  without a core change. No such call exists in the app today.

### Cost

- File: 292 bytes for a new blank 80x24 session, about 15 KB for eight held states of a full
  80x24 screen (docs/RESUME.md:446-448); read limit 256 MiB (SnapshotCodec.swift:60).
- Decode builds every row and every held `TerminalState`, not just the newest
  (SnapshotCodec.swift:203-248). Row decoding calls `RowGeneration.reserve(through:)`
  (`Sources/MoshTerminal/Serialization.swift:14`, 362): a process-wide side effect (it only
  raises the floor of new generation numbers).
- At the list's 1 s refresh that would be one full decode per record per second unless cached
  (for example by the file's modification date).

### What is unsafe or misleading

- A record being written: `snapshot` is replaced by write-tmp, fsync, rename, fsync dir
  (`Sources/MoshResume/Storage.swift:383-398`), so an unlocked reader sees the old or the new
  whole file, never a mix. `counters` is written in place, one slot at a time, CRC-checked.
  `create` writes `counters` last (ST:169-209), so a record being made reads as unreadable for an
  instant.
- The live session's record: its snapshot is the last background save, stale while the session
  runs (counters dirty after `enterForeground`, docs/RESUME.md "The app"). The live screen is in
  the terminal's `frames`, not on disk.
- Taking the lock to read (`SessionRecord.open`) collides with the app's own users: a tap's cold
  start would get `RecordError.locked` → `.retryLater(.inUse)` ("Session Not Available Now"),
  and Forget would fail with "in use" (`ResumeCoordinator.swift:387-388`, 371-377).
- Damaged or foreign bytes: decode is strict and throws (SnapshotCodec.swift:142-271); a preview
  must treat a throw as "no preview", never as a record state.
- On a locked device the files are `completeUntilFirstUserAuthentication`
  (`Sources/MoshResume/RecordProtection.swift:63`): readable after the first unlock; before it,
  EACCES, as the `unreadable` state already shows for counters.

## 4. UI tests and their support

### Tests that touch the list, resume, End Session, Forget

- `App/IOSMoshUITests/SessionListUITests.swift`:
  `testASavedSessionIsListedAsResumableAndATapResumesIt` (16), `testEndSessionStopsTheServerAndRemovesTheSession`
  (48), `testForgetRemovesTheSessionAndLeavesTheServerRunning` (73),
  `testEndSessionThatCannotReachTheHostKeepsTheSession` (98),
  `testAnUnansweredShutdownKeepsTheSessionEndedUntilEndSessionStopsTheServer` (133),
  `testAnUnansweredShutdownIsFinishedByTheNextLaunch` (167),
  `testARecordThatCannotBeReadIsListedAndTheLaunchWaits` (196). Helpers: `openSession` (279),
  `startSavedSession` (313: Home, wait for mark `background-clean`, terminate),
  `relaunchShowingTheList` (325), `relaunchNormally` (264), `swipeAction` (255, `row.swipeRight()`
  then the button by title), `leaveWithTheServerStopped` (239).
- `App/IOSMoshUITests/ResumeUITests.swift`: tests at 28, 73, 132, 180, 226, 287 (kill in the
  background, second generation, size change in the background, crash in the foreground, server
  gone, dirty record kills the old server).
- Others that rely on "back ends the session" (`buttons["Hosts"].tap()` then
  `sshdServers() == []`): `SessionListUITests.swift:40-41`, 229-230; `ResumeUITests.swift:277-278`,
  341-342; `SSHBootstrapUITests.swift:55-60` (also `liveTerminals == "0"`), 68-69;
  `LocalEchoUITests.swift:247`, 250, 262-263; `HostUITests.swift:223`.
- Unit tests: `App/IOSMoshTests/SessionListTests.swift` (states 29-58, waiting text 60, End Session
  message 65, records read and grouped 76, newest per host 99);
  `App/IOSMoshTests/SessionResumeTests.swift` (cold start, ended records, forget, orphans, reset
  argument 349); `App/IOSMoshTests/SessionEndingTests.swift`.

### Accessibility identifiers in use

- List: `host-<displayName>` cell (value = state identifier or `none`/`ending`), `session-<id>`
  cell, `noHosts`, `addHost`, `keysButton`, `settingsButton`, `sessionWaiting`; nav bar "Hosts";
  swipe buttons by title "End Session", "Forget"; alerts by title "End Session?", "Forget
  Session?", "Session Not Ended".
- Editor: `field.<key>` for name, host, port, user, serverPath, locale, udpPorts, remoteCommand
  (`HostEditorViewController.swift:140`, 221), `saveHost` (47), `deleteHost` (106),
  `knownHostKey` (94), `forgetHostKey` (97), `commandPresets` (197); the info button is reached
  as `cell.buttons.firstMatch` (`HostUITests.swift:175-181`).
- Terminal: `screenText` (value = visible rows), `sessionStatus`, `connectProgress`,
  `contactBanner` (TVC:216-228), `terminalAppearance`, `localEcho`; window: `liveTerminals`
  (count of live terminal controllers, `UITestSupport.swift:110-128`); alerts `hostKeyAlert`,
  `passwordAlert`, `passwordField` (TVC:900, 918, 922).

### Servers (`scripts/mosh-spawner.py`, client `MoshSpawner`, `App/IOSMoshUITests/SessionUITests.swift:66-202`)

- Started once per run by `scripts/sim-test.sh` with `--sshd` (sim-test.sh:61); its URL reaches
  the tests as `MOSH_SPAWNER_URL` (SessionUITests.swift:79-87).
- Endpoints (mosh-spawner.py:7-60): `/new` (a direct `mosh-server new -i 127.0.0.1 -- /bin/sh`,
  port + key + pid; `delay_ms`, `program`), `/alive`, `/stop`, `/mark`, `/marks`, `/marks/clear`,
  `/diagnostics`, `/keycheck`, `/sshd`, `/sshd/authorize`, `/sshd/servers`, `/sshd/stop`,
  `/sshd/signal`.
- One throwaway sshd per run (`Handler.sshd`, mosh-spawner.py:444, 548-585) on 127.0.0.1, one
  UDP range `62700:62799` (mosh-spawner.py:338-340, the value at 340) that every test host uses (`udpPorts` from
  `/sshd`). `/sshd/servers` lists every mosh-server with `-p 62700:62799` (mosh-spawner.py:418-427).
- Two servers and two sessions at once: the spawner allows it (many `/new` servers; many
  mosh-servers through the one sshd, 100 UDP ports). Two saved hosts can point at the same sshd
  (different names). There is no second sshd, so two hosts are never two machines (same address
  127.0.0.1). The current helpers assume one: `openSession` asserts `sshdServers() == []` before
  and `count == 1` after (SessionListUITests.swift:282, 307), and many tests wait for
  `sshdServers() == []` after back.
- `Handler.bundle_id` (used for diagnostics) is being changed by the parallel debug-app work: at
  HEAD `us.v9n.ios-mosh`, in the working tree now `us.v9n.ios-mosh.dev` (mosh-spawner.py:449,
  uncommitted). Line numbers of `scripts/mosh-spawner.py` in this map are from the working tree
  as read on 2026-11-21 and may shift by a line or two.

### Launch arguments that matter

- `-uiTesting 1`: animations off, `screenText` and friends published (SD:20-25, 32-34; TVC:272-276).
- `-uiTestingResetSessions 1`: deletes `sessions/`, `session-hosts.json` and all session Keychain
  items at scene connect (SF:121-142; SD:27), unless `-uiTestingKeepSessions 1` (SF:126-128).
- `-uiTestingKeepSessions 1`: the relaunches of resume and list tests.
- `-uiTestingSkipColdStart 1`: root = the list, no cold start, no ended-record finishing, but
  orphans are still removed (SD:63-66; `UITestSupport.swift:15-24`).
- `-uiTestingReset 1`: no hosts, no known host keys (HS:203-211).
- `-uiTestingCountersMode 000|600`: chmod of every record's `counters` (SF:144-161).
- `-uiTestingSpawnerPort N`: the app's marks (`UITestMarks`, `UITestSupport.swift:130-164`):
  `background-clean`, `background-not-resumable` (TVC:309), `background-input`,
  `background-resize` (TVC:301-305, 325-329), `old-server-<outcome>` (LA:195-197, 226-234).
- Also `-uiTestingKeepSettings` (`AppSettings.swift:81`), `-uiTestingHardwareKeyboard`
  (`KeyBarView.swift:282`).
- Debug session arguments (`App/IOSMosh/DebugLaunch.swift:7-23`): `-debugMoshPort/-debugMoshKey
  [-debugMoshHost]` open a session straight to that server only when the cold start found no
  record (SD:71-73); `-debugFallbackPort/-debugFallbackKey` replace the bootstrap in a fallback;
  `-debugCrashAfter N`; `-debugLocalEcho`; `-debugPlaceholder 1`; `-debugSwipePaging`
  (`SwipePaging.swift:42`). A debug session has no host link, so it lands in section 1, and its
  terminal is the navigation root with no back button (SD:116-123).

## 5. The host editor's fields that matter here

- "UDP ports" field, key `udpPorts`, placeholder `60001:60010`
  (`HostEditorViewController.swift:79`), saved as `udpPortRange` (282).
- Validation: `SavedHost.serverCommand()` parses it with `UDPPortRange(_:)` (HS:76-85;
  `Sources/MoshBootstrap/MoshServerCommand.swift:2-30`, the forms of `mosh-server -p`); empty =
  no `-p`.
- What limits sessions on one host: each session is its own `mosh-server`, which binds the first
  free UDP port in its range (`.refs/mosh/src/network/network.cc:304-314`), and fails with "Could
  not bind" when none is free (network.cc:288). Without `-p` the range is mosh's
  `PORT_RANGE_LOW..HIGH` = 60001..60999 (`.refs/mosh/src/network/network.h:136-137`). Ports held
  by any other process on that host (other users' mosh sessions too) count against the range. A
  failed bootstrap shows its error in the terminal's status banner (TVC:615-629).
- The app counts nothing per host today: no code compares the number of records of a host with
  its range.

## What the new screen needs that does not exist yet

- All records of a host in the list: `SessionList.group` keeps only the newest per host and drops
  the rest (SL:119-121).
- Session rows indented under their host, with their own identifiers and accessibility values
  (today only `host-<name>` and `session-<id>` in section 1).
- The "+" mark on a host row that has sessions.
- Row preview text: an unlocked snapshot read in the app (`SessionStore.readSnapshot` is internal;
  `SnapshotCodec.decode` on the file's bytes is the public path), the newest remote state's
  `windowTitle` when `titleInitialized`, else the last non-empty `rowText`; a cache so the 1 s
  refresh does not decode every second.
- A record of which session was looked at last (the green dot, and the launch going there): the
  launch picks the newest by `createdAt` (LA:47-49), and nothing stores "last looked at".
- Leaving the terminal without ending the session (park): back today calls `endSession()`
  (TVC:337-342).
- "End Session" behind a "…" button in the terminal's navigation bar; none exists.
- End Session of a parked record through mosh's shutdown: the list's End Session uses only the
  SSH identity-checked kill and, with no pid in `meta`, deletes the record without stopping the
  server (LA:133-137, 159-162, 238-244).
- Returning to the list when the server ends the session (Ctrl-D): the terminal stays on screen
  with "Session ended" (TVC:763-766).
- Taps on another session while one is open: `open` refuses any tap while
  `TerminalViewController.current` has a live session (VC:169); `retryColdStart` waits while any
  terminal exists (SD:128-133).
- The row wording "Could not be resumed" (today "Cannot be resumed", SL:66).
- UI-test helpers for two sessions: `openSession` asserts no servers before and exactly one after
  (SessionListUITests.swift:282, 307); a way to tell which server belongs to which session (today
  only pids from `/sshd/servers`).
- A per-host session count against the UDP port range (nothing counts it today).
