// The options `moshcli connect` and `moshcli soak` share.
import Foundation
import MoshCrypto
import MoshTerminal
import MoshTransport

/// Command-line arguments as `--name value` pairs and flags.
struct ArgumentList {
    private(set) var values: [String: String] = [:]
    /// Arguments that are not options.
    private(set) var rest: [String] = []

    /// - Parameters:
    ///   - valued: options that take a value.
    ///   - flags: options that take none.
    init(_ arguments: [String], valued: Set<String>, flags: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            index += 1
            if flags.contains(name) {
                values[name] = ""
            } else if valued.contains(name) {
                guard index < arguments.count else { throw CLIError("\(name) needs a value") }
                values[name] = arguments[index]
                index += 1
            } else if name.hasPrefix("--") {
                throw CLIError("unknown option \(name)")
            } else {
                rest.append(name)
            }
        }
    }

    func has(_ name: String) -> Bool { values[name] != nil }

    func string(_ name: String) -> String? { values[name] }

    func integer(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text), range.contains(value) else {
            throw CLIError("\(name) must be a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }
}

/// Where the server is and how to talk to it.
struct SessionOptions {
    static let names: Set<String> = Set(["--host", "--port", "--key", "--width", "--height", "--seq-log"])
        .union(SessionTuning.names)

    var host: String
    var port: UInt16
    var key: Base64Key
    var size: TerminalSize
    var seqLog: String?
    var tuning: SessionTuning

    /// `--key` may be left out if `MOSH_KEY` is set, as for mosh-client: a key on the command
    /// line is visible in `ps`.
    init(_ arguments: ArgumentList) throws {
        guard let host = arguments.string("--host"), !host.isEmpty else { throw CLIError("--host is required") }
        guard let port = try arguments.integer("--port", in: 1...65_535) else { throw CLIError("--port is required") }
        guard let key = arguments.string("--key") ?? ProcessInfo.processInfo.environment["MOSH_KEY"], !key.isEmpty else {
            throw CLIError("--key (or MOSH_KEY) is required")
        }
        self.host = host
        self.port = UInt16(port)
        do {
            self.key = try Base64Key(printable: key)
        } catch {
            throw CLIError("the key is not a mosh session key: \(error)")
        }
        let width = try arguments.integer("--width", in: 1...65_535) ?? 80
        let height = try arguments.integer("--height", in: 1...65_535) ?? 24
        size = TerminalSize(width: width, height: height)
        seqLog = arguments.string("--seq-log")
        tuning = try SessionTuning(arguments, defaultServerSize: TerminalSize(width: 80, height: 24))
    }
}

/// Options about the session itself that `connect`, `soak` and `bootstrap` share.
struct SessionTuning {
    static let names: Set<String> = ["--server-size", "--no-reply-ms", "--loss", "--predict", "--delay-ms"]
    static let flags: Set<String> = ["--predict-overwrite"]
    static let help = """
        --server-size WxH  the size the server's terminal had when it started (its state 0):
                           80x24 for a server started without a tty (the default for connect
                           and soak); bootstrap uses the pty size it asked for
        --no-reply-ms MS   give up with exit code 6 when no state came from the server within
                           MS ms (default 15000, mosh's "timed out waiting for server"); 0: never
        --loss PERCENT     throw away this share of the datagrams in each direction, in the
                           client (a lossy network without tc netem)
        --predict MODE     local echo: always, never (default), adaptive, experimental
                           (mosh's --predict)
        --predict-overwrite
                           predicted text overwrites instead of inserting (mosh's
                           --predict-overwrite)
        --delay-ms MS      hold every datagram MS ms (0 to 2000) in each direction, in the
                           client, after --loss: the round trip grows by 2 * MS

        """

    var serverStartSize: TerminalSize
    var noReplyTimeout: UInt64?
    var lossPercent: Int
    var prediction: PredictionSettings
    var delayMs: Int

    init(_ arguments: ArgumentList, defaultServerSize: TerminalSize) throws {
        lossPercent = try arguments.integer("--loss", in: 0...99) ?? 0
        delayMs = try arguments.integer("--delay-ms", in: 0...2000) ?? 0
        var display = PredictionDisplay.never
        if let name = arguments.string("--predict") {
            // mosh.pl:143-153 rejects an unknown mode too.
            guard let mode = PredictionDisplay(rawValue: name) else {
                throw CLIError("--predict must be always, never, adaptive or experimental")
            }
            display = mode
        }
        prediction = PredictionSettings(display: display, overwrite: arguments.has("--predict-overwrite"))
        if let text = arguments.string("--server-size") {
            let parts = text.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  (1...65_535).contains(width), (1...65_535).contains(height) else {
                throw CLIError("--server-size must be WxH, for example 80x24")
            }
            serverStartSize = TerminalSize(width: width, height: height)
        } else {
            serverStartSize = defaultServerSize
        }
        let milliseconds = try arguments.integer("--no-reply-ms", in: 0...86_400_000) ?? 15_000
        noReplyTimeout = milliseconds == 0 ? nil : UInt64(milliseconds)
    }
}
