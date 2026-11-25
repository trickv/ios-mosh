import Foundation
import MoshTerminal
import SwiftTerm
import XCTest

/// Random small sessions full of wide characters, combining characters, emoji sequences,
/// erases, insertions and scrolls, fed to SwiftTerm state by state (some skipped, some
/// after `invalidate()`) and compared after every feed.
///
/// The recorded corpus has few places where a wide character is half overwritten or
/// shifted by one column; this test is made of them.
final class SurfaceFeedRandomTests: XCTestCase {
    /// Characters SwiftTerm and glibc agree on, most of them guarded by the feed.
    static let tokens: [String] = [
        "a", "Z", " ", "~", "\u{00E9}", "\u{2500}", "\u{2588}",
        "\u{6F22}", "\u{5B57}", "\u{304B}", "\u{D55C}", "\u{FF21}",
        "\u{1F600}", "\u{1F469}\u{200D}\u{1F469}", "\u{1F44D}\u{1F3FD}", "\u{1F1E9}\u{1F1EA}",
        "e\u{0301}", "o\u{0308}\u{0304}", "\u{1100}\u{1161}", "\u{2764}\u{FE0F}", "\u{0301}",
        "word", "\u{6F22}\u{5B57}\u{6F22}", "x\u{6F22}y",
    ]

    private func step(_ g: inout SeededGenerator, width: Int, height: Int) -> String {
        func pick(_ n: Int) -> Int { return Int(g.next() % UInt64(n)) }
        switch pick(100) {
        case 0..<30:
            return SurfaceFeedRandomTests.tokens[pick(SurfaceFeedRandomTests.tokens.count)]
        case 30..<50:
            // Often at the right margin, where widths matter most.
            let col = pick(3) == 0 ? width - pick(3) : pick(width) + 1
            return "\u{1B}[\(pick(height) + 1);\(col)H"
        case 50..<60:
            let sgr = ["0", "1", "4", "7", "3", "5", "8", "31", "42", "38;5;\(pick(256))", "48;5;\(pick(256))",
                       "38;2;\(pick(256));\(pick(256));\(pick(256))", "48;2;1;2;\(pick(256))", "0;44", "39", "49"]
            return "\u{1B}[\(sgr[pick(sgr.count)])m"
        case 60..<68:
            return "\u{1B}[\(pick(3))K"
        case 68..<74:
            return "\u{1B}[\(pick(4) + 1)X"
        case 74..<79:
            return "\u{1B}[\(pick(3) + 1)@"
        case 79..<84:
            return "\u{1B}[\(pick(3) + 1)P"
        case 84..<87:
            return pick(2) == 0 ? "\u{1B}[L" : "\u{1B}[M"
        case 87..<91:
            return pick(2) == 0 ? "\r\n" : "\n"
        case 91..<93:
            return "\u{1B}M"
        case 93..<95:
            return "\u{1B}[\(pick(2) * 2)J"
        case 95..<97:
            return pick(2) == 0 ? "\u{1B}[?7l" : "\u{1B}[?7h"
        case 97..<98:
            return pick(2) == 0 ? "\u{1B}[?25l" : "\u{1B}[?25h"
        case 98..<99:
            let top = pick(height - 1) + 1
            return "\u{1B}[\(top);\(top + 1 + pick(height - top))r"
        default:
            return pick(2) == 0 ? "\u{1B}[?5h" : "\u{1B}[?5l"
        }
    }

    func testRandomSessionsOfWideAndCombiningCharacters() {
        let sizes = [(16, 5), (9, 4), (2, 3), (31, 3)]
        var total = SurfaceTally()
        var failures = 0
        // SURFACE_RANDOM_RUNS=3000 for a longer run (about three minutes).
        let runs = ProcessInfo.processInfo.environment["SURFACE_RANDOM_RUNS"].flatMap { Int($0) } ?? 240
        for run in 0..<runs {
            let (width, height) = sizes[run % sizes.count]
            var g = SeededGenerator(state: 0x5EED_0000 + UInt64(run))
            var state = TerminalState(width: width, height: height)
            let screen = SwiftTermScreen(cols: width, rows: height)
            var feed = SurfaceFeed()
            var script: [String] = []
            for _ in 0..<80 {
                let s = step(&g, width: width, height: height)
                script.append(s)
                total.states += 1
                _ = state.act(Array(s.utf8))
                let choice = g.next() % 20
                if choice < 6 { continue } // this state is skipped
                if choice == 19 { feed.invalidate() }
                if feed.needsFullRepaint(to: state.framebuffer) { total.fullRepaints += 1 }
                let bytes = feed.feed(to: state.framebuffer)
                total.feeds += 1
                if bytes.isEmpty { total.emptyFeeds += 1 }
                total.feedBytes += bytes.count
                screen.feed(bytes)
                var found: [String] = []
                SurfaceComparison.compare(screen, state.framebuffer, tally: &total, found: &found, limit: 4)
                if !screen.sent.isEmpty {
                    found.append("SwiftTerm sent \(SurfaceComparison.escaped(screen.sent))")
                }
                if !found.isEmpty {
                    failures += 1
                    XCTFail("run \(run) (\(width)x\(height)) after \(script.count) steps: "
                        + found.joined(separator: "; ")
                        + "\n  last steps: " + script.suffix(6).map { SurfaceComparison.escaped(Array($0.utf8)) }.joined(separator: " | ")
                        + "\n  feed: " + SurfaceComparison.escaped(bytes.prefix(300)))
                    break
                }
            }
            if failures >= 5 { break }
        }
        total.cases = runs
        print("RANDOM \(total.summary)")
        XCTAssertGreaterThan(total.feeds, runs * 40)
    }
}
