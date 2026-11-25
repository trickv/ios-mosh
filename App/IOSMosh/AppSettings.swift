import UIKit

/// App-wide settings (docs/PLAN.md section 5, "Appearance" and "Key bar"), stored in
/// `UserDefaults.standard`:
/// - `terminalFontSize`: the terminal's font size in points, changed on the Settings screen,
///   by pinch and by Cmd-plus / Cmd-minus (M7, "stored").
/// - `keyBarTmuxPrefix`: the key bar's tmux prefix key in `C-x` form (default `C-b`).
/// - `terminalTheme`: the id of the colour theme (`TerminalTheme.all`, default "system", the
///   look before M8). A change applies to the next terminal screen.
/// - `terminalCursorShape` (block, underline, bar; default block) and `terminalCursorBlink`
///   (default on): the cursor style, also for the next terminal screen.
///
/// UI-test launches start from the defaults unless they pass `-uiTestingKeepSettings 1`, so
/// a test that changes a setting does not change the tests after it.
enum AppSettings {
    static let fontSizeKey = "terminalFontSize"
    static let tmuxPrefixKey = "keyBarTmuxPrefix"
    static let themeKey = "terminalTheme"
    static let cursorShapeKey = "terminalCursorShape"
    static let cursorBlinkKey = "terminalCursorBlink"

    /// SwiftTerm's own default size.
    static let defaultFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    static let defaultTmuxPrefix = "C-b"

    /// A size the terminal can use: whole points, within `fontSizeRange`.
    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: fontSizeKey)
            return stored > 0 ? clampedFontSize(CGFloat(stored)) : defaultFontSize
        }
        set {
            UserDefaults.standard.set(Double(clampedFontSize(newValue)), forKey: fontSizeKey)
        }
    }

    /// The prefix as typed in Settings; `C-b` when unset.
    static var tmuxPrefixText: String {
        UserDefaults.standard.string(forKey: tmuxPrefixKey) ?? defaultTmuxPrefix
    }

    /// Stores `text` if it is a valid prefix (`KeyBarView.prefixBytes`); false otherwise, and
    /// nothing is stored.
    @discardableResult
    static func setTmuxPrefix(_ text: String) -> Bool {
        guard KeyBarView.prefixBytes(text) != nil else { return false }
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespaces), forKey: tmuxPrefixKey)
        return true
    }

    /// The stored theme; an unknown id (a theme that is gone) reads as the default.
    static var theme: TerminalTheme {
        get { TerminalTheme.named(UserDefaults.standard.string(forKey: themeKey)) ?? .system }
        set { UserDefaults.standard.set(newValue.id, forKey: themeKey) }
    }

    static var cursorShape: CursorShape {
        get { CursorShape(rawValue: UserDefaults.standard.string(forKey: cursorShapeKey) ?? "") ?? .block }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cursorShapeKey) }
    }

    static var cursorBlinks: Bool {
        get { UserDefaults.standard.object(forKey: cursorBlinkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cursorBlinkKey) }
    }

    /// What a terminal screen applies when it opens.
    static var appearance: TerminalAppearance {
        TerminalAppearance(theme: theme, cursorShape: cursorShape, cursorBlinks: cursorBlinks)
    }

    /// At launch: a UI-test launch forgets the settings of earlier tests.
    static func resetForUITestingIfNeeded() {
        #if DEBUG
        guard UITestSupport.isUITesting, !UserDefaults.standard.bool(forKey: "uiTestingKeepSettings") else { return }
        for key in [fontSizeKey, tmuxPrefixKey, themeKey, cursorShapeKey, cursorBlinkKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
    }
}
