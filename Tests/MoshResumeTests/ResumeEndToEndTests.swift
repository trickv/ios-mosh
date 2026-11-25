import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// A gate that passes everything on and writes down the sequence numbers it handed out, the
/// way `moshcli --seq-log` will.
private final class LoggingGate: DurabilityGate, @unchecked Sendable {
    private let inner: any DurabilityGate
    private let lock = NSLock()
    private var log: [UInt64] = []

    init(_ inner: any DurabilityGate) { self.inner = inner }

    var sequenceNumbers: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var reservedLimits: GateCounters { inner.reservedLimits }
    func takeSequenceNumber() throws -> UInt64 {
        let number = try inner.takeSequenceNumber()
        lock.lock()
        log.append(number)
        lock.unlock()
        return number
    }
    func takeStateNumber() throws -> UInt64 { try inner.takeStateNumber() }
    func takeFragmentID() throws -> UInt64 { try inner.takeFragmentID() }
    func willSendDatagram() throws { try inner.willSendDatagram() }
    var datagramsPassed: UInt64 { inner.datagramsPassed }
    var isDirty: Bool { inner.isDirty }
    func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool { try inner.markClean(ifDatagramsPassed: expected) }
}

/// The whole path in one process, against a real mosh-server 1.4.0 on 127.0.0.1: a session
/// whose numbers come from the file-backed gate, exported to the store, everything dropped,
/// the record opened again from disk, the session continued. Skipped without mosh-server.
final class ResumeEndToEndTests: XCTestCase {
    private func startServer() throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
    }

    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func waitForRow(_ line: String, on session: MoshSession, seconds: Double = 10) async -> Bool {
        await wait(seconds: seconds) {
            visibleText(of: await session.screen().framebuffer).contains(line)
        }
    }

    private func firstScreen(of session: MoshSession) async -> ScreenUpdate? {
        for await event in session.events {
            if case .screen(let update) = event { return update }
        }
        return nil
    }

    private func meta(for server: MoshServerProcess) -> SessionMeta {
        SessionMeta(createdAt: UInt64(Date().timeIntervalSince1970), hostName: "localhost", address: "127.0.0.1",
                    port: server.port, user: NSUserName(), remoteCommand: "/bin/sh",
                    serverStartSize: TerminalRemoteState.defaultServerSize, serverPID: UInt32(server.pid))
    }

    /// Type, quiesce, store, forget everything, open the record, continue typing, see the output.
    func testASessionContinuesFromItsRecord() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("resume-e2e")
        let size = TerminalSize(width: 80, height: 24)
        let small = GateCounters(sequence: 2, state: 2, fragmentID: 2)   // several reservations in a short test

        // The first life of the session.
        let id: SessionID
        let firstLimits: GateCounters
        let firstSequenceNumbers: [UInt64]
        let storedScreen: ScreenUpdate
        do {
            let key = try Base64Key(printable: server.key)
            let record = try SessionRecord.create(root: root, meta: meta(for: server), key: key, blocks: small)
            id = record.id
            let gate = LoggingGate(record.gate)
            let session = try MoshSession(endpoint: record.meta.endpoint(key: key), initialSize: size,
                                          serverStartSize: record.meta.serverStartSize, gate: gate)
            await session.start()
            let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
            XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
            for word in ["warm", "up"] {
                _ = await session.type(Array("echo \(word)-$((1+1))\r".utf8))
                let shown = await waitForRow("\(word)-2", on: session)
                XCTAssertTrue(shown)
            }
            _ = await session.type(Array("echo before-$((2+3)); echo pid-$$\r".utf8))
            let before = await waitForRow("before-5", on: session)
            XCTAssertTrue(before)
            let settled = await wait(seconds: 10) { await session.unacknowledgedInputCount() == 0 }
            XCTAssertTrue(settled)
            XCTAssertTrue(record.gate.isDirty)
            XCTAssertThrowsError(try record.loadSnapshot(), "a record in use is not resumable") {
                XCTAssertEqual($0 as? RecordError, .notResumable(.dirty))
            }

            await session.quiesce()
            let exported = try await session.exportState()
            let clean = try record.save(exported)
            XCTAssertTrue(clean, "nothing was sent after the export")
            storedScreen = await session.screen()
            firstLimits = record.gate.reservedLimits
            firstSequenceNumbers = gate.sequenceNumbers
            XCTAssertFalse(firstSequenceNumbers.isEmpty)
            XCTAssertGreaterThan(firstLimits.sequence, 2, "the test crossed a block boundary")
            XCTAssertEqual(exported.snapshot.transport.usedCounters.sequence, firstSequenceNumbers.last! + 1)
            await session.close()
            record.close()
        }
        // Nothing of the first life is left but the directory.

        // The second life: only `root` and `id` are known.
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [id])
        let record = try SessionRecord.open(root: root, id: id, blocks: small)
        XCTAssertEqual(record.meta.port, server.port)
        XCTAssertEqual(record.meta.serverPID, UInt32(server.pid))
        guard case .clean = record.state else { return XCTFail("the record is \(record.state)") }
        let snapshot = try record.loadSnapshot()
        let gate = LoggingGate(record.gate)
        let session = try MoshSession(restoring: snapshot, endpoint: record.meta.endpoint(key: try record.readKey()),
                                      gate: gate, currentSize: size)
        async let first = firstScreen(of: session)
        try record.gate.beginSending()
        await session.start()
        let restored = await first
        XCTAssertEqual(restored?.isLive, false, "the stored screen comes first")
        XCTAssertEqual(restored?.number, storedScreen.number)
        XCTAssertEqual(restored?.state, storedScreen.state)
        XCTAssertTrue(visibleText(of: restored!.framebuffer).contains("before-5"))

        _ = await session.type(Array("echo after-$((3+4)); echo pid-$$\r".utf8))
        let after = await waitForRow("after-7", on: session)
        let rows = visibleText(of: await session.screen().framebuffer)
        XCTAssertTrue(after, "after-7 is not on the screen:\n\(rows.joined(separator: "\n"))")
        XCTAssertTrue(rows.contains("before-5"))
        // The same shell answered both times, and the same server process is alive.
        let pids = rows.filter { $0.hasPrefix("pid-") }
        XCTAssertEqual(pids.count, 2, rows.joined(separator: "\n"))
        XCTAssertEqual(Set(pids).count, 1)
        XCTAssertTrue(server.isAlive)

        // N1 across the two lives: every sequence number once, the second life above the first.
        let secondSequenceNumbers = gate.sequenceNumbers
        XCTAssertFalse(secondSequenceNumbers.isEmpty)
        XCTAssertEqual(secondSequenceNumbers.first, firstLimits.sequence, "the new life starts at the reserved limit")
        XCTAssertGreaterThan(secondSequenceNumbers.min()!, firstSequenceNumbers.max()!)
        let all = firstSequenceNumbers + secondSequenceNumbers
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(all, all.sorted())

        // In use again, so not resumable: a kill now leads to the fallback.
        XCTAssertEqual(record.state, .dirty)
        XCTAssertThrowsError(try record.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .notResumable(.dirty)) }

        // And a third life, from a second snapshot.
        let settled = await wait(seconds: 10) { await session.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(settled)
        await session.quiesce()
        let cleanAgain = try record.save(try await session.exportState())
        XCTAssertTrue(cleanAgain)
        await session.close()
        record.close()

        let third = try SessionRecord.open(root: root, id: id, blocks: small)
        let last = try MoshSession(restoring: try third.loadSnapshot(), endpoint: third.meta.endpoint(key: try third.readKey()),
                                   gate: third.gate, currentSize: TerminalSize(width: 60, height: 20))
        await last.start()
        _ = await last.type(Array("echo third-$((4+5))\r".utf8))
        let thirdRow = await waitForRow("third-9", on: last)
        XCTAssertTrue(thirdRow)
        let resized = await wait(seconds: 10) { await last.screen().framebuffer.ds.width == 60 }
        XCTAssertTrue(resized, "the changed view size reached the server")
        XCTAssertGreaterThanOrEqual(third.gate.reservedLimits.sequence, secondSequenceNumbers.max()! + 1)
        await last.close()
        third.close()
    }

    /// The other half of the dirty rule, end to end: quiesce and store, come back to the
    /// foreground in the same process, type, and die without a new snapshot. The record that is
    /// left does not resume, and its counters are still above everything that was sent.
    func testAKillAfterReturningToTheForegroundLeavesNoResumableRecord() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("resume-e2e")
        let size = TerminalSize(width: 80, height: 24)
        let key = try Base64Key(printable: server.key)
        var record: SessionRecord? = try SessionRecord.create(root: root, meta: meta(for: server), key: key)
        let id = record!.id
        let gate = LoggingGate(record!.gate)
        let session = try MoshSession(endpoint: record!.meta.endpoint(key: key), initialSize: size,
                                      serverStartSize: TerminalRemoteState.defaultServerSize, gate: gate)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await session.type(Array("echo one-$((1+1))\r".utf8))
        let one = await waitForRow("one-2", on: session)
        XCTAssertTrue(one)
        await session.quiesce()
        let exported = try await session.exportState()
        let clean = try record!.save(exported)
        XCTAssertTrue(clean)
        XCTAssertNoThrow(try record!.loadSnapshot(), "resumable while in the background")

        await session.resume()
        _ = await session.type(Array("echo two-$((2+2))\r".utf8))
        let two = await waitForRow("two-4", on: session)
        XCTAssertTrue(two)
        // A clean mark for the old export is refused now, whoever asks.
        XCTAssertThrowsError(try record!.gate.markClean(exported.cleanToken))
        XCTAssertFalse(try record!.save(exported))
        let sent = gate.sequenceNumbers
        // "Killed": no quiesce, no snapshot. (The session object is closed only to stop its socket.)
        await session.close()
        record = nil

        let reopened = try SessionRecord.open(root: root, id: id)
        XCTAssertEqual(reopened.state, .dirty)
        XCTAssertThrowsError(try reopened.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .notResumable(.dirty)) }
        XCTAssertGreaterThan(reopened.gate.reservedLimits.sequence, sent.max()!)
        XCTAssertTrue(server.isAlive, "nothing was sent that could hurt the server")
    }
}

#endif
