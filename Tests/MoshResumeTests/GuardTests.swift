import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import MoshWire
import XCTest
@testable import MoshResume

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// The last row of the stage 1 table (docs/PLAN.md, "Verification"): what a client without the
/// guards does to the real mosh-server 1.4.0, and that the same run with the guards does not.
/// These tests break a server on purpose; each has its own. Skipped without mosh-server.
final class GuardTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

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

    private func meta(for server: MoshServerProcess) -> SessionMeta {
        SessionMeta(createdAt: UInt64(Date().timeIntervalSince1970), hostName: "localhost", address: "127.0.0.1",
                    port: server.port, serverStartSize: TerminalRemoteState.defaultServerSize, serverPID: UInt32(server.pid))
    }

    /// One session up to the point where a stale snapshot exists: saved, returned to the
    /// foreground, three more bytes sent to the server (which now holds a state with a longer
    /// input list than the snapshot's), and the process "killed". Returns the record's id.
    private func sessionWithAStaleSnapshot(root: String, server: MoshServerProcess) async throws -> SessionID {
        let key = try Base64Key(printable: server.key)
        let record = try SessionRecord.create(root: root, meta: meta(for: server), key: key)
        let session = try MoshSession(endpoint: record.meta.endpoint(key: key), initialSize: size,
                                      serverStartSize: record.meta.serverStartSize, gate: record.gate)
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await session.type(Array("echo one-$((1+1))\r".utf8))
        let shown = await wait(seconds: 10) { visibleText(of: await session.screen().framebuffer).contains("one-2") }
        XCTAssertTrue(shown)
        let settled = await wait(seconds: 10) { await session.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(settled)
        await session.quiesce()
        let clean = try record.save(try await session.exportState())
        XCTAssertTrue(clean)

        // Back in the foreground: more input reaches the server, and no new snapshot is taken.
        await session.resume()
        _ = await session.type(Array("xyz".utf8))
        await session.quiesceAfterSend()
        try await Task.sleep(nanoseconds: 300_000_000)   // the datagram arrives
        await session.close()
        record.close()
        return record.id
    }

    /// N2. A client that resumes from a snapshot although a datagram left after it sends a state
    /// whose input list is shorter than one the server already has: the server's `UserStream`
    /// assert fires and the server, with the user's shell, is gone.
    func testAResumeFromAStaleSnapshotKillsTheServer() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("guards")
        let id = try await sessionWithAStaleSnapshot(root: root, server: server)
        XCTAssertTrue(server.isAlive)

        // The broken client: it reads the stored snapshot past the dirty rule. Its numbers are
        // good (they come from the record's counters), so only the stale state is wrong.
        let record = try SessionRecord.open(root: root, id: id)
        XCTAssertEqual(record.state, .dirty)
        let stale = try XCTUnwrap(try record.store.readSnapshot())
        let session = try MoshSession(restoring: stale.snapshot, endpoint: record.meta.endpoint(key: try record.readKey()),
                                      gate: record.gate, currentSize: size)
        await session.start()
        let gone = await wait(seconds: 10) { !server.isAlive }
        XCTAssertTrue(gone, "mosh-server survived a state with a shorter input list (N2)")
        await session.close()
        record.close()
    }

    /// The same run with the guard: the record is dirty, the cold start is the fallback, nothing
    /// is sent, and the server lives.
    func testTheDirtyRuleKeepsTheServerAlive() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("guards")
        let id = try await sessionWithAStaleSnapshot(root: root, server: server)

        guard case .fallback(let fallback) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size) else {
            return XCTFail("a dirty record must not resume")
        }
        XCTAssertEqual(fallback.reason, .dirty)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(server.isAlive)
    }

    /// One hand-made first instruction to a new server, which holds only state 0.
    private func sendFirstInstruction(to server: MoshServerProcess, throwawayNum: UInt64) throws {
        let cipher = try MoshCipher(key: try Base64Key(printable: server.key))
        let message = UserMessage(instructions: [.resize(width: 80, height: 24)])
        let instruction = Instruction(oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: throwawayNum,
                                      diff: message.serialized(), chaff: Instruction.makeChaff())
        let budget = WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: budget)
        XCTAssertEqual(fragments.count, 1)
        let packet = Packet(seq: 0, direction: .toServer,
                            timestamp: Timestamp16.now(milliseconds: UInt64(Date().timeIntervalSince1970 * 1000)),
                            timestampReply: Timestamp16.none, payload: fragments[0].serialized())
        let socket = try UDPTestSocket(port: server.port)
        defer { socket.close() }
        try socket.send(try packet.encrypted(with: cipher))
    }

    /// N3. An instruction on a base the server holds, whose `throwaway_num` is above every
    /// state the server has: the server erases them all and stops at its `fatal_assert`
    /// (networktransport-impl.h, `process_throwaway_until`). The Swift sender cannot produce it:
    /// `Outbox` refuses `throwaway_num > old_num` and halts
    /// (`GateTests`, `.throwawayAboveOld`).
    func testAThrowawayNumberAboveEveryStateKillsTheServer() async throws {
        let server = try startServer()
        defer { server.stop() }
        try sendFirstInstruction(to: server, throwawayNum: 1 << 62)
        let gone = await wait(seconds: 10) { !server.isAlive }
        XCTAssertTrue(gone, "mosh-server survived throwaway_num above all its states (N3)")
    }

    /// The same instruction with `throwaway_num` at its base: the server lives.
    func testTheSameInstructionWithAThrowawayNumberAtItsBaseDoesNot() async throws {
        let server = try startServer()
        defer { server.stop() }
        try sendFirstInstruction(to: server, throwawayNum: 0)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(server.isAlive)
    }
}

#endif
