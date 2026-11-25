import XCTest

/// "End Session" on a parked row through mosh's own shutdown (docs/notes/multi-session/DESIGN.md
/// step 12; section 6, 3.4 R1): the session is opened again, the shutdown is sent once the server
/// has shown that it is there, and the server exits when it has acknowledged it. No pid is needed,
/// so it also ends a session on a host where the app does not know the server's pid (his `hg`;
/// a `-debugMosh*` session has the same shape: no pid and no saved host). A server that does not
/// answer within 10 s gets no shutdown: the session is kept, resumable. The dot is cleared before
/// anything else, so an end the process does not survive starts nothing at the next launch.
///
/// Sessions on the spawner's sshd are started through the shared helpers of `SessionUITests.swift`
/// (`openSession` registers the teardown that stops what a test leaves), so the classes that run
/// after this one find no server left (section 8).
final class EndSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Set when the teardown of `stopTheAppFirst` kept the diagnostics of a failed test.
    private var diagnosticsKept = false

    override func tearDown() {
        if !diagnosticsKept { keepDiagnosticsIfFailed() }
        super.tearDown()
    }

    /// The dotted row's server is stopped (SIGSTOP), so the end waits for its contact; the process
    /// is killed 3 s into it. The launch shows the list: no session is started (no
    /// `connectProgress`, no terminal, no banner), no row has the dot, and the session is still
    /// listed. Control: stage a removed (the dot kept): the launch falls back into the session.
    func testAnInterruptedEndDoesNotStartASession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "interrupted")
        stopTheAppFirst(app)
        let server = opened.servers[0]
        defer { _ = try? spawner.signalSSHDServer(pid: server, "CONT") }
        back(app, spawner: spawner, row: "session-interrupted-1")
        let row = app.cells["session-interrupted-1"]
        let last = app.otherElements["lastSession"]
        waitFor((last.value as? String) == "session-interrupted-1", "the row has the dot (is \(last.value ?? "nil"))",
                timeout: 10)

        XCTAssertTrue(try spawner.signalSSHDServer(pid: server, "STOP"), "SIGSTOP to \(server)")
        endFromTheRow(app, row: row)
        waitFor((row.value as? String) == "ending", "the row reads Ending… (is \(row.value ?? "nil"))", timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(row.value as? String, "ending", "the end still waits for the silent server")
        app.terminate()

        launchNormally(app, spawner: spawner)
        let screen = app.otherElements["screenText"]
        let progress = app.descendants(matching: .any)["connectProgress"]
        let status = app.staticTexts["sessionStatus"]
        waitFor(app.navigationBars["Hosts"].exists || screen.exists || progress.exists, "the launch shows a screen",
                timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(progress.exists, "no session is being connected (no connectProgress)")
        XCTAssertFalse(screen.exists, "no terminal: the launch started nothing")
        XCTAssertFalse(status.exists, "no banner")
        XCTAssertTrue(app.navigationBars["Hosts"].exists, "the host list")
        waitFor((last.value as? String) == "none", "no row has the dot (is \(last.value ?? "nil"))", timeout: 10)
        waitFor(row.exists, "the session is still listed: an interrupted end deletes nothing", timeout: 10)
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "no server was started")
        attachScreenshot(app, "interrupted-end-the-list")
    }

    /// A parked session on a saved host, its server running: "End Session" on its row asks with
    /// the text of 4.6, ends it through mosh (the server leaves `/sshd/servers`), and the row
    /// goes, with no `old-server-killed` mark (no SSH kill) and no error. Control: stage g removed
    /// (the SSH way after the contact): the identity-checked kill, `old-server-killed`.
    func testEndSessionOnAParkedSessionOfAHost() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "endhost")
        stopTheAppFirst(app)
        let server = opened.servers[0]
        back(app, spawner: spawner, row: "session-endhost-1")
        let row = app.cells["session-endhost-1"]

        try spawner.clearMarks()
        endFromTheRow(app, row: row)
        waitFor((try? spawner.sshdServers()).map { !$0.contains(server) } == true,
                "the server \(server) left (servers: \((try? spawner.sshdServers()) ?? []))", timeout: 20)
        let host = app.cells["host-endhost"]
        waitFor((host.value as? String) == "none" && !row.exists,
                "the session's row is gone (host: \(host.value ?? "nil"))", timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")
        let marks = try spawner.marks()
        XCTAssertFalse(marks.contains("old-server-killed"), "no identity-checked kill: mosh ended it (marks: \(marks))")
        XCTAssertEqual(marks.filter { $0.hasPrefix("old-server-") }, [], "nothing was asked over SSH (marks: \(marks))")
        XCTAssertEqual(app.otherElements["lastSession"].value as? String, "none", "no row has the dot")
        attachScreenshot(app, "end-parked-session-of-a-host")
    }

    /// The shape of `hg`: a `-debugMosh*` session has no pid and no saved host, so nothing can be
    /// asked over SSH. Parked, then "End Session" on its row: the server exits (it acknowledged
    /// mosh's shutdown), the row goes, and no `old-server-*` mark appears. Control: stage g removed
    /// (the SSH way after the contact): `old-server-nothing-to-ask`, the record forgotten and the
    /// server left running.
    func testEndSessionOnAParkedSessionWithoutAPid() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = try parkADebugSession(spawner: spawner, server: server)
        let row = debugRow(app)

        try spawner.clearMarks()
        endFromTheRow(app, row: row)
        waitFor((try? spawner.isAlive(pid: server.pid)) == false,
                "the server \(server.pid) exits: it acknowledged mosh's shutdown", timeout: 20)
        waitFor(!row.exists, "the session's row is gone", timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error")
        let marks = try spawner.marks()
        XCTAssertEqual(marks.filter { $0.hasPrefix("old-server-") }, [], "nothing was asked over SSH (marks: \(marks))")
        attachScreenshot(app, "end-parked-session-without-a-pid")
    }

    /// A `-debugMosh*` session (no pid, no saved host), parked, its server stopped with the
    /// spawner's `/stop`: "End Session" on its row waits about 10 s for the server, sends no
    /// shutdown, and says "Session Not Ended"; the row is still resumable; Forget removes it.
    /// Control: stage e removed (the shutdown without contact): not acknowledged, nobody to ask
    /// over SSH, the row goes.
    func testEndSessionWhenTheServerIsGoneKeepsTheSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = try parkADebugSession(spawner: spawner, server: server)
        let row = debugRow(app)

        spawner.stop(pid: server.pid)
        waitFor((try? spawner.isAlive(pid: server.pid)) == false, "the server \(server.pid) is gone", timeout: 10)
        try spawner.clearMarks()
        let began = endFromTheRow(app, row: row)
        waitFor((row.value as? String) == "ending", "the row reads Ending… (is \(row.value ?? "nil"))", timeout: 5)
        let problem = app.alerts["Session Not Ended"]
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "Session Not Ended")
        let waited = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(waited, 9, "the end waited about 10 s for the server before it gave up (\(waited) s)")
        XCTAssertTrue(problem.staticTexts.matching(NSPredicate(format: "label CONTAINS 'did not answer'")).firstMatch.exists,
                      "the reason: the host did not answer")
        XCTAssertTrue(problem.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The session is kept'")).firstMatch.exists,
                      "the session is kept")
        attachScreenshot(app, "end-server-gone-not-ended")
        problem.buttons["OK"].tap()
        waitFor(row.exists && (row.value as? String) == "resumable",
                "still resumable (is \(row.exists ? (row.value as? String) ?? "nil" : "gone"))", timeout: 10)
        let marks = try spawner.marks()
        XCTAssertEqual(marks.filter { $0.hasPrefix("old-server-") }, [], "nothing was asked over SSH (marks: \(marks))")

        swipe(app, row: row, "Forget")
        let forget = app.alerts["Forget Session?"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "the confirmation")
        forget.buttons["Forget"].tap()
        waitFor(!row.exists, "Forget removed the session", timeout: 10)
    }

    // MARK: Helpers

    /// As `LaunchUITests.stopTheAppFirst`: a teardown that keeps a failed test's diagnostics while
    /// the app is as the failure left it, then terminates the app, before the servers are stopped
    /// (teardown blocks run last in, first out; call it right after `openSession`).
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

    /// "‹ Hosts" from the terminal: the list, the park closed clean (`park-clean` since the marks
    /// were last cleared), then the row `resumable`.
    private func back(_ app: XCUIApplication, spawner: MoshSpawner, row: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the back button", file: file, line: line)
        button.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list", file: file, line: line)
        waitFor(((try? spawner.marks()) ?? []).contains("park-clean"), "the park closed clean", timeout: 20,
                file: file, line: line)
        let cell = row.map { app.cells[$0] } ?? debugRow(app)
        waitFor(cell.exists && (cell.value as? String) == "resumable",
                "\(row ?? "the debug session's row") is resumable (is \(cell.value ?? "nil"))", timeout: 10,
                file: file, line: line)
    }

    /// A `-debugMosh*` session to `server` at launch (no host, no pid), then back: parked.
    private func parkADebugSession(spawner: MoshSpawner, server: MoshSpawner.Server,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> XCUIApplication {
        try spawner.clearMarks()
        let app = XCUIApplication()
        stopTheAppFirst(app)
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the debug session's terminal", file: file, line: line)
        expect(screen, contains: "$", timeout: 15)
        back(app, spawner: spawner, file: file, line: line)
        return app
    }

    /// The one session row of a launch that reset the sessions and started a `-debugMosh*` one:
    /// a session without a saved host, `session-<id>`.
    private func debugRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
    }

    /// Swipes the row from the leading edge and taps one of its actions.
    private func swipe(_ app: XCUIApplication, row: XCUIElement, _ title: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        row.swipeRight()
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "swipe action \(title)", file: file, line: line)
        button.tap()
    }

    /// "End Session" from the row's swipe; the question says what ends (DESIGN.md 4.6, a parked
    /// row); confirmed. Returns when it was confirmed.
    @discardableResult
    private func endFromTheRow(_ app: XCUIApplication, row: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) -> Date {
        swipe(app, row: row, "End Session", file: file, line: line)
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation", file: file, line: line)
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS 'its shell and the programs in it stop'"))
                        .firstMatch.exists, "the question says what ends", file: file, line: line)
        XCTAssertFalse(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS 'over SSH'")).firstMatch.exists,
                       "not the SSH way", file: file, line: line)
        attachScreenshot(app, "end-session-question-parked-row")
        confirm.buttons["End Session"].tap()
        return Date()
    }
}
