import Foundation
import MoshCrypto
import MoshWire
import XCTest
@testable import MoshTransport

/// The two reads local echo takes from `MoshConnection` (docs/notes/m10/DESIGN.md 2.3):
/// `typeNotingLastSent` gives the number stmclient reads with `get_sent_state_last()` before
/// the bytes are queued (stc:322), even when the bytes go out in the same call, and
/// `predictionReadings` the three values of stc:298-300 in one turn.
final class PredictionReadingsTests: XCTestCase {
    /// A clock that moves only when the test says so.
    private final class ManualClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var now: UInt64 = 1 << 24
        func nowMilliseconds() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
        func advance(_ milliseconds: UInt64) {
            lock.lock()
            now += milliseconds
            lock.unlock()
        }
    }

    /// A socket that sends nowhere and counts.
    private final class CountingTransport: DatagramTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sentCount = 0
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {
            lock.lock()
            sentCount += 1
            lock.unlock()
        }
        func close() {}
        var sent: Int {
            lock.lock()
            defer { lock.unlock() }
            return sentCount
        }
    }

    private func connection(_ transport: CountingTransport, clock: ManualClock = ManualClock())
        throws -> MoshConnection<OpaqueRemoteState> {
        try MoshConnection<OpaqueRemoteState>(
            key: FakeServer.key,
            configuration: TransportConfiguration(sendMinDelay: 0),
            initialSize: TerminalSize(width: 80, height: 24),
            clock: clock,
            makeTransport: { transport }
        )
    }

    func testTypeNotingLastSentReadsTheNumberBeforeTheBytesAreSent() async throws {
        let transport = CountingTransport()
        let clock = ManualClock()
        let c = try connection(transport, clock: clock)
        await c.start()
        clock.advance(1000)   // past the send interval: typed bytes go out within the call
        let sentBefore = transport.sent
        let first = await c.typeNotingLastSent(Array("a".utf8))
        XCTAssertTrue(first.accepted)
        XCTAssertGreaterThan(transport.sent, sentBefore, "the bytes went out in the same call")
        let second = await c.typeNotingLastSent(Array("b".utf8))
        XCTAssertTrue(second.accepted)
        XCTAssertGreaterThan(second.lastSentStateNumber, first.lastSentStateNumber,
                             "the first call sent a new state, so its number was read before the append")
        XCTAssertEqual(second.lastSentStateNumber, first.lastSentStateNumber + 1,
                       "the next read sees the state that carried the first bytes")
        await c.close()
    }

    func testRefusedInputStillReportsTheNumber() async throws {
        let transport = CountingTransport()
        let c = try connection(transport)
        await c.start()
        await c.close()
        let receipt = await c.typeNotingLastSent(Array("a".utf8))
        XCTAssertFalse(receipt.accepted)
        let typed = await c.type(Array("a".utf8))
        XCTAssertFalse(typed)
    }

    func testPredictionReadings() async throws {
        let transport = CountingTransport()
        let c = try connection(transport)
        await c.start()
        let r = await c.predictionReadings()
        let acked = await c.acknowledgedStateNumber()
        let newest = await c.newestRemoteState()
        XCTAssertEqual(r.sender.acknowledgedStateNumber, acked)
        XCTAssertEqual(r.sender.sendInterval, 250, "the send interval before the first RTT sample (network.cc:248)")
        XCTAssertEqual(r.newest, newest)
        await c.close()
    }
}
