// A mosh session driven step by step: what `moshcli connect` and `moshcli soak` are made of.
import Foundation
import MoshBootstrap
import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import MoshWire

/// Milliseconds on a clock that does not jump.
func monotonicMilliseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000_000
}

func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// moshcli's exit codes (docs/PLAN.md "Test tools").
enum ExitCode {
    static let done: Int32 = 0
    /// An `expect` or another wait ran out of time.
    static let expectationFailed: Int32 = 1
    static let usage: Int32 = 2
    /// The server builds on a state we do not hold: only a new session helps.
    static let fallbackNeeded: Int32 = 3
    /// The server ended the session.
    static let serverEnded: Int32 = 4
    /// The transport stopped itself (an invariant did not hold) or could not be set up.
    static let internalError: Int32 = 5
    /// `MOSH CONNECT` was seen (or a port and key given), but no state came from the server
    /// within the no-reply timeout (15 s): UDP is blocked.
    static let noServerReply: Int32 = 6
    /// `moshcli bootstrap`: the SSH login or the server start failed.
    static let bootstrapFailed: Int32 = 7
    /// `moshcli resume`: the record is in use or cannot be read now; try again later.
    static let retryLater: Int32 = 8
}

/// The outcome of one step.
enum StepResult: Equatable {
    case ok
    /// Stop the script with this exit code; the text says why.
    case stop(Int32, String)
}

/// What a `ScriptedSession` drives: the facade alone with a gate in memory (`moshcli connect`,
/// `soak`, `bootstrap`), or a `ResumeCoordinator` with the session's record on disk
/// (`--session-root`, `moshcli resume`).
enum SessionDriver {
    case plain(MoshSession)
    case recorded(ResumeCoordinator)

    var events: AsyncStream<SessionEvent> {
        switch self {
        case .plain(let session): return session.events
        case .recorded(let coordinator): return coordinator.events
        }
    }

    func type(_ bytes: [UInt8]) async -> Bool {
        switch self {
        case .plain(let session): return await session.type(bytes)
        case .recorded(let coordinator): return await coordinator.type(bytes)
        }
    }

    func resize(_ size: TerminalSize) async -> Bool {
        switch self {
        case .plain(let session): return await session.resize(size)
        case .recorded(let coordinator): return await coordinator.resize(size)
        }
    }

    func screen() async -> ScreenUpdate {
        switch self {
        case .plain(let session): return await session.screen()
        case .recorded(let coordinator): return await coordinator.screen()
        }
    }

    /// The shown frame (local echo). With a record the coordinator forwards the session's
    /// `.display` events, and `latestDisplay` is the newest of them.
    func displayed(latestDisplay: Framebuffer?) async -> Framebuffer {
        switch self {
        case .plain(let session): return await session.displayedScreen()
        case .recorded(let coordinator):
            if let latestDisplay { return latestDisplay }
            return await coordinator.screen().framebuffer
        }
    }

    func unacknowledgedInputCount() async -> Int {
        switch self {
        case .plain(let session): return await session.unacknowledgedInputCount()
        case .recorded(let coordinator): return await coordinator.unacknowledgedInputCount()
        }
    }

    func retransmissions() async -> UInt64 {
        switch self {
        case .plain(let session): return await session.retransmissions()
        case .recorded(let coordinator): return await coordinator.retransmissions()
        }
    }

    func replaceSocket() async {
        switch self {
        case .plain(let session): await session.replaceSocket()
        case .recorded(let coordinator): await coordinator.replaceSocket()
        }
    }

    func isQuiesced() async -> Bool {
        switch self {
        case .plain(let session): return await session.isQuiesced()
        case .recorded(let coordinator): return await coordinator.isInBackground
        }
    }

    /// Quiesces. With a record this is "leaving the foreground": the snapshot is stored and
    /// the record marked clean; the result says whether it is.
    func quiesce(afterSend: Bool) async -> SaveOutcome? {
        switch self {
        case .plain(let session):
            if afterSend { await session.quiesceAfterSend() } else { await session.quiesce() }
            return nil
        case .recorded(let coordinator):
            return await coordinator.enterBackground(afterSend: afterSend)
        }
    }

    func resume() async {
        switch self {
        case .plain(let session): await session.resume()
        case .recorded(let coordinator): await coordinator.enterForeground()
        }
    }

    func shutdown() async {
        switch self {
        case .plain(let session): await session.shutdown()
        case .recorded(let coordinator): await coordinator.shutdown()
        }
    }

    func close() async {
        switch self {
        case .plain(let session): await session.close()
        case .recorded(let coordinator): await coordinator.close()
        }
    }
}

/// One mosh session against a real server: a `MoshSession` (the facade the app uses, replaced
/// at every `resumeMem`) with its gate, or a `ResumeCoordinator` with its record, and what
/// arrived so far.
///
/// The step methods are called from one task, one at a time. Events arrive on another task and
/// are kept behind a lock.
final class ScriptedSession: @unchecked Sendable {
    struct Settings {
        var host: String
        var port: UInt16
        var key: Base64Key
        var size: TerminalSize
        /// The server's terminal size when it started: the size of remote state 0. 80x24 for a
        /// server started without a tty, the pty size after an SSH bootstrap.
        var serverStartSize: TerminalSize
        /// nil: never report "no UDP reply".
        var noReplyTimeout: UInt64? = MoshSession.defaultNoReplyTimeout
        var recorder: Recorder?
        var tap: WireTap
        /// `--seq-log`: every number taken from the gate.
        var numbers: NumbersLog? = nil
        /// `--predict`, `--predict-overwrite`.
        var prediction: PredictionSettings = .off
    }

    private let settings: Settings
    private let endpoint: SessionEndpoint
    private var size: TerminalSize

    // Touched only by the stepping task.
    private var driver: SessionDriver
    private var gate: InMemoryGate
    private var eventTask: Task<Void, Never>
    private var retransmissionsOfDiscardedSessions: UInt64 = 0
    private(set) var resumes = 0

    // Behind the lock.
    private let lock = NSLock()
    private var hostBytes: [UInt8] = []
    /// `expect` searches from here: the end of the previous match.
    private var mark = 0
    private var lastStateAt = monotonicMilliseconds()
    private var statesApplied: UInt64 = 0
    private var baseLost = false
    private var serverEnded = false
    private var serverEndAcknowledged = false
    private var shutdownAcknowledged = false
    private var shutdownTimedOut = false
    private var internalError: String?
    private var noReply: BootstrapError?
    private var lastNetworkError = ""
    /// `.display` events so far, and the newest one's frame.
    private var displayCount = 0
    private var latestDisplay: Framebuffer?
    private var signalSource: DispatchSourceSignal?

    /// Connects: the first datagram is on its way when this returns.
    init(_ settings: Settings) async throws {
        self.settings = settings
        size = settings.size
        endpoint = SessionEndpoint(host: settings.host, port: settings.port, key: settings.key)
        let gate = InMemoryGate()
        self.gate = gate
        let tap = settings.tap, host = settings.host, port = settings.port
        let session = try MoshSession(
            endpoint: endpoint,
            initialSize: settings.size,
            serverStartSize: settings.serverStartSize,
            gate: settings.numbers.map { LoggingGate(gate, log: $0) } ?? gate,
            configuration: Self.configuration(for: endpoint),
            noReplyTimeout: settings.noReplyTimeout,
            prediction: settings.prediction,
            makeTransport: { try tap.open(host: host, port: port) }
        )
        driver = .plain(session)
        eventTask = Task {}
        eventTask = listen(to: driver)
        await session.start()
    }

    /// A session with a record (`--session-root`, `moshcli resume`): starts the coordinator,
    /// which was made with `recordOptions(...)`.
    init(_ settings: Settings, coordinator: ResumeCoordinator) async throws {
        self.settings = settings
        size = settings.size
        endpoint = SessionEndpoint(host: settings.host, port: settings.port, key: settings.key)
        gate = InMemoryGate()   // not used
        driver = .recorded(coordinator)
        eventTask = Task {}
        eventTask = listen(to: driver)
        try await coordinator.start()
    }

    /// The defaults, plus the applied instructions for `--record` and the host-bytes `expect`.
    static func configuration(for endpoint: SessionEndpoint) -> TransportConfiguration {
        var configuration = TransportConfiguration(family: endpoint.family)
        configuration.reportsInstructions = true
        return configuration
    }

    private func listen(to driver: SessionDriver) -> Task<Void, Never> {
        // The task holds the event stream, not the session.
        let events = driver.events
        return Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .instructionApplied(let applied):
            lastStateAt = monotonicMilliseconds()
            statesApplied += 1
            let message = (try? HostMessage(serialized: applied.diff)) ?? HostMessage()
            for instruction in message.instructions {
                if case .hostBytes(let bytes) = instruction {
                    hostBytes.append(contentsOf: bytes)
                }
            }
            settings.recorder?.record(applied, message: message)
        case .screen:
            lastStateAt = monotonicMilliseconds()
        case .serverEnded:
            serverEnded = true
        case .serverEndAcknowledged:
            serverEndAcknowledged = true
        case .shutdownFinished(let acknowledged):
            if acknowledged { shutdownAcknowledged = true } else { shutdownTimedOut = true }
        case .baseStateLost(let serverBase):
            baseLost = true
            writeError("moshcli: the server builds on state \(serverBase), which is not held")
        case .halted(let violation):
            internalError = violation
        case .gateFailed(let description):
            writeError("moshcli: gate: \(description)")
        case .protocolProblem(let description):
            writeError("moshcli: peer protocol error: \(description)")
        case .noServerReply(let error):
            noReply = error
            writeError("moshcli: \(error.message)")
        case .networkProblem(let description):
            if description != lastNetworkError {
                lastNetworkError = description
                writeError("moshcli: network: \(description)")
            }
        case .display(let frame):
            displayCount += 1
            latestDisplay = frame.framebuffer
        case .contact, .clipboard:
            break
        }
    }

    /// Reads or changes the state behind the lock.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Waiting

    /// Why the session cannot go on, if it cannot.
    private func fatal() -> StepResult? {
        lock.lock()
        defer { lock.unlock() }
        if let internalError {
            return .stop(ExitCode.internalError, "the transport halted: \(internalError)")
        }
        if baseLost {
            return .stop(ExitCode.fallbackNeeded, "the base state is lost: a new session is needed")
        }
        if serverEnded {
            return .stop(ExitCode.serverEnded, "the server ended the session")
        }
        if let noReply {
            return .stop(ExitCode.noServerReply, noReply.message)
        }
        return nil
    }

    private enum Waited {
        case satisfied
        case timedOut
        case stopped(StepResult)
    }

    /// Polls every 5 ms. The condition is looked at before the reasons to stop, so that text
    /// which arrived together with the end of the session is still found.
    private func wait(timeout: UInt64?, until condition: () async -> Bool) async -> Waited {
        let deadline = timeout.map { monotonicMilliseconds() + $0 }
        while true {
            if await condition() { return .satisfied }
            if let stop = fatal() { return .stopped(stop) }
            if let deadline, monotonicMilliseconds() >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Steps

    func type(_ bytes: [UInt8]) async -> StepResult {
        if await driver.type(bytes) { return .ok }
        return fatal() ?? .stop(ExitCode.expectationFailed, "the session takes no more input")
    }

    func resize(width: Int, height: Int) async -> StepResult {
        let newSize = TerminalSize(width: width, height: height)
        if await driver.resize(newSize) {
            size = newSize
            return .ok
        }
        return fatal() ?? .stop(ExitCode.expectationFailed, "the session takes no more input")
    }

    /// Until the server has acknowledged every input event.
    func waitAck(timeout: UInt64) async -> StepResult {
        let driver = self.driver
        switch await wait(timeout: timeout, until: { await driver.unacknowledgedInputCount() == 0 }) {
        case .satisfied: return .ok
        case .stopped(let stop): return stop
        case .timedOut:
            let left = await driver.unacknowledgedInputCount()
            return .stop(ExitCode.expectationFailed, "wait-ack: \(left) input events not acknowledged after \(timeout) ms")
        }
    }

    /// Until `text` appears in the host bytes received after the previous match. Returns the
    /// time waited.
    func expect(_ text: [UInt8], timeout: UInt64) async -> (result: StepResult, waited: UInt64) {
        let started = monotonicMilliseconds()
        var scanned = 0
        let waited = await wait(timeout: timeout, until: { self.findAndMark(text, scanned: &scanned) })
        let elapsed = monotonicMilliseconds() - started
        switch waited {
        case .satisfied: return (.ok, elapsed)
        case .stopped(let stop): return (stop, elapsed)
        case .timedOut:
            return (.stop(ExitCode.expectationFailed, "expect: \(quotedBytes(text)) did not arrive within \(timeout) ms; "
                    + "the last host bytes are \(quotedBytes(tail(200)))"), elapsed)
        }
    }

    /// Until a row of the newest screen contains `text` (rows as `visibleText(of:)` gives them,
    /// trailing blanks cut). The screen shows only the newest state: text that scrolled off is
    /// not found, use `expect` for that.
    func expectScreen(_ text: String, timeout: UInt64) async -> StepResult {
        let driver = self.driver
        let waited = await wait(timeout: timeout, until: {
            visibleText(of: await driver.screen().framebuffer).contains { $0.contains(text) }
        })
        switch waited {
        case .satisfied: return .ok
        case .stopped(let stop): return stop
        case .timedOut:
            let rows = await screenRows()
            return .stop(ExitCode.expectationFailed, "expect-screen: \(quotedBytes(Array(text.utf8))) is not on the screen "
                         + "after \(timeout) ms; the screen is:\n" + rows.joined(separator: "\n"))
        }
    }

    private func findAndMark(_ needle: [UInt8], scanned: inout Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !needle.isEmpty, hostBytes.count >= needle.count else { return false }
        var index = max(mark, scanned)
        let last = hostBytes.count - needle.count
        while index <= last {
            if hostBytes[index] == needle[0], hostBytes[index..<(index + needle.count)].elementsEqual(needle) {
                mark = index + needle.count
                return true
            }
            index += 1
        }
        scanned = max(scanned, index)
        return false
    }

    private func tail(_ count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return Array(hostBytes.suffix(count))
    }

    /// Until no server state has arrived for `quiet` ms. Gives up after `quiet` + 60 s.
    func settle(_ quiet: UInt64) async -> StepResult {
        let waited = await wait(timeout: quiet + 60_000, until: {
            monotonicMilliseconds() >= self.locked { self.lastStateAt } + quiet
        })
        switch waited {
        case .satisfied: return .ok
        case .stopped(let stop): return stop
        case .timedOut: return .stop(ExitCode.expectationFailed, "settle: server states kept arriving")
        }
    }

    func sleep(_ milliseconds: UInt64) async -> StepResult {
        switch await wait(timeout: milliseconds, until: { false }) {
        case .stopped(let stop): return stop
        case .satisfied, .timedOut: return .ok
        }
    }

    func rebind() async -> StepResult {
        await driver.replaceSocket()
        return .ok
    }

    /// With a record, a quiesce stores the snapshot; the script stops if the record is not
    /// clean afterwards (a script that wants a dirty record does not quiesce).
    func quiesce(afterSend: Bool) async -> StepResult {
        guard let outcome = await driver.quiesce(afterSend: afterSend) else { return .ok }
        if outcome.isClean {
            writeError("moshcli: quiesce: the record is clean")
            return .ok
        }
        return fatal() ?? .stop(ExitCode.expectationFailed, "quiesce: the record is not resumable: \(outcome)")
    }

    func resume() async -> StepResult {
        guard await driver.isQuiesced() else {
            return .stop(ExitCode.usage, "resume without a quiesce before it")
        }
        await driver.resume()
        return .ok
    }

    /// `SIGUSR1` quiesces (docs/PLAN.md "Test tools"): with a record, the snapshot is stored.
    /// The script goes on; what it types from then on is input in the background.
    func installQuiesceSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                switch await self.driver.quiesce(afterSend: false) {
                case .none: writeError("moshcli: SIGUSR1: quiesced")
                case .some(.clean): writeError("moshcli: SIGUSR1: quiesced; the record is clean")
                case .some(let outcome): writeError("moshcli: SIGUSR1: quiesced; the record is not resumable: \(outcome)")
                }
            }
        }
        source.resume()
        lock.lock()
        signalSource = source
        lock.unlock()
    }

    /// Exports the state, discards the session object and continues in a new one: a new gate
    /// that starts at the old one's reserved limits, a new socket. This is a cold start with a
    /// record (docs/PLAN.md section 3) without the disk.
    func resumeMem(dropFirst: Int) async -> StepResult {
        guard case .plain(let session) = driver else {
            return .stop(ExitCode.usage, "resume-mem is for a session without a record; with one, use moshcli resume")
        }
        if !(await session.isQuiesced()) {
            await session.quiesce()
        }
        let snapshot: SessionSnapshot
        do {
            snapshot = try await session.exportState().snapshot
        } catch {
            return fatal() ?? .stop(ExitCode.internalError, "resume-mem: export failed: \(error)")
        }
        let limits = gate.reservedLimits
        retransmissionsOfDiscardedSessions += await session.retransmissions()
        await session.close()
        await eventTask.value

        settings.tap.dropNextDatagrams(dropFirst)
        let newGate = InMemoryGate(startingAt: limits)
        let host = settings.host, port = settings.port, tap = settings.tap
        let newSession: MoshSession
        do {
            newSession = try MoshSession(
                restoring: snapshot,
                endpoint: endpoint,
                gate: settings.numbers.map { LoggingGate(newGate, log: $0) } ?? newGate,
                currentSize: size,
                configuration: Self.configuration(for: endpoint),
                prediction: settings.prediction,
                makeTransport: { try tap.open(host: host, port: port) }
            )
        } catch {
            return .stop(ExitCode.internalError, "resume-mem: import failed: \(error)")
        }
        gate = newGate
        driver = .plain(newSession)
        eventTask = listen(to: driver)
        await newSession.start()
        resumes += 1
        return .ok
    }

    /// The newest screen's rows, trailing blanks cut.
    func screenRows() async -> [String] {
        visibleText(of: await driver.screen().framebuffer)
    }

    /// Writes the rendered screen: one line per row, trailing blanks cut, the same form as
    /// `tmux capture-pane -p`.
    func dumpScreen(to path: String) async -> StepResult {
        let rows = await screenRows()
        return write(Data((rows.map { $0 + "\n" }.joined()).utf8), to: path, what: "dump-screen")
    }

    // MARK: Local echo

    /// The shown frame: the newest remote screen with local echo's guesses.
    func displayedFrame() async -> Framebuffer {
        await driver.displayed(latestDisplay: locked { latestDisplay })
    }

    private func rows(_ framebuffer: Framebuffer) -> String {
        visibleText(of: framebuffer).joined(separator: "\n")
    }

    private func onARow(_ text: String, _ framebuffer: Framebuffer) -> Bool {
        visibleText(of: framebuffer).contains { $0.contains(text) }
    }

    private func timedOut(_ what: String, _ text: String?, _ timeout: UInt64) async -> StepResult {
        let shown = await displayedFrame()
        let remote = await driver.screen().framebuffer
        let quoted = text.map { quotedBytes(Array($0.utf8)) + " " } ?? ""
        return .stop(ExitCode.expectationFailed, "\(what): \(quoted)not seen within \(timeout) ms; the shown frame is:\n"
                     + rows(shown) + "\nand the remote screen is:\n" + rows(remote))
    }

    private func outcome(_ waited: Waited, _ what: String, _ text: String?, _ timeout: UInt64) async -> StepResult {
        switch waited {
        case .satisfied: return .ok
        case .stopped(let stop): return stop
        case .timedOut: return await timedOut(what, text, timeout)
        }
    }

    func expectDisplay(_ text: String, timeout: UInt64) async -> StepResult {
        let waited = await wait(timeout: timeout, until: { self.onARow(text, await self.displayedFrame()) })
        return await outcome(waited, "expect-display", text, timeout)
    }

    func expectPredicted(_ text: String, timeout: UInt64) async -> StepResult {
        let driver = self.driver
        let waited = await wait(timeout: timeout, until: {
            let shown = await self.displayedFrame()
            let remote = await driver.screen().framebuffer
            return self.onARow(text, shown) && !self.onARow(text, remote)
        })
        return await outcome(waited, "expect-predicted", text, timeout)
    }

    func expectDisplaySettled(timeout: UInt64) async -> StepResult {
        let driver = self.driver
        let waited = await wait(timeout: timeout, until: {
            let shown = await self.displayedFrame()
            let remote = await driver.screen().framebuffer
            return shown == remote
        })
        return await outcome(waited, "expect-display-settled", nil, timeout)
    }

    /// TEXT on a row of the shown frame, one cell per character, every cell underlined.
    func expectUnderlined(_ text: String, timeout: UInt64) async -> StepResult {
        let wanted = text.unicodeScalars.map { Array(String($0).utf8) }
        let waited = await wait(timeout: timeout, until: {
            let frame = await self.displayedFrame()
            for row in frame.rows {
                let cells = row.cells
                guard cells.count >= wanted.count else { continue }
                for start in 0...(cells.count - wanted.count) {
                    var all = true
                    for (offset, contents) in wanted.enumerated() {
                        let cell = cells[start + offset]
                        if cell.contents != contents || !cell.renditions.getAttribute(.underlined) {
                            all = false
                            break
                        }
                    }
                    if all { return true }
                }
            }
            return false
        })
        return await outcome(waited, "expect-underlined", text, timeout)
    }

    func dumpDisplay(to path: String) async -> StepResult {
        let rows = visibleText(of: await displayedFrame())
        return write(Data((rows.map { $0 + "\n" }.joined()).utf8), to: path, what: "dump-display")
    }

    var displayEvents: Int { locked { displayCount } }

    /// Writes every host-bytes string received so far, in arrival order (raw, not a screen).
    func dumpBytes(to path: String) -> StepResult {
        write(Data(locked { hostBytes }), to: path, what: "dump-bytes")
    }

    private func write(_ data: Data, to path: String, what: String) -> StepResult {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return .ok
        } catch {
            return .stop(ExitCode.expectationFailed, "\(what): \(error)")
        }
    }

    /// Asks the server to end the session and waits for its acknowledgment.
    func shutdown() async -> StepResult {
        if let stop = fatal() { return stop }
        await driver.shutdown()
        while true {
            let (acknowledged, timedOut, halted) = locked { (shutdownAcknowledged, shutdownTimedOut, internalError) }
            if acknowledged { return .ok }
            if timedOut { return .stop(ExitCode.expectationFailed, "shutdown: the server did not acknowledge") }
            if let halted { return .stop(ExitCode.internalError, "the transport halted: \(halted)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Ends the client side. If the server ended the session, first gives our acknowledgment up
    /// to 3 s to leave, so that the server exits at once instead of waiting for it.
    func finish() async {
        if locked({ serverEnded }) {
            let deadline = monotonicMilliseconds() + 3000
            while monotonicMilliseconds() < deadline {
                if locked({ serverEndAcknowledged }) { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await driver.close()
        await eventTask.value
    }

    // MARK: Numbers

    /// States sent again under their own number, over all session objects.
    func retransmissions() async -> UInt64 {
        retransmissionsOfDiscardedSessions + (await driver.retransmissions())
    }

    func unacknowledgedInputCount() async -> Int {
        await driver.unacknowledgedInputCount()
    }

    var hostByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hostBytes.count
    }

    var instructionsApplied: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return statesApplied
    }
}

/// Bytes as a double-quoted string with escapes, for messages.
func quotedBytes(_ bytes: [UInt8]) -> String {
    var out = "\""
    for byte in bytes {
        switch byte {
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        case 0x1b: out += "\\e"
        case 0x22: out += "\\\""
        case 0x5c: out += "\\\\"
        case 0x20...0x7e: out += String(UnicodeScalar(byte))
        default:
            let digits = String(byte, radix: 16)
            out += "\\x" + (digits.count == 1 ? "0" + digits : digits)
        }
    }
    return out + "\""
}
