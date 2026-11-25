// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import MoshCrypto
import MoshWire

/// The mosh client transport as a deterministic state machine: a port of mosh 1.4.0's
/// `Network::Connection` (client side), `TransportSender<UserStream>` and `Transport::recv`.
///
/// No sockets, no threads, no clock: the owner passes the time (milliseconds on any monotonic
/// clock that starts well above zero) with every call, and `tick` hands back the datagrams to
/// send, the time of the next wake-up, and events. The same inputs give the same outputs.
///
/// How to drive it (this is mosh's main loop in `STMClient::main`):
///
///     core.receive(datagram: d, now: t)     // for each datagram that arrived
///     core.type(bytes) / core.resize(size)  // for user input
///     let out = core.tick(now: t)           // always, after any of the above and on the timer
///     send out.datagrams; handle out.events; sleep until out.nextWakeup
///
/// Every datagram is made by the one `Outbox`, which takes its numbers from the `DurabilityGate`
/// and refuses anything that would break N1 to N4.
public struct TransportCore<Remote: RemoteState>: Sendable {
    // MARK: Parts

    private let configuration: TransportConfiguration
    /// The single send point. Internal so that tests can reach its hooks.
    var outbox: Outbox
    private let cipher: MoshCipher

    // MARK: Sender (TransportSender)

    private struct SentState {
        /// When it was last sent.
        var timestamp: UInt64
        var num: UInt64
        /// The input it contains (index into the log).
        var end: UInt64
    }

    /// Everything the user did (mosh: `current_state`).
    private var log = InputLog()
    /// First: the acknowledged state. Last: the last state sent.
    private var sentStates: [SentState]
    /// Index of the state the receiver is assumed to hold (mosh: `assumed_receiver_state`).
    private var assumedIndex = 0
    /// Nil is mosh's `uint64_t(-1)`: never.
    private var nextAckTime: UInt64?
    private var nextSendTime: UInt64?
    /// Time of the first change to the current state that has not been sent.
    private var mindelayClock: UInt64?
    /// What we acknowledge: the newest remote state, or 2^64 - 1 after a server shutdown.
    private var ackNum: UInt64
    private var pendingDataAck = false
    /// When the newest remote state arrived (mosh: the sender's `last_heard`). Nil is mosh's 0.
    private var senderLastHeard: UInt64?
    private var shutdownInProgress = false
    private var shutdownTries = 0
    private var shutdownStart: UInt64 = 0
    /// The input the shutdown state contains, fixed when the shutdown starts (mosh: the current
    /// state cannot change while `shutdown_in_progress`, transportsender.h:140).
    private var shutdownTarget: UInt64?
    /// After an import or a new socket: nothing authentic has arrived yet, so empty acks are
    /// repeated every RTO + `ACK_DELAY` instead of every 3 s (within the 10 s window). That is
    /// 1.1 s with a fresh estimator (after an import) and as little as 150 ms once round trips
    /// were measured on a fast link: the rate at which mosh resends pending data
    /// (transportsender-impl.h:114-116), not "once a second".
    private var probing = false
    private var currentSize: TerminalSize?
    private var datagramMTU: Int

    // MARK: Receiver (Transport)

    private struct ReceivedState {
        var timestamp: UInt64
        var num: UInt64
        var state: Remote
    }

    /// Ascending by number. Never empty.
    private var receivedStates: [ReceivedState]
    private var receiverQuenchTimer: UInt64 = 0
    private var assembly = FragmentAssembly()
    /// The highest `throwaway_num` acted on: an instruction with a lower one is old.
    private var highestThrowaway: UInt64
    private var serverShutdownSeen = false
    private var serverShutdownAckPending = false
    private var serverShutdownAckSent = false
    private var finalState: Remote?
    private var baseStateLostReported = false

    // MARK: Connection

    public private(set) var rtt = RTTEstimator()
    private var expectedReceiverSeq: UInt64 = 0
    private var savedTimestamp: (value: UInt16, receivedAt: UInt64)?
    private var lastHeard: UInt64?
    private var lastPortChoice: UInt64
    private var lastRoundtripSuccess: UInt64?

    // MARK: Lifecycle

    public private(set) var isQuiesced = false
    /// An invariant was violated: nothing is sent any more.
    public private(set) var isHalted = false
    /// The session is over: a shutdown was acknowledged or timed out.
    public private(set) var hasEnded = false
    private var gateRetryTime: UInt64?
    private var events: [TransportEvent] = []
    private var lastNow: UInt64

    // MARK: Making one

    /// A new session.
    ///
    /// - Parameters:
    ///   - initialSize: announced to the server as the first input event (mosh's client always
    ///     starts with a Resize).
    ///   - now: the current time; must be well above zero (mosh uses 0 and -1 as "never").
    ///   - initialRemoteState: the remote state numbered 0, which must equal what the server's
    ///     state 0 is (mosh's `Transport` constructor takes it as `initial_remote`; for a terminal
    ///     it is a blank screen of the server's starting size). nil means `Remote()`.
    public init(
        cipher: MoshCipher,
        gate: any DurabilityGate,
        configuration: TransportConfiguration = TransportConfiguration(),
        initialSize: TerminalSize?,
        initialRemoteState: Remote? = nil,
        now: UInt64
    ) {
        self.configuration = configuration
        self.cipher = cipher
        self.datagramMTU = configuration.datagramMTU
        self.outbox = Outbox(cipher: cipher, gate: gate, baseNum: 0, baseEnd: 0, highestAckSent: 0)
        self.sentStates = [SentState(timestamp: now, num: 0, end: 0)]
        self.receivedStates = [ReceivedState(timestamp: now, num: 0, state: initialRemoteState ?? Remote())]
        self.ackNum = 0
        self.highestThrowaway = 0
        self.nextAckTime = now
        self.nextSendTime = now
        self.lastPortChoice = now
        self.lastNow = now
        if let initialSize {
            log.append(.resize(initialSize))
            currentSize = initialSize
        }
    }

    /// Continues a session from a snapshot (docs/PLAN.md section 3, "Cold start with a record",
    /// steps 4 to 6).
    ///
    /// The receiver holds the snapshot's remote states. The sender holds one state: `A` with no
    /// input and an old timestamp; the pending input is its current state. The first `tick`
    /// therefore sends
    ///
    /// - with pending input: `new_num` = the gate's next state number, `old_num` = `A`,
    ///   `throwaway_num` = `A`, `ack_num` = the newest remote state, and a diff of the pending
    ///   input. Retransmissions reuse that number; new input gets the next one;
    /// - with nothing pending: an empty ack with the same numbers.
    ///
    /// "Last heard" is now, so a lost first datagram is retried every RTO + 100 ms for 10 s. The
    /// estimator of an import is fresh (RTO 1000 ms), so that is every 1.1 s until the first
    /// round-trip sample.
    ///
    /// Throws `SnapshotError.gateBelowSnapshot` if the gate's reserved limits are below the
    /// snapshot's `usedCounters`: such a gate does not continue this session, and its numbers
    /// could repeat ones already on the wire (N1, N2, N4). A gate with limits that pass and
    /// numbers that do not is stopped at the first send by the Outbox, which starts from the same
    /// counters. Neither check can tell a stale snapshot from a fresh one; that is the gate's
    /// dirty rule.
    ///
    /// - Parameters:
    ///   - gate: a gate that starts at the old reserved limits.
    ///   - currentSize: the size of the view now. If it differs from the snapshot's, a Resize is
    ///     added to the pending input.
    public init(
        restoring snapshot: TransportSnapshot<Remote>,
        cipher: MoshCipher,
        gate: any DurabilityGate,
        configuration: TransportConfiguration = TransportConfiguration(),
        currentSize: TerminalSize?,
        now: UInt64
    ) throws {
        guard !snapshot.remoteStates.isEmpty else { throw SnapshotError.remoteStatesInvalid }
        for (index, held) in snapshot.remoteStates.enumerated() {
            guard held.number != Instruction.shutdownNum else { throw SnapshotError.reservedStateNumber }
            if index > 0, snapshot.remoteStates[index - 1].number >= held.number {
                throw SnapshotError.remoteStatesInvalid
            }
        }
        guard snapshot.acknowledgedStateNumber != Instruction.shutdownNum else {
            throw SnapshotError.reservedStateNumber
        }
        guard snapshot.remoteStates.contains(where: { $0.number == snapshot.highestAckSent }) else {
            throw SnapshotError.acknowledgedRemoteStateMissing(snapshot.highestAckSent)
        }
        let used = snapshot.usedCounters
        guard used.state > snapshot.acknowledgedStateNumber, used.sequence <= MoshCipher.maxSequence + 1 else {
            throw SnapshotError.usedCountersInvalid
        }
        let limits = gate.reservedLimits
        guard limits.sequence >= used.sequence, limits.state >= used.state, limits.fragmentID >= used.fragmentID else {
            throw SnapshotError.gateBelowSnapshot(limits: limits, used: used)
        }

        self.configuration = configuration
        self.cipher = cipher
        self.datagramMTU = configuration.datagramMTU
        self.outbox = Outbox(
            cipher: cipher,
            gate: gate,
            baseNum: snapshot.acknowledgedStateNumber,
            baseEnd: 0,
            highestAckSent: snapshot.highestAckSent,
            usedBefore: used
        )
        self.expectedReceiverSeq = snapshot.receiverExpectedSequence
        // Old enough that the receiver is not assumed to have anything newer than A.
        let longAgo = 2 * (RTTEstimator.maximumRTO + TransportConstants.ackDelay)
        self.sentStates = [SentState(timestamp: now > longAgo ? now - longAgo : 0, num: snapshot.acknowledgedStateNumber, end: 0)]
        self.receivedStates = snapshot.remoteStates.map { ReceivedState(timestamp: now, num: $0.number, state: $0.state) }
        self.ackNum = snapshot.remoteStates[snapshot.remoteStates.count - 1].number
        self.highestThrowaway = snapshot.remoteStates[0].number
        self.nextAckTime = now
        self.nextSendTime = now
        self.lastPortChoice = now
        self.lastNow = now
        self.senderLastHeard = now
        self.probing = true
        for event in snapshot.pendingInput {
            log.append(event)
        }
        self.currentSize = snapshot.terminalSize
        if let currentSize, currentSize != snapshot.terminalSize {
            log.append(.resize(currentSize))
            self.currentSize = currentSize
        }
    }

    // MARK: Inputs

    /// The user typed (or pasted) these bytes. Returns false if the session no longer takes input
    /// (a shutdown has begun, or the transport halted). Call `tick` afterwards.
    @discardableResult
    public mutating func type(_ bytes: some Sequence<UInt8>) -> Bool {
        guard acceptsInput else { return false }
        log.append(bytes: bytes)
        return true
    }

    /// The terminal view has this size now. Like mosh, this does not compare with the last size:
    /// every call is an event. Call `tick` afterwards.
    @discardableResult
    public mutating func resize(_ size: TerminalSize) -> Bool {
        guard acceptsInput else { return false }
        log.append(.resize(size))
        currentSize = size
        return true
    }

    /// Whether `type` and `resize` are accepted. Input is still accepted while quiesced; it is
    /// sent after `unquiesce`.
    public var acceptsInput: Bool {
        !(shutdownInProgress || serverShutdownSeen || hasEnded || isHalted)
    }

    /// A datagram arrived. Never throws and never traps, whatever the bytes are. Call `tick`
    /// afterwards.
    ///
    /// - Parameter congestionExperienced: the datagram's IP header carried ECN "congestion
    ///   experienced". mosh then echoes the timestamp 500 ms older, which slows the server down.
    @discardableResult
    public mutating func receive(datagram: [UInt8], now time: UInt64, congestionExperienced: Bool = false) -> ReceiveResult {
        let now = clock(time)
        guard !isQuiesced else { return .ignored }
        guard let packet = try? Packet(decrypting: datagram, with: cipher), packet.direction == .toClient else {
            return .rejected
        }
        // mosh: "don't use (but do return) out-of-order packets for timestamp or targeting".
        let inOrder = packet.seq >= expectedReceiverSeq
        if inOrder {
            expectedReceiverSeq = packet.seq &+ 1
            if packet.timestamp != Timestamp16.none {
                var value = packet.timestamp
                if congestionExperienced {
                    value &-= TransportConstants.congestionTimestampPenalty
                }
                savedTimestamp = (value: value, receivedAt: now)
            }
            if packet.timestampReply != Timestamp16.none {
                rtt.addSample(now: Timestamp16.now(milliseconds: now), timestampReply: packet.timestampReply)
            }
            lastHeard = now
            probing = false
        }
        process(payload: packet.payload, now: now)
        return inOrder ? .authentic : .authenticOutOfOrder
    }

    /// The owner replaced the socket (mosh's `hop_port`, or a new network path).
    ///
    /// - Parameter probe: true when the owner expects the server to be reachable now (back in the
    ///   foreground, a new path): an ack goes out at once so that the server learns the new
    ///   address, and retries follow every RTO + 100 ms for 10 s or until an authentic datagram
    ///   arrives in order. With the RTT this session has measured that is between 150 ms (fast
    ///   link) and 1.1 s, so up to 68 empty acks, each a new state number, when the server stays
    ///   silent. False for the periodic port hop the core asked for itself, which keeps mosh's
    ///   timing.
    public mutating func socketReplaced(now time: UInt64, probe: Bool) {
        let now = clock(time)
        lastPortChoice = now
        if probe {
            senderLastHeard = now
            probing = true
            if let ack = nextAckTime, ack > now {
                nextAckTime = now
            }
        }
    }

    /// The socket refused a datagram as too long (`EMSGSIZE`). Like mosh, fall back to 500-byte
    /// datagrams for the rest of the session.
    public mutating func datagramTooLarge() {
        datagramMTU = min(datagramMTU, WireConstants.defaultSendMTU)
    }

    /// Starts a shutdown from our side (mosh: `start_shutdown`). No input is accepted afterwards.
    ///
    /// Returns true if a shutdown is running after the call: its outcome arrives as
    /// `.shutdownAcknowledged` or `.shutdownTimedOut`. Returns false, and no event follows, if
    /// the session is already over (a shutdown finished, the server shut down) or the transport
    /// halted.
    ///
    /// The state the server is asked to end on is fixed here: everything typed so far, but no
    /// more than the input window allows ahead of the acknowledged state. Input beyond the
    /// window (more than `unacknowledgedInputLimit` unacknowledged events, a paste above 256 KiB
    /// followed at once by a disconnect) is not sent. mosh has no window and would send it all.
    ///
    /// While quiesced nothing is sent; the 10 s limit starts at `unquiesce`.
    @discardableResult
    public mutating func startShutdown(now time: UInt64) -> Bool {
        let now = clock(time)
        if shutdownInProgress, !hasEnded, !isHalted { return true }
        guard !hasEnded, !isHalted, !serverShutdownSeen else { return false }
        shutdownTarget = targetEnd
        shutdownInProgress = true
        shutdownStart = now
        return true
    }

    /// Stops all sends. `tick` returns no datagrams and no wake-up until `unquiesce`, and received
    /// datagrams are ignored, so the state stays as `exportState()` saw it. The owner closes the
    /// socket.
    public mutating func quiesce() {
        isQuiesced = true
    }

    /// Continues after `quiesce` with the state in memory. The owner has opened a new socket.
    ///
    /// A shutdown that was started before or during the quiesce gets its full 10 s from here
    /// (mosh has no quiesce; its limit is 10 s of trying, transportsender-impl.h:386-391). The
    /// tries already made still count.
    public mutating func unquiesce(now: UInt64) {
        guard isQuiesced else { return }
        isQuiesced = false
        socketReplaced(now: now, probe: true)
        if shutdownInProgress {
            shutdownStart = lastNow
        }
    }

    // MARK: Tick

    /// Sends what is due (mosh: `TransportSender::tick`) and reports events and the next wake-up.
    public mutating func tick(now time: UInt64) -> TransportOutput {
        let now = clock(time)
        var output = TransportOutput()
        if canSend {
            checkShutdownTimeout(now: now)
        }
        if canSend, gateRetryTime.map({ now >= $0 }) ?? true {
            gateRetryTime = nil
            do {
                try runSender(now: now, into: &output.datagrams)
            } catch {
                sendFailed(error, now: now, output: &output)
            }
        }
        output.events = events
        events.removeAll()
        output.nextWakeup = wakeup(now: now)
        return output
    }

    /// Sends the current state now if the server has not acknowledged all of it, whatever the
    /// send timers say (the 8 ms collection delay, the send interval, the retransmission
    /// timeout). The diff is taken from the acknowledged state, the one base the server is
    /// certain to hold. Sends nothing if nothing is unacknowledged.
    ///
    /// For `quiesce --after-send`: the owner calls this and then `quiesce()` with nothing in
    /// between, which leaves a snapshot whose pending input the server may or may not have. That
    /// is the case a resume must get right (the input must arrive exactly once).
    public mutating func sendPendingNow(now time: UInt64) -> TransportOutput {
        let now = clock(time)
        var output = TransportOutput()
        if canSend, !shutdownInProgress, !serverShutdownSeen {
            calculateTimers(now: now)
            let target = targetEnd
            if target != sentStates[0].end {
                gateRetryTime = nil
                assumedIndex = 0
                do {
                    try sendToReceiver(now: now, target: target, into: &output.datagrams)
                    mindelayClock = nil
                } catch {
                    sendFailed(error, now: now, output: &output)
                }
            }
        }
        output.events = events
        events.removeAll()
        output.nextWakeup = wakeup(now: now)
        return output
    }

    /// A send threw: nothing of that instruction leaves. A gate error is retried later, anything
    /// else halts the transport.
    private mutating func sendFailed(_ error: Error, now: UInt64, output: inout TransportOutput) {
        output.datagrams.removeAll()
        switch error {
        case OutboxError.violation(let violation):
            isHalted = true
            events.append(.internalError(violation))
        case OutboxError.gate(let description):
            gateRetryTime = now + TransportConstants.gateRetryInterval
            events.append(.gateFailed(description))
        default:
            isHalted = true
            events.append(.internalError(.encodingFailed("\(error)")))
        }
    }

    private var canSend: Bool {
        !(isQuiesced || isHalted || hasEnded)
    }

    private mutating func wakeup(now: UInt64) -> UInt64? {
        guard canSend else { return nil }
        if let retry = gateRetryTime {
            return retry
        }
        calculateTimers(now: now)
        var wake = min(nextAckTime ?? UInt64.max, nextSendTime ?? UInt64.max)
        if shutdownInProgress {
            wake = min(wake, shutdownStart + TransportConstants.activeRetryTimeout)
        }
        return wake == UInt64.max ? nil : wake
    }

    /// Times never go backwards inside the core, so no subtraction below can underflow.
    private mutating func clock(_ now: UInt64) -> UInt64 {
        lastNow = max(lastNow, now)
        return lastNow
    }

    // MARK: Sender

    /// The state that would be sent now: everything the user did, but no further ahead of the
    /// acknowledged state than the limit, so that no diff can outgrow what a peer can expand.
    /// Fixed once a shutdown has started.
    private var targetEnd: UInt64 {
        if let shutdownTarget { return shutdownTarget }
        return min(log.end, sentStates[0].end + UInt64(configuration.unacknowledgedInputLimit))
    }

    /// mosh: `calculate_timers`.
    private mutating func calculateTimers(now: UInt64) {
        updateAssumedReceiverState(now: now)
        rationalizeStates()

        if pendingDataAck, (nextAckTime ?? UInt64.max) > now + TransportConstants.ackDelay {
            nextAckTime = now + TransportConstants.ackDelay
        }

        let target = targetEnd
        let back = sentStates[sentStates.count - 1]
        let activeRetry = senderLastHeard.map { $0 + TransportConstants.activeRetryTimeout > now } ?? false
        if target != back.end {
            let started = mindelayClock ?? now
            mindelayClock = started
            nextSendTime = max(started + configuration.sendMinDelay, back.timestamp + rtt.sendInterval)
        } else if target != sentStates[assumedIndex].end, activeRetry {
            var time = back.timestamp + rtt.sendInterval
            if let started = mindelayClock {
                time = max(time, started + configuration.sendMinDelay)
            }
            nextSendTime = time
        } else if target != sentStates[0].end, activeRetry {
            nextSendTime = back.timestamp + rtt.timeout + TransportConstants.ackDelay
        } else {
            nextSendTime = nil
        }

        // "speed up shutdown sequence"
        if shutdownInProgress || serverShutdownAckPending {
            nextAckTime = back.timestamp + rtt.sendInterval
        } else if serverShutdownSeen {
            // The server is gone and has our acknowledgment: nothing more to say, unless it asks
            // again.
            nextAckTime = nil
            nextSendTime = nil
        }
    }

    /// mosh: `update_assumed_receiver_state`. "Start from what is known and give benefit of the
    /// doubt to unacknowledged states transmitted recently enough ago."
    ///
    /// The shutdown state is never the assumed state: 2^64 - 1 is not a state number a diff can
    /// be based on here (the Outbox refuses it). mosh does send `old_num` = `new_num` = 2^64 - 1
    /// with an empty diff while its shutdown state is recent (transportsender-impl.h:212-221,
    /// 325); a server that could use it holds the shutdown state already. Here the base is the
    /// newest recent ordinary state, or the acknowledged one, so every repeat can be applied.
    private mutating func updateAssumedReceiverState(now: UInt64) {
        assumedIndex = 0
        for index in sentStates.indices.dropFirst() where sentStates[index].num != Instruction.shutdownNum {
            if now - sentStates[index].timestamp < rtt.timeout + TransportConstants.ackDelay {
                assumedIndex = index
            } else {
                return
            }
        }
    }

    /// mosh: `rationalize_states` ("cut out common prefix of all states"). With states kept as
    /// indices into one log this only frees the input the server has acknowledged.
    private mutating func rationalizeStates() {
        log.discard(before: sentStates[0].end)
    }

    /// mosh: `TransportSender::tick` after its first line.
    private mutating func runSender(now: UInt64, into datagrams: inout [[UInt8]]) throws {
        calculateTimers(now: now)
        guard now >= (nextAckTime ?? UInt64.max) || now >= (nextSendTime ?? UInt64.max) else { return }

        let target = targetEnd
        attemptProspectiveResendOptimization(target: target)

        if target == sentStates[assumedIndex].end {
            // Nothing to tell: an empty ack if one is due.
            if let ack = nextAckTime, now >= ack {
                try sendEmptyAck(now: now, target: target, into: &datagrams)
                mindelayClock = nil
            }
            if let send = nextSendTime, now >= send {
                nextSendTime = nil
                mindelayClock = nil
            }
        } else {
            try sendToReceiver(now: now, target: target, into: &datagrams)
            mindelayClock = nil
        }
    }

    /// mosh: `attempt_prospective_resend_optimization`. "We do a prophylactic resend if it would
    /// make the diff shorter, or if it would lengthen it by no more than 100 bytes and still be
    /// less than 1000 bytes."
    private mutating func attemptProspectiveResendOptimization(target: UInt64) {
        guard assumedIndex != 0 else { return }
        let frontEnd = sentStates[0].end
        let assumedEnd = sentStates[assumedIndex].end
        if frontEnd == assumedEnd {
            // The two diffs are the same bytes.
            assumedIndex = 0
            return
        }
        // Every event is at least one byte on the wire: a diff of 1000 events cannot qualify.
        guard target - frontEnd < 1000,
              let proposed = log.diff(from: assumedEnd, to: target),
              let resend = log.diff(from: frontEnd, to: target) else { return }
        if resend.count <= proposed.count || (resend.count < 1000 && resend.count - proposed.count < 100) {
            assumedIndex = 0
        }
    }

    /// mosh: `send_empty_ack`. An empty ack is a new state with the same content.
    private mutating func sendEmptyAck(now: UInt64, target: UInt64, into datagrams: inout [[UInt8]]) throws {
        let saved = (sentStates, assumedIndex)
        do {
            let back = sentStates[sentStates.count - 1]
            if shutdownInProgress {
                if back.num == Instruction.shutdownNum {
                    sentStates[sentStates.count - 1].timestamp = now
                } else {
                    addSentState(timestamp: now, num: Instruction.shutdownNum, end: target)
                }
                try sendInFragments(newNum: Instruction.shutdownNum, newEnd: target, now: now, into: &datagrams)
            } else {
                let newNum = try outbox.takeStateNumber()
                addSentState(timestamp: now, num: newNum, end: target)
                try sendInFragments(newNum: newNum, newEnd: target, now: now, into: &datagrams)
            }
        } catch {
            // Nothing reached the server: the state was never sent.
            (sentStates, assumedIndex) = saved
            throw error
        }
        thinSentStates()
        let activeRetry = senderLastHeard.map { $0 + TransportConstants.activeRetryTimeout > now } ?? false
        if probing, activeRetry {
            nextAckTime = now + rtt.timeout + TransportConstants.ackDelay
        } else {
            nextAckTime = now + TransportConstants.ackInterval
        }
        nextSendTime = nil
    }

    /// mosh: `send_to_receiver`.
    private mutating func sendToReceiver(now: UInt64, target: UInt64, into datagrams: inout [[UInt8]]) throws {
        let saved = (sentStates, assumedIndex)
        do {
            let back = sentStates[sentStates.count - 1]
            let newNum: UInt64
            if shutdownInProgress {
                newNum = Instruction.shutdownNum
            } else if target == back.end {
                newNum = back.num // previously sent
            } else {
                newNum = try outbox.takeStateNumber()
            }
            if newNum == back.num {
                sentStates[sentStates.count - 1].timestamp = now
            } else {
                addSentState(timestamp: now, num: newNum, end: target)
            }
            try sendInFragments(newNum: newNum, newEnd: target, now: now, into: &datagrams)
            if newNum == back.num {
                retransmissions += 1
            }
        } catch {
            (sentStates, assumedIndex) = saved
            throw error
        }
        thinSentStates()
        // "successfully sent, probably". Recomputed before every use; see
        // `updateAssumedReceiverState` for the shutdown state.
        if sentStates[sentStates.count - 1].num != Instruction.shutdownNum {
            assumedIndex = sentStates.count - 1
        }
        nextAckTime = now + TransportConstants.ackInterval
        nextSendTime = nil
    }

    /// mosh: `add_sent_state`, first half.
    private mutating func addSentState(timestamp: UInt64, num: UInt64, end: UInt64) {
        sentStates.append(SentState(timestamp: timestamp, num: num, end: end))
    }

    /// mosh: `add_sent_state`, second half, with its way of thinning: above 32 states the 16th
    /// from the end goes, so the acknowledged state, the next 16 and the newest 15 stay.
    ///
    /// mosh thins before it sends; here it happens after the send succeeded, so that a failed
    /// send can be undone completely. The datagrams are the same: the state that goes is never
    /// the base of the diff (that is the acknowledged state or one of the newest).
    private mutating func thinSentStates() {
        guard sentStates.count > TransportConstants.sentStatesLimit else { return }
        let index = sentStates.count - 16
        let removed = sentStates.remove(at: index)
        outbox.forget(stateNumber: removed.num)
        if assumedIndex == index {
            assumedIndex = 0
        } else if assumedIndex > index {
            assumedIndex -= 1
        }
    }

    /// mosh: `send_in_fragments` and `Connection::send`.
    private mutating func sendInFragments(newNum: UInt64, newEnd: UInt64, now: UInt64, into datagrams: inout [[UInt8]]) throws {
        let assumed = sentStates[assumedIndex]
        let request = OutgoingInstruction(
            oldNum: assumed.num,
            oldEnd: assumed.end,
            newNum: newNum,
            newEnd: newEnd,
            ackNum: ackNum,
            throwawayNum: sentStates[0].num
        )
        if newNum == Instruction.shutdownNum {
            shutdownTries += 1
        }

        // mosh: `new_packet`. A timestamp received less than a second ago is echoed once,
        // "corrected" by how long we held it.
        var timestampReply = Timestamp16.none
        var echoed = false
        if let saved = savedTimestamp, now - saved.receivedAt < TransportConstants.timestampEchoLimit {
            timestampReply = saved.value &+ UInt16(truncatingIfNeeded: now - saved.receivedAt)
            echoed = true
        }

        let made = try outbox.send(
            request,
            log: log,
            chaff: configuration.makeChaff(),
            contentsBudget: WireConstants.fragmentContentsBudget(datagramMTU: datagramMTU),
            timestamp: Timestamp16.now(milliseconds: now),
            timestampReply: timestampReply
        )
        datagrams.append(contentsOf: made)
        if echoed {
            savedTimestamp = nil
        }
        pendingDataAck = false

        if ackNum == Instruction.shutdownNum {
            serverShutdownAckPending = false
            if !serverShutdownAckSent {
                serverShutdownAckSent = true
                events.append(.serverShutdownAcknowledged)
            }
        }

        // mosh: the client's part of `Connection::send`. hop_port() sends nothing itself.
        let noRoundtrip = lastRoundtripSuccess.map { now - $0 > TransportConstants.portHopInterval } ?? true
        if now - lastPortChoice > TransportConstants.portHopInterval, noRoundtrip, !serverShutdownSeen {
            lastPortChoice = now
            events.append(.socketReplacementWanted)
        }
    }

    /// mosh: `process_acknowledgment_through`. An ack for a state we do not hold changes nothing.
    private mutating func processAcknowledgment(through ack: UInt64) {
        guard sentStates.contains(where: { $0.num == ack }) else { return }
        let before = sentStates.count
        sentStates.removeAll { $0.num < ack }
        assumedIndex = max(0, assumedIndex - (before - sentStates.count))
        if sentStates[0].num == Instruction.shutdownNum, shutdownInProgress, !hasEnded {
            hasEnded = true
            events.append(.shutdownAcknowledged)
        }
    }

    /// mosh: `shutdown_ack_timed_out`, checked by the client's main loop before each tick.
    private mutating func checkShutdownTimeout(now: UInt64) {
        guard shutdownInProgress else { return }
        if shutdownTries >= TransportConstants.shutdownRetries
            || now - shutdownStart >= TransportConstants.activeRetryTimeout {
            hasEnded = true
            events.append(.shutdownTimedOut)
        }
    }

    // MARK: Receiver

    /// mosh: `Transport::recv` after `connection.recv()`.
    private mutating func process(payload: [UInt8], now: UInt64) {
        let instruction: Instruction
        do {
            let fragment = try Fragment(serialized: payload)
            guard try assembly.add(fragment) else { return }
            instruction = try assembly.takeInstruction()
        } catch {
            events.append(.peerProtocolError("fragment: \(error)"))
            return
        }
        guard instruction.protocolVersion == WireConstants.protocolVersion else {
            events.append(.peerProtocolError("protocol version \(instruction.protocolVersion)"))
            return
        }

        processAcknowledgment(through: instruction.ackNum)
        // "inform network layer of roundtrip (end-to-end-to-end) connectivity"
        lastRoundtripSuccess = sentStates[0].timestamp

        if instruction.newNum == Instruction.shutdownNum {
            processServerShutdown(instruction)
            return
        }

        // "first, make sure we don't already have the new state"
        if receivedStates.contains(where: { $0.num == instruction.newNum }) {
            return
        }

        // "now, make sure we do have the old state"
        guard let reference = receivedStates.first(where: { $0.num == instruction.oldNum }) else {
            // Ignored: "this is security-sensitive and part of how we enforce idempotency".
            // If this is also the state the server will keep building on, we are stuck for good.
            if instruction.oldNum == instruction.throwawayNum,
               instruction.throwawayNum >= highestThrowaway,
               !baseStateLostReported {
                baseStateLostReported = true
                events.append(.baseStateLost(serverBase: instruction.oldNum))
            }
            return
        }

        // mosh would erase its reference state here and then use it.
        guard instruction.throwawayNum <= instruction.oldNum else {
            events.append(.peerProtocolError("throwaway_num \(instruction.throwawayNum) above old_num \(instruction.oldNum)"))
            return
        }
        processThrowaway(until: instruction.throwawayNum)

        // "Do not accept state if our queue is full."
        if receivedStates.count > TransportConstants.receivedStatesLimit {
            if now < receiverQuenchTimer {
                return
            }
            receiverQuenchTimer = now + TransportConstants.quenchInterval
        }

        // "apply diff to reference state"
        var state = reference.state
        if !instruction.diff.isEmpty {
            do {
                try state.apply(diff: instruction.diff)
            } catch {
                events.append(.peerProtocolError("diff of state \(instruction.newNum): \(error)"))
                return
            }
        }
        let new = ReceivedState(timestamp: now, num: instruction.newNum, state: state)
        if configuration.reportsInstructions {
            events.append(.instructionApplied(AppliedInstruction(oldNum: instruction.oldNum, newNum: instruction.newNum, diff: instruction.diff)))
        }

        // "Insert new state in sorted place": an out-of-order state is kept but not acknowledged.
        if let index = receivedStates.firstIndex(where: { $0.num > new.num }) {
            receivedStates.insert(new, at: index)
            return
        }
        receivedStates.append(new)
        // After the server's shutdown the acknowledgment stays 2^64 - 1. In mosh the shutdown
        // state is the last of `received_states`, so a state that arrives late is inserted
        // before it and `set_ack_num`, `remote_heard` and `set_data_ack` are not reached
        // (networktransport-impl.h:143-160). The state is kept: a newer screen is a newer screen.
        if !serverShutdownSeen {
            ackNum = new.num
            senderLastHeard = now
            if !instruction.diff.isEmpty {
                pendingDataAck = true
            }
        }
        events.append(.remoteStateAdvanced(number: new.num))
    }

    /// mosh: `process_throwaway_until`. The reference state is at or above `throwawayNum`, so the
    /// list cannot become empty.
    private mutating func processThrowaway(until throwawayNum: UInt64) {
        receivedStates.removeAll { $0.num < throwawayNum }
        highestThrowaway = max(highestThrowaway, throwawayNum)
    }

    /// The server's last word: `new_num` = 2^64 - 1. mosh stores it like any other state; here
    /// that number stays out of the state list and out of every counter.
    private mutating func processServerShutdown(_ instruction: Instruction) {
        // Acknowledge it, and again whenever the server repeats it (our ack may have been lost).
        serverShutdownAckPending = true
        ackNum = Instruction.shutdownNum
        if !serverShutdownSeen {
            serverShutdownSeen = true
            events.append(.serverShutdown)
        }
        if finalState == nil,
           instruction.throwawayNum <= instruction.oldNum,
           let reference = receivedStates.first(where: { $0.num == instruction.oldNum }) {
            var state = reference.state
            if instruction.diff.isEmpty {
                finalState = state
            } else if (try? state.apply(diff: instruction.diff)) != nil {
                finalState = state
            }
        }
    }

    // MARK: Reading

    /// The newest remote state and its number.
    public var newestRemoteState: NumberedRemoteState<Remote> {
        let newest = receivedStates[receivedStates.count - 1]
        return NumberedRemoteState(number: newest.num, state: newest.state)
    }

    /// The state the server's shutdown instruction led to, if its base was held.
    public var finalRemoteState: Remote? { finalState }

    /// The numbers of the remote states held, ascending.
    public var heldRemoteStateNumbers: [UInt64] { receivedStates.map(\.num) }

    /// `A`: the newest client state the server acknowledged (2^64 - 1 once it acknowledged our
    /// shutdown).
    public var acknowledgedStateNumber: UInt64 { sentStates[0].num }

    /// The number of the last client state sent.
    public var lastSentStateNumber: UInt64 { sentStates[sentStates.count - 1].num }

    /// The numbers of the client states the sender holds: acknowledged first, last sent last.
    public var sentStateNumbers: [UInt64] { sentStates.map(\.num) }

    /// The `ack_num` the next instruction carries.
    public var acknowledgmentNumber: UInt64 { ackNum }

    /// Input events the server has not acknowledged.
    public var pendingInputCount: Int { Int(log.end - sentStates[0].end) }

    /// Whether the server announced the end of the session.
    public var serverHasShutDown: Bool { serverShutdownSeen }

    /// Whether we started a shutdown.
    public var isShuttingDown: Bool { shutdownInProgress }

    /// The size last announced to the server.
    public var terminalSize: TerminalSize? { currentSize }

    /// The datagram size in use: 1252, 1216, or 500 after `datagramTooLarge()`.
    public var currentDatagramMTU: Int { datagramMTU }

    /// Number of datagrams produced so far.
    public var datagramsSent: UInt64 { outbox.datagramsSent }

    /// How often a state was sent again under its own number (input the server had not
    /// acknowledged in time, or a repeated shutdown request). For test tools.
    public private(set) var retransmissions: UInt64 = 0

    /// The times the "Last contact" banner is computed from.
    public var contactTimes: ContactTimes {
        ContactTimes(
            newestRemoteStateAt: receivedStates[receivedStates.count - 1].timestamp,
            acknowledgedStateSentAt: sentStates[0].timestamp,
            lastAuthenticDatagramAt: lastHeard
        )
    }

    // MARK: Resume

    /// The state to store for a later `init(restoring:)`.
    ///
    /// The pending input is counted from the acknowledged state `A` as it is now, also when the
    /// ack arrived after the last tick (the case in which mosh's own lists are not yet trimmed).
    /// Needs `quiesce()` first: a snapshot is only worth something if nothing is sent after it.
    public func exportState() throws -> TransportSnapshot<Remote> {
        guard isQuiesced else { throw SnapshotError.notQuiesced }
        guard !isHalted, !hasEnded, !shutdownInProgress, !serverShutdownSeen else {
            throw SnapshotError.sessionEnded
        }
        let front = sentStates[0]
        let pending = log.events(from: front.end, to: log.end).map(Array.init) ?? []
        return TransportSnapshot(
            acknowledgedStateNumber: front.num,
            pendingInput: pending,
            remoteStates: receivedStates.map { NumberedRemoteState(number: $0.num, state: $0.state) },
            highestAckSent: outbox.highestAckSent,
            terminalSize: currentSize,
            usedCounters: outbox.usedCounters,
            receiverExpectedSequence: expectedReceiverSeq
        )
    }
}
