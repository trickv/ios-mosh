import Foundation

/// Where to log in.
public struct SSHTarget: Equatable, Hashable, Sendable {
    /// Host name or IP address, as the user typed it. Also the name the host key is remembered
    /// under.
    public var host: String
    public var port: Int
    public var user: String

    public init(host: String, port: Int = 22, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }
}

/// Time limits, in seconds. Every step of an SSH operation has one, so a host that stops
/// answering can never hang the app. Time the user spends on a prompt (host key, password) does
/// not count.
public struct SSHTimeouts: Equatable, Sendable {
    /// TCP connect. nil means `ConnectTimeoutPolicy`: 30 s for private and link-local
    /// addresses, 10 s otherwise.
    public var connect: TimeInterval?
    /// From the TCP connection to the host key, and each answer of the host during login.
    public var handshake: TimeInterval
    /// From the `exec` of the server command to `MOSH CONNECT`.
    public var serverStart: TimeInterval
    /// Any other remote command (`ps`, `kill`, the key install).
    public var command: TimeInterval

    public init(
        connect: TimeInterval? = nil, handshake: TimeInterval = 15, serverStart: TimeInterval = 20,
        command: TimeInterval = 10
    ) {
        self.connect = connect
        self.handshake = handshake
        self.serverStart = serverStart
        self.command = command
    }

    public func connectSeconds(forHost host: String) -> TimeInterval {
        connect ?? TimeInterval(ConnectTimeoutPolicy.timeoutSeconds(forHost: host))
    }
}

/// What the user is asked when a password is needed.
public struct PasswordPrompt: Equatable, Sendable {
    public let host: String
    public let user: String
    /// 1 for the first question of this connection, 2 after one wrong password, and so on.
    public let attempt: Int
    /// The device key was offered first and the host rejected it. The app shows the public key
    /// with Copy next to the password field.
    public let keyWasRejected: Bool

    public init(host: String, user: String, attempt: Int, keyWasRejected: Bool) {
        self.host = host
        self.user = user
        self.attempt = attempt
        self.keyWasRejected = keyWasRejected
    }
}

/// The two questions a connection may have for the user. Both closures are called at most a few
/// times per connection, from an unspecified task, and must return: a prompt that is dismissed
/// answers `false` or `nil`.
public struct SSHInteraction: Sendable {
    /// First contact with a host: show the fingerprint; `true` remembers the key and goes on.
    public var confirmHostKey: @Sendable (HostKeyPrompt) async -> Bool
    /// The password for this login, or nil to give up. It is used once and not kept.
    public var password: @Sendable (PasswordPrompt) async -> String?

    public init(
        confirmHostKey: @escaping @Sendable (HostKeyPrompt) async -> Bool,
        password: @escaping @Sendable (PasswordPrompt) async -> String?
    ) {
        self.confirmHostKey = confirmHostKey
        self.password = password
    }

    /// Never asks: unknown hosts are refused and there is no password. For work that must not
    /// put up a prompt, such as the background health probe.
    public static let silent = SSHInteraction(confirmHostKey: { _ in false }, password: { _ in nil })
}

/// How the login succeeded.
public enum LoginMethod: String, Equatable, Sendable, Codable {
    case publicKey
    case password
    /// The host asked for nothing.
    case none
}

/// The result of a remote command.
public struct CommandResult: Equatable, Sendable {
    /// nil if the host closed the channel without reporting a status.
    public var exitStatus: Int?
    /// Standard output.
    public var output: String
    /// Standard error.
    public var errorOutput: String

    public init(exitStatus: Int?, output: String, errorOutput: String) {
        self.exitStatus = exitStatus
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// What a bootstrap hands to the session layer.
public struct BootstrapResult: Equatable, Sendable {
    /// The numeric IP address the SSH connection actually used. The UDP session goes to this
    /// address, not to a second DNS lookup of the name.
    public var remoteAddress: String
    /// The server's UDP port.
    public var udpPort: Int
    /// The session key as printed by the server: 22 base64 characters (16 bytes).
    public var sessionKey: String
    /// The pid of the detached server. nil only if the server did not print its
    /// "detached" line.
    public var serverPID: Int32?
    /// When that process started, as the host's `ps` reports it (UTC). Kept with the pid for the
    /// identity check. nil if it could not be read; such a server is never killed by the app.
    public var serverStartTime: Date?
    public var loginMethod: LoginMethod
    /// Everything the server command printed, for the debug log.
    public var serverOutput: String

    public init(
        remoteAddress: String, udpPort: Int, sessionKey: String, serverPID: Int32?, serverStartTime: Date?,
        loginMethod: LoginMethod, serverOutput: String
    ) {
        self.remoteAddress = remoteAddress
        self.udpPort = udpPort
        self.sessionKey = sessionKey
        self.serverPID = serverPID
        self.serverStartTime = serverStartTime
        self.loginMethod = loginMethod
        self.serverOutput = serverOutput
    }
}

/// A started server as the session record remembers it.
public struct ServerIdentity: Equatable, Sendable, Codable {
    public var pid: Int32
    public var startTime: Date

    public init(pid: Int32, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}
