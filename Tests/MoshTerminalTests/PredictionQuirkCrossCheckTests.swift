// Named cases, each run through mosh's own engine (mosh-oracle predict) and the port with
// a dump after every command: the worked example of spec 5.4 and one case per quirk of
// spec 11 that the engine can show (all but 12, escape-key wiring, and 18, the origin-mode
// assert, deviation D2). The oracle is the expectation; the cases only make each quirk act.

#if os(Linux)
import XCTest
@testable import MoshTerminal

final class PredictionQuirkCrossCheckTests: XCTestCase {
    private typealias C = PredictCommand

    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Interleave a dump after every command and compare.
    private func check(_ commands: [C], file: StaticString = #filePath, line: UInt = #line) throws {
        var script: [C] = []
        for c in commands {
            script.append(c)
            script.append(.dump)
        }
        if let d = try PredictComparison.firstDifference(script) {
            XCTFail(d, file: file, line: line)
        }
    }

    /// A session with a prompt, one confirmed epoch, at time 1000, send interval `si`.
    private func confirmed(_ w: Int = 10, _ h: Int = 3, display: String = "always", si: UInt32 = 250) -> [C] {
        return [.new(w, h), .display(PredictionDisplay(rawValue: display)!), .time(1000), .recv(acked: 0, sendInterval: si),
                .host(b("$ ")), .frame, .read(sent: 1, b("e")), .time(1100), .host(b("e")), .echoAck(2),
                .recv(acked: 2, sendInterval: si), .frame]
    }

    func testWorkedExample() throws {
        try check([.new(80, 24), .display(.adaptive), .time(1000), .recv(acked: 0, sendInterval: 250),
                   .host(b("\u{1b}[6;1H$ ")), .frame, .read(sent: 10, b("l")), .read(sent: 10, b("s")), .frame,
                   .time(1300), .host(b("ls")), .echoAck(11), .recv(acked: 11, sendInterval: 250), .frame,
                   .read(sent: 11, b("-")), .frame, .read(sent: 11, [0x0D]), .read(sent: 12, b("x")),
                   .time(1600), .host(b("-\r\ny")), .echoAck(13), .recv(acked: 13, sendInterval: 250), .frame,
                   .read(sent: 13, b("q")), .host(b("z")), .echoAck(14), .recv(acked: 14, sendInterval: 250), .frame])
    }

    func testQuirk1StaleShownFrameOnKeystroke() throws {
        // A new echo ack arrives, then a key is read before the next frame: the keystroke's
        // cull judges against the shown frame, which holds the guess drawn on itself.
        try check(confirmed() + [.read(sent: 2, b("c")), .frame, .host(b("q")), .echoAck(3),
                                 .recv(acked: 3, sendInterval: 250), .read(sent: 3, b("h")), .frame])
    }

    func testQuirk2OriginalsAndNeighboursFromShownFrame() throws {
        try check(confirmed() + [.read(sent: 2, b("ab")), .frame, .read(sent: 2, [0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x44]),
                                 .read(sent: 2, b("z")), .frame])
    }

    func testQuirk3OverwriteBackspaceUsesFrameCursorCell() throws {
        try check(confirmed() + [.overwrite(true), .read(sent: 2, b("\u{1b}[D")), .read(sent: 2, [0x7F]), .frame])
    }

    func testQuirk4InsertBackspaceTwoUnknownColumns() throws {
        try check(confirmed(6, 2) + [.read(sent: 2, [0x7F]), .frame, .read(sent: 2, [0x7F, 0x7F]), .frame])
        try check(confirmed(2, 2) + [.read(sent: 2, [0x7F]), .frame])
    }

    func testQuirk5StaleReplacementFlags() throws {
        try check(confirmed(6, 2) + [.host(b("\u{1b}[1;31m語\u{1b}[m")), .frame, .read(sent: 2, b("a")),
                                     .reset, .read(sent: 2, b("b")), .frame])
    }

    func testQuirk6BlankLastRow() throws {
        try check(confirmed(4, 2) + [.host(b("\r\n$ ")), .frame, .read(sent: 2, b("ab")), .frame,
                                     .read(sent: 2, [0x0D]), .frame])
    }

    func testQuirk7NewlineDoesNotExpireCursor() throws {
        try check(confirmed(display: "experimental") + [.time(1500), .read(sent: 2, b("a")), .time(1700),
                                                       .read(sent: 3, [0x0D]), .frame])
    }

    func testQuirk8ArrowParametersIgnored() throws {
        try check(confirmed() + [.read(sent: 2, b("\u{1b}[5C\u{1b}[1;5C\u{1b}[?D")), .frame])
    }

    func testQuirk9EscORewrite() throws {
        try check(confirmed() + [.read(sent: 2, b("\u{1b}")), .read(sent: 2, b("OC")), .read(sent: 2, b("\u{1b}Oh")),
                                 .frame])
    }

    func testQuirk10ByteAfterBareEscIsEaten() throws {
        try check(confirmed() + [.read(sent: 2, b("\u{1b}")), .read(sent: 2, b("a")), .read(sent: 2, b("b")), .frame])
    }

    func testQuirk11PasteLeavesParserMidSequence() throws {
        try check(confirmed() + [.read(sent: 2, b("\u{1b}[")), .read(sent: 2, Array(repeating: 0x61, count: 120)),
                                 .read(sent: 2, b("C")), .frame])
    }

    func testQuirk13NeverLeavesParser() throws {
        try check(confirmed() + [.display(.never), .read(sent: 2, b("\u{1b}[")), .display(.always),
                                 .read(sent: 2, b("C")), .frame])
    }

    func testQuirk14OnlyNewestCursorResets() throws {
        try check(confirmed() + [.read(sent: 2, b("\u{1b}[C")), .read(sent: 2, [0x09]), .read(sent: 3, b("\u{1b}[C")),
                                 .host(b("  ")), .echoAck(4), .recv(acked: 4, sendInterval: 250), .frame])
        try check(confirmed() + [.read(sent: 2, [0x09]), .read(sent: 2, b("\u{1b}[C")), .echoAck(3),
                                 .recv(acked: 3, sendInterval: 250), .frame])
    }

    func testQuirk15CursorMovesNeverConfirm() throws {
        try check([.new(10, 3), .display(.always), .time(5), .host(b("$ ")), .frame, .read(sent: 1, b("\u{1b}[C")),
                   .host(b("\u{1b}[C")), .echoAck(2), .recv(acked: 2, sendInterval: 250), .frame])
    }

    func testQuirk16ConfirmationRecoloursRow() throws {
        try check(confirmed() + [.read(sent: 2, b("xyz")), .host(b("\u{1b}[32mx\u{1b}[m")), .echoAck(3),
                                 .recv(acked: 3, sendInterval: 250), .frame])
    }

    func testQuirk17UnsignedArithmeticNearZero() throws {
        try check([.new(10, 3), .display(.adaptive), .time(3), .recv(acked: 0, sendInterval: 20), .host(b("$ ")), .frame,
                   .read(sent: 1, b("a")), .time(300), .frame, .time(310), .host(b("a")), .echoAck(2),
                   .recv(acked: 2, sendInterval: 20), .frame, .read(sent: 2, b("b")), .time(320), .host(b("b")),
                   .echoAck(3), .recv(acked: 3, sendInterval: 20), .frame])
    }

    func testQuirk19BlankGuessesNeverCount() throws {
        try check(confirmed() + [.read(sent: 2, b(" ")), .host(b("Q")), .echoAck(3), .recv(acked: 3, sendInterval: 250),
                                 .frame])
    }

    func testQuirk20WcwidthDecides() throws {
        try check(confirmed() + [.read(sent: 2, b("é語\u{301}\u{A0}ß")), .frame])
    }

    func testQuirk21DelIsAPrintBackspace() throws {
        try check(confirmed() + [.read(sent: 2, b("ab")), .read(sent: 2, [0x7F]), .read(sent: 2, [0x08]), .frame])
    }

    func testQuirk22BackspaceAtColumnZeroMakesRow() throws {
        try check(confirmed() + [.host(b("\r")), .frame, .read(sent: 2, [0x7F]), .frame])
    }

    func testQuirk23EarlyAckUnused() throws {
        try check(confirmed() + [.read(sent: 2, b("ab")), .recv(acked: 9, sendInterval: 250), .frame])
    }

    func testQuirk24KillEpochCursorFromShownFrame() throws {
        try check(confirmed() + [.read(sent: 2, [0x0D]), .read(sent: 3, b("x")), .host(b("\r\ny")), .echoAck(4),
                                 .recv(acked: 4, sendInterval: 250), .read(sent: 4, b("w")), .frame])
    }

    func testQuirk25OneLocalFrameSentPerRead() throws {
        try check(confirmed() + [.read(sent: 7, b("abc")), .read(sent: 8, b("d")), .frame])
    }

    func testGlitchTimerAndUnderline() throws {
        try check(confirmed(si: 20) + [.read(sent: 2, b("ab")), .time(1349), .frame, .time(1350), .frame,
                                        .time(6099), .frame, .time(6100), .frame, .host(b("ab")), .echoAck(3),
                                        .recv(acked: 3, sendInterval: 20), .frame])
    }

    func testResizeResets() throws {
        try check(confirmed() + [.read(sent: 2, b("ab")), .hostResize(8, 2), .reset, .frame, .read(sent: 2, b("c")),
                                 .frame])
    }
}
#endif
