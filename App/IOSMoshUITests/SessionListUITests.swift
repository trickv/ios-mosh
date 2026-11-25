import XCTest

/// M8 on the simulator (docs/PLAN.md, Design 4 "Session list"): the host list shows each host's
/// sessions as rows under it (docs/notes/multi-session/DESIGN.md 4.1, step 4), each with its
/// state, and a tap on a session row opens it through the coordinator. A session row is
/// `session-<host>-<n>`, numbered from 1 under its host; its value is the state. A host row's
/// value is `none` without sessions and `sessions=N` with.
///
/// A launch resumes the newest record by itself, so these tests relaunch with
/// `-uiTestingSkipColdStart 1`: the host list comes up with the record still on disk, as for a
/// record that the launch did not take (an older one, review M6-5; or "try again later").
final class SessionListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Saved in the background, the app killed: the list shows the host's session as
    /// resumable; a tap resumes it (same `$$`, same server, no fallback banner).
    func testASavedSessionIsListedAsResumableAndATapResumesIt() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "resume")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        let row = app.cells["session-resume-1"]
        waitFor(row.exists && (row.value as? String) == "resumable",
                "the row says resumable (is \(row.value ?? "nil"))", timeout: 10)
        // A resumable row's state line is "last used …" (DESIGN.md 4.3, step 5).
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS 'last used'")).firstMatch.exists,
                      "the state is shown in the row")
        attachScreenshot(app, "list-resumable")

        row.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == saved.pidLine }.count >= 2,
                "the same $$ (\(saved.pidLine)):\n\(rows(screen).joined(separator: "\n"))", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the same server")

        // Ending it from the terminal; the host has no session afterwards.
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15)
        let host = app.cells["host-resume"]
        waitFor((host.value as? String) == "none", "no session left (is \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(row.exists, "no session row")
    }

    /// "End Session" on a stored session whose server runs: the server is stopped over SSH
    /// after the identity check (its pid is no longer a running mosh-server), the row has no
    /// session, and the next normal launch resumes nothing.
    func testEndSessionStopsTheServerAndRemovesTheSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "end")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        let row = app.cells["session-end-1"]
        waitFor(row.exists && (row.value as? String) == "resumable", "the row says resumable", timeout: 10)
        swipeAction(app, row: row, "End Session")
        let alert = app.alerts["End Session?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirmation")
        attachScreenshot(app, "end-session-confirm")
        alert.buttons["End Session"].tap()
        waitFor((try? spawner.sshdServers()).map { !$0.contains(saved.servers[0]) } == true,
                "the old server \(saved.servers[0]) stopped (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)
        waitFor((app.cells["host-end"].value as? String) == "none", "the host has no session", timeout: 10)
        XCTAssertFalse(row.exists, "no session row")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")

        app.terminate()
        relaunchNormally(app, spawner: spawner)
    }

    /// "Forget" removes the session from the phone without contacting the host: the row has no
    /// session, the next normal launch resumes nothing, and the server still runs.
    func testForgetRemovesTheSessionAndLeavesTheServerRunning() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "forget")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        let row = app.cells["session-forget-1"]
        waitFor(row.exists && (row.value as? String) == "resumable", "the row says resumable", timeout: 10)
        swipeAction(app, row: row, "Forget")
        let alert = app.alerts["Forget Session?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirmation")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keeps running'")).firstMatch.exists,
                      "the confirmation says the server keeps running")
        attachScreenshot(app, "forget-confirm")
        alert.buttons["Forget"].tap()
        waitFor((app.cells["host-forget"].value as? String) == "none", "the host has no session", timeout: 10)
        XCTAssertFalse(row.exists, "no session row")

        app.terminate()
        relaunchNormally(app, spawner: spawner)
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the server was not contacted and still runs")
    }

    /// "End Session" when the host cannot be reached: the server's pid and start time are kept
    /// (review M6-4), so the session stays listed as it was, and the user is told why. A parked row
    /// ends through mosh (DESIGN.md section 6, step 12), so the server is stopped too (SIGSTOP, as
    /// behind a dead network): no contact in 10 s, no shutdown spent (e), the session saved clean
    /// again (f), then the identity-checked kill over SSH (h), which cannot reach the host. Running
    /// again (SIGCONT), the server is still there: nothing was asked of it.
    func testEndSessionThatCannotReachTheHostKeepsTheSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "away")
        let pid = saved.servers[0]
        defer {
            _ = try? spawner.signalSSHDServer(pid: pid, "CONT")
            saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) }
        }

        relaunchShowingTheList(app, spawner: spawner)
        // SSH to a port where nothing listens: the host is not reached.
        openEditor(app, row: "host-away")
        replaceText(app, field: "field.port", with: "1")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        let row = app.cells["session-away-1"]
        waitFor(row.exists && (row.value as? String) == "resumable", "the row says resumable", timeout: 10)
        // The server does not answer either: the end gets no contact and goes on to the kill.
        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "STOP"), "SIGSTOP to \(pid)")
        swipeAction(app, row: row, "End Session")
        app.alerts["End Session?"].buttons["End Session"].tap()
        let problem = app.alerts["Session Not Ended"]
        // 10 s for a contact, then the SSH connect's own 10 s.
        XCTAssertTrue(problem.waitForExistence(timeout: 45), "the reason")
        XCTAssertTrue(problem.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not be reached'")).firstMatch.exists)
        attachScreenshot(app, "end-session-not-reached")
        problem.buttons["OK"].tap()
        waitFor((row.value as? String) == "resumable", "still resumable (is \(row.value ?? "nil"))", timeout: 10)
        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "CONT"), "SIGCONT to \(pid)")
        // A shutdown or a kill sent while it was stopped would end it now.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the server still runs")
    }

    /// Review M6-4: the server cannot answer (SIGSTOP, as behind a dead network) when the user
    /// leaves the terminal. mosh gives the shutdown up after 16 sends (`.shutdownFinished(
    /// acknowledged: false)`); the session is closed but its record stays "ended", also past the
    /// 11 s of the path where no event comes at all, and the host list says so. "End Session"
    /// then stops the server through the identity-checked kill (the app reports
    /// `old-server-killed`), and the server is gone once it runs again (SIGCONT).
    ///
    /// The kill is asked for while the server is still stopped: its SIGTERM waits for the
    /// SIGCONT. Continued first, the server would read the queued shutdown requests and exit by
    /// itself, and "End Session" would only find it gone.
    func testAnUnansweredShutdownKeepsTheSessionEndedUntilEndSessionStopsTheServer() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "stopped")
        let pid = opened.servers[0]
        defer {
            _ = try? spawner.signalSSHDServer(pid: pid, "CONT")
            try? spawner.stopSSHDServer(pid: pid)
        }

        let row = try leaveWithTheServerStopped(app, spawner: spawner, pid: pid, name: "stopped")
        attachScreenshot(app, "list-ended")

        try spawner.clearMarks()
        swipeAction(app, row: row, "End Session")
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        confirm.buttons["End Session"].tap()
        waitFor((try? spawner.marks())?.contains("old-server-killed") == true,
                "the identity-checked kill (marks: \((try? spawner.marks()) ?? []))", timeout: 30)
        let host = app.cells["host-stopped"]
        waitFor((host.value as? String) == "none", "the host has no session (is \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(row.exists, "no session row")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")

        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "CONT"), "SIGCONT to \(pid)")
        waitFor((try? spawner.sshdServers()).map { !$0.contains(pid) } == true,
                "the server \(pid) exited (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)

        app.terminate()
        relaunchNormally(app, spawner: spawner)
    }

    /// The same unanswered shutdown, then the app is killed: the next launch finishes the "ended"
    /// record by itself (`SceneDelegate.finishEndedSessions`): the identity-checked kill, then
    /// the record removed; nothing is resumed and no new session is started.
    func testAnUnansweredShutdownIsFinishedByTheNextLaunch() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "relaunch")
        let pid = opened.servers[0]
        defer {
            _ = try? spawner.signalSSHDServer(pid: pid, "CONT")
            try? spawner.stopSSHDServer(pid: pid)
        }

        _ = try leaveWithTheServerStopped(app, spawner: spawner, pid: pid, name: "relaunch")
        app.terminate()
        try spawner.clearMarks()
        relaunchNormally(app, spawner: spawner)
        waitFor((try? spawner.marks())?.contains("old-server-killed") == true,
                "the identity-checked kill at launch (marks: \((try? spawner.marks()) ?? []))", timeout: 30)
        let row = app.cells["host-relaunch"]
        waitFor((row.value as? String) == "none", "the row has no session (is \(row.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(app.otherElements["screenText"].exists, "no new session")

        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "CONT"), "SIGCONT to \(pid)")
        waitFor((try? spawner.sshdServers()).map { !$0.contains(pid) } == true,
                "the server \(pid) exited (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)
    }

    /// A record whose counters cannot be read now (here their file's mode is 000, as for the
    /// files of a locked device): the launch's cold start says "try again later", the host list
    /// says that a session is waiting and shows the row as "cannot be read now", and nothing is
    /// started, written or killed. Readable again, the next launch resumes the same shell.
    func testARecordThatCannotBeReadIsListedAndTheLaunchWaits() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "locked")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingCountersMode", "000",
                               "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 15), "the host list")
        let row = app.cells["session-locked-1"]
        waitFor(row.exists && (row.value as? String) == "unreadable",
                "the row says unreadable (is \(row.value ?? "nil"))", timeout: 10)
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Cannot be read now'")).firstMatch.exists,
                      "the state is shown in the row")
        let waiting = app.staticTexts["sessionWaiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the waiting line")
        XCTAssertTrue(waiting.label.hasPrefix("A session is waiting:"), "the waiting line says why (\(waiting.label))")
        attachScreenshot(app, "list-unreadable-waiting")
        XCTAssertFalse(app.otherElements["screenText"].exists, "no terminal")
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the server was left alone")

        app.terminate()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingCountersMode", "600",
                               "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the session resumed")
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == saved.pidLine }.count >= 2,
                "the same $$ (\(saved.pidLine)):\n\(rows(screen).joined(separator: "\n"))", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the same server")
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionWaiting"].exists, "nothing waiting any more")
    }

    /// Test hygiene (docs/notes/multi-session/DESIGN.md, step 1): a session sent to the
    /// background keeps its server; `MoshSpawner.stopLeftoverServers()`, which `openSession`
    /// registers as a teardown, stops it, so `/sshd/servers` is empty for the next test.
    func testServersATestLeftAreStopped() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "leftover")

        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot", timeout: 15)
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the server runs on with the app in the background")

        spawner.stopLeftoverServers()
        XCTAssertEqual(try spawner.sshdServers(), [], "no server left after the helper")
        app.terminate()
    }

    /// DESIGN.md step 4: a host's session is a row of its own under the host's row and above the
    /// next host; the host row says how many sessions it has and has no state line; from step 10
    /// it has the "+", and a host without sessions has none and reads `none`. Screenshots of the
    /// list with one session and with none (the simulator's appearance decides light or dark).
    func testASessionIsARowUnderItsHost() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "under")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        addHost(app, fields: ["name": "bare", "host": "bare.example", "user": "u"])
        let host = app.cells["host-under"]
        let session = app.cells["session-under-1"]
        let bare = app.cells["host-bare"]
        XCTAssertTrue(bare.waitForExistence(timeout: 10), "the second host")
        waitFor(session.exists && (session.value as? String) == "resumable",
                "the session row says resumable (is \(session.value ?? "nil"))", timeout: 10)
        XCTAssertEqual(host.value as? String, "sessions=1", "the host counts its session")
        XCTAssertEqual(bare.value as? String, "none", "a host without sessions")
        XCTAssertTrue(host.descendants(matching: .any)["hostPlus"].exists, "the host with a session has the \"+\" (step 10)")
        XCTAssertFalse(bare.descendants(matching: .any)["hostPlus"].exists, "the host without sessions has no \"+\"")
        XCTAssertFalse(app.cells["session-under-2"].exists, "one session row")
        XCTAssertFalse(app.cells["session-bare-1"].exists, "no session row under the other host")
        XCTAssertLessThanOrEqual(host.frame.maxY, session.frame.minY + 0.5,
                                 "the session row (\(session.frame)) is below its host (\(host.frame))")
        XCTAssertLessThanOrEqual(session.frame.maxY, bare.frame.minY + 0.5,
                                 "and above the next host (\(bare.frame))")
        // A resumable row's state line is "last used …" (DESIGN.md 4.3, step 5).
        XCTAssertTrue(session.staticTexts.matching(NSPredicate(format: "label CONTAINS 'last used'")).firstMatch.exists,
                      "the state is shown in the session row")
        XCTAssertFalse(host.staticTexts.matching(NSPredicate(format: "label CONTAINS 'last used'")).firstMatch.exists,
                       "not in the host row")
        attachScreenshot(app, "list-one-session")

        swipeAction(app, row: session, "Forget")
        let alert = app.alerts["Forget Session?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirmation")
        alert.buttons["Forget"].tap()
        waitFor((host.value as? String) == "none", "the host has no session (is \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(session.exists, "no session row")
        attachScreenshot(app, "list-no-session")
    }

    /// DESIGN.md step 4: two hosts, a resumable session on each. "End Session" on the second
    /// host's session row ends that session only: its server leaves, the first host's server
    /// stays, and the first host's row resumes the same shell. Screenshots of the list with two
    /// sessions and, after the end, one.
    func testEndSessionOnOneHostLeavesTheOther() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let first = try startSavedSession(app, spawner: spawner, name: "first")
        defer { first.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        let second = try openSessionOnAnotherHost(app, spawner: spawner, name: "second")
        defer { try? spawner.stopSSHDServer(pid: second.server) }
        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot of the second session",
                timeout: 15)
        app.terminate()
        XCTAssertEqual(Set(try spawner.sshdServers()), Set(first.servers + [second.server]), "both servers run")

        relaunchShowingTheList(app, spawner: spawner)
        let firstRow = app.cells["session-first-1"]
        let secondRow = app.cells["session-second-1"]
        waitFor((firstRow.value as? String) == "resumable" && (secondRow.value as? String) == "resumable",
                "both session rows say resumable (\(firstRow.value ?? "nil"), \(secondRow.value ?? "nil"))", timeout: 10)
        XCTAssertEqual(app.cells["host-first"].value as? String, "sessions=1")
        XCTAssertEqual(app.cells["host-second"].value as? String, "sessions=1")
        attachScreenshot(app, "list-two-sessions")

        swipeAction(app, row: secondRow, "End Session")
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        confirm.buttons["End Session"].tap()
        waitFor((try? spawner.sshdServers()).map { !$0.contains(second.server) } == true,
                "the second host's server \(second.server) stopped (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 20)
        XCTAssertEqual(try spawner.sshdServers(), first.servers, "the first host's server stays")
        waitFor((app.cells["host-second"].value as? String) == "none", "the second host has no session", timeout: 10)
        XCTAssertFalse(secondRow.exists, "no session row under the second host")
        XCTAssertEqual(firstRow.value as? String, "resumable", "the first host's session is untouched")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")
        attachScreenshot(app, "list-one-session-after-end")

        firstRow.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == first.pidLine }.count >= 2,
                "the same $$ (\(first.pidLine)):\n\(rows(screen).joined(separator: "\n"))", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertEqual(try spawner.sshdServers(), first.servers, "the same server")
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15)
    }

    /// DESIGN.md step 5: the host sets a window title; the saved session's row shows it as its
    /// first line, "last used …" as its second, and has the dot (`lastSession` names it: the
    /// session was looked at last). Screenshot of the list with the preview and the dot.
    func testARowShowsTheTitleAndTheDot() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "titled")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        let screen = app.otherElements["screenText"]
        app.typeText("printf '\\033]2;build box\\007'; echo title-set\n")
        expect(screen, containsLine: "title-set", timeout: 15)
        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot", timeout: 15)
        app.terminate()

        relaunchShowingTheList(app, spawner: spawner)
        let row = app.cells["session-titled-1"]
        waitFor(row.exists && (row.value as? String) == "resumable",
                "the row says resumable (is \(row.value ?? "nil"))", timeout: 10)
        let labels = row.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(row.staticTexts["build box"].waitForExistence(timeout: 5),
                      "the window title is the row's first line (texts: \(labels))")
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'started ' AND label CONTAINS ' · last used '"))
                          .firstMatch.exists,
                      "and \"started … · last used …\" its second (texts: \(labels))")
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "session-titled-1",
                "lastSession names the row (is \(last.value ?? "nil"))", timeout: 10)
        attachScreenshot(app, "list-preview-dot")
    }

    /// BRIEF.md item 11 (step 13b): a session row's second line says how long ago the session was
    /// started, before when it was last used. A session kept on screen for over a minute, then
    /// "‹ Hosts": its row reads "started 1 min ago · last used just now" (the start is the
    /// record's creation, the last use its park).
    func testARowSaysHowLongAgoItsSessionStarted() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "aged")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        // The record was made before the shell answered: 65 s from here it is over a minute old.
        RunLoop.current.run(until: Date().addingTimeInterval(65))
        let back = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the back button")
        back.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        let row = app.cells["session-aged-1"]
        waitFor(row.exists && (row.value as? String) == "resumable",
                "the parked row says resumable (is \(row.value ?? "nil"))", timeout: 20)
        let line = row.staticTexts.matching(NSPredicate(format: "label MATCHES %@",
                                                        "started [1-9][0-9]* min ago · last used just now"))
        waitFor(line.firstMatch.exists,
                "the second line carries the start first (texts: \(row.staticTexts.allElementsBoundByIndex.map(\.label)))",
                timeout: 5)
        attachScreenshot(app, "list-session-age")
    }

    /// DESIGN.md step 5 (4.4), step 5c: a swipe that is open stays open, still, across several of
    /// the list's 1 s refreshes: "End Session" is there, in the same place and drawn, in every
    /// sample over 3 s, and "Forget" is there at the end. With animations on, as on the phone:
    /// there a refresh that reconfigured the open row slid its actions shut and open again at
    /// every tick (2026-11-22, build 218). Then "End Session" still asks, and Cancel keeps the row.
    func testAnOpenSwipeSurvivesARefresh() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "swiped")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner, animations: true)
        let row = app.cells["session-swiped-1"]
        waitFor(row.exists && (row.value as? String) == "resumable", "the row says resumable", timeout: 30)
        row.swipeRight()
        checkTheSwipeStaysOpen(app, ["End Session", "Forget"], "the session row's swipe")
        attachScreenshot(app, "list-swipe-open")
        app.buttons["End Session"].tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the swipe's action still asks")
        confirm.buttons["Cancel"].tap()
        waitFor(!confirm.exists, "the confirmation is gone", timeout: 10)
        waitFor((row.value as? String) == "resumable", "Cancel kept the session (is \(row.value ?? "nil"))", timeout: 10)
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the server untouched")
    }

    /// Step 5c, the twin on a host row (a host without sessions, so no server): its trailing
    /// swipe's "Delete" is there, in the same place and drawn, in every sample over 3 s of
    /// refreshes, and "Edit" is there at the end, with animations on.
    func testAnOpenHostSwipeSurvivesARefresh() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1",
                               "-uiTestingAnimations", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 60), "the host list")
        addHost(app, fields: ["name": "swipedhost", "host": "127.0.0.1", "port": "1", "user": "u"])
        let host = app.cells["host-swipedhost"]
        XCTAssertTrue(host.waitForExistence(timeout: 30), "the host row")
        // Back from the editor: the push's animation is over before the swipe.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        host.swipeLeft()
        checkTheSwipeStaysOpen(app, ["Delete", "Edit"], "the host row's swipe")
    }

    /// Step 5c (A): "Delete" from a host row's swipe, with animations on as on the phone. The app
    /// stays alive (it aborted before: the delete's `reloadData()` reset the open swipe, UIKit's
    /// reset called `didEndEditingRowAt`, and the refresh made there reconfigured rows inside the
    /// reload), the row goes, the other host and its session stay, and the list still refreshes
    /// afterwards: the session row's state line moves on at its next minute, which only the 1 s
    /// refresh redraws (nothing else happens on the screen meanwhile).
    func testDeletingAHostFromItsSwipeLeavesTheAppRunning() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: "stays")
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner, animations: true)
        addHost(app, fields: ["name": "goner", "host": "127.0.0.1", "port": "1", "user": "u"])
        let goner = app.cells["host-goner"]
        let session = app.cells["session-stays-1"]
        XCTAssertTrue(goner.waitForExistence(timeout: 30), "the host to delete")
        waitFor((session.value as? String) == "resumable", "the other host's session row (is \(session.value ?? "nil"))",
                timeout: 30)
        // Back from the editor: the pop's animation is over before the swipe.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        goner.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "the host row's swipe is open")
        delete.tap()
        waitFor(!goner.exists, "the deleted host's row is gone", timeout: 15)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the swipe's Delete")
        XCTAssertTrue(app.navigationBars["Hosts"].exists, "still the host list")
        waitFor(!app.buttons["Delete"].exists, "the swipe is closed", timeout: 10)
        XCTAssertTrue(app.cells["host-stays"].exists, "the other host stays")
        XCTAssertEqual(session.value as? String, "resumable", "and its session")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")

        let before = stateLine(session)
        XCTAssertTrue(before.hasPrefix("started "), "the state line (is \"\(before)\")")
        waitFor(stateLine(session) != before,
                "the session row's state line moved on from \"\(before)\": the list still refreshes after the delete",
                timeout: 75)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
    }

    /// Step 5c (C): "End Session" and "Forget" from session rows' swipes, with animations on. The
    /// app stays alive; "End Session" stops its server and its row goes; "Forget" removes the other
    /// row and leaves its server running.
    func testEndSessionAndForgetFromSwipesWithAnimations() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let (first, second) = try startTwoSavedSessions(app, spawner: spawner, first: "forgotten", second: "endedrow")
        defer {
            first.servers.forEach { try? spawner.stopSSHDServer(pid: $0) }
            try? spawner.stopSSHDServer(pid: second.server)
        }

        relaunchShowingTheList(app, spawner: spawner, animations: true)
        let firstRow = app.cells["session-forgotten-1"]
        let secondRow = app.cells["session-endedrow-1"]
        waitFor((firstRow.value as? String) == "resumable" && (secondRow.value as? String) == "resumable",
                "both session rows say resumable (\(firstRow.value ?? "nil"), \(secondRow.value ?? "nil"))", timeout: 30)

        swipeAction(app, row: secondRow, "End Session")
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the confirmation")
        confirm.buttons["End Session"].tap()
        waitFor((try? spawner.sshdServers()).map { !$0.contains(second.server) } == true,
                "the ended session's server \(second.server) stopped (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 30)
        let secondHost = app.cells["host-endedrow"]
        waitFor((secondHost.value as? String) == "none", "the ended session's row is gone (host: \(secondHost.value ?? "nil"))",
                timeout: 15)
        XCTAssertFalse(secondRow.exists, "no session row under that host")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the swipe's End Session")
        XCTAssertEqual(firstRow.value as? String, "resumable", "the other session is untouched")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")

        swipeAction(app, row: firstRow, "Forget")
        let forget = app.alerts["Forget Session?"]
        XCTAssertTrue(forget.waitForExistence(timeout: 10), "the confirmation")
        forget.buttons["Forget"].tap()
        let firstHost = app.cells["host-forgotten"]
        waitFor((firstHost.value as? String) == "none", "the forgotten session's row is gone (host: \(firstHost.value ?? "nil"))",
                timeout: 15)
        XCTAssertFalse(firstRow.exists, "no session row under that host")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the swipe's Forget")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")
        XCTAssertEqual(try spawner.sshdServers(), first.servers, "Forget left its server running")
    }

    /// Step 5c (B, C): an "End Session" finishes on one row while another row's swipe is open,
    /// with animations on. Its server is stopped (SIGSTOP) until the other swipe is open, so the
    /// end through mosh waits for its contact (DESIGN.md section 6 e, step 12), and the end's last
    /// reload and `SessionActivity`'s change come while it is open: running again (SIGCONT), the
    /// server answers, acknowledges the shutdown and exits. No crash; the open swipe stays open
    /// and drawn (they wait), the ended row still reads "ending"; once the swipe is closed the
    /// list is right: the ended row is gone, the other one resumable, its server running.
    func testAnEndThatFinishesUnderAnotherRowsOpenSwipe() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let (first, second) = try startTwoSavedSessions(app, spawner: spawner, first: "openswipe", second: "endsbelow")
        defer {
            _ = try? spawner.signalSSHDServer(pid: second.server, "CONT")
            first.servers.forEach { try? spawner.stopSSHDServer(pid: $0) }
            try? spawner.stopSSHDServer(pid: second.server)
        }

        relaunchShowingTheList(app, spawner: spawner, animations: true)
        let firstRow = app.cells["session-openswipe-1"]
        let secondRow = app.cells["session-endsbelow-1"]
        waitFor((firstRow.value as? String) == "resumable" && (secondRow.value as? String) == "resumable",
                "both session rows say resumable (\(firstRow.value ?? "nil"), \(secondRow.value ?? "nil"))", timeout: 30)

        XCTAssertTrue(try spawner.signalSSHDServer(pid: second.server, "STOP"), "SIGSTOP to \(second.server)")
        swipeAction(app, row: secondRow, "End Session")
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the confirmation")
        confirm.buttons["End Session"].tap()
        waitFor((secondRow.value as? String) == "ending", "the row says ending (is \(secondRow.value ?? "nil"))", timeout: 10)
        waitFor(!confirm.exists, "the confirmation is gone", timeout: 10)

        firstRow.swipeRight()
        XCTAssertTrue(app.buttons["Forget"].waitForExistence(timeout: 10), "the other row's swipe is open")
        XCTAssertTrue(try spawner.signalSSHDServer(pid: second.server, "CONT"), "SIGCONT to \(second.server)")
        waitFor((try? spawner.sshdServers()).map { !$0.contains(second.server) } == true,
                "the ended session's server \(second.server) is gone (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 20)
        // The end's forget and its reload follow the server's answer at once.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the end finished")
        checkTheSwipeStaysOpen(app, ["End Session", "Forget"], "the open swipe while the other row's end finished")
        XCTAssertEqual(secondRow.value as? String, "ending", "the ended row is redrawn only when the swipe closes")

        // Closed by a swipe back.
        firstRow.swipeLeft()
        waitFor(!app.buttons["Forget"].exists, "the swipe is closed", timeout: 10)
        let secondHost = app.cells["host-endsbelow"]
        waitFor((secondHost.value as? String) == "none" && !secondRow.exists,
                "the ended row is gone once the swipe closed (host: \(secondHost.value ?? "nil"))", timeout: 15)
        XCTAssertEqual(firstRow.value as? String, "resumable", "the other session is untouched")
        XCTAssertEqual(app.cells["host-openswipe"].value as? String, "sessions=1")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")
        XCTAssertEqual(try spawner.sshdServers(), first.servers, "the other session's server runs")
    }

    /// DESIGN.md 5.2, step 6: "End Session" behind the terminal's "…" button (a plain button, no
    /// menu) asks once and ends the session: the list comes back, the server is gone and the session's row too.
    func testEndSessionFromTheMenu() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "menu")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        let menu = app.navigationBars.buttons["sessionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the \"…\" button")
        XCTAssertEqual(menu.label, "Session", "the button's accessibility label")
        // One tap asks at once: no menu in between (DESIGN.md 5.2, D8).
        menu.tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS 'its shell and the programs in it stop'"))
                        .firstMatch.exists, "the confirmation says what ends")
        attachScreenshot(app, "terminal-end-confirm")
        confirm.buttons["End Session"].tap()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        waitFor((try? spawner.sshdServers()) == [], "the server ended (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 15)
        let host = app.cells["host-menu"]
        waitFor((host.value as? String) == "none", "the host has no session (is \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(app.cells["session-menu-1"].exists, "no session row")
        XCTAssertFalse(app.otherElements["screenText"].exists, "no terminal")
    }

    /// DESIGN.md 5.2, step 6: Cancel in the confirmation leaves the session as it was: the
    /// terminal stays, the same server runs, and the shell still answers.
    func testCancelLeavesTheSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "cancel")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        let menu = app.navigationBars.buttons["sessionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the \"…\" button")
        menu.tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        confirm.buttons["Cancel"].tap()

        waitFor(!confirm.exists, "the confirmation is gone", timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.exists, "the terminal stays")
        XCTAssertFalse(app.navigationBars["Hosts"].exists, "not the host list")
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the same server runs")
        app.typeText("echo still-$((6*7))\n")
        expect(screen, containsLine: "still-42", timeout: 15)

        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15)
    }

    /// DESIGN.md 5.1, step 6: a session without a saved host (here a `-debugMosh*` session) opens
    /// over the host list as every other session: "‹ Hosts" and the "…" button are in its
    /// navigation bar, and back shows the list.
    func testADebugSessionHasTheListUnderIt() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the debug session's terminal")
        expect(screen, contains: "$", timeout: 15)
        let back = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "a back button to the host list")
        XCTAssertTrue(app.navigationBars.buttons["sessionMenu"].exists, "the \"…\" button")
        attachScreenshot(app, "debug-session-over-the-list")

        back.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        XCTAssertFalse(screen.exists, "no terminal")
        // From step 9 back parks the session (DESIGN.md 3.3 B1): its row is resumable and its
        // server runs on.
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        waitFor(row.exists && (row.value as? String) == "resumable",
                "the debug session's row is resumable (is \(row.value ?? "nil"))", timeout: 15)
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the debug session's server still runs")
    }

    /// DESIGN.md 5.4, 3.3 X1, step 7: the server ends the session (`exit` in the shell): the
    /// terminal goes back to the list by itself, with no tap; the session's row and its server
    /// are gone, no row has the dot, and a normal relaunch resumes nothing.
    func testExitReturnsToTheList() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "exit")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        let screen = app.otherElements["screenText"]

        app.typeText("exit\n")
        // The message is built before the wait, when the terminal may already be gone: it reads
        // nothing of the screen.
        waitFor(!screen.exists, "the list by itself: the terminal is gone", timeout: 15)
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
        waitFor((try? spawner.sshdServers()) == [], "the server ended (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 15)
        let host = app.cells["host-exit"]
        waitFor((host.value as? String) == "none", "the host has no session (is \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(app.cells["session-exit-1"].exists, "no session row")
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "none", "no row has the dot (is \(last.value ?? "nil"))", timeout: 10)
        attachScreenshot(app, "list-after-exit")

        app.terminate()
        relaunchNormally(app, spawner: spawner)
        XCTAssertEqual(app.cells["host-exit"].value as? String, "none", "no session after the relaunch")
        XCTAssertEqual(try spawner.sshdServers(), [], "no server was started")
    }

    /// Step 6 corrected (review-steps-2-4.md, "Step 6, first check", A): "End Session?" from the
    /// "…" button can be up when the connect asks its first question (here the unknown host key;
    /// the sshd is held until the alert is up). The question waits for the alert and is not
    /// lost: after Cancel it is shown, Trust lets the session come up, and the screen does not
    /// stay on "Connecting…".
    func testAQuestionOfTheConnectWaitsForEndSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let sshd = try spawner.sshd()
        XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run")
        addTeardownBlock {
            try? spawner.holdSSHD(false)
            spawner.stopLeftoverServers()
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1",
                               "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)
        addHost(app, fields: [
            "name": "ask", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ])
        let row = app.cells["host-ask"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        try spawner.holdSSHD(true)
        row.tap()
        let menu = app.navigationBars.buttons["sessionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the \"…\" button while connecting")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no question yet: the sshd is held")
        menu.tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")

        // The connect goes on and reaches its host key question while the alert is up.
        try spawner.holdSSHD(false)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(confirm.exists, "\"End Session?\" stays up")
        XCTAssertEqual(app.alerts.count, 1, "the question does not replace the alert")
        attachScreenshot(app, "end-confirm-while-connecting")
        confirm.buttons["Cancel"].tap()

        let question = app.alerts["Unknown Host Key"]
        XCTAssertTrue(question.waitForExistence(timeout: 10), "the host key question after Cancel")
        question.buttons["Trust"].tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        expect(screen, contains: "$", timeout: 30)
        waitFor((try? spawner.sshdServers())?.count == 1, "one server", timeout: 15)

        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15)
    }

    // MARK: A sideways drag opens no row (review-steps-2-4.md, R24-M1; step 4c)

    // A host row has no leading swipe actions and a session row no trailing ones (DESIGN.md
    // 3.4). A drag towards that side, fast (XCUITest's swipe) or slow (a press, then a slow
    // drag), opens nothing: no terminal, no alert, the row as it was. Then the row's own swipe
    // actions, its detail button (host rows) and a plain tap still work.

    func testASidewaysSwipeOnAHostRowOpensNothing() throws {
        try checkASidewaysDragOnAHostRow(name: "sidefast") { $0.swipeRight() }
    }

    func testASlowSidewaysDragOnAHostRowOpensNothing() throws {
        try checkASidewaysDragOnAHostRow(name: "sideslow") { self.slowDrag($0, rightwards: true) }
    }

    func testASidewaysSwipeOnASessionRowOpensNothing() throws {
        try checkASidewaysDragOnASessionRow(name: "rowfast") { $0.swipeLeft() }
    }

    func testASlowSidewaysDragOnASessionRowOpensNothing() throws {
        try checkASidewaysDragOnASessionRow(name: "rowslow") { self.slowDrag($0, rightwards: false) }
    }

    /// R24-S1 (step 4c): a host whose newest session already reads "ended" gets a new session
    /// from a tap also while "End Session" runs on that session (its SSH is held here, so it
    /// cannot finish first), as before step 4. The ending session is still finished: the
    /// identity-checked kill, then its row is gone.
    func testAHostTapStartsANewSessionWhileItsEndedSessionIsBeingEnded() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "again")
        let pid = opened.servers[0]
        addTeardownBlock { try? spawner.holdSSHD(false) }
        defer {
            _ = try? spawner.signalSSHDServer(pid: pid, "CONT")
            try? spawner.stopSSHDServer(pid: pid)
        }

        let row = try leaveWithTheServerStopped(app, spawner: spawner, pid: pid, name: "again")
        try spawner.clearMarks()
        // "End Session" on the ended row; its SSH waits for the held sshd.
        try spawner.holdSSHD(true)
        swipeAction(app, row: row, "End Session")
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        confirm.buttons["End Session"].tap()
        waitFor((row.value as? String) == "ending", "the row says ending (is \(row.value ?? "nil"))", timeout: 5)

        app.cells["host-again"].tap()
        XCTAssertTrue(app.navigationBars.buttons["sessionMenu"].waitForExistence(timeout: 5),
                      "a host tap starts a new session while End Session runs on its ended session")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
        try spawner.holdSSHD(false)

        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        expect(screen, contains: "$", timeout: 30)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { $0 != pid }; return added.count == 1 }(),
                "one new server beside the stopped one", timeout: 15)
        waitFor((try? spawner.marks())?.contains("old-server-killed") == true,
                "the ended session's identity-checked kill (marks: \((try? spawner.marks()) ?? []))", timeout: 30)
        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "CONT"), "SIGCONT to \(pid)")
        waitFor((try? spawner.sshdServers()).map { !$0.contains(pid) } == true,
                "the ended session's server \(pid) exited (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)

        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the new session's server ended", timeout: 15)
        let host = app.cells["host-again"]
        waitFor((host.value as? String) == "none", "the host has no session left (is \(host.value ?? "nil"))", timeout: 10)
    }

    /// DESIGN.md step 8: a session ended from the terminal reads "ending" in the list while its
    /// end runs (here its server is stopped, so for 11 s), and a host tap meanwhile starts a new
    /// session on that host: a host tap ignores "ending", and the newest record already reads
    /// "ended". The first session's end then returns and leaves its row "ended".
    func testAHostTapStartsANewSessionWhileItsSessionEndsFromTheTerminal() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "leaving")
        let pid = opened.servers[0]
        defer {
            _ = try? spawner.signalSSHDServer(pid: pid, "CONT")
            try? spawner.stopSSHDServer(pid: pid)
        }

        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "STOP"), "SIGSTOP to \(pid)")
        endSessionFromTerminal(app)
        let row = app.cells["session-leaving-1"]
        waitFor((row.value as? String) == "ending", "the row says ending (is \(row.value ?? "nil"))", timeout: 5)
        // The list reads the records every second: by now it has read the "ended" mark that the
        // shutdown wrote. The end runs for 11 s from the confirm.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(row.value as? String, "ending", "still ending at the host tap")

        app.cells["host-leaving"].tap()
        XCTAssertTrue(app.navigationBars.buttons["sessionMenu"].waitForExistence(timeout: 5),
                      "a host tap starts a new session while its session ends from the terminal")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        expect(screen, contains: "$", timeout: 30)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { $0 != pid }; return added.count == 1 }(),
                "one new server beside the stopped one", timeout: 15)

        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [pid], "the new session's server ended", timeout: 15)
        waitFor((row.value as? String) == "ended", "the first session's end returned: ended (is \(row.value ?? "nil"))",
                timeout: 20)
        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "CONT"), "SIGCONT to \(pid)")
        waitFor((try? spawner.sshdServers()).map { !$0.contains(pid) } == true,
                "the stopped server \(pid) exited (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)
    }

    // MARK: Helpers

    /// Two hosts on the spawner's sshd, `first` and `second`, each with a saved (resumable)
    /// session, and the app killed, as `testEndSessionOnOneHostLeavesTheOther` makes them.
    func startTwoSavedSessions(_ app: XCUIApplication, spawner: MoshSpawner, first: String, second: String,
                               file: StaticString = #filePath, line: UInt = #line) throws
        -> (first: (pidLine: String, servers: [Int32]), second: (pidLine: String, server: Int32)) {
        let one = try startSavedSession(app, spawner: spawner, name: first, file: file, line: line)
        relaunchShowingTheList(app, spawner: spawner)
        let two = try openSessionOnAnotherHost(app, spawner: spawner, name: second, file: file, line: line)
        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot of the second session",
                timeout: 15, file: file, line: line)
        app.terminate()
        XCTAssertEqual(Set(try spawner.sshdServers()), Set(one.servers + [two.server]), "both servers run",
                       file: file, line: line)
        return (one, two)
    }

    /// A session row's state line ("started … · last used …"), or "" when it has none.
    func stateLine(_ row: XCUIElement) -> String {
        let text = row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'started '")).firstMatch
        return text.exists ? text.label : ""
    }

    /// A press, then a slow drag across the row towards one side, held a moment at the end.
    func slowDrag(_ row: XCUIElement, rightwards: Bool) {
        let left = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let right = row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let (from, to) = rightwards ? (left, right) : (right, left)
        from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Two seconds after a drag: still the host list, no terminal and no alert.
    func checkNothingOpened(_ app: XCUIApplication, after what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.navigationBars.buttons["sessionMenu"].exists, "no terminal after \(what)", file: file, line: line)
        XCTAssertFalse(app.otherElements["screenText"].exists, "no terminal screen after \(what)", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert after \(what)", file: file, line: line)
        XCTAssertTrue(app.navigationBars["Hosts"].exists, "still the host list after \(what)", file: file, line: line)
    }

    /// R24-M1 on a host row without sessions (a tap would connect: 127.0.0.1 port 1, where
    /// nothing listens, so no server is started): `drag` towards the side without actions opens
    /// nothing; then the trailing swipe still offers Edit and Delete, the detail button opens the
    /// editor, and a tap starts a session.
    func checkASidewaysDragOnAHostRow(name: String, file: StaticString = #filePath, line: UInt = #line,
                                      _ drag: (XCUIElement) -> Void) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        addHost(app, fields: ["name": name, "host": "127.0.0.1", "port": "1", "user": "u"], file: file, line: line)
        let host = app.cells["host-\(name)"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "the host row", file: file, line: line)
        XCTAssertEqual(host.value as? String, "none", "no session", file: file, line: line)

        drag(host)
        checkNothingOpened(app, after: "the drag", file: file, line: line)
        XCTAssertEqual(host.value as? String, "none", "still no session", file: file, line: line)

        host.swipeLeft()
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the trailing swipe's Edit", file: file, line: line)
        XCTAssertTrue(app.buttons["Delete"].exists, "and Delete", file: file, line: line)
        edit.tap()
        XCTAssertTrue(app.textFields["field.host"].waitForExistence(timeout: 5), "Edit opens the editor", file: file, line: line)
        app.navigationBars.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list", file: file, line: line)

        openEditor(app, row: "host-\(name)", file: file, line: line)
        app.navigationBars.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list", file: file, line: line)

        host.tap()
        XCTAssertTrue(app.navigationBars.buttons["sessionMenu"].waitForExistence(timeout: 10),
                      "a tap on the row still starts a session", file: file, line: line)
    }

    /// R24-M1 on a resumable session row: `drag` towards the side without actions opens nothing
    /// (the row stays resumable, the server untouched); then the leading swipe still offers End
    /// Session and Forget, and a tap resumes the same shell.
    func checkASidewaysDragOnASessionRow(name: String, file: StaticString = #filePath, line: UInt = #line,
                                         _ drag: (XCUIElement) -> Void) throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let saved = try startSavedSession(app, spawner: spawner, name: name, file: file, line: line)
        defer { saved.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }

        relaunchShowingTheList(app, spawner: spawner)
        let row = app.cells["session-\(name)-1"]
        waitFor(row.exists && (row.value as? String) == "resumable",
                "the row says resumable (is \(row.value ?? "nil"))", timeout: 10, file: file, line: line)

        drag(row)
        checkNothingOpened(app, after: "the drag", file: file, line: line)
        XCTAssertEqual(row.value as? String, "resumable", "the row as it was", file: file, line: line)
        XCTAssertEqual(try spawner.sshdServers(), saved.servers, "the server untouched", file: file, line: line)

        swipeAction(app, row: row, "Forget", file: file, line: line)
        let forget = app.alerts["Forget Session?"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "the leading swipe still works", file: file, line: line)
        forget.buttons["Cancel"].tap()
        waitFor(!forget.exists, "the confirmation is gone", timeout: 5, file: file, line: line)
        XCTAssertEqual(row.value as? String, "resumable", "Cancel kept the session", file: file, line: line)

        row.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "a tap on the row still resumes it", file: file, line: line)
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == saved.pidLine }.count >= 2,
                "the same $$ (\(saved.pidLine)):\n\(rows(screen).joined(separator: "\n"))", timeout: 15, file: file, line: line)
        endSessionFromTerminal(app, file: file, line: line)
        waitFor((try? spawner.sshdServers()) == [], "the server ended", timeout: 15, file: file, line: line)
    }

    /// With a session open: SIGSTOP its server, end the session from the terminal, and check that
    /// the row reads "ending" while that end runs (DESIGN.md step 8: until the terminal's `end`
    /// returns, 11 s after an unanswered shutdown), then "ended", and that the record stays
    /// "ended" for longer than both shutdown paths take (16 sends, or 11 s without an event)
    /// while the stopped server is still there. Returns the session's row.
    func leaveWithTheServerStopped(_ app: XCUIApplication, spawner: MoshSpawner, pid: Int32, name: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        XCTAssertTrue(try spawner.signalSSHDServer(pid: pid, "STOP"), "SIGSTOP to \(pid)", file: file, line: line)
        endSessionFromTerminal(app, file: file, line: line)
        let row = app.cells["session-\(name)-1"]
        waitFor((row.value as? String) == "ending",
                "the row says ending while the end from the terminal runs (is \(row.value ?? "nil"))",
                timeout: 5, file: file, line: line)
        // The end returns 11 s after the shutdown (`end` waits that long without an answer).
        waitFor((row.value as? String) == "ended", "the row says ended once that end returned (is \(row.value ?? "nil"))",
                timeout: 20, file: file, line: line)
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ended'")).firstMatch.exists,
                      "the state is shown in the row", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(13))
        XCTAssertEqual(row.value as? String, "ended", "still ended after 13 s", file: file, line: line)
        XCTAssertEqual(try spawner.sshdServers(), [pid], "the stopped server is still there", file: file, line: line)
        return row
    }

    /// Step 5c: with a row's swipe just opened, its first action (`titles[0]`, a red destructive
    /// one) is sampled about every 100 ms for 3 s, each time twice: its accessibility snapshot
    /// (there, its frame unchanged from the one taken when the open had settled, 1 s after it
    /// appeared) and a screenshot (at least 30% of the pixels in that frame are its red; about 90%
    /// when it is drawn, 0 when it is not). The screenshot is the check that sees what the phone showed: there the
    /// actions slid away and back while the accessibility tree kept them in place (the model
    /// stays "open", only what is drawn moves). Then every action is still there and hittable.
    /// The samples are printed (`swipe sample:` in the test log) and named in a failure, with the
    /// first screenshot that lacked the button attached.
    func checkTheSwipeStaysOpen(_ app: XCUIApplication, _ titles: [String], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let first = app.buttons[titles[0]]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "\(what) is open", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let screenWidth = app.frame.width
        guard let settled = try? first.snapshot().frame else {
            XCTFail("\(what): \"\(titles[0])\" is gone 1 s after it appeared", file: file, line: line)
            return
        }
        let settledRed = Self.redShare(XCUIScreen.main.screenshot(), in: settled, screenWidth: screenWidth)
        var samples: [String] = []
        var bad = 0
        var firstGone: XCUIScreenshot?
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let frame = try? first.snapshot().frame
            let shot = XCUIScreen.main.screenshot()
            let red = Self.redShare(shot, in: settled, screenWidth: screenWidth)
            var faults: [String] = []
            if let frame {
                if abs(frame.minX - settled.minX) > 0.5 || abs(frame.minY - settled.minY) > 0.5
                    || abs(frame.width - settled.width) > 0.5 || abs(frame.height - settled.height) > 0.5 {
                    faults.append("MOVED")
                }
            } else {
                faults.append("MISSING")
            }
            if red < 0.3 {
                faults.append("NOT DRAWN")
                if firstGone == nil { firstGone = shot }
            }
            if !faults.isEmpty { bad += 1 }
            samples.append(String(format: "%d ms: %@ frame %@ red %.2f", ms, faults.isEmpty ? "there" : faults.joined(separator: " "),
                                  frame.map { "\($0)" } ?? "-", red))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        samples.forEach { print("swipe sample: \(what): \($0)") }
        if let firstGone {
            let attachment = XCTAttachment(screenshot: firstGone)
            attachment.name = "swipe-not-drawn"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(bad, 0, "\(what): \"\(titles[0])\" missing, moved or not drawn in \(bad) of \(samples.count) samples "
                       + String(format: "(settled at %@, red %.2f):\n", "\(settled)", settledRed)
                       + samples.joined(separator: "\n"), file: file, line: line)
        for title in titles {
            let button = app.buttons[title]
            XCTAssertTrue(button.exists && button.isHittable, "\(what): \"\(title)\" is still on screen after 3 s of refreshes",
                          file: file, line: line)
        }
    }

    /// The share of the pixels inside `rect` (points) of `shot` that are the red of a destructive
    /// swipe action (systemRed, light or dark).
    static func redShare(_ shot: XCUIScreenshot, in rect: CGRect, screenWidth: CGFloat) -> Double {
        guard let image = shot.image.cgImage, screenWidth > 0 else { return 0 }
        let scale = CGFloat(image.width) / screenWidth
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return 0 }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var red = 0
        for index in stride(from: 0, to: data.count, by: 4)
        where data[index] > 200 && data[index + 1] < 110 && data[index + 2] < 110 {
            red += 1
        }
        return Double(red) / Double(width * height)
    }

    /// Swipes the row from the leading edge and taps one of its actions.
    func swipeAction(_ app: XCUIApplication, row: XCUIElement, _ title: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        row.swipeRight()
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "swipe action \(title)", file: file, line: line)
        button.tap()
    }

    /// A launch with the cold start: the host list, and no session resumed.
    func relaunchNormally(_ app: XCUIApplication, spawner: MoshSpawner) {
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 15), "the host list")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.otherElements["screenText"].exists, "nothing resumed")
    }


    func rows(_ screen: XCUIElement) -> [String] {
        ((screen.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
