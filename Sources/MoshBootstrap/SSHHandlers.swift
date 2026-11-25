import Crypto
import Foundation
import MoshKeys
import NIOCore
import NIOSSH

#if canImport(Network)
import NIOTransportServices
#endif

// MARK: - Root pipeline

/// Sits in front of `NIOSSHHandler` and reads the server's identification line and KEXINIT from
/// the raw stream, without changing it. See `ServerAlgorithms` for why.
final class KexInitSniffer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let state: SSHConnectionState
    private var parser = ServerKexInitParser()
    private var done = false

    init(state: SSHConnectionState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !done {
            let buffer = unwrapInboundIn(data)
            switch parser.feed(buffer.readableBytesView) {
            case .needMoreData:
                break
            case .parsed(let algorithms):
                state.record(algorithms)
                done = true
            case .invalid:
                done = true
            }
        }
        context.fireChannelRead(data)
    }
}

/// Sits behind `NIOSSHHandler` and turns what comes out of it (events, errors, the end of the
/// connection) into entries in the connection state.
final class RootEventsHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let state: SSHConnectionState

    init(state: SSHConnectionState) {
        self.state = state
    }

    func channelActive(context: ChannelHandlerContext) {
        // TCP is up and the library has sent its version line: the handshake clock starts.
        state.setStage(.keyExchange)
        state.armWatchdog(on: context.eventLoop, stage: .keyExchange)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            state.authenticationSucceeded()
        }
        #if canImport(Network)
        if let waiting = event as? NIOTSNetworkEvents.WaitingForConnectivity {
            // Fired while the connect is still pending, for example while the Local Network
            // alert is on screen.
            state.record(.waitingForConnectivity(reason: String(describing: waiting.transientError)))
        }
        #endif
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.connectionClosed()
        context.fireChannelInactive()
    }
}

// MARK: - Host key

/// Checks the host key against the known-hosts store, asking the user on first contact.
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let state: SSHConnectionState

    init(state: SSHConnectionState) {
        self.state = state
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let state = self.state
        let loop = validationCompletePromise.futureResult.eventLoop
        // The user may take as long as they like to read a fingerprint.
        state.disarmWatchdog()
        state.setStage(.hostKeyCheck)
        let line = String(openSSHPublicKey: hostKey)
        Task {
            do {
                let key: OpenSSHPublicKey
                do {
                    key = try OpenSSHPublicKey(line: line)
                } catch {
                    throw KnownHostsError.unreadable("host key from the server: \(error)")
                }
                try await state.knownHosts.verify(
                    host: state.target.host, port: state.target.port, key: key,
                    confirm: state.interaction.confirmHostKey)
                state.setStage(.authentication)
                state.armWatchdog(on: loop, stage: .authentication)
                validationCompletePromise.succeed(())
            } catch {
                state.record(hostKeyFailure: (error as? KnownHostsError) ?? .unreadable("\(error)"))
                validationCompletePromise.fail(error)
            }
        }
    }
}

// MARK: - Login

/// Logs in with the device key, then with a password from the user if the key is rejected.
///
/// swift-nio-ssh asks this object for one offer at a time. The first question comes before the
/// library knows what the host accepts, so the first offer is `none`: the host answers with its
/// real list of methods (RFC 4252 section 5.2), and OpenSSH does not count that as a failed
/// attempt. From then on: the key if there is one and the host takes keys, then passwords.
final class LoginDelegate: NIOSSHClientUserAuthenticationDelegate {
    private enum Step {
        case start
        case sentNone
        case sentKey
        case sentPassword(attempt: Int)
    }

    private let state: SSHConnectionState
    // Only touched on the event loop: the library calls `nextAuthenticationType` there.
    private var step: Step = .start
    private var keyTried = false

    init(state: SSHConnectionState) {
        self.state = state
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let loop = nextChallengePromise.futureResult.eventLoop
        state.disarmWatchdog()
        state.setStage(.authentication)

        switch step {
        case .start:
            step = .sentNone
            send(.none, as: .none, on: loop, promise: nextChallengePromise)
            return
        case .sentNone:
            break
        case .sentKey:
            state.recordKeyRejected()
        case .sentPassword:
            state.recordPasswordRejected()
        }
        // Every call after the first follows a failure message, which carries the host's list.
        state.record(methods: availableMethods)

        if !keyTried, let key = state.privateKey, availableMethods.contains(.publicKey) {
            keyTried = true
            step = .sentKey
            send(.privateKey(.init(privateKey: key)), as: .publicKey, on: loop, promise: nextChallengePromise)
            return
        }

        var attempt = 1
        if case .sentPassword(let previous) = step { attempt = previous + 1 }
        guard availableMethods.contains(.password), attempt <= state.maxPasswordAttempts else {
            // Nothing left to offer. What exactly went wrong is in the trace.
            nextChallengePromise.fail(SSHInternalError.authenticationAbandoned)
            return
        }
        step = .sentPassword(attempt: attempt)
        let prompt = PasswordPrompt(
            host: state.target.host, user: state.target.user, attempt: attempt, keyWasRejected: keyTried)
        let state = self.state
        Task {
            guard let password = await state.interaction.password(prompt) else {
                state.recordPromptCancelled()
                nextChallengePromise.fail(SSHInternalError.authenticationAbandoned)
                return
            }
            state.recordOffer(.password)
            state.armWatchdog(on: loop, stage: .authentication)
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: state.target.user, serviceName: "", offer: .password(.init(password: password))))
        }
    }

    private func send(
        _ offer: NIOSSHUserAuthenticationOffer.Offer, as method: LoginMethod, on loop: EventLoop,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        state.recordOffer(method)
        state.armWatchdog(on: loop, stage: .authentication)
        promise.succeed(NIOSSHUserAuthenticationOffer(username: state.target.user, serviceName: "", offer: offer))
    }
}

// MARK: - One command on a session channel

/// A pty for a command.
struct PseudoTerminal: Equatable, Sendable {
    var term: String
    var columns: Int
    var rows: Int
}

/// Raw result of one `exec`.
struct ExecOutcome: Sendable {
    var exitStatus: Int?
    var exitSignal: String?
    var standardOutput: [UInt8] = []
    var standardError: [UInt8] = []
    /// The host refused the `exec` request itself.
    var execRefused = false
    var timedOut = false
    var cancelled = false
    /// An error on the channel, if one ended it.
    var error: Error?
    /// The parser fed with the output, when one was given.
    var parser: ConnectLineParser?
}

/// Runs one command on an SSH session channel: optional pty request, `exec`, collect output and
/// exit status until the channel closes. With a `ConnectLineParser` it finishes as soon as the
/// parser has both of mosh-server's lines, without waiting for the channel to close.
///
/// All methods run on the channel's event loop. That confinement, not a lock, is what makes it
/// safe to hand the object to closures that hop to the loop (hence `@unchecked Sendable`).
final class ExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private enum Request {
        case pty
        case exec
    }

    /// Output beyond this is dropped; no command of this module prints anything near it.
    private static let maxOutputBytes = 256 * 1024

    private let command: String
    private let pty: PseudoTerminal?
    private let result: OneShot<ExecOutcome>
    private var outcome = ExecOutcome()
    private var awaitingReply: [Request] = []
    private var context: ChannelHandlerContext?
    private var finished = false

    init(command: String, pty: PseudoTerminal?, parser: ConnectLineParser?, result: OneShot<ExecOutcome>) {
        self.command = command
        self.pty = pty
        self.result = result
        self.outcome.parser = parser
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        finish()
    }

    func channelActive(context: ChannelHandlerContext) {
        if let pty {
            awaitingReply.append(.pty)
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: pty.term, terminalCharacterWidth: pty.columns, terminalRowHeight: pty.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
            context.triggerUserOutboundEvent(request, promise: nil)
        }
        awaitingReply.append(.exec)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        if pty == nil {
            // Nothing will be typed: end of input, so a command that reads stdin does not wait.
            context.close(mode: .output, promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = buffer.readableBytesView
        switch message.type {
        case .channel:
            append(bytes, to: &outcome.standardOutput)
        case .stdErr:
            append(bytes, to: &outcome.standardError)
        default:
            return
        }
        if outcome.parser != nil {
            // Without a pty stderr is a separate stream; the parser wants both.
            outcome.parser?.feed(bytes)
            if outcome.parser?.isComplete == true { finish() }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            outcome.exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            outcome.exitSignal = signal.signalName
        case is ChannelSuccessEvent:
            if !awaitingReply.isEmpty { awaitingReply.removeFirst() }
        case is ChannelFailureEvent:
            // A refused pty is not fatal (the command still runs, with plain pipes). A refused
            // exec is.
            if !awaitingReply.isEmpty, awaitingReply.removeFirst() == .exec {
                outcome.execRefused = true
                context.close(promise: nil)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if outcome.error == nil { outcome.error = error }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    /// The time for this command is up: report what there is and close the channel, which makes
    /// the host end the command.
    func timeOut() {
        guard !finished else { return }
        outcome.timedOut = true
        finish()
        context?.close(promise: nil)
    }

    /// The caller no longer wants the result.
    func cancel() {
        guard !finished else {
            context?.close(promise: nil)
            return
        }
        outcome.cancelled = true
        finish()
        context?.close(promise: nil)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        outcome.parser?.finish()
        result.succeed(outcome)
    }

    private func append(_ bytes: ByteBufferView, to storage: inout [UInt8]) {
        let room = Self.maxOutputBytes - storage.count
        guard room > 0 else { return }
        storage.append(contentsOf: bytes.prefix(room))
    }
}
