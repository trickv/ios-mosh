import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import Security
import XCTest
@testable import IOSMosh

/// The session key in the Keychain (docs/PLAN.md section 3: account = session id,
/// `AfterFirstUnlockThisDeviceOnly`), in the app's own process.
final class SessionKeychainTests: XCTestCase {
    private var keys: SessionKeychain!

    override func setUp() {
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        keys.deleteAll()
    }

    func testStoreReadListDelete() throws {
        let id = SessionID.random()
        let key = try Base64Key(bytes: (0..<16).map { UInt8($0 * 7) })
        XCTAssertNil(try keys.key(for: id))
        try keys.store(key, for: id)
        XCTAssertEqual(try SessionKeychain(service: keys.service).key(for: id), key, "read by a new instance")
        XCTAssertEqual(try keys.sessionIDs(), [id])
        XCTAssertThrowsError(try keys.store(key, for: id), "an id is stored once")
        try keys.delete(id)
        XCTAssertNil(try keys.key(for: id))
        XCTAssertEqual(try keys.sessionIDs(), [])
        XCTAssertNoThrow(try keys.delete(id), "deleting what is not there is not an error")
    }

    func testTheItemHasThePlansAccessibilityClass() throws {
        let id = SessionID.random()
        try keys.store(try Base64Key(bytes: [UInt8](repeating: 1, count: 16)), for: id)
        XCTAssertEqual(try keys.accessibility(for: id), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}

/// `SessionLauncher.launch` and `coldStart` on records made here (no server needed: nothing is
/// started). From step 11 (docs/notes/multi-session/DESIGN.md 2.5) the launch opens only its
/// target, the session looked at last, so each test that asks the launch about a record names that
/// record as the one looked at last.
///
/// The async tests are `@MainActor`, and so is `makeRecord`: off the main
/// actor, a failure recorded after an `await` was sometimes not counted (seen on the simulator in
/// step 11's check: with a broken launch target the app's log shows the wrong record cold-started,
/// and XCTest recorded only the checks before the first `await`), so such a test could pass with
/// broken code. On the main actor every failing check is recorded.
final class SessionLauncherTests: XCTestCase {
    private var root: String!
    private var keys: SessionKeychain!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)").path
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        keys.deleteAll()
    }

    /// A record as the app makes it: key in the Keychain, none in the record. Never started,
    /// so it is "dirty".
    @MainActor
    private func makeRecord(storeKey: Bool, createdAt: UInt64 = 1) async throws -> SessionMeta {
        let key = try Base64Key(bytes: [UInt8](repeating: 3, count: 16))
        let meta = SessionMeta(createdAt: createdAt, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 42, serverStartTime: 1000)
        if storeKey { try keys.store(key, for: meta.id) }
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        await coordinator.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/\(meta.id)/key"), "no key file on iOS")
        return meta
    }

    func testNoRecordIsNothing() {
        guard case .nothing = SessionLauncher.launch(root: root, keys: keys, last: nil, ended: []).decision else {
            return XCTFail("expected nothing")
        }
    }

    @MainActor
    func testARecordThatWasNeverSavedFallsBackWithItsMeta() async throws {
        let meta = try await makeRecord(storeKey: true)
        guard case .fallback(let fallback) = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: []).decision else {
            return XCTFail("expected the fallback")
        }
        XCTAssertEqual(fallback.id, meta.id)
        XCTAssertEqual(fallback.reason, "the record is dirty")
        XCTAssertEqual(fallback.meta, meta)
        XCTAssertTrue(fallback.wantsNewSession)
        XCTAssertFalse(fallback.recordDeleted, "kept until the new session exists")
        XCTAssertEqual(SessionLauncher.serverIdentity(fallback.meta)?.pid, 42)
    }

    @MainActor
    func testARecordWithoutItsKeychainKeyFallsBackAndIsNotChanged() async throws {
        let meta = try await makeRecord(storeKey: false)
        let before = try SessionStore(root: root, id: meta.id).readCounters()
        guard case .fallback(let fallback) = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: []).decision else {
            return XCTFail("expected the fallback")
        }
        XCTAssertEqual(fallback.reason, "the session key is not in the Keychain")
        XCTAssertEqual(fallback.meta, meta)
        XCTAssertTrue(fallback.wantsNewSession)
        XCTAssertEqual(try SessionStore(root: root, id: meta.id).readCounters(), before, "nothing written")
    }

    @MainActor
    func testARecordInUseIsRetriedLater() async throws {
        let meta = try await makeRecord(storeKey: true)
        let record = try SessionRecord.open(root: root, id: meta.id)
        defer { record.close() }
        guard case .retryLater = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: []).decision else {
            return XCTFail("expected retry later")
        }
    }

    // MARK: Review M6-4

    /// The record holds the only copy of the server's pid and start time: it may go only when
    /// the server is stopped or provably gone, or when nobody can be asked with it.
    func testAnEndedRecordIsForgottenOnlyWhenItsServerIsDealtWith() {
        XCTAssertTrue(OldServerOutcome.killed.mayForget)
        XCTAssertTrue(OldServerOutcome.notThere(atSessionAddress: true).mayForget)
        XCTAssertTrue(OldServerOutcome.nothingToAsk.mayForget)
        XCTAssertFalse(OldServerOutcome.hostNotReached.mayForget, "no network: the server may still run")
        XCTAssertFalse(OldServerOutcome.notAnswered.mayForget)
        XCTAssertFalse(OldServerOutcome.notThere(atSessionAddress: false).mayForget,
                       "a pid that is missing on another machine proves nothing")
    }

    @MainActor
    func testWithoutAHostOrAnIdentityThereIsNothingToAsk() async throws {
        let meta = try await makeRecord(storeKey: true)
        let noHost = await SessionLauncher.stopOldServer(meta: meta, host: nil)
        XCTAssertEqual(noHost, .nothingToAsk)
        let noMeta = await SessionLauncher.stopOldServer(meta: nil, host: nil)
        XCTAssertEqual(noMeta, .nothingToAsk)
    }

    /// A shutdown that got no answer leaves an "ended" record. The launch lists it for the
    /// identity-checked kill, with its pid and start time, and starts no session from it;
    /// a record that is not ended is not listed.
    @MainActor
    func testAnEndedRecordIsListedWithItsServerIdentityAndIsNotASession() async throws {
        let dirty = try await makeRecord(storeKey: true)
        XCTAssertTrue(SessionLauncher.endedRecords(root: root).isEmpty)

        let key = try Base64Key(bytes: [UInt8](repeating: 4, count: 16))
        let meta = SessionMeta(createdAt: 2, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 43, serverStartTime: 2000)
        try keys.store(key, for: meta.id)
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        let accepted = await coordinator.shutdown()
        XCTAssertTrue(accepted)
        await coordinator.close()

        let ended = SessionLauncher.endedRecords(root: root)
        XCTAssertEqual(ended.map(\.id), [meta.id])
        XCTAssertEqual(ended.first?.wantsNewSession, false)
        XCTAssertEqual(SessionLauncher.serverIdentity(ended.first?.meta)?.pid, 43)
        XCTAssertEqual(SessionLauncher.serverIdentity(ended.first?.meta)?.startTime, Date(timeIntervalSince1970: 2000))

        // The ended one is newer, and still the launch decides about the other record, the one
        // looked at last; with the ended one looked at last it opens nothing (DESIGN.md 2.5).
        let ids = Set(ended.map(\.id))
        guard case .fallback(let fallback) = SessionLauncher.launch(root: root, keys: keys, last: dirty.id, ended: ids).decision else {
            return XCTFail("expected the dirty record's fallback")
        }
        XCTAssertEqual(fallback.id, dirty.id)
        XCTAssertTrue(fallback.wantsNewSession)
        guard case .nothing = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: ids).decision else {
            return XCTFail("an ended record is not a session")
        }
    }

    // MARK: Review M6-10

    /// A Keychain that cannot be read now, as before the first unlock.
    private final class LockedKeychain: SessionKeychain {
        override func key(for id: SessionID) throws -> Base64Key? {
            throw SessionKeychain.Failure.locked
        }
    }

    /// The bytes of every file in a record directory.
    private func contents(of id: SessionID) throws -> [String: Data] {
        let dir = root + "/\(id)"
        var files: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: dir) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir + "/" + name, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        return files
    }

    /// `errSecInteractionNotAllowed` (device locked) is `.locked`; the launch then says
    /// "retry later" and writes nothing: the record, its files and the key stay as they were.
    @MainActor
    func testALockedKeychainIsRetryLaterAndWritesNothing() async throws {
        guard case .locked = SessionKeychain.failure(errSecInteractionNotAllowed, "read") else {
            return XCTFail("errSecInteractionNotAllowed must be .locked")
        }
        let meta = try await makeRecord(storeKey: true)
        let before = try contents(of: meta.id)
        XCTAssertFalse(before.isEmpty)
        let locked = LockedKeychain(service: keys.service)
        guard case .retryLater(let why) = SessionLauncher.launch(root: root, keys: locked, last: meta.id, ended: []).decision else {
            return XCTFail("expected retry later")
        }
        XCTAssertTrue(why.contains("locked"), why)
        XCTAssertEqual(try contents(of: meta.id), before, "the record is not changed")
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [meta.id], "nothing deleted")
        XCTAssertNotNil(try keys.key(for: meta.id), "the key is kept")
    }

    // MARK: Review M6-6

    /// A Keychain item that is not a 16-byte key is not repaired by waiting: the launch must
    /// not say "retry later" for ever. It is the fallback of a record without its key, and
    /// the record is not changed.
    @MainActor
    func testAMalformedKeychainItemIsAFallbackNotARetry() async throws {
        let meta = try await makeRecord(storeKey: false)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keys.service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccount as String: meta.id.description,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data([1, 2, 3, 4, 5]),
        ]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try keys.key(for: meta.id)) { error in
            guard case SessionKeychain.Failure.malformed = error else { return XCTFail("\(error)") }
        }
        let before = try SessionStore(root: root, id: meta.id).readCounters()
        guard case .fallback(let fallback) = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: []).decision else {
            return XCTFail("expected a fallback")
        }
        XCTAssertEqual(fallback.id, meta.id)
        XCTAssertEqual(fallback.meta, meta)
        XCTAssertFalse(fallback.recordDeleted)
        XCTAssertEqual(try SessionStore(root: root, id: meta.id).readCounters().state, before.state)
    }

    // MARK: Step 11: the launch target (DESIGN.md 2.5, D1)

    /// D1: the launch target is the session he looked at last, whichever record is newer and
    /// whichever others are ended, and the launch opens that record and no other (3.5 L2, L3).
    /// Both records here were never saved, so the target's answer is its fallback; the newer
    /// record is not opened and nothing of it changes.
    @MainActor
    func testTheLaunchTargetIsTheLastLookedAtSession() async throws {
        let a = SessionID.random(), b = SessionID.random(), c = SessionID.random()
        XCTAssertEqual(SessionLauncher.launchTarget(last: a, ended: [], stored: [a, b]), a)
        XCTAssertEqual(SessionLauncher.launchTarget(last: b, ended: [], stored: [a, b]), b)
        XCTAssertEqual(SessionLauncher.launchTarget(last: a, ended: [b, c], stored: [a, b, c]), a,
                       "other records ended: still the one looked at last")

        let older = try await makeRecord(storeKey: true, createdAt: 1)
        let newer = try await makeRecord(storeKey: true, createdAt: 2)
        let newerBefore = try contents(of: newer.id)
        let launch = SessionLauncher.launch(root: root, keys: keys, last: older.id, ended: [])
        XCTAssertEqual(launch.target, older.id, "the target is the session looked at last, not the newest")
        guard case .fallback(let fallback) = launch.decision else {
            return XCTFail("expected the fallback of the session looked at last, got \(launch.decision)")
        }
        XCTAssertEqual(fallback.id, older.id, "the launch decided about the session looked at last, not the newest")
        XCTAssertEqual(try contents(of: newer.id), newerBefore, "the newer record is not opened or written")
        XCTAssertEqual(Set(SessionStore.sessionIDs(root: root)), [older.id, newer.id], "nothing deleted")
    }

    /// D1, D4, 3.5 L4 and L6: no launch target without a session looked at last (records older
    /// than "last looked at", or the dotted session ended, D4), and none when the one looked at
    /// last is an ended record (finished in the background, never opened). The launch then opens
    /// no record, not even the only one, and writes nothing.
    @MainActor
    func testNoLaunchTargetWithoutAnIdOrForAnEndedOne() async throws {
        let a = SessionID.random(), b = SessionID.random()
        XCTAssertNil(SessionLauncher.launchTarget(last: nil, ended: [], stored: [a, b]), "no id: no target")
        XCTAssertNil(SessionLauncher.launchTarget(last: a, ended: [a], stored: [a, b]), "the one looked at last is ended")
        XCTAssertNil(SessionLauncher.launchTarget(last: a, ended: [a, b], stored: [a, b]))

        let dirty = try await makeRecord(storeKey: true, createdAt: 1)
        let key = try Base64Key(bytes: [UInt8](repeating: 6, count: 16))
        let meta = SessionMeta(createdAt: 2, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 44, serverStartTime: 3000)
        try keys.store(key, for: meta.id)
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        let accepted = await coordinator.shutdown()
        XCTAssertTrue(accepted)
        await coordinator.close()
        let ended = Set(SessionLauncher.endedRecords(root: root).map(\.id))
        XCTAssertEqual(ended, [meta.id], "the record is ended")
        let before = try [dirty.id: contents(of: dirty.id), meta.id: contents(of: meta.id)]

        let none = SessionLauncher.launch(root: root, keys: keys, last: nil, ended: ended)
        XCTAssertNil(none.target, "no id: no target")
        guard case .nothing = none.decision else {
            return XCTFail("no id: the launch opens nothing, not the newest record (\(none.decision))")
        }
        let endedLaunch = SessionLauncher.launch(root: root, keys: keys, last: meta.id, ended: ended)
        XCTAssertNil(endedLaunch.target, "the one looked at last is ended: no target")
        guard case .nothing = endedLaunch.decision else {
            return XCTFail("the one looked at last is ended: the launch opens nothing (\(endedLaunch.decision))")
        }
        XCTAssertEqual(try [dirty.id: contents(of: dirty.id), meta.id: contents(of: meta.id)], before,
                       "no record is opened or written")
    }

    /// review-steps-2-4.md R24-S3: "last looked at" can name a record that is gone (forgotten
    /// while `removeOrphans` could not list the Keychain). The launch target checks that the
    /// record is there: no target, and the launch asks no cold start, which would answer a
    /// fallback that wants a new session (no key, no directory: the "no key" branch of
    /// `SessionLauncher.coldStart`).
    @MainActor
    func testNoLaunchTargetForARecordThatIsGone() async throws {
        let a = SessionID.random(), b = SessionID.random()
        XCTAssertNil(SessionLauncher.launchTarget(last: a, ended: [], stored: [b]), "its record is not stored")
        XCTAssertNil(SessionLauncher.launchTarget(last: a, ended: [], stored: []))

        let other = try await makeRecord(storeKey: true)
        let launch = SessionLauncher.launch(root: root, keys: keys, last: SessionID.random(), ended: [])
        XCTAssertNil(launch.target, "no target for a record that is not there")
        guard case .nothing = launch.decision else {
            return XCTFail("a record that is gone: the launch opens nothing, got \(launch.decision)")
        }
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [other.id], "the other record is not touched")
    }

    /// DESIGN.md 2.2, 4.5, 3.5 W6 (step 11): the launch's "try again later" waits in
    /// `SessionActivity`, with its reason for the list's line. A tap that is taken drops both at
    /// once, before it waits for anything; the launch's own retry goes the same way and keeps the
    /// wait when the gate drops it; the end or the forget of a session drops it only for that
    /// session.
    @MainActor
    func testATapDropsTheLaunchsWait() async throws {
        let activity = SessionActivity()
        let id = SessionID.random()
        activity.beginWait(for: id, reason: "the record is in use")
        XCTAssertEqual(activity.busy.waiting, id)
        XCTAssertEqual(activity.waitingReason, "the record is in use")
        XCTAssertTrue(activity.busy.mayRetry, "the launch asks again at the next activation")

        let retry = SessionListViewController.open("the launch's retry", activity: activity, dropsTheWait: false,
                                                   mayOpen: { false }) { true }
        XCTAssertNotNil(retry, "the retry is taken")
        await retry?.value
        XCTAssertEqual(activity.busy.waiting, id, "a retry that the gate dropped keeps the wait")
        XCTAssertFalse(activity.busy.opening, "and \"opening\" is cleared")

        let tap = SessionListViewController.open("a row", activity: activity, mayOpen: { true }) { true }
        XCTAssertNotNil(tap, "the tap is taken")
        XCTAssertNil(activity.busy.waiting, "a tap that is taken drops the launch's wait at once (4.5)")
        XCTAssertNil(activity.waitingReason, "and the list's waiting line")
        XCTAssertFalse(activity.busy.mayRetry, "the launch does not ask again")
        await tap?.value
        activity.openFinished()

        activity.beginWait(for: id, reason: "the record is in use")
        activity.dropWait(for: SessionID.random())
        XCTAssertEqual(activity.busy.waiting, id, "the end or forget of another session keeps the wait")
        activity.dropWait(for: id)
        XCTAssertNil(activity.busy.waiting, "the end or forget of the session waited for drops it")
        XCTAssertNil(activity.waitingReason)
    }

    /// DESIGN.md 3.5 L7: the launch target's directory is not a record (here an empty directory
    /// with a key in the Keychain, so that the cold start itself finds out and deletes it). It is
    /// forgotten (directory and key), the launch opens nothing, and no other record is tried in
    /// its place (before step 11 the loop went on to the next record).
    @MainActor
    func testALaunchTargetThatIsNotARecordIsForgottenAndNothingElseIsOpened() async throws {
        let other = try await makeRecord(storeKey: true, createdAt: 2)
        let otherBefore = try contents(of: other.id)
        let id = SessionID.random()
        try FileManager.default.createDirectory(atPath: root + "/\(id)", withIntermediateDirectories: true)
        try keys.store(try Base64Key(bytes: [UInt8](repeating: 7, count: 16)), for: id)
        XCTAssertEqual(Set(SessionStore.sessionIDs(root: root)), [id, other.id], "the directory is listed as stored")

        let launch = SessionLauncher.launch(root: root, keys: keys, last: id, ended: [])
        XCTAssertEqual(launch.target, id, "the target is the session looked at last")
        guard case .nothing = launch.decision else {
            return XCTFail("a target that is not a record: the launch opens nothing (got \(launch.decision))")
        }
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [other.id], "its directory is gone")
        XCTAssertNil(try keys.key(for: id), "its key is forgotten with it")
        XCTAssertEqual(try contents(of: other.id), otherBefore, "no other record is opened or written (L7)")
    }

    /// DESIGN.md 2.2 (the wait is dropped when that session is ended or forgotten): a row's End
    /// Session, as it begins, and a Forget that deleted the record call `dropWait(for:)`. It drops
    /// the launch's wait and its line only when the launch waits for that session, and then tells
    /// the list (4.4); for another session, or with no wait, it changes nothing.
    @MainActor
    func testTheEndOrForgetOfASessionDropsOnlyItsOwnWait() {
        let activity = SessionActivity()
        var changes = 0
        activity.onChange = { changes += 1 }
        let id = SessionID.random(), other = SessionID.random()

        activity.dropWait(for: id)
        XCTAssertEqual(changes, 0, "no wait: nothing changes")

        activity.beginWait(for: id, reason: "the device is locked")
        changes = 0
        activity.dropWait(for: other)
        XCTAssertEqual(activity.busy.waiting, id, "the end or forget of another session keeps the wait")
        XCTAssertEqual(activity.waitingReason, "the device is locked", "and its line")
        XCTAssertTrue(activity.busy.mayRetry, "the launch still asks again")
        XCTAssertEqual(changes, 0, "nothing changed")

        activity.dropWait(for: id)
        XCTAssertNil(activity.busy.waiting, "the end or forget of the session waited for drops the wait")
        XCTAssertNil(activity.waitingReason, "and its line")
        XCTAssertFalse(activity.busy.mayRetry, "the launch does not ask again")
        XCTAssertEqual(changes, 1, "the list is told once")
    }

    /// DESIGN.md 3.5 W6 and 2.2 (should-fix 2 of step 11's review): the launch's retry waits for
    /// the settle before it decides, and meanwhile a tap, an end or a forget may have dropped the
    /// wait, or the session it would open may be being ended. Asked after the settle and the gate
    /// (`SessionLauncher.retry`), it then opens nothing, looks for no ended record and leaves the
    /// record as it is; a wait that still stands is kept for the next activation. With the wait
    /// standing and nothing ending that session, it is the launch's own answer for the target.
    @MainActor
    func testTheRetryOpensNothingOnceTheWaitIsDroppedOrItsTargetIsBeingEnded() async throws {
        let meta = try await makeRecord(storeKey: true)
        let before = try contents(of: meta.id)
        let activity = SessionActivity()
        var endedAsked = 0
        let ended = { () -> Set<SessionID> in endedAsked += 1; return [] }

        XCTAssertNil(SessionLauncher.retry(root: root, keys: keys, activity: activity, last: meta.id, ended: ended),
                     "the launch waits for nothing (the wait was dropped): the retry opens nothing")

        activity.beginWait(for: meta.id, reason: "the record is in use")
        activity.beginEnd(meta.id)
        XCTAssertNil(SessionLauncher.retry(root: root, keys: keys, activity: activity, last: meta.id, ended: ended),
                     "the session the retry would open is being ended: it opens nothing")
        XCTAssertEqual(activity.busy.waiting, meta.id, "that wait stands, for the next activation")
        XCTAssertEqual(endedAsked, 0, "no ended record was looked for")
        XCTAssertEqual(try contents(of: meta.id), before, "the record is not opened or written")

        activity.endFinished(meta.id)
        guard let retry = SessionLauncher.retry(root: root, keys: keys, activity: activity, last: meta.id, ended: ended) else {
            return XCTFail("the wait stands and nothing ends that session: the retry asks the launch")
        }
        XCTAssertEqual(retry.target, meta.id, "the retry's target is the session looked at last")
        guard case .fallback(let fallback) = retry.decision else {
            return XCTFail("the record's own answer, its fallback (never saved), got \(retry.decision)")
        }
        XCTAssertEqual(fallback.id, meta.id)
        XCTAssertEqual(endedAsked, 1, "the ended records are looked for once, by the launch")
    }
}

/// `SessionFiles.forget` and `removeOrphans` (review M6-10) on a temporary root, Keychain
/// service and links file.
///
/// The async tests and `makeSession` are `@MainActor` (step 13c), for the reason given above
/// `SessionLauncherTests`: every check of these tests comes after an `await`.
final class SessionFilesTests: XCTestCase {
    private var root: String!
    private var keys: SessionKeychain!
    private var linksURL: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions").path
        linksURL = base.appendingPathComponent("session-hosts.json")
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: linksURL.deletingLastPathComponent())
        keys.deleteAll()
    }

    /// A record as the app makes it, with its key in the Keychain and a link to a host.
    @MainActor
    private func makeSession(record: Bool = true, key: Bool = true, link: Bool = true) async throws -> SessionID {
        let sessionKey = try Base64Key(bytes: [UInt8](repeating: 5, count: 16))
        let meta = SessionMeta(createdAt: 1, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 42, serverStartTime: 1000)
        if key { try keys.store(sessionKey, for: meta.id) }
        if link { SessionFiles.link(meta.id, to: UUID(), linksURL: linksURL) }
        if record {
            let coordinator = try ResumeCoordinator.create(
                root: root, meta: meta, key: sessionKey, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
                options: SessionLauncher.options(address: meta.address, port: meta.port))
            await coordinator.close()
        }
        return meta.id
    }

    private func recordExists(_ id: SessionID) throws -> Bool {
        try SessionStore(root: root, id: id).exists
    }

    private func hasKey(_ id: SessionID) throws -> Bool {
        try keys.key(for: id) != nil
    }

    private func hasLink(_ id: SessionID) -> Bool {
        SessionFiles.linkedHostID(of: id, linksURL: linksURL) != nil
    }

    @MainActor
    func testForgetRemovesRecordKeyAndLinkOfThatSessionOnly() async throws {
        let id = try await makeSession()
        let other = try await makeSession()
        XCTAssertTrue(try recordExists(id))
        XCTAssertTrue(SessionFiles.forget(id, root: root, keys: keys, linksURL: linksURL))
        XCTAssertFalse(try recordExists(id))
        XCTAssertFalse(try hasKey(id))
        XCTAssertFalse(hasLink(id))
        XCTAssertTrue(try recordExists(other), "the other session is untouched")
        XCTAssertTrue(try hasKey(other))
        XCTAssertTrue(hasLink(other))
    }

    @MainActor
    func testForgetOfARecordInUseKeepsEverything() async throws {
        let id = try await makeSession()
        let record = try SessionRecord.open(root: root, id: id)
        defer { record.close() }
        XCTAssertFalse(SessionFiles.forget(id, root: root, keys: keys, linksURL: linksURL), "not deleted now")
        XCTAssertTrue(try recordExists(id))
        XCTAssertTrue(try hasKey(id), "the key stays with its record")
        XCTAssertTrue(hasLink(id))
    }

    @MainActor
    func testForgetOfASessionWithoutARecordRemovesItsKeyAndLink() async throws {
        let id = try await makeSession(record: false)
        XCTAssertTrue(SessionFiles.forget(id, root: root, keys: keys, linksURL: linksURL))
        XCTAssertFalse(try hasKey(id))
        XCTAssertFalse(hasLink(id))
    }

    @MainActor
    func testRemoveOrphans() async throws {
        let keyOnly = try await makeSession(record: false, key: true, link: false)
        let keyAndLinkOnly = try await makeSession(record: false, key: true, link: true)
        let linkOnly = try await makeSession(record: false, key: false, link: true)
        let unlinked = try await makeSession(record: true, key: true, link: false)
        let keyless = try await makeSession(record: true, key: false, link: true)
        let complete = try await makeSession()
        let inUse = try await makeSession()
        let record = try SessionRecord.open(root: root, id: inUse)
        defer { record.close() }

        SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)

        XCTAssertFalse(try hasKey(keyOnly), "a key without a record directory is an orphan")
        XCTAssertFalse(try hasKey(keyAndLinkOnly))
        XCTAssertFalse(hasLink(keyAndLinkOnly))
        XCTAssertFalse(hasLink(linkOnly), "a link without a record is an orphan")

        XCTAssertTrue(try recordExists(unlinked), "a record without a link is not an orphan")
        XCTAssertTrue(try hasKey(unlinked))
        XCTAssertTrue(try recordExists(keyless), "a record without a key is left to the cold start")
        XCTAssertTrue(hasLink(keyless))
        for id in [complete, inUse] {
            XCTAssertTrue(try recordExists(id), "\(id)")
            XCTAssertTrue(try hasKey(id), "\(id)")
            XCTAssertTrue(hasLink(id), "\(id)")
        }
        XCTAssertEqual(Set(try keys.sessionIDs()), [unlinked, complete, inUse])
    }

    /// Review M6-11: a Debug build on the phone launched with `-uiTesting 1` alone must keep
    /// every session; only an explicit `-uiTestingResetSessions 1` wipes, and
    /// `-uiTestingKeepSessions 1` wins over it.
    func testOnlyAnExplicitResetArgumentWipesTheSessions() {
        for uiTesting in [false, true] {
            for reset in [false, true] {
                for keep in [false, true] {
                    XCTAssertEqual(
                        SessionFiles.resetsSessionsForUITests(uiTesting: uiTesting, resetSessions: reset, keepSessions: keep),
                        (uiTesting, reset, keep) == (true, true, false), "uiTesting \(uiTesting), reset \(reset), keep \(keep)")
                }
            }
        }
        XCTAssertFalse(SessionFiles.resetsSessionsForUITests(uiTesting: true, resetSessions: false, keepSessions: false),
                       "-uiTesting 1 alone keeps the sessions")
        XCTAssertFalse(SessionFiles.resetsSessionsForUITests(uiTesting: false, resetSessions: true, keepSessions: false),
                       "the reset argument does nothing outside a UI-test launch")
    }
}
