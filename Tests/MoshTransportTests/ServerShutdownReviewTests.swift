import MoshWire
import XCTest
@testable import MoshTransport

/// Finding M6 of docs/notes/review-transport/refutation.md.
final class ServerShutdownReviewTests: XCTestCase {
    /// The server's last frame arrives after its shutdown instruction (reordered). mosh keeps
    /// the shutdown state in `received_states`, so the late state is inserted before it and
    /// `set_ack_num` is not reached (networktransport-impl.h:143-160): the ack stays 2^64 - 1.
    func testLateStateAfterServerShutdownKeepsTheShutdownAck() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 5
        let late = harness.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 2, diff: hostBytes("bye"))
        harness.deliver(old: 2, new: Instruction.shutdownNum, ack: 2, throwaway: 2)
        XCTAssertEqual(harness.core.acknowledgmentNumber, Instruction.shutdownNum)
        XCTAssertEqual(harness.core.receive(datagram: late[0], now: harness.now), .authenticOutOfOrder)
        XCTAssertEqual(harness.core.acknowledgmentNumber, Instruction.shutdownNum)

        var sent: [ClientInstruction] = []
        for _ in 0..<200 {
            sent += harness.advance(20)
        }
        XCTAssertEqual(sent.map(\.ackNum), [Instruction.shutdownNum], "one ack of the shutdown, then silence")
        XCTAssertEqual(harness.events.filter { $0 == .serverShutdownAcknowledged }.count, 1)
        XCTAssertNil(harness.lastWakeup)
        // The late state is still a newer screen.
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
        XCTAssertTrue(harness.events.contains(.remoteStateAdvanced(number: 3)))
        XCTAssertFalse(harness.core.isHalted)
    }
}
