import MoshWire
import XCTest
@testable import MoshTransport

/// quiesce, export and import: the seams M6 builds resume on (docs/PLAN.md section 3).
final class ResumeSeamTests: XCTestCase {
    private func keys(_ text: String) -> [UserEvent] {
        Array(text.utf8).map(UserEvent.byte)
    }

    /// A session in which the server has acknowledged "abc" (client state 3) while "de" was sent
    /// as state 4 and not acknowledged. The ack for state 3 has just arrived; no tick since.
    private func sessionWithAnAckAndNoTick() -> Harness {
        var harness = Harness(gate: InMemoryGate())
        harness.connectAndSettle()
        harness.type("abc")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 3)
        harness.now += 1
        harness.type("de")
        let second = harness.advanceToWakeup()
        XCTAssertEqual(second.first?.newNum, 4)
        XCTAssertEqual(second.first?.oldNum, 2)
        XCTAssertEqual(second.first?.input, [.keystroke(Array("abcde".utf8))])
        // The server got state 3 only and says so; its screen has moved on to state 3.
        harness.now += 5
        harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2, diff: hostBytes("abc"))
        return harness
    }

    // MARK: Export

    func testExportNeedsQuiesce() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertThrowsError(try harness.core.exportState()) { error in
            XCTAssertEqual(error as? SnapshotError, .notQuiesced)
        }
        harness.core.quiesce()
        XCTAssertNoThrow(try harness.core.exportState())
    }

    /// The rationalise case of the plan: mosh advances the front of its list on an ack but trims
    /// the input lists only at the next tick. A snapshot taken in between must not pair the new
    /// `A` with input counted from the old one.
    func testExportRightAfterAnAckHoldsExactlyTheInputTheServerHasNotSeen() throws {
        var harness = sessionWithAnAckAndNoTick()
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 3)
        XCTAssertEqual(snapshot.pendingInput, keys("de"), "not \"abcde\": the server has \"abc\"")
        XCTAssertEqual(snapshot.remoteStates.map(\.number), [2, 3])
        XCTAssertEqual(snapshot.remoteStates.last?.state.hostBytes, Array("helloabc".utf8))
        XCTAssertEqual(snapshot.highestAckSent, 2, "state 3 arrived but no ack for it was sent yet")
        XCTAssertEqual(snapshot.terminalSize, TerminalSize(width: 80, height: 24))

        // The same after a tick (which is when mosh would have trimmed).
        var ticked = sessionWithAnAckAndNoTick()
        ticked.tick()
        ticked.core.quiesce()
        let later = try ticked.core.exportState()
        XCTAssertEqual(later.acknowledgedStateNumber, 3)
        XCTAssertEqual(later.pendingInput, keys("de"))
    }

    func testExportIncludesInputThatWasNeverSent() throws {
        var harness = sessionWithAnAckAndNoTick()
        harness.core.type(Array("f".utf8))
        harness.core.resize(TerminalSize(width: 120, height: 40))
        harness.core.quiesce()
        // Input is still taken while quiesced; it is part of a later export.
        XCTAssertTrue(harness.core.type(Array("g".utf8)))
        let snapshot = try harness.core.exportState()
        XCTAssertEqual(snapshot.pendingInput, keys("def") + [.resize(TerminalSize(width: 120, height: 40))] + keys("g"))
        XCTAssertEqual(snapshot.terminalSize, TerminalSize(width: 120, height: 40))
    }

    func testExportOfAnIdleSessionHasNothingPending() throws {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 2)
        XCTAssertEqual(snapshot.pendingInput, [])
        XCTAssertEqual(snapshot.remoteStates.map(\.number), [1, 2])
        XCTAssertEqual(snapshot.highestAckSent, 1)
    }

    func testExportBeforeTheFirstReply() throws {
        var harness = Harness()
        harness.tick()
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        XCTAssertEqual(snapshot.acknowledgedStateNumber, 0)
        XCTAssertEqual(snapshot.pendingInput, [.resize(TerminalSize(width: 80, height: 24))])
        XCTAssertEqual(snapshot.remoteStates.map(\.number), [0])
        XCTAssertEqual(snapshot.highestAckSent, 0)
    }

    // MARK: Quiesce

    func testQuiesceStopsSendsAndFreezesTheState() throws {
        var harness = sessionWithAnAckAndNoTick()
        harness.core.quiesce()
        let passed = harness.gate.datagramsPassed
        let snapshot = try harness.core.exportState()
        harness.now += 10_000
        XCTAssertTrue(harness.tickRaw().isEmpty)
        XCTAssertNil(harness.lastWakeup, "no timer runs")
        // Datagrams that still arrive are not looked at.
        XCTAssertEqual(harness.deliver(old: 3, new: 4, ack: 4, throwaway: 3, diff: hostBytes("late")), [.ignored])
        XCTAssertEqual(try harness.core.exportState(), snapshot)
        XCTAssertEqual(harness.gate.datagramsPassed, passed)

        // Back in the foreground with the state in memory: a datagram at once.
        harness.core.unquiesce(now: harness.now)
        let sent = harness.tick()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, 3)
        XCTAssertEqual(sent.first?.newNum, 4, "the unacknowledged state, again")
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("de".utf8))])
        XCTAssertEqual(sent.first?.ackNum, 3)
        // And retries at the retransmission timeout, not after 3 s.
        XCTAssertEqual(harness.lastWakeup, harness.now + 150)
    }

    // MARK: Import

    /// Plan, "Cold start with a record", step 5, with pending input.
    func testImportWithPendingInputSendsThePlansFirstDatagram() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        // Next numbers start at the old reserved limits.
        let limits = old.gate.reservedLimits
        XCTAssertEqual(limits, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025))
        let gate = InMemoryGate(startingAt: limits, dirty: false)

        let startedAt: UInt64 = 5_000_000
        var harness = try Harness(restoring: snapshot, gate: gate, currentSize: TerminalSize(width: 80, height: 24), now: startedAt)
        XCTAssertEqual(harness.core.sentStateNumbers, [3], "[{num: A, events: []}]")
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [2, 3])
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("helloabc".utf8))
        XCTAssertFalse(gate.isDirty)

        let first = harness.tick()
        XCTAssertTrue(gate.isDirty, "dirty before the first datagram after a load")
        XCTAssertEqual(first.count, 1, "sent at once")
        XCTAssertEqual(first.first?.newNum, 1_025, "nextNum")
        XCTAssertEqual(first.first?.oldNum, 3, "A")
        XCTAssertEqual(first.first?.throwawayNum, 3, "A")
        XCTAssertEqual(first.first?.ackNum, 3, "the highest state in the snapshot")
        XCTAssertEqual(first.first?.diff, [0x0A, 0x06, 0x12, 0x04, 0x22, 0x02, 0x64, 0x65], "keystroke \"de\"")
        XCTAssertEqual(first.first?.sequences, [65_536])
        XCTAssertEqual(first.first?.fragmentID, 1_025)
        XCTAssertEqual(first.first?.timestampReply, Timestamp16.none)
        XCTAssertEqual(harness.core.sentStateNumbers, [3, 1_025])

        // Lost: retried about every second (RTO 1000 + ACK_DELAY 100 with a fresh estimator),
        // under the same state number.
        var times: [UInt64] = []
        while let wakeup = harness.lastWakeup, wakeup <= startedAt + 14_000 {
            for instruction in harness.advanceToWakeup() {
                XCTAssertEqual(instruction.newNum, 1_025, "retransmits reuse nextNum")
                XCTAssertEqual(instruction.oldNum, 3)
                XCTAssertEqual(instruction.throwawayNum, 3)
                XCTAssertEqual(instruction.input, [.keystroke(Array("de".utf8))])
                times.append(harness.now - startedAt)
            }
        }
        XCTAssertEqual(Array(times.prefix(3)), [1100, 2200, 3300])
        XCTAssertEqual(times, [1100, 2200, 3300, 4400, 5500, 6600, 7700, 8800, 9900, 12_900], "every 1.1 s for 10 s, then the 3 s ack timer")

        // New keystrokes get the next number.
        harness.type("f")
        let next = harness.advanceToWakeup()
        XCTAssertEqual(next.first?.newNum, 1_026)
        XCTAssertEqual(next.first?.oldNum, 3)
        XCTAssertEqual(next.first?.input, [.keystroke(Array("def".utf8))])
        XCTAssertEqual(Set(harness.sequences).count, harness.sequences.count)
        XCTAssertEqual(harness.sequences.min(), 65_536)
    }

    /// Plan, step 5, with nothing pending: an empty ack numbered nextNum on base A.
    func testImportWithNothingPendingSendsAnEmptyAck() throws {
        var old = Harness(gate: InMemoryGate())
        old.connectAndSettle()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        XCTAssertEqual(snapshot.pendingInput, [])
        let gate = InMemoryGate(startingAt: old.gate.reservedLimits)

        let startedAt: UInt64 = 5_000_000
        var harness = try Harness(restoring: snapshot, gate: gate, currentSize: TerminalSize(width: 80, height: 24), now: startedAt)
        // The same server: its sequence numbers go on where they were (a server's counter runs for
        // the life of the key, and the import keeps the expected number; network.cc:515-519).
        harness.server = old.server
        let first = harness.tick()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.newNum, 1_025)
        XCTAssertEqual(first.first?.oldNum, 2)
        XCTAssertEqual(first.first?.throwawayNum, 2)
        XCTAssertEqual(first.first?.ackNum, 2)
        XCTAssertEqual(first.first?.diff, [])
        XCTAssertEqual(first.first?.sequences, [65_536])

        // Lost: the server still sends to the old address, so nothing comes back. The ack is
        // repeated about every second for 10 s (each one a new state number, as every empty ack).
        var times: [UInt64] = []
        var numbers: [UInt64] = []
        while let wakeup = harness.lastWakeup, wakeup <= startedAt + 5000 {
            for instruction in harness.advanceToWakeup() {
                XCTAssertEqual(instruction.diff, [])
                XCTAssertEqual(instruction.oldNum, 2)
                times.append(harness.now - startedAt)
                numbers.append(instruction.newNum)
            }
        }
        XCTAssertEqual(times, [1100, 2200, 3300, 4400])
        XCTAssertEqual(numbers, [1_026, 1_027, 1_028, 1_029])

        // The server answers. The ack that was already scheduled still goes out; after it the
        // timer is mosh's 3 s again.
        harness.deliver(old: 2, new: 3, ack: 1_029, throwaway: 2)
        harness.tick()
        XCTAssertEqual(harness.core.sentStateNumbers, [1_029])
        XCTAssertEqual(harness.lastWakeup, startedAt + 5500)
        XCTAssertEqual(harness.advanceToWakeup().first?.ackNum, 3)
        XCTAssertEqual(harness.lastWakeup, startedAt + 5500 + 3000)
    }

    func testImportAddsAResizeWhenTheViewChangedSize() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        let gate = InMemoryGate(startingAt: old.gate.reservedLimits)
        var harness = try Harness(restoring: snapshot, gate: gate, currentSize: TerminalSize(width: 100, height: 30))
        let first = harness.tick()
        XCTAssertEqual(first.first?.input, [.keystroke(Array("de".utf8)), .resize(width: 100, height: 30)])
        XCTAssertEqual(harness.core.terminalSize, TerminalSize(width: 100, height: 30))

        // Unknown size (nil) and the same size add nothing.
        var same = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        XCTAssertEqual(same.tick().first?.input, [.keystroke(Array("de".utf8))])
        XCTAssertEqual(same.core.terminalSize, TerminalSize(width: 80, height: 24))
    }

    func testAnAckForAnUnknownStateNumberChangesNothing() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        harness.tick()
        XCTAssertEqual(harness.core.sentStateNumbers, [3, 1_025])

        // The server answers before it has state 1025: its ack names state 4, which the old
        // process sent and this one has never heard of.
        harness.now += 20
        harness.deliver(old: 3, new: 4, ack: 4, throwaway: 3, diff: hostBytes("x"))
        XCTAssertEqual(harness.core.sentStateNumbers, [3, 1_025], "A is kept")
        XCTAssertEqual(harness.core.acknowledgedStateNumber, 3)
        // Acks far above and below are ignored too.
        harness.deliver(old: 4, new: 5, ack: 99_999, throwaway: 3)
        harness.deliver(old: 5, new: 6, ack: 1, throwaway: 3)
        XCTAssertEqual(harness.core.sentStateNumbers, [3, 1_025])

        harness.type("f")
        let next = harness.advanceToWakeup()
        XCTAssertEqual(next.first?.oldNum, 3, "still built on A")
        XCTAssertEqual(next.first?.throwawayNum, 3)
        XCTAssertEqual(next.first?.newNum, 1_026)
        XCTAssertEqual(next.first?.input, [.keystroke(Array("def".utf8))])

        // The real ack moves A.
        harness.deliver(old: 6, new: 7, ack: 1_026, throwaway: 3)
        XCTAssertEqual(harness.core.sentStateNumbers, [1_026])
        XCTAssertTrue(harness.events.allSatisfy { if case .internalError = $0 { return false } else { return true } })
    }

    func testAnAckForAnUnknownStateInAFreshSessionChangesNothing() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.deliver(old: 2, new: 3, ack: 77, throwaway: 2)
        XCTAssertEqual(harness.core.sentStateNumbers, [2])
        harness.deliver(old: 3, new: 4, ack: 0, throwaway: 2)
        XCTAssertEqual(harness.core.sentStateNumbers, [2])
    }

    /// The whole way: export, a new core from the snapshot, and the session goes on with a
    /// server that never noticed.
    func testAResumedSessionContinues() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        let snapshot = try old.core.exportState()
        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        // The fake server carries on with its own numbering.
        harness.server = old.server
        let first = harness.tick()
        harness.now += 30
        // It applies "de" as state 1025 and acknowledges it, building on its state 3.
        harness.deliver(old: 3, new: 4, ack: 1_025, throwaway: 3, diff: hostBytes("de"), timestampReply: first.first?.timestamp ?? 0)
        harness.tick()
        XCTAssertEqual(harness.core.sentStateNumbers, [1_025])
        XCTAssertEqual(harness.core.newestRemoteState.number, 4)
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("helloabcde".utf8))
        XCTAssertEqual(harness.core.rtt.srtt, 30)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [3, 4])
        XCTAssertFalse(harness.events.contains { if case .baseStateLost = $0 { return true } else { return false } })

        harness.type("g")
        let next = harness.advanceToWakeup()
        XCTAssertEqual(next.first?.oldNum, 1_025)
        XCTAssertEqual(next.first?.newNum, 1_026)
        XCTAssertEqual(next.first?.throwawayNum, 1_025)
        XCTAssertEqual(next.first?.ackNum, 4)
        XCTAssertEqual(next.first?.input, [.keystroke(Array("g".utf8))])

        // And it can be exported again.
        harness.core.quiesce()
        let again = try harness.core.exportState()
        XCTAssertEqual(again.acknowledgedStateNumber, 1_025)
        XCTAssertEqual(again.pendingInput, keys("g"))
        XCTAssertEqual(again.highestAckSent, 4)
    }

    func testALostBaseAfterAResumeIsReported() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        var snapshot = try old.core.exportState()
        // A damaged record: the newest remote state is missing, but the server builds on it.
        snapshot.remoteStates.removeLast()
        snapshot.highestAckSent = 2
        var harness = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        harness.server = old.server
        harness.tick()
        harness.deliver(old: 3, new: 4, ack: 1_025, throwaway: 3, diff: hostBytes("de"))
        harness.tick()
        XCTAssertTrue(harness.events.contains(.baseStateLost(serverBase: 3)))
        XCTAssertEqual(harness.core.newestRemoteState.number, 2)
    }

    func testImportRefusesABrokenSnapshot() throws {
        var old = sessionWithAnAckAndNoTick()
        old.core.quiesce()
        let good = try old.core.exportState()
        func restore(_ snapshot: TransportSnapshot<OpaqueRemoteState>) throws {
            _ = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: old.gate.reservedLimits), currentSize: nil)
        }
        XCTAssertNoThrow(try restore(good))

        var empty = good
        empty.remoteStates = []
        XCTAssertThrowsError(try restore(empty)) { XCTAssertEqual($0 as? SnapshotError, .remoteStatesInvalid) }

        var unordered = good
        unordered.remoteStates.reverse()
        XCTAssertThrowsError(try restore(unordered)) { XCTAssertEqual($0 as? SnapshotError, .remoteStatesInvalid) }

        var missing = good
        missing.highestAckSent = 1 // not held
        XCTAssertThrowsError(try restore(missing)) { XCTAssertEqual($0 as? SnapshotError, .acknowledgedRemoteStateMissing(1)) }

        var reserved = good
        reserved.acknowledgedStateNumber = UInt64.max
        XCTAssertThrowsError(try restore(reserved)) { XCTAssertEqual($0 as? SnapshotError, .reservedStateNumber) }

        var reservedRemote = good
        reservedRemote.remoteStates.append(NumberedRemoteState(number: UInt64.max, state: OpaqueRemoteState()))
        XCTAssertThrowsError(try restore(reservedRemote)) { XCTAssertEqual($0 as? SnapshotError, .reservedStateNumber) }
    }
}
