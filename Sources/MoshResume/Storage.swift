import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The class below has methods named like these calls.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

private func systemRename(_ from: String, _ to: String) -> Int32 {
    rename(from, to)
}

/// One step of a change to a session record on disk: a system call on one file. Every step has
/// a name, `file.operation` (for example `counters.fsync`), so that a test or `moshcli
/// --crashpoint` can stop the process at exactly that step.
public struct StorageStep: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Operation: String, Equatable, Hashable, Sendable {
        case makeDirectory = "mkdir"
        case create
        case write
        case fsync
        case rename
        case remove
        /// The platform's protection of the session directory (`RecordProtection.apply`).
        case protect
    }

    /// The file's name inside the session directory (`counters`, `snapshot.tmp`, ...); `.` is
    /// the session directory itself and `..` the directory above it.
    public var file: String
    public var operation: Operation

    public init(file: String, operation: Operation) {
        self.file = file
        self.operation = operation
    }

    public var description: String {
        let name = file == "." ? "dir" : file == ".." ? "root" : file
        return "\(name).\(operation.rawValue)"
    }
}

/// What a `StorageHook` tells the storage layer to do at a step.
public enum StorageHookAction: Equatable, Sendable {
    /// Do the step.
    case proceed
    /// The process dies before the step: it is not done, and nothing after it is.
    case crashBefore
    /// The process dies right after the step.
    case crashAfter
    /// Only for a write: the first `bytes` bytes reach the file, then the process dies (a torn
    /// write). For other steps the same as `crashBefore`.
    case tornWrite(bytes: Int)
    /// The step fails with this error number and the process lives on (a locked device, a full
    /// disk). For a write, the first `bytes` bytes reach the file before the failure.
    case fail(errno: Int32, bytes: Int = 0)
}

/// Called before every step. Tests use it to play a crash; `moshcli --crashpoint` kills the
/// process inside it. After a played crash the storage refuses every further step, as a dead
/// process would do nothing more.
public typealias StorageHook = @Sendable (StorageStep) -> StorageHookAction

public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A system call failed. "Device locked" (`EPERM`, `EACCES`) is among these: try again later.
    case io(step: String, errno: Int32)
    /// A hook played a crash at this step.
    case simulatedCrash(step: String)
    /// A step was asked for after a played crash.
    case afterCrash
    /// The file is larger than anything this code writes.
    case tooLarge(file: String)

    public var description: String {
        switch self {
        case .io(let step, let code): return "\(step) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .simulatedCrash(let step): return "simulated crash at \(step)"
        case .afterCrash: return "storage used after a simulated crash"
        case .tooLarge(let file): return "\(file) is too large"
        }
    }
}

/// The few file operations a session record needs, each a plain POSIX call, with the hook in
/// front of every call that changes something. Nothing here is Linux-only.
final class Storage: @unchecked Sendable {
    let directory: String
    private let hook: StorageHook?
    private let lock = NSLock()
    private var crashed = false

    private let parent: String

    init(parent: String, name: String, hook: StorageHook?) {
        self.parent = parent
        self.directory = parent + "/" + name
        self.hook = hook
    }

    func path(_ file: String) -> String {
        switch file {
        case ".": return directory
        case "..": return parent
        default: return directory + "/" + file
        }
    }

    /// Runs one step under the hook. `body` gets the torn-write length, if the hook asked for one.
    private func step(_ file: String, _ operation: StorageStep.Operation, _ body: (Int?) throws -> Void) throws {
        let step = StorageStep(file: file, operation: operation)
        lock.lock()
        let dead = crashed
        lock.unlock()
        guard !dead else { throw StorageError.afterCrash }
        let action = hook?(step) ?? .proceed
        func die() -> StorageError {
            lock.lock()
            crashed = true
            lock.unlock()
            return .simulatedCrash(step: step.description)
        }
        switch action {
        case .proceed:
            try body(nil)
        case .crashBefore:
            throw die()
        case .crashAfter:
            try body(nil)
            throw die()
        case .tornWrite(let bytes):
            if operation == .write { try body(max(0, bytes)) }
            throw die()
        case .fail(let code, let bytes):
            if operation == .write, bytes > 0 { try body(bytes) }
            throw StorageError.io(step: step.description, errno: code)
        }
    }

    private func failure(_ file: String, _ what: String) -> StorageError {
        let code = errno
        let name = file == "." ? "dir" : file == ".." ? "root" : file
        return .io(step: "\(name).\(what)", errno: code)
    }

    // MARK: Reading (no hook: reading changes nothing)

    /// The whole file, or nil if it does not exist.
    func read(_ file: String, limit: Int) throws -> [UInt8]? {
        let descriptor = open(path(file), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if Self.presence(afterErrno: errno) == .missing { return nil }
            throw failure(file, "open")
        }
        defer { close(descriptor) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = chunk.withUnsafeMutableBytes { systemRead(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure(file, "read")
            }
            if count == 0 { return bytes }
            bytes.append(contentsOf: chunk[0..<count])
            guard bytes.count <= limit else { throw StorageError.tooLarge(file: file) }
        }
    }

    /// Up to `count` bytes at `offset`; fewer if the file ends there.
    func read(descriptor: Int32, file: String, count: Int, offset: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let result = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset + done))
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw failure(file, "read")
            }
            if result == 0 { break }
            done += result
        }
        return Array(bytes[0..<done])
    }

    /// What a failed look at a file says about whether the file is there.
    enum Presence: Equatable {
        /// It is not there.
        case missing
        /// It could not be found out (a denial, an I/O error, a path that does not resolve).
        /// Never to be read as "missing": the cold start deletes what is missing.
        case unknown
    }

    /// Only "no such file" means that a file is not there (review finding A-7).
    static func presence(afterErrno code: Int32) -> Presence {
        code == ENOENT ? .missing : .unknown
    }

    /// Whether the file (or directory) is there.
    /// - Throws: `StorageError.io` if that could not be found out.
    func exists(_ file: String) throws -> Bool {
        var info = stat()
        if lstat(path(file), &info) == 0 { return true }
        if Self.presence(afterErrno: errno) == .missing { return false }
        throw failure(file, "stat")
    }

    // MARK: Steps

    func makeDirectory(_ file: String) throws {
        try step(file, .makeDirectory) { _ in
            if file == ".." {
                // The root of all records may be several levels deep and usually exists.
                do {
                    try FileManager.default.createDirectory(
                        atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } catch {
                    throw StorageError.io(step: "root.mkdir", errno: EIO)
                }
                return
            }
            // An existing session directory is an error (`EEXIST`): a record is made once.
            guard mkdir(path(file), 0o700) == 0 else { throw failure(file, "mkdir") }
        }
    }

    /// Runs the platform's protection of a new session directory as a step of its own, so that
    /// a test can fail it or kill the process around it.
    func protect(_ file: String, _ body: () throws -> Void) throws {
        try step(file, .protect) { _ in
            do {
                try body()
            } catch let error as StorageError {
                throw error
            } catch {
                throw StorageError.io(step: StorageStep(file: file, operation: .protect).description, errno: EIO)
            }
        }
    }

    /// Opens for reading and writing without a hook (nothing changes on disk). Nil if the file
    /// does not exist; every other failure throws.
    func openExisting(_ file: String) throws -> Int32? {
        let descriptor = open(path(file), O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            if Self.presence(afterErrno: errno) == .missing { return nil }
            throw failure(file, "open")
        }
        return descriptor
    }

    /// Creates the file, or empties it, for writing. Owner-only.
    func create(_ file: String) throws -> Int32 {
        var descriptor: Int32 = -1
        try step(file, .create) { _ in
            descriptor = open(path(file), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw failure(file, "create") }
        }
        return descriptor
    }

    func write(descriptor: Int32, file: String, _ bytes: [UInt8], offset: Int) throws {
        try step(file, .write) { torn in
            let total = min(torn ?? bytes.count, bytes.count)
            var done = 0
            while done < total {
                let result = bytes.withUnsafeBytes {
                    pwrite(descriptor, $0.baseAddress! + done, total - done, off_t(offset + done))
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw failure(file, "write")
                }
                done += result
            }
        }
    }

    /// Durable: `F_FULLFSYNC` where it exists (on Apple platforms `fsync` alone leaves the data
    /// in the drive's cache), `fsync` elsewhere and for file systems that do not know it. A
    /// full sync that fails for any other reason is an error, not a reason to try `fsync`,
    /// whose success would then be reported as durable (review finding A-8).
    func sync(descriptor: Int32, file: String) throws {
        try step(file, .fsync) { _ in
            try Self.fullSync(descriptor) { failure(file, "fsync") }
        }
    }

    /// What to do when `fcntl(F_FULLFSYNC)` failed.
    enum FullSyncFailureAction: Equatable {
        /// Interrupted: call it again.
        case retry
        /// This descriptor's file system does not know the call: `fsync` is all there is.
        case fallBackToFsync
        /// A real failure: the data is not known to be durable, and `fsync` must not paper
        /// over it.
        case fail
    }

    /// The decision, apart from the call, so that it can be tested where there is no
    /// `F_FULLFSYNC`.
    static func afterFullSyncFailure(errno code: Int32) -> FullSyncFailureAction {
        if code == EINTR { return .retry }
        return fullSyncNotSupportedErrors.contains(code) ? .fallBackToFsync : .fail
    }

    /// The error numbers taken to mean "this file system has no full sync".
    ///
    /// Empty: there is no fallback on Darwin. Seen on charlie (macOS 26, 2026-11-14):
    /// `fcntl(F_FULLFSYNC)` returns 0 on a file and on a directory descriptor on APFS, and
    /// also on MS-DOS, ExFAT and HFS+ disk images. No file system at hand returned an error,
    /// so no error number is known to mean "not supported" (`ENOTSUP` and `ENOTTY` were
    /// guesses by name). The record lives on APFS (the app's container, the test
    /// directories); a full sync that fails there is a failure.
    static let fullSyncNotSupportedErrors: [Int32] = []

    /// Makes a descriptor's data durable with the calls given: the full sync if the platform
    /// has one, else (or if the file system does not know it) the plain one.
    /// - Returns: nil if durable, else the error number of the call that failed.
    static func durableSync(full: (() -> Int32)?, plain: () -> Int32, lastError: () -> Int32) -> Int32? {
        if let full {
            retrying: while true {
                if full() == 0 { return nil }
                let code = lastError()
                switch afterFullSyncFailure(errno: code) {
                case .retry: continue
                case .fallBackToFsync: break retrying
                case .fail: return code
                }
            }
        }
        while plain() != 0 {
            let code = lastError()
            if code != EINTR { return code }
        }
        return nil
    }

    private static func fullSync(_ descriptor: Int32, _ error: () -> StorageError) throws {
        #if canImport(Darwin)
        let full: (() -> Int32)? = { fcntl(descriptor, F_FULLFSYNC) }
        #else
        let full: (() -> Int32)? = nil
        #endif
        if let code = durableSync(full: full, plain: { fsync(descriptor) }, lastError: { errno }) {
            errno = code
            throw error()
        }
    }

    func rename(_ from: String, to: String) throws {
        try step(to, .rename) { _ in
            guard systemRename(path(from), path(to)) == 0 else { throw failure(to, "rename") }
        }
    }

    /// Makes a create, rename or remove inside the directory durable.
    func syncDirectory(_ file: String = ".") throws {
        try step(file, .fsync) { _ in
            let descriptor = open(path(file), O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure(file, "open") }
            defer { close(descriptor) }
            try Self.fullSync(descriptor) { failure(file, "fsync") }
        }
    }

    func remove(_ file: String) throws {
        try step(file, .remove) { _ in
            let result = file == "." ? rmdir(directory) : unlink(path(file))
            guard result == 0 || errno == ENOENT else { throw failure(file, "remove") }
        }
    }

    /// Replaces a whole file so that a reader sees the old content or the new one, never a mix:
    /// write `file.tmp`, fsync it, rename it over `file`, fsync the directory.
    func replace(_ file: String, with bytes: [UInt8]) throws {
        let temporary = file + ".tmp"
        let descriptor = try create(temporary)
        do {
            try write(descriptor: descriptor, file: temporary, bytes, offset: 0)
            try sync(descriptor: descriptor, file: temporary)
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
        try rename(temporary, to: file)
        try syncDirectory()
    }
}
