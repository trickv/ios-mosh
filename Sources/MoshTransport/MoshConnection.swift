// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import Foundation
import MoshCrypto
import MoshWire

/// A source of milliseconds that never goes backwards.
public protocol MonotonicClock: Sendable {
    /// Milliseconds since an arbitrary point well in the past (never near zero).
    func nowMilliseconds() -> UInt64
}

/// `CLOCK_MONOTONIC`, shifted so that it is far above zero even right after boot (mosh's timer
/// code treats 0 and -1 as "never").
public struct SystemMonotonicClock: MonotonicClock {
    /// Added to the system's reading: about 4.6 hours.
    public static let offset: UInt64 = 1 << 24

    public init() {}

    public func nowMilliseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1000 + UInt64(time.tv_nsec) / 1_000_000 + Self.offset
    }
}

/// How long ago, in milliseconds, the things happened that the "Last contact" banner shows.
public struct ContactAges: Equatable, Sendable {
    /// Since the newest remote state arrived (or since the connection was made, before the first).
    /// mosh shows "Last contact" when this passes 6.5 s.
    public var sinceNewestRemoteState: UInt64
    /// Since the client state the server acknowledged was sent. mosh shows "Last reply" when this
    /// passes 10 s while the server is still heard.
    public var sinceAcknowledgedStateSent: UInt64
    /// Since any authentic datagram arrived; nil if none has.
    public var sinceLastAuthenticDatagram: UInt64?

    public init(sinceNewestRemoteState: UInt64, sinceAcknowledgedStateSent: UInt64, sinceLastAuthenticDatagram: UInt64?) {
        self.sinceNewestRemoteState = sinceNewestRemoteState
        self.sinceAcknowledgedStateSent = sinceAcknowledgedStateSent
        self.sinceLastAuthenticDatagram = sinceLastAuthenticDatagram
    }
}

/// The shortest time between two attempts to open a socket that nobody asked for: the retry
/// after a failed open, and the replacement of a socket that died younger than this. Without it
/// a network that fails every new socket at once makes a loop of opens, each with a datagram.
/// Replacements that are asked for (foreground, mosh's port hop) are not limited by it.
let socketReopenInterval: UInt64 = 1000

/// What a `MoshConnection` tells its owner.
public enum ConnectionEvent: Equatable, Sendable {
    /// An event of the transport core: a new remote state, a shutdown, a lost base state, an
    /// internal error (see `TransportEvent`).
    case transport(TransportEvent)
    /// An authentic datagram arrived; these are the ages at that moment. Between events the owner
    /// asks `contactAges()` (for a banner that counts seconds).
    case contact(ContactAges)
    /// A datagram could not be sent or a socket could not be opened. The connection keeps trying.
    case networkError(String)
}

/// A live mosh session: a `TransportCore`, a `DurabilityGate`, one `DatagramTransport`, a clock
/// and a timer. All protocol logic is in the core; this actor moves datagrams and time into it
/// and its output out.
///
/// The methods run one at a time in arrival order and none of them suspends, so a `quiesce()`
/// is complete before a `resume()` that was called after it begins.
public actor MoshConnection<Remote: RemoteState> {
    /// Events, in order. The stream ends at `close()`.
    public nonisolated let events: AsyncStream<ConnectionEvent>

    private var core: TransportCore<Remote>
    private let gate: any DurabilityGate
    private let clock: any MonotonicClock
    private let makeTransport: @Sendable () throws -> any DatagramTransport

    private struct Socket {
        var id: UInt64
        var transport: any DatagramTransport
    }

    private var current: Socket?
    /// The socket before the last replacement, kept until the new one has proved itself.
    private var previous: Socket?
    private var nextSocketID: UInt64 = 0
    private var lastOpenAttempt: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var isClosed = false

    private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation
    private let inbox: AsyncStream<(UInt64, DatagramTransportEvent)>
    private let inboxContinuation: AsyncStream<(UInt64, DatagramTransportEvent)>.Continuation

    /// A new session. Nothing is sent before `start()`.
    ///
    /// - Parameters:
    ///   - key: the session key from `MOSH CONNECT`.
    ///   - initialRemoteState: the remote state numbered 0 (see `TransportCore.init`); nil means
    ///     `Remote()`.
    ///   - makeTransport: opens a new socket to the server. Called at `start()`, at every socket
    ///     replacement and at `resume()`.
    public init(
        key: Base64Key,
        gate: any DurabilityGate = InMemoryGate(),
        configuration: TransportConfiguration = TransportConfiguration(),
        initialSize: TerminalSize,
        initialRemoteState: Remote? = nil,
        clock: any MonotonicClock = SystemMonotonicClock(),
        makeTransport: @escaping @Sendable () throws -> any DatagramTransport
    ) throws {
        let core = TransportCore<Remote>(
            cipher: try MoshCipher(key: key),
            gate: gate,
            configuration: configuration,
            initialSize: initialSize,
            initialRemoteState: initialRemoteState,
            now: clock.nowMilliseconds()
        )
        self.init(core: core, gate: gate, clock: clock, makeTransport: makeTransport)
    }

    /// Continues a session from a snapshot; see `TransportCore.init(restoring:)`. The gate must
    /// start at the old session's reserved limits; one whose limits are below the snapshot's
    /// `usedCounters` is refused with `SnapshotError.gateBelowSnapshot`.
    public init(
        restoring snapshot: TransportSnapshot<Remote>,
        key: Base64Key,
        gate: any DurabilityGate,
        configuration: TransportConfiguration = TransportConfiguration(),
        currentSize: TerminalSize?,
        clock: any MonotonicClock = SystemMonotonicClock(),
        makeTransport: @escaping @Sendable () throws -> any DatagramTransport
    ) throws {
        let core = try TransportCore<Remote>(
            restoring: snapshot,
            cipher: try MoshCipher(key: key),
            gate: gate,
            configuration: configuration,
            currentSize: currentSize,
            now: clock.nowMilliseconds()
        )
        self.init(core: core, gate: gate, clock: clock, makeTransport: makeTransport)
    }

    private init(
        core: TransportCore<Remote>,
        gate: any DurabilityGate,
        clock: any MonotonicClock,
        makeTransport: @escaping @Sendable () throws -> any DatagramTransport
    ) {
        self.core = core
        self.gate = gate
        self.clock = clock
        self.makeTransport = makeTransport
        // Unbounded: an event such as a server shutdown or a lost base state must not be pushed
        // out by newer ones. The owner is expected to read the stream.
        (events, eventContinuation) = AsyncStream<ConnectionEvent>.makeStream(bufferingPolicy: .unbounded)
        (inbox, inboxContinuation) = AsyncStream<(UInt64, DatagramTransportEvent)>.makeStream(bufferingPolicy: .bufferingNewest(4096))
    }

    // MARK: Lifecycle

    /// Opens the first socket and sends at once.
    public func start() {
        guard !isClosed, reader == nil else { return }
        let inbox = self.inbox
        reader = Task { [weak self] in
            for await (id, event) in inbox {
                guard let self else { return }
                await self.handle(event, from: id)
            }
        }
        openSocket(probe: false)
        pump()
    }

    /// Opens a new socket (new source port) and keeps the old one until the server answers on
    /// the new one. For a return to the foreground with the session in memory, and whenever the
    /// network path may have changed.
    public func replaceSocket() {
        guard !isClosed, !core.isQuiesced else { return }
        openSocket(probe: true)
        pump()
    }

    /// Stops all sends and closes the sockets. After this `exportState()` gives a snapshot that
    /// stays true until `resume()`.
    public func quiesce() {
        core.quiesce()
        timer?.cancel()
        timer = nil
        closeSockets()
    }

    /// Sends the unacknowledged input now, if there is any, then does `quiesce()`, with nothing
    /// read in between: the answer to that datagram is never seen. A snapshot taken afterwards
    /// holds input the server may already have. Test tools use this to prove that a resume
    /// delivers such input exactly once.
    public func quiesceAfterSend() {
        guard !isClosed, !core.isQuiesced else { return }
        let output = core.sendPendingNow(now: clock.nowMilliseconds())
        if let socket = current {
            for datagram in output.datagrams {
                socket.transport.send(datagram)
            }
        }
        for event in output.events where event != .socketReplacementWanted {
            eventContinuation.yield(.transport(event))
        }
        quiesce()
    }

    /// Continues after `quiesce()` with the state in memory: a new socket, and a datagram at once.
    public func resume() {
        guard !isClosed, core.isQuiesced else { return }
        core.unquiesce(now: clock.nowMilliseconds())
        openSocket(probe: true)
        pump()
    }

    /// The state to store for a later resume, and the token for its clean mark. Needs
    /// `quiesce()` first.
    ///
    /// The snapshot writer stores `snapshot` and then calls `gate.markClean(cleanToken)`. The
    /// token is the gate's datagram count read here, in the same actor call as the snapshot and
    /// with the core quiesced, so the two describe the same moment: whatever happens afterwards
    /// (a `resume()` between any two steps of the writer), the mark succeeds only if no
    /// datagram left after this snapshot was taken.
    public func exportState() throws -> TransportExport<Remote> {
        let snapshot = try core.exportState()
        return TransportExport(snapshot: snapshot, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
    }

    /// Asks the server to end the session (mosh: `start_shutdown`).
    ///
    /// Returns true if a shutdown is running: the outcome arrives as
    /// `.transport(.shutdownAcknowledged)` or `.transport(.shutdownTimedOut)`. Returns false,
    /// and no event follows, if the connection is closed, the session is already over (the
    /// server shut down, or an earlier shutdown finished) or the transport halted. See
    /// `TransportCore.startShutdown` for what is sent and for a shutdown asked for while quiesced.
    @discardableResult
    public func shutdown() -> Bool {
        guard !isClosed else { return false }
        let running = core.startShutdown(now: clock.nowMilliseconds())
        pump()
        return running
    }

    /// Stops everything and ends the event stream. The server is not told; see `shutdown()`.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        core.quiesce()
        timer?.cancel()
        timer = nil
        closeSockets()
        inboxContinuation.finish()
        eventContinuation.finish()
        reader?.cancel()
        reader = nil
    }

    // MARK: Input

    /// Sends bytes the user typed or pasted. Returns false once the session takes no more input.
    @discardableResult
    public func type(_ bytes: [UInt8]) -> Bool {
        return typeNotingLastSent(bytes).accepted
    }

    /// `type(_:)` with the number local echo needs: the last sent state number read before the
    /// bytes are appended, mosh's `set_local_frame_sent( get_sent_state_last() )` before the
    /// read is queued (stmclient.cc:322, transportsender.h:154). One actor turn: read, append,
    /// pump; a later read could see the number of the state that already carries the bytes.
    public func typeNotingLastSent(_ bytes: [UInt8]) -> TypeReceipt {
        let lastSent = core.lastSentStateNumber
        guard !isClosed, core.type(bytes) else {
            return TypeReceipt(accepted: false, lastSentStateNumber: lastSent)
        }
        pump()
        return TypeReceipt(accepted: true, lastSentStateNumber: lastSent)
    }

    /// Tells the server the size of the terminal view.
    @discardableResult
    public func resize(_ size: TerminalSize) -> Bool {
        guard !isClosed, core.resize(size) else { return false }
        pump()
        return true
    }

    // MARK: Reading

    /// The newest remote state and its number.
    public func newestRemoteState() -> NumberedRemoteState<Remote> {
        core.newestRemoteState
    }

    /// The state the server's shutdown led to, if it could be built.
    public func finalRemoteState() -> Remote? {
        core.finalRemoteState
    }

    /// The ages for the "Last contact" banner, as of now.
    public func contactAges() -> ContactAges {
        ages(now: clock.nowMilliseconds())
    }

    /// The smoothed round-trip time in milliseconds.
    public func smoothedRoundTripTime() -> Double {
        core.rtt.srtt
    }

    /// Whether `quiesce()` is in effect.
    public func isQuiesced() -> Bool {
        core.isQuiesced
    }

    /// Number of datagrams handed to sockets so far.
    public func datagramsSent() -> UInt64 {
        core.datagramsSent
    }

    /// Number of input events (keystroke bytes and resizes) the server has not acknowledged.
    /// Zero means the server has everything that was typed.
    public func unacknowledgedInputCount() -> Int {
        core.pendingInputCount
    }

    /// How often a state was sent again under its own number.
    public func retransmissions() -> UInt64 {
        core.retransmissions
    }

    /// The client state number the server has acknowledged.
    public func acknowledgedStateNumber() -> UInt64 {
        core.acknowledgedStateNumber
    }

    /// What mosh's client reads for its prediction engine after every receive
    /// (stmclient.cc:298-300): the acknowledged state number, the send interval and the
    /// newest remote state (whose echo ack is the late ack), in one turn.
    public func predictionReadings() -> (sender: SenderReadings, newest: NumberedRemoteState<Remote>) {
        let interval = core.rtt.sendInterval   // 20...250 (RTTEstimator), so it fits
        return (SenderReadings(acknowledgedStateNumber: core.acknowledgedStateNumber,
                               sendInterval: UInt32(clamping: interval)),
                core.newestRemoteState)
    }

    // MARK: Plumbing

    private func ages(now: UInt64) -> ContactAges {
        let times = core.contactTimes
        func age(_ then: UInt64) -> UInt64 { now > then ? now - then : 0 }
        return ContactAges(
            sinceNewestRemoteState: age(times.newestRemoteStateAt),
            sinceAcknowledgedStateSent: age(times.acknowledgedStateSentAt),
            sinceLastAuthenticDatagram: times.lastAuthenticDatagramAt.map(age)
        )
    }

    private func openSocket(probe: Bool) {
        lastOpenAttempt = clock.nowMilliseconds()
        let transport: any DatagramTransport
        do {
            transport = try makeTransport()
        } catch {
            eventContinuation.yield(.networkError("socket: \(error)"))
            return
        }
        nextSocketID += 1
        let id = nextSocketID
        if let old = current {
            previous?.transport.close()
            previous = old
        }
        // With no current socket (it died, see `.unusable`), `previous` stays what it is: it may
        // still be the socket the server answers on.
        current = Socket(id: id, transport: transport)
        let continuation = inboxContinuation
        transport.start { event in
            continuation.yield((id, event))
        }
        core.socketReplaced(now: clock.nowMilliseconds(), probe: probe)
    }

    private func closeSockets() {
        current?.transport.close()
        previous?.transport.close()
        current = nil
        previous = nil
    }

    private func handle(_ event: DatagramTransportEvent, from id: UInt64) {
        guard !isClosed, id == current?.id || id == previous?.id else { return }
        switch event {
        case .received(let datagram):
            let now = clock.nowMilliseconds()
            let result = core.receive(datagram: datagram, now: now)
            guard result == .authentic || result == .authenticOutOfOrder else { return }
            if result == .authentic, id == current?.id, let old = previous {
                // The new socket works: the old one is no longer needed.
                old.transport.close()
                previous = nil
            }
            pump()
            eventContinuation.yield(.contact(ages(now: now)))
        case .messageTooLong:
            core.datagramTooLarge()
            eventContinuation.yield(.networkError("datagram too long for the path; using smaller datagrams"))
            pump()
        case .sendFailed(let description):
            eventContinuation.yield(.networkError(description))
        case .unusable(let description):
            eventContinuation.yield(.networkError(description))
            if id == previous?.id {
                // The old socket died before the new one proved itself: nothing to keep.
                previous?.transport.close()
                previous = nil
            } else if id == current?.id {
                // Drop the dead socket first, so that opening the next one leaves `previous`
                // (which may still work) alone.
                current?.transport.close()
                current = nil
                guard !core.isQuiesced else { return }
                if clock.nowMilliseconds() >= lastOpenAttempt + socketReopenInterval {
                    openSocket(probe: false)
                }
                // A socket that died young is not replaced here: `pump()` opens the next one
                // when `socketReopenInterval` is over, and sets the timer for that moment.
                pump()
            }
        }
    }

    /// Runs the core's tick, sends what it made, passes its events on and sets the timer.
    private func pump() {
        guard !isClosed else { return }
        let now = clock.nowMilliseconds()
        if current == nil, !core.isQuiesced, now >= lastOpenAttempt + socketReopenInterval {
            // The last attempt to open a socket failed (no network at the time), or the socket
            // died young: try again.
            openSocket(probe: false)
        }
        let output = core.tick(now: now)
        if let socket = current {
            for datagram in output.datagrams {
                socket.transport.send(datagram)
            }
        }
        var replace = false
        for event in output.events {
            if event == .socketReplacementWanted {
                replace = true
            }
            eventContinuation.yield(.transport(event))
        }
        if replace {
            openSocket(probe: false)
        }
        var wakeup = output.nextWakeup
        if current == nil, !core.isQuiesced, !core.isHalted, !core.hasEnded {
            // No socket: wake up when the next open is allowed, not only when the core has
            // something to send. (Quiesced, halted or ended: no socket is needed.)
            wakeup = min(wakeup ?? UInt64.max, lastOpenAttempt + socketReopenInterval)
        }
        schedule(wakeup, now: now)
    }

    private func schedule(_ wakeup: UInt64?, now: UInt64) {
        timer?.cancel()
        timer = nil
        guard let wakeup else { return }
        // Never less than a millisecond, so that a wake-up "at once" cannot spin.
        let delay = wakeup > now ? wakeup - now : 1
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        pump()
    }
}
