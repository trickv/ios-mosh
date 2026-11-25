import MoshWire
import XCTest
@testable import MoshTransport

/// RTT and RTO as in `Connection::recv_one` and `Connection::timeout` (mosh 1.4.0 network.cc).
final class RTTEstimatorTests: XCTestCase {
    func testInitialValues() {
        let rtt = RTTEstimator()
        XCTAssertEqual(rtt.srtt, 1000)
        XCTAssertEqual(rtt.rttvar, 500)
        XCTAssertFalse(rtt.hasSample)
        // ceil(1000 + 4 * 500) = 3000, clamped to MAX_RTO.
        XCTAssertEqual(rtt.timeout, 1000)
        // ceil(1000 / 2) = 500, clamped to SEND_INTERVAL_MAX.
        XCTAssertEqual(rtt.sendInterval, 250)
    }

    func testFirstSampleSetsBothValues() {
        var rtt = RTTEstimator()
        XCTAssertTrue(rtt.addSample(now: 1100, timestampReply: 1000))
        XCTAssertEqual(rtt.srtt, 100)
        XCTAssertEqual(rtt.rttvar, 50)
        XCTAssertEqual(rtt.timeout, 300)
        XCTAssertEqual(rtt.sendInterval, 50)
    }

    func testLaterSamplesAreSmoothed() {
        var rtt = RTTEstimator()
        rtt.addSample(now: 100, timestampReply: 0)
        rtt.addSample(now: 200, timestampReply: 0)
        // RTTVAR = 0.75 * 50 + 0.25 * |100 - 200| = 62.5; SRTT = 0.875 * 100 + 0.125 * 200 = 112.5
        XCTAssertEqual(rtt.rttvar, 62.5)
        XCTAssertEqual(rtt.srtt, 112.5)
        // ceil(112.5 + 250) = 363; ceil(56.25) = 57
        XCTAssertEqual(rtt.timeout, 363)
        XCTAssertEqual(rtt.sendInterval, 57)
    }

    func testClamps() {
        var fast = RTTEstimator()
        fast.addSample(now: 1, timestampReply: 0)
        // ceil(1 + 4 * 0.5) = 3, below MIN_RTO; ceil(0.5) = 1, below SEND_INTERVAL_MIN.
        XCTAssertEqual(fast.timeout, 50)
        XCTAssertEqual(fast.sendInterval, 20)

        var zero = RTTEstimator()
        zero.addSample(now: 7, timestampReply: 7)
        XCTAssertEqual(zero.srtt, 0)
        XCTAssertEqual(zero.timeout, 50)
        XCTAssertEqual(zero.sendInterval, 20)

        var slow = RTTEstimator()
        slow.addSample(now: 4999, timestampReply: 0)
        XCTAssertEqual(slow.srtt, 4999)
        XCTAssertEqual(slow.timeout, 1000)
        XCTAssertEqual(slow.sendInterval, 250)
    }

    func testSamplesOfFiveSecondsOrMoreAreIgnored() {
        var rtt = RTTEstimator()
        XCTAssertFalse(rtt.addSample(now: 5000, timestampReply: 0))
        XCTAssertFalse(rtt.addSample(now: 0, timestampReply: 1)) // 65535 ms
        XCTAssertFalse(rtt.hasSample)
        XCTAssertEqual(rtt.srtt, 1000)
        XCTAssertEqual(rtt.rttvar, 500)
        XCTAssertTrue(rtt.addSample(now: 4999, timestampReply: 0))
        XCTAssertTrue(rtt.hasSample)
    }

    func testTimestampWrapsAtSixteenBits() {
        var rtt = RTTEstimator()
        // Sent at 65500, echoed at 65536 + 14 = 14 (mod 65536): 50 ms.
        XCTAssertTrue(rtt.addSample(now: 14, timestampReply: 65500))
        XCTAssertEqual(rtt.srtt, 50)
        XCTAssertEqual(Timestamp16.difference(14, 65500), 50)
        // The clock value 65535 is sent as 0, because 0xFFFF means "no timestamp".
        XCTAssertEqual(Timestamp16.now(milliseconds: 65535), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 3 * 65536 + 65535), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 65536 + 5), 5)
    }

    /// The core feeds the estimator from `timestamp_reply`, only for datagrams in sequence, and
    /// echoes a received timestamp once, advanced by the time it was held.
    func testCoreTakesSamplesAndEchoesTimestamps() {
        var harness = Harness()
        let first = harness.tick()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].timestamp, Timestamp16.now(milliseconds: Harness.start))
        XCTAssertEqual(first[0].timestampReply, Timestamp16.none, "nothing received yet")

        // The reply comes back 80 ms later.
        harness.now += 80
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("x"), timestamp: 4242, timestampReply: first[0].timestamp)
        XCTAssertEqual(harness.core.rtt.srtt, 80)
        XCTAssertEqual(harness.core.rtt.rttvar, 40)

        // The ack goes out after the 100 ms ack delay and echoes 4242 + 100.
        harness.tick()
        let ack = harness.advance(100)
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack[0].timestampReply, 4342)

        // The echo is used once.
        let later = harness.advance(3000)
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later[0].timestampReply, Timestamp16.none)

        // A timestamp held for a second or more is not echoed at all.
        harness.deliver(old: 1, new: 2, ack: later[0].newNum, throwaway: 1, timestamp: 100)
        let stale = harness.advance(3000)
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].timestampReply, Timestamp16.none)
    }

    func testOutOfOrderDatagramsGiveNoSampleAndNoEcho() {
        var harness = Harness()
        let first = harness.tick()
        harness.now += 80
        // Sequence number 5 arrives first, then 3: mosh still processes 3 but takes neither its
        // timestamp nor its reply.
        let newer = harness.server.packet(
            payload: try! Fragmenter.makeFragments(instruction: Instruction(oldNum: 0, newNum: 1, ackNum: 1, throwawayNum: 0, diff: hostBytes("a")), id: 1, contentsBudget: 1214)[0].serialized(),
            timestamp: 100, timestampReply: first[0].timestamp, seq: 5)
        XCTAssertEqual(harness.core.receive(datagram: newer, now: harness.now), .authentic)
        XCTAssertEqual(harness.core.rtt.srtt, 80)
        XCTAssertTrue(harness.tick().isEmpty, "the ack waits 100 ms for data to ride along with")

        harness.now += 500
        let older = harness.server.packet(
            payload: try! Fragmenter.makeFragments(instruction: Instruction(oldNum: 1, newNum: 2, ackNum: 1, throwawayNum: 0, diff: hostBytes("b")), id: 2, contentsBudget: 1214)[0].serialized(),
            timestamp: 7777, timestampReply: first[0].timestamp, seq: 3)
        XCTAssertEqual(harness.core.receive(datagram: older, now: harness.now), .authenticOutOfOrder)
        XCTAssertEqual(harness.core.rtt.srtt, 80, "no sample from an out-of-order datagram")
        // Its instruction is used all the same.
        XCTAssertEqual(harness.core.newestRemoteState.number, 2)
        XCTAssertNil(harness.core.contactTimes.lastAuthenticDatagramAt.flatMap { $0 == harness.now ? $0 : nil }, "last heard is not updated")

        // The echo is still the one of datagram 5 (held 500 ms), not 7777.
        let ack = harness.tick()
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack.first?.timestampReply, 600)
    }

    func testCongestionMarkMakesTheEchoOlder() {
        var harness = Harness()
        harness.tick()
        let datagram = harness.server.datagrams(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("x"), timestamp: 1000)[0]
        harness.core.receive(datagram: datagram, now: harness.now, congestionExperienced: true)
        harness.tick()
        let ack = harness.advance(100)
        // 1000 - 500 (CONGESTION_TIMESTAMP_PENALTY) + 100 held.
        XCTAssertEqual(ack.first?.timestampReply, 600)
    }
}
