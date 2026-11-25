// moshcli bootstrap: log in over SSH (MoshBootstrap), start mosh-server, run a script on the
// session (docs/PLAN.md "Test tools").
import Foundation
import MoshBootstrap
import MoshCrypto
import MoshKeys
import MoshTransport

private let bootstrapUsage = """
    usage: moshcli bootstrap --ssh-host H --user U [--ssh-port P] --known-hosts FILE
                             [--accept-new-host-key] [--key-store DIR --key-name NAME]
                             [--server-path P] [--locale L] [--remote-command CMD]
                             [--udp-ports LOW[:HIGH]] [--width W] [--height H] --script FILE
                             [--no-reply-ms MS] [--record DIR] [--seq-log FILE]
                             [--print-server FILE] [--quiet]

    Logs in to H over SSH as U, starts mosh-server (asking for a pty of W x H, default 80x24, so
    that the server's state 0 has the view's size), then runs the script on the mosh session to
    the address the SSH connection used.

    Login: the device key from --key-store DIR (a MoshKeys FileKeyStore) named --key-name, and
    the password in the environment variable MOSH_SSH_PASSWORD when the host asks for one. A
    password is never taken from the command line.

    --known-hosts FILE      the host keys (MoshBootstrap's JSON format; created if missing)
    --accept-new-host-key   trust an unknown host key (and print its fingerprint); without it
                            an unknown host is refused
    --server-path P         mosh-server's path or prefix on the host
    --locale L              LANG for the server (default en_US.UTF-8)
    --remote-command CMD    run CMD through the login shell instead of the shell itself
    --udp-ports LOW[:HIGH]  mosh-server's -p
    --print-server FILE     write "PID PORT" of the started server to FILE
    \(SessionTuning.help)
    The other options and the script are those of moshcli connect. Exit codes: as for
    connect, and 7 the SSH login or the server start failed (the reason is printed).

    """

func bootstrapCommand(_ arguments: [String]) async throws -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(bootstrapUsage, terminator: "")
        return ExitCode.done
    }
    let request: SSHBootstrap.Request
    let knownHostsPath: String
    let acceptNew: Bool
    let script: [ScriptLine]
    let tuning: SessionTuning
    let size: TerminalSize
    let recordDirectory: String?
    let seqLog: String?
    let printServer: String?
    let quiet: Bool
    do {
        let valued: Set<String> = [
            "--ssh-host", "--ssh-port", "--user", "--known-hosts", "--key-store", "--key-name", "--server-path",
            "--locale", "--remote-command", "--udp-ports", "--width", "--height", "--script", "--record",
            "--seq-log", "--print-server",
        ]
        let list = try ArgumentList(arguments, valued: valued.union(SessionTuning.names),
                                    flags: SessionTuning.flags.union(["--accept-new-host-key", "--quiet"]))
        guard list.rest.isEmpty else { throw CLIError("unexpected argument \(list.rest[0])") }
        guard let host = list.string("--ssh-host"), !host.isEmpty else { throw CLIError("--ssh-host is required") }
        guard let user = list.string("--user"), !user.isEmpty else { throw CLIError("--user is required") }
        guard let known = list.string("--known-hosts") else { throw CLIError("--known-hosts is required") }
        let sshPort = try list.integer("--ssh-port", in: 1...65_535) ?? 22
        let width = try list.integer("--width", in: 1...65_535) ?? 80
        let height = try list.integer("--height", in: 1...65_535) ?? 24
        size = TerminalSize(width: width, height: height)
        // The pty has the view's size: the server's state 0 is then the same as ours.
        tuning = try SessionTuning(list, defaultServerSize: size)
        if tuning.serverStartSize != size {
            throw CLIError("--server-size cannot differ from the pty size (--width x --height) in bootstrap")
        }

        var privateKey: Data?
        switch (list.string("--key-store"), list.string("--key-name")) {
        case (let directory?, let name?):
            privateKey = try FileKeyStore(directory: URL(fileURLWithPath: directory)).loadPrivateKey(name: name)
        case (nil, nil):
            privateKey = nil
        default:
            throw CLIError("--key-store and --key-name go together")
        }
        var command = MoshServerCommand()
        if let path = list.string("--server-path") { command.serverPath = path }
        if let locale = list.string("--locale") { command.locale = locale }
        if let remote = list.string("--remote-command") { command.remoteCommand = remote }
        if let ports = list.string("--udp-ports") {
            guard let range = UDPPortRange(ports) else { throw CLIError("--udp-ports must be LOW or LOW:HIGH") }
            command.portRange = range
        }
        request = SSHBootstrap.Request(
            target: SSHTarget(host: host, port: sshPort, user: user), privateKey: privateKey, command: command,
            columns: width, rows: height)
        knownHostsPath = known
        acceptNew = list.has("--accept-new-host-key")
        guard let path = list.string("--script") else { throw CLIError("--script is required") }
        script = try readScript(path)
        recordDirectory = list.string("--record")
        seqLog = list.string("--seq-log")
        printServer = list.string("--print-server")
        quiet = list.has("--quiet")
    } catch {
        writeError("moshcli bootstrap: \(error)\n\(bootstrapUsage)")
        return ExitCode.usage
    }

    let started = monotonicMilliseconds()
    let password = ProcessInfo.processInfo.environment["MOSH_SSH_PASSWORD"]
    let interaction = SSHInteraction(
        confirmHostKey: { prompt in
            writeError("moshcli bootstrap: unknown host key \(prompt.keyType) \(prompt.fingerprint) for "
                + "\(prompt.host):\(prompt.port); " + (acceptNew ? "trusted" : "refused (see --accept-new-host-key)"))
            return acceptNew
        },
        password: { prompt in
            // Once: a second question means the first answer was wrong.
            prompt.attempt == 1 ? password : nil
        })
    let result: BootstrapResult
    do {
        result = try await SSHBootstrap.run(
            request, knownHosts: KnownHosts(fileURL: URL(fileURLWithPath: knownHostsPath)), interaction: interaction)
    } catch let error as BootstrapError {
        writeError("moshcli bootstrap: \(error.message)" + (error.suggestedFix.map { " \($0)" } ?? "") + " (\(error))")
        return ExitCode.bootstrapFailed
    }
    writeError("moshcli bootstrap: mosh-server pid \(result.serverPID.map(String.init) ?? "?") on \(result.remoteAddress) "
        + "UDP port \(result.udpPort), login \(result.loginMethod.rawValue), \(monotonicMilliseconds() - started) ms")
    if let printServer {
        try Data("\(result.serverPID.map(String.init) ?? "-") \(result.udpPort)\n".utf8)
            .write(to: URL(fileURLWithPath: printServer))
    }
    guard let port = UInt16(exactly: result.udpPort), port > 0 else {
        writeError("moshcli bootstrap: the server named UDP port \(result.udpPort)")
        return ExitCode.bootstrapFailed
    }
    let key: Base64Key
    do {
        key = try Base64Key(printable: result.sessionKey)
    } catch {
        writeError("moshcli bootstrap: the server's key is not a mosh session key: \(error)")
        return ExitCode.bootstrapFailed
    }

    let tap = try WireTap(seqLogPath: seqLog, lossPercent: tuning.lossPercent, delayMs: tuning.delayMs)
    let recorder = try recordDirectory.map {
        try Recorder(directory: $0, width: Int(size.width), height: Int(size.height))
    }
    let session = try await ScriptedSession(ScriptedSession.Settings(
        host: result.remoteAddress, port: port, key: key, size: size,
        serverStartSize: tuning.serverStartSize, noReplyTimeout: tuning.noReplyTimeout,
        recorder: recorder, tap: tap, prediction: tuning.prediction
    ))
    let code = await runScript(script, on: session, name: "bootstrap", quiet: quiet, started: started)
    print("bootstrap: " + (await finishAndSummarize(session, code: code, tap: tap, started: started)))
    return code
}
