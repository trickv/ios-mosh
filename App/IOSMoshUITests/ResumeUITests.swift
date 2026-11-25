import XCTest

/// M6 on the simulator (docs/PLAN.md, "App, on charlie's simulator"): a session survives the
/// death of the app's process when it was saved on leaving the foreground; a death in the
/// foreground and a server that is gone end in the fallback, with the reason shown.
final class ResumeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // No test turns the device any more (the size tests use -uiTestingBackgroundInset since
        // 2026-11-21), but a simulator left in landscape by an older run or by hand fails tests
        // that read earlier rows: testASecondResumeGenerationKeepsTheSameServer failed on a
        // 102x8 screen whose first `$$` line had scrolled off (2026-11-20). So portrait first.
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        keepDiagnosticsIfFailed()
        // Portrait again for the classes after this one, for the same reason as in setUp. Here,
        // not in a `defer`: a failed assertion ends the test without running its defers.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Connect, print `$$`, Home, wait until the snapshot is stored ("background-clean" from
    /// the app), `terminate()`, relaunch without the session arguments: the stored screen is
    /// back, `$$` is the same, a new command works and the spawner still sees the same server.
    func testASessionSavedInTheBackgroundResumesAfterTheAppIsKilled() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        try spawner.clearMarks()

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        app.typeText("echo pid-$$\n")
        let pidLine = waitForLine(screen, prefix: "pid-")
        app.typeText("echo before-$((6*7))\n")
        expect(screen, containsLine: "before-42", timeout: 15)

        XCUIDevice.shared.press(.home)
        waitFor([.runningBackground, .runningBackgroundSuspended].contains(app.state), "app in the background", timeout: 5)
        waitFor((try? spawner.marks())?.contains("background-clean") == true,
                "the app stored a clean snapshot (marks: \((try? spawner.marks()) ?? []))", timeout: 15)
        app.terminate()
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the server outlives the app")

        // No -debugMosh* arguments: the stored record is the only way back to the server.
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing after the relaunch")
        expect(screen, containsLine: "before-42", timeout: 15)
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == pidLine }.count >= 2, "the same $$ (\(pidLine)) printed again:\n\(rows(screen).joined(separator: "\n"))", timeout: 15)
        app.typeText("echo after-$((6*7))\n")
        expect(screen, containsLine: "after-42", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the same server")
        attachScreenshot(app, "resumed")
    }

    /// Review M6-10: a second resume generation. Save in the background, kill, resume; type,
    /// save in the background again, kill, resume again: the counters go through two clean
    /// marks. Same server and same `$$` throughout; the lines of both generations are on the
    /// screen after the second resume.
    func testASecondResumeGenerationKeepsTheSameServer() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        try spawner.clearMarks()

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        app.typeText("echo pid-$$\n")
        let pidLine = waitForLine(screen, prefix: "pid-")
        app.typeText("echo gen-$((6*7))-0\n")
        expect(screen, containsLine: "gen-42-0", timeout: 15)

        let relaunch = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        for generation in 1...2 {
            try spawner.clearMarks()
            XCUIDevice.shared.press(.home)
            waitFor([.runningBackground, .runningBackgroundSuspended].contains(app.state), "app in the background", timeout: 5)
            waitFor((try? spawner.marks())?.contains("background-clean") == true,
                    "generation \(generation): a clean snapshot (marks: \((try? spawner.marks()) ?? []))", timeout: 15)
            app.terminate()
            XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the server outlives the app")

            app.launchArguments = relaunch
            app.launch()
            XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing after relaunch \(generation)")
            for earlier in 0..<generation {
                expect(screen, containsLine: "gen-42-\(earlier)", timeout: 15)
            }
            XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner after relaunch \(generation)")
            app.typeText("echo gen-$((6*7))-\(generation)\n")
            expect(screen, containsLine: "gen-42-\(generation)", timeout: 15)
        }
        app.typeText("echo pid-$$\n")
        waitFor(rows(screen).filter { $0 == pidLine }.count >= 2,
                "the same $$ (\(pidLine)) printed again:\n\(rows(screen).joined(separator: "\n"))", timeout: 15)
        for generation in 0...2 {
            XCTAssertTrue(rows(screen).contains("gen-42-\(generation)"), "line of generation \(generation) on the screen")
        }
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the same server")
        attachScreenshot(app, "resumed-twice")
    }

    /// The 2026-11-20 flake of `testASecondResumeGenerationKeepsTheSameServer`: the app's view
    /// changed size after the background save had reported "background-clean"; the resize
    /// reached the session in the background, which made the record dirty until a second save,
    /// and the kill came in between: the relaunch fell back. A size change while the app is not
    /// active must not reach the session; it is announced when the app is active again.
    ///
    /// How the size changes: until 2026-11-21 the test turned the device while the app was in
    /// the background. Since the tools update of that day the simulator no longer lays out an
    /// app in the background for a turn (docs/MAC.md, log), and no test turns the device any
    /// more. The launch passes `-uiTestingBackgroundInset 40` instead (`BackgroundLayoutChange`):
    /// 0.8 s after the clean save the terminal screen widens its left safe-area inset and lays
    /// itself out, so its grid loses columns and the size path runs as for any layout by iOS.
    /// The app reports the held size as the mark "background-size-held-<columns>x<rows>"; the
    /// test requires one with fewer columns than before, so it cannot pass with no size change.
    ///
    /// Here: the narrower size is held, no input or resize reaches the session (the app reports
    /// one as a mark), and the kill then resumes on the same server without a fallback.
    func testASizeChangeInTheBackgroundLeavesTheSavedRecordClean() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let (app, screen, before) = try holdASizeChangeInTheBackground(spawner, server)
        app.terminate()
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the server outlives the app")

        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing after the relaunch")
        expect(screen, containsLine: before.line, timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no fallback alert")
        app.typeText("echo after-$((6*7))\n")
        expect(screen, containsLine: "after-42", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the same server")
        attachScreenshot(app, "resumed-after-a-size-change-in-the-background")
    }

    /// The size held in the background reaches the server once the app is active again: the
    /// same held size change as above, then back to the foreground without a kill (a killed
    /// app lays itself out afresh at launch, so only this path shows the held size announced).
    /// `stty size` in the shell then prints the held columns, not the first size.
    func testASizeHeldInTheBackgroundReachesTheServerInTheForeground() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let (app, screen, before) = try holdASizeChangeInTheBackground(spawner, server)
        let held = try XCTUnwrap(heldSizes(try spawner.marks()).last(where: { $0.columns < before.columns }))

        app.activate()
        waitFor(app.state == .runningForeground, "app in the foreground", timeout: 10)
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing in the foreground")
        app.typeText("echo size-$(stty size | tr ' ' x)\n")
        let after = waitForLine(screen, prefix: "size-", excluding: before.line)
        XCTAssertNotEqual(after, before.line, "the server has a new size")
        XCTAssertEqual(columns(ofSizeLine: after), held.columns,
                       "the server has the held width (\(held.columns) columns): \(after)")
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the same server")
        attachScreenshot(app, "foreground-after-a-size-change-in-the-background")
    }

    /// Both size tests up to the held size: connect with `-uiTestingBackgroundInset 40`, print
    /// `stty size`, Home, the clean save, then the held narrower size and nothing sent to the
    /// session in the background. Returns the app, its screen element and the first size line.
    private func holdASizeChangeInTheBackground(
        _ spawner: MoshSpawner, _ server: MoshSpawner.Server, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (XCUIApplication, XCUIElement, (line: String, columns: Int)) {
        try spawner.clearMarks()
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
            "-uiTestingBackgroundInset", "40",
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing", file: file, line: line)
        expect(screen, contains: "$", timeout: 15)
        app.typeText("echo size-$(stty size | tr ' ' x)\n")
        let first = waitForLine(screen, prefix: "size-", file: file, line: line)
        let firstColumns = try XCTUnwrap(columns(ofSizeLine: first), "a size line: \(first)", file: file, line: line)

        XCUIDevice.shared.press(.home)
        waitFor([.runningBackground, .runningBackgroundSuspended].contains(app.state), "app in the background", timeout: 5)
        waitFor((try? spawner.marks())?.contains("background-clean") == true,
                "a clean snapshot (marks: \((try? spawner.marks()) ?? []))", timeout: 15)
        // The layout comes 0.8 s after the save (the flake's delay), the resize timer 0.1 s later.
        // Wait for the narrower size held, or for a resize or input that reached the session.
        let narrower = { (marks: [String]) in self.heldSizes(marks).contains(where: { $0.columns < firstColumns }) }
        let reached = { (marks: [String]) in marks.contains("background-resize") || marks.contains("background-input") }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !((try? spawner.marks()).map { narrower($0) || reached($0) } ?? false) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // Time for anything that would follow the layout (the flake's resize came at once).
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let marks = try spawner.marks()
        XCTAssertFalse(reached(marks), "nothing reached the session in the background (marks: \(marks))", file: file, line: line)
        XCTAssertTrue(narrower(marks), "a narrower size (< \(firstColumns) columns) held in the background (marks: \(marks))",
                      file: file, line: line)
        XCTAssertNotEqual(app.state, .runningForeground, "still in the background", file: file, line: line)
        return (app, screen, (first, firstColumns))
    }

    /// The sizes in "background-size-held-<columns>x<rows>" marks, in arrival order.
    private func heldSizes(_ marks: [String]) -> [(columns: Int, rows: Int)] {
        let prefix = "background-size-held-"
        return marks.compactMap { mark in
            guard mark.hasPrefix(prefix) else { return nil }
            let parts = mark.dropFirst(prefix.count).split(separator: "x")
            guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]) else { return nil }
            return (columns, rows)
        }
    }

    /// "size-<rows>x<columns>" (`stty size`) -> columns.
    private func columns(ofSizeLine line: String) -> Int? {
        let parts = line.dropFirst("size-".count).split(separator: "x")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// A crash in the foreground leaves a dirty record: the next launch takes the fallback
    /// (message and reason shown, a new session on the fallback server), never a resume.
    /// The crash is `-debugCrashAfter` (the same `DebugCrash.now()` as Settings' "Crash Now",
    /// which cannot be reached while a session is open: leaving the terminal ends it).
    func testACrashInTheForegroundFallsBackToANewSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let first = try spawner.newServer()
        defer { spawner.stop(pid: first.pid) }
        let second = try spawner.newServer()
        defer { spawner.stop(pid: second.pid) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-debugMoshPort", String(first.port), "-debugMoshKey", first.key,
            "-debugCrashAfter", "12",
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        app.typeText("echo pid-$$\n")
        let firstPid = waitForLine(screen, prefix: "pid-")
        XCTAssertNotEqual(app.state, .notRunning, "the crash came before the shell answered")

        // The process dies with the session open and in the foreground.
        waitFor(app.state == .notRunning, "the app is gone", timeout: 30)

        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingKeepSessions", "1",
            "-debugFallbackPort", String(second.port), "-debugFallbackKey", second.key,
        ]
        app.launch()
        let status = app.staticTexts["sessionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the fallback banner")
        XCTAssertTrue(status.label.contains("Previous session could not be resumed. Starting a new one."), status.label)
        XCTAssertTrue(status.label.contains("the record is dirty"), "the reason is shown: \(status.label)")
        expect(screen, contains: "$", timeout: 15)
        XCTAssertFalse(rows(screen).contains(firstPid), "nothing of the old screen")
        app.typeText("echo pid-$$\n")
        let secondPid = waitForLine(screen, prefix: "pid-")
        XCTAssertNotEqual(secondPid, firstPid, "another shell: a new session")
        app.typeText("echo fb-$((6*7))\n")
        expect(screen, containsLine: "fb-42", timeout: 15)
        XCTAssertTrue(try spawner.isAlive(pid: first.pid), "the old server did not abort")
        attachScreenshot(app, "fallback-dirty")
    }

    /// The server is gone when the app comes back: the record resumes, nothing answers, the
    /// SSH probe finds no server, and the app falls back to a new session over SSH, with the
    /// reason shown.
    func testAServerGoneAtRelaunchFallsBackToANewSessionOverSSH() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let sshd = try spawner.sshd()
        XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run")
        try spawner.clearMarks()

        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)
        addHost(app, fields: [
            "name": "gone", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ])
        let row = app.cells["host-gone"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "host key prompt")
        alert.buttons["Trust"].tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 30)
        app.typeText("echo pid-$$\n")
        let firstPid = waitForLine(screen, prefix: "pid-")
        let oldServers = try spawner.sshdServers()
        XCTAssertEqual(oldServers.count, 1)

        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot", timeout: 15)
        app.terminate()
        try spawner.stopSSHDServer(pid: oldServers[0])
        waitFor((try? spawner.sshdServers()) == [], "the old server is gone", timeout: 10)

        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let status = app.staticTexts["sessionStatus"]
        waitFor(status.exists && status.label.contains("Previous session could not be resumed. Starting a new one."),
                "the fallback banner", timeout: 60)
        XCTAssertTrue(status.label.contains("The session has ended or the host was restarted."),
                      "the probe's reason is shown: \(status.label)")
        waitFor((try? spawner.sshdServers())?.count == 1, "a new server over SSH", timeout: 30)
        let newServers = try spawner.sshdServers()
        XCTAssertNotEqual(newServers, oldServers)
        app.typeText("echo pid-$$\n")
        let secondPid = waitForLine(screen, prefix: "pid-", excluding: firstPid)
        XCTAssertNotEqual(secondPid, firstPid)
        attachScreenshot(app, "fallback-server-gone")

        // Ending it from the terminal ends the new session too.
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the new server ended", timeout: 15)
    }

    /// Review M6-10: the identity-checked kill of a live old server, from the app. A session
    /// over SSH to a saved host dies in the foreground (`-debugCrashAfter`), so its record is
    /// dirty while its `mosh-server` still runs. The relaunch falls back: a new server over SSH,
    /// then the old one is killed after the identity check on the same connection. Afterwards
    /// the old pid is no longer a running `mosh-server` (the spawner's `/sshd/servers` checks
    /// each pid with `ps`; `/alive` knows only the servers it started itself).
    func testADirtyRecordAtRelaunchKillsTheLiveOldServerOverSSH() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let sshd = try spawner.sshd()
        XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run")

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1", "-uiTestingSpawnerPort", String(spawner.port),
            "-debugCrashAfter", "20",
        ]
        app.launch()
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)
        addHost(app, fields: [
            "name": "kill", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ])
        let row = app.cells["host-kill"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "host key prompt")
        alert.buttons["Trust"].tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 30)
        app.typeText("echo pid-$$\n")
        let firstPid = waitForLine(screen, prefix: "pid-")
        let oldServers = try spawner.sshdServers()
        XCTAssertEqual(oldServers.count, 1)
        XCTAssertNotEqual(app.state, .notRunning, "the crash came before the shell answered")

        // The process dies with the session open: the record is dirty, the server runs on.
        waitFor(app.state == .notRunning, "the app is gone", timeout: 40)
        XCTAssertEqual(try spawner.sshdServers(), oldServers, "the old server outlives the app")

        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let status = app.staticTexts["sessionStatus"]
        waitFor(status.exists && status.label.contains("Previous session could not be resumed. Starting a new one."),
                "the fallback banner", timeout: 30)
        XCTAssertTrue(status.label.contains("the record is dirty"), "the reason is shown: \(status.label)")
        expect(screen, contains: "$", timeout: 30)
        app.typeText("echo pid-$$\n")
        let secondPid = waitForLine(screen, prefix: "pid-", excluding: firstPid)
        XCTAssertNotEqual(secondPid, firstPid, "another shell: a new session")
        waitFor((try? spawner.sshdServers()).map { $0.count == 1 && !$0.contains(oldServers[0]) } == true,
                "the old server \(oldServers[0]) killed, the new one running (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 20)
        app.typeText("echo kill-$((6*7))\n")
        expect(screen, containsLine: "kill-42", timeout: 15)
        attachScreenshot(app, "fallback-old-server-killed")

        // Ending it from the terminal ends the new session too.
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the new server ended", timeout: 15)
    }

    // MARK: Helpers

    private func rows(_ screen: XCUIElement) -> [String] {
        ((screen.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Polls until a row starts with `prefix` (and is not `excluding`); returns it.
    private func waitForLine(
        _ screen: XCUIElement, prefix: String, excluding: String? = nil, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = rows(screen).first(where: { $0.hasPrefix(prefix) && $0 != excluding }) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("no row starts with \(prefix). Screen:\n\(rows(screen).joined(separator: "\n"))", file: file, line: line)
        return ""
    }
}
