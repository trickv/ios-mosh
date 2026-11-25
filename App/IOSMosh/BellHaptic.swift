import Foundation
import UIKit

/// When the bell rings (docs/PLAN.md section 5, "Appearance", M7: bell as a haptic). The bell
/// is not in the screen bytes: mosh counts bells in the framebuffer (`bellCount`), and a
/// change of the count between two screens of one session is a bell.
///
/// Decisions where the plan is silent: the first screen of a session only sets the count (a
/// resumed session's stored screen is not a new bell); screens of a resume repaint
/// (`isLive == false`) never ring; several bells within 0.25 s give one haptic.
struct BellWatch {
    static let minimumInterval: TimeInterval = 0.25

    private var session: AnyHashable?
    private var count: UInt32?
    private var lastRing: Date?

    /// Records a screen; true when it should ring now.
    mutating func observe(bellCount: UInt32, isLive: Bool, session: AnyHashable, now: Date = Date()) -> Bool {
        if session != self.session {
            self.session = session
            count = bellCount
            return false
        }
        let previous = count
        count = bellCount
        guard isLive, let previous, previous != bellCount else { return false }
        if let lastRing, now.timeIntervalSince(lastRing) < Self.minimumInterval { return false }
        lastRing = now
        return true
    }
}

/// Plays the bell's haptic. In UI-test launches the number of rings is published as the value
/// of the `bellRings` element (a haptic cannot be seen on the simulator).
final class BellHaptic {
    private let generator = UINotificationFeedbackGenerator()
    private var watch = BellWatch()
    private let element = UIView()
    private var rings = 0

    func install(in parent: UIView) {
        guard UITestSupport.isUITesting else { return }
        element.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        element.isUserInteractionEnabled = false
        element.isAccessibilityElement = true
        element.accessibilityIdentifier = "bellRings"
        element.accessibilityValue = "0"
        parent.addSubview(element)
    }

    func observe(bellCount: UInt32, isLive: Bool, session: AnyHashable) {
        guard watch.observe(bellCount: bellCount, isLive: isLive, session: session) else { return }
        generator.notificationOccurred(.warning)
        rings += 1
        element.accessibilityValue = String(rings)
    }
}
