import Foundation
import MoshCrypto
import MoshTestSupport
import MoshWire
import XCTest
@testable import MoshTransport

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// How many of the next datagrams a `LossyTransport` must swallow.
private final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    private var total = 0

    func dropNext(_ count: Int) {
        lock.lock()
        remaining = count
        lock.unlock()
    }

    /// True if this datagram is to be dropped.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        total += 1
        return true
    }

    var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// A socket that loses the datagrams the counter tells it to.
private final class LossyTransport: DatagramTransport, @unchecked Sendable {
    private let inner: POSIXDatagramTransport
    private let counter: DropCounter

    init(port: UInt16, counter: DropCounter) throws {
        inner = try POSIXDatagramTransport(host: "127.0.0.1", port: port)
        self.counter = counter
    }

    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) { inner.start(handler: handler) }
    func send(_ datagram: [UInt8]) {
        if !counter.take() { inner.send(datagram) }
    }
    func close() { inner.close() }
}

/// The resume seams against a real mosh-server 1.4.0, in memory: quiesce, export, throw the
/// connection object away, import into a new one with a gate that starts at the old reserved
/// limits and with a new socket. These are the preconditions of M6 (docs/PLAN.md section 3);
/// `scripts/itest.sh resume-mem` runs the same variants through moshcli.
///
/// Skipped where mosh-server is not installed.
final class ResumeIntegrationTests: XCTestCase {
    private typealias Connection = MoshConnection<OpaqueRemoteState>

    /// A session that can be moved into a new connection object.
    private final class Session {
        let server: MoshServerProcess
        let key: Base64Key
        let drops = DropCounter()
        let size = TerminalSize(width: 100, height: 30)
        var gate: InMemoryGate
        var connection: Connection
        private(set) var resumes = 0

        init(command: [String]) async throws {
            guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
            server = try MoshServerProcess(command: command, environment: ["PS1": "$ ", "ENV": ""])
            key = try Base64Key(printable: server.key)
            gate = InMemoryGate()
            let port = server.port, drops = self.drops
            connection = try Connection(key: key, gate: gate, initialSize: size, makeTransport: {
                try LossyTransport(port: port, counter: drops)
            })
            await connection.start()
        }

        func type(_ text: String) async {
            let accepted = await connection.type(Array(text.utf8))
            XCTAssertTrue(accepted, "the session takes input")
        }

        func wait(seconds: Double, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return await condition()
        }

        /// The text is in the host bytes of the newest remote state.
        func sees(_ text: String, within seconds: Double) async -> Bool {
            let connection = self.connection
            return await wait(seconds: seconds) { await connection.newestRemoteState().state.hostBytesContain(text) }
        }

        /// The server has acknowledged everything typed.
        func waitAck(seconds: Double = 10) async -> Bool {
            let connection = self.connection
            return await wait(seconds: seconds) { await connection.unacknowledgedInputCount() == 0 }
        }

        /// Exports (quiescing first unless that was done), discards the connection object and
        /// continues in a new one.
        func resumeInANewObject(droppingFirst dropCount: Int = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
            if !(await connection.isQuiesced()) {
                await connection.quiesce()
            }
            let snapshot = try await connection.exportState().snapshot
            let limits = gate.reservedLimits
            let highestSent = snapshot.acknowledgedStateNumber
            await connection.close()

            // Nothing of the old connection survives but the exported value.
            weak var old = connection
            drops.dropNext(dropCount)
            let newGate = InMemoryGate(startingAt: limits)
            XCTAssertGreaterThan(newGate.reservedLimits.state, highestSent, file: file, line: line)
            let port = server.port, drops = self.drops
            connection = try Connection(restoring: snapshot, key: key, gate: newGate, currentSize: size, makeTransport: {
                try LossyTransport(port: port, counter: drops)
            })
            gate = newGate
            for _ in 0..<200 where old != nil {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNil(old, "the old connection object is gone", file: file, line: line)
            await connection.start()
            resumes += 1
        }

        func end() async {
            await connection.close()
            server.stop()
        }
    }

    /// Waits until the file has the wanted content (cat writes each line as it gets it).
    private func fileBecomes(_ path: String, _ expected: String, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.contents(atPath: path) == Data(expected.utf8) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FileManager.default.contents(atPath: path) == Data(expected.utf8)
    }

    private func temporaryFile(_ name: String) -> String {
        let path = NSTemporaryDirectory() + "/mosh-resume-\(ProcessInfo.processInfo.processIdentifier)-\(name)"
        try? FileManager.default.removeItem(atPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// Connect, type a marker, wait for the ack, quiesce, export, discard, import, type a second
    /// marker: its echo arrives within 5 s and the server is the same process.
    func testResumeInANewObjectContinuesTheSession() async throws {
        let session = try await Session(command: ["/bin/sh"])
        let prompt = await session.sees("$ ", within: 10)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        let pid = session.server.pid
        await session.type("echo first-$((20+1))\r")
        let first = await session.sees("first-21", within: 10)
        XCTAssertTrue(first)
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)

        try await session.resumeInANewObject()
        await session.type("echo second-$((40+2))\r")
        let second = await session.sees("second-42", within: 5)
        XCTAssertTrue(second, "the second marker did not come back within 5 s of the resume")
        XCTAssertEqual(session.server.pid, pid)
        XCTAssertTrue(session.server.isAlive, "the same mosh-server process is alive")
        await session.end()
    }

    /// Input that was typed but not acknowledged when the session was quiesced, whether it had
    /// been sent or not, reaches the server exactly once. The server runs `cat > file`; the tty is
    /// in cooked mode, so every `\r` typed is a `\n` in the file.
    func testUnacknowledgedInputReachesTheServerExactlyOnce() async throws {
        let path = temporaryFile("exactly-once.txt")
        let session = try await Session(command: ["/bin/sh", "-c", "cat > '\(path)'"])

        await session.type("line-1 acknowledged\r")
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)

        // Typed and quiesced at once: nothing was sent.
        let sentBefore = await session.connection.datagramsSent()
        await session.type("line-2 typed and not sent\r")
        await session.connection.quiesce()
        let sentAfter = await session.connection.datagramsSent()
        XCTAssertEqual(sentAfter, sentBefore, "the line was still waiting for the send timer")
        try await session.resumeInANewObject()

        // Sent by the timer; the ack may or may not have arrived.
        await session.type("line-3 sent, perhaps not acknowledged\r")
        try await Task.sleep(nanoseconds: 4_000_000)
        try await session.resumeInANewObject()

        // Sent for certain, the answer never read.
        await session.type("line-4 sent, the answer never read\r")
        let before = await session.connection.datagramsSent()
        await session.connection.quiesceAfterSend()
        let after = await session.connection.datagramsSent()
        XCTAssertGreaterThan(after, before, "quiesceAfterSend sent the line")
        let pending = await session.connection.unacknowledgedInputCount()
        XCTAssertGreaterThan(pending, 0, "and did not read the acknowledgment")
        try await session.resumeInANewObject()

        // The same, and the first datagram of the resume is lost.
        await session.type("line-5 sent, then the first datagram of the resume is lost\r")
        await session.connection.quiesceAfterSend()
        try await session.resumeInANewObject(droppingFirst: 1)

        // Two resumes with nothing in between.
        await session.type("line-6 two resumes in a row\r")
        await session.connection.quiesceAfterSend()
        try await session.resumeInANewObject()
        try await session.resumeInANewObject()

        await session.type("line-7 the last\r")
        let all = await session.waitAck()
        XCTAssertTrue(all, "everything typed was acknowledged")
        XCTAssertEqual(session.drops.dropped, 1)

        let expected = """
            line-1 acknowledged
            line-2 typed and not sent
            line-3 sent, perhaps not acknowledged
            line-4 sent, the answer never read
            line-5 sent, then the first datagram of the resume is lost
            line-6 two resumes in a row
            line-7 the last

            """
        let equal = await fileBecomes(path, expected)
        XCTAssertTrue(equal, "the server's file is not the typed lines, each once")
        if !equal {
            let got = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? "(no file)"
            XCTFail("file: \(got.prefix(600))")
        }
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }

    /// `quiesceAfterSend` with a shell: the command runs once, although the client offers its
    /// input a second time after the resume.
    func testACommandSentBeforeQuiesceRunsOnceAfterTheResume() async throws {
        let path = temporaryFile("runs-once.txt")
        let session = try await Session(command: ["/bin/sh"])
        let prompt = await session.sees("$ ", within: 10)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await session.type("echo up-$((1+1))\r")
        let up = await session.sees("up-2", within: 10)
        XCTAssertTrue(up)

        await session.type("echo ran >> '\(path)'; echo done-$((2+2))\r")
        await session.connection.quiesceAfterSend()
        try await session.resumeInANewObject()
        let done = await session.sees("done-4", within: 5)
        XCTAssertTrue(done, "the output of the command sent before the quiesce arrives after the resume")
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)
        let once = await fileBecomes(path, "ran\n")
        XCTAssertTrue(once, "the command ran exactly once")
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }

    /// A paste that needs several datagrams (it does not compress), sent and not acknowledged at
    /// quiesce time; the first fragment of the resume's second offer is lost.
    func testAPasteLargerThanOneDatagramSurvivesAResume() async throws {
        let path = temporaryFile("paste.txt")
        let session = try await Session(command: ["/bin/sh", "-c", "cat > '\(path)'"])
        await session.type("start\r")
        let started = await session.waitAck()
        XCTAssertTrue(started)

        // 100 lines of 80 letters from a fixed generator: about 8 KB that zlib cannot shrink
        // below one datagram.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        var paste = ""
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")
        for _ in 0..<100 {
            for _ in 0..<80 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                paste.append(alphabet[Int(seed >> 58)])
            }
            paste.append("\r")
        }
        let before = await session.connection.datagramsSent()
        await session.type(paste)
        await session.connection.quiesceAfterSend()
        let after = await session.connection.datagramsSent()
        XCTAssertGreaterThan(after - before, 2, "the paste took several datagrams")

        try await session.resumeInANewObject(droppingFirst: 1)
        await session.type("end\r")
        let acknowledged = await session.waitAck(seconds: 20)
        XCTAssertTrue(acknowledged, "the paste and the line after it were acknowledged")
        let expected = "start\n" + paste.replacingOccurrences(of: "\r", with: "\n") + "end\n"
        let equal = await fileBecomes(path, expected)
        XCTAssertTrue(equal, "the server's file is the paste, once")
        if !equal {
            let got = FileManager.default.contents(atPath: path) ?? Data()
            XCTFail("the file has \(got.count) bytes, expected \(expected.utf8.count)")
        }
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }

    /// The first datagram after the resume is lost: the transport must try again soon enough
    /// for the echo to arrive within 5 s.
    func testResumeWhoseFirstDatagramIsLost() async throws {
        let session = try await Session(command: ["/bin/sh"])
        let prompt = await session.sees("$ ", within: 10)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await session.type("echo first-$((20+1))\r")
        let first = await session.sees("first-21", within: 10)
        XCTAssertTrue(first)
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)

        // With nothing pending the lost datagram is an empty ack...
        try await session.resumeInANewObject(droppingFirst: 1)
        await session.type("echo second-$((40+2))\r")
        let second = await session.sees("second-42", within: 5)
        XCTAssertTrue(second)

        // ...and with input pending it is the one that carries the input.
        await session.type("echo third-$((60+3))\r")
        try await session.resumeInANewObject(droppingFirst: 1)
        let third = await session.sees("third-63", within: 5)
        XCTAssertTrue(third, "input whose first datagram was lost came back within 5 s")
        XCTAssertEqual(session.drops.dropped, 2)
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }

    /// After 40 s without a datagram mosh-server forgets the client's address
    /// (`SERVER_ASSOCIATION_TIMEOUT`, network.h) and stops sending. The first datagram of the
    /// resume attaches it again.
    func testResumeAfterTheServersAssociationTimeout() async throws {
        let session = try await Session(command: ["/bin/sh"])
        let prompt = await session.sees("$ ", within: 10)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        await session.type("echo before-$((20+1))\r")
        let before = await session.sees("before-21", within: 10)
        XCTAssertTrue(before)
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)

        await session.connection.quiesce()
        try await Task.sleep(nanoseconds: 42_000_000_000)
        try await session.resumeInANewObject()
        await session.type("echo after-$((40+2))\r")
        let after = await session.sees("after-42", within: 5)
        XCTAssertTrue(after, "the marker did not come back within 5 s of a resume after 42 s of silence")
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }

    /// Twenty resumes in one session, each into a new object with a gate one block higher.
    func testTwentyResumesInARow() async throws {
        let path = temporaryFile("twenty.txt")
        let session = try await Session(command: ["/bin/sh"])
        let prompt = await session.sees("$ ", within: 10)
        XCTAssertTrue(prompt, "the shell's first prompt arrived before the first line")
        let pid = session.server.pid
        var expected = ""
        for round in 1...20 {
            await session.type("echo r\(round) >> '\(path)'; echo round-\(round)-$((\(round)*3))\r")
            expected += "r\(round)\n"
            if round % 2 == 0 {
                let acknowledged = await session.waitAck()
                XCTAssertTrue(acknowledged)
            }
            if round % 5 == 0 {
                await session.connection.quiesceAfterSend()
            }
            try await session.resumeInANewObject()
            let seen = await session.sees("round-\(round)-\(round * 3)", within: 5)
            XCTAssertTrue(seen, "round \(round): no echo within 5 s of the resume")
            if !seen { break }
        }
        XCTAssertEqual(session.resumes, 20)
        let acknowledged = await session.waitAck()
        XCTAssertTrue(acknowledged)
        let equal = await fileBecomes(path, expected)
        XCTAssertTrue(equal, "every command ran exactly once")
        XCTAssertEqual(session.gate.reservedLimits.state, 1 + 21 * 1024, "one block of state numbers per connection object")
        XCTAssertEqual(session.server.pid, pid)
        XCTAssertTrue(session.server.isAlive)
        await session.end()
    }
}

#endif
