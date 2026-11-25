import Foundation

extension SSHConnection {
    /// Runs the identity check command for a pid and parses the answer. nil means there is no
    /// such process.
    /// - Throws: `BootstrapError`; `.sshFailure` if `ps` answers with something unreadable.
    public func readIdentity(pid: Int32) async throws -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        let outcome = try await execute(
            IdentityCheck.remoteCommand(pid: pid), pty: nil, parser: nil, timeout: state.timeouts.command,
            stage: .identityCheck)
        let output = String(decoding: outcome.standardOutput, as: UTF8.self)
        if let identity = IdentityCheck.parse(output) { return identity }
        // ps prints nothing and exits with 1 when the pid does not exist.
        if output.allSatisfy(\.isWhitespace), outcome.exitStatus != nil { return nil }
        let errorText = String(decoding: outcome.standardError, as: UTF8.self)
        throw BootstrapError.sshFailure(
            description: "the process list on the host could not be read: "
                + (output + errorText).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The identity check (plan section 4): is the process with this pid the `mosh-server` that
    /// this app started at `expectedStartTime` as the login user?
    public func checkIdentity(pid: Int32, expectedStartTime: Date) async throws -> IdentityVerdict {
        let found = try await readIdentity(pid: pid)
        return IdentityCheck.evaluate(found, loginUser: target.user, expectedStartTime: expectedStartTime)
    }

    /// Stops a `mosh-server`, but only after the identity check has passed on this same
    /// connection. A process that fails the check is never signalled.
    ///
    /// The server gets SIGTERM. With a client attached it then says goodbye to the client first
    /// and may take some seconds to exit; with none it exits at once.
    ///
    /// - Throws: `BootstrapError.identityCheckFailed` when the check does not pass (nothing was
    ///   killed), other `BootstrapError`s when the host could not be asked.
    public func killServer(pid: Int32, expectedStartTime: Date) async throws {
        let verdict = try await checkIdentity(pid: pid, expectedStartTime: expectedStartTime)
        guard case .passed = verdict else {
            if case .failed(let mismatch) = verdict { throw BootstrapError.identityCheckFailed(mismatch) }
            return
        }
        // Plain words that every login shell passes on unchanged.
        let result = try await run("kill -TERM \(pid)")
        guard result.exitStatus == 0 else {
            throw BootstrapError.sshFailure(
                description: "kill failed"
                    + (result.exitStatus.map { " (exit status \($0))" } ?? "") + ": "
                    + (result.output + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Session health (plan section 4): when no authenticated datagram has arrived for 15 s, or on
/// request, the app logs in over SSH and runs the identity check to find out why.
public enum ServerProbe {
    /// What the session record knows about the server.
    public struct SavedSession: Equatable, Sendable {
        /// The numeric IP the session's UDP traffic goes to (the address SSH used at bootstrap).
        public var remoteAddress: String
        public var server: ServerIdentity

        public init(remoteAddress: String, server: ServerIdentity) {
            self.remoteAddress = remoteAddress
            self.server = server
        }
    }

    /// Logs in, runs the identity check, closes the connection and returns the row of the
    /// plan's result table that applies. Never throws: a failed SSH connection is the first row.
    public static func probe(
        target: SSHTarget, privateKey: Data?, saved: SavedSession, knownHosts: KnownHosts,
        interaction: SSHInteraction = .silent, timeouts: SSHTimeouts = SSHTimeouts()
    ) async -> ProbeResult {
        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(
                to: target, privateKey: privateKey, knownHosts: knownHosts, interaction: interaction,
                timeouts: timeouts)
        } catch {
            return .hostUnreachable((error as? BootstrapError) ?? .sshFailure(description: "\(error)"))
        }
        let result = await probe(on: connection, saved: saved)
        await connection.close()
        return result
    }

    /// The same on a connection that is already open.
    public static func probe(on connection: SSHConnection, saved: SavedSession) async -> ProbeResult {
        do {
            let verdict = try await connection.checkIdentity(
                pid: saved.server.pid, expectedStartTime: saved.server.startTime)
            return ProbeResult.from(
                verdict: verdict, savedAddress: saved.remoteAddress, sshAddress: connection.remoteAddress)
        } catch {
            return .hostUnreachable((error as? BootstrapError) ?? .sshFailure(description: "\(error)"))
        }
    }
}
