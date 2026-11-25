import Crypto
import Foundation
import MoshKeys
import NIOCore
import NIOSSH

#if canImport(Network)
import Network
import NIOTransportServices
#else
import NIOPosix
#endif

/// An authenticated SSH connection to a host, for the few things this app does over SSH: start
/// `mosh-server`, read and check its identity, stop it, and install a public key.
///
/// The connection runs on swift-nio-ssh, over Network.framework (NIOTransportServices) on Apple
/// platforms and over POSIX sockets (NIOPosix) on Linux. The host key is checked against
/// `KnownHosts` before anything is sent to the host. Every failure is thrown as a
/// `BootstrapError`.
///
/// Typical use is `SSHBootstrap.run`. Open a connection yourself to do more than one thing on
/// it, for example to offer "Install my key on this host" after a password login:
///
///     let connection = try await SSHConnection.connect(to: target, privateKey: key, ...)
///     let result = try await connection.startMoshServer(command, columns: 80, rows: 24)
///     if result.loginMethod == .password { try await connection.installAuthorizedKey(publicKey) }
///     await connection.close()
public final class SSHConnection: @unchecked Sendable {
    public let target: SSHTarget
    /// The numeric IP address the connection goes to.
    public let remoteAddress: String
    /// How the login succeeded.
    public let loginMethod: LoginMethod
    /// The algorithm lists the server announced, if they could be read.
    public let serverAlgorithms: ServerAlgorithms?

    let channel: Channel
    let state: SSHConnectionState

    private init(channel: Channel, state: SSHConnectionState, remoteAddress: String) {
        self.channel = channel
        self.state = state
        self.target = state.target
        self.remoteAddress = remoteAddress
        self.loginMethod = state.loginMethod
        self.serverAlgorithms = state.serverAlgorithmsSeen
    }

    deinit {
        channel.close(promise: nil)
    }

    // MARK: - Connect

    /// Connects, checks the host key and logs in.
    ///
    /// - Parameters:
    ///   - privateKey: the device's 32-byte Ed25519 private key, or nil to log in by password only.
    ///   - knownHosts: the store the host key is checked against and, on first contact and with the
    ///     user's consent, added to.
    ///   - interaction: the prompts for an unknown host key and for a password. The password is
    ///     asked for when the host rejects the key (or there is none) and accepts passwords; it is
    ///     handed to the SSH library for this one login and not kept.
    ///   - maxPasswordAttempts: how many passwords are tried before giving up.
    /// - Throws: `BootstrapError`.
    public static func connect(
        to target: SSHTarget, privateKey: Data?, knownHosts: KnownHosts, interaction: SSHInteraction,
        timeouts: SSHTimeouts = SSHTimeouts(), maxPasswordAttempts: Int = 3
    ) async throws -> SSHConnection {
        guard !target.host.isEmpty, (1...65535).contains(target.port), !target.user.isEmpty else {
            throw BootstrapError.invalidConfiguration("host, port or user is missing")
        }
        var sshKey: NIOSSHPrivateKey?
        if let privateKey {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
                throw BootstrapError.invalidConfiguration("the private key is not an Ed25519 key")
            }
            sshKey = NIOSSHPrivateKey(ed25519Key: key)
        }
        let state = SSHConnectionState(
            target: target, knownHosts: knownHosts, interaction: interaction, timeouts: timeouts,
            privateKey: sshKey, maxPasswordAttempts: maxPasswordAttempts)

        let connectSeconds = timeouts.connectSeconds(forHost: target.host)
        let channel: Channel
        do {
            // The future is carried through a OneShot so that cancelling the task ends the wait
            // at once; a connection that completes after that is closed again.
            let opened = OneShot<Channel>()
            openChannel(state: state, connectSeconds: connectSeconds).whenComplete { outcome in
                if !opened.complete(outcome), case .success(let late) = outcome {
                    late.close(promise: nil)
                }
            }
            do {
                channel = try await opened.value()
            } catch let error as CancellationError {
                // Stop a later completion from being taken for a result.
                if !opened.fail(error), case .success(let raced) = opened.current {
                    raced.close(promise: nil)
                }
                throw error
            }
        } catch {
            if error is CancellationError {
                state.markCancelled()
            } else if case ChannelError.connectTimeout = error {
                state.record(.connectTimeout(seconds: Int(connectSeconds.rounded())))
            } else {
                state.record(.connectFailed(reason: connectFailureReason(error)))
            }
            state.connectionClosed()
            throw BootstrapError.classify(state.evidence())
        }
        state.setChannel(channel)

        // The handshake and the login run by themselves from here; wait for the outcome.
        do {
            try await withTaskCancellationHandler {
                try await state.authenticated.value()
            } onCancel: {
                state.markCancelled()
                channel.close(promise: nil)
            }
        } catch {
            if error is CancellationError { state.markCancelled() }
            channel.close(promise: nil)
            throw BootstrapError.classify(state.evidence())
        }

        let address = channel.remoteAddress?.ipAddress ?? target.host
        return SSHConnection(channel: channel, state: state, remoteAddress: address)
    }

    /// Opens the TCP connection with the SSH pipeline in place.
    private static func openChannel(state: SSHConnectionState, connectSeconds: TimeInterval) -> EventLoopFuture<Channel> {
        let timeout = TimeAmount.milliseconds(Int64((connectSeconds * 1000).rounded()))
        let initializer: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            channel.eventLoop.makeCompletedFuture {
                let ssh = NIOSSHHandler(
                    role: .client(
                        SSHClientConfiguration(
                            userAuthDelegate: LoginDelegate(state: state),
                            serverAuthDelegate: HostKeyDelegate(state: state))),
                    allocator: channel.allocator, inboundChildChannelInitializer: nil)
                let pipeline = channel.pipeline.syncOperations
                try pipeline.addHandler(KexInitSniffer(state: state))
                try pipeline.addHandler(ssh)
                try pipeline.addHandler(RootEventsHandler(state: state))
            }
        }
        #if canImport(Network)
        // Network.framework: the connection waits while there is no usable path (and while the
        // Local Network alert is unanswered) and reports that as a WaitingForConnectivity event,
        // which RootEventsHandler records. The connect timeout still ends the wait.
        return NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton.next())
            .connectTimeout(timeout)
            .channelInitializer(initializer)
            .connect(host: state.target.host, port: state.target.port)
        #else
        return ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton.next())
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer(initializer)
            .connect(host: state.target.host, port: state.target.port)
        #endif
    }

    /// A short reason for a failed connect.
    private static func connectFailureReason(_ error: Error) -> String {
        #if !canImport(Network)
        if let connectionError = error as? NIOConnectionError {
            if let first = connectionError.connectionErrors.first {
                return connectFailureReason(first.error)
            }
            if connectionError.dnsAError != nil || connectionError.dnsAAAAError != nil {
                return "the host name was not found"
            }
        }
        #endif
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED: return "connection refused"
            case EHOSTUNREACH, ENETUNREACH: return "no route to the host"
            case ETIMEDOUT: return "the connection timed out"
            default: return String(cString: strerror(ioError.errnoCode))
            }
        }
        return String(describing: error)
    }

    // MARK: - Commands

    /// Runs a command without a pty and returns its output and exit status when it ends.
    ///
    /// The host runs the text with the user's login shell (`$SHELL -c`). Text that needs POSIX
    /// `sh` syntax should be wrapped: `sh -c ` + `ShellQuote.alwaysQuote(script)`.
    ///
    /// - Throws: `BootstrapError.timedOut(stage: .command)` if it does not end within `timeout`
    ///   (default: `timeouts.command`), `.cancelled`, `.connectionLost`.
    public func run(_ command: String, timeout: TimeInterval? = nil) async throws -> CommandResult {
        let outcome = try await execute(
            command, pty: nil, parser: nil, timeout: timeout ?? state.timeouts.command, stage: .command)
        return CommandResult(
            exitStatus: outcome.exitStatus,
            output: String(decoding: outcome.standardOutput, as: UTF8.self),
            errorOutput: String(decoding: outcome.standardError, as: UTF8.self))
    }

    /// Opens a session channel, runs the command and waits for the handler's outcome. Timeouts,
    /// cancellation and a lost connection are thrown; an outcome is returned for everything the
    /// command itself did, including a non-zero exit status.
    func execute(
        _ command: String, pty: PseudoTerminal?, parser: ConnectLineParser?, timeout: TimeInterval,
        stage: BootstrapStage
    ) async throws -> ExecOutcome {
        let result = OneShot<ExecOutcome>()
        let handler = ExecHandler(command: command, pty: pty, parser: parser, result: result)
        let loop = channel.eventLoop
        let channel = self.channel
        let milliseconds = Int64((timeout * 1000).rounded())

        loop.execute {
            // If the time runs out before the channel even opens, the handler is not in a
            // pipeline yet; it still reports the timeout.
            let timer = loop.scheduleTask(in: .milliseconds(max(1, milliseconds))) { handler.timeOut() }
            let opened = loop.makePromise(of: Channel.self)
            opened.futureResult.whenComplete { outcome in
                switch outcome {
                case .success(let child):
                    child.closeFuture.whenComplete { _ in timer.cancel() }
                    // The caller may have stopped waiting while the channel opened.
                    if result.isCompleted { child.close(promise: nil) }
                case .failure(let error):
                    timer.cancel()
                    result.fail(error)
                }
            }
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, channelType in
                    guard case .session = channelType else {
                        return child.eventLoop.makeFailedFuture(SSHInternalError.closed)
                    }
                    // Wait for the host's CLOSE instead of closing on its EOF, so the exit
                    // status that travels between the two is not lost.
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                        try child.pipeline.syncOperations.addHandler(handler)
                    }
                }
            } catch {
                // No SSH handler in the pipeline: the connection is gone.
                opened.fail(ChannelError.ioOnClosedChannel)
            }
        }

        let outcome: ExecOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await result.value()
            } onCancel: {
                loop.execute { handler.cancel() }
            }
        } catch {
            if error is CancellationError {
                loop.execute { handler.cancel() }
                throw BootstrapError.cancelled
            }
            throw BootstrapError.classify(state.evidence(stage: stage, timedOut: false, error: error))
        }
        if outcome.cancelled { throw BootstrapError.cancelled }
        // A parser that found its lines is a success even if the clock ran out a moment later.
        if outcome.timedOut, outcome.parser?.connect == nil {
            var evidence = state.evidence(stage: stage, timedOut: true, error: nil)
            evidence.output = outcome.parser?.text ?? String(decoding: outcome.standardOutput, as: UTF8.self)
            throw BootstrapError.classify(evidence)
        }
        if outcome.execRefused {
            throw BootstrapError.sshFailure(description: "the host refused to run a command")
        }
        if let error = outcome.error, outcome.exitStatus == nil, outcome.parser?.connect == nil {
            throw BootstrapError.classify(state.evidence(stage: stage, timedOut: false, error: error))
        }
        return outcome
    }

    // MARK: - Close

    /// Closes the connection. Commands still running on it are ended by the host. Safe to call
    /// more than once.
    public func close() async {
        channel.close(promise: nil)
        // Do not let a peer that never acknowledges the close hold the caller up.
        let closed = OneShot<Void>()
        channel.closeFuture.whenComplete { _ in closed.succeed(()) }
        let timer = channel.eventLoop.scheduleTask(in: .seconds(2)) { closed.succeed(()) }
        _ = try? await closed.value()
        timer.cancel()
    }

    /// Whether the connection is still open.
    public var isOpen: Bool { channel.isActive }
}
