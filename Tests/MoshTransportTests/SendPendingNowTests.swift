import MoshWire
import XCTest
@testable import MoshTransport

/// `sendPendingNow`, the send half of `quiesce --after-send`: the snapshot taken afterwards holds
/// input the server may already have, and a resume must offer it again under a new state number
/// on the acknowledged base (docs/PLAN.md section 3).
final class SendPendingNowTests: XCTestCase {
    private func keys(_ text: String) -> [UserEvent] {
        Array(text.utf8).map(UserEvent.byte)
    }

    /// Runs `sendPendingNow` at the harness's time and decodes what it made.
    private func sendPendingNow(_ harness: inout Harness) -> [ClientInstruction] {
        let output = harness.core.sendPendingNow(now: harness.now)
        harness.events.append(contentsOf: output.events)
        harness.lastWakeup = output.nextWakeup
        return harness.server.read(output.datagrams)
    }

    func testInputTypedAMomentAgoIsSentWithoutWaitingForTheSendTimers() throws {
        var harness = Harness()
        harness.connectAndSettle()
        // Typed, and no tick: the 8 ms collection delay has not even started.
        XCTAssertTrue(harness.core.type(Array("abc".utf8)))
        let sent = sendPendingNow(&harness)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, 2)
        XCTAssertEqual(sent.first?.newNum, 3)
        XCTAssertEqual(sent.first?.throwawayNum, 2)
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("abc".utf8))])
        XCTAssertEqual(harness.core.retransmissions, 0)

        // The answer is never read: the snapshot still has "abc" pending on base 2.
        harness.core.quiesce()
        XCTAssertEqual(harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2, diff: hostBytes("abc")), [.ignored])
        let snapshot = try harness.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 2)
        XCTAssertEqual(snapshot.pendingInput, keys("abc"))

        // The resume offers the same input as a new state above everything sent before, on the
        // base the server certainly holds. A server that has state 3 finds nothing new in it.
        let limits = harness.gate.reservedLimits
        var resumed = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: limits), currentSize: TerminalSize(width: 80, height: 24))
        let first = resumed.tick()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.oldNum, 2)
        XCTAssertEqual(first.first?.throwawayNum, 2)
        XCTAssertEqual(first.first?.newNum, limits.state)
        XCTAssertGreaterThan(limits.state, 3)
        XCTAssertEqual(first.first?.input, [.keystroke(Array("abc".utf8))])
        XCTAssertGreaterThanOrEqual(first.first?.sequences.first ?? 0, limits.sequence)
    }

    /// A state that was sent a moment ago counts as "assumed received": a normal tick would send
    /// nothing. `sendPendingNow` repeats it in full, from the acknowledged state.
    func testAStateAlreadySentIsRepeatedFromTheAcknowledgedState() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("abc")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 3)
        harness.now += 1
        XCTAssertTrue(harness.tick().isEmpty, "the sender waits for the ack")

        let sent = sendPendingNow(&harness)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, 2)
        XCTAssertEqual(sent.first?.newNum, 3, "the same state: its content has not changed")
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("abc".utf8))])
        XCTAssertEqual(harness.core.retransmissions, 1)
        XCTAssertEqual(harness.core.sentStateNumbers, [2, 3])
    }

    func testSentAndUnsentInputGoOutTogetherUnderANewNumber() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("abc")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 3)
        harness.now += 1
        XCTAssertTrue(harness.core.type(Array("de".utf8)))
        let sent = sendPendingNow(&harness)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, 2)
        XCTAssertEqual(sent.first?.newNum, 4)
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("abcde".utf8))])
        XCTAssertEqual(harness.core.retransmissions, 0)
    }

    func testNothingIsSentWhenEverythingIsAcknowledged() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertTrue(sendPendingNow(&harness).isEmpty)
        XCTAssertEqual(harness.core.sentStateNumbers, [2])
    }

    func testNothingIsSentWhileQuiescedOrAfterAShutdownBegan() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertTrue(harness.core.type(Array("abc".utf8)))
        harness.core.quiesce()
        XCTAssertTrue(sendPendingNow(&harness).isEmpty)
        XCTAssertNil(harness.lastWakeup)

        var ending = Harness()
        ending.connectAndSettle()
        XCTAssertTrue(ending.core.type(Array("abc".utf8)))
        ending.core.startShutdown(now: ending.now)
        XCTAssertTrue(sendPendingNow(&ending).isEmpty, "the shutdown request is the tick's business")
    }

    /// The counter the soak prints: a state sent again because no ack came.
    func testRetransmissionsAreCounted() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("abc")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 3)
        XCTAssertEqual(harness.core.retransmissions, 0)
        // No ack: the state is repeated at the retransmission timeout.
        let again = harness.advanceToWakeup()
        XCTAssertEqual(again.first?.newNum, 3)
        XCTAssertEqual(again.first?.oldNum, 2)
        XCTAssertEqual(harness.core.retransmissions, 1)
    }
}
