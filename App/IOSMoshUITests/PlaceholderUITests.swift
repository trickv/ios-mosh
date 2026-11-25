import XCTest

final class PlaceholderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTypedKeysReachTheTerminal() throws {
        let app = XCUIApplication()
        // The host list is the start screen since M5; the echo screen is behind a flag.
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-debugPlaceholder", "1"]
        app.launch()

        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "placeholder")

        app.typeText("abc")
        expect(screen, contains: "abc")

        // Hardware keyboard path.
        app.typeKey("d", modifierFlags: [])
        expect(screen, contains: "abcd")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "placeholder"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCTestCase {
    /// Polls the screen text. A single read would race the display tick.
    func expect(
        _ screen: XCUIElement, contains text: String, timeout: TimeInterval = 8,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (screen.value as? String) ?? ""
            if last.contains(text) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("screen does not contain \"\(text)\". Screen:\n\(last)", file: file, line: line)
    }
}
