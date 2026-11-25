# Hostile review of the app's resume wiring (App M6)

Reviewed: commits `66bf4f7`, `b6ce7c4`, `d8d4646` on `main`. All `file:line` references are
to the files as of `d8d4646` (`fb5669a` later moved lines in `TerminalViewController.swift`
by about 11). Read only: nothing was built or run. The library (`MoshResume`, `MoshSession`,
`MoshBootstrap`) is taken as correct as documented; the question was whether the app uses it
correctly in every order of events.

Contract: `docs/RESUME.md` (R1-R21, C1-C13, "The app"), `docs/PLAN.md` sections 3 to 7.

Severity: **critical** can violate N1-N4 or leak a key; **high** loses a resumable session or
kills the wrong thing; **medium** wrong behaviour the user sees, or a server left behind;
**low** the rest.

Short names: TVC = `App/IOSMosh/TerminalViewController.swift`, SD = `SceneDelegate.swift`,
SL = `SessionLauncher.swift`, SF = `SessionFiles.swift`, SK = `SessionKeychain.swift`,
PW = `PathWatcher.swift`.

## Result

No critical finding. I found no order of events in which the app sends a datagram outside
the coordinator's gate, runs two live sessions on one record or key, or pairs a key with
older counters. Two high findings lose a session that could have been kept, three medium
findings are behaviour against the contract, and the tests leave the kill path and most
cold-start outcomes unproven.

| Id | Severity | Finding |
|---|---|---|
| M6-1 | high | A failed probe at a machine other than the saved address abandons a live session |
| M6-2 | high | A session that starts while the app is not active is never saved |
| M6-3 | medium | 15 s after the server ends the session, the app starts a new one by itself |
| M6-4 | medium | A deliberate end that does not reach the host deletes the only identity of a live server |
| M6-5 | medium | A launch handles only the newest record; older ones wait and surprise later |
| M6-6 | low | "Retry later" shows nothing, can be dropped, and never ends for a bad Keychain item |
| M6-7 | low | A deferred start that fails is only logged; the old record is already forgotten |
| M6-8 | low | The old server is killed before the new one exists |
| M6-9 | low | `PathWatcher` misses a change with the same interface names and has no upper bound on its delay |
| M6-10 | medium | The tests do not exercise the identity-checked kill, `.ended`, `.retryLater`, `forget` or `removeOrphans` |
| M6-11 | low | The phone runs a Debug build: debug launch arguments are live there, one of them wipes all sessions |

## Status

After the fix round of 2026-11-14 (commits on `main`). Unit tests are in `App/IOSMoshTests`
unless a path is given.

| Id | Status |
|---|---|
| M6-1 | Fixed in `63aa1ba`, in `ProbeResult.from`: a failed check is "ended" only when SSH reached the record's address; a failed check at another address, an unreadable `ps` answer and a record without an address are `ProbeResult.unknown` (action: say so, keep the session). Tests (`Tests/MoshBootstrapTests/IdentityCheckTests.swift`): `testAFailedCheckAtTheSessionsAddressIsEnded`, `testAFailedCheckAtAnotherAddressIsUnknownAndKeepsTheSession`, `testAnUnreadableAnswerIsUnknownEvenAtTheSessionsAddress`, `testWithoutASavedAddressNothingIsProven`, `testOnlyEndedStartsANewSession`. No test with a real host that resolves elsewhere |
| M6-2 | Fixed in `d9a257f`: `SceneSavePolicy`; `attach` queues the background save before `start()` when the scene has resigned or is in the background. Tests: `SceneSavePolicyTests` (6, sequences A, B, C). The policy is tested, not a real resign during a bootstrap on the simulator |
| M6-3 | Fixed in `e007db6`: `HealthPolicy.step` does nothing after `.serverEnded`; timer and path watcher stop; leaving the screen then closes and deletes without a shutdown request. Test: `HealthPolicyTests.testAfterTheServerEndedTheSessionThereIsNoProbeAndNoBanner`. No UI test "`exit`, wait 20 s" with a saved host |
| M6-4 | Fixed in `f090443` for three of the four places: a shutdown without an answer in 11 s keeps the "ended" record; `finishEnded` deletes only by `OldServerOutcome.mayForget` (killed, check failed at the session's own address, or nobody to ask); a refused shutdown tries the identity-checked kill before the delete. Tests: `SessionLauncherTests.testAnEndedRecordIsForgottenOnlyWhenItsServerIsDealtWith`, `testWithoutAHostOrAnIdentityThereIsNothingToAsk`, `testAnEndedRecordIsListedWithItsServerIdentityAndIsNotASession`. **Open:** the screen left while a fallback bootstraps: the old record is dirty and cannot be marked "ended" without a new call in `MoshResume` (not changed in this round), so the kill is tried once and the record is deleted even when the host was not reached. Also open: an ended record whose host never answers again is kept and asked at every launch, with no expiry. **2026-11-19, the fourth place (found in M8 unit 1), `3838564`:** a shutdown that mosh gave up (`.shutdownFinished(acknowledged: false)`: 16 sends without an answer, about 0.4 s on loopback, or 10 s) no longer deletes. `SessionEnding.after` (pure) maps it to `.keepEnded`: `TerminalViewController` only closes and the record stays "ended" for `finishEnded` at the next launch or "End Session"; only `.shutdownFinished(acknowledged: true)` and `.serverEndAcknowledged` delete at once. Tests: `SessionEndingTests` (5); `SessionListUITests.testAnUnansweredShutdownKeepsTheSessionEndedUntilEndSessionStopsTheServer` and `testAnUnansweredShutdownIsFinishedByTheNextLaunch` (server stopped with SIGSTOP through the spawner's `/sshd/signal`; the row stays "ended" past 13 s; the identity-checked kill then runs against the throwaway sshd, reported as the mark `old-server-killed`, and the server is gone after SIGCONT). The first fails on the old mapping (record gone 0.37 s after leaving) |
| M6-5 | Partly fixed in `f090443`: every "ended" record, whatever its age, is finished at launch (`SessionLauncher.endedRecords`, `SceneDelegate.finishEndedSessions`) and no longer hides or delays the others. **Open:** older dirty records still wait until they are the newest; a record with unreadable `meta` still sorts first |
| M6-6 | Partly fixed in `d66e3f8`: a malformed Keychain item is a fallback, not "retry later" (`SessionLauncherTests.testAMalformedKeychainItemIsAFallbackNotARetry`); a skipped retry stays pending (no test). **Open:** the line on the host list |
| M6-7 | Fixed in `eda736a`: `.gateFailed` shows a status and `start()` is asked again at the next return. No test (the app cannot make the gate fail). The old record is still forgotten when `start()` returns, also for a deferred start; it holds nothing a new session needs |
| M6-8 | Fixed in `5eb1f4b`: the kill follows `startMoshServer` on the same connection. No new test; `SSHBootstrapUITests` and `ResumeUITests` pass |
| M6-9 | Partly fixed in `aa8c8e7`: the debounce fires at most 2 s after a change (`PathChangeFilterTests.testTheDebounceHasAnUpperBound`). **Open:** same interface name on another network (needs a device), a socket per flap of a secondary interface |
| M6-10 | Partly: the unit tests named above, and (2026-11-14) `SessionFilesTests` (`635eba3`: `testForgetRemovesRecordKeyAndLinkOfThatSessionOnly`, `testForgetOfARecordInUseKeepsEverything`, `testForgetOfASessionWithoutARecordRemovesItsKeyAndLink`, `testRemoveOrphans`); `SessionLauncherTests.testALockedKeychainIsRetryLaterAndWritesNothing` (`151e32b`; `.locked` injected by a test subclass of `SessionKeychain`, which is no longer `final`, plus the `errSecInteractionNotAllowed` mapping); `ResumeUITests.testADirtyRecordAtRelaunchKillsTheLiveOldServerOverSSH` (`92bb6b7`: crash with a live saved-host session, relaunch, new server over SSH, the old pid gone from `/sshd/servers`); `ResumeUITests.testASecondResumeGenerationKeepsTheSameServer` (`dad82f3`). No app bug found by them. **Open:** a kill refused for a pid that fails the check, from the app; background-task expiry. (Shutdown without network as a UI test: done 2026-11-19 with a SIGSTOPped server, see M6-4) |
| M6-11 | Fixed for the session wipe on 2026-11-20: `SessionFiles.resetForUITestsIfAsked` deletes records, keys and links only when the launch passes `-uiTestingResetSessions 1` (as `AppFiles` waits for `-uiTestingReset 1`); `-uiTestingKeepSessions 1` still wins. The decision is the pure `SessionFiles.resetsSessionsForUITests(uiTesting:resetSessions:keepSessions:)`, test `SessionFilesTests.testOnlyAnExplicitResetArgumentWipesTheSessions`. Every UI-test launch that wiped before (29 launches in 11 classes: each `-uiTesting 1` launch without `-uiTestingKeepSessions 1`) now passes the new argument, so no test changes its behaviour. **Still true:** the phone runs a Debug build, and its other debug arguments stay live there: `-debugMoshPort`/`-debugMoshKey` (a key from the command line), `-debugFallback*`, `-debugCrashAfter`, `-uiTesting 1` itself (settings start from the defaults unless `-uiTestingKeepSettings 1`, `screenText`, spawner marks), `-uiTestingReset 1` (saved hosts and known host keys), `-uiTestingCountersMode`, and "Crash Now". Only someone with `devicectl` access can pass them. A Release build for daily use (owner: later) would end all of it |

## Findings

### M6-1 (high) A failed probe at another machine abandons a live session

Sequence:

1. A session runs to host `h` (saved host with a name; `meta.address` is the IP the first
   bootstrap reached).
2. The name now leads to another machine: several A records, split DNS on another network,
   or the user edited the saved host (the session keeps the host by id, so it sees the
   edited one: SF:53-56).
3. 15 s pass without a datagram from the server while the app is active (UDP blocked on
   this network is enough): TVC:645-646.
4. `probe()` logs in to `host.target` (TVC:666-669) and runs `ps -p <pid>` there. No such
   process, or another one.
5. `ProbeResult.from` returns `.sessionEnded` for every failed verdict and compares the SSH
   address with the saved one only when the verdict passed
   (`Sources/MoshBootstrap/IdentityCheck.swift:196-204`). The action is `.startNewSession`.
6. `runtimeFallback` (TVC:674-675, 394-413): `abandon()`, new bootstrap, old record, key and
   link deleted at TVC:593.

The old `mosh-server` and its shell still run on the real machine. The kill in the new
bootstrap is identity-checked at the wrong machine, so it kills nothing (correct), and after
step 6 nothing knows the pid any more. The user loses a session that needed only a network
where UDP passes.

A failed check proves "ended" only at the machine the session is on. The plan's table
(section 4) has the address comparison only in the "passes" rows.

Smallest fix, in the app: in `probe()`, when the action is `.startNewSession` and the
address SSH reached differs from `meta.address`, treat it as `.informAndKeepSession` ("the
host name now leads to another machine"). `ServerProbe.probe` must then expose the SSH
address in its result if it does not already. The better place is `ProbeResult.from` (a
library change: a new case for "check failed at another address"), because every caller
needs the same rule.

### M6-2 (high) A session that starts while the app is not active is never saved

`sceneWillResignActive` saves only if a coordinator exists at that moment (TVC:269).
`attach` starts the session without looking at the scene state (TVC:540-558), and nothing
runs when the scene later goes from inactive to background (SD has only
`sceneWillResignActive` and `sceneDidBecomeActive`, SD:41-51).

Sequence A (new session):

1. Tap a host. The bootstrap runs (seconds).
2. Home, lock, or the app switcher: `sceneWillResignActive`, `coordinator == nil`, return.
3. The bootstrap ends in the time the process still has. `openSession` (TVC:473) makes the
   record, `attach` calls `begin`, `start()` sends. The record is dirty with an open socket.
4. The process is suspended and later killed. No clean mark was ever written.
5. Next launch: `.fallback(.dirty)`, the server is killed, a new session starts.

Sequence B (resumed session, loses user content):

1. Cold start returns `.resumed` (SD:63, 81-82). The record on disk is clean.
2. The scene resigns before the terminal screen has its first size (the user leaves at
   once, or a system alert followed by Home): `coordinator == nil` (it is set only in
   `attach`, TVC:541), return.
3. `startSessionIfNeeded` runs at the first layout: `attach`, `start()`. The record is now
   dirty (R-rule for the first send) and is never saved.
4. Killed in the background: the session that was resumable is a dirty fallback.

Sequence C: the replacement session of a cold-start or run-time fallback (TVC:373-380)
starts while not active; same as A.

If the user returns while the process lives, nothing is lost (`.foreground`, then the next
resign saves). The loss needs a kill before that.

Smallest fix: remember in `sceneWillResignActive` that the scene resigned without a
coordinator (a flag, cleared in `sceneDidBecomeActive`; `isAppActive` itself already has
this meaning once the scene has been active). In `attach`, if the flag is set, yield
`.background(BackgroundTask(name: "save session"))` before `begin`. Either order at the
coordinator is then safe: background first makes `start()` a deferred start (C11), start
first is followed by a normal save.

### M6-3 (medium) 15 s after the server ends the session, the app starts a new one

Sequence:

1. The user types `exit`. The server says so: `.serverEnded` shows "Session ended"
   (TVC:608-610). On `.serverEndAcknowledged` the event task closes the coordinator and
   deletes record, key and link (TVC:549-551, 329-332).
2. `self.coordinator` stays set, and the health timer and `PathWatcher` keep running
   (stopped only in `endSession` and `runtimeFallback`).
3. No contact for 15 s, of course: `checkHealth` calls `probe()` (TVC:633, 645-646), since
   a session from a saved host has a host and an identity.
4. SSH login, `ps` finds no such pid: `.sessionEnded`, `.startNewSession`.
5. `runtimeFallback`: banner "Previous session could not be resumed. Starting a new one."
   and a full bootstrap of a new session (TVC:405-411).

The contract (RESUME.md, `.fallback(.ended)`; SD:85-88 for the cold start) says an ended
session wants no new one. The UI tests do not see this because their debug sessions have no
host (TVC:651-653) and the SSH test leaves within 15 s.

A second effect of the same state: leaving the screen afterwards runs `end()`, `shutdown()`
returns false because the session is over, and the log says "shutdown refused (the record
cannot be written)" (TVC:318-323), which is not what happened.

Smallest fix: on `.serverEnded` and `.serverEndAcknowledged` in `handle`, stop the health
timer and the path watcher and set a flag that `checkHealth` and `probe` respect (or clear
`coordinator` after `finish`).

### M6-4 (medium) A deliberate end that does not reach the host forgets a live server

RESUME.md says the shutdown request may never arrive and `mosh-server` has no timeout once
a client has been seen; that is why "ended" records exist. The app deletes them too early
in four places:

- TVC:317-325: after 11 s without `.shutdownFinished` (no network), `finish` closes and
  deletes record, key and link.
- TVC:320-325: `shutdown()` false because the record could not be written: deleted at once,
  nothing was sent to the server.
- SL:141-145: `finishEnded` deletes the record even when "ended session's host not
  reached", and also when the kill failed for a reason other than a failed identity check.
- TVC:304-308: leaving while a fallback is still bootstrapping deletes the old record
  without any kill attempt.

Sequence for the first: on a train, the user goes back to the host list; no network for
11 s; the record is gone. The server and its shell run until the host restarts, and the app
no longer holds pid and start time to kill them.

Smallest fix: in `end`, when the 11 s pass without `.shutdownFinished`, `close()` only and
keep the "ended" record. In `finishEnded`, forget only when the kill succeeded or the
identity check failed (the server is provably not there); otherwise keep the record for the
next launch. In the TVC:304 case, mark the old record for the same path instead of
forgetting it (it needs M6-5, or it is never looked at again).

### M6-5 (medium) A launch handles only the newest record

`SessionLauncher.coldStart` sorts by `createdAt`, and returns the first decision
(SL:44-56). The others are not touched. More than one record does occur:

- A: leave session 1 (record "ended", 11 s window, TVC:319), open host 2 within that time,
  the process is killed. Records: 2 (newest) and 1 (ended).
- B: `forget(old)` fails after a fallback (TVC:593 keeps `oldSession`, nothing retries it).
- C: `.retryLater` for record 1, the user opens another host (M6-6).

What happens: launch resumes or falls back for the newest only. Record 1 is handled when it
has become the newest, which may be weeks later: for a dirty one the user then gets
"Previous session could not be resumed. Starting a new one." and a new session to a host
he left long ago; for an ended one the kill of a leftover server happens that late.
A record whose `meta` is unreadable sorts first (`.max`, SL:59-61) and, if its decision is
`.retryLater`, hides every other record at every launch.

Smallest fix: go through all records at launch. Ended ones go to `finishEnded` in the
background; at most one (the newest that resumes) becomes the session; for other dirty ones
kill the old server if the check passes and forget them, with no new session.

### M6-6 (low) "Retry later" is silent, can be dropped, and can last for ever

- SD:78-80: the host list appears with no word that a session is waiting.
- SD:114-117: the retry at the next activation is skipped when a terminal screen is open,
  and the flag was cleared at SD:48, so it is not tried again in this process. The record
  then is an older record in the sense of M6-5.
- SK:74-76 with SL:68-73: a Keychain item that is not 16 bytes is an `.io` error, which is
  `.retryLater` at every launch. It is not a state that time repairs.

Smallest fix: a line on the host list ("A session is waiting: <reason>"); set
`coldStartPending` again when the retry was skipped; treat a malformed item like a missing
one (fallback without a key).

### M6-7 (low) A deferred start that fails is only logged

`start()` asked for while the coordinator is in the background returns success and is
carried out at `enterForeground` (C11). In the app this is reachable today through
`startFailed` and becomes the normal path with the fix for M6-2.

Sequence: `begin` returns without error, `sessionStarted` forgets the old record
(TVC:584-585, 590-594). Back in the foreground the deferred start fails; the coordinator
reports `.gateFailed`, which `handle` only writes to the log (TVC:619-620). `startFailed`
stays false, so nothing retries, and the screen shows no message.

Smallest fix: handle `.gateFailed` like the catch branch of `begin` (status text, set
`startFailed`).

### M6-8 (low) The old server is killed before the new one exists

RESUME.md's order is: bootstrap the new session, kill the old server, delete the record.
`bootstrap` kills first (TVC:446-457) and starts `mosh-server` after (TVC:459). If the
start then fails, the old server is gone, there is no new one, and the old record stays
(deleted only at `sessionStarted`). Nothing is lost that was resumable, since a fallback
was already decided; the order just differs from the document, and the screen then shows a
bootstrap error over a record that the next launch falls back on again (the kill then fails
the identity check, which is fine).

Smallest fix: call `killServer` after `startMoshServer` returned, before `close()`.

### M6-9 (low) `PathWatcher`

- PW:54-60: a change counts when the interface name list or the first interface differs,
  or the path goes from unsatisfied to satisfied. Wi-Fi A to Wi-Fi B with the same name
  (`en0`) and no unsatisfied update in between is not a change. mosh's own roaming (the
  server follows the source address) covers this only if the old socket still works on the
  new network; an `NWConnection` bound to the old path may not. Not traced further, see
  "Not verified".
- A secondary interface that comes and goes changes the name list each time: a new socket
  per flap, although the route in use did not change. Harmless for N1-N4 (numbers come from
  the gate, and `replaceSocket` does nothing in the background or when closed,
  `ResumeCoordinator.swift:672-675`), it costs a port on the server's side each time.
- Every update while a change is pending restarts the 0.3 s timer, so a stream of updates
  less than 0.3 s apart postpones the new socket without limit.

Smallest fix: compare the local address of the first interface as well where available,
and give the debounce a maximum wait (for example 2 s from the first update).

### M6-10 (medium) What the tests prove and what they do not

`ResumeUITests`:

- (a) proves a real resume: the relaunch has no `-debugMosh*` arguments, so the key can
  only come from the Keychain, and the shell's `$$` is the same before and after. It does
  not check that the first screen after the relaunch is the stored one (only that the text
  is there in the end), and it resumes once; the second generation (resume, save, kill,
  resume) is what exercises the counters across two clean marks.
- (b) proves the dirty decision by the banner text and a new pid. "The first server is
  still alive" is checked at once, which does not show that no datagram reached it, and the
  test does not check that the old record and key are gone afterwards. It uses the debug
  fallback, so no kill is attempted.
- (c) the server is already stopped when the app returns, so the kill finds nothing.

So the identity-checked kill of a live old server is never run from the app: neither the
kill itself, nor a refusal for a pid that fails the check.

Unit tests (`SessionResumeTests`): Keychain round trip and accessibility class; four
launcher cases (no record, dirty, no key, record in use). Missing:

| Missing test | Finding it would have caught |
|---|---|
| `SessionLauncher` returning `.resumed` and a start that sends | - |
| `.ended` record: `finishEnded` with host reached / not reached | M6-4 |
| Two or more records at launch | M6-5 |
| `SessionFiles.forget` (order, failure keeps key and link) and `removeOrphans` | - |
| Keychain `.locked` and a malformed item | M6-6 |
| Resign during bootstrap, then the session starts | M6-2 |
| `exit` in a session from a saved host, wait 20 s | M6-3 |
| Probe with a host that resolves elsewhere | M6-1 |
| Shutdown without network (11 s) | M6-4 |
| Fast resign/active flips; background-task expiry | - |
| A Release build ignores `-debugMosh*`, `-uiTesting` | M6-11 |

### M6-11 (low) Debug arguments on the phone

All debug launch arguments, `screenText`, the spawner marks and "Crash Now" are under
`#if DEBUG` (`DebugLaunch.swift`, `UITestSupport.swift`, SF:109-114), and `DEBUG` is set
only in the Debug configuration (`project.pbxproj:508`). The archive is Release, but
`scripts/deploy.sh` installs a Debug build on the phone. There, a launch with `-uiTesting 1`
and without `-uiTestingKeepSessions 1` deletes every record and every session key
(SF:108-114), and `-debugMoshKey` takes a key from the command line. Only someone with
`devicectl` access can pass arguments, so this is a foot-gun, not a leak.

Smallest fix: have `resetForUITestsIfAsked` act only when an explicit reset argument is
given (as `AppFiles` does with `-uiTestingReset`), or install Release for daily use.

2026-11-20: the first of these is done (Status table, M6-11).

## Not verified

- **`replaceSocket` before the first start.** `runReplaceSocket` checks `closed` and
  `inBackground`, not `started` (`ResumeCoordinator.swift:672-675`), and the path watcher is
  installed in `attach` whether or not `start()` succeeded. `MoshConnection.replaceSocket`
  opens a socket and pumps (`MoshConnection.swift:181-185`). To check: can `pump()` send on
  a connection whose `start()` was never run or failed at the gate? If it can, it must still
  go through the gate, but that path has no test.
- **Server output in the log.** A failed server start puts the pty text into the error's
  description, which goes to `debug.log` and the status label (TVC:484-491,
  `BootstrapError.swift:194-199`). That path is taken only when no valid `MOSH CONNECT` was
  parsed (`SSHBootstrap.swift:36-41`). To check: can `ConnectLineParser` reject a line that
  still holds a usable key (valid key, bad port) so that the text carries it?
- **Keychain before first unlock on a phone.** The code relies on
  `errSecInteractionNotAllowed` for a locked device (SK). If iOS answers `errSecItemNotFound`
  for an `AfterFirstUnlock` item in some state, SL:74-84 turns a resumable record into a
  fallback. Needs the phone.
- **`ps` failing with empty output.** `readIdentity` reads whitespace-only stdout plus any
  exit status as "no such process" and ignores stderr (`ServerProbe.swift:15`). A `ps` that
  fails for another reason would make the probe say "ended" (then M6-1's consequence).
  To check on the supported hosts: what `ps -p` prints when it cannot run.
- **Scene disconnect and reconnect in one process.** `TerminalViewController.deinit` closes
  the coordinator; whether its lock is released before a new `scene(_:willConnectTo:)` runs
  the cold start was not traced (the result would be `.retryLater`, then M6-6).
- **Resize after a resume.** The cold start passes `currentSize: nil` (SL:85) and
  `announcedSize` is nil for a resumed session; whether the first `viewSizeChanged` then
  sends a resize equal to the server's size (a wasted state number, nothing worse) was not
  traced.
- **Wi-Fi to Wi-Fi with the same interface name** (M6-9): whether the old `NWConnection`
  keeps working needs a device.
- **`Signing.xcconfig`** was not read (secrets); a `DEBUG` condition set there for Release
  would change M6-11.

## Checked and found correct

- Every session of the terminal screen is a `ResumeCoordinator`. The app constructs no
  `MoshSession`, `MoshConnection` or gate of its own (`grep` over `App/IOSMosh`).
- One consumer feeds input, resize, background, foreground and socket replacement to the
  coordinator in the order they happened (TVC:215-226); a command for a missing coordinator
  is dropped and its background task ended.
- `perform`, `end` and `finish` are static members of a main-actor class, so
  `BackgroundTask.end()` is always called on the main actor, as is the expiration handler.
- Key before record (TVC:504, 525); a failed `create` forgets the key (TVC:529). `forget`
  deletes the record under its lock first and keeps key and link when that fails
  (SF:66-82). Orphan keys are removed only when the directory is known to be absent, and
  not at all when the keys cannot be listed (SF:87-104).
- Session ids are random; `SecItemAdd` and `create` both refuse an existing id, so a key
  cannot be paired with another record's counters.
- Any Keychain error other than "not found" is `.retryLater` and deletes nothing
  (SL:68-73). The fallback without a Keychain item writes nothing to the record and cannot
  send (there is no key), so skipping `coldStart` there cannot break N1-N4.
- A second cold start of the same record while a coordinator holds it gets "in use"
  (R12), so `retryColdStart` cannot make a second live object.
- `runtimeFallback` awaits `abandon()` before the replacement starts, and the replacement
  has a new id and key (TVC:408-411).
- Resign while ended or after a run-time fallback does nothing; fast resign/active flips
  are ordered by the queue; `enterForeground` is queued before any later input.
- `killServer` runs the identity check on the same connection and signals nothing when it
  fails (`ServerProbe.swift:37-40`); the app never kills by pid alone.
- Logs: endpoint host, port, pid, ids and reasons; no session key, private key, password or
  typed input in any `DebugLog` call of the reviewed files. `BootstrapResult.serverOutput`
  (which holds the `MOSH CONNECT` line) is not used by the app.
- Session keys: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable, a
  service of their own.
- One scene (`UIApplicationSupportsMultipleScenes` false), so `static weak var current` is
  enough.
