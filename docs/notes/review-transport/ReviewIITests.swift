import MoshWire
import XCTest
@testable import MoshTransport

final class ReviewIITests: XCTestCase {
    /// II-1: a server datagram captured before the export is taken as in-order after the import.
    func testReplayAfterImportIsNotInOrder() throws {
        var harness = Harness(gate: InMemoryGate())
        harness.connectAndSettle()
        // An authentic datagram the old process has seen (seq below expected).
        harness.now += 5
        let old = harness.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 1, diff: hostBytes("x"), timestamp: 1234, timestampReply: UInt16(truncatingIfNeeded: harness.now + 60_000 + 100 - 700))
        XCTAssertEqual(harness.core.receive(datagram: old[0], now: harness.now), .authentic)
        XCTAssertEqual(harness.core.receive(datagram: old[0], now: harness.now), .authenticOutOfOrder, "replay in the same process")
        harness.tick()
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        let srttBefore = harness.core.rtt.srtt

        var resumed = try Harness(restoring: snapshot, gate: InMemoryGate(startingAt: harness.gate.reservedLimits), currentSize: snapshot.terminalSize, now: harness.now + 60_000)
        let first = resumed.tick()
        XCTAssertEqual(first.count, 1)
        // Chosen so that the stale reply gives a sample below 5000.
        let result = resumed.core.receive(datagram: old[0], now: resumed.now + 100)
        print("II-1 result \(result) srtt before \(srttBefore) after \(resumed.core.rtt.srtt) hasSample \(resumed.core.rtt.hasSample) contact \(resumed.core.contactTimes)")
        let next = resumed.advance(150)
        print("II-1 next echo \(next.map { $0.timestampReply }) wake \(String(describing: resumed.lastWakeup.map { $0 - resumed.now }))")
        XCTAssertEqual(result, .authenticOutOfOrder)
        XCTAssertNil(resumed.core.contactTimes.lastAuthenticDatagramAt)
    }

    /// II-2: a late ordinary state after the server's shutdown takes the ack number back.
    func testLateStateAfterServerShutdownKeepsTheShutdownAck() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 5
        let late = harness.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 2, diff: hostBytes("bye"))
        harness.deliver(old: 2, new: Instruction.shutdownNum, ack: 2, throwaway: 2)
        XCTAssertEqual(harness.core.acknowledgmentNumber, Instruction.shutdownNum)
        _ = harness.core.receive(datagram: late[0], now: harness.now)
        print("II-2 ackNum after late state: \(harness.core.acknowledgmentNumber)")
        var sent = 0
        var acks: [UInt64] = []
        for _ in 0..<200 {
            let out = harness.advance(20)
            sent += out.count
            acks.append(contentsOf: out.map(\.ackNum))
        }
        print("II-2 sent \(sent) in 4 s, acks \(Set(acks)), events \(harness.events)")
        XCTAssertEqual(harness.core.acknowledgmentNumber, Instruction.shutdownNum)
        XCTAssertTrue(harness.events.contains(.serverShutdownAcknowledged))
        XCTAssertLessThan(sent, 5)
    }

    /// II-3: a snapshot with A = 0 and a gate that does not start at the old limits.
    func testImportWithAGateBelowTheOldNumbersIsRefused() throws {
        var harness = Harness()
        let first = harness.tick()
        XCTAssertEqual(harness.sequences, [0])
        harness.core.quiesce()
        let snapshot = try harness.core.exportState()
        var resumed: Harness
        do {
            resumed = try Harness(restoring: snapshot, gate: InMemoryGate(), currentSize: TerminalSize(width: 100, height: 30), now: harness.now + 1000)
        } catch {
            return // refused: good
        }
        let again = resumed.tick()
        print("II-3 first \(first.map { ($0.sequences, $0.newNum, $0.fragmentID) }) again \(again.map { ($0.sequences, $0.newNum, $0.fragmentID, $0.input) }) events \(resumed.events)")
        XCTAssertTrue(again.isEmpty, "sequence 0, state 1 and fragment id 1 went out a second time with other content")
    }

    /// II-4: a shutdown with more pending input than the window.
    func testShutdownWithInputBeyondTheWindow() {
        var harness = Harness(configuration: Harness.configuration(limit: 2))
        harness.connectAndSettle()
        harness.type("abcdef")
        let a = harness.advanceToWakeup()
        print("II-4 a \(a.map { ($0.oldNum, $0.newNum, $0.input) })")
        harness.core.startShutdown(now: harness.now)
        let b = harness.advance(30)
        print("II-4 b \(b.map { ($0.oldNum, $0.newNum, $0.input) }) sent \(harness.core.sentStateNumbers)")
        // The server acknowledges the state before the shutdown state.
        if let n = a.first?.newNum {
            harness.deliver(old: 2, new: 3, ack: n, throwaway: 2, diff: hostBytes("ab"))
        }
        var all: [ClientInstruction] = []
        for _ in 0..<20 { all += harness.advance(30) }
        print("II-4 later \(all.map { ($0.oldNum, $0.newNum, $0.input) }) events \(harness.events) halted \(harness.core.isHalted)")
        XCTAssertFalse(harness.core.isHalted)
    }

    /// II-5: a shutdown while 150 bytes of input are unacknowledged.
    func testShutdownWithALotOfUnacknowledgedInput() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 150))
        var all: [ClientInstruction] = harness.advanceToWakeup()
        // No ack ever arrives. The user closes the session 30 s later.
        for _ in 0..<30 { all += harness.advance(1000) }
        print("II-5 before \(all.map { ($0.oldNum, $0.newNum, $0.diff.count) })")
        harness.core.startShutdown(now: harness.now)
        var shut: [ClientInstruction] = harness.tick()
        for _ in 0..<600 { shut += harness.advance(20) }
        print("II-5 shutdown sends \(shut.map { ($0.oldNum, $0.newNum, $0.diff.count) }) events \(harness.events.suffix(3)) halted \(harness.core.isHalted) ended \(harness.core.hasEnded)")
        XCTAssertFalse(harness.core.isHalted)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
    }

    /// The same with little input, for comparison.
    func testShutdownWithLittleUnacknowledgedInput() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("xyz")
        _ = harness.advanceToWakeup()
        for _ in 0..<30 { harness.advance(1000) }
        harness.core.startShutdown(now: harness.now)
        var shut: [ClientInstruction] = harness.tick()
        for _ in 0..<600 { shut += harness.advance(20) }
        print("II-5b shutdown sends \(shut.count) first \(shut.prefix(3).map { ($0.oldNum, $0.newNum, $0.diff.count) }) events \(harness.events.suffix(2)) halted \(harness.core.isHalted)")
    }
}
