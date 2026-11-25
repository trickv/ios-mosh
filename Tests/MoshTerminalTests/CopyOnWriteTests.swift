// Framebuffer copies share rows; a write copies only the row it touches. Also the two
// notions of equality: structural `==` and mosh's `operator==` (`moshEquals`).

import XCTest
@testable import MoshTerminal

final class CopyOnWriteTests: XCTestCase {
    private func ids(_ t: TerminalState) -> [ObjectIdentifier] {
        return t.framebuffer.rows.map { ObjectIdentifier($0) }
    }

    func testCopyingAStateDoesNotCopyCells() {
        var a = terminal(20, 6, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")
        let b = a
        // the copy holds the very same row objects, so no cell was copied
        XCTAssertEqual(ids(a), ids(b))
        XCTAssertTrue(a.moshEquals(b))
        XCTAssertEqual(a, b)

        // 1024 copies (as many states as a client keeps) still share every row
        let copies = Array(repeating: a, count: 1024)
        XCTAssertEqual(ids(copies[1023]), ids(a))

        // a write through one copy replaces only the row it touches
        a.feed("\(CSI)3;1HTHREE")
        let ia = ids(a)
        let ib = ids(b)
        for y in 0..<6 {
            if y == 2 {
                XCTAssertNotEqual(ia[y], ib[y])
            } else {
                XCTAssertEqual(ia[y], ib[y], "line \(y) is still shared")
            }
        }
        XCTAssertEqual(ids(copies[0]), ib)
    }

    func testMutatingACopyLeavesTheOriginalUnchanged() {
        let original = terminal(10, 4, "\(CSI)1;31mhello\r\nworld\u{1B}]0;title\u{7}\(CSI)2;3r\(CSI)?1000h")
        let dumpBefore = original.debugDump()
        let reference = terminal(10, 4, "\(CSI)1;31mhello\r\nworld\u{1B}]0;title\u{7}\(CSI)2;3r\(CSI)?1000h")
        XCTAssertEqual(original, reference)

        var copy = original
        copy.feed("\(CSI)r\(CSI)1;1H\(CSI)0;42mXYZ\(CSI)2;2H\(CSI)K\n\n\n\n\(CSI)2J\u{1B}]0;other\u{7}\u{1B}]52;c;eA==\u{7}\u{7}")
        copy.feed("\(CSI)?1000l\(CSI)?25l\(CSI)4h\(CSI)3g\u{1B}7\(CSI)1;2")
        copy.resize(width: 7, height: 9)
        copy.applyEchoAck(99)

        XCTAssertNotEqual(copy, original)
        XCTAssertEqual(original, reference, "the original compares equal to an untouched twin")
        XCTAssertEqual(Array(original.debugDump().utf8), Array(dumpBefore.utf8), "and its dump is byte-identical")
        XCTAssertScreen(original, ["hello", "world", "", ""])
        XCTAssertEqual(original.cell(0, 0).renditions.foregroundColor, 31)

        // and the other way round: writes to the original do not reach the copy
        var a = terminal(5, 2, "ab")
        let b = a
        a.feed("cd\(CSI)2;1Hef")
        XCTAssertScreen(a, ["abcd", "ef"])
        XCTAssertScreen(b, ["ab", ""])
        // in-place cell mutations that keep the row object (insert, delete, erase) included
        var c = terminal(5, 2, "abcde")
        let d = c
        c.feed("\(CSI)1;2H\(CSI)P\(CSI)@\(CSI)X\u{301}")
        XCTAssertScreen(d, ["abcde", ""])
        XCTAssertEqual(d.cell(0, 1).contents, [0x62])
    }

    func testAnUnsharedRowIsWrittenInPlace() {
        var t = terminal(10, 3)
        // every line of a new screen is one row object
        XCTAssertEqual(Set(ids(t)).count, 1)
        t.feed("a")
        XCTAssertEqual(Set(ids(t)).count, 2, "line 0 got its own copy; lines 1 and 2 still share")
        let id0 = ids(t)[0]
        t.feed("bc\(CSI)K\(CSI)1;1H\(CSI)@\(CSI)P")
        XCTAssertEqual(ids(t)[0], id0, "no other owner: no further copy")

        // an older state that is dropped stops forcing copies
        var old: TerminalState? = t
        t.feed("d")
        XCTAssertNotEqual(ids(t)[0], id0)
        XCTAssertEqual(ids(old!)[0], id0)
        let id1 = ids(t)[0]
        old = nil
        t.feed("e")
        XCTAssertEqual(ids(t)[0], id1)
    }

    func testGenerations() {
        var t = terminal(10, 3, "abc\r\ndef")
        let rows = t.framebuffer.rows
        XCTAssertEqual(rows[0].gen, rows[2].gen, "copies of the first blank row keep its generation")
        XCTAssertEqual(rows[1].gen, rows[2].gen)

        // copy on write keeps the generation: for mosh the row is "the same row, changed"
        let saved = t
        t.feed("\(CSI)1;1HX")
        XCTAssertFalse(t.framebuffer.rows[0] === saved.framebuffer.rows[0])
        XCTAssertEqual(t.framebuffer.rows[0].gen, saved.framebuffer.rows[0].gen)

        // restoring the old text makes the rows equal for mosh's Row::operator==, though not identical
        t.feed("\ra")
        XCTAssertTrue(t.framebuffer.rows[0].moshEquals(saved.framebuffer.rows[0]))
        XCTAssertFalse(t.framebuffer.rows[0] === saved.framebuffer.rows[0])

        // erasing a whole line, and scrolling in a new line, give new generations
        t.feed("\(CSI)2K")
        XCTAssertNotEqual(t.framebuffer.rows[0].gen, saved.framebuffer.rows[0].gen)
        var blank = terminal(10, 3)
        let before = blank.framebuffer.rows[2].gen
        blank.feed("\n\n\n")
        XCTAssertNotEqual(blank.framebuffer.rows[2].gen, before)
        XCTAssertFalse(blank.framebuffer.rows[2].moshEquals(Row(width: 10, backgroundColor: 0)),
                       "two blank rows of different origin are not equal for mosh")

        // every new row and every reset takes a fresh number
        let g1 = RowGeneration.next()
        let r = Row(width: 3, backgroundColor: 0)
        XCTAssertGreaterThan(r.gen, g1)
        RowGeneration.reserve(through: r.gen + 1000)
        XCTAssertGreaterThan(RowGeneration.next(), r.gen + 1000)
    }

    func testStructuralAndMoshEquality() {
        let input = "\(CSI)1mfoo\r\nbar\(CSI)2;2H"
        let a = terminal(10, 3, input)
        let b = terminal(10, 3, input)
        // built separately: equal field by field, but no shared rows
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.moshEquals(b), "mosh compares row objects")
        XCTAssertFalse(a.compare(b), "mosh's Complete::compare sees no difference")

        // a copy is equal both ways until it is written to, even with the same text
        var c = a
        XCTAssertTrue(c.moshEquals(a))
        c.feed("a")
        XCTAssertEqual(c.framebuffer.rows[1].cells, a.framebuffer.rows[1].cells)
        c.feed("\(CSI)2;2H")
        XCTAssertEqual(c, a)
        XCTAssertFalse(c.moshEquals(a))

        // fields mosh's operator== ignores: structural equality sees them
        func differsOnlyStructurally(_ change: String, line: UInt = #line) {
            var d = a
            d.feed(change)
            XCTAssertNotEqual(d, a, "==", line: line)
            XCTAssertTrue(d.moshEquals(a), "moshEquals", line: line)
        }
        differsOnlyStructurally("\u{1B}7") // saved cursor
        differsOnlyStructurally("\(CSI)2;3r\(CSI)2;2H") // scrolling region
        differsOnlyStructurally("\(CSI)4h") // insert mode
        differsOnlyStructurally("\(CSI)?1h") // application cursor keys
        differsOnlyStructurally("\(CSI)?7l") // autowrap
        differsOnlyStructurally("\u{1B}H") // tab stop
        differsOnlyStructurally("\u{1B}]1;icon\u{7}") // icon name and title_initialized
        differsOnlyStructurally("\u{1B}[") // parser state
        differsOnlyStructurally("\(CSI)1m") // dispatcher (the pen is already bold)

        // an incomplete UTF-8 character waiting in the parser
        var e = a
        e.act([0xE2, 0x82])
        XCTAssertNotEqual(e, a)
        XCTAssertTrue(e.moshEquals(a))

        // fields mosh's operator== does compare
        func differsForMosh(_ change: String, line: UInt = #line) {
            var d = a
            d.feed(change)
            XCTAssertNotEqual(d, a, "==", line: line)
            XCTAssertFalse(d.moshEquals(a), "moshEquals", line: line)
        }
        differsForMosh("\(CSI)C") // cursor
        differsForMosh("\(CSI)31m") // pen
        differsForMosh("\(CSI)?25l") // cursor visibility
        differsForMosh("\(CSI)?5h") // reverse video
        differsForMosh("\(CSI)?2004h") // bracketed paste
        differsForMosh("\(CSI)?1000h") // mouse reporting
        differsForMosh("\(CSI)?1006h") // mouse encoding
        differsForMosh("\(CSI)?1004h") // focus events
        differsForMosh("\(CSI)?1007h") // alternate scroll
        differsForMosh("\u{1B}]2;title\u{7}") // window title
        differsForMosh("\u{1B}]52;c;eA==\u{7}") // clipboard
        differsForMosh("\u{7}") // bell count
        differsForMosh("x") // a cell
        var f = a
        f.applyEchoAck(1)
        XCTAssertNotEqual(f, a)
        XCTAssertFalse(f.moshEquals(a))
        var g = a
        g.resize(width: 10, height: 4)
        XCTAssertNotEqual(g, a)
        XCTAssertFalse(g.moshEquals(a))
    }

    /// Cell contents are bytes. Canonically equivalent text (which Swift's String == would
    /// call equal) is different contents.
    func testContentsAreComparedAsBytes() {
        let precomposed = terminal(5, 1, "\u{E9}") // é as one code point
        let decomposed = terminal(5, 1, "e\u{301}") // e + combining acute
        XCTAssertTrue("\u{E9}" == "e\u{301}", "Swift strings: canonically equivalent")
        XCTAssertEqual(precomposed.contents(0, 0), [0xC3, 0xA9])
        XCTAssertEqual(decomposed.contents(0, 0), [0x65, 0xCC, 0x81])
        XCTAssertNotEqual(precomposed.cell(0, 0), decomposed.cell(0, 0))
        XCTAssertNotEqual(precomposed, decomposed)
        XCTAssertTrue(precomposed.compare(decomposed))
        XCTAssertNotEqual(Array(precomposed.debugDump().utf8), Array(decomposed.debugDump().utf8))
    }
}
