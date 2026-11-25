import XCTest

/// The M5 screens: host list, host editor, keys screen.
final class HostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAddEditAndDeleteAHostAcrossRelaunches() throws {
        let app = XCUIApplication()
        // No saved hosts and no known host keys to start with.
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        XCTAssertTrue(app.cells["noHosts"].waitForExistence(timeout: 10), "empty host list")

        addHost(app, fields: ["name": "box-a", "host": "box.example", "user": "alice", "port": "2222"])
        let rowA = app.cells["host-box-a"]
        XCTAssertTrue(rowA.waitForExistence(timeout: 10), "new host in the list")
        XCTAssertTrue(rowA.staticTexts["alice@box.example:2222"].exists)

        // Saved: still there after a relaunch without the reset.
        app.terminate()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        XCTAssertTrue(app.cells["host-box-a"].waitForExistence(timeout: 10), "host survives a relaunch")

        // Edit: rename and change the user.
        openEditor(app, row: "host-box-a")
        replaceText(app, field: "field.name", with: "box-b")
        replaceText(app, field: "field.user", with: "bob")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.cells["host-box-b"].waitForExistence(timeout: 10), "renamed host in the list")
        XCTAssertTrue(app.cells["host-box-b"].staticTexts["bob@box.example:2222"].exists)
        waitFor(!app.cells["host-box-a"].exists, "old name gone")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.cells["host-box-b"].waitForExistence(timeout: 10), "edit survives a relaunch")
        XCTAssertEqual(app.cells.matching(identifier: "host-box-b").count, 1, "edited in place, not added")

        // Delete from the editor, with confirmation.
        openEditor(app, row: "host-box-b")
        let delete = app.buttons["deleteHost"]
        scrollTo(app, delete)
        delete.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Delete"].tap()
        waitFor(!app.cells["host-box-b"].exists, "deleted host gone")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        waitFor(!app.cells["host-box-b"].exists, "deletion survives a relaunch")

        attachScreenshot(app, "host-list")
    }

    func testAnInvalidHostIsNotSaved() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["addHost"].waitForExistence(timeout: 10))
        app.buttons["addHost"].tap()
        let host = app.textFields["field.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        host.typeText("box.example")
        // No user.
        app.buttons["saveHost"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["User is missing."].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["saveHost"].exists, "still in the editor")
    }

    /// The local echo rows of the editor (owner's report on build 183): with any of the three
    /// chosen, every row's title and detail start at the left edge of the editor's other
    /// labels (the section header), and no row moves when the choice changes. Before the fix,
    /// the rows without the checkmark centred their text.
    func testTheLocalEchoRowsStayLeftAlignedWhateverIsChosen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["addHost"].waitForExistence(timeout: 10))
        app.buttons["addHost"].tap()
        XCTAssertTrue(app.textFields["field.host"].waitForExistence(timeout: 5), "editor")

        let modes = ["adaptive", "always", "never"]
        let header = app.staticTexts["LOCAL ECHO"]
        scrollTo(app, app.buttons["localEcho.never"])
        XCTAssertTrue(header.waitForExistence(timeout: 5), "section header")
        var firstEdges: [String: CGFloat] = [:]
        for chosen in modes {
            let row = app.buttons["localEcho.\(chosen)"]
            scrollTo(app, row)
            row.tap()
            waitFor((row.value as? String) == "chosen", "\(chosen) chosen")
            let margin = header.frame.minX
            for mode in modes {
                let title = app.staticTexts["localEcho.\(mode).title"]
                let detail = app.staticTexts["localEcho.\(mode).detail"]
                XCTAssertTrue(title.waitForExistence(timeout: 5), "title of \(mode)")
                XCTAssertTrue(detail.exists, "detail of \(mode)")
                XCTAssertEqual(title.frame.minX, margin, accuracy: 0.5,
                               "\(chosen) chosen: title of \(mode) starts at \(title.frame.minX), the header at \(margin)")
                XCTAssertEqual(detail.frame.minX, margin, accuracy: 0.5,
                               "\(chosen) chosen: detail of \(mode) starts at \(detail.frame.minX), the header at \(margin)")
                if let first = firstEdges[mode] {
                    XCTAssertEqual(title.frame.minX, first, accuracy: 0.5, "\(mode) moved when \(chosen) was chosen")
                } else {
                    firstEdges[mode] = title.frame.minX
                }
            }
            attachScreenshot(app, "local-echo-\(chosen)")
        }
    }

    /// The device key is made once and kept in the Keychain: the same fingerprint after a
    /// relaunch.
    func testTheKeysScreenShowsAKeyThatIsStableAcrossLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        let first = readDeviceKey(app, screenshot: "keys")
        XCTAssertTrue(first.line.hasPrefix("ssh-ed25519 AAAA"), first.line)
        XCTAssertTrue(first.line.contains(" ios-mosh@"), first.line)
        XCTAssertTrue(first.fingerprint.hasPrefix("SHA256:"), first.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 7 + 43, first.fingerprint)

        app.terminate()
        app.launch()
        let second = readDeviceKey(app)
        XCTAssertEqual(second.fingerprint, first.fingerprint)
        XCTAssertEqual(second.line, first.line)

        // The host-list reset does not touch keys.
        app.terminate()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()
        XCTAssertEqual(readDeviceKey(app).fingerprint, first.fingerprint)
    }
}

extension XCTestCase {
    /// Polls a condition. Never a single read.
    func waitFor(
        _ condition: @autoclosure () -> Bool, _ what: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    /// Adds a host through the editor and saves it. Field keys as in HostEditorViewController
    /// (`field.<key>`).
    func addHost(_ app: XCUIApplication, fields: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        let add = app.buttons["addHost"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "add button", file: file, line: line)
        add.tap()
        XCTAssertTrue(app.textFields["field.host"].waitForExistence(timeout: 5), "editor", file: file, line: line)
        for key in ["name", "host", "port", "user", "serverPath", "locale", "udpPorts", "remoteCommand"] {
            guard let value = fields[key] else { continue }
            replaceText(app, field: "field.\(key)", with: value)
        }
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list", file: file, line: line)
    }

    func openEditor(_ app: XCUIApplication, row: String, file: StaticString = #filePath, line: UInt = #line) {
        let cell = app.cells[row]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "row \(row)", file: file, line: line)
        // The row's detail (info) button.
        cell.buttons.firstMatch.tap()
        XCTAssertTrue(app.textFields["field.host"].waitForExistence(timeout: 5), "editor", file: file, line: line)
    }

    func replaceText(_ app: XCUIApplication, field identifier: String, with text: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[identifier]
        scrollTo(app, field)
        field.tap()
        waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true, "\(identifier) has the keyboard focus", file: file, line: line)
        // The field's own clear button (clearButtonMode .whileEditing) shows only while it
        // holds text. The value alone cannot tell: an empty field reads as its placeholder.
        let clear = field.buttons.firstMatch
        if clear.exists {
            clear.tap()
            waitFor(!clear.exists, "\(identifier) cleared", file: file, line: line)
        }
        field.typeText(text)
        waitFor((field.value as? String) == text, "\(identifier) reads \"\(text)\" (is \(field.value ?? "nil"))",
                file: file, line: line)
    }

    /// Swipes the editor up until the element can be tapped (the keyboard covers the lower
    /// part).
    func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) {
        var tries = 0
        while !element.isHittable, tries < 6 {
            app.scrollViews.firstMatch.swipeUp()
            tries += 1
        }
    }

    func readDeviceKey(
        _ app: XCUIApplication, screenshot: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) -> (line: String, fingerprint: String) {
        let keys = app.buttons["keysButton"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10), "Keys button", file: file, line: line)
        keys.tap()
        let fingerprint = app.staticTexts["keyFingerprint"]
        let publicKey = app.staticTexts["publicKey"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 10), "fingerprint", file: file, line: line)
        waitFor(fingerprint.label.hasPrefix("SHA256:"), "a fingerprint", file: file, line: line)
        let result = (publicKey.label, fingerprint.label)
        if let screenshot { attachScreenshot(app, screenshot) }
        app.navigationBars.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), file: file, line: line)
        return result
    }

    func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
