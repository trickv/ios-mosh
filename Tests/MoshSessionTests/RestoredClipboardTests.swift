import MoshCrypto
import MoshTerminal
import MoshTransport
import MoshWire
import XCTest
@testable import MoshSession

/// Finding M10 of docs/notes/review-transport/refutation.md: the clipboard policy is exported on
/// the session actor and the transport snapshot on the connection actor, so the stored policy
/// can be one state behind the stored screen. mosh sends an OSC 52 only when the field changes
/// (terminaldisplay.cc:113-122), so a copy that the restore swallows never comes again.
final class RestoredClipboardTests: XCTestCase {
    /// A socket that sends nowhere.
    private final class NullTransport: DatagramTransport, @unchecked Sendable {
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {}
        func close() {}
    }

    private static let copied = Array("Y29waWVkIQ==".unicodeScalars.map(\.value)) // "copied!"

    /// A snapshot whose newest remote state (number 5) has "copied!" in its clipboard field.
    private func snapshot(policy: ClipboardPolicy) throws -> SessionSnapshot {
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 80, height: 24))
        try state.apply(diff: HostMessage(instructions: [.hostBytes(Array("prompt$ \u{1B}]52;c;Y29waWVkIQ==\u{07}".utf8))]).serialized())
        XCTAssertEqual(state.framebuffer.clipboard, Self.copied)
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 3,
            pendingInput: [],
            remoteStates: [NumberedRemoteState(number: 5, state: state)],
            highestAckSent: 5,
            terminalSize: TerminalSize(width: 80, height: 24),
            usedCounters: GateCounters(sequence: 10, state: 4, fragmentID: 10),
            receiverExpectedSequence: 10
        )
        return SessionSnapshot(transport: transport, clipboard: policy)
    }

    /// Restores, starts, closes, and returns every event up to the close.
    private func eventsOfARestoredStart(_ snapshot: SessionSnapshot) async throws -> ([SessionEvent], ClipboardPolicy) {
        let endpoint = SessionEndpoint(host: "127.0.0.1", port: 9, key: Base64Key.random())
        let session = try MoshSession(
            restoring: snapshot,
            endpoint: endpoint,
            gate: InMemoryGate(startingAt: GateCounters(sequence: 100, state: 100, fragmentID: 100)),
            currentSize: nil,
            makeTransport: { NullTransport() }
        )
        await session.start()
        let policy = await session.clipboardPolicy()
        await session.close()
        var events: [SessionEvent] = []
        for await event in session.events {
            events.append(event)
        }
        return (events, policy)
    }

    private func clipboardEvents(_ events: [SessionEvent]) -> [ClipboardPolicy.Decision] {
        events.compactMap { if case .clipboard(let decision) = $0 { return decision } else { return nil } }
    }

    /// The policy saw the state before the copy; the stored screen has it: written at the restore.
    func testAClipboardThePolicyHadNotSeenIsWrittenAtTheRestore() async throws {
        for behind in [ClipboardPolicy(), ClipboardPolicy(lastSeen: []), ClipboardPolicy(lastSeen: Array("b2xk".unicodeScalars.map(\.value)))] {
            let (events, policy) = try await eventsOfARestoredStart(try snapshot(policy: behind))
            guard case .screen(let screen)? = events.first else { return XCTFail("\(events)") }
            XCTAssertFalse(screen.isLive, "the stored screen is still a repaint")
            XCTAssertEqual(screen.number, 5)
            XCTAssertEqual(clipboardEvents(events), [.write(text: "copied!", byteCount: 7)])
            XCTAssertEqual(policy.lastSeen, Self.copied)
            XCTAssertEqual(policy.lastWrittenHash, ClipboardPolicy.fnv1a64(Array("copied!".utf8)))
        }
    }

    /// Control: the policy had seen the stored state. Nothing is written a second time.
    func testAClipboardThePolicyHadSeenIsNotWrittenAgain() async throws {
        let seen = ClipboardPolicy(lastSeen: Self.copied, lastWrittenHash: ClipboardPolicy.fnv1a64(Array("copied!".utf8)))
        let (events, policy) = try await eventsOfARestoredStart(try snapshot(policy: seen))
        XCTAssertEqual(clipboardEvents(events), [])
        XCTAssertEqual(policy, seen)
        XCTAssertEqual(events.count, 1, "\(events)")
    }

    /// The hash check still stops a double write (PLAN section 3, cold start step 7), and the
    /// per-host switch still applies.
    func testTheHashAndTheSwitchStillApplyAtTheRestore() async throws {
        let written = ClipboardPolicy(lastSeen: [], lastWrittenHash: ClipboardPolicy.fnv1a64(Array("copied!".utf8)))
        let (events, policy) = try await eventsOfARestoredStart(try snapshot(policy: written))
        XCTAssertEqual(clipboardEvents(events), [])
        XCTAssertEqual(policy.lastSeen, Self.copied)

        let off = ClipboardPolicy(isEnabled: false, lastSeen: [])
        let (offEvents, offPolicy) = try await eventsOfARestoredStart(try snapshot(policy: off))
        XCTAssertEqual(clipboardEvents(offEvents), [])
        XCTAssertNil(offPolicy.lastWrittenHash)
    }
}
