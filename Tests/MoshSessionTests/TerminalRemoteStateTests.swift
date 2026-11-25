import MoshTerminal
import MoshTestSupport
import MoshTransport
import MoshWire
import XCTest
@testable import MoshSession

/// The adapter from the transport's remote state to the terminal: `Complete::apply_string`.
final class TerminalRemoteStateTests: XCTestCase {
    private func rows(_ state: TerminalRemoteState) -> [String] {
        visibleText(of: state.framebuffer)
    }

    private func diff(_ instructions: [HostInstruction]) -> [UInt8] {
        HostMessage(instructions: instructions).serialized()
    }

    func testStateZeroIsABlankTerminalOfTheServersSize() {
        let plain = TerminalRemoteState()
        XCTAssertEqual(plain.size, TerminalSize(width: 80, height: 24))
        XCTAssertEqual(plain.terminal, TerminalState(width: 80, height: 24))
        XCTAssertEqual(plain.echoAck, 0)
        let sized = TerminalRemoteState(serverStartSize: TerminalSize(width: 100, height: 30))
        XCTAssertEqual(sized.terminal, TerminalState(width: 100, height: 30))
    }

    func testHostBytesAreActedOn() throws {
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 10, height: 3))
        try state.apply(diff: diff([.hostBytes(Array("hi\r\nthere".utf8))]))
        XCTAssertEqual(rows(state), ["hi", "there", ""])
        XCTAssertEqual(state.framebuffer.ds.cursorRow, 1)
        XCTAssertEqual(state.framebuffer.ds.cursorCol, 5)
    }

    func testAnEscapeSequenceMaySpanTwoDiffs() throws {
        // The parser is part of the state (mosh's Complete holds it), so a sequence cut between
        // two instructions continues in the next state.
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 10, height: 3))
        try state.apply(diff: diff([.hostBytes([0x1B, 0x5B])]))
        try state.apply(diff: diff([.hostBytes(Array("2;3Hx".utf8))]))
        XCTAssertEqual(rows(state), ["", "  x", ""])
    }

    func testResizeChangesTheSize() throws {
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 80, height: 24))
        try state.apply(diff: diff([.resize(width: 100, height: 30), .hostBytes(Array("ok".utf8))]))
        XCTAssertEqual(state.size, TerminalSize(width: 100, height: 30))
        XCTAssertEqual(rows(state).first, "ok")
        var expected = TerminalState(width: 80, height: 24)
        expected.resize(width: 100, height: 30)
        expected.act(Array("ok".utf8))
        XCTAssertEqual(state.terminal, expected)
    }

    func testANonPositiveResizeIsIgnored() throws {
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 10, height: 3))
        try state.apply(diff: diff([.resize(width: 0, height: 5), .resize(width: -3, height: 2)]))
        XCTAssertEqual(state.size, TerminalSize(width: 10, height: 3))
    }

    func testEchoAckIsRecorded() throws {
        var state = TerminalRemoteState()
        try state.apply(diff: diff([.echoAck(7)]))
        XCTAssertEqual(state.echoAck, 7)
        try state.apply(diff: diff([.echoAck(9), .hostBytes(Array("x".utf8))]))
        XCTAssertEqual(state.echoAck, 9)
        XCTAssertEqual(state.echoAckRegressions, 0)
        // mosh asserts; the port follows the server and counts it.
        try state.apply(diff: diff([.echoAck(3)]))
        XCTAssertEqual(state.echoAck, 3)
        XCTAssertEqual(state.echoAckRegressions, 1)
    }

    func testInstructionsAreAppliedInOrder() throws {
        // A server writes echo ack, resize, host bytes; apply_string takes any order.
        var a = TerminalRemoteState(serverStartSize: TerminalSize(width: 4, height: 2))
        try a.apply(diff: diff([.hostBytes(Array("abcdefgh".utf8)), .resize(width: 2, height: 2)]))
        var b = TerminalRemoteState(serverStartSize: TerminalSize(width: 4, height: 2))
        try b.apply(diff: diff([.resize(width: 2, height: 2), .hostBytes(Array("abcdefgh".utf8))]))
        XCTAssertEqual(rows(a), ["ab", "ef"], "printed at 4 columns, then cut to 2")
        XCTAssertEqual(rows(b), ["ef", "gh"], "printed at 2 columns, scrolled")
        XCTAssertEqual(a.size, TerminalSize(width: 2, height: 2))
        XCTAssertEqual(b.size, TerminalSize(width: 2, height: 2))
    }

    func testAnInstructionWithHostBytesAndResizeIsHostBytesOnly() throws {
        // completeterminal.cc:110-116: `if hostbytes ... else if resize ... else if echoack`.
        // Field 1 of HostMessage, holding extension 2 (hostbytes) and 3 (resize) at once.
        var inner = ProtoWriter()
        var hostBytes = ProtoWriter()
        hostBytes.appendBytesField(4, Array("A".utf8))
        inner.appendBytesField(2, hostBytes.bytes)
        var resize = ProtoWriter()
        resize.appendVarintField(5, 20)
        resize.appendVarintField(6, 5)
        inner.appendBytesField(3, resize.bytes)
        var message = ProtoWriter()
        message.appendBytesField(1, inner.bytes)
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 10, height: 3))
        try state.apply(diff: message.bytes)
        XCTAssertEqual(state.size, TerminalSize(width: 10, height: 3))
        XCTAssertEqual(rows(state).first, "A")
    }

    func testAnInstructionWithNothingKnownDoesNothing() throws {
        var unknown = ProtoWriter()
        unknown.appendVarintField(9, 1)
        var message = ProtoWriter()
        message.appendBytesField(1, unknown.bytes)
        var state = TerminalRemoteState()
        try state.apply(diff: message.bytes)
        XCTAssertEqual(state, TerminalRemoteState())
    }

    func testAMalformedDiffThrowsAndChangesNothing() {
        var state = TerminalRemoteState()
        // A length-delimited field claiming 100 bytes, followed by 2.
        XCTAssertThrowsError(try state.apply(diff: [0x0A, 0x64, 0x12, 0x00]))
        XCTAssertEqual(state, TerminalRemoteState())
    }

    func testARepliedQueryIsDiscarded() throws {
        // Device status report: the emulator answers it; a client drops the answer (mosh
        // asserts there is none; a correct server never writes a query).
        var state = TerminalRemoteState()
        try state.apply(diff: diff([.hostBytes(Array("\u{1B}[6n".utf8))]))
        XCTAssertGreaterThan(state.discardedReplyBytes, 0)
    }

    func testCopiesDoNotShareChanges() throws {
        let base = TerminalRemoteState(serverStartSize: TerminalSize(width: 10, height: 3))
        var next = base
        try next.apply(diff: diff([.hostBytes(Array("changed".utf8))]))
        XCTAssertEqual(rows(base), ["", "", ""])
        XCTAssertEqual(rows(next).first, "changed")
    }

    // MARK: The corpus: mosh's own client as the oracle

    /// Every instruction of the golden corpus, applied the way the transport does it (copy
    /// state `old_num`, `apply(diff:)` with the recorded serialized HostMessage, store as
    /// `new_num`), gives the state mosh 1.4.0's client printed (`Tools/mosh-oracle apply`):
    /// size, cursor, every cell's UTF-8 contents, echo ack and clipboard. And it is the same
    /// value as `TerminalState` driven by the decoded ops, which the MoshTerminal corpus tests
    /// compare with the oracle field by field.
    func testTheCorpusThroughTheAdapterEqualsTheOracle() throws {
        let cases = try GoldenCorpus.loadAll()
        XCTAssertGreaterThanOrEqual(cases.count, 38)
        var instructionsChecked = 0
        var cellsChecked = 0
        for c in cases {
            let start = TerminalRemoteState(serverStartSize: TerminalSize(width: c.width, height: c.height))
            var states: [UInt64: TerminalRemoteState] = [0: start]
            var byOps: [UInt64: TerminalState] = [0: TerminalState(width: c.width, height: c.height)]
            for (i, instruction) in c.instructions.enumerated() {
                let what = "\(c.name) instruction \(i + 1) (\(instruction.oldNum) -> \(instruction.newNum))"
                guard var state = states[instruction.oldNum], var reference = byOps[instruction.oldNum] else {
                    XCTFail("\(what): base state missing"); return
                }
                if !instruction.diff.isEmpty {   // the transport never applies an empty diff
                    try state.apply(diff: instruction.diff)
                }
                for op in instruction.ops {
                    switch op {
                    case .hostBytes(let bytes): reference.act(bytes)
                    case .resize(let w, let h): reference.resize(width: w, height: h)
                    case .echoAck(let n): reference.applyEchoAck(n)
                    }
                }
                states[instruction.newNum] = state
                byOps[instruction.newNum] = reference
                guard state.terminal == reference else {
                    XCTFail("\(what): adapter differs from TerminalState driven by the ops"); return
                }

                let expected = c.expected[i]
                let fb = state.framebuffer
                guard fb.ds.width == expected.width, fb.ds.height == expected.height else {
                    XCTFail("\(what): size \(fb.ds.width)x\(fb.ds.height), oracle \(expected.width)x\(expected.height)")
                    return
                }
                XCTAssertEqual(fb.ds.cursorRow, expected.cursorRow, what)
                XCTAssertEqual(fb.ds.cursorCol, expected.cursorCol, what)
                switch expected[.echoAck] {
                case .uint(let n): XCTAssertEqual(state.echoAck, n, what)
                case .int(let n): XCTAssertEqual(state.echoAck, UInt64(n), what)
                default: XCTFail("\(what): echo_ack has no number")
                }
                if case .text(let clip) = expected[.clipboard] {
                    XCTAssertEqual(fb.clipboard, clip, what)
                }
                for y in 0..<fb.ds.height {
                    for x in 0..<fb.ds.width {
                        let mine = fb.rows[y].cells[x]
                        let theirs = expected.rows[y][x]
                        if mine.contents != theirs.contents || mine.wide != theirs.wide {
                            XCTFail("\(what): row \(y) column \(x): \(mine.contents) wide \(mine.wide), oracle \(theirs.contents) wide \(theirs.wide)")
                            return
                        }
                        cellsChecked += 1
                    }
                }
                instructionsChecked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(instructionsChecked, 2916)
        print("ADAPTER: \(cases.count) cases, \(instructionsChecked) instructions, \(cellsChecked) cells equal to the oracle")
    }
}
