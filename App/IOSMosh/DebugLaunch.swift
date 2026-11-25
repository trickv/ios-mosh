import Darwin
import Foundation
import MoshCrypto
import MoshResume
import MoshSession
import MoshTransport

/// Debug-build launch arguments (docs/PLAN.md M5, "Debug launch arguments"):
///
///     -debugMoshPort 60001 -debugMoshKey <22-character key> [-debugMoshHost 127.0.0.1]
///     -debugFallbackPort 60002 -debugFallbackKey <key> [-debugFallbackHost 127.0.0.1]
///     -debugCrashAfter 5
///
/// - `-debugMoshPort`/`-debugMoshKey` start a session straight to that server (skipping SSH),
///   only when no session record exists; a launch without them (or with them and a record)
///   resumes the stored record.
/// - `-debugFallbackPort`/`-debugFallbackKey` replace the SSH bootstrap in the fallback.
/// - Both are taken only through `takeRequest()` and `takeFallbackRequest()`: a request is
///   refused when a stored record's `meta` names its address and port, and each of the two is
///   handed out once per process. A second record under the same key would start from
///   sequence 0, the shape of N1 (docs/notes/multi-session/DESIGN.md section 7, A21, LC-16). The
///   stored-record check alone does not see every earlier record (one forgotten while its
///   server runs, one whose `meta` cannot be read; review-steps-2-4.md R24-S4), and the launch
///   may read the `-debugMosh*` request again in one process (`makeRoot` runs at every
///   connection of the scene), so the once-per-process rule is kept here, for every reader
///   (step 10). A real host cannot repeat a key: its mosh-server makes a new one each time.
/// - `-debugCrashAfter N` kills the process (SIGKILL) N seconds after the session is up: the
///   same code as the "Crash Now" row in Settings (`DebugCrash`). A crash with a session open
///   needs this argument: Settings is reached only from the host list, with no session open.
///
/// UI tests get ports and keys from scripts/mosh-spawner.py. The host defaults to 127.0.0.1
/// (the simulator shares the Mac's network). Launch arguments land in the volatile argument
/// domain of UserDefaults: nothing is stored. Keys are throwaway test keys and never logged.
enum DebugLaunch {
    struct Request {
        var endpoint: SessionEndpoint
        /// The size of the server's terminal when it started: state 0's size. A
        /// mosh-server started without a tty (the spawner's) starts at 80x24.
        var serverStartSize: TerminalSize
    }

    /// `-debugPlaceholder 1`: the M0 placeholder screen, which echoes typed keys
    /// (PlaceholderUITests).
    static var placeholder: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugPlaceholder")
        #else
        return false
        #endif
    }

    /// The server a request or a stored record names: an address and a UDP port.
    struct Server: Hashable {
        var address: String
        var port: UInt16
    }

    /// The rule: may this request make a record? No when it was handed out before (for a
    /// request that is handed out once) or when a stored record names its server.
    static func mayHandOut(_ request: Request, handedOutBefore: Bool, storedServers: Set<Server>) -> Bool {
        !handedOutBefore && !storedServers.contains(Server(address: request.endpoint.host, port: request.endpoint.port))
    }

    /// The servers the stored records' `meta` names, read without the lock (as the list reads
    /// the counters). A record whose `meta` cannot be read names none.
    static func storedServers(root: String) -> Set<Server> {
        Set(SessionStore.sessionIDs(root: root).compactMap { id in
            (try? SessionStore(root: root, id: id).readMeta()).map { Server(address: $0.address, port: $0.port) }
        })
    }

    /// Hands a request out by `mayHandOut`, and remembers that it did.
    final class Handout: @unchecked Sendable {
        private let name: String
        /// Handed out at most once (the app's two hand-outs; the unit tests read it).
        let once: Bool
        private let lock = NSLock()
        private var handedOut = false

        init(name: String, once: Bool) {
            self.name = name
            self.once = once
        }

        func take(_ request: Request?, root: String) -> Request? {
            guard let request else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard DebugLaunch.mayHandOut(request, handedOutBefore: once && handedOut,
                                         storedServers: DebugLaunch.storedServers(root: root)) else {
                // The port only: the key is never logged.
                DebugLog.shared.log("debug launch: \(name) request for port \(request.endpoint.port) refused (handed out before, or a stored record names its server)")
                return nil
            }
            handedOut = true
            return request
        }
    }

    /// The app's two hand-outs, each once per process (internal for the unit tests).
    static let sessionHandout = Handout(name: "-debugMosh", once: true)
    static let fallbackHandout = Handout(name: "-debugFallback", once: true)

    /// The `-debugMosh*` session, once per process and only if no stored record names its server.
    static func takeRequest(root: String = SessionFiles.root) -> Request? {
        sessionHandout.take(request(prefix: "debugMosh"), root: root)
    }

    /// The `-debugFallback*` server, once per process and only if no stored record names it.
    static func takeFallbackRequest(root: String = SessionFiles.root) -> Request? {
        fallbackHandout.take(request(prefix: "debugFallback"), root: root)
    }

    /// `-debugCrashAfter N`, in seconds.
    static var crashAfter: TimeInterval? {
        #if DEBUG
        guard let text = UserDefaults.standard.string(forKey: "debugCrashAfter"), let seconds = Double(text),
              seconds >= 0 else { return nil }
        return seconds
        #else
        return nil
        #endif
    }

    /// `-debugLocalEcho adaptive|always|never|experimental`: local echo of a session without a
    /// saved host (a debug launch). Without it such a session has mosh's default, Adaptive.
    static var localEchoMode: LocalEcho.Mode? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "debugLocalEcho").flatMap(LocalEcho.Mode.init(rawValue:))
        #else
        return nil
        #endif
    }

    private static func request(prefix: String) -> Request? {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let portText = defaults.string(forKey: prefix + "Port"),
              let port = UInt16(portText), port != 0,
              let keyText = defaults.string(forKey: prefix + "Key"),
              let key = try? Base64Key(printable: keyText)
        else { return nil }
        let host = defaults.string(forKey: prefix + "Host") ?? "127.0.0.1"
        return Request(endpoint: SessionEndpoint(host: host, port: port, key: key),
                       serverStartSize: TerminalRemoteState.defaultServerSize)
        #else
        return nil
        #endif
    }
}

/// "Crash now" (docs/PLAN.md M6: a debug-only row that calls `kill(getpid(), SIGKILL)`), so
/// that a process death in the foreground can be tried by hand and by the UI tests.
enum DebugCrash {
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func now() {
        #if DEBUG
        DebugLog.shared.log("debug: crash now (SIGKILL)")
        DebugLog.shared.flush()
        kill(getpid(), SIGKILL)
        #endif
    }
}
