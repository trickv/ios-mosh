import Darwin
import MoshTerminal
import UIKit

/// Launch arguments for UI tests. `-uiTesting 1` lands in UserDefaults.
enum UITestSupport {
    static var isUITesting: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "uiTesting")
        #else
        return false
        #endif
    }

    /// `-uiTestingSkipColdStart 1`: the launch shows the host list without the cold start (no
    /// record is resumed, finished or deleted at launch), so that a test sees a stored record
    /// in the list and acts on it from there. Debug builds and UI-test launches only.
    static var skipsColdStart: Bool {
        #if DEBUG
        return isUITesting && UserDefaults.standard.bool(forKey: "uiTestingSkipColdStart")
        #else
        return false
        #endif
    }

    /// `-uiTestingAnimations 1`: a UI-test launch keeps UIKit's animations and transitions on
    /// (`SceneDelegate` otherwise turns them off), for the two tests that need UIKit's own
    /// behaviour: a back swipe let go half way, and the keyboard during the pop
    /// (docs/notes/multi-session/DESIGN.md section 8, step 9). Debug builds and UI-test launches
    /// only.
    static var keepsAnimations: Bool {
        #if DEBUG
        return isUITesting && UserDefaults.standard.bool(forKey: "uiTestingAnimations")
        #else
        return false
        #endif
    }
}

/// `-uiTestingBackgroundInset N` (UI-test launches of Debug builds only): a real size change of
/// the terminal view after the background save, as iOS made one in the 2026-11-20 flake (a
/// layout 0.8 s after the save). Since the 2026-11-21 tools update the simulator no longer turns
/// an app in the background, so a UI test cannot make one from outside. The terminal screen
/// adds N points to its left safe-area inset and lays itself out: the grid loses columns and
/// the ordinary path (`onSizeChange`, `viewSizeChanged`, `announceSize`) runs by itself. Nothing
/// here sends a resize or names a size. Once per process, and only after a clean save.
struct BackgroundLayoutChange {
    /// How long after the save the layout comes (the flake's 0.8 s).
    static let delay: TimeInterval = 0.8

    /// Points to add to the left safe-area inset; nil: the launch asked for no change.
    let inset: Double?
    private(set) var done = false

    /// `argument`: the value of `-uiTestingBackgroundInset`; a number from 1 to 200.
    init(argument: String?) {
        inset = argument.flatMap(Double.init).flatMap { (1...200).contains($0) ? $0 : nil }
    }

    /// The launch's change, inert outside UI-test launches and in Release.
    static var fromLaunch: BackgroundLayoutChange {
        #if DEBUG
        guard UITestSupport.isUITesting else { return BackgroundLayoutChange(argument: nil) }
        return BackgroundLayoutChange(argument: UserDefaults.standard.string(forKey: "uiTestingBackgroundInset"))
        #else
        return BackgroundLayoutChange(argument: nil)
        #endif
    }

    /// A background save ended: the inset to add after `delay`, or nil (none asked for, the
    /// save was not clean, or the change was made already).
    mutating func insetAfterSave(clean: Bool) -> Double? {
        guard let inset, clean, !done else { return nil }
        done = true
        return inset
    }

    /// The mark a held size sends to the spawner: "background-size-held-<columns>x<rows>", so
    /// a test sees that a size change really reached the screen in the background, and which.
    static func heldMark(columns: Int, rows: Int) -> String {
        "background-size-held-\(columns)x\(rows)"
    }
}

/// UI tests run outside the app process and cannot read the terminal's cells.
/// In UI-test launches the visible rows are copied into this element's
/// accessibility value on every display tick. Tests poll it.
final class ScreenTextElement: UIView {
    private var last: String?

    func install(in parent: UIView) {
        frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "screenText"
        accessibilityValue = ""
        parent.addSubview(self)
    }

    func update(rows: [String]) {
        let text = rows.joined(separator: "\n")
        guard text != last else { return }
        last = text
        accessibilityValue = text
    }
}

/// The terminal view's colours and cursor as the view reports them
/// (`TerminalSurface.appearanceDescription`), published in UI-test launches as the value of
/// `terminalAppearance`; also the colours of the bars over the terminal (`TerminalBars`), as
/// `terminalBars`.
final class TerminalAppearanceElement: UIView {
    func install(in parent: UIView, identifier: String = "terminalAppearance") {
        frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityValue = ""
        parent.addSubview(self)
    }

    func update(_ text: String) {
        if accessibilityValue != text { accessibilityValue = text }
    }
}

/// Local echo as the UI tests see it (M10), published in UI-test launches as the value of
/// `localEcho`, from one display tick, so the drawn and the server's rows are one sample:
///
///     mode=<the screen's> session=<the session's> guesses=0|1 inputs=<sizes of the last inputs>
///     <the drawn rows, as screenText>
///     --- remote
///     <the rows of the newest .screen, trailing blanks trimmed>
final class LocalEchoElement: UIView {
    private var last: String?

    func install(in parent: UIView) {
        frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "localEcho"
        accessibilityValue = ""
        parent.addSubview(self)
    }

    func update(mode: String, session: String, guesses: Bool, drawn: [String], remote: [String], inputs: [Int]) {
        let head = "mode=\(mode) session=\(session) guesses=\(guesses ? 1 : 0) inputs=\(inputs.map(String.init).joined(separator: ","))"
        let text = ([head] + drawn + ["--- remote"] + remote).joined(separator: "\n")
        guard text != last else { return }
        last = text
        accessibilityValue = text
    }

    /// The visible text of each row, as mosh would write it, trailing blanks trimmed.
    static func rows(_ framebuffer: Framebuffer) -> [String] {
        (0..<framebuffer.ds.height).map { y in
            var text = Substring(String(decoding: framebuffer.rowText(y), as: UTF8.self))
            while text.last == " " { text.removeLast() }
            return String(text)
        }
    }
}

/// How many terminal screens exist, published for UI tests in the window as the value of
/// `liveTerminals`: a test checks that a terminal screen is freed after it is left.
final class LiveTerminalsElement: UIView {
    private var timer: Timer?

    func install(in window: UIWindow) {
        frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "liveTerminals"
        accessibilityValue = String(TerminalViewController.liveCount)
        window.addSubview(self)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.superview?.bringSubviewToFront(self)
            let text = String(TerminalViewController.liveCount)
            if self.accessibilityValue != text { self.accessibilityValue = text }
        }
    }
}

/// The session with the green dot (docs/notes/multi-session/DESIGN.md 4.1), published for UI
/// tests in the window as the value of `lastSession`: the accessibility identifier of the
/// dotted row (`session-<host>-<n>` or `session-<id>`), or `none`. The host list installs it
/// when it appears in a UI-test launch and sets it at every read of the records; while another
/// screen covers the list it keeps the list's last value.
final class LastSessionElement: UIView {
    static let shared = LastSessionElement()

    func install(in window: UIWindow) {
        guard superview !== window else { return }
        removeFromSuperview()
        frame = CGRect(x: 1, y: 0, width: 1, height: 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "lastSession"
        if accessibilityValue == nil { accessibilityValue = "none" }
        window.addSubview(self)
    }

    /// `identifier`: the dotted row's, or nil when no row has the dot.
    func update(_ identifier: String?) {
        let text = identifier ?? "none"
        if accessibilityValue != text { accessibilityValue = text }
        superview?.bringSubviewToFront(self)
    }
}

/// UI tests cannot read the app while it is in the background. In UI-test launches that pass
/// `-uiTestingSpawnerPort N`, the app reports lifecycle facts ("background-clean" when a save
/// left the record clean, "background-size-held-<columns>x<rows>" when a size change was held
/// while the scene was not active; "park-clean" or "park-not-resumable" when the park of a
/// session left by the back button has closed it, `SessionQueue.ParkReport`) to
/// scripts/mosh-spawner.py (`GET /mark?event=...` on 127.0.0.1), and the test polls the
/// spawner's `/marks`. Event names carry no key or other secret.
enum UITestMarks {
    static func send(_ event: String) {
        #if DEBUG
        guard UITestSupport.isUITesting,
              let text = UserDefaults.standard.string(forKey: "uiTestingSpawnerPort"),
              let port = UInt16(text) else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return }
        let name = event.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let request = Array("GET /mark?event=\(name) HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        while read(fd, &buffer, buffer.count) > 0 {}
        #endif
    }
}
