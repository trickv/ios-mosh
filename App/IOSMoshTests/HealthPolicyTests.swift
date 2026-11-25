import XCTest
@testable import IOSMosh

final class HealthPolicyTests: XCTestCase {
    func testBannerThenProbe() {
        XCTAssertEqual(HealthPolicy.step(watching: true, serverEnded: false, silent: 3, probing: false, probeDue: true), .nothing)
        XCTAssertEqual(HealthPolicy.step(watching: true, serverEnded: false, silent: 7, probing: false, probeDue: true),
                       .init(showBanner: true, probe: false))
        XCTAssertEqual(HealthPolicy.step(watching: true, serverEnded: false, silent: 15, probing: false, probeDue: true),
                       .init(showBanner: true, probe: true))
    }

    func testOneProbeAtATimeAndNotBeforeItIsDue() {
        XCTAssertFalse(HealthPolicy.step(watching: true, serverEnded: false, silent: 20, probing: true, probeDue: true).probe)
        XCTAssertFalse(HealthPolicy.step(watching: true, serverEnded: false, silent: 20, probing: false, probeDue: false).probe)
    }

    func testNothingWithoutASessionInTheForeground() {
        XCTAssertEqual(HealthPolicy.step(watching: false, serverEnded: false, silent: 60, probing: false, probeDue: true), .nothing)
    }

    /// Review M6-3: `exit` in a session from a saved host, then 20 s and more of silence. No
    /// probe (it would start a new session), no "Last contact" banner.
    func testAfterTheServerEndedTheSessionThereIsNoProbeAndNoBanner() {
        for silent in [0, 7, 15, 20, 3600] as [TimeInterval] {
            XCTAssertEqual(
                HealthPolicy.step(watching: true, serverEnded: true, silent: silent, probing: false, probeDue: true),
                .nothing, "\(silent) s")
        }
    }
}
