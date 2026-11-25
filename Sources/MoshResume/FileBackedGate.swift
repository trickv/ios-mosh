import Foundation
import MoshTransport
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Errors of `FileBackedGate` beyond `GateError` and the storage's.
public enum FileGateError: Error, Equatable, Sendable {
    /// The protocol's `markClean(ifDatagramsPassed:)` was called on a `FileBackedGate`. A clean
    /// mark names a stored snapshot, so only `SessionRecord.save`, which has just stored one,
    /// can ask for it; there is no clean mark on the gate's own word.
    case noSnapshotStored
    /// The gate was closed.
    case closed
    /// A gate was already made with this lock. Two gates on one record would hand out the same
    /// numbers.
    case lockHasAGate
}

/// The `DurabilityGate` of a resumable session: the counters live in the record's `counters`
/// file (docs/PLAN.md section 3, "Rules"; docs/RESUME.md has the invariants with their tests).
///
/// What it guarantees, whatever moment the process is killed at, and also if one of the two
/// slots is damaged afterwards:
///
/// - **A number is handed out only below a limit that both slots hold.** A new gate for the same
///   record starts at the highest limit any valid slot holds, so it starts above every number
///   any earlier gate handed out (N1, N2, N4).
/// - **A datagram passes only after both slots say "dirty".** So if a datagram may have left
///   after the snapshot was stored, no valid slot says "clean".
/// - **"Clean" names a snapshot.** It is written (to the older slot, once) only if no datagram
///   passed since the export, and it carries the id of the snapshot that was stored. Only
///   `SessionRecord.save` can ask for it.
///
/// A change of the counters is two writes, each `pwrite` of one slot followed by an fsync
/// (`F_FULLFSYNC` on Apple platforms): first the older slot, then the other. The plan asked for
/// one write. With one, a slot that goes bad later (not torn by a crash, but damaged at rest)
/// would hand the session back to its older slot: lower limits, or "clean" for a snapshot that
/// is stale. With two, the older slot never says anything less safe than what was acted on.
///
/// If a write fails (the device is locked, the disk is full), the call throws, no number is
/// handed out and no datagram passes; the next call writes again.
///
/// Thread-safe. The calls block for the fsyncs: about once per 1,024 new states, once per 65,536
/// datagrams, and for the first datagram after a snapshot.
public final class FileBackedGate: DurabilityGate, @unchecked Sendable {
    /// Block sizes from the plan: 65,536 sequence numbers, 1,024 state numbers and fragment ids.
    public static let defaultBlocks = InMemoryGate.defaultBlocks

    private let store: SessionStore
    private let sessionLock: SessionLock
    private let blocks: GateCounters
    private let lock = NSLock()
    private var descriptor: Int32

    /// The newest generation a slot write was started for.
    private var diskGeneration: UInt64
    /// The highest limits put into any slot write, finished or not. Every write carries these, so
    /// a newer slot never holds a lower limit than an older one.
    private var written: GateCounters
    /// Limits both slots are known to hold. Numbers are handed out below these only.
    private var limits: GateCounters
    private var next: GateCounters
    /// The record's state as this process means it to be.
    private var state: RecordState
    /// True when both slots are known to say "dirty" (or "ended"). A datagram needs this.
    private var notCleanIsDurable = false
    private var passed: UInt64 = 0

    /// Opens the counters of an existing record. Reads only; nothing is written until a number
    /// is taken or a datagram is about to leave.
    ///
    /// Internal: `SessionRecord` makes the one gate of a record. A second gate on the same lock
    /// would start at the same limits and hand out the same numbers, so the lock also remembers
    /// that it has a gate.
    ///
    /// - Parameter lock: the record's lock, which the gate keeps for as long as it lives: there
    ///   is no gate without the lock, and so no second writer.
    /// - Throws: `RecordError.missing(.counters)`, `RecordFormatError` if no slot is valid,
    ///   `FileGateError.lockHasAGate`.
    init(store: SessionStore, lock: SessionLock, blocks: GateCounters = FileBackedGate.defaultBlocks) throws {
        try store.check(lock)
        guard let descriptor = try store.storage.openExisting("counters") else { throw RecordError.missing(.counters) }
        let reading: CountersReading
        do {
            reading = try store.readCounters(descriptor: descriptor)
            guard lock.claimForGate() else { throw FileGateError.lockHasAGate }
        } catch {
            _ = systemClose(descriptor)
            throw error
        }
        self.store = store
        self.sessionLock = lock
        self.blocks = GateCounters(sequence: max(1, blocks.sequence), state: max(1, blocks.state),
                                   fragmentID: max(1, blocks.fragmentID))
        self.descriptor = descriptor
        diskGeneration = reading.generation
        written = reading.limits
        limits = reading.limits
        next = reading.limits
        state = reading.state
    }

    deinit {
        if descriptor >= 0 { _ = systemClose(descriptor) }
    }

    /// Closes the file. The lock is the record's to release. Every later call throws.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            _ = systemClose(descriptor)
            descriptor = -1
        }
    }

    // MARK: Reading

    public var reservedLimits: GateCounters {
        lock.lock()
        defer { lock.unlock() }
        return limits
    }

    /// The record's state: what `counters` said when the gate was opened, then what this gate
    /// made of it.
    public var recordState: RecordState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var datagramsPassed: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return passed
    }

    /// True when both slots are known to say "dirty" or "ended": whatever happens to the process
    /// or to one slot, the record will not be read as clean.
    public var isDurablyNotClean: Bool {
        lock.lock()
        defer { lock.unlock() }
        return notCleanIsDurable
    }

    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .clean = state { return false }
        return true
    }

    // MARK: Numbers

    public func takeSequenceNumber() throws -> UInt64 { try take(\.sequence) }
    public func takeStateNumber() throws -> UInt64 { try take(\.state) }
    public func takeFragmentID() throws -> UInt64 { try take(\.fragmentID) }

    private func take(_ counter: WritableKeyPath<GateCounters, UInt64>) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        if next[keyPath: counter] >= limits[keyPath: counter] {
            // Reserve ahead: the new limit is in both slots before a number below it is used.
            // (After a failed attempt `written` is already raised, and is not raised twice.)
            if written[keyPath: counter] <= limits[keyPath: counter] {
                let (limit, overflow) = limits[keyPath: counter].addingReportingOverflow(blocks[keyPath: counter])
                guard !overflow else { throw GateError.exhausted }
                written[keyPath: counter] = limit
            }
            try writeBothSlots(state)
        }
        let value = next[keyPath: counter]
        next[keyPath: counter] = value + 1
        return value
    }

    // MARK: Dirty and clean

    public func willSendDatagram() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        if !notCleanIsDurable {
            // Dirty before send: both slots, before the datagram can reach a socket. For a
            // record that is to be ended, the mark is "ended" (see `markEnded`).
            try writeBothSlots(state == .ended ? .ended : .dirty)
        }
        if state != .ended { state = .dirty }
        passed += 1
    }

    /// The protocol's clean mark. A file-backed record is clean only for a snapshot, and this
    /// call names none, so it always throws: `SessionRecord.save` is the way.
    ///
    /// - Throws: `FileGateError.noSnapshotStored`, always (`closed` on a closed gate).
    public func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        throw FileGateError.noSnapshotStored
    }

    /// Writes "clean, for the snapshot with this id" if no datagram passed since the export
    /// whose `CleanToken` is given. The caller (`SessionRecord.save`) has durably stored that
    /// snapshot, made from that export, right before. Id and token come in one call, so a
    /// refused mark leaves nothing behind that a later call could use. One critical section
    /// with `willSendDatagram()`.
    ///
    /// - Returns: false, with nothing changed, if a datagram passed or the record is ended.
    /// - Throws: storage errors (the record then stays dirty as far as this gate is concerned,
    ///   and the next datagram writes "dirty" again).
    func markClean(snapshotID id: UInt64, _ token: CleanToken) throws -> Bool {
        precondition(id != 0)
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        guard passed == token.datagramsPassed, state != .ended else { return false }
        if state == .clean(snapshotID: id) { return true }
        // From here a slot may say "clean" even if the write fails half way.
        notCleanIsDurable = false
        try writeOneSlot(.clean(snapshotID: id))
        state = .clean(snapshotID: id)
        return true
    }

    /// Cold start, step 3 of the plan: reserves a block of every counter and writes "dirty", in
    /// one change, so that the first datagram needs no further write. Call it after the
    /// snapshot was loaded and the session rebuilt, right before it starts. Optional: without
    /// it the first number taken and the first datagram do the same in two changes.
    public func beginSending() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        for counter in [\GateCounters.sequence, \.state, \.fragmentID] where written[keyPath: counter] <= limits[keyPath: counter] {
            let (limit, overflow) = limits[keyPath: counter].addingReportingOverflow(blocks[keyPath: counter])
            guard !overflow else { throw GateError.exhausted }
            written[keyPath: counter] = limit
        }
        let target: RecordState = state == .ended ? .ended : .dirty
        try writeBothSlots(target)
        state = target
    }

    /// Makes "not clean" durable now, without a datagram: for a change the stored snapshot does
    /// not hold (input accepted while quiesced) and for the return to the foreground. Nothing is
    /// written if both slots already say "dirty" or "ended". An ended record stays ended: if its
    /// mark is not in both slots yet, this writes "ended", not "dirty".
    public func markDirty() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        if !notCleanIsDurable {
            try writeBothSlots(state == .ended ? .ended : .dirty)
        }
        guard state != .ended else { return }
        state = .dirty
    }

    /// Marks the record as ended on purpose (the user ended the session, or the server did):
    /// never resumed, and no new session is owed. Datagrams may still pass, for a last shutdown
    /// request.
    ///
    /// The gate takes this as final before it writes: from the call on the state is "ended",
    /// no clean mark is possible, and if the write fails (it throws), every later write of this
    /// gate (a reservation, dirty before send, `markDirty`, `beginSending`) writes "ended". So a
    /// mark that reached one slot is completed, never covered by "dirty", and no datagram
    /// passes before both slots hold it.
    public func markEnded() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkOpen()
        if state == .ended, notCleanIsDurable { return }
        state = .ended
        try writeBothSlots(.ended)
    }

    // MARK: Writing

    private func checkOpen() throws {
        guard descriptor >= 0 else { throw FileGateError.closed }
        try store.check(sessionLock)
    }

    /// One slot: the next generation, into the slot it belongs in (the older one), then fsync.
    private func writeOneSlot(_ slotState: RecordState) throws {
        let generation = diskGeneration + 1
        let slot = CountersSlot(generation: generation, sessionID: store.id, limits: written, state: slotState)
        let offset = CountersFile.offset(ofSlot: CountersFile.slotIndex(forGeneration: generation))
        // A failed write is repeated with the same generation into the same slot: the other slot
        // stays the valid one until this one is complete.
        try store.storage.write(descriptor: descriptor, file: "counters", slot.encoded(), offset: offset)
        try store.storage.sync(descriptor: descriptor, file: "counters")
        diskGeneration = generation
    }

    /// Both slots, one after the other. Only when both are durable do the limits count as
    /// reserved and "not clean" as durable.
    private func writeBothSlots(_ slotState: RecordState) throws {
        notCleanIsDurable = false
        try writeOneSlot(slotState)
        try writeOneSlot(slotState)
        limits = written
        if case .clean = slotState {} else { notCleanIsDurable = true }
    }
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}
