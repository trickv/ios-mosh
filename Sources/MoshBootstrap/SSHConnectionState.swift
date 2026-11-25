import Foundation
import NIOCore
import NIOSSH

/// Errors this module puts into the pipeline itself. They carry no information: what happened is
/// in `SSHConnectionState`, and `BootstrapError.classify` reads it from there.
enum SSHInternalError: Error {
    /// The login ran out of methods, or the user gave up.
    case authenticationAbandoned
    /// A step's timer fired.
    case timedOut
    /// The connection closed.
    case closed
}

/// Everything one SSH connection knows about itself: the settings it was opened with, how far
/// it got, and what went wrong. Written by the channel handlers and the two swift-nio-ssh
/// delegates (on the event loop and from the tasks that run user prompts) and read by the async
/// API, so all mutable state is behind a lock.
final class SSHConnectionState: @unchecked Sendable {
    let target: SSHTarget
    let knownHosts: KnownHosts
    let interaction: SSHInteraction
    let timeouts: SSHTimeouts
    let privateKey: NIOSSHPrivateKey?
    let maxPasswordAttempts: Int

    /// Completed when the login succeeded, failed when the connection ended before that.
    let authenticated = OneShot<Void>()

    private let lock = NSLock()
    private var stage: BootstrapStage = .connect
    private var serverAlgorithms: ServerAlgorithms?
    private var hostKeyFailure: KnownHostsError?
    private var trace: AuthenticationTrace
    private var connectivity: [ConnectivityEvent] = []
    private var firstError: Error?
    private var timedOut = false
    private var cancelled = false
    private var loggedIn = false
    private var lastOffer: LoginMethod = .none
    private var watchdog: Scheduled<Void>?
    private var channel: Channel?

    init(
        target: SSHTarget, knownHosts: KnownHosts, interaction: SSHInteraction, timeouts: SSHTimeouts,
        privateKey: NIOSSHPrivateKey?, maxPasswordAttempts: Int
    ) {
        self.target = target
        self.knownHosts = knownHosts
        self.interaction = interaction
        self.timeouts = timeouts
        self.privateKey = privateKey
        self.maxPasswordAttempts = max(1, maxPasswordAttempts)
        self.trace = AuthenticationTrace(keyAvailable: privateKey != nil)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Progress

    func setChannel(_ channel: Channel) {
        locked { self.channel = channel }
    }

    func setStage(_ newStage: BootstrapStage) {
        locked { stage = newStage }
    }

    func record(_ algorithms: ServerAlgorithms) {
        locked { serverAlgorithms = algorithms }
    }

    func record(_ event: ConnectivityEvent) {
        locked { connectivity.append(event) }
    }

    func record(hostKeyFailure failure: KnownHostsError) {
        locked { hostKeyFailure = failure }
    }

    func record(methods: NIOSSHAvailableUserAuthenticationMethods) {
        var offered: LoginMethods = []
        if methods.contains(.publicKey) { offered.insert(.publicKey) }
        if methods.contains(.password) { offered.insert(.password) }
        if methods.contains(.hostBased) { offered.insert(.hostBased) }
        locked { trace.methodsOffered = offered }
    }

    func recordKeyRejected() {
        locked { trace.keyRejected = true }
    }

    func recordPasswordRejected() {
        locked { trace.passwordsRejected += 1 }
    }

    func recordPromptCancelled() {
        locked { trace.promptCancelled = true }
    }

    func recordOffer(_ method: LoginMethod) {
        locked { lastOffer = method }
    }

    func markCancelled() {
        locked { cancelled = true }
    }

    var serverAlgorithmsSeen: ServerAlgorithms? { locked { serverAlgorithms } }
    /// The method of the offer that the host accepted. Valid after `authenticated` succeeded.
    var loginMethod: LoginMethod { locked { lastOffer } }
    var isLoggedIn: Bool { locked { loggedIn } }

    // MARK: - Outcome

    func authenticationSucceeded() {
        disarmWatchdog()
        locked { loggedIn = true }
        authenticated.succeed(())
    }

    /// Records the first error and ends the wait for the login.
    func fail(_ error: Error) {
        locked { if firstError == nil { firstError = error } }
        disarmWatchdog()
        authenticated.fail(error)
    }

    func connectionClosed() {
        disarmWatchdog()
        authenticated.fail(SSHInternalError.closed)
    }

    // MARK: - Watchdog

    /// Starts (or restarts) the timer for the current step of the handshake. When it fires the
    /// connection is closed and the failure is reported as a timeout of that step.
    func armWatchdog(on loop: EventLoop, stage watchedStage: BootstrapStage) {
        let milliseconds = Int64((timeouts.handshake * 1000).rounded())
        let task: Scheduled<Void> = loop.scheduleTask(in: .milliseconds(max(1, milliseconds))) { [weak self] in
            guard let self else { return }
            self.watchdogFired(watchedStage)
        }
        let old: Scheduled<Void>? = locked {
            let previous = watchdog
            watchdog = task
            return previous
        }
        old?.cancel()
    }

    func disarmWatchdog() {
        let old: Scheduled<Void>? = locked {
            let previous = watchdog
            watchdog = nil
            return previous
        }
        old?.cancel()
    }

    private func watchdogFired(_ watchedStage: BootstrapStage) {
        let toClose: Channel? = locked {
            guard !loggedIn else { return nil }
            timedOut = true
            stage = watchedStage
            if firstError == nil { firstError = SSHInternalError.timedOut }
            return channel
        }
        guard let toClose else { return }
        authenticated.fail(SSHInternalError.timedOut)
        toClose.close(promise: nil)
    }

    // MARK: - Evidence

    /// What is known about a failure before or during the login.
    func evidence() -> BootstrapEvidence {
        locked {
            var evidence = BootstrapEvidence(stage: stage, host: target.host)
            evidence.serverAlgorithms = serverAlgorithms
            evidence.hostKeyFailure = hostKeyFailure
            evidence.authentication = trace
            evidence.connectivity = connectivity
            evidence.timedOut = timedOut
            evidence.cancelled = cancelled
            if let firstError {
                evidence.sshFailure = Self.failureKind(of: firstError)
                evidence.errorDescription = Self.describe(firstError)
            }
            return evidence
        }
    }

    /// What is known about a failure of an operation after the login.
    func evidence(stage operationStage: BootstrapStage, timedOut operationTimedOut: Bool, error: Error?) -> BootstrapEvidence {
        var evidence = self.evidence()
        evidence.stage = operationStage
        evidence.timedOut = operationTimedOut
        // The login is over; its trace must not turn a later failure into a login error.
        evidence.authentication = AuthenticationTrace()
        evidence.hostKeyFailure = nil
        if let error {
            evidence.sshFailure = Self.failureKind(of: error) ?? evidence.sshFailure
            evidence.errorDescription = Self.describe(error) ?? evidence.errorDescription
        }
        return evidence
    }

    static func failureKind(of error: Error) -> SSHFailureKind? {
        if let sshError = error as? NIOSSHError {
            if sshError.type == .keyExchangeNegotiationFailure { return .algorithmNegotiation }
            if sshError.type == .tcpShutdown || sshError.type == .creatingChannelAfterClosure {
                return .connectionClosed
            }
            return .protocolError
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed:
                return .connectionClosed
            default:
                return nil
            }
        }
        if let internalError = error as? SSHInternalError, case .closed = internalError {
            return .connectionClosed
        }
        return nil
    }

    /// Text for errors that come from the network or the library. nil for this module's own
    /// marker errors, which say nothing a user could use.
    static func describe(_ error: Error) -> String? {
        if error is SSHInternalError || error is KnownHostsError || error is CancellationError { return nil }
        return String(describing: error)
    }
}
