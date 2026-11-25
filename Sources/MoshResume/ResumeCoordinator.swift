import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTransport

// MARK: Outcomes

/// Why a stored session could not be continued (docs/PLAN.md section 3, "Fallback").
public enum FallbackReason: Equatable, Sendable, CustomStringConvertible {
    /// A datagram may have left after the stored snapshot was taken (the process died in the
    /// foreground), or a change was accepted that the snapshot does not hold.
    case dirty
    /// The session was ended on purpose: the user asked for a shutdown, or the server ended it.
    /// (A session that was only given up, by a fallback or by `abandon()`, says `dirty`.) The
    /// server is gone unless the shutdown request never reached it, so the app still runs the
    /// identity check with `meta` and kills what is left before it deletes the record.
    case ended
    /// The record says "clean" for another snapshot than the one stored.
    case snapshotDoesNotMatch
    /// A part of the record is not there (`key`, `counters`, `meta`, `snapshot`).
    case missing(RecordPart)
    /// A part of the record cannot be read: damaged, or of another session or format version.
    case damaged(String)
    /// The snapshot was read but the transport refused it (its numbers do not fit the gate's).
    case snapshotRefused(String)

    public var description: String {
        switch self {
        case .dirty: return "the record is dirty"
        case .ended: return "the session was ended"
        case .snapshotDoesNotMatch: return "the stored snapshot is not the one the record is clean for"
        case .missing(let part): return "the record has no \(part.rawValue)"
        case .damaged(let text): return "the record is damaged: \(text)"
        case .snapshotRefused(let text): return "the snapshot was refused: \(text)"
        }
    }
}

/// A cold start that ended in the fallback. Nothing was sent under the old key.
public struct ColdStartFallback: Equatable, Sendable {
    /// What the app shows before it bootstraps again (docs/PLAN.md section 3).
    public static let userMessage = "Previous session could not be resumed. Starting a new one."

    public var reason: FallbackReason
    /// The record's `meta`, if it could be read: the host, user and remote command for the new
    /// bootstrap, and the old server's pid and start time for the identity check before it is
    /// killed.
    public var meta: SessionMeta?
    /// True if the record is already gone (it lacked a part, so it never was or no longer is a
    /// record). Otherwise it stays, not resumable, until `ResumeCoordinator.deleteRecord`, which
    /// the app calls once the new session exists; until then every cold start gives a fallback
    /// that still wants a new session.
    public var recordDeleted: Bool

    /// False for a session that was ended on purpose: the app removes it from its list instead
    /// of starting a new one (after the check for a server that outlived the request).
    public var wantsNewSession: Bool { reason != .ended }
}

/// A cold start that could not be decided now. The record is untouched; try again later. Never
/// treat this as a dead session.
public enum ColdStartRetry: Equatable, Sendable, CustomStringConvertible {
    /// Another process (or another coordinator in this one) holds the record's lock.
    case inUse
    /// A file operation failed: the device is locked, or the disk is in trouble.
    case storage(String)

    public var description: String {
        switch self {
        case .inUse: return "the record is in use"
        case .storage(let text): return "storage: \(text)"
        }
    }
}

public enum ColdStartOutcome: Sendable {
    /// The session continues. Call `start()` on the coordinator.
    case resumed(ResumeCoordinator)
    case fallback(ColdStartFallback)
    case retryLater(ColdStartRetry)
}

/// What a save (leaving the foreground, or a change while in the background) left on disk.
public enum SaveOutcome: Equatable, Sendable {
    /// The record is clean for a snapshot that holds everything accepted so far: a process
    /// death from now on is followed by a resume.
    case clean
    /// The record is not resumable; a process death from now on is followed by the fallback.
    case notResumable(NotSavedReason)

    public var isClean: Bool { self == .clean }
}

public enum NotSavedReason: Equatable, Sendable {
    /// A datagram left after the export (a return to the foreground overtook the save).
    case datagramSentSinceExport
    /// The session is over (its record is marked ended) or was given up (dirty).
    case ended
    /// Exporting or storing failed (the text says how). The record is dirty or names a
    /// snapshot that is not the stored one; either way it is not resumed.
    case failed(String)
    /// The coordinator is closed.
    case closed
}

// MARK: Coordinator

/// One resumable session: a `MoshSession` and its `SessionRecord`, with the rules between them
/// (docs/PLAN.md section 3; docs/RESUME.md, "Coordinator").
///
/// The app talks to the session through this type only, so that the rules cannot be skipped:
///
/// - **Cold start in order.** Lock and counters, then the snapshot (only if the record is
///   clean for it), then the session, then "dirty" with new reservations, then the first
///   datagram. Anything else is the fallback, and the fallback sends nothing.
/// - **Save in order.** Quiesce, export, store the snapshot, mark clean with the export's
///   token (`enterBackground()`).
/// - **A clean record holds everything that was accepted.** Input, a resize or a shutdown
///   accepted while in the background pass no datagram, so the gate's clean rule does not see
///   them (finding M9 of the transport review). Here they first make "dirty" (or "ended")
///   durable, are then given to the session, and are then saved again. Whenever the process
///   dies, the record is clean for a snapshot that holds the input, or it is not clean.
/// - **An ended session stays ended.** A shutdown request, the server's end of the session, a
///   lost base state and a halted transport mark the record ended before anything else
///   happens; no later save makes it clean again.
/// - **One at a time.** Lifecycle calls and input run in the order they arrive: a save
///   finishes before a return to the foreground starts.
///
/// A new session:
///
///     let coordinator = try ResumeCoordinator.create(root: root, meta: meta, key: key, initialSize: size)
///     Task { for await event in coordinator.events { ... } }
///     try await coordinator.start()
///
/// Leaving and returning (`sceneWillResignActive`, `sceneDidBecomeActive`):
///
///     await coordinator.enterBackground()
///     await coordinator.enterForeground()
///
/// A cold start:
///
///     switch ResumeCoordinator.coldStart(root: root, id: id, key: .provided(key), currentSize: size) {
///     case .resumed(let coordinator): try await coordinator.start()
///     case .fallback(let fallback):   // show ColdStartFallback.userMessage, bootstrap again,
///                                     // then ResumeCoordinator.deleteRecord(root:id:)
///     case .retryLater:               // device locked, or the record is in use
///     }
public actor ResumeCoordinator {
    /// What the session is built with besides the record. The defaults are the app's.
    public struct Options: Sendable {
        /// Sizes of the gate's reservations (tests use small ones).
        public var blocks: GateCounters = FileBackedGate.defaultBlocks
        /// Sees every storage step (tests; `moshcli --crashpoint`).
        public var storageHook: StorageHook?
        /// How the record's directory is kept out of backups. The default is the platform's;
        /// tests give their own.
        public var protection: any RecordProtection = RecordProtections.platform
        public var configuration: TransportConfiguration?
        public var clock: any MonotonicClock = SystemMonotonicClock()
        /// For a new session only; see `MoshSession.init`.
        public var noReplyTimeout: UInt64? = MoshSession.defaultNoReplyTimeout
        /// For a new session only.
        public var clipboard = ClipboardPolicy()
        public var makeTransport: (@Sendable () throws -> any DatagramTransport)?
        /// Wraps the record's gate (`moshcli --seq-log` logs the numbers that pass). The wrapper
        /// must pass every call on.
        public var wrapGate: (@Sendable (FileBackedGate) -> any DurabilityGate)?
        /// Local echo for every session the coordinator makes (new, resumed, or the new one
        /// after a fallback, which the app creates with the same options). Not stored in the
        /// record: the app passes its setting at each `create` and `coldStart`.
        public var prediction: PredictionSettings = .off

        public init() {}
    }

    /// The session's events, in order, as `MoshSession.events` gives them. The coordinator has
    /// acted on an event before it appears here (an ended session's record is already marked).
    /// Ends at `close()`.
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let meta: SessionMeta
    /// True if this session was continued from its record.
    public nonisolated let isRestored: Bool

    public nonisolated var id: SessionID { meta.id }

    private let record: SessionRecord
    private let session: MoshSession
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private var reader: Task<Void, Never>?
    private var started = false
    private var closed = false
    /// Between `enterBackground()` and `enterForeground()`: the session is quiesced.
    private var inBackground = false
    /// The session is over (record "ended") or given up (record "dirty"). Set before the mark is
    /// written, and never unset, so that no save follows even if the write failed.
    private var ended = false
    /// True from a save that left the record clean until anything that can change the session
    /// or the record (a return to the foreground, input). While it is true, saving again has
    /// nothing to add.
    private var savedClean = false
    /// `start()` was asked for while in the background; it happens at `enterForeground()`.
    private var startDeferred = false
    /// The size the view reported before `start()`; announced when the session starts.
    private var sizeBeforeStart: TerminalSize?
    /// The last lifecycle operation; the next one waits for it.
    private var tail: Task<Void, Never>?

    private init(record: SessionRecord, session: MoshSession, isRestored: Bool) {
        self.record = record
        self.session = session
        self.meta = record.meta
        self.isRestored = isRestored
        (events, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: Making one

    /// A new session and its record. Nothing is sent before `start()`, and no input is taken.
    ///
    /// - Parameters:
    ///   - key: the session key from `MOSH CONNECT`.
    ///   - storesKey: false where the key is kept elsewhere (the iOS Keychain); the cold start
    ///     is then given the key.
    ///   - initialSize: the terminal view's size.
    /// - Throws: storage errors; nothing usable is left behind (a later cold start of the
    ///   unfinished directory deletes it).
    public static func create(
        root: String,
        meta: SessionMeta,
        key: Base64Key,
        storesKey: Bool = true,
        initialSize: TerminalSize,
        options: Options = Options()
    ) throws -> ResumeCoordinator {
        let record = try SessionRecord.create(root: root, meta: meta, key: storesKey ? key : nil,
                                              blocks: options.blocks, hook: options.storageHook,
                                              protection: options.protection)
        do {
            let session = try MoshSession(
                endpoint: meta.endpoint(key: key),
                initialSize: initialSize,
                serverStartSize: meta.serverStartSize,
                gate: options.wrapGate?(record.gate) ?? record.gate,
                configuration: options.configuration,
                clipboard: options.clipboard,
                clock: options.clock,
                noReplyTimeout: options.noReplyTimeout,
                prediction: options.prediction,
                makeTransport: options.makeTransport
            )
            return ResumeCoordinator(record: record, session: session, isRestored: false)
        } catch {
            try? record.delete()
            throw error
        }
    }

    /// Where a cold start gets the session key from. There is no default: on iOS the key is a
    /// Keychain item and the record has no `key` file, so "no key given" would read as "the
    /// record has no key" and end a session that only had a locked Keychain in its way.
    public enum KeySource: Sendable {
        /// The record's `key` file (`moshcli`; not on iOS).
        case recordFile
        /// The key from elsewhere (the iOS Keychain). A caller that cannot get the key now
        /// (device locked) does not call `coldStart` at all: that is "try again later".
        case provided(Base64Key)
    }

    /// Cold start with a record (docs/PLAN.md section 3): continues the stored session, or says
    /// why not. Nothing is sent here in any case; a resumed session sends at `start()`.
    ///
    /// - Parameters:
    ///   - key: where the session key comes from.
    ///   - currentSize: the view's size now; announced to the server if it changed.
    public static func coldStart(
        root: String,
        id: SessionID,
        key: KeySource,
        currentSize: TerminalSize?,
        options: Options = Options()
    ) -> ColdStartOutcome {
        // 1. The lock and the counters.
        let record: SessionRecord
        do {
            record = try SessionRecord.open(root: root, id: id, blocks: options.blocks, hook: options.storageHook,
                                            protection: options.protection)
        } catch {
            switch disposition(of: error) {
            case .retry(let retry):
                return .retryLater(retry)
            case .fallback(let reason):
                // Not a record (a part is missing or unreadable, or the directory is not
                // excluded from backups and may be a restored copy): the plan deletes it. The
                // lock is taken first, so that a record somebody is just making is left alone.
                let store = SessionStore(root: root, id: id)
                let meta = try? store.readMeta()
                // "Gone" only if the directory is known not to be there. If that cannot be
                // found out, nothing is known about the record: later.
                var deleted: Bool
                do {
                    deleted = try !store.exists
                } catch {
                    return .retryLater(.storage("\(error)"))
                }
                if !deleted {
                    do {
                        let lock = try store.acquireLock()
                        defer { lock.release() }
                        try store.delete()
                        deleted = true
                    } catch RecordError.locked {
                        return .retryLater(.inUse)
                    } catch {
                        deleted = false
                    }
                }
                return .fallback(ColdStartFallback(reason: reason, meta: meta, recordDeleted: deleted))
            }
        }

        // 2. The snapshot (only if the record is clean for it) and the key; 4. and 5. the
        // session rebuilt from them. Step 3 ("dirty", new reservations) is in `start()`, right
        // before the first datagram: the snapshot can only be loaded while the record is clean.
        do {
            let snapshot = try record.loadSnapshot()
            let sessionKey: Base64Key
            switch key {
            case .recordFile: sessionKey = try record.readKey()
            case .provided(let given): sessionKey = given
            }
            let session = try MoshSession(
                restoring: snapshot,
                endpoint: record.meta.endpoint(key: sessionKey),
                gate: options.wrapGate?(record.gate) ?? record.gate,
                currentSize: currentSize,
                configuration: options.configuration,
                clock: options.clock,
                prediction: options.prediction,
                makeTransport: options.makeTransport
            )
            return .resumed(ResumeCoordinator(record: record, session: session, isRestored: true))
        } catch {
            switch disposition(of: error) {
            case .retry(let retry):
                record.close()
                return .retryLater(retry)
            case .fallback(let reason):
                // Given up, and it must stay so whatever a later start finds: "dirty", which is
                // never resumed and never read as "ended on purpose", so the next start says
                // again that a new session is owed (and hands `meta` over for it) until the app
                // deletes the record. If the mark cannot be written, the record is as unusable
                // the next time. Two cases write nothing: an ended record stays ended, and a
                // missing key is not a fact about the record (the caller named the wrong
                // source, or the file is gone for good; either way the same call says the same
                // again, and the right call can still resume).
                if reason != .missing(.key) {
                    try? record.gate.markDirty()
                }
                let meta = record.meta
                record.close()
                return .fallback(ColdStartFallback(reason: reason, meta: meta, recordDeleted: false))
            }
        }
    }

    /// Removes a record: after a fallback once the new session exists, or for "Forget".
    ///
    /// - Throws: `RecordError.locked` if a live session holds it; storage errors, also when it
    ///   cannot be found out whether the record is there.
    public static func deleteRecord(root: String, id: SessionID) throws {
        let store = SessionStore(root: root, id: id)
        guard try store.exists else { return }
        let lock = try store.acquireLock()
        defer { lock.release() }
        try store.delete()
    }

    private enum Disposition {
        case fallback(FallbackReason)
        case retry(ColdStartRetry)
    }

    /// Everything that goes wrong at a cold start is the fallback, except a record somebody
    /// else holds and a file operation that failed (device locked: `EPERM`, `EACCES`).
    private static func disposition(of error: Error) -> Disposition {
        switch error {
        case RecordError.locked:
            return .retry(.inUse)
        case let error as StorageError:
            if case .tooLarge(let file) = error { return .fallback(.damaged("\(file) is too large")) }
            return .retry(.storage("\(error)"))
        case RecordError.missing(let part):
            return .fallback(.missing(part))
        case RecordError.notProtected:
            return .fallback(.damaged("not excluded from backup (it may be a restored copy)"))
        case RecordError.notResumable(.dirty):
            return .fallback(.dirty)
        case RecordError.notResumable(.ended):
            return .fallback(.ended)
        case RecordError.notResumable(.snapshotDoesNotMatch):
            return .fallback(.snapshotDoesNotMatch)
        case let error as RecordFormatError:
            return .fallback(.damaged("\(error)"))
        case let error as SnapshotError:
            return .fallback(.snapshotRefused("\(error)"))
        default:
            return .fallback(.damaged("\(error)"))
        }
    }

    // MARK: One at a time

    /// Runs `operation` after every operation that was asked for before it.
    private func inOrder<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Lifecycle

    /// Starts sending. For a restored session this is steps 3 and 6 of the cold start: one
    /// counters change (new reservations, "dirty"), then the first datagram; its first event is
    /// the stored screen (`isLive` false).
    ///
    /// Before `start()` nothing reaches the session, whatever is called: input is refused, a
    /// size is kept and announced at the start, and `enterBackground()` leaves the record as it
    /// is. A `start()` asked for while in the background happens at `enterForeground()` (a
    /// failure of its counters change is then reported as a `.gateFailed` event; call `start()`
    /// again).
    ///
    /// - Throws: storage errors from the counters change. Nothing was sent and the record is
    ///   still resumable: call `start()` again later, or `close()`.
    public func start() async throws {
        let result: Result<Void, Error> = await inOrder { await self.runStart() }
        try result.get()
    }

    private func runStart() async -> Result<Void, Error> {
        guard !started, !closed else { return .success(()) }
        if inBackground {
            // Not now: a session that starts sending here would be dirty and never saved.
            startDeferred = true
            return .success(())
        }
        if isRestored {
            do {
                try record.gate.beginSending()
            } catch {
                return .failure(error)
            }
        }
        started = true
        let stream = session.events
        reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.inOrder { await self.handle(event) }
            }
        }
        await session.start()
        if let size = sizeBeforeStart {
            sizeBeforeStart = nil
            _ = await session.resize(size)
        }
        return .success(())
    }

    /// Leaving the foreground: quiesce, export, store the snapshot, mark clean.
    ///
    /// Safe to call again while in the background: if the record is still clean, nothing has
    /// changed since the save (input in the background makes it dirty first), and the call
    /// writes nothing. Saving again could only lose the record: between the new snapshot's
    /// rename and its clean mark the counters name a snapshot that is gone.
    ///
    /// - Parameter afterSend: a test seam (`MoshSession.quiesceAfterSend()`): send what is
    ///   pending, read nothing more, then quiesce.
    @discardableResult
    public func enterBackground(afterSend: Bool = false) async -> SaveOutcome {
        await inOrder { await self.runEnterBackground(afterSend: afterSend) }
    }

    private func runEnterBackground(afterSend: Bool) async -> SaveOutcome {
        guard !closed else { return .notResumable(.closed) }
        guard started else {
            // Nothing reached the session yet, so there is nothing to quiesce or to save. A
            // restored session's record is still clean for its snapshot, which is still the
            // whole truth; a new session's record is dirty and has no snapshot.
            inBackground = true
            if !ended, case .clean = record.state { return .clean }
            return .notResumable(.failed("the session was not started"))
        }
        if inBackground, !ended, savedClean, case .clean = record.state {
            return .clean
        }
        if afterSend {
            await session.quiesceAfterSend()
        } else {
            await session.quiesce()
        }
        inBackground = true
        return await save()
    }

    /// Returning to the foreground with the process alive: "dirty", then a new socket, and the
    /// session continues from memory.
    public func enterForeground() async {
        await inOrder { await self.runEnterForeground() }
    }

    private func runEnterForeground() async {
        guard !closed, inBackground else { return }
        inBackground = false
        savedClean = false
        guard started else {
            if startDeferred {
                startDeferred = false
                if case .failure(let error) = await runStart() {
                    continuation.yield(.gateFailed("the session could not be started: \(error)"))
                }
            }
            return
        }
        // The plan writes "dirty" here. If the write fails, the gate writes it before the first
        // datagram all the same (or lets none pass).
        try? record.gate.markDirty()
        await session.resume()
    }

    /// Stores the session as it is now. The session is quiesced and this runs in order, so
    /// nothing can change between the export and the clean mark except through the gate, which
    /// the token covers.
    private func save() async -> SaveOutcome {
        guard !ended else { return .notResumable(.ended) }
        savedClean = false
        do {
            let exported = try await session.exportState()
            savedClean = try record.save(exported)
            return savedClean ? .clean : .notResumable(.datagramSentSinceExport)
        } catch SnapshotError.sessionEnded {
            // Over before the event about it was handled here.
            markEnded()
            return .notResumable(.ended)
        } catch {
            // Before the rename: the record is as it was (dirty, or clean for a snapshot that
            // holds everything, because a change makes it dirty first). After the rename: the
            // clean mark, if any, names a snapshot that is no longer there.
            return .notResumable(.failed("\(error)"))
        }
    }

    /// Never resume this record. The flag comes first: even if the write fails, no later save
    /// marks the record clean. The gate keeps the intent too: its next write of any kind says
    /// "ended", and no datagram passes before that.
    private func markEnded() {
        ended = true
        do {
            try record.gate.markEnded()
        } catch {
            continuation.yield(.gateFailed("the record could not be marked ended: \(error)"))
        }
    }

    /// Never resume this record, and remember that a new session is owed: no more saves, and
    /// "dirty" durable. Not "ended", which a later cold start reads as "closed on purpose,
    /// nothing to do" (review finding B-1).
    private func giveUp() {
        ended = true
        do {
            try record.gate.markDirty()
        } catch {
            continuation.yield(.gateFailed("the record could not be marked dirty: \(error)"))
        }
    }

    // MARK: Input

    /// Bytes the user typed or pasted. False if they were not taken (the session was not
    /// started or takes no more input, or, in the background, the record could not be written).
    ///
    /// In the background the bytes are in the stored snapshot when this returns true, unless
    /// the record is no longer resumable.
    ///
    /// In the foreground true means "taken by the session", not "stored": a process death in
    /// the foreground normally ends in the fallback. One case ends in a resume instead: if
    /// "dirty" could not be written at the return to the foreground (`.gateFailed` events say
    /// so), no datagram has passed since, so the record is still clean for the last snapshot;
    /// a process death then resumes the session as the server has it, without the input typed
    /// since, which the server never saw and the user never saw echoed.
    @discardableResult
    public func type(_ bytes: [UInt8]) async -> Bool {
        await inOrder { await self.runInput { await $0.type(bytes) } }
    }

    /// The terminal view's size changed. Before `start()` the size is kept (the latest one)
    /// and announced when the session starts: a view lays out before the app is ready.
    @discardableResult
    public func resize(_ size: TerminalSize) async -> Bool {
        await inOrder { await self.runResize(size) }
    }

    private func runResize(_ size: TerminalSize) async -> Bool {
        guard !closed else { return false }
        guard started else {
            sizeBeforeStart = size
            return true
        }
        return await runInput { await $0.resize(size) }
    }

    private func runInput(_ apply: @Sendable (MoshSession) async -> Bool) async -> Bool {
        // Before `start()` nothing reaches the session: it would open a socket and send, with
        // the cold start's counters change not made and no reader for the events.
        guard !closed, started else { return false }
        guard inBackground, !ended else { return await apply(session) }
        // M9. The stored snapshot does not hold this input, and no datagram will tell the gate:
        // the record stops being clean before the session takes the input.
        do {
            try record.gate.markDirty()
        } catch {
            continuation.yield(.gateFailed("input in the background was not taken: \(error)"))
            return false
        }
        savedClean = false
        let accepted = await apply(session)
        _ = await save()
        return accepted
    }

    /// Asks the server to end the session (`MoshSession.shutdown()`). The record is marked ended
    /// first, in the foreground and in the background: a session the user closed is never
    /// resumed, and never bootstrapped again by a fallback (`FallbackReason.ended`).
    ///
    /// False also if the record could not be made "not clean" (the device is locked, the disk
    /// is full): the request is then refused and nothing has changed, as for input in the
    /// background. Otherwise a process death would resume a session the user closed.
    @discardableResult
    public func shutdown() async -> Bool {
        await inOrder { await self.runShutdown() }
    }

    private func runShutdown() async -> Bool {
        guard !closed else { return false }
        if !ended {
            // First "not clean" in both slots, which either happens or changes nothing. (Asking
            // for "ended" directly could fail half way and leave a record that says clean on
            // disk with a gate that is set on ending it.) Usually nothing is written here: in
            // the foreground the record is dirty already.
            do {
                try record.gate.markDirty()
            } catch {
                continuation.yield(.gateFailed("the shutdown was not taken: \(error)"))
                return false
            }
            // Then "ended". If that cannot be written now, the record is at least dirty, and
            // the gate writes "ended" before it lets the request's first datagram pass.
            markEnded()
        }
        return await session.shutdown()
    }

    /// The per-host clipboard switch. (In the background the stored snapshot keeps the old
    /// value until the next save; the app holds the switch itself.)
    public func setClipboardWriting(enabled: Bool) async {
        await session.setClipboardWriting(enabled: enabled)
    }

    /// A new socket (a path change in the foreground).
    public func replaceSocket() async {
        await inOrder { await self.runReplaceSocket() }
    }

    private func runReplaceSocket() async {
        guard !closed, !inBackground else { return }
        await session.replaceSocket()
    }

    // MARK: Ending

    /// Gives the session up ("Start new session" under the banner, a fallback at run time): the
    /// record is made "dirty" (not "ended": a later cold start must still say that a new session
    /// is owed) and everything is closed. The server is not told.
    public func abandon() async {
        await inOrder { await self.runAbandon() }
    }

    private func runAbandon() async {
        guard !closed else { return }
        giveUp()
        await runClose()
    }

    /// Stops the session and releases the record as it is: clean after `enterBackground()`,
    /// otherwise dirty or ended. Ends the event stream.
    public func close() async {
        await inOrder { await self.runClose() }
    }

    private func runClose() async {
        guard !closed else { return }
        closed = true
        await session.close()
        reader?.cancel()
        reader = nil
        record.close()
        continuation.finish()
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) async {
        guard !closed else { return }
        switch event {
        case .serverEnded, .shutdownFinished:
            // Over: the record says so before the app hears of it.
            if !ended { markEnded() }
        case .baseStateLost, .halted:
            // Never to be continued, but the server may live: a new session is owed.
            if !ended { giveUp() }
        default:
            break
        }
        continuation.yield(event)
    }

    // MARK: Reading

    /// What `counters` says now: `.clean` means a process death is followed by a resume.
    public var recordState: RecordState { record.state }
    public var isInBackground: Bool { inBackground }
    public var hasEnded: Bool { ended }

    public func screen() async -> ScreenUpdate { await session.screen() }
    public func contactAges() async -> ContactAges { await session.contactAges() }
    public func smoothedRoundTripTime() async -> Double { await session.smoothedRoundTripTime() }
    public func unacknowledgedInputCount() async -> Int { await session.unacknowledgedInputCount() }
    public func retransmissions() async -> UInt64 { await session.retransmissions() }
    public func datagramsSent() async -> UInt64 { await session.datagramsSent() }
    public func acknowledgedStateNumber() async -> UInt64 { await session.acknowledgedStateNumber() }
    public func clipboardPolicy() async -> ClipboardPolicy { await session.clipboardPolicy() }

    // MARK: Local echo

    /// Changes local echo on the live session at once (`MoshSession.setPrediction`). The
    /// setting is not written to the record; the app passes it again in `Options.prediction`
    /// for the next session (a cold start or a new one after a fallback).
    public func setPrediction(_ settings: PredictionSettings) async {
        await session.setPrediction(settings)
    }

    public func predictionSettings() async -> PredictionSettings { await session.predictionSettings() }
}
