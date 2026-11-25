@testable import MoshTerminal
import SwiftTerm
import XCTest

/// Characters whose width SwiftTerm and the glibc table (the mosh model) disagree on,
/// and what the feed does about them.
///
/// The scan covers every scalar value the mosh model can put on the screen: glibc width
/// 0, 1 or 2. (A value with glibc width -1 is dropped by mosh's emulator on the server
/// and on the client, so it never is in a framebuffer. SwiftTerm gives 763,968 of those
/// one column and 60,649 two; measured once with the same scan over all 1,111,999
/// values.)
final class WidthDisagreementTests: XCTestCase {
    struct Disputed {
        var scalar: UInt32
        var glibc: Int
        var swiftTerm: Int
    }

    /// Scalars with glibc width 1 or 2 that SwiftTerm gives another width.
    static let disputed: [Disputed] = {
        let st = WidthScan.swiftTermWidths
        var out: [Disputed] = []
        for v in UInt32(0x20)...0x10FFFF {
            let m = WidthScan.moshWidth(v)
            if m >= 1 && Int(st[Int(v)]) != m {
                out.append(Disputed(scalar: v, glibc: m, swiftTerm: Int(st[Int(v)])))
            }
        }
        return out
    }()

    /// Scan and print the classes.
    func testScanSwiftTermWidthsAgainstTheGlibcTable() {
        let st = WidthScan.swiftTermWidths
        // counts[glibc width][SwiftTerm width]
        var counts = [[Int]](repeating: [0, 0, 0], count: 3)
        var runStarts = [[[UInt32]]](repeating: [[], [], []], count: 3)
        var runs = [[Int]](repeating: [0, 0, 0], count: 3)
        var lastClass = -1
        var scanned = 0
        for v in UInt32(0x20)...0x10FFFF {
            let s = Int(st[Int(v)])
            let m = WidthScan.moshWidth(v)
            if m < 0 { continue }
            XCTAssertGreaterThanOrEqual(s, 0, "\(WidthScan.hex(v)) was not measured")
            if s < 0 { return }
            scanned += 1
            counts[m][s] += 1
            let cls = m * 3 + s
            if cls != lastClass {
                runs[m][s] += 1
                if runStarts[m][s].count < 10 { runStarts[m][s].append(v) }
            }
            lastClass = cls
        }
        print("WIDTHS scanned \(scanned) scalar values (glibc width 0, 1 or 2)")
        var disagreements = 0
        for m in 0...2 {
            for s in 0...2 {
                let n = counts[m][s]
                if m != s { disagreements += n }
                print("WIDTHS glibc \(m), SwiftTerm \(s): \(n) scalars in \(runs[m][s]) runs"
                    + (m == s || n == 0 ? "" : "; DISAGREE; first runs start at "
                        + runStarts[m][s].map(WidthScan.hex).joined(separator: " ")))
            }
        }
        print("WIDTHS disagreements: \(disagreements)")

        XCTAssertGreaterThan(scanned, 280_000)
        // A combining character for glibc is one for SwiftTerm too: a cell with
        // combining characters never takes more columns in SwiftTerm than in mosh.
        XCTAssertEqual(counts[0][1] + counts[0][2], 0)
        XCTAssertEqual(disagreements, WidthDisagreementTests.disputed.count)
        // The figures in NOTES.md and in the comment of SurfaceFeed.swift. A change means
        // SwiftTerm's table or the glibc table changed.
        XCTAssertEqual([counts[1][0], counts[1][2], counts[2][0], counts[2][1]], [448, 124, 4, 8],
                       "glibc 1 / SwiftTerm 0, 1 / 2, 2 / 0, 2 / 1")
    }

    /// With SwiftTerm's default options the 26 regional indicator symbols are two
    /// columns wide; with the app's options (`regionalIndicatorWidth: .narrow`) one, as
    /// for glibc.
    func testRegionalIndicatorsAreNarrowWithTheAppsOptions() {
        let range: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
        let defaults = WidthScan.measure(options: TerminalOptions(cols: 8, rows: 2), only: range)
        for v in range {
            XCTAssertEqual(WidthScan.moshWidth(v), 1)
            XCTAssertEqual(defaults[Int(v)], 2, WidthScan.hex(v))
            XCTAssertEqual(WidthScan.swiftTermWidths[Int(v)], 1, WidthScan.hex(v))
        }
    }

    // MARK: A disputed character does not shift its row

    /// What SwiftTerm holds in a cell, for a message.
    private func show(_ screen: SwiftTermScreen, _ col: Int, _ row: Int) -> String {
        return "w\(screen.width(col: col, row: row))" + SurfaceComparison.hex(screen.scalars(col: col, row: row))
    }

    /// One disputed scalar in the middle of a row and at the right margin of the bottom
    /// row, fed as a full repaint and as a diff. Every cell that is not the character's
    /// own or its left neighbour must be what the framebuffer has, and the cursor too.
    /// Returns what SwiftTerm shows in the character's cell and its left neighbour.
    private func check(_ d: Disputed, options: TerminalOptions?) -> String {
        let width = 12
        let height = 3
        var grapheme: [UInt8] = []
        Cell.appendUTF8(d.scalar, to: &grapheme)
        let fill = String(repeating: "x", count: d.glibc)
        let marginCol = width - d.glibc // zero based

        var before = TerminalState(width: width, height: height)
        _ = before.act(Array("top\r\nab\(fill)cdefg\r\n0123456789A".utf8))
        var after = before
        _ = after.act(Array("\u{1B}[2;3H".utf8) + grapheme + Array("\u{1B}[3;\(marginCol + 1)H".utf8) + grapheme
            + Array("\u{1B}[1;4H".utf8))
        let fb = after.framebuffer
        let name = WidthScan.hex(d.scalar)
        XCTAssertEqual(fb.rows[1].cells[2].contents, grapheme, name)
        XCTAssertEqual(fb.rows[2].cells[marginCol].contents, grapheme, name)
        XCTAssertEqual(fb.rows[1].cells[2].width, d.glibc, name)

        var outcome = ""
        for full in [true, false] {
            let screen = SwiftTermScreen(cols: width, rows: height, options: options)
            var feed = SurfaceFeed()
            if !full {
                screen.feed(feed.feed(to: before.framebuffer))
            }
            let bytes = feed.feed(to: fb)
            screen.feed(bytes)
            let what = "\(name) (glibc \(d.glibc), SwiftTerm \(d.swiftTerm), \(full ? "full repaint" : "diff"))"

            for y in 0..<height {
                let cells = fb.rows[y].cells
                // The character's own columns and the cell on its left.
                let own: Range<Int> = y == 1 ? 1..<(2 + d.glibc) : (y == 2 ? (marginCol - 1)..<width : 0..<0)
                var x = 0
                while x < width {
                    defer { x += cells[x].width }
                    if own.contains(x) { continue }
                    let got = screen.scalars(col: x, row: y)
                    let expected = SurfaceComparison.scalars(cells[x].contents)
                    let equal = cells[x].isEmpty ? (got == [0] || got == [0x20]) : got == expected
                    if !equal || screen.width(col: x, row: y) != 1 {
                        XCTFail("\(what): row \(y) col \(x) should be \(SurfaceComparison.hex(expected)), SwiftTerm has "
                            + "\(show(screen, x, y)); feed \(SurfaceComparison.escaped(bytes))")
                        return "failed"
                    }
                }
            }
            XCTAssertEqual(screen.cursor.x, fb.ds.cursorCol, what)
            XCTAssertEqual(screen.cursor.y, fb.ds.cursorRow, what)
            XCTAssertEqual(screen.privateMode(7), 1, what)

            // What became of the character: its cell(s) and the left neighbour, in the
            // middle of the row and at the margin.
            var o = "left " + show(screen, 1, 1) + " own " + show(screen, 2, 1)
            if d.glibc == 2 { o += " " + show(screen, 3, 1) }
            o += " | margin: left " + show(screen, marginCol - 1, 2) + " own " + show(screen, marginCol, 2)
            if d.glibc == 2 { o += " " + show(screen, marginCol + 1, 2) }
            o = o.replacingOccurrences(of: name, with: "C")
            if full {
                outcome = o
            } else if o != outcome {
                XCTFail("\(what): a diff leaves \(o), a full repaint \(outcome)")
            }
        }
        return outcome
    }

    func testADisputedCharacterDoesNotShiftTheRestOfItsRow() {
        let disputed = WidthDisagreementTests.disputed
        XCTAssertFalse(disputed.isEmpty)
        // outcomes[class][outcome] = (count, first example)
        var outcomes: [String: [String: (Int, UInt32)]] = [:]
        for d in disputed {
            let cls = "glibc \(d.glibc), SwiftTerm \(d.swiftTerm)"
            let o = check(d, options: nil)
            let entry = outcomes[cls, default: [:]][o] ?? (0, d.scalar)
            outcomes[cls, default: [:]][o] = (entry.0 + 1, entry.1)
        }
        for (cls, byOutcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            for (o, entry) in byOutcome.sorted(by: { $0.value.0 > $1.value.0 }) {
                print("DISPUTED \(cls): \(entry.0) scalars (first \(WidthScan.hex(entry.1))): \(o)")
            }
        }
        print("DISPUTED \(disputed.count) scalars checked, each as a full repaint and as a diff")

        // What SwiftTerm shows for each class. w1[U+0000] is a blank cell, w0 the right
        // half of a two-column cell, C the character.
        // SwiftTerm has no width for it (spacing combining marks, mostly Indic vowel
        // signs): it joins the character to the cell on its left and, for most, widens
        // that cell over the character's own column, which is where mosh has it; some
        // it does not store after a Latin letter. The left neighbour is the one cell
        // outside the character's own that can differ from the framebuffer.
        XCTAssertEqual(outcomes["glibc 1, SwiftTerm 0"]?.keys.sorted(), [
            "left w1[U+0062 C] own w1[U+0000] | margin: left w1[U+0041 C] own w1[U+0000]",
            "left w1[U+0062] own w1[U+0000] | margin: left w1[U+0041] own w1[U+0000]",
            "left w2[U+0062 C] own w0[U+0000] | margin: left w2[U+0041 C] own w0[U+0000]",
        ])
        XCTAssertEqual(outcomes["glibc 2, SwiftTerm 0"]?.keys.sorted(), [
            "left w2[U+0062 C] own w0[U+0000] w1[U+0000] | margin: left w2[U+0039 C] own w0[U+0000] w1[U+0000]",
        ])
        // SwiftTerm wider: the redraw of the next cell blanks the character.
        XCTAssertEqual(outcomes["glibc 1, SwiftTerm 2"]?.keys.sorted(),
                       ["left w1[U+0062] own w1[U+0000] | margin: left w1[U+0041] own w1[U+0000]"])
        // SwiftTerm narrower: the character is there, the second column is blank.
        XCTAssertEqual(outcomes["glibc 2, SwiftTerm 1"]?.keys.sorted(),
                       ["left w1[U+0062] own w1[C] w1[U+0000] | margin: left w1[U+0039] own w1[C] w1[U+0000]"])
    }

    /// The same for the regional indicators when the app forgets the option.
    func testARegionalIndicatorDoesNotShiftItsRowWithDefaultOptions() {
        var outcomes: Set<String> = []
        for v in UInt32(0x1F1E6)...0x1F1FF {
            outcomes.insert(check(Disputed(scalar: v, glibc: 1, swiftTerm: 2), options: TerminalOptions(cols: 12, rows: 3)))
        }
        XCTAssertEqual(outcomes.sorted(), ["left w1[U+0062] own w1[U+0000] | margin: left w1[U+0041] own w1[U+0000]"])
    }

    // MARK: Trusted ranges

    /// Every scalar of `SurfaceFeed.trustedNarrowRanges` that can be alone in a narrow
    /// cell is one column wide in SwiftTerm and is not joined to its neighbours, so the
    /// feed may print such cells one after the other.
    func testTrustedRangesAreOneColumnAndNeverJoin() {
        let st = WidthScan.swiftTermWidths
        var trusted: [UInt32] = []
        for range in SurfaceFeed.trustedNarrowRanges {
            for v in range where WidthScan.moshWidth(v) == 1 {
                XCTAssertEqual(st[Int(v)], 1, "\(WidthScan.hex(v)) is in a trusted range")
                trusted.append(v)
            }
        }
        XCTAssertGreaterThan(trusted.count, 1500)
        // No value of the ranges is wide for glibc (such a cell would be guarded anyway).
        for range in SurfaceFeed.trustedNarrowRanges {
            for v in range {
                XCTAssertNotEqual(WidthScan.moshWidth(v), 2, WidthScan.hex(v))
            }
        }

        // Printed in runs, with no cursor movement: a, v, b, v, v, c per scalar.
        let perRow = 16
        let screen = SwiftTermScreen(cols: perRow * 6, rows: 2)
        var index = 0
        while index < trusted.count {
            let chunk = Array(trusted[index..<min(index + perRow, trusted.count)])
            var bytes = Array("\u{1B}[H\u{1B}[2K".utf8)
            for v in chunk {
                bytes.append(0x61)
                Cell.appendUTF8(v, to: &bytes)
                bytes.append(0x62)
                Cell.appendUTF8(v, to: &bytes)
                Cell.appendUTF8(v, to: &bytes)
                bytes.append(0x63)
            }
            screen.feed(bytes)
            for (i, v) in chunk.enumerated() {
                let expected: [UInt32] = [0x61, v, 0x62, v, v, 0x63]
                for (j, e) in expected.enumerated() {
                    let col = i * 6 + j
                    if screen.scalars(col: col, row: 0) != [e] || screen.width(col: col, row: 0) != 1 {
                        XCTFail("\(WidthScan.hex(v)): column \(j) of a v b v v c holds \(show(screen, col, 0))")
                        break
                    }
                }
            }
            index += perRow
        }
        print("TRUSTED \(trusted.count) scalars in \(SurfaceFeed.trustedNarrowRanges.count) ranges: width 1, never joined")

        // The cell test agrees with the scalar test.
        for v in [UInt32(0x41), 0xE9, 0x2500, 0x3B1, 0x28FF, 0xE0B0] {
            var s = TerminalState(width: 4, height: 1)
            var bytes: [UInt8] = []
            Cell.appendUTF8(v, to: &bytes)
            _ = s.act(bytes)
            XCTAssertTrue(SurfaceFeed.isTrusted(s.framebuffer.rows[0].cells[0]), WidthScan.hex(v))
        }
        for text in ["\u{6F22}", "e\u{0301}", "\u{00A0}", "\u{00AD}", "\u{2764}", "\u{1F600}", "\u{0915}", "\u{0301}"] {
            var s = TerminalState(width: 4, height: 1)
            _ = s.act(Array(text.utf8))
            XCTAssertFalse(SurfaceFeed.isTrusted(s.framebuffer.rows[0].cells[0]), text)
        }
        XCTAssertTrue(SurfaceFeed.isTrusted(Cell(backgroundColor: 0)))
    }
}
