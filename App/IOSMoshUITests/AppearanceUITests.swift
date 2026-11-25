import XCTest

/// M8 appearance on the simulator (docs/PLAN.md section 5, "Appearance"): a theme chosen in
/// Settings is stored and used by the next terminal screen; the colours are checked as the
/// terminal view reports them and in a screenshot of what it drew.
final class AppearanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTangoLightIsUsedByTheNextTerminal() throws {
        try checkTheme(id: "tangoLight", background: (0xFF, 0xFF, 0xFF), foreground: "#2E3436", red: (0xCC, 0x00, 0x00))
    }

    func testTangoDarkIsUsedByTheNextTerminal() throws {
        try checkTheme(id: "tangoDark", background: (0x2E, 0x34, 0x36), foreground: "#D3D7CF", red: (0xCC, 0x00, 0x00))
    }

    /// A steady bar chosen in Settings is the next terminal's cursor, and stays so after full
    /// repaints (a clear and a font size change, which resizes and repaints everything).
    func testCursorStyleIsUsedByTheNextTerminal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        openSettings(app)
        let bar = app.cells["settings.cursor.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "cursor rows")
        XCTAssertEqual(app.cells["settings.cursor.block"].value as? String, "selected", "block is the default")
        bar.tap()
        waitFor((bar.value as? String) == "selected", "bar selected")
        let blink = app.switches["settings.cursorBlink"]
        XCTAssertEqual(blink.value as? String, "1", "blinking is the default")
        blink.tap()
        waitFor((blink.value as? String) == "0", "blinking off")
        attachScreenshot(app, "settings-cursor")
        app.terminate()

        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingKeepSettings", "1",
                               "-debugMoshPort", String(server.port), "-debugMoshKey", server.key]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        let reported = app.otherElements["terminalAppearance"]
        waitFor(((reported.value as? String) ?? "").hasSuffix("cursor=steadyBar"),
                "the view's cursor is a steady bar (is \(reported.value ?? "nil"))")
        app.typeText("clear; echo cur-$((6*7))\n")
        expect(screen, containsLine: "cur-42", timeout: 15)
        app.typeKey("-", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.typeText("echo cur2-$((6*7))\n")
        expect(screen, containsLine: "cur2-42", timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(((reported.value as? String) ?? "").hasSuffix("cursor=steadyBar"),
                      "still a steady bar after full repaints: \(reported.value ?? "nil")")
        attachScreenshot(app, "cursor-steady-bar")
    }

    /// The terminal draws with the bundled Hack Nerd Font Mono (docs/PLAN.md section 5, App/Fonts):
    /// the view reports its four faces by PostScript name, at the default size and after a
    /// Cmd-minus; a powerline glyph and bold text reach the screen.
    func testTheTerminalDrawsWithTheBundledFont() throws {
        let faces = "HackNFM-Regular,HackNFM-Bold,HackNFM-Italic,HackNFM-BoldItalic"
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-debugMoshPort", String(server.port), "-debugMoshKey", server.key]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 15)
        let reported = app.otherElements["terminalAppearance"]
        waitFor(((reported.value as? String) ?? "").contains(" font=\(faces)@12 "),
                "the view draws with the bundled faces at 12 pt (is \(reported.value ?? "nil"))")

        // U+E0B0 (powerline arrow) as UTF-8, then bold and italic text.
        app.typeText("clear; printf 'pl-\\356\\202\\260-\\033[1mbold\\033[0m-\\033[3mital\\033[0m-%s\\n' $((6*7))\n")
        expect(screen, containsLine: "pl-\u{E0B0}-bold-ital-42", timeout: 15)
        attachScreenshot(app, "bundled-font")

        // The simulator ignores a Command combination until a character key has come by the
        // hardware-keyboard path (as in SettingsUITests): "q" and Return first.
        app.typeKey("q", modifierFlags: [])
        app.typeText("\n")
        app.typeKey("-", modifierFlags: .command)
        waitFor(((reported.value as? String) ?? "").contains(" font=\(faces)@11 "),
                "the bundled faces at 11 pt after Cmd-minus (is \(reported.value ?? "nil"))", timeout: 10)
    }

    // MARK: Helpers

    typealias Pixel = (r: Int, g: Int, b: Int)

    /// Chooses the theme in Settings, then opens a session in a new launch that keeps the
    /// settings: the view reports the theme's colours, the empty part of the terminal has the
    /// theme's background and `ESC [ 41 m` (palette colour 1) the theme's red.
    func checkTheme(id: String, background: Pixel, foreground: String, red: Pixel,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        openSettings(app)
        let row = app.cells["settings.theme.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "theme row", file: file, line: line)
        XCTAssertEqual(app.cells["settings.theme.system"].value as? String, "selected", "System is the default",
                       file: file, line: line)
        row.tap()
        waitFor((row.value as? String) == "selected", "\(id) selected", file: file, line: line)
        attachScreenshot(app, "settings-theme-\(id)")
        app.terminate()

        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingKeepSettings", "1",
                               "-debugMoshPort", String(server.port), "-debugMoshKey", server.key]
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing", file: file, line: line)
        expect(screen, contains: "$", timeout: 15)
        let reported = app.otherElements["terminalAppearance"]
        let hex = String(format: "#%02X%02X%02X", background.r, background.g, background.b)
        waitFor(((reported.value as? String) ?? "").contains("background=\(hex) foreground=\(foreground)"),
                "the view reports the theme (is \(reported.value ?? "nil"))", file: file, line: line)

        app.typeText("clear; printf '\\033[41m%40s\\033[0m\\n' ''\n")
        waitFor({ let r = rows(screen); return r.count > 1 && r[0].isEmpty && r[1].hasPrefix("$") }(),
                "a red row 0 and the prompt on row 1:\n\(rows(screen).joined(separator: "\n"))", timeout: 15,
                file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssertTrue(terminal.exists, "the terminal view", file: file, line: line)
        let frame = terminal.frame
        let shot = app.screenshot()
        let shotFile = XCTAttachment(screenshot: shot)
        shotFile.name = "theme-\(id)"
        shotFile.lifetime = .keepAlways
        add(shotFile)
        let image = shot.image
        let redPixel = pixel(image, at: CGPoint(x: frame.minX + 4, y: frame.minY + 4))
        let emptyPixel = pixel(image, at: CGPoint(x: frame.maxX - 4, y: frame.maxY - 4))
        XCTAssertTrue(close(redPixel, red), "palette colour 1 drawn as the theme's red: \(redPixel)", file: file, line: line)
        XCTAssertTrue(close(emptyPixel, background), "the empty part has the theme's background: \(emptyPixel)",
                      file: file, line: line)
    }

    func rows(_ screen: XCUIElement) -> [String] {
        ((screen.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["settingsButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Settings button")
        button.tap()
        XCTAssertTrue(app.tables["settings"].waitForExistence(timeout: 10), "Settings")
    }

    func close(_ a: Pixel, _ b: Pixel, tolerance: Int = 12) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// One pixel of a screenshot, at a point in screen coordinates, as 8-bit sRGB.
    func pixel(_ image: UIImage, at point: CGPoint) -> Pixel {
        guard let cgImage = image.cgImage else { return (-1, -1, -1) }
        let scale = CGFloat(cgImage.width) / image.size.width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
