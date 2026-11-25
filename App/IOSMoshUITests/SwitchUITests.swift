import XCTest

/// Back parks (docs/notes/multi-session/DESIGN.md step 9; 2.3, 3.3 B1, B6, 5.3): "‹ Hosts" saves
/// the session as the scene's save does and closes it; its row is resumable, its server runs on,
/// and a tap on the row resumes the same shell. Step 9's tests were written when a tap did not
/// yet wait for a park, so before every tap on a row they wait for the park's `park-clean` mark
/// (sent after the close) and the row's `resumable`; from step 10 the tap waits by itself, and
/// the waits stay (they also count the parks).
///
/// Step 10 (3.1, 3.2, 4.1, 4.5): a tap on a host is always a new session and a host with
/// sessions shows the "+"; a row tapped twice opens one terminal; a parked session whose server
/// is silent at a switch is kept and goes on once the server answers.
///
/// `testABackSwipeLetGoHalfWayParksNothing` and `testASwitchSendsNoResize` keep UIKit's
/// animations on (`-uiTestingAnimations 1`, section 8): a back swipe let go half way, and the
/// keyboard during the pop. They start a `-debugMosh*` session (no host to add) so that they need
/// few actions: with animations on, XCUITest may wait for the app to be idle before each one.
final class SwitchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        keepDiagnosticsIfFailed()
        super.tearDown()
    }

    /// B1: back parks; the row is resumable and its server still runs; the row resumes the same
    /// shell (the same `$$`), with no banner.
    func testBackParksAndTheRowResumesTheSameShell() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "park")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        let pid = String(opened.pidLine.dropFirst("pid-".count))

        back(app, spawner: spawner, row: "session-park-1", parks: 1)
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the server still runs: back did not end the session")
        XCTAssertEqual(app.cells["host-park"].value as? String, "sessions=1", "the host has its session")
        attachScreenshot(app, "list-after-back")

        let screen = app.otherElements["screenText"]
        let tapped = Date()
        app.cells["session-park-1"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        waitFor(screenRows(screen).contains(opened.pidLine), "the stored screen (\(opened.pidLine))", timeout: 15)
        reportTime(since: tapped, "tap on the row to the stored screen")
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(pid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner")
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the same server")
    }

    /// Ten switches between the sessions of two hosts: no banner ever, the same two servers, and
    /// no terminal screen alive on the list.
    func testSwitchingTenTimesBetweenTwoHosts() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let first = try openSession(app, spawner: spawner, name: "swa")
        defer { first.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        back(app, spawner: spawner, row: "session-swa-1", parks: 1)
        // It clears the marks before it opens the second session.
        let second = try openSessionOnAnotherHost(app, spawner: spawner, name: "swb")
        defer { try? spawner.stopSSHDServer(pid: second.server) }
        back(app, spawner: spawner, row: "session-swb-1", parks: 1)
        let servers = Set(first.servers + [second.server])
        XCTAssertEqual(servers.count, 2, "two servers")
        XCTAssertEqual(Set(try spawner.sshdServers()), servers, "both still run")

        let screen = app.otherElements["screenText"]
        let live = app.otherElements["liveTerminals"]
        var parks = 1
        for switchNumber in 1...10 {
            let (row, pidLine) = switchNumber % 2 == 1 ? ("session-swa-1", first.pidLine) : ("session-swb-1", second.pidLine)
            let pid = String(pidLine.dropFirst("pid-".count))
            app.cells[row].tap()
            XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal, switch \(switchNumber)")
            app.typeText("echo s\(switchNumber)-$$\n")
            expect(screen, containsLine: "s\(switchNumber)-\(pid)", timeout: 15)
            XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner, switch \(switchNumber)")
            parks += 1
            back(app, spawner: spawner, row: row, parks: parks)
            XCTAssertEqual(Set(try spawner.sshdServers()), servers, "the same two servers after switch \(switchNumber)")
            waitFor((live.value as? String) == "0",
                    "no terminal screen alive on the list after switch \(switchNumber) (is \(live.value ?? "nil"))", timeout: 10)
        }
        attachScreenshot(app, "list-after-ten-switches")
    }

    /// B6, with animations on: a back swipe from the terminal's left edge, held at 40% of the
    /// width and let go, is cancelled by UIKit. The terminal stays, nothing is parked (no
    /// `park-*` mark), and the same shell answers.
    func testABackSwipeLetGoHalfWayParksNothing() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = launchADebugSessionWithAnimations(spawner: spawner, server: server)
        let screen = app.otherElements["screenText"]
        let pid = shellPID(app, screen)

        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1)

        XCTAssertTrue(screen.waitForExistence(timeout: 60), "the terminal stays")
        XCTAssertTrue(app.navigationBars.buttons["sessionMenu"].exists, "the terminal's bar")
        app.typeText("echo still-$$\n")
        expect(screen, containsLine: "still-\(pid)", timeout: 60)
        let parks = ((try? spawner.marks()) ?? []).filter { $0.hasPrefix("park-") }
        XCTAssertEqual(parks, [], "nothing was parked")
    }

    /// 5.3, with animations on and a software keyboard up: a switch (back, then a tap on the
    /// row) sends no Resize. The shell prints "resized" at every SIGWINCH; a line printed before
    /// the park reaches the screen with the server's next frame. The keyboard check comes first,
    /// so that with a hardware keyboard and no software keyboard up the test fails instead of
    /// passing with nothing tested. The deciding assertion is the last line.
    ///
    /// The Mac's /bin/sh (bash 3.2) redraws its prompt at a SIGWINCH and the trap prints after
    /// it, so a Resize shows as the row "$ resized", not "resized" (step 9, 2026-11-22: the first
    /// build looked for the row "resized" only, and its control passed although the app sent two
    /// Resizes). So a Resize is any row that ends in "resized" and is not the line that sets the
    /// trap (that line ends in "armed").
    func testASwitchSendsNoResize() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = launchADebugSessionWithAnimations(spawner: spawner, server: server)
        let screen = app.otherElements["screenText"]
        let pid = shellPID(app, screen)
        app.typeText("trap 'echo resized' WINCH; echo armed\n")
        expect(screen, containsLine: "armed", timeout: 60)
        XCTAssertTrue(app.keyboards.count > 0, "a software keyboard is on screen")

        app.navigationBars.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 60), "the host list")
        waitFor(((try? spawner.marks()) ?? []).contains("park-clean"),
                "the park closed clean (marks: \((try? spawner.marks()) ?? []))", timeout: 60)
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        waitFor(row.exists && (row.value as? String) == "resumable", "the row is resumable (is \(row.value ?? "nil"))",
                timeout: 60)
        row.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 60), "the terminal")
        expect(screen, containsLine: "armed", timeout: 60)
        app.typeText("echo after-$$\n")
        expect(screen, containsLine: "after-\(pid)", timeout: 60)
        // A trap that ran with the last command prints in the same moment; one frame later at most.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let rows = screenRows(screen)
        let isResize = { (row: String) -> Bool in
            let text = row.trimmingCharacters(in: .whitespaces)
            return text.hasSuffix("resized") && !text.contains("trap ")
        }
        XCTAssertFalse(rows.contains(where: isResize), "a Resize reached the shell at the switch:\n\(rows.joined(separator: "\n"))")
    }

    // MARK: Step 10

    /// 3.1 H1, 4.1 (step 10): a tap on a host always starts a new session, also when the host
    /// has one. After the first session and back, the host's row has the "+" and `sessions=1`; a
    /// second tap on the host is a second shell (another `$$`) on a second server, and the host
    /// reads `sessions=2`; row 1 then resumes the first shell. With both ended the host has no
    /// session and no "+" (a host without sessions looks as before).
    func testTwoSessionsOnOneHost() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let first = try openSession(app, spawner: spawner, name: "two")
        var servers = first.servers
        defer { servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        let firstPid = String(first.pidLine.dropFirst("pid-".count))
        let host = app.cells["host-two"]
        let plus = host.descendants(matching: .any)["hostPlus"]

        back(app, spawner: spawner, row: "session-two-1", parks: 1)
        XCTAssertEqual(host.value as? String, "sessions=1", "the host has its session")
        XCTAssertTrue(plus.exists, "a host with a session shows the \"+\"")
        attachScreenshot(app, "list-host-plus")

        let screen = app.otherElements["screenText"]
        host.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the terminal")
        expect(screen, contains: "$", timeout: 30)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert, no host key prompt")
        app.typeText("echo pid-$$\n")
        var secondLine = ""
        waitFor({ secondLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !secondLine.isEmpty }(),
                "a shell's pid", timeout: 15)
        XCTAssertNotEqual(secondLine, first.pidLine,
                          "the host tap started a second shell, not the first one again:\n\(screenRows(screen).joined(separator: "\n"))")
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { !first.servers.contains($0) }; return added.count == 1 }(),
                "a second server beside the first (\(first.servers))", timeout: 15)
        servers += added
        XCTAssertEqual(Set(try spawner.sshdServers()), Set(servers), "two servers")

        back(app, spawner: spawner, row: "session-two-2", parks: 2)
        XCTAssertEqual(host.value as? String, "sessions=2", "two sessions under the host")
        XCTAssertTrue(plus.exists, "still the \"+\"")
        attachScreenshot(app, "list-two-sessions-one-host")

        app.cells["session-two-1"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        waitFor(screenRows(screen).contains(first.pidLine), "row 1 resumes the first shell (\(first.pidLine))", timeout: 15)
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(firstPid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner")

        // Both ended from the terminal: the second one's row is row 1 once the first is gone.
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == added, "the first server ended (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 15)
        let remaining = app.cells["session-two-1"]
        waitFor(remaining.exists && (remaining.value as? String) == "resumable" && (host.value as? String) == "sessions=1",
                "one session left, resumable (host: \(host.value ?? "nil"), row: \(remaining.value ?? "nil"))", timeout: 15)
        remaining.tap()
        waitFor(screenRows(screen).contains(secondLine), "row 1 is now the second shell (\(secondLine))", timeout: 15)
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "the second server ended", timeout: 15)
        waitFor((host.value as? String) == "none", "the host has no session (is \(host.value ?? "nil"))", timeout: 15)
        XCTAssertFalse(plus.exists, "a host without sessions has no \"+\"")
    }

    /// 3.2 S3 (step 10; step 9's review): a session row tapped twice quickly opens one terminal:
    /// the first tap sets "opening" and the second is dropped, so there is no "Session Not
    /// Available Now" and no second screen. One back then shows the list, with no terminal
    /// screen alive.
    func testARowTappedTwiceOpensOneTerminal() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "twice")
        defer { opened.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        let pid = String(opened.pidLine.dropFirst("pid-".count))
        back(app, spawner: spawner, row: "session-twice-1", parks: 1)

        let screen = app.otherElements["screenText"]
        let live = app.otherElements["liveTerminals"]
        app.cells["session-twice-1"].doubleTap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        waitFor(screenRows(screen).contains(opened.pidLine), "the stored screen (\(opened.pidLine))", timeout: 15)
        // Whatever the second tap did has happened by now.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert: the second tap was dropped")
        XCTAssertEqual(live.value as? String, "1", "one terminal screen alive")
        app.typeText("echo again-$$\n")
        expect(screen, containsLine: "again-\(pid)", timeout: 15)

        back(app, spawner: spawner, row: "session-twice-1", parks: 2)
        XCTAssertFalse(screen.exists, "one back reaches the list")
        waitFor((live.value as? String) == "0", "no terminal screen alive on the list (is \(live.value ?? "nil"))", timeout: 10)
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the same server")
    }

    /// 3.2 S10 (step 10, kept out of step 9 to keep it small): a parked session's server stops
    /// answering (SIGSTOP). A tap on its row shows the stored screen and, after mosh's 6.5 s, "Last
    /// contact"; back parks it again (before the probe at 15 s). The server answers again
    /// (SIGCONT); a tap: the stored screen, no fallback, the same `$$`, and `echo after-$$` typed
    /// then appears, so the session is live, not only its stored screen.
    func testASilentServerAtASwitch() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        let opened = try openSession(app, spawner: spawner, name: "silent")
        let server = opened.servers[0]
        defer {
            _ = try? spawner.signalSSHDServer(pid: server, "CONT")
            try? spawner.stopSSHDServer(pid: server)
        }
        let pid = String(opened.pidLine.dropFirst("pid-".count))
        back(app, spawner: spawner, row: "session-silent-1", parks: 1)

        XCTAssertTrue(try spawner.signalSSHDServer(pid: server, "STOP"), "SIGSTOP to \(server)")
        let screen = app.otherElements["screenText"]
        app.cells["session-silent-1"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        waitFor(screenRows(screen).contains(opened.pidLine), "the stored screen (\(opened.pidLine))", timeout: 15)
        let contact = app.staticTexts["contactBanner"]
        waitFor(contact.exists && contact.label.hasPrefix("Last contact"), "\"Last contact\" while the server is silent",
                timeout: 12)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        back(app, spawner: spawner, row: "session-silent-1", parks: 2)

        XCTAssertTrue(try spawner.signalSSHDServer(pid: server, "CONT"), "SIGCONT to \(server)")
        app.cells["session-silent-1"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the terminal")
        waitFor(screenRows(screen).contains(opened.pidLine), "the stored screen again (\(opened.pidLine))", timeout: 15)
        app.typeText("echo after-$$\n")
        expect(screen, containsLine: "after-\(pid)", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no fallback banner")
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the same server")
    }

    // MARK: Step 13

    /// The UDP ports of the host of `testTheLimitOfThePortRange`: two, inside the spawner's sshd
    /// range (62700:62799), at its top end, away from the ports the other hosts' servers take
    /// first (mosh-server takes the first free port of a range).
    private let twoPorts = "62798:62799"

    /// 3.1 H3 (step 13; brief item 10): a host with two UDP ports, two sessions on it, a third
    /// tap on the host: the red banner names the range and keeps mosh's own lines ("Failed binding
    /// to", which also shows that mosh-server's words reach the app through the pty), and no
    /// third server runs. After "End Session" on one of the two rows and its server gone from
    /// `/sshd/servers` (right after an end the port may still be taken, review LC-17), a tap on
    /// the host starts a new session. Control: a range of three ports (the third tap starts a
    /// session).
    func testTheLimitOfThePortRange() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        // A first host with the sshd's whole range: the launch, the device key authorized, the
        // host key trusted, and the teardown that stops every server of the test range.
        let seed = try openSession(app, spawner: spawner, name: "seed")
        var started = seed.servers
        defer { started.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        back(app, spawner: spawner, row: "session-seed-1", parks: 1)

        let sshd = try spawner.sshd()
        addHost(app, fields: [
            "name": "limit", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": twoPorts, "remoteCommand": "/bin/sh",
        ])
        let host = app.cells["host-limit"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "the host with two ports")
        var limitServers: [Int32] = []
        for number in 1...2 {
            let server = try startASessionByTheHostTap(app, spawner: spawner, host: host, number: number)
            limitServers.append(server)
            started.append(server)
            back(app, spawner: spawner, row: "session-limit-\(number)", parks: 1 + number)
        }
        XCTAssertEqual(host.value as? String, "sessions=2", "two sessions under the host")
        let before = Set(try spawner.sshdServers())
        XCTAssertEqual(before, Set(seed.servers + limitServers), "three servers: the seed's and the two of the host")

        // The third tap: no free port in the range.
        host.tap()
        let status = app.staticTexts["sessionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "the red banner")
        let banner = status.label
        XCTAssertTrue(banner.contains("No free UDP port on limit in \(twoPorts)."), "the banner names the range:\n\(banner)")
        XCTAssertTrue(banner.contains("end a session on this host"), "the banner says what to do:\n\(banner)")
        XCTAssertTrue(banner.contains("Failed binding to"), "mosh's own lines reach the banner:\n\(banner)")
        XCTAssertFalse(banner.contains("could not be resumed"), "not a fallback: no row named:\n\(banner)")
        attachScreenshot(app, "port-range-full")
        // A server that started after all would be listed by now.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(Set(try spawner.sshdServers()), before, "no third server on the host")

        let button = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the back button")
        button.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        waitFor((host.value as? String) == "sessions=2", "still two sessions (is \(host.value ?? "nil"))", timeout: 10)

        // "End Session" on one of them, then its server gone before the next tap.
        let row = app.cells["session-limit-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "session-limit-1")
        row.swipeRight()
        let end = app.buttons["End Session"]
        XCTAssertTrue(end.waitForExistence(timeout: 5), "swipe action End Session")
        end.tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation")
        confirm.buttons["End Session"].tap()
        var remaining: [Int32] = []
        waitFor({ remaining = ((try? spawner.sshdServers()) ?? []).filter { limitServers.contains($0) }; return remaining.count == 1 }(),
                "one of the host's two servers left /sshd/servers (servers: \((try? spawner.sshdServers()) ?? []))",
                timeout: 20)
        waitFor((host.value as? String) == "sessions=1", "one session under the host (is \(host.value ?? "nil"))", timeout: 10)

        // A port is free again: a tap on the host starts a new session.
        let server = try startASessionByTheHostTap(app, spawner: spawner, host: host, number: 3)
        started.append(server)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no banner")
        XCTAssertEqual(Set(try spawner.sshdServers()).intersection(Set(limitServers + [server])), Set(remaining + [server]),
                       "the host's two servers: the one left and the new one")
    }

    /// A tap on `host` (a known host key: no prompt), the shell, `echo pid-$$`, and one new server
    /// in `/sshd/servers`; returns its pid. The marks are not cleared (`back` counts the parks).
    private func startASessionByTheHostTap(_ app: XCUIApplication, spawner: MoshSpawner, host: XCUIElement, number: Int,
                                           file: StaticString = #filePath, line: UInt = #line) throws -> Int32 {
        let before = Set(try spawner.sshdServers())
        host.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the terminal of session \(number)", file: file, line: line)
        let status = app.staticTexts["sessionStatus"]
        waitFor(screenRows(screen).contains { $0.contains("$") } || status.exists,
                "the shell of session \(number)", timeout: 30, file: file, line: line)
        XCTAssertFalse(status.exists, "no banner for session \(number): \(status.exists ? status.label : "")", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert, no host key prompt", file: file, line: line)
        app.typeText("echo pid-$$\n")
        waitFor(screenRows(screen).contains { $0.hasPrefix("pid-") }, "the shell's pid, session \(number)",
                timeout: 15, file: file, line: line)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { !before.contains($0) }; return added.count == 1 }(),
                "one new server for session \(number) (before: \(before.sorted()))", timeout: 15, file: file, line: line)
        return added.first ?? 0
    }

    // MARK: Helpers

    /// "‹ Hosts" from the terminal: the list, then the park of `parks` sessions in all closed clean
    /// (its `park-clean` marks since the last clear), then the row `resumable`.
    private func back(_ app: XCUIApplication, spawner: MoshSpawner, row: String, parks: Int,
                      file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the back button", file: file, line: line)
        button.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list", file: file, line: line)
        waitFor(((try? spawner.marks()) ?? []).filter { $0 == "park-clean" }.count >= parks,
                "park \(parks) closed clean (marks: \((try? spawner.marks()) ?? []))", timeout: 20, file: file, line: line)
        let cell = app.cells[row]
        waitFor(cell.exists && (cell.value as? String) == "resumable",
                "\(row) is resumable (is \(cell.value ?? "nil"))", timeout: 10, file: file, line: line)
    }

    /// A `-debugMosh*` session with animations on, over the list.
    private func launchADebugSessionWithAnimations(spawner: MoshSpawner, server: MoshSpawner.Server) -> XCUIApplication {
        try? spawner.clearMarks()
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingAnimations", "1",
            "-uiTestingSpawnerPort", String(spawner.port),
            "-debugMoshPort", String(server.port), "-debugMoshKey", server.key,
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 60), "the debug session's terminal")
        expect(screen, contains: "$", timeout: 60)
        return app
    }

    /// `echo pid-$$`; the shell's pid.
    private func shellPID(_ app: XCUIApplication, _ screen: XCUIElement) -> String {
        app.typeText("echo pid-$$\n")
        var pidLine = ""
        waitFor({ pidLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !pidLine.isEmpty }(),
                "the shell's pid", timeout: 60)
        return String(pidLine.dropFirst("pid-".count))
    }

    /// DESIGN.md risk 1: the time as XCUITest sees it (its own latency included), in the test log
    /// and the result bundle.
    private func reportTime(since start: Date, _ what: String) {
        let text = "switch timing: \(what): \(Int(Date().timeIntervalSince(start) * 1000)) ms"
        print(text)
        let note = XCTAttachment(string: text)
        note.name = "switch-timing"
        note.lifetime = .keepAlways
        add(note)
    }
}
