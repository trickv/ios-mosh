// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import MoshWire

/// mosh's timing constants for the transport (transportsender.h, network.h, stmclient.cc).
public enum TransportConstants {
    /// `ACK_INTERVAL`: an empty ack goes out when nothing was sent for this long.
    public static let ackInterval: UInt64 = 3000
    /// `ACK_DELAY`: how long an ack for new data may wait for data to ride along with.
    public static let ackDelay: UInt64 = 100
    /// `SEND_MINDELAY` as the mosh client sets it (`network->set_send_delay( 1 )`): how long new
    /// input waits for more input before it is sent. The sender's own default is 8.
    public static let clientSendMinDelay: UInt64 = 1
    /// `SHUTDOWN_RETRIES`: shutdown instructions sent before giving up.
    public static let shutdownRetries = 16
    /// `ACTIVE_RETRY_TIMEOUT`: how long after the last new server state unacknowledged input is
    /// resent at the retransmission timeout; also the time limit of a shutdown.
    public static let activeRetryTimeout: UInt64 = 10_000
    /// `PORT_HOP_INTERVAL`: a new socket is wanted after this long without a round trip.
    public static let portHopInterval: UInt64 = 10_000
    /// Sender keeps at most this many states.
    public static let sentStatesLimit = 32
    /// Above this many held remote states the quench rule applies.
    public static let receivedStatesLimit = 1024
    /// Length of the quench window.
    public static let quenchInterval: UInt64 = 15_000
    /// A received timestamp is echoed only if it is younger than this.
    public static let timestampEchoLimit: UInt64 = 1000
    /// `CONGESTION_TIMESTAMP_PENALTY`.
    public static let congestionTimestampPenalty: UInt16 = 500
    /// After a failed gate call the next attempt waits this long.
    public static let gateRetryInterval: UInt64 = 1000
    /// Largest number of input events ahead of the acknowledged state that are put into states.
    /// Every diff is then at most this many events, which keeps it below the 4 MiB an mosh peer
    /// can expand (a resize is at most 12 bytes on the wire, a byte at most 7).
    public static let defaultUnacknowledgedInputLimit = 262_144
}

/// The address family of the server, which decides the datagram size (network.cc `set_MTU`).
public enum AddressFamily: Equatable, Sendable {
    case ipv4
    case ipv6

    /// Largest datagram a client sends to a server of this family: 1252 or 1216 bytes.
    public var datagramMTU: Int {
        switch self {
        case .ipv4: return WireConstants.ipv4DatagramMTU
        case .ipv6: return WireConstants.ipv6DatagramMTU
        }
    }
}

/// Settings of a `TransportCore`.
public struct TransportConfiguration: Sendable {
    /// Largest datagram to send. 1252 for IPv4, 1216 for IPv6.
    public var datagramMTU: Int
    /// How long new input waits for more input. mosh's client uses 1 ms.
    public var sendMinDelay: UInt64
    /// See `TransportConstants.defaultUnacknowledgedInputLimit`.
    public var unacknowledgedInputLimit: Int
    /// Report every server instruction that was applied and stored as `.instructionApplied`
    /// (for `moshcli --record`). Off by default.
    public var reportsInstructions = false
    /// The source of chaff (0 to 16 random bytes per instruction). Injected so that tests are
    /// deterministic.
    public var makeChaff: @Sendable () -> [UInt8]

    public init(
        family: AddressFamily = .ipv4,
        sendMinDelay: UInt64 = TransportConstants.clientSendMinDelay,
        unacknowledgedInputLimit: Int = TransportConstants.defaultUnacknowledgedInputLimit,
        makeChaff: @escaping @Sendable () -> [UInt8] = { Instruction.makeChaff() }
    ) {
        self.datagramMTU = family.datagramMTU
        self.sendMinDelay = sendMinDelay
        self.unacknowledgedInputLimit = max(1, unacknowledgedInputLimit)
        self.makeChaff = makeChaff
    }
}

/// A server instruction that was applied: the remote state `newNum` is the state `oldNum` plus
/// `diff` (a serialized `HostMessage`, possibly empty).
public struct AppliedInstruction: Equatable, Sendable {
    public var oldNum: UInt64
    public var newNum: UInt64
    public var diff: [UInt8]

    public init(oldNum: UInt64, newNum: UInt64, diff: [UInt8]) {
        self.oldNum = oldNum
        self.newNum = newNum
        self.diff = diff
    }
}

/// Something the owner of a `TransportCore` should know about.
public enum TransportEvent: Equatable, Sendable {
    /// Only with `TransportConfiguration.reportsInstructions`: a server instruction was applied
    /// and its state stored. Reported in arrival order, once per state number, also for states
    /// that arrive out of order. Comes before the `.remoteStateAdvanced` of the same state.
    case instructionApplied(AppliedInstruction)
    /// A new newest remote state is held: read it with `newestRemoteState`.
    case remoteStateAdvanced(number: UInt64)
    /// The server announced the end of the session (`new_num` = 2^64 - 1). The transport
    /// acknowledges it; nothing more will be sent after that.
    case serverShutdown
    /// Our acknowledgment of the server's shutdown has been handed to the socket.
    case serverShutdownAcknowledged
    /// The server acknowledged the shutdown we started.
    case shutdownAcknowledged
    /// The shutdown we started was not acknowledged within 16 sends or 10 s.
    case shutdownTimedOut
    /// The server builds its diffs on a state we do not hold (`old_num` equals `throwaway_num`
    /// and is not held): no later instruction can ever be applied. Nothing is damaged, but the
    /// screen is frozen for good. The owner falls back to a new session.
    case baseStateLost(serverBase: UInt64)
    /// No round trip for 10 s: the owner should replace the socket (mosh's port hop) and call
    /// `socketReplaced`.
    case socketReplacementWanted
    /// A send-side invariant did not hold. Nothing was sent and nothing will be: fall back.
    case internalError(InvariantViolation)
    /// The gate failed; the send is retried in a second.
    case gateFailed(String)
    /// An authenticated instruction that a correct server would not send (wrong protocol version,
    /// `throwaway_num` above `old_num`, a diff that does not parse). It was dropped.
    case peerProtocolError(String)
}

/// What a call of `TransportCore.tick` hands back.
public struct TransportOutput: Equatable, Sendable {
    /// Datagrams to send now, in order.
    public var datagrams: [[UInt8]] = []
    /// Events since the last tick, in order.
    public var events: [TransportEvent] = []
    /// When to call `tick` next (same clock as `now`), if nothing else happens first. A value
    /// at or below `now` means "at once". Nil: no timer is running (quiesced, halted or ended).
    public var nextWakeup: UInt64?

    public init() {}
}

/// What became of a received datagram.
public enum ReceiveResult: Equatable, Sendable {
    /// Decrypted under the session key, came from the server, and is newer than every datagram
    /// before it: the path it came on works. The owner may now drop an older socket.
    case authentic
    /// Authentic but numbered below a datagram already seen (reordered, or replayed). Its
    /// instruction was processed; like mosh, the core takes no timing or reachability from it.
    case authenticOutOfOrder
    /// Not from our server, or damaged: dropped without a trace.
    case rejected
    /// Not looked at, because the transport is quiesced.
    case ignored
}

/// Times, on the core's clock, for the "Last contact" banner.
public struct ContactTimes: Equatable, Sendable {
    /// When the newest remote state arrived (for a new or imported core: when it was made).
    /// mosh's `server_heard`.
    public var newestRemoteStateAt: UInt64
    /// When the acknowledged client state was sent. mosh's `server_acked`.
    public var acknowledgedStateSentAt: UInt64
    /// When the last authentic datagram of any kind arrived, if one did.
    public var lastAuthenticDatagramAt: UInt64?

    public init(newestRemoteStateAt: UInt64, acknowledgedStateSentAt: UInt64, lastAuthenticDatagramAt: UInt64?) {
        self.newestRemoteStateAt = newestRemoteStateAt
        self.acknowledgedStateSentAt = acknowledgedStateSentAt
        self.lastAuthenticDatagramAt = lastAuthenticDatagramAt
    }
}

/// What `MoshConnection.typeNotingLastSent(_:)` returns.
public struct TypeReceipt: Sendable, Equatable {
    /// Whether the bytes were taken (false once the session takes no more input).
    public var accepted: Bool
    /// The last sent state number read before the bytes were appended: mosh's
    /// `set_local_frame_sent( get_sent_state_last() )` (stmclient.cc:322, transportsender.h:154).
    public var lastSentStateNumber: UInt64

    public init(accepted: Bool, lastSentStateNumber: UInt64) {
        self.accepted = accepted
        self.lastSentStateNumber = lastSentStateNumber
    }
}

/// The sender's values local echo reads after every receive (stmclient.cc:298-299).
public struct SenderReadings: Sendable, Equatable {
    /// `get_sent_state_acked()` (transportsender.h:153)
    public var acknowledgedStateNumber: UInt64
    /// `send_interval()` (transportsender.cc:73-83): ceil(SRTT / 2) within 20...250 ms
    public var sendInterval: UInt32

    public init(acknowledgedStateNumber: UInt64, sendInterval: UInt32) {
        self.acknowledgedStateNumber = acknowledgedStateNumber
        self.sendInterval = sendInterval
    }
}

/// A remote state with its number.
public struct NumberedRemoteState<Remote: RemoteState>: Sendable {
    public var number: UInt64
    public var state: Remote

    public init(number: UInt64, state: Remote) {
        self.number = number
        self.state = state
    }
}

extension NumberedRemoteState: Equatable where Remote: Equatable {}

/// Everything needed to continue a session in a new process: the value `exportState()` returns
/// and `TransportCore(restoring:)` takes. Plain data; M6 decides how it is stored.
///
/// It is valid only as long as no datagram was sent after it was taken (the gate's dirty rule).
/// The clean mark for it is made with the token that `MoshConnection.exportState()` returns
/// beside it (`TransportExport`).
public struct TransportSnapshot<Remote: RemoteState>: Sendable {
    /// `A`: the newest client state the server acknowledged.
    public var acknowledgedStateNumber: UInt64
    /// The input events since `A`, in order: exactly what the server has not acknowledged.
    public var pendingInput: [UserEvent]
    /// Every held remote state, ascending by number. Never empty.
    public var remoteStates: [NumberedRemoteState<Remote>]
    /// The highest `ack_num` that was sent. Always the number of a held state.
    public var highestAckSent: UInt64
    /// The size last announced to the server, if any.
    public var terminalSize: TerminalSize?
    /// The first datagram sequence number, client state number and fragment id that had not been
    /// used when the snapshot was taken: everything below was sent, or taken from the gate.
    /// `init(restoring:)` refuses a gate whose reserved limits are below any of them, and the
    /// send point refuses a number below them, so that an import with the wrong gate cannot
    /// repeat a number (N1, N2, N4). They are a floor for checks, not a source of numbers: the
    /// numbers still come from the gate, which starts at the old reserved limits.
    public var usedCounters: GateCounters
    /// The sequence number the next datagram from the server must at least have to count as in
    /// order (mosh: `expected_receiver_seq`, network.cc:515-519, one counter for the life of the
    /// key). Without it a datagram recorded before the snapshot could be replayed after an
    /// import and be taken for contact with the server.
    public var receiverExpectedSequence: UInt64

    public init(
        acknowledgedStateNumber: UInt64,
        pendingInput: [UserEvent],
        remoteStates: [NumberedRemoteState<Remote>],
        highestAckSent: UInt64,
        terminalSize: TerminalSize?,
        usedCounters: GateCounters,
        receiverExpectedSequence: UInt64
    ) {
        self.acknowledgedStateNumber = acknowledgedStateNumber
        self.pendingInput = pendingInput
        self.remoteStates = remoteStates
        self.highestAckSent = highestAckSent
        self.terminalSize = terminalSize
        self.usedCounters = usedCounters
        self.receiverExpectedSequence = receiverExpectedSequence
    }
}

/// What the snapshot writer passes to `DurabilityGate.markClean(_:)` after it stored a snapshot.
///
/// It is made only by `MoshConnection.exportState()`, in the same actor call as the snapshot, so
/// it cannot belong to another moment than the snapshot does: if a datagram left after the
/// export (a `resume()` in between, at any point), the clean mark is refused. A count read
/// from the gate at another time does not have this property and must not be used.
public struct CleanToken: Equatable, Sendable {
    /// The gate's `datagramsPassed` when the snapshot was taken.
    public let datagramsPassed: UInt64

    public init(datagramsPassed: UInt64) {
        self.datagramsPassed = datagramsPassed
    }
}

/// A snapshot and the token for its clean mark: what `MoshConnection.exportState()` returns.
/// Store `snapshot`, then call `gate.markClean(cleanToken)`; the token is not stored.
public struct TransportExport<Remote: RemoteState>: Sendable {
    public var snapshot: TransportSnapshot<Remote>
    public var cleanToken: CleanToken

    public init(snapshot: TransportSnapshot<Remote>, cleanToken: CleanToken) {
        self.snapshot = snapshot
        self.cleanToken = cleanToken
    }
}

extension TransportExport: Equatable where Remote: Equatable {}

extension TransportSnapshot: Equatable where Remote: Equatable {}

/// Why a snapshot could not be taken or used.
public enum SnapshotError: Error, Equatable, Sendable {
    /// `exportState()` needs `quiesce()` first.
    case notQuiesced
    /// The session is over (either side shut down) or the transport halted on an internal error.
    case sessionEnded
    /// The snapshot holds no remote state, or the numbers are not strictly ascending.
    case remoteStatesInvalid
    /// The snapshot does not hold the state numbered `highestAckSent`: the server may build on it.
    case acknowledgedRemoteStateMissing(UInt64)
    /// A state number in the snapshot is 2^64 - 1.
    case reservedStateNumber
    /// The snapshot's `usedCounters` do not fit the rest of it: the state counter is not above
    /// the acknowledged state number, or the sequence counter is beyond 63 bits.
    case usedCountersInvalid
    /// The gate's reserved limits are below numbers the snapshot says were used: this gate does
    /// not continue the session the snapshot is from. Sending with it could repeat a sequence
    /// number, a state number or a fragment id, so nothing is built at all. Fall back.
    case gateBelowSnapshot(limits: GateCounters, used: GateCounters)
}
