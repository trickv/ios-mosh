import MoshResume

/// What leaving the terminal screen does with its session (docs/notes/multi-session/DESIGN.md 5.3).
///
/// `viewDidDisappear` with `isMovingFromParent` first does what every leave does (the bootstrap
/// cancelled, timers and watchers stopped), then asks this one pure decision what becomes of the
/// session. Leaving ends a session only when "End Session" asked for it.
///
/// Step 8b: nothing calls it yet; step 9 wires it into the leave (and its hostile review reads it).
enum LeaveAction: Equatable {
    /// Save, then close (2.3): the session stays, parked (B1, B5, B7, B8).
    case park
    /// Nothing is in the slot and no old record waits: the bootstrap is cancelled (B2, E2).
    case cancelStart
    /// A fallback was still connecting and he went back: the attempt is cancelled, "last looked
    /// at" is cleared for the old session, and the old, dirty record is kept, listed as "Could
    /// not be resumed" (B3, step 11b).
    case keepOldRecord
    /// The server had ended the session: `finish(c, .forget)`, close and forget (B4).
    case finishForget
    /// "End Session" on an attached session: today's `end` (shutdown) in a `BackgroundTask`
    /// (E1, E4).
    case shutdown
    /// "End Session" on a coordinator that was never attached (a resumed screen left before
    /// `attach`): `close()` and nothing else, the record stays as it was (C11). `shutdown()`
    /// would mark a clean session that never started "ended" (RC:647-663).
    case closeOnly
    /// "End Session" while a fallback was still connecting: the old record's end (E3): a run-time
    /// fallback's `abandon()` awaited, the old server stopped over SSH, the record forgotten only
    /// by `afterStop` (step 11b).
    case endDuringFallback

    /// The table of 5.3.
    ///
    /// - `endRequested`: the "End Session" alert was confirmed before the pop.
    /// - `slotFilled`: the screen's slot holds a coordinator (`SessionQueue.held`), attached or not.
    /// - `attached`: `attach` has run for it (`SessionQueue.isAttached`); read only when the slot
    ///   is filled.
    /// - `serverEnded`: the server ended the session (`.serverEnded`); read only when the slot is
    ///   filled.
    /// - `fallbackInFlight`: a fallback's new session is still connecting (an old record is set
    ///   and nothing is in the slot); read only when the slot is empty.
    ///
    /// The slot decides first and is never taken from `attached`: a resumed coordinator is in the
    /// slot from `init`, before `attach`, and must be parked (or, with an end requested, closed),
    /// never left to a cancelled start that would not release its lock.
    static func decide(endRequested: Bool, slotFilled: Bool, attached: Bool, serverEnded: Bool,
                       fallbackInFlight: Bool) -> LeaveAction {
        if slotFilled {
            // The server's end wins, whether an end was requested or not: there is no shutdown
            // to ask for. (`serverEnded` is set only by the events of an attached session.)
            if serverEnded { return .finishForget }
            guard endRequested else { return .park }
            return attached ? .shutdown : .closeOnly
        }
        guard fallbackInFlight else { return .cancelStart }
        return endRequested ? .endDuringFallback : .keepOldRecord
    }

    /// The ids whose "last looked at" a confirmed "End Session" clears, in the alert's action and
    /// before the pop (DESIGN.md 2.5, 5.2; E1, E3, E4): the slot's session (attached or not) and
    /// the old session of a fallback that is still connecting. So a session he ended never starts
    /// anything at the next launch, whatever interrupts the ending.
    static func idsToClear(slot: SessionID?, old: SessionID?) -> [SessionID] {
        [slot, old].compactMap { $0 }
    }

    /// What becomes of a record after the app tried to stop its server over SSH
    /// (`SessionLauncher.stopOldServer`), when mosh's own shutdown could not end it: `end`'s
    /// refused branch (E4) and the old record of a fallback ended while it was connecting (E3).
    enum AfterStop: Equatable {
        /// Delete the record, its key and its link: the server is stopped or provably gone, or
        /// the record cannot help to stop it.
        case forget
        /// Keep the record as its files say (without the dot): it alone holds the server's pid
        /// and start time for a later identity-checked kill (from its row, R2).
        case keep
    }

    /// DESIGN.md 5.3, review LC-14: forget only when `OldServerOutcome.mayForget` (LA:238-244), as
    /// the row's End Session does (R2). A host that was not reached, an answer that cannot be
    /// used, or "not there" from another address says nothing about the server, which may still
    /// run: the record is kept. Before step 11b both callers forgot whatever the answer.
    static func afterStop(_ outcome: OldServerOutcome) -> AfterStop {
        outcome.mayForget ? .forget : .keep
    }
}

/// The gate of an open (docs/notes/multi-session/DESIGN.md 2.4 G3, 3.1 H5, 4.5; step 10): asked
/// after the settle (`SessionActivity.settled()`), in the same main-actor turn as the cold start
/// and the push. A resign that fell into the settle reached no terminal screen (the scene's save
/// goes to `TerminalViewController.current` only), so a screen made then would start its session
/// unsaved; and a screen pushed over another one, or under an alert, is not what was tapped.
enum OpenGate {
    /// Whether the tap may go on now: the scene is in the foreground and active, the host list
    /// is the top screen with nothing presented over it, and no terminal screen is open (one
    /// that has not been left: `TerminalViewController.current`). Otherwise the tap is dropped:
    /// nothing was opened, so nothing is undone.
    static func mayOpen(sceneIsActive: Bool, listIsOnTop: Bool, terminalIsOpen: Bool) -> Bool {
        sceneIsActive && listIsOnTop && !terminalIsOpen
    }
}

/// What the park does after each answer of the save (docs/notes/multi-session/DESIGN.md 2.3,
/// steps 2 and 4).
///
/// The park calls `enterBackground()`, reads `recordState`, and asks `after`. `saveAgain` means:
/// wait, call `enterBackground()` once more, read the state again and ask again with `attempt` 2;
/// that answer is final. Otherwise the park closes the coordinator and, for `closeAndForget`
/// only, forgets the record.
///
/// Step 8b: nothing calls it yet; step 9's park does.
enum ParkPlan: Equatable {
    /// The save did not leave the record clean (`.failed`, `.datagramSentSinceExport`): wait, then
    /// save once more. The second call saves again because the first left `savedClean` false
    /// (RC:498-507, 544).
    case saveAgain(after: Duration)
    /// Close; the record stays as its files say (resumable after a clean save, "Could not be
    /// resumed" after two failed ones or a session given up).
    case closeAndKeep
    /// Close, then `SessionFiles.forget`: the server ended the session during the leave (as B4).
    case closeAndForget
    /// `.notResumable(.closed)`: the event task's `finish` closed and forgot it first. Nothing
    /// more to do.
    case alreadyClosed

    /// The wait before the second save.
    static let secondSaveDelay: Duration = .milliseconds(300)

    /// The step after a save that answered `outcome`, with the record in `state` afterwards.
    /// `attempt` is 1 for the first save and 2 for the one after `secondSaveDelay`.
    ///
    /// **A record is forgotten only when the save says the session is over and the record says
    /// "ended".** The same answer with a dirty record is a session that was given up (lost base
    /// state, halted: RC:98-99, 572-579), which is kept as "Could not be resumed".
    ///
    /// Every case of `NotSavedReason` is named, with no `default`, so that a new one is a compile
    /// error here and what the park does with it is decided, not inherited.
    static func after(_ outcome: SaveOutcome, state: RecordState, attempt: Int) -> ParkPlan {
        switch outcome {
        case .clean:
            return .closeAndKeep
        case .notResumable(.closed):
            return .alreadyClosed
        case .notResumable(.ended):
            return state == .ended ? .closeAndForget : .closeAndKeep
        case .notResumable(.failed), .notResumable(.datagramSentSinceExport):
            return attempt < 2 ? .saveAgain(after: secondSaveDelay) : .closeAndKeep
        }
    }
}
