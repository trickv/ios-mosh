import MoshTerminal
import UIKit

/// Swipe paging (docs/PLAN.md section 5, "Selection and touch"): with mouse mode off, a vertical
/// swipe sends PgUp or PgDn if the host has that option on (`SavedHost.swipeSendsPaging`). It is
/// the app's own one-finger pan recogniser, installed only while mouse mode is off.
///
/// Decisions where the plan is silent: the finger moving down sends PgUp and up sends PgDn (as
/// if dragging the text); one key per swipe; a swipe is at least 40 pt and more vertical than
/// twice its horizontal part. A debug session (no saved host) has the option with
/// `-debugSwipePaging 1`.
enum SwipePagingRule {
    static let minimumDistance: CGFloat = 40

    static func isActive(hostOption: Bool, mouseMode: MouseReportingMode) -> Bool {
        hostOption && mouseMode == .none
    }

    /// The key a finished pan sends, if any.
    static func key(for translation: CGPoint) -> TerminalKey? {
        let vertical = abs(translation.y), horizontal = abs(translation.x)
        guard vertical >= minimumDistance, vertical > 2 * horizontal else { return nil }
        return translation.y > 0 ? .pageUp : .pageDown
    }
}

final class SwipePaging: NSObject, UIGestureRecognizerDelegate {
    private weak var surface: TerminalSurface?
    private weak var view: UIView?
    private let hostOption: Bool
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()

    /// The option of a debug session, which has no saved host.
    static var debugOption: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugSwipePaging")
        #else
        return false
        #endif
    }

    init(surface: TerminalSurface, hostOption: Bool) {
        self.surface = surface
        self.hostOption = hostOption
        super.init()
    }

    func install(on view: UIView) {
        self.view = view
        update(mouseMode: .none)
    }

    /// Called with each screen: the recogniser is there only while the remote has mouse mode off.
    func update(mouseMode: MouseReportingMode) {
        let active = SwipePagingRule.isActive(hostOption: hostOption, mouseMode: mouseMode)
        if active, pan.view == nil, let view {
            view.addGestureRecognizer(pan)
        } else if !active, let owner = pan.view {
            owner.removeGestureRecognizer(pan)
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended,
              let key = SwipePagingRule.key(for: recognizer.translation(in: recognizer.view)) else { return }
        surface?.sendKey(key)
    }

    // The terminal view's own recognisers (it is a scroll view) keep working.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
