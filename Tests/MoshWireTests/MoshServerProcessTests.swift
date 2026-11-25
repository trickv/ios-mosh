import XCTest
import MoshCrypto
@testable import MoshTestSupport

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// The shared mosh-server helper itself. Skipped where mosh-server is not installed.
final class MoshServerProcessTests: XCTestCase {
    private func requireServer() throws {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
    }

    func testStartExposesPortKeyAndPidAndStopKills() throws {
        try requireServer()
        let server = try MoshServerProcess()
        defer { server.stop() }

        // Without -p the server takes a port from mosh's range (PORT_RANGE_LOW ... PORT_RANGE_HIGH).
        XCTAssertTrue((60001...60999).contains(server.port), "port \(server.port)")
        XCTAssertEqual(server.key.utf8.count, 22)
        XCTAssertNoThrow(try Base64Key(printable: server.key))
        XCTAssertGreaterThan(server.pid, 1)
        XCTAssertTrue(server.isAlive)

        server.stop()
        XCTAssertFalse(server.isAlive)
        server.stop() // a second call does nothing
        XCTAssertFalse(server.isAlive)
    }

    func testExplicitPortAndCommand() throws {
        try requireServer()
        let server = try MoshServerProcess(port: "60777", command: ["/bin/sh", "-c", "sleep 30"])
        defer { server.stop() }
        XCTAssertEqual(server.port, 60777)
        XCTAssertTrue(server.isAlive)

        // A port range: the server takes a port inside it, and not the one that is taken.
        let second = try MoshServerProcess(port: "60777:60779")
        defer { second.stop() }
        XCTAssertTrue((60778...60779).contains(second.port), "port \(second.port)")
        XCTAssertNotEqual(second.key, server.key)
        XCTAssertNotEqual(second.pid, server.pid)
    }

    func testStartFailuresAreReported() throws {
        try requireServer()
        XCTAssertThrowsError(try MoshServerProcess(port: "99999999")) { error in
            guard case MoshServerProcess.StartError.failed(let status, let output) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(output.contains("Bad UDP port range"), output)
        }
        // mosh-server insists on a UTF-8 locale.
        XCTAssertThrowsError(try MoshServerProcess(locale: "C")) { error in
            guard case MoshServerProcess.StartError.failed(_, let output) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(output.contains("UTF-8"), output)
        }
    }

    func testMissingBinaryIsReported() {
        XCTAssertThrowsError(try MoshServerProcess(executable: "/nonexistent/mosh-server")) { error in
            guard case MoshServerProcess.StartError.failed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testParsing() {
        let output = "MOSH CONNECT 60001 0X1+nYp85u/oewZKZlm3cQ\n"
        XCTAssertEqual(MoshServerProcess.parseConnectLine(output)?.port, 60001)
        XCTAssertEqual(MoshServerProcess.parseConnectLine(output)?.key, "0X1+nYp85u/oewZKZlm3cQ")
        // As it looks through a pty: blank lines and carriage returns around it.
        let viaTerminal = "\r\n\r\nMOSH CONNECT 60999 AAAAAAAAAAAAAAAAAAAAAA\r\n"
        XCTAssertEqual(MoshServerProcess.parseConnectLine(viaTerminal)?.port, 60999)
        XCTAssertEqual(MoshServerProcess.parseConnectLine(viaTerminal)?.key, "AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertNil(MoshServerProcess.parseConnectLine(""))
        XCTAssertNil(MoshServerProcess.parseConnectLine("MOSH CONNECT 60001\n"))
        XCTAssertNil(MoshServerProcess.parseConnectLine("MOSH CONNECT 99999 AAAAAAAAAAAAAAAAAAAAAA\n"))
        XCTAssertNil(MoshServerProcess.parseConnectLine("MOSH CONNECT 60001 tooshort\n"))
        XCTAssertNil(MoshServerProcess.parseConnectLine("mosh-server: Bad UDP port range (x)\n"))

        let banner = """

            mosh-server (mosh 1.4.0) [build mosh 1.4.0]
            Copyright 2012 Keith Winstein <mosh-devel@mit.edu>

            [mosh-server detached, pid = 4711]

            """
        XCTAssertEqual(MoshServerProcess.parseDetachedPid(banner), 4711)
        XCTAssertNil(MoshServerProcess.parseDetachedPid("[mosh-server detached, pid = "))
        XCTAssertNil(MoshServerProcess.parseDetachedPid("no pid here"))
        XCTAssertNil(MoshServerProcess.parseDetachedPid("[mosh-server detached, pid = abc]"))
    }
}

#endif
