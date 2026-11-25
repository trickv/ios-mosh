import Foundation
import MoshCrypto
import MoshTestSupport
import MoshWire
import XCTest
@testable import MoshTransport

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// Collects the events of a connection for a test to look at.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ConnectionEvent] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<ConnectionEvent>) {
        task = Task { [weak self] in
            for await event in events {
                self?.append(event)
            }
        }
    }

    private func append(_ event: ConnectionEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [ConnectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func contains(_ event: TransportEvent) -> Bool {
        events.contains(.transport(event))
    }

    var problems: [ConnectionEvent] {
        events.filter {
            switch $0 {
            case .transport(.internalError), .transport(.baseStateLost), .transport(.peerProtocolError), .transport(.gateFailed):
                return true
            default:
                return false
            }
        }
    }
}

/// `MoshConnection` with `POSIXDatagramTransport` against a real mosh-server 1.4.0.
/// Skipped where mosh-server is not installed.
final class ConnectionIntegrationTests: XCTestCase {
    private typealias Connection = MoshConnection<OpaqueRemoteState>

    private func startServer() throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
    }

    private func connect(to server: MoshServerProcess, gate: any DurabilityGate = InMemoryGate()) throws -> Connection {
        let port = server.port
        return try Connection(
            key: try Base64Key(printable: server.key),
            gate: gate,
            initialSize: TerminalSize(width: 100, height: 30),
            makeTransport: { try POSIXDatagramTransport(host: "127.0.0.1", port: port) }
        )
    }

    /// Polls until `condition` holds or the time is up.
    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func waitForText(_ text: String, on connection: Connection, seconds: Double = 10) async -> Bool {
        await wait(seconds: seconds) { await connection.newestRemoteState().state.hostBytesContain(text) }
    }

    /// M2's exit test: type `echo hello-$((6*7))` and Enter, find `hello-42` in the host bytes
    /// within 10 s.
    func testTypedCommandComesBackAsHostBytes() async throws {
        let server = try startServer()
        defer { server.stop() }
        let connection = try connect(to: server)
        let log = EventLog(connection.events)
        await connection.start()
        let prompt = await waitForText("$ ", on: connection)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")

        let typed = await connection.type(Array("echo hello-$((6*7))\r".utf8))
        XCTAssertTrue(typed)
        let found = await waitForText("hello-42", on: connection)
        XCTAssertTrue(found, "hello-42 did not arrive within 10 s")

        let newest = await connection.newestRemoteState()
        XCTAssertGreaterThan(newest.number, 0)
        XCTAssertEqual(newest.state.size, TerminalSize(width: 100, height: 30), "the server took our size")
        XCTAssertTrue(log.events.contains { if case .transport(.remoteStateAdvanced) = $0 { return true } else { return false } })
        XCTAssertTrue(log.events.contains { if case .contact = $0 { return true } else { return false } })
        XCTAssertEqual(log.problems, [])
        let ages = await connection.contactAges()
        XCTAssertLessThan(ages.sinceNewestRemoteState, 10_000)
        XCTAssertNotNil(ages.sinceLastAuthenticDatagram)
        let srtt = await connection.smoothedRoundTripTime()
        XCTAssertLessThan(srtt, 500, "a loopback round trip was measured")
        XCTAssertTrue(server.isAlive)
        await connection.close()
    }

    /// A new socket (new source port): the server follows, the session stays.
    func testSocketReplacementKeepsTheSession() async throws {
        let server = try startServer()
        defer { server.stop() }
        let connection = try connect(to: server)
        let log = EventLog(connection.events)
        await connection.start()
        let prompt = await waitForText("$ ", on: connection)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await connection.type(Array("echo first-$((1+1))\r".utf8))
        let first = await waitForText("first-2", on: connection)
        XCTAssertTrue(first)

        for round in 1...3 {
            await connection.replaceSocket()
            await connection.type(Array("echo round\(round)-$((\(round)*100))\r".utf8))
            let found = await waitForText("round\(round)-\(round * 100)", on: connection)
            XCTAssertTrue(found, "round \(round)")
        }
        XCTAssertEqual(log.problems, [])
        XCTAssertTrue(server.isAlive)
        await connection.close()
    }

    /// quiesce, export, and a new connection object from the snapshot with a gate that starts at
    /// the old limits: the same server carries on, in both shapes of the plan's step 5.
    func testExportAndImportContinueTheSessionOnTheSameServer() async throws {
        let server = try startServer()
        defer { server.stop() }
        let key = try Base64Key(printable: server.key)
        let port = server.port
        var gate = InMemoryGate()
        var connection = try connect(to: server, gate: gate)
        await connection.start()
        let prompt = await waitForText("$ ", on: connection)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await connection.type(Array("V=kept-$((5*5)); echo $V\r".utf8))
        let before = await waitForText("kept-25", on: connection)
        XCTAssertTrue(before)

        for round in 1...2 {
            // Leave: nothing pending in round 1; in round 2 a command is typed after the quiesce,
            // so it is in the snapshot but was never sent.
            try await Task.sleep(nanoseconds: 300_000_000)
            await connection.quiesce()
            if round == 2 {
                await connection.type(Array("echo pending-$((7*7))\r".utf8))
            }
            let exported = try await connection.exportState()
            let snapshot = exported.snapshot
            let sent = await connection.datagramsSent()
            XCTAssertTrue(try gate.markClean(exported.cleanToken))
            XCTAssertEqual(snapshot.pendingInput.isEmpty, round == 1)
            await connection.close()
            let after = await connection.datagramsSent()
            XCTAssertEqual(after, sent, "nothing was sent after the quiesce")

            // "A new process": a new gate from the old limits, a new connection from the snapshot.
            let limits = gate.reservedLimits
            gate = InMemoryGate(startingAt: limits, dirty: false)
            connection = try Connection(
                restoring: snapshot,
                key: key,
                gate: gate,
                currentSize: TerminalSize(width: 100, height: 30),
                makeTransport: { try POSIXDatagramTransport(host: "127.0.0.1", port: port) }
            )
            let log = EventLog(connection.events)
            await connection.start()
            if round == 2 {
                let pending = await waitForText("pending-49", on: connection)
                XCTAssertTrue(pending, "the input from the snapshot reached the shell")
            }
            // The shell variable proves it is the same shell.
            await connection.type(Array("echo round\(round)-$V\r".utf8))
            let found = await waitForText("round\(round)-kept-25", on: connection)
            XCTAssertTrue(found, "round \(round)")
            XCTAssertEqual(log.problems, [], "round \(round)")
            XCTAssertTrue(gate.isDirty)
            XCTAssertTrue(server.isAlive)
        }
        await connection.close()
    }

    /// The shell exits: the server announces the end, we acknowledge, the server leaves.
    func testServerShutdownIsReportedAndAcknowledged() async throws {
        let server = try startServer()
        defer { server.stop() }
        let connection = try connect(to: server)
        let log = EventLog(connection.events)
        await connection.start()
        let prompt = await waitForText("$ ", on: connection)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await connection.type(Array("echo up-$((2*2))\r".utf8))
        let up = await waitForText("up-4", on: connection)
        XCTAssertTrue(up)

        await connection.type(Array("exit\r".utf8))
        let acknowledged = await wait(seconds: 10) { log.contains(.serverShutdownAcknowledged) }
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(log.contains(.serverShutdown))
        let gone = await wait(seconds: 5) { !server.isAlive }
        XCTAssertTrue(gone, "the server exits once it has our acknowledgment")
        let refused = await connection.type([0x61])
        XCTAssertFalse(refused)
        XCTAssertEqual(log.problems, [])
        await connection.close()
    }

    /// We end the session: the server acknowledges and exits.
    func testClientShutdownIsAcknowledged() async throws {
        let server = try startServer()
        defer { server.stop() }
        let connection = try connect(to: server)
        let log = EventLog(connection.events)
        await connection.start()
        let prompt = await waitForText("$ ", on: connection)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await connection.type(Array("echo up-$((3*3))\r".utf8))
        let up = await waitForText("up-9", on: connection)
        XCTAssertTrue(up)

        await connection.shutdown()
        let acknowledged = await wait(seconds: 10) { log.contains(.shutdownAcknowledged) }
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(log.contains(.shutdownTimedOut))
        let gone = await wait(seconds: 5) { !server.isAlive }
        XCTAssertTrue(gone)
        XCTAssertEqual(log.problems, [])
        await connection.close()
    }

    func testPOSIXTransportTakesNumericAddressesOnly() throws {
        XCTAssertEqual(try POSIXDatagramTransport(host: "127.0.0.1", port: 60001).family, .ipv4)
        XCTAssertThrowsError(try POSIXDatagramTransport(host: "localhost", port: 60001)) { error in
            XCTAssertEqual(error as? DatagramTransportError, .notANumericAddress("localhost"))
        }
        XCTAssertThrowsError(try POSIXDatagramTransport(host: "", port: 60001))
        do {
            let transport = try POSIXDatagramTransport(host: "::1", port: 60001)
            XCTAssertEqual(transport.family, .ipv6)
        } catch DatagramTransportError.system {
            // No IPv6 in this container.
        }
    }

    /// Two transports talking to each other through a plain UDP socket's port.
    func testPOSIXTransportSendsAndReceives() async throws {
        // A bound socket to learn a free port from: UDPTestSocket connects, so use a transport
        // pair around a server that echoes. mosh-server is not needed; the kernel's loopback is.
        let listener = try UDPEcho()
        defer { listener.stop() }
        let transport = try POSIXDatagramTransport(host: "127.0.0.1", port: listener.port)
        let received = EventBox()
        transport.start { event in
            received.append(event)
        }
        transport.send([1, 2, 3])
        transport.send(Array(repeating: 7, count: 1252))
        let arrived = await wait(seconds: 5) { received.events.count >= 2 }
        XCTAssertTrue(arrived)
        // (No XCTAssertEqual on the datagrams: a failure would print 1252 numbers.)
        let events = received.events
        XCTAssertTrue(events.first == .received([1, 2, 3]), "the first datagram came back")
        XCTAssertTrue(events.dropFirst().first == .received(Array(repeating: 7, count: 1252)), "a full-size datagram came back")
        transport.close()
        transport.send([4]) // ignored after close
        transport.close()
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DatagramTransportEvent] = []

    func append(_ event: DatagramTransportEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [DatagramTransportEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// A UDP socket on 127.0.0.1 that sends every datagram back to where it came from.
final class UDPEcho: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let thread: Thread

    init(port requested: UInt16 = 0) throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw DatagramTransportError.system(operation: "socket", code: errno) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { throw DatagramTransportError.system(operation: "bind", code: errno) }
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = fd
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Thread.current.isCancelled {
                var from = sockaddr_storage()
                var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { source in
                        recvfrom(fd, &buffer, buffer.count, 0, source, &fromLength)
                    }
                }
                guard count > 0 else { continue }
                _ = withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                        sendto(fd, buffer, count, 0, target, fromLength)
                    }
                }
            }
            close(fd)
        }
        thread.start()
    }

    func stop() {
        thread.cancel()
    }
}

#endif
