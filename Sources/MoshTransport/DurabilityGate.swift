import Foundation

/// The three counters that must never go backwards for one session key.
public struct GateCounters: Equatable, Sendable {
    /// Datagram sequence numbers (the AES-OCB nonce; N1).
    public var sequence: UInt64
    /// State numbers of the client's own states (`new_num`; N2).
    public var state: UInt64
    /// Fragment (instruction) ids (N4).
    public var fragmentID: UInt64

    public init(sequence: UInt64, state: UInt64, fragmentID: UInt64) {
        self.sequence = sequence
        self.state = state
        self.fragmentID = fragmentID
    }

    /// What a new session starts with: mosh's first datagram is numbered 0, its first new state
    /// 1 (state 0 is the empty state both sides start from) and its first fragment id 1.
    public static let sessionStart = GateCounters(sequence: 0, state: 1, fragmentID: 1)
}

/// Where every number that goes on the wire comes from (docs/PLAN.md section 3, "Rules").
///
/// The transport never computes "last number + 1". It asks the gate, and the gate answers only
/// with numbers below a limit it has already made durable, so that a process that is killed and
/// started again from the stored limits can never repeat one. Until M6 the only implementation is
/// `InMemoryGate`; the file-backed gate (`counters` with two slots and `F_FULLFSYNC`) is another
/// implementation of this protocol.
///
/// Rules an implementation must keep:
///
/// - **Reserve ahead.** A `take…` call returns a number that is below the matching durable limit,
///   raising the limit first (and making that durable) when the block is used up. It never returns
///   a number twice. A new process starts at the stored limits (`reservedLimits` of the old one).
/// - **Dirty before send.** `willSendDatagram()` is called by the transport's single send point
///   for every datagram, before the datagram can reach a socket. The first call after a snapshot
///   was taken or loaded must make `dirty = 1` durable before it returns.
/// - **Clean only if nothing was sent.** `markClean(ifDatagramsPassed:)` writes `dirty = 0` only
///   if no datagram passed since the count was read; the check and the write are one critical
///   section. The snapshot writer does not read the count itself: it uses the `CleanToken` that
///   `MoshConnection.exportState()` returns with the snapshot (`markClean(_:)`).
///
/// If a call throws, nothing is sent and the transport tries again later ("device locked" is a
/// reason to wait, not a dead session).
///
/// The transport calls the gate from one place at a time; the snapshot writer may call
/// `datagramsPassed` and `markClean` from elsewhere, so implementations are thread-safe.
public protocol DurabilityGate: AnyObject, Sendable {
    /// The durable limits: no sequence number, state number or fragment id at or above its limit
    /// may be used. The transport checks every number against these before it sends.
    var reservedLimits: GateCounters { get }

    /// The next datagram sequence number.
    func takeSequenceNumber() throws -> UInt64
    /// The next state number for a new client state.
    func takeStateNumber() throws -> UInt64
    /// The next fragment id.
    func takeFragmentID() throws -> UInt64

    /// A datagram is about to leave. See "Dirty before send".
    func willSendDatagram() throws

    /// How many datagrams have passed `willSendDatagram()` since the gate was made.
    var datagramsPassed: UInt64 { get }

    /// Whether a datagram has passed since the last snapshot was taken or loaded.
    var isDirty: Bool { get }

    /// Marks the session record clean (`dirty = 0`) if `datagramsPassed` still equals `expected`.
    /// Returns false, and changes nothing, if a datagram passed in between.
    func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool
}

extension DurabilityGate {
    /// Marks the session record clean for the snapshot this token was exported with
    /// (`MoshConnection.exportState()`). Returns false, and changes nothing, if a datagram
    /// passed since the export: the snapshot is stale and the record stays dirty.
    public func markClean(_ token: CleanToken) throws -> Bool {
        try markClean(ifDatagramsPassed: token.datagramsPassed)
    }
}

/// A gate that keeps its counters in memory: the rules of `DurabilityGate` with nothing written
/// to disk. For sessions that are not resumable across a process death (everything before M6) and
/// for tests.
///
/// It still reserves in blocks, so that a test can play "the process died": make a new gate with
/// `InMemoryGate(startingAt: old.reservedLimits)` and every number jumps ahead to the old limits,
/// as it will with the file-backed gate.
public final class InMemoryGate: DurabilityGate, @unchecked Sendable {
    /// Block sizes from the plan: 65,536 sequence numbers, 1,024 state numbers and fragment ids.
    public static let defaultBlocks = GateCounters(sequence: 65_536, state: 1_024, fragmentID: 1_024)

    private let lock = NSLock()
    private let blocks: GateCounters
    private var next: GateCounters
    private var limits: GateCounters
    private var passed: UInt64 = 0
    private var dirty: Bool

    /// - Parameters:
    ///   - start: the first numbers handed out. For a resumed session: the old gate's
    ///     `reservedLimits`.
    ///   - blocks: how many numbers one reservation covers.
    ///   - dirty: the initial dirty flag. A new session has no snapshot, so it starts dirty.
    public init(startingAt start: GateCounters = .sessionStart, blocks: GateCounters = InMemoryGate.defaultBlocks, dirty: Bool = true) {
        self.blocks = GateCounters(sequence: max(1, blocks.sequence), state: max(1, blocks.state), fragmentID: max(1, blocks.fragmentID))
        self.next = start
        self.limits = start
        self.dirty = dirty
    }

    public var reservedLimits: GateCounters {
        lock.lock()
        defer { lock.unlock() }
        return limits
    }

    public func takeSequenceNumber() throws -> UInt64 {
        try take(\.sequence)
    }

    public func takeStateNumber() throws -> UInt64 {
        try take(\.state)
    }

    public func takeFragmentID() throws -> UInt64 {
        try take(\.fragmentID)
    }

    private func take(_ counter: WritableKeyPath<GateCounters, UInt64>) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if next[keyPath: counter] >= limits[keyPath: counter] {
            // Reserve the next block. A file-backed gate makes the new limit durable here.
            let (limit, overflow) = limits[keyPath: counter].addingReportingOverflow(blocks[keyPath: counter])
            guard !overflow else { throw GateError.exhausted }
            limits[keyPath: counter] = limit
        }
        let value = next[keyPath: counter]
        next[keyPath: counter] = value + 1
        return value
    }

    public func willSendDatagram() throws {
        lock.lock()
        defer { lock.unlock() }
        dirty = true
        passed += 1
    }

    public var datagramsPassed: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return passed
    }

    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }

    public func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard passed == expected else { return false }
        dirty = false
        return true
    }
}

/// Errors a gate can throw on its own account.
public enum GateError: Error, Equatable, Sendable {
    /// A counter reached the end of its range.
    case exhausted
}
