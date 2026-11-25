// The overlay types of the prediction engine (Prediction.swift): validity and apply of a
// cell and of a cursor move, every branch in mosh's order (toc:43-157), the two resets
// (toh:77, 115-124), and the copy-on-write write helper they use. No oracle: runs on the
// Mac too.

import XCTest
@testable import MoshTerminal

final class PredictionOverlayTests: XCTestCase {
    private func cell(_ text: String, col: Int = 1, exp: UInt64 = 5, epoch: UInt64 = 1) -> ConditionalOverlayCell {
        var c = ConditionalOverlayCell(expirationFrame: exp, col: col, tentativeUntilEpoch: epoch)
        c.active = true
        c.replacement.contents = Array(text.utf8)
        return c
    }

    private func screen(_ input: String, _ width: Int = 4, _ height: Int = 2) -> Framebuffer {
        return terminal(width, height, input).framebuffer
    }

    // MARK: withMutableCell

    func testWithMutableCellCopiesASharedRowAndKeepsItsGeneration() {
        let original = screen("ab")
        var copy = original
        let gen = original.rows[0].gen
        copy.withMutableCell(0, 1) { $0.contents = Array("X".utf8) }
        XCTAssertEqual(original.getCell(0, 1).contents, Array("b".utf8), "the original row is untouched")
        XCTAssertEqual(copy.getCell(0, 1).contents, Array("X".utf8))
        XCTAssertFalse(original.rows[0] === copy.rows[0])
        XCTAssertEqual(copy.rows[0].gen, gen, "mosh's row copy keeps the generation")
        XCTAssertTrue(original.rows[1] === copy.rows[1], "other rows stay shared")
    }

    func testWithMutableCellMinusOneIsTheCursor() {
        var fb = screen("ab")
        fb.withMutableCell(-1, -1) { $0.contents = Array("Z".utf8) }
        XCTAssertEqual(fb.getCell(0, 2).contents, Array("Z".utf8))
    }

    // MARK: Cell validity (toc:74-114)

    func testCellValidityBranchesInOrder() {
        let fb = screen("ab")
        var c = cell("b")
        c.active = false
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 9), .inactive)

        c = cell("b")
        XCTAssertEqual(c.validity(fb, row: 2, lateAck: 0), .incorrectOrExpired, "row out of range before the ack test")
        c.col = 4
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 0), .incorrectOrExpired, "col out of range")

        c = cell("b")
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 4), .pending)

        c.unknown = true
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correctNoCredit, "unknown, even though it would match")

        c = cell(" ", col: 3)
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correctNoCredit, "a blank guess")
        c.replacement.contents = [0xC2, 0xA0]
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correctNoCredit, "no-break space is blank")

        c = cell("b")
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correct)
        c.originalContents = [Cell(backgroundColor: 0), Cell(contents: Array("b".utf8), renditions: Renditions(background: 3),
                                                              wide: true, fallback: false, wrap: false)]
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correctNoCredit, "matches an original (contents only)")

        c = cell("q")
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .incorrectOrExpired)

        // contents_match: blank on blank matches even when the bytes differ (not reached
        // for a blank guess, which is CorrectNoCredit first), and renditions do not count.
        c = cell("a", col: 0)
        c.replacement.renditions.setAttribute(.bold, true)
        XCTAssertEqual(c.validity(fb, row: 0, lateAck: 5), .correct)
    }

    // MARK: Cell apply (toc:43-72)

    func testCellApplySkipsInactiveOutOfRangeAndTentative() {
        let fb = screen("ab")
        var c = cell("Q")
        c.active = false
        var f = fb
        c.apply(&f, confirmedEpoch: 9, row: 0, flag: true)
        XCTAssertEqual(f, fb)
        c = cell("Q")
        c.apply(&f, confirmedEpoch: 9, row: 2, flag: true)
        XCTAssertEqual(f, fb)
        c = cell("Q", epoch: 3)
        c.apply(&f, confirmedEpoch: 2, row: 0, flag: true)
        XCTAssertEqual(f, fb, "tentative: not drawn")
        XCTAssertTrue(f.rows[0] === fb.rows[0], "nothing written, row still shared")
    }

    func testCellApplyWritesAndUnderlines() {
        let fb = screen("ab")
        var f = fb
        cell("Q", epoch: 2).apply(&f, confirmedEpoch: 2, row: 0, flag: false)
        XCTAssertEqual(f.getCell(0, 1).contents, Array("Q".utf8))
        XCTAssertFalse(f.getCell(0, 1).renditions.getAttribute(.underlined))
        XCTAssertEqual(fb.getCell(0, 1).contents, Array("b".utf8))

        f = fb
        cell("Q").apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f.getCell(0, 1).contents, Array("Q".utf8))
        XCTAssertTrue(f.getCell(0, 1).renditions.getAttribute(.underlined))
    }

    func testCellApplyEqualCellIsNotUnderlined() {
        let fb = screen("ab")
        var f = fb
        var c = cell("b")
        c.replacement = fb.getCell(0, 1)
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f, fb, "full == : no write, so no underline")
        XCTAssertTrue(f.rows[0] === fb.rows[0])
    }

    func testCellApplyBlankOnBlankClearsFlag() {
        let fb = screen("ab")
        var f = fb
        var c = cell("", col: 3)
        c.replacement.renditions = Renditions(background: 2)
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f.getCell(0, 3).renditions.backgroundColor, Renditions(background: 2).backgroundColor, "written")
        XCTAssertFalse(f.getCell(0, 3).renditions.getAttribute(.underlined), "blank on blank: flag off")
    }

    func testCellApplyUnknownUnderlinesWithoutWritingExceptInTheLastColumn() {
        let fb = screen("abcd")
        var f = fb
        var c = cell("Q", col: 1)
        c.unknown = true
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f.getCell(0, 1).contents, Array("b".utf8), "unknown writes no contents")
        XCTAssertTrue(f.getCell(0, 1).renditions.getAttribute(.underlined))

        f = fb
        c.col = 3
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f, fb, "last column: not underlined")

        f = fb
        c.col = 1
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: false)
        XCTAssertEqual(f, fb, "no flag: nothing")
    }

    // MARK: Cell resets (toh:77, 115-124)

    func testResetKeepsReplacementAndCol() {
        var c = cell("Q", col: 2)
        c.unknown = true
        c.originalContents = [Cell(backgroundColor: 0)]
        c.predictionTime = 77
        c.reset()
        XCTAssertFalse(c.active)
        XCTAssertFalse(c.unknown)
        XCTAssertEqual(c.originalContents, [])
        XCTAssertEqual(c.expirationFrame, .max)
        XCTAssertEqual(c.tentativeUntilEpoch, .max)
        XCTAssertEqual(c.replacement.contents, Array("Q".utf8), "quirk 5: replacement stays")
        XCTAssertEqual(c.col, 2)
        XCTAssertEqual(c.predictionTime, 77)
    }

    func testResetWithOrig() {
        var c = cell("Q")
        c.originalContents = [Cell(backgroundColor: 1)]
        c.resetWithOrig()
        XCTAssertFalse(c.active)
        XCTAssertEqual(c.originalContents.count, 2)
        XCTAssertEqual(c.originalContents.last?.contents, Array("Q".utf8))
        XCTAssertEqual(c.expirationFrame, .max)

        var u = cell("Q")
        u.unknown = true
        u.originalContents = [Cell(backgroundColor: 1)]
        u.resetWithOrig()
        XCTAssertEqual(u.originalContents, [], "unknown: plain reset")
        XCTAssertFalse(u.unknown)

        var i = cell("Q")
        i.active = false
        i.originalContents = [Cell(backgroundColor: 1)]
        i.resetWithOrig()
        XCTAssertEqual(i.originalContents, [], "inactive: plain reset")
    }

    func testInitialValues() {
        let c = ConditionalOverlayCell(expirationFrame: 3, col: 4, tentativeUntilEpoch: 5)
        XCTAssertFalse(c.active)
        XCTAssertEqual(c.predictionTime, .max)
        XCTAssertEqual(c.replacement, Cell(backgroundColor: 0))
        XCTAssertFalse(c.unknown)
        let m = ConditionalCursorMove(expirationFrame: 3, row: 1, col: 4, tentativeUntilEpoch: 5)
        XCTAssertFalse(m.active)
        XCTAssertEqual(m.predictionTime, .max)
        XCTAssertTrue(m.tentative(4))
        XCTAssertFalse(m.tentative(5))
    }

    func testExpire() {
        var c = cell("Q")
        c.expire(9, now: 123)
        XCTAssertEqual(c.expirationFrame, 9)
        XCTAssertEqual(c.predictionTime, 123)
        var m = ConditionalCursorMove(expirationFrame: 3, row: 1, col: 4, tentativeUntilEpoch: 5)
        m.expire(8, now: 7)
        XCTAssertEqual(m.expirationFrame, 8)
        XCTAssertEqual(m.predictionTime, 7)
        m.reset()
        XCTAssertEqual(m.expirationFrame, .max)
        XCTAssertEqual(m.tentativeUntilEpoch, .max)
        XCTAssertEqual(m.predictionTime, 7)
        XCTAssertFalse(m.active)
    }

    // MARK: Cursor move (toc:116-157)

    private func move(row: Int, col: Int, exp: UInt64 = 5, epoch: UInt64 = 1) -> ConditionalCursorMove {
        var m = ConditionalCursorMove(expirationFrame: exp, row: row, col: col, tentativeUntilEpoch: epoch)
        m.active = true
        return m
    }

    func testCursorValidity() {
        let fb = screen("ab")   // cursor (0,2)
        var m = move(row: 0, col: 2)
        m.active = false
        XCTAssertEqual(m.validity(fb, lateAck: 9), .inactive)
        XCTAssertEqual(move(row: 2, col: 0).validity(fb, lateAck: 0), .incorrectOrExpired)
        XCTAssertEqual(move(row: 0, col: 4).validity(fb, lateAck: 0), .incorrectOrExpired)
        XCTAssertEqual(move(row: 0, col: 2).validity(fb, lateAck: 4), .pending)
        XCTAssertEqual(move(row: 0, col: 2).validity(fb, lateAck: 5), .correct)
        XCTAssertEqual(move(row: 0, col: 3).validity(fb, lateAck: 5), .incorrectOrExpired)
        XCTAssertEqual(move(row: 1, col: 2).validity(fb, lateAck: 5), .incorrectOrExpired)
    }

    func testCursorApply() {
        let fb = screen("ab")
        var f = fb
        var m = move(row: 1, col: 3)
        m.active = false
        m.apply(&f, confirmedEpoch: 1)
        XCTAssertEqual(f, fb)
        move(row: 1, col: 3, epoch: 2).apply(&f, confirmedEpoch: 1)
        XCTAssertEqual(f, fb, "tentative")
        move(row: 1, col: 3).apply(&f, confirmedEpoch: 1)
        XCTAssertEqual(f.ds.cursorRow, 1)
        XCTAssertEqual(f.ds.cursorCol, 3)
        XCTAssertEqual(f.rows.map { $0.cells }, fb.rows.map { $0.cells })
    }

    /// D2: a server in origin mode does not trap the port, in this debug build too; the
    /// cursor moves as mosh's move_row/move_col move it after the assert.
    func testCursorApplyInOriginModeDoesNotTrap() {
        var f = terminal(6, 5, "\u{1b}[2;4r\u{1b}[?6h").framebuffer
        XCTAssertTrue(f.ds.originMode)
        move(row: 1, col: 2).apply(&f, confirmedEpoch: 1)
        var expected = f.ds
        expected.moveRow(1, relative: false)
        expected.moveCol(2, relative: false, implicit: false)
        XCTAssertEqual(f.ds, expected)
        XCTAssertEqual(f.ds.cursorRow, 2, "row 1 of the region that starts at row 1")
    }

    /// D3 in release semantics: an out-of-range cursor guess is not applied.
    func testCursorApplyOutOfRangeReleaseSkips() {
        PredictionBounds.trapsOnFailure = false
        defer { PredictionBounds.trapsOnFailure = true }
        let fb = screen("ab")
        var f = fb
        move(row: 2, col: 0).apply(&f, confirmedEpoch: 1)
        XCTAssertEqual(f, fb)
        move(row: 0, col: -1).apply(&f, confirmedEpoch: 1)
        XCTAssertEqual(f, fb)
        var c = cell("Q", col: -1)
        c.apply(&f, confirmedEpoch: 1, row: 0, flag: true)
        XCTAssertEqual(f, fb)
        c.col = 1
        XCTAssertEqual(c.validity(fb, row: -1, lateAck: 9), .incorrectOrExpired)
    }

    func testRowApplyInColumnOrder() {
        let fb = screen("ab")
        var f = fb
        var row = ConditionalOverlayRow(rowNum: 1)
        row.cells = [cell("x", col: 0), cell("y", col: 1)]
        row.apply(&f, confirmedEpoch: 1, flag: false)
        XCTAssertEqual(f.getCell(1, 0).contents, Array("x".utf8))
        XCTAssertEqual(f.getCell(1, 1).contents, Array("y".utf8))
        XCTAssertTrue(f.rows[0] === fb.rows[0], "row 0 untouched and still shared")
    }
}
