import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

/// Counts the sockets opened and the datagrams handed to them; nothing leaves, nothing arrives.
/// A server that is never heard from: every input event stays unacknowledged.
private final class DeadNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var openedCount = 0
    private var sentCount = 0

    var opened: Int { lock.lock(); defer { lock.unlock() }; return openedCount }
    var sent: Int { lock.lock(); defer { lock.unlock() }; return sentCount }

    var makeTransport: @Sendable () throws -> any DatagramTransport {
        { [self] in
            lock.lock()
            openedCount += 1
            lock.unlock()
            return Socket(network: self)
        }
    }

    private final class Socket: DatagramTransport, @unchecked Sendable {
        let network: DeadNetwork
        init(network: DeadNetwork) { self.network = network }
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {
            network.lock.lock()
            network.sentCount += 1
            network.lock.unlock()
        }
        func close() {}
    }
}

/// The coordinator's rules without a server: what is on disk after each lifecycle call, the
/// cold start's three outcomes, and M9 (a change accepted in the background).
final class ResumeCoordinatorTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

    private func options(_ network: DeadNetwork, hook: StorageHook? = nil) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.blocks = GateCounters(sequence: 4, state: 2, fragmentID: 2)
        options.storageHook = hook
        options.noReplyTimeout = nil
        options.makeTransport = network.makeTransport
        return options
    }

    /// A started session that has typed something.
    private func newSession(root: String, network: DeadNetwork, hook: StorageHook? = nil) async throws -> ResumeCoordinator {
        let coordinator = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       initialSize: size, options: options(network, hook: hook))
        try await coordinator.start()
        let typed = await coordinator.type(Array("ls\r".utf8))
        XCTAssertTrue(typed)
        return coordinator
    }

    private func resumed(_ outcome: ColdStartOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> ResumeCoordinator {
        guard case .resumed(let coordinator) = outcome else {
            XCTFail("not resumed: \(outcome)", file: file, line: line)
            throw XCTSkip("not resumed")
        }
        return coordinator
    }

    private func fallback(_ outcome: ColdStartOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> ColdStartFallback {
        guard case .fallback(let fallback) = outcome else {
            XCTFail("not a fallback: \(outcome)", file: file, line: line)
            throw XCTSkip("not a fallback")
        }
        return fallback
    }

    // MARK: Save and cold start

    func testLeavingTheForegroundMakesTheRecordCleanAndAColdStartResumesIt() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        let id = first.id
        var state = await first.recordState
        XCTAssertEqual(state, .dirty)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let pending = await first.unacknowledgedInputCount()
        XCTAssertGreaterThanOrEqual(pending, 3)
        // The app switcher fires the callback again: still clean.
        let again = await first.enterBackground()
        XCTAssertEqual(again, .clean)
        await first.close()

        let sentBefore = network.sent
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertTrue(second.isRestored)
        XCTAssertEqual(network.sent, sentBefore, "a cold start sends nothing before start()")
        state = await second.recordState
        guard case .clean = state else { return XCTFail("\(state)") }
        try await second.start()
        state = await second.recordState
        XCTAssertEqual(state, .dirty, "dirty before the first datagram of the new life")
        let restoredPending = await second.unacknowledgedInputCount()
        XCTAssertEqual(restoredPending, pending)
        await second.close()

        // That life died in the foreground: the next start is the fallback, and it is final.
        let opened = network.opened, sent = network.sent
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .dirty)
        XCTAssertTrue(dead.wantsNewSession)
        XCTAssertFalse(dead.recordDeleted)
        XCTAssertEqual(dead.meta?.id, id)
        XCTAssertEqual(network.opened, opened, "the fallback opens no socket")
        XCTAssertEqual(network.sent, sent, "the fallback sends nothing under the old key")
        let later = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(later.reason, .dirty, "a record given up stays dead, and still owes a new session")
        XCTAssertTrue(later.wantsNewSession)
        try ResumeCoordinator.deleteRecord(root: root, id: id)
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
    }

    func testReturningToTheForegroundMakesTheRecordDirtyAtOnce() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let coordinator = try await newSession(root: root, network: network)
        let saved = await coordinator.enterBackground()
        XCTAssertEqual(saved, .clean)
        await coordinator.enterForeground()
        let state = await coordinator.recordState
        XCTAssertEqual(state, .dirty)
        let background = await coordinator.isInBackground
        XCTAssertFalse(background)
        // And clean again at the next save, with what was typed in between.
        _ = await coordinator.type(Array("pwd\r".utf8))
        let pending = await coordinator.unacknowledgedInputCount()
        let again = await coordinator.enterBackground()
        XCTAssertEqual(again, .clean)
        await coordinator.close()
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: coordinator.id, key: .recordFile, currentSize: size, options: options(network)))
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, pending)
        await second.close()
    }

    // MARK: M9

    /// Finding M9: input accepted while quiesced passes no datagram, so the gate's clean rule
    /// does not see it. After `type` returned true in the background, a process death must lead
    /// to a resume that has the input, or to the fallback: never to a resume without it.
    func testInputAcceptedInTheBackgroundIsInTheRecord() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let before = await first.unacknowledgedInputCount()
        let sent = network.sent

        let accepted = await first.type(Array("late".utf8))
        XCTAssertTrue(accepted)
        XCTAssertEqual(network.sent, sent, "nothing is sent in the background")
        let state = await first.recordState
        guard case .clean = state else { return XCTFail("after the second save the record is \(state)") }
        await first.close()   // the process dies here, still in the background

        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)))
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, before + 4, "the stored snapshot must hold the four bytes typed in the background")
        await second.close()
    }

    func testAResizeAcceptedInTheBackgroundIsInTheRecord() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        _ = await first.enterBackground()
        let before = await first.unacknowledgedInputCount()
        let accepted = await first.resize(TerminalSize(width: 100, height: 30))
        XCTAssertTrue(accepted)
        await first.close()

        // No size is given at the cold start, so the import adds no resize of its own: the one
        // in the snapshot is the one that was accepted.
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: nil, options: options(network)))
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, before + 1)
        await second.close()
    }

    /// The same with the process killed at every storage step of the background input: if
    /// `type` said the input was taken, the next start has it or falls back; if the process died
    /// first, the next start is a resume without it or a fallback, and never anything else.
    func testAProcessDeathAtEveryStepOfBackgroundInput() async throws {
        // How many steps the background input takes.
        let probeRoot = try scratchRoot("coordinator")
        let probeScript = StepScript()
        let probe = try await newSession(root: probeRoot, network: DeadNetwork(), hook: probeScript.hook)
        _ = await probe.enterBackground()
        let start = probeScript.count
        _ = await probe.type(Array("late".utf8))
        let steps = probeScript.count - start
        await probe.close()
        // "Dirty" in both slots, the snapshot replaced, the clean mark.
        XCTAssertEqual(steps, 4 + 5 + 2)

        var resumedWith = 0, resumedWithout = 0, fellBack = 0
        for step in 0..<steps {
            for action in [StorageHookAction.crashBefore, .crashAfter] {
                let root = try scratchRoot("coordinator")
                let network = DeadNetwork()
                let script = StepScript()
                let first = try await newSession(root: root, network: network, hook: script.hook)
                let saved = await first.enterBackground()
                XCTAssertEqual(saved, .clean)
                let before = await first.unacknowledgedInputCount()
                script.at(script.count + step, action)
                let accepted = await first.type(Array("late".utf8))
                await first.close()

                switch ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)) {
                case .resumed(let second):
                    let restored = await second.unacknowledgedInputCount()
                    if restored == before + 4 {
                        resumedWith += 1
                    } else {
                        XCTAssertEqual(restored, before, "step \(step) \(action)")
                        XCTAssertFalse(accepted, "step \(step) \(action): input that was taken is not in the resumed session")
                        resumedWithout += 1
                    }
                    await second.close()
                case .fallback(let fallback):
                    XCTAssertTrue([.dirty, .snapshotDoesNotMatch].contains(fallback.reason), "step \(step) \(action): \(fallback.reason)")
                    fellBack += 1
                case .retryLater(let retry):
                    XCTFail("step \(step) \(action): \(retry)")
                }
            }
        }
        // Death before the first write: the old snapshot is still right. Death once the clean
        // mark is in its slot (after its write, before and after its fsync): the new one is.
        // Everything in between is the fallback.
        XCTAssertEqual(resumedWithout, 1)
        XCTAssertEqual(resumedWith, 3)
        XCTAssertEqual(fellBack, steps * 2 - 4)
    }

    /// M9, third requirement: a shutdown asked for in the background is not in the snapshot
    /// either (the export refuses a session that is shutting down). The record must not stay
    /// clean: a session the user closed is not resumed.
    func testAShutdownInTheBackgroundEndsTheRecord() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let running = await first.shutdown()
        XCTAssertTrue(running)
        let state = await first.recordState
        XCTAssertEqual(state, .ended)
        // Nothing makes it clean again.
        let typed = await first.type(Array("x".utf8))
        _ = typed
        let again = await first.enterBackground()
        XCTAssertEqual(again, .notResumable(.ended))
        await first.close()

        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .ended)
        XCTAssertFalse(dead.wantsNewSession, "a session the user closed is not started again")
    }

    func testAShutdownInTheForegroundEndsTheRecord() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        _ = await first.shutdown()
        let state = await first.recordState
        XCTAssertEqual(state, .ended)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .notResumable(.ended))
        await first.close()
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .ended)
    }

    func testAnAbandonedSessionIsNotResumed() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let first = try await newSession(root: root, network: network)
        _ = await first.enterBackground()
        await first.abandon()
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .dirty)
    }

    /// If "dirty" cannot be written, background input is refused: the record stays clean for a
    /// snapshot that is still the whole truth.
    func testBackgroundInputIsRefusedWhenTheRecordCannotBeWritten() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        _ = await first.enterBackground()
        let before = await first.unacknowledgedInputCount()
        script.at(script.count, .fail(errno: EPERM))
        let accepted = await first.type(Array("late".utf8))
        XCTAssertFalse(accepted)
        let pending = await first.unacknowledgedInputCount()
        XCTAssertEqual(pending, before, "the session did not get the input")
        // The device is unlocked again.
        let retried = await first.type(Array("late".utf8))
        XCTAssertTrue(retried)
        await first.close()
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size, options: options(network)))
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, before + 4)
        await second.close()
    }

    // MARK: Fallback and retry

    private func savedRecord(root: String, network: DeadNetwork) async throws -> SessionID {
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()
        return first.id
    }

    private func path(_ root: String, _ id: SessionID, _ file: String) -> String {
        "\(root)/\(id)/\(file)"
    }

    func testARecordInUseIsRetriedLater() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let live = try await newSession(root: root, network: network)
        _ = await live.enterBackground()
        guard case .retryLater(.inUse) = ResumeCoordinator.coldStart(root: root, id: live.id, key: .recordFile, currentSize: size, options: options(network)) else {
            return XCTFail("a record whose lock is held must be left alone")
        }
        XCTAssertThrowsError(try ResumeCoordinator.deleteRecord(root: root, id: live.id)) {
            XCTAssertEqual($0 as? RecordError, .locked)
        }
        let state = await live.recordState
        guard case .clean = state else { return XCTFail("\(state)") }
        await live.close()
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: live.id, key: .recordFile, currentSize: size, options: options(network)))
        await second.close()
    }

    /// "Device locked" at the cold start's counters write: nothing is sent, the record is still
    /// resumable, and the same start works later.
    func testAStorageErrorAtStartIsRetriedLaterAndNeverAFallback() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        let script = StepScript()
        script.at(0, .fail(errno: EPERM))
        let sent = network.sent
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network, hook: script.hook)))
        do {
            try await second.start()
            XCTFail("start() must report the failed write")
        } catch {
            guard case StorageError.io = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(network.sent, sent, "no datagram without the counters write")
        try await second.start()
        XCTAssertGreaterThan(network.sent, sent)
        await second.close()
    }

    func testAStorageErrorAtOpenIsRetriedLater() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        if geteuid() == 0 { throw XCTSkip("root reads a file without permissions") }
        XCTAssertEqual(chmod(path(root, id, "snapshot"), 0), 0)
        defer { _ = chmod(path(root, id, "snapshot"), 0o600) }
        guard case .retryLater(.storage) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)) else {
            return XCTFail("a file that cannot be read now is not a dead session")
        }
    }

    func testARecordWithoutItsSnapshotFallsBack() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        XCTAssertEqual(unlink(path(root, id, "snapshot")), 0)
        let sent = network.sent, opened = network.opened
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .missing(.snapshot))
        XCTAssertEqual(dead.meta?.id, id)
        XCTAssertFalse(dead.recordDeleted)
        XCTAssertEqual(network.sent, sent)
        XCTAssertEqual(network.opened, opened)
    }

    func testADamagedSnapshotFallsBack() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path(root, id, "snapshot"))))
        bytes[bytes.count / 2] ^= 0x10
        try Data(bytes).write(to: URL(fileURLWithPath: path(root, id, "snapshot")))
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        guard case .damaged = dead.reason else { return XCTFail("\(dead.reason)") }
        XCTAssertEqual(network.opened, 1, "only the first life opened a socket")
    }

    func testARecordWithoutItsKeyFallsBack() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        XCTAssertEqual(unlink(path(root, id, "key")), 0)
        let sent = network.sent
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertEqual(dead.reason, .missing(.key))
        XCTAssertEqual(network.sent, sent)
        // With the key from elsewhere (the Keychain on iOS) the same record would have resumed.
        let other = try await savedRecord(root: root, network: network)
        XCTAssertEqual(unlink(path(root, other, "key")), 0)
        let second = try resumed(ResumeCoordinator.coldStart(root: root, id: other, key: .provided(Fixtures.key), currentSize: size,
                                                             options: options(network)))
        await second.close()
    }

    func testARecordWithBothCountersSlotsBadIsDeleted() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let id = try await savedRecord(root: root, network: network)
        try Data(repeating: 0xFF, count: 8192).write(to: URL(fileURLWithPath: path(root, id, "counters")))
        let sent = network.sent
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network)))
        guard case .damaged = dead.reason else { return XCTFail("\(dead.reason)") }
        XCTAssertEqual(dead.meta?.id, id, "meta is still handed over for the new bootstrap")
        XCTAssertTrue(dead.recordDeleted)
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
        XCTAssertEqual(network.sent, sent)
    }

    /// One bad slot is not a damaged record: the other one is used, and it says what the first
    /// said (docs/RESUME.md, R10).
    func testARecordWithOneBadCountersSlotResumes() async throws {
        for slot in 0..<2 {
            let root = try scratchRoot("coordinator")
            let network = DeadNetwork()
            let id = try await savedRecord(root: root, network: network)
            let url = URL(fileURLWithPath: path(root, id, "counters"))
            var bytes = [UInt8](try Data(contentsOf: url))
            let newer = try SessionStore(root: root, id: id).readCounters().generation
            for index in 0..<68 { bytes[slot * 4096 + index] = 0 }
            try Data(bytes).write(to: url)
            let outcome = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size, options: options(network))
            if Int(newer % 2) == slot {
                // The slot with the clean mark is gone; the older one says "dirty".
                XCTAssertEqual(try fallback(outcome).reason, .dirty)
            } else {
                let second = try resumed(outcome)
                await second.close()
            }
        }
    }

    func testADirectoryThatNeverBecameARecordIsDeleted() async throws {
        let root = try scratchRoot("coordinator")
        let network = DeadNetwork()
        let script = StepScript()
        // The process dies while the record is made, before `counters` exists.
        script.at(8, .crashBefore)
        let meta = Fixtures.meta(id: .random())
        XCTAssertThrowsError(try ResumeCoordinator.create(root: root, meta: meta, key: Fixtures.key, initialSize: size,
                                                          options: options(network, hook: script.hook)))
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [meta.id])
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: meta.id, key: .recordFile, currentSize: size, options: options(network)))
        XCTAssertTrue(dead.recordDeleted)
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
        XCTAssertEqual(network.opened, 0)
    }

    func testAnIDWithoutARecordIsAFallback() throws {
        let root = try scratchRoot("coordinator")
        let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: .random(), key: .recordFile, currentSize: size))
        XCTAssertEqual(dead.reason, .missing(.meta))
        XCTAssertTrue(dead.recordDeleted)
        XCTAssertNil(dead.meta)
    }
}

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// Collects a coordinator's events for a test, from before `start()`.
private final class CoordinatorEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionEvent] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await event in events { self?.append(event) }
        }
    }

    deinit { task?.cancel() }

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

    var sawContact: Bool {
        events.contains { if case .contact = $0 { return true } else { return false } }
    }

    /// The `acknowledged` of every `.shutdownFinished`, in order.
    var shutdownAnswers: [Bool] {
        events.compactMap { if case .shutdownFinished(let acknowledged) = $0 { return acknowledged } else { return nil } }
    }

    var problems: [SessionEvent] {
        events.filter {
            switch $0 {
            case .halted, .baseStateLost, .protocolProblem, .gateFailed: return true
            default: return false
            }
        }
    }

    /// The kinds of events seen, runs counted, for a failure message (no screen contents).
    var summary: String {
        var runs: [(String, Int)] = []
        for event in events {
            let kind: String
            switch event {
            case .screen: kind = "screen"
            case .contact: kind = "contact"
            case .display: kind = "display"
            case .instructionApplied: kind = "instruction"
            case .clipboard: kind = "clipboard"
            case .serverEnded: kind = "serverEnded"
            case .serverEndAcknowledged: kind = "serverEndAcknowledged"
            case .shutdownFinished(let acknowledged): kind = "shutdownFinished(acknowledged: \(acknowledged))"
            case .baseStateLost: kind = "baseStateLost"
            case .noServerReply: kind = "noServerReply"
            default: kind = "\(event)"   // halted, gateFailed, networkProblem, protocolProblem: their text
            }
            if let last = runs.last, last.0 == kind { runs[runs.count - 1].1 += 1 } else { runs.append((kind, 1)) }
        }
        return runs.map { $0.1 > 1 ? "\($0.0) x\($0.1)" : $0.0 }.joined(separator: ", ")
    }
}

/// The coordinator against a real mosh-server 1.4.0. Skipped without mosh-server.
final class ResumeCoordinatorServerTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

    private func startServer() throws -> MoshServerProcess {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        return try MoshServerProcess(command: ["/bin/sh"], environment: ["PS1": "$ ", "ENV": ""])
    }

    private func meta(for server: MoshServerProcess) -> SessionMeta {
        SessionMeta(createdAt: UInt64(Date().timeIntervalSince1970), hostName: "localhost", address: "127.0.0.1",
                    port: server.port, user: NSUserName(), remoteCommand: "/bin/sh",
                    serverStartSize: TerminalRemoteState.defaultServerSize, serverPID: UInt32(server.pid))
    }

    private func wait(seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func waitForRow(_ row: String, on coordinator: ResumeCoordinator, seconds: Double = 10) async -> Bool {
        await wait(seconds: seconds) {
            visibleText(of: await coordinator.screen().framebuffer).contains(row)
        }
    }

    /// M9 against the real server: a line typed in the background, the process gone before it
    /// returns to the foreground, a cold start. The same shell runs the line, once.
    func testALineTypedInTheBackgroundReachesTheServerAfterAColdStart() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("coordinator-server")
        let key = try Base64Key(printable: server.key)

        let first = try ResumeCoordinator.create(root: root, meta: meta(for: server), key: key, initialSize: size)
        try await first.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await first.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await first.type(Array("echo one-$((1+1)); echo pid-$$\r".utf8))
        let one = await waitForRow("one-2", on: first)
        XCTAssertTrue(one)
        let settled = await wait(seconds: 10) { await first.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(settled)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let accepted = await first.type(Array("echo late-$((2+3)); echo pid-$$\r".utf8))
        XCTAssertTrue(accepted)
        await first.close()

        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size) else {
            return XCTFail("the record did not resume")
        }
        try await second.start()
        let late = await waitForRow("late-5", on: second)
        let rows = visibleText(of: await second.screen().framebuffer)
        XCTAssertTrue(late, "the line typed in the background never ran:\n\(rows.joined(separator: "\n"))")
        XCTAssertEqual(rows.filter { $0 == "late-5" }.count, 1, "exactly once")
        let pids = rows.filter { $0.hasPrefix("pid-") }
        XCTAssertEqual(pids.count, 2, rows.joined(separator: "\n"))
        XCTAssertEqual(Set(pids).count, 1, "the same shell")
        XCTAssertTrue(server.isAlive)
        await second.close()
    }

    /// The server's end of the session marks the record ended before the app hears of it.
    func testTheServersEndOfTheSessionEndsTheRecord() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("coordinator-server")
        let key = try Base64Key(printable: server.key)
        let coordinator = try ResumeCoordinator.create(root: root, meta: meta(for: server), key: key, initialSize: size)
        try await coordinator.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await coordinator.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await coordinator.type(Array("exit\r".utf8))
        var sawEnd = false
        for await event in coordinator.events {
            if case .serverEnded = event {
                sawEnd = true
                let state = await coordinator.recordState
                XCTAssertEqual(state, .ended, "marked before the event is passed on")
                break
            }
        }
        XCTAssertTrue(sawEnd)
        let saved = await coordinator.enterBackground()
        XCTAssertEqual(saved, .notResumable(.ended))
        await coordinator.close()
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: coordinator.id, key: .recordFile, currentSize: size) else {
            return XCTFail("an ended session resumed")
        }
        XCTAssertEqual(dead.reason, .ended)
    }

    /// Leave, return, leave, die, cold start, twice: the plan's lifecycle through the
    /// coordinator, on one server process and one shell.
    func testBackgroundForegroundAndTwoColdStarts() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("coordinator-server")
        let key = try Base64Key(printable: server.key)
        var coordinator = try ResumeCoordinator.create(root: root, meta: meta(for: server), key: key, initialSize: size)
        let id = coordinator.id
        try await coordinator.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await coordinator.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        for life in 1...3 {
            _ = await coordinator.type(Array("echo life\(life)-$((\(life)*7))\r".utf8))
            let shown = await waitForRow("life\(life)-\(life * 7)", on: coordinator)
            XCTAssertTrue(shown, "life \(life)")
            var saved = await coordinator.enterBackground()
            XCTAssertEqual(saved, .clean)
            await coordinator.enterForeground()
            _ = await coordinator.type(Array("echo again\(life)-$((\(life)*9))\r".utf8))
            let again = await waitForRow("again\(life)-\(life * 9)", on: coordinator)
            XCTAssertTrue(again, "life \(life) after returning to the foreground")
            saved = await coordinator.enterBackground(afterSend: life == 2)
            XCTAssertEqual(saved, .clean)
            await coordinator.close()
            guard life < 3 else { break }
            guard case .resumed(let next) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size) else {
                return XCTFail("life \(life) did not resume")
            }
            coordinator = next
            try await coordinator.start()
        }
        XCTAssertTrue(server.isAlive)
    }

    // MARK: Ending a parked session through mosh (multi-session design, section 6)

    /// A session that talked to its server, was saved clean and closed: what the app holds for a
    /// session that is not on screen.
    private func parkedRecord(on server: MoshServerProcess, root: String) async throws -> SessionID {
        let key = try Base64Key(printable: server.key)
        let first = try ResumeCoordinator.create(root: root, meta: meta(for: server), key: key, initialSize: size)
        try await first.start()
        let prompt = await ShellPrompt.wait { ShellPrompt.isOnScreen(visibleText(of: await first.screen().framebuffer)) }
        XCTAssertTrue(prompt, "the shell's first prompt is on the screen before the first line")
        _ = await first.type(Array("echo up-$((3*3))\r".utf8))
        let up = await waitForRow("up-9", on: first)
        XCTAssertTrue(up)
        let settled = await wait(seconds: 10) { await first.unacknowledgedInputCount() == 0 }
        XCTAssertTrue(settled)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()
        return first.id
    }

    private func coldStart(root: String, id: SessionID, file: StaticString = #filePath, line: UInt = #line) throws -> ResumeCoordinator {
        guard case .resumed(let coordinator) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size) else {
            XCTFail("the parked record did not resume", file: file, line: line)
            throw XCTSkip("not resumed")
        }
        XCTAssertTrue(coordinator.isRestored, file: file, line: line)
        return coordinator
    }

    /// Step 0 of the multi-session design: "End Session" on a parked session goes through mosh's
    /// own shutdown, with no pid. Cold start, `start()`, first contact, `shutdown()`: the real
    /// server acknowledges, the coordinator reports it, and the server exits.
    /// Control: without `start()` nothing reads the server's answer (no contact, no
    /// `.shutdownFinished`).
    func testAResumedSessionEndsByMoshShutdown() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("coordinator-server")
        let id = try await parkedRecord(on: server, root: root)
        XCTAssertTrue(server.isAlive, "the parked session's server runs on")

        let second = try coldStart(root: root, id: id)
        let log = CoordinatorEventLog(second.events)
        try await second.start()
        let contact = await wait(seconds: 10) { log.sawContact }
        XCTAssertTrue(contact, "no contact from the server within 10 s; events: \(log.summary)")

        let running = await second.shutdown()
        XCTAssertTrue(running, "shutdown() refused; events: \(log.summary)")
        let state = await second.recordState
        XCTAssertEqual(state, .ended, "marked ended before anything is sent")
        let answered = await wait(seconds: 15) { !log.shutdownAnswers.isEmpty }
        XCTAssertTrue(answered, "no .shutdownFinished within 15 s; events: \(log.summary)")
        XCTAssertEqual(log.shutdownAnswers, [true], "events: \(log.summary)")
        let gone = await wait(seconds: 5) { !server.isAlive }
        XCTAssertTrue(gone, "the server exits once it has acknowledged the shutdown")
        XCTAssertEqual(log.problems, [])
        await second.close()

        // The one try through mosh is spent: the record is never resumed again.
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size) else {
            return XCTFail("an ended record resumed")
        }
        XCTAssertEqual(dead.reason, .ended)
        XCTAssertFalse(dead.wantsNewSession)
    }

    /// The same with the parked session's server gone: the shutdown is sent and never
    /// acknowledged, and the coordinator says so within mosh's limit (16 sends or 10 s).
    /// Control: with the server left running the answer is `true`.
    func testAResumedSessionWithoutItsServerIsNotAcknowledged() async throws {
        let server = try startServer()
        defer { server.stop() }
        let root = try scratchRoot("coordinator-server")
        let id = try await parkedRecord(on: server, root: root)
        server.stop()
        XCTAssertFalse(server.isAlive, "the server was stopped")

        let second = try coldStart(root: root, id: id)
        let log = CoordinatorEventLog(second.events)
        try await second.start()
        // As long as the first test waits at most for its contact, so that the two differ only
        // in the server.
        _ = await wait(seconds: 10) { log.sawContact }

        let running = await second.shutdown()
        XCTAssertTrue(running, "shutdown() refused; events: \(log.summary)")
        let state = await second.recordState
        XCTAssertEqual(state, .ended)
        let answered = await wait(seconds: 15) { !log.shutdownAnswers.isEmpty }
        XCTAssertTrue(answered, "no .shutdownFinished within 15 s; events: \(log.summary)")
        XCTAssertEqual(log.shutdownAnswers, [false], "events: \(log.summary)")
        XCTAssertEqual(log.problems, [])
        await second.close()

        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size) else {
            return XCTFail("an ended record resumed")
        }
        XCTAssertEqual(dead.reason, .ended)
    }
}

#endif
