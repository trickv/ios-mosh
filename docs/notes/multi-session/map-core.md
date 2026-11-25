# Map: what the core allows for several sessions

Covered: everything the task asked for (the coordinator's surface and order, park, unpark, two
at once, ending a parked session through mosh, the preview, the invariants). Not covered: the
app's screens (other maps). Read only, from the code at `b5aec27` (main), 2026-11-21. Nothing
was built or run. Paths are under `Sources/` unless they start with `docs/`, `Tests/`, `App/`
or `.refs/`. "C" and "R" numbers are the invariants of `docs/RESUME.md`. Nothing here changes
`BRIEF.md`.

**Verdict, short:** park, unpark, two coordinators at once, and "End Session" through mosh's
own shutdown can all be done with today's `Sources/`, with no change. For the preview the app
can read the snapshot file itself with public calls, and the core needs no change for that
either. What is missing is listed at the end: one test, and some rules on the order the app
must call things in.

## 1. ResumeCoordinator: surface and the order of calls today

`MoshResume/ResumeCoordinator.swift`, an `actor` (149).

| Call | What it does | Record (counters) | Lock | Sockets |
|---|---|---|---|---|
| `static create(root:meta:key:storesKey:initialSize:options:)` (228-257) | Makes the record (`SessionRecord.create`, 236) and a new `MoshSession` (240-251). Nothing is sent | new: "dirty", nothing reserved (`SessionStore.create`, `SessionStore.swift:182-210`) | taken (`SessionStore.swift:193`), held by the record | none |
| `static coldStart(root:id:key:currentSize:options:)` (276-365) | **Synchronous**, not `async`. 1. `SessionRecord.open` (286): lock, protection check, meta, counters (`SessionRecord.swift:79-97`). 2. `loadSnapshot` (326), only if clean for that snapshot (`SessionRecord.swift:128-142`). Key from `KeySource` (327-331, no default, C12). Builds `MoshSession(restoring:)` (332-341). Nothing is written or sent (C1, C2) | unchanged on `.resumed`; on a fallback with the lock: "dirty" (357-359), except when ended or the key is missing; a directory that is not a record is deleted under its lock (293-318) | held by the coordinator on `.resumed`; released on fallback/retry (346, 361) | none |
| outcomes (77-82) | `.resumed(coordinator)`; `.fallback(ColdStartFallback)` with `reason`, `meta`, `recordDeleted`, `wantsNewSession` (= reason is not `.ended`, 58); `.retryLater(.inUse / .storage)` (63-75). Mapping in `disposition(of:)` (386-410) | | | |
| `start()` (439-472) | Restored: `gate.beginSending()` (453): new blocks for all three counters and "dirty" in both slots, in one change (`FileBackedGate.swift:237-249`). Then the event reader (460-465), `session.start()` (466), the size kept from before (467-470). Throws only from the counters change. If asked while in the background, it is deferred to `enterForeground` (446-450) | "dirty" (or still "ended") | held | first socket and first datagram (`MoshConnection.swift:165-176`) |
| `enterBackground(afterSend:)` (484-508) | Not started: writes nothing; `.clean` for a restored record (490-497). Already saved and clean: writes nothing (498-500, C10). Otherwise quiesce (504), then `save()` (538-555): export, `SessionRecord.save` = snapshot replace and then the clean mark (`SessionRecord.swift:113-120`) | "clean" for the new snapshot, or `.notResumable(...)` (85-105) | held | closed by the quiesce (`MoshConnection.swift:189-194`); the timer is cancelled |
| `enterForeground()` (512-533) | `markDirty()` (531), `session.resume()` (532): a new socket and a datagram at once (`MoshConnection.swift:215-220`); runs a deferred `start()` (520-527) | "dirty" | held | new socket |
| `type(_:)` (596), `resize(_:)` (603-614) | Before `start()`: input refused, the size is kept (C11). In the foreground: passed on. In the background: "dirty" first, then the input, then saved again (616-633, C6) | in the background: dirty → clean again | held | in the background: none |
| `shutdown()` (643-665) | `markDirty()`, and if that fails, refused with `false` (654-659, C7); then `markEnded()` (662); then `session.shutdown()` (664). **Not guarded by `started`** (C11 names it as the exception) | "ended" before the request goes on | held | see section 5 |
| `replaceSocket()` (674-681) | ignored while in the background (679) | — | — | new socket |
| `abandon()` (688-696) | `giveUp()` ("dirty", 572-579), then close; the server is not told | "dirty" | released | closed |
| `close()` (700-712) | `session.close()`, cancels the reader, `record.close()` (gate closed, lock released, `SessionRecord.swift:145-148`), ends `events`. **Writes nothing:** the record stays as it is ("clean after enterBackground()", 698-699) | as it was | **released when `close()` returns** | closed |
| `static deleteRecord(root:id:)` (371-377) | Takes the lock and deletes the directory; `RecordError.locked` if a live coordinator holds it | gone | briefly | — |
| `events` (180) | `MoshSession` events, after the coordinator has acted on them (716-729): `.serverEnded`, `.shutdownFinished` → `markEnded`; `.baseStateLost`, `.halted` → `giveUp`. The list of events: `MoshSession/SessionTypes.swift:59-107` | | | |
| reads | `recordState` (734), `isInBackground` (735), `hasEnded` (736), `screen()` (738; says `isLive: true` even before start, `MoshSession.swift:387-390`), `contactAges()` (739) and others (740-745) | | | |

Every call except the reads, `setClipboardWriting` and `setPrediction` runs through `inOrder`
(415-423), one after another in the order they came (C8).

The app's order today (`docs/RESUME.md` "The app"; `App/IOSMosh/TerminalViewController.swift`):
`create` then `start`; `enterBackground` when the scene resigns (306-311), inside a
`BackgroundTask`; `enterForeground` when it becomes active (312-314, 357-369); leaving the screen
calls `shutdown`, waits up to 11 s, then `close` (425-443); the cold start at launch goes through
`SessionLauncher.coldStart` (`App/IOSMosh/SessionLauncher.swift:66-106`, the key read from the
Keychain by record id, 73).

## 2. PARK: `enterBackground()` with the app still in the foreground

**Complete and safe, if it is followed by `close()`.** Do not just drop the coordinator.

- What it does: quiesce, export, snapshot, clean mark (C5). Nothing in `MoshResume`,
  `MoshSession` or `MoshTransport` asks whether the app is really in the background: no
  UIKit, no `UIApplication` (grep of the three folders), no OS state. "Background" is only the
  flag `inBackground` (194), and its effects are: input goes the M9 way (620-632),
  `replaceSocket` is ignored (679), `start` is deferred (446-450). The scene callbacks appear
  only in a usage comment (136-139).
- Timers after the quiesce: the connection's timer is cancelled (`MoshConnection.swift:191-192`)
  and the core gives no wake-up while quiesced (`TransportCore.swift:440-445`). The prediction
  timer is stopped (`MoshSession.swift:262-265, 574-578`). The 15 s no-reply timer of a *new*
  session may still fire once, finds the session quiesced and does nothing
  (`MoshSession.swift:244-247`); a restored session has none (167).
- The record afterwards: `counters` says "clean" for the stored snapshot. Saving a second time
  without a change writes nothing (C10). If the save fails, the outcome is `.notResumable(...)`:
  the record is "dirty", or clean for a snapshot that is gone, and the next cold start falls back
  (R7). The direction is safe; the row says "Could not be resumed".
- The lock: until `close()`, the coordinator's `SessionRecord` holds the `flock`
  (`SessionStore.swift:143-161`, `LOCK_EX|LOCK_NB` at 153). `close()` releases it before it
  returns (`SessionRecord.swift:145-148`, `SessionStore.swift:71-78`).
- Releasing the object without `close()`: `SessionRecord.deinit` closes (157-159) and
  `SessionLock.deinit` closes the descriptor (`SessionStore.swift:80-82`). But when that happens
  depends on the tasks that still hold the actors (the `tail` task, 207; readers that wait on
  streams that are never finished, `ResumeCoordinator.swift:460-465`,
  `MoshSession.swift:217-222`, `MoshConnection.swift:168-173`). The code does not show when, or
  whether, that ends. Until then an unpark of the same record gets `.retryLater(.inUse)`. So:
  `await enterBackground()`, then `await close()`. This is exactly what
  `Tests/MoshResumeTests/ResumeCoordinatorTests.swift:601-632` does (three lives against a real
  `mosh-server` in one process: save, close, cold start, start) and 84-111 (with a dead network).
- Input queued between the save and the close goes the M9 way (C6): "dirty", applied, saved
  again, clean. Then `close()`.
- A coordinator kept in memory after `enterBackground()` (no close) is also safe. It holds the
  lock and its memory, with no sockets and no timers, and `enterForeground()` continues it
  (`markDirty`, a new socket). This is today's path for going to the background and coming back.

## 3. UNPARK: a cold start while the app keeps running

**The same as at launch.** `coldStart` is a static function with no state in the process
(276-365). The app adds the key read (`SessionLauncher.swift:66-106`) and the transport
options, which read `meta` before the lock (122-127).

- Before it: the coordinator that parked the record has returned from `close()`. Otherwise
  `RecordError.locked` → `.retryLater(.inUse)` (388-389). `flock` locks of two descriptors in
  the same process exclude each other; the code says so ("or another coordinator in this one",
  64), and `testARecordInUseIsRetriedLater` (`ResumeCoordinatorTests.swift:341-346`) checks it in
  one process. The Keychain key must be the key of **that** record id (section 7).
- What it costs: no network. `coldStart` does file reads on the calling thread: lock, `lstat`,
  meta, both counters slots, the snapshot (about 15 KB for eight 80x24 states, `docs/RESUME.md`
  446-449), decode, rebuild. `start()` then writes four storage steps (two `pwrite` plus
  `F_FULLFSYNC`). Phone measurements of the parts: first reservation 4.3 ms, a save median 12 ms,
  first datagram after a save median 6.9 ms (`docs/RESUME.md:293`). The cold start itself was
  never timed (grep of `docs/MAC.md` and `docs/CLOUD.md`).
- The first screen: the stored one. `start()` yields `.screen(isLive: false)` from the
  snapshot's newest state, then a `.display`, before anything has come back from the server
  (`MoshSession.swift:207-215`). Live screens follow when the server answers.
- The server is gone, or the network is down: nothing in the core says so. A restored session
  has no no-reply timeout (`MoshSession.swift:167`; `SessionTypes.swift:92`). With no network,
  each failed socket open gives a `.networkProblem`, and it is tried again every 1 s
  (`MoshConnection.swift:44-48, 366-370, 441-445`). With the server gone, there are only send and
  socket errors. The record is "dirty" from `start()` on. The app's 15 s health check and
  `ServerProbe` (`docs/RESUME.md:266`) are what tell. Parking it again makes it clean again
  (nothing was received, the save is valid), so a dead session stays "parked" until the next
  unpark.
- `start()` throws (storage): the coordinator can call `start()` again (the gate's state is
  unchanged, `FileBackedGate.swift:246-248`). If it is closed instead, one slot may already say
  "dirty" (`writeBothSlots` is two writes, 305-311), and the next cold start then falls back. The
  doc comment says "still resumable" (437-438); that holds only within the same coordinator. The
  direction is safe.

## 4. TWO AT ONCE (different records)

**Allowed.** Each record has its own directory, `flock`, gate, counters file descriptor,
`MoshSession`, `MoshConnection` and socket. Each transport has its own `DispatchQueue`
(`MoshTransport/NWDatagramTransport.swift:104`, `POSIXDatagramTransport.swift:87`). There is no
shared mutable state in `MoshResume`, `MoshSession` or `MoshTransport`: the only `static var`s
are computed (`RecordProtection.swift:80`, `POSIXDatagramTransport.swift:189,197`). The common
root is made with `withIntermediateDirectories: true`, which accepts a root that already exists
(`MoshResume/Storage.swift:221-229`). One coordinator can be on screen while another ends a
parked session, or while one is parking and the next unparking.

The same record twice is impossible: the second `open` gets `locked` (R12), and a lock serves one
gate (`claimForGate`, `SessionStore.swift:62-68`; `FileBackedGate.swift:91`). So a tap on a
session row that races its own "End Session" gives `.retryLater(.inUse)`, or
`RecordError.locked` for `deleteRecord`. It never gives two writers.

## 5. END A PARKED SESSION THROUGH MOSH

The calls: `coldStart` → `.resumed(c)` → `try await c.start()` → `await c.shutdown()` → wait for
`.shutdownFinished` on `c.events` → `await c.close()` → `deleteRecord` (and the app's key and
link) only if acknowledged.

- **`start()` must come first.** `shutdown()` is accepted before `start()` (C11's exception,
  647-665). But then `MoshConnection.shutdown` pumps, opens a socket and sends
  (`MoshConnection.swift:243-248, 441-449`) while no reader runs on the connection's inbox (that
  reader is made in `start`, 165-173) and none on the session's events (made in
  `MoshSession.start`, 216-222). The server's answer is never processed, and the outcome never
  reaches the coordinator. There is no test of that order.
- With `start()` first: the record goes clean → "dirty" (`beginSending`) → "ended" (`shutdown`;
  `markDirty` writes nothing because "not clean" is already durable, `FileBackedGate.swift:259`;
  then `markEnded`, 275-282). `shutdown()` returns `true` (a shutdown is running). It returns
  `false` only if the coordinator is closed or the session is already over, for example a
  `.serverEnded` that came first (`TransportCore.swift:338-346`).
- What is sent: mosh's shutdown state (number 2^64−1), as fast as possible, until it is
  acknowledged (`TransportCore.swift:587-593, 620-621, 684-686`; mosh
  `transportsender-impl.h:121-122`).
- **Acknowledged:** `.shutdownFinished(acknowledged: true)` (`TransportCore.swift:733-736` →
  `MoshSession.swift:450-452`). mosh-server leaves its loop once it has acknowledged
  (`.refs/mosh/src/frontend/mosh-server.cc:889-892`): the server is gone. Record: "ended". Then
  `close`, `deleteRecord`.
- **Timed out:** after 16 sends of the shutdown state, or 10 s after it started (the 10 s start
  at `unquiesce` if it was quiesced): `.shutdownFinished(acknowledged: false)`
  (`TransportCore.swift:740-747`; `TransportTypes.swift:13,16`; mosh `transportsender.h:56-57`,
  `transportsender-impl.h:384-391`). Record: "ended". The server may still run.
- **No network:** the core still builds a shutdown datagram on every tick, and each counts as a
  try even when there is no socket to send it on (`MoshConnection.swift:446-451`;
  `TransportCore.swift:684-686`). The time limit is checked before every tick
  (`TransportCore.swift:375-377`). So this also ends in `acknowledged: false` within about 10 s.
  The same holds when the gate cannot write (retry every second, the check runs first). Record:
  "ended".
- **Only one try through mosh.** An "ended" record is never resumed again (R16, R7:
  `loadSnapshot` throws, `SessionRecord.swift:133-134`; `coldStart` gives `.fallback(.ended)`
  and creates no session, C2). After a timeout the core can never send a second mosh shutdown for
  that record; only the SSH kill is left, and on `hg` there is no pid for it. The app can avoid
  spending its one try with today's core: after `start()`, wait for the first `.contact` or a
  live `.screen` before it calls `shutdown()`. Without contact, `enterBackground()` + `close()`
  parks it again as "clean" (nothing was ended, C7 has not run).
- A process death during all this: before `shutdown()` the record is "dirty", and the next
  launch falls back with a new session (C4). After it, the record is "ended", and the next launch
  runs the identity-checked kill without a new session (`docs/RESUME.md:124, 264`).
- Tested: the record states with a dead network (`ResumeCoordinatorTests.swift:257-291`,
  `ReviewFixTests.swift:301-343`, which includes a shutdown on a resumed, started coordinator).
  An acknowledged shutdown against a real server is tested only for a plain `MoshConnection`
  (`Tests/MoshTransportTests/ConnectionIntegrationTests.swift:240-241`). No test has a resumed
  coordinator whose shutdown a real server acknowledges.

## 6. PREVIEW of a parked record (no lock, no write)

There is no single core call. `SessionRecord.loadSnapshot` needs the lock
(`SessionRecord.swift:128-129`), and `SessionStore.readSnapshot` is internal
(`SessionStore.swift:249-252`). The public pieces are enough:

- `SessionStore(root:id:)` (`SessionStore.swift:105`), `.directory` (103): read
  `<directory>/snapshot` with Foundation (at most `SnapshotCodec.maxFileSize`,
  `SnapshotCodec.swift:60`). Then `SnapshotCodec.decode(_:expecting:)` (public, 143) gives a
  `StoredSnapshot` with `.snapshot.transport.remoteStates.last` (the newest,
  `MoshSession.swift:163-165`) and `.state.framebuffer`, which has `windowTitle` and `rows`
  (`MoshTerminal/Framebuffer.swift:20-22`). The app already decodes snapshots this way in
  `App/IOSMosh/StageTwoProbe.swift:129`.
- `readMeta()` (`SessionStore.swift:222`) and `readCounters()` (233-237) take no lock. They open
  read-only and write nothing; the host list already uses them (`App/IOSMosh/SessionList.swift:98-106`).
- While another coordinator holds a **different** record: unaffected (section 4).
- While **this** record is open: the reader finds the old snapshot or the new one, never a torn
  one (R8: `snapshot.tmp` → fsync → rename). An open session's snapshot is its last save, not
  its live screen. A "dirty" record still has the snapshot of its last save; a record that was
  never saved has none (show something else).
- R7 still holds: a preview is not a resume. Nothing built from it may get a gate, and none can,
  since gates are internal (`FileBackedGate.swift:85`). Use `readCounters().state` for "Could not
  be resumed" or "Ended". Do not use whether a snapshot file exists.

## 7. The invariants against parking and switching many times

- **A clean record saved twice (C10):** parking twice with nothing between writes nothing. An
  unpark always writes "dirty" (`beginSending`), so the next park is a real save.
- **A record that was given up (C4):** a failed park, `abandon()`, `.baseStateLost` or `.halted`
  leave it "dirty". Every cold start then gives `.fallback(.dirty)` with `meta`, until
  `deleteRecord`. With several sessions this is a row ("Could not be resumed"), not a takeover of
  the screen. The core does not care which.
- **Input in the background (C6):** parked records are closed and take no input. A coordinator
  kept quiesced in memory would store each input with a full save.
- **The key's source (C12) and N1:** on iOS the record has no key file. Nothing in the record
  ties it to its key: `SessionMeta` has no key hash (`SessionMeta.swift:79-97`). If the app passed
  record B's Keychain key to `coldStart` for record A, A's sequence numbers would be used under
  B's key: nonces reused for B (N1). The core cannot detect this. The app must read the key by
  the record id, as `SessionLauncher.swift:73` does.
- **N1, N2, N4 over many lives:** each life starts at the limits it reserved (R1, R2), and each
  unpark reserves new blocks: 65,536 sequence numbers and 1,024 state numbers and fragment ids
  (`FileBackedGate.swift:237-245`). The numbers skip ahead and never repeat. They are 64-bit,
  with an overflow check (`GateError.exhausted`, 174, 243), so there is no practical limit. The
  kill loop shows 203 lives in a row (`docs/RESUME.md:192, 202`).
- **Two writers:** impossible (R12). A coordinator that was dropped without `close()` only blocks
  (`.inUse`); a closed gate refuses every call (`FileBackedGate.swift:286-289`).
- **N2 through a stale snapshot:** only `SessionRecord.save` can mark a record clean, and only if
  no datagram left after the export (R5, R6). A switch adds no other path.
- **N3** is the transport's and does not depend on storage (`docs/RESUME.md:40-41`). The guard
  tests cover a restored `throwaway_num` (`docs/RESUME.md:206`).

## Missing

Nothing in `Sources/` is missing: the app can do all of this with today's core. What is open:

1. A test (in `Tests/`, not `Sources/`): a resumed coordinator, `start()`, `shutdown()`,
   `.shutdownFinished(acknowledged: true)` from a real `mosh-server`, and the server gone
   afterwards.
2. Rules for the app that the core does not enforce: `await close()` before the same record's
   `coldStart`; `start()` before `shutdown()`; the key read by the record id; wait for contact
   before `shutdown()` (one try only).
3. Optional: a public `SessionStore` method that reads the snapshot without the lock, in place of
   the app reading the file itself. It is not needed. It would touch reviewed code only to
   expose a read.
