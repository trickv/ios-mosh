import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

private final class DeadNet: @unchecked Sendable {
    private let lock = NSLock()
    private var openedCount = 0
    private var sentCount = 0
    var opened: Int { lock.lock(); defer { lock.unlock() }; return openedCount }
    var sent: Int { lock.lock(); defer { lock.unlock() }; return sentCount }
    var makeTransport: @Sendable () throws -> any DatagramTransport {
        { [self] in
            lock.lock(); openedCount += 1; lock.unlock()
            return Socket(network: self)
        }
    }
    private final class Socket: DatagramTransport, @unchecked Sendable {
        let network: DeadNet
        init(network: DeadNet) { self.network = network }
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {
            network.lock.lock(); network.sentCount += 1; network.lock.unlock()
        }
        func close() {}
    }
}

/// Scratch tests of review B. Each one asserts what should hold and is expected to FAIL.
final class ReviewBTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

    private func options(_ network: DeadNet, hook: StorageHook? = nil) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.blocks = GateCounters(sequence: 4, state: 2, fragmentID: 2)
        options.storageHook = hook
        options.noReplyTimeout = nil
        options.makeTransport = network.makeTransport
        return options
    }

    private func newSession(root: String, network: DeadNet, hook: StorageHook? = nil) async throws -> ResumeCoordinator {
        let coordinator = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       initialSize: size, options: options(network, hook: hook))
        try await coordinator.start()
        _ = await coordinator.type(Array("ls\r".utf8))
        return coordinator
    }

    // B-1: the reason of a fallback is lost at the second cold start.
    func testB1_AFallbackThatTheAppDidNotFinishStillWantsANewSession() async throws {
        let root = try scratchRoot("review-b")
        let network = DeadNet()
        let first = try await newSession(root: root, network: network)
        await first.close()     // died in the foreground: dirty
        guard case .fallback(let one) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) else {
            return XCTFail("no fallback")
        }
        XCTAssertEqual(one.reason, .dirty)
        XCTAssertTrue(one.wantsNewSession)
        // The app is killed (or has no network) before the new bootstrap and deleteRecord.
        guard case .fallback(let two) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) else {
            return XCTFail("no fallback")
        }
        XCTAssertTrue(two.wantsNewSession, "second start says \(two.reason): the session is dropped and the old server never killed")
    }

    func testB1_AnAbandonedSessionStillWantsANewSession() async throws {
        let root = try scratchRoot("review-b")
        let network = DeadNet()
        let first = try await newSession(root: root, network: network)
        await first.abandon()   // "Start new session" under the banner; the app dies before the bootstrap
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) else {
            return XCTFail("no fallback")
        }
        XCTAssertTrue(dead.wantsNewSession, "reason \(dead.reason)")
    }

    // B-2: input before start() on a resumed coordinator.
    func testB2_InputBeforeStartSendsAndTheSessionIsThenLost() async throws {
        let root = try scratchRoot("review-b")
        let network = DeadNet()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()

        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) else {
            return XCTFail("not resumed")
        }
        let sent = network.sent, opened = network.opened
        // The terminal view lays out and reports its size before the app's start() ran.
        _ = await second.resize(TerminalSize(width: 100, height: 30))
        XCTAssertEqual(network.opened, opened, "a socket was opened before start()")
        XCTAssertEqual(network.sent, sent, "a datagram left before start()")
        let state = await second.recordState
        if case .clean = state {} else { XCTFail("the record is \(state) before start()") }
        // The app goes to the background (start() still not called, or it threw).
        let outcome = await second.enterBackground()
        XCTAssertEqual(outcome, .clean, "enterBackground did not save")
        let sentAfter = network.sent
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(network.sent, sentAfter, "still sending in the background: not quiesced")
        await second.close()
        if case .resumed(let third) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) {
            await third.close()
        } else {
            XCTFail("the session is lost")
        }
    }

    // B-3: a repeated enterBackground() can only lose a record that was resumable.
    func testB3_ASecondSaveNeverMakesAResumableRecordUnresumable() async throws {
        var lost: [String] = []
        for step in 0..<7 {
            for action in [StorageHookAction.crashBefore, .crashAfter] {
                let root = try scratchRoot("review-b")
                let network = DeadNet()
                let script = StepScript()
                let first = try await newSession(root: root, network: network, hook: script.hook)
                let saved = await first.enterBackground()
                XCTAssertEqual(saved, .clean)
                script.at(script.count + step, action)
                _ = await first.enterBackground()   // the app switcher, didEnterBackground, ...
                await first.close()
                switch ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) {
                case .resumed(let second): await second.close()
                case .fallback(let fallback): lost.append("step \(step) \(action): \(fallback.reason)")
                case .retryLater(let retry): XCTFail("\(retry)")
                }
            }
        }
        XCTAssertEqual(lost, [], "nothing was sent and nothing changed, yet the session is dead")
    }

    // B-4: a shutdown in the background whose marks cannot be written.
    func testB4_AShutdownThatCannotBeRecordedIsNotResumed() async throws {
        let root = try scratchRoot("review-b")
        let network = DeadNet()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        for index in 0..<40 { script.at(script.count + index, .fail(errno: EPERM)) }
        let running = await first.shutdown()
        XCTAssertFalse(running, "the shutdown was accepted although the record still says clean")
        await first.close()
        script.clearPlan()
        if case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) {
            XCTAssertFalse(running, "a session the user closed came back")
            await second.close()
        }
    }

    // B-5: M9 in the foreground while the gate cannot write.
    func testB5_InputAcceptedWhileTheGateCannotWriteIsNotLostByAResume() async throws {
        let root = try scratchRoot("review-b")
        let network = DeadNet()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let before = await first.unacknowledgedInputCount()
        for index in 0..<200 { script.at(script.count + index, .fail(errno: EPERM)) }
        await first.enterForeground()
        let accepted = await first.type(Array("rm -rf build\r".utf8))
        let sent = network.sent
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(network.sent, sent)
        await first.close()     // the process dies
        script.clearPlan()
        switch ResumeCoordinator.coldStart(root: root, id: first.id, currentSize: size, options: options(network)) {
        case .resumed(let second):
            let restored = await second.unacknowledgedInputCount()
            if accepted {
                XCTAssertEqual(restored, before + 13, "type() returned true, the resumed session does not have the input")
            }
            await second.close()
        case .fallback, .retryLater:
            break
        }
    }
}
