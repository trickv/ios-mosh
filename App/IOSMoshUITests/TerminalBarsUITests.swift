import XCTest

/// The bars over the terminal (the navigation bar with the session's title, and the status bar
/// above it) take the terminal's own colours (`TerminalBars`), whatever the phone's light or dark
/// mode; the Hosts list keeps the system's. Checked on the screen itself: in a screenshot, the
/// title's and the status bar's text must stand out from the bar behind it (WCAG 2 contrast ratio
/// at least 4.5) and that bar must have the terminal's background
/// (docs/notes/publication/screenshots.md, "Seen while making them": in light mode the title and
/// the status bar were black on the black terminal).
///
/// The appearance is made certain, not assumed: `XCUIDevice.shared.appearance` is set before and
/// after the launch, and the test goes on only once the app itself reports that mode
/// (`terminalBars`, "system=light|dark", the terminal screen's trait collection); if it does not,
/// it switches to the other mode and back, up to five times (a simulator booted headless once kept
/// the old mode until it was rebooted; screenshots.md). It is put back at the end.
final class TerminalBarsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Light mode, the default theme (System, which SwiftTerm draws black): white title and status
    /// bar over the black terminal; back on the Hosts list, dark text on light bars again.
    func testInLightModeTheBarsOverTheDefaultTerminalCanBeRead() throws {
        keepAppearance()
        XCUIDevice.shared.appearance = .light
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1",
                               "-debugMoshPort", String(server.port), "-debugMoshKey", server.key]
        app.launch()
        try checkTerminalBars(app, mode: .light, name: "light-system")
        try checkHostsBars(app, mode: .light)
    }

    /// Dark mode, the light theme Tango Light (white background): black title and status bar over
    /// the white terminal; back on the Hosts list, light text on dark bars again.
    func testInDarkModeTheBarsOverTangoLightCanBeRead() throws {
        keepAppearance()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings button")
        settings.tap()
        let row = app.cells["settings.theme.tangoLight"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "theme row")
        row.tap()
        waitFor((row.value as? String) == "selected", "Tango Light selected")
        app.terminate()

        XCUIDevice.shared.appearance = .dark
        let spawner = try MoshSpawner.fromEnvironment()
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingKeepSettings", "1",
                               "-debugMoshPort", String(server.port), "-debugMoshKey", server.key]
        app.launch()
        try checkTerminalBars(app, mode: .dark, name: "dark-tangoLight", terminal: (0xFF, 0xFF, 0xFF))
        try checkHostsBars(app, mode: .dark)
    }

    // MARK: Checks

    typealias Pixel = (r: Int, g: Int, b: Int)

    /// The terminal screen is up in `mode` (as the app reports it); its title and status bar can
    /// be read and lie on the terminal's background (`terminal`, when the theme fixes it).
    private func checkTerminalBars(_ app: XCUIApplication, mode: XCUIDevice.Appearance, name: String,
                                   terminal expected: Pixel? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing", file: file, line: line)
        expect(screen, contains: "$", timeout: 15)
        XCUIDevice.shared.appearance = mode
        makeCertain(app, mode: mode, file: file, line: line)
        let bar = app.navigationBars["Session"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the terminal's navigation bar", file: file, line: line)
        let title = bar.staticTexts["Session"]
        XCTAssertTrue(title.exists, "the title \"Session\"", file: file, line: line)
        let terminalView = app.descendants(matching: .any)["terminal"]
        XCTAssertTrue(terminalView.exists, "the terminal view", file: file, line: line)
        // The status bar and the bar's colours settle after the push.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let shot = XCUIScreen.main.screenshot()
        keep(shot, name)
        let image = try XCTUnwrap(Pixels(shot.image), "screenshot pixels", file: file, line: line)
        let frame = terminalView.frame
        let terminalPixel = image.at(CGPoint(x: frame.maxX - 4, y: frame.maxY - 4))
        if let expected {
            XCTAssertTrue(close(terminalPixel, expected), "the terminal's background is the theme's: \(terminalPixel)",
                          file: file, line: line)
        }
        let report = (app.otherElements["terminalBars"].value as? String) ?? "nil"

        let titleArea = image.area(title.frame)
        XCTAssertTrue(close(titleArea.background, terminalPixel),
                      "the title's bar has the terminal's background \(terminalPixel): \(titleArea.background) (\(report))",
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(titleArea.contrast, 4.5,
                                    "the title stands out from its bar: \(titleArea) (\(report))", file: file, line: line)

        let statusArea = image.area(statusBarRect(bar))
        XCTAssertTrue(close(statusArea.background, terminalPixel),
                      "the status bar has the terminal's background \(terminalPixel): \(statusArea.background) (\(report))",
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(statusArea.contrast, 4.5,
                                    "the status bar's text stands out: \(statusArea) (\(report))", file: file, line: line)
    }

    /// Back on the Hosts list: its bars follow the system's mode again (light bars with dark text
    /// in light mode, dark bars with light text in dark mode), and both can be read.
    private func checkHostsBars(_ app: XCUIApplication, mode: XCUIDevice.Appearance,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let back = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the back button", file: file, line: line)
        back.tap()
        let bar = app.navigationBars["Hosts"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the host list", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let shot = XCUIScreen.main.screenshot()
        keep(shot, "hosts-\(mode == .dark ? "dark" : "light")")
        let image = try XCTUnwrap(Pixels(shot.image), "screenshot pixels", file: file, line: line)
        let title = bar.staticTexts["Hosts"]
        XCTAssertTrue(title.exists, "the title \"Hosts\"", file: file, line: line)
        for (what, area) in [("title", image.area(title.frame)), ("status bar", image.area(statusBarRect(bar)))] {
            let light = Self.luminance(area.background) > 0.5
            XCTAssertEqual(light, mode == .light, "the Hosts list's \(what) follows the system's mode: \(area)",
                           file: file, line: line)
            XCTAssertGreaterThanOrEqual(area.contrast, 4.5, "the Hosts list's \(what) can be read: \(area)",
                                        file: file, line: line)
        }
    }

    /// The left third of the strip above the navigation bar: the status bar's time (the middle has
    /// the Dynamic Island, black in either mode).
    private func statusBarRect(_ bar: XCUIElement) -> CGRect {
        let width = XCUIApplication().windows.firstMatch.frame.width
        return CGRect(x: 0, y: 0, width: width / 3, height: max(bar.frame.minY, 1))
    }

    /// Waits until the terminal screen reports `mode` as its trait collection's; switches the
    /// device to the other mode and back when it does not.
    private func makeCertain(_ app: XCUIApplication, mode: XCUIDevice.Appearance,
                             file: StaticString, line: UInt) {
        let word = mode == .dark ? "dark" : "light"
        let reported = app.otherElements["terminalBars"]
        func reportsMode() -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if ((reported.value as? String) ?? "").hasPrefix("system=\(word) ") { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return false
        }
        for _ in 0..<5 {
            if reportsMode() { return }
            XCUIDevice.shared.appearance = mode == .dark ? .light : .dark
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCUIDevice.shared.appearance = mode
        }
        XCTAssertTrue(reportsMode(), "the app shows \(word) mode (reports \(reported.value ?? "nil"))", file: file, line: line)
    }

    private func keepAppearance() {
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { XCUIDevice.shared.appearance = appearance }
    }

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "bars-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func close(_ a: Pixel, _ b: Pixel, tolerance: Int = 12) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// WCAG 2 relative luminance and contrast ratio, as `TerminalBars` in the app.
    static func luminance(_ p: Pixel) -> Double {
        func linear(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(p.r) + 0.7152 * linear(p.g) + 0.0722 * linear(p.b)
    }

    static func contrast(_ a: Pixel, _ b: Pixel) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A screenshot as 8-bit sRGB pixels, read in screen points.
    struct Pixels {
        let width: Int, height: Int, scale: CGFloat
        let data: [UInt8]

        init?(_ image: UIImage) {
            guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            width = cgImage.width
            height = cgImage.height
            scale = CGFloat(cgImage.width) / image.size.width
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                                              bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                return true
            }
            guard drawn else { return nil }
            data = bytes
        }

        private func pixel(x: Int, y: Int) -> Pixel {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        func at(_ point: CGPoint) -> Pixel {
            pixel(x: Int(point.x * scale), y: Int(point.y * scale))
        }

        /// The pixels of `rect` (points): the commonest colour is the background, and the text is
        /// the pixel that differs most from it.
        func area(_ rect: CGRect) -> Area {
            let x0 = Int(rect.minX * scale), x1 = Int(rect.maxX * scale)
            let y0 = Int(rect.minY * scale), y1 = Int(rect.maxY * scale)
            var counts: [Int: Int] = [:]
            var all: [Pixel] = []
            for y in stride(from: y0, to: max(y1, y0 + 1), by: 1) {
                for x in stride(from: x0, to: max(x1, x0 + 1), by: 1) {
                    let p = pixel(x: x, y: y)
                    all.append(p)
                    counts[p.r << 16 | p.g << 8 | p.b, default: 0] += 1
                }
            }
            let key = counts.max { $0.value < $1.value }?.key ?? 0
            let background: Pixel = (key >> 16 & 0xFF, key >> 8 & 0xFF, key & 0xFF)
            let text = all.max { TerminalBarsUITests.contrast($0, background) < TerminalBarsUITests.contrast($1, background) }
                ?? background
            return Area(background: background, text: text, contrast: TerminalBarsUITests.contrast(text, background))
        }
    }

    struct Area: CustomStringConvertible {
        let background: Pixel, text: Pixel
        let contrast: Double
        var description: String {
            String(format: "background (%d,%d,%d), text (%d,%d,%d), contrast %.2f",
                   background.r, background.g, background.b, text.r, text.g, text.b, contrast)
        }
    }
}
