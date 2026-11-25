import Foundation
import MoshCrypto
import MoshSession
import MoshTransport

/// An open session record: the directory, its lock and its gate, held together so that the
/// rules between them cannot be skipped.
///
/// A new session:
///
///     let record = try SessionRecord.create(root: root, meta: meta, key: key)
///     let session = try MoshSession(endpoint: meta.endpoint(key: key), ..., gate: record.gate)
///
/// Leaving the foreground:
///
///     await session.quiesce()
///     let exported = try await session.exportState()
///     let clean = try record.save(exported)      // false: a datagram left since, still dirty
///
/// A cold start:
///
///     let record = try SessionRecord.open(root: root, id: id)      // takes the lock
///     let snapshot = try record.loadSnapshot()                     // throws unless clean
///     let session = try MoshSession(restoring: snapshot, endpoint: record.meta.endpoint(key: try record.readKey()),
///                                   gate: record.gate, currentSize: size)
///     try record.gate.beginSending()
///     await session.start()
///
/// The policy around it (which record to open, fallback, deleting dead records, input that
/// arrives while quiesced) is the coordinator's.
public final class SessionRecord: @unchecked Sendable {
    public let meta: SessionMeta
    public let store: SessionStore
    public let gate: FileBackedGate
    private let sessionLock: SessionLock
    private let saveLock = NSLock()

    public var id: SessionID { meta.id }

    private init(meta: SessionMeta, store: SessionStore, gate: FileBackedGate, lock: SessionLock) {
        self.meta = meta
        self.store = store
        self.gate = gate
        self.sessionLock = lock
    }

    /// Makes the record of a new session: directory, lock, key, meta, and counters that say
    /// "nothing reserved, dirty".
    ///
    /// - Parameters:
    ///   - root: the directory that holds all records (`Application Support/sessions`).
    ///   - key: nil where the key is stored elsewhere (the iOS Keychain).
    public static func create(
        root: String,
        meta: SessionMeta,
        key: Base64Key?,
        blocks: GateCounters = FileBackedGate.defaultBlocks,
        hook: StorageHook? = nil,
        protection: any RecordProtection = RecordProtections.platform
    ) throws -> SessionRecord {
        let store = SessionStore(root: root, id: meta.id, hook: hook, protection: protection)
        let lock = try store.create(meta: meta, key: key)
        do {
            let gate = try FileBackedGate(store: store, lock: lock, blocks: blocks)
            return SessionRecord(meta: meta, store: store, gate: gate, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    /// Opens an existing record: takes the lock, checks that the directory is still excluded
    /// from backups, reads `meta` and `counters`. Nothing is written.
    ///
    /// - Throws: `RecordError.locked`; `RecordError.notProtected` (the record may be a restored
    ///   copy: there is no gate for it, so nothing can be sent from its counters);
    ///   `RecordError.missing`; `RecordFormatError` for a damaged `meta` or two bad counters
    ///   slots.
    public static func open(
        root: String,
        id: SessionID,
        blocks: GateCounters = FileBackedGate.defaultBlocks,
        hook: StorageHook? = nil,
        protection: any RecordProtection = RecordProtections.platform
    ) throws -> SessionRecord {
        let store = SessionStore(root: root, id: id, hook: hook, protection: protection)
        let lock = try store.acquireLock()
        do {
            try store.checkProtection()
            let meta = try store.readMeta()
            let gate = try FileBackedGate(store: store, lock: lock, blocks: blocks)
            return SessionRecord(meta: meta, store: store, gate: gate, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    /// The key from the `key` file (not on iOS).
    public func readKey() throws -> Base64Key {
        try store.readKey()
    }

    /// What `counters` says about the record, as the gate holds it.
    public var state: RecordState { gate.recordState }

    /// Stores an exported snapshot and marks the record clean for it: quiesce steps 3 and 4 of
    /// the plan. The snapshot replaces the old one atomically; then the gate writes "clean" with
    /// the snapshot's id, unless a datagram passed since the export.
    ///
    /// - Returns: true if the record is now clean for this snapshot. False if a datagram left
    ///   after the export (or the record is ended): the snapshot is stored but will not be used.
    public func save(_ exported: SessionExport) throws -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        var generator = SystemRandomNumberGenerator()
        let snapshotID = UInt64.random(in: 1...UInt64.max, using: &generator)
        try store.writeSnapshot(StoredSnapshot(id: snapshotID, snapshot: exported.snapshot), lock: sessionLock)
        return try gate.markClean(snapshotID: snapshotID, exported.cleanToken)
    }

    /// The stored snapshot, if it may be used: the record is clean, and the snapshot file is the
    /// one the clean mark names. This is the only way to a stored snapshot, so a stale one
    /// cannot be resumed from.
    ///
    /// - Throws: `RecordError.notResumable`, `RecordError.missing(.snapshot)`,
    ///   `RecordFormatError` for a damaged file.
    public func loadSnapshot() throws -> SessionSnapshot {
        try store.check(sessionLock)
        switch gate.recordState {
        case .dirty:
            throw RecordError.notResumable(.dirty)
        case .ended:
            throw RecordError.notResumable(.ended)
        case .clean(let expected):
            guard let stored = try store.readSnapshot() else { throw RecordError.missing(.snapshot) }
            guard stored.id == expected else {
                throw RecordError.notResumable(.snapshotDoesNotMatch(expected: expected, found: stored.id))
            }
            return stored.snapshot
        }
    }

    /// Closes the gate and releases the lock. The files stay.
    public func close() {
        gate.close()
        sessionLock.release()
    }

    /// Closes the record and removes its directory.
    public func delete() throws {
        gate.close()
        defer { sessionLock.release() }
        try store.delete()
    }

    deinit {
        close()
    }
}
