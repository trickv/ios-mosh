import MoshSession

/// What an event that ends a session leaves of its record (review M6-4).
///
/// The record of an ended session is the only place that holds its server's pid and start time,
/// which the identity-checked kill needs (`SessionLauncher.stopOldServer`). So it is removed only
/// when the server is known to be gone:
///
/// - `.shutdownFinished(acknowledged: true)`: the server acknowledged our shutdown and exits.
/// - `.serverEndAcknowledged`: the server ended the session itself and has our acknowledgment.
///
/// `.shutdownFinished(acknowledged: false)` means mosh gave up (16 sends without an answer, or
/// 10 s): the request may never have reached the server, which then runs on with no timeout of
/// its own (docs/RESUME.md). The session is closed and its "ended" record kept, for the kill at
/// the next launch (`SceneDelegate.finishEndedSessions`) or by "End Session" on the host list.
enum SessionEnding: Equatable {
    /// Close, then remove record, key and link (`SessionFiles.forget`).
    case forget
    /// Close only; the record stays "ended".
    case keepEnded

    /// What to do after `event`; nil for an event that does not end the session.
    ///
    /// Every case is named, with no `default`, so that a new `SessionEvent` is a compile error
    /// here and its effect on the record is decided, not inherited.
    static func after(_ event: SessionEvent) -> SessionEnding? {
        switch event {
        case .shutdownFinished(acknowledged: true), .serverEndAcknowledged:
            return .forget
        case .shutdownFinished(acknowledged: false):
            return .keepEnded
        case .screen, .contact, .clipboard, .serverEnded, .baseStateLost, .halted, .gateFailed,
             .networkProblem, .protocolProblem, .noServerReply, .instructionApplied, .display:
            return nil
        }
    }
}
