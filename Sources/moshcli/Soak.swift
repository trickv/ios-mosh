// moshcli soak: a long session under a bad network (scripts/netem.sh).
import Foundation
import MoshTransport

private let soakUsage = """
    usage: moshcli soak --host H --port P --key K --minutes N [--width W] [--height H]
                        [--seq-log FILE] [--rebind-every S] [--screen-out FILE [--settle-ms MS]]
                        [--server-size WxH] [--no-reply-ms MS]

    Types the line  echo soak-<n>-$((n*7))  every 2 to 3 seconds for N minutes (a fraction is
    allowed) and measures the time until the computed result, soak-<n>-<7n>, arrives in the host
    bytes. The session must run a POSIX shell. Fails if a marker takes more than 30 s.

    --seq-log FILE     append every client-to-server sequence number, one per line
    --rebind-every S   replace the socket (new source port) every S seconds
    --screen-out FILE  at the end, wait until the server has acknowledged all input and no new
                       state arrived for --settle-ms (default 500), then write the rendered
                       screen to FILE, one line per row with trailing blanks cut (the form of
                       tmux capture-pane -p, which scripts/soak.sh compares it with)
    \(SessionTuning.help)

    Prints a summary: markers, median and maximum latency, datagrams sent and received,
    retransmits, socket replacements.
    Exit codes: 0 every marker arrived in time, 1 one did not, 2 usage, 3 fallback needed,
    4 the server ended the session, 5 internal error.

    """

/// A marker that takes longer than this is a stall.
private let soakMarkerTimeout: UInt64 = 30_000

func soakCommand(_ arguments: [String]) async throws -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(soakUsage, terminator: "")
        return ExitCode.done
    }
    let options: SessionOptions
    let duration: UInt64
    let rebindEvery: UInt64?
    let screenOut: String?
    let settleQuiet: UInt64
    do {
        let list = try ArgumentList(arguments, valued: SessionOptions.names.union([
            "--minutes", "--rebind-every", "--screen-out", "--settle-ms",
        ]), flags: SessionTuning.flags)
        guard list.rest.isEmpty else { throw CLIError("unexpected argument \(list.rest[0])") }
        options = try SessionOptions(list)
        guard let text = list.string("--minutes"), let minutes = Double(text), minutes > 0, minutes <= 1440 else {
            throw CLIError("--minutes is required: a number above 0")
        }
        duration = UInt64(minutes * 60_000)
        rebindEvery = try list.integer("--rebind-every", in: 1...86_400).map { UInt64($0) * 1000 }
        screenOut = list.string("--screen-out")
        settleQuiet = UInt64(try list.integer("--settle-ms", in: 1...600_000) ?? 500)
    } catch {
        writeError("moshcli soak: \(error)\n\(soakUsage)")
        return ExitCode.usage
    }

    let tap = try WireTap(seqLogPath: options.seqLog, lossPercent: options.tuning.lossPercent,
                          delayMs: options.tuning.delayMs)
    let started = monotonicMilliseconds()
    let session = try await ScriptedSession(ScriptedSession.Settings(
        host: options.host, port: options.port, key: options.key, size: options.size,
        serverStartSize: options.tuning.serverStartSize, noReplyTimeout: options.tuning.noReplyTimeout,
        recorder: nil, tap: tap, prediction: options.tuning.prediction
    ))

    var latencies: [UInt64] = []
    var typed = 0
    var rebinds = 0
    var lastRebind = started
    var code = ExitCode.done
    var failure = ""

    func fail(_ result: StepResult) -> Bool {
        guard case .stop(let stopCode, let reason) = result else { return false }
        code = stopCode
        failure = reason
        return true
    }

    while monotonicMilliseconds() - started < duration {
        typed += 1
        let number = typed
        let interval = UInt64.random(in: 2000...3000)
        let typedAt = monotonicMilliseconds()
        if fail(await session.type(Array("echo soak-\(number)-$((\(number)*7))\r".utf8))) { break }
        let (result, waited) = await session.expect(Array("soak-\(number)-\(number * 7)".utf8), timeout: soakMarkerTimeout)
        if fail(result) {
            failure = "marker \(number), typed \(typedAt - started) ms after the start: " + failure
            break
        }
        latencies.append(waited)
        if waited >= 5000 {
            writeError("[\(monotonicMilliseconds() - started) ms] marker \(number) took \(waited) ms")
        }

        if let rebindEvery, monotonicMilliseconds() - lastRebind >= rebindEvery {
            _ = await session.rebind()
            rebinds += 1
            lastRebind = monotonicMilliseconds()
        }
        let elapsed = monotonicMilliseconds() - typedAt
        if elapsed < interval, fail(await session.sleep(interval - elapsed)) { break }
    }

    var screenNote = ""
    if code == ExitCode.done, let screenOut {
        // The screen is compared with the server's: first let everything arrive.
        let settled = monotonicMilliseconds()
        if !fail(await session.waitAck(timeout: soakMarkerTimeout)), !fail(await session.settle(settleQuiet)),
           !fail(await session.dumpScreen(to: screenOut)) {
            screenNote = "; screen written after \(monotonicMilliseconds() - settled) ms of settling"
        }
    }

    let retransmissions = await session.retransmissions()
    await session.finish()
    let counts = tap.counts
    let sorted = latencies.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let maximum = sorted.last ?? 0
    print("soak: \(code == ExitCode.done ? "ok" : "FAILED"); \((monotonicMilliseconds() - started) / 1000) s; "
        + "markers typed \(typed) arrived \(latencies.count); latency p50 \(median) ms max \(maximum) ms; "
        + "datagrams sent \(counts.sent) received \(counts.received); retransmits \(retransmissions); "
        + "socket replacements \(counts.sockets > 0 ? counts.sockets - 1 : 0) (\(rebinds) by --rebind-every)" + screenNote)
    if code != ExitCode.done {
        writeError("moshcli soak: \(failure)")
    }
    return code
}
