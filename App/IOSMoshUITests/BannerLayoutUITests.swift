import XCTest

/// The terminal screen's banners take room from the terminal instead of covering its first
/// rows: a visible banner sits above the terminal, the terminal starts below it and has fewer
/// rows, and the server is told so with an ordinary resize.
final class BannerLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A first session (no banner) gives the host's `stty size`; it dies in the foreground,
    /// so the relaunch takes the fallback and shows its banner, which stays for the whole
    /// session. With the banner: its frame and the terminal's do not overlap, the terminal
    /// starts at or below the banner's bottom, a line printed on row 1 after `clear` is the
    /// first row of the screen, and `stty size` has fewer rows (same columns) than before.
    func testTheFallbackBannerSitsAboveTheTerminalAndTakesItsRows() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let first = try spawner.newServer()
        defer { spawner.stop(pid: first.pid) }
        let second = try spawner.newServer()
        defer { spawner.stop(pid: second.pid) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingResetSessions", "1", "-debugMoshPort", String(first.port), "-debugMoshKey", first.key,
            "-debugCrashAfter", "25",
        ]
        app.launch()
        let screen = app.otherElements["screenText"]
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        let status = app.staticTexts["sessionStatus"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        XCTAssertFalse(status.exists, "no banner in the first session")
        let before = remoteSize(app, screen, tag: "full")
        XCTAssertNotEqual(app.state, .notRunning, "the crash came before the size was read")
        XCTAssertTrue(terminal.exists, "terminal view missing")
        let fullHeight = terminal.frame.height

        waitFor(app.state == .notRunning, "the app is gone", timeout: 40)

        app.launchArguments = [
            "-uiTesting", "1", "-uiTestingKeepSessions", "1",
            "-debugFallbackPort", String(second.port), "-debugFallbackKey", second.key,
        ]
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the fallback banner")
        XCTAssertTrue(status.label.contains("Previous session could not be resumed. Starting a new one."), status.label)
        XCTAssertTrue(status.label.contains("the record is dirty"), status.label)
        expect(screen, contains: "$", timeout: 15)
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "terminal view missing")

        // (a) The banner is above the terminal, not on it.
        let bannerFrame = status.frame, terminalFrame = terminal.frame
        XCTAssertGreaterThan(bannerFrame.height, 0, "the banner has a height")
        let overlap = bannerFrame.intersection(terminalFrame)
        XCTAssertTrue(overlap.isNull || overlap.height < 0.5 || overlap.width < 0.5,
                      "banner \(bannerFrame) overlaps terminal \(terminalFrame)")
        XCTAssertGreaterThanOrEqual(terminalFrame.minY, bannerFrame.maxY - 0.5,
                                    "terminal \(terminalFrame) starts below banner \(bannerFrame)")
        XCTAssertLessThan(terminalFrame.height, fullHeight - 0.5,
                          "the terminal is shorter with the banner (\(terminalFrame.height) vs \(fullHeight))")
        app.typeText("clear; echo row1-$((6*7))\n")
        waitFor(rows(screen).first == "row1-42",
                "row 1 of the screen is the printed line:\n\(rows(screen).joined(separator: "\n"))", timeout: 15)

        // (b) The server has the smaller size: fewer rows, the same columns.
        var with = remoteSize(app, screen, tag: "banner")
        for attempt in 0..<5 where with.rows >= before.rows {
            Thread.sleep(forTimeInterval: 1)
            with = remoteSize(app, screen, tag: "banner\(attempt)")
        }
        XCTAssertLessThan(with.rows, before.rows, "fewer rows with the banner (\(with) vs \(before))")
        XCTAssertEqual(with.columns, before.columns, "the same columns")
        XCTAssertTrue(status.exists, "the banner is still shown")
        attachScreenshot(app, "fallback-banner-above-terminal")
    }

    // MARK: Helpers

    private func rows(_ screen: XCUIElement) -> [String] {
        ((screen.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The terminal's size as the host sees it, from a fresh `stty size` on a cleared screen.
    private func remoteSize(_ app: XCUIApplication, _ screen: XCUIElement, tag: String,
                            file: StaticString = #filePath, line: UInt = #line) -> (rows: Int, columns: Int) {
        app.typeText("clear; echo \(tag)-$(stty size | tr ' ' x)\n")
        let deadline = Date().addingTimeInterval(10)
        var last = ""
        while Date() < deadline {
            last = (screen.value as? String) ?? ""
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
}
