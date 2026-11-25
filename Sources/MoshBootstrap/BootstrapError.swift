/// The step of the bootstrap an error or a timeout belongs to.
public enum BootstrapStage: String, Equatable, Sendable {
    case connect
    case keyExchange
    case hostKeyCheck
    case authentication
    case serverStart
    case identityCheck
    case command
}

/// Why a bootstrap (or another SSH operation of this module) failed.
///
/// The first nine cases are the rows of the plan's error table (section 4), in its order. The
/// rest are failures the table does not list but a network client cannot avoid. Every case has
/// a `message` for the user and most have a `suggestedFix`.
public enum BootstrapError: Error, Equatable, Sendable {
    // MARK: Rows of the error table

    /// No `MOSH CONNECT`, and exit status 127 or "not found" in the output.
    case serverNotFound(output: String)
    /// "mosh-server needs a UTF-8 native locale to run."
    case localeMissing(locale: String, output: String)
    /// `MOSH CONNECT` was seen, but no UDP reply came within 15 s. Raised by the session layer,
    /// which owns the transport; this module only defines the case and its text.
    case udpBlocked(port: Int)
    /// The host rejected the device key. `passwordLoginOffered` says whether the host would
    /// take a password instead.
    case keyRejected(passwordLoginOffered: Bool)
    /// The host rejected the password.
    case passwordRejected
    /// The host presented a key that differs from the remembered one. Refused.
    case hostKeyChanged(knownFingerprint: String, presentedFingerprint: String)
    /// The host has no host key of a type this app supports (in practice: only RSA).
    case noSharedHostKeyAlgorithm(serverOffers: [String])
    /// The host's list of login methods has neither `publickey` nor `password` (for example
    /// only `keyboard-interactive`, as with 2FA).
    case unsupportedLoginMethod
    /// The connection to a private or link-local address waited for connectivity and then
    /// timed out: Local Network access is off or the alert was not answered in time.
    case localNetworkDenied

    // MARK: Other failures

    /// The user did not accept the key of an unknown host.
    case hostKeyNotTrusted(fingerprint: String)
    /// The host accepts only keys and there is no key to offer.
    case keyRequired
    /// The TCP connection could not be made (refused, no route, name not found).
    case connectFailed(reason: String)
    case connectTimedOut(seconds: Int)
    /// A step did not finish in its time, for example a server command that hangs.
    case timedOut(stage: BootstrapStage)
    /// The server command ended without `MOSH CONNECT` for a reason the output does not name.
    case serverStartFailed(exitStatus: Int?, output: String)
    /// Key exchange or cipher negotiation found nothing in common.
    case noSharedAlgorithm(kind: String, serverOffers: [String])
    /// The connection closed in the middle of a step.
    case connectionLost(stage: BootstrapStage)
    /// SSH protocol trouble that fits nothing above.
    case sshFailure(description: String)
    /// The per-host settings cannot be turned into a command (for example a line break in the
    /// remote command).
    case invalidConfiguration(String)
    /// The known-hosts store cannot be read or written.
    case knownHostsUnavailable(String)
    /// The identity check did not pass, so nothing was killed.
    case identityCheckFailed(IdentityMismatch)
    /// The user cancelled, or the task was cancelled.
    case cancelled

    /// One or two sentences for the user.
    public var message: String {
        switch self {
        case .serverNotFound:
            return "mosh-server was not found on the host. It is not on the PATH of a non-login shell."
        case .localeMissing(let locale, _):
            return "The locale \(locale) is missing on the host."
        case .udpBlocked(let port):
            return "The server started, but no reply arrived on UDP port \(port) within 15 seconds. UDP is blocked."
        case .keyRejected:
            return "The host rejected this device's key."
        case .passwordRejected:
            return "Wrong password."
        case .hostKeyChanged(let known, let presented):
            return "The host key has changed. The connection was refused.\nKnown: \(known)\nPresented: \(presented)"
        case .noSharedHostKeyAlgorithm(let offers):
            let onlyRSA = !offers.isEmpty && offers.allSatisfy { $0.contains("rsa") }
            if onlyRSA || offers.isEmpty {
                return "The host offers only RSA host keys. They are not supported."
            }
            return "The host offers no host key type this app supports (it offers \(offers.joined(separator: ", ")))."
        case .unsupportedLoginMethod:
            return "This host needs a login method the app does not support (for example two-factor login)."
        case .localNetworkDenied:
            return "Local Network access is off or was not answered in time."
        case .hostKeyNotTrusted:
            return "The host key was not accepted, so nothing was sent to the host."
        case .keyRequired:
            return "This host accepts only key login, and no key is set for it."
        case .connectFailed(let reason):
            return "Could not connect to the host: \(reason)"
        case .connectTimedOut(let seconds):
            return "The host did not answer within \(seconds) seconds."
        case .timedOut(let stage):
            switch stage {
            case .serverStart: return "The host did not start mosh-server in time."
            case .keyExchange, .hostKeyCheck: return "The host did not finish the SSH handshake in time."
            case .authentication: return "The host did not answer the login in time."
            case .connect: return "The host did not answer in time."
            case .identityCheck, .command: return "The host did not answer a command in time."
            }
        case .serverStartFailed(let status, _):
            if let status { return "mosh-server did not start (exit status \(status))." }
            return "mosh-server did not start."
        case .noSharedAlgorithm(let kind, _):
            return "The host and this app share no \(kind) algorithm."
        case .connectionLost(let stage):
            return "The SSH connection closed unexpectedly (\(stage.rawValue))."
        case .sshFailure(let description):
            return "SSH error: \(description)"
        case .invalidConfiguration(let reason):
            return "The host settings cannot be used: \(reason)"
        case .knownHostsUnavailable(let reason):
            return "The list of known hosts cannot be used: \(reason)"
        case .identityCheckFailed:
            return "The process on the host is not this session's mosh-server. Nothing was stopped."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// What the user can do about it, nil where there is nothing useful to say.
    public var suggestedFix: String? {
        switch self {
        case .serverNotFound:
            return "Set the server path in the host settings, for example /opt/homebrew/bin/mosh-server. If mosh is not installed on the host, install it."
        case .localeMissing:
            return "Try C.UTF-8 as the locale in the host settings."
        case .udpBlocked:
            return "Set a UDP port range in the host settings that the firewall lets through, or open the firewall for UDP 60000-61000."
        case .keyRejected(let passwordLoginOffered):
            return passwordLoginOffered
                ? "Copy the public key to ~/.ssh/authorized_keys on the host, or log in with the password."
                : "Copy the public key to ~/.ssh/authorized_keys on the host. This host does not take passwords."
        case .passwordRejected:
            return "Check the user name and the password, then try again."
        case .hostKeyChanged:
            return "If the host was reinstalled, remove its known key in the host settings and connect again. If not, someone may be intercepting the connection."
        case .noSharedHostKeyAlgorithm:
            return "Add an Ed25519 host key on the host (ssh-keygen -A, then restart sshd)."
        case .unsupportedLoginMethod:
            return "Allow public key login for this user on the host."
        case .localNetworkDenied:
            return "Settings > Privacy & Security > Local Network, switch it on for this app, then retry."
        case .hostKeyNotTrusted:
            return "Compare the fingerprint with the host's own (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) and connect again."
        case .keyRequired:
            return "Create a key and copy its public key to ~/.ssh/authorized_keys on the host."
        case .connectFailed, .connectTimedOut:
            return "Check the host name, the SSH port and the network."
        case .timedOut(let stage):
            return stage == .serverStart
                ? "Check that the login shell's start files on the host do not wait for input."
                : "Check the network and try again."
        case .serverStartFailed:
            return "Run the same command on the host to see what it prints."
        case .noSharedAlgorithm:
            return "The host's SSH server is too old or too restricted for this app."
        case .connectionLost, .sshFailure:
            return "Try again."
        case .invalidConfiguration:
            return "Correct the host settings."
        case .knownHostsUnavailable:
            return nil
        case .identityCheckFailed:
            return nil
        case .cancelled:
            return nil
        }
    }

    /// The host's or shell's own words, where the error carries them.
    public var output: String? {
        switch self {
        case .serverNotFound(let output), .localeMissing(_, let output), .serverStartFailed(_, let output):
            return output.isEmpty ? nil : output
        default:
            return nil
        }
    }
}

extension BootstrapError: CustomStringConvertible {
    public var description: String {
        var text = message
        if let suggestedFix { text += " " + suggestedFix }
        if let output { text += "\n" + output }
        return text
    }
}

/// What the network layer reported while connecting.
public enum ConnectivityEvent: Equatable, Sendable {
    /// Network.framework could not connect right away and is waiting for conditions to change
    /// (`NIOTSNetworkEvents.WaitingForConnectivity`). Never seen on Linux.
    case waitingForConnectivity(reason: String)
    /// The connect timeout fired.
    case connectTimeout(seconds: Int)
    /// The connect attempt failed with an error.
    case connectFailed(reason: String)
}

/// Login methods of an SSH server, as far as this client can use or recognise them. Mirrors
/// swift-nio-ssh's `NIOSSHAvailableUserAuthenticationMethods`, so that users of this module do
/// not need to import NIOSSH.
public struct LoginMethods: OptionSet, Hashable, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let publicKey = LoginMethods(rawValue: 1 << 0)
    public static let password = LoginMethods(rawValue: 1 << 1)
    public static let hostBased = LoginMethods(rawValue: 1 << 2)
}

/// What kind of SSH-level error ended a connection. Made from the `NIOSSHError` by the SSH
/// layer.
public enum SSHFailureKind: Equatable, Sendable {
    /// `NIOSSHError.keyExchangeNegotiationFailure`: key exchange, host key or cipher lists have
    /// nothing in common.
    case algorithmNegotiation
    /// The connection closed under the protocol (`tcpShutdown` and the like).
    case connectionClosed
    /// Any other protocol error.
    case protocolError
}

/// What a user authentication went through.
public struct AuthenticationTrace: Equatable, Sendable {
    /// The methods the host said it accepts, nil if it never said. swift-nio-ssh drops methods
    /// it does not know (such as `keyboard-interactive`), so a host that wants only those shows
    /// as an empty set.
    public var methodsOffered: LoginMethods?
    /// A key was available to offer.
    public var keyAvailable: Bool
    /// The key was offered and the host rejected it.
    public var keyRejected: Bool
    /// How many passwords the host rejected.
    public var passwordsRejected: Int
    /// The password prompt returned nil.
    public var promptCancelled: Bool

    public init(
        methodsOffered: LoginMethods? = nil, keyAvailable: Bool = false,
        keyRejected: Bool = false, passwordsRejected: Int = 0, promptCancelled: Bool = false
    ) {
        self.methodsOffered = methodsOffered
        self.keyAvailable = keyAvailable
        self.keyRejected = keyRejected
        self.passwordsRejected = passwordsRejected
        self.promptCancelled = promptCancelled
    }
}

/// Everything known about a failed bootstrap. `BootstrapError.classify` turns it into the error
/// to show. It is plain data so that every row of the error table can be tested without a
/// network, including those that only happen on a phone.
public struct BootstrapEvidence: Equatable, Sendable {
    /// The step that was running when it failed.
    public var stage: BootstrapStage
    /// The host field as the user typed it.
    public var host: String
    /// The locale that was asked for (for the locale message).
    public var locale: String
    /// Exit status of the server command, nil if it did not report one.
    public var exitStatus: Int?
    /// Output of the server command.
    public var output: String
    /// The kind of the `NIOSSHError` that ended the connection, if one did.
    public var sshFailure: SSHFailureKind?
    /// Text of the error that ended the connection, whatever its type.
    public var errorDescription: String?
    /// The server's algorithm lists, if its KEXINIT was read.
    public var serverAlgorithms: ServerAlgorithms?
    /// The host key check's refusal, if that is what ended the connection.
    public var hostKeyFailure: KnownHostsError?
    public var authentication: AuthenticationTrace
    public var connectivity: [ConnectivityEvent]
    /// The step's timer fired.
    public var timedOut: Bool
    /// The caller's task was cancelled.
    public var cancelled: Bool

    public init(
        stage: BootstrapStage, host: String = "", locale: String = MoshServerCommand.defaultLocale,
        exitStatus: Int? = nil, output: String = "", sshFailure: SSHFailureKind? = nil,
        errorDescription: String? = nil, serverAlgorithms: ServerAlgorithms? = nil,
        hostKeyFailure: KnownHostsError? = nil, authentication: AuthenticationTrace = AuthenticationTrace(),
        connectivity: [ConnectivityEvent] = [], timedOut: Bool = false, cancelled: Bool = false
    ) {
        self.stage = stage
        self.host = host
        self.locale = locale
        self.exitStatus = exitStatus
        self.output = output
        self.sshFailure = sshFailure
        self.errorDescription = errorDescription
        self.serverAlgorithms = serverAlgorithms
        self.hostKeyFailure = hostKeyFailure
        self.authentication = authentication
        self.connectivity = connectivity
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

extension BootstrapError {
    /// The error for a failed bootstrap, from what was observed. Pure.
    public static func classify(_ evidence: BootstrapEvidence) -> BootstrapError {
        if evidence.cancelled { return .cancelled }

        // The host key check speaks for itself.
        if let failure = evidence.hostKeyFailure {
            switch failure {
            case .hostKeyChanged(_, _, let known, let presented):
                return .hostKeyChanged(knownFingerprint: known, presentedFingerprint: presented)
            case .notTrusted(_, _, let fingerprint):
                return .hostKeyNotTrusted(fingerprint: fingerprint)
            case .unreadable(let reason), .writeFailed(let reason):
                return .knownHostsUnavailable(reason)
            }
        }

        switch evidence.stage {
        case .connect:
            return classifyConnect(evidence)
        case .keyExchange, .hostKeyCheck:
            if let error = classifyNegotiation(evidence) { return error }
        case .authentication:
            if let error = classifyNegotiation(evidence) { return error }
            // A host that stops answering in the middle of a login is a timeout, whatever was
            // rejected before.
            if evidence.timedOut { return .timedOut(stage: .authentication) }
            if let error = classifyAuthentication(evidence.authentication) { return error }
        case .serverStart:
            if let error = classifyServerStart(evidence) { return error }
        case .identityCheck, .command:
            break
        }

        if evidence.timedOut { return .timedOut(stage: evidence.stage) }
        if let kind = evidence.sshFailure {
            if kind == .connectionClosed { return .connectionLost(stage: evidence.stage) }
            return .sshFailure(description: evidence.errorDescription ?? "protocol error")
        }
        if let description = evidence.errorDescription {
            return .sshFailure(description: description)
        }
        return .connectionLost(stage: evidence.stage)
    }

    private static func classifyConnect(_ evidence: BootstrapEvidence) -> BootstrapError {
        var waited = false
        for event in evidence.connectivity {
            switch event {
            case .waitingForConnectivity:
                waited = true
            case .connectTimeout(let seconds):
                // "WaitingForConnectivity event, then connect timeout, on a private or
                // link-local address."
                if waited, ConnectTimeoutPolicy.addressClass(ofHost: evidence.host).isLocalNetwork {
                    return .localNetworkDenied
                }
                return .connectTimedOut(seconds: seconds)
            case .connectFailed(let reason):
                return .connectFailed(reason: reason)
            }
        }
        if evidence.timedOut {
            return .connectTimedOut(seconds: ConnectTimeoutPolicy.timeoutSeconds(forHost: evidence.host))
        }
        return .connectFailed(reason: evidence.errorDescription ?? "the connection could not be made")
    }

    private static func classifyNegotiation(_ evidence: BootstrapEvidence) -> BootstrapError? {
        guard evidence.sshFailure == .algorithmNegotiation else { return nil }
        guard let server = evidence.serverAlgorithms else {
            return .noSharedAlgorithm(kind: "SSH", serverOffers: [])
        }
        switch server.mismatch {
        case .hostKey:
            return .noSharedHostKeyAlgorithm(serverOffers: server.hostKey)
        case .keyExchange:
            return .noSharedAlgorithm(kind: "key exchange", serverOffers: server.keyExchange)
        case .encryption:
            return .noSharedAlgorithm(kind: "encryption", serverOffers: server.encryptionClientToServer)
        case nil:
            return .noSharedAlgorithm(kind: "SSH", serverOffers: [])
        }
    }

    private static func classifyAuthentication(_ trace: AuthenticationTrace) -> BootstrapError? {
        if let methods = trace.methodsOffered {
            if !methods.contains(.publicKey), !methods.contains(.password) {
                return .unsupportedLoginMethod
            }
            if trace.passwordsRejected > 0 { return .passwordRejected }
            if trace.keyRejected { return .keyRejected(passwordLoginOffered: methods.contains(.password)) }
            if !trace.keyAvailable, !methods.contains(.password) { return .keyRequired }
        } else {
            if trace.passwordsRejected > 0 { return .passwordRejected }
            if trace.keyRejected { return .keyRejected(passwordLoginOffered: false) }
        }
        if trace.promptCancelled { return .cancelled }
        return nil
    }

    private static func classifyServerStart(_ evidence: BootstrapEvidence) -> BootstrapError? {
        // The locale text is checked before the exit status and before "not found": mosh-server
        // runs `locale` after the message, which prints "No such file or directory".
        let failure = ConnectLineParser.recognizeFailure(in: evidence.output)
        if failure == .localeMissing {
            return .localeMissing(locale: evidence.locale, output: evidence.output)
        }
        if evidence.exitStatus == 127 || failure == .serverNotFound {
            return .serverNotFound(output: evidence.output)
        }
        if evidence.timedOut { return .timedOut(stage: .serverStart) }
        if evidence.exitStatus != nil || !evidence.output.isEmpty {
            return .serverStartFailed(exitStatus: evidence.exitStatus, output: evidence.output)
        }
        return nil
    }
}
