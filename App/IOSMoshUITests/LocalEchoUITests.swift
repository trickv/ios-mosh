import XCTest

/// Local echo in the app (M10, docs/notes/m10/DESIGN.md section 5; docs/PLAN.md "Local echo
/// (M10)"), against a real mosh-server from scripts/mosh-spawner.py.
///
/// Loopback has no delay, and mosh shows no guess on a fast link: the tests that look for a
/// guess ask the spawner for a server behind its delaying UDP relay (`/new?delay_ms=`, 400 ms
/// each way), so the server's echo of a key comes back at the earliest 800 ms after the key,
/// as on a slow mobile link. The app publishes the drawn rows and the rows of the server's
/// newest screen in one element (`localEcho`), taken in the same display tick, so "drawn
/// before the server's echo" is read from one sample: a row on the screen that holds typed
/// text the server's screen does not have yet. Timing does not decide the outcome; the
/// delay only makes the window long enough to be sampled.
final class LocalEchoUITests: XCTestCase {
    static let delayMs = 400

    override func setUp() {
        continueAfterFailure = false
    }

    /// One sample of the `localEcho` element.
    struct Sample: CustomStringConvertible {
        var head: String
        var drawn: [String]
        var remote: [String]

        init?(_ value: String) {
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let first = lines.first, let split = lines.firstIndex(of: "--- remote") else { return nil }
            head = first
            drawn = Array(lines[1..<split])
            remote = Array(lines[(split + 1)...])
        }

        func field(_ name: String) -> String? {
            head.split(separator: " ").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }

        var guesses: Bool { field("guesses") == "1" }

        var inputs: [Int] {
            (field("inputs") ?? "").split(separator: ",").compactMap { Int($0) }
        }

        /// A row whose drawn text runs ahead of the server's: it starts with the server's
        /// text of that row (at least `minimum` characters of it), adds more, and is a start of
        /// `target`.
        func guessShown(toward target: String, minimum: Int) -> Bool {
            guard guesses else { return false }
            for (index, row) in drawn.enumerated() where index < remote.count {
                let server = remote[index]
                if server.count >= minimum, row.count > server.count, row.hasPrefix(server), target.hasPrefix(row) {
                    return true
                }
            }
            return false
        }

        var description: String {
            ([head] + drawn.map { "drawn  |" + $0 } + remote.map { "remote |" + $0 }).joined(separator: "\n")
        }
    }

    private func launch(_ server: MoshSpawner.Server, _ extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTesting", "1", "-uiTestingResetSessions", "1",
            "-uiTestingHardwareKeyboard", "0",
            "-debugMoshPort", String(server.port),
            "-debugMoshKey", server.key,
        ] + extra
        app.launch()
        let element = app.otherElements["localEcho"]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "localEcho element missing")
        return (app, element)
    }

    /// Polls samples until one satisfies `condition`; returns it.
    @discardableResult
    private func waitForSample(
        _ element: XCUIElement, _ what: String, timeout: TimeInterval = 20,
        file: StaticString = #filePath, line: UInt = #line, _ condition: (Sample) -> Bool
    ) -> Sample? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Sample?
        while Date() < deadline {
            if let sample = Sample((element.value as? String) ?? "") {
                last = sample
                if condition(sample) { return sample }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        XCTFail("timed out waiting for: \(what). Last sample:\n\(last.map(String.init(describing:)) ?? "none")",
                file: file, line: line)
        return nil
    }

    private func remoteHasRow(_ sample: Sample, _ row: String) -> Bool { sample.remote.contains(row) }

    /// Plan row "a guess before the server's echo, then the server's text", with mosh's
    /// default mode (Adaptive) on a slow link and `/bin/sh` echoing what it gets.
    func testAGuessIsDrawnBeforeTheServersEchoAndThenTheServersText() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer(delayMs: Self.delayMs)
        defer { spawner.stop(pid: server.pid) }
        let (app, element) = launch(server)

        waitForSample(element, "the session's own setting is Adaptive") {
            $0.field("mode") == "adaptive" && $0.field("session") == "adaptive"
        }
        waitForSample(element, "the prompt") { self.remoteHasRow($0, "$") }
        // One echoed key first: mosh shows guesses on a row only once one was confirmed there.
        app.typeText("e")
        waitForSample(element, "the server's echo of the first key") { self.remoteHasRow($0, "$ e") }

        let target = "$ echo guess-ok"
        app.typeText("cho guess-ok")
        let early = waitForSample(element, "typed text drawn before the server has it") {
            $0.guessShown(toward: target, minimum: 3)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "local-echo-guess"
        shot.lifetime = .keepAlways
        add(shot)
        if let early { print("local echo: early sample\n\(early)") }

        // The server's echo replaces the guess: drawn and server agree, no guess left.
        waitForSample(element, "the server's text, with no guess left") {
            self.remoteHasRow($0, target) && $0.drawn.contains(target) && !$0.guesses
        }
        app.typeText("\n")
        waitForSample(element, "the command ran") { self.remoteHasRow($0, "guess-ok") && $0.drawn.contains("guess-ok") }
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no error banner")
    }

    /// A guess the server does not confirm is replaced by what the server sent: the spawner's
    /// "first-then-upper" program echoes the first key as it is (which confirms the row) and
    /// every later one upper-cased, so the guessed "y" must give way to the server's "Y".
    func testAWrongGuessIsReplacedByTheServersText() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer(delayMs: Self.delayMs, program: "first-then-upper")
        defer { spawner.stop(pid: server.pid) }
        let (app, element) = launch(server)

        waitForSample(element, "the program's ready line") { self.remoteHasRow($0, "ready") }
        app.typeText("x")
        waitForSample(element, "the server's echo of x") { self.remoteHasRow($0, "x") }
        app.typeText("y")
        waitForSample(element, "the guessed y drawn before the server's answer") {
            $0.guessShown(toward: "xy", minimum: 1)
        }
        waitForSample(element, "the server's Y in place of the guess") {
            self.remoteHasRow($0, "xY") && $0.drawn.contains("xY") && !$0.drawn.contains("xy") && !$0.guesses
        }
    }

    /// Never: on the same slow link, nothing is drawn that the server's screen does not hold,
    /// in any sample while the keys travel.
    func testNeverDrawsOnlyTheServersScreen() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer(delayMs: Self.delayMs)
        defer { spawner.stop(pid: server.pid) }
        let (app, element) = launch(server, ["-debugLocalEcho", "never"])

        waitForSample(element, "the session's own setting is Never") {
            $0.field("mode") == "never" && $0.field("session") == "never"
        }
        waitForSample(element, "the prompt") { self.remoteHasRow($0, "$") }
        app.typeText("e")
        waitForSample(element, "the server's echo of the first key") { self.remoteHasRow($0, "$ e") }
        app.typeText("cho never-ok")
        let deadline = Date().addingTimeInterval(4)
        var samples = 0
        while Date() < deadline {
            if let sample = Sample((element.value as? String) ?? "") {
                samples += 1
                XCTAssertFalse(sample.guesses, "no guess in Never mode:\n\(sample)")
                XCTAssertEqual(sample.drawn, sample.remote, "drawn is the server's screen:\n\(sample)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertGreaterThan(samples, 10, "the typing window was sampled")
        waitForSample(element, "the server's echo of the line") { self.remoteHasRow($0, "$ echo never-ok") }
    }

    /// DESIGN.md section 5 item 5: mosh predicts no read of more than 100 bytes (a paste), so a
    /// paste must reach `coordinator.type` as one array. 300 bytes put on the clipboard by the
    /// app itself (OSC 52), pasted with the Paste key and with Cmd-V.
    func testAPasteReachesTheSessionAsOneInput() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        let element = session.app.otherElements["localEcho"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        session.app.typeText("printf '\\033]52;c;%s\\a' \"$(printf '%0300d' 0 | base64)\"\n")
        expect(label: session.app.staticTexts["clipboardToast"], contains: "Copied 300 bytes")
        session.app.typeText("stty -echo; printf '\\033[?2004l'; cat >/dev/null\n")
        Thread.sleep(forTimeInterval: 1)

        let before = Sample((element.value as? String) ?? "")?.inputs ?? []
        session.tap("paste")
        let expected = Array((before + [300]).suffix(16))
        waitForSample(element, "one input of 300 bytes after \(before)") { $0.inputs == expected }

        // Cmd-V: a character key first (the simulator ignores a Command combination before one).
        session.app.typeKey("q", modifierFlags: [])
        session.app.typeKey("v", modifierFlags: .command)
        let withKey = Array((expected + [1, 300]).suffix(16))
        waitForSample(element, "\"q\", then one input of 300 bytes") { $0.inputs == withKey }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(Sample((element.value as? String) ?? "")?.inputs, withKey, "no pieces after it")
    }

    /// The host editor's setting: Adaptive for a new host, the offered modes only, stored per
    /// host across a relaunch, and passed to the session of that host (the session itself
    /// reports it).
    func testTheHostsSettingIsStoredAndReachesItsSession() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let sshd = try spawner.sshd()
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)

        addHost(app, fields: [
            "name": "echo", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ])
        addHost(app, fields: ["name": "other", "host": "other.example", "user": "u"])

        openEditor(app, row: "host-echo")
        expectChosen(app, "adaptive")
        XCTAssertFalse(app.buttons["localEcho.experimental"].exists, "Experimental is not offered")
        XCTAssertFalse(app.switches["switch.localEchoOverwrite"].exists, "the overwrite switch is not offered")
        let always = app.buttons["localEcho.always"]
        scrollTo(app, always)
        always.tap()
        expectChosen(app, "always")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        openEditor(app, row: "host-echo")
        expectChosen(app, "always")
        app.navigationBars.buttons["Hosts"].tap()
        openEditor(app, row: "host-other")
        expectChosen(app, "adaptive")
        app.navigationBars.buttons["Hosts"].tap()

        app.cells["host-echo"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "host key prompt")
        alert.buttons["Trust"].tap()
        let element = app.otherElements["localEcho"]
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        // The login shell's prompt ("sh-3.2$"): the session is up.
        waitForSample(element, "the session of the host runs with Always", timeout: 30) {
            $0.field("mode") == "always" && $0.field("session") == "always" && $0.remote.contains { $0.hasSuffix("$") }
        }
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "mosh-server ended", timeout: 15)
    }

    private func expectChosen(_ app: XCUIApplication, _ mode: String, file: StaticString = #filePath, line: UInt = #line) {
        for each in ["adaptive", "always", "never"] {
            let button = app.buttons["localEcho.\(each)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "row \(each)", file: file, line: line)
            let value = (button.value as? String) ?? ""
            XCTAssertEqual(value == "chosen", each == mode, "\(each) is \(value.isEmpty ? "not chosen" : value)",
                           file: file, line: line)
        }
    }
}
