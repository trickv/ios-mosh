// The emulator functions, one family per test. Expected cells, cursor positions and
// modes are worked out from mosh 1.4.0 src/terminal/terminalfunctions.cc, terminal.cc
// and terminalframebuffer.cc, not from the port. (MoshCrossCheckTests compares the port
// with mosh's code itself.)

import XCTest
@testable import MoshTerminal

final class EmulatorTests: XCTestCase {
    // MARK: Printing and simple controls

    func testPrintAndControls() {
        var t = terminal(10, 3, "ab\r\ncd\u{8}e")
        XCTAssertScreen(t, ["ab", "ce", ""])
        XCTAssertEqual(t.cursor, [1, 2])
        // LF, VT, FF, IND all go down one line; NEL also returns to column 0
        t.feed("\u{1B}[1;3H\u{B}x")
        XCTAssertEqual(t.cursor, [1, 3])
        t = terminal(10, 4, "a\u{C}b\u{1B}Dc\u{1B}Ed")
        XCTAssertScreen(t, ["a", " b", "  c", "d"])
        // DEL and NUL print nothing
        t = terminal(10, 1, "a\u{7F}b\u{0}c")
        XCTAssertScreen(t, ["abc"])
        XCTAssertEqual(t.cursor, [0, 3])
    }

    // MARK: Cursor motion

    func testCursorMotionAndClamping() {
        var t = terminal(10, 5)
        func at(_ s: String, _ row: Int, _ col: Int, line: UInt = #line) {
            t.feed(s)
            XCTAssertEqual(t.cursor, [row, col], "after \(s.debugDescription)", line: line)
        }
        at("\(CSI)3;4H", 2, 3)
        at("\(CSI)99A", 0, 3)
        at("\(CSI)99B", 4, 3)
        at("\(CSI)99D", 4, 0)
        at("\(CSI)99C", 4, 9)
        XCTAssertFalse(t.fb.ds.nextPrintWillWrap, "an explicit move to the last column does not arm the wrap")
        at("\(CSI)2A", 2, 9)
        at("\(CSI)3D", 2, 6)
        at("\(CSI)B", 3, 6)
        at("\(CSI)0B", 4, 6) // parameter 0 means the default, 1
        at("\(CSI)C", 4, 7)
        at("\(CSI)99;99H", 4, 9)
        at("\(CSI)0;0H", 0, 0)
        at("\(CSI);5H", 0, 4)
        at("\(CSI)2H", 1, 0)
        at("\(CSI)3;4f", 2, 3)
        at("\(CSI)4d", 3, 3) // VPA keeps the column
        at("\(CSI)99d", 4, 3)
        at("\(CSI)9G", 4, 8) // CHA
        at("\(CSI)2`", 4, 1) // HPA
        at("\(CSI)99G", 4, 9)
        at("\r", 4, 0)
        at("\u{8}", 4, 0) // backspace stops at the left margin
        at("\(CSI)65535B\(CSI)65536A", 3, 0) // 65536 is out of range: reads as the default, 1
    }

    // MARK: Erasing

    func testEraseInLineTakesThePenBackground() {
        var t = terminal(6, 3, "aaaaaabbbbbbcccccc")
        XCTAssertScreen(t, ["aaaaaa", "bbbbbb", "cccccc"])
        XCTAssertTrue(t.fb.rows[0].wrap)

        // EL 0: cursor to end of line
        t.feed("\(CSI)1;3H\(CSI)44m\(CSI)K")
        XCTAssertScreen(t, ["aa", "bbbbbb", "cccccc"])
        for x in 2...5 {
            XCTAssertEqual(t.cell(0, x), Cell(backgroundColor: 44), "column \(x)")
        }
        XCTAssertEqual(t.cell(0, 1).renditions, Renditions(background: 0))
        XCTAssertFalse(t.fb.rows[0].wrap, "erasing the last cell removes the wrap mark")
        XCTAssertEqual(t.cursor, [0, 2])

        // EL 1: start of line to cursor, inclusive. Only the background is taken from the pen.
        t.feed("\(CSI)2;3H\(CSI)0;1;31;41m\(CSI)1K")
        XCTAssertScreen(t, ["aa", "   bbb", "cccccc"])
        for x in 0...2 {
            XCTAssertEqual(t.cell(1, x), Cell(backgroundColor: 41), "column \(x)")
        }
        XCTAssertTrue(t.fb.rows[1].wrap, "the last cell was not touched")

        // EL 2: the whole line, and the row gets a new generation
        let genBefore = t.fb.rows[2].gen
        t.feed("\(CSI)3;3H\(CSI)m\(CSI)2K")
        XCTAssertScreen(t, ["aa", "   bbb", ""])
        XCTAssertEqual(t.fb.rows[2].cells, Array(repeating: Cell(backgroundColor: 0), count: 6))
        XCTAssertNotEqual(t.fb.rows[2].gen, genBefore)
        XCTAssertEqual(t.cursor, [2, 2])

        // an unknown parameter does nothing
        t.feed("\(CSI)2;5H\(CSI)7K")
        XCTAssertScreen(t, ["aa", "   bbb", ""])
    }

    func testEraseInDisplay() {
        var t = terminal(4, 4, "1111222233334444")
        t.feed("\(CSI)2;2H\(CSI)42m\(CSI)J")
        XCTAssertScreen(t, ["1111", "2", "", ""])
        XCTAssertEqual(t.cell(1, 0).contents, [0x32])
        XCTAssertEqual(t.cell(1, 1), Cell(backgroundColor: 42))
        XCTAssertEqual(t.cell(3, 3), Cell(backgroundColor: 42))
        XCTAssertTrue(t.fb.rows[0].wrap)
        XCTAssertFalse(t.fb.rows[1].wrap)
        XCTAssertEqual(t.cursor, [1, 1])

        t = terminal(4, 4, "1111222233334444")
        t.feed("\(CSI)3;2H\(CSI)43m\(CSI)1J")
        XCTAssertScreen(t, ["", "", "  33", "4444"])
        XCTAssertEqual(t.cell(0, 0), Cell(backgroundColor: 43))
        XCTAssertEqual(t.cell(2, 1), Cell(backgroundColor: 43))
        XCTAssertEqual(t.cell(2, 2).contents, [0x33])

        t.feed("\(CSI)2J")
        XCTAssertScreen(t, ["", "", "", ""])
        XCTAssertEqual(t.cell(3, 3), Cell(backgroundColor: 43))
        XCTAssertEqual(t.cursor, [2, 1], "ED does not move the cursor")

        // ED 3 is not implemented by mosh: nothing happens
        t = terminal(4, 2, "ab")
        t.feed("\(CSI)3J")
        XCTAssertScreen(t, ["ab", ""])
    }

    func testEraseCharacter() {
        var t = terminal(8, 2, "abcdefgh")
        t.feed("\(CSI)1;3H\(CSI)45m\(CSI)3X")
        XCTAssertScreen(t, ["ab   fgh", ""])
        for x in 2...4 { XCTAssertEqual(t.cell(0, x), Cell(backgroundColor: 45)) }
        XCTAssertEqual(t.cursor, [0, 2])
        t.feed("\(CSI)1;7H\(CSI)99X") // clamped at the right margin
        XCTAssertScreen(t, ["ab   f", ""])
        XCTAssertEqual(t.cell(0, 7), Cell(backgroundColor: 45))
        XCTAssertEqual(t.cursor, [0, 6])
        t.feed("\(CSI)1;1H\(CSI)X") // default 1
        XCTAssertScreen(t, [" b   f", ""])
    }

    // MARK: Lines and characters

    func testInsertAndDeleteLines() {
        var t = terminal(3, 5, "1\r\n2\r\n3\r\n4\r\n5")
        t.feed("\(CSI)2;2H\(CSI)2L")
        XCTAssertScreen(t, ["1", "", "", "2", "3"])
        XCTAssertEqual(t.cursor, [1, 0], "IL moves to the first column")
        XCTAssertTrue(t.fb.rows[1] === t.fb.rows[2], "the inserted lines are one row object")

        t.feed("\(CSI)41m\(CSI)1;3H\(CSI)M")
        XCTAssertScreen(t, ["", "", "2", "3", ""])
        XCTAssertEqual(t.cell(4, 0), Cell(backgroundColor: 41), "the new line takes the pen background")
        XCTAssertEqual(t.cursor, [0, 0])

        t.feed("\(CSI)3;1H\(CSI)99M")
        XCTAssertScreen(t, ["", "", "", "", ""])
        XCTAssertTrue(t.fb.rows[2] === t.fb.rows[4])

        // with a scrolling region: only lines inside it move
        t = terminal(3, 5, "1\r\n2\r\n3\r\n4\r\n5")
        t.feed("\(CSI)2;4r\(CSI)3;2H\(CSI)L")
        XCTAssertScreen(t, ["1", "2", "", "3", "5"])
        // outside the region nothing moves, but the cursor still goes to column 0
        t.feed("\(CSI)5;3H\(CSI)L")
        XCTAssertScreen(t, ["1", "2", "", "3", "5"])
        XCTAssertEqual(t.cursor, [4, 0])
        t.feed("\(CSI)1;3H\(CSI)M")
        XCTAssertScreen(t, ["1", "2", "", "3", "5"])
        XCTAssertEqual(t.cursor, [0, 0])
        t.feed("\(CSI)2;1H\(CSI)M")
        XCTAssertScreen(t, ["1", "", "3", "", "5"])
    }

    func testInsertAndDeleteCharacters() {
        var t = terminal(6, 2, "abcdef")
        t.feed("\(CSI)1;2H\(CSI)42m\(CSI)2@")
        XCTAssertScreen(t, ["a  bcd", ""])
        XCTAssertEqual(t.cell(0, 1), Cell(backgroundColor: 42))
        XCTAssertEqual(t.cell(0, 2), Cell(backgroundColor: 42))
        XCTAssertEqual(t.cursor, [0, 1])

        t.feed("\(CSI)m\(CSI)2;1Hghijkl\(CSI)2;2H\(CSI)43m\(CSI)2P")
        XCTAssertScreen(t, ["a  bcd", "gjkl"])
        XCTAssertEqual(t.cell(1, 4), Cell(backgroundColor: 43))
        XCTAssertEqual(t.cell(1, 5), Cell(backgroundColor: 43))
        t.feed("\(CSI)99P")
        XCTAssertScreen(t, ["a  bcd", "g"])

        // DCH shifts the old last cell left together with its wrap mark
        t = terminal(6, 2, "aaaaaab")
        XCTAssertTrue(t.fb.rows[0].wrap)
        t.feed("\(CSI)1;1H\(CSI)P")
        XCTAssertFalse(t.fb.rows[0].wrap)
        XCTAssertTrue(t.cell(0, 4).wrap)
        XCTAssertFalse(t.cell(0, 5).wrap)
        // ICH pushes the last cell out
        t.feed("\(CSI)@")
        XCTAssertTrue(t.fb.rows[0].wrap, "the marked cell is the last one again")
    }

    func testInsertMode() {
        var t = terminal(8, 2, "abcdef")
        t.feed("\(CSI)1;3H\(CSI)4hXY")
        XCTAssertTrue(t.fb.ds.insertMode)
        XCTAssertScreen(t, ["abXYcdef", ""])
        t.feed("\(CSI)4lZ")
        XCTAssertFalse(t.fb.ds.insertMode)
        XCTAssertScreen(t, ["abXYZdef", ""])
        // a wide character inserts two cells
        t.feed("\(CSI)1;1H\(CSI)4h日")
        XCTAssertScreen(t, ["日abXYZd", ""])
        XCTAssertTrue(t.cell(0, 0).wide)
        XCTAssertEqual(t.cell(0, 2).contents, [0x61])
    }

    // MARK: Scrolling

    func testScrollingRegionWithLFAndRI() {
        var t = terminal(3, 5, "1\r\n2\r\n3\r\n4\r\n5")
        t.feed("\(CSI)2;4r")
        XCTAssertEqual(t.fb.ds.scrollingRegionTopRow, 1)
        XCTAssertEqual(t.fb.ds.scrollingRegionBottomRow, 3)
        XCTAssertEqual(t.cursor, [0, 0], "DECSTBM homes the cursor")

        // LF on the bottom line of the region scrolls the region only
        t.feed("\(CSI)4;1H\n")
        XCTAssertScreen(t, ["1", "3", "4", "", "5"])
        XCTAssertEqual(t.cursor, [3, 0])
        t.feed("X")

        // RI on the top line of the region scrolls it down
        t.feed("\(CSI)2;1H\u{1B}M")
        XCTAssertScreen(t, ["1", "", "3", "4", "5"])
        XCTAssertEqual(t.cursor, [1, 0])

        // below the region: LF moves, and stops at the last line without scrolling
        t.feed("\(CSI)5;1H\n\n")
        XCTAssertScreen(t, ["1", "", "3", "4", "5"])
        XCTAssertEqual(t.cursor, [4, 0])
        // above the region: LF moves into it
        t.feed("\(CSI)1;1H\n")
        XCTAssertEqual(t.cursor, [1, 0])
        // RI above the region stops at the first line
        t.feed("\(CSI)1;1H\u{1B}M")
        XCTAssertEqual(t.cursor, [0, 0])
        XCTAssertScreen(t, ["1", "", "3", "4", "5"])

        // invalid regions are ignored and do not move the cursor
        t.feed("\(CSI)3;2H\(CSI)4;2r\(CSI)3;3r\(CSI)9;10r")
        XCTAssertEqual(t.fb.ds.scrollingRegionTopRow, 1)
        XCTAssertEqual(t.fb.ds.scrollingRegionBottomRow, 3)
        XCTAssertEqual(t.cursor, [2, 1])
        // the bottom is clamped; no parameters means the whole screen
        t.feed("\(CSI)2;99r")
        XCTAssertEqual(t.fb.ds.scrollingRegionBottomRow, 4)
        t.feed("\(CSI)r")
        XCTAssertEqual(t.fb.ds.scrollingRegionTopRow, 0)
        XCTAssertEqual(t.fb.ds.scrollingRegionBottomRow, 4)
    }

    func testFullScreenScrollAndSDSU() {
        var t = terminal(3, 3, "1\r\n2\r\n3\n")
        XCTAssertScreen(t, ["2", "3", ""])
        XCTAssertEqual(t.cursor, [2, 1], "LF keeps the column")
        t.feed("\(CSI)S") // SD in mosh's naming: text moves up
        XCTAssertScreen(t, ["3", "", ""])
        t.feed("\(CSI)2T") // text moves down
        XCTAssertScreen(t, ["", "", "3"])
        XCTAssertEqual(t.cursor, [2, 1], "scrolling does not move the cursor")
        t.feed("\(CSI)99S")
        XCTAssertScreen(t, ["", "", ""])
    }

    func testOriginMode() {
        var t = terminal(5, 6)
        // Setting origin mode homes the cursor *before* the mode changes: to the screen's
        // first line, above the region.
        t.feed("\(CSI)2;4r\(CSI)3;3H\(CSI)?6h")
        XCTAssertTrue(t.fb.ds.originMode)
        XCTAssertEqual(t.cursor, [0, 0])
        t.feed("\(CSI)1;1H")
        XCTAssertEqual(t.cursor, [1, 0], "row 1 is the top of the region")
        t.feed("\(CSI)9;9H")
        XCTAssertEqual(t.cursor, [3, 4], "clamped to the bottom of the region")
        t.feed("\(CSI)99A")
        XCTAssertEqual(t.cursor, [1, 4])
        t.feed("\(CSI)2d")
        XCTAssertEqual(t.cursor, [2, 4])
        // Resetting it homes the cursor while the mode is still on: to the region's top.
        t.feed("\(CSI)?6l")
        XCTAssertFalse(t.fb.ds.originMode)
        XCTAssertEqual(t.cursor, [1, 0])
        t.feed("\(CSI)1;1H")
        XCTAssertEqual(t.cursor, [0, 0])
    }

    // MARK: SGR

    func testSGRAttributes() {
        var t = terminal(10, 1)
        t.feed("\(CSI)1;3;4;5;7;8m")
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x7D) // bits 0, 2, 3, 4, 5, 6
        for a in [Renditions.Attribute.bold, .italic, .underlined, .blink, .inverse, .invisible] {
            XCTAssertTrue(t.fb.ds.renditions.getAttribute(a))
        }
        XCTAssertFalse(t.fb.ds.renditions.getAttribute(.faint))
        t.feed("\(CSI)22;24m")
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x74)
        t.feed("\(CSI)23;25;27;28m")
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0)
        t.feed("\(CSI)2;9;21;53m") // faint, strike, double underline, overline: not supported
        XCTAssertEqual(t.fb.ds.renditions, Renditions(background: 0))
        t.feed("\(CSI)1;31;42m\(CSI)m")
        XCTAssertEqual(t.fb.ds.renditions, Renditions(background: 0))
        t.feed("\(CSI)1;4m\(CSI)0;7m")
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x20)
    }

    func testSGRColours() {
        var t = terminal(10, 1)
        func pen() -> [UInt32] { return [t.fb.ds.renditions.foregroundColor, t.fb.ds.renditions.backgroundColor] }
        t.feed("\(CSI)31;42m")
        XCTAssertEqual(pen(), [31, 42])
        t.feed("\(CSI)91;102m") // bright colours are palette entries 9 and 10
        XCTAssertEqual(pen(), [39, 50])
        t.feed("\(CSI)39m")
        XCTAssertEqual(pen(), [0, 50])
        t.feed("\(CSI)49m")
        XCTAssertEqual(pen(), [0, 0])
        t.feed("\(CSI)38;5;200m\(CSI)48;5;255m")
        XCTAssertEqual(pen(), [230, 295])
        t.feed("\(CSI)38;5;1m\(CSI)48;5;0m") // palette 1 is the same value as SGR 31; index 0 is not "default"
        XCTAssertEqual(pen(), [31, 40])
        t.feed("\(CSI)38;5;300m") // out of range: ignored
        XCTAssertEqual(pen(), [31, 40])
        t.feed("\(CSI)38;2;1;2;3m\(CSI)48;2;255;254;253m")
        XCTAssertEqual(pen(), [0x1010203, 0x1FFFEFD])
        t.feed("\(CSI)38;2;0;0;0m") // black is not "default"
        XCTAssertEqual(pen(), [0x1000000, 0x1FFFEFD])
        t.feed("\(CSI)38;2;300;0;0m") // components are not clamped: 300 << 16 keeps its low 9 bits
        XCTAssertEqual(pen(), [0x12C0000, 0x1FFFEFD])
        t.feed("\(CSI)0m")
        XCTAssertEqual(pen(), [0, 0])

        // several in one sequence, in order
        t.feed("\(CSI)1;38;5;9;4;48;2;9;8;7;7m")
        XCTAssertEqual(pen(), [39, 0x1090807])
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x29) // bold, underlined, inverse

        // too few parameters for the extended forms: 38 is ignored, the rest are plain SGRs
        t.feed("\(CSI)m\(CSI)38;5m")
        XCTAssertEqual(pen(), [0, 0])
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x10, "5 alone is blink")
        t.feed("\(CSI)m\(CSI)48;2;1;4m")
        XCTAssertEqual(pen(), [0, 0])
        XCTAssertEqual(t.fb.ds.renditions.attributes, 0x09, "1 is bold and 4 is underlined; 2 is ignored")

        // a printed cell takes the whole pen
        t.feed("\(CSI)0;1;33;44mx")
        XCTAssertEqual(t.cell(0, 0).renditions, t.fb.ds.renditions)
        XCTAssertEqual(t.cell(0, 0).renditions.foregroundColor, 33)
        XCTAssertEqual(t.cell(0, 0).renditions.backgroundColor, 44)
        XCTAssertEqual(t.cell(0, 0).renditions.attributes, 1)
    }

    func testSGRString() {
        XCTAssertEqual(Renditions(background: 0).sgr(), "\u{1B}[0m")
        var r = Renditions(background: 0)
        r.setRendition(1); r.setRendition(31); r.setRendition(42)
        XCTAssertEqual(r.sgr(), "\u{1B}[0;1;31;42m")
        r = Renditions(background: 0)
        for n in [3, 4, 5, 7, 8] as [UInt32] { r.setRendition(n) }
        r.setForegroundColor(200)
        r.setBackgroundColor(Renditions.makeTrueColor(255, 254, 253))
        XCTAssertEqual(r.sgr(), "\u{1B}[0;3;4;5;7;8;38;5;200;48;2;255;254;253m")
        r = Renditions(background: 0)
        r.setRendition(91); r.setRendition(102) // stored as palette 9 and 10, written as such
        XCTAssertEqual(r.sgr(), "\u{1B}[0;38;5;9;48;5;10m")
        r = Renditions(background: 0)
        r.setForegroundColor(Renditions.makeTrueColor(1, 2, 3))
        r.setBackgroundColor(7) // palette 7 is written as the ANSI colour
        XCTAssertEqual(r.sgr(), "\u{1B}[0;38;2;1;2;3;47m")
        // Renditions( background ) keeps only the background
        XCTAssertEqual(Renditions(background: 240).sgr(), "\u{1B}[0;48;5;200m")
    }

    // MARK: Tabs

    func testTabs() {
        var t = terminal(20, 2, "\t")
        XCTAssertEqual(t.cursor, [0, 8])
        t.feed("\t")
        XCTAssertEqual(t.cursor, [0, 16])
        t.feed("\t")
        XCTAssertEqual(t.cursor, [0, 19], "no stop left: last column")
        XCTAssertFalse(t.fb.ds.nextPrintWillWrap)

        // HTS (ESC H) at column 4
        t.feed("\(CSI)1;5H\u{1B}H\r\t")
        XCTAssertEqual(t.cursor, [0, 4])
        // TBC 0 clears the stop under the cursor
        t.feed("\(CSI)1;9H\(CSI)g\r\t\t")
        XCTAssertEqual(t.cursor, [0, 16])
        // CBT: back one stop, back two stops (column 0 is the floor, not a stop that counts)
        t.feed("\(CSI)1;11H\(CSI)Z")
        XCTAssertEqual(t.cursor, [0, 4])
        t.feed("\(CSI)1;11H\(CSI)2Z")
        XCTAssertEqual(t.cursor, [0, 0])
        // CHT: forward two stops
        t.feed("\(CSI)2I")
        XCTAssertEqual(t.cursor, [0, 16])
        XCTAssertTrue(t.fb.ds.defaultTabs)
        // TBC 3 clears all stops
        t.feed("\(CSI)3g\r\t")
        XCTAssertEqual(t.cursor, [0, 19])
        XCTAssertFalse(t.fb.ds.defaultTabs)
        XCTAssertEqual(t.fb.ds.tabs, Array(repeating: false, count: 20))
    }

    func testTabKeepsThePendingWrap() {
        var t = terminal(5, 2, "abcde")
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        t.feed("\t")
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap, "a tab is the only motion that keeps the wrap state")
        t.feed("f")
        XCTAssertScreen(t, ["abcde", "f"])
    }

    func testTabsAfterResize() {
        var t = terminal(20, 1)
        t.resize(width: 30, height: 1)
        XCTAssertEqual(t.fb.ds.tabs.enumerated().filter { $0.element }.map { $0.offset }, [0, 8, 16, 24])
        t.feed("\(CSI)3g")
        t.resize(width: 40, height: 1)
        XCTAssertEqual(t.fb.ds.tabs, Array(repeating: false, count: 40), "no default stops after TBC 3")
    }

    // MARK: Wrapping

    func testAutowrapAtTheRightMargin() {
        var t = terminal(5, 3, "abcde")
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        XCTAssertFalse(t.fb.rows[0].wrap, "the row is marked only when the next character wraps")
        t.feed("f")
        XCTAssertScreen(t, ["abcde", "f", ""])
        XCTAssertTrue(t.fb.rows[0].wrap)
        XCTAssertTrue(t.cell(0, 4).wrap, "the mark is the wrap bit of the last cell")
        XCTAssertEqual(t.cursor, [1, 1])
        XCTAssertFalse(t.fb.ds.nextPrintWillWrap)

        // the wrap scrolls at the bottom of the screen
        t = terminal(5, 2, "abcdefghijk")
        XCTAssertScreen(t, ["fghij", "k"])
        XCTAssertTrue(t.fb.rows[0].wrap)
        XCTAssertEqual(t.cursor, [1, 1])
    }

    func testPendingWrapIsCancelledByMotionAndUnknownFunctions() {
        func after(_ s: String) -> TerminalState { return terminal(5, 2, "abcde" + s + "X") }
        XCTAssertScreen(after("\(CSI)D"), ["abcXe", ""]) // CUB from column 4
        XCTAssertScreen(after("\r"), ["Xbcde", ""])
        XCTAssertScreen(after("\(CSI)1;5H"), ["abcdX", ""])
        XCTAssertScreen(after("\u{7}"), ["abcdX", ""]) // BEL is a registered function that clears it
        XCTAssertScreen(after("\u{0}"), ["abcdX", ""]) // NUL is an unknown control: clears it too
        XCTAssertScreen(after("\(CSI)1 q"), ["abcdX", ""]) // unknown CSI
        XCTAssertScreen(after("\u{1B}7"), ["abcdX", ""]) // DECSC
        // these keep it
        XCTAssertScreen(after("\(CSI)1;31m"), ["abcde", "X"]) // SGR
        XCTAssertScreen(after("\(CSI)?25l"), ["abcde", "X"]) // DECRM
        XCTAssertScreen(after("\(CSI)?2004h"), ["abcde", "X"]) // DECSM
        XCTAssertScreen(after("\(CSI)g"), ["abcde", "X"]) // TBC
        XCTAssertScreen(after("\t"), ["abcde", "X"])
        XCTAssertScreen(after("\u{1B}]0;t\u{7}"), ["abcde", "X"]) // OSC
        XCTAssertScreen(after("\u{301}"), ["abcde\u{301}", "X"]) // combining character
        XCTAssertScreen(after("\u{7F}"), ["abcde", "X"]) // dropped character
    }

    func testAutowrapOff() {
        var t = terminal(5, 2, "\(CSI)?7labcdefg")
        XCTAssertFalse(t.fb.ds.autoWrapMode)
        XCTAssertScreen(t, ["abcdg", ""])
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap, "the flag is still set, only not acted on")
        XCTAssertFalse(t.fb.rows[0].wrap)
        t.feed("\(CSI)?7hh")
        XCTAssertScreen(t, ["abcdg", "h"])
    }

    func testWideCharacters() {
        var t = terminal(6, 3, "a日b")
        XCTAssertEqual(t.cell(0, 1).contents, utf8("日"))
        XCTAssertTrue(t.cell(0, 1).wide)
        XCTAssertEqual(t.cell(0, 2), Cell(backgroundColor: 0), "the second half is a plain blank cell")
        XCTAssertEqual(t.cell(0, 3).contents, [0x62])
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertScreen(t, ["a日b", "", ""])

        // a wide character that fills the row exactly arms the wrap
        t = terminal(5, 3, "abc日")
        XCTAssertTrue(t.cell(0, 3).wide)
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        t.feed("x")
        XCTAssertTrue(t.fb.rows[0].wrap)
        XCTAssertEqual(t.cell(1, 0).contents, [0x78])

        // overwriting the second half does not repair the first: mosh leaves the wide cell
        t = terminal(6, 1, "日\(CSI)1;2HX")
        XCTAssertTrue(t.cell(0, 0).wide)
        XCTAssertEqual(t.cell(0, 1).contents, [0x58])
        // overwriting the first half with a narrow character clears the wide flag
        t = terminal(6, 1, "日\rX")
        XCTAssertFalse(t.cell(0, 0).wide)
        XCTAssertEqual(t.cell(0, 0).contents, [0x58])
    }

    func testWideCharacterAtTheRightMargin() {
        // One column left: the wide character goes to the next line. The skipped cell is
        // erased and the row is *not* marked as wrapped.
        var t = terminal(5, 3, "\(CSI)41mabcd日")
        XCTAssertEqual(t.cell(0, 4), Cell(backgroundColor: 41))
        XCTAssertFalse(t.fb.rows[0].wrap)
        XCTAssertTrue(t.cell(1, 0).wide)
        XCTAssertEqual(t.cell(1, 0).contents, utf8("日"))
        XCTAssertEqual(t.cursor, [1, 2])
        XCTAssertScreen(t, ["abcd", "日", ""])

        // without autowrap it is written into the last column and nothing to its right is erased
        t = terminal(5, 3, "\(CSI)?7labcd日")
        XCTAssertTrue(t.cell(0, 4).wide)
        XCTAssertEqual(t.cell(0, 4).contents, utf8("日"))
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        XCTAssertScreen(t, ["abcd日", "", ""])

        // a screen one column wide: every wide character first moves down a line
        t = terminal(1, 3, "日")
        XCTAssertEqual(t.cursor, [1, 0])
        XCTAssertTrue(t.cell(1, 0).wide)
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
    }

    // MARK: Combining characters

    func testCombiningCharacters() {
        var t = terminal(10, 2, "e\u{301}x")
        XCTAssertEqual(t.contents(0, 0), [0x65, 0xCC, 0x81])
        XCTAssertFalse(t.cell(0, 0).fallback)
        XCTAssertEqual(t.contents(0, 1), [0x78])
        XCTAssertEqual(t.cursor, [0, 2])

        // on an empty cell: a "fallback" cell, the cursor advances, later combiners join it
        t = terminal(10, 2, "\u{301}")
        XCTAssertTrue(t.cell(0, 0).fallback)
        XCTAssertEqual(t.contents(0, 0), [0xCC, 0x81])
        XCTAssertEqual(t.cursor, [0, 1])
        t.feed("\u{302}")
        XCTAssertEqual(t.contents(0, 0), [0xCC, 0x81, 0xCC, 0x82])
        XCTAssertEqual(t.cursor, [0, 1])
        var printed: [UInt8] = []
        t.cell(0, 0).printGrapheme(into: &printed)
        XCTAssertEqual(printed, [0xC2, 0xA0, 0xCC, 0x81, 0xCC, 0x82], "drawn on a no-break space")
        // the fallback cell keeps the renditions it had; the pen is not applied
        t = terminal(10, 2, "\(CSI)1;31m\u{301}")
        XCTAssertEqual(t.cell(0, 0).renditions, Renditions(background: 0))

        // after an explicit cursor move the cell under the cursor is the target
        t = terminal(10, 2, "ab\(CSI)1;1H\u{301}")
        XCTAssertEqual(t.contents(0, 0), [0x61, 0xCC, 0x81])
        XCTAssertEqual(t.cursor, [0, 0])

        // the limit: no more appends once the cell holds 32 bytes or more
        t = terminal(10, 2, "a" + String(repeating: "\u{301}", count: 20))
        XCTAssertEqual(t.contents(0, 0).count, 33) // 1 + 16 * 2
        t = terminal(10, 2, "a" + String(repeating: "\u{1D167}", count: 20)) // 4 bytes each
        XCTAssertEqual(t.contents(0, 0).count, 33) // 1 + 8 * 4
        t = terminal(10, 2, "日" + String(repeating: "\u{1D167}", count: 20))
        XCTAssertEqual(t.contents(0, 0).count, 35) // 3 + 8 * 4: the largest a cell can get
    }

    func testCombiningCharacterAfterAWrap() {
        // at the right margin with the wrap pending: joins the last column, nothing moves
        var t = terminal(5, 3, "abcde\u{301}")
        XCTAssertEqual(t.contents(0, 4), [0x65, 0xCC, 0x81])
        XCTAssertEqual(t.cursor, [0, 4])
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        // the next character wraps and takes its own combiner
        t.feed("f\u{302}")
        XCTAssertEqual(t.contents(1, 0), [0x66, 0xCC, 0x82])
        XCTAssertEqual(t.contents(0, 4), [0x65, 0xCC, 0x81])
        XCTAssertTrue(t.fb.rows[0].wrap)
        XCTAssertEqual(t.cursor, [1, 1])
        // after a wide character that was moved to the next line
        t = terminal(5, 3, "abcd日\u{3099}")
        XCTAssertEqual(t.contents(1, 0), utf8("日") + [0xE3, 0x82, 0x99])
    }

    func testCombiningCharacterAfterResize() {
        var t = terminal(10, 2, "abcdefgh")
        XCTAssertEqual([t.fb.ds.combiningCharRow, t.fb.ds.combiningCharCol], [0, 7])
        t.resize(width: 4, height: 2)
        XCTAssertEqual([t.fb.ds.combiningCharRow, t.fb.ds.combiningCharCol], [-1, -1])
        t.feed("\u{301}")
        XCTAssertScreen(t, ["abcd", ""])
        XCTAssertEqual(t.contents(0, 3), [0x64], "the combiner had no cell left and was dropped")
    }

    // MARK: Saved cursor

    func testSaveAndRestoreCursor() {
        var t = terminal(10, 4, "\(CSI)2;3H\(CSI)1;31m\(CSI)?7l\u{1B}7")
        XCTAssertEqual(t.fb.ds.save.cursorRow, 1)
        XCTAssertEqual(t.fb.ds.save.cursorCol, 2)
        XCTAssertEqual(t.fb.ds.save.renditions.foregroundColor, 31)
        XCTAssertEqual(t.fb.ds.save.renditions.attributes, 1)
        XCTAssertFalse(t.fb.ds.save.autoWrapMode)
        XCTAssertFalse(t.fb.ds.save.originMode)

        t.feed("\(CSI)m\(CSI)?7h\(CSI)4;4Hx\u{1B}8")
        XCTAssertEqual(t.cursor, [1, 2])
        XCTAssertEqual(t.fb.ds.renditions.foregroundColor, 31)
        XCTAssertEqual(t.fb.ds.renditions.attributes, 1)
        XCTAssertFalse(t.fb.ds.autoWrapMode)
        t.feed("y")
        XCTAssertEqual(t.cell(1, 2).renditions.foregroundColor, 31)

        // origin mode is saved too
        t = terminal(10, 4, "\(CSI)2;3r\(CSI)?6h\u{1B}7\(CSI)?6l\u{1B}8")
        XCTAssertTrue(t.fb.ds.originMode)

        // DECRC without DECSC: home position, default pen, autowrap on
        t = terminal(10, 4, "\(CSI)3;3H\(CSI)1m\(CSI)?7l\u{1B}8")
        XCTAssertEqual(t.cursor, [0, 0])
        XCTAssertEqual(t.fb.ds.renditions, Renditions(background: 0))
        XCTAssertTrue(t.fb.ds.autoWrapMode)

        // a saved position outside a smaller screen is clamped on restore
        t = terminal(10, 4, "\(CSI)4;10H\u{1B}7")
        t.resize(width: 5, height: 2)
        XCTAssertEqual(t.fb.ds.save.cursorRow, 3, "the saved cursor itself is not touched by a resize")
        t.feed("\u{1B}8")
        XCTAssertEqual(t.cursor, [1, 4])
    }

    // MARK: Resets

    func testFullReset() {
        var t = terminal(10, 3, "\u{1B}]0;title\u{7}\u{7}\u{7}\u{1B}]52;c;Zm9v\u{7}abc\(CSI)2;3r\(CSI)?6h\(CSI)1;41m\(CSI)3g\(CSI)?25l\(CSI)4h\(CSI)?1000h\u{1B}7")
        XCTAssertEqual(t.fb.bellCount, 2)
        t.feed("\u{1B}c")
        XCTAssertScreen(t, ["", "", ""])
        XCTAssertEqual(t.fb.ds, DrawState(width: 10, height: 3), "the whole draw state is new")
        XCTAssertEqual(t.fb.rows[0].cells, Array(repeating: Cell(backgroundColor: 0), count: 10))
        XCTAssertTrue(t.fb.rows[0] === t.fb.rows[1] && t.fb.rows[1] === t.fb.rows[2], "one shared blank row")
        XCTAssertEqual(t.fb.windowTitle, [])
        XCTAssertEqual(t.fb.clipboard, [])
        // what RIS does not reset
        XCTAssertEqual(t.fb.iconName, "title".unicodeScalars.map { $0.value })
        XCTAssertEqual(t.fb.bellCount, 2)
        XCTAssertTrue(t.fb.titleInitialized)
    }

    func testSoftReset() {
        var t = terminal(10, 4, "abc\(CSI)2;3r\(CSI)?6h\(CSI)4h\(CSI)?25l\(CSI)?1h\(CSI)1;31m\u{1B}7\(CSI)?7l\(CSI)?5h\(CSI)?2004h\(CSI)?1002h\(CSI)3g\(CSI)2;5H")
        let before = t.fb.ds
        XCTAssertEqual([before.cursorRow, before.cursorCol], [2, 4])
        t.feed("\(CSI)!p")
        let ds = t.fb.ds
        XCTAssertFalse(ds.insertMode)
        XCTAssertFalse(ds.originMode)
        XCTAssertTrue(ds.cursorVisible)
        XCTAssertFalse(ds.applicationModeCursorKeys)
        XCTAssertEqual([ds.scrollingRegionTopRow, ds.scrollingRegionBottomRow], [0, 3])
        XCTAssertEqual(ds.renditions, Renditions(background: 0))
        XCTAssertEqual(ds.save, SavedCursor())
        // what DECSTR leaves alone
        XCTAssertEqual([ds.cursorRow, ds.cursorCol], [2, 4])
        XCTAssertFalse(ds.autoWrapMode)
        XCTAssertTrue(ds.reverseVideo)
        XCTAssertTrue(ds.bracketedPaste)
        XCTAssertEqual(ds.mouseReportingMode, .btnEvent)
        XCTAssertFalse(ds.defaultTabs)
        XCTAssertScreen(t, ["abc", "", "", ""])
    }

    // MARK: Titles, clipboard, bell

    private func scalars(_ s: String) -> [UInt32] { return s.unicodeScalars.map { $0.value } }

    func testTitles() {
        var t = terminal(10, 2)
        XCTAssertFalse(t.fb.titleInitialized)
        t.feed("\u{1B}]3;no\u{7}\u{1B}]2\u{7}\u{1B}]\u{7}\u{1B}]12;x\u{7}")
        XCTAssertFalse(t.fb.titleInitialized, "none of these is a title sequence")
        XCTAssertEqual(t.fb.windowTitle, [])

        t.feed("\u{1B}]0;both\u{7}")
        XCTAssertTrue(t.fb.titleInitialized)
        XCTAssertEqual(t.fb.iconName, scalars("both"))
        XCTAssertEqual(t.fb.windowTitle, scalars("both"))
        t.feed("\u{1B}]1;icon\u{7}")
        XCTAssertEqual(t.fb.iconName, scalars("icon"))
        XCTAssertEqual(t.fb.windowTitle, scalars("both"))
        t.feed("\u{1B}]2;title\u{1B}\\") // ST as terminator
        XCTAssertEqual(t.fb.iconName, scalars("icon"))
        XCTAssertEqual(t.fb.windowTitle, scalars("title"))
        t.feed("\u{1B}];bare\u{7}") // no number: counts as 0
        XCTAssertEqual(t.fb.iconName, scalars("bare"))
        XCTAssertEqual(t.fb.windowTitle, scalars("bare"))
        t.feed("\u{1B}]2;日本 e\u{301}\u{9C}") // code points, not bytes; C1 ST as terminator
        XCTAssertEqual(t.fb.windowTitle, [0x65E5, 0x672C, 0x20, 0x65, 0x301])
        t.feed("\u{1B}]0;\u{7}")
        XCTAssertEqual(t.fb.windowTitle, [])
        XCTAssertEqual(t.fb.iconName, [])
        XCTAssertTrue(t.fb.titleInitialized)

        // command and title together are cut at 256 characters
        t.feed("\u{1B}]0;" + String(repeating: "a", count: 300) + "\u{7}")
        XCTAssertEqual(t.fb.windowTitle.count, 254)
        t.feed("\u{1B}];" + String(repeating: "b", count: 300) + "\u{7}")
        XCTAssertEqual(t.fb.windowTitle.count, 255)

        // C0 controls inside the string are ignored, not part of the title
        t.feed("\u{1B}]2;a\nb\rc\u{7}")
        XCTAssertEqual(t.fb.windowTitle, scalars("abc"))
        XCTAssertEqual(t.fb.bellCount, 0, "a BEL that ends an OSC does not ring")
    }

    func testPrefixWindowTitle() {
        var t = terminal(10, 2, "\u{1B}]0;x\u{7}")
        var fb = t.fb
        fb.prefixWindowTitle(scalars("[mosh] "))
        XCTAssertEqual(fb.windowTitle, scalars("[mosh] x"))
        XCTAssertEqual(fb.iconName, scalars("[mosh] x"), "equal names stay equal")
        t.feed("\u{1B}]1;i\u{7}")
        fb = t.fb
        fb.prefixWindowTitle(scalars("[mosh] "))
        XCTAssertEqual(fb.windowTitle, scalars("[mosh] x"))
        XCTAssertEqual(fb.iconName, scalars("i"))
    }

    func testClipboard() {
        var t = terminal(10, 2, "\u{1B}]52;c;aGVsbG8=\u{7}")
        XCTAssertEqual(t.fb.clipboard, scalars("aGVsbG8="), "stored as sent, not decoded")
        XCTAssertFalse(t.fb.titleInitialized)
        // only the literal prefix "52;c;" is accepted
        t.feed("\u{1B}]52;;bm8=\u{7}\u{1B}]52;p;bm8=\u{7}\u{1B}]52;c\u{7}\u{1B}]52;cs;bm8=\u{7}")
        XCTAssertEqual(t.fb.clipboard, scalars("aGVsbG8="))
        t.feed("\u{1B}]52;c;?\u{1B}\\") // a query is stored like any other text
        XCTAssertEqual(t.fb.clipboard, scalars("?"))
        t.feed("\u{1B}]52;c;\u{7}")
        XCTAssertEqual(t.fb.clipboard, [])
        // the OSC string is capped at 16384 characters, prefix included
        t.feed("\u{1B}]52;c;" + String(repeating: "A", count: 20000) + "\u{7}")
        XCTAssertEqual(t.fb.clipboard.count, 16384 - 5)
    }

    func testBell() {
        var t = terminal(10, 2, "\u{7}a\u{7}\u{7}")
        XCTAssertEqual(t.fb.bellCount, 3)
        t.feed("\u{1B}[1\u{7}m") // executed in the middle of a CSI
        XCTAssertEqual(t.fb.bellCount, 4)
        XCTAssertEqual(t.fb.ds.renditions.attributes, 1)
    }

    // MARK: Modes

    func testModes() {
        var t = terminal(10, 3)
        let d0 = t.fb.ds
        XCTAssertEqual([d0.applicationModeCursorKeys, d0.reverseVideo, d0.originMode, d0.insertMode,
                        d0.bracketedPaste, d0.mouseFocusEvent, d0.mouseAlternateScroll],
                       [false, false, false, false, false, false, false])
        XCTAssertEqual([d0.autoWrapMode, d0.cursorVisible], [true, true])
        XCTAssertEqual(d0.mouseReportingMode, .none)
        XCTAssertEqual(d0.mouseEncodingMode, .default)

        t.feed("\(CSI)?1h"); XCTAssertTrue(t.fb.ds.applicationModeCursorKeys)
        t.feed("\(CSI)?5h"); XCTAssertTrue(t.fb.ds.reverseVideo)
        t.feed("\(CSI)?7l"); XCTAssertFalse(t.fb.ds.autoWrapMode)
        t.feed("\(CSI)?25l"); XCTAssertFalse(t.fb.ds.cursorVisible)
        t.feed("\(CSI)?1004h"); XCTAssertTrue(t.fb.ds.mouseFocusEvent)
        t.feed("\(CSI)?1007h"); XCTAssertTrue(t.fb.ds.mouseAlternateScroll)
        t.feed("\(CSI)?2004h"); XCTAssertTrue(t.fb.ds.bracketedPaste)
        t.feed("\(CSI)4h"); XCTAssertTrue(t.fb.ds.insertMode)

        // several parameters in one sequence
        t.feed("\(CSI)?1;5;1004;1007;2004l\(CSI)?7;25h\(CSI)4l")
        XCTAssertEqual(t.fb.ds, d0)

        // ANSI and DEC modes do not mix
        t.feed("\(CSI)?4h\(CSI)25l\(CSI)2004h")
        XCTAssertEqual(t.fb.ds, d0)
        // unknown modes are ignored
        t.feed("\(CSI)?12h\(CSI)?1049h\(CSI)?47h\(CSI)20h")
        XCTAssertEqual(t.fb.ds, d0)
    }

    func testMouseModes() {
        var t = terminal(10, 3)
        for (n, mode) in [(9, MouseReportingMode.x10), (1000, .vt220), (1001, .vt220Hilight),
                          (1002, .btnEvent), (1003, .anyEvent)] {
            t.feed("\(CSI)?\(n)h")
            XCTAssertEqual(t.fb.ds.mouseReportingMode, mode)
        }
        // resetting any reporting mode turns reporting off, whichever is active
        t.feed("\(CSI)?9l")
        XCTAssertEqual(t.fb.ds.mouseReportingMode, .none)
        // the way mosh's display turns it off
        t.feed("\(CSI)?1002h\(CSI)?1003l\(CSI)?1002l\(CSI)?1001l\(CSI)?1000l")
        XCTAssertEqual(t.fb.ds.mouseReportingMode, .none)

        for (n, mode) in [(1005, MouseEncodingMode.utf8), (1006, .sgr), (1015, .urxvt)] {
            t.feed("\(CSI)?\(n)h")
            XCTAssertEqual(t.fb.ds.mouseEncodingMode, mode)
        }
        t.feed("\(CSI)?1005l")
        XCTAssertEqual(t.fb.ds.mouseEncodingMode, .default)
        t.feed("\(CSI)?1000;1006h")
        XCTAssertEqual(t.fb.ds.mouseReportingMode, .vt220)
        XCTAssertEqual(t.fb.ds.mouseEncodingMode, .sgr)
    }

    func testDECCOLMClearsTheScreen() {
        var t = terminal(6, 2, "abc\r\ndef\(CSI)41m\(CSI)?3h")
        XCTAssertScreen(t, ["", ""])
        XCTAssertEqual(t.cursor, [0, 0])
        XCTAssertEqual(t.cell(1, 5), Cell(backgroundColor: 41))
        XCTAssertEqual(t.fb.ds.width, 6, "the width does not change")
        t.feed("xyz\(CSI)?3l") // resetting it clears as well
        XCTAssertScreen(t, ["", ""])
    }

    func testDECALN() {
        let t = terminal(4, 2, "\(CSI)1;41mab\u{1B}#8")
        XCTAssertScreen(t, ["EEEE", "EEEE"])
        // each cell is reset with the pen's background, then gets the letter; the pen itself is not applied
        XCTAssertEqual(t.cell(1, 3).renditions, Renditions(background: 41))
        XCTAssertEqual(t.cursor, [0, 2])
    }

    // MARK: Replies

    func testReplies() {
        var t = terminal(10, 5)
        XCTAssertEqual(t.feed("\(CSI)c"), "\u{1B}[?62c")
        XCTAssertEqual(t.feed("\(CSI)0c"), "\u{1B}[?62c")
        XCTAssertEqual(t.feed("\(CSI)>c"), "\u{1B}[>1;10;0c")
        XCTAssertEqual(t.feed("\(CSI)5n"), "\u{1B}[0n")
        XCTAssertEqual(t.feed("\(CSI)3;4H\(CSI)6n"), "\u{1B}[3;4R")
        XCTAssertEqual(t.feed("\(CSI)n\(CSI)7n\(CSI)?6n"), "")
        XCTAssertEqual(t.feed("a\(CSI)c\(CSI)5n"), "\u{1B}[?62c\u{1B}[0n", "replies of one write are returned together")
        XCTAssertEqual(t.terminal.dispatch.terminalToHost, [], "act empties the reply buffer")
    }

    // MARK: Resize

    func testResize() {
        var t = terminal(10, 4, "0123456789abcdefghij\r\nrow3\r\nrow4\(CSI)2;3r")
        t.feed("\(CSI)4;5H")
        XCTAssertTrue(t.fb.rows[0].wrap)

        t.resize(width: 6, height: 2)
        XCTAssertEqual([t.fb.ds.width, t.fb.ds.height], [6, 2])
        XCTAssertScreen(t, ["012345", "abcdef"]) // lines are cut at the bottom, columns at the right
        XCTAssertFalse(t.fb.rows[0].wrap, "a width change removes the wrap marks")
        XCTAssertEqual(t.cursor, [1, 4])
        XCTAssertEqual([t.fb.ds.scrollingRegionTopRow, t.fb.ds.scrollingRegionBottomRow], [0, 1])
        XCTAssertEqual(t.fb.ds.tabs.count, 6)
        XCTAssertEqual(t.fb.rows.count, 2)
        XCTAssertEqual(t.fb.rows[1].cells.count, 6)

        t.feed("\(CSI)42m")
        t.resize(width: 8, height: 4)
        XCTAssertScreen(t, ["012345", "abcdef", "", ""])
        XCTAssertEqual(t.cell(0, 7), Cell(backgroundColor: 42), "new cells take the pen background")
        XCTAssertEqual(t.cell(3, 0), Cell(backgroundColor: 42))
        XCTAssertTrue(t.fb.rows[2] === t.fb.rows[3], "the added lines are one row object")
        XCTAssertEqual(t.cursor, [1, 4])

        // sizes that are not positive are ignored (mosh would abort)
        let before = t
        t.resize(width: 0, height: 4)
        t.resize(width: 8, height: -1)
        XCTAssertEqual(t, before)
    }

    func testResizeKeepsThePendingWrapAndTheParser() {
        var t = terminal(6, 2, "abcdef\(CSI)3")
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap)
        t.resize(width: 8, height: 2)
        XCTAssertTrue(t.fb.ds.nextPrintWillWrap, "the flag survives a resize")
        XCTAssertEqual(t.cursor, [0, 5])
        t.feed("1mg") // the sequence that was cut by the resize is completed
        XCTAssertEqual(t.fb.ds.renditions.foregroundColor, 31)
        XCTAssertScreen(t, ["abcdef", "g"])
        XCTAssertTrue(t.fb.rows[0].wrap, "the mark is put on the last cell of the wider row")
        XCTAssertTrue(t.cell(0, 7).wrap)
    }

    // MARK: Dispatcher

    func testParameterParsing() {
        var d = Dispatcher()
        for c in "1;;3;65535;65536;007;99999999999999999999;0".unicodeScalars { d.newParamChar(c.value) }
        XCTAssertFalse(d.parsed)
        XCTAssertEqual(d.paramCount(), 8)
        XCTAssertTrue(d.parsed)
        XCTAssertEqual(d.parsedParams, [1, -1, 3, 65535, -1, 7, -1, 0])
        XCTAssertEqual(d.getparam(0, 9), 1)
        XCTAssertEqual(d.getparam(1, 9), 9, "empty")
        XCTAssertEqual(d.getparam(3, 9), 65535)
        XCTAssertEqual(d.getparam(4, 9), 9, "above PARAM_MAX")
        XCTAssertEqual(d.getparam(5, 9), 7)
        XCTAssertEqual(d.getparam(6, 9), 9, "overflows a long")
        XCTAssertEqual(d.getparam(7, 9), 9, "zero means default")
        XCTAssertEqual(d.getparam(8, 5), 5, "absent")
        XCTAssertEqual(d.getparam(7, 0), 0)

        // clear keeps the stale parsed values until the next use
        d.clear()
        XCTAssertEqual(d.params, [])
        XCTAssertFalse(d.parsed)
        XCTAssertEqual(d.parsedParams, [1, -1, 3, 65535, -1, 7, -1, 0])
        XCTAssertEqual(d.paramCount(), 1, "no parameter characters: one empty parameter")
        XCTAssertEqual(d.parsedParams, [-1])

        // at most 100 parameter characters, at most 8 dispatch characters below 256
        for _ in 0..<150 { d.newParamChar(0x31) }
        XCTAssertEqual(d.params.count, 100)
        for _ in 0..<12 { d.collect(0x20) }
        d.collect(0x100)
        XCTAssertEqual(d.dispatchChars, Array(repeating: 0x20, count: 8))
    }

    func testDispatcherStateOutlivesTheSequence() {
        var t = terminal(10, 2, "\(CSI)1;31m")
        XCTAssertEqual(t.terminal.dispatch.params, utf8("1;31"))
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, utf8("m"))
        XCTAssertEqual(t.terminal.dispatch.parsedParams, [1, 31])
        XCTAssertTrue(t.terminal.dispatch.parsed)
        // DA does not read its parameters; ESC cleared params but not the parsed values
        t.feed("\(CSI)>c")
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, utf8(">c"))
        XCTAssertEqual(t.terminal.dispatch.parsedParams, [1, 31])
        XCTAssertFalse(t.terminal.dispatch.parsed)
        // controls do not touch the dispatch characters
        t.feed("\n")
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, utf8(">c"))
        // ESC D is the C1 control IND: dispatched as a control, nothing collected
        t.feed("\u{1B}D")
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, [])
        // the OSC string stays after the OSC ended
        t.feed("\u{1B}]2;title\u{7}")
        XCTAssertEqual(t.terminal.dispatch.oscString, "2;title".unicodeScalars.map { $0.value })
        // a final character above 255 is not collected; one in 160...255 is
        t.feed("\(CSI)?日")
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, utf8("?"))
        t.feed("\(CSI)é")
        XCTAssertEqual(t.terminal.dispatch.dispatchChars, [0xE9])
    }

    func testEscapeSequencesForC1Controls() {
        // ESC M, ESC D, ESC E, ESC H are RI, IND, NEL, HTS; the same as U+008D, U+0084, U+0085, U+0088
        let a = terminal(10, 4, "ab\u{1B}Dcd\u{1B}Eef\u{1B}Mgh\(CSI)1;4H\u{1B}H")
        let b = terminal(10, 4, "ab\u{84}cd\u{85}ef\u{8D}gh\(CSI)1;4H\u{88}")
        // IND keeps the column, NEL returns to column 0, RI goes back up: "gh" lands on "cd"
        XCTAssertScreen(a, ["ab", "  gh", "ef", ""])
        XCTAssertEqual(a.fb, b.fb)
        XCTAssertTrue(a.fb.ds.tabs[3])
        // with an intermediate it is an escape sequence of its own, not a C1 control
        let c = terminal(10, 4, "ab\u{1B} Dcd")
        XCTAssertScreen(c, ["abcd", "", "", ""])
    }

    // MARK: User input and echo ack (server side of Complete)

    func testUserInputTranslation() {
        var t = terminal(10, 2)
        func type(_ s: String) -> String {
            var out: [UInt8] = []
            for c in utf8(s) { out += t.actUserByte(c) }
            return String(decoding: out, as: UTF8.self)
        }
        XCTAssertEqual(type("a\u{1B}OAb"), "a\u{1B}[Ab", "cursor keys become ANSI sequences outside application mode")
        XCTAssertEqual(type("\u{1B}OD\u{1B}OP"), "\u{1B}[D\u{1B}OP", "only A to D are translated")
        XCTAssertEqual(type("\u{1B}[A"), "\u{1B}[A")
        XCTAssertEqual(type("\u{1B}\u{1B}OA"), "\u{1B}\u{1B}OA", "the second ESC ends the look-ahead")
        t.feed("\(CSI)?1h")
        XCTAssertEqual(type("\u{1B}OA"), "\u{1B}OA", "application cursor keys: passed through")
        XCTAssertEqual(type("\u{1B}O"), "\u{1B}")
        XCTAssertEqual(t.terminal.user.state, .ss3)
        XCTAssertEqual(type("x"), "Ox")
        XCTAssertEqual(t.terminal.user.state, .ground)
    }

    func testEchoAck() {
        var t = terminal(10, 2)
        XCTAssertEqual(t.echoAck, 0)
        t.applyEchoAck(7)
        XCTAssertEqual(t.echoAck, 7)
        t.applyEchoAck(UInt64.max)
        XCTAssertEqual(t.echoAck, UInt64.max)

        // the server's side: frames are acknowledged 50 ms after they arrived
        var s = terminal(10, 2)
        XCTAssertEqual(s.waitTime(now: 1000), Int(Int32.max))
        s.registerInputFrame(1, now: 1000)
        s.registerInputFrame(2, now: 1020)
        XCTAssertEqual(s.waitTime(now: 1030), 40)
        XCTAssertEqual(s.waitTime(now: 1070), 0)
        XCTAssertFalse(s.setEchoAck(now: 1040))
        XCTAssertEqual(s.echoAck, 0)
        XCTAssertTrue(s.setEchoAck(now: 1060))
        XCTAssertEqual(s.echoAck, 1)
        XCTAssertEqual(s.inputHistory.count, 2)
        XCTAssertTrue(s.setEchoAck(now: 1075))
        XCTAssertEqual(s.echoAck, 2)
        XCTAssertEqual(s.inputHistory, [TerminalState.InputFrame(frameNum: 2, timestamp: 1020)])
        XCTAssertFalse(s.setEchoAck(now: 1080))
    }
}
