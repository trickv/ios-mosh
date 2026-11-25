import MoshBootstrap
import MoshCrypto
import MoshTerminal
import MoshTransport

/// The facade the app uses for one mosh session: a `MoshConnection` whose remote state is a
/// terminal (`TerminalRemoteState`), the clipboard policy, and one stream of events.
///
/// It adds no protocol or durability logic of its own. Every datagram goes through the
/// connection and so through the `DurabilityGate` it was given; quiesce, export and import are
/// the connection's seams, passed through.
///
/// Typical use:
///
///     let session = try MoshSession(bootstrap: result, initialSize: size)
///     Task { for await event in session.events { ... } }
///     await session.start()
///     await session.type(Array("ls\r".utf8))
///
/// Resume in a new object (or, from M6, a new process):
///
///     await old.quiesce()
///     let exported = try await old.exportState()
///     // M6: write exported.snapshot, then oldGate.markClean(exported.cleanToken)
///     await old.close()
///     let gate = InMemoryGate(startingAt: oldGate.reservedLimits)   // M6: the file-backed gate
///     let session = try MoshSession(restoring: exported.snapshot, endpoint: endpoint, gate: gate, currentSize: size)
///     await session.start()       // first event: the stored screen, isLive false
public actor MoshSession {
    public typealias Connection = MoshConnection<TerminalRemoteState>

    /// Events, in order. The stream ends at `close()`. Unbounded, as the connection's: a
    /// `serverEnded` or `baseStateLost` must not be pushed out. The app must read it.
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let endpoint: SessionEndpoint

    private let connection: Connection
    private var clipboard: ClipboardPolicy
    private let isRestored: Bool
    private var lastScreenNumber: UInt64?
    private var reader: Task<Void, Never>?
    private var started = false
    private var closed = false
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let noReplyTimeout: UInt64?
    private var noReplyTimer: Task<Void, Never>?
    private var noReplyReported = false
    /// A test seam: awaited before each connection event is handled, so that a test can hold
    /// the session's reader back while the connection goes on. Never set outside tests.
    private var beforeEvent: (@Sendable () async -> Void)?

    // Local echo (docs/notes/m10/DESIGN.md section 4). Touched only in synchronous sections
    // of this actor: each entry does at most one await on the connection first, then reads
    // the clock, feeds the engine and renders with no suspension in between.
    private let clock: any MonotonicClock
    private var engine: PredictionEngine
    /// mosh's `local_framebuffer` (stmclient.cc:287): the last frame rendered, with guesses.
    private var shown: Framebuffer
    /// The newest remote state this actor has read; only moves forward.
    private var latest: (number: UInt64, framebuffer: Framebuffer)
    private var displaySerial: UInt64 = 0
    private var lastDisplayed: (number: UInt64, framebuffer: Framebuffer)?
    private var predictionTimer: Task<Void, Never>?
    /// Set before the connection is quiesced, cleared after it resumed: no timer meanwhile.
    private var quiesced = false
    /// The session is over (server end, shutdown finished, halted, base lost): no echo ack
    /// will come, so no guess is kept and no timer runs.
    private var ended = false

    /// mosh's client gives up when no state came from the server within 15 s
    /// (`still_connecting()` and `timestamp() - latest_remote_state.timestamp > 15000`,
    /// stmclient.cc:532-538, stmclient.h:81-85).
    public static let defaultNoReplyTimeout: UInt64 = 15_000

    // MARK: Making one

    /// A new session.
    ///
    /// - Parameters:
    ///   - initialSize: the terminal view's size, announced to the server as the first input.
    ///   - serverStartSize: the size the server's terminal had when it started, which is the
    ///     size of the remote state numbered 0 (see `TerminalRemoteState.init(serverStartSize:)`).
    ///     After an SSH bootstrap that is the pty size of the bootstrap request; nil means
    ///     `initialSize`, which is right when the bootstrap used the same size. A server started
    ///     without a tty uses 80x24 (`TerminalRemoteState.defaultServerSize`).
    ///   - gate: every sequence number, state number and fragment id comes from it.
    ///   - configuration: nil means the defaults for the endpoint's address family.
    ///   - makeTransport: opens a socket to the endpoint; nil means `POSIXDatagramTransport`.
    ///   - noReplyTimeout: milliseconds after `start()` (time spent quiesced aside) without any
    ///     state from the server after which `.noServerReply` is reported; nil never reports it.
    ///     Real time, not `clock`: it is a user-facing wait, not protocol timing.
    public init(
        endpoint: SessionEndpoint,
        initialSize: TerminalSize,
        serverStartSize: TerminalSize? = nil,
        gate: any DurabilityGate = InMemoryGate(),
        configuration: TransportConfiguration? = nil,
        clipboard: ClipboardPolicy = ClipboardPolicy(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        noReplyTimeout: UInt64? = MoshSession.defaultNoReplyTimeout,
        prediction: PredictionSettings = .off,
        makeTransport: (@Sendable () throws -> any DatagramTransport)? = nil
    ) throws {
        let initialRemoteState = TerminalRemoteState(serverStartSize: serverStartSize ?? initialSize)
        let connection = try Connection(
            key: endpoint.key,
            gate: gate,
            configuration: configuration ?? TransportConfiguration(family: endpoint.family),
            initialSize: initialSize,
            initialRemoteState: initialRemoteState,
            clock: clock,
            makeTransport: makeTransport ?? Self.posixTransport(endpoint)
        )
        self.init(connection: connection, endpoint: endpoint, clipboard: clipboard, isRestored: false,
                  noReplyTimeout: noReplyTimeout, clock: clock, prediction: prediction,
                  newest: (0, initialRemoteState.framebuffer))
    }

    /// A new session from an SSH bootstrap's `MOSH CONNECT` result. See the other initializer
    /// for `serverStartSize`.
    public init(
        bootstrap result: BootstrapResult,
        initialSize: TerminalSize,
        serverStartSize: TerminalSize? = nil,
        gate: any DurabilityGate = InMemoryGate(),
        clipboard: ClipboardPolicy = ClipboardPolicy(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        noReplyTimeout: UInt64? = MoshSession.defaultNoReplyTimeout,
        prediction: PredictionSettings = .off,
        makeTransport: (@Sendable () throws -> any DatagramTransport)? = nil
    ) throws {
        try self.init(endpoint: try SessionEndpoint(bootstrap: result), initialSize: initialSize,
                      serverStartSize: serverStartSize, gate: gate, clipboard: clipboard, clock: clock,
                      noReplyTimeout: noReplyTimeout, prediction: prediction, makeTransport: makeTransport)
    }

    /// Continues a session from a snapshot (`MoshConnection.init(restoring:)`). The gate must
    /// start at or above the old session's reserved limits: a gate whose limits are below the
    /// numbers the snapshot says were used is refused (`SnapshotError.gateBelowSnapshot`). The
    /// snapshot must also still be valid under the gate's dirty rule, which is not checked here.
    ///
    /// - Parameter currentSize: the view's size now; announced if it differs from the
    ///   snapshot's.
    public init(
        restoring snapshot: SessionSnapshot,
        endpoint: SessionEndpoint,
        gate: any DurabilityGate,
        currentSize: TerminalSize?,
        configuration: TransportConfiguration? = nil,
        clock: any MonotonicClock = SystemMonotonicClock(),
        prediction: PredictionSettings = .off,
        makeTransport: (@Sendable () throws -> any DatagramTransport)? = nil
    ) throws {
        let connection = try Connection(
            restoring: snapshot.transport,
            key: endpoint.key,
            gate: gate,
            configuration: configuration ?? TransportConfiguration(family: endpoint.family),
            currentSize: currentSize,
            clock: clock,
            makeTransport: makeTransport ?? Self.posixTransport(endpoint)
        )
        // The connection refused a snapshot without remote states, so `last` is there; the
        // newest is the last (as `exportState()` reads it).
        let stored = snapshot.transport.remoteStates.last
        self.init(connection: connection, endpoint: endpoint, clipboard: snapshot.clipboard, isRestored: true,
                  noReplyTimeout: nil, clock: clock, prediction: prediction,
                  newest: (stored?.number ?? 0, stored?.state.framebuffer ?? Framebuffer(width: 1, height: 1)))
    }

    private init(connection: Connection, endpoint: SessionEndpoint, clipboard: ClipboardPolicy, isRestored: Bool,
                 noReplyTimeout: UInt64?, clock: any MonotonicClock, prediction: PredictionSettings,
                 newest: (number: UInt64, framebuffer: Framebuffer)) {
        self.connection = connection
        self.endpoint = endpoint
        self.clipboard = clipboard
        self.isRestored = isRestored
        self.noReplyTimeout = noReplyTimeout
        self.clock = clock
        self.engine = PredictionEngine(settings: prediction)
        // Deviation D6: the first shown frame is the newest remote state's, not a blank frame
        // of the window size (stmclient.cc:245).
        self.latest = newest
        self.shown = newest.framebuffer
        (events, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    private static func posixTransport(_ endpoint: SessionEndpoint) -> @Sendable () throws -> any DatagramTransport {
        let host = endpoint.host
        let port = endpoint.port
        return { try POSIXDatagramTransport(host: host, port: port) }
    }

    // MARK: Lifecycle

    /// Starts sending. A restored session first reports its stored screen (`isLive` false).
    ///
    /// The stored screen's clipboard is compared with what the stored policy last saw. They are
    /// equal for a snapshot from `exportState()`, which shows the policy the newest state it
    /// exports, and nothing is written. If they differ all the same (a snapshot put together
    /// some other way), that copy counts as never written, and since the server sends an OSC 52
    /// only when the field changes, it is decided on now, under the usual rules (the hash of
    /// the last write, the per-host switch). A `.clipboard` event then follows the stored screen.
    public func start() async {
        guard !started, !closed else { return }
        started = true
        if isRestored {
            let newest = await connection.newestRemoteState()
            lastScreenNumber = newest.number
            continuation.yield(.screen(ScreenUpdate(number: newest.number, state: newest.state.terminal, isLive: false)))
            report(clipboard.observe(newest.state.framebuffer.clipboard, live: true))
            // The first cull sees a 0x0 last size and resets (terminaloverlay.cc:446-451), so
            // this first `.display` has no guess.
            render(now: clock.nowMilliseconds())
        }
        let stream = connection.events
        reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await connection.start()
        armNoReplyTimer()
    }

    /// Starts (or restarts) the wait for the first state from the server.
    private func armNoReplyTimer() {
        noReplyTimer?.cancel()
        noReplyTimer = nil
        guard let timeout = noReplyTimeout, !noReplyReported, !closed else { return }
        noReplyTimer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout * 1_000_000)
            } catch {
                return
            }
            await self?.noReplyTimerFired()
        }
    }

    /// mosh's rule: still connecting means the newest remote state is the one numbered 0.
    /// While quiesced nothing is sent, so the wait starts again at `resume()`.
    private func noReplyTimerFired() async {
        noReplyTimer = nil
        guard !closed, !noReplyReported, !(await connection.isQuiesced()) else { return }
        guard await connection.newestRemoteState().number == 0 else { return }
        noReplyReported = true
        continuation.yield(.noServerReply(.udpBlocked(port: Int(endpoint.port))))
    }

    /// A new socket (new source port); for a return to the foreground and a path change.
    public func replaceSocket() async {
        await connection.replaceSocket()
    }

    /// Stops all sends and closes the sockets; `exportState()` is valid after this until
    /// `resume()`.
    ///
    /// The prediction engine and the shown frame are kept; no prediction timer runs until
    /// `resume()` (nothing is sent meanwhile, so no answer can judge a guess).
    public func quiesce() async {
        stopPredictionTimer()
        await connection.quiesce()
    }

    /// `MoshConnection.quiesceAfterSend()`: a test seam (moshcli, resume tests).
    public func quiesceAfterSend() async {
        stopPredictionTimer()
        await connection.quiesceAfterSend()
    }

    /// Continues after `quiesce()` with the state in memory.
    public func resume() async {
        await connection.resume()
        quiesced = false
        if !closed {
            // Pending guesses are old now: the first cull may raise glitch_trigger
            // (terminaloverlay.cc:576-586), as after a long stall in mosh.
            let readings = await connection.predictionReadings()
            _ = apply(readings)
            render(now: clock.nowMilliseconds())
        }
        if started, noReplyTimeout != nil, !noReplyReported, await connection.newestRemoteState().number == 0 {
            armNoReplyTimer()
        }
    }

    /// The snapshot to store and the token for its clean mark (`MoshConnection.exportState()`):
    /// store `snapshot`, then `gate.markClean(cleanToken)`. Needs `quiesce()` first.
    ///
    /// The clipboard policy in the snapshot has seen the newest state in the snapshot. The
    /// transport's part comes from the connection's actor, and its newest state may not have
    /// reached this actor yet (its event is still in the stream, or the handler is suspended).
    /// So that state is reported and shown to the policy here, before the policy is copied,
    /// with no suspension in between; when its event arrives later it finds the screen already
    /// reported. Otherwise the snapshot would pair a screen that has a copy with a policy that
    /// has not seen it, and a restore would write to the pasteboard a copy that the live
    /// process had already written (review finding B-6).
    public func exportState() async throws -> SessionExport {
        let exported = try await connection.exportState()
        // (State 0 of a session that has heard nothing is the blank start screen: not an event.)
        if started, !closed, let newest = exported.snapshot.remoteStates.last, newest.number != lastScreenNumber,
           lastScreenNumber != nil || newest.number != 0 {
            lastScreenNumber = newest.number
            let update = ScreenUpdate(number: newest.number, state: newest.state.terminal, isLive: true)
            continuation.yield(.screen(update))
            report(clipboard.observe(update.framebuffer.clipboard, live: true))
        }
        return SessionExport(
            snapshot: SessionSnapshot(transport: exported.snapshot, clipboard: clipboard),
            cleanToken: exported.cleanToken
        )
    }

    /// Asks the server to end the session. True: the outcome arrives as `.shutdownFinished`.
    /// False: no event follows, because the session is closed or already over (`.serverEnded`,
    /// an earlier `.shutdownFinished`) or the transport halted; the app just closes it.
    ///
    /// Asked for while quiesced, the request is sent after `resume()` and has 10 s from then.
    @discardableResult
    public func shutdown() async -> Bool {
        await connection.shutdown()
    }

    /// Stops everything and ends the event stream. The server is not told (see `shutdown()`).
    public func close() async {
        guard !closed else { return }
        closed = true
        noReplyTimer?.cancel()
        noReplyTimer = nil
        predictionTimer?.cancel()
        predictionTimer = nil
        await connection.close()
        reader?.cancel()
        reader = nil
        continuation.finish()
    }

    // MARK: Input

    /// Bytes the user typed or pasted. False once the session takes no more input.
    ///
    /// One call is one of mosh's reads (stmclient.cc:303-334): a call of more than 100 bytes
    /// is a paste and is not predicted.
    @discardableResult
    public func type(_ bytes: [UInt8]) async -> Bool {
        let receipt = await connection.typeNotingLastSent(bytes)
        // stmclient.cc:319-321: input refused at shutdown does not reach the engine.
        guard receipt.accepted else { return false }
        let now = clock.nowMilliseconds()
        // stmclient.cc:322-334, judged against the shown frame (local_framebuffer).
        engine.newUserRead(bytes, lastSent: receipt.lastSentStateNumber, shown, now: now)
        render(now: now)
        return true
    }

    /// The terminal view's size changed (the app debounces).
    @discardableResult
    public func resize(_ size: TerminalSize) async -> Bool {
        let accepted = await connection.resize(size)
        // stmclient.cc:418: the engine is reset whether or not the resize could be sent.
        engine.reset()
        render(now: clock.nowMilliseconds())
        return accepted
    }

    /// Local echo's display mode and overwrite switch (mosh's `--predict` and
    /// `--predict-overwrite`; `set_display_preference`, `set_predict_overwrite`,
    /// terminaloverlay.h:272-273). Takes effect at once.
    public func setPrediction(_ settings: PredictionSettings) {
        engine.setDisplayPreference(settings.display)
        engine.setPredictOverwrite(settings.overwrite)
        render(now: clock.nowMilliseconds())
    }

    public func predictionSettings() -> PredictionSettings { engine.settings }

    /// The per-host clipboard switch.
    public func setClipboardWriting(enabled: Bool) {
        clipboard.isEnabled = enabled
    }

    // MARK: Reading

    /// The newest screen.
    public func screen() async -> ScreenUpdate {
        let newest = await connection.newestRemoteState()
        return ScreenUpdate(number: newest.number, state: newest.state.terminal, isLive: true)
    }

    /// The ages for the "Last contact" banner, now.
    public func contactAges() async -> ContactAges {
        await connection.contactAges()
    }

    public func smoothedRoundTripTime() async -> Double { await connection.smoothedRoundTripTime() }
    public func isQuiesced() async -> Bool { await connection.isQuiesced() }
    public func datagramsSent() async -> UInt64 { await connection.datagramsSent() }
    public func unacknowledgedInputCount() async -> Int { await connection.unacknowledgedInputCount() }
    public func retransmissions() async -> UInt64 { await connection.retransmissions() }
    public func acknowledgedStateNumber() async -> UInt64 { await connection.acknowledgedStateNumber() }
    public func clipboardPolicy() -> ClipboardPolicy { clipboard }

    /// The frame last rendered with local echo's guesses (mosh's `local_framebuffer`). Equal to
    /// the newest remote framebuffer this actor has read when no guess is drawn. For tools and
    /// tests; the app draws `.display` events.
    public func displayedScreen() -> Framebuffer { shown }

    func predictionEngineForTesting() -> PredictionEngine { engine }
    func predictionTimerIsArmedForTesting() -> Bool { predictionTimer != nil }

    // MARK: Events

    func setBeforeEventForTesting(_ hook: (@Sendable () async -> Void)?) {
        beforeEvent = hook
    }

    private func handle(_ event: ConnectionEvent) async {
        if let beforeEvent { await beforeEvent() }
        guard !closed else { return }
        switch event {
        case .contact(let ages):
            continuation.yield(.contact(ages))
            // stmclient.cc:290-301: every recv gives the engine its three readings.
            let readings = await connection.predictionReadings()
            guard !closed else { return }
            if apply(readings) != nil {
                render(now: clock.nowMilliseconds())
            }
        case .networkError(let text):
            continuation.yield(.networkProblem(text))
        case .transport(let transportEvent):
            switch transportEvent {
            case .remoteStateAdvanced:
                let readings = await connection.predictionReadings()
                guard !closed else { return }
                let reported = reportNewestScreen(readings.newest)
                let applied = apply(readings) != nil
                // Every `.screen` gets a `.display` after it, even when `resume()` already
                // rendered this state, so the app never keeps a frame older than the screen.
                if reported, engine.settings.display != .never { lastDisplayed = nil }
                if applied || reported {
                    render(now: clock.nowMilliseconds())
                }
            case .serverShutdown:
                let final = await connection.finalRemoteState()
                await endPrediction()
                continuation.yield(.serverEnded(final?.terminal))
            case .shutdownAcknowledged:
                await endPrediction()
                continuation.yield(.shutdownFinished(acknowledged: true))
            case .shutdownTimedOut:
                await endPrediction()
                continuation.yield(.shutdownFinished(acknowledged: false))
            case .baseStateLost(let serverBase):
                await endPrediction()
                continuation.yield(.baseStateLost(serverBase: serverBase))
            case .internalError(let violation):
                await endPrediction()
                continuation.yield(.halted("\(violation)"))
            case .gateFailed(let text):
                continuation.yield(.gateFailed(text))
            case .peerProtocolError(let text):
                continuation.yield(.protocolProblem(text))
            case .instructionApplied(let applied):
                continuation.yield(.instructionApplied(applied))
            case .serverShutdownAcknowledged:
                continuation.yield(.serverEndAcknowledged)
            case .socketReplacementWanted:
                break
            }
        }
    }

    /// Reports the newest state (several advances may have happened since the event) once,
    /// then lets the clipboard policy look at it. Never an older one than already reported: a
    /// handler that resumes after a newer state was reported yields nothing.
    @discardableResult
    private func reportNewestScreen(_ newest: NumberedRemoteState<TerminalRemoteState>) -> Bool {
        if let last = lastScreenNumber, newest.number <= last { return false }
        lastScreenNumber = newest.number
        let update = ScreenUpdate(number: newest.number, state: newest.state.terminal, isLive: true)
        continuation.yield(.screen(update))
        report(clipboard.observe(update.framebuffer.clipboard, live: true))
        return true
    }

    private func report(_ decision: ClipboardPolicy.Decision) {
        switch decision {
        case .write, .invalid:
            continuation.yield(.clipboard(decision))
        case .none:
            break
        }
    }

    // MARK: Local echo

    /// stmclient.cc:298-300 from one reading, which also gives the frame the next render draws
    /// on. Nil (nothing applied) when a newer reading was applied while this one waited.
    private func apply(
        _ readings: (sender: SenderReadings, newest: NumberedRemoteState<TerminalRemoteState>)
    ) -> UInt64? {
        guard readings.newest.number >= latest.number else { return nil }
        engine.setLocalFrameAcked(readings.sender.acknowledgedStateNumber)
        engine.setSendInterval(readings.sender.sendInterval)
        engine.setLocalFrameLateAcked(readings.newest.state.echoAck)
        latest = (readings.newest.number, readings.newest.state.framebuffer)
        return readings.newest.number
    }

    /// mosh's `output_new_frame` (stmclient.cc:267-288) without notifications and title (D1):
    /// a copy of the newest remote frame, culled and drawn on, becomes the shown frame.
    private func render(now: UInt64) {
        guard started, !closed else { return }
        let frame = engine.overlay(latest.framebuffer, now: now)
        shown = frame
        emitDisplay(frame)
        armPredictionTimer()
    }

    /// A `.display` for every new remote state and for every change of the frame while the
    /// mode is not `never` (an unchanged frame is skipped, as `Display::new_frame` writes
    /// nothing for it); after a switch to `never` one more with the remote frame.
    private func emitDisplay(_ frame: Framebuffer) {
        if engine.settings.display == .never {
            guard lastDisplayed != nil else { return }
            lastDisplayed = nil
            displaySerial &+= 1
            continuation.yield(.display(DisplayFrame(serial: displaySerial, number: latest.number,
                                                     framebuffer: latest.framebuffer, hasPredictions: false)))
            return
        }
        if let last = lastDisplayed, last.number == latest.number, last.framebuffer == frame { return }
        displaySerial &+= 1
        lastDisplayed = (latest.number, frame)
        continuation.yield(.display(DisplayFrame(serial: displaySerial, number: latest.number, framebuffer: frame,
                                                 hasPredictions: frame != latest.framebuffer)))
    }

    /// mosh's loop waits at most `overlays.wait_time()` (50 ms) before the next frame
    /// (stmclient.cc:441-444). While a guess is active and no timing test is due, mosh still
    /// culls on every network pass; a 250 ms timer stands in for those passes (design 4.1).
    private func armPredictionTimer() {
        predictionTimer?.cancel()
        predictionTimer = nil
        guard !quiesced, !ended, !closed else { return }
        let delay: UInt64
        if engine.waitTime() == 50 {
            delay = 50
        } else if engine.isActive {
            delay = 250
        } else {
            return
        }
        predictionTimer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            } catch {
                return
            }
            await self?.predictionTimerFired()
        }
    }

    private func predictionTimerFired() {
        // A render in between replaced (and cancelled) this timer.
        guard !Task.isCancelled else { return }
        predictionTimer = nil
        render(now: clock.nowMilliseconds())
    }

    private func stopPredictionTimer() {
        quiesced = true
        predictionTimer?.cancel()
        predictionTimer = nil
    }

    /// The session is over: no echo ack will come. The last `.display` is the newest remote
    /// frame without a guess, and no timer runs (mosh-client exits at that point).
    private func endPrediction() async {
        let readings = await connection.predictionReadings()
        guard !closed, !ended else { return }
        _ = apply(readings)
        ended = true
        engine.reset()
        render(now: clock.nowMilliseconds())
        predictionTimer?.cancel()
        predictionTimer = nil
    }
}
