import MoshCrypto
import MoshResume
import MoshTransport
import UIKit
import XCTest
@testable import IOSMosh

/// Sends nowhere and hears nothing (as in `SessionQueueTests`): a session started on it saves
/// clean (DESIGN.md section 8). The connection still counts what it sends.
private final class NowhereTransport: DatagramTransport {
    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
    func send(_ datagram: [UInt8]) {}
    func close() {}
}

/// A storage hook that holds every write of one file for `hold` seconds and then lets it
/// proceed (a slow disk), and says whether it held one.
private final class SlowWrite: @unchecked Sendable {
    private let file: String
    private let hold: TimeInterval
    private let lock = NSLock()
    private var count = 0

    init(file: String, hold: TimeInterval) {
        self.file = file
        self.hold = hold
    }

    var held: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var hook: StorageHook {
        { [self] step in
            guard step.file == file, step.operation == .write else { return .proceed }
            Thread.sleep(forTimeInterval: hold)
            lock.lock()
            count += 1
            lock.unlock()
            return .proceed
        }
    }
}

private struct Unexpected: Error, CustomStringConvertible {
    var description: String
}

/// `SessionActivity` (docs/notes/multi-session/DESIGN.md 2.2, 2.4 G2, section 7; step 8): the
/// tail of releases that `settled()` waits for, and the pure `Busy` that decides what a row and
/// the launch's retry may do. On instances of their own, not `shared`, except where the real
/// terminal screen and its queue are used (step 10: they track their releases in `shared`).
///
/// Step 10: the open of a tap (`SessionListViewController.open`, DESIGN.md 4.5) waits for the
/// settle and then asks the gate (`OpenGate`, G3); a leave's park is a tracked release, so an
/// open after it finds the record free (rule 1 of section 7); and a resign during the pop of a
/// confirmed "End Session" leaves the shutdown to be sent.
@MainActor
final class SessionActivityTests: XCTestCase {
    /// Opened by the test; a release waits on it.
    @MainActor
    private final class Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// G2: `settled()` returns only once every release tracked before it has returned, also when
    /// a later one returns first. Meanwhile each record reads "being saved".
    func testSettledWaitsForATrackedRelease() async throws {
        let activity = SessionActivity()
        let changes = Counter()
        activity.onChange = { changes.value += 1 }
        let a = SessionID.random(), b = SessionID.random()
        let first = Latch(), second = Latch()
        activity.track(release: a) { await first.wait() }
        activity.track(release: b) { await second.wait() }
        XCTAssertEqual(activity.busy.parking, [a, b], "both read \"Saving…\" while their release is in flight")
        XCTAssertEqual(changes.value, 2, "each track is a change")

        let settled = Flag()
        let waiter = Task { @MainActor in
            await activity.settled()
            settled.value = true
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(settled.value, "settled() waits while both releases are in flight")

        second.open()
        let laterReturned = try await eventually { !activity.busy.parking.contains(b) }
        XCTAssertTrue(laterReturned, "the later release returned")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(settled.value, "settled() still waits for the earlier release")
        XCTAssertEqual(activity.busy.parking, [a])

        first.open()
        await waiter.value
        XCTAssertTrue(settled.value, "settled() returned once both had returned")
        XCTAssertEqual(activity.busy.parking, [], "nothing is being saved any more")
        XCTAssertEqual(changes.value, 4, "each return is a change too")

        // Nothing in flight: it returns at once.
        await activity.settled()
    }

    /// Two shutdowns of one record (a row's end over SSH still running when the record is
    /// resumed and ended from the terminal): it reads "ending", and takes no tap and no swipe,
    /// until both have finished, whichever finishes first. A finish with none in flight changes
    /// nothing.
    func testAnEndBegunTwiceIsEndingUntilBothHaveFinished() {
        let activity = SessionActivity()
        let changes = Counter()
        activity.onChange = { changes.value += 1 }
        let a = SessionID.random(), b = SessionID.random()

        activity.beginEnd(a)
        activity.beginEnd(a)
        activity.beginEnd(b)
        XCTAssertEqual(activity.busy.ending, [a, b], "both read \"Ending…\"")
        activity.endFinished(a)
        XCTAssertTrue(activity.busy.ending.contains(a), "still ending after the first of its two ends finished")
        XCTAssertFalse(activity.busy.mayTap(session: a), "no tap while the other end runs (S8)")
        XCTAssertFalse(activity.busy.maySwipe(session: a), "no swipe while the other end runs (R6)")
        activity.endFinished(a)
        XCTAssertEqual(activity.busy.ending, [b], "no longer ending once both have finished")
        activity.endFinished(a)
        XCTAssertEqual(activity.busy.ending, [b], "a finish with none in flight changes nothing")
        activity.endFinished(b)
        XCTAssertEqual(activity.busy.ending, [], "nothing is ending")
        XCTAssertEqual(changes.value, 6, "each begin and each finish of one in flight is a change")
    }

    /// The rows of DESIGN.md 2.2, 3.1 (H2, H4), 3.2 (S2, S8), 3.4 (R6) and 3.5 (W6).
    func testBusyDecidesTapSwipeAndRetry() {
        typealias Busy = SessionActivity.Busy
        let a = SessionID.random(), b = SessionID.random()

        let idle = Busy()
        XCTAssertTrue(idle.mayTap(session: a), "idle: a tap")
        XCTAssertTrue(idle.maySwipe(session: a), "idle: a swipe")
        XCTAssertTrue(idle.mayTapHost, "idle: a host tap")
        XCTAssertFalse(idle.mayRetry, "idle: the launch waits for nothing")

        let parking = Busy(parking: [a])
        XCTAssertTrue(parking.mayTap(session: a), "a row being saved takes a tap: the open waits for the save (S2)")
        XCTAssertFalse(parking.maySwipe(session: a), "no swipe on a row being saved (R6)")
        XCTAssertTrue(parking.mayTap(session: b), "another row is not concerned")
        XCTAssertTrue(parking.maySwipe(session: b), "another row keeps its swipe")
        XCTAssertTrue(parking.mayTapHost, "a new session while another is being saved (H2)")

        let ending = Busy(ending: [a])
        XCTAssertFalse(ending.mayTap(session: a), "no tap on a row being ended (S8)")
        XCTAssertFalse(ending.maySwipe(session: a), "no swipe on a row being ended (R6)")
        XCTAssertTrue(ending.mayTap(session: b), "another row takes a tap")
        XCTAssertTrue(ending.maySwipe(session: b), "another row keeps its swipe")
        XCTAssertTrue(ending.mayTapHost, "a host tap ignores \"ending\" (step 8)")

        let opening = Busy(opening: true, waiting: a)
        XCTAssertFalse(opening.mayTap(session: b), "no other tap while an open is in flight (2.2)")
        XCTAssertFalse(opening.mayTapHost, "no host tap while an open is in flight (H4)")
        XCTAssertFalse(opening.maySwipe(session: b), "no swipe while an open is in flight (R6)")
        XCTAssertFalse(opening.mayRetry, "the launch's retry does not run while an open is in flight (2.2, W6)")

        let waiting = Busy(waiting: a)
        XCTAssertTrue(waiting.mayRetry, "the launch asks again for the session it waits for (W6)")
        XCTAssertTrue(waiting.mayTap(session: a), "the wait takes nothing from the rows")
        XCTAssertTrue(waiting.maySwipe(session: a))
        XCTAssertTrue(waiting.mayTapHost)
    }

    // MARK: Step 10: taps wait

    /// G3, 3.1 H5, 3.5 W7: the gate is asked after the settle, not at the tap. A tap is taken
    /// while a release is in flight and waits for it; the scene stops being active meanwhile
    /// (Control Centre, the Home gesture); when the release returns the tap is dropped: nothing
    /// is opened, and "opening" is cleared. The next tap, with the scene active, opens, and
    /// "opening" stays set until the list appears again (a screen was pushed). Through the
    /// open's own sequence (`SessionListViewController.open`) and the real gate (`OpenGate`).
    func testATapIsDroppedWhenTheSceneIsNotActiveAfterTheSettle() async throws {
        XCTAssertTrue(OpenGate.mayOpen(sceneIsActive: true, listIsOnTop: true, terminalIsOpen: false),
                      "active, the list on top, no terminal: the tap goes on")
        XCTAssertFalse(OpenGate.mayOpen(sceneIsActive: false, listIsOnTop: true, terminalIsOpen: false),
                       "the scene is not active (H5)")
        XCTAssertFalse(OpenGate.mayOpen(sceneIsActive: true, listIsOnTop: false, terminalIsOpen: false),
                       "another screen is on top of the list")
        XCTAssertFalse(OpenGate.mayOpen(sceneIsActive: true, listIsOnTop: true, terminalIsOpen: true),
                       "a terminal screen is open")

        let activity = SessionActivity()
        let release = Latch()
        activity.track(release: SessionID.random()) { await release.wait() }
        let sceneIsActive = Flag()
        sceneIsActive.value = true
        let opened = Counter()
        let gate: @MainActor () -> Bool = {
            OpenGate.mayOpen(sceneIsActive: sceneIsActive.value, listIsOnTop: true, terminalIsOpen: false)
        }

        let tap = try XCTUnwrap(SessionListViewController.open("unit test row", activity: activity, mayOpen: gate) {
            opened.value += 1
            return true
        }, "the tap is taken")
        XCTAssertTrue(activity.busy.opening, "\"opening\" while the tap waits")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(opened.value, 0, "the open waits for the release in flight (G2)")

        sceneIsActive.value = false
        release.open()
        await tap.value
        XCTAssertEqual(opened.value, 0, "the tap was dropped: the scene was not active after the settle")
        XCTAssertFalse(activity.busy.opening, "and \"opening\" is cleared")

        sceneIsActive.value = true
        let next = try XCTUnwrap(SessionListViewController.open("unit test row", activity: activity, mayOpen: gate) {
            opened.value += 1
            return true
        }, "the next tap is taken")
        await next.value
        XCTAssertEqual(opened.value, 1, "with the scene active the next tap opens")
        XCTAssertTrue(activity.busy.opening, "a screen was pushed: \"opening\" until the list appears again")
    }

    /// S3 and step 9's review: a second tap that comes while the first one waits (before its push
    /// has started) is dropped at once; it never reaches a settle, a cold start or a push. The
    /// gate here answers yes to both, so only the "opening" guard can stop the second.
    func testASecondTapWhileAnOpenWaitsIsDropped() async throws {
        let activity = SessionActivity()
        let release = Latch()
        activity.track(release: SessionID.random()) { await release.wait() }
        let opened = Counter()
        let first = SessionListViewController.open("first tap", activity: activity, mayOpen: { true }) {
            opened.value += 1
            return true
        }
        XCTAssertNotNil(first, "the first tap is taken")
        let second = SessionListViewController.open("second tap", activity: activity, mayOpen: { true }) {
            opened.value += 1
            return true
        }
        XCTAssertNil(second, "the second tap, before the first one's push, is dropped")
        release.open()
        await first?.value
        await second?.value
        XCTAssertEqual(opened.value, 1, "one screen")
    }

    /// Rule 1 of DESIGN.md section 7 (`await close()` before the same record's cold start), G2:
    /// through the real terminal screen and its `SessionQueue`, a resumed session attached and
    /// started, then the back's leave, whose park's save is slowed (`Options.storageHook`, 1.5 s
    /// on the snapshot's write); `await settled()`; then the cold start of that record answers
    /// `.resumed`. Without the settle's wait for the park it would meet the park's lock:
    /// `.retryLater(.inUse)`.
    func testAnOpenAfterALeaveFindsTheRecordFree() async throws {
        let root = makeRoot()
        let key = try Base64Key(bytes: [UInt8](repeating: 9, count: 16))
        let first = try newSession(root: root, key: key)
        let id = first.id
        addTeardownBlock { SessionFiles.clearLastLookedAt(ifNamed: id) }
        try await first.start()
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean, "the first life saved clean")
        await first.close()

        let slow = SlowWrite(file: "snapshot.tmp", hold: 1.5)
        var slowed = Self.options()
        slowed.storageHook = slow.hook
        let resumed = try coldStart(root: root, id: id, key: key, options: slowed)
        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        weak let weakScreen = screen
        var window: UIWindow? = try show(screen!)
        let attached = try await waitUntil(15) { screen?.liveSessionID == id }
        XCTAssertTrue(attached, "the screen attached the session")
        let started = try await waitUntil { try SessionStore(root: root, id: id).readCounters().state == .dirty }
        XCTAssertTrue(started, "start() made the record dirty")

        let left = Date()
        screen?.leaveScreen()
        await SessionActivity.shared.settled()
        let waited = Date().timeIntervalSince(left)
        let decision = ResumeCoordinator.coldStart(root: root, id: id, key: .provided(key), currentSize: nil,
                                                   options: Self.options())
        guard case .resumed(let next) = decision else {
            XCTFail("the cold start after the settle did not resume: \(decision) (the settle waited \(Int(waited * 1000)) ms)")
            hide(window)
            return
        }
        XCTAssertTrue(next.isRestored, "the cold start resumed the record")
        XCTAssertEqual(slow.held, 1, "the park's save was the slow one")
        XCTAssertGreaterThanOrEqual(waited, 1.4, "the settle waited for the slowed park (\(Int(waited * 1000)) ms)")
        await next.close()

        hide(window)
        window = nil
        screen = nil
        let freed = try await waitUntil { weakScreen == nil }
        XCTAssertTrue(freed, "the screen is freed")
    }

    /// Step 9's review (W4, E1): "End Session" is confirmed and the scene resigns during the pop,
    /// before the leave. The resign queues no save (a save would quiesce the session, and the
    /// leave's shutdown would then wait for a return to the foreground, `MoshSession.shutdown`):
    /// the leave's shutdown goes out at once, and the record reads "ended". Here the pop is
    /// played by hand (no navigation controller): the confirm, the resign, 500 ms, the leave.
    func testAResignDuringTheEndSessionPopLeavesTheShutdownSent() async throws {
        let root = makeRoot()
        let key = try Base64Key(bytes: [UInt8](repeating: 9, count: 16))
        let first = try newSession(root: root, key: key)
        let id = first.id
        addTeardownBlock { SessionFiles.clearLastLookedAt(ifNamed: id) }
        try await first.start()
        _ = await first.enterBackground()
        await first.close()
        let resumed = try coldStart(root: root, id: id, key: key, options: Self.options())

        var screen: TerminalViewController? = TerminalViewController(start: .resumed(resumed, host: nil))
        var window: UIWindow? = try show(screen!)
        let attached = try await waitUntil(15) { screen?.liveSessionID == id }
        XCTAssertTrue(attached, "the screen attached the session")
        let started = try await waitUntil { try SessionStore(root: root, id: id).readCounters().state == .dirty }
        XCTAssertTrue(started, "start() made the record dirty")

        screen?.endFromMenu()
        screen?.sceneWillResignActive()
        // The pop's animation: a save queued by the resign would run now.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(screen?.queue.recentCommands.contains("background") ?? true,
                       "the resign during the pop queued no save (commands: \(screen?.queue.recentCommands ?? []))")
        let inBackground = await resumed.isInBackground
        XCTAssertFalse(inBackground, "the session is not quiesced when the leave comes")
        let before = await resumed.datagramsSent()

        screen?.leaveScreen()
        XCTAssertTrue(SessionActivity.shared.busy.ending.contains(id), "the session is ending")
        let sent = try await waitUntil(5) { await resumed.datagramsSent() > before }
        let after = await resumed.datagramsSent()
        XCTAssertTrue(sent, "the shutdown went out after the leave (datagrams before it: \(before), after: \(after))")
        XCTAssertEqual(try SessionStore(root: root, id: id).readCounters().state, .ended, "the record reads ended")

        hide(window)
        window = nil
        screen = nil
        await resumed.close()
    }

    // MARK: Helpers of the step 10 tests (as in `SessionQueueTests`)

    private static let size = TerminalSize(width: 80, height: 24)

    private static func options() -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.makeTransport = { NowhereTransport() }
        return options
    }

    private func makeRoot() -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    private func newSession(root: String, key: Base64Key) throws -> ResumeCoordinator {
        let meta = SessionMeta(createdAt: 1, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: Self.size)
        return try ResumeCoordinator.create(root: root, meta: meta, key: key, storesKey: false,
                                            initialSize: Self.size, options: Self.options())
    }

    private func coldStart(root: String, id: SessionID, key: Base64Key,
                           options: ResumeCoordinator.Options) throws -> ResumeCoordinator {
        let decision = ResumeCoordinator.coldStart(root: root, id: id, key: .provided(key), currentSize: nil,
                                                   options: options)
        guard case .resumed(let resumed) = decision else {
            throw Unexpected(description: "the cold start did not resume: \(decision)")
        }
        return resumed
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await condition()
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        try await waitUntil(5, condition)
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
}
