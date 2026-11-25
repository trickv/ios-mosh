# Critique of DESIGN.md: the screen, the tests and the plan

**Coverage (2026-11-21):** written under the usage rule (session at 40-42% when started), so it is
deliberately short. Covered: brief rows 1-10 against the design; the owner's day; the list rows;
the UI-test tooling (spawner, server counting, leftovers); the unit-test split; step sizes.
Not covered: a line-by-line check of every TVC/VC/SD citation in DESIGN.md; the lifecycle and
resume invariants (the other critique's lens); the preview cache under real file timestamps.
Code facts are from `main` at `b5aec27`; "verified" means read in this pass.

| id | severity | section | one line |
|---|---|---|---|
| U1 | major | 8.2, 8.3, 9 | Parked sessions leave mosh-servers on the spawner's sshd; dropping the "no servers before" check lets them pile up until the 100-port range is full and every test meets H3 |
| U2 | major | 8.1 | "The park itself" and `SessionPreview.read` need a real mosh-server, but 8.1 is "no server" and no app unit test has a spawner |
| U3 | major | 9 | Step 8 is too big for one agent under the 45/50% rule |
| U4 | major | 2.5, readings | The dot is not moved after the dotted session ends: an unlisted reading of brief item 8 |
| U5 | minor | 9 step 3 | "What a tap does is as today" is undefined for the new session rows |
| U6 | minor | 4.1, 8.2 | `session-<host>-<n>` renumbers when a row goes; a test can tap the wrong session |
| U7 | minor | 8.2 | The test "Kill while the list is on screen" encodes the answer to question 1 before he gives it |
| U8 | minor | 4.4 | An open swipe or alert freezes every row, including "Saving…" and "Ending…" |
| U9 | minor | 3.4 | The host row loses its leading swipe and its state line; brief item 1 says "a row as today" |
| U10 | doc | 4.2, risk 9 | With a plain shell, every preview is the prompt line; say so to the owner with the tmux note |

## U1. Servers left by parked sessions fill the test sshd's port range (major, verified in part)

**Design text:** 8.3 "`openSession` ... loses its 'no server before, one after' assertions in favour
of the set of new pids"; 8.2 tests park sessions and leave them (two sessions, two hosts,
switching, kills, preview) without ending them.

**Code:** `App/IOSMoshUITests/SessionListUITests.swift:282`:
`XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run")`, which
holds today because the tests end sessions with back. `scripts/mosh-spawner.py:340`
`SSHD_UDP_PORTS = "62700:62799"`; `servers()` at 418-427 lists every `mosh-server new` of the
user with that range; the only removal is `/sshd/stop?pid=N` (562). `-uiTestingResetSessions`
deletes records and keys, not servers (SessionFiles.swift:122-136). Not verified: whether
`stop()` (429) takes the detached mosh-servers with the sshd (it terminates `self.process`).

**Scenario:** each of the ~15 new tests leaves 1-3 parked servers. A mosh-server whose client went
quiet runs on (no network timeout set by the app). After 3-5 suite runs on charlie, 100 servers
hold the range: every `openSession` gets "Failed binding", H3's banner, and the whole suite is
red for a reason no step introduced. Before that, "the set of new pids" is computed against a
growing set and a stale server of an earlier run can match.

**Failing test idea:** run the "Two sessions on one host" test 60 times in a row; it fails at the
50th with H3.

**Smallest change:** keep the assertion and clean up instead: a `tearDown` (or a spawner
`/sshd/stopall`, a few lines in the same file step 10 touches) that SIGKILLs every listed server,
used by every test that parks. Move that to step 7, before the first test that parks.

## U2. Two "unit" tests need a server (major, verified)

**Design text:** 8.1 "Unit tests (`App/IOSMoshTests`, no server)": "The park itself: create,
`start()`, the app's park ... a cold start resumes; three times"; "Not yet verified" 1 requires it
to "go through the screen's real queue and consumer"; `SessionPreview.read`: "a record saved by a
real coordinator".

**Code:** no file in `App/IOSMoshTests` uses the spawner (grep of `spawner|Spawner`: none).
`start()` sends and the park's save needs a started session (DESIGN 2.3 table, row 4: unstarted
gives `.notResumable`).

**Scenario:** the step-8 agent writes the park test with no server; `start()` has nothing to talk
to, or the test calls `enterBackground()`/`close()` directly to make it pass, which is exactly
what "Not yet verified" 1 forbids. The AsyncStream ordering then goes untested.

**Smallest change:** say where they run: either a fake `DatagramTransport` in the app test target
(does one exist? not checked) or move both to UI tests / `Tests/MoshResumeTests` (the coordinator
part already exists at `ResumeCoordinatorTests.swift:601-632` per the design). State which.

## U3. Step 8 is too big (major, plan)

**Design text:** step 8: `.park`, `leaveScreen`, `LeaveAction`, settle on every tap, host tap always
new, launch without an id, and six UI tests (two sessions, two hosts, switching, kills, double tap,
silent server), plus a hostile review before push.

**Scenario:** at 30-90 s per UI test (risk 10) and a full sim suite per step (section 9), plus the
negative controls of 8.2 ("the change is undone once"), one agent cannot finish this inside the
45% start / 50% stop rule (CLAUDE.md "Usage"); it stops mid-step with nothing green to commit,
since step 8 alone is the feature.

**Smallest change:** split 8 into 8a (`SessionSlot` consumer parks on leave and `LeaveAction`,
proven by "Two sessions on one host" and "Switching"), 8b (taps settle, host tap new, double tap),
8c (launch target and the three kill tests). Each builds and passes alone; 8a is the one the
hostile review must see.

## U4. The dot after the dotted session ends (major, owner-facing)

**Design text:** 2.5 "It is not moved to another session: after the last looked-at session ended
there is no dot, and the launch shows the list."

**Brief:** item 8 "A green dot marks the session he looked at last." The readings section lists
five readings; this is not among them.

**Scenario:** he works in A, then B, types `exit` in B. Back on the list A is the session he
looked at last of those that exist, but no row has a dot; next launch he gets the list, not A.
That may be right, but it is a choice he did not make.

**Failing test idea:** "Only parked ones" in 8.2 already asserts "no dot": it would fail under the
other reading, so the test exists; the question does not.

**Smallest change:** add it as reading 6 and question 4 ("after the dotted session ends, should
the dot move to the one you used before it?"). No code change unless he says yes (then a short
history instead of one id).

## U5. Step 3 tap behaviour undefined (minor, verified)

Step 3: "the screen changes; what a tap does is as today". Today `open(host:session:)`
(SessionListViewController.swift:168-178) takes a tap on the *host* row and resumes its record.
In step 3 there are session rows that today's code has no answer for, and a host tap that still
resumes. Say it: in step 3 a session row calls `openRecord`, a host row calls today's `open`.

## U6. Row numbers shift (minor)

4.1: `session-<host display name>-<n>`, "`n` counting from 1 in row order". After row 1 ends, B is
`-1`. A test that keeps an identifier across an `exit` taps B believing it is C. Use `n` in tests
only right after a fresh list read, or publish the record id as the row's accessibility hint.

## U7. A test answers question 1 (minor)

"Kill while the list is on screen ... the launch goes into A (question 1)". Writing the test is
fine; mark it "follows the answer to question 1" so the step agent does not treat it as approved.

## U8. Frozen list while a swipe is open (minor)

4.4: "no reload while a swipe is open or one of the list's alerts is up". With a swipe left open on
row C, A's "Saving…" and an R1 "Ending…" stay on screen indefinitely; a tap on A still works (it is
decided by the coordinator), so this is cosmetic. Reload the changed rows with
`reconfigureRows(at:)` (keeps the swipe) instead of holding everything.

## U9. Host row changed beyond the brief (minor)

3.4 drops the host row's leading swipe and 4.1 its state line; brief item 1 "Each saved host is a
row as today". The swipe moves to the session row, which is item 5, so this follows; say it in the
readings so he is not surprised (`leadingSwipeActionsConfigurationForRowAt`, VC:392).

## U10. Previews of plain shells (doc)

4.2: the last non-empty line of a shell at rest is its prompt, so two sessions on one host read the
same (`trick@hg:~$`). Brief item 7 asked for exactly that, so no design change; tell him with risk 9
so it is not reported as a bug.

## What held

- Brief rows 1-6 and 10 map to table rows H1-H4, S1-S11, B1-B6, X1, E1-E4, R1-R6 with nothing
  added; "End Session" sits behind "…", Ctrl-D returns to the list (X1), back parks (B1).
- The preview needs no key: `SnapshotCodec.decode(_:expecting:)` takes only the `SessionID`
  (`Sources/MoshResume/SnapshotCodec.swift:143-146`), and the id is the directory name; a wrong
  file throws `.wrongSession`, which 4.2 maps to "no preview". Rows are cheap with the cache.
- The double-tap guard has a backstop today: a second `coldStart` on a locked record answers
  `.retryLater`, an alert (VC:190-193), never a second coordinator.
- The spawner can already run several servers on one sshd and stop or SIGSTOP one by pid
  (`mosh-spawner.py:54-59`, 562-571), so the switching, kill and silent-server tests are runnable;
  `sim-test.sh` takes `-only-testing:` (`scripts/sim-test.sh:5`), so a step can run its tests alone.
- The night in the pocket: with a terminal on screen it is today's W1/W5; with the list on screen
  nothing is open (W2). A wrong tap costs one resume and one park, both clean.
