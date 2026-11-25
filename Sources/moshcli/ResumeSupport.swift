// What `moshcli connect --session-root` and `moshcli resume` share: the numbers log of
// `--seq-log`, `--crashpoint`, `--step-log`, and the coordinator's options.
import Foundation
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport

/// `--seq-log FILE` also writes `FILE.numbers`: every number taken from the durability gate, one
/// per line, as `seq N`, `state N` or `frag N`, appended across process generations. A line is
/// in the file before the number is used. `scripts/check-seq-log.sh` checks that each kind only
/// goes up (N1, N2 and N4 of docs/PLAN.md section 3).
final class NumbersLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CLIError("cannot create \(path)")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw CLIError("cannot open \(path) for writing")
        }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    /// For `--seq-log FILE`: `FILE.numbers`.
    static func beside(seqLog: String?) throws -> NumbersLog? {
        try seqLog.map { try NumbersLog(path: $0 + ".numbers") }
    }

    func write(_ kind: String, _ number: UInt64) {
        lock.lock()
        handle.write(Data("\(kind) \(number)\n".utf8))
        lock.unlock()
    }
}

/// A gate that passes every call on and logs the numbers it hands out.
final class LoggingGate: DurabilityGate, @unchecked Sendable {
    private let inner: any DurabilityGate
    private let log: NumbersLog

    init(_ inner: any DurabilityGate, log: NumbersLog) {
        self.inner = inner
        self.log = log
    }

    var reservedLimits: GateCounters { inner.reservedLimits }

    func takeSequenceNumber() throws -> UInt64 {
        let number = try inner.takeSequenceNumber()
        log.write("seq", number)
        return number
    }

    func takeStateNumber() throws -> UInt64 {
        let number = try inner.takeStateNumber()
        log.write("state", number)
        return number
    }

    func takeFragmentID() throws -> UInt64 {
        let number = try inner.takeFragmentID()
        log.write("frag", number)
        return number
    }

    func willSendDatagram() throws { try inner.willSendDatagram() }
    var datagramsPassed: UInt64 { inner.datagramsPassed }
    var isDirty: Bool { inner.isDirty }
    func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool { try inner.markClean(ifDatagramsPassed: expected) }
}

/// `--crashpoint SPEC`: where the process kills itself (SIGKILL) while it writes its record.
struct Crashpoint: Equatable {
    enum Target: Equatable {
        /// `#K`: the Kth storage step of the process, whatever it is.
        case ordinal(Int)
        /// `file.operation[:N]`: the Nth step with this name.
        case named(String, occurrence: Int)
    }

    enum Mode: Equatable {
        /// The step is not done.
        case before
        /// The step is done and nothing after it, on disk or on the wire.
        case after
        /// A write step: only this many bytes of it reach the file.
        case torn(Int)
    }

    var target: Target
    var mode: Mode

    static let help = """
        --crashpoint SPEC  kill this process (SIGKILL) at a storage step of its record. SPEC is
                           STEP[:N][:before|:after|:torn=BYTES] or '#K[:before|:after|:torn=BYTES]':
                           the Nth step named STEP (default the first), or the Kth step of any
                           name; before the step (default), after it (the step is done, nothing
                           after it is, on disk or on the wire), or in the middle of a write.
                           --crashpoint list prints the step names. Needs --session-root
        --step-log FILE    append each storage step as it starts: its number and its name

        """

    static let stepNames = """
        Storage steps, as --crashpoint and --step-log name them (docs/RESUME.md, "Storage steps"):
          making a record    root.mkdir dir.mkdir dir.protect, then key, meta and counters replaced,
                             root.fsync
          replacing X        X.tmp.create X.tmp.write X.tmp.fsync X.rename dir.fsync
                             (X is key, meta, counters or snapshot)
          a counters change  counters.write counters.fsync counters.write counters.fsync
                             (a reservation, "dirty" before a send, the cold start, "ended")
          a save (quiesce)   snapshot replaced, then counters.write counters.fsync (the clean mark)
        The order in one process: run it with --step-log FILE.

        """

    init(_ text: String) throws {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { throw CLIError("--crashpoint needs a step") }
        parts.removeFirst()
        var mode = Mode.before
        var occurrence = 1
        for part in parts {
            if part == "before" {
                mode = .before
            } else if part == "after" {
                mode = .after
            } else if part.hasPrefix("torn="), let bytes = Int(part.dropFirst(5)), bytes >= 0 {
                mode = .torn(bytes)
            } else if let number = Int(part), number >= 1 {
                occurrence = number
            } else {
                throw CLIError("--crashpoint: \(part) is not a count, before, after or torn=BYTES")
            }
        }
        if first.hasPrefix("#") {
            guard let ordinal = Int(first.dropFirst()), ordinal >= 1 else { throw CLIError("--crashpoint: \(first) is not #K") }
            target = .ordinal(ordinal)
        } else {
            guard first.contains(".") else { throw CLIError("--crashpoint: \(first) is not a step name (see --crashpoint list)") }
            target = .named(first, occurrence: occurrence)
        }
        self.mode = mode
    }
}

/// The storage hook of a moshcli process: logs the steps and dies at the crash point.
final class StorageWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let crashpoint: Crashpoint?
    private let stepLog: FileHandle?
    private var count = 0
    private var perName: [String: Int] = [:]
    private var dying = false

    init(crashpoint: Crashpoint?, stepLogPath: String?) throws {
        self.crashpoint = crashpoint
        if let stepLogPath {
            if !FileManager.default.fileExists(atPath: stepLogPath) {
                guard FileManager.default.createFile(atPath: stepLogPath, contents: nil) else {
                    throw CLIError("cannot create \(stepLogPath)")
                }
            }
            guard let handle = FileHandle(forWritingAtPath: stepLogPath) else {
                throw CLIError("cannot open \(stepLogPath) for writing")
            }
            handle.seekToEndOfFile()
            stepLog = handle
        } else {
            stepLog = nil
        }
    }

    var hook: StorageHook {
        { [self] step in
            lock.lock()
            defer { lock.unlock() }
            let name = step.description
            count += 1
            perName[name, default: 0] += 1
            guard !dying else { return .proceed }   // the storage refuses the step itself
            var hit = false
            switch crashpoint?.target {
            case .ordinal(let ordinal): hit = count == ordinal
            case .named(let wanted, let occurrence): hit = name == wanted && perName[name] == occurrence
            case nil: break
            }
            guard hit, let mode = crashpoint?.mode else {
                stepLog?.write(Data("\(count) \(name)\n".utf8))
                return .proceed
            }
            switch mode {
            case .before:
                stepLog?.write(Data("\(count) \(name) KILLED before\n".utf8))
                kill(getpid(), SIGKILL)
                while true { pause() }
            case .after:
                stepLog?.write(Data("\(count) \(name) KILLED after\n".utf8))
                dying = true
                dieSoon()
                return .crashAfter
            case .torn(let bytes):
                stepLog?.write(Data("\(count) \(name) KILLED torn=\(bytes)\n".utf8))
                dying = true
                dieSoon()
                return step.operation == .write ? .tornWrite(bytes: bytes) : .crashBefore
            }
        }
    }

    /// The storage layer plays the crash (the step is done, or half done, and every later step
    /// is refused, so no number is handed out and no datagram passes); the process itself goes
    /// a moment later.
    private func dieSoon() {
        StorageWatch.crashLock.lock()
        StorageWatch.crashPlayed = true
        StorageWatch.crashLock.unlock()
        Thread.detachNewThread {
            usleep(50_000)
            kill(getpid(), SIGKILL)
        }
    }

    private static let crashLock = NSLock()
    private nonisolated(unsafe) static var crashPlayed = false

    /// Called before moshcli exits on its own: a process whose crash point was reached must end
    /// by SIGKILL, not with an exit code, even if the error from the storage layer gets it to
    /// its end first.
    static func dieIfCrashPlayed() {
        crashLock.lock()
        let played = crashPlayed
        crashLock.unlock()
        if played {
            kill(getpid(), SIGKILL)
            while true { pause() }
        }
    }
}

/// The options about a session's record.
struct RecordFlags {
    static let valued: Set<String> = ["--session-root", "--crashpoint", "--step-log"]

    var root: String?
    var watch: StorageWatch?

    init(_ arguments: ArgumentList) throws {
        root = arguments.string("--session-root")
        let crashpoint = try arguments.string("--crashpoint").map { try Crashpoint($0) }
        let stepLog = arguments.string("--step-log")
        if crashpoint != nil || stepLog != nil {
            guard root != nil else { throw CLIError("--crashpoint and --step-log need --session-root") }
            watch = try StorageWatch(crashpoint: crashpoint, stepLogPath: stepLog)
        }
    }

    /// The coordinator's options for a moshcli session: datagrams through the tap, numbers
    /// through the log, storage steps through the watch.
    func options(endpoint: SessionEndpoint, tap: WireTap, numbers: NumbersLog?, noReplyTimeout: UInt64?,
                 prediction: PredictionSettings = .off) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.prediction = prediction
        options.storageHook = watch?.hook
        options.configuration = ScriptedSession.configuration(for: endpoint)
        options.noReplyTimeout = noReplyTimeout
        let host = endpoint.host, port = endpoint.port
        options.makeTransport = { try tap.open(host: host, port: port) }
        if let numbers {
            options.wrapGate = { LoggingGate($0, log: numbers) }
        }
        return options
    }
}
