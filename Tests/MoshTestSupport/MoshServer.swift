// Starts and stops a real mosh-server for tests.
//
// Linux and macOS only: it uses Foundation.Process, which does not exist on iOS. On other
// platforms this file compiles to nothing.

#if os(Linux) || os(macOS)

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A `mosh-server` started for one test, listening on 127.0.0.1.
///
///     func testSomething() throws {
///         guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
///         let server = try MoshServerProcess(command: ["/bin/sh", "-c", "echo hello; sleep 30"])
///         defer { server.stop() }
///         // connect to 127.0.0.1, port server.port, with key server.key
///     }
///
/// What to know about the server (mosh 1.4.0):
/// - It runs `mosh-server new -i 127.0.0.1 [-p PORT] [-- COMMAND...]`, which prints
///   `MOSH CONNECT <port> <key>`, detaches, and prints the pid of the detached process. `pid` is
///   that process, the one that owns the UDP port and the session.
/// - The command (or the login shell, without one) starts only when the first datagram from a
///   client arrives, and the server exits when the command ends.
/// - A server that never hears from a client exits by itself after 60 seconds.
/// - Its terminal is 80 x 24 until a client sends another size.
/// - It ignores SIGHUP and SIGPIPE; `stop()` uses SIGKILL.
/// - Each instance has its own random key. A sequence number must never be used twice with one
///   key, so a test that restarts its client must carry the counters over or start a new server.
public final class MoshServerProcess {
    /// Why a server could not be started.
    public enum StartError: Error, CustomStringConvertible {
        /// `locate()` found no `mosh-server` (and no path was given). Tests should skip instead.
        case notInstalled
        /// The process could not be run, or exited with a status other than 0.
        case failed(status: Int32, output: String)
        /// It ran, but its output had no `MOSH CONNECT` line or no detached pid.
        case unexpectedOutput(String)

        public var description: String {
            switch self {
            case .notInstalled: return "mosh-server is not installed (not found in PATH or the usual places)"
            case .failed(let status, let output): return "mosh-server exited with status \(status): \(output)"
            case .unexpectedOutput(let output): return "unexpected output from mosh-server: \(output)"
            }
        }
    }

    /// The UDP port the server listens on (on 127.0.0.1).
    public let port: UInt16
    /// The session key as printed: 22 base64 characters.
    public let key: String
    /// Process id of the detached server.
    public let pid: Int32

    private var stopped = false
    private let launcher: Process

    /// A UTF-8 locale that exists on a stock system: mosh-server refuses to start without one.
    public static var defaultLocale: String {
        #if os(Linux)
        return "C.UTF-8"
        #else
        return "en_US.UTF-8"
        #endif
    }

    /// The full path of `mosh-server`, or nil if it is not installed. Tests call this first and
    /// throw `XCTSkip` on nil.
    ///
    /// Looks at the environment variable `MOSH_SERVER` first (a full path; if set, nothing else
    /// is tried), then at every directory of `PATH`, then at the directories where Homebrew and
    /// MacPorts install it. Those are not in the `PATH` of a command run over SSH on a Mac, and
    /// without them the tests there would be skipped without anyone noticing.
    public static func locate() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["MOSH_SERVER"], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = directory + "/mosh-server"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Starts a server and waits until it has printed its port and key and has detached.
    ///
    /// - Parameters:
    ///   - port: what to pass to `-p`: a port (`"60123"`) or a range (`"60100:60199"`). With nil the
    ///     server takes the first free port from 60001 to 60999, so servers started by different
    ///     tests do not collide.
    ///   - command: the command to run in the session, with its arguments. Empty runs the user's
    ///     login shell.
    ///   - environment: variables to add to (or replace in) this process's environment.
    ///   - locale: value for `LC_ALL` and `LANG`. Must be a UTF-8 locale.
    ///   - executable: full path of the binary; nil uses `locate()`.
    /// - Throws: `StartError`.
    public init(
        port: String? = nil,
        command: [String] = [],
        environment: [String: String] = [:],
        locale: String = MoshServerProcess.defaultLocale,
        executable: String? = nil
    ) throws {
        guard let path = executable ?? Self.locate() else { throw StartError.notInstalled }

        var arguments = ["new", "-i", "127.0.0.1"]
        if let port {
            arguments += ["-p", port]
        }
        if !command.isEmpty {
            arguments += ["--"] + command
        }

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["LC_ALL"] = locale
        processEnvironment["LANG"] = locale
        for (name, value) in environment {
            processEnvironment[name] = value
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = processEnvironment
        // Not a terminal: the server then skips the "\r\n" it prints for typeahead, and starts at 80 x 24.
        process.standardInput = FileHandle.nullDevice
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw StartError.failed(status: -1, output: "could not run \(path): \(error)")
        }

        // Read up to the line we need from each stream, not to end of file, and do not call
        // waitUntilExit() first. On Linux, Foundation notices the end of a process when a socket
        // that the child inherits is closed; the detached server inherits it too and keeps it, so
        // waitUntilExit() would only return when the server itself ends.
        let outputText = Self.read(standardOutput.fileHandleForReading, until: { Self.parseConnectLine($0) != nil })
        let errorText = Self.read(standardError.fileHandleForReading, until: { Self.parseDetachedPid($0) != nil })
        try? standardOutput.fileHandleForReading.close()
        try? standardError.fileHandleForReading.close()

        let everything = outputText + errorText
        guard let connect = Self.parseConnectLine(outputText), let pid = Self.parseDetachedPid(errorText) else {
            // It did not come up. Both streams are at end of file, so the process is ending; give
            // Foundation a moment to see that, to report the exit status.
            var waited = 0
            while process.isRunning && waited < 100 {
                usleep(50_000)
                waited += 1
            }
            if let strayPid = Self.parseDetachedPid(errorText) {
                kill(strayPid, SIGKILL)
            }
            guard !process.isRunning else { throw StartError.unexpectedOutput(everything) }
            if process.terminationReason == .exit && process.terminationStatus == 0 {
                throw StartError.unexpectedOutput(everything)
            }
            throw StartError.failed(status: process.terminationStatus, output: everything)
        }
        // Keeps Foundation's bookkeeping for the short-lived parent process alive with the server.
        self.launcher = process
        self.port = connect.port
        self.key = connect.key
        self.pid = pid
    }

    deinit {
        stop()
    }

    /// True while the detached server process exists.
    public var isAlive: Bool {
        Self.processExists(pid)
    }

    /// Kills the server (SIGKILL) and waits until it is gone. The command it ran loses its terminal
    /// and gets SIGHUP. Safe to call more than once, and after the server has exited by itself.
    public func stop() {
        if stopped { return }
        stopped = true
        guard Self.processExists(pid), Self.looksLikeMoshServer(pid) else { return }
        kill(pid, SIGKILL)
        // The server is not our child (it detached), so it cannot be waited for; poll instead.
        for _ in 0..<500 {
            if !Self.processExists(pid) { return }
            usleep(10_000)
        }
    }

    // MARK: - Parsing (internal so that they can be tested without a server)

    /// Finds `MOSH CONNECT <port> <key>` on a line of its own. Tolerates `\r` before the newline.
    static func parseConnectLine(_ text: String) -> (port: UInt16, key: String)? {
        // isNewline covers "\n", "\r" and the pair "\r\n", which is a single Character in Swift.
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count == 4, words[0] == "MOSH", words[1] == "CONNECT",
                  let port = UInt16(words[2]), words[3].utf8.count == 22 else { continue }
            return (port, String(words[3]))
        }
        return nil
    }

    /// Finds the pid in `[mosh-server detached, pid = 12345]`.
    static func parseDetachedPid(_ text: String) -> Int32? {
        let marker = "[mosh-server detached, pid = "
        guard let start = text.range(of: marker) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        return Int32(rest[..<end])
    }

    // MARK: - Private

    /// Reads from `handle` until `done` accepts the text so far or the stream ends.
    private static func read(_ handle: FileHandle, until done: (String) -> Bool) -> String {
        var collected = Data()
        while true {
            let text = String(decoding: collected, as: UTF8.self)
            if done(text) { return text }
            let chunk = handle.availableData // blocks until there is data; empty at end of file
            if chunk.isEmpty { return text }
            collected.append(chunk)
        }
    }

    private static func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 && errno != EPERM {
            return false
        }
        #if os(Linux)
        // A process that has exited but has not been reaped yet still answers kill(pid, 0).
        // /proc/<pid>/stat is "pid (name) state ..."; state Z is a zombie.
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.range(of: ") ", options: .backwards),
           stat[close.upperBound...].first == "Z" {
            return false
        }
        #endif
        return true
    }

    /// Guards `stop()` against a pid that was reused by another program after the server exited.
    private static func looksLikeMoshServer(_ pid: Int32) -> Bool {
        #if os(Linux)
        guard let name = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return false }
        return name.hasPrefix("mosh-server")
        #else
        return true
        #endif
    }
}

#endif
