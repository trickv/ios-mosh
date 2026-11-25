import XCTest

/// M7 (docs/PLAN.md section 5, "Appearance" and "Key bar"): the Settings screen's font size
/// and tmux prefix, and the font size by pinch and Cmd-plus / Cmd-minus on an open terminal.
/// A new font size must reach the server as new columns and rows: checked with `stty size` on
/// the host.
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The terminal's size as the host sees it, from a fresh `stty size`.
    private func remoteSize(_ session: InputSession, tag: String,
                            file: StaticString = #filePath, line: UInt = #line) -> (rows: Int, columns: Int) {
        clearScreen(session, file: file, line: line)
        session.app.typeText("echo \(tag)-$(stty size | tr ' ' x)\n")
        let deadline = Date().addingTimeInterval(10)
        var last = ""
        while Date() < deadline {
            last = (session.screen.value as? String) ?? ""
            for row in last.split(separator: "\n") where row.hasPrefix("\(tag)-") {
                let parts = row.dropFirst(tag.count + 1).split(separator: "x")
                if parts.count == 2, let rows = Int(parts[0]), let columns = Int(parts[1]) {
                    return (rows, columns)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("no \(tag) size row. Screen:\n\(last)", file: file, line: line)
        return (0, 0)
    }

    /// Polls `stty size` until `condition` holds (a resize reaches the server after a 100 ms
    /// debounce and a round trip).
    private func waitForRemoteSize(_ session: InputSession, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line,
                                   _ condition: ((rows: Int, columns: Int)) -> Bool) -> (rows: Int, columns: Int) {
        var size = (rows: 0, columns: 0)
        for attempt in 0..<5 {
            size = remoteSize(session, tag: "sz\(attempt)", file: file, line: line)
            if condition(size) { return size }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("remote size \(size.rows)x\(size.columns): \(what)", file: file, line: line)
        return size
    }

    /// Settings: the font size stepper and the tmux prefix are stored, shown again after a
    /// relaunch, and used by the next terminal: a smaller font gives the server more columns,
    /// and the prefix key sends the new prefix.
    func testFontSizeAndTmuxPrefixFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Settings button on the host list")
        settingsButton.tap()
        let value = app.staticTexts["settings.fontSizeValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "12 pt", "default size")
        let decrement = app.buttons["settings.fontSizeStepper-Decrement"]
        for _ in 0..<4 { decrement.tap() }
        waitFor(app.staticTexts["settings.fontSizeValue"].label == "8 pt", "font size 8 pt")
        decrement.tap()
        waitFor(app.staticTexts["settings.fontSizeValue"].label == "8 pt", "8 pt is the smallest")

        // An invalid prefix is not stored; a valid one is.
        replaceText(app, field: "settings.tmuxPrefix", with: "M-a")
        app.textFields["settings.tmuxPrefix"].typeText("\n")
        waitFor((app.textFields["settings.tmuxPrefix"].value as? String) == "C-b", "invalid prefix rejected")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "is not a prefix")).firstMatch.exists)
        replaceText(app, field: "settings.tmuxPrefix", with: "C-a")
        app.textFields["settings.tmuxPrefix"].typeText("\n")
        waitFor((app.textFields["settings.tmuxPrefix"].value as? String) == "C-a", "prefix stored")
        attachScreenshot(app, "settings")

        // Stored: shown again after a relaunch that keeps the settings.
        app.terminate()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingKeepSettings", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["settings.fontSizeValue"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["settings.fontSizeValue"].label, "8 pt")
        XCTAssertEqual(app.textFields["settings.tmuxPrefix"].value as? String, "C-a")
        app.terminate()

        // The next terminal uses them. At 12 pt an iPhone 17 is about 55 columns wide; at 8 pt
        // well over 70.
        let session = try InputSession.launch(self, extraArguments: ["-uiTestingKeepSettings", "1"])
        defer { session.stop() }
        _ = waitForRemoteSize(session, "8 pt gives more than 70 columns") { $0.columns > 70 }
        clearScreen(session)
        session.app.typeText("cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.scrollKeyBar(toShow: "tmuxPrefix")
        XCTAssertEqual(session.key("tmuxPrefix").label, "^A")
        session.tap("tmuxPrefix")
        session.app.typeText("\n")
        expect(session.screen, rows: "^A", count: 1)
        session.screenshot(self, "settings-8pt")
    }

    /// Pinching the terminal makes the font bigger: fewer columns and rows reach the server.
    /// Cmd-minus makes it smaller again: more columns.
    func testPinchAndCommandMinusResizeTheTerminal() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        let start = remoteSize(session, tag: "start")
        XCTAssertGreaterThan(start.columns, 0)

        let terminal = session.app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "terminal view")
        terminal.pinch(withScale: 2, velocity: 1)
        let pinched = waitForRemoteSize(session, "fewer columns after the pinch") {
            $0.columns < start.columns && $0.rows < start.rows
        }
        session.screenshot(self, "pinched")

        // The simulator ignores a Command combination until a character key has come by the
        // hardware-keyboard path: "q" and Return first (the shell says "q: not found").
        session.app.typeKey("q", modifierFlags: [])
        session.app.typeText("\n")
        for _ in 0..<4 { session.app.typeKey("-", modifierFlags: .command) }
        _ = waitForRemoteSize(session, "more columns after Cmd-minus") { $0.columns > pinched.columns }
    }

    /// Settings has Help (the OSC 52 setup) and About (version and build from
    /// App/Version.xcconfig, the GPL notice, the source link).
    func testHelpAndAboutPages() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()

        XCTAssertTrue(app.cells["settings.help"].waitForExistence(timeout: 5))
        app.cells["settings.help"].tap()
        let help = app.textViews["helpText"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        let helpText = (help.value as? String) ?? ""
        XCTAssertTrue(helpText.contains("set -s set-clipboard on"), helpText)
        XCTAssertTrue(helpText.contains("Ms=\\E]52;c;%?%{0}%t%p1%s%;%p2%s\\a"), helpText)
        XCTAssertTrue(helpText.contains("require('vim.ui.clipboard.osc52')"), helpText)
        XCTAssertTrue(helpText.contains("about 12 KB"), helpText)
        XCTAssertTrue(helpText.contains("Never: Never use local echo."), helpText)
        app.navigationBars.buttons["Settings"].tap()

        XCTAssertTrue(app.cells["settings.about"].waitForExistence(timeout: 5))
        app.cells["settings.about"].tap()
        let about = app.textViews["aboutText"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        let aboutText = (about.value as? String) ?? ""
        let version = try NSRegularExpression(pattern: "Version [0-9]+\\.[0-9]+ \\([0-9]+\\) [0-9a-f]{7,}")
        XCTAssertNotNil(version.firstMatch(in: aboutText, range: NSRange(aboutText.startIndex..., in: aboutText)),
                        "version, build and commit: \(aboutText)")
        XCTAssertTrue(aboutText.contains("GNU General Public License"))
        XCTAssertTrue(aboutText.contains("https://github.com/trickv/ios-mosh"))
        attachScreenshot(app, "about")
    }

    /// Debug builds have "Crash Now" as the last row of Settings (docs/PLAN.md M6); it kills
    /// the process at once.
    func testCrashNowInSettingsKillsTheApp() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let crash = app.cells["settings.crashNow"]
        XCTAssertTrue(crash.waitForExistence(timeout: 5), "the debug row")
        crash.tap()
        waitFor(app.state == .notRunning, "the app is gone", timeout: 10)
    }
}
