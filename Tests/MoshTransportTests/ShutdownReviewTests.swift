import MoshWire
import XCTest
@testable import MoshTransport

/// The client's shutdown with input pending, with input beyond the window, and across a quiesce
/// (findings M1 to M3 of docs/notes/review-transport/refutation.md).
///
/// mosh: `send_empty_ack` and `send_to_receiver` use 2^64 - 1 as `new_num` while
/// `shutdown_in_progress` (transportsender-impl.h:212-221, 248-250), `get_current_state` asserts
/// that the state is frozen (transportsender.h:140), and the client gives up after 16 tries or
/// 10 s (transportsender-impl.h:386-391).
final class ShutdownReviewTests: XCTestCase {
    /// Starts a shutdown now and runs until the core asks for no more wake-ups (or 20 s).
    private func runShutdown(_ harness: inout Harness) -> [ClientInstruction] {
        let startedAt = harness.now
        XCTAssertTrue(harness.core.startShutdown(now: harness.now))
        var sent = harness.tick()
        while harness.lastWakeup != nil, harness.now < startedAt + 20_000 {
            sent += harness.advanceToWakeup()
        }
        return sent
    }

    private func assertCleanTimeout(_ harness: Harness, _ sent: [ClientInstruction], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(harness.core.isHalted, file: file, line: line)
        XCTAssertFalse(harness.events.contains { if case .internalError = $0 { return true } else { return false } },
                       "\(harness.events)", file: file, line: line)
        XCTAssertEqual(sent.count, TransportConstants.shutdownRetries, file: file, line: line)
        for instruction in sent {
            XCTAssertEqual(instruction.newNum, Instruction.shutdownNum, file: file, line: line)
            XCTAssertNotEqual(instruction.oldNum, Instruction.shutdownNum, "2^64 - 1 is never a base", file: file, line: line)
            XCTAssertLessThanOrEqual(instruction.throwawayNum, instruction.oldNum, file: file, line: line)
        }
        XCTAssertEqual(harness.events.filter { $0 == .shutdownTimedOut }.count, 1, file: file, line: line)
        XCTAssertTrue(harness.core.hasEnded, file: file, line: line)
    }

    // MARK: M1

    /// 200 bytes sent a moment ago and not acknowledged: the diff from the acknowledged state is
    /// more than 100 bytes longer than an empty one, so the sender does not go back to the front
    /// (transportsender-impl.h:419-424) and the second shutdown send needs a base.
    func testShutdownWithRecentUnacknowledgedInputIsRepeatedAndTimesOut() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 200))
        XCTAssertEqual(harness.advanceToWakeup().first?.newNum, 3)
        let sent = runShutdown(&harness)
        assertCleanTimeout(harness, sent)
        // Every instruction leads to the same state: all 200 bytes.
        for instruction in sent {
            let typed = keystrokes(instruction.input).count
            XCTAssertEqual(typed, instruction.oldNum == 3 ? 0 : 200, "base \(instruction.oldNum)")
        }
        XCTAssertEqual(sent.first?.oldNum, 3, "the recent ordinary state is the base while it is recent")
        XCTAssertEqual(sent.last?.oldNum, 2, "and the acknowledged state afterwards")
    }

    /// The same with input that was typed but never sent.
    func testShutdownWithUnsentInputIsRepeatedAndTimesOut() {
        var harness = Harness()
        harness.connectAndSettle()
        XCTAssertTrue(harness.core.type(Array(repeating: 0x78, count: 200)))
        let sent = runShutdown(&harness)
        assertCleanTimeout(harness, sent)
        for instruction in sent {
            XCTAssertEqual(instruction.oldNum, 2)
            XCTAssertEqual(keystrokes(instruction.input).count, 200)
        }
    }

    /// A dead link for 30 s, then Disconnect (the case review II measured).
    func testShutdownAfterALongOutageWithUnacknowledgedInput() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 150))
        harness.advanceToWakeup()
        for _ in 0..<30 { harness.advance(1000) }
        XCTAssertTrue(harness.core.startShutdown(now: harness.now))
        var sent = harness.tick()
        for _ in 0..<600 { sent += harness.advance(20) }
        assertCleanTimeout(harness, sent)
    }

    /// On a working link the owner sees the acknowledgment and no internal error.
    func testShutdownWithRecentUnacknowledgedInputIsAcknowledged() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.type(String(repeating: "x", count: 200))
        harness.advanceToWakeup()
        XCTAssertTrue(harness.core.startShutdown(now: harness.now))
        var sent = harness.tick()
        sent += harness.advanceToWakeup()
        sent += harness.advanceToWakeup()
        XCTAssertGreaterThanOrEqual(sent.count, 2, "the second send is the one that needs a base")
        harness.now += 5
        harness.deliver(old: 2, new: 3, ack: UInt64.max, throwaway: 2)
        harness.tick()
        XCTAssertFalse(harness.core.isHalted)
        XCTAssertEqual(harness.events.filter { $0 == .shutdownAcknowledged }.count, 1)
        XCTAssertFalse(harness.events.contains { if case .internalError = $0 { return true } else { return false } })
        XCTAssertTrue(harness.core.hasEnded)
    }

    // MARK: M2

    /// More input than the window when the shutdown starts, and an ack for an earlier state
    /// during it: the shutdown state keeps the content it was first sent with.
    func testShutdownStateDoesNotMoveWithTheInputWindow() {
        for limit in [2, 4] {
            var harness = Harness(configuration: Harness.configuration(limit: limit))
            harness.connectAndSettle()
            harness.type("abcdefghij")
            let first = harness.advanceToWakeup()
            XCTAssertEqual(first.first?.newNum, 3)
            XCTAssertEqual(keystrokes(first.first?.input ?? []).count, limit)
            XCTAssertTrue(harness.core.startShutdown(now: harness.now))
            var sent = harness.tick()
            sent += harness.advance(30)
            // The server acknowledges the state before the shutdown state: the window's front moves.
            harness.deliver(old: 2, new: 3, ack: 3, throwaway: 2)
            for _ in 0..<600 where harness.lastWakeup != nil || sent.count < 3 {
                sent += harness.advance(20)
            }
            XCTAssertFalse(harness.core.isHalted, "limit \(limit): \(harness.events)")
            XCTAssertTrue(harness.events.contains(.shutdownTimedOut), "limit \(limit): \(harness.events)")
            XCTAssertTrue(harness.core.hasEnded)
            // Content of the shutdown state = content of the base + the diff: always the first
            // `limit` bytes.
            let all = Array("abcdefghij".utf8)
            for instruction in sent {
                XCTAssertEqual(instruction.newNum, Instruction.shutdownNum)
                let base = instruction.oldNum == 3 ? Array(all.prefix(limit)) : []
                XCTAssertEqual(base + keystrokes(instruction.input), Array(all.prefix(limit)),
                               "limit \(limit), base \(instruction.oldNum)")
            }
            XCTAssertTrue(sent.contains { $0.oldNum == 3 }, "the run covers sends after the ack")
        }
    }

    // MARK: M3

    /// Disconnect while quiesced, then back in the foreground after more than 10 s: the server
    /// is told, with the full 10 s and 16 tries.
    func testShutdownAskedWhileQuiescedIsSentAfterResume() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.core.quiesce()
        XCTAssertTrue(harness.core.startShutdown(now: harness.now))
        XCTAssertTrue(harness.tick().isEmpty)
        harness.now += 60_000
        harness.core.unquiesce(now: harness.now)
        let resumedAt = harness.now
        var sent = harness.tick()
        XCTAssertEqual(sent.first?.newNum, Instruction.shutdownNum, "\(harness.events)")
        XCTAssertFalse(harness.core.hasEnded)
        XCTAssertFalse(harness.events.contains(.shutdownTimedOut))
        while harness.lastWakeup != nil, harness.now < resumedAt + 20_000 {
            sent += harness.advanceToWakeup()
        }
        XCTAssertEqual(sent.count, TransportConstants.shutdownRetries)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
    }

    /// Disconnect, one send, then the app is suspended for 11 s: the shutdown goes on afterwards.
    func testShutdownClockDoesNotRunWhileQuiesced() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500
        XCTAssertTrue(harness.core.startShutdown(now: harness.now))
        XCTAssertEqual(harness.tick().count, 1)
        harness.core.quiesce()
        harness.now += 11_000
        XCTAssertTrue(harness.tick().isEmpty)
        harness.core.unquiesce(now: harness.now)
        let sent = harness.tick()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.newNum, Instruction.shutdownNum)
        XCTAssertFalse(harness.events.contains(.shutdownTimedOut))
        XCTAssertFalse(harness.core.hasEnded)
        // The tries made before the quiesce still count: 14 more, 16 in all.
        var more = 0
        let resumedAt = harness.now
        while harness.lastWakeup != nil, harness.now < resumedAt + 20_000 {
            more += harness.advanceToWakeup().count
        }
        XCTAssertEqual(more, TransportConstants.shutdownRetries - 2)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
    }

    /// `startShutdown` says whether a shutdown is running; false means no outcome event follows.
    func testStartShutdownReportsWhetherAnOutcomeFollows() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 5
        harness.deliver(old: 2, new: Instruction.shutdownNum, ack: 2, throwaway: 2)
        harness.tick()
        XCTAssertTrue(harness.core.serverHasShutDown)
        XCTAssertFalse(harness.core.startShutdown(now: harness.now), "the server has shut down: nothing to ask for")
        XCTAssertFalse(harness.core.isShuttingDown)

        var second = Harness()
        second.connectAndSettle()
        second.now += 500
        XCTAssertTrue(second.core.startShutdown(now: second.now))
        XCTAssertTrue(second.core.startShutdown(now: second.now), "already running: the outcome is still to come")
        second.tick()
        second.now += 5
        second.deliver(old: 2, new: 3, ack: UInt64.max, throwaway: 2)
        second.tick()
        XCTAssertTrue(second.core.hasEnded)
        XCTAssertFalse(second.core.startShutdown(now: second.now), "over: no further event")
    }

    private func keystrokes(_ input: [UserInstruction]) -> [UInt8] {
        input.flatMap { instruction -> [UInt8] in
            if case .keystroke(let bytes) = instruction { return bytes }
            return []
        }
    }
}
