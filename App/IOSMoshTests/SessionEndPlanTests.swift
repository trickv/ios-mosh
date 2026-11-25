import MoshBootstrap
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import IOSMosh

/// docs/notes/multi-session/DESIGN.md section 6, step 12: the decisions of "End Session" on a
/// parked row, without a server (`SessionEndPlan.next`: phase and input give the next step).
final class SessionEndPlanTests: XCTestCase {
    private typealias Plan = SessionEndPlan

    private func next(_ phase: Plan.Phase, _ input: Plan.Input, identity: Bool = false) -> Plan.Step {
        Plan.next(phase, input, canAskOverSSH: identity)
    }

    private func screen(live: Bool) -> SessionEvent {
        .screen(ScreenUpdate(number: 1, state: TerminalState(width: 80, height: 24), isLive: live))
    }

    private let contact = SessionEvent.contact(ContactAges(sinceNewestRemoteState: 0, sinceAcknowledgedStateSent: 0,
                                                           sinceLastAuthenticDatagram: nil))

    /// Events that are no proof of the server and end nothing.
    private var undecided: [SessionEvent] {
        [
            screen(live: false), .gateFailed("x"), .networkProblem("x"), .protocolProblem("x"),
            .noServerReply(.udpBlocked(port: 60001)), .clipboard(.write(text: "x", byteCount: 1)),
            .instructionApplied(AppliedInstruction(oldNum: 0, newNum: 1, diff: [])),
            .display(DisplayFrame(serial: 1, number: 1, framebuffer: Framebuffer(width: 80, height: 24), hasPredictions: false)),
        ]
    }

    /// Contact, then the shutdown; no contact, with and without an identity; acknowledged; not
    /// acknowledged; the server's own end; a lost base state; "try again later" keeps.
    /// Control: the shutdown without contact (`.started` answered by `.shutdown`).
    func testTheEndPlan() {
        // Contact, then the shutdown. c: a resumed record is started (d), then the contact wait
        // (e): the stored screen and what else comes are no proof; a contact or a live screen is,
        // and only then is the one try spent.
        XCTAssertEqual(next(.coldStart, .resumed), .start)
        XCTAssertEqual(next(.starting, .started), .waitForContact, "no shutdown before the server has shown it is there")
        for event in undecided {
            XCTAssertEqual(next(.waitingForContact, .event(event)), .keepWaiting, "no proof: \(Plan.Input.event(event).brief)")
            XCTAssertEqual(next(.waitingForContact, .event(event), identity: true), .keepWaiting)
        }
        XCTAssertEqual(next(.waitingForContact, .event(contact)), .shutdown, "a contact is proof")
        XCTAssertEqual(next(.waitingForContact, .event(screen(live: true))), .shutdown, "a live screen is proof")
        XCTAssertEqual(next(.waitingForContact, .shutdownAnswered(true)), .keepWaiting, "not an input of the contact wait")

        // No contact in 10 s: the ordinary save and the close; then the SSH way only with a saved
        // host and a known identity, otherwise kept: never "nobody to ask, so forget".
        XCTAssertEqual(next(.waitingForContact, .timedOut, identity: true), .saveThenStopOverSSH)
        XCTAssertEqual(next(.waitingForContact, .timedOut, identity: false), .saveAndKeep)

        // Acknowledged: close and forget. After the request, nothing else asks for a second one.
        XCTAssertEqual(next(.shuttingDown, .event(.shutdownFinished(acknowledged: true))), .closeAndForget)
        XCTAssertEqual(next(.shuttingDown, .shutdownAnswered(true)), .keepWaiting)
        XCTAssertEqual(next(.shuttingDown, .event(contact)), .keepWaiting, "one try only")
        XCTAssertEqual(next(.shuttingDown, .event(screen(live: true))), .keepWaiting, "one try only")
        for event in undecided {
            XCTAssertEqual(next(.shuttingDown, .event(event)), .keepWaiting, Plan.Input.event(event).brief)
        }

        // Not acknowledged (16 sends or 10 s), or no end in 11 s: the record is "ended": close,
        // then the SSH way.
        XCTAssertEqual(next(.shuttingDown, .event(.shutdownFinished(acknowledged: false))), .closeThenStopOverSSH)
        XCTAssertEqual(next(.shuttingDown, .timedOut), .closeThenStopOverSSH)
        XCTAssertEqual(next(.shuttingDown, .timedOut, identity: true), .closeThenStopOverSSH)

        // The server's own end: during the contact wait it begins the wait for its
        // acknowledgment, without a request; refused (already over) waits the same way.
        XCTAssertEqual(next(.waitingForContact, .event(.serverEnded(nil))), .waitForTheEnd)
        XCTAssertEqual(next(.shuttingDown, .event(.serverEnded(nil))), .keepWaiting)
        XCTAssertEqual(next(.shuttingDown, .shutdownAnswered(false)), .keepWaiting)
        XCTAssertEqual(next(.shuttingDown, .event(.serverEndAcknowledged)), .closeAndForget)
        XCTAssertEqual(next(.waitingForContact, .event(.serverEndAcknowledged)), .closeAndForget)

        // A lost base state, or a halted transport: the coordinator gave the record up (dirty):
        // close, then the SSH way, in either phase.
        for event: SessionEvent in [.baseStateLost(serverBase: 3), .halted("x")] {
            XCTAssertEqual(next(.waitingForContact, .event(event)), .closeThenStopOverSSH, Plan.Input.event(event).brief)
            XCTAssertEqual(next(.shuttingDown, .event(event)), .closeThenStopOverSSH, Plan.Input.event(event).brief)
        }

        // "Try again later" keeps, and forgets nothing (an unreadable row ends here, R4); a start
        // that failed keeps; a record that is not resumable after all goes the SSH way; a
        // directory that is not a record is forgotten.
        XCTAssertEqual(next(.coldStart, .cannotOpenNow("storage: locked")), .keep("storage: locked"))
        XCTAssertEqual(next(.coldStart, .cannotOpenNow("the record is in use")), .keep("the record is in use"))
        XCTAssertEqual(next(.starting, .startFailed("disk full")), .closeAndKeep("disk full"))
        XCTAssertEqual(next(.coldStart, .notResumable), .stopOverSSH)
        XCTAssertEqual(next(.coldStart, .notARecord), .forget)

        // The way by the row's state (3.4): a parked row through mosh, a dead or ended one the
        // SSH way, and nothing for a row that offers no "End Session" (R6).
        XCTAssertEqual(Plan.way(for: .resumable), .mosh)
        XCTAssertEqual(Plan.way(for: .unreadable), .mosh)
        XCTAssertEqual(Plan.way(for: .dead), .ssh)
        XCTAssertEqual(Plan.way(for: .ended), .ssh)
        XCTAssertNil(Plan.way(for: .live))
        XCTAssertNil(Plan.way(for: .ending))
        XCTAssertNil(Plan.way(for: .parking))
    }
}
