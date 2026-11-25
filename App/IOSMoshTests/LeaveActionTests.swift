import MoshResume
import XCTest
@testable import IOSMosh

/// The leave decisions as pure functions (docs/notes/multi-session/DESIGN.md section 9, step 8b):
/// `LeaveAction.decide` (5.3) and `ParkPlan.after` (2.3 steps 2 and 4); from step 11b also
/// `LeaveAction.afterStop` (5.3) and `LeaveAction.idsToClear` (5.2).
final class LeaveActionTests: XCTestCase {
    /// One row of the table of 5.3; nil is "—" or "either": the row holds for both values.
    private struct Row {
        let endRequested: Bool?
        let slotFilled: Bool
        let attached: Bool?
        let serverEnded: Bool?
        let fallbackInFlight: Bool?
        let action: LeaveAction
        let cases: String

        func matches(_ input: Input) -> Bool {
            (endRequested ?? input.endRequested) == input.endRequested
                && slotFilled == input.slotFilled
                && (attached ?? input.attached) == input.attached
                && (serverEnded ?? input.serverEnded) == input.serverEnded
                && (fallbackInFlight ?? input.fallbackInFlight) == input.fallbackInFlight
        }
    }

    private struct Input: CustomStringConvertible {
        let endRequested, slotFilled, attached, serverEnded, fallbackInFlight: Bool

        var description: String {
            "endRequested \(endRequested), slotFilled \(slotFilled), attached \(attached), "
                + "serverEnded \(serverEnded), fallbackInFlight \(fallbackInFlight)"
        }

        var decided: LeaveAction {
            LeaveAction.decide(endRequested: endRequested, slotFilled: slotFilled, attached: attached,
                               serverEnded: serverEnded, fallbackInFlight: fallbackInFlight)
        }
    }

    /// The table of 5.3, row by row. "Slot filled: yes" covers attached and not attached unless
    /// the row says "attached" or "not attached"; with the slot empty, `attached` and
    /// `serverEnded` mean nothing ("—").
    private let table: [Row] = [
        Row(endRequested: false, slotFilled: true, attached: nil, serverEnded: false, fallbackInFlight: nil,
            action: .park, cases: "B1, B5, B7, B8"),
        Row(endRequested: false, slotFilled: false, attached: nil, serverEnded: nil, fallbackInFlight: false,
            action: .cancelStart, cases: "B2"),
        Row(endRequested: false, slotFilled: false, attached: nil, serverEnded: nil, fallbackInFlight: true,
            action: .keepOldRecord, cases: "B3"),
        Row(endRequested: nil, slotFilled: true, attached: nil, serverEnded: true, fallbackInFlight: nil,
            action: .finishForget, cases: "B4"),
        Row(endRequested: true, slotFilled: true, attached: true, serverEnded: false, fallbackInFlight: nil,
            action: .shutdown, cases: "E1, E4"),
        Row(endRequested: true, slotFilled: true, attached: false, serverEnded: false, fallbackInFlight: nil,
            action: .closeOnly, cases: "E1 before attach"),
        Row(endRequested: true, slotFilled: false, attached: nil, serverEnded: nil, fallbackInFlight: false,
            action: .cancelStart, cases: "E2"),
        Row(endRequested: true, slotFilled: false, attached: nil, serverEnded: nil, fallbackInFlight: true,
            action: .endDuringFallback, cases: "E3"),
    ]

    func testTheLeaveDecisions() {
        // Every combination of the five inputs falls in exactly one row, and gets that row's action.
        let bools = [false, true]
        var combinations = 0
        for endRequested in bools {
            for slotFilled in bools {
                for attached in bools {
                    for serverEnded in bools {
                        for fallbackInFlight in bools {
                            let input = Input(endRequested: endRequested, slotFilled: slotFilled,
                                              attached: attached, serverEnded: serverEnded,
                                              fallbackInFlight: fallbackInFlight)
                            combinations += 1
                            let rows = table.filter { $0.matches(input) }
                            XCTAssertEqual(rows.count, 1, "the table has one row for \(input)")
                            guard let row = rows.first else { continue }
                            XCTAssertEqual(input.decided, row.action, "\(row.cases): \(input)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combinations, 32)

        // A resumed coordinator is in the slot from `init`, before `attach`: a back parks it
        // (B7: `.clean`, nothing written, the lock released), and "End Session" closes it and
        // nothing else. Neither leaves it to a cancelled start that would not close it.
        for fallbackInFlight in bools {
            XCTAssertEqual(
                LeaveAction.decide(endRequested: false, slotFilled: true, attached: false,
                                   serverEnded: false, fallbackInFlight: fallbackInFlight),
                .park, "a back on a resumed screen before attach parks it")
            XCTAssertEqual(
                LeaveAction.decide(endRequested: true, slotFilled: true, attached: false,
                                   serverEnded: false, fallbackInFlight: fallbackInFlight),
                .closeOnly, "End Session on a resumed screen before attach closes it only")
        }
    }

    func testOnlyAnEndedRecordIsForgottenByThePark() {
        let clean = RecordState.clean(snapshotID: 7)
        let failed = SaveOutcome.notResumable(.failed("disk full"))
        let sentSinceExport = SaveOutcome.notResumable(.datagramSentSinceExport)

        // `.clean`: on to the close; the record is kept, resumable.
        XCTAssertEqual(ParkPlan.after(.clean, state: clean, attempt: 1), .closeAndKeep)
        XCTAssertEqual(ParkPlan.after(.clean, state: clean, attempt: 2), .closeAndKeep,
                       "the second save answered clean")

        // `.ended`: forgotten only with the record in state "ended" (the server ended the session
        // during the leave, as B4). With a dirty record the session was given up: kept.
        for attempt in [1, 2] {
            XCTAssertEqual(ParkPlan.after(.notResumable(.ended), state: .ended, attempt: attempt),
                           .closeAndForget, "the server's end during the leave, save \(attempt)")
            XCTAssertEqual(ParkPlan.after(.notResumable(.ended), state: .dirty, attempt: attempt),
                           .closeAndKeep, "a session given up is kept, save \(attempt)")
            XCTAssertEqual(ParkPlan.after(.notResumable(.ended), state: clean, attempt: attempt),
                           .closeAndKeep, "only an ended record is forgotten, save \(attempt)")
        }

        // `.closed`: the event task closed and forgot it first; nothing more.
        for state in [clean, RecordState.dirty, .ended] {
            XCTAssertEqual(ParkPlan.after(.notResumable(.closed), state: state, attempt: 1), .alreadyClosed)
            XCTAssertEqual(ParkPlan.after(.notResumable(.closed), state: state, attempt: 2), .alreadyClosed)
        }

        // `.failed` and `.datagramSentSinceExport`: once more after 300 ms, then final.
        for outcome in [failed, sentSinceExport] {
            for state in [clean, RecordState.dirty] {
                XCTAssertEqual(ParkPlan.after(outcome, state: state, attempt: 1),
                               .saveAgain(after: .milliseconds(300)), "\(outcome): saved once more")
                XCTAssertEqual(ParkPlan.after(outcome, state: state, attempt: 2), .closeAndKeep,
                               "\(outcome): the second answer is final, the record kept as its files say")
            }
        }
        XCTAssertEqual(ParkPlan.secondSaveDelay, .milliseconds(300))

        // Nothing but an ended record is ever forgotten, whatever the answer or the attempt.
        let outcomes: [SaveOutcome] = [.clean, .notResumable(.ended), .notResumable(.closed), failed, sentSinceExport]
        for outcome in outcomes {
            for state in [clean, RecordState.dirty, .ended] {
                for attempt in [1, 2] where ParkPlan.after(outcome, state: state, attempt: attempt) == .closeAndForget {
                    XCTAssertEqual(state, .ended, "\(outcome) forgot a record in state \(state)")
                    XCTAssertEqual(outcome, .notResumable(.ended), "\(outcome) forgot a record")
                }
            }
        }
    }

    /// Step 11b, review LC-14 (DESIGN.md 5.3, 3.3 E3 and E4): after the SSH stop of a server that
    /// mosh's shutdown could not end, the record is kept unless the answer says the server is
    /// stopped, provably gone, or cannot be asked by anyone. `end`'s refused branch and
    /// `endDuringFallback` decide by this one function (`TerminalViewController`; shown there by
    /// grep, since this test is pure).
    func testAStopThatDidNotReachTheHostKeepsTheRecord() {
        // Kept: the server may still run, and the record alone holds its pid and start time.
        XCTAssertEqual(LeaveAction.afterStop(.hostNotReached), .keep, "the host was not reached")
        XCTAssertEqual(LeaveAction.afterStop(.notAnswered), .keep, "logged in, but no usable answer")
        XCTAssertEqual(LeaveAction.afterStop(.notThere(atSessionAddress: false)), .keep,
                       "\"not there\" from another address says nothing about the session's server")

        // Forgotten: stopped, gone at the session's own address, or nobody to ask now or later.
        XCTAssertEqual(LeaveAction.afterStop(.killed), .forget, "the server was killed")
        XCTAssertEqual(LeaveAction.afterStop(.nothingToAsk), .forget, "no saved host or no pid: nothing to keep it for")
        XCTAssertEqual(LeaveAction.afterStop(.notThere(atSessionAddress: true)), .forget,
                       "the server is gone at the session's address")

        // The same rule as the row's End Session (R2): `mayForget`, for every outcome.
        let outcomes: [OldServerOutcome] = [.nothingToAsk, .killed, .notThere(atSessionAddress: true),
                                            .notThere(atSessionAddress: false), .hostNotReached, .notAnswered]
        for outcome in outcomes {
            XCTAssertEqual(LeaveAction.afterStop(outcome) == .forget, outcome.mayForget, "\(outcome)")
        }
    }

    /// Step 11b (DESIGN.md 5.2): a confirmed "End Session" clears "last looked at" for the slot's
    /// session and for the old session of a fallback that is still connecting, whichever there is.
    func testAnEndRequestClearsTheSessionAndTheOldOne() {
        let slot = SessionID.random(), old = SessionID.random()
        XCTAssertEqual(LeaveAction.idsToClear(slot: slot, old: nil), [slot], "the slot's session only")
        XCTAssertEqual(LeaveAction.idsToClear(slot: nil, old: old), [old], "the old session of a fallback only (E3)")
        XCTAssertEqual(Set(LeaveAction.idsToClear(slot: slot, old: old)), [slot, old],
                       "both: a fallback's new session in the slot and the old one it replaces")
        XCTAssertEqual(LeaveAction.idsToClear(slot: slot, old: old).count, 2, "each once")
        XCTAssertEqual(LeaveAction.idsToClear(slot: nil, old: nil), [], "neither: nothing to clear")
    }
}
