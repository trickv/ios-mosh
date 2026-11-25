import XCTest
@testable import IOSMosh

/// The decision "is this path update a change worth a new socket", and its debounce.
final class PathChangeFilterTests: XCTestCase {
    private let wifi = PathSnapshot(isSatisfied: true, interfaces: ["en0/wifi"])
    private let wifiAndCell = PathSnapshot(isSatisfied: true, interfaces: ["en0/wifi", "pdp_ip0/cellular"])
    private let cellFirst = PathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0/cellular", "en0/wifi"])
    private let cell = PathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0/cellular"])
    private let none = PathSnapshot(isSatisfied: false, interfaces: [])

    func testTheFirstUpdateIsTheCurrentStateNotAChange() {
        XCTAssertFalse(PathChangeFilter.isChange(from: nil, to: wifi))
        XCTAssertFalse(PathChangeFilter.isChange(from: nil, to: none))
        var filter = PathChangeFilter()
        XCTAssertFalse(filter.observe(wifi), "no timer for the first update")
        XCTAssertFalse(filter.timerFired())
    }

    func testWhatCountsAsAChange() {
        XCTAssertTrue(PathChangeFilter.isChange(from: none, to: wifi), "satisfied after unsatisfied")
        XCTAssertTrue(PathChangeFilter.isChange(from: wifi, to: cell), "other interface")
        XCTAssertTrue(PathChangeFilter.isChange(from: wifi, to: wifiAndCell), "an interface added")
        XCTAssertTrue(PathChangeFilter.isChange(from: wifiAndCell, to: wifi), "an interface gone")
        XCTAssertTrue(PathChangeFilter.isChange(from: wifiAndCell, to: cellFirst), "other preferred interface")
        XCTAssertFalse(PathChangeFilter.isChange(from: wifi, to: wifi), "the same path again")
        XCTAssertFalse(PathChangeFilter.isChange(from: wifi, to: none), "unsatisfied: nothing to open a socket on")
        XCTAssertFalse(PathChangeFilter.isChange(from: none, to: none))
    }

    func testABurstGivesOneReplacement() {
        var filter = PathChangeFilter()
        _ = filter.observe(wifi)
        // Wi-Fi goes, cellular comes, in three updates within the debounce interval.
        XCTAssertFalse(filter.observe(none), "unsatisfied alone starts nothing")
        XCTAssertTrue(filter.observe(cell))
        XCTAssertTrue(filter.observe(PathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0/cellular", "ipsec0/other"])),
                      "a later update restarts the timer")
        XCTAssertTrue(filter.timerFired(), "one replacement")
        XCTAssertFalse(filter.timerFired(), "and only one")
        XCTAssertFalse(filter.observe(filter.last!), "the same path again starts nothing")
        XCTAssertFalse(filter.timerFired())
    }

    func testNoReplacementWhileThePathIsUnusable() {
        var filter = PathChangeFilter()
        _ = filter.observe(wifi)
        XCTAssertTrue(filter.observe(cell))
        _ = filter.observe(none)   // gone again before the timer fired
        XCTAssertFalse(filter.timerFired(), "no socket on an unsatisfied path")
        XCTAssertTrue(filter.observe(wifi), "back: still pending")
        XCTAssertTrue(filter.timerFired())
    }

    func testEachSeparateChangeGivesItsOwnReplacement() {
        var filter = PathChangeFilter()
        _ = filter.observe(wifi)
        XCTAssertTrue(filter.observe(wifiAndCell))
        XCTAssertTrue(filter.timerFired())
        XCTAssertTrue(filter.observe(cell))
        XCTAssertTrue(filter.timerFired())
    }

    /// Review M6-9: a stream of updates less than the debounce interval apart must not put
    /// the new socket off without limit.
    func testTheDebounceHasAnUpperBound() {
        var filter = PathChangeFilter()
        let start = Date(timeIntervalSince1970: 1000)
        _ = filter.observe(wifi, at: start)
        XCTAssertTrue(filter.observe(cell, at: start))
        XCTAssertEqual(filter.timerDelay(at: start), PathChangeFilter.debounce)
        // An update every 0.2 s, each restarting the timer.
        var now = start
        var flap = false
        while now.timeIntervalSince(start) < PathChangeFilter.maximumWait - 0.1 {
            now += 0.2
            flap.toggle()
            XCTAssertTrue(filter.observe(flap ? wifiAndCell : cell, at: now))
            XCTAssertLessThanOrEqual(
                now.timeIntervalSince(start) + filter.timerDelay(at: now), PathChangeFilter.maximumWait + 0.0001,
                "the timer is never set past the maximum wait")
        }
        XCTAssertEqual(filter.timerDelay(at: start + PathChangeFilter.maximumWait + 1), 0, "overdue: at once")
        XCTAssertTrue(filter.timerFired())
        // The next change counts from its own first update.
        let later = start + 60
        XCTAssertTrue(filter.observe(wifi, at: later))
        XCTAssertEqual(filter.timerDelay(at: later), PathChangeFilter.debounce)
    }
}
