import MoshTerminal
import MoshTestSupport
import SwiftTerm
import XCTest

/// Every corpus case through `SurfaceFeed` into SwiftTerm, compared after every feed.
final class SurfaceFeedCorpusTests: XCTestCase {
    static let corpus: Result<[GoldenCase], Error> = Result { try GoldenCorpus.loadAll() }

    /// The cases that must pass with no exclusion at all.
    static let mustPassCompletely = ["rec-vim", "rec-tmux", "rec-bash", "rec-htop"]

    private func walkAll(_ mode: WalkMode, name: String) throws {
        let cases = try SurfaceFeedCorpusTests.corpus.get()
        XCTAssertGreaterThanOrEqual(cases.count, 38)
        var total = SurfaceTally()
        var failed: [String] = []
        for c in cases {
            var tally = SurfaceTally()
            let failures = SurfaceWalk.run(c, mode: mode, tally: &tally)
            if !failures.isEmpty {
                failed.append(c.name)
                XCTFail("\(name): " + failures.joined(separator: "\n  "))
            }
            if SurfaceFeedCorpusTests.mustPassCompletely.contains(c.name) {
                XCTAssertTrue(tally.exclusions.isEmpty, "\(c.name) must pass completely: \(tally.summary)")
            }
            total.cases += tally.cases
            total.states += tally.states
            total.feeds += tally.feeds
            total.emptyFeeds += tally.emptyFeeds
            total.fullRepaints += tally.fullRepaints
            total.feedBytes += tally.feedBytes
            total.cells += tally.cells
            total.cellFields += tally.cellFields
            total.cursors += tally.cursors
            total.modeFields += tally.modeFields
            total.focusReports += tally.focusReports
            for (k, v) in tally.exclusions {
                total.exclusions[k, default: 0] += v
                print("SURFACE \(name) \(c.name): \(v) x \(k)")
            }
        }
        for must in SurfaceFeedCorpusTests.mustPassCompletely {
            XCTAssertTrue(cases.contains { $0.name == must }, "the corpus has no case \(must)")
        }
        print("SURFACE \(name): \(total.summary)")
        print("SURFACE \(name): \(cases.count - failed.count) of \(cases.count) cases equal"
            + (failed.isEmpty ? "" : "; differing: " + failed.joined(separator: " ")))
    }

    func testEveryStateFed() throws {
        try walkAll(.every, name: "every state")
    }

    func testEveryThirdStateFed() throws {
        try walkAll(.everyNth(3), name: "every 3rd state")
    }

    func testEverySeventhStateFed() throws {
        try walkAll(.everyNth(7), name: "every 7th state")
    }

    func testInvalidateBeforeRandomFeeds() throws {
        try walkAll(.invalidating(seed: 20261112), name: "invalidate at random")
    }
}
