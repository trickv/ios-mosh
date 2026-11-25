import Foundation
import MoshCrypto
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshSession

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// Review finding B-6 (docs/notes/review-resume/refutation.md): the transport's part of a
/// snapshot is taken on the connection's actor and the clipboard policy is read on the
/// session's. If a state with a new clipboard had reached the connection but not yet the
/// policy, the snapshot paired a screen that has the copy with a policy that had not seen it:
/// the live process then wrote the pasteboard, and after a kill the restored session wrote the
/// same copy again at its start, over whatever the user had copied since.
final class ExportClipboardTests: XCTestCase {
    private static let copied = Array("Y29waWVkIQ==".unicodeScalars.map(\.value)) // "copied!"

    /// Holds whoever awaits `wait()` until `open()`.
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = true
        private var waiting = 0
        func close() { lock.lock(); isOpen = false; lock.unlock() }
        func open() { lock.lock(); isOpen = true; lock.unlock() }
        var held: Int { lock.lock(); defer { lock.unlock() }; return waiting }
        private func check() -> Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
        private func count(_ delta: Int) { lock.lock(); waiting += delta; lock.unlock() }
        func wait() async {
            if check() { return }
            count(1)
            while !check() { try? await Task.sleep(nanoseconds: 5_000_000) }
            count(-1)
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SessionEvent] = []
        private var task: Task<Void, Never>?
        init(_ events: AsyncStream<SessionEvent>) {
            task = Task { [weak self] in
                for await event in events { self?.append(event) }
            }
        }
        private func append(_ event: SessionEvent) { lock.lock(); stored.append(event); lock.unlock() }
        var clipboard: [ClipboardPolicy.Decision] {
            lock.lock()
            defer { lock.unlock() }
            return stored.compactMap { if case .clipboard(let decision) = $0 { return decision } else { return nil } }
        }
        var screenNumbers: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return stored.compactMap { if case .screen(let update) = $0 { return update.number } else { return nil } }
        }
    }

    private final class NullTransport: DatagramTransport, @unchecked Sendable {
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {}
        func close() {}
    }

    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testACopyThatArrivesRightBeforeTheSaveIsWrittenOnceNotAgainAfterARestore() async throws {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        let server = try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
        defer { server.stop() }
        let endpoint = SessionEndpoint(host: "127.0.0.1", port: server.port, key: try Base64Key(printable: server.key))
        let gate = InMemoryGate()
        let session = try MoshSession(endpoint: endpoint, initialSize: TerminalSize(width: 80, height: 24),
                                      serverStartSize: TerminalRemoteState.defaultServerSize, gate: gate)
        let log = EventLog(session.events)
        let barrier = Barrier()
        await session.setBeforeEventForTesting { await barrier.wait() }
        await session.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleRows(await session.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await session.type(Array("echo ready-$((1+1))\r".utf8))
        let ready = await wait(seconds: 10) { visibleRows(await session.screen().framebuffer).contains("ready-2") }
        XCTAssertTrue(ready)
        let quiet = await wait(seconds: 10) { await session.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(quiet)
        XCTAssertEqual(log.clipboard, [])

        // From here the session's reader is held: the connection goes on receiving, the policy
        // sees nothing. The host copies.
        barrier.close()
        _ = await session.type(Array("printf '\\033]52;c;Y29waWVkIQ==\\a'\r".utf8))
        let arrived = await wait(seconds: 10) { await session.screen().framebuffer.clipboard == Self.copied }
        XCTAssertTrue(arrived, "the copy never reached the connection")
        let policyBefore = await session.clipboardPolicy()
        XCTAssertNotEqual(policyBefore.lastSeen, Self.copied, "the reader was not held: the test shows nothing")

        // The save.
        await session.quiesce()
        let exported = try await session.exportState()
        XCTAssertEqual(exported.snapshot.transport.remoteStates.last?.state.framebuffer.clipboard, Self.copied)
        XCTAssertEqual(exported.snapshot.clipboard.lastSeen, Self.copied,
                       "the stored policy has not seen the clipboard of the stored screen")

        // The process lives on for a moment: the held events are handled.
        barrier.open()
        let handled = await wait(seconds: 5) { barrier.held == 0 && log.clipboard.count >= 1 }
        XCTAssertTrue(handled)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.clipboard, [.write(text: "copied!", byteCount: 7)], "written once by the live process")
        let numbers = log.screenNumbers
        XCTAssertEqual(numbers, Array(Set(numbers)).sorted(), "a screen was reported twice or out of order")
        await session.close()

        // Killed and restored from that snapshot: the copy is not written a second time.
        let limits = gate.reservedLimits
        let restored = try MoshSession(restoring: exported.snapshot, endpoint: endpoint,
                                       gate: InMemoryGate(startingAt: limits), currentSize: nil,
                                       makeTransport: { NullTransport() })
        await restored.start()
        await restored.close()
        var again: [ClipboardPolicy.Decision] = []
        for await event in restored.events {
            if case .clipboard(let decision) = event { again.append(decision) }
        }
        XCTAssertEqual(again, [], "the restored session wrote the pasteboard again")
    }
}

private func visibleRows(_ framebuffer: Framebuffer) -> [String] {
    visibleText(of: framebuffer)
}

#endif
