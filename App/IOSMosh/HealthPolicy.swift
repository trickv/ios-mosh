import Foundation

/// What the terminal screen's one-second health check does (docs/PLAN.md section 4, "Session
/// health"): the "Last contact" banner after mosh's 6.5 s without the server, the SSH probe
/// after 15 s.
///
/// A session the server has ended is silent for good and wants neither: a probe would find
/// no process, read that as a lost session and bootstrap a new one by itself, which an ended
/// session must not get (docs/RESUME.md, `.fallback(.ended)`; review M6-3).
enum HealthPolicy {
    static let bannerAfter: TimeInterval = 6.5
    static let probeAfter: TimeInterval = 15

    struct Step: Equatable {
        var showBanner: Bool
        var probe: Bool

        static let nothing = Step(showBanner: false, probe: false)
    }

    /// - Parameters:
    ///   - watching: there is a session, the app is active and the screen has not been left.
    ///   - serverEnded: the server said the session is over.
    ///   - silent: seconds without the server, counted in the foreground only.
    ///   - probing: a probe is running.
    ///   - probeDue: the time of the next probe has come.
    static func step(watching: Bool, serverEnded: Bool, silent: TimeInterval, probing: Bool, probeDue: Bool) -> Step {
        guard watching, !serverEnded else { return .nothing }
        return Step(showBanner: silent > bannerAfter, probe: silent >= probeAfter && !probing && probeDue)
    }
}
