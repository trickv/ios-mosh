@testable import IOSMosh
import MoshTerminal
import XCTest

/// Settings and font size (docs/PLAN.md section 5, "Appearance", M7).
final class SettingsTests: XCTestCase {
    private var savedFontSize: Any?
    private var savedPrefix: Any?
    private var savedTheme: Any?
    private var savedCursor: [Any?] = []

    override func setUp() {
        savedFontSize = UserDefaults.standard.object(forKey: AppSettings.fontSizeKey)
        savedPrefix = UserDefaults.standard.object(forKey: AppSettings.tmuxPrefixKey)
        savedTheme = UserDefaults.standard.object(forKey: AppSettings.themeKey)
        savedCursor = [AppSettings.cursorShapeKey, AppSettings.cursorBlinkKey].map { UserDefaults.standard.object(forKey: $0) }
    }

    override func tearDown() {
        UserDefaults.standard.set(savedFontSize, forKey: AppSettings.fontSizeKey)
        UserDefaults.standard.set(savedPrefix, forKey: AppSettings.tmuxPrefixKey)
        UserDefaults.standard.set(savedTheme, forKey: AppSettings.themeKey)
        UserDefaults.standard.set(savedCursor[0], forKey: AppSettings.cursorShapeKey)
        UserDefaults.standard.set(savedCursor[1], forKey: AppSettings.cursorBlinkKey)
    }

    // MARK: M8 themes

    func testThemesHaveSixteenColoursAndDistinctIds() {
        XCTAssertEqual(TerminalTheme.all.count, 3, "the plan's two or three themes")
        XCTAssertEqual(Set(TerminalTheme.all.map(\.id)).count, TerminalTheme.all.count)
        for theme in TerminalTheme.all where theme != .system {
            XCTAssertEqual(theme.palette?.count, 16, theme.id)
            XCTAssertNotNil(theme.foreground, theme.id)
            XCTAssertNotNil(theme.background, theme.id)
            XCTAssertNotEqual(theme.foreground, theme.background, theme.id)
        }
        XCTAssertNil(TerminalTheme.system.palette, "System keeps the view's own colours")
        XCTAssertEqual(TerminalTheme.tangoPalette[1].description, "#CC0000")
    }

    func testThemeIsStoredAndAnUnknownOneIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: AppSettings.themeKey)
        XCTAssertEqual(AppSettings.theme, .system, "default: the look before M8")
        AppSettings.theme = .tangoLight
        XCTAssertEqual(AppSettings.theme, .tangoLight)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.themeKey), "tangoLight")
        XCTAssertEqual(AppSettings.appearance.theme, .tangoLight)
        UserDefaults.standard.set("gone", forKey: AppSettings.themeKey)
        XCTAssertEqual(AppSettings.theme, .system)
    }

    func testCursorStyleIsStoredAndMapped() {
        UserDefaults.standard.removeObject(forKey: AppSettings.cursorShapeKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.cursorBlinkKey)
        XCTAssertEqual(AppSettings.cursorShape, .block, "default: SwiftTerm's blinking block, the look before M8")
        XCTAssertTrue(AppSettings.cursorBlinks)
        XCTAssertEqual(SwiftTermSurface.cursorStyle(.block, blinks: true).tagName, "blinkBlock")
        AppSettings.cursorShape = .bar
        AppSettings.cursorBlinks = false
        XCTAssertEqual(AppSettings.appearance.cursorShape, .bar)
        XCTAssertFalse(AppSettings.appearance.cursorBlinks)
        var tags: Set<String> = []
        for shape in CursorShape.allCases {
            for blinks in [true, false] { tags.insert(SwiftTermSurface.cursorStyle(shape, blinks: blinks).tagName) }
        }
        XCTAssertEqual(tags.count, 6, "every SwiftTerm style is reachable")
        UserDefaults.standard.set("triangle", forKey: AppSettings.cursorShapeKey)
        XCTAssertEqual(AppSettings.cursorShape, .block)
    }

    func testFontSizeIsClampedToWholePoints() {
        XCTAssertEqual(AppSettings.clampedFontSize(12.4), 12)
        XCTAssertEqual(AppSettings.clampedFontSize(12.6), 13)
        XCTAssertEqual(AppSettings.clampedFontSize(2), 8)
        XCTAssertEqual(AppSettings.clampedFontSize(100), 32)
        XCTAssertEqual(AppSettings.clampedFontSize(.nan), AppSettings.defaultFontSize)
    }

    func testFontSizeIsStored() {
        UserDefaults.standard.removeObject(forKey: AppSettings.fontSizeKey)
        XCTAssertEqual(AppSettings.fontSize, 12, "default")
        AppSettings.fontSize = 17.2
        XCTAssertEqual(AppSettings.fontSize, 17)
        AppSettings.fontSize = 50
        XCTAssertEqual(AppSettings.fontSize, 32)
    }

    func testPinchAndSteps() {
        XCTAssertEqual(FontZoom.pinchSize(start: 12, scale: 2), 24)
        XCTAssertEqual(FontZoom.pinchSize(start: 12, scale: 0.5), 8)
        XCTAssertEqual(FontZoom.pinchSize(start: 20, scale: 3), 32)
        XCTAssertEqual(FontZoom.steppedSize(from: 12, by: 1), 13)
        XCTAssertEqual(FontZoom.steppedSize(from: 8, by: -1), 8)
        XCTAssertEqual(FontZoom.steppedSize(from: 32, by: 1), 32)
    }

    func testOnlyAValidPrefixIsStored() {
        UserDefaults.standard.removeObject(forKey: AppSettings.tmuxPrefixKey)
        XCTAssertEqual(AppSettings.tmuxPrefixText, "C-b")
        XCTAssertFalse(AppSettings.setTmuxPrefix("M-a"))
        XCTAssertEqual(AppSettings.tmuxPrefixText, "C-b")
        XCTAssertTrue(AppSettings.setTmuxPrefix(" C-a "))
        XCTAssertEqual(AppSettings.tmuxPrefixText, "C-a")
        XCTAssertEqual(KeyBarView.configuredTmuxPrefix(), [0x01])
    }

    func testKeyCommands() {
        let commands = FontZoom.keyCommands(bigger: #selector(UIResponder.copy(_:)), smaller: #selector(UIResponder.paste(_:)))
        XCTAssertEqual(commands.map(\.input), ["+", "=", "-"])
        XCTAssertTrue(commands.allSatisfy { $0.modifierFlags == .command })
    }

    func testSwipePagingRule() {
        XCTAssertTrue(SwipePagingRule.isActive(hostOption: true, mouseMode: .none))
        XCTAssertFalse(SwipePagingRule.isActive(hostOption: true, mouseMode: .vt220))
        XCTAssertFalse(SwipePagingRule.isActive(hostOption: false, mouseMode: .none))
        XCTAssertEqual(SwipePagingRule.key(for: CGPoint(x: 5, y: 120)), .pageUp)
        XCTAssertEqual(SwipePagingRule.key(for: CGPoint(x: -5, y: -120)), .pageDown)
        XCTAssertNil(SwipePagingRule.key(for: CGPoint(x: 0, y: 30)), "too short")
        XCTAssertNil(SwipePagingRule.key(for: CGPoint(x: 80, y: 100)), "too diagonal")
    }

    func testBellWatch() {
        var watch = BellWatch()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(watch.observe(bellCount: 3, isLive: false, session: "a", now: t0), "first screen sets the count")
        XCTAssertFalse(watch.observe(bellCount: 3, isLive: true, session: "a", now: t0), "no change")
        XCTAssertTrue(watch.observe(bellCount: 4, isLive: true, session: "a", now: t0 + 1))
        XCTAssertFalse(watch.observe(bellCount: 5, isLive: true, session: "a", now: t0 + 1.1), "within 0.25 s")
        XCTAssertFalse(watch.observe(bellCount: 6, isLive: false, session: "a", now: t0 + 3), "resume repaint")
        XCTAssertTrue(watch.observe(bellCount: 7, isLive: true, session: "a", now: t0 + 4))
        XCTAssertFalse(watch.observe(bellCount: 0, isLive: true, session: "b", now: t0 + 5), "a new session starts over")
        XCTAssertTrue(watch.observe(bellCount: 1, isLive: true, session: "b", now: t0 + 6))
    }

    func testAboutShowsVersionLicenceAndSource() {
        let text = AppTexts.about(version: "0.1", build: "104", sha: "1ab096e")
        XCTAssertTrue(text.contains("Version 0.1 (104) 1ab096e"))
        XCTAssertTrue(text.contains("GNU General Public License"))
        XCTAssertTrue(text.contains("https://github.com/trickv/ios-mosh"))
        XCTAssertTrue(text.contains("SwiftTerm, MIT License"))
        XCTAssertTrue(AppTexts.about().contains("Version \(BuildInfo.version) (\(BuildInfo.build)) \(BuildInfo.gitSHA)"))
    }

    func testHelpGivesTheClipboardSetup() {
        // The two tmux lines and the neovim lines of docs/SERVER-SETUP.md section 6, which were
        // proved end to end (docs/CLOUD.md, 2026-11-15 14:36 UTC), exactly.
        XCTAssertTrue(AppTexts.help.contains("set -s set-clipboard on"))
        XCTAssertTrue(AppTexts.help.contains(
            "set -as terminal-overrides ',xterm*:Ms=\\E]52;c;%?%{0}%t%p1%s%;%p2%s\\a'"))
        XCTAssertTrue(AppTexts.help.contains("local osc52 = require('vim.ui.clipboard.osc52')"))
        XCTAssertTrue(AppTexts.help.contains("copy = { ['+'] = copy('+'), ['*'] = copy('*') },"))
        XCTAssertTrue(AppTexts.help.contains("paste = { ['+'] = paste, ['*'] = paste },"))
        // The old lines, which do not work (SERVER-SETUP.md's table), are gone.
        XCTAssertFalse(AppTexts.help.contains("52;c%p1%s;"))
        XCTAssertFalse(AppTexts.help.contains("vim.g.clipboard = 'osc52'"))
        // The limits: the largest copy that arrives (12282 bytes) and the same text twice.
        XCTAssertTrue(AppTexts.help.contains("about 12 KB"))
        XCTAssertTrue(AppTexts.help.contains("same text copied twice in a row arrives once"))
        XCTAssertTrue(AppTexts.help.contains("mosh issue 1090"))
        // Local echo, in mosh's own words for each mode the host editor offers.
        for mode in LocalEcho.offeredModes {
            XCTAssertTrue(AppTexts.help.contains("\(mode.title): \(mode.detail)"), mode.title)
        }
    }
}
