import Foundation
import MoshResume
import MoshSession
import UIKit

/// The decisions of "End Session" on a row of the host list (docs/notes/multi-session/DESIGN.md
/// section 6, stages c to h, and 3.4; step 12): from the phase the ender is in and what it met,
/// the next step. Pure: no coordinator, no clock, no file. `SessionEnder` does what it says.
///
/// A parked session (resumable, or unreadable now) is ended through mosh's own shutdown, which
/// needs no pid (the brief's "To confirm"; his host `hg`): the record is opened again, started,
/// and the shutdown is sent only once the server has shown that it is there (stage e), because
/// `shutdown()` marks the record "ended" before anything is sent (C7) and an ended record is never
/// resumed (R16): there is exactly one try. A dead or ended record must send nothing (C2, C4): it
/// is ended the SSH way, as before.
enum SessionEndPlan {
    /// How a row's "End Session" ends its session (DESIGN.md 3.4).
    enum Way: Equatable {
        /// Section 6: opened again and ended by mosh's shutdown (R1, R4).
        case mosh
        /// The server stopped over SSH after the identity check, then the record forgotten only
        /// when `OldServerOutcome.mayForget` says so (R2, R3; stage h).
        case ssh
    }

    /// The way for the state the row was read in (the swipe's captured session). A row that is
    /// on screen, being ended or being saved offers no "End Session" (R6): nil.
    static func way(for state: ListedSessionState) -> Way? {
        switch state {
        case .resumable, .unreadable: return .mosh
        case .dead, .ended: return .ssh
        case .live, .ending, .parking: return nil
        }
    }

    /// Where the ender is.
    enum Phase: Equatable {
        /// c: the cold start of the record (key by id, then the lock).
        case coldStart
        /// d: a reader on the events, then `start()`.
        case starting
        /// e: up to `SessionEnder.contactWait` for proof that the server is there.
        case waitingForContact
        /// g: the shutdown was asked for (or the server's own end began); up to
        /// `SessionEnder.endWait` for its end.
        case shuttingDown
    }

    /// What the ender met.
    enum Input: Equatable {
        /// c: `.resumed`.
        case resumed
        /// c: `.fallback` for a record: it was not resumable after all.
        case notResumable
        /// c: `.fallback` for a directory that is not a record (deleted, no `meta`).
        case notARecord
        /// c: `.retryLater` (an unreadable row ends here, R4), with its reason.
        case cannotOpenNow(String)
        /// d: `start()` returned.
        case started
        /// d: `start()` threw, with the error.
        case startFailed(String)
        /// e, g: an event of the session.
        case event(SessionEvent)
        /// g: `shutdown()` returned (false: refused, or the session is already over).
        case shutdownAnswered(Bool)
        /// e, g: the phase's time is up.
        case timedOut

        /// For the log: never a screen's or a clipboard's contents.
        var brief: String {
            switch self {
            case .resumed: return "resumed"
            case .notResumable: return "not resumable"
            case .notARecord: return "not a record"
            case .cannotOpenNow(let reason): return "cannot be opened now (\(reason))"
            case .started: return "started"
            case .startFailed(let reason): return "start failed (\(reason))"
            case .shutdownAnswered(let accepted): return "shutdown \(accepted ? "accepted" : "refused")"
            case .timedOut: return "timed out"
            case .event(let event):
                switch event {
                case .screen(let update): return "screen (\(update.isLive ? "live" : "stored"))"
                case .contact: return "contact"
                case .clipboard: return "clipboard"
                case .serverEnded: return "server ended"
                case .shutdownFinished(let acknowledged): return "shutdown finished (acknowledged: \(acknowledged))"
                case .baseStateLost: return "base state lost"
                case .halted: return "halted"
                case .gateFailed: return "gate failed"
                case .networkProblem: return "network problem"
                case .protocolProblem: return "protocol problem"
                case .noServerReply: return "no server reply"
                case .instructionApplied: return "instruction applied"
                case .serverEndAcknowledged: return "server end acknowledged"
                case .display: return "display"
                }
            }
        }
    }

    /// What the ender does next.
    enum Step: Equatable {
        /// d: a reader on the events, then `start()`.
        case start
        /// e: wait for proof that the server is there.
        case waitForContact
        /// g: `shutdown()`, then wait for its end.
        case shutdown
        /// The server's own end began (`.serverEnded`): wait for its acknowledgment as for the
        /// end of a shutdown, without asking for one.
        case waitForTheEnd
        /// Nothing decided by this input.
        case keepWaiting
        /// f, with a saved host and a known server identity: the ordinary save, `close()`, then
        /// h; the record stays resumable if that does not end it.
        case saveThenStopOverSSH
        /// f without (`hg`, a session without a saved host): the ordinary save, `close()`, and
        /// the session kept. Never deleted for "nobody to ask": that is right for a record that
        /// cannot be resumed and wrong for one that can.
        case saveAndKeep
        /// The server acknowledged the shutdown, or ended the session and has our
        /// acknowledgment: `close()`, `forget`, done.
        case closeAndForget
        /// The shutdown was not acknowledged, its end did not come in time, or the coordinator
        /// gave the record up: `close()` (the record is "ended", or dirty), then h.
        case closeThenStopOverSSH
        /// d: `start()` threw: `close()`, the session kept.
        case closeAndKeep(String)
        /// c: "try again later": nothing was opened, the session kept.
        case keep(String)
        /// c: not a record: `forget`.
        case forget
        /// c: not resumable after all: h, with no coordinator to close.
        case stopOverSSH
    }

    /// The next step after `input` in `phase`. `canAskOverSSH`: the session has a saved host and
    /// a known server identity (pid and start time, `SessionLauncher.serverIdentity`); read only
    /// when the contact wait is over.
    ///
    /// An input that does not belong to the phase decides nothing (`keepWaiting`).
    static func next(_ phase: Phase, _ input: Input, canAskOverSSH: Bool) -> Step {
        switch (phase, input) {
        case (.coldStart, .resumed): return .start
        case (.coldStart, .notResumable): return .stopOverSSH
        case (.coldStart, .notARecord): return .forget
        case (.coldStart, .cannotOpenNow(let reason)): return .keep(reason)
        case (.starting, .started): return .waitForContact
        case (.starting, .startFailed(let reason)): return .closeAndKeep(reason)
        case (.waitingForContact, .event(let event)): return whileWaitingForContact(event)
        case (.waitingForContact, .timedOut): return canAskOverSSH ? .saveThenStopOverSSH : .saveAndKeep
        case (.shuttingDown, .event(let event)): return whileShuttingDown(event)
        case (.shuttingDown, .shutdownAnswered): return .keepWaiting
        case (.shuttingDown, .timedOut): return .closeThenStopOverSSH
        default: return .keepWaiting
        }
    }

    /// e. Proof that the server is there: `.contact` (an authentic datagram), or a screen that
    /// just arrived (`isLive`). The stored screen a resume shows first is not proof.
    ///
    /// Every event is named, with no `default`, so that a new `SessionEvent` is a compile error
    /// here and its effect on the one try is decided, not inherited.
    private static func whileWaitingForContact(_ event: SessionEvent) -> Step {
        switch event {
        case .contact:
            return .shutdown
        case .screen(let update):
            return update.isLive ? .shutdown : .keepWaiting
        case .serverEnded:
            return .waitForTheEnd
        case .serverEndAcknowledged, .shutdownFinished:
            return over(event)
        case .baseStateLost, .halted:
            return .closeThenStopOverSSH
        case .clipboard, .gateFailed, .networkProblem, .protocolProblem, .noServerReply, .instructionApplied,
             .display:
            return .keepWaiting
        }
    }

    /// g. The end, by `SessionEnding.after` (unchanged); a coordinator that gave the record up
    /// (dirty) is closed and the server asked over SSH.
    private static func whileShuttingDown(_ event: SessionEvent) -> Step {
        switch event {
        case .serverEndAcknowledged, .shutdownFinished:
            return over(event)
        case .baseStateLost, .halted:
            return .closeThenStopOverSSH
        case .serverEnded, .contact, .screen, .clipboard, .gateFailed, .networkProblem, .protocolProblem,
             .noServerReply, .instructionApplied, .display:
            return .keepWaiting
        }
    }

    private static func over(_ event: SessionEvent) -> Step {
        switch SessionEnding.after(event) {
        case .forget?: return .closeAndForget
        case .keepEnded?: return .closeThenStopOverSSH
        case nil: return .keepWaiting
        }
    }
}

/// "End Session" on a row of the host list (docs/notes/multi-session/DESIGN.md section 6, 3.4;
/// step 12), in a background task of its own, the record "ending" (`SessionActivity`) until it
/// returns.
///
/// - a. "Last looked at" is cleared if it names the session, and the launch's wait for it is
///   dropped, before anything else: from here on a death of the process leaves a row, never a
///   launch that starts a session by itself (2.5).
/// - For a parked row (`SessionEndPlan.Way.mosh`): b. the settle (G2); c. the cold start, through
///   `SessionLauncher.coldStart(root:id:keys:options:)` (key by id, then the lock; G1); d. a reader
///   on the events, then `start()` (`shutdown()` is accepted before it, but then nothing reads the
///   server's answer); e. up to 10 s for proof that the server is there; g. `shutdown()` and up to
///   11 s for its end; f. no proof: the ordinary save and `close()`, then h with a saved host and
///   a known identity, otherwise kept. Each decision is `SessionEndPlan.next`.
/// - h. For a dead or ended row, and where the plan says so: the SSH way
///   (`SessionLauncher.stopOldServer`), then `forget` only when `mayForget`.
@MainActor
enum SessionEnder {
    /// What the list shows afterwards: nothing (the row goes or reads as its files say), or
    /// "Session Not Ended" with the reason.
    enum Outcome: Equatable {
        case ended
        case notEnded(String)
    }

    /// e: mosh's own patience for a shutdown (`ACTIVE_RETRY_TIMEOUT`, transportsender.h:57).
    static let contactWait: Duration = .seconds(10)
    /// g: as the terminal's end waits for the end of its shutdown (`TerminalViewController.end`).
    static let endWait: Duration = .seconds(11)

    /// Begins the end of `id` and returns its task; `finished` is called on the main actor with
    /// the outcome, after the record stopped reading "ending". `meta`: the row's, for the SSH way
    /// of a dead or ended row; `hostName` for the messages.
    @discardableResult
    static func end(id: SessionID, meta: SessionMeta?, host: SavedHost?, hostName: String, way: SessionEndPlan.Way,
                    finished: @escaping @MainActor (Outcome) -> Void) -> Task<Void, Never> {
        let activity = SessionActivity.shared
        let task = BackgroundTask(name: "end session from its row")
        activity.beginEnd(id)
        // a.
        SessionFiles.clearLastLookedAt(ifNamed: id)
        activity.dropWait(for: id)
        DebugLog.shared.log("end session \(id): begun (\(way == .mosh ? "through mosh" : "over SSH"))")
        return Task { @MainActor in
            let outcome: Outcome
            switch way {
            case .mosh:
                outcome = await throughMosh(id, host: host, hostName: hostName, activity: activity)
            case .ssh:
                outcome = await overSSH(id, meta: meta, host: host, hostName: hostName)
            }
            DebugLog.shared.log("end session \(id): \(outcome)")
            // Whether or not the list is still there: the mark is the process's.
            activity.endFinished(id)
            task.end()
            finished(outcome)
        }
    }

    /// Section 6, b to h.
    private static func throughMosh(_ id: SessionID, host: SavedHost?, hostName: String,
                                    activity: SessionActivity) async -> Outcome {
        // b.
        await activity.settled()
        // c.
        let root = SessionFiles.root
        let decision = SessionLauncher.coldStart(root: root, id: id, keys: .shared,
                                                 options: SessionLauncher.coldStartOptions(root: root, id: id))
        let input: SessionEndPlan.Input
        var fallbackMeta: SessionMeta?
        var resumed: ResumeCoordinator?
        switch decision {
        case .resumed(let coordinator):
            resumed = coordinator
            input = .resumed
        case .fallback(let fallback):
            fallbackMeta = fallback.meta
            input = fallback.recordDeleted && fallback.meta == nil ? .notARecord : .notResumable
        case .retryLater(let reason):
            input = .cannotOpenNow(reason)
        case .nothing:
            // Not an answer for one record (the cold start of an id never gives it).
            input = .cannotOpenNow("no answer for this session")
        }
        let first = SessionEndPlan.next(.coldStart, input, canAskOverSSH: false)
        log(id, .coldStart, input, first)
        switch first {
        case .forget:
            SessionFiles.forget(id)
            return .ended
        case .keep(let reason):
            return .notEnded("It cannot be opened now (\(reason)). The session is kept; try again later, or use Forget.")
        case .stopOverSSH:
            return await overSSH(id, meta: fallbackMeta, host: host, hostName: hostName)
        default:
            break
        }
        guard let coordinator = resumed else { return .notEnded("The session was not opened.") }
        return await endResumed(coordinator, host: host, hostName: hostName)
    }

    /// What the ender's loop reads: the session's events, the answer of `shutdown()`, and the
    /// time-outs of a phase (a late one of an earlier phase is dropped).
    private enum Feed {
        case input(SessionEndPlan.Input)
        case timeUp(SessionEndPlan.Phase)
    }

    /// d to g, then f or h, for a coordinator this ender holds; it is closed before this returns.
    private static func endResumed(_ coordinator: ResumeCoordinator, host: SavedHost?,
                                   hostName: String) async -> Outcome {
        let id = coordinator.id
        let canAskOverSSH = host != nil && SessionLauncher.serverIdentity(coordinator.meta) != nil
        let (feed, feeder) = AsyncStream<Feed>.makeStream(bufferingPolicy: .unbounded)
        // d. The reader first: without it nobody reads the server's answer.
        let events = coordinator.events
        let reader = Task {
            for await event in events { feeder.yield(.input(.event(event))) }
        }
        var timer: Task<Void, Never>?
        defer {
            timer?.cancel()
            reader.cancel()
            feeder.finish()
        }
        func arm(_ phase: SessionEndPlan.Phase, _ limit: Duration) {
            timer?.cancel()
            timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                feeder.yield(.timeUp(phase))
            }
        }

        var phase = SessionEndPlan.Phase.starting
        let started: SessionEndPlan.Input
        do {
            try await coordinator.start()
            started = .started
        } catch {
            started = .startFailed("\(error)")
        }
        var step = SessionEndPlan.next(phase, started, canAskOverSSH: canAskOverSSH)
        log(id, phase, started, step)
        var iterator = feed.makeAsyncIterator()
        while true {
            switch step {
            case .waitForContact:
                phase = .waitingForContact
                arm(phase, contactWait)
            case .shutdown:
                // g. The one try: the record is "ended" from here on.
                phase = .shuttingDown
                arm(phase, endWait)
                let accepted = await coordinator.shutdown()
                feeder.yield(.input(.shutdownAnswered(accepted)))
            case .waitForTheEnd:
                phase = .shuttingDown
                arm(phase, endWait)
            case .keepWaiting:
                break
            case .closeAndForget:
                await coordinator.close()
                guard SessionFiles.forget(id) else {
                    return .notEnded("The session ended, but its record is in use or cannot be deleted now. Try again in a few seconds.")
                }
                return .ended
            case .closeThenStopOverSSH:
                await coordinator.close()
                return await overSSH(id, meta: coordinator.meta, host: host, hostName: hostName)
            case .saveThenStopOverSSH, .saveAndKeep:
                // f. The ordinary save: quiesce, export, snapshot, clean mark (C5, R5).
                let saved = await coordinator.enterBackground()
                let state = await coordinator.recordState
                await coordinator.close()
                DebugLog.shared.log("end session \(id): no proof of the server in \(contactWait); saved \(saved), record \(state), closed")
                guard step == .saveThenStopOverSSH else {
                    return .notEnded("\(hostName.prefix(1).uppercased() + hostName.dropFirst()) did not answer. The session is kept; try again later, or use Forget.")
                }
                return await overSSH(id, meta: coordinator.meta, host: host, hostName: hostName)
            case .closeAndKeep(let reason):
                await coordinator.close()
                return .notEnded("It could not be started now (\(reason)). The session is kept; try again later, or use Forget.")
            case .start, .keep, .forget, .stopOverSSH:
                // Steps of the cold start only; not met here.
                await coordinator.close()
                return .notEnded("The session was not ended.")
            }
            // The next input of this phase; the time-outs end every phase, so this returns.
            var input: SessionEndPlan.Input?
            while input == nil {
                guard let next = await iterator.next() else { break }
                switch next {
                case .input(let given): input = given
                case .timeUp(let of): if of == phase { input = .timedOut }
                }
            }
            guard let input else {
                await coordinator.close()
                return .notEnded("The session was not ended.")
            }
            step = SessionEndPlan.next(phase, input, canAskOverSSH: canAskOverSSH)
            // Every decision, and every input but the events that decide nothing (screens).
            if case .event = input, step == .keepWaiting {} else { log(id, phase, input, step) }
        }
    }

    /// h. The SSH way (as the row's End Session did before step 12): the identity-checked kill
    /// (`SessionLauncher.stopOldServer`), then the record, its key and its link removed only when
    /// that leaves nothing to do with the server's pid and start time (`mayForget`, review
    /// M6-4); otherwise kept as its files say, and the reason.
    static func overSSH(_ id: SessionID, meta: SessionMeta?, host: SavedHost?, hostName: String) async -> Outcome {
        let outcome = await SessionLauncher.stopOldServer(meta: meta, host: host)
        DebugLog.shared.log("end session \(id): old server: \(outcome)")
        guard outcome.mayForget else {
            return .notEnded(SessionListViewController.notEnded(outcome, host: hostName))
        }
        guard SessionFiles.forget(id) else {
            return .notEnded("The session's server was dealt with, but its record is in use or cannot be deleted now. Try again in a few seconds.")
        }
        return .ended
    }

    private static func log(_ id: SessionID, _ phase: SessionEndPlan.Phase, _ input: SessionEndPlan.Input,
                            _ step: SessionEndPlan.Step) {
        DebugLog.shared.log("end session \(id): \(phase), \(input.brief): \(step)")
    }
}
