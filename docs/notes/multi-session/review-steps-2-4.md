# Hostile review of the diffs of steps 2 and 4

**2026-11-22 00:10 UTC, session model, read from `git show 47f2822` and `git show 7ffb6c4`; nothing was run.**
Required by `DESIGN.md` section 7 before step 8 starts and before any build is offered to the owner.
**Not approved: one must-fix finding.** Word for word below. Ids: R24-M = must fix, R24-S = should fix.

## Must fix

1. **R24-M1.** App/IOSMosh/SessionListViewController.swift:431-462 with 411-421 (step 4): a sideways swipe on a row that has no actions in that direction is taken as a tap. The builder saw it and dropped the check (docs/MAC.md:1866: swipeRight() on a host row "was taken as a tap and opened its session"). Step 4 made two such cases: a right swipe on a host row, where End Session and Forget were until now, and a left swipe on a session row (the iOS direction for Delete). Sequence: he swipes to remove a row and it opens instead: a resumable session is resumed, a "Cannot be resumed" row logs in over SSH and starts a new server, a host row opens its newest session or starts one. Until step 9 the only way out is back, which ends that session. Seen under XCUITest only, not tried by hand. Smallest change: give both row kinds actions in both directions (session rows the same two trailing, host rows Edit leading), or cancel the touch after sideways movement; put the dropped check back as a UI test for both row kinds.

## Should fix

1. **R24-S1.** SessionListViewController.swift:117-128 and 186-196: a host tap does nothing while End Session runs on the host's newest record, also when that record already reads "ended". Before step 4 that tap started a new session (ended was tested before the ending set), and step 8's text counts on it. Change: test the file state for ended before the "ending" mark.
2. **R24-S2.** SessionFiles.swift:38-43, 63-68: loadFile answers "empty" for a file that exists but cannot be read or decoded, and update writes that back: every link is lost, sessions move to "Without a Saved Host", and a dead one is then forgotten on a tap or at launch instead of getting a new session. The pattern is older; step 2 adds a write at every attach. Change: only "no such file" is empty (as HostStore.load does); otherwise skip the write and log.
3. **R24-S3.** SessionFiles.swift:166-185: removeOrphans returns before it visits "last looked at" when the Keychain cannot be listed, so the id of a forgotten record can survive a launch. Step 11's launchTarget does not check that the record exists; it must. Also fileLock is held across every SecItemDelete: collect the ids under the lock, delete the keys after it.
4. **R24-S4.** DebugLaunch.swift:56-66: the guard compares address text and port, not the key. Still handed out: the same server under another spelling (localhost, the Mac's LAN address; the test asserts that another address passes), a stored record whose meta cannot be read (it "names none"), and a server whose record was forgotten while it still runs. Each is a second record under a used key from sequence 0. Change: refuse when a stored record's Keychain key equals the request's key or a meta is unreadable; hand -debugMosh out once per process too. Debug builds only.
5. **R24-S5.** SessionListViewController.swift:209-240: from a session row, today's openRecord can start a new session where 3.2 says none: the cold start finds the record ended (229-230), not a record (224-225), or forgotten within the last second (no key, no directory: SessionLauncher.swift:81-90 answers a fallback that wants a new session, line 232 pushes it). Step 10's open(row) must not inherit this.
6. **R24-S6.** SessionListViewController.swift:248-287, on the owner's host (no server pid in meta): End Session on any row answers nothingToAsk and forgets the record without stopping anything, while the alert says the server is stopped. Older than these commits, but now on every row, and rows are what he will clean up in the step 6 build. Change: say so in the alert when serverIdentity(meta) is nil, or put it in the step 6 note.
7. **R24-S7.** Smaller: no test has two sessions under one host (End Session or Forget on row 1 leaves row 2; a host tap opens row 2). "Session Not Ended" is lost when the list is covered or another alert is up (line 285). With equal createdAt the host tap takes the smallest id, the bottom row is the largest. Delete on a host row is a full swipe without confirmation and cuts every session of that host off from it.

## What held

Read from git show; nothing run. forget and removeOrphans delete nothing today's app keeps: a key or link goes only when lstat says ENOENT for the record directory, any other error leaves it; a held record cannot be deleted (flock); key, link and create are one main-thread stretch with no await, and removeOrphans runs on main only. Order: record, key, link. A file without lastLookedAt decodes; the orphan test does not read the links file. Every read-change-write of session-hosts.json is under fileLock, with no nested lock and nothing suspended under it. lastLookedAt is written only in attach and cleared by forget and removeOrphans, which is all 2.5 asks of step 2. DebugLaunch.fallbackRequest is gone; all three callers take through the hand-out. Taps and swipes carry the row's own record by value, so a refresh cannot redirect them. End Session kills by that record's pid, start time, user and command, so another session of the host is not hit. A host tap is today's open for the newest record.

## Not covered

Nothing was built or run, and no file was changed. Open: a hand check of the sideways swipe with a finger or mouse (the must-fix); whether a reloadData during a touch drops the tap or moves it to another row (I assumed it drops it; step 5's held reload covers it either way); the UI tests and unit tests were read, not run; step 3's SessionList.rows was read only where step 4 uses it. Not checkable from the repository: that the Dev app and the TestFlight app share no Keychain group (the signing files are on charlie). If they did, removeOrphans in one would delete the other's session keys at launch, so it is worth one look at the entitlements.

## What is done with it

- R24-M1, R24-S1 and R24-S2 are corrected in a step of their own ("step 4c") before the build after step 6 is
  offered; the reviewer then reads that diff.
- R24-S3 binds step 11 (`launchTarget` checks that the record exists) and R24-S5 binds step 10 (`open(row)` starts
  no new session for an ended or missing record): the agents of those steps read this file.
- R24-S4 (debug builds only) is read again by the hostile review of step 9, which re-reads the `DebugLaunch` rule.
- R24-S6 goes into the note to the owner for the step-6 build: on a host where the app does not know the
  server's pid, End Session on a row forgets the session without stopping its server, until step 12.
- R24-S7 is left as it is (older behaviour, nothing he asked to change).

# Step 6, first check (2026-11-22 01:00 UTC): not approved

Step 6 is built and NOT committed (its files are in the working tree). The checking agent refused it:

- The evidence section 9 asks for is missing. The only whole-suite run, out/yellow/ms/step6/full.log, ends with 'Executed 57 tests, with 1 failure' and TEST EXECUTE FAILED. The failing test, LocalEchoUITests.testAPasteReachesTheSessionAsOneInput, runs in a -debugMosh* session through InputSession.launch. That is exactly the kind of session step 6 changed: it is now pushed over the list and has a back button and the new menu. So the report's 'outside the step' is not shown. Counting my run, it passed 26 of 28 times with step 6 and 11 of 11 without.
- The run did not come after the last change to App/. TerminalViewController.swift and SceneDelegate.swift were last written at 00:51:39 UTC, when the HEAD-swap paste runs were undone. full.log is from 00:42:18. The MAC.md entry's 'after the last change' cannot be checked.
- New bug the step does not name: the '…' menu works while a session is still connecting. If 'End Session?' is up when the connect needs a prompt (Unknown Host Key, password, the key-install offer), ask() calls present() while an alert is already shown. UIKit refuses that, so the continuation never resumes. Cancel then leaves the terminal stuck on 'Connecting…' for good. Fix: turn the menu off while a prompt can come, or have ask() wait for or replace the alert that is up.

What the builder reported about the failing test:

- LocalEchoUITests.testAPasteReachesTheSessionAsOneInput (outside the step) failed in the full run at LocalEchoUITests.swift:208, timed out waiting for "q", then one input of 300 bytes. Last inputs ended 300,1: the Paste key's input and the q arrived, but the Cmd-V paste did not. Alone 3 times with step 6's code: pass, fail at the same check, pass. With HEAD's TVC and SceneDelegate 3 times: 3 passes. Then -test-iterations 8 with each version: 8 of 8 passed both times. Totals: 10 of 12 passed with step 6, 11 of 11 without. Cause not established. Step 6 changes nothing on the Cmd-V path, but a debug session now has a back button and the menu item in its navigation bar.
