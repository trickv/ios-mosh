import Foundation
import MoshCrypto
import MoshWire
import XCTest
@testable import MoshTransport

/// The import and export seams (findings M7, M5 and M8 of
/// docs/notes/review-transport/refutation.md; docs/PLAN.md section 3).
final class SnapshotReviewTests: XCTestCase {
    /// A session with state 3 = "abc" sent and not acknowledged; A = 2.
    private func sessionWithUnacknowledgedInput() throws -> (old: Harness, snapshot: TransportSnapshot<OpaqueRemoteState>, sent: ClientInstruction) {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()
        old.type("abc")
        let sent = old.advanceToWakeup()
        XCTAssertEqual(sent.first?.newNum, 3)
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 2)
        return (old, snapshot, try XCTUnwrap(sent.first))
    }

    // MARK: M7

    func testExportCarriesTheFirstUnusedNumbers() throws {
        var fresh = Harness()
        fresh.core.quiesce()
        XCTAssertEqual(try fresh.core.exportState().usedCounters, GateCounters(sequence: 0, state: 1, fragmentID: 0),
                       "nothing used: state 0 is the base both sides start from")

        let (old, snapshot, sent) = try sessionWithUnacknowledgedInput()
        let lastSequence = try XCTUnwrap(old.sequences.last)
        XCTAssertEqual(snapshot.usedCounters, GateCounters(sequence: lastSequence + 1, state: 4, fragmentID: sent.fragmentID + 1))
        // Used numbers are below the gate's limits, so the gate of a new process passes.
        let limits = old.gate.reservedLimits
        XCTAssertLessThanOrEqual(snapshot.usedCounters.sequence, limits.sequence)
        XCTAssertLessThanOrEqual(snapshot.usedCounters.state, limits.state)
        XCTAssertLessThanOrEqual(snapshot.usedCounters.fragmentID, limits.fragmentID)
    }

    /// A snapshot with A = 0 and a new gate: sequence 0, state 1 and fragment id 1 would go out a
    /// second time with other content.
    func testImportWithANewGateIsRefused() throws {
        var harness = Harness()
        harness.tick()
        XCTAssertEqual(harness.sequences, [0])
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        XCTAssertThrowsError(try Harness(restoring: snapshot, gate: InMemoryGate(), currentSize: TerminalSize(width: 100, height: 30), now: harness.now + 1000)) { error in
            XCTAssertEqual(error as? SnapshotError, .gateBelowSnapshot(
                limits: GateCounters.sessionStart,
                used: GateCounters(sequence: 1, state: 2, fragmentID: 2)
            ))
        }
    }

    /// A gate above A but not above what was sent, and one counter at a time below.
    func testImportWithAGateBelowWhatWasUsedIsRefused() throws {
        let (old, snapshot, _) = try sessionWithUnacknowledgedInput()
        let good = old.gate.reservedLimits
        let used = snapshot.usedCounters
        var wrong = [GateCounters(sequence: 0, state: 3, fragmentID: 1)]
        wrong.append(GateCounters(sequence: used.sequence - 1, state: good.state, fragmentID: good.fragmentID))
        wrong.append(GateCounters(sequence: good.sequence, state: used.state - 1, fragmentID: good.fragmentID))
        wrong.append(GateCounters(sequence: good.sequence, state: good.state, fragmentID: used.fragmentID - 1))
        for start in wrong {
            let gate = InMemoryGate(startingAt: start)
            XCTAssertThrowsError(try Harness(restoring: snapshot, gate: gate, currentSize: TerminalSize(width: 100, height: 30)), "\(start)") { error in
                XCTAssertEqual(error as? SnapshotError, .gateBelowSnapshot(limits: start, used: used))
            }
            XCTAssertEqual(gate.datagramsPassed, 0)
        }
        // The lowest gate that cannot repeat anything, and the one a new process would make.
        XCTAssertNoThrow(try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: used), currentSize: nil))
        XCTAssertNoThrow(try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: good), currentSize: nil))
    }

    /// Limits that pass, numbers that do not: the send point starts from the snapshot's counters
    /// and refuses the first number that was used before. Nothing is sent.
    func testAGateWithGoodLimitsAndUsedNumbersIsStoppedAtTheFirstSend() throws {
        let (_, snapshot, _) = try sessionWithUnacknowledgedInput()
        let used = snapshot.usedCounters
        let high = GateCounters(sequence: 1 << 40, state: 1 << 40, fragmentID: 1 << 40)

        func run(_ next: GateCounters) throws -> (Harness, ScriptedGate) {
            let gate = ScriptedGate()
            gate.next = next
            gate.limits = high
            var harness = try Harness(restoring: snapshot, gate: gate, currentSize: nil)
            XCTAssertTrue(harness.tickRaw().isEmpty, "\(next)")
            XCTAssertTrue(harness.core.isHalted, "\(next)")
            harness.now += 5000
            XCTAssertTrue(harness.tickRaw().isEmpty, "\(next)")
            XCTAssertEqual(gate.passed, 0, "no datagram passed the gate")
            return (harness, gate)
        }

        let (lowSequence, _) = try run(GateCounters(sequence: used.sequence - 1, state: 5000, fragmentID: 5000))
        XCTAssertTrue(lowSequence.events.contains(.internalError(.sequenceNotIncreasing(last: used.sequence - 1, offered: used.sequence - 1))), "\(lowSequence.events)")

        // State 3 was sent as "abc"; the pending input would give it other content.
        let (lowState, _) = try run(GateCounters(sequence: 5000, state: 3, fragmentID: 5000))
        XCTAssertTrue(lowState.events.contains(.internalError(.stateNumberNotIncreasing(last: 3, offered: 3))), "\(lowState.events)")

        let (lowFragment, _) = try run(GateCounters(sequence: 5000, state: 5000, fragmentID: used.fragmentID - 1))
        XCTAssertTrue(lowFragment.events.contains(.internalError(.fragmentIDNotIncreasing(last: used.fragmentID - 1, offered: used.fragmentID - 1))), "\(lowFragment.events)")

        // Control: the first unused numbers themselves are fine.
        let gate = ScriptedGate()
        gate.next = used
        gate.limits = high
        var harness = try Harness(restoring: snapshot, gate: gate, currentSize: nil)
        let first = harness.tick()
        XCTAssertEqual(first.first?.newNum, used.state)
        XCTAssertEqual(first.first?.sequences, [used.sequence])
        XCTAssertEqual(first.first?.fragmentID, used.fragmentID)
        XCTAssertFalse(harness.core.isHalted)
    }

    func testImportRefusesCountersThatDoNotFitTheSnapshot() throws {
        let (old, good, _) = try sessionWithUnacknowledgedInput()
        var snapshot = good
        snapshot.usedCounters.state = snapshot.acknowledgedStateNumber
        XCTAssertThrowsError(try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)) {
            XCTAssertEqual($0 as? SnapshotError, .usedCountersInvalid)
        }
    }

    /// The counters survive a second export, with and without sends in between.
    func testCountersCarryOverASecondExport() throws {
        let (old, snapshot, _) = try sessionWithUnacknowledgedInput()
        let limits = old.gate.reservedLimits
        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: limits), currentSize: nil)
        harness.core.quiesce()
        XCTAssertEqual(try harness.core.exportState(), snapshot, "an import that sent nothing exports the same snapshot")
        harness.core.unquiesce(now: harness.now)
        let first = harness.tick()
        XCTAssertEqual(first.first?.newNum, limits.state)
        harness.core.quiesce()
        let second = try harness.core.exportState()
        XCTAssertEqual(second.usedCounters, GateCounters(sequence: limits.sequence + 1, state: limits.state + 1, fragmentID: limits.fragmentID + 1))
        XCTAssertThrowsError(try Harness(restoring: second, gate: InMemoryGate(startingAt: limits), currentSize: nil))
    }

    // MARK: M5

    /// mosh keeps one `expected_receiver_seq` for the life of the key (network.cc:515-519): a
    /// server datagram recorded before the export is out of order after the import too.
    func testAReplayedServerDatagramAfterImportIsOutOfOrder() throws {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()
        old.now += 5
        // The reply is chosen so that, replayed 60 s later, it would be a sample below 5 s.
        let kept = old.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 1, diff: hostBytes("x"), timestamp: 1234,
                                        timestampReply: UInt16(truncatingIfNeeded: old.now + 60_000 + 100 - 700))
        XCTAssertEqual(old.core.receive(datagram: kept[0], now: old.now), .authentic)
        old.deliver(old: 3, new: 4, ack: 2, throwaway: 1, diff: hostBytes("y"))
        XCTAssertEqual(old.core.receive(datagram: kept[0], now: old.now), .authenticOutOfOrder, "in the old process a replay is recognised")
        old.tick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        XCTAssertEqual(snapshot.receiverExpectedSequence, old.server.nextSeq)

        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil, now: old.now + 60_000)
        harness.server = old.server
        XCTAssertEqual(harness.tick().count, 1)
        harness.now += 100
        XCTAssertEqual(harness.core.receive(datagram: kept[0], now: harness.now), .authenticOutOfOrder)
        XCTAssertNil(harness.core.contactTimes.lastAuthenticDatagramAt, "no contact from a replay")
        XCTAssertFalse(harness.core.rtt.hasSample, "no round-trip sample from a replay")
        // Still probing: the next ack comes at the retransmission timeout, not after 3 s, and it
        // does not echo the replayed timestamp.
        let next = harness.advanceToWakeup()
        XCTAssertEqual(next.count, 1)
        XCTAssertLessThan(harness.now, old.now + 60_000 + 2000)
        XCTAssertEqual(next.first?.timestampReply, Timestamp16.none)

        // A genuine datagram is in order.
        XCTAssertEqual(harness.deliver(old: 4, new: 5, ack: snapshot.acknowledgedStateNumber, throwaway: 1, diff: hostBytes("z")), [.authentic])
        XCTAssertNotNil(harness.core.contactTimes.lastAuthenticDatagramAt)
    }

    // MARK: M8

    /// A socket that sends nowhere.
    private final class NullTransport: DatagramTransport, @unchecked Sendable {
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {}
        func close() {}
    }

    /// The token for the clean mark comes with the snapshot. Whatever the writer does later, the
    /// mark fails once a datagram left after the export.
    func testTheCleanTokenBelongsToTheExportedSnapshot() async throws {
        let gate = InMemoryGate()
        let connection = try MoshConnection<OpaqueRemoteState>(
            key: FakeServer.key,
            gate: gate,
            initialSize: TerminalSize(width: 80, height: 24),
            makeTransport: { NullTransport() }
        )
        await connection.start()
        XCTAssertGreaterThan(gate.datagramsPassed, 0)
        XCTAssertTrue(gate.isDirty)

        // The documented order: quiesce, export, write, mark clean.
        await connection.quiesce()
        let first = try await connection.exportState()
        XCTAssertEqual(first.cleanToken, CleanToken(datagramsPassed: gate.datagramsPassed))
        XCTAssertTrue(try gate.markClean(first.cleanToken))
        XCTAssertFalse(gate.isDirty)

        // Back in the foreground before the writer of a second snapshot is done.
        let second = try await connection.exportState()
        await connection.resume()
        await connection.type(Array("x".utf8))
        XCTAssertGreaterThan(gate.datagramsPassed, second.cleanToken.datagramsPassed, "resume sends at once")
        XCTAssertTrue(gate.isDirty)
        XCTAssertFalse(try gate.markClean(second.cleanToken), "dirty = 0 for a snapshot the server has moved past")
        XCTAssertTrue(gate.isDirty)

        // And an export is refused while not quiesced, so no token exists for that moment.
        do {
            _ = try await connection.exportState()
            XCTFail("export while sending")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .notQuiesced)
        }
        await connection.close()
    }
}
