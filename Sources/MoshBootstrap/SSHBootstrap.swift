import Foundation
import MoshKeys

extension SSHConnection {
    /// Starts `mosh-server` on the host and reads what the session needs (plan section 4, steps
    /// 3 to 5): requests a pty of the terminal's size, runs the server command, finds
    /// `MOSH CONNECT <port> <key>` and `[mosh-server detached, pid = N]` in the output, and then
    /// reads the new process's start time on a second channel with the identity check command.
    ///
    /// The connection stays open; the caller closes it.
    ///
    /// - Throws: `BootstrapError`: `.serverNotFound`, `.localeMissing`,
    ///   `.timedOut(stage: .serverStart)` for a command that hangs, `.serverStartFailed` for
    ///   anything else without `MOSH CONNECT`, `.invalidConfiguration` for settings that cannot
    ///   be sent.
    public func startMoshServer(
        _ command: MoshServerCommand, columns: Int, rows: Int, term: String = "xterm-256color"
    ) async throws -> BootstrapResult {
        let line: String
        do {
            line = try command.commandLine()
        } catch let error as MoshServerCommand.CommandError {
            switch error {
            case .unrepresentable(let field):
                throw BootstrapError.invalidConfiguration("\(field) contains a line break or a NUL character")
            case .invalidLocale(let locale):
                throw BootstrapError.invalidConfiguration("\"\(locale)\" is not a locale name")
            }
        }
        let pty = PseudoTerminal(
            term: term, columns: min(max(columns, 1), 10_000), rows: min(max(rows, 1), 10_000))
        let outcome = try await execute(
            line, pty: pty, parser: ConnectLineParser(), timeout: state.timeouts.serverStart, stage: .serverStart)
        let parser = outcome.parser ?? ConnectLineParser()

        guard let connect = parser.connect else {
            var evidence = state.evidence(stage: .serverStart, timedOut: outcome.timedOut, error: outcome.error)
            evidence.locale = command.locale
            evidence.exitStatus = outcome.exitStatus
            evidence.output = parser.text
            throw BootstrapError.classify(evidence)
        }

        // Step 5: the start time, kept with the pid for the identity check. A server whose start
        // time cannot be read still works; it just can never be probed or killed by pid.
        var startTime: Date?
        if let pid = parser.serverPID {
            do {
                if let identity = try await readIdentity(pid: pid),
                    IdentityCheck.userMatches(psUser: identity.user, loginUser: target.user),
                    identity.commandBasename == IdentityCheck.serverName
                {
                    startTime = identity.startTime
                }
            } catch BootstrapError.cancelled {
                throw BootstrapError.cancelled
            } catch {
                startTime = nil
            }
        }
        return BootstrapResult(
            remoteAddress: remoteAddress, udpPort: connect.port, sessionKey: connect.key,
            serverPID: parser.serverPID, serverStartTime: startTime, loginMethod: loginMethod,
            serverOutput: parser.text)
    }

    /// "Install my key on this host": appends the public key line to `~/.ssh/authorized_keys`
    /// over this connection. See `AuthorizedKeys` for what exactly the host is asked to do.
    @discardableResult
    public func installAuthorizedKey(_ key: OpenSSHPublicKey) async throws -> AuthorizedKeys.Outcome {
        guard ShellQuote.isRepresentable(key.line) else {
            throw BootstrapError.invalidConfiguration("the key comment contains a line break or a NUL character")
        }
        let result = try await run(AuthorizedKeys.installCommand(for: key))
        do {
            return try AuthorizedKeys.outcome(exitStatus: result.exitStatus, output: result.output)
        } catch {
            let text = (result.output + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BootstrapError.sshFailure(
                description: "the key could not be added to ~/.ssh/authorized_keys"
                    + (result.exitStatus.map { " (exit status \($0))" } ?? "") + (text.isEmpty ? "" : ": " + text))
        }
    }
}

/// The whole bootstrap in one call: connect, check the host key, log in, start the server, read
/// its identity, close.
public enum SSHBootstrap {
    public struct Request: Sendable {
        public var target: SSHTarget
        /// The device's 32-byte Ed25519 private key; nil for password login only.
        public var privateKey: Data?
        public var command: MoshServerCommand
        /// The terminal's size, for the pty and so for the server's first window size.
        public var columns: Int
        public var rows: Int
        public var timeouts: SSHTimeouts
        /// A server left over from a session that could not be resumed (plan section 3,
        /// "Fallback"). It is killed on the same connection, but only if the identity check
        /// passes; otherwise nothing is killed.
        public var replacing: ServerIdentity?

        public init(
            target: SSHTarget, privateKey: Data?, command: MoshServerCommand = MoshServerCommand(),
            columns: Int = 80, rows: Int = 24, timeouts: SSHTimeouts = SSHTimeouts(),
            replacing: ServerIdentity? = nil
        ) {
            self.target = target
            self.privateKey = privateKey
            self.command = command
            self.columns = columns
            self.rows = rows
            self.timeouts = timeouts
            self.replacing = replacing
        }
    }

    /// What happened to the server named in `Request.replacing`.
    public enum ReplacedServer: Equatable, Sendable {
        /// The identity check passed and the server was told to stop.
        case killed
        /// The identity check did not pass; nothing was killed.
        case notKilled(IdentityMismatch)
        /// The check or the kill could not be carried out.
        case failed(BootstrapError)
    }

    public struct Outcome: Equatable, Sendable {
        public var result: BootstrapResult
        /// nil when the request named no server to replace.
        public var replaced: ReplacedServer?
    }

    /// Runs the bootstrap and closes the SSH connection, whatever the outcome.
    /// - Throws: `BootstrapError`.
    public static func run(
        _ request: Request, knownHosts: KnownHosts, interaction: SSHInteraction
    ) async throws -> BootstrapResult {
        try await runReplacing(request, knownHosts: knownHosts, interaction: interaction).result
    }

    /// The same, and also reports what happened to the server that was to be replaced.
    public static func runReplacing(
        _ request: Request, knownHosts: KnownHosts, interaction: SSHInteraction
    ) async throws -> Outcome {
        // Fail on unusable settings before any network traffic.
        do {
            _ = try request.command.commandLine()
        } catch {
            throw BootstrapError.invalidConfiguration("the server path, locale or remote command cannot be sent: \(error)")
        }
        let connection = try await SSHConnection.connect(
            to: request.target, privateKey: request.privateKey, knownHosts: knownHosts, interaction: interaction,
            timeouts: request.timeouts)
        do {
            // The old server goes first: with a single UDP port configured it would otherwise
            // still hold the port the new one needs.
            var replaced: ReplacedServer?
            if let old = request.replacing {
                do {
                    try await connection.killServer(pid: old.pid, expectedStartTime: old.startTime)
                    replaced = .killed
                } catch BootstrapError.cancelled {
                    throw BootstrapError.cancelled
                } catch BootstrapError.identityCheckFailed(let mismatch) {
                    replaced = .notKilled(mismatch)
                } catch let error as BootstrapError {
                    replaced = .failed(error)
                }
            }
            let result = try await connection.startMoshServer(
                request.command, columns: request.columns, rows: request.rows)
            await connection.close()
            return Outcome(result: result, replaced: replaced)
        } catch {
            await connection.close()
            throw error
        }
    }
}
