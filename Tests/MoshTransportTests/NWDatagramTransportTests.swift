import Foundation
import MoshCrypto
#if canImport(Network)
import Network
#endif
import MoshTestSupport
import XCTest
@testable import MoshTransport

// NWDatagramTransport exists where Network.framework does; the helpers (UDPEcho, EventBox,
// EventLog, MoshServerProcess) on macOS.
#if canImport(Network) && os(macOS)

/// `NWDatagramTransport` against a local UDP echo and against a real mosh-server, with the same
/// checks as the POSIX transport's tests in `ConnectionIntegrationTests`.
final class NWDatagramTransportTests: XCTestCase {
    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testTakesNumericAddressesOnly() throws {
        XCTAssertEqual(try NWDatagramTransport(host: "127.0.0.1", port: 60001).family, .ipv4)
        XCTAssertEqual(try NWDatagramTransport(host: "::1", port: 60001).family, .ipv6)
        XCTAssertEqual(try NWDatagramTransport(host: "fe80::1%lo0", port: 60001).family, .ipv6)
        XCTAssertEqual(try NWDatagramTransport(host: "::ffff:127.0.0.1", port: 60001).family, .ipv6)
        for host in ["localhost", "", "example.com", "127.0.0.1:60001", "[::1]", " 127.0.0.1"] {
            XCTAssertThrowsError(try NWDatagramTransport(host: host, port: 60001), host) { error in
                XCTAssertEqual(error as? DatagramTransportError, .notANumericAddress(host))
            }
        }
    }

    func testSendsAndReceives() async throws {
        let listener = try UDPEcho()
        defer { listener.stop() }
        let transport = try NWDatagramTransport(host: "127.0.0.1", port: listener.port)
        let received = EventBox()
        transport.start { event in
            received.append(event)
        }
        // Sent at once after start, before the connection is ready: these must not be lost.
        transport.send([1, 2, 3])
        transport.send(Array(repeating: 7, count: 1252))
        let arrived = await wait(seconds: 5) { received.events.count >= 2 }
        XCTAssertTrue(arrived)
        let events = received.events
        XCTAssertTrue(events.first == .received([1, 2, 3]), "the first datagram came back")
        XCTAssertTrue(events.dropFirst().first == .received(Array(repeating: 7, count: 1252)), "a full-size datagram came back")
        transport.close()
        transport.send([4]) // ignored after close
        transport.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(received.events.count, 2, "nothing after close")
    }

    func testIPv6LoopbackSendsAndReceives() async throws {
        // A transport to itself is not possible; an NWListener on ::1 echoes instead.
        let echo = try IPv6Echo()
        defer { echo.stop() }
        let port = try await echo.waitForPort()
        let transport = try NWDatagramTransport(host: "::1", port: port)
        let received = EventBox()
        transport.start { received.append($0) }
        transport.send([6, 6])
        let arrived = await wait(seconds: 5) { received.events.contains(.received([6, 6])) }
        XCTAssertTrue(arrived, "events: \(received.events)")
        transport.close()
    }

    /// A datagram larger than any path takes is reported as too long (EMSGSIZE), as `sendto`'s
    /// error is by the POSIX transport, and the transport keeps working.
    func testOversizedDatagramIsReportedAsTooLong() async throws {
        let listener = try UDPEcho()
        defer { listener.stop() }
        let transport = try NWDatagramTransport(host: "127.0.0.1", port: listener.port)
        let received = EventBox()
        transport.start { received.append($0) }
        transport.send(Array(repeating: 1, count: 70_000))
        let reported = await wait(seconds: 5) { received.events.contains(.messageTooLong) }
        XCTAssertTrue(reported, "events: \(received.events)")
        transport.send([9])
        let echoed = await wait(seconds: 5) { received.events.contains(.received([9])) }
        XCTAssertTrue(echoed)
        transport.close()
    }

    /// Datagrams to a closed port draw ICMP "port unreachable" (ECONNREFUSED on a connected
    /// socket). That is not the end of the transport: no `.unusable`, and once something
    /// listens on the port, datagrams flow.
    func testRefusedDatagramsDoNotKillTheTransport() async throws {
        let port = try freeUDPPort()
        let transport = try NWDatagramTransport(host: "127.0.0.1", port: port)
        let received = EventBox()
        transport.start { received.append($0) }
        for _ in 0..<5 {
            transport.send([1])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let listener = try UDPEcho(port: port)
        defer { listener.stop() }
        let echoed = await wait(seconds: 5) {
            transport.send([2])
            return received.events.contains(.received([2]))
        }
        XCTAssertTrue(echoed, "events: \(received.events)")
        XCTAssertFalse(received.events.contains { if case .unusable = $0 { return true } else { return false } })
        transport.close()
    }

    /// The decision behind the bound on receive errors: the first few in a row are followed by
    /// a new receive at once, later ones by a pause, and a datagram starts the count again.
    func testReceiveRearmDelay() {
        XCTAssertEqual(NWDatagramTransport.receiveRearmDelay(consecutiveErrors: 0), 0, "after a datagram")
        for errors in 1...NWDatagramTransport.immediateReceiveRetries {
            XCTAssertEqual(NWDatagramTransport.receiveRearmDelay(consecutiveErrors: errors), 0, "\(errors)")
        }
        for errors in [NWDatagramTransport.immediateReceiveRetries + 1, 10, 1_000_000, Int.max] {
            XCTAssertEqual(NWDatagramTransport.receiveRearmDelay(consecutiveErrors: errors),
                           NWDatagramTransport.receiveRetryDelayMilliseconds, "\(errors)")
        }
        XCTAssertGreaterThanOrEqual(NWDatagramTransport.receiveRetryDelayMilliseconds, 50, "a pause, not a spin")
        XCTAssertLessThanOrEqual(NWDatagramTransport.receiveRetryDelayMilliseconds, 500, "datagrams must not wait long")
    }

    /// Many refused datagrams in a row: the process does not spin meanwhile, the transport
    /// still receives afterwards, nothing arrives after close, and the transport goes away.
    ///
    /// On macOS 26 loopback the ICMP errors do not complete `receiveMessage` with an error (seen
    /// with a counter: none in this test), so the paused retry itself is not reached here; its
    /// decision is tested in `testReceiveRearmDelay`. This test guards the normal path around it.
    func testRefusedDatagramsNeitherSpinNorStopReception() async throws {
        let port = try freeUDPPort()
        var transport: NWDatagramTransport? = try NWDatagramTransport(host: "127.0.0.1", port: port)
        weak let weakTransport = transport
        let received = EventBox()
        transport?.start { received.append($0) }

        let cpuBefore = processCPUSeconds()
        let wallBefore = Date()
        for _ in 0..<30 {
            transport?.send([1])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cpu = processCPUSeconds() - cpuBefore
        let wall = Date().timeIntervalSince(wallBefore)
        XCTAssertLessThan(cpu, wall * 0.5, "CPU \(cpu) s in \(wall) s: a receive loop is spinning")

        let listener = try UDPEcho(port: port)
        defer { listener.stop() }
        let echoed = await wait(seconds: 5) { [transport] in
            transport?.send([2])
            return received.events.contains(.received([2]))
        }
        XCTAssertTrue(echoed, "events: \(received.events)")
        XCTAssertFalse(received.events.contains { if case .unusable = $0 { return true } else { return false } })

        transport?.close()
        let count = received.events.count
        transport = nil
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(received.events.count, count, "nothing after close")
        XCTAssertNil(weakTransport, "the transport goes away on its own")
    }

    // MARK: With mosh-server

    private func startServer() throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
    }

    /// M2's exit test and the socket replacement test of `ConnectionIntegrationTests`, with
    /// this transport: `hello-42` arrives, and three new sockets (new source ports) keep the
    /// session.
    func testMoshSessionOverNetworkFramework() async throws {
        let server = try startServer()
        defer { server.stop() }
        let port = server.port
        let connection = try MoshConnection<OpaqueRemoteState>(
            key: try Base64Key(printable: server.key),
            gate: InMemoryGate(),
            initialSize: TerminalSize(width: 100, height: 30),
            makeTransport: { try NWDatagramTransport(host: "127.0.0.1", port: port) }
        )
        let log = EventLog(connection.events)
        await connection.start()
        let prompt = await wait(seconds: 10) { await connection.newestRemoteState().state.hostBytesContain("$ ") }
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")

        await connection.type(Array("echo hello-$((6*7))\r".utf8))
        let found = await wait(seconds: 10) { await connection.newestRemoteState().state.hostBytesContain("hello-42") }
        XCTAssertTrue(found, "hello-42 did not arrive within 10 s")

        for round in 1...3 {
            await connection.replaceSocket()
            await connection.type(Array("echo round\(round)-$((\(round)*100))\r".utf8))
            let text = "round\(round)-\(round * 100)"
            let arrived = await wait(seconds: 10) { await connection.newestRemoteState().state.hostBytesContain(text) }
            XCTAssertTrue(arrived, "round \(round)")
        }
        XCTAssertEqual(log.problems, [])
        XCTAssertFalse(log.events.contains { if case .networkError = $0 { return true } else { return false } },
                       "events: \(log.events.filter { if case .networkError = $0 { return true } else { return false } })")
        XCTAssertTrue(server.isAlive)
        await connection.close()
    }
}

/// User and system CPU time of this process so far, in seconds.
private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// A port on 127.0.0.1 that nothing listens on (bound once, then closed).
private func freeUDPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw DatagramTransportError.system(operation: "socket", code: errno) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard bound == 0 else { throw DatagramTransportError.system(operation: "bind", code: errno) }
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

/// A UDP echo on [::1] made with NWListener.
private final class IPv6Echo: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ipv6-echo")

    init() throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv6(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            func loop() {
                connection.receiveMessage { data, _, _, error in
                    if let data { connection.send(content: data, completion: .idempotent) }
                    if error == nil { loop() }
                }
            }
            loop()
        }
        listener.start(queue: queue)
    }

    func waitForPort() async throws -> UInt16 {
        for _ in 0..<250 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("no IPv6 loopback listener")
    }

    func stop() {
        listener.cancel()
    }
}

#endif
