import MoshCrypto
import MoshResume
import MoshTransport
import UIKit
import XCTest
@testable import IOSMosh

/// A transport that sends nowhere and hears nothing. A session started on it saves clean (state
/// 0 and its first Resize; docs/notes/multi-session/DESIGN.md section 8).
private final class DroppingTransport: DatagramTransport {
    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
    func send(_ datagram: [UInt8]) {}
    func close() {}
}

/// Stands in for a terminal screen in `testQueuedCommandsRunAfterTheScreenIsGone`: the only
/// owner of its queue, as `TerminalViewController` is.
@MainActor
private final class QueueOwner {
    let queue = SessionQueue()
}

private struct Unexpected: Error, CustomStringConvertible {
    var description: String
}

/// A storage hook that fails one step, the `nth` time it comes, once, after holding it for
/// `hold` seconds (the record's own thread waits, as a slow disk would make it). Says when the
/// held step began, so that a test can act while it is in flight.
private final class FailOneStep: @unchecked Sendable {
    private let file: String
    private let operation: StorageStep.Operation
    private let nth: Int
    private let hold: TimeInterval
    private let lock = NSLock()
    private var seen = 0
    private var holding = false
    private(set) var failed = 0

    init(file: String, operation: StorageStep.Operation, nth: Int = 1, hold: TimeInterval = 0) {
        self.file = file
        self.operation = operation
        self.nth = nth
        self.hold = hold
    }

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    var hook: StorageHook {
        { [self] step in
            guard step.file == file, step.operation == operation else { return .proceed }
            lock.lock()
            seen += 1
            let fails = seen == nth
            if fails { holding = true }
            lock.unlock()
            guard fails else { return .proceed }
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
            lock.lock()
            holding = false
            failed += 1
            lock.unlock()
            return .fail(errno: EIO)
        }
    }
}

/// `SessionQueue` and the terminal screen's slot (DESIGN.md 2.3 rules 1 and 2, 5.3, 5.6; step 8),
/// through the real queue, its consumer and `TerminalViewController`, on a temporary root with
/// coordinators on `DroppingTransport`. A screen that must attach is shown in a window of the
/// app's scene; `attach` writes "last looked at" of the app's own files, which each test clears.
@MainActor
final class SessionQueueTests: XCTestCase {
    private static let size = TerminalSize(width: 80, height: 24)

    private static func options() -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.makeTransport = { DroppingTransport() }
        return options
    }

    private func makeRoot() -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    private func newSession(root: String, options: ResumeCoordinator.Options? = nil) throws -> (ResumeCoordinator, Base64Key) {
        let key = try Base64Key(bytes: [UInt8](repeating: 9, count: 16))
        let meta = SessionMeta(createdAt: 1, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: Self.size)
        let coordinator = try ResumeCoordinator.create(root: root, meta: meta, key: key, storesKey: false,
                                                       initialSize: Self.size, options: options ?? Self.options())
        return (coordinator, key)
    }

    /// A cold start of `id` that must resume.
    private func coldStart(root: String, id: SessionID, key: Base64Key,
                           options: ResumeCoordinator.Options? = nil) throws -> ResumeCoordinator {
        let decision = ResumeCoordinator.coldStart(root: root, id: id, key: .provided(key), currentSize: nil,
                                                   options: options ?? Self.options())
        guard case .resumed(let resumed) = decision else {
            throw Unexpected(description: "the cold start did not resume: \(decision)")
        }
        return resumed
    }

    /// The park of a back (DESIGN.md 2.3) through the real queue and its consumer: `.park` at the
    /// end of the queue, the queue finished, the consumer awaited.
    private func park(_ queue: SessionQueue, attachedRestored: Bool) async {
        XCTAssertTrue(queue.send(.park(BackgroundTask(name: "unit test: park"), attachedRestored: attachedRestored)),
                      "the park is queued")
        queue.finish()
        await queue.consumer?.value
    }

    /// A new session, started: its record is dirty.
    private func startedSession(root: String) async throws -> ResumeCoordinator {
        let (coordinator, _) = try newSession(root: root)
        try await coordinator.start()
        return coordinator
    }

    /// A session saved clean and closed, then cold-started: a resumed coordinator that holds the
    /// record and has not started (nothing written yet, C1).
    private func resumedSession(root: String) async throws -> ResumeCoordinator {
        let (first, key) = try newSession(root: root)
        try await first.start()
        let saved = await first.enterBackground()
        guard saved == .clean else { throw Unexpected(description: "the first life did not save clean: \(saved)") }
        await first.close()
        guard case .resumed(let resumed) = ResumeCoordinator.coldStart(
            root: root, id: first.id, key: .provided(key), currentSize: nil, options: Self.options()) else {
            throw Unexpected(description: "the cold start did not resume")
        }
        return resumed
    }

    private func state(_ root: String, _ id: SessionID) throws -> RecordState {
        try SessionStore(root: root, id: id).readCounters().state
    }

    private func isClean(_ root: String, _ id: SessionID) throws -> Bool {
        Self.isClean(try state(root, id))
    }

    private static func isClean(_ state: RecordState?) -> Bool {
        if case .clean? = state { return true }
        return false
    }

    private func counters(_ root: String, _ id: SessionID) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: SessionStore(root: root, id: id).directory + "/counters"))
    }

    /// Whether a coordinator holds the record (its lock): a second open in this process is refused.
    private func isHeld(_ root: String, _ id: SessionID) throws -> Bool {
        do {
            let record = try SessionRecord.open(root: root, id: id)
            record.close()
            return false
        } catch RecordError.locked {
            return true
        }
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await condition()
    }

    /// The screen in a window of the app's scene, so that it appears and `attach` runs.
    private func show(_ screen: TerminalViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the app's scene")
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = screen
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow?) {
        window?.isHidden = true
        window?.rootViewController = nil
    }

    // MARK: Tests

    /// Rule 1 of DESIGN.md 2.3 and 5.6: the consumer holds the slot, not the screen. Input and a
    /// background save sent just before the screen went (with its queue; nothing is finished by
    /// hand) still run in order, and the queue's end then closes the session: the record is clean
    /// and free.
    func testQueuedCommandsRunAfterTheScreenIsGone() async throws {
        let root = makeRoot()
        let session = try await startedSession(root: root)
        let id = session.id
        XCTAssertEqual(try state(root, id), .dirty, "a started session is dirty")

        var owner: QueueOwner? = QueueOwner()
        owner?.queue.attach(session)
        XCTAssertEqual(owner?.queue.send(.input(Array("echo after\r".utf8))), true)
        XCTAssertEqual(owner?.queue.send(.background(BackgroundTask(name: "unit test: save"))), true)
        let consumer = try XCTUnwrap(owner?.queue.consumer)
        weak let weakQueue = owner?.queue
        owner = nil
        XCTAssertNil(weakQueue, "the queue went with its screen")

        await consumer.value
        XCTAssertTrue(try isClean(root, id), "the save sent before the screen went ran: the record is clean (is \(String(describing: try? state(root, id))))")
        XCTAssertFalse(try isHeld(root, id), "the queue's end closed the session: its lock is free")
        await session.close()
    }

    /// 5.3: an "End Session" leave empties the slot before it hands the session to the ending
    /// code, so the queue's end, which runs at once, does not park or close it: the shutdown
    /// keeps the record for its answer. Meanwhile the session is "ending" (its row reads
    /// "Ending…"). From step 9 a leave without "End Session" parks, so the test confirms the end
    /// first, as the alert's action does.
    func testATakenCoordinatorIsNotClosedByTheQueue() async throws {
        let root = makeRoot()
        let resumed = try await resumedSession(root: root)
        let id = resumed.id
        addTeardownBlock { SessionFiles.clearLastLookedAt(ifNamed: id) }
        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        weak let weakScreen = screen
        var window: UIWindow? = try show(screen!)
        let attached = try await eventually(15) { screen?.liveSessionID == id }
        XCTAssertTrue(attached, "the screen attached the session")
        let started = try await eventually { try self.state(root, id) == .dirty }
        XCTAssertTrue(started, "start() made the record dirty")

        screen?.endFromMenu()
        screen?.leaveScreen()
        XCTAssertTrue(SessionActivity.shared.busy.ending.contains(id), "the session is ending while its shutdown runs")
        var heldThroughout = true
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try !isHeld(root, id) {
                heldThroughout = false
                break
            }
        }
        XCTAssertTrue(heldThroughout, "for 2 s after the leave the shutdown still holds the record: the queue's end did not close it")
        XCTAssertEqual(try state(root, id), .ended, "the shutdown marked the record ended")

        hide(window)
        window = nil
        screen = nil
        let freed = try await eventually { weakScreen == nil }
        XCTAssertTrue(freed, "the screen is freed")
        await resumed.close()
    }

    /// 5.3, step 8: a resumed coordinator in the slot, "End Session" and the leave before
    /// `attach` (`closeOnly`): it is closed and nothing else. The lock is free, the counters are
    /// clean and byte-equal. Step 9 adds the back before `attach` (B7): the park saves nothing
    /// and starts nothing (C11), closes it, and leaves the same.
    func testALeaveBeforeAttachClosesAndKeepsTheRecordClean() async throws {
        let root = makeRoot()
        let resumed = try await resumedSession(root: root)
        let id = resumed.id
        let before = try counters(root, id)
        XCTAssertTrue(try isClean(root, id), "clean before")
        XCTAssertTrue(try isHeld(root, id), "the cold start holds the record")

        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        weak let weakScreen = screen
        XCTAssertTrue(screen?.queue.held === resumed, "the slot holds the resumed coordinator from init")
        XCTAssertEqual(screen?.queue.isAttached, false, "not attached")
        screen?.endFromMenu()
        screen?.leaveScreen()

        let free = try await eventually { try !self.isHeld(root, id) }
        XCTAssertTrue(free, "the leave closed the session: its lock is free")
        XCTAssertEqual(try counters(root, id), before, "the counters are byte-equal")
        XCTAssertTrue(try isClean(root, id), "still clean (is \(String(describing: try? state(root, id))))")

        screen = nil
        let freed = try await eventually { weakScreen == nil }
        XCTAssertTrue(freed, "the screen is freed")

        // B7: the same record resumed again, and the back before `attach`.
        let again = try coldStart(root: root, id: id, key: try Base64Key(bytes: [UInt8](repeating: 9, count: 16)))
        var back: TerminalViewController? = TerminalViewController(start: .resumed(again, host: nil))
        weak let weakBack = back
        back?.leaveScreen()
        let consumer = try XCTUnwrap(back?.queue.consumer)
        await consumer.value
        XCTAssertEqual(back?.queue.lastPark?.savedClean, true, "the park answered clean from the record (C11)")
        XCTAssertEqual(back?.queue.lastPark?.plan, .closeAndKeep, "and kept it")
        XCTAssertFalse(try isHeld(root, id), "the park closed the session: its lock is free")
        XCTAssertEqual(try counters(root, id), before, "the park wrote nothing: the counters are byte-equal")
        back = nil
        let backFreed = try await eventually { weakBack == nil }
        XCTAssertTrue(backFreed, "the screen is freed")
    }

    // MARK: Step 9: back parks

    /// DESIGN.md 2.3, step 9: three lives of one record through the real queue. In each, input
    /// and then the park: afterwards the counters are clean, the lock is free, the slot is empty,
    /// and a cold start resumes the record (lives 2 and 3 are those resumed coordinators, which
    /// the park starts again: it does nothing once `start()` has run).
    func testAParkSavesCleanAndFreesTheRecordThreeTimes() async throws {
        let root = makeRoot()
        let (first, key) = try newSession(root: root)
        let id = first.id
        var coordinator = first
        for life in 1...3 {
            // As `attach` runs `begin`: the session started, so the record is dirty.
            let queue = SessionQueue(root: root)
            queue.attach(coordinator)
            try await coordinator.start()
            XCTAssertEqual(try state(root, id), .dirty, "life \(life): a started session is dirty")
            XCTAssertTrue(queue.send(.input(Array("echo life-\(life)\r".utf8))))
            await park(queue, attachedRestored: coordinator.isRestored)

            XCTAssertNil(queue.held, "life \(life): the park emptied the slot")
            XCTAssertTrue(try isClean(root, id), "life \(life): the park saved the record clean (is \(String(describing: try? state(root, id))))")
            XCTAssertFalse(try isHeld(root, id), "life \(life): the park closed the session: its lock is free")
            XCTAssertEqual(queue.lastPark?.mark, "park-clean", "life \(life): the mark")
            XCTAssertTrue(Self.isClean(queue.lastPark?.stateAfter),
                          "life \(life): the counters after the close, as the park read them")
            coordinator = try coldStart(root: root, id: id, key: key)
            XCTAssertTrue(coordinator.isRestored, "life \(life): the cold start resumed the record")
        }
        await coordinator.close()
    }

    /// 2.3 step 2, B5: the park's first save fails (the snapshot cannot be written, once); 300 ms
    /// later the park saves again, and the record is clean and free. Without the second save it
    /// would stay dirty.
    func testAFailedSaveIsTriedOnceMore() async throws {
        let root = makeRoot()
        let failing = FailOneStep(file: "snapshot.tmp", operation: .write)
        var options = Self.options()
        options.storageHook = failing.hook
        let (session, _) = try newSession(root: root, options: options)
        let id = session.id
        let queue = SessionQueue(root: root)
        queue.attach(session)
        try await session.start()
        await park(queue, attachedRestored: false)

        XCTAssertEqual(failing.failures, 1, "the park's first save failed")
        XCTAssertTrue(try isClean(root, id), "the second save left the record clean (is \(String(describing: try? state(root, id))))")
        XCTAssertFalse(try isHeld(root, id), "the lock is free")
        XCTAssertEqual(queue.lastPark?.savedClean, true, "the park's last save answered clean")
        XCTAssertEqual(queue.lastPark?.plan, .closeAndKeep, "closed and kept")
    }

    /// 2.3 step 1, CL-1: the second slot write of `beginSending` fails once and is slow. The
    /// screen is left (back) while `begin`'s `start()` is still in flight, before it throws, so
    /// nothing at the leave says that it failed. The park calls `start()` again, which completes
    /// the counters change, and then saves: afterwards the park's mark and the counters agree.
    /// Without that call the park answers "clean" from memory while the newest slot says dirty.
    func testAFailedStartIsTriedAgainByThePark() async throws {
        let root = makeRoot()
        let (first, key) = try newSession(root: root)
        let id = first.id
        addTeardownBlock { SessionFiles.clearLastLookedAt(ifNamed: id) }
        try await first.start()
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean, "the first life saved clean")
        await first.close()

        // The cold start writes nothing (C1): the first two counters writes are beginSending's.
        let failing = FailOneStep(file: "counters", operation: .write, nth: 2, hold: 2)
        var options = Self.options()
        options.storageHook = failing.hook
        let resumed = try coldStart(root: root, id: id, key: key, options: options)
        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        weak let weakScreen = screen
        var window: UIWindow? = try show(screen!)
        let inFlight = try await eventually(15) { failing.isHolding }
        XCTAssertTrue(inFlight, "begin's start() is in beginSending's second slot write")
        XCTAssertEqual(screen?.queue.isAttached, true, "attached")
        XCTAssertEqual(failing.failures, 0, "not thrown yet")

        screen?.leaveScreen()
        let consumer = try XCTUnwrap(screen?.queue.consumer)
        await consumer.value

        XCTAssertEqual(failing.failures, 1, "begin's start() failed")
        let report = try XCTUnwrap(screen?.queue.lastPark, "the park ran")
        let after = try SessionStore(root: root, id: id).readCounters().state
        let countersClean = Self.isClean(after)
        XCTAssertEqual(report.savedClean, countersClean,
                       "the park's mark (\(report.mark)) and the counters (\(after)) agree")
        XCTAssertTrue(countersClean, "the park started and saved the session: clean (is \(after))")
        XCTAssertFalse(try isHeld(root, id), "the lock is free")
        let next = try coldStart(root: root, id: id, key: key)
        await next.close()

        hide(window)
        window = nil
        screen = nil
        let freed = try await eventually { weakScreen == nil }
        XCTAssertTrue(freed, "the screen is freed")
    }

    /// CL-S1, 2.3 rule 2: a resign with the slot filled and not attached queues nothing (the
    /// policy notes it); `attach` then queues the save before `start()`, so the start is deferred
    /// and nothing is written. Afterwards the screen is freed without being left, and the
    /// queue's end closes the session (5.6).
    func testAResignBeforeAttachIsSavedAtAttach() async throws {
        let root = makeRoot()
        let resumed = try await resumedSession(root: root)
        let id = resumed.id
        addTeardownBlock { SessionFiles.clearLastLookedAt(ifNamed: id) }
        let before = try counters(root, id)

        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        weak let weakScreen = screen
        screen?.sceneWillResignActive()
        XCTAssertEqual(screen?.queue.recentCommands ?? ["no screen"], [],
                       "a resign with the slot filled and not attached queues nothing")

        var window: UIWindow? = try show(screen!)
        let attached = try await eventually(15) { screen?.liveSessionID == id }
        XCTAssertTrue(attached, "the screen attached the session")
        XCTAssertEqual(screen?.queue.recentCommands.first, "background", "attach queued the save first")
        let saved = try await eventually { await resumed.isInBackground }
        XCTAssertTrue(saved, "the save reached the session before its start")
        // start() and the rest of attach have run by now; the start is deferred.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(try counters(root, id), before, "nothing was written: the start waits for the return (C11)")
        XCTAssertTrue(try isClean(root, id), "still clean (is \(String(describing: try? state(root, id))))")

        hide(window)
        window = nil
        screen = nil
        let freed = try await eventually { weakScreen == nil }
        XCTAssertTrue(freed, "the screen is freed")
        let free = try await eventually { try !self.isHeld(root, id) }
        XCTAssertTrue(free, "the queue's end closed the session that was still in the slot")
        XCTAssertTrue(try isClean(root, id), "and left the record clean")
    }
}
