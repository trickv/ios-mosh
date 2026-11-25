import MoshWire
import XCTest
@testable import MoshTransport

/// When the sender sends: `TransportSender::calculate_timers` and `tick` (mosh 1.4.0).
final class SendTimingTests: XCTestCase {
    func testFirstSendIsImmediate() {
        var harness = Harness()
        let sent = harness.tick()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.oldNum, 0)
        XCTAssertEqual(sent.first?.newNum, 1)
        XCTAssertEqual(sent.first?.ackNum, 0)
        XCTAssertEqual(sent.first?.throwawayNum, 0)
        XCTAssertEqual(sent.first?.sequences, [0])
        XCTAssertEqual(sent.first?.fragmentID, 1)
        XCTAssertEqual(sent.first?.input, [.resize(width: 80, height: 24)])
        // Nothing more until the 3 s ack timer: without a word from the server there is no fast
        // retry (mosh's last_heard is still "never").
        XCTAssertEqual(harness.lastWakeup, Harness.start + 3000)
        XCTAssertTrue(harness.tick().isEmpty, "a second tick at the same time sends nothing")
    }

    func testUnansweredFirstStateIsRepeatedEveryThreeSeconds() {
        var harness = Harness()
        harness.tick()
        XCTAssertTrue(harness.advance(2999).isEmpty)
        for round in 1...3 {
            let again = harness.advance(round == 1 ? 1 : 3000)
            XCTAssertEqual(again.count, 1)
            XCTAssertEqual(again.first?.newNum, 1, "a retransmission keeps the state number")
            XCTAssertEqual(again.first?.oldNum, 0)
            XCTAssertEqual(again.first?.input, [.resize(width: 80, height: 24)])
            XCTAssertEqual(again.first?.sequences, [UInt64(round)], "but takes a new sequence number")
            XCTAssertEqual(again.first?.fragmentID, UInt64(round + 1), "and a new fragment id")
            XCTAssertEqual(harness.lastWakeup, harness.now + 3000)
        }
    }

    func testAckForDataWaitsOneHundredMilliseconds() {
        var harness = Harness()
        harness.connect()
        let arrived = harness.now
        XCTAssertTrue(harness.tick().isEmpty, "the ack is not sent at once")
        XCTAssertEqual(harness.lastWakeup, arrived + 100)
        XCTAssertTrue(harness.advance(99).isEmpty)
        let ack = harness.advance(1)
        XCTAssertEqual(ack.count, 1)
        // An empty ack is a new state number with an empty diff.
        XCTAssertEqual(ack.first?.newNum, 2)
        XCTAssertEqual(ack.first?.oldNum, 1)
        XCTAssertEqual(ack.first?.ackNum, 1)
        XCTAssertEqual(ack.first?.throwawayNum, 1)
        XCTAssertEqual(ack.first?.diff, [])
        XCTAssertEqual(harness.lastWakeup, harness.now + 3000)
    }

    func testAnEmptyServerStateIsNotAckedEarly() {
        var harness = Harness()
        harness.connectAndSettle()
        let settled = harness.now
        // A pure ack from the server (empty diff) does not start the 100 ms ack delay.
        harness.now += 50
        harness.deliver(old: 2, new: 3, ack: 2, throwaway: 2)
        XCTAssertTrue(harness.tick().isEmpty)
        XCTAssertEqual(harness.lastWakeup, settled + 3000)
        XCTAssertEqual(harness.core.acknowledgmentNumber, 3)
    }

    func testEmptyAckEveryThreeSeconds() {
        var harness = Harness()
        harness.connectAndSettle()
        let settled = harness.now
        var number: UInt64 = 3
        for round in 1...3 {
            XCTAssertEqual(harness.lastWakeup, settled + UInt64(round) * 3000)
            harness.now = settled + UInt64(round) * 3000 - 1
            XCTAssertTrue(harness.tick().isEmpty)
            let ack = harness.advance(1)
            XCTAssertEqual(ack.count, 1)
            XCTAssertEqual(ack.first?.newNum, number, "every empty ack is a new state")
            XCTAssertEqual(ack.first?.oldNum, 2, "based on the acknowledged state")
            XCTAssertEqual(ack.first?.throwawayNum, 2)
            XCTAssertEqual(ack.first?.diff, [])
            number += 1
        }
    }

    func testNewInputWaitsForTheSendIntervalFromSRTT() {
        var harness = Harness()
        harness.connectAndSettle()
        let settled = harness.now // also when state 2 was last sent
        XCTAssertEqual(harness.core.rtt.sendInterval, 20)

        // Typed at once after a send: goes out one send interval after that send.
        XCTAssertTrue(harness.type("a").isEmpty)
        XCTAssertEqual(harness.lastWakeup, settled + 20)
        harness.now = settled + 19
        XCTAssertTrue(harness.tick().isEmpty)
        let first = harness.advance(1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.newNum, 3)
        XCTAssertEqual(first.first?.input, [.keystroke(Array("a".utf8))])

        // The next key, typed 1 ms later, waits for the rest of the interval.
        harness.now += 1
        XCTAssertTrue(harness.type("b").isEmpty)
        XCTAssertEqual(harness.lastWakeup, settled + 40)
        let second = harness.advanceToWakeup()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.newNum, 4)
    }

    func testSendIntervalFollowsASlowerLink() {
        var harness = Harness()
        let first = harness.tick()
        // The reply takes 300 ms: SRTT 300, send interval ceil(300 / 2) = 150.
        harness.now += 300
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, timestampReply: first.first?.timestamp ?? 0)
        XCTAssertEqual(harness.core.rtt.sendInterval, 150)
        XCTAssertTrue(harness.type("a").isEmpty)
        // State 1 was sent at the start, 300 ms ago: the interval has passed, so only the 1 ms
        // minimum delay applies.
        XCTAssertEqual(harness.lastWakeup, harness.now + 1)
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.count, 1)
        let sentAt = harness.now
        XCTAssertTrue(harness.type("b").isEmpty)
        XCTAssertEqual(harness.lastWakeup, sentAt + 150)
    }

    func testKeystrokesAreBatchedByTheMinimumDelay() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500 // long after the last send
        let typedAt = harness.now
        // mosh's client sets SEND_MINDELAY to 1 ms: keys typed within it share one instruction.
        XCTAssertTrue(harness.type("a").isEmpty)
        XCTAssertEqual(harness.lastWakeup, typedAt + 1)
        XCTAssertTrue(harness.type("b").isEmpty)
        XCTAssertTrue(harness.type("c").isEmpty)
        XCTAssertEqual(harness.lastWakeup, typedAt + 1, "the delay runs from the first key")
        let sent = harness.advance(1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("abc".utf8))])
        XCTAssertEqual(sent.first?.newNum, 3)
        XCTAssertEqual(sent.first?.oldNum, 2)
    }

    func testALongerMinimumDelayBatchesMore() {
        var configuration = Harness.configuration()
        configuration.sendMinDelay = 8 // the sender's own default
        var harness = Harness(configuration: configuration)
        harness.connectAndSettle()
        harness.now += 500
        let typedAt = harness.now
        harness.type("a")
        harness.now += 5
        XCTAssertTrue(harness.type("b").isEmpty)
        XCTAssertEqual(harness.lastWakeup, typedAt + 8)
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.first?.input, [.keystroke(Array("ab".utf8))])
    }

    func testUnacknowledgedStateIsRetransmitted() {
        var harness = Harness()
        harness.connectAndSettle()
        let settled = harness.now
        harness.type("a")
        let first = harness.advanceToWakeup()
        XCTAssertEqual(first.first?.newNum, 3)
        let sentAt = harness.now
        XCTAssertEqual(sentAt, settled + 20)

        // No ack. The receiver is assumed to have the state for RTO + ACK_DELAY = 50 + 100 ms;
        // then it is sent again, and again, as long as the server was heard in the last 10 s.
        XCTAssertEqual(harness.core.rtt.timeout, 50)
        var times: [UInt64] = []
        while let wakeup = harness.lastWakeup, wakeup <= settled + 13_500 {
            let sent = harness.advanceToWakeup()
            for instruction in sent {
                XCTAssertEqual(instruction.newNum, 3, "retransmissions keep the number")
                XCTAssertEqual(instruction.oldNum, 2)
                XCTAssertEqual(instruction.input, [.keystroke(Array("a".utf8))])
                times.append(harness.now - sentAt)
            }
        }
        XCTAssertEqual(Array(times.prefix(3)), [150, 300, 450])
        // The server was last heard at `settled`: fast retries stop 10 s after that, and the 3 s
        // ack timer takes over.
        XCTAssertEqual(times.filter { $0 < 9990 - 20 }.count, 66)
        XCTAssertEqual(Array(times.suffix(2)), [9900, 12_900])
        // Sequence numbers never repeat.
        XCTAssertEqual(Set(harness.sequences).count, harness.sequences.count)
        XCTAssertEqual(harness.sequences, harness.sequences.sorted())
    }

    func testAckStopsRetransmission() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type("a")
        harness.advanceToWakeup()
        harness.now += 30
        harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2)
        XCTAssertEqual(harness.core.sentStateNumbers, [3])
        XCTAssertTrue(harness.tick().isEmpty)
        // Only the ack timer is left: 3 s after the last send.
        XCTAssertEqual(harness.lastWakeup, harness.now - 30 + 3000)
    }

    func testPortHopIsRequestedAfterTenSecondsWithoutARoundTrip() {
        var harness = Harness()
        harness.tick()
        var requestedAt: [UInt64] = []
        while harness.now < Harness.start + 30_000 {
            harness.advanceToWakeup()
            if harness.events.contains(.socketReplacementWanted) {
                requestedAt.append(harness.now - Harness.start)
                harness.events.removeAll()
                harness.core.socketReplaced(now: harness.now, probe: false)
            }
        }
        // Sends happen every 3 s; the first one more than 10 s after the last port choice asks.
        XCTAssertEqual(requestedAt, [12_000, 24_000])
    }

    func testNoPortHopWhileRoundTripsSucceed() {
        var harness = Harness()
        harness.connectAndSettle()
        // The server acknowledges every empty ack for a minute.
        while harness.now < Harness.start + 60_000 {
            for instruction in harness.advanceToWakeup() {
                harness.deliver(old: harness.core.newestRemoteState.number, new: harness.core.newestRemoteState.number + 1, ack: instruction.newNum, throwaway: harness.core.newestRemoteState.number)
            }
        }
        XCTAssertFalse(harness.events.contains(.socketReplacementWanted))
    }

    func testProbeAfterASocketReplacementSendsAtOnceAndRetriesAtTheRetransmissionTimeout() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 60_000 // a long silence, as after time in the background
        harness.tick()
        harness.events.removeAll()
        let replacedAt = harness.now + 500
        harness.now = replacedAt
        harness.core.socketReplaced(now: harness.now, probe: true)
        var times: [UInt64] = []
        var sent = harness.tick()
        while harness.now <= replacedAt + 14_000 {
            if !sent.isEmpty {
                times.append(harness.now - replacedAt)
                XCTAssertEqual(sent.first?.diff, [])
            }
            sent = harness.advanceToWakeup()
        }
        // SRTT is 10 ms, so the timeout is 50 + 100 ms: an ack at once and every 150 ms while
        // the replacement is less than 10 s old, then mosh's 3 s again.
        XCTAssertEqual(Array(times.prefix(3)), [0, 150, 300])
        XCTAssertEqual(Array(times.suffix(3)), [9900, 10_050, 13_050])
    }

    func testIPv6UsesSmallerDatagrams() {
        var v4 = Harness(configuration: Harness.configuration(family: .ipv4))
        var v6 = Harness(configuration: Harness.configuration(family: .ipv6))
        // Bytes that do not compress.
        var value: UInt32 = 12345
        var noise: [UInt8] = []
        for _ in 0..<5000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            noise.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        v4.core.type(noise)
        v6.core.type(noise)
        let datagrams4 = v4.tickRaw()
        let datagrams6 = v6.tickRaw()
        XCTAssertGreaterThan(datagrams4.count, 1)
        XCTAssertEqual(datagrams4.map(\.count).max(), 1252)
        XCTAssertEqual(datagrams6.map(\.count).max(), 1216)
        XCTAssertEqual(v4.server.read(datagrams4).first?.input.count, 2)

        // After EMSGSIZE the datagrams shrink to 500 bytes for good (mosh never raises the MTU
        // again). The unanswered state is repeated after 3 s, now in more and smaller pieces.
        v4.core.datagramTooLarge()
        XCTAssertEqual(v4.core.currentDatagramMTU, 500)
        v4.now += 3000
        let small = v4.tickRaw()
        XCTAssertGreaterThan(small.count, datagrams4.count)
        XCTAssertEqual(small.map(\.count).max(), 500)
        XCTAssertEqual(v4.server.read(small).first?.newNum, 1)
    }
}
