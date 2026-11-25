import MoshBootstrap
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import IOSMosh

/// Review M6-4: which end of a session may remove its record (and with it the only copy of the
/// server's pid and start time).
final class SessionEndingTests: XCTestCase {
    func testAnAcknowledgedShutdownForgetsTheSession() {
        XCTAssertEqual(SessionEnding.after(.shutdownFinished(acknowledged: true)), .forget)
    }

    func testTheServersOwnEndForgetsTheSessionOnceAcknowledged() {
        XCTAssertEqual(SessionEnding.after(.serverEndAcknowledged), .forget)
        // The end itself only announces it; the acknowledgment follows.
        XCTAssertNil(SessionEnding.after(.serverEnded(nil)))
    }

    /// 16 shutdown sends without an answer (or 10 s): the server may still run, so the "ended"
    /// record stays for the identity-checked kill.
    func testAShutdownThatTimedOutKeepsTheEndedRecord() {
        XCTAssertEqual(SessionEnding.after(.shutdownFinished(acknowledged: false)), .keepEnded)
    }

    func testOtherEventsDoNotEndTheSession() {
        let events: [SessionEvent] = [
            .baseStateLost(serverBase: 3), .halted("x"), .gateFailed("x"), .networkProblem("x"),
            .protocolProblem("x"), .noServerReply(.udpBlocked(port: 60001)),
            .screen(ScreenUpdate(number: 1, state: TerminalState(width: 80, height: 24), isLive: true)),
            .contact(ContactAges(sinceNewestRemoteState: 0, sinceAcknowledgedStateSent: 0, sinceLastAuthenticDatagram: nil)),
            .clipboard(.write(text: "x", byteCount: 1)), .clipboard(.invalid(.truncated)),
            .display(DisplayFrame(serial: 1, number: 1, framebuffer: Framebuffer(width: 80, height: 24), hasPredictions: false)),
            .instructionApplied(AppliedInstruction(oldNum: 0, newNum: 1, diff: [])),
        ]
        for event in events {
            XCTAssertNil(SessionEnding.after(event), "\(event)")
        }
    }

    /// The marks UI tests wait for: one per outcome, and the two `notThere` cases apart.
    func testOldServerOutcomesHaveDistinctIdentifiers() {
        let outcomes: [OldServerOutcome] = [
            .nothingToAsk, .killed, .notThere(atSessionAddress: true), .notThere(atSessionAddress: false),
            .hostNotReached, .notAnswered,
        ]
        XCTAssertEqual(Set(outcomes.map(\.identifier)).count, outcomes.count)
        XCTAssertEqual(OldServerOutcome.killed.identifier, "killed")
    }
}
