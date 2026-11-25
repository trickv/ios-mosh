# Resume review B: the coordinator

Scope: `Sources/MoshResume/ResumeCoordinator.swift` and how it drives `MoshSession`,
`MoshConnection` (export, import, quiesce, `CleanToken`, `markClean`) and `moshcli resume`.
Branch `cloud-work` at `c7ddc83`. Nothing in the repo was changed.

Scratch tests: `/tmp/claude-0/-home-user-ios-mosh/547e2632-dd16-5a23-85ee-9d1f7fd2dd40/scratchpad/resume-review-b/Tests/MoshResumeTests/ReviewBTests.swift`
(a copy of the repo; run there with `scripts/dev.sh swift test --filter ReviewBTests`).
Each test asserts what should hold; all 6 fail on the current code (12 failed assertions).

## Result in one paragraph

No path to N1, N2 or N4 was found. Every send before "dirty" that I could construct
(input before `start()`, a failed `beginSending`, a failed `markDirty` at the return to the
foreground) is stopped by `FileBackedGate` itself, not by the coordinator's order. The
findings are about sessions that are lost or dropped although they need not be, input reported
as taken that a resume does not have, and an API that makes two wrong orders easy.
One major, six minor. B-6 was found by reading and is not reproduced.

## What was checked and held

Server's view (mosh 1.4.0, read in `.refs/mosh/src`):

- An ack that goes backwards or names a culled state changes nothing:
  `transportsender-impl.h:360-378` ("Ignore ack if we have culled the state it's
  acknowledging"); states are erased only below an ack that is found.
- A resumed instruction `old_num = A`, `new_num` = a fresh number is applied on `A`, which the
  server still holds because it erases only below `throwaway_num`
  (`networktransport-impl.h:88-116`, `process_throwaway_until`) and the client never sent a
  `throwaway_num` above its acknowledged state. The new state's input list is the old states'
  list or longer, because the snapshot's pending input is the whole log from `A`
  (`TransportCore.swift:943-944`); so `user.cc:54-56` and `:68-69` cannot fire.
- A late datagram of the old process is either ignored (base gone, or number held) or inserted
  out of order without an ack (`networktransport-impl.h:143-153`); its list is a prefix.
- Sequence numbers: the server uses a datagram for the return address only if
  `p.seq >= expected_receiver_seq` (`network.cc:515-518`); the gate starts a new process at the
  reserved limit, so the first resumed datagram moves the address.

Coordinator:

- `inOrder` is assigned synchronously on the actor; lifecycle calls, input and event handling
  cannot interleave. No await sits between a check and its act inside one operation except the
  session calls, which are themselves serialized.
- While `inBackground` is true the core is quiesced: a datagram already in the inbox is dropped
  (`MoshConnection.swift:365`, no socket ids), a late timer produces nothing
  (`TransportCore.canSend`).
- Token and snapshot are read in one call of the connection actor
  (`MoshConnection.swift:224-227`); nothing but the gate changes `passed`.
- A server shutdown, a finished shutdown or a halt that happened before the save but whose event
  has not been handled yet: `exportState` throws `sessionEnded` and `save` marks the record
  ended (`ResumeCoordinator.swift:450-453`).
- M9 as specified (input, resize, shutdown while `inBackground`): closed for every order I
  could build with working storage. The holes are B-4 and B-5 (storage fails) and B-2 (before
  `start()`).

---

## B-1 (major): "ended" hides three different things; a fallback the app did not finish is dropped at the next start, and the old server is never killed

**Where.** `ResumeCoordinator.swift:305-311` (cold-start fallback: `try? record.gate.markEnded()`),
`:547-551` (`runAbandon`), `:571-577` (`handle`: `.baseStateLost` and `.halted` mark the record
ended), `:55` (`wantsNewSession: reason != .ended`), `:343-346`.

**Violated.** PLAN section 3, "Fallback": "(dirty, unreadable snapshot, missing key, lost base
state): mark the record dead, show "Previous session could not be resumed. Starting a new
one.", and bootstrap again over SSH with the host's remote command. ... In the same SSH
connection, kill the old `mosh-server`". And: "The banner also has a "Start new session"
button, which marks the record dead and bootstraps again." RESUME.md, outcome table, for
`.fallback(.ended)`: "`wantsNewSession` is false: removes the session from its list,
`deleteRecord`".

**What happens.** The record has one mark, "ended", for (a) the user or the server ended the
session, (b) a cold-start fallback gave it up and the app still owes a new bootstrap and the
kill of the old server, (c) "Start new session" (`abandon`), a lost base state or a halted
transport at run time, which the plan also sends to the fallback. The reason exists only in the
return value of the first `coldStart` (or in the event). If the process dies before the app has
bootstrapped again and called `deleteRecord` (the bootstrap needs the network and possibly the
user; a launch without network, then the user leaves, is enough), the next `coldStart` returns
`.fallback(.ended)` with `wantsNewSession == false`. Following RESUME.md the app removes the
session and deletes the record: no banner, no new session, and the old `mosh-server` (with the
user's shell and whatever runs in it) stays for good: mosh-server has no network timeout
unless `MOSH_SERVER_NETWORK_TMOUT` is set (`mosh-server.cc:384`).

The same mark is written for a shutdown request that was never delivered (asked for in the
background, or in the foreground with the server unreachable, then the process dies): next
start `.ended`, record deleted, server orphaned. `ColdStartFallback` says of `.ended` "The
server is normally gone"; in cases (b), (c) and this one it is alive.

**Tests (fail).** `testB1_AFallbackThatTheAppDidNotFinishStillWantsANewSession` (dirty record,
`coldStart` twice: second says `.ended`, `wantsNewSession` false),
`testB1_AnAbandonedSessionStillWantsANewSession`. The existing
`testLeavingTheForeground...` asserts the behaviour as intended (`later.reason == .ended`).

**Direction.** Keep why the record is dead (a fourth counters state, or the reason beside
"ended"): "given up, new session owed" must survive until `deleteRecord`, and "shutdown asked,
not confirmed" should still hand the app `meta` with the instruction to kill the server.

## B-2 (minor): input before `start()` sends at once; `enterBackground()` then neither quiesces nor saves, and the session is lost

**Where.** `ResumeCoordinator.swift:493-495` (`runInput` passes input to the session when not
`inBackground`, whether or not `started`), `:415-417` (`runEnterBackground`:
`guard started else { return .notResumable(.failed("the session was not started")) }`, before
the quiesce), `MoshConnection.swift:262-274` and `:394-400` (`type`/`resize` call `pump()`,
which opens a socket when `current == nil` and `now >= lastOpenAttempt + 1000`; `lastOpenAttempt`
starts at 0).

**Violated.** `coldStart` doc: "Nothing is sent here in any case; a resumed session sends at
`start()`"; `create` doc: "Nothing is sent before `start()`". RESUME.md C1: "then one counters
change ("dirty", new reservations); then the first datagram". C5 (save at `enterBackground`).

**What happens.** After `.resumed(coordinator)`, a `resize` (the terminal view reports its size
at its first layout) or `type` that reaches the coordinator before `start()` ran, or after
`start()` threw its storage error ("call `start()` again later"), opens a socket and sends the
pending input. The gate still writes "dirty" first (two changes, not one), so no number is
reused. But the connection's reader is not running (replies are not processed), and if the app
now goes to the background, `enterBackground()` returns "not started" without quiescing: the
timer keeps sending in the background and the record stays dirty. A process death then gives
`.fallback(.dirty)`: a session that was resumable a moment ago is gone.

**Test (fails).** `testB2_InputBeforeStartSendsAndTheSessionIsThenLost`: socket opened and a
datagram sent before `start()`, record dirty, `enterBackground()` = "not started", one more
datagram 1.5 s later, next cold start is the fallback.

**Direction.** Before `started`: hold input in the coordinator (or refuse it), and let
`enterBackground()` on a not-started coordinator be a no-op that reports the record's real
state. `MoshConnection.pump()` should not open a socket before `start()`.

## B-3 (minor): a repeated `enterBackground()` can only lose a resumable record

**Where.** `ResumeCoordinator.swift:415-425` and `:445-460` (every call saves again),
`SessionRecord.swift:107-115` (the snapshot is replaced under a new random id, then the clean
mark is rewritten).

**Violated.** Coordinator doc: "Safe to call again while in the background." PLAN: "System
alerts and the app switcher also fire this callback, so it runs often."

**What happens.** The record is clean for S1. A second `enterBackground()` (resign-active and
did-enter-background both wired, or two alerts) renames a new file S2 with the same content
over S1 and then writes "clean for S2". Between the rename and the mark the record says "clean
for S1" and holds S2: a death there gives `.fallback(.snapshotDoesNotMatch)`, which marks the
record ended. If the mark's write fails instead, `save` returns `.failed`, and
`coordinator.recordState` still answers `.clean(S1)` ("`.clean` means a process death is
followed by a resume") while the next start falls back. Nothing was sent and nothing changed;
the first save was sufficient.

**Test (fails).** `testB3_ASecondSaveNeverMakesAResumableRecordUnresumable`: of 14 kill points
in the second save, 4 (after `snapshot.rename`, before and after `dir.fsync`, before the
`counters.write`) end in the fallback.

**Direction.** In `runEnterBackground`, when already `inBackground` and the record is clean,
return `.clean` without saving (background input already saves on its own).

## B-4 (minor): a shutdown in the background whose mark cannot be written is accepted, and the closed session is resumed

**Where.** `ResumeCoordinator.swift:517-521` (`runShutdown` ignores whether `markEnded`
worked), `:464-473` (`markEnded`: on failure `try? markDirty()`, then only an event).

**Violated.** RESUME.md C7: "A shutdown request (foreground or background) ... mark the record
ended before the request is passed on"; M9: "a session the user closed" must not be resumed.
Compare C6, where input is refused when "dirty" cannot be written.

**What happens.** In the background the record is clean. `shutdown()` fails to write "ended"
and "dirty" (storage error), yields `.gateFailed`, passes the request to the quiesced session
and returns true. Nothing is sent. The process dies: the next cold start resumes the session,
and the user's shutdown is gone (the export would have refused a session that is shutting
down, but the old snapshot is still the clean one).

**Test (fails).** `testB4_AShutdownThatCannotBeRecordedIsNotResumed`.

**Direction.** As for input: if neither "ended" nor "dirty" can be written while the record is
clean, do not accept the shutdown (return false).

## B-5 (minor): M9 is closed only while `inBackground`; after a return to the foreground with a gate that cannot write, accepted input is missing from the resumed session

**Where.** `ResumeCoordinator.swift:433-440` (`runEnterForeground`: `inBackground = false`,
`try? record.gate.markDirty()`), `:495` (`guard inBackground, !ended else { return await apply(session) }`).

**Violated.** RESUME.md C6 in spirit ("A clean record holds everything that was accepted"), and
the reason given for M9: "a process death then resumed a session that had silently lost
input". C9's note "if that fails the gate still writes it before any datagram" covers
datagrams, not accepted input.

**What happens.** `enterForeground()` cannot write "dirty" (storage error). The gate then lets
no datagram pass (`.gateFailed`, retry every second), so the record stays clean for the old
snapshot. `type()` is not in the background path any more, the session takes the bytes and
`type()` returns true. If the process dies before storage works again, the cold start resumes
the old snapshot: the session continues without input that was reported as taken (no protocol
damage; nothing was sent).

**Test (fails).** `testB5_InputAcceptedWhileTheGateCannotWriteIsNotLostByAResume`: 13 bytes
accepted, the resumed session has 4 pending events, as before.

**Direction.** Decide the M9 path on "the record is not durably dirty" (ask the gate), not on
`inBackground`; or stay `inBackground` until `markDirty()` succeeded.

## B-6 (minor, by reading, not reproduced): a clipboard copy seen right at the save is written to the iOS pasteboard twice, the second time at the cold start

**Where.** `MoshSession.swift:238-244` (`exportState`: transport snapshot from the connection
actor, then `clipboard` read on the session actor), `:348-355` (`reportNewestScreen` observes
after its own await), `:170-175` (restored `start()` runs `clipboard.observe(_, live: true)` on
the stored screen).

**Violated.** PLAN section 3, cold start step 7: "The first server state after a resume writes
the iOS clipboard only if its hash differs from the one in the snapshot"; ClipboardPolicy rule
"Skip a write whose content hash equals the last one written". The fix of M10 assumed "that
copy was never written" (`MoshSession.swift:160-166`).

**What happens.** A state with a new OSC 52 clipboard reaches the connection just before the
quiesce; its `.remoteStateAdvanced` is still in the stream (or `reportNewestScreen` is at its
await). If the continuation of `exportState` runs first, the snapshot pairs the transport state
that has the copy with a policy (`lastSeen`, `lastWrittenHash`) that has not. The session then
handles the event: `.clipboard(.write)` goes to the app, which writes the pasteboard. After a
kill in the background the cold start compares the stored screen with the stored policy, finds
a change and an unknown hash, and reports `.write` again: the pasteboard is overwritten with
the old copy, possibly hours later and over something the user copied since. Window: the delay
of one event. (Copy on the host, then switch apps to paste, is the ordinary use.)

**Test idea.** A fake server state with a clipboard delivered to the connection, then
`quiesce()` and `exportState()` with the session's reader held back (a seam that delays
`handle`), then let the event through, expect `.clipboard(.write)`; import the snapshot,
`start()`, expect no second `.write`.

**Direction.** Take the policy for the snapshot after bringing it up to the exported newest
state (observe the exported state's clipboard inside `exportState` and emit the decision), so
that policy and transport describe the same state.

## B-7 (minor): `coldStart(key: nil)` on a record made with `storesKey: false` kills the session for good

**Where.** `ResumeCoordinator.swift:250` (`key: Base64Key? = nil`), `:289`
(`try key ?? record.readKey()`), `:305-311` (fallback marks ended), `:341-342`.

**Violated.** PLAN section 3: ""Device locked" errors (`errSecInteractionNotAllowed`, `EPERM`)
mean try again later, never dead." RESUME.md C3: "Fallback or "try again later", never a
guess."

**What happens.** On iOS the record has no `key` file. The record does not say so, so a nil key
(the default argument; or `try? keychain.read(...)` that failed because the device is locked)
reads as `RecordError.missing(.key)`: fallback, and the record is marked ended. A second call
with the key gets `.ended`. The rule "do not call `coldStart` without the key" is only in a doc
comment, and the failure is permanent. The existing `testARecordWithoutItsKeyFallsBack` needs a
second record to show the keyed resume for this reason.

**Test idea.** `create(storesKey: false)`, `enterBackground()`, `close()`;
`coldStart(key: nil)` must be `.retryLater` (or a precondition failure), and
`coldStart(key: key)` afterwards must resume.

**Direction.** Store in `meta` (or by a marker) that the key is external; then a nil key for
such a record is "try again later", never a fallback.
