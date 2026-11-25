import Foundation
import MoshCrypto
import MoshTestSupport
import MoshTransport
import MoshWire
import XCTest
@testable import MoshSession
@testable import MoshTerminal

/// Local echo's wiring in `MoshSession` (docs/notes/m10/DESIGN.md 4 and 7.4): the engine is
/// fed as stmclient feeds it, its frame reaches the app only as `.display`, and no prediction
/// ever reaches `.screen`, `screen()` or a snapshot. Exactness of the engine is the
/// differential test's job (MoshTerminalTests); these tests run against a real mosh-server.
///
/// A fresh engine draws nothing in its first epoch (terminaloverlay.h:76, 298-299;
/// terminaloverlay.cc:51-53, 147-149), so a test that needs a guess drawn first has one key
/// echoed and waits until the engine confirmed it (`confirmEpoch`).
final class PredictionWiringTests: XCTestCase {
    /// Collects a session's events.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SessionEvent] = []
        private var task: Task<Void, Never>?
        init(_ events: AsyncStream<SessionEvent>) {
            task = Task { [weak self] in
                for await event in events { self?.append(event) }
            }
        }
        private func append(_ event: SessionEvent) { lock.lock(); stored.append(event); lock.unlock() }
        var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return stored }
        var displays: [DisplayFrame] {
            events.compactMap { if case .display(let frame) = $0 { return frame } else { return nil } }
        }
        var screens: [ScreenUpdate] {
            events.compactMap { if case .screen(let update) = $0 { return update } else { return nil } }
        }
        var serverEnded: Bool {
            events.contains { if case .serverEnded = $0 { return true } else { return false } }
        }
    }

    /// Holds whoever awaits `wait()` until `open()`.
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = true
        func close() { lock.lock(); isOpen = false; lock.unlock() }
        func open() { lock.lock(); isOpen = true; lock.unlock() }
        private func check() -> Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
        func wait() async {
            while !check() { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    /// A socket that sends nowhere.
    private final class NullTransport: DatagramTransport, @unchecked Sendable {
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {}
        func close() {}
    }

    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func text(_ framebuffer: Framebuffer) -> String {
        visibleText(of: framebuffer).joined(separator: "\n")
    }

    #if os(Linux) || os(macOS)

    private func startServer(_ command: [String] = ["/bin/sh"]) throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: command, environment: ["PS1": "$ ", "ENV": ""])
    }

    /// A session to `server` whose datagrams are held `delayMs` each way (0: a plain socket).
    private func makeSession(_ server: MoshServerProcess, prediction: PredictionSettings, delayMs: Int = 0,
                             box: TransportBox = TransportBox()) throws -> MoshSession {
        let port = server.port
        return try MoshSession(
            endpoint: SessionEndpoint(host: "127.0.0.1", port: port, key: try Base64Key(printable: server.key)),
            initialSize: TerminalSize(width: 80, height: 24),
            serverStartSize: TerminalRemoteState.defaultServerSize,
            prediction: prediction,
            makeTransport: {
                let transport = try DelayingTransport(host: "127.0.0.1", port: port, delayMs: delayMs)
                box.transport = transport
                return transport
            }
        )
    }

    private func waitForPrompt(_ session: MoshSession) async -> Bool {
        await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await session.screen().framebuffer)) }
    }

    /// Types `key`, which the server echoes, and waits until the engine confirmed its epoch
    /// (the echo ack comes in a later state, 50 ms after the server applied the input,
    /// completeterminal.cc:130-158), so that later guesses are drawn.
    private func confirmEpoch(_ session: MoshSession, key: String = "e") async -> Bool {
        _ = await session.type(Array(key.utf8))
        return await wait(seconds: 10) { await session.predictionEngineForTesting().confirmedEpoch >= 1 }
    }

    /// (1) Display `never`: no `.display` event at all, the session as before.
    func testNeverSendsNoDisplayEvent() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: .off)
        let log = Log(session.events)
        await session.start()
        let v1 = await waitForPrompt(session)
        XCTAssertTrue(v1)
        _ = await session.type(Array("echo nev-$((2+3))\r".utf8))
        let found = await wait(seconds: 10) { visibleText(of: await session.screen().framebuffer).contains("nev-5") }
        XCTAssertTrue(found)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.displays, [])
        let shown = await session.displayedScreen()
        let v2 = await session.screen().framebuffer
        XCTAssertEqual(text(shown), text(v2), "the shown frame is the remote one")
        await session.close()
    }

    /// (2) `always` over a 300 ms round trip, epoch confirmed: a typed character is in a
    /// `.display` before any `.screen` shows it, and once echoed the last `.display` is the
    /// remote frame.
    func testATypedCharacterIsDisplayedBeforeItsEcho() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always), delayMs: 150)
        let log = Log(session.events)
        await session.start()
        let v3 = await waitForPrompt(session)
        XCTAssertTrue(v3)
        let v4 = await confirmEpoch(session)
        XCTAssertTrue(v4, "the first key's epoch was never confirmed")

        _ = await session.type(Array("q".utf8))
        let v5 = await session.displayedScreen()
        XCTAssertTrue(text(v5).contains("$ eq"), "the guess is not shown at once")
        let v6 = await session.screen().framebuffer
        XCTAssertFalse(text(v6).contains("$ eq"))
        let echoed = await wait(seconds: 5) { text(await session.screen().framebuffer).contains("$ eq") }
        XCTAssertTrue(echoed)
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = log.events
        let firstDisplay = events.firstIndex {
            if case .display(let f) = $0 { return text(f.framebuffer).contains("$ eq") } else { return false }
        }
        let firstScreen = events.firstIndex {
            if case .screen(let u) = $0 { return text(u.framebuffer).contains("$ eq") } else { return false }
        }
        let d = try XCTUnwrap(firstDisplay, "no display holds the guess")
        let s = try XCTUnwrap(firstScreen)
        XCTAssertLessThan(d, s, "the guess was displayed only after its echo")
        if case .display(let f) = events[d] { XCTAssertTrue(f.hasPredictions) }
        let settled = await wait(seconds: 5) {
            await session.displayedScreen() == (await session.screen().framebuffer)
        }
        XCTAssertTrue(settled, "a guess is still drawn after its echo")
        try await Task.sleep(nanoseconds: 100_000_000)
        let last = try XCTUnwrap(log.displays.last)
        XCTAssertFalse(last.hasPredictions)
        XCTAssertEqual(log.displays.map(\.serial), Array(1...UInt64(log.displays.count)), "serials count up from 1")
        await session.close()
    }

    /// (3) Every `.screen` from the reader is followed by a `.display` of the same number, also
    /// for a state that changes only the echo ack; three keys typed within one round trip are
    /// on every state's last `.display` until they are echoed.
    func testEveryScreenIsFollowedByItsDisplay() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always), delayMs: 150)
        let log = Log(session.events)
        await session.start()
        let v7 = await waitForPrompt(session)
        XCTAssertTrue(v7)
        let v8 = await confirmEpoch(session, key: "#")
        XCTAssertTrue(v8)
        try await Task.sleep(nanoseconds: 400_000_000)
        let from = await session.screen().number
        for key in ["x", "y", "z"] {
            _ = await session.type(Array(key.utf8))
        }
        let echoed = await wait(seconds: 5) { text(await session.screen().framebuffer).contains("$ #xyz") }
        XCTAssertTrue(echoed)
        _ = await wait(seconds: 3) { await session.displayedScreen() == (await session.screen().framebuffer) }
        try await Task.sleep(nanoseconds: 100_000_000)

        let events = log.events
        for (index, event) in events.enumerated() {
            guard case .screen(let update) = event else { continue }
            let rest = events[(index + 1)...]
            let next = rest.first { if case .display = $0 { return true }; if case .screen = $0 { return true }; return false }
            guard case .display(let frame)? = next else {
                XCTFail("screen \(update.number) is not followed by a display"); continue
            }
            XCTAssertEqual(frame.number, update.number)
        }
        var lastOfState: [UInt64: DisplayFrame] = [:]
        for frame in log.displays where frame.number > from { lastOfState[frame.number] = frame }
        XCTAssertFalse(lastOfState.isEmpty)
        for (number, frame) in lastOfState {
            XCTAssertTrue(text(frame.framebuffer).contains("$ #xyz"), "state \(number): \(text(frame.framebuffer))")
        }
        await session.close()
    }

    /// (4) A program that echoes only its first byte: the guesses after it are shown, but
    /// never reach `screen()` or the exported snapshot.
    func testAGuessNeverReachesTheRemoteScreenOrTheSnapshot() async throws {
        let server = try startServer(["/bin/sh", "-c", "stty raw -echo; dd bs=1 count=1 2>/dev/null; cat >/dev/null"])
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always))
        await session.start()
        let alive = await wait(seconds: 10) { await session.screen().number > 0 }
        XCTAssertTrue(alive)
        try await Task.sleep(nanoseconds: 700_000_000)  // the program has run stty
        let v9 = await confirmEpoch(session, key: "x")
        XCTAssertTrue(v9, "the one echoed byte was not confirmed")
        _ = await session.type(Array("abc".utf8))
        let shown = await session.displayedScreen()
        XCTAssertTrue(text(shown).contains("xabc"), "the guesses are not shown:\n\(text(shown))")
        let v10 = await session.screen().framebuffer
        XCTAssertFalse(text(v10).contains("abc"))

        await session.quiesce()
        let exported = try await session.exportState()
        let stored = try XCTUnwrap(exported.snapshot.transport.remoteStates.last)
        XCTAssertFalse(text(stored.state.framebuffer).contains("abc"), "a guess reached the snapshot")
        let v11 = await session.screen().framebuffer
        XCTAssertFalse(text(v11).contains("abc"), "a guess reached screen()")
        await session.close()
    }

    /// (5) A resize resets the engine: no guess is drawn after it.
    func testAResizeDropsTheGuesses() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always), delayMs: 150)
        let log = Log(session.events)
        await session.start()
        let v12 = await waitForPrompt(session)
        XCTAssertTrue(v12)
        let v13 = await confirmEpoch(session)
        XCTAssertTrue(v13)
        _ = await session.type(Array("w".utf8))
        let drawn = await wait(seconds: 1) { log.displays.last?.hasPredictions == true }
        XCTAssertTrue(drawn, "the guess was not drawn")
        _ = await session.resize(TerminalSize(width: 90, height: 24))
        try await Task.sleep(nanoseconds: 100_000_000)
        let last = try XCTUnwrap(log.displays.last)
        XCTAssertFalse(last.hasPredictions, "a guess is drawn after the resize")
        let v14 = await session.predictionEngineForTesting().isActive
        XCTAssertFalse(v14)
        await session.close()
    }

    /// (8) Inbound datagrams dropped for 6 s while a guess is pending with flagging on: the
    /// 250 ms timer keeps culling, so the guess's age reaches 5000 ms and sets glitch_trigger
    /// to 20 (terminaloverlay.cc:576-586), as mosh's loop passes do during a stall.
    func testAStallRaisesTheGlitchTriggerTo20() async throws {
        let server = try startServer()
        defer { server.stop() }
        let box = TransportBox()
        let session = try makeSession(server, prediction: PredictionSettings(display: .adaptive), delayMs: 100, box: box)
        await session.start()
        let v15 = await waitForPrompt(session)
        XCTAssertTrue(v15)
        let v16 = await confirmEpoch(session)
        XCTAssertTrue(v16)
        let flagging = await wait(seconds: 5) { await session.predictionEngineForTesting().flagging }
        XCTAssertTrue(flagging, "a 200 ms round trip should turn flagging on")

        box.transport?.dropsInbound = true
        _ = await session.type(Array("g".utf8))
        let raised = await wait(seconds: 8) { await session.predictionEngineForTesting().glitchTrigger == 20 }
        let engine = await session.predictionEngineForTesting()
        XCTAssertTrue(raised, "glitch_trigger \(engine.glitchTrigger) after the stall")
        box.transport?.dropsInbound = false
        let recovered = await wait(seconds: 10) { text(await session.screen().framebuffer).contains("$ eg") }
        XCTAssertTrue(recovered)
        let v17 = await session.predictionEngineForTesting().glitchTrigger
        XCTAssertEqual(v17, 20,
                       "an old guess confirmed late does not lower the trigger")
        await session.close()
    }

    /// (9) The session's reader held while the connection goes on and an export reports the
    /// newest screen first: `.screen` and `.display` numbers never go down.
    func testNumbersNeverGoDownAcrossAnExport() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always))
        let log = Log(session.events)
        let barrier = Barrier()
        await session.setBeforeEventForTesting { await barrier.wait() }
        await session.start()
        let v18 = await waitForPrompt(session)
        XCTAssertTrue(v18)
        barrier.close()
        _ = await session.type(Array("echo held-$((3*3))\r".utf8))
        let arrived = await wait(seconds: 10) { text(await session.screen().framebuffer).contains("held-9") }
        XCTAssertTrue(arrived)
        await session.quiesce()
        _ = try await session.exportState()
        barrier.open()
        await session.resume()
        _ = await session.type(Array("echo after\r".utf8))
        _ = await wait(seconds: 10) { text(await session.screen().framebuffer).contains("\nafter") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let screens = log.screens.map(\.number)
        XCTAssertEqual(screens, Array(Set(screens)).sorted(), "a screen went back or came twice")
        let displays = log.displays.map(\.number)
        XCTAssertEqual(displays, displays.sorted(), "a display went back")
        await session.close()
    }

    /// (10) Guesses pending, then `quiesce()` and `exportState()`: no timer and no render for 1 s.
    func testNothingIsRenderedWhileQuiesced() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always), delayMs: 150)
        let log = Log(session.events)
        await session.start()
        let v19 = await waitForPrompt(session)
        XCTAssertTrue(v19)
        _ = await session.type(Array("p".utf8))
        let v20 = await session.predictionTimerIsArmedForTesting()
        XCTAssertTrue(v20, "a pending guess arms the timer")
        await session.quiesce()
        _ = try await session.exportState()
        let v21 = await session.predictionTimerIsArmedForTesting()
        XCTAssertFalse(v21)
        let count = log.displays.count
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(log.displays.count, count, "a frame was rendered while quiesced")
        let v22 = await session.predictionTimerIsArmedForTesting()
        XCTAssertFalse(v22)
        let v23 = await session.predictionEngineForTesting().isActive
        XCTAssertTrue(v23, "the guess is kept")
        await session.close()
    }

    /// (11) After `.serverEnded` the last `.display` is the final remote frame and no timer runs.
    func testTheEndShowsNoGuessAndStopsTheTimer() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try makeSession(server, prediction: PredictionSettings(display: .always), delayMs: 50)
        let log = Log(session.events)
        await session.start()
        let v24 = await waitForPrompt(session)
        XCTAssertTrue(v24)
        let v25 = await confirmEpoch(session)
        XCTAssertTrue(v25)
        _ = await session.type(Array("cho x; exit\r".utf8))  // "echo x; exit"
        let ended = await wait(seconds: 15) { log.serverEnded }
        XCTAssertTrue(ended, "no serverEnded; events: \(log.events.suffix(5))")
        try await Task.sleep(nanoseconds: 100_000_000)
        let last = try XCTUnwrap(log.displays.last)
        XCTAssertFalse(last.hasPredictions)
        let v26 = await session.screen().framebuffer
        XCTAssertEqual(last.framebuffer, v26)
        let v27 = await session.predictionTimerIsArmedForTesting()
        XCTAssertFalse(v27)
        let v28 = await session.predictionEngineForTesting().isActive
        XCTAssertFalse(v28)
        await session.close()
    }

    #endif

    // MARK: No server

    private static func restoredSnapshot() throws -> SessionSnapshot {
        var state = TerminalRemoteState(serverStartSize: TerminalSize(width: 80, height: 24))
        try state.apply(diff: HostMessage(instructions: [.hostBytes(Array("stored$ ".utf8))]).serialized())
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 3,
            pendingInput: [],
            remoteStates: [NumberedRemoteState(number: 5, state: state)],
            highestAckSent: 5,
            terminalSize: TerminalSize(width: 80, height: 24),
            usedCounters: GateCounters(sequence: 10, state: 4, fragmentID: 10),
            receiverExpectedSequence: 10
        )
        return SessionSnapshot(transport: transport, clipboard: ClipboardPolicy())
    }

    /// (6) A restored session's first `.display` follows the stored screen and has no guess.
    func testARestoredSessionsFirstDisplayHasNoGuess() async throws {
        let session = try MoshSession(
            restoring: try Self.restoredSnapshot(),
            endpoint: SessionEndpoint(host: "127.0.0.1", port: 9, key: Base64Key.random()),
            gate: InMemoryGate(startingAt: GateCounters(sequence: 100, state: 100, fragmentID: 100)),
            currentSize: nil,
            prediction: PredictionSettings(display: .always),
            makeTransport: { NullTransport() }
        )
        await session.start()
        await session.close()
        var events: [SessionEvent] = []
        for await event in session.events { events.append(event) }
        guard case .screen(let stored)? = events.first else { return XCTFail("first event: \(String(describing: events.first))") }
        XCTAssertFalse(stored.isLive)
        let display = events.compactMap { if case .display(let f) = $0 { return f } else { return nil } }.first
        let frame = try XCTUnwrap(display)
        XCTAssertEqual(frame.number, 5)
        XCTAssertEqual(frame.serial, 1)
        XCTAssertFalse(frame.hasPredictions)
        XCTAssertEqual(frame.framebuffer, stored.framebuffer)
    }

    /// (7) Input refused after `shutdown()` does not reach the engine (stmclient.cc:319-321).
    func testRefusedInputLeavesTheEngineAlone() async throws {
        let session = try MoshSession(
            endpoint: SessionEndpoint(host: "127.0.0.1", port: 9, key: Base64Key.random()),
            initialSize: TerminalSize(width: 80, height: 24),
            noReplyTimeout: nil,
            prediction: PredictionSettings(display: .always),
            makeTransport: { NullTransport() }
        )
        await session.start()
        let v29 = await session.type(Array("a".utf8))
        XCTAssertTrue(v29)
        let v30 = await session.predictionEngineForTesting().isActive
        XCTAssertTrue(v30, "accepted input is predicted")
        await session.shutdown()
        let before = await session.predictionEngineForTesting()
        let v31 = await session.type(Array("b".utf8))
        XCTAssertFalse(v31, "input after shutdown is refused")
        let v32 = await session.predictionEngineForTesting()
        XCTAssertEqual(v32, before)
        await session.close()
    }

    /// The settings API, and a switch to `never` sends one last `.display` with the remote frame.
    func testSwitchingToNeverSendsTheRemoteFrameOnce() async throws {
        let session = try MoshSession(
            endpoint: SessionEndpoint(host: "127.0.0.1", port: 9, key: Base64Key.random()),
            initialSize: TerminalSize(width: 80, height: 24),
            noReplyTimeout: nil,
            makeTransport: { NullTransport() }
        )
        let v33 = await session.predictionSettings()
        XCTAssertEqual(v33, .off)
        await session.start()
        await session.setPrediction(PredictionSettings(display: .experimental, overwrite: true))
        let v34 = await session.predictionSettings()
        XCTAssertEqual(v34, PredictionSettings(display: .experimental, overwrite: true))
        _ = await session.type(Array("a".utf8))
        await session.setPrediction(.off)
        _ = await session.type(Array("b".utf8))
        await session.close()
        var displays: [DisplayFrame] = []
        for await event in session.events {
            if case .display(let frame) = event { displays.append(frame) }
        }
        // Experimental mode draws a guess at once (its epoch is always the confirmed one,
        // terminaloverlay.cc:657-659).
        XCTAssertTrue(displays.contains { $0.hasPredictions && text($0.framebuffer).contains("a") })
        let last = try XCTUnwrap(displays.last)
        XCTAssertFalse(last.hasPredictions)
        XCTAssertFalse(text(last.framebuffer).contains("a"), "the last display after the switch is the remote frame")
        XCTAssertFalse(displays.contains { text($0.framebuffer).contains("b") }, "no display after the switch to never")
        XCTAssertEqual(displays.map(\.serial), Array(1...UInt64(displays.count)))
    }
}
