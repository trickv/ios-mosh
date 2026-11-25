import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

/// Counts the sockets opened and the datagrams handed to them; nothing leaves, nothing arrives.
final class CountingDeadNetwork: @unchecked Sendable {
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
        let network: CountingDeadNetwork
        init(network: CountingDeadNetwork) { self.network = network }
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {
            network.lock.lock()
            network.sentCount += 1
            network.lock.unlock()
        }
        func close() {}
    }
}

/// One test (or a few) per surviving finding of the review of `MoshResume`
/// (docs/notes/review-resume/refutation.md). Each was seen failing on the code before its fix.
final class ReviewFixTests: XCTestCase {
    let size = TerminalSize(width: 80, height: 24)

    func options(_ network: CountingDeadNetwork, hook: StorageHook? = nil) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.blocks = GateCounters(sequence: 4, state: 2, fragmentID: 2)
        options.storageHook = hook
        options.noReplyTimeout = nil
        options.makeTransport = network.makeTransport
        return options
    }

    /// A started session that has typed something.
    func newSession(root: String, network: CountingDeadNetwork, hook: StorageHook? = nil,
                    storesKey: Bool = true) async throws -> ResumeCoordinator {
        let coordinator = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       storesKey: storesKey, initialSize: size,
                                                       options: options(network, hook: hook))
        try await coordinator.start()
        _ = await coordinator.type(Array("ls\r".utf8))
        return coordinator
    }

    // MARK: A-1: create over an existing record

    /// `create` over a record that exists (its holder gone) must not hand the session a second
    /// set of counters under the same key (N1).
    func testA1_CreateOverAnExistingRecordIsRefused() throws {
        let root = try scratchRoot("review")
        let first = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        var used: [UInt64] = []
        for _ in 0..<5 {
            used.append(try first.gate.takeSequenceNumber())
            try first.gate.willSendDatagram()
        }
        first.close()
        XCTAssertThrowsError(try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)) {
            XCTAssertEqual($0 as? RecordError, .exists)
        }
        // The record is as it was: the next number is above every one used.
        let reopened = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertEqual(try reopened.readKey(), Fixtures.key)
        XCTAssertGreaterThan(try reopened.gate.takeSequenceNumber(), used.max()!)
        reopened.close()
    }

    func testA1_CreateOverAHeldRecordIsRefused() throws {
        let root = try scratchRoot("review")
        let first = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertThrowsError(try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)) {
            XCTAssertEqual($0 as? RecordError, .exists)
        }
        XCTAssertEqual(try first.gate.takeSequenceNumber(), 0)
        first.close()
    }

    /// The same through the call the app has.
    func testA1_TheCoordinatorDoesNotCreateTwice() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let meta = Fixtures.meta()
        let one = try ResumeCoordinator.create(root: root, meta: meta, key: Fixtures.key, initialSize: size,
                                               options: options(network))
        try await one.start()
        _ = await one.type(Array("ls\r".utf8))
        await one.close()
        XCTAssertGreaterThan(network.sent, 0)
        let before = try SessionStore(root: root, id: meta.id).readCounters()
        XCTAssertThrowsError(try ResumeCoordinator.create(root: root, meta: meta, key: Fixtures.key, initialSize: size,
                                                          options: options(network))) {
            XCTAssertEqual($0 as? RecordError, .exists)
        }
        XCTAssertEqual(try SessionStore(root: root, id: meta.id).readCounters(), before, "the counters were touched")
    }

    /// A create that fails on the way (not a crash) leaves nothing, so the same id can be tried
    /// again; nothing was sent under the key yet.
    func testA1_AFailedCreateLeavesNothingAndCanBeRepeated() throws {
        let probe = StepScript()
        try SessionRecord.create(root: try scratchRoot("review"), meta: Fixtures.meta(), key: Fixtures.key, hook: probe.hook).close()
        let total = probe.count
        for stepIndex in 2..<total {       // after `dir.mkdir`
            let root = try scratchRoot("review")
            let script = StepScript()
            script.at(stepIndex, .fail(errno: ENOSPC))
            XCTAssertThrowsError(try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook),
                                 "step \(stepIndex)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/" + Fixtures.id.description),
                           "step \(stepIndex) (\(probe.steps[stepIndex])): something was left behind")
            let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook)
            XCTAssertEqual(try record.gate.takeSequenceNumber(), 0)
            record.close()
        }
    }

    // MARK: B-1: a record that was given up still owes a new session

    private func fallback(_ outcome: ColdStartOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> ColdStartFallback {
        guard case .fallback(let fallback) = outcome else {
            XCTFail("not a fallback: \(outcome)", file: file, line: line)
            throw XCTSkip("not a fallback")
        }
        return fallback
    }

    /// The app dies (or has no network) between the fallback and the new bootstrap. Every later
    /// start must still say that a new session is wanted, with `meta` for it.
    func testB1_AFallbackThatTheAppDidNotFinishStillWantsANewSession() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network)
        await first.close()     // died in the foreground: dirty
        let sent = network.sent, opened = network.opened
        for start in 1...3 {
            let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                options: options(network)))
            XCTAssertEqual(dead.reason, .dirty, "start \(start)")
            XCTAssertTrue(dead.wantsNewSession, "start \(start) says \(dead.reason): the session is dropped and the old server never killed")
            XCTAssertEqual(dead.meta?.id, first.id)
            XCTAssertFalse(dead.recordDeleted)
        }
        XCTAssertEqual(network.sent, sent)
        XCTAssertEqual(network.opened, opened)
        try ResumeCoordinator.deleteRecord(root: root, id: first.id)
    }

    /// The same for a record whose snapshot cannot be used: the first fallback names the
    /// damage, and no later start drops the session.
    func testB1_AFallbackForADamagedSnapshotStillWantsANewSessionLater() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()
        XCTAssertEqual(unlink("\(root)/\(first.id)/snapshot"), 0)
        let one = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                           options: options(network)))
        XCTAssertEqual(one.reason, .missing(.snapshot))
        let two = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                           options: options(network)))
        XCTAssertTrue(two.wantsNewSession, "second start says \(two.reason)")
        XCTAssertEqual(two.meta?.id, first.id)
    }

    /// "Start new session" under the banner, and the app dies before the bootstrap.
    func testB1_AnAbandonedSessionStillWantsANewSession() async throws {
        for background in [false, true] {
            let root = try scratchRoot("review")
            let network = CountingDeadNetwork()
            let first = try await newSession(root: root, network: network)
            if background {
                let saved = await first.enterBackground()
                XCTAssertEqual(saved, .clean)
            }
            await first.abandon()
            let sent = network.sent
            let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                options: options(network)))
            XCTAssertEqual(dead.reason, .dirty, "background \(background)")
            XCTAssertTrue(dead.wantsNewSession)
            XCTAssertEqual(network.sent, sent)
        }
    }

    /// Only a session that was ended on purpose says "ended", and it still hands `meta` over
    /// (the shutdown request may never have arrived; the app checks for the old server).
    func testB1_AShutDownSessionSaysEndedWithMeta() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network)
        _ = await first.shutdown()
        await first.close()
        for _ in 1...2 {
            let dead = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                options: options(network)))
            XCTAssertEqual(dead.reason, .ended)
            XCTAssertFalse(dead.wantsNewSession)
            XCTAssertEqual(dead.meta?.id, first.id)
        }
    }

    // MARK: B-7: the key's source is said, never guessed

    /// A record made without a key file (iOS), asked for its key file: a fallback that changes
    /// nothing, so the right call still resumes.
    func testB7_AskingARecordWithoutAKeyFileForItsKeyDoesNotEndIt() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network, storesKey: false)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()
        let sent = network.sent
        let wrong = try fallback(ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                             options: options(network)))
        XCTAssertEqual(wrong.reason, .missing(.key))
        XCTAssertEqual(network.sent, sent)
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .provided(Fixtures.key),
                                                                      currentSize: size, options: options(network)) else {
            return XCTFail("the keyed start does not resume")
        }
        await second.close()
    }

    // MARK: A-6 + B-4: an "ended" mark that could not be written

    /// The first slot says "ended", the second write fails. Whatever the gate writes next
    /// completes the mark; nothing writes "dirty" over it, and nothing marks the record clean.
    func testA6_AHalfWrittenEndedMarkIsCompletedNeverOverwritten() throws {
        for next in ["markDirty", "willSendDatagram", "take", "beginSending"] {
            let root = try scratchRoot("review")
            let script = StepScript()
            let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key,
                                                  blocks: GateCounters(sequence: 1, state: 1, fragmentID: 1), hook: script.hook)
            _ = try record.gate.takeSequenceNumber()
            try record.gate.willSendDatagram()
            script.at(script.count + 2, .fail(errno: EIO))      // third step of markEnded: the second slot's write
            XCTAssertThrowsError(try record.gate.markEnded())
            XCTAssertEqual(try record.store.readCounters().state, .ended, "the first slot holds the mark")
            XCTAssertEqual(record.state, .ended, "the gate remembers what it was told")
            XCTAssertFalse(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(),
                                                         cleanToken: CleanToken(datagramsPassed: record.gate.datagramsPassed))),
                           "an ended record is never clean again")
            switch next {
            case "markDirty": try record.gate.markDirty()        // what the coordinator did after the failure
            case "willSendDatagram": try record.gate.willSendDatagram()
            case "take": _ = try record.gate.takeSequenceNumber()
            default: try record.gate.beginSending()
            }
            record.close()
            let image = Array(try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(Fixtures.id)/counters")))
            let slots: [RecordState?] = (0..<2).map { slot in
                let start = CountersFile.offset(ofSlot: slot)
                return (try? CountersSlot(encoded: Array(image[start..<(start + CountersFile.slotSize)]), expecting: Fixtures.id))?.state
            }
            XCTAssertEqual(slots, [.ended, .ended], "after \(next)")
        }
    }

    /// With the mark not durable, no datagram passes on the strength of "ended" in memory.
    func testA6_NoDatagramPassesWhileTheEndedMarkCannotBeWritten() throws {
        let root = try scratchRoot("review")
        let script = StepScript()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook)
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        for index in 0..<8 { script.at(script.count + index, .fail(errno: EPERM)) }
        XCTAssertThrowsError(try record.gate.markEnded())
        XCTAssertThrowsError(try record.gate.willSendDatagram(), "the disk still says clean")
        XCTAssertEqual(record.gate.datagramsPassed, 0)
        script.clearPlan()
        try record.gate.willSendDatagram()
        XCTAssertEqual(try record.store.readCounters().state, .ended)
    }

    /// A shutdown asked for in the background while nothing can be written: the record still
    /// says clean, so the request is refused (as input is), and nothing changes. The session
    /// then resumes, and background input still goes the M9 way.
    func testB4_AShutdownThatCannotBeRecordedIsRefused() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let before = await first.unacknowledgedInputCount()
        for index in 0..<40 { script.at(script.count + index, .fail(errno: EPERM)) }
        let running = await first.shutdown()
        XCTAssertFalse(running, "the shutdown was accepted although the record still says clean")
        let ended = await first.hasEnded
        XCTAssertFalse(ended)
        var state = await first.recordState
        guard case .clean = state else { return XCTFail("\(state)") }
        // Still refused, like the shutdown.
        let refused = await first.type(Array("x".utf8))
        XCTAssertFalse(refused)
        // The device is unlocked again: input in the background is stored before it is taken.
        script.clearPlan()
        let typed = await first.type(Array("late".utf8))
        XCTAssertTrue(typed)
        state = await first.recordState
        guard case .clean = state else { return XCTFail("after background input the record is \(state)") }
        await first.close()
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                      options: options(network)) else {
            return XCTFail("a session whose shutdown was refused did not resume")
        }
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, before + 4)
        // And a shutdown that can be recorded ends it.
        try await second.start()
        _ = await second.enterBackground()
        let accepted = await second.shutdown()
        XCTAssertTrue(accepted)
        await second.close()
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                     options: options(network)) else {
            return XCTFail("a session the user closed came back")
        }
        XCTAssertEqual(dead.reason, .ended)
    }

    /// "Dirty" can be written, "ended" cannot: the shutdown goes on (the record is not clean, so
    /// the closed session cannot come back), and the next write the gate makes says "ended".
    func testB4_AnEndedMarkThatFailedIsCompletedAtTheNextWrite() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        script.at(script.count + 4, .fail(errno: EIO))      // after the four steps of "dirty"
        let running = await first.shutdown()
        XCTAssertTrue(running)
        let ended = await first.hasEnded
        XCTAssertTrue(ended)
        XCTAssertEqual(try SessionStore(root: root, id: first.id).readCounters().state, .dirty)
        let again = await first.enterBackground()
        XCTAssertEqual(again, .notResumable(.ended))
        await first.enterForeground()       // writes; the shutdown request may now leave
        XCTAssertEqual(try SessionStore(root: root, id: first.id).readCounters().state, .ended)
        await first.close()
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                     options: options(network)) else {
            return XCTFail("a session the user closed came back")
        }
        XCTAssertEqual(dead.reason, .ended)
    }

    // MARK: A-3 + B-3: a second save of a clean record

    /// `enterBackground()` again while in the background and clean (the app switcher,
    /// `sceneDidEnterBackground` after `sceneWillResignActive`): nothing was sent and nothing
    /// changed, so nothing is written, and no process death during the call can cost the record.
    func testB3_ASecondSaveNeverMakesAResumableRecordUnresumable() async throws {
        var lost: [String] = []
        for step in 0..<7 {
            for action in [StorageHookAction.crashBefore, .crashAfter] {
                let root = try scratchRoot("review")
                let network = CountingDeadNetwork()
                let script = StepScript()
                let first = try await newSession(root: root, network: network, hook: script.hook)
                let saved = await first.enterBackground()
                XCTAssertEqual(saved, .clean)
                let steps = script.count
                script.at(steps + step, action)
                let again = await first.enterBackground()
                XCTAssertEqual(again, .clean)
                XCTAssertEqual(script.count, steps, "the second call wrote something")
                await first.close()
                switch ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                   options: options(network)) {
                case .resumed(let second): await second.close()
                case .fallback(let fallback): lost.append("step \(step) \(action): \(fallback.reason)")
                case .retryLater(let retry): XCTFail("\(retry)")
                }
            }
        }
        XCTAssertEqual(lost, [], "nothing was sent and nothing changed, yet the session is dead")
    }

    /// After a return to the foreground, and after input in the background, the next
    /// `enterBackground()` saves as before.
    func testB3_ASaveStillHappensWhenSomethingChanged() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let script = StepScript()
        let first = try await newSession(root: root, network: network, hook: script.hook)
        _ = await first.enterBackground()
        await first.enterForeground()
        _ = await first.type(Array("pwd\r".utf8))
        let pending = await first.unacknowledgedInputCount()
        var steps = script.count
        var saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        XCTAssertGreaterThan(script.count, steps)
        // A save that failed leaves the record not clean: the next call tries again.
        _ = await first.type(Array("x".utf8))
        script.at(script.count + 4, .fail(errno: ENOSPC))    // the snapshot of the M9 save; "dirty" is written
        _ = await first.type(Array("y".utf8))
        var state = await first.recordState
        XCTAssertEqual(state, .dirty)
        steps = script.count
        saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        XCTAssertGreaterThan(script.count, steps)
        state = await first.recordState
        guard case .clean = state else { return XCTFail("\(state)") }
        await first.close()
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                      options: options(network)) else {
            return XCTFail("not resumed")
        }
        let restored = await second.unacknowledgedInputCount()
        XCTAssertEqual(restored, pending + 2)
        await second.close()
    }

    // MARK: B-2: nothing reaches the session before start()

    /// The terminal view reports its size at first layout, before the app called `start()` (or
    /// after `start()` threw its storage error); then the app leaves the foreground. Nothing
    /// may be sent, the record stays clean, and the session is still there afterwards.
    func testB2_InputBeforeStartSendsNothingAndKeepsTheRecord() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        let pending = await first.unacknowledgedInputCount()
        await first.close()

        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                      options: options(network)) else {
            return XCTFail("not resumed")
        }
        let sent = network.sent, opened = network.opened
        let resized = await second.resize(TerminalSize(width: 100, height: 30))
        XCTAssertTrue(resized, "the size is kept for start()")
        let typed = await second.type(Array("x".utf8))
        XCTAssertFalse(typed, "no input before start()")
        XCTAssertEqual(network.opened, opened, "a socket was opened before start()")
        XCTAssertEqual(network.sent, sent, "a datagram left before start()")
        var state = await second.recordState
        if case .clean = state {} else { XCTFail("the record is \(state) before start()") }
        // The app goes to the background, start() still not called.
        let outcome = await second.enterBackground()
        XCTAssertEqual(outcome, .clean, "the stored snapshot is still the truth")
        // A start() that arrives now waits for the foreground.
        try await second.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(network.sent, sent, "sending in the background")
        XCTAssertEqual(network.opened, opened)
        state = await second.recordState
        if case .clean = state {} else { XCTFail("the record is \(state) in the background") }
        await second.close()

        // Killed there: the session is not lost.
        guard case .resumed(let third) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                     options: options(network)) else {
            return XCTFail("the session is lost")
        }
        // The size reported before start() is announced once the session starts.
        _ = await third.resize(TerminalSize(width: 90, height: 20))
        _ = await third.resize(TerminalSize(width: 100, height: 30))
        let before = await third.unacknowledgedInputCount()
        XCTAssertEqual(before, pending)
        try await third.start()
        let after = await third.unacknowledgedInputCount()
        XCTAssertEqual(after, pending + 1, "the latest size, once")
        XCTAssertGreaterThan(network.sent, sent)
        await third.close()
    }

    /// A start() asked for in the background happens at the return to the foreground.
    func testB2_AStartAskedForInTheBackgroundHappensInTheForeground() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let coordinator = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       initialSize: size, options: options(network))
        let early = await coordinator.type(Array("x".utf8))
        XCTAssertFalse(early)
        let outcome = await coordinator.enterBackground()
        XCTAssertNotEqual(outcome, .clean, "a new session that never started has no snapshot")
        try await coordinator.start()
        XCTAssertEqual(network.opened, 0)
        await coordinator.enterForeground()
        let typed = await coordinator.type(Array("ls\r".utf8))
        XCTAssertTrue(typed)
        XCTAssertGreaterThan(network.sent, 0)
        let saved = await coordinator.enterBackground()
        XCTAssertEqual(saved, .clean)
        await coordinator.close()
    }

    // MARK: A-4: the clean mark names the snapshot it is given

    /// A save that was refused (a datagram left after its export) must leave nothing behind
    /// that a later call could mark clean: there is no clean mark on the gate's own word.
    func testA4_ARefusedSaveLeavesNoSnapshotIDToMark() throws {
        let root = try scratchRoot("review")
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let gate = record.gate
        _ = try gate.takeSequenceNumber()
        try gate.willSendDatagram()
        var snapshot = Fixtures.minimalSnapshot()
        snapshot.transport.receiverExpectedSequence = 1                 // the world after one datagram
        let exported = SessionExport(snapshot: snapshot, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
        _ = try gate.takeSequenceNumber()
        try gate.willSendDatagram()                                     // a second datagram leaves
        XCTAssertFalse(try record.save(exported))                       // refused, as it must be
        // Somebody reads the count afresh and asks the gate directly.
        XCTAssertThrowsError(try gate.markClean(ifDatagramsPassed: gate.datagramsPassed)) {
            XCTAssertEqual($0 as? FileGateError, .noSnapshotStored)
        }
        XCTAssertThrowsError(try gate.markClean(CleanToken(datagramsPassed: gate.datagramsPassed)))
        XCTAssertEqual(record.state, .dirty)
        record.close()
        let reopened = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertEqual(reopened.state, .dirty)
        XCTAssertThrowsError(try reopened.loadSnapshot(), "a snapshot older than a datagram was loaded")
        reopened.close()
    }

    // MARK: A-5: one gate per lock

    func testA5_ASecondGateOnOneLockIsRefused() throws {
        let root = try scratchRoot("review")
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        record.close()
        let store = SessionStore(root: root, id: Fixtures.id)
        let lock = try store.acquireLock()
        let first = try FileBackedGate(store: store, lock: lock)
        XCTAssertThrowsError(try FileBackedGate(store: store, lock: lock), "two gates on one lock hand out the same numbers") {
            XCTAssertEqual($0 as? FileGateError, .lockHasAGate)
        }
        XCTAssertEqual(try first.takeSequenceNumber(), 0)
    }

    // MARK: A-7: only "no such file" means missing

    /// The cold start cannot tell whether the record is there (here: the path to it loops; on
    /// the phone it would be a denial). That is "try again later", with the record untouched:
    /// not "missing", which the cold start answers with a fallback and a deletion.
    func testA7_ARecordThatCannotBeLookedAtIsRetriedLaterNotDeclaredMissing() async throws {
        let root = try scratchRoot("review")
        let network = CountingDeadNetwork()
        let first = try await newSession(root: root, network: network)
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()

        // The records move aside and `root` becomes a link to itself: every look at the record
        // fails with ELOOP, which is not ENOENT.
        let aside = root + ".aside"
        XCTAssertEqual(rename(root, aside), 0)
        XCTAssertEqual(symlink(root, root), 0)
        let outcome = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                  options: options(network))
        guard case .retryLater(.storage) = outcome else {
            XCTAssertEqual(unlink(root), 0)
            return XCTFail("a record that could not be looked at was declared: \(outcome)")
        }
        XCTAssertThrowsError(try ResumeCoordinator.deleteRecord(root: root, id: first.id),
                             "deleteRecord reported success for a record it could not see")
        XCTAssertThrowsError(try SessionStore(root: root, id: first.id).exists)
        XCTAssertEqual(unlink(root), 0)
        XCTAssertEqual(rename(aside, root), 0)

        // The record is as it was.
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: first.id, key: .recordFile, currentSize: size,
                                                                      options: options(network)) else {
            return XCTFail("not resumed")
        }
        await second.close()
    }

    func testA7_OnlyNoSuchFileMeansMissing() throws {
        XCTAssertEqual(Storage.presence(afterErrno: ENOENT), .missing)
        for code in [EACCES, EPERM, EIO, ELOOP, ENOTDIR, ENAMETOOLONG, EINTR, ENOMEM] {
            XCTAssertEqual(Storage.presence(afterErrno: code), .unknown, "errno \(code)")
        }
        // And on a real directory.
        let root = try scratchRoot("review")
        let store = SessionStore(root: root, id: Fixtures.id)
        XCTAssertFalse(try store.exists)
        XCTAssertThrowsError(try store.readCounters()) { XCTAssertEqual($0 as? RecordError, .missing(.counters)) }
        XCTAssertThrowsError(try store.acquireLock()) { XCTAssertEqual($0 as? RecordError, .missing(.meta)) }
        try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key).close()
        XCTAssertTrue(try store.exists)
        XCTAssertEqual(unlink(store.directory + "/counters"), 0)
        XCTAssertThrowsError(try store.readCounters()) { XCTAssertEqual($0 as? RecordError, .missing(.counters)) }
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordError, .missing(.counters))
        }
    }

    // MARK: A-8: a failed full sync is not replaced by a plain one

    func testA8_WhatFollowsAFailedFullSync() {
        XCTAssertEqual(Storage.afterFullSyncFailure(errno: EINTR), .retry)
        for code in Storage.fullSyncNotSupportedErrors {
            XCTAssertEqual(Storage.afterFullSyncFailure(errno: code), .fallBackToFsync, "errno \(code)")
        }
        for code in [EIO, EBADF, ENOSPC, EDQUOT, EACCES, EPERM, EAGAIN, ENOLCK, EINVAL, EROFS, ENOMEM]
        where !Storage.fullSyncNotSupportedErrors.contains(code) {
            XCTAssertEqual(Storage.afterFullSyncFailure(errno: code), .fail, "errno \(code)")
        }
    }

    /// The sync as a whole, with the system calls played: an interrupted full sync is repeated,
    /// a failed one fails (the plain sync is not even called), and only "not supported" falls
    /// back to the plain sync.
    func testA8_TheSyncWithPlayedCalls() {
        final class Calls: @unchecked Sendable {
            var fullResults: [Int32]
            var plainResults: [Int32]
            var full = 0, plain = 0, last: Int32 = 0
            init(full: [Int32], plain: [Int32] = []) { fullResults = full; plainResults = plain }
            func run(hasFull: Bool = true) -> Int32? {
                func next(_ results: inout [Int32]) -> Int32 {
                    let code = results.isEmpty ? 0 : results.removeFirst()
                    last = code
                    return code == 0 ? 0 : -1
                }
                return Storage.durableSync(full: hasFull ? { self.full += 1; return next(&self.fullResults) } : nil,
                                           plain: { self.plain += 1; return next(&self.plainResults) },
                                           lastError: { self.last })
            }
        }
        var calls = Calls(full: [])
        XCTAssertNil(calls.run())
        XCTAssertEqual([calls.full, calls.plain], [1, 0])

        calls = Calls(full: [EINTR, EINTR])
        XCTAssertNil(calls.run(), "an interrupted full sync is repeated, not replaced")
        XCTAssertEqual([calls.full, calls.plain], [3, 0])

        calls = Calls(full: [EIO])
        XCTAssertEqual(calls.run(), EIO)
        XCTAssertEqual([calls.full, calls.plain], [1, 0], "a plain fsync after a failed full sync would report success")

        if let unsupported = Storage.fullSyncNotSupportedErrors.first {
            calls = Calls(full: [unsupported])
            XCTAssertNil(calls.run())
            XCTAssertEqual([calls.full, calls.plain], [1, 1])
            calls = Calls(full: [unsupported], plain: [EINTR, EIO])
            XCTAssertEqual(calls.run(), EIO)
            XCTAssertEqual([calls.full, calls.plain], [1, 2])
        }

        // No full sync on this platform (Linux): the plain one, repeated when interrupted.
        calls = Calls(full: [], plain: [EINTR])
        XCTAssertNil(calls.run(hasFull: false))
        XCTAssertEqual([calls.full, calls.plain], [0, 2])
        calls = Calls(full: [], plain: [ENOSPC])
        XCTAssertEqual(calls.run(hasFull: false), ENOSPC)
    }
}
