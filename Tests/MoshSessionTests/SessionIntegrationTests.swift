import Foundation
import MoshCrypto
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshSession

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// Collects a session's events for a test.
private final class SessionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionEvent] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await event in events {
                self?.append(event)
            }
        }
    }

    private func append(_ event: SessionEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [SessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var screens: [ScreenUpdate] {
        events.compactMap { if case .screen(let update) = $0 { return update } else { return nil } }
    }

    var problems: [SessionEvent] {
        events.filter {
            switch $0 {
            case .halted, .baseStateLost, .protocolProblem, .gateFailed: return true
            default: return false
            }
        }
    }
}

/// `MoshSession` against a real mosh-server 1.4.0 on 127.0.0.1. Skipped where mosh-server is
/// not installed.
final class SessionIntegrationTests: XCTestCase {
    private func startServer() throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
    }

    private func endpoint(_ server: MoshServerProcess) throws -> SessionEndpoint {
        SessionEndpoint(host: "127.0.0.1", port: server.port, key: try Base64Key(printable: server.key))
    }

    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Whether a row of the session's screen is exactly `line` (trailing blanks aside).
    private func waitForRow(_ line: String, on session: MoshSession, seconds: Double = 10) async -> Bool {
        await wait(seconds: seconds) {
            visibleText(of: await session.screen().framebuffer).contains(line)
        }
    }

    private func screenDump(_ session: MoshSession) async -> String {
        visibleText(of: await session.screen().framebuffer).joined(separator: "\n")
    }

    /// The exit test: connect, type a command, see its output as a row of the screen.
    /// The server runs without a tty, so its state 0 is 80x24; the client's view is 100x30.
    func testTypedCommandAppearsOnTheScreen() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try MoshSession(
            endpoint: try endpoint(server),
            initialSize: TerminalSize(width: 100, height: 30),
            serverStartSize: TerminalRemoteState.defaultServerSize
        )
        let log = SessionEventLog(session.events)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")

        let typed = await session.type(Array("echo hi-$((6*7))\r".utf8))
        XCTAssertTrue(typed)
        let found = await waitForRow("hi-42", on: session)
        let dump = await screenDump(session)
        XCTAssertTrue(found, "hi-42 is not a row of the screen:\n\(dump)")
        let rows = visibleText(of: await session.screen().framebuffer)
        XCTAssertTrue(rows.contains { $0.hasPrefix("$ echo hi-$((6*7))") }, "the command line is on the screen:\n\(dump)")

        let screen = await session.screen()
        XCTAssertEqual(screen.framebuffer.ds.width, 100)
        XCTAssertEqual(screen.framebuffer.ds.height, 30)
        // The server acknowledges the echo of a client state 50 ms after it applied it
        // (ECHO_TIMEOUT, completeterminal.h), in a later state of its own.
        let echoAcked = await wait(seconds: 5) { await session.screen().state.echoAck > 0 }
        XCTAssertTrue(echoAcked, "the server acknowledged the echo of our input")
        XCTAssertFalse(log.screens.isEmpty)
        XCTAssertTrue(log.screens.allSatisfy { $0.isLive })
        XCTAssertEqual(log.screens.map(\.number), log.screens.map(\.number).sorted(), "screens arrive in order")
        XCTAssertEqual(Set(log.screens.map(\.number)).count, log.screens.count, "each screen once")
        XCTAssertTrue(log.events.contains { if case .contact = $0 { return true } else { return false } })
        XCTAssertEqual(log.problems, [])
        let ages = await session.contactAges()
        XCTAssertLessThan(ages.sinceNewestRemoteState, 10_000)
        await session.close()
    }

    /// A line typed at once, before the shell has started. mosh-server releases the shell when
    /// the first datagram arrives (mosh-server.cc:593, :822); `start()` sends that datagram
    /// itself, so this line follows in the next one, about 20 ms later, and races the shell's
    /// start-up. Either may win: under load the tty echoes the line before the prompt and dash
    /// prints "$ once-42" on one row; otherwise the prompt comes first. What must hold either way:
    /// the line runs exactly once, its output is on the screen, no problem is reported. The view
    /// is the server's start size (80x24), whose small first reply leaves the shortest gap.
    func testACommandTypedBeforeThePromptRunsOnce() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try MoshSession(endpoint: try endpoint(server), initialSize: TerminalSize(width: 80, height: 24),
                                      serverStartSize: TerminalRemoteState.defaultServerSize)
        let log = SessionEventLog(session.events)
        await session.start()
        let typed = await session.type(Array("echo once-$((6*7))\r".utf8))
        XCTAssertTrue(typed)
        // The output, in whichever row: a row that ends with it and is not the echoed command.
        let output: @Sendable ([String]) -> Int = { rows in
            rows.filter { $0.hasSuffix("once-42") && !$0.contains("echo") }.count
        }
        let found = await wait(seconds: 10) { output(visibleText(of: await session.screen().framebuffer)) > 0 }
        let firstDump = await screenDump(session)
        XCTAssertTrue(found, "once-42 is not on the screen:\n\(firstDump)")
        // A second line, after the shell has answered the first: once it ran, a repeat of the
        // first line would be on the screen as well.
        let prompt = await wait(seconds: 10) { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        let promptDump = await screenDump(session)
        XCTAssertTrue(prompt, "the prompt after the first line:\n\(promptDump)")
        _ = await session.type(Array("echo done-$((1+1))\r".utf8))
        let done = await waitForRow("done-2", on: session)
        let dump = await screenDump(session)
        XCTAssertTrue(done, "done-2 is not a row of the screen:\n\(dump)")
        let count = output(visibleText(of: await session.screen().framebuffer))
        XCTAssertEqual(count, 1, "the line ran exactly once:\n\(dump)")
        XCTAssertEqual(log.problems, [])
        XCTAssertTrue(server.isAlive)
        await session.close()
    }

    /// Resize: the server redraws at the new size.
    func testResizeReachesTheScreen() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try MoshSession(endpoint: try endpoint(server), initialSize: TerminalSize(width: 80, height: 24),
                                      serverStartSize: TerminalRemoteState.defaultServerSize)
        let log = SessionEventLog(session.events)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await session.type(Array("echo first-$((1+1))\r".utf8))
        let first = await waitForRow("first-2", on: session)
        XCTAssertTrue(first)

        await session.resize(TerminalSize(width: 50, height: 12))
        let resized = await wait(seconds: 10) {
            let fb = await session.screen().framebuffer
            return fb.ds.width == 50 && fb.ds.height == 12
        }
        XCTAssertTrue(resized)
        _ = await session.type(Array("stty size\r".utf8))
        let size = await waitForRow("12 50", on: session)
        let dump = await screenDump(session)
        XCTAssertTrue(size, "the shell sees the new size:\n\(dump)")
        XCTAssertEqual(log.problems, [])
        await session.close()
    }

    /// OSC 52 from the shell arrives as a clipboard event.
    func testOSC52BecomesAClipboardWrite() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try MoshSession(endpoint: try endpoint(server), initialSize: TerminalSize(width: 80, height: 24),
                                      serverStartSize: TerminalRemoteState.defaultServerSize)
        let log = SessionEventLog(session.events)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        // base64 of "copied!" is Y29waWVkIQ==; printf builds the sequence so that the echo of
        // the command line does not contain it.
        _ = await session.type(Array("printf '\\033]52;c;%s\\007' Y29waWVkIQ==\r".utf8))
        let written = await wait(seconds: 10) {
            log.events.contains(.clipboard(.write(text: "copied!", byteCount: 7)))
        }
        XCTAssertTrue(written, "events: \(log.events.filter { if case .clipboard = $0 { return true } else { return false } })")
        await session.close()
    }

    /// Quiesce, export, import into a new object, continue: the first screen of the new object
    /// is the stored one (not live), then typing works on the same server.
    func testExportAndImportContinueTheSession() async throws {
        let server = try startServer()
        defer { server.stop() }
        let endpoint = try endpoint(server)
        let gate = InMemoryGate()
        let old = try MoshSession(endpoint: endpoint, initialSize: TerminalSize(width: 80, height: 24),
                                  serverStartSize: TerminalRemoteState.defaultServerSize, gate: gate)
        let oldLog = SessionEventLog(old.events)
        await old.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await old.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await old.type(Array("echo before-$((2+3))\r".utf8))
        let before = await waitForRow("before-5", on: old)
        XCTAssertTrue(before)
        let settled = await wait(seconds: 10) { await old.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(settled)

        await old.quiesce()
        let snapshot = try await old.exportState().snapshot
        let oldScreen = await old.screen()
        await old.close()
        XCTAssertEqual(oldLog.problems, [])

        let session = try MoshSession(restoring: snapshot, endpoint: endpoint,
                                      gate: InMemoryGate(startingAt: gate.reservedLimits),
                                      currentSize: TerminalSize(width: 80, height: 24))
        let log = SessionEventLog(session.events)
        await session.start()
        let first = log.screens.first
        XCTAssertEqual(first?.isLive, false, "the restored screen comes first and is not live")
        XCTAssertEqual(first?.number, oldScreen.number)
        XCTAssertEqual(first?.state, oldScreen.state)

        _ = await session.type(Array("echo after-$((3+4))\r".utf8))
        let after = await waitForRow("after-7", on: session)
        let dump = await screenDump(session)
        XCTAssertTrue(after, "after-7 is not on the screen:\n\(dump)")
        let rows = visibleText(of: await session.screen().framebuffer)
        XCTAssertTrue(rows.contains("before-5"), dump)
        XCTAssertTrue(log.screens.dropFirst().allSatisfy { $0.isLive })
        XCTAssertEqual(log.problems, [])
        XCTAssertTrue(server.isAlive)
        await session.close()
    }

    /// The shell exits: the server ends the session and says so.
    func testServerEndIsReported() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try MoshSession(endpoint: try endpoint(server), initialSize: TerminalSize(width: 80, height: 24),
                                      serverStartSize: TerminalRemoteState.defaultServerSize)
        let log = SessionEventLog(session.events)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await session.type(Array("echo bye\r".utf8))
        let bye = await waitForRow("bye", on: session)
        XCTAssertTrue(bye)
        _ = await session.type(Array("exit\r".utf8))
        let ended = await wait(seconds: 15) {
            log.events.contains { if case .serverEnded = $0 { return true } else { return false } }
        }
        XCTAssertTrue(ended, "no serverEnded; events: \(log.events.suffix(5))")
        XCTAssertEqual(log.problems, [])
        await session.close()
    }
}

#endif
