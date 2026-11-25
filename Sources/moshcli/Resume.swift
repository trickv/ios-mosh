// moshcli resume: cold start from a session record (docs/PLAN.md section 3 and "Test tools").
import Foundation
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport

private let resumeUsage = """
    usage: moshcli resume --session-root DIR [--session ID] [--width W] [--height H] --script FILE
                          [--drop-first N] [--loss PERCENT] [--record DIR] [--seq-log FILE]
                          [--crashpoint SPEC] [--step-log FILE] [--quiet]
           moshcli resume --session-root DIR [--session ID] --info

    Continues the session whose record is under DIR (made by moshcli connect --session-root):
    takes the record's lock, and if the record is clean loads its snapshot, rebuilds the
    session, writes "dirty" and sends. Then runs the script (FILE, or - for standard input) as
    moshcli connect does. Without --session, DIR must hold exactly one record.

    If the record cannot be resumed (dirty, ended, damaged, a part missing), nothing is sent:
    the reason and the old server's pid are printed, the record is deleted, and the exit code is
    3. A caller then starts a new session, as the app does.

    --info          print what the record says (id, state, server pid, port, reserved limits)
                    without taking its lock or changing it, and exit
    --drop-first N  the first N datagrams after the resume are not sent
    --seq-log FILE  as for connect; give the file the session's earlier processes used
    \(Crashpoint.help)
    A script that ends without a quiesce leaves a record that does not resume.
    SIGUSR1 quiesces and stores the snapshot; the script goes on.

    Exit codes: as for connect; 3 also for the fallback at the start; 8 the record is in use or
    cannot be read now (try again later).

    \(Script.help)
    """

private func stateName(_ state: RecordState) -> String {
    switch state {
    case .clean: return "clean"
    case .dirty: return "dirty"
    case .ended: return "ended"
    }
}

/// `--info`: one `name=value` per line, for scripts. Reads only, without the lock.
private func printInfo(root: String, id: SessionID) -> Int32 {
    let store = SessionStore(root: root, id: id)
    print("session=\(id)")
    do {
        let meta = try store.readMeta()
        print("server_pid=\(meta.serverPID)")
        print("address=\(meta.address)")
        print("port=\(meta.port)")
    } catch {
        print("meta_error=\(error)")
    }
    do {
        let counters = try store.readCounters()
        print("state=\(stateName(counters.state))")
        print("generation=\(counters.generation)")
        print("seq_reserved=\(counters.limits.sequence)")
        print("num_reserved=\(counters.limits.state)")
        print("frag_reserved=\(counters.limits.fragmentID)")
    } catch {
        print("state=unusable")
        print("counters_error=\(error)")
    }
    return ExitCode.done
}

func resumeCommand(_ arguments: [String]) async throws -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(resumeUsage, terminator: "")
        return ExitCode.done
    }
    if arguments.contains("--crashpoint"), arguments.contains("list") {
        print(Crashpoint.stepNames, terminator: "")
        return ExitCode.done
    }
    let root: String
    let id: SessionID
    let info: Bool
    var script: [ScriptLine] = []
    let size: TerminalSize
    let flags: RecordFlags
    let seqLog: String?
    let recordDirectory: String?
    let dropFirst: Int
    let loss: Int
    let quiet: Bool
    do {
        let list = try ArgumentList(arguments, valued: RecordFlags.valued.union([
            "--session", "--width", "--height", "--script", "--drop-first", "--loss", "--record", "--seq-log",
        ]), flags: ["--quiet", "--info"])
        guard list.rest.isEmpty else { throw CLIError("unexpected argument \(list.rest[0])") }
        flags = try RecordFlags(list)
        guard let rootPath = flags.root else { throw CLIError("--session-root is required") }
        root = rootPath
        if let text = list.string("--session") {
            guard let parsed = SessionID(text) else { throw CLIError("--session is not a session id") }
            id = parsed
        } else {
            let ids = SessionStore.sessionIDs(root: root)
            guard ids.count == 1 else { throw CLIError("\(root) holds \(ids.count) records; say which with --session") }
            id = ids[0]
        }
        info = list.has("--info")
        if !info {
            guard let path = list.string("--script") else { throw CLIError("--script is required") }
            script = try readScript(path)
        }
        let width = try list.integer("--width", in: 1...65_535) ?? 80
        let height = try list.integer("--height", in: 1...65_535) ?? 24
        size = TerminalSize(width: width, height: height)
        seqLog = list.string("--seq-log")
        recordDirectory = list.string("--record")
        dropFirst = try list.integer("--drop-first", in: 0...1000) ?? 0
        loss = try list.integer("--loss", in: 0...99) ?? 0
        quiet = list.has("--quiet")
    } catch {
        writeError("moshcli resume: \(error)\n\(resumeUsage)")
        return ExitCode.usage
    }
    if info {
        return printInfo(root: root, id: id)
    }

    let tap = try WireTap(seqLogPath: seqLog, lossPercent: loss)
    let numbers = try NumbersLog.beside(seqLog: seqLog)
    let started = monotonicMilliseconds()
    // The endpoint is the record's; only its address and port are needed before the cold start
    // (for the socket), and those are in `meta`, which is read again under the lock.
    let store = SessionStore(root: root, id: id)
    let peek = try? store.readMeta()
    let endpointForOptions = SessionEndpoint(host: peek?.address ?? "127.0.0.1", port: peek?.port ?? 1,
                                             key: (try? store.readKey()) ?? (try! .init(bytes: [UInt8](repeating: 0, count: 16))))
    let options = flags.options(endpoint: endpointForOptions, tap: tap, numbers: numbers, noReplyTimeout: nil)

    switch ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options) {
    case .retryLater(let retry):
        writeError("moshcli resume: not now: \(retry)")
        print("resume: exit \(ExitCode.retryLater); retry later (\(retry))")
        return ExitCode.retryLater
    case .fallback(let fallback):
        let server = fallback.meta.map { "mosh-server pid \($0.serverPID) port \($0.port)" } ?? "the old server is not known"
        writeError("moshcli resume: fallback: \(fallback.reason); \(server)")
        writeError("moshcli resume: \(ColdStartFallback.userMessage)")
        if !fallback.recordDeleted {
            try ResumeCoordinator.deleteRecord(root: root, id: id)
        }
        print("resume: exit \(ExitCode.fallbackNeeded); fallback (\(fallback.reason)); nothing sent; the record is deleted; "
            + "datagrams sent \(tap.counts.sent)")
        return ExitCode.fallbackNeeded
    case .resumed(let coordinator):
        let meta = coordinator.meta
        writeError("moshcli resume: resumed session \(meta.id); mosh-server pid \(meta.serverPID) port \(meta.port)")
        let recorder = try recordDirectory.map {
            try Recorder(directory: $0, width: Int(size.width), height: Int(size.height))
        }
        tap.dropNextDatagrams(dropFirst)
        let session = try await ScriptedSession(ScriptedSession.Settings(
            host: meta.address, port: meta.port, key: endpointForOptions.key, size: size,
            serverStartSize: meta.serverStartSize, noReplyTimeout: nil, recorder: recorder, tap: tap, numbers: numbers
        ), coordinator: coordinator)
        session.installQuiesceSignal()
        let code = await runScript(script, on: session, name: "resume", quiet: quiet, started: started)
        print("resume: resumed; " + (await finishAndSummarize(session, code: code, tap: tap, started: started)))
        return code
    }
}
