import Foundation
import MoshResume
import MoshTerminal
import MoshTransport

/// A terminal screen's commands and the session they go to (docs/notes/multi-session/DESIGN.md
/// 2.3, "Three rules of the queue"; section 7). Moved out of `TerminalViewController` as it was,
/// with its UI-test hook.
///
/// - One consumer runs the commands in the order they were sent, one at a time, so input,
///   resizes and the lifecycle calls reach the coordinator in the order they happened (the
///   coordinator then runs them one at a time).
/// - The slot: the coordinator the screen has (`held`), from the moment it has one (from `init`
///   of a resumed screen, from `openSession` of a new one), and whether `attach` has run for it
///   (`isAttached`). Commands run only once it is attached; before that, and once the slot is
///   empty, they are dropped (a background task in one is ended).
/// - **The consumer holds the slot strongly, not the screen.** What was sent before the screen
///   went still runs. When the queue is finished (`finish()`, or the queue is freed with its
///   screen) and everything sent before has run, a coordinator still in the slot is parked
///   (5.6: saved, then closed). `take()` empties the slot: what it returns is the caller's to
///   end, and the queue's end does not touch it.
/// - **The park** (DESIGN.md 2.3, step 9): `.park` is the last command a back sends before it
///   finishes the queue. It runs after everything sent before it, also on a coordinator that was
///   never attached (a resumed screen left before `attach`: nothing is started or written, C11),
///   and empties the slot. Steps: `start()` again if the slot's coordinator is a resumed one
///   that was attached (it does nothing once started, RC:445, and completes a counters change a
///   failed `beginSending` began); `enterBackground()`, and once more after 300 ms if that did
///   not leave the record clean (`ParkPlan`); `close()`; `SessionFiles.forget` only for a
///   record the server ended (`ParkPlan.closeAndForget`). It sends nothing of its own (D5).
/// - The screen's three callbacks (input counted, local echo read, the UI-test layout after a
///   save) hold the screen weakly; the queue holds nothing of the screen.
/// - The consumer task is never cancelled. A command sent after `finish()` is dropped (a
///   `BackgroundTask` in it ends when it is freed), so nothing that must be ended is sent then.
///
/// Only the main thread uses it.
@MainActor
final class SessionQueue {
    enum Command {
        case input([UInt8])
        case resize(TerminalSize)
        case background(BackgroundTask)
        case foreground
        case replaceSocket
        case prediction(PredictionSettings)
        /// The back button's save, then close (DESIGN.md 2.3). `attachedRestored`: the slot's
        /// coordinator came from a cold start and `attach` has run for it, known at the leave.
        case park(BackgroundTask, attachedRestored: Bool)

        /// For logs and unit tests.
        var name: String {
            switch self {
            case .input: return "input"
            case .resize: return "resize"
            case .background: return "background"
            case .foreground: return "foreground"
            case .replaceSocket: return "replaceSocket"
            case .prediction: return "prediction"
            case .park: return "park"
            }
        }
    }

    /// What a park left, as its UI-test mark says (`park-clean`, `park-not-resumable`) and as the
    /// counters say after the close (unit tests).
    struct ParkReport: Equatable {
        var id: SessionID
        /// The park's last save answered `.clean`: the mark is `park-clean`.
        var savedClean: Bool
        var plan: ParkPlan
        /// `counters` read without the lock after the close; nil if it cannot be read (the
        /// record was forgotten, or it is not under this queue's root).
        var stateAfter: RecordState?

        var mark: String { savedClean ? "park-clean" : "park-not-resumable" }
    }

    /// The coordinator to release and whether `attach` has run for it. The consumer holds it
    /// strongly (rule 1 of DESIGN.md 2.3).
    private final class Slot {
        var coordinator: ResumeCoordinator?
        var attached = false
    }

    private let slot = Slot()
    private let continuation: AsyncStream<Command>.Continuation
    /// Runs every command sent before `finish()`, then the queue's end. Never cancelled.
    private(set) var consumer: Task<Void, Never>?
    /// Where the records are: the park reads the counters there after the close and forgets an
    /// ended record there. The app's root; unit tests pass their own.
    let root: String
    /// What the last park of this queue left (unit tests). Set while the queue is alive.
    private(set) var lastPark: ParkReport?

    /// `.input`: how many bytes went to the session (UI tests). Holds the screen weakly.
    var inputCounted: (@MainActor (Int) -> Void)?
    /// After `.prediction`: the session's own setting is read again (UI tests). Holds the
    /// screen weakly.
    var predictionApplied: (@MainActor (ResumeCoordinator) -> Void)?
    /// UI tests (`-uiTestingBackgroundInset`): asked before a background save; what it returns
    /// runs after the save, with whether the save left the record clean. Holds the screen weakly.
    var layoutAfterSave: (@MainActor () -> (@MainActor (Bool) -> Void)?)?

    /// The names of the last commands sent, oldest first (unit tests).
    private(set) var recentCommands: [String] = []

    init(root: String = SessionFiles.root) {
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.root = root
        let slot = self.slot
        consumer = Task { @MainActor [weak self] in
            for await command in stream {
                if case .park(let task, let attachedRestored) = command {
                    // Also a coordinator that was never attached (B7): it is closed, its record
                    // as it was (C11).
                    let report = await Self.park(slot, attachedRestored: attachedRestored, root: root, task: task)
                    if let report { self?.lastPark = report }
                    continue
                }
                guard slot.attached, let coordinator = slot.coordinator else {
                    if case .background(let task) = command { task.end() }
                    continue
                }
                if case .input(let bytes) = command { self?.inputCounted?(bytes.count) }
                // UI tests: a task of its own keeps the process running from before the save's
                // task ends until the layout after it has been held (or not).
                var afterSave: (@MainActor (Bool) -> Void)?
                if case .background = command { afterSave = self?.layoutAfterSave?() }
                let savedClean = await Self.perform(command, on: coordinator)
                afterSave?(savedClean)
                if case .prediction = command { self?.predictionApplied?(coordinator) }
            }
            // The queue's end (DESIGN.md 5.6): a coordinator still in the slot was neither parked
            // or taken by a leave nor given up (only tests, and a resumed screen that never
            // appeared, get here). It is parked, as a back parks it: saved, then closed, a
            // tracked release (G2).
            if let coordinator = slot.coordinator {
                DebugLog.shared.log("session: the screen went without being left; parking \(coordinator.id)")
                let attachedRestored = slot.attached && coordinator.isRestored
                let task = BackgroundTask(name: "park session at the queue's end")
                let park = Task { @MainActor in
                    await Self.park(slot, attachedRestored: attachedRestored, root: root, task: task)
                }
                SessionActivity.shared.track(release: coordinator.id) { _ = await park.value }
                if let report = await park.value { self?.lastPark = report }
            }
        }
    }

    /// The park (DESIGN.md 2.3 steps 1 to 5) of the slot's coordinator; nil if the slot is empty.
    /// Empties the slot. Runs in the consumer, after every command sent before it.
    private static func park(_ slot: Slot, attachedRestored: Bool, root: String, task: BackgroundTask) async -> ParkReport? {
        guard let coordinator = slot.coordinator else {
            task.end()
            return nil
        }
        let id = coordinator.id
        // 1. A resumed session's `start()` again, whether or not `begin`'s call failed: it does
        //    nothing once started (RC:445) and runs after `begin`'s in the coordinator's order;
        //    after a failed `beginSending` it completes the counters change that began
        //    (FileBackedGate.swift:237-249, 305-311). A coordinator that was not attached gets
        //    none (C11: its record stays as it was).
        if attachedRestored {
            do {
                try await coordinator.start()
            } catch {
                DebugLog.shared.log("session: park of \(id): start failed again: \(error)")
            }
        }
        // 2. The scene's save; once more after 300 ms if it did not leave the record clean.
        var outcome = await coordinator.enterBackground()
        var plan = ParkPlan.after(outcome, state: await coordinator.recordState, attempt: 1)
        if case .saveAgain(let delay) = plan {
            DebugLog.shared.log("session: park of \(id): saved \(outcome); once more")
            try? await Task.sleep(for: delay)
            outcome = await coordinator.enterBackground()
            plan = ParkPlan.after(outcome, state: await coordinator.recordState, attempt: 2)
        }
        // 3. The lock is released; nothing is written (RC:700-712).
        slot.coordinator = nil
        slot.attached = false
        await coordinator.close()
        // 4. Forgotten only when the server ended the session and the record says so.
        if plan == .closeAndForget { SessionFiles.forget(id, root: root) }
        // 5. The mark and the log line, then the task's end.
        let report = ParkReport(id: id, savedClean: outcome.isClean, plan: plan,
                                stateAfter: try? SessionStore(root: root, id: id).readCounters().state)
        DebugLog.shared.log("session: parked \(id): saved \(outcome), \(plan); counters after the close: \(report.stateAfter.map { "\($0)" } ?? "not readable")")
        let mark = report.mark
        await Task.detached { UITestMarks.send(mark) }.value
        task.end()
        return report
    }

    deinit {
        continuation.finish()
    }

    // MARK: The slot

    /// The coordinator in the slot, attached or not: what the leave decides about.
    var held: ResumeCoordinator? { slot.coordinator }

    /// `attach` has run for the coordinator in the slot.
    var isAttached: Bool { slot.attached && slot.coordinator != nil }

    /// The coordinator in the slot once `attach` has run for it; nil before and after.
    var attached: ResumeCoordinator? { slot.attached ? slot.coordinator : nil }

    /// Puts the screen's coordinator into the empty slot (a resumed one at `init`, a new one in
    /// `openSession`). One coordinator per slot: a second would be a record nobody releases.
    func hold(_ coordinator: ResumeCoordinator) {
        precondition(slot.coordinator == nil || slot.coordinator === coordinator,
                     "the slot holds another coordinator")
        slot.coordinator = coordinator
    }

    /// `attach` has run for `coordinator`: commands now reach it.
    func attach(_ coordinator: ResumeCoordinator) {
        hold(coordinator)
        slot.attached = true
    }

    /// Empties the slot. The coordinator returned is the caller's to end; the queue no longer
    /// runs commands on it and its end does not close it.
    @discardableResult
    func take() -> ResumeCoordinator? {
        let taken = slot.coordinator
        slot.coordinator = nil
        slot.attached = false
        return taken
    }

    // MARK: Commands

    /// Queues a command. False if the queue is finished (the command is dropped).
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard case .enqueued = continuation.yield(command) else { return false }
        recentCommands = Array((recentCommands + [command.name]).suffix(32))
        return true
    }

    /// No more commands. What was sent before still runs, then the queue's end.
    func finish() {
        continuation.finish()
    }

    /// Returns whether the command was a background save that left the record clean.
    private static func perform(_ command: Command, on coordinator: ResumeCoordinator) async -> Bool {
        switch command {
        case .park:
            // Run by the consumer before it reaches here.
            break
        case .input(let bytes):
            await reportBackgroundInputForUITests("background-input", coordinator)
            await coordinator.type(bytes)
        case .resize(let size):
            await reportBackgroundInputForUITests("background-resize", coordinator)
            await coordinator.resize(size)
        case .background(let task):
            let outcome = await coordinator.enterBackground()
            DebugLog.shared.log("session: background, saved: \(outcome)")
            let mark = outcome.isClean ? "background-clean" : "background-not-resumable"
            await Task.detached { UITestMarks.send(mark) }.value
            task.end()
            return outcome.isClean
        case .foreground:
            DebugLog.shared.log("session: foreground, dirty and a new socket")
            await coordinator.enterForeground()
        case .replaceSocket:
            await coordinator.replaceSocket()
        case .prediction(let settings):
            await coordinator.setPrediction(settings)
        }
        return false
    }

    /// UI-test launches with a spawner: input or a resize that reaches a session in the
    /// background makes its saved record dirty until the coordinator saves it again (a process
    /// death in between is a fallback), so it is reported to the spawner as a mark.
    private static func reportBackgroundInputForUITests(_ mark: String, _ coordinator: ResumeCoordinator) async {
        guard UITestSupport.isUITesting, await coordinator.isInBackground else { return }
        DebugLog.shared.log("session: \(mark) while the session is in the background")
        await Task.detached { UITestMarks.send(mark) }.value
    }
}
