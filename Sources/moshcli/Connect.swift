// moshcli connect: run a script against a mosh-server (docs/PLAN.md "Test tools").
import Foundation
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport

private let connectUsage = """
    usage: moshcli connect --host H --port P --key K [--width W] [--height H] --script FILE
                           [--server-size WxH] [--no-reply-ms MS]
                           [--record DIR] [--seq-log FILE] [--quiet]
                           [--session-root DIR [--server-pid PID] [--crashpoint SPEC] [--step-log FILE]]

    Connects to a running mosh-server and runs the script (FILE, or - for standard input).
    H is a numeric address. Without --key the key is read from MOSH_KEY. The client's view is
    W x H (default 80x24).

    --record DIR    write meta.json and instructions.jsonl (the corpus format of mosh-oracle)
    --seq-log FILE  append every client-to-server sequence number, one per line; and to
                    FILE.numbers every number taken from the durability gate (seq N, state N,
                    frag N). scripts/check-seq-log.sh checks both
    --quiet         do not print each script line to standard error as it starts
    --session-root DIR
                    keep a session record under DIR (docs/RESUME.md), so that moshcli resume can
                    continue the session after this process is gone. The session id is printed.
                    quiesce then also stores the snapshot (the script stops if the record is not
                    clean afterwards) and resume is the return to the foreground. A script that
                    ends without a quiesce leaves a record that does not resume
    --server-pid PID
                    the mosh-server's process id, for the record
    \(Crashpoint.help)\(SessionTuning.help)
    SIGUSR1 quiesces (with a record: stores the snapshot); the script goes on.


    Exit codes: 0 the script ran to its end, 1 an expectation failed, 2 usage,
    3 fallback needed (the server builds on a state that is not held), 4 the server ended
    the session, 5 internal error, 6 no reply from the server (UDP blocked).

    \(Script.help)
    """

/// Reads a script from a file, or from standard input for `-`.
func readScript(_ path: String) throws -> [ScriptLine] {
    let text: String
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        guard let data = FileManager.default.contents(atPath: path) else { throw CLIError("cannot read \(path)") }
        text = String(decoding: data, as: UTF8.self)
    }
    return try Script.parse(text)
}

func connectCommand(_ arguments: [String]) async throws -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(connectUsage, terminator: "")
        return ExitCode.done
    }
    let options: SessionOptions
    let script: [ScriptLine]
    let recordDirectory: String?
    let quiet: Bool
    let flags: RecordFlags
    let serverPID: Int
    if arguments.contains("--crashpoint"), arguments.contains("list") {
        print(Crashpoint.stepNames, terminator: "")
        return ExitCode.done
    }
    do {
        let list = try ArgumentList(arguments, valued: SessionOptions.names.union(RecordFlags.valued)
            .union(["--script", "--record", "--server-pid"]), flags: SessionTuning.flags.union(["--quiet"]))
        guard list.rest.isEmpty else { throw CLIError("unexpected argument \(list.rest[0])") }
        options = try SessionOptions(list)
        flags = try RecordFlags(list)
        serverPID = try list.integer("--server-pid", in: 0...Int(Int32.max)) ?? 0
        guard let path = list.string("--script") else { throw CLIError("--script is required") }
        script = try readScript(path)
        recordDirectory = list.string("--record")
        quiet = list.has("--quiet")
    } catch {
        writeError("moshcli connect: \(error)\n\(connectUsage)")
        return ExitCode.usage
    }

    let tap = try WireTap(seqLogPath: options.seqLog, lossPercent: options.tuning.lossPercent,
                          delayMs: options.tuning.delayMs)
    let numbers = try NumbersLog.beside(seqLog: options.seqLog)
    let recorder = try recordDirectory.map {
        try Recorder(directory: $0, width: Int(options.size.width), height: Int(options.size.height))
    }
    let started = monotonicMilliseconds()
    let settings = ScriptedSession.Settings(
        host: options.host, port: options.port, key: options.key, size: options.size,
        serverStartSize: options.tuning.serverStartSize, noReplyTimeout: options.tuning.noReplyTimeout,
        recorder: recorder, tap: tap, numbers: numbers, prediction: options.tuning.prediction
    )
    let session: ScriptedSession
    if let root = flags.root {
        let meta = SessionMeta(createdAt: UInt64(Date().timeIntervalSince1970), hostName: options.host, address: options.host,
                               port: options.port, user: NSUserName(), serverStartSize: options.tuning.serverStartSize,
                               serverPID: UInt32(serverPID))
        let endpoint = meta.endpoint(key: options.key)
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: options.key, initialSize: options.size,
            options: flags.options(endpoint: endpoint, tap: tap, numbers: numbers, noReplyTimeout: options.tuning.noReplyTimeout,
                                   prediction: options.tuning.prediction))
        writeError("moshcli connect: session \(meta.id)")
        session = try await ScriptedSession(settings, coordinator: coordinator)
    } else {
        session = try await ScriptedSession(settings)
    }
    session.installQuiesceSignal()
    let code = await runScript(script, on: session, name: "connect", quiet: quiet, started: started)
    print("connect: " + (await finishAndSummarize(session, code: code, tap: tap, started: started)))
    return code
}

/// Runs the script line by line; returns the exit code.
func runScript(_ script: [ScriptLine], on session: ScriptedSession, name: String, quiet: Bool, started: UInt64) async -> Int32 {
    for line in script {
        if !quiet {
            writeError("[\(monotonicMilliseconds() - started) ms] \(line.number): \(line.text)")
        }
        let result: StepResult
        switch line.command {
        case .type(let bytes): result = await session.type(bytes)
        case .resize(let width, let height): result = await session.resize(width: width, height: height)
        case .waitAck(let timeout): result = await session.waitAck(timeout: timeout)
        case .expect(let text, let timeout): result = await session.expect(text, timeout: timeout).result
        case .expectScreen(let text, let timeout): result = await session.expectScreen(text, timeout: timeout)
        case .settle(let quiet): result = await session.settle(quiet)
        case .sleep(let milliseconds): result = await session.sleep(milliseconds)
        case .rebind: result = await session.rebind()
        case .quiesce(let afterSend): result = await session.quiesce(afterSend: afterSend)
        case .resume: result = await session.resume()
        case .resumeMem(let dropFirst): result = await session.resumeMem(dropFirst: dropFirst)
        case .dumpScreen(let path): result = await session.dumpScreen(to: path)
        case .expectDisplay(let text, let timeout): result = await session.expectDisplay(text, timeout: timeout)
        case .expectPredicted(let text, let timeout): result = await session.expectPredicted(text, timeout: timeout)
        case .expectDisplaySettled(let timeout): result = await session.expectDisplaySettled(timeout: timeout)
        case .expectUnderlined(let text, let timeout): result = await session.expectUnderlined(text, timeout: timeout)
        case .dumpDisplay(let path): result = await session.dumpDisplay(to: path)
        case .dumpBytes(let path): result = session.dumpBytes(to: path)
        case .shutdown: result = await session.shutdown()
        }
        if case .stop(let stopCode, let reason) = result {
            writeError("moshcli \(name): script line \(line.number) (\(line.text)): \(reason)")
            return stopCode
        }
    }
    return ExitCode.done
}

/// Ends the session and returns the summary line (without the command's name).
func finishAndSummarize(_ session: ScriptedSession, code: Int32, tap: WireTap, started: UInt64) async -> String {
    let retransmissions = await session.retransmissions()
    await session.finish()
    let counts = tap.counts
    return "exit \(code); \(session.instructionsApplied) server instructions applied, \(session.hostByteCount) host bytes; "
        + "datagrams sent \(counts.sent) received \(counts.received) withheld \(counts.dropped); "
        + "retransmits \(retransmissions); sockets \(counts.sockets); resumes \(session.resumes); "
        + "displays \(session.displayEvents); "
        + "\(monotonicMilliseconds() - started) ms"
}
