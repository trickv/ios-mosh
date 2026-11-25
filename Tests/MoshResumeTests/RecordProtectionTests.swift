import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

/// A protection a test can steer: it records what it was asked and answers as told.
private final class FakeProtection: RecordProtection, @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var appliedTo: [String] = []
    private var contentsAtApply: [[String]] = []
    private var failApply = false
    private var answer: Result<Bool, Error> = .success(true)

    var applied: [String] { lock.lock(); defer { lock.unlock() }; return appliedTo }
    var contents: [[String]] { lock.lock(); defer { lock.unlock() }; return contentsAtApply }
    func refuseApply(_ refuse: Bool) { lock.lock(); failApply = refuse; lock.unlock() }
    func verifySays(_ result: Result<Bool, Error>) { lock.lock(); answer = result; lock.unlock() }

    func apply(directory: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failApply { throw Refused() }
        appliedTo.append(directory)
        contentsAtApply.append(((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? ["?"]).filter { $0 != "lock" })
    }

    func verify(directory: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try answer.get()
    }
}

/// Review finding A-2: a record's directory is excluded from backups when it is made, a record
/// that cannot be excluded is not made, and one that is found not excluded is never resumed.
/// The rules are tested here with an injected protection; what the Apple one really does to a
/// directory needs the Mac (the last test) and the phone (docs/RESUME.md).
final class RecordProtectionTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

    private func options(_ network: CountingDeadNetwork, _ protection: any RecordProtection,
                         hook: StorageHook? = nil) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.blocks = GateCounters(sequence: 4, state: 2, fragmentID: 2)
        options.storageHook = hook
        options.noReplyTimeout = nil
        options.makeTransport = network.makeTransport
        options.protection = protection
        return options
    }

    private func savedSession(root: String, network: CountingDeadNetwork, _ protection: any RecordProtection) async throws -> SessionID {
        let first = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                 initialSize: size, options: options(network, protection))
        try await first.start()
        _ = await first.type(Array("ls\r".utf8))
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()
        return first.id
    }

    func testTheDirectoryIsProtectedRightAfterItIsMadeAndBeforeAnythingIsInIt() throws {
        let root = try scratchRoot("protection")
        let protection = FakeProtection()
        let script = StepScript()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook,
                                              protection: protection)
        XCTAssertEqual(protection.applied, [record.store.directory])
        XCTAssertEqual(protection.contents, [[]], "the directory was not empty when it was protected")
        XCTAssertEqual(script.steps.prefix(4).map(\.description), ["root.mkdir", "dir.mkdir", "dir.protect", "key.tmp.create"])
        record.close()
    }

    func testARecordThatCannotBeProtectedIsNotMade() async throws {
        let root = try scratchRoot("protection")
        let protection = FakeProtection()
        protection.refuseApply(true)
        let network = CountingDeadNetwork()
        let meta = Fixtures.meta()
        XCTAssertThrowsError(try ResumeCoordinator.create(root: root, meta: meta, key: Fixtures.key, initialSize: size,
                                                          options: options(network, protection))) {
            guard case StorageError.io(let step, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(step, "dir.protect")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/\(meta.id)"), "an unprotected directory was left behind")
        XCTAssertEqual(network.opened, 0)
        // Once it can be done, the same id works.
        protection.refuseApply(false)
        let coordinator = try ResumeCoordinator.create(root: root, meta: meta, key: Fixtures.key, initialSize: size,
                                                       options: options(network, protection))
        await coordinator.close()
    }

    /// The process dies around the protection step: what is left is not a record (no counters),
    /// and the cold start deletes it.
    func testACrashAroundTheProtectionStepLeavesNoRecord() throws {
        for action in [StorageHookAction.crashBefore, .crashAfter] {
            let root = try scratchRoot("protection")
            let script = StepScript()
            script.at(2, action)
            XCTAssertThrowsError(try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook,
                                                          protection: FakeProtection()))
            XCTAssertEqual(script.steps.last?.description, "dir.protect")
            guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: Fixtures.id, key: .recordFile, currentSize: size) else {
                return XCTFail("\(action)")
            }
            XCTAssertTrue(dead.recordDeleted)
            XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
        }
    }

    /// A clean record whose directory is found not excluded (as after a restore from a backup
    /// that held it): never a resume. Nothing is sent, the app gets `meta`, the record is gone.
    func testACleanRecordThatIsNotExcludedFromBackupFallsBackAndSendsNothing() async throws {
        let root = try scratchRoot("protection")
        let network = CountingDeadNetwork()
        let protection = FakeProtection()
        let id = try await savedSession(root: root, network: network, protection)
        let sent = network.sent, opened = network.opened
        protection.verifySays(.success(false))
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size,
                                                                     options: options(network, protection)) else {
            return XCTFail("a record that may be a restored copy was not refused")
        }
        guard case .damaged(let text) = dead.reason else { return XCTFail("\(dead.reason)") }
        XCTAssertTrue(text.contains("backup"), text)
        XCTAssertTrue(dead.wantsNewSession)
        XCTAssertEqual(dead.meta?.id, id)
        XCTAssertTrue(dead.recordDeleted)
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
        XCTAssertEqual(network.sent, sent)
        XCTAssertEqual(network.opened, opened)
    }

    /// No gate is made for such a record, so not even its counters can be used.
    func testOpeningAnUnprotectedRecordGivesNoGate() throws {
        let root = try scratchRoot("protection")
        let protection = FakeProtection()
        try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, protection: protection).close()
        protection.verifySays(.success(false))
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: Fixtures.id, protection: protection)) {
            XCTAssertEqual($0 as? RecordError, .notProtected)
        }
        // The lock was given back.
        protection.verifySays(.success(true))
        try SessionRecord.open(root: root, id: Fixtures.id, protection: protection).close()
    }

    /// If the answer cannot be had now (the device is locked), that is "try again later": the
    /// record is untouched and resumes when the answer is yes.
    func testAProtectionThatCannotBeReadIsRetriedLater() async throws {
        let root = try scratchRoot("protection")
        let network = CountingDeadNetwork()
        let protection = FakeProtection()
        let id = try await savedSession(root: root, network: network, protection)
        protection.verifySays(.failure(FakeProtection.Refused()))
        guard case .retryLater(.storage) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size,
                                                                       options: options(network, protection)) else {
            return XCTFail("an unreadable attribute is not a dead session")
        }
        protection.verifySays(.success(true))
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile, currentSize: size,
                                                                      options: options(network, protection)) else {
            return XCTFail("not resumed")
        }
        await second.close()
    }

    func testThePlatformDefault() throws {
        #if canImport(Darwin)
        XCTAssertTrue(RecordProtections.platform is AppleRecordProtection)
        #else
        XCTAssertTrue(RecordProtections.platform is NoRecordProtection)
        let root = try scratchRoot("protection")
        try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key).close()
        try SessionRecord.open(root: root, id: Fixtures.id).close()
        #endif
    }

    #if canImport(Darwin)
    /// NEEDS THE MAC (never run on Linux): the real attribute is set by a create, reads back,
    /// survives a snapshot replace inside the directory, and a directory without it is refused.
    func testTheAppleProtectionReadsBack() throws {
        let root = try scratchRoot("protection")
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let directory = record.store.directory
        XCTAssertTrue(try AppleRecordProtection().verify(directory: directory))
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        XCTAssertTrue(try AppleRecordProtection().verify(directory: directory), "replacing a file cleared the attribute")
        record.close()
        try SessionRecord.open(root: root, id: Fixtures.id).close()

        var url = URL(fileURLWithPath: directory, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
        XCTAssertFalse(try AppleRecordProtection().verify(directory: directory))
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordError, .notProtected)
        }
    }
    #endif
}
