import MoshTestSupport
import MoshWire
import XCTest
@testable import MoshTransport

/// What the diffs contain: `UserStream::diff_from` and the sender's choice of base state.
final class DiffContentTests: XCTestCase {
    func testFirstStateIsTheResize() {
        var harness = Harness(size: TerminalSize(width: 80, height: 24))
        let sent = harness.tick()
        // docs/PLAN.md appendix: resize 80x24.
        XCTAssertEqual(sent.first?.diff, [0x0A, 0x06, 0x1A, 0x04, 0x28, 0x50, 0x30, 0x18])
    }

    func testAKeystrokeHasTheExactBytes() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("a")
        let sent = harness.advanceToWakeup()
        // docs/PLAN.md appendix: keystroke "a".
        XCTAssertEqual(sent.first?.diff, [0x0A, 0x05, 0x12, 0x03, 0x22, 0x01, 0x61])
    }

    func testKeysAndResizesKeepTheirOrder() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.type(Array("ab".utf8))
        harness.core.resize(TerminalSize(width: 100, height: 30))
        harness.core.type(Array("c".utf8))
        harness.core.type([0x1B, 0x5B, 0x41]) // up arrow
        harness.tick()
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.first?.diff, [
            0x0A, 0x06, 0x12, 0x04, 0x22, 0x02, 0x61, 0x62, // keystroke "ab"
            0x0A, 0x06, 0x1A, 0x04, 0x28, 0x64, 0x30, 0x1E, // resize 100x30
            0x0A, 0x08, 0x12, 0x06, 0x22, 0x04, 0x63, 0x1B, 0x5B, 0x41, // keystroke "c" ESC [ A
        ])
        XCTAssertEqual(harness.core.terminalSize, TerminalSize(width: 100, height: 30))
    }

    func testAfterAnAckTheNextDiffStartsAtTheAcknowledgedState() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("a")
        let first = harness.advanceToWakeup()
        XCTAssertEqual(first.first?.oldNum, 2)
        XCTAssertEqual(first.first?.newNum, 3)

        // The server acknowledges state 3.
        harness.now += 5
        harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2)
        harness.type("b")
        let second = harness.advanceToWakeup()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.oldNum, 3)
        XCTAssertEqual(second.first?.newNum, 4)
        XCTAssertEqual(second.first?.throwawayNum, 3, "the server may forget everything before state 3")
        XCTAssertEqual(second.first?.ackNum, 3)
        XCTAssertEqual(second.first?.input, [.keystroke(Array("b".utf8))], "only what the server has not seen")
    }

    func testWithoutAnAckASmallDiffIsResentFromTheAcknowledgedState() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("a")
        harness.advanceToWakeup()
        harness.now += 1
        harness.type("b")
        let second = harness.advanceToWakeup()
        // mosh's "prospective resend": state 3 was sent 20 ms ago and may well have arrived, but
        // "ab" from state 2 is only one byte longer than "b" from state 3, and survives its loss.
        XCTAssertEqual(second.first?.oldNum, 2)
        XCTAssertEqual(second.first?.newNum, 4)
        XCTAssertEqual(second.first?.throwawayNum, 2)
        XCTAssertEqual(second.first?.input, [.keystroke(Array("ab".utf8))])
    }

    func testWithoutAnAckALargeDiffBuildsOnTheAssumedState() {
        var harness = Harness()
        harness.connectAndSettle()
        let paste = String(repeating: "0123456789", count: 20)
        harness.type(paste)
        let first = harness.advanceToWakeup()
        XCTAssertEqual(first.first?.input, [.keystroke(Array(paste.utf8))])

        // Within RTO + ACK_DELAY the receiver is assumed to hold state 3, and resending 200 bytes
        // to save against a loss is not worth it (more than 100 bytes longer).
        harness.now += 1
        harness.type("x")
        let second = harness.advanceToWakeup()
        XCTAssertEqual(second.first?.oldNum, 3)
        XCTAssertEqual(second.first?.newNum, 4)
        XCTAssertEqual(second.first?.throwawayNum, 2)
        XCTAssertEqual(second.first?.input, [.keystroke(Array("x".utf8))])

        // Once the assumption has timed out, everything since the acknowledged state goes again.
        harness.now += 1000
        harness.type("y")
        let third = harness.advanceToWakeup()
        XCTAssertEqual(third.first?.oldNum, 2)
        XCTAssertEqual(third.first?.newNum, 5)
        XCTAssertEqual(third.first?.input, [.keystroke(Array((paste + "xy").utf8))])
    }

    /// mosh: `add_sent_state`. Above 32 states the 16th from the end is erased, so the
    /// acknowledged state, the next 16 and the newest 15 remain.
    func testSentStatesAreCappedAsInMosh() {
        var harness = Harness()
        harness.tick() // state 1, never acknowledged
        for _ in 2...40 {
            harness.type("k")
            let sent = harness.advance(300)
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent.first?.throwawayNum, 0)
        }
        XCTAssertEqual(harness.core.lastSentStateNumber, 40)
        XCTAssertEqual(harness.core.sentStateNumbers.count, 32)
        XCTAssertEqual(harness.core.sentStateNumbers, Array(0...16) + Array(26...40))

        // Exactly at the limit nothing is dropped; one more drops number 17.
        var exact = Harness()
        exact.tick()
        for _ in 2...31 {
            exact.type("k")
            exact.advance(300)
        }
        XCTAssertEqual(exact.core.sentStateNumbers, Array(0...31))
        exact.type("k")
        exact.advance(300)
        XCTAssertEqual(exact.core.sentStateNumbers, Array(0...16) + Array(18...32))

        // An ack for a state that was thinned out is ignored ("Ignore ack if we have culled the
        // state it's acknowledging").
        harness.deliver(old: 0, new: 1, ack: 20, throwaway: 0)
        XCTAssertEqual(harness.core.sentStateNumbers.first, 0)
        XCTAssertEqual(harness.core.sentStateNumbers.count, 32)

        // An ack for a kept state drops everything before it.
        harness.deliver(old: 1, new: 2, ack: 16, throwaway: 0)
        XCTAssertEqual(harness.core.sentStateNumbers, [16] + Array(26...40))
        harness.now += 2000
        harness.type("z")
        let next = harness.advanceToWakeup()
        XCTAssertEqual(next.first?.oldNum, 16)
        XCTAssertEqual(next.first?.throwawayNum, 16)
        XCTAssertEqual(next.first?.newNum, 41)
        // States 17...40 added one "k" each; the server has those up to state 16.
        XCTAssertEqual(next.first?.input, [.keystroke(Array((String(repeating: "k", count: 24) + "z").utf8))])
        XCTAssertFalse(harness.events.contains { if case .internalError = $0 { return true } else { return false } })
    }

    /// Not in mosh: input far ahead of the acknowledged state is sent in bounded states, so that
    /// no diff outgrows the 4 MiB a mosh peer can expand.
    func testInputBeyondTheLimitWaitsForAnAck() {
        var harness = Harness(configuration: Harness.configuration(limit: 10))
        harness.connectAndSettle()
        let text = "abcdefghijklmnopqrstuvwxy" // 25 bytes
        harness.type(text)
        let first = harness.advanceToWakeup()
        XCTAssertEqual(first.first?.newNum, 3)
        XCTAssertEqual(first.first?.input, [.keystroke(Array("abcdefghij".utf8))])

        // Unacknowledged: the same state is repeated; no new state appears.
        let repeated = harness.advanceToWakeup()
        XCTAssertEqual(repeated.first?.newNum, 3)
        XCTAssertEqual(repeated.first?.input, [.keystroke(Array("abcdefghij".utf8))])

        harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2)
        harness.tick()
        let second = harness.advanceToWakeup()
        XCTAssertEqual(second.first?.oldNum, 3)
        XCTAssertEqual(second.first?.newNum, 4)
        XCTAssertEqual(second.first?.input, [.keystroke(Array("klmnopqrst".utf8))])

        harness.deliver(old: 3, new: 4, ack: 4, throwaway: 3)
        harness.tick()
        let third = harness.advanceToWakeup()
        XCTAssertEqual(third.first?.oldNum, 4)
        XCTAssertEqual(third.first?.input, [.keystroke(Array("uvwxy".utf8))])
        XCTAssertEqual(harness.core.pendingInputCount, 5)
    }

    func testInputLogDiffsAndDiscards() {
        var log = InputLog()
        log.append(bytes: Array("abc".utf8))
        log.append(.resize(TerminalSize(width: 10, height: 5)))
        log.append(bytes: Array("d".utf8))
        XCTAssertEqual(log.end, 5)
        XCTAssertEqual(log.diff(from: 5, to: 5), [], "equal states have an empty diff")
        XCTAssertEqual(log.diff(from: 1, to: 3), UserMessage(instructions: [.keystroke(Array("bc".utf8))]).serialized())
        XCTAssertEqual(log.diff(from: 2, to: 5), UserMessage(instructions: [
            .keystroke(Array("c".utf8)), .resize(width: 10, height: 5), .keystroke(Array("d".utf8)),
        ]).serialized())
        XCTAssertNil(log.diff(from: 3, to: 2))
        XCTAssertNil(log.diff(from: 0, to: 6))

        // subtract(): forget what the receiver has; positions stay the same.
        log.discard(before: 3)
        XCTAssertEqual(log.base, 3)
        XCTAssertEqual(log.end, 5)
        XCTAssertNil(log.diff(from: 2, to: 5))
        XCTAssertEqual(log.diff(from: 4, to: 5), UserMessage(instructions: [.keystroke(Array("d".utf8))]).serialized())
        log.discard(before: 1) // going back does nothing
        XCTAssertEqual(log.base, 3)
        log.discard(before: 99) // nor does going past the end
        XCTAssertEqual(log.base, 5)
        XCTAssertEqual(log.end, 5)
    }

    func testChaffIsInjected() {
        let configuration = TransportConfiguration(makeChaff: { [1, 2, 3] })
        var harness = Harness(configuration: configuration)
        XCTAssertEqual(harness.tick().first?.instruction.chaff, [1, 2, 3])

        // The default is mosh's: 0 to 16 random bytes for every instruction.
        var lengths = Set<Int>()
        var random = Harness(configuration: TransportConfiguration())
        for _ in 0..<60 {
            if let chaff = random.advance(3000).first?.instruction.chaff {
                XCTAssertLessThanOrEqual(chaff.count, 16)
                lengths.insert(chaff.count)
            }
        }
        XCTAssertGreaterThan(lengths.count, 3, "the length varies")
    }

    func testTerminalSizeIsClamped() {
        XCTAssertEqual(TerminalSize(width: 0, height: -3), TerminalSize(width: UInt16(1), height: UInt16(1)))
        XCTAssertEqual(TerminalSize(width: 1_000_000, height: 24).width, 65535)
    }
}
