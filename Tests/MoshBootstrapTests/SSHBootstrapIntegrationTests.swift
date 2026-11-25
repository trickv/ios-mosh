import Foundation
import MoshBootstrap
import MoshKeys
import MoshTestSupport
import XCTest

/// MoshBootstrap against real OpenSSH servers and the real mosh-server.
/// Run with `scripts/itest.sh bootstrap`; skipped otherwise.
final class SSHBootstrapIntegrationTests: XCTestCase {
    private var environment: SSHTestEnvironment!
    private var scratch: ScratchDirectory!
    private var knownHosts: KnownHosts!
    private var keyStore: FileKeyStore!
    /// Connections a test opened; closed in tearDown.
    private var connections: [SSHConnection] = []

    override func setUpWithError() throws {
        environment = try SSHTestEnvironment.load()
        scratch = try ScratchDirectory(label: "sshitest")
        knownHosts = KnownHosts(fileURL: scratch.file("known_hosts.json"))
        keyStore = FileKeyStore(directory: scratch.file("keys"))
        connections = []
    }

    override func tearDown() async throws {
        for connection in connections { await connection.close() }
        connections = []
        scratch?.remove()
    }

    // MARK: - Helpers

    private var fastTimeouts: SSHTimeouts { SSHTimeouts(connect: 5, handshake: 10, serverStart: 15, command: 10) }

    /// Opens a connection and registers it for closing.
    private func connect(
        _ server: String = "normal", key: Data? = nil, script: ScriptedInteraction, timeouts: SSHTimeouts? = nil,
        maxPasswordAttempts: Int = 3
    ) async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(
            to: try environment.target(server), privateKey: key, knownHosts: knownHosts,
            interaction: script.interaction, timeouts: timeouts ?? fastTimeouts,
            maxPasswordAttempts: maxPasswordAttempts)
        connections.append(connection)
        return connection
    }

    /// A connection logged in with the test user's password.
    private func passwordConnection(_ server: String = "normal") async throws -> SSHConnection {
        try await connect(server, script: ScriptedInteraction(passwords: [environment.password]))
    }

    /// A new key in the FileKeyStore.
    private func newKey(_ name: String = "device") throws -> (stored: StoredKey, privateKey: Data) {
        let stored = try keyStore.generate(name: name, comment: "ios-mosh@itest \(name)")
        return (stored, try keyStore.loadPrivateKey(name: name))
    }

    /// Stops a server this test started, without going through the code under test.
    private func stopServer(pid: Int32?, on connection: SSHConnection) async {
        guard let pid else { return }
        _ = try? await connection.run("kill -TERM \(pid)")
    }

    private func assertServerAlive(_ result: BootstrapResult, file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(result.serverPID, "no pid", file: file, line: line)
        XCTAssertEqual(processName(pid: pid), "mosh-server", "pid \(pid)", file: file, line: line)
    }

    // MARK: - Login and bootstrap

    func testPasswordLoginBootstrapsAServer() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        let connection = try await connect(script: script)
        XCTAssertEqual(connection.loginMethod, .password)
        XCTAssertEqual(connection.remoteAddress, "127.0.0.1")
        XCTAssertEqual(script.passwordAsked, [PasswordPrompt(host: "127.0.0.1", user: environment.user, attempt: 1, keyWasRejected: false)])
        XCTAssertEqual(connection.serverAlgorithms?.identification.hasPrefix("SSH-2.0-OpenSSH"), true)

        let result = try await connection.startMoshServer(MoshServerCommand(), columns: 100, rows: 30)
        // The default range of mosh-server.
        XCTAssertTrue((60001...60999).contains(result.udpPort), "\(result.udpPort)")
        XCTAssertEqual(result.sessionKey.count, 22)
        XCTAssertNotNil(Data(base64Encoded: result.sessionKey + "=="), "the key is base64 for 16 bytes")
        XCTAssertEqual(Data(base64Encoded: result.sessionKey + "==")?.count, 16)
        XCTAssertEqual(result.remoteAddress, "127.0.0.1")
        XCTAssertEqual(result.loginMethod, .password)
        XCTAssertTrue(result.serverOutput.contains("MOSH CONNECT \(result.udpPort) \(result.sessionKey)"))
        try assertServerAlive(result)

        // The start time was read on a second channel and is "now" on the host's clock.
        let started = try XCTUnwrap(result.serverStartTime)
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 10)

        // The server listens on the UDP port it named.
        let sockets = try ToolRunner.check("ss", ["-H", "-u", "-l", "-n"])
        XCTAssertTrue(sockets.contains("127.0.0.1:\(result.udpPort) "), sockets)

        await stopServer(pid: result.serverPID, on: connection)
    }

    func testKeyLoginWithAFileKeyStoreKey() async throws {
        let key = try newKey()
        // The authorized_keys line is the one MoshKeys produced, installed over a password login.
        let setup = try await passwordConnection()
        await XCTAssertEqualAsync(try await setup.installAuthorizedKey(key.stored.publicKey), .added)
        await setup.close()

        // The fingerprint MoshKeys shows is the one ssh-keygen computes for the same key.
        XCTAssertEqual(key.stored.fingerprint, try sshKeygenFingerprint(ofFile: keyStore.directory.path + "/device.pub"))

        // "nopassword" takes keys only, so this login can only have used the key.
        let script = ScriptedInteraction()
        let connection = try await connect("nopassword", key: key.privateKey, script: script)
        XCTAssertEqual(connection.loginMethod, .publicKey)
        XCTAssertEqual(script.passwordAsked, [])

        let result = try await connection.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        XCTAssertEqual(result.loginMethod, .publicKey)
        try assertServerAlive(result)
        await stopServer(pid: result.serverPID, on: connection)

        // A key that sshd has in authorized_keys shows the same fingerprint in its log line; ask
        // OpenSSH itself which keys the file holds.
        let listed = try await connection.run("ssh-keygen -lf .ssh/authorized_keys")
        XCTAssertTrue(listed.output.contains(key.stored.fingerprint), listed.output)
    }

    func testOneCallBootstrap() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        let request = SSHBootstrap.Request(
            target: try environment.target("normal"), privateKey: nil, columns: 90, rows: 25, timeouts: fastTimeouts)
        let result = try await SSHBootstrap.run(request, knownHosts: knownHosts, interaction: script.interaction)
        try assertServerAlive(result)
        XCTAssertNotNil(result.serverStartTime)

        // A second bootstrap that replaces the first: the old server is killed on the same
        // connection because its identity checks out.
        let old = ServerIdentity(pid: try XCTUnwrap(result.serverPID), startTime: try XCTUnwrap(result.serverStartTime))
        var second = request
        second.replacing = old
        let script2 = ScriptedInteraction(passwords: [environment.password])
        let outcome = try await SSHBootstrap.runReplacing(second, knownHosts: knownHosts, interaction: script2.interaction)
        XCTAssertEqual(outcome.replaced, .killed)
        XCTAssertNotEqual(outcome.result.serverPID, old.pid)
        try assertServerAlive(outcome.result)
        let gone = await waitUntil(timeout: 5) { processName(pid: old.pid) == nil }
        XCTAssertTrue(gone, "the replaced server still runs")

        // Replacing with a wrong start time kills nothing.
        var third = request
        third.replacing = ServerIdentity(
            pid: try XCTUnwrap(outcome.result.serverPID),
            startTime: try XCTUnwrap(outcome.result.serverStartTime).addingTimeInterval(-3600))
        let script3 = ScriptedInteraction(passwords: [environment.password])
        let outcome3 = try await SSHBootstrap.runReplacing(third, knownHosts: knownHosts, interaction: script3.interaction)
        guard case .notKilled(.startTimeDiffers) = outcome3.replaced else {
            return XCTFail("\(String(describing: outcome3.replaced))")
        }
        try assertServerAlive(outcome.result)

        let cleanup = try await passwordConnection()
        await stopServer(pid: outcome.result.serverPID, on: cleanup)
        await stopServer(pid: outcome3.result.serverPID, on: cleanup)
    }

    // MARK: - Host keys

    func testFirstContactShowsTheHostFingerprintAndTheSecondConnectIsSilent() async throws {
        let expected = try environment.hostKeyFingerprint("normal")
        let first = ScriptedInteraction(passwords: [environment.password])
        let connection = try await connect(script: first)
        XCTAssertEqual(
            first.hostKeyAsked,
            [HostKeyPrompt(host: "127.0.0.1", port: try environment.server("normal").port, keyType: "ssh-ed25519", fingerprint: expected)])
        await connection.close()

        let stored = try XCTUnwrap(try knownHosts.lookup(host: "127.0.0.1", port: try environment.server("normal").port))
        XCTAssertEqual(stored.fingerprint, expected)

        // A new store object on the same file: the second connect asks nothing.
        knownHosts = KnownHosts(fileURL: scratch.file("known_hosts.json"))
        let second = ScriptedInteraction(trustHostKey: false, passwords: [environment.password])
        let again = try await connect(script: second)
        XCTAssertEqual(second.hostKeyAsked, [])
        XCTAssertEqual(again.loginMethod, .password)
    }

    func testDecliningAnUnknownHostKeySendsNothing() async throws {
        let script = ScriptedInteraction(trustHostKey: false, passwords: [environment.password])
        let fingerprint = try environment.hostKeyFingerprint("normal")
        await assertThrowsBootstrapError(.hostKeyNotTrusted(fingerprint: fingerprint)) {
            try await self.connect(script: script)
        }
        XCTAssertEqual(script.hostKeyAsked.count, 1)
        XCTAssertEqual(script.passwordAsked, [], "no login is attempted with an untrusted host")
        XCTAssertEqual(try knownHosts.entries(), [])
    }

    func testChangedHostKeyIsRefused() async throws {
        // The store remembers, for the address of the "nopassword" server, the key of the
        // "normal" server: from the client's side the host now presents a different key.
        let rememberedLine = try String(contentsOfFile: try environment.server("normal").hostKeyFile, encoding: .utf8)
        let remembered = try OpenSSHPublicKey(line: rememberedLine)
        let port = try environment.server("nopassword").port
        try knownHosts.trust(host: "127.0.0.1", port: port, key: remembered)

        let key = try newKey()
        let script = ScriptedInteraction(passwords: [environment.password])
        await assertThrowsBootstrapError(
            .hostKeyChanged(
                knownFingerprint: try environment.hostKeyFingerprint("normal"),
                presentedFingerprint: try environment.hostKeyFingerprint("nopassword"))
        ) {
            try await self.connect("nopassword", key: key.privateKey, script: script)
        }
        XCTAssertEqual(script.hostKeyAsked, [], "a changed key is refused without asking")
        XCTAssertEqual(script.passwordAsked, [])
        // The remembered key is untouched.
        XCTAssertEqual(try knownHosts.check(host: "127.0.0.1", port: port, key: remembered), .trusted)
    }

    func testRSAOnlyHostGivesNoSharedHostKeyAlgorithm() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        let error = await bootstrapError { try await self.connect("rsaonly", script: script) }
        guard case .noSharedHostKeyAlgorithm(let offers) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(offers.isEmpty)
        XCTAssertTrue(offers.allSatisfy { $0.contains("rsa") }, "\(offers)")
        XCTAssertEqual(error?.message, "The host offers only RSA host keys. They are not supported.")
        XCTAssertEqual(script.hostKeyAsked, [])
        XCTAssertEqual(script.passwordAsked, [])
    }

    // MARK: - Login failures

    func testWrongPassword() async throws {
        let script = ScriptedInteraction(passwords: ["wrong-1", "wrong-2", "wrong-3", "wrong-4"])
        await assertThrowsBootstrapError(.passwordRejected) {
            try await self.connect(script: script)
        }
        // Three tries, then the connection gives up.
        XCTAssertEqual(script.passwordAsked.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(script.passwordAsked.map(\.keyWasRejected), [false, false, false])
    }

    func testWrongPasswordThenTheRightOne() async throws {
        let script = ScriptedInteraction(passwords: ["wrong", environment.password])
        let connection = try await connect(script: script)
        XCTAssertEqual(connection.loginMethod, .password)
        XCTAssertEqual(script.passwordAsked.map(\.attempt), [1, 2])
    }

    func testGivingUpAfterAWrongPasswordIsAWrongPassword() async throws {
        let script = ScriptedInteraction(passwords: ["wrong", nil])
        await assertThrowsBootstrapError(.passwordRejected) {
            try await self.connect(script: script)
        }
        XCTAssertEqual(script.passwordAsked.count, 2)
    }

    func testCancellingTheFirstPasswordPrompt() async throws {
        let script = ScriptedInteraction(passwords: [nil])
        await assertThrowsBootstrapError(.cancelled) {
            try await self.connect(script: script)
        }
    }

    func testKeyRejectedThenPasswordFallback() async throws {
        let key = try newKey("unknown-to-the-host")
        let script = ScriptedInteraction(passwords: [environment.password])
        let connection = try await connect(key: key.privateKey, script: script)
        XCTAssertEqual(connection.loginMethod, .password)
        // The prompt says that the key was tried and rejected.
        XCTAssertEqual(
            script.passwordAsked,
            [PasswordPrompt(host: "127.0.0.1", user: environment.user, attempt: 1, keyWasRejected: true)])
        let result = try await connection.run("echo fallback-ok")
        XCTAssertEqual(result.output, "fallback-ok\n")
    }

    func testKeyRejectedAndPasswordPromptCancelled() async throws {
        let key = try newKey("unknown-to-the-host")
        let script = ScriptedInteraction(passwords: [nil])
        await assertThrowsBootstrapError(.keyRejected(passwordLoginOffered: true)) {
            try await self.connect(key: key.privateKey, script: script)
        }
        XCTAssertEqual(script.passwordAsked.count, 1)
    }

    func testKeyRejectedByAHostWithoutPasswordLogin() async throws {
        let key = try newKey("unknown-to-the-host")
        let script = ScriptedInteraction(passwords: [environment.password])
        await assertThrowsBootstrapError(.keyRejected(passwordLoginOffered: false)) {
            try await self.connect("nopassword", key: key.privateKey, script: script)
        }
        XCTAssertEqual(script.passwordAsked, [], "the host does not take passwords, so none is asked for")
    }

    func testKeyOnlyHostWithoutAKey() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        await assertThrowsBootstrapError(.keyRequired) {
            try await self.connect("nopassword", script: script)
        }
        XCTAssertEqual(script.passwordAsked, [])
    }

    func testKeyboardInteractiveOnlyHostIsAnUnsupportedLoginMethod() async throws {
        let key = try newKey()
        let script = ScriptedInteraction(passwords: [environment.password])
        await assertThrowsBootstrapError(.unsupportedLoginMethod) {
            try await self.connect("kbdonly", key: key.privateKey, script: script)
        }
        XCTAssertEqual(script.passwordAsked, [])
        XCTAssertEqual(script.hostKeyAsked.count, 1)
    }

    func testConnectionRefused() async throws {
        let script = ScriptedInteraction()
        let target = SSHTarget(host: "127.0.0.1", port: 22299, user: environment.user)
        await assertThrowsBootstrapError(.connectFailed(reason: "connection refused")) {
            try await SSHConnection.connect(
                to: target, privateKey: nil, knownHosts: self.knownHosts, interaction: script.interaction,
                timeouts: self.fastTimeouts)
        }
    }

    // MARK: - Server start

    func testServerNotFound() async throws {
        let connection = try await passwordConnection()
        // A prefix that points nowhere.
        let error = await bootstrapError {
            try await connection.startMoshServer(MoshServerCommand(serverPath: "/nonexistent/prefix"), columns: 80, rows: 24)
        }
        guard case .serverNotFound(let output) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(output.contains("/nonexistent/prefix/mosh-server"), output)
        XCTAssertTrue(error?.message.contains("not on the PATH") == true)

        // A program name that is not on the PATH.
        let error2 = await bootstrapError {
            try await connection.startMoshServer(MoshServerCommand(serverPath: "mosh-server-9.9"), columns: 80, rows: 24)
        }
        guard case .serverNotFound = error2 else { return XCTFail("\(String(describing: error2))") }

        // The connection survives a failed start.
        let result = try await connection.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        try assertServerAlive(result)
        await stopServer(pid: result.serverPID, on: connection)
    }

    func testServerFoundThroughAnExplicitPathAndPrefix() async throws {
        let connection = try await passwordConnection()
        for path in ["/usr/bin/mosh-server", "/usr/bin", "/usr/bin/"] {
            let result = try await connection.startMoshServer(MoshServerCommand(serverPath: path), columns: 80, rows: 24)
            try assertServerAlive(result)
            await stopServer(pid: result.serverPID, on: connection)
        }
    }

    func testMissingLocale() async throws {
        let connection = try await passwordConnection()
        let error = await bootstrapError {
            try await connection.startMoshServer(MoshServerCommand(locale: "xx_XX.UTF-8"), columns: 80, rows: 24)
        }
        guard case .localeMissing(let locale, let output) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(locale, "xx_XX.UTF-8")
        XCTAssertTrue(output.contains("needs a UTF-8 native locale"), output)
        XCTAssertEqual(error?.suggestedFix?.contains("C.UTF-8"), true)

        // The suggested fix works on this host.
        let result = try await connection.startMoshServer(MoshServerCommand(locale: "C.UTF-8"), columns: 80, rows: 24)
        try assertServerAlive(result)
        await stopServer(pid: result.serverPID, on: connection)
    }

    func testPortRangeIsHonoured() async throws {
        let connection = try await passwordConnection()
        let range = try XCTUnwrap(UDPPortRange("61500:61503"))
        var started: [BootstrapResult] = []
        for _ in 0..<3 {
            let result = try await connection.startMoshServer(MoshServerCommand(portRange: range), columns: 80, rows: 24)
            XCTAssertTrue(range.contains(result.udpPort), "\(result.udpPort)")
            started.append(result)
        }
        XCTAssertEqual(Set(started.map(\.udpPort)).count, 3, "three servers, three ports of the range")

        let single = try await connection.startMoshServer(
            MoshServerCommand(portRange: UDPPortRange(port: 61777)), columns: 80, rows: 24)
        XCTAssertEqual(single.udpPort, 61777)
        for result in started + [single] { await stopServer(pid: result.serverPID, on: connection) }
    }

    func testHungServerCommandHitsTheTimeout() async throws {
        let timeouts = SSHTimeouts(connect: 5, handshake: 10, serverStart: 2, command: 10)
        let connection = try await connect(script: ScriptedInteraction(passwords: [environment.password]), timeouts: timeouts)
        let begin = Date()
        await assertThrowsBootstrapError(.timedOut(stage: .serverStart)) {
            try await connection.startMoshServer(
                MoshServerCommand(serverPath: self.environment.hangingServer), columns: 80, rows: 24)
        }
        let elapsed = Date().timeIntervalSince(begin)
        XCTAssertGreaterThan(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 6)

        // The hung command (the stand-in server is "exec sleep 600") was ended on the host when
        // its channel closed: it had a pty, so it got SIGHUP. The connection is still usable.
        let cleared = try await waitUntil(timeout: 5) {
            // "60[0]" so that the pattern does not match the shell that runs pgrep itself.
            try await connection.run("pgrep -u \(self.environment.user) -f 'sleep 60[0]'").exitStatus == 1
        }
        XCTAssertTrue(cleared, "the hung command still runs on the host")
    }

    func testHungCommandHitsTheCommandTimeout() async throws {
        let timeouts = SSHTimeouts(connect: 5, handshake: 10, serverStart: 15, command: 10)
        let connection = try await connect(script: ScriptedInteraction(passwords: [environment.password]), timeouts: timeouts)
        let begin = Date()
        await assertThrowsBootstrapError(.timedOut(stage: .command)) {
            try await connection.run("sleep 300", timeout: 1.5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(begin), 5)
        await XCTAssertEqualAsync(try await connection.run("echo still-here").output, "still-here\n")
        // A command without a pty is not signalled when its channel closes (sshd only closes its
        // pipes), so this one is still there. Remove it.
        _ = try await connection.run("pkill -u \(environment.user) -f 'sleep 30[0]'")
    }

    func testCancellationEndsAHungBootstrap() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        var command = MoshServerCommand()
        command.serverPath = environment.hangingServer
        let request = SSHBootstrap.Request(
            target: try environment.target("normal"), privateKey: nil, command: command,
            timeouts: SSHTimeouts(connect: 5, handshake: 10, serverStart: 60, command: 10))
        let knownHosts = self.knownHosts!
        let task = Task { try await SSHBootstrap.run(request, knownHosts: knownHosts, interaction: script.interaction) }
        // Let it log in and start the command that never answers.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let begin = Date()
        task.cancel()
        let outcome = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(begin), 4, "cancellation must not wait for the timeout")
        switch outcome {
        case .success(let result): XCTFail("unexpected success: \(result)")
        case .failure(let error): XCTAssertEqual(error as? BootstrapError, .cancelled)
        }
    }

    func testInvalidSettingsAreRefusedBeforeConnecting() async throws {
        let script = ScriptedInteraction(passwords: [environment.password])
        var command = MoshServerCommand()
        command.remoteCommand = "echo one\necho two"
        let request = SSHBootstrap.Request(target: try environment.target("normal"), privateKey: nil, command: command)
        let error = await bootstrapError {
            try await SSHBootstrap.run(request, knownHosts: self.knownHosts, interaction: script.interaction)
        }
        guard case .invalidConfiguration = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(script.hostKeyAsked, [], "nothing was sent")
    }

    // MARK: - Remote command

    /// The real mosh-client on a pty made by script(1). The pty of script has no size when the
    /// standard input is not a terminal, and mosh-client aborts on a 0x0 screen, hence stty.
    private func startMoshClient(for result: BootstrapResult) throws -> BackgroundProcess {
        try BackgroundProcess(
            "script",
            ["-qfc", "stty rows 24 cols 80; exec mosh-client 127.0.0.1 \(result.udpPort)", "/dev/null"],
            environment: ["MOSH_KEY": result.sessionKey, "TERM": "xterm-256color"])
    }

    func testRemoteCommandAttachesToTmux() async throws {
        guard ToolRunner.which("mosh-client") != nil, ToolRunner.which("script") != nil else {
            throw XCTSkip("mosh-client and script are needed to send the first datagram")
        }
        let connection = try await passwordConnection()
        _ = try await connection.run("tmux kill-server")
        await XCTAssertNotEqualAsync(try await connection.run("tmux has-session -t main").exitStatus, 0, "no tmux session yet")

        let result = try await connection.startMoshServer(
            MoshServerCommand(remoteCommand: "tmux new -A -s main"), columns: 80, rows: 24)
        try assertServerAlive(result)

        // mosh-server holds the command back until the first datagram of a client arrives
        // (mosh-server.cc, "child_released"). The real mosh-client, on a pty made by script(1),
        // is that client.
        let client = try startMoshClient(for: result)
        defer { client.stop() }

        let attached = try await waitUntil(timeout: 15, interval: 0.25) {
            try await connection.run("tmux has-session -t main").exitStatus == 0
        }
        XCTAssertTrue(attached, "no tmux session named main after the client connected")
        let sessions = try await connection.run("tmux list-sessions -F '#{session_name} #{session_attached}'")
        XCTAssertEqual(sessions.output, "main 1\n", "the mosh session is attached to it")

        // The tmux client runs inside this mosh-server: its parent chain leads to the pid we got.
        let clients = try await connection.run("tmux list-clients -F '#{client_pid}'")
        let clientPID = try XCTUnwrap(Int32(clients.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let ancestry = try await connection.run("sh -c 'p=\(clientPID); while [ \"$p\" -gt 1 ]; do echo $p; p=$(ps -o ppid= -p $p | tr -d \" \"); done'")
        XCTAssertTrue(
            ancestry.output.split(separator: "\n").contains(Substring(String(try XCTUnwrap(result.serverPID)))),
            ancestry.output)

        // With tmux gone the command of the session has ended, and so does the server (it says
        // goodbye to the client first, which is why the client is still running here).
        _ = try await connection.run("tmux kill-server")
        let ended = await waitUntil(timeout: 20) { processName(pid: result.serverPID ?? 0) == nil }
        XCTAssertTrue(ended, "mosh-server should exit when its command ends")
        client.stop()
    }

    func testRemoteCommandThroughPlainSh() async throws {
        guard ToolRunner.which("mosh-client") != nil, ToolRunner.which("script") != nil else {
            throw XCTSkip("mosh-client and script are needed to send the first datagram")
        }
        let connection = try await passwordConnection()
        let marker = "marker-\(UUID().uuidString)"
        // Shell syntax in the command is interpreted once, inside the session.
        let command = MoshServerCommand(
            remoteCommand: "echo \"$((6*7)) $(id -un)\" > /tmp/\(marker); sleep 30", remoteCommandShell: .sh)
        let result = try await connection.startMoshServer(command, columns: 80, rows: 24)
        await XCTAssertNotEqualAsync(try await connection.run("test -e /tmp/\(marker)").exitStatus, 0, "held back until a client connects")

        let client = try startMoshClient(for: result)
        defer { client.stop() }
        let written = try await waitUntil(timeout: 15, interval: 0.25) {
            try await connection.run("cat /tmp/\(marker)").output == "42 \(self.environment.user)\n"
        }
        XCTAssertTrue(written)
        client.stop()
        _ = try await connection.run("rm -f /tmp/\(marker)")
        await stopServer(pid: result.serverPID, on: connection)
    }

    // MARK: - Install my key

    func testInstallMyKeyThenKeyLogin() async throws {
        let key = try newKey()
        let connection = try await passwordConnection()
        // Start without ~/.ssh, so that the install has to create everything.
        await XCTAssertEqualAsync(try await connection.run("rm -rf .ssh").exitStatus, 0)

        // Key login does not work yet.
        await assertThrowsBootstrapError(.keyRejected(passwordLoginOffered: false)) {
            try await self.connect("nopassword", key: key.privateKey, script: ScriptedInteraction())
        }

        await XCTAssertEqualAsync(try await connection.installAuthorizedKey(key.stored.publicKey), .added)
        await XCTAssertEqualAsync(try await connection.run("stat -c '%a %U' .ssh").output, "700 \(environment.user)\n")
        await XCTAssertEqualAsync(try await connection.run("stat -c '%a %U' .ssh/authorized_keys").output, "600 \(environment.user)\n")
        await XCTAssertEqualAsync(try await connection.run("cat .ssh/authorized_keys").output, key.stored.authorizedKeysLine + "\n")

        // Installing twice adds one line.
        await XCTAssertEqualAsync(try await connection.installAuthorizedKey(key.stored.publicKey), .alreadyPresent)
        await XCTAssertEqualAsync(try await connection.run("cat .ssh/authorized_keys").output, key.stored.authorizedKeysLine + "\n")

        // Now the key logs in, on the server that takes nothing else.
        let withKey = try await connect("nopassword", key: key.privateKey, script: ScriptedInteraction())
        XCTAssertEqual(withKey.loginMethod, .publicKey)
        await XCTAssertEqualAsync(try await withKey.run("id -un").output, environment.user + "\n")

        // A second key is appended; the first line stays as it was.
        let other = try newKey("second")
        await XCTAssertEqualAsync(try await withKey.installAuthorizedKey(other.stored.publicKey), .added)
        await XCTAssertEqualAsync(
            try await withKey.run("cat .ssh/authorized_keys").output,
            key.stored.authorizedKeysLine + "\n" + other.stored.authorizedKeysLine + "\n")
        let second = try await connect("nopassword", key: other.privateKey, script: ScriptedInteraction())
        XCTAssertEqual(second.loginMethod, .publicKey)
    }

    func testInstallKeyWithAHostileComment() async throws {
        let pair = KeyGenerator.generateEd25519()
        let marker = "/tmp/pwned-\(UUID().uuidString)"
        let comment = "it's \"x\" $(touch \(marker)) `touch \(marker)` ; touch \(marker) ; '"
        let publicKey = try pair.openSSHPublicKey(comment: comment)
        let connection = try await passwordConnection()
        await XCTAssertEqualAsync(try await connection.installAuthorizedKey(publicKey), .added)
        await XCTAssertEqualAsync(try await connection.installAuthorizedKey(publicKey), .alreadyPresent)
        let grep = try await connection.run("grep -c -F " + ShellQuote.alwaysQuote(publicKey.line) + " .ssh/authorized_keys")
        XCTAssertEqual(grep.output, "1\n", "the line is in the file once, exactly as given")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the comment was executed")
        // And the key works.
        let withKey = try await connect("nopassword", key: pair.privateKey, script: ScriptedInteraction())
        XCTAssertEqual(withKey.loginMethod, .publicKey)
    }

    // MARK: - Identity check, kill, probe

    func testIdentityCheck() async throws {
        let connection = try await passwordConnection()
        let result = try await connection.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        let pid = try XCTUnwrap(result.serverPID)
        let started = try XCTUnwrap(result.serverStartTime)

        // Passes for the server that was just started. The test user's name is longer than
        // procps's user column, so this also proves the truncated-name rule against a real ps.
        let found = try await connection.readIdentity(pid: pid)
        let identity = try XCTUnwrap(found)
        XCTAssertEqual(identity.commandBasename, "mosh-server")
        XCTAssertEqual(identity.startTime, started)
        XCTAssertTrue(environment.user.count > 8 && identity.user.hasSuffix("+"), identity.user)
        await XCTAssertEqualAsync(try await connection.checkIdentity(pid: pid, expectedStartTime: started), .passed(identity))
        await XCTAssertTrueAsync(try await connection.checkIdentity(pid: pid, expectedStartTime: started.addingTimeInterval(2)).isPassed)

        // A different pid: none at all, and one of another user.
        await XCTAssertEqualAsync(try await connection.checkIdentity(pid: 4_000_000, expectedStartTime: started), .failed(.noSuchProcess))
        await XCTAssertEqualAsync(try await connection.checkIdentity(pid: 1, expectedStartTime: started), .failed(.wrongUser(found: "root")))

        // A process of the same user that is not mosh-server.
        let sleeper = try await connection.run("sh -c 'sleep 60 >/dev/null 2>&1 & echo $!'")
        let sleeperPID = try XCTUnwrap(Int32(sleeper.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        await XCTAssertEqualAsync(
            try await connection.checkIdentity(pid: sleeperPID, expectedStartTime: started),
            .failed(.notMoshServer(found: "sleep")))

        // The right process, the wrong start time.
        await XCTAssertEqualAsync(
            try await connection.checkIdentity(pid: pid, expectedStartTime: started.addingTimeInterval(-60)),
            .failed(.startTimeDiffers(found: started)))
        await XCTAssertEqualAsync(
            try await connection.checkIdentity(pid: pid, expectedStartTime: started.addingTimeInterval(3)),
            .failed(.startTimeDiffers(found: started)))

        _ = try await connection.run("kill \(sleeperPID)")
        await stopServer(pid: pid, on: connection)
    }

    func testKillServerKillsOnlyAfterTheIdentityCheck() async throws {
        let connection = try await passwordConnection()
        let victim = try await connection.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        let bystander = try await connection.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        let pid = try XCTUnwrap(victim.serverPID)
        let started = try XCTUnwrap(victim.serverStartTime)

        // Refused: wrong start time. Nothing is killed.
        await assertThrowsBootstrapError(.identityCheckFailed(.startTimeDiffers(found: started))) {
            try await connection.killServer(pid: pid, expectedStartTime: started.addingTimeInterval(-600))
        }
        // Refused: not a mosh-server.
        let sleeper = try await connection.run("sh -c 'sleep 60 >/dev/null 2>&1 & echo $!'")
        let sleeperPID = try XCTUnwrap(Int32(sleeper.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        await assertThrowsBootstrapError(.identityCheckFailed(.notMoshServer(found: "sleep"))) {
            try await connection.killServer(pid: sleeperPID, expectedStartTime: started)
        }
        // Refused: no such process, another user's process.
        await assertThrowsBootstrapError(.identityCheckFailed(.noSuchProcess)) {
            try await connection.killServer(pid: 4_000_000, expectedStartTime: started)
        }
        await assertThrowsBootstrapError(.identityCheckFailed(.wrongUser(found: "root"))) {
            try await connection.killServer(pid: 1, expectedStartTime: started)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(processName(pid: pid), "mosh-server", "a refused kill must leave the server alone")
        XCTAssertEqual(processName(pid: sleeperPID), "sleep")

        // Accepted: the right process dies, and only that one.
        try await connection.killServer(pid: pid, expectedStartTime: started)
        let gone = await waitUntil(timeout: 5) { processName(pid: pid) == nil }
        XCTAssertTrue(gone, "mosh-server \(pid) still runs after killServer")
        try assertServerAlive(bystander)
        XCTAssertEqual(processName(pid: sleeperPID), "sleep")

        // Killing it again is refused: there is no such process any more.
        await assertThrowsBootstrapError(.identityCheckFailed(.noSuchProcess)) {
            try await connection.killServer(pid: pid, expectedStartTime: started)
        }

        _ = try await connection.run("kill \(sleeperPID)")
        await stopServer(pid: bystander.serverPID, on: connection)
    }

    func testProbeResults() async throws {
        let key = try newKey()
        let setup = try await passwordConnection()
        try await setup.installAuthorizedKey(key.stored.publicKey)
        let result = try await setup.startMoshServer(MoshServerCommand(), columns: 80, rows: 24)
        let server = ServerIdentity(pid: try XCTUnwrap(result.serverPID), startTime: try XCTUnwrap(result.serverStartTime))
        let target = try environment.target("normal")

        // The server runs and SSH reaches the saved address: UDP must be what is blocked.
        // The probe is silent: it logs in with the key and asks nothing.
        let saved = ServerProbe.SavedSession(remoteAddress: result.remoteAddress, server: server)
        let alive = await ServerProbe.probe(
            target: target, privateKey: key.privateKey, saved: saved, knownHosts: knownHosts, timeouts: fastTimeouts)
        XCTAssertEqual(alive, .udpBlocked)

        // The server runs, but the session was bootstrapped through another address.
        let elsewhere = ServerProbe.SavedSession(remoteAddress: "192.168.77.5", server: server)
        let moved = await ServerProbe.probe(
            target: target, privateKey: key.privateKey, saved: elsewhere, knownHosts: knownHosts, timeouts: fastTimeouts)
        XCTAssertEqual(moved, .serverBoundToUnreachableAddress(savedAddress: "192.168.77.5", sshAddress: "127.0.0.1"))

        // The server is gone.
        try await setup.killServer(pid: server.pid, expectedStartTime: server.startTime)
        _ = await waitUntil(timeout: 5) { processName(pid: server.pid) == nil }
        let ended = await ServerProbe.probe(
            target: target, privateKey: key.privateKey, saved: saved, knownHosts: knownHosts, timeouts: fastTimeouts)
        XCTAssertEqual(ended, .sessionEnded(.noSuchProcess))
        XCTAssertEqual(ended.action, .startNewSession)

        // SSH fails: nothing listens there.
        let nowhere = SSHTarget(host: "127.0.0.1", port: 22299, user: environment.user)
        let unreachable = await ServerProbe.probe(
            target: nowhere, privateKey: key.privateKey, saved: saved, knownHosts: knownHosts, timeouts: fastTimeouts)
        XCTAssertEqual(unreachable, .hostUnreachable(.connectFailed(reason: "connection refused")))
        XCTAssertEqual(unreachable.action, .keepWaiting)

        // A silent probe never trusts a host it does not know.
        let emptyStore = KnownHosts(fileURL: scratch.file("empty_known_hosts.json"))
        let untrusted = await ServerProbe.probe(
            target: target, privateKey: key.privateKey, saved: saved, knownHosts: emptyStore, timeouts: fastTimeouts)
        XCTAssertEqual(untrusted, .hostUnreachable(.hostKeyNotTrusted(fingerprint: try environment.hostKeyFingerprint("normal"))))
    }

    // MARK: - Commands

    func testRunReportsOutputAndExitStatus() async throws {
        let connection = try await passwordConnection()
        let ok = try await connection.run("echo out; echo err >&2")
        XCTAssertEqual(ok, CommandResult(exitStatus: 0, output: "out\n", errorOutput: "err\n"))
        await XCTAssertEqualAsync(try await connection.run("exit 7").exitStatus, 7)
        await XCTAssertEqualAsync(try await connection.run("nosuchcommand-xyz").exitStatus, 127)
        // Standard input is at its end, so a command that reads it does not wait.
        await XCTAssertEqualAsync(try await connection.run("cat; echo after").output, "after\n")
        // Several commands at once on one connection.
        async let a = connection.run("sleep 0.3; echo a")
        async let b = connection.run("echo b")
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.output + second.output, "a\nb\n")
        // After close, a command fails cleanly.
        await connection.close()
        XCTAssertFalse(connection.isOpen)
        let error = await bootstrapError { try await connection.run("echo x") }
        XCTAssertEqual(error, .connectionLost(stage: .command))
    }
}
