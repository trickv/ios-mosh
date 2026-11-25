import Foundation

/// A colour as the themes give it, 8 bits per channel.
struct RGB: Equatable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// `#RRGGBB`.
    var description: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// A terminal colour theme (docs/PLAN.md section 5, "Appearance", M8: two or three themes with
/// 16-colour palettes). `palette`, `foreground` and `background` nil: the terminal view's own
/// (SwiftTerm's palette, the system's label and background colours, which follow light and dark
/// mode): the look before M8.
struct TerminalTheme: Equatable {
    var id: String
    var name: String
    var palette: [RGB]?
    var foreground: RGB?
    var background: RGB?

    /// The Tango palette (Tango Desktop Project, public domain), as GNOME Terminal uses it.
    static let tangoPalette: [RGB] = [
        0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ].map(RGB.init)

    static let system = TerminalTheme(id: "system", name: "System", palette: nil, foreground: nil, background: nil)
    static let tangoDark = TerminalTheme(id: "tangoDark", name: "Tango Dark", palette: tangoPalette,
                                         foreground: RGB(0xD3D7CF), background: RGB(0x2E3436))
    static let tangoLight = TerminalTheme(id: "tangoLight", name: "Tango Light", palette: tangoPalette,
                                          foreground: RGB(0x2E3436), background: RGB(0xFFFFFF))

    static let all: [TerminalTheme] = [.system, .tangoDark, .tangoLight]

    static func named(_ id: String?) -> TerminalTheme? {
        all.first { $0.id == id }
    }
}

/// The colours of the bars over a terminal screen: the navigation bar with the session's title,
/// and the status bar above it. They follow the terminal, not the phone's light or dark mode:
/// their background is the terminal's own background, and their text is white or black,
/// whichever stands out more on it (the WCAG 2 contrast ratio). A dark terminal (System, which
/// SwiftTerm draws black in either mode, or Tango Dark) gets white text, a light one (Tango Light)
/// black text. The Hosts list and the other screens keep the system's colours.
struct TerminalBars: Equatable {
    static let white = RGB(0xFFFFFF)
    static let black = RGB(0x000000)

    var background: RGB

    /// White text (and a light status bar) rather than black.
    var lightText: Bool {
        Self.contrast(Self.white, background) >= Self.contrast(Self.black, background)
    }

    var text: RGB { lightText ? Self.white : Self.black }

    /// WCAG 2 relative luminance of an sRGB colour, 0 (black) to 1 (white).
    static func luminance(_ color: RGB) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG 2 contrast ratio, 1 (none) to 21 (black on white).
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// UI tests (`terminalBars`): `background=#RRGGBB text=#RRGGBB status=light|dark`.
    var testDescription: String {
        "background=\(background) text=\(text) status=\(lightText ? "light" : "dark")"
    }
}

/// The cursor's shape (docs/PLAN.md section 5, M8: cursor style). Blinking is a separate
/// setting.
enum CursorShape: String, CaseIterable, Equatable {
    case block, underline, bar

    var name: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .bar: return "Bar"
        }
    }
}

/// The terminal's look, as the Settings screen stores it. Applied by the terminal surface
/// (`TerminalSurface.apply`) when a terminal screen opens. The default (System, a blinking
/// block) is the look before M8.
struct TerminalAppearance: Equatable {
    var theme: TerminalTheme
    var cursorShape: CursorShape = .block
    var cursorBlinks: Bool = true
}
