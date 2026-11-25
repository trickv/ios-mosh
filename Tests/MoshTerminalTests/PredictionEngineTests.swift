// PredictionEngine without the oracle (runs on the Mac too): the thresholds of cull at
// their edges, the glitch timer and its unsigned arithmetic, wait_time, the decision table
// of new_user_byte (spec 6.4), and the release behaviour of the bound checks (D3). The
// differential tests against mosh's own engine come in step 4.

import XCTest
@testable import MoshTerminal

final class PredictionEngineTests: XCTestCase {
    private func screen(_ input: String = "$ ", _ width: Int = 10, _ height: Int = 3) -> Framebuffer {
        return terminal(width, height, input).framebuffer
    }

    /// An engine that has seen one frame of `fb` (the first cull resets for the size).
    private func engine(_ display: PredictionDisplay = .always, _ fb: Framebuffer, sendInterval: UInt32 = 250,
                        now: UInt64 = 10_000) -> PredictionEngine {
        var e = PredictionEngine(settings: PredictionSettings(display: display))
        e.setSendInterval(sendInterval)
        _ = e.overlay(fb, now: now)
        return e
    }

    func testInitialState() {
        let e = PredictionEngine()
        XCTAssertEqual(e.settings, PredictionSettings(display: .adaptive, overwrite: false))
        XCTAssertEqual(e.predictionEpoch, 1)
        XCTAssertEqual(e.confirmedEpoch, 0)
        XCTAssertEqual(e.sendInterval, 250)
        XCTAssertEqual(e.lastByte, 0)
        XCTAssertFalse(e.isActive)
        XCTAssertEqual(e.waitTime(), Int(Int32.max))
        XCTAssertEqual(PredictionSettings.off.display, .never)
    }

    func testFirstCullResetsForTheSize() {
        let e = engine(.adaptive, screen())
        XCTAssertEqual(e.predictionEpoch, 2)
        XCTAssertEqual(e.lastWidth, 10)
        XCTAssertEqual(e.lastHeight, 3)
    }

    func testNeverDoesNothing() {
        let fb = screen()
        var e = PredictionEngine(settings: .off)
        XCTAssertEqual(e.overlay(fb, now: 5), fb)
        e.newUserRead(Array("ab".utf8), lastSent: 3, fb, now: 5)
        XCTAssertEqual(e.predictionEpoch, 1, "no cull, no reset")
        XCTAssertEqual(e.lastByte, 0, "new_user_byte returns first")
        XCTAssertEqual(e.localFrameSent, 3, "set_local_frame_sent happens in stmclient, before")
        XCTAssertFalse(e.isActive)
    }

    // MARK: Hysteresis (toc:456-474)

    func testSrttTriggerEdges() {
        let fb = screen()
        var e = engine(.adaptive, fb, sendInterval: 30)
        XCTAssertFalse(e.srttTrigger, "30 is not > 30")
        e.setSendInterval(31)
        e.cull(fb, now: 1)
        XCTAssertTrue(e.srttTrigger)
        e.setSendInterval(21)
        e.cull(fb, now: 1)
        XCTAssertTrue(e.srttTrigger, "21 is not <= 20")
        e.newUserRead(Array("a".utf8), lastSent: 0, fb, now: 1)   // its preamble's cull sees 21
        e.setSendInterval(20)
        e.cull(fb, now: 1)
        XCTAssertTrue(e.isActive)
        XCTAssertTrue(e.srttTrigger, "stays on while a prediction is active")
        e.reset()
        e.cull(fb, now: 1)
        XCTAssertFalse(e.srttTrigger)
    }

    func testFlaggingEdges() {
        let fb = screen()
        var e = engine(.adaptive, fb, sendInterval: 80)
        XCTAssertFalse(e.flagging)
        e.setSendInterval(81)
        e.cull(fb, now: 1)
        XCTAssertTrue(e.flagging)
        e.setSendInterval(51)
        e.cull(fb, now: 1)
        XCTAssertTrue(e.flagging)
        e.setSendInterval(50)
        e.cull(fb, now: 1)
        XCTAssertFalse(e.flagging)
        e.glitchTrigger = 11
        e.cull(fb, now: 1)
        XCTAssertTrue(e.flagging, "glitch_trigger > 10 underlines too")
        e.glitchTrigger = 10
        e.setSendInterval(50)
        e.cull(fb, now: 1)
        XCTAssertFalse(e.flagging)
    }

    // MARK: Glitch timer (toc:555-584)

    private func pendingGuess(at t: UInt64) -> (PredictionEngine, Framebuffer) {
        let fb = screen()
        var e = engine(.adaptive, fb, sendInterval: 20, now: t)
        e.newUserRead(Array("a".utf8), lastSent: 0, fb, now: t)
        return (e, fb)
    }

    func testGlitchThresholds() {
        var (e, fb) = pendingGuess(at: 1000)
        e.cull(fb, now: 1249)
        XCTAssertEqual(e.glitchTrigger, 0)
        e.cull(fb, now: 1250)
        XCTAssertEqual(e.glitchTrigger, 10)
        e.cull(fb, now: 5999)
        XCTAssertEqual(e.glitchTrigger, 10)
        e.cull(fb, now: 6000)
        XCTAssertEqual(e.glitchTrigger, 20)
        e.cull(fb, now: 6001)
        XCTAssertEqual(e.glitchTrigger, 20, "the 250 rule only raises a trigger below 10")
    }

    func testGlitchRepairSpacingAndWrapBelow150() {
        // A Correct cell judged soon after its prediction takes one off the trigger, at most
        // once per 150 ms.
        func confirm(_ e: inout PredictionEngine, at t: UInt64, sent: UInt64) {
            var server = terminal(10, 3, "$ ")
            let fb = server.framebuffer
            e.newUserRead(Array("x".utf8), lastSent: sent, fb, now: t)
            _ = server.feed("x")
            e.setLocalFrameLateAcked(sent + 1)
            e.cull(server.framebuffer, now: t + 10)
        }
        let fb = screen()
        var e = engine(.adaptive, fb, sendInterval: 20, now: 100)
        e.glitchTrigger = 5
        confirm(&e, at: 100, sent: 0)
        // now - 150 wraps for now = 110 (quirk 17): a huge number, >= 0
        XCTAssertEqual(e.glitchTrigger, 4)
        XCTAssertEqual(e.lastQuickConfirmation, 110)
        XCTAssertEqual(e.confirmedEpoch, e.predictionEpoch)

        e.reset()
        confirm(&e, at: 200, sent: 1)   // 210 - 150 = 60 < 110: no decrement
        XCTAssertEqual(e.glitchTrigger, 4)
        e.reset()
        confirm(&e, at: 250, sent: 2)   // 260 - 150 = 110 >= 110
        XCTAssertEqual(e.glitchTrigger, 3)
        XCTAssertEqual(e.lastQuickConfirmation, 260)
    }

    func testWaitTime() {
        var (e, fb) = pendingGuess(at: 1000)
        XCTAssertTrue(e.isActive)
        XCTAssertEqual(e.waitTime(), 50)
        e.flagging = true
        XCTAssertEqual(e.waitTime(), 50, "flagging alone keeps the timing tests")
        e.glitchTrigger = 10
        XCTAssertEqual(e.waitTime(), Int(Int32.max), "glitch && flagging: no timing test left")
        e.flagging = false
        e.reset()
        e.cull(fb, now: 1000)
        XCTAssertEqual(e.waitTime(), Int(Int32.max), "nothing active")
    }

    // MARK: Decision table (spec 6.4)

    func testPrintablePredictsAndAdvances() {
        let fb = screen()
        var e = engine(.always, fb)
        let epoch = e.predictionEpoch
        e.newUserRead(Array("a".utf8), lastSent: 7, fb, now: 10_000)
        XCTAssertEqual(e.predictionEpoch, epoch)
        XCTAssertEqual(e.cursors.count, 1)
        XCTAssertEqual(e.cursors[0].row, 0)
        XCTAssertEqual(e.cursors[0].col, 3)
        XCTAssertEqual(e.cursors[0].expirationFrame, 8)
        XCTAssertEqual(e.cursors[0].predictionTime, 10_000)
        let row = e.overlays[0]
        XCTAssertEqual(row.cells.count, 10)
        XCTAssertEqual(row.cells[2].replacement.contents, Array("a".utf8))
        XCTAssertEqual(row.cells[2].originalContents, [fb.getCell(0, 2)])
        XCTAssertTrue(row.cells[9].unknown, "the last column of an insert is unknown")
        XCTAssertFalse(row.cells[3].unknown)
        XCTAssertFalse(row.cells[1].active)
    }

    func testLastColumnIsTentativeAndWraps() {
        let fb = screen("123456789")    // cursor (0,9)
        var e = engine(.always, fb)
        let epoch = e.predictionEpoch
        e.newUserRead(Array("a".utf8), lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.predictionEpoch, epoch + 2, "tentative before the insert and again on the wrap")
        XCTAssertEqual(e.cursors.last?.row, 1)
        XCTAssertEqual(e.cursors.last?.col, 0)
        XCTAssertEqual(e.cursors.last?.tentativeUntilEpoch, epoch + 2)
    }

    func testCarriageReturnOnLastRowBlanksIt() {
        let fb = screen("\r\n\r\n$ x")
        var e = engine(.always, fb)
        let epoch = e.predictionEpoch
        e.newUserRead([0x0D], lastSent: 4, fb, now: 9)
        XCTAssertEqual(e.predictionEpoch, epoch + 1)
        XCTAssertEqual(e.cursors.last?.row, 2)
        XCTAssertEqual(e.cursors.last?.col, 0)
        XCTAssertEqual(e.cursors.last?.predictionTime, .max, "no expire (quirk 7)")
        let row = try? XCTUnwrap(e.overlays.first { $0.rowNum == 2 })
        XCTAssertEqual(row?.cells.allSatisfy { $0.active && $0.replacement.contents.isEmpty && $0.expirationFrame == 5 }, true)
    }

    func testUnknownPrintIsTentativeOnly() {
        let fb = screen()
        var e = engine(.always, fb)
        let epoch = e.predictionEpoch
        e.newUserRead(Array("語".utf8), lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.predictionEpoch, epoch + 1)
        XCTAssertEqual(e.cursors.count, 1, "init_cursor ran")
        XCTAssertEqual(e.cursors[0].col, 2, "not moved")
        XCTAssertTrue(e.overlays.isEmpty)
        e.newUserRead([0xCC, 0x81], lastSent: 0, fb, now: 1)   // combining acute
        XCTAssertEqual(e.predictionEpoch, epoch + 2)
    }

    func testSplitUTF8WaitsForTheLastByte() {
        let fb = screen()
        var e = engine(.always, fb)
        e.newUserRead([0xC3], lastSent: 0, fb, now: 1)
        XCTAssertTrue(e.cursors.isEmpty)
        XCTAssertEqual(e.parser.pendingBytes, [0xC3])
        XCTAssertEqual(e.lastByte, 0xC3)
        e.newUserRead([0xA9], lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.overlays.first?.cells[2].replacement.contents, [0xC3, 0xA9])
    }

    func testExecuteEscAndCsi() {
        let fb = screen()
        var e = engine(.always, fb)
        var epoch = e.predictionEpoch
        e.newUserRead([0x09], lastSent: 0, fb, now: 1)
        epoch += 1
        XCTAssertEqual(e.predictionEpoch, epoch, "Tab: tentative")
        e.newUserRead(Array("\u{1b}x".utf8), lastSent: 0, fb, now: 1)
        epoch += 1
        XCTAssertEqual(e.predictionEpoch, epoch, "Esc_Dispatch: tentative")
        e.newUserRead(Array("\u{1b}[A".utf8), lastSent: 0, fb, now: 1)
        epoch += 1
        XCTAssertEqual(e.predictionEpoch, epoch, "CSI A: tentative")
        e.newUserRead(Array("\u{1b}[5C".utf8), lastSent: 2, fb, now: 3)
        XCTAssertEqual(e.predictionEpoch, epoch, "CSI C: never tentative, parameters ignored")
        XCTAssertEqual(e.cursors.last?.col, 3)
        XCTAssertEqual(e.cursors.last?.expirationFrame, 3)
        e.newUserRead(Array("\u{1b}OD".utf8), lastSent: 2, fb, now: 3)
        XCTAssertEqual(e.cursors.last?.col, 2, "ESC O D is rewritten to ESC [ D")
        XCTAssertEqual(e.predictionEpoch, epoch)
    }

    func testRightArrowStopsBeforeTheLastColumnAndLeftAtZero() {
        let fb = screen("12345678")   // cursor col 8 of 10
        var e = engine(.always, fb)
        e.newUserRead(Array("\u{1b}[C\u{1b}[C".utf8), lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.cursors.last?.col, 9)
        let fb2 = screen("\r")
        var f = engine(.always, fb2)
        f.newUserRead(Array("\u{1b}[D".utf8), lastSent: 0, fb2, now: 1)
        XCTAssertEqual(f.cursors.last?.col, 0)
        XCTAssertEqual(f.cursors.last?.predictionTime, .max, "no expire at col 0")
    }

    func testBackspaceAtColumnZeroStillMakesTheRow() {
        let fb = screen("\r")
        var e = engine(.always, fb)
        let epoch = e.predictionEpoch
        e.newUserRead([0x7F], lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.overlays.count, 1, "quirk 22")
        XCTAssertFalse(e.overlays[0].cells.contains { $0.active })
        XCTAssertEqual(e.predictionEpoch, epoch, "never tentative")
    }

    func testBackspaceInsertModeShiftsLeft() {
        let fb = screen("abcd")       // cursor (0,4)
        var e = engine(.always, fb)
        e.newUserRead([0x7F], lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.cursors.last?.col, 3)
        let cells = e.overlays[0].cells
        XCTAssertTrue(cells[3...].allSatisfy { $0.active })
        XCTAssertTrue(cells[3].replacement.contents.isEmpty, "takes the next actual cell (blank)")
        XCTAssertTrue(cells[8].unknown && cells[9].unknown, "i + 2 < W fails for the last two (quirk 4)")
        XCTAssertFalse(cells[7].unknown)
    }

    func testBackspaceOverwriteUsesTheFrameCursorCell() {
        let fb = screen("abcd")
        var e = engine(.always, fb)
        e.setPredictOverwrite(true)
        e.newUserRead(Array("\u{1b}[D".utf8), lastSent: 0, fb, now: 1)   // predicted cursor at col 3
        e.newUserRead([0x7F], lastSent: 0, fb, now: 1)
        let cell = e.overlays[0].cells[2]
        XCTAssertTrue(cell.active)
        XCTAssertEqual(cell.replacement.contents, [0x20])
        XCTAssertEqual(cell.originalContents.last, fb.getCell(0, 4), "fb.get_cell(): the frame's cursor (quirk 3)")
        XCTAssertFalse(e.overlays[0].cells[3].active)
    }

    func testPasteResetsAndPredictsNothing() {
        let fb = screen()
        var e = engine(.always, fb)
        e.newUserRead(Array("a".utf8), lastSent: 0, fb, now: 1)
        let epoch = e.predictionEpoch
        e.newUserRead(Array(repeating: 0x61, count: 101), lastSent: 9, fb, now: 1)
        XCTAssertFalse(e.isActive)
        XCTAssertEqual(e.predictionEpoch, epoch + 1)
        XCTAssertEqual(e.localFrameSent, 9)
        e.newUserRead(Array(repeating: 0x61, count: 100), lastSent: 9, fb, now: 1)
        XCTAssertTrue(e.isActive, "100 bytes are typed, not pasted")
    }

    // MARK: Judging (toc:482-625)

    func testWrongConfirmedGuessResetsEverything() {
        var server = terminal(10, 3, "$ ")
        var e = engine(.always, server.framebuffer)
        e.confirmedEpoch = e.predictionEpoch
        e.newUserRead(Array("ab".utf8), lastSent: 0, server.framebuffer, now: 1)
        _ = server.feed("x")
        e.setLocalFrameLateAcked(1)
        let epoch = e.predictionEpoch
        e.cull(server.framebuffer, now: 2)
        XCTAssertTrue(e.overlays.isEmpty)
        XCTAssertTrue(e.cursors.isEmpty)
        XCTAssertEqual(e.predictionEpoch, epoch + 1)
    }

    func testWrongTentativeGuessKillsItsEpoch() {
        var server = terminal(10, 3, "$ ")
        var e = engine(.always, server.framebuffer)
        let epoch = e.predictionEpoch
        e.newUserRead(Array("ab".utf8), lastSent: 0, server.framebuffer, now: 1)
        _ = server.feed("x")
        e.setLocalFrameLateAcked(1)
        e.cull(server.framebuffer, now: 2)
        XCTAssertEqual(e.predictionEpoch, epoch + 1)
        XCTAssertFalse(e.overlays.contains { $0.cells.contains { $0.active } })
        XCTAssertEqual(e.confirmedEpoch, 0)
    }

    func testExperimentalResetsSingleCells() {
        var server = terminal(10, 3, "$ ")
        var e = engine(.experimental, server.framebuffer)
        XCTAssertEqual(e.predictionEpoch, 1, "experimental: become_tentative does nothing")
        e.newUserRead(Array("ab".utf8), lastSent: 0, server.framebuffer, now: 1)
        XCTAssertEqual(e.predictionEpoch, 0, "prediction_epoch = confirmed_epoch per byte")
        _ = server.feed("x")
        e.setLocalFrameLateAcked(1)
        e.cull(server.framebuffer, now: 2)
        XCTAssertFalse(e.overlays[0].cells[2].active)
        XCTAssertEqual(e.overlays.count, 1, "no full reset")
    }

    func testApplyNeedsATrigger() {
        let fb = screen()
        var e = engine(.adaptive, fb, sendInterval: 20)
        e.confirmedEpoch = e.predictionEpoch
        e.newUserRead(Array("a".utf8), lastSent: 0, fb, now: 1)
        XCTAssertEqual(e.overlay(fb, now: 1), fb, "adaptive with no trigger draws nothing")
        e.setSendInterval(31)
        let shown = e.overlay(fb, now: 1)
        XCTAssertEqual(shown.getCell(0, 2).contents, Array("a".utf8))
        XCTAssertEqual(shown.ds.cursorCol, 3)
        XCTAssertEqual(fb.getCell(0, 2).contents, [], "the remote frame is untouched")
    }

    // MARK: D3

    /// Why the printable branch's bound asserts (toc:751-754) cannot fire: the preamble's
    /// cull judges an out-of-range last cursor IncorrectOrExpired (toc:126-130) and resets
    /// (toc:596-613) before init_cursor makes a fresh one from the frame.
    func testOutOfRangeCursorIsResetByThePreamblesCull() {
        let fb = screen()
        var e = engine(.always, fb)
        var c = ConditionalCursorMove(expirationFrame: 9, row: 5, col: 0, tentativeUntilEpoch: e.predictionEpoch)
        c.active = true
        e.cursors = [c]
        let epoch = e.predictionEpoch
        e.newUserByte(UInt8(ascii: "a"), fb, now: 1)
        XCTAssertEqual(e.predictionEpoch, epoch + 1, "reset")
        XCTAssertEqual(e.cursors.count, 1)
        XCTAssertEqual(e.cursors[0].row, 0)
        XCTAssertEqual(e.cursors[0].col, 3)
        XCTAssertEqual(e.overlays.first?.cells[2].replacement.contents, Array("a".utf8))
    }
}
