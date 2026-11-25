import XCTest

/// The launch target (docs/notes/multi-session/DESIGN.md step 11; 2.5, 3.5 K1, L2 to L4, D1, D2,
/// D4): a launch goes into the session he looked at last and opens no other record, whichever is
/// newer, also when the list was on screen when the app went away; a session that died on screen
/// falls back to a new one and leaves the parked ones as they were; once the dotted session has
/// ended a launch shows the list. Step 11b: "End Session" clears the dot before its shutdown, and
/// a fallback he left keeps the old record without the dot, so no later launch comes back to it.
///
/// Every session is started on the spawner's sshd through the shared helpers of
/// `SessionUITests.swift` (`openSession` registers the teardown that stops what a test leaves),
/// so the classes that run after this one find no server left (section 8).
final class LaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Set when the teardown of `stopTheAppFirst` kept the diagnostics of a failed test.
    private var diagnosticsKept = false

    override func tearDown() {
        if !diagnosticsKept { keepDiagnosticsIfFailed() }
        super.tearDown()
    }

    /// K1, then L2: A and B are parked on one host, A (the older record) is opened again, the app
    /// goes Home, saves A clean, and is killed. The launch resumes A, the session looked at last,
    /// not B, the newest record; B stays resumable and both servers run on.
    func testAKillOffScreenResumesTheLastLookedAtSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let a = try openSession(app, spawner: spawner, name: "koff")
        stopTheAppFirst(app)
        let aPid = pid(of: a.pidLine)
        back(app, spawner: spawner, row: "session-koff-1", parks: 1)
        let b = try newSession(app, spawner: spawner, host: "koff", besides: a.servers)
        back(app, spawner: spawner, row: "session-koff-2", parks: 2)
        let servers = Set(a.servers + [b.server])
        XCTAssertEqual(servers.count, 2, "two servers")

        let screen = app.otherElements["screenText"]
        app.cells["session-koff-1"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "A's terminal")
        waitFor(screenRows(screen).contains(a.pidLine), "A's stored screen (\(a.pidLine))", timeout: 15)
        try spawner.clearMarks()
        XCUIDevice.shared.press(.home)
        waitFor(((try? spawner.marks()) ?? []).contains("background-clean"), "A saved clean in the background", timeout: 15)
        app.terminate()
        XCTAssertEqual(Set(try spawner.sshdServers()), servers, "both servers outlive the app")

        launchNormally(app, spawner: spawner)
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the launch opened a session")
        waitFor(screenRows(screen).contains(a.pidLine),
                "the launch resumed A (\(a.pidLine)), the session looked at last, not B (\(b.pidLine)), the newest record",
                timeout: 15)
        XCTAssertFalse(screenRows(screen).contains(b.pidLine), "nothing of B on the screen")
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(aPid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner")
        attachScreenshot(app, "launch-resumes-the-last-looked-at")

        try spawner.clearMarks()
        back(app, spawner: spawner, row: "session-koff-1", parks: 1)
        let bRow = app.cells["session-koff-2"]
        waitFor(bRow.exists && (bRow.value as? String) == "resumable", "B is still resumable (is \(bRow.value ?? "nil"))",
                timeout: 10)
        XCTAssertEqual(Set(try spawner.sshdServers()), servers, "the same two servers: nothing was started or ended")
    }

    /// D1 (the reading of brief item 8 that 10.2 asks the owner about): A opened, back (the list
    /// on screen, A parked clean; a kill inside the park would leave the record dirty and the
    /// launch would fall back), Home, the process killed. The launch goes into A, the dotted
    /// session, although the list was on screen when the app went away.
    func testAKillWithTheListOnScreenGoesIntoTheDottedSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let a = try openSession(app, spawner: spawner, name: "klist")
        stopTheAppFirst(app)
        let aPid = pid(of: a.pidLine)
        back(app, spawner: spawner, row: "session-klist-1", parks: 1)
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "session-klist-1", "A has the dot (is \(last.value ?? "nil"))", timeout: 10)
        XCUIDevice.shared.press(.home)
        waitFor(app.state != .runningForeground, "the app left the foreground", timeout: 10)
        app.terminate()
        XCTAssertEqual(try spawner.sshdServers(), a.servers, "the server outlives the app")

        launchNormally(app, spawner: spawner)
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15),
                      "the launch went into the dotted session, although the list was on screen (D1)")
        waitFor(screenRows(screen).contains(a.pidLine), "A's stored screen (\(a.pidLine))", timeout: 15)
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(aPid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner")
        XCTAssertEqual(try spawner.sshdServers(), a.servers, "the same server")
        attachScreenshot(app, "launch-into-the-dotted-session")
    }

    /// K1 (death on screen), then L3 (D2): B is made first, A second (the newest record) and
    /// parked. A launch that shows the list and starts nothing (`-uiTestingSkipColdStart`) arms
    /// `-debugCrashAfter` for the first session started in it (A23); B is opened and the process
    /// dies with B on screen, its record dirty. The launch falls back on B's host (the banner, a
    /// new shell, B's old server stopped after the identity check), and A is untouched: its row
    /// is resumable and resumes A's shell.
    func testACrashOnScreenFallsBackAndTheParkedOneStays() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let b = try openSession(app, spawner: spawner, name: "crb")
        stopTheAppFirst(app)
        back(app, spawner: spawner, row: "session-crb-1", parks: 1)
        let a = try openSessionOnAnotherHost(app, spawner: spawner, name: "cra")
        let aPid = pid(of: a.pidLine)
        back(app, spawner: spawner, row: "session-cra-1", parks: 1)
        let bServer = b.servers[0]
        XCTAssertEqual(Set(try spawner.sshdServers()), [bServer, a.server], "two servers")
        app.terminate()

        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSkipColdStart", "1",
                               "-uiTestingSpawnerPort", String(spawner.port), "-debugCrashAfter", "8"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 15), "the host list")
        let screen = app.otherElements["screenText"]
        XCTAssertFalse(screen.exists, "nothing started at this launch")
        let bRow = app.cells["session-crb-1"]
        waitFor(bRow.exists && (bRow.value as? String) == "resumable", "B is resumable (is \(bRow.value ?? "nil"))",
                timeout: 10)
        bRow.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "B's terminal")
        waitFor(screenRows(screen).contains(b.pidLine), "B's stored screen (\(b.pidLine))", timeout: 7)
        waitFor(app.state == .notRunning, "the process died with B on screen", timeout: 30)
        XCTAssertEqual(Set(try spawner.sshdServers()), [bServer, a.server], "both servers outlive the crash")

        try spawner.clearMarks()
        launchNormally(app, spawner: spawner)
        let status = app.staticTexts["sessionStatus"]
        waitFor(status.exists && status.label.contains("Previous session could not be resumed. Starting a new one."),
                "the fallback banner: B, looked at last, died on screen", timeout: 60)
        XCTAssertTrue(app.navigationBars["crb"].exists, "the new session is on B's host")
        expect(screen, contains: "$", timeout: 30)
        app.typeText("echo pid-$$\n")
        var newLine = ""
        waitFor({ newLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !newLine.isEmpty }(),
                "the new shell's pid", timeout: 15)
        XCTAssertNotEqual(newLine, b.pidLine, "a new shell, not B's")
        XCTAssertNotEqual(newLine, a.pidLine, "not A's either")
        var now: Set<Int32> = []
        waitFor({ now = Set((try? spawner.sshdServers()) ?? []); return now.count == 2 && now.contains(a.server) && !now.contains(bServer) }(),
                "B's old server \(bServer) stopped, A's \(a.server) and the new one running", timeout: 30)
        attachScreenshot(app, "launch-fallback-on-b")

        back(app, spawner: spawner, row: "session-crb-1", parks: 1)
        let bHost = app.cells["host-crb"]
        waitFor((bHost.value as? String) == "sessions=1",
                "B's record was replaced by the new session (host: \(bHost.value ?? "nil"))", timeout: 10)
        let aRow = app.cells["session-cra-1"]
        waitFor(aRow.exists && (aRow.value as? String) == "resumable", "A is still resumable (is \(aRow.value ?? "nil"))",
                timeout: 10)
        aRow.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "A's terminal")
        waitFor(screenRows(screen).contains(a.pidLine), "A's stored screen (\(a.pidLine))", timeout: 15)
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(aPid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner on A")
        XCTAssertEqual(Set(try spawner.sshdServers()), now, "A's own server")
    }

    /// D4, 3.5 L4: A is parked; B is opened (the dot is B's) and its server ends it (`exit`): the
    /// list, no row has the dot. After the process is killed the launch shows the list: no session
    /// is opened, `lastSession` is `none`, A is still resumable and its server runs.
    func testAfterTheDottedSessionEndsTheLaunchShowsTheList() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let a = try openSession(app, spawner: spawner, name: "dotend")
        stopTheAppFirst(app)
        back(app, spawner: spawner, row: "session-dotend-1", parks: 1)
        _ = try newSession(app, spawner: spawner, host: "dotend", besides: a.servers)
        let screen = app.otherElements["screenText"]
        app.typeText("exit\n")
        waitFor(!screen.exists, "the list by itself: the terminal is gone", timeout: 15)
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        waitFor((try? spawner.sshdServers()) == a.servers, "B's server ended, A's runs", timeout: 15)
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "none", "no row has the dot (is \(last.value ?? "nil"))", timeout: 10)
        let aRow = app.cells["session-dotend-1"]
        waitFor(aRow.exists && (aRow.value as? String) == "resumable", "A is resumable (is \(aRow.value ?? "nil"))",
                timeout: 10)
        XCTAssertFalse(app.cells["session-dotend-2"].exists, "B's row is gone")
        app.terminate()

        launchNormally(app, spawner: spawner)
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 15), "the host list")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(screen.exists, "no session is opened: none has the dot")
        waitFor((last.value as? String) == "none", "lastSession is none (is \(last.value ?? "nil"))", timeout: 10)
        waitFor(aRow.exists && (aRow.value as? String) == "resumable", "A is still resumable (is \(aRow.value ?? "nil"))",
                timeout: 10)
        XCTAssertEqual(try spawner.sshdServers(), a.servers, "nothing was started or ended")
        attachScreenshot(app, "launch-shows-the-list-after-the-dot-ended")
    }

    /// Step 11b (DESIGN.md 2.5, 5.2, 3.3 E1, 3.5 W4): "End Session" from the "…" button clears
    /// "last looked at" in the alert's action, before the pop, so that nothing of the ending can
    /// be interrupted before the dot is gone. The session's server is stopped (SIGSTOP), so the
    /// shutdown is not answered and the row reads "Ending…" for 11 s; meanwhile no row has the
    /// dot. Then SIGCONT.
    func testEndSessionClearsTheDotBeforeTheShutdown() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let a = try openSession(app, spawner: spawner, name: "enddot")
        stopTheAppFirst(app)
        let server = a.servers[0]
        defer { _ = try? spawner.signalSSHDServer(pid: server, "CONT") }

        XCTAssertTrue(try spawner.signalSSHDServer(pid: server, "STOP"), "SIGSTOP to \(server)")
        endSessionFromTerminal(app)
        let row = app.cells["session-enddot-1"]
        waitFor((row.value as? String) == "ending", "the row reads Ending… (is \(row.value ?? "nil"))", timeout: 5)
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label == %@", "Ending…")).firstMatch.exists,
                      "the row says Ending…")
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "none",
                "no row has the dot while the shutdown is in flight (is \(last.value ?? "nil"))", timeout: 5)
        XCTAssertEqual(row.value as? String, "ending", "still ending: the dot went before the end did")
        attachScreenshot(app, "end-session-clears-the-dot")

        XCTAssertTrue(try spawner.signalSSHDServer(pid: server, "CONT"), "SIGCONT to \(server)")
        waitFor(!row.exists || (row.value as? String) != "ending",
                "the end returned (the row: \(row.exists ? (row.value as? String) ?? "nil" : "gone"))", timeout: 20)
    }

    /// Step 11b, B3 (DESIGN.md 3.3, reading 3, 10.3 item 4): a session dies on screen; its host is
    /// made unreachable (its SSH port edited to one where nothing listens, under
    /// `-uiTestingSkipColdStart`); the launch falls back on it (L3) and the new session's connect
    /// fails (the error banner); he goes back. The old record is kept, "Could not be resumed",
    /// without the dot, and the next launch shows the list instead of falling back into it again.
    /// Its server was never reached and runs on.
    func testAFallbackHeLeftDoesNotComeBack() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let a = try openSession(app, spawner: spawner, name: "fbleft")
        stopTheAppFirst(app)
        back(app, spawner: spawner, row: "session-fbleft-1", parks: 1)
        app.terminate()

        // A launch that shows the list and starts nothing arms `-debugCrashAfter` for the first
        // session started in it (A23): A, resumed from its row, dies on screen, its record dirty.
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSkipColdStart", "1",
                               "-uiTestingSpawnerPort", String(spawner.port), "-debugCrashAfter", "8"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 15), "the host list")
        let screen = app.otherElements["screenText"]
        let row = app.cells["session-fbleft-1"]
        waitFor(row.exists && (row.value as? String) == "resumable", "A is resumable (is \(row.value ?? "nil"))",
                timeout: 10)
        row.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "A's terminal")
        waitFor(screenRows(screen).contains(a.pidLine), "A's stored screen (\(a.pidLine))", timeout: 7)
        waitFor(app.state == .notRunning, "the process died with A on screen", timeout: 30)
        XCTAssertEqual(try spawner.sshdServers(), a.servers, "A's server outlives the crash")

        // The host becomes unreachable: its SSH port is one where nothing listens.
        relaunchShowingTheList(app, spawner: spawner)
        waitFor(row.exists && (row.value as? String) == "dead", "A could not be resumed (is \(row.value ?? "nil"))",
                timeout: 10)
        openEditor(app, row: "host-fbleft")
        replaceText(app, field: "field.port", with: "1")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list")
        app.terminate()

        // L3: A, looked at last and dirty, falls back; the new session's connect fails (on the
        // simulator a connect to port 1 is not refused but goes unanswered: the bootstrap gives
        // up after 10 s, "The host did not answer within 10 seconds").
        launchNormally(app, spawner: spawner)
        let status = app.staticTexts["sessionStatus"]
        waitFor(status.exists && (status.label.contains("did not answer") || status.label.contains("Could not connect")),
                "the fallback's error banner", timeout: 40)
        XCTAssertTrue(app.navigationBars["fbleft"].exists, "the fallback screen is on A's host")
        attachScreenshot(app, "fallback-he-left-the-error")

        // B3: back keeps the old record, without the dot.
        let hosts = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 10), "the back button")
        hosts.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        waitFor(row.exists && (row.value as? String) == "dead",
                "A's record is kept: Could not be resumed (is \(row.exists ? (row.value as? String) ?? "nil" : "gone"))",
                timeout: 10)
        app.terminate()

        launchNormally(app, spawner: spawner)
        waitFor(app.navigationBars["Hosts"].exists || screen.exists, "the launch shows a screen", timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(screen.exists, "the launch did not fall back into A again")
        XCTAssertTrue(app.navigationBars["Hosts"].exists, "the host list")
        XCTAssertFalse(status.exists, "no banner")
        waitFor(row.exists && (row.value as? String) == "dead", "A's row: Could not be resumed (is \(row.value ?? "nil"))",
                timeout: 10)
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Could not be resumed")).firstMatch.exists,
                      "the row says Could not be resumed")
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "none", "no row has the dot (is \(last.value ?? "nil"))", timeout: 10)
        XCTAssertEqual(try spawner.sshdServers(), a.servers, "A's server was never reached: it runs on")
        attachScreenshot(app, "fallback-he-left-the-list")
    }

    // MARK: Helpers

    /// Called right after `openSession`, whose teardown stops every server the test left:
    /// teardown blocks run last in, first out, so this one runs before that one, whether the test
    /// passed or failed. The app is stopped before the servers are: a session still on screen
    /// would otherwise find its server gone at the probe (15 s) and start a fallback server after
    /// the teardown, which the next test would find at "no servers left" (seen in this step's
    /// first run, and after a failed test in its check). A failed test's diagnostics are kept
    /// first, while the app is still as the failure left it (`tearDown` then does not keep them
    /// again). A failure inside `openSession` itself comes before this registration.
    private func stopTheAppFirst(_ app: XCUIApplication) {
        addTeardownBlock { [weak self] in
            if let self, !self.diagnosticsKept {
                self.diagnosticsKept = true
                self.keepDiagnosticsIfFailed()
            }
            app.terminate()
        }
    }

    /// A launch with the stored records and hosts and the launch's own cold start.
    private func launchNormally(_ app: XCUIApplication, spawner: MoshSpawner) {
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
    }

    /// "‹ Hosts" from the terminal: the list, then `parks` parks closed clean since the marks were
    /// last cleared (`park-clean`), then the row `resumable`.
    private func back(_ app: XCUIApplication, spawner: MoshSpawner, row: String, parks: Int,
                      file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the back button", file: file, line: line)
        button.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list", file: file, line: line)
        waitFor(((try? spawner.marks()) ?? []).filter { $0 == "park-clean" }.count >= parks,
                "park \(parks) closed clean", timeout: 20, file: file, line: line)
        let cell = app.cells[row]
        waitFor(cell.exists && (cell.value as? String) == "resumable",
                "\(row) is resumable", timeout: 10, file: file, line: line)
    }

    /// A tap on a host that has a session already (its host key is known: no question): a new
    /// session on it (3.1 H1). Returns its `pid-$$` row and its server, the one new beside
    /// `besides`.
    private func newSession(_ app: XCUIApplication, spawner: MoshSpawner, host: String, besides: [Int32],
                            file: StaticString = #filePath, line: UInt = #line) throws -> (pidLine: String, server: Int32) {
        let before = Set(besides)
        let row = app.cells["host-\(host)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the host's row", file: file, line: line)
        row.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the new session's terminal", file: file, line: line)
        expect(screen, contains: "$", timeout: 30, file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no question for a known host", file: file, line: line)
        app.typeText("echo pid-$$\n")
        var pidLine = ""
        waitFor({ pidLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !pidLine.isEmpty }(),
                "the new shell's pid", timeout: 15, file: file, line: line)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { !before.contains($0) }; return added.count == 1 }(),
                "one new server beside \(besides)", timeout: 15, file: file, line: line)
        return (pidLine, added.first ?? 0)
    }

    private func pid(of pidLine: String) -> String {
        String(pidLine.dropFirst("pid-".count))
    }
}
