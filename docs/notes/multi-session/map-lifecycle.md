# Map: the session lifecycle in the app, and every place that assumes one session

Read-only map for the multi-session design (`BRIEF.md` in this folder). Facts are from the code at
HEAD `b5aec27` (2026-11-21), with file:line. App paths are relative to `App/IOSMosh/`; core paths
start with `Sources/`. No design here: where a fact bears on parking, the map says what the code
does and what that implies, not what to build. Nothing in this file changes `BRIEF.md`.

**Covered:** the terminal screen, the scene and its save policy, the launcher, files and keys,
the list's use of "the" session, debug and test hooks, the background/foreground sequence call by
call, the closing table. **Not covered** (other maps): the host list's layout and its tests in
detail, the `ResumeCoordinator` calls for the row preview and "End Session" on a parked session.

## 1. Words

- *Record*: `Application Support/sessions/<id>/` (`SessionFiles.swift:15-17`), made, opened and
  deleted only through `ResumeCoordinator` (`SessionFiles.swift:7-8`).
- *Open* session: a `ResumeCoordinator` that holds the record's `flock`. One writer per record
  (R12, `docs/RESUME.md`; `Sources/MoshResume/SessionStore.swift:143-161`). A second open in the
  same process fails with `RecordError.locked` (flock is per open file description;
  `SessionStore.swift:153-158`), which a cold start turns into `.retryLater(.inUse)`
  (`Sources/MoshResume/ResumeCoordinator.swift:388-389`, `SessionLauncher.swift:101-103`).
- *Live* (list word): the record of `TerminalViewController.current?.liveSessionID`
  (`SessionListViewController.swift:110`, `TerminalViewController.swift:176`).

## 2. The terminal screen (`TerminalViewController.swift`)

### 2.1 What it is

- One controller = one *start* (`Start`, `:45-50`: `.host`, `.debug`, `.resumed(coordinator, host:)`,
  `.fallback(fallback, host:, debug:)`), stored immutable (`:75`). It starts once
  (`startRequested`, `:111`, `:483-484`) and once left (`ended`, `:110`, `:377-378`) nothing
  starts again in it (`:483`, `:605`, `:617`, `:637`). A controller cannot be re-shown for a
  second life of its session; a resumed session today is always a new controller with
  `.resumed` (`SceneDelegate.swift:93`, `SessionListViewController.swift:189`).
- It can hold more than one coordinator over its life, one at a time: a fallback (cold-start or
  run-time) replaces `coordinator` (`:532`, then `openSession` `:675` → `attach` `:680`).
  `oldSession`/`oldMeta` (`:100-103`) are one slot for "the record that fell back".

### 2.2 Everything it owns for as long as a session

| Owned | Where made | Where stopped | Per what |
|---|---|---|---|
| `coordinator` | `attach` `:680` | `runtimeFallback` `:532` (set nil); never nil-ed at `endSession` | controller |
| `eventTask` (consumes `coordinator.events`, also does `finish`) | `:687-696` | ends with the stream at `close()` (`ResumeCoordinator.swift:711`); cancelled at run-time fallback `:533`; **not cancelled by `endSession`** | coordinator |
| `commandTask` + `commands` stream (serial queue of input, resize, background, foreground, replaceSocket, prediction) | `:149`, `:285-295` | `commandContinuation.finish()` `:389`, deinit `:187` | controller |
| `connectTask` (SSH bootstrap) | `:490`, `:513` | `:379-380`, deinit `:188` | controller |
| `displayLink` (weak proxy) | `:278-280` | `:381-382`, deinit `:184` | controller |
| `resizeTimer`, `announcedSize` | `:978`, `:673`, `:991` | `:383-384` | controller |
| `healthTimer` (1 s), `lastContact`, `activeSince`, `nextProbeAt`, `probing`, `isAppActive` | `:716-718`, `:136-143` | `:385-386`, `:534-535`, `sessionIsOver` `:802-803` | controller |
| `pathWatcher` (`NWPathMonitor`) | `:711-715` | `:387-388`, `:536-537`, `:804-805` | coordinator (remade per attach) |
| `savePolicy` (`SceneSavePolicy`) | `:139` | never | controller |
| `localEcho`, `frames` (`FrameToDraw`), `shownSerial`, `sessionLocalEcho`, `inputSizes` | `:120-128`, `:156-157` | with the controller | controller |
| `surface`, key bar, font zoom, swipe paging, bell, clipboard writer, banners | `:78-94`, `:216-263` | with the controller | controller |
| `serverEnded`, `startFailed` | `:114-117` | reset at `attach` `:682` | coordinator |
| Observer of `LocalEcho.hostSaved` | `:168` | never removed explicitly (NotificationCenter selector observers are dropped at dealloc) | controller |

The controller is counted in `liveCount` (`:66-73`, `:159-161`, `:194-196`) and becomes the
process-wide `current` at `viewDidLoad` (`:62`, `:202`), never cleared except by being freed (weak).

### 2.3 Attach (`:679-721`)

In order: `self.coordinator = coordinator`; `frames.newSession()`; `serverEnded = false`;
contact/active times reset; `eventTask` started; **if** `savePolicy.saveAtAttach(sceneInBackground:)`
(scene state read from `view.window?.windowScene?.activationState`) a `.background` save is queued
before `start()` (review M6-2, `:697-703`); for `.resumed` a `.prediction` is queued (`:704-708`);
`readSessionLocalEcho` (UI tests); `begin` → `coordinator.start()` in a Task (`:725-739`; a throw
sets `startFailed` and shows a banner; success → `sessionStarted`: forget `oldSession`
(`:742-746`), arm `-debugCrashAfter` (`:747-749`)); new `PathWatcher`; new 1 s `healthTimer`;
`viewSizeChanged()`.

Inputs to attach: `.resumed` attaches the cold start's coordinator at once (`:493-495`); the others
go through `openSession` (`:635-676`): `SessionID.random()`, Keychain key first
(`SessionKeychain.shared.store`, `:642`), link (`SessionFiles.link(id, to: host?.id)`, `:648`),
`SessionMeta` from host and bootstrap result (`:649-660`), `ResumeCoordinator.create(... storesKey:
false, initialSize: viewSize, options: SessionLauncher.options(...))` (`:663-666`); a failed create
forgets the id (`:668`).

### 2.4 Leaving the screen today ("left the screen, shutting down")

Trigger: `viewDidDisappear` with `isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed`
(`:337-342`), i.e. the back button, or the controller being removed by `setViewControllers`
(`SceneDelegate.swift:138`). Then `endSession()` (`:376-416`):

1. `ended = true`; cancel `connectTask`; invalidate display link, resize timer, health timer; stop
   the path watcher; `commandContinuation.finish()` (queued commands not yet taken are dropped; a
   queued `.background` task would then never be ended by the consumer, see 2.6).
2. If a fallback was still bootstrapping (`oldSession != nil, coordinator == nil`): Task:
   `SessionLauncher.stopOldServer(meta: oldMeta, host:)` then `SessionFiles.forget(old)`
   (`:390-403`).
3. No coordinator: done (`:404`). Server-ended already (`serverEnded`): Task `finish(coordinator,
   .forget)` = `close()` + `SessionFiles.forget` (`:405-411`, `:447-455`).
4. Otherwise log "session: left the screen, shutting down" (`:413`) and Task `end(coordinator,
   host:)` (`:425-443`): `coordinator.shutdown()` (record marked ended first,
   `ResumeCoordinator.swift:647-665`). If accepted: sleep 11 s, `close()`, log if the record still
   exists (kept "ended" for `finishEnded` at the next launch). If refused (record not writable):
   `close()`, `stopOldServer`, `SessionFiles.forget`.
5. In parallel the still-running `eventTask` sees `.shutdownFinished(acknowledged:)` →
   `SessionEnding.after` (`SessionEnding.swift:26-36`): `true` → `finish(.forget)` (close, forget
   record + key + link); `false` → `.keepEnded` (close only) (`:689-693`). Then `handle` ignores it
   (`.shutdownFinished` → `break`, `:790`).

"Forgetting the record" = `SessionFiles.forget` (section 5.3). The tasks in steps 2-5 capture the
coordinator, not the controller, so the controller is freed at once (`:39-43`, `:1046-1058`).

`deinit` (`:183-197`): if the controller dies without `endSession` (a root debug screen replaced, a
test), `close()` only: "clean after a save, otherwise not resumable" (`:189-193`). A close without a
save before it leaves a started session's record dirty: a later tap/launch is a fallback.

### 2.5 Reactions to the session's events (`handle`, `:752-795`; ignored unless from the current coordinator, `:753`)

| Event | What the screen does |
|---|---|
| `.screen` | `frames.take(screen:)`, swipe-paging mouse mode, bell (`BellWatch` keyed by `ObjectIdentifier(coordinator)`, `:758-759`, `BellHaptic.swift:19-31`), `lastContact` if live |
| `.contact` | `lastContact` |
| `.serverEnded` (Ctrl-D / `exit`) | banner "Session ended", `sessionIsOver()` (`:800-807`: `serverEnded`, stop health timer and path watcher, hide contact). The screen stays; nothing navigates. The record is already "ended" (`ResumeCoordinator.swift:719-721`) |
| `.serverEndAcknowledged` | `SessionEnding` → `finish(.forget)` in `eventTask` (`:689-693`), then `sessionIsOver()` (`:788-789`) |
| `.shutdownFinished(true/false)` | `finish(.forget / .keepEnded)` in `eventTask`; `handle` does nothing (`:790`). No timeout of its own in `handle`; the 11 s timeout is in `end` (`:427-428`) |
| `.noServerReply` | red banner with the error (`:767-769`) |
| `.baseStateLost`, `.halted` | `runtimeFallback("the session cannot continue")` (`:770-772`) |
| `.gateFailed` | `startFailed = true`, banner "tried again when the app returns" (`:777-785`) |
| `.clipboard` | `clipboardWriter.apply` |
| `.display` | `frames.take(display:)` |
| `.networkProblem`, `.protocolProblem` | log only |

`runtimeFallback` (`:529-549`): coordinator nil-ed, `eventTask` cancelled, health and path stopped,
`oldSession/oldMeta` set, banner `ColdStartFallback.userMessage` + reason, then Task:
`old.abandon()` (record "dirty", close; `ResumeCoordinator.swift:688-696`) and
`startReplacement(for: identity, size:, debug: DebugLaunch.fallbackRequest)` (`:547`), which
bootstraps the host with the identity-checked kill of the old server after the new one started
(`:585-598`); `sessionStarted` forgets the old record (`:742-746`).

### 2.6 Banners, health check, probe

- Banners (`:216-258`): `statusLabel` (red: fallback, errors, "Session ended"), `progressLabel`
  ("Connecting…", "Starting mosh-server…"), `contactLabel` ("Last contact N s ago"). They take rows
  from the terminal, so showing one is a resize (`:230-234`). One set per controller.
- Health (`:814-827`, `HealthPolicy.swift:27-30`): every second; watching only if `coordinator !=
  nil && isAppActive && !ended` and not `serverEnded`; silence counted from
  `max(lastContact, activeSince)` so background time does not count; banner after 6.5 s, probe at
  15 s. `isAppActive` changes only through `sceneWillResignActive`/`sceneDidBecomeActive` of
  **this** controller (`:350`, `:358`), which the scene calls only on `current`.
- Probe (`:829-864`): needs a saved host and a server identity from `meta` (else
  `nextProbeAt = .distantFuture`); silent key login (`ServerProbe.probe`); `.startNewSession` →
  `runtimeFallback`; `.keepWaiting` → again in 15 s; `.informAndKeepSession` → banner, again in
  60 s. Result ignored if the coordinator changed (`:850`).
- Path watcher (`PathWatcher.swift:103-140`, filter `:49-97`): one `NWPathMonitor` per attach; a
  debounced change yields `.replaceSocket` (`:711-715`); the coordinator ignores it while in the
  background (`ResumeCoordinator.swift:678-681`). It keeps running between resign and return
  (not stopped at `sceneWillResignActive`).
- Local echo (`:996-1024`, `LocalEcho.swift:85-91`): mode from the saved host at init (`:156`); a
  host saved while open posts `LocalEcho.hostSaved` (`HostStore.swift:182`) and every controller
  with that host id follows (`:1001-1009`). For a cold start the option is read from the host at
  `coldStartOptions` (`SessionLauncher.swift:126-130`), and `.resumed` re-sends the screen's setting
  (`:704-708`). Not in the record (`ResumeCoordinator.swift:169-172`).

## 3. The scene (`SceneDelegate.swift`, `SceneSavePolicy.swift`)

### 3.1 Cold start at launch (`scene(_:willConnectTo:)` `:13-40`, `makeRoot` `:59-75`)

Order:
1. UI-test resets: `AppFiles.resetForUITestsIfAsked` (hosts, known hosts), `SessionFiles.resetForUITestsIfAsked`
   (every record, links, all session keys; `SessionFiles.swift:132-142`), counters chmod
   (`:150-161`) (`SceneDelegate.swift:26-28`).
2. `-debugPlaceholder` → placeholder only (`:60-62`).
3. `SessionFiles.removeOrphans()` (`:63`; section 5.2).
4. `-uiTestingSkipColdStart` → host list, no cold start (`:64-66`).
5. `finishEndedSessions()` (`:147-156`): `SessionLauncher.endedRecords()` (every record whose
   counters say ended, read without the lock, `SessionLauncher.swift:202-209`); one background Task
   finishes them one after another (`finishEnded` → `stopOldServer`, forget if `mayForget`); their
   ids are skipped.
6. `SessionLauncher.coldStart(skipping:)` (`SessionLauncher.swift:45-60`): every other record id,
   sorted by `meta.createdAt`, **newest created first** (unreadable meta sorts first: `.max`,
   `:62-64`). For each: `coldStart(root:id:keys:options:)`. A "not a record" fallback (deleted, no
   meta) is forgotten and the next id tried (`:52-55`); **the first other decision is returned and
   the loop stops** (`:57`). So: one record decides; the others are not opened, not saved, not
   deleted, not looked at.
7. `terminal(for:)` (`:78-112`): sets the single `SessionList.waitingReason` (`:81-85`);
   `.retryLater` → `coldStartPending = true`, host list; `.resumed` → terminal `.resumed` with
   `SessionFiles.host(of:)`; `.fallback` not wanting a new session → Task `finishEnded`, host list;
   fallback with neither host nor `-debugFallback*` → forget + alert; otherwise terminal `.fallback`
   with `DebugLaunch.fallbackRequest`.
8. `navigation(showing:)` (`:116-123`): with a host, the terminal is pushed over a new
   `SessionListViewController`; **without a host (debug), the terminal is the root, with no list
   under it** (`:122`). `.nothing` + `-debugMosh*` → debug terminal as root (`:71-73`).

### 3.2 Retry (`:46-52`, `:125-141`)

`sceneDidBecomeActive` calls `current?.sceneDidBecomeActive()` first, then, if `coldStartPending`,
`retryColdStart`: if `TerminalViewController.current != nil` ("a session open") it stays pending
(`:128-133`); else it runs `finishEndedSessions` + `coldStart` again and pushes (host) or replaces
the root (no host) (`:134-140`).

### 3.3 Background and return

`sceneWillResignActive` → `TerminalViewController.current?.sceneWillResignActive()` (`:42-44`);
`sceneDidBecomeActive` → `current?.sceneDidBecomeActive()` (`:46-47`). There is no
`sceneDidEnterBackground`/`sceneWillEnterForeground` handler: every resign (also Control Center,
the app switcher, a system alert) saves. Exactly one session is told: `current`, the controller
whose `viewDidLoad` ran last and that still exists (weak).

`SceneSavePolicy` (`SceneSavePolicy.swift:10-41`), one per controller (`TerminalViewController.swift:139`):
`resigned` set at resign, cleared at become-active; `saveAtAttach` = `resigned || sceneInBackground`;
`announcesSize` = `!(resigned || sceneInBackground)` (commit `6145d34`, 2026-11-20: iOS lays the view
out ~0.8 s after the save; a resize reaching a backgrounded session marks the record dirty and saves
again, and a kill in that window fell back). The held size is sent at `sceneDidBecomeActive`
(`TerminalViewController.swift:367-368`, `:985-994`). A controller that was not `current` at the
resign never has `resigned` set; it falls back on the scene's own `activationState == .background`
(`:697`, `:987`), which is false while merely inactive.

### 3.4 Stored properties and singletons that hold "the" session

| Holder | What | File:line |
|---|---|---|
| `TerminalViewController.current` (static weak) | the screen that gets the scene lifecycle and that the list reads as "live" | `TerminalViewController.swift:61-62`, `:202` |
| `TerminalViewController.liveCount` (static) | number of controllers (UI tests) | `:66-73` |
| `SceneDelegate.coldStartPending` | one pending cold start | `SceneDelegate.swift:11` |
| `SessionList.waitingReason` (static) | one "a session is waiting" line | `SessionList.swift:88` |
| `SessionKeychain.shared` | Keychain service, per-id items (not a single session) | `SessionKeychain.swift:23` |
| `DebugLaunch.request` / `.fallbackRequest` / `.crashAfter` | one debug server, one fallback server (port + key), one crash timer, per launch | `DebugLaunch.swift:42-55` |
| `AppFiles.knownHosts` | global, not per session | `HostStore.swift:201` |

## 4. The launcher (`SessionLauncher.swift`)

| Call | Needs from the record | Needs from the host | Writes |
|---|---|---|---|
| `coldStart(root:keys:skipping:)` `:45-60` | `meta.createdAt` of each, for the order | — | forgets non-records (`:54`) |
| `coldStart(root:id:keys:options:)` `:66-105` | Keychain key (`.locked`/`.io` → `.retryLater`; missing or malformed → fallback "key not in the Keychain", ended-ness from counters, nothing written, `:70-91`); then `ResumeCoordinator.coldStart(key: .provided, currentSize: nil)` which takes the lock, needs clean-for-snapshot, else marks dirty and closes (`ResumeCoordinator.swift:276-365`) | via `coldStartOptions`: local echo of the linked host | the core may mark dirty or delete a non-record |
| `options(address:port:clipboard:localEcho:)` `:112-119` | — | clipboard (new sessions only), local echo | — |
| `coldStartOptions(root:id:)` `:126-130` | `meta.address`, `meta.port` (read before the lock) | `SessionFiles.host(of:)` → local echo | — |
| `serverIdentity(meta)` `:133-137` | `serverPID != 0`, `serverStartTime != 0` (on Trick's host the pid is never learnt, CLAUDE.md "Phone (2026-11-21)": then nil) | — | — |
| `stopOldServer(meta:host:)` `:158-190` | identity, `meta.address` (proof only at that address) | `target`, `keyName` (silent key login, `KeychainKeyStore`, `AppFiles.knownHosts`) | UI-test mark `old-server-*` |
| `finishEnded(fallback:host:)` `:145-153` | meta | host | `SessionFiles.forget` if `mayForget` |
| `endedRecords(root:)` `:202-209` | counters state, meta (no lock) | — | — |

Fallback (new session) itself lives in the terminal screen (`startReplacement`, `bootstrap` with
`replacing:`), not in the launcher: it needs a saved host (or `-debugFallback*`), and kills the old
server only if identity is known (`TerminalViewController.swift:508-524`, `:585-598`).

The launcher is a plain `enum` (no actor); the app is built with `SWIFT_VERSION: "5.0"` and no
default isolation (`App/project.yml:54`). Its `async` functions (`finishEnded`, `stopOldServer`)
are non-isolated, so `SessionFiles.forget` inside `finishEnded` (`:149`) runs off the main thread
(see 5.1).

## 5. Files and keys

### 5.1 Per session and global

| Thing | Per session? | Where |
|---|---|---|
| Record directory (`meta`, `counters`, `snapshot`, `lock`) | per session | `SessionFiles.swift:15-17`; `SessionStore.swift:85-94` |
| Session key | per session: Keychain generic password, account = id, service `us.v9n.ios-mosh.session-keys` | `SessionKeychain.swift:22`, `:58-66` |
| Session → host link | **one file for all sessions**, `session-hosts.json` `{version: 1, links: {id: hostID}}`, read-modify-write with an atomic replace and no lock | `SessionFiles.swift:19-50`, `:93-94`, `:110-118` |
| Hosts, known hosts, SSH keys, settings | global | `HostStore.swift:194-201`, `KeychainKeyStore.swift:21`, `AppSettings.swift` |

The link file is written from `openSession` (main thread, `TerminalViewController.swift:648`) and
from `forget`, which runs on main in the screen and the list but off main in
`SessionLauncher.finishEnded` (4, last paragraph). Two writers at once can lose an update (a new
session's link, so it has no host for a fallback and is listed "without a saved host"; or a removed
link coming back, which `removeOrphans` then removes). This exists today (launch finishing ended
records while a session is started); more sessions make it more likely.

### 5.2 `removeOrphans` (`SessionFiles.swift:102-119`)

Runs once per scene connect, before the cold start (`SceneDelegate.swift:63`), never later. For
every id that has a Keychain key or a link: if `SessionStore.exists` says the directory is not
there, delete the key and the link. A listing error of the Keychain stops it (`:105-108`); an id
whose existence cannot be found out is left (`:113`). It does not look at records without a key
(those are the cold start's fallback, `SessionLauncher.swift:81-91`).

### 5.3 What "forget" removes (`SessionFiles.swift:80-97`)

Under the record's lock: `ResumeCoordinator.deleteRecord` (`ResumeCoordinator.swift:371-377`;
throws `locked` while any coordinator holds it, so forgetting an open or parked-but-not-closed
session fails and keeps key and link). Then the Keychain item, then the link. Returns false if the
record could not be deleted.

Callers: `endSession` (fallback in flight, `TerminalViewController.swift:401`), `end` (refused
shutdown, `:441`), `finish(.forget)` (`:451`), `startReplacement` with no host (`:520`),
`sessionStarted` (`:745`), `openSession` failure (`:668`); `SceneDelegate` no-host fallback
(`:104`); `SessionLauncher` non-records (`:54`), `finishEnded` (`:149`); the list's End Session
(`SessionListViewController.swift:248`), Forget (`:283`), non-record and no-host fallbacks (`:197`,
`:208`).

## 6. The host list's use of "the" session (only what bears on the lifecycle)

- Live = `current?.liveSessionID` (`SessionListViewController.swift:110`), one id
  (`SessionList.load(liveID:)`, `SessionList.swift:95-110`).
- Taps are refused while `current?.liveSessionID != nil` ("one live session at a time",
  `:166-169`). Today this is only a guard: the list is not visible with a session open.
- A tap on a not-live record runs the single-record cold start (`:182-213`): `.retryLater`
  (also `.inUse`) is an alert; `.resumed` pushes a `.resumed` terminal; a fallback pushes
  `.fallback` with `debug: nil` (`:205`).
- `SessionList.group` keeps **only the newest record per host** (`SessionList.swift:114-126`); the
  row's swipe acts on that one record.
- "End Session" on the list = identity-checked kill over SSH, not mosh's shutdown (`:233-259`);
  needs pid and start time in `meta` (else `.nothingToAsk` → forget without stopping anything,
  `SessionLauncher.swift:159-161`, `OldServerOutcome.mayForget` `:238-244`).

## 7. The sequences today, call by call

### 7.1 Going to the background with a session open

1. UIKit: `SceneDelegate.sceneWillResignActive` (`SceneDelegate.swift:42-44`) →
   `TerminalViewController.current?.sceneWillResignActive()` (`TerminalViewController.swift:349`).
2. `isAppActive = false` (`:350`, stops the health check: `:817`); `contactLabel.isHidden = true` (`:351`).
3. `savePolicy.sceneResigned(hasSession: coordinator != nil && !ended)` (`:352`;
   `SceneSavePolicy.swift:15-18`: `resigned = true`). No session yet → nothing now; the save is
   queued at attach (`:697-703`).
4. `commandContinuation.yield(.background(BackgroundTask(name: "save session")))` (`:353`); the
   `BackgroundTask` init calls `UIApplication.beginBackgroundTask` right here, on main
   (`:1065-1069`).
5. The command consumer (`:285-295`) takes it after any earlier input/resize; no coordinator →
   `task.end()` (`:288`).
6. `perform(.background)` (`:306-311`): `await coordinator.enterBackground()` →
   `inOrder` → `runEnterBackground` (`ResumeCoordinator.swift:488-508`): closed → `.closed`; not
   started → `inBackground = true`, `.clean` only for a still-clean restored record, else
   not resumable; already saved clean → `.clean`; else `session.quiesce()`, `inBackground = true`,
   `save()` (`:538-555`: `exportState`, `record.save` = snapshot replace + clean mark with the
   export's token).
7. Log "session: background, saved: …"; UI-test mark `background-clean` or
   `background-not-resumable` (`:308-310`); `task.end()` (`:311`).
8. While resigned: the size is held (`:987-990`); input or a resize that still arrives makes the
   record dirty, is applied, and saves again (`ResumeCoordinator.swift:616-633`), with UI-test marks
   `background-input`/`background-resize` (`:325-329`); `replaceSocket` is ignored
   (`ResumeCoordinator.swift:679`). The display link, path watcher and timers are **not** stopped;
   iOS suspends the process.

### 7.2 Coming back with the process alive

1. UIKit: `SceneDelegate.sceneDidBecomeActive` (`:46`) → `current?.sceneDidBecomeActive()`
   (`TerminalViewController.swift:357`).
2. `isAppActive = true`; `savePolicy.sceneBecameActive()` (`resigned = false`); `activeSince = Date()`
   (`:358-360`). No coordinator or `ended` → stop here (`:361`).
3. `yield(.foreground)` (`:362`) → `perform` → `coordinator.enterForeground()` (`:312-314`) →
   `runEnterForeground` (`ResumeCoordinator.swift:516-533`): `inBackground = false`,
   `savedClean = false`; not started → the deferred `runStart` if one was asked for (failure →
   `.gateFailed`); else `markDirty()` (best effort) and `session.resume()` (new socket, continue
   from memory).
4. `startFailed` → `begin(coordinator)` again (`:363-366`).
5. `announceSize()` (`:368`): the held size, as an ordinary `.resize` command.
6. Back in `SceneDelegate`: `coldStartPending` → `retryColdStart()` (`:48-51`).

### 7.3 Coming back after the process was killed

`scene(_:willConnectTo:)` → 3.1: `removeOrphans`, finish ended records, the newest other record's
cold start → `.resumed` coordinator (record still clean) → `TerminalViewController(.resumed)` →
`viewDidAppear` → `startSessionIfNeeded` → `attach` → `start()` (`beginSending`: dirty, new
reservations; first screen is the stored one, `ResumeCoordinator.swift:451-466`). A kill on screen
leaves a dirty record → fallback with the banner.

### 7.4 What a park would have to repeat, as facts

- The save is 7.1 steps 4-7: a background task, the command queue (so it follows queued input),
  `enterBackground()`, the mark, the task's end. The screen-side state of step 2/3/8 (health off,
  size held) is keyed to the *scene* (`isAppActive`, `savePolicy.resigned`), not to "this session is
  off screen".
- After `enterBackground()` the coordinator still holds the lock. Two ways back exist in the code:
  `enterForeground()` on the same coordinator in memory (7.2; needs the object, keeps its socket
  closed until then), or `close()` (releases the record "as it is: clean after `enterBackground()`",
  `ResumeCoordinator.swift:698-712`) followed later by a cold start of that id (7.3's path, as the
  list's tap already does, `SessionListViewController.swift:182-189`). A cold start of a record
  whose coordinator is not yet closed answers `.retryLater(.inUse)` (1).
- `close()` without a save first (the `deinit` path, `TerminalViewController.swift:189-193`)
  leaves a started session dirty: a fallback at the next open.
- A session left before it was started (bootstrap or start in flight) has no clean record:
  `enterBackground()` returns `.notResumable(.failed("the session was not started"))` for a new one
  (`ResumeCoordinator.swift:490-497`); today such a leave cancels the bootstrap and lets the server
  exit after 60 s (`TerminalViewController.swift:605-608`).

## 8. Debug and test hooks that assume one session

- `-debugMosh{Port,Key,Host}` (`DebugLaunch.swift:42`): used only when the cold start says
  `.nothing` (`SceneDelegate.swift:71`), i.e. no record at all other than ended ones; the session is
  the root with no list (`:72`, `:122`).
- `-debugFallback{Port,Key,Host}` (`DebugLaunch.swift:44`): one server and **one key** per launch,
  used by every fallback of the launch: the cold start (`SceneDelegate.swift:101`) and every
  run-time fallback (`TerminalViewController.swift:547`). A second fallback in the same launch makes
  a second record with the same key and counters from 0 against the same server (sequence numbers
  repeat under one key: the N1 shape). Possible today (a run-time fallback after a cold-start
  fallback); several debug sessions per launch make it easy.
- `-debugCrashAfter N` (`DebugLaunch.swift:47-55`): armed at every `sessionStarted`
  (`TerminalViewController.swift:747-749`), so at the first session that starts.
- `-uiTestingSkipColdStart`, `-uiTestingResetSessions`, `-uiTestingKeepSessions`,
  `-uiTestingCountersMode` (`UITestSupport.swift:18-24`, `SessionFiles.swift:126-161`): all records
  at once; fine for several.
- UI-test marks (`UITestSupport.swift:134-163`): `background-clean`, `background-not-resumable`,
  `background-input`, `background-resize`, `old-server-*` carry **no session id**
  (`TerminalViewController.swift:301-310`, `SessionLauncher.swift:196`); a park that reuses the save
  would send `background-clean` too.
- Accessibility elements: `screenText`, `terminalAppearance`, `localEcho`, `bellRings` per terminal
  view (`TerminalViewController.swift:272-276`, `BellHaptic.swift:42-50`); `liveTerminals` = count of
  controllers (`UITestSupport.swift:110-128`, used by `SSHBootstrapUITests`); the list row's
  accessibility value = the state of the newest record of the host (`SessionListViewController.swift:374`).
- Phone probes do not touch sessions: `DeviceProbe.root` = `smoke-probe/` with its own Keychain
  service (`DeviceProbe.swift:35-40`), `WriteKillProbe.directory` = `smoke-writekill/`
  (`StageTwoProbe.swift:158-160`); "Crash Now" kills the process (`DebugLaunch.swift:95-101`,
  `SettingsViewController.swift:215-216`).

## 9. Every assumption of one session

"Two live" = two coordinators started at once; "parked" = BRIEF item 6 (only the session on screen
open). Verdict "harmless" means: harmless as long as at most one coordinator is open and the code
path is used as today.

| # | Place | Assumption | Two live | One live, several parked / two launches racing | Under parking |
|---|---|---|---|---|---|
| A1 | `TerminalViewController.current` `:61-62`, `:202`; `SceneDelegate.swift:43`, `:47` | the last loaded screen is the only session; only it is saved at resign | the other is never saved; a kill loses it (dirty → fallback) | a screen popped but not yet freed while another is pushed: `current` is the new one; the old one's park (if still running) is not tied to the scene | harmless only if a park needs no scene call and `current` is the on-screen session; **must change** if a parked coordinator is kept in memory |
| A2 | back button = `endSession` = shutdown (`:337-342`, `:376-416`) | leaving the screen ends the session | — | — | **must change** (BRIEF item 4) |
| A3 | `endSession` does not stop `eventTask`; `finish` runs in it (`:687-696`) | events of a left session only finish it | — | a parked-and-closed coordinator's stream ends at `close()`: harmless | harmless if parked = closed |
| A4 | `isAppActive`, `savePolicy` per controller, set only via `current` (`:137-139`, `:350`, `:358`) | the controller that has a session is `current` | a non-current controller keeps probing and announcing sizes in the background | — | harmless if only the on-screen controller has a coordinator and timers |
| A5 | `healthTimer`, `pathWatcher`, display link stopped only in `endSession`/fallback/`sessionIsOver` | a controller that is off screen is ending | — | a controller kept alive off screen keeps a 1 s timer, an `NWPathMonitor` and a display link | **must change** if a parked controller is kept; harmless if it is freed |
| A6 | `deinit` closes without saving (`:189-193`) | a controller dies only after `endSession` or in tests | — | freeing a parked controller before its save → dirty → fallback | **must change** (order: save, then close) |
| A7 | `Start` immutable, `startRequested`, `ended` one-way (`:75`, `:110-111`) | one controller per session life | — | re-entering a parked session needs a new controller (`.resumed`) or new code | harmless with a new controller per resume |
| A8 | `SessionLauncher.coldStart` newest **created** first, first decision wins (`SessionLauncher.swift:47-58`) | one record | — | launch opens the newest-created parked session, not the last looked at (BRIEF item 8); a `.retryLater` on it blocks all; a dirty older record stays dead in the list | **must change** (which record) |
| A9 | `SceneDelegate.coldStartPending`, `SessionList.waitingReason` (`SceneDelegate.swift:11`, `SessionList.swift:88`) | one waiting record | — | several locked records show one line; retry only when `current == nil` (`:128`) | **must change** if `current` stays non-nil on the list or if each record needs its own state |
| A10 | `navigation(showing:)`, `retryColdStart` root replace (`SceneDelegate.swift:116-123`, `:138`) | a debug session has no list under it | — | a parked debug session resumed at launch is the root: no "‹ Hosts" | **must change** (BRIEF items 1, 4) |
| A11 | list guard `current?.liveSessionID == nil` (`SessionListViewController.swift:169`) | the list is never visible with a session open | — | taps refused while a session is open; harmless if the open session is parked before the list is usable | harmless if parking completes on leave; otherwise **must change** |
| A12 | list `liveID` single (`:110`, `SessionList.swift:95-110`) | one live record | two live rows impossible | parked records read from disk | harmless |
| A13 | `SessionList.group` newest per host (`SessionList.swift:114-126`) | one record per host matters | — | older sessions of a host invisible, not tappable, not swipeable | **must change** (BRIEF items 1-3) |
| A14 | tap on a parked record = cold start of that id (`:182-213`) | the record is closed | `.inUse` | a tap before the previous park's `close()` ran → `.retryLater(.inUse)` alert | harmless only if the park closes before the list takes taps, or the tap waits; else **must change** |
| A15 | `session-hosts.json` read-modify-write, no lock (`SessionFiles.swift:46-50`, `:93-94`) | writes do not overlap | overlapping `link`/`forget` lose an update | `finishEnded` forget off main (`SessionLauncher.swift:149`) vs `openSession` link on main | **must change** (or serialize); exists today |
| A16 | `removeOrphans` at launch only (`SceneDelegate.swift:63`) | — | — | per-id; parked records keep key and link | harmless |
| A17 | `SessionFiles.forget` needs the lock (`ResumeCoordinator.swift:371-377`) | — | — | forgetting a parked session whose coordinator is open fails (`false`) | harmless if parked = closed |
| A18 | `SessionKeychain` per id (`SessionKeychain.swift:58-118`) | — | — | — | harmless |
| A19 | `oldSession`/`oldMeta` one slot (`TerminalViewController.swift:100-103`) | one fallback in flight per screen | — | per controller | harmless |
| A20 | leaving during a fallback forgets the old record (`:390-403`) | leaving = not wanted | — | under parking "leave" is not "not wanted": the old dirty record and the replacement's half-bootstrap | **must change** (what a back during a fallback/bootstrap means) |
| A21 | `DebugLaunch.fallbackRequest` one key per launch (`DebugLaunch.swift:44`; used `SceneDelegate.swift:101`, `TerminalViewController.swift:547`) | at most one fallback per launch | two fallbacks reuse one key from counter 0 (N1 shape) | same with parked debug sessions | **must change** (debug-only, but it is an N1 path) |
| A22 | `-debugMosh*` used only with no record (`SceneDelegate.swift:71`) | one debug session per launch | — | a launch with parked records never opens the debug session | must change only if tests need a debug session beside parked ones |
| A23 | `-debugCrashAfter` armed at every `sessionStarted` (`:747-749`) | one session starts per launch | — | the first resume or start after launch arms it | harmless (tests) |
| A24 | UI-test marks without session id (`:301-310`, `UITestSupport.swift:134-163`) | one session saves | — | a park's save and the scene's save look alike | **must change** for tests that tell them apart |
| A25 | `liveTerminals` counts controllers (`UITestSupport.swift:110-128`) | 0 after leaving | — | stays 0 only if parked controllers are freed | harmless if freed; **must change** if kept |
| A26 | `BellWatch` keyed by coordinator (`TerminalViewController.swift:758-759`, `BellHaptic.swift:19-31`) | — | — | a resumed session's first screen only sets the count | harmless (no bell while parked, accepted in BRIEF item 6) |
| A27 | `LocalEcho.hostSaved` to every controller of the host (`:1001-1009`) | — | each follows | parked ones get it at resume via `coldStartOptions` | harmless |
| A28 | `SceneSavePolicy.saveAtAttach`/`announcesSize` read the scene state (`SceneSavePolicy.swift:28-40`) | — | — | a resume attached while the scene is inactive saves at once | harmless |
| A29 | `SessionLauncher.endedRecords` + `finishEndedSessions` all ended records at launch | — | — | per record, sequential | harmless |
| A30 | the core: one coordinator per record (R12), `ResumeCoordinator` is per session; no process-wide session state in `Sources/MoshResume` (`ResumeCoordinator.swift:149-215`) | — | two records, two coordinators are allowed by the core | — | harmless; no core change needed for the map's facts |
