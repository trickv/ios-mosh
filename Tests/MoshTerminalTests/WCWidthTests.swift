// Character widths: the table's shape and the values the emulator relies on. (On Linux,
// GlibcConformanceTests compares the whole table with the C library.)

import XCTest
@testable import MoshTerminal

final class WCWidthTests: XCTestCase {
    func testTableShape() {
        XCTAssertEqual(WCWidthTable.starts.count, WCWidthTable.runCount)
        XCTAssertEqual(WCWidthTable.widths.count, WCWidthTable.runCount)
        XCTAssertEqual(WCWidthTable.starts.first, 0)
        for i in 1..<WCWidthTable.starts.count {
            XCTAssertLessThan(WCWidthTable.starts[i - 1], WCWidthTable.starts[i], "ascending")
            XCTAssertNotEqual(WCWidthTable.widths[i - 1], WCWidthTable.widths[i], "neighbouring runs differ")
        }
        XCTAssertLessThanOrEqual(WCWidthTable.starts.last!, 0x10FFFF)
        XCTAssertTrue(WCWidthTable.widths.allSatisfy { $0 >= -1 && $0 <= 2 })
    }

    func testWidths() {
        let table: [(UInt32, Int, String)] = [
            (0x00, 0, "NUL (the emulator never asks: it drops NUL)"),
            (0x01, -1, "C0 control"),
            (0x1F, -1, "C0 control"),
            (0x20, 1, "space"),
            (0x41, 1, "A"),
            (0x7E, 1, "~"),
            (0x7F, -1, "DEL"),
            (0x80, -1, "C1 control"),
            (0x9F, -1, "C1 control"),
            (0xA0, 1, "no-break space"),
            (0xAD, 1, "soft hyphen"),
            (0xE9, 1, "é"),
            (0x300, 0, "combining grave"),
            (0x301, 0, "combining acute"),
            (0x36F, 0, "last of the combining diacriticals"),
            (0x378, -1, "unassigned"),
            (0x1100, 2, "Hangul choseong"),
            (0x1160, 0, "Hangul jungseong filler"),
            (0x200B, 0, "zero width space"),
            (0x200D, 0, "zero width joiner"),
            (0x20AC, 1, "euro sign"),
            (0x2500, 1, "box drawing"),
            (0x3000, 2, "ideographic space"),
            (0x3042, 2, "hiragana a"),
            (0x3099, 0, "combining voiced sound mark"),
            (0x4E00, 2, "CJK ideograph"),
            (0x65E5, 2, "CJK ideograph"),
            (0xAC00, 2, "Hangul syllable"),
            (0xD800, -1, "surrogate"),
            (0xE000, 1, "private use"),
            (0xFE0F, 0, "variation selector 16"),
            (0xFF41, 2, "fullwidth a"),
            (0xFFFD, 1, "replacement character"),
            (0xFFFF, -1, "noncharacter"),
            (0x1D165, 1, "musical combining stem (spacing mark)"),
            (0x1D167, 0, "musical combining tremolo"),
            (0x1F1EE, 1, "regional indicator"),
            (0x1F600, 2, "emoji"),
            (0x20000, 2, "CJK extension B"),
            (0xE0001, 0, "language tag"),
            (0xE0100, 0, "variation selector 17"),
            (0x10FFFF, -1, "last code point"),
            (0x110000, -1, "beyond Unicode"),
            (0xFFFFFFFF, -1, "beyond Unicode"),
        ]
        for (cp, width, what) in table {
            XCTAssertEqual(WCWidth.wcwidth(cp), width, "U+\(String(cp, radix: 16)) \(what)")
        }
    }

    /// Run boundaries: the code point before a run start belongs to the previous run.
    func testRunBoundaries() {
        for i in 1..<WCWidthTable.starts.count {
            let start = WCWidthTable.starts[i]
            XCTAssertEqual(WCWidth.wcwidth(start), Int(WCWidthTable.widths[i]))
            XCTAssertEqual(WCWidth.wcwidth(start - 1), Int(WCWidthTable.widths[i - 1]))
        }
    }
}
