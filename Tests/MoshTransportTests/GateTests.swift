import MoshWire
import XCTest
@testable import MoshTransport

/// A gate whose answers a test can script: jumping numbers, repeated numbers, failures.
final class ScriptedGate: DurabilityGate, @unchecked Sendable {
    struct Failure: Error {}

    var next = GateCounters(sequence: 1000, state: 500, fragmentID: 90)
    var step = GateCounters(sequence: 10, state: 7, fragmentID: 5)
    var limits = GateCounters(sequence: 1 << 40, state: 1 << 40, fragmentID: 1 << 40)
    /// Change a number on its way out.
    var sequenceOverride: ((UInt64) -> UInt64)?
    var stateOverride: ((UInt64) -> UInt64)?
    var fragmentOverride: ((UInt64) -> UInt64)?
    /// Number of calls that throw before the gate works again.
    var failSequence = 0
    var failState = 0
    var failFragment = 0
    var failWillSend = 0
    var passed: UInt64 = 0
    var dirty = false

    var reservedLimits: GateCounters { limits }

    func takeSequenceNumber() throws -> UInt64 {
        if failSequence > 0 { failSequence -= 1; throw Failure() }
        let value = next.sequence
        next.sequence += step.sequence
        return sequenceOverride?(value) ?? value
    }

    func takeStateNumber() throws -> UInt64 {
        if failState > 0 { failState -= 1; throw Failure() }
        let value = next.state
        next.state += step.state
        return stateOverride?(value) ?? value
    }

    func takeFragmentID() throws -> UInt64 {
        if failFragment > 0 { failFragment -= 1; throw Failure() }
        let value = next.fragmentID
        next.fragmentID += step.fragmentID
        return fragmentOverride?(value) ?? value
    }

    func willSendDatagram() throws {
        if failWillSend > 0 { failWillSend -= 1; throw Failure() }
        dirty = true
        passed += 1
    }

    var datagramsPassed: UInt64 { passed }
    var isDirty: Bool { dirty }

    func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool {
        guard passed == expected else { return false }
        dirty = false
        return true
    }
}

/// Numbers come from the gate, and the single send point refuses what would break N1 to N4
/// (docs/PLAN.md section 3).
final class GateTests: XCTestCase {
    private func violations(_ events: [TransportEvent]) -> [InvariantViolation] {
        events.compactMap { if case .internalError(let violation) = $0 { return violation } else { return nil } }
    }

    /// A session with a scripted gate, connected, with nothing pending. The client's states so
    /// far are 500 (the resize) and 507 (an empty ack); sequence numbers 1000 and 1010; fragment
    /// ids 90 and 95.
    private func settled(_ gate: ScriptedGate) -> Harness {
        var harness = Harness(gate: gate)
        let first = harness.tick()
        XCTAssertEqual(first.first?.newNum, 500)
        harness.now += 10
        harness.deliver(old: 0, new: 1, ack: 500, throwaway: 0, diff: hostBytes("hi"), timestampReply: first.first?.timestamp ?? 0)
        harness.tick()
        let ack = harness.advance(100)
        XCTAssertEqual(ack.first?.newNum, 507)
        harness.deliver(old: 1, new: 2, ack: 507, throwaway: 1)
        harness.tick()
        harness.events.removeAll()
        return harness
    }

    /// Checks that the transport refused to send and stays silent.
    private func assertHalted(_ harness: inout Harness, _ expected: InvariantViolation, sent: [ClientInstruction], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sent.isEmpty, "nothing may reach the server", file: file, line: line)
        XCTAssertEqual(violations(harness.events), [expected], file: file, line: line)
        XCTAssertTrue(harness.core.isHalted, file: file, line: line)
        XCTAssertNil(harness.lastWakeup, file: file, line: line)
        let passed = harness.gate.datagramsPassed
        harness.core.type([0x7A])
        harness.now += 10_000
        XCTAssertTrue(harness.tickRaw().isEmpty, "and nothing is sent afterwards", file: file, line: line)
        XCTAssertEqual(harness.gate.datagramsPassed, passed, file: file, line: line)
        XCTAssertEqual(violations(harness.events).count, 1, "reported once", file: file, line: line)
    }

    // MARK: Numbers come from the gate

    func testEveryNumberOnTheWireComesFromTheGate() {
        let gate = ScriptedGate()
        var harness = Harness(gate: gate)
        let first = harness.tick()
        XCTAssertEqual(first.first?.sequences, [1000])
        XCTAssertEqual(first.first?.newNum, 500)
        XCTAssertEqual(first.first?.fragmentID, 90)

        harness.now += 10
        harness.deliver(old: 0, new: 1, ack: 500, throwaway: 0, diff: hostBytes("hi"))
        XCTAssertEqual(harness.core.sentStateNumbers, [500])
        harness.tick()
        let ack = harness.advance(100)
        XCTAssertEqual(ack.first?.sequences, [1010])
        XCTAssertEqual(ack.first?.newNum, 507, "an empty ack takes a state number from the gate")
        XCTAssertEqual(ack.first?.oldNum, 500)
        XCTAssertEqual(ack.first?.fragmentID, 95)

        // New input: the next state number. A retransmission: the same state number, but a new
        // sequence number and a new fragment id.
        harness.type("a")
        let typed = harness.advanceToWakeup()
        XCTAssertEqual(typed.first?.newNum, 514)
        XCTAssertEqual(typed.first?.sequences, [1020])
        XCTAssertEqual(typed.first?.fragmentID, 100)
        let again = harness.advanceToWakeup()
        XCTAssertEqual(again.first?.newNum, 514)
        XCTAssertEqual(again.first?.sequences, [1030])
        XCTAssertEqual(again.first?.fragmentID, 105)

        // Several fragments: one sequence number each, one fragment id for all.
        var value: UInt32 = 7
        var noise: [UInt8] = []
        for _ in 0..<4000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            noise.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        harness.core.type(noise)
        harness.tick()
        let big = harness.advanceToWakeup()
        XCTAssertEqual(big.count, 1)
        XCTAssertEqual(big.first?.newNum, 521)
        XCTAssertEqual(big.first?.sequences, [1040, 1050, 1060, 1070])
        XCTAssertEqual(big.first?.fragmentID, 110)

        XCTAssertEqual(gate.passed, 8, "the gate saw every datagram")
        XCTAssertEqual(harness.core.datagramsSent, 8)
        XCTAssertTrue(violations(harness.events).isEmpty)
    }

    func testInMemoryGateReservesInBlocksAndANewGateStartsAtTheLimits() throws {
        let gate = InMemoryGate(blocks: GateCounters(sequence: 100, state: 10, fragmentID: 10))
        XCTAssertEqual(gate.reservedLimits, GateCounters(sequence: 0, state: 1, fragmentID: 1), "nothing reserved yet")
        XCTAssertEqual(try gate.takeSequenceNumber(), 0)
        XCTAssertEqual(try gate.takeStateNumber(), 1)
        XCTAssertEqual(try gate.takeFragmentID(), 1)
        XCTAssertEqual(gate.reservedLimits, GateCounters(sequence: 100, state: 11, fragmentID: 11))
        for expected in 1..<100 {
            XCTAssertEqual(try gate.takeSequenceNumber(), UInt64(expected))
        }
        XCTAssertEqual(gate.reservedLimits.sequence, 100)
        XCTAssertEqual(try gate.takeSequenceNumber(), 100)
        XCTAssertEqual(gate.reservedLimits.sequence, 200, "the next block")

        // "The process died": whatever was used of the block, the next process starts at the limit.
        let resumed = InMemoryGate(startingAt: gate.reservedLimits)
        XCTAssertEqual(try resumed.takeSequenceNumber(), 200)
        XCTAssertEqual(try resumed.takeStateNumber(), 11)
        XCTAssertEqual(try resumed.takeFragmentID(), 11)

        let exhausted = InMemoryGate(startingAt: GateCounters(sequence: UInt64.max - 5, state: 1, fragmentID: 1))
        XCTAssertThrowsError(try exhausted.takeSequenceNumber())
    }

    func testDefaultBlocksAreThePlans() throws {
        let gate = InMemoryGate()
        _ = try gate.takeSequenceNumber()
        _ = try gate.takeStateNumber()
        _ = try gate.takeFragmentID()
        XCTAssertEqual(gate.reservedLimits, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025))
    }

    func testDirtyBeforeSendAndCleanOnlyIfNothingPassed() throws {
        let gate = InMemoryGate(dirty: false)
        var harness = Harness(gate: gate)
        XCTAssertFalse(gate.isDirty)
        harness.tick()
        XCTAssertTrue(gate.isDirty, "the first datagram makes the record dirty")
        XCTAssertEqual(gate.datagramsPassed, 1)

        // Quiesce, snapshot, mark clean.
        harness.core.quiesce()
        let token = gate.datagramsPassed
        _ = try harness.core.exportState()
        XCTAssertTrue(try gate.markClean(ifDatagramsPassed: token))
        XCTAssertFalse(gate.isDirty)

        // Back to the foreground: the next datagram makes it dirty again.
        harness.core.unquiesce(now: harness.now)
        XCTAssertEqual(harness.tick().count, 1)
        XCTAssertTrue(gate.isDirty)

        // A snapshot whose "clean" comes after a send is refused.
        XCTAssertFalse(try gate.markClean(ifDatagramsPassed: token))
        XCTAssertTrue(gate.isDirty)
    }

    // MARK: N1, sequence numbers

    func testN1ARepeatedSequenceNumberIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.sequenceOverride = { _ in 1010 } // the number of the last datagram, again
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .sequenceNotIncreasing(last: 1010, offered: 1010), sent: sent)
    }

    func testN1ALowerSequenceNumberIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.sequence = { _ in 3 }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .sequenceNotIncreasing(last: 1010, offered: 3), sent: sent)
    }

    func testN1ASequenceNumberAtTheReservedLimitIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.limits.sequence = 1020 // the next number is 1020: not below the limit
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .sequenceNotReserved(offered: 1020, limit: 1020), sent: sent)
    }

    func testN1AViolationInTheMiddleOfAnInstructionSendsNoneOfIt() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        var value: UInt32 = 7
        var noise: [UInt8] = []
        for _ in 0..<4000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            noise.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        // The third datagram of the instruction would repeat the second one's number.
        gate.sequenceOverride = { $0 == 1040 ? 1030 : $0 }
        harness.core.type(noise)
        harness.tick()
        let raw = { () -> [[UInt8]] in harness.now = harness.lastWakeup ?? harness.now; return harness.tickRaw() }()
        XCTAssertTrue(raw.isEmpty, "not even the first two datagrams leave")
        XCTAssertEqual(violations(harness.events), [.sequenceNotIncreasing(last: 1030, offered: 1030)])
        XCTAssertTrue(harness.core.isHalted)
    }

    // MARK: N2, state numbers and their content

    func testN2ARepeatedStateNumberIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.stateOverride = { _ in 507 } // already used for the empty ack
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .stateNumberNotIncreasing(last: 507, offered: 507), sent: sent)
    }

    func testN2AStateNumberAtTheReservedLimitIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.limits.state = 514
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .stateNumberNotReserved(offered: 514, limit: 514), sent: sent)
    }

    func testN2AStateNumberTheGateNeverGaveIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.instruction = { $0.newNum += 1 }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .stateNumberNotReserved(offered: 515, limit: 1 << 40), sent: sent)
    }

    func testN2ASentStateNumberWithOtherContentIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.type("a")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 514)
        // More input, but the instruction claims to be state 514 again.
        harness.core.outbox.hooks.instruction = { $0.newNum = 514 }
        harness.now += 1
        harness.type("b")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .stateContentChanged(number: 514), sent: sent)
    }

    func testN2ANewStateWithAShorterInputListIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.type("ab")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 514)
        // A new state number whose content ends before state 514's: the server would assert
        // (UserStream::diff_from) and the remote shell would die.
        harness.core.outbox.hooks.instruction = { $0.newEnd -= 2 }
        harness.now += 1
        harness.type("c")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .stateInputShorter(number: 521), sent: sent)
    }

    func testN2TheSameStateAgainIsAllowed() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.type("a")
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 514)
        for _ in 0..<5 {
            let again = harness.advanceToWakeup()
            XCTAssertEqual(again.first?.newNum, 514)
            XCTAssertEqual(again.first?.input, [.keystroke([0x61])])
        }
        XCTAssertTrue(violations(harness.events).isEmpty)
    }

    // MARK: N3, throwaway_num

    func testN3ThrowawayAboveOldIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.instruction = { $0.throwawayNum = $0.oldNum + 1 }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .throwawayAboveOld(throwaway: 508, old: 507), sent: sent)
    }

    func testN3ABaseTheServerWasNeverGivenIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.instruction = { $0.oldNum = 506; $0.throwawayNum = 506 }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .baseStateUnknown(number: 506), sent: sent)
    }

    func testN3ABaseTheServerWasToldToForgetIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        // State 500 was acknowledged long ago and throwaway_num has been 507 since.
        harness.type("a")
        XCTAssertEqual(harness.advanceToWakeup().first?.throwawayNum, 507)
        harness.core.outbox.hooks.instruction = { $0.oldNum = 500; $0.throwawayNum = 500 }
        harness.now += 1
        harness.type("b")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .baseStateUnknown(number: 500), sent: sent)
    }

    func testTheShutdownNumberIsNoBaseAndNoThrowaway() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.instruction = { $0.throwawayNum = UInt64.max; $0.oldNum = UInt64.max }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .reservedStateNumber, sent: sent)
    }

    // MARK: N4, fragment ids

    func testN4ARepeatedFragmentIDIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.fragmentOverride = { _ in 95 }
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .fragmentIDNotIncreasing(last: 95, offered: 95), sent: sent)
    }

    func testN4AFragmentIDAtTheReservedLimitIsRefused() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        gate.limits.fragmentID = 100
        harness.type("a")
        let sent = harness.advanceToWakeup()
        assertHalted(&harness, .fragmentIDNotReserved(offered: 100, limit: 100), sent: sent)
    }

    func testN4ARetransmissionNeverReusesAFragmentID() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.type("a")
        var ids: [UInt64] = []
        for _ in 0..<6 {
            ids.append(contentsOf: harness.advanceToWakeup().map(\.fragmentID))
        }
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6)
        XCTAssertEqual(ids, ids.sorted())
    }

    // MARK: A gate that cannot write

    func testAGateFailureSendsNothingAndIsRetried() {
        for failing in ["sequence", "state", "fragment", "willSend"] {
            let gate = ScriptedGate()
            var harness = settled(gate)
            switch failing {
            case "sequence": gate.failSequence = 1
            case "state": gate.failState = 1
            case "fragment": gate.failFragment = 1
            default: gate.failWillSend = 1
            }
            harness.type("a")
            let passedBefore = gate.passed
            let failed = harness.advanceToWakeup()
            let failedAt = harness.now
            XCTAssertTrue(failed.isEmpty, failing)
            XCTAssertEqual(gate.passed, passedBefore, failing)
            XCTAssertEqual(harness.events.filter { if case .gateFailed = $0 { return true } else { return false } }.count, 1, failing)
            XCTAssertFalse(harness.core.isHalted, "a gate that cannot write now is not a dead session")
            XCTAssertEqual(harness.core.sentStateNumbers, [507], "the unsent state is not kept")
            XCTAssertEqual(harness.lastWakeup, failedAt + 1000, failing)
            XCTAssertTrue(harness.advance(999).isEmpty)

            let retried = harness.advance(1)
            XCTAssertEqual(retried.count, 1, failing)
            XCTAssertEqual(retried.first?.oldNum, 507)
            XCTAssertEqual(retried.first?.input, [.keystroke([0x61])])
            XCTAssertGreaterThan(retried.first?.newNum ?? 0, 507)
            XCTAssertTrue(violations(harness.events).isEmpty, failing)

            // And the session carries on.
            harness.deliver(old: 2, new: 3, ack: retried.first?.newNum ?? 0, throwaway: 2)
            XCTAssertEqual(harness.core.sentStateNumbers, [retried.first?.newNum ?? 0])
        }
    }

    /// A failed send is undone completely, also when it would have thinned the list of sent
    /// states: the state that would have gone is still a valid base afterwards.
    func testAGateFailureWhenTheSentStatesAreFullLosesNothing() {
        let gate = ScriptedGate()
        var harness = Harness(gate: gate)
        harness.tick()
        for _ in 2...32 {
            harness.type("k")
            harness.advance(300)
        }
        let full = harness.core.sentStateNumbers
        XCTAssertEqual(full.count, 32)
        XCTAssertEqual(full.first, 0)

        // The next state would make 33 and push out the one at index 17.
        gate.failSequence = 1
        harness.type("k")
        XCTAssertTrue(harness.advance(300).isEmpty)
        XCTAssertEqual(harness.core.sentStateNumbers, full, "exactly as before the failed send")

        // The server acknowledges that very state. It must still be usable as a base.
        harness.deliver(old: 0, new: 1, ack: full[17], throwaway: 0)
        XCTAssertEqual(harness.core.acknowledgedStateNumber, full[17])
        harness.now += 1000
        let sent = harness.tick()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, full[17])
        XCTAssertEqual(sent.first?.throwawayNum, full[17])
        XCTAssertEqual(sent.first?.input, [.keystroke(Array(String(repeating: "k", count: 15).utf8))])
        XCTAssertTrue(violations(harness.events).isEmpty)
        XCTAssertFalse(harness.core.isHalted)
    }

    func testAHaltedCoreStillReceivesButCannotBeExported() {
        let gate = ScriptedGate()
        var harness = settled(gate)
        harness.core.outbox.hooks.instruction = { $0.throwawayNum = $0.oldNum + 1 }
        harness.type("a")
        harness.advanceToWakeup()
        XCTAssertTrue(harness.core.isHalted)
        harness.deliver(old: 2, new: 3, ack: 507, throwaway: 2, diff: hostBytes("still here"))
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
        harness.core.quiesce()
        XCTAssertThrowsError(try harness.core.exportState()) { error in
            XCTAssertEqual(error as? SnapshotError, .sessionEnded)
        }
    }
}
