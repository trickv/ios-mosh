import MoshCrypto
import MoshWire
import XCTest
@testable import MoshTransport

/// Scratch tests of review III. Each test asserts the behaviour the plan wants, so a failure
/// confirms the finding.
final class ReviewIIITests: XCTestCase {
    // III-1: a gate that does not start at the old limits.
    func testImportWithAGateBelowTheOldLimitsMustNotSend() throws {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()                     // A = 2, sequences 0 and 1 used
        old.type("abc")
        let sent = old.advanceToWakeup()           // state 3 = "abc", not acknowledged
        XCTAssertEqual(sent.first?.newNum, 3)
        let oldSequences = old.sequences
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 2)

        // State counter above A but not above what was sent; sequence and fragment id from 0/1.
        let wrong = InMemoryGate(startingAt: GateCounters(sequence: 0, state: 3, fragmentID: 1))
        var harness = try Harness(restoring: snapshot, gate: wrong, currentSize: TerminalSize(width: 100, height: 30))
        harness.server = FakeServer()
        let first = harness.tick()
        let reusedSequence = harness.sequences.contains { oldSequences.contains($0) }
        XCTAssertFalse(reusedSequence, "N1: sequence numbers \(harness.sequences) were used before: \(oldSequences)")
        XCTAssertNotEqual(first.first?.newNum, 3, "N2: state 3 goes out again with other content: \(String(describing: first.first?.input)) instead of \(String(describing: sent.first?.input))")
        XCTAssertTrue(harness.core.isHalted || first.isEmpty, "nothing told the owner")
    }

    // III-2: the clean mark can be given to a snapshot that is already stale.
    func testMarkCleanCannotSucceedForAStaleSnapshot() throws {
        let gate = InMemoryGate()
        var harness = Harness(gate: gate)
        harness.connectAndSettle()
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        // Back in the foreground before the writer got its token.
        harness.core.unquiesce(now: harness.now)
        harness.tick()
        harness.type("x")
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("x".utf8))])
        let token = gate.datagramsPassed
        let clean = try gate.markClean(ifDatagramsPassed: token)
        XCTAssertFalse(clean, "dirty = 0 for a snapshot with pending \(snapshot.pendingInput) while the server was sent \"x\"")
    }

    // III-2b: input after the export does not pass the gate, so the clean mark does not see it.
    func testInputAfterExportIsNotCoveredByTheCleanMark() throws {
        let gate = InMemoryGate()
        var harness = Harness(gate: gate)
        harness.connectAndSettle()
        harness.core.quiesce()
        let token = gate.datagramsPassed
        let snapshot = try harness.core.exportState()
        XCTAssertTrue(harness.core.type(Array("lost".utf8)))
        harness.core.startShutdown(now: harness.now)
        let clean = try gate.markClean(ifDatagramsPassed: token)
        XCTAssertFalse(clean && snapshot.pendingInput.isEmpty, "record clean, snapshot without the input and without the shutdown request")
    }

    // III-3: the receiver's expected sequence number is not carried over.
    func testAReplayedServerDatagramAfterImportIsOutOfOrder() throws {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()
        // Three more server datagrams; keep the first of them.
        let kept = old.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 1, diff: hostBytes("x"), timestamp: 100, timestampReply: 4242)
        XCTAssertEqual(old.core.receive(datagram: kept[0], now: old.now), .authentic)
        old.deliver(old: 3, new: 4, ack: 2, throwaway: 1, diff: hostBytes("y"))
        old.deliver(old: 4, new: 5, ack: 2, throwaway: 1, diff: hostBytes("z"))
        XCTAssertEqual(old.core.receive(datagram: kept[0], now: old.now), .authenticOutOfOrder, "in the old process a replay is recognised")
        old.tick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()

        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil, now: old.now + 60_000)
        harness.server = old.server
        harness.tick()
        let srttBefore = harness.core.rtt.srtt
        let result = harness.core.receive(datagram: kept[0], now: harness.now)
        XCTAssertEqual(result, .authenticOutOfOrder, "a datagram numbered below one the old process saw")
        XCTAssertEqual(harness.core.rtt.srtt, srttBefore, "no RTT sample from a replay")
        XCTAssertNil(harness.core.contactTimes.lastAuthenticDatagramAt, "no contact from a replay")
    }

    // III-4: a shutdown asked for while quiesced.
    func testShutdownAskedWhileQuiescedIsSentAfterResume() throws {
        var harness = Harness(gate: InMemoryGate())
        harness.connectAndSettle()
        harness.core.quiesce()
        harness.core.startShutdown(now: harness.now)
        harness.now += 11_000
        harness.core.unquiesce(now: harness.now)
        let sent = harness.tick()
        XCTAssertEqual(sent.first?.newNum, Instruction.shutdownNum, "the server was never told; events: \(harness.events)")
        XCTAssertFalse(harness.core.hasEnded)
    }

    // Control: the export of an import equals the snapshot (no hidden drift).
    func testExportOfAFreshImportIsTheSnapshot() throws {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()
        old.type("abc")
        old.advanceToWakeup()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        harness.core.quiesce()
        XCTAssertEqual(try harness.core.exportState(), snapshot)
    }
}
