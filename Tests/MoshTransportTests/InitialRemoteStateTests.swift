import MoshWire
import XCTest
@testable import MoshTransport

/// The remote state numbered 0 can be given (mosh's `Transport( initial_state, initial_remote,
/// ... )`, networktransport-impl.h:43-49), so that the server's first diff is applied to a copy
/// of what the server's own state 0 is.
final class InitialRemoteStateTests: XCTestCase {
    func testTheGivenStateIsStateZeroAndTheBaseOfTheFirstDiff() throws {
        var initial = OpaqueRemoteState()
        try initial.apply(diff: hostBytes("base"))
        var server = FakeServer()
        var core = TransportCore<OpaqueRemoteState>(
            cipher: server.cipher, gate: InMemoryGate(), configuration: Harness.configuration(),
            initialSize: TerminalSize(width: 80, height: 24), initialRemoteState: initial, now: Harness.start)
        XCTAssertEqual(core.newestRemoteState.number, 0)
        XCTAssertEqual(core.newestRemoteState.state, initial)

        let first = server.read(core.tick(now: Harness.start).datagrams)
        XCTAssertEqual(first.count, 1)
        for datagram in server.datagrams(old: 0, new: 1, ack: first.first?.newNum ?? 1, throwaway: 0, diff: hostBytes("-next")) {
            _ = core.receive(datagram: datagram, now: Harness.start + 10)
        }
        XCTAssertEqual(core.newestRemoteState.number, 1)
        XCTAssertTrue(core.newestRemoteState.state.hostBytesContain("base-next"))
        XCTAssertEqual(core.newestRemoteState.state.operationCount, 2)
    }

    func testWithoutOneStateZeroIsTheDefault() {
        let server = FakeServer()
        let core = TransportCore<OpaqueRemoteState>(
            cipher: server.cipher, gate: InMemoryGate(), configuration: Harness.configuration(),
            initialSize: nil, now: Harness.start)
        XCTAssertEqual(core.newestRemoteState.state, OpaqueRemoteState())
    }
}
