import Foundation
import MoshSession
import MoshTerminal

/// Local echo (mosh's speculative echo, `--predict`; docs/notes/m10/DESIGN.md section 5), a
/// setting of each saved host (Trick, 2026-11-19: per host, mosh's defaults: Adaptive).
///
/// Stored in `hosts.json` as `{"mode": "...", "overwrite": false}`: the user's choice only,
/// never a guessed frame.
struct LocalEcho: Codable, Equatable {
    /// mosh's four `--predict` modes, by mosh's own names.
    enum Mode: String, CaseIterable, Codable {
        case adaptive, always, never, experimental

        var display: PredictionDisplay {
            switch self {
            case .adaptive: return .adaptive
            case .always: return .always
            case .never: return .never
            case .experimental: return .experimental
            }
        }

        var title: String {
            switch self {
            case .adaptive: return "Adaptive"
            case .always: return "Always"
            case .never: return "Never"
            case .experimental: return "Experimental"
            }
        }

        /// mosh's own words for the mode (`mosh --help`, mosh.pl:98-101).
        var detail: String {
            switch self {
            case .adaptive: return "Local echo for slower links (mosh's default)."
            case .always: return "Use local echo even on fast links."
            case .never: return "Never use local echo."
            case .experimental: return "Aggressively echo even when incorrect."
            }
        }
    }

    var mode: Mode
    /// mosh's `--predict-overwrite`: "prediction overwrites instead of inserting".
    var overwrite: Bool

    init(mode: Mode = .adaptive, overwrite: Bool = false) {
        self.mode = mode
        self.overwrite = overwrite
    }

    /// mosh's defaults: adaptive, insert.
    static let standard = LocalEcho()

    /// The modes the host editor offers. Whether Experimental is offered is not decided yet
    /// (Trick, 2026-11-19); adding it here is the whole change.
    static let offeredModes: [Mode] = [.adaptive, .always, .never]

    /// Whether the host editor shows mosh's overwrite switch. Not decided yet (Trick,
    /// 2026-11-19); `true` here is the whole change.
    static let offersOverwrite = false

    /// The overwrite switch's label, in mosh's words (`mosh --help`, mosh.pl:103).
    static let overwriteTitle = "Prediction overwrites instead of inserting"

    /// The core's settings for this choice (`ResumeCoordinator.Options.prediction`,
    /// `setPrediction`).
    var settings: PredictionSettings {
        PredictionSettings(display: mode.display, overwrite: overwrite)
    }

    /// A stored mode this build does not know reads as the default, so that one unknown
    /// value never makes the whole host list unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .mode)
        mode = text.flatMap(Mode.init(rawValue:)) ?? Self.standard.mode
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? Self.standard.overwrite
    }

    /// The setting of a session: its saved host's, or for a session without one (a debug
    /// launch) `-debugLocalEcho MODE` or mosh's default.
    static func forSession(host: SavedHost?) -> LocalEcho {
        if let host { return host.localEcho }
        return LocalEcho(mode: DebugLaunch.localEchoMode ?? standard.mode)
    }

    /// Posted by `HostStore.upsert` with the saved host (`object`), so that an open session of
    /// that host can follow a change at once (`setPrediction`).
    static let hostSaved = Notification.Name("IOSMosh.hostSaved")
}

/// The one frame the terminal screen draws (docs/notes/m10/DESIGN.md section 5 item 2).
///
/// While the mode is not Never only a `.display` replaces it: a `.screen` (the remote frame,
/// without the guesses) drawn between a `.screen` and its `.display` would take the guesses
/// off the screen for a refresh on every server state. In Never mode the session sends no
/// `.display` and the `.screen` is drawn. Until the first `.display` of a session (or after a
/// switch away from Never) the `.screen` is drawn too: no guess has been drawn yet that it
/// could hide, and a session whose `.display` never came would otherwise show nothing.
///
/// Bell, mouse mode and the last contact stay on `.screen` in every mode (the controller).
/// Nothing here is stored.
struct FrameToDraw {
    private(set) var display: PredictionDisplay
    /// The frame to draw, and a serial that changes with every replacement (the screen's tick
    /// draws when it changed).
    private(set) var framebuffer: Framebuffer?
    private(set) var serial: UInt64 = 0
    /// Whether `framebuffer` holds guesses (`DisplayFrame.hasPredictions`).
    private(set) var hasPredictions = false
    /// The newest `.screen`'s frame (the server's screen).
    private(set) var remote: Framebuffer?
    private var sawDisplay = false

    init(display: PredictionDisplay) {
        self.display = display
    }

    mutating func take(screen: Framebuffer) {
        remote = screen
        if display == .never || !sawDisplay {
            replace(with: screen, predictions: false)
        }
    }

    mutating func take(display frame: DisplayFrame) {
        guard display != .never else { return }
        sawDisplay = true
        replace(with: frame.framebuffer, predictions: frame.hasPredictions)
    }

    /// The mode the screen asked the session for. A switch to Never draws the newest server
    /// screen at once (the session's last `.display` may still hold guesses).
    mutating func setDisplay(_ newDisplay: PredictionDisplay) {
        guard newDisplay != display else { return }
        display = newDisplay
        if newDisplay == .never {
            sawDisplay = false
            if let remote { replace(with: remote, predictions: false) }
        }
    }

    /// Another session takes the screen (a fallback's new one): its first `.display` is
    /// awaited as for the first session.
    mutating func newSession() {
        sawDisplay = false
    }

    private mutating func replace(with framebuffer: Framebuffer, predictions: Bool) {
        self.framebuffer = framebuffer
        hasPredictions = predictions
        serial &+= 1
    }
}
