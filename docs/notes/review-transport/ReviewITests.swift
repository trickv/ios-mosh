import MoshWire
import XCTest
@testable import MoshTransport

final class ReviewITests: XCTestCase {
    /// I-1
    func testShutdownWithLargeUnackedInput() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 200))
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.count, 1)
        print("REVIEW sent states before shutdown", harness.core.sentStateNumbers)
        harness.core.startShutdown(now: harness.now)
        let startedAt = harness.now
        var shutdownSends = 0
        var log: [String] = []
        harness.tick().forEach { i in log.append("\(harness.now - startedAt): \(i.oldNum)->\(i.newNum == UInt64.max ? "SHUT" : String(i.newNum)) diff \(i.diff.count)"); shutdownSends += 1 }
        while harness.lastWakeup != nil, harness.now < startedAt + 20_000 {
            for i in harness.advanceToWakeup() {
                log.append("\(harness.now - startedAt): \(i.oldNum == UInt64.max ? "SHUT" : String(i.oldNum))->\(i.newNum == UInt64.max ? "SHUT" : String(i.newNum)) diff \(i.diff.count)")
                shutdownSends += 1
            }
        }
        print("REVIEW I-1 log", log)
        print("REVIEW I-1 events", harness.events, "halted", harness.core.isHalted, "ended", harness.core.hasEnded)
        XCTAssertFalse(harness.core.isHalted)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
        XCTAssertEqual(shutdownSends, 16)
    }

    /// I-1 variant: input typed but not yet sent when the shutdown starts.
    func testShutdownWithLargeUnsentInput() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertTrue(harness.core.type(Array(repeating: 0x78, count: 200)))
        harness.core.startShutdown(now: harness.now)
        let startedAt = harness.now
        var sends = 0
        sends += harness.tick().count
        while harness.lastWakeup != nil, harness.now < startedAt + 20_000 {
            sends += harness.advanceToWakeup().count
        }
        print("REVIEW I-1b events", harness.events, "halted", harness.core.isHalted, "sends", sends)
        XCTAssertFalse(harness.core.isHalted)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
    }

    /// Small input: fine?
    func testShutdownWithSmallUnackedInput() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertTrue(harness.core.type(Array(repeating: 0x78, count: 20)))
        harness.core.startShutdown(now: harness.now)
        let startedAt = harness.now
        var sends = 0
        sends += harness.tick().count
        while harness.lastWakeup != nil, harness.now < startedAt + 20_000 {
            sends += harness.advanceToWakeup().count
        }
        print("REVIEW small events", harness.events, "halted", harness.core.isHalted, "sends", sends)
        XCTAssertFalse(harness.core.isHalted)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
    }

    /// I-2: window + shutdown
    func testShutdownWithInputBeyondTheWindow() {
        var harness = Harness(configuration: Harness.configuration(limit: 4))
        harness.connectAndSettle()
        harness.type("abcdefghij")
        let sent = harness.advanceToWakeup()
        XCTAssertEqual(sent.first?.newNum, 3)
        harness.core.startShutdown(now: harness.now)
        var all = harness.tick()
        all += harness.advanceToWakeup()
        print("REVIEW I-2 shut sends", all.map { "\($0.oldNum)->\($0.newNum == UInt64.max ? "SHUT" : String($0.newNum)) \($0.diff.count)" })
        harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2)
        _ = harness.tick()
        _ = harness.advanceToWakeup()
        print("REVIEW I-2 events", harness.events, "halted", harness.core.isHalted)
        XCTAssertFalse(harness.core.isHalted)
    }

    /// I-1 with a working link: what the owner sees.
    func testShutdownWithLargeUnackedInputOnAWorkingLink() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 200))
        harness.advanceToWakeup()
        harness.core.startShutdown(now: harness.now)
        var sent = harness.tick()
        sent += harness.advanceToWakeup()
        sent += harness.advanceToWakeup()
        print("REVIEW I-1c sends", sent.map { "\($0.oldNum == UInt64.max ? "SHUT" : String($0.oldNum))->\($0.newNum == UInt64.max ? "SHUT" : String($0.newNum))" }, "wake", String(describing: harness.lastWakeup))
        harness.now += 30
        harness.deliver(old: 2, new: 3, ack: UInt64.max, throwaway: 2)
        harness.tick()
        print("REVIEW I-1c events", harness.events.suffix(3), "halted", harness.core.isHalted, "ended", harness.core.hasEnded)
    }

    /// I-3
    func testShutdownWhileQuiesced() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.quiesce()
        harness.core.startShutdown(now: harness.now)
        let sent = harness.tick()
        print("REVIEW I-3 quiesced: sent", sent.count, "wake", String(describing: harness.lastWakeup), "events", harness.events.suffix(1))
        harness.now += 60_000
        _ = harness.tick()
        print("REVIEW I-3 60 s later: wake", String(describing: harness.lastWakeup), "shuttingDown", harness.core.isShuttingDown, "ended", harness.core.hasEnded)
        harness.core.unquiesce(now: harness.now)
        let after = harness.tick()
        print("REVIEW I-3 after unquiesce: sent", after.count, "events", harness.events.suffix(1))
    }

    func testShutdownThenQuiesce() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.startShutdown(now: harness.now)
        let first = harness.tick()
        harness.core.quiesce()
        harness.now += 11_000
        harness.core.unquiesce(now: harness.now)
        let after = harness.tick()
        print("REVIEW I-3b first", first.count, "after unquiesce sent", after.count, "events", harness.events.suffix(1))
    }

    func testProbeCount() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.quiesce()
        harness.now += 60_000
        harness.core.unquiesce(now: harness.now)
        let start = harness.now
        var count = harness.tick().count
        while harness.now < start + 10_000 { count += harness.advanceToWakeup().count }
        print("REVIEW I-4 probes in 10 s", count, "sent states", harness.core.sentStateNumbers.count, "last state number", harness.core.lastSentStateNumber)
    }
}
