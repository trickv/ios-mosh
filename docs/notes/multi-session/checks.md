# Checks of the revised DESIGN.md

**Status (2026-11-21 17:10 UTC): first half answered in `DESIGN.md`; the second half and its verification (both further down) are answered there too.** First half, 12:50 UTC: Two independent checks of the revised design
(lifecycle and resume invariants: session model; the brief, the tests and the plan: Opus) were
stopped by the usage rule after their reading. This file holds what they returned, word for word.
Nothing here is answered in `DESIGN.md` yet. None of the must-fix findings touches steps 0 to 3.
Ids: CL = lifecycle check, CP = plan check; S = should fix.

## Lifecycle and resume invariants

**Finished:** no (stopped at the 50% usage line).

### Must fix

1. **CL-1.** Blocks step 9. 2.3 step 1 (LC-13): `retryStart` is fixed when `.park(task, retryStart:)` is queued at the leave, but the failure is reported later: `begin` sets `startFailed` only after `await coordinator.start()` has thrown (TVC:726-733), and a deferred start's failure comes through the event task (TVC:777-785). Unpark on slow, failing storage and go back before the throw: the flag is false, the park answers `.clean` from memory (RC:490-495), one slot says dirty, the row reads "Could not be resumed": LC-13 unchanged. `testAFailedStartIsTriedAgainByThePark`, written failure first, passes. Smallest change: no flag; the park calls `try? await c.start()` for every restored coordinator that was attached (known at the leave). It does nothing once started (RC:445) and runs after `begin`'s call in the coordinator's order. The test leaves while `start()` is in flight. Rare: storage must fail.
2. **CL-2.** Blocks step 9. E1, E3, E4 (LC-14, the note under LC-3): the fixes have no step and no test, and the design contradicts itself on E4. Section 7's row for the terminal screen says the refused shutdown forgets "only if `mayForget`" and, in the same cell, "Unchanged bodies: `end`"; 5.3 calls the action "today's `end` (TVC:425-443) | E1, E4". The refused shutdown is `end`'s else branch, which forgets whatever the kill said (TVC:432-441). An agent that keeps the body keeps LC-14: the host is not reached and the pid is thrown away. No named test fails if E3 or E4 forget regardless, or if E1, E3, E4 do not clear "last looked at" first (step 12's test covers the ender, step 11's covers B3). Smallest change: 5.3 and 7 say `end`'s refused branch changes; step 9 names E3, E4 and the clearing; add LC-14's pure test (`.hostNotReached` keeps) and one that every end request clears the id first.

### Should fix

1. **CL-S1.** 2.3 rule 2, 5.5, G3: with the slot filled from `init`, the design does not say which reads mean "attached" and which "held". TVC:352 gives the scene's resign `hasSession: coordinator != nil && !ended`. If that becomes "slot filled", a resign between an unpark's push and its `attach` (tap a row, pull Control Centre during the push) queues `.background`, the consumer drops it (not attached), the policy never notes the resign, `attach` saves nothing and the session starts unsaved: LC-1's outcome again. Say: the scene's resign and return, health, probe and path watcher read `isAttached`; only the leave decision and the queue's end read `held`. Add a unit test for a resign before `attach`. (`SceneSavePolicy.swift` not re-read: usage.)
2. **CL-S2.** G3, H1, S4, W6, risk 1: (a) only the unpark (2.3, S1) says `loadViewIfNeeded()` before the push; H1, the fallback screen of S4 and the retry of W6 just push, so `current` is set whenever UIKit loads the view. Say it for every screen that `open` and the retry push. (b) Risk 1 says the cold start may move off the main thread, "which the design allows"; G3 needs no suspension from the gate to the push. Say that the gate is then asked again after the cold start, and a `.resumed` result is closed as a tracked release when it fails.
3. **CL-S3.** Section 7, the four rules. Rule 1 (`close()` before the cold start): `testSettledWaitsForATrackedRelease` proves the primitive; no named test fails if the leave does not register the park or `open` skips the settle (the user then meets "Session Not Available Now"; G1 keeps the record safe). Add to step 10 a unit test through the real `SessionQueue` with a slowed save: leave, `await settled()`, the cold start answers `.resumed`; control: the leave without `track`. Rule 3 (key by id): no test at all; add to the evidence of steps 9 to 12 that `ResumeCoordinator.coldStart(` occurs once under `App/IOSMosh`. Rules 2 and 4 are covered (step 12's UI tests, `testTheEndPlan`). Rule 2's cell is wrong for E1 on a resumed session whose `start()` failed: `shutdown()` goes out with no reader, as today (TVC:426); say so, or start first as the park does.
4. **CL-S4.** Section 9, summary 10: "steps 0 to 7 change no lifecycle" is not so. Step 2 rewrites `forget` and `removeOrphans` (they delete keys and records; `removeOrphans` runs at every launch, SD:63), step 4 decides which record a tap resumes and a swipe ends, for every record including the leftovers hidden today, step 6 gives sessions without a host a back button that ends them. All three are Opus with no hostile review, and the owner's first build follows step 6; only the `DebugLaunch` rule is read again, in step 9. Smallest change: the hostile reviewer reads the diffs of steps 2 and 4 before the step-6 build is offered, and step 4 gets a UI test with two hosts: End Session on the second host's row leaves the first host's `$$` and server.
5. **CL-S5.** Step 8: it brings the slot and "`endSession()` empties the slot first", but not what happens to a resumed coordinator taken from the slot before `attach`. Today that leave returns at TVC:404 and the record stays clean. If step 8 hands the taken coordinator to today's `end`, `shutdown()` marks a clean session that never started as ended (RC:647-663). Say: until step 9 a taken coordinator that was not attached is closed and nothing else; add the case to `testATakenCoordinatorIsNotClosedByTheQueue`.
6. **CL-S6.** Risk 2 and 10.3 item 3 (D5): input stranded by a park is also sent by "End Session" on that row. Section 6 d calls `start()`, which sends the stored input, and g ends the shell right after: a command typed just before "Hosts" can run at the moment he ends the session. One sentence in risk 2 and in 10.3.
7. **CL-S7.** 2.3 steps 2 and 4, W4, E1: (a) `.notResumable(.failed)` is also the answer for a session that was not started (RC:496), so that case waits 300 ms for nothing; `ParkPlan.after` has no row for `.closed` (RC:489: the event task's `finish` closed and forgot it first, so `readCounters()` finds no record) nor for `.datagramSentSinceExport`. Add the rows to the table and the test. (b) W4 says E1's ending "runs in its own background task"; today's `end` is a plain `Task` (TVC:415) and section 7 keeps its body: say the leave wraps it. (c) E1 clears "last looked at" at the leave, which comes after the pop; clear it in the alert's action.

### What held

Reasoned from the coordinator and the design; nothing was run. No sequence found that sends under a record older than what was sent, or opens a record twice. The park is `enterBackground()` then `close()` in the coordinator's own order (RC:415-423, 488-508, 704-712). `begin`'s `start()` against the park is safe in each order (RC:445-449). The second save after a failure does save again (RC:498-507). Step 1's `start()` and 6 f's save go through the gate, and G1 backs every G2 mistake. No size reaches another session. Replayed and fixed as written: LC-1, LC-3 (the ender), 4, 5, 6, 7, 9, 10, 11, 18; LC-2 and LC-12 are as D5 and D7 decide. Rules 2 and 4 have tests that fail. D1 is in one place (2.5), its one test named. Steps 8 to 12 have the session model and a review; steps 9 and 10 alone lose nothing today's app keeps. The TVC, RC, SD and LA lines I checked at b5aec27 are right. BRIEF.md is not modified.

### Not covered yet

Stopped by the usage rule at 51%, after the reading; no file was written. Read in full: CLAUDE.md, BRIEF.md, DESIGN.md, critique-lifecycle.md. Read at b5aec27: TVC 96-205 and 255-873, RC 86-115 and 280-757, SceneDelegate 18-169, SessionLauncher 20-245. Not read, so not checked: SessionFiles, SessionListViewController, SessionList, SceneSavePolicy, DebugLaunch, FileBackedGate, SessionRecord, MoshConnection, TransportCore, TVC 874-1076 (`BackgroundTask`, the resize code), the three maps, docs/RESUME.md, docs/PLAN.md section 3, any mosh line. Left: (1) LC-13: that a second `start()` completes the half-written counters change (FileBackedGate 237-249, 305-311); (2) LC-8, LC-16, LC-17 against their lines; (3) SceneSavePolicy behind G3 and my finding on the slot; (4) N1 to N4 against the gate and PLAN section 3; (5) the C and R numbers the design cites.

## The brief, the tests and the plan

**Finished:** no (stopped at the 50% usage line).

### Must fix

1. **CP-1.** Steps 4-6 vs 10 (order, nothing shown he later loses): from step 4 a host with sessions shows '+' (brief item 2: tap starts another) but its tap resumes the newest session until step 10, and step 6 is the owner's try build. He is shown the opposite of what '+' means. Smallest change: add hostPlus in step 10, or make the host tap a new session in step 4.
2. **CP-2.** Step 6 (files, other work): it changes 7 files, among them ResumeUITests.swift, which another workflow is editing right now (risk 11). Smallest change: say step 6 starts only after that work has landed on HEAD, and move the SSHBootstrap/LocalEcho helper switch into a step of its own (Opus) before step 6.
3. **CP-3.** Step 9 (size): 7 files, 2 UI tests plus a conditional third (testASwitchSendsNoResize and the size hold of 5.3 if WINCH prints) and a hostile review, in one agent. Smallest change: name the size hold as a separate step 9b, built only if the hand check fails.

### Should fix

1. **CP-S1.** Step 11, the D1 test: its control ('the park without its save: A falls back') does not exercise D1. Give it the control 'launchTarget answering none when the list was on screen', so a flip of his answer is the only thing it encodes.
2. **CP-S2.** Step 8: says 'behaviour same' but changes the host tap ('ignores ending') while step 4 still has host tap = resume newest; state what a host tap does on an 'Ending...' newest session between steps 8 and 10.
3. **CP-S3.** Status paragraph: says the deciding lines were read again and 'the design to build from', yet item 7/8 of 'Not yet verified' say most line numbers come from maps and the file was not read back. Put that caveat in Status.
4. **CP-S4.** Step 11: 5 UI tests, at the limit; 6 files. Consider moving testAFallbackHeLeftDoesNotComeBack (B3) to its own step.

### What held

Read in full: BRIEF.md (unchanged: git diff HEAD empty), DESIGN.md sections readings, 1-10 and Review status, critique-ui.md. From the text: brief items 1-10 and 'To confirm' all map to rows (H1-H5, S1-S11, B1-B8, X1, E1-E4, R1-R6, L1-L7, section 6); differences are listed as readings 1-9 or D1-D7. U1, U2, U3 (D6), U4 (reading 6), U5 (step 4), U6 (4.1), U7 (step 11 marker), U8 (4.4), U9 (reading 7), U10 (risk 9) are each answered in text. Step 1 hygiene comes before the first park (step 9). D1 is in one place (2.5) with its test marked.

### Not covered yet

Stopped by the usage rule (session 51%). Not done: lens item 4 (tooling: read scripts/mosh-spawner.py, scripts/sim-test.sh, App/IOSMoshUITests support for two hosts at once, kill/relaunch, server counting, a two-port range for step 13 and whether the spawner's sshd honours a per-host -p range); lens item 5 (15 citations of DESIGN.md against git show b5aec27, none checked); a replay of U-scenarios against code; a check that the 'no servers left' assertion at SessionListUITests.swift:282 still exists at HEAD. The must_fix list rests on the design text only.

# Second half (2026-11-21 17:10 UTC)

The findings above were answered in `DESIGN.md` by a fix round (its report first), then both
checks were finished and repeated. Neither approves yet: the lifecycle check has no must-fix
finding and one open text change (it blocks no step before 9); the plan check has four new
must-fix findings (steps 5b, 9, 12 and the evidence line of every step) and one still open (step
9 is too big). Steps 4 and 5 are not blocked. Ids continue: L2 = lifecycle, P2 = plan.

## What the fix round reported

Closed:

- CL-1: park calls try? start() for every attached restored coordinator, no startFailed flag (TVC:726-733 at b5aec27; RC:445 no-op); 2.3, step 9 test leaves mid-start, control = flag version
- CL-2: 5.3/7 now say end's refused branch changes; LeaveAction.afterStop (LC-14 pure test), idsToClear test, UI dot-cleared test; placed in new step 11b not 9: E3/E4/B3 keep a dirty record and the pre-step-11 launch takes the newest (LA:45-60)
- CP-1: '+' moved to step 10 with the new-session host tap; step 4 asserts no hostPlus
- CP-2: step 5b (helper, SSHBootstrap+LocalEcho); step 6 builds on HEAD after 376c583
- CP-3: size hold is step 9b, only if step 9's hand check prints a resize
- Should-fix CL-S1..S7, CP-S1..S4 all taken; 16 Review-status rows added; top Checks line and Status (CP-S3) rewritten; Not-yet-verified items 7-9 updated

Refuted:

- CL-S1 failure path partly: sceneResigned notes the resign whatever it answers (SceneSavePolicy.swift:15-18), so attach would save; the rule (isAttached vs held) and a test were still added
- CL-2 placement in step 9: refuted by LA:45-60 (newest-record launch until step 11); fix placed in step 11b

Not taken:

- CL-S3 rule-2 exception (E1 on a resumed session whose start() failed): stated as today's behaviour (TVC:426), not engineered (D7)

## Lifecycle and resume invariants, second half

**Approves:** no.

### Still open from the first half

1. **L2-O1.** CL-S7 (a), first clause only; its two new rows and (b), (c) are closed. 2.3 step 2: "the same answers from one that was not attached (RC:496) are final at once" never applies. RC:496 is reached only by a new coordinator (a restored one answers .clean, RC:495), and a new one is attached in the call that fills the slot (TVC:663-675). So an attached session whose start() has not run still waits 300 ms and retries for nothing: the first enterBackground() set inBackground (RC:494), begin's start() is then deferred (RC:446-449), and the record stays dirty. Harmless and close to unreachable; it blocks no step before 9. Smallest change: step 1 calls try? c.start() for every attached coordinator, not only a restored one (a new session is then started and saved clean, and the table row "start() has not run" goes); or strike the sentence and accept the wait.

### New must fix

(none)

### Should fix

1. **L2-S1.** Step 11b, "The owner can try a build: the feature", and 4.6. Until step 12, End Session on a parked row is VC:238-259: on hg stopOldServer answers .nothingToAsk (LA:159-162), mayForget is true, and the resumable session is forgotten with its shell left running, which 6 f calls wrong. Step 12 says so; "Tell him" does not, and no step says when 4.6's text "its shell and the programs in it stop" arrives. Smallest: add it to "Tell him" (or offer the build after step 12) and put 4.6's new alert text in step 12.
2. **L2-S2.** 2.3 rule 2, step 8. The isAttached list names five readers; TVC reads `coordinator` in more places. announceSize (TVC:986, HEAD 1024) is the one that bites: read as `held` on a resumed screen, the 100 ms timer fires before viewDidAppear (animated push) and sets announcedSize, the consumer drops the .resize (not attached), and attach then announces nothing. After a rotation or zoom between park and unpark the server keeps the old size. UI tests stay green (animations off: attach comes first). Smallest: say every read of `coordinator` except 5.3's decision and 5.6 is isAttached, and name announceSize, liveSessionID (176) and openSession's guard (637).
3. **L2-S3.** Step 2 and section 7, DebugLaunch (LC-16 against its lines). Step 2 names SD:71-73, 101 and TVC:486-488, but the fallback request is also read at TVC:547 (HEAD 585, runtimeFallback). If "handed out once" is built only at the named places, a run-time fallback of a debug session makes a second record under the fallback key from sequence 0: N1's shape, debug builds only, as today. Smallest: step 9's review, which reads the rule again, checks that DebugLaunch.fallbackRequest has no reader outside the rule.
4. **L2-S4.** Summary 10, section 7, step 6. The hostile review of the diffs of steps 2 and 4 is tied to the offer of the step-6 build. If no build is offered, steps 8 to 12 are built on forget and removeOrphans (run at every launch) and on step 4's choice of record, unreviewed. Smallest: "before step 8 starts, and before any build is offered".
5. **L2-S5.** 3.3 E4, "Record safety" and "as E3". shutdown() is refused for storage only when markDirty has to write, that is while the record is still clean (a resumed session whose start() failed, or a return to the foreground whose dirty mark failed). After .hostNotReached the kept record is therefore resumable, not "dirty", and the row is not "Could not be resumed". shutdown() is also false when the session is already over (MoshConnection.swift:237-241); the record is then ended. Smallest: the cell says "kept as its files say (resumable, ended or dirty), without the dot; never resumed by itself".
6. **L2-S6.** 2.3 step 1 (CL-1's fix). If a .background precedes the park in the queue (the scene resigns during the pop, before viewDidDisappear), the coordinator is inBackground and the park's start() is deferred (RC:446-449). A start() that failed half way is then not completed and the park answers .clean from memory: LC-13's outcome. It needs a storage failure and a resign inside the pop (D7). Smallest: say so in the table row "start() failed again".
7. **L2-S7.** Steps 10, 11, 11b. (a) Neither step 10 nor 11 lists the file where a tap drops the launch's wait (4.5, 2.2): step 11 lacks SessionListViewController.swift. (b) No step says where finish and abandon() become tracked releases (G2), which 11b's E3 awaits; no test fails without it. (c) testAStopThatDidNotReachTheHostKeepsTheRecord is pure and passes while end's refused branch still forgets. Smallest for (c): 11b's evidence shows that SessionFiles.forget in end and endDuringFallback is reached only through afterStop.
8. **L2-S8.** 3.3 E1 and section 7, rule 4. End Session from the menu on a session with no contact (opened without network, "Last contact" showing) spends the one shutdown try (C7, R16). On hg the server can then never be ended from the phone, while the same request on its row (6 e, f) keeps the session. That is today's behaviour for back. Smallest: one sentence in E1 or the risks (D7), or E1 without contact runs the ender's stages e to h.

### What held

Read, nothing run: FileBackedGate, ResumeCoordinator, SessionRecord, SessionStore, Counters, SceneSavePolicy, DebugLaunch, SceneDelegate, SessionLauncher, SessionFiles, the list, TVC 90-880 and 960-1076, the cited lines of MoshConnection, TransportCore, mosh, PLAN section 3, RESUME's R and C tables. Closed: CL-1 (a second start() repeats beginSending: limits not raised twice, the failed slot rewritten with the same generation; FileBackedGate 237-249, 292-311), CL-2 (3.3, 5.3, 7 agree; 11b instead of 9 is sound, LA:45-60), CL-S1 (the policy notes the resign whatever it answers), CL-S2 to S6, S7 (b), (c). CL-S3's exception not taken: sound. LC-8 and LC-17 match their lines; LC-16 except TVC:547. Every cited C and R number says what the design says. G1 is flock on a fresh descriptor, so a second open in one process is refused. No sequence found that sends under an older saved state or opens a record twice. Steps 4 to 12 alone lose nothing today's app keeps; 8 to 12 and 11b have the session model and a review.

### Not covered

Nothing in this lens. approve is false only because of the one still-open item: a text change in 2.3 that touches no step before 9. No finding blocks steps 4 to 7; should-fix 4 (when steps 2 and 4 are reviewed) is the only one that concerns them. Not read: the three maps, MoshSession.swift, TransportCore beyond the cited lines. Nothing was built or run, and I wrote no file. The plan half's open items (test tooling for two hosts and a two-port range, its 15 citations against b5aec27) are outside this lens and still unchecked.

## The brief, the tests and the plan, second half

**Approves:** no.

### Still open from the first half

1. **P2-O1.** CP-3 (step 9, size), partly closed: 9b is split out, but step 9 still has 7 files (SessionQueue, LeaveAction, TVC, UITestSupport, LeaveActionTests, SessionQueueTests, SwitchUITests), 5 unit tests, 2 UI tests, two checks by hand and a hostile review in one agent. Smallest change: move the pure LeaveAction.swift (decide, ParkPlan.after) and testTheLeaveDecisions and testOnlyAnEndedRecordIsForgottenByThePark into a step 8b of their own (session model, no behaviour change) before step 9.

### New must fix

1. **P2-M1.** Steps 9, 11, 12 (section 8, U1 replay): openSession and startSavedSession are methods of `final class SessionListUITests` (HEAD SessionListUITests.swift:9, 279-331), and step 1's teardown is registered only there. The new files SwitchUITests, LaunchUITests and EndSessionUITests cannot call them. XCTest runs classes in alphabetical order, so EndSessionUITests and LaunchUITests run before LocalEchoUITests:263, ResumeUITests (its own 'no servers left' check) and SSHBootstrapUITests:62, and the parked servers they leave break those waits for sshdServers()==[]. Smallest change: step 5b also moves openSession, startSavedSession and relaunchShowingTheList, with the teardown, into the shared `extension XCTestCase` in SessionUITests.swift.
2. **P2-M2.** Section 9, the evidence of every step: '/sshd/servers empty after the run' cannot be read. sim-test.sh's EXIT trap (line 66) stops the spawner, whose `finally` (mosh-spawner.py:638-641) kills the servers, and nothing asks /sshd/servers before that. Smallest change: sim-test.sh prints the /sshd/servers answer before the key check (one tooling line, in step 4 or 5b), and the evidence names that line. Steps 1-3, which are built from the old text, log it as not available.
3. **P2-M3.** Step 12, testEndSessionWhenTheServerIsGoneKeepsTheSession: the session kind is not named. For a host session with a known pid, 6 f goes on to h: stopOldServer finds the server gone (.notThere), mayForget is true (LA:238-244), and the record is forgotten, so the row goes instead of 'Session Not Ended' and a resumable row. Only a no-pid session is kept. The control's predicted result ('the row turns Ended') is wrong for both kinds, because after g, h forgets. Smallest change: name a -debugMosh session whose server is stopped with /stop, and give the control's failing check as 'the row goes'.
4. **P2-M4.** Step 9 (and the choice of 9b): nobody can do the checks 'by hand on the simulator with animations on' (B6, the WINCH trap). No session sits on charlie (CLAUDE.md), -uiTesting turns animations off (SceneDelegate.swift:23 at HEAD), and screenText exists only with -uiTesting. Smallest change: say how the agent runs them, either with a launch flag that keeps animations on in a UI-test launch (UITestSupport.swift is already in step 9) or with a launch without -uiTesting read through simctl screenshots. If neither is possible, 9b is built.

### Should fix

1. **P2-S1.** Step 9 UI tests (testBackParks..., testSwitchingTenTimes...): until step 10, a tap during a park meets .inUse, which the step itself says. Each tap must first wait for the row's value `resumable` (the park has closed). Say so, or the ten switches will flake.
2. **P2-S2.** Step 11, testAKillWithTheListOnScreenGoesIntoTheDottedSession: wait for the `park-clean` mark before Home and terminate. A kill in the middle of the park leaves the record dirty and the launch falls back. This is the D1 test, so it must not flake.
3. **P2-S3.** Step 4 test: openSession wipes sessions and hosts (-uiTestingResetSessions and -uiTestingReset, SessionListUITests:284). The second host therefore needs a new helper that adds a host on the same 127.0.0.1:port without the reset and without the Trust prompt (known hosts are keyed by host:port). Name that helper in step 4.
4. **P2-S4.** Step 10, testASilentServerAtASwitch: it would already pass at step 9, and its control (leaving out the SIGCONT) changes the test, not the app. The stored screen already shows the same $$. Assert a new command's output after the SIGCONT, and move the test to step 9 or name a control in the app. Step 11's testACrashOnScreen... has the same problem: 'without -debugCrashAfter' is a test change.
5. **P2-S5.** 2.3 step 1, reading 9, D5: when an earlier start failed, the park's second start() can now succeed. beginSending, the first datagram and the stored input then go out at the park, so 'the park sends nothing' is false in that case. One sentence.
6. **P2-S6.** Citations: about 40 checked at b5aec27 and in mosh (TVC, RC, LA, SD, SF, VC, SL, SceneSavePolicy, DebugLaunch, UITestSupport, spawner, SnapshotCodec, SessionStore, TransportCore, MoshConnection, MoshSession:167, RESUME.md:293, network.cc, mosh-server.cc, terminaldisplay.cc, transportsender*.h). One is wrong: 2.3 cites MoshConnection.swift:196-213 for 'goes out at the next start() exactly once', but those lines are quiesceAfterSend, a test seam. sim-test.sh:60-64 is where the spawner starts; the kill is the trap at line 66.
7. **P2-S7.** Step 6 note to the owner: also tell him what is temporary (back still ends a session, a host tap resumes the newest session, there is no '+' yet).
8. **P2-S8.** 4.4 onChange: SessionActivity comes in step 8, but step 5 builds the refresh. Name step 8 as the step that wires it.
9. **P2-S9.** Status says 'none refuted', but the CL-S1 row ('the outcome does not happen') and the owner's own report count CL-S1 and the CL-2 placement as refuted. Make the counts agree.

### What held

["Steps 0-3 have the same text as HEAD (Step 0 to Step 4 extracted and diffed), and no change touches the sections they build on. BRIEF.md is unmodified. CP-1 ('+' in step 10, and step 4 asserts no hostPlus), CP-2 (5b, then 6 on HEAD), CP-S1, CP-S2, CP-S3 and CP-S4 are closed, and no step order breaks. The tooling can do what the design asks: two hosts on one sshd, a kill, a crash, a relaunch, server counts, STOP/CONT. The sshd runs the app's per-host -p; only servers() matches the exact range, and step 13's change also covers /stop and /signal. The assertion at SessionListUITests.swift:282 is still at HEAD. The unit-test seams are public and already used by the app tests. U2 to U10 hold."]

### Not covered

Not checked: the lifecycle parts (CL lens), that TerminalSerialization stores windowTitle (Framebuffer has it), the HostUITests reads in step 4, and the scheme's test order (alphabetical is assumed, the default). No file was written.

# Verification of the second fix round (2026-11-21 17:35 UTC)

A fix round answered the second half in `DESIGN.md`; a verifying agent then read the change.
It did not approve: two findings partly open, two things the round broke, four minor notes. All
eight were then corrected in `DESIGN.md` (rows V-1 to V-8 of its "Review status"); with that the
design is the one to build from. Steps 8 to 12 still get their hostile reviews when built.

## What the second fix round reported

Closed:

- P2-M1: step 5b moves openSession, startSavedSession, relaunchShowingTheList, step 4's new helper and the teardown into the shared extension XCTestCase (HEAD SessionListUITests 296-357). They read the screen through a new screenRows(_:), because Appearance, BannerLayout and Resume UITests each declare rows(_:). Section 8 states the rule.
- P2-M2: confirmed at sim-test.sh:66 and spawner 636-641. Step 5b adds one sim-test.sh line, '== servers left after the run:' plus the /sshd/servers answer, before the key check. Every step's evidence names it from 5b on; steps 0-5 log it as not available yet.
- P2-M3: step 12's test uses a -debugMosh session (no pid) whose server is stopped with /stop. Control: the row goes.
- P2-M4: step 9 gets UI tests testABackSwipeLetGoHalfWayParksNothing and testASwitchSendsNoResize, run with -uiTestingAnimations 1 (read in UITestSupport and SceneDelegate). The decider is the last assertion, XCTAssertFalse(rows.contains("resized")). If it fails, it is wrapped in XCTExpectFailure and 9b is built.
- P2-O1: new step 8b (LeaveAction.decide, ParkPlan.after, two unit tests).
- L2-O1: sentence struck, the 300 ms wait accepted. The other option would not help: the park's start() is deferred too (RC:446-449).
- L2-S1..S8 and P2-S1..S9: all taken. Review status has 23 new rows (68 in all: 64 accepted, 4 decided). Status and top line rewritten.

Refuted:

- L2-O1, first remedy only: having the park call start() for every attached coordinator would not start a new session whose start() an earlier resign deferred. inBackground stays set (RC:494), so the park's start() is deferred too (RC:446-449). The second remedy was taken instead.

Not taken:

- Step 5's evidence line 'by hand on the simulator, a swipe left open survives a refresh' has the same flaw as P2-M4: nobody sits at the simulator. The constraint allowed only P2-S8 in step 5, so the step text is unchanged. Risk 8 now says step 5's agent reports that check as not done. The owner or orchestrator may want it turned into a UI test.

## What the verification found

Still open:

- P2-M4 (partly): the deciding test can pass with nothing tested. If the simulator has a hardware keyboard (InputUITests.swift:8-9 at HEAD hints it can), no software keyboard is up, the back changes no size, the test passes, 9b is skipped, and its control (endEditing) cannot fail either. The old text had a rule for a control that does not fail; the new one dropped it. Fix: assert app.keyboards.count > 0 before the back, or say 'control does not fail: 9b is built'.
- P2-M4/9b: step 9 says '9b is built' when the test cannot be made to finish, but 9b's header says 'if and only if the deciding assertion failed', and 9b's evidence (that test passed by name) cannot be met in that case. Make the two agree.

Broken by the round:

- Section 8 now says every UI test that starts a session on the spawner's sshd does so through the shared helpers, 'whatever its class'. At HEAD that is false: ResumeUITests:296 and 357, LocalEchoUITests:216 and SSHBootstrapUITests:12 start their own, and step 5b's files do not move them. Section 8 and step 5b disagree. Fix: 'every new UI test'.
- Step 5b evidence: git grep -n 'func openSession' also matches openSessionOnAnotherHost, so it finds two lines and 'finds it once' fails as written. Use 'func openSession('.

Notes:

Closed and sound: L2-O1 (the refutation holds: RC:490-496 sets inBackground, so start() is deferred at RC:446-449), L2-S1 to S8, P2-O1 (8b needs only step 8), P2-M1 (helpers at HEAD 296-352; extension rows clash is real), P2-M2 (trap :66, finally 636-641, TEST_RUNNER_MOSH_SPAWNER_URL exists), P2-M3 (played: e then f keeps; control g then h gives .nothingToAsk, forget, row goes), P2-S1 to S9 (citations checked, LA:47-48 sorts by createdAt so step 11's crash control fails as claimed; KnownHosts is keyed by host and port). Steps 0-3 are byte-identical; steps 4 and 5 differ only by P2-S3 and P2-S8. BRIEF diff is empty. Review status: 68 rows, 64 accepted, 4 decided, which matches Status. Minor: the rule-2 sentence 'except the two named below:' reads as if the list after the colon were the exceptions. Step 12's note calls the host test a server-gone case; it is not. openSession's guard checks for an empty slot (held), not isAttached; give that to step 8's review. Step 5's hand check is still undoable: the orchestrator decides.
