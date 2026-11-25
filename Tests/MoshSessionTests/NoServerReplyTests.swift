import Foundation
import MoshBootstrap
import MoshCrypto
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshSession

#if canImport(Glibc) || canImport(Musl) || canImport(Darwin)

/// The error row "`MOSH CONNECT` seen, no UDP reply in 15 s" (docs/PLAN.md section 4): a
/// `MOSH CONNECT` line points at a UDP port on 127.0.0.1 that reads every datagram and answers
/// none. The timeout is shortened; the rule is the same.
final class NoServerReplyTests: XCTestCase {
    private func events(_ session: MoshSession) -> EventCollector { EventCollector(session.events) }

    /// A bootstrap result as `SSHBootstrap` would hand it over, from the server's lines.
    private func bootstrapResult(port: UInt16) throws -> BootstrapResult {
        let key = Base64Key.random().printable
        var parser = ConnectLineParser()
        parser.feed("\r\nMOSH CONNECT \(port) \(key)\r\n\r\nmosh-server (mosh 1.4.0) [build mosh 1.4.0]\r\n"
            + "[mosh-server detached, pid = 4242]\r\n")
        parser.finish()
        let connect = try XCTUnwrap(parser.connect)
        return BootstrapResult(remoteAddress: "127.0.0.1", udpPort: connect.port, sessionKey: connect.key,
                               serverPID: parser.serverPID, serverStartTime: nil, loginMethod: .password,
                               serverOutput: parser.text)
    }

    func testSilentServerRaisesUDPBlockedAfterTheTimeout() async throws {
        let sink = try UDPSink()
        defer { sink.stop() }
        let session = try MoshSession(bootstrap: try bootstrapResult(port: sink.port),
                                      initialSize: TerminalSize(width: 80, height: 24), noReplyTimeout: 600)
        let log = events(session)
        let started = Date()
        await session.start()

        let raised = await log.wait(seconds: 10) { $0.contains(.noServerReply(.udpBlocked(port: Int(sink.port)))) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(raised, "no .noServerReply; events: \(log.events)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.6, "not before the timeout")
        XCTAssertGreaterThan(sink.received, 0, "the client did send to the port")
        let number = await session.screen().number
        XCTAssertEqual(number, 0)
        XCTAssertEqual(BootstrapError.udpBlocked(port: Int(sink.port)).message,
                       "The server started, but no reply arrived on UDP port \(sink.port) within 15 seconds. UDP is blocked.")
        // Reported once.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(log.events.filter { $0 == .noServerReply(.udpBlocked(port: Int(sink.port))) }.count, 1)
        await session.close()
    }

    func testDefaultTimeoutIsMoshs15Seconds() {
        XCTAssertEqual(MoshSession.defaultNoReplyTimeout, 15_000)
    }

    /// Time spent quiesced does not count: the wait starts again at resume.
    func testQuiescedTimeDoesNotCount() async throws {
        let sink = try UDPSink()
        defer { sink.stop() }
        let session = try MoshSession(bootstrap: try bootstrapResult(port: sink.port),
                                      initialSize: TerminalSize(width: 80, height: 24), noReplyTimeout: 500)
        let log = events(session)
        await session.start()
        await session.quiesce()
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertFalse(log.events.contains { if case .noServerReply = $0 { return true } else { return false } },
                       "reported while quiesced")
        await session.resume()
        let raised = await log.wait(seconds: 10) { events in
            events.contains { if case .noServerReply = $0 { return true } else { return false } }
        }
        XCTAssertTrue(raised)
        await session.close()
    }

    /// nil turns the rule off.
    func testNoTimeoutNeverReports() async throws {
        let sink = try UDPSink()
        defer { sink.stop() }
        let session = try MoshSession(bootstrap: try bootstrapResult(port: sink.port),
                                      initialSize: TerminalSize(width: 80, height: 24), noReplyTimeout: nil)
        let log = events(session)
        await session.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(log.events.contains { if case .noServerReply = $0 { return true } else { return false } })
        await session.close()
    }

    #if os(Linux) || os(macOS)
    /// A server that answers is never reported, even with a short timeout.
    func testAnsweringServerIsNotReported() async throws {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        let server = try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
        defer { server.stop() }
        let session = try MoshSession(
            endpoint: SessionEndpoint(host: "127.0.0.1", port: server.port, key: try Base64Key(printable: server.key)),
            initialSize: TerminalSize(width: 80, height: 24),
            serverStartSize: TerminalRemoteState.defaultServerSize, noReplyTimeout: 3000)
        let log = events(session)
        await session.start()
        let screen = await log.wait(seconds: 10) { $0.contains { if case .screen = $0 { return true } else { return false } } }
        XCTAssertTrue(screen)
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertFalse(log.events.contains { if case .noServerReply = $0 { return true } else { return false } })
        await session.close()
    }
    #endif
}

/// Collects a session's events.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionEvent] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await event in events { self?.append(event) }
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

    func wait(seconds: Double, _ condition: ([SessionEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(events) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition(events)
    }
}

#endif
