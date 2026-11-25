import Foundation
import MoshBootstrap
import MoshKeys
import MoshTestSupport
import XCTest

/// What scripts/itest-sshd.sh prepared: a test user and four sshd instances on 127.0.0.1.
/// Read from `$MOSH_SSHD_ITEST_DIR/env.json`.
struct SSHTestEnvironment: Decodable {
    struct Server: Decodable {
        let port: Int
        let hostKeyFile: String
    }

    let user: String
    let password: String
    let home: String
    /// A program named mosh-server that sleeps forever.
    let hangingServer: String
    let servers: [String: Server]

    /// Throws XCTSkip unless the tests were started by `scripts/itest.sh bootstrap`.
    static func load() throws -> SSHTestEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MOSH_SSHD_ITEST"] == "1" else {
            throw XCTSkip("needs the sshd instances of scripts/itest.sh bootstrap (MOSH_SSHD_ITEST=1)")
        }
        guard let directory = environment["MOSH_SSHD_ITEST_DIR"] else {
            throw XCTSkip("MOSH_SSHD_ITEST_DIR is not set")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/env.json"))
        return try JSONDecoder().decode(SSHTestEnvironment.self, from: data)
    }

    func server(_ name: String) throws -> Server {
        try XCTUnwrap(servers[name], "no sshd instance named \(name)")
    }

    func target(_ name: String) throws -> SSHTarget {
        SSHTarget(host: "127.0.0.1", port: try server(name).port, user: user)
    }

    /// The fingerprint of an instance's host key, as `ssh-keygen -lf` prints it.
    func hostKeyFingerprint(_ name: String) throws -> String {
        try sshKeygenFingerprint(ofFile: try server(name).hostKeyFile)
    }
}

/// The second field of `ssh-keygen -lf <file>`.
func sshKeygenFingerprint(ofFile path: String) throws -> String {
    let output = try ToolRunner.check("ssh-keygen", ["-lf", path])
    let fields = output.split(separator: " ")
    guard fields.count >= 2 else { throw ToolRunner.ToolError.failed(command: "ssh-keygen -lf", status: 0, stderr: output) }
    return String(fields[1])
}

/// Records the prompts a connection puts up and answers them from a script.
final class ScriptedInteraction: @unchecked Sendable {
    private let lock = NSLock()
    private var hostKeyPrompts: [HostKeyPrompt] = []
    private var passwordPrompts: [PasswordPrompt] = []
    private var passwords: [String?]
    private let trustHostKey: Bool

    /// - Parameters:
    ///   - trustHostKey: the answer to a first-contact question.
    ///   - passwords: the answers to the password prompts, in order; when they run out, nil.
    init(trustHostKey: Bool = true, passwords: [String?] = []) {
        self.trustHostKey = trustHostKey
        self.passwords = passwords
    }

    var hostKeyAsked: [HostKeyPrompt] {
        lock.lock()
        defer { lock.unlock() }
        return hostKeyPrompts
    }

    var passwordAsked: [PasswordPrompt] {
        lock.lock()
        defer { lock.unlock() }
        return passwordPrompts
    }

    private func answerHostKey(_ prompt: HostKeyPrompt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        hostKeyPrompts.append(prompt)
        return trustHostKey
    }

    private func answerPassword(_ prompt: PasswordPrompt) -> String? {
        lock.lock()
        defer { lock.unlock() }
        passwordPrompts.append(prompt)
        return passwords.isEmpty ? nil : passwords.removeFirst()
    }

    var interaction: SSHInteraction {
        SSHInteraction(
            confirmHostKey: { prompt in self.answerHostKey(prompt) },
            password: { prompt in self.answerPassword(prompt) })
    }
}

/// A process that keeps running while a test goes on, with its standard input held open.
final class BackgroundProcess {
    private let process = Process()
    private let input = Pipe()

    init(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        guard let executable = ToolRunner.which(tool) else { throw ToolRunner.ToolError.notFound(tool) }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
    }
}

/// Whether a process exists, and what the kernel calls it. /proc is readable for every user.
func processName(pid: Int32) -> String? {
    guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/comm") else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Polls until the condition holds or the time is up.
func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.1, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// Asserts that an async call throws the given `BootstrapError`.
func assertThrowsBootstrapError<T>(
    _ expected: BootstrapError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        let value = try await body()
        XCTFail("expected \(expected), got \(value)", file: file, line: line)
    } catch let error as BootstrapError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

/// Runs an async call that must throw a `BootstrapError` and returns it.
func bootstrapError<T>(
    file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
) async -> BootstrapError? {
    do {
        let value = try await body()
        XCTFail("expected an error, got \(value)", file: file, line: line)
    } catch let error as BootstrapError {
        return error
    } catch {
        XCTFail("expected a BootstrapError, got \(error)", file: file, line: line)
    }
    return nil
}

// XCTest's assertions take plain autoclosures, which cannot await. These evaluate the async
// expression first and then assert.

func XCTAssertEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertEqual(value, try expected(), message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNotEqual(value, try expected(), message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertTrueAsync(
    _ expression: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertTrue(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}
