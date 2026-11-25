import Foundation
import MoshCrypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a session record could not be used. The coordinator turns every one of these into the
/// fallback (a new session), except `locked` and `StorageError.io`, which mean "try again".
public enum RecordError: Error, Equatable, Sendable {
    /// Another connection (this process or another) holds the record's lock.
    case locked
    /// `create` found a directory for this session id. A record is made once; an existing one
    /// is opened, never made again (its counters would start over under the same key).
    case exists
    /// The record's directory is not excluded from backups (`RecordProtection.verify`): it may
    /// have come out of a backup, with counters older than what the key was used for. Never
    /// resumed; the record is to be deleted.
    case notProtected
    /// A part every record needs is not there. The record is to be deleted.
    case missing(RecordPart)
    /// The record must not be resumed.
    case notResumable(NotResumableReason)
    /// The lock given does not belong to this record, or was released.
    case lockNotHeld
    /// The record object was closed.
    case closed
}

public enum NotResumableReason: Equatable, Sendable {
    /// A datagram may have been sent after the stored snapshot was taken.
    case dirty
    /// The session was ended or given up.
    case ended
    /// The counters name a snapshot, and the snapshot file is not that one.
    case snapshotDoesNotMatch(expected: UInt64, found: UInt64)
}

/// The lock of a session record: an exclusive `flock` on the file `lock`, held as long as this
/// object lives (or until `release()`). Only one connection writes a record.
public final class SessionLock: @unchecked Sendable {
    let directory: String
    private let guardLock = NSLock()
    private var descriptor: Int32
    private var hasGate = false

    fileprivate init(directory: String, descriptor: Int32) {
        self.directory = directory
        self.descriptor = descriptor
    }

    public var isHeld: Bool {
        guardLock.lock()
        defer { guardLock.unlock() }
        return descriptor >= 0
    }

    /// A lock serves one gate. True the first time, false ever after.
    func claimForGate() -> Bool {
        guardLock.lock()
        defer { guardLock.unlock() }
        if hasGate { return false }
        hasGate = true
        return true
    }

    /// Gives the lock up. Closing the descriptor releases the `flock`.
    public func release() {
        guardLock.lock()
        defer { guardLock.unlock() }
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}

/// One session's directory, `<root>/<session id>/`, and its files:
///
/// | File | Content | How it is written |
/// |---|---|---|
/// | `meta` | `SessionMeta` | once, by replace |
/// | `key` | the session key (not on iOS, where it is a Keychain item) | once, by replace |
/// | `counters` | two slots of limits and state | in place, the older slot, then fsync |
/// | `snapshot` | `StoredSnapshot` | by replace (`snapshot.tmp`, fsync, rename, fsync of the directory) |
/// | `lock` | empty; its `flock` is the lock | never |
///
/// This type moves bytes. Which snapshot may be used, and when the counters are written, is
/// decided by `FileBackedGate` and `SessionRecord`.
public final class SessionStore: Sendable {
    public let root: String
    public let id: SessionID
    let storage: Storage
    let protection: any RecordProtection

    public var directory: String { storage.directory }

    public init(root: String, id: SessionID, hook: StorageHook? = nil,
                protection: any RecordProtection = RecordProtections.platform) {
        self.root = root
        self.id = id
        self.protection = protection
        storage = Storage(parent: root, name: id.description, hook: hook)
    }

    /// Whether the directory is still excluded from backups. Reads only.
    /// - Throws: `RecordError.notProtected`; `StorageError.io` if it cannot be found out now.
    func checkProtection() throws {
        let protected: Bool
        do {
            protected = try protection.verify(directory: directory)
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.io(step: "dir.verify-protection", errno: EIO)
        }
        guard protected else { throw RecordError.notProtected }
    }

    /// The ids of the directories under `root` whose names are session ids. Nothing is read.
    public static func sessionIDs(root: String) -> [SessionID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.compactMap { SessionID($0) }.sorted { $0.description < $1.description }
    }

    /// Whether the session's directory is there.
    /// - Throws: `StorageError.io` if that cannot be found out now. Only "no such file" is a no.
    public var exists: Bool { get throws { try storage.exists(".") } }

    // MARK: Lock

    /// Takes the record's lock without waiting. The directory must exist. Internal: a lock is
    /// what a gate is made from, and `SessionRecord` and the coordinator are the ways to both.
    /// - Throws: `RecordError.locked` if it is held, `RecordError.missing(.meta)` if there is no
    ///   such directory.
    func acquireLock() throws -> SessionLock {
        guard try storage.exists(".") else { throw RecordError.missing(.meta) }
        let path = storage.path("lock")
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            // The directory went away between the two calls.
            if Storage.presence(afterErrno: code) == .missing { throw RecordError.missing(.meta) }
            throw StorageError.io(step: "lock.open", errno: code)
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            if code == EWOULDBLOCK { throw RecordError.locked }
            throw StorageError.io(step: "lock.flock", errno: code)
        }
        return SessionLock(directory: directory, descriptor: descriptor)
    }

    func check(_ lock: SessionLock) throws {
        guard lock.directory == directory, lock.isHeld else { throw RecordError.lockNotHeld }
    }

    // MARK: Making and deleting

    /// Makes the directory and the parts that never change, then the counters of a session
    /// that has not sent anything. `counters` comes last: a directory without it is not a record
    /// (a crash on the way leaves something the coordinator deletes). Right after the directory
    /// is made it is excluded from backups (`RecordProtection.apply`, step `dir.protect`).
    ///
    /// The session directory must not exist. Making a record over an existing one would start
    /// its counters again under the same key (N1), so it is refused whoever asks; an existing
    /// record is opened or deleted. If a later step fails, what was made is removed again
    /// (nothing can have been sent), so the same id can be tried once more.
    ///
    /// - Parameter key: nil where the key is kept elsewhere (the iOS Keychain).
    /// - Returns: the lock, taken before anything is written.
    /// - Throws: `RecordError.exists`; storage errors.
    func create(meta: SessionMeta, key: Base64Key?) throws -> SessionLock {
        precondition(meta.id == id)
        let metaBytes = try meta.encoded()
        try storage.makeDirectory("..")
        do {
            try storage.makeDirectory(".")
        } catch StorageError.io(_, EEXIST) {
            throw RecordError.exists
        }
        // From here the directory is this call's own. (If somebody else takes its lock first,
        // it is theirs to remove: a cold start deletes a directory that is not a record.)
        let lock = try acquireLock()
        do {
            // Out of the backup before anything is in it. If that cannot be done there is no
            // record: its counters must never come back from a backup (see `RecordProtection`).
            try storage.protect(".") { try protection.apply(directory: directory) }
            if let key {
                try storage.replace("key", with: StoredKey.encode(key, id: id))
            }
            try storage.replace("meta", with: metaBytes)
            try storage.replace("counters", with: CountersFile.initialImage(sessionID: id))
            try storage.syncDirectory("..")
        } catch {
            try? delete()
            lock.release()
            throw error
        }
        return lock
    }

    /// Removes the record. The caller holds the lock (or knows that nobody else can).
    public func delete() throws {
        for file in ["snapshot", "snapshot.tmp", "counters", "counters.tmp", "meta", "meta.tmp", "key", "key.tmp", "lock"] {
            try storage.remove(file)
        }
        try storage.remove(".")
    }

    // MARK: Parts

    public func readMeta() throws -> SessionMeta {
        guard let bytes = try storage.read("meta", limit: 1 << 20) else { throw RecordError.missing(.meta) }
        return try SessionMeta(encoded: bytes, expecting: id)
    }

    public func readKey() throws -> Base64Key {
        guard let bytes = try storage.read("key", limit: 1 << 10) else { throw RecordError.missing(.key) }
        return try StoredKey.decode(bytes, expecting: id)
    }

    /// What the two counters slots say now.
    public func readCounters() throws -> CountersReading {
        guard let descriptor = try storage.openExisting("counters") else { throw RecordError.missing(.counters) }
        defer { close(descriptor) }
        return try readCounters(descriptor: descriptor)
    }

    func readCounters(descriptor: Int32) throws -> CountersReading {
        let slots = try (0..<2).map {
            try storage.read(descriptor: descriptor, file: "counters", count: CountersFile.slotSize,
                             offset: CountersFile.offset(ofSlot: $0))
        }
        return try CountersFile.read(slot0: slots[0], slot1: slots[1], sessionID: id)
    }

    /// The stored snapshot, whatever the counters say about it, or nil if there is none.
    /// `SessionRecord.loadSnapshot()` is the way to get a snapshot that may be used.
    func readSnapshot() throws -> StoredSnapshot? {
        guard let bytes = try storage.read("snapshot", limit: SnapshotCodec.maxFileSize) else { return nil }
        return try SnapshotCodec.decode(bytes, expecting: id)
    }

    /// Replaces the snapshot: the old one stays until the new one is complete and durable.
    func writeSnapshot(_ stored: StoredSnapshot, lock: SessionLock) throws {
        try check(lock)
        try storage.replace("snapshot", with: SnapshotCodec.encode(stored, sessionID: id))
    }
}
