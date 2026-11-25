import Foundation
import MoshCrypto
import MoshSession
import MoshTransport
import XCTest
@testable import MoshResume

final class SessionStoreTests: XCTestCase {
    private func export(_ snapshot: SessionSnapshot, _ gate: FileBackedGate) -> SessionExport {
        SessionExport(snapshot: snapshot, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
    }

    func testCreateWritesEveryPartAndOpenReadsThem() throws {
        let root = try scratchRoot()
        let meta = Fixtures.meta()
        let record = try SessionRecord.create(root: root, meta: meta, key: Fixtures.key)
        XCTAssertEqual(record.state, .dirty, "a new record has no snapshot")
        XCTAssertEqual(record.gate.reservedLimits, .sessionStart)
        XCTAssertEqual(try record.readKey(), Fixtures.key)
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [Fixtures.id])
        let directory = root + "/" + Fixtures.id.description
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        XCTAssertEqual(names, ["counters", "key", "lock", "meta"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory + "/counters")[.size] as? Int, 8192)
        for name in names + ["."] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory + "/" + name)[.posixPermissions] as? Int
            XCTAssertEqual(mode.map { $0 & 0o077 }, 0, "\(name) is for the owner only")
        }
        XCTAssertThrowsError(try record.loadSnapshot()) {
            XCTAssertEqual($0 as? RecordError, .notResumable(.dirty))
        }
        record.close()

        let again = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertEqual(again.meta, meta)
        XCTAssertEqual(try again.readKey(), Fixtures.key)
        XCTAssertEqual(again.state, .dirty)
        XCTAssertEqual(again.meta.endpoint(key: Fixtures.key), SessionEndpoint(host: "127.0.0.1", port: 60001, key: Fixtures.key))
    }

    func testARecordWithoutAKeyFile() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: nil)
        XCTAssertThrowsError(try record.readKey()) { XCTAssertEqual($0 as? RecordError, .missing(.key)) }
    }

    func testOnlyOneHolderOfTheLock() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordError, .locked)
        }
        let store = SessionStore(root: root, id: Fixtures.id)
        XCTAssertThrowsError(try store.acquireLock()) { XCTAssertEqual($0 as? RecordError, .locked) }
        record.close()
        let second = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertThrowsError(try store.acquireLock()) { XCTAssertEqual($0 as? RecordError, .locked) }
        second.close()
        // Dropping a record without `close()` releases the lock too.
        var third: SessionRecord? = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertNotNil(third)
        third = nil
        XCTAssertNoThrow(try store.acquireLock())
    }

    func testAClosedRecordDoesNothingMore() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let gate = record.gate
        record.close()
        XCTAssertThrowsError(try gate.takeSequenceNumber()) { XCTAssertEqual($0 as? FileGateError, .closed) }
        XCTAssertThrowsError(try gate.willSendDatagram())
        XCTAssertThrowsError(try gate.markClean(ifDatagramsPassed: 0))
        XCTAssertThrowsError(try record.save(export(Fixtures.minimalSnapshot(), gate))) {
            XCTAssertEqual($0 as? RecordError, .lockNotHeld)
        }
        XCTAssertThrowsError(try record.loadSnapshot())
    }

    func testALockOfAnotherRecordIsRefused() throws {
        let root = try scratchRoot()
        let one = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let other = SessionStore(root: root, id: Fixtures.otherID)
        let otherLock = try other.create(meta: Fixtures.meta(id: Fixtures.otherID), key: Fixtures.key)
        XCTAssertThrowsError(try FileBackedGate(store: one.store, lock: otherLock)) {
            XCTAssertEqual($0 as? RecordError, .lockNotHeld)
        }
        XCTAssertThrowsError(try one.store.writeSnapshot(StoredSnapshot(id: 1, snapshot: Fixtures.minimalSnapshot()), lock: otherLock))
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [Fixtures.id, Fixtures.otherID])
    }

    func testMissingPartsAreNamed() throws {
        let root = try scratchRoot()
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordError, .missing(.meta))
        }
        for (file, part) in [("meta", RecordPart.meta), ("counters", .counters)] {
            let id = SessionID.random()
            let record = try SessionRecord.create(root: root, meta: Fixtures.meta(id: id), key: Fixtures.key)
            record.close()
            try FileManager.default.removeItem(atPath: root + "/" + id.description + "/" + file)
            XCTAssertThrowsError(try SessionRecord.open(root: root, id: id), file) {
                XCTAssertEqual($0 as? RecordError, .missing(part))
            }
            // A failed open does not keep the lock.
            XCTAssertNoThrow(try SessionStore(root: root, id: id).acquireLock())
        }
    }

    func testPartsCopiedFromAnotherSessionAreRefused() throws {
        let root = try scratchRoot()
        let a = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let b = try SessionRecord.create(root: root, meta: Fixtures.meta(id: Fixtures.otherID), key: Fixtures.key)
        XCTAssertTrue(try a.save(export(Fixtures.richSnapshot(), a.gate)))
        XCTAssertTrue(try b.save(export(Fixtures.minimalSnapshot(), b.gate)))
        a.close()
        b.close()
        let dirA = root + "/" + Fixtures.id.description
        let dirB = root + "/" + Fixtures.otherID.description
        for file in ["snapshot", "key", "meta", "counters"] {
            let saved = try Data(contentsOf: URL(fileURLWithPath: dirB + "/" + file))
            try Data(contentsOf: URL(fileURLWithPath: dirA + "/" + file)).write(to: URL(fileURLWithPath: dirB + "/" + file))
            defer { try? saved.write(to: URL(fileURLWithPath: dirB + "/" + file)) }
            do {
                let record = try SessionRecord.open(root: root, id: Fixtures.otherID)
                defer { record.close() }
                _ = try record.readKey()
                _ = try record.loadSnapshot()
                XCTFail("\(file) of another session was accepted")
            } catch let error as RecordFormatError {
                XCTAssertEqual(error.reason, .wrongSession, file)
            }
        }
        // With its own parts back, B is whole again.
        let record = try SessionRecord.open(root: root, id: Fixtures.otherID)
        XCTAssertEqual(try record.loadSnapshot(), Fixtures.minimalSnapshot())
    }

    func testSaveThenLoad() throws {
        let root = try scratchRoot()
        var record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertTrue(try record.save(export(Fixtures.richSnapshot(), record.gate)))
        guard case .clean(let id) = record.state else { return XCTFail("not clean") }
        XCTAssertEqual(try record.loadSnapshot(), Fixtures.richSnapshot())
        XCTAssertFalse(record.gate.isDirty)
        record.close()

        record = try SessionRecord.open(root: root, id: Fixtures.id)
        XCTAssertEqual(record.state, .clean(snapshotID: id))
        XCTAssertEqual(try record.loadSnapshot(), Fixtures.richSnapshot())
        // A second snapshot replaces the first, and has another id.
        XCTAssertTrue(try record.save(export(Fixtures.minimalSnapshot(), record.gate)))
        guard case .clean(let second) = record.state else { return XCTFail("not clean") }
        XCTAssertNotEqual(second, id)
        XCTAssertEqual(try record.loadSnapshot(), Fixtures.minimalSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.store.directory + "/snapshot.tmp"))
    }

    /// The counters say "clean" for one snapshot and the file is another one (an old file put
    /// back, a rename that was lost): not resumable.
    func testASnapshotThatIsNotTheOneTheCleanMarkNames() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertTrue(try record.save(export(Fixtures.richSnapshot(), record.gate)))
        let path = URL(fileURLWithPath: record.store.directory + "/snapshot")
        let first = try Data(contentsOf: path)
        guard case .clean(let firstID) = record.state else { return XCTFail("not clean") }
        try record.gate.willSendDatagram()
        XCTAssertTrue(try record.save(export(Fixtures.minimalSnapshot(), record.gate)))
        guard case .clean(let secondID) = record.state else { return XCTFail("not clean") }
        try first.write(to: path)
        XCTAssertThrowsError(try record.loadSnapshot()) {
            XCTAssertEqual($0 as? RecordError, .notResumable(.snapshotDoesNotMatch(expected: secondID, found: firstID)))
        }
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try record.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .missing(.snapshot)) }
    }

    func testADamagedSnapshotFileIsRefused() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertTrue(try record.save(export(Fixtures.richSnapshot(), record.gate)))
        let path = URL(fileURLWithPath: record.store.directory + "/snapshot")
        let good = try Data(contentsOf: path)
        for index in stride(from: 0, to: good.count, by: 7) {
            var bad = good
            bad[index] ^= 0x20
            try bad.write(to: path)
            XCTAssertThrowsError(try record.loadSnapshot(), "byte \(index)") { XCTAssertTrue($0 is RecordFormatError) }
        }
        for length in stride(from: 0, to: good.count, by: 13) {
            try good.prefix(length).write(to: path)
            XCTAssertThrowsError(try record.loadSnapshot(), "cut at \(length)") { XCTAssertTrue($0 is RecordFormatError) }
        }
        try good.write(to: path)
        XCTAssertEqual(try record.loadSnapshot(), Fixtures.richSnapshot())
    }

    /// The process dies at every step of replacing a snapshot, with the write torn at several
    /// lengths: afterwards the old snapshot loads (the record is still clean for it), or the
    /// record is not resumable. A half-written snapshot is never read.
    func testACrashAtEveryStepOfASnapshotReplace() throws {
        let old = Fixtures.richSnapshot()
        let new = Fixtures.minimalSnapshot()
        // Find the steps of one replace.
        let probe = StepScript()
        do {
            let root = try scratchRoot()
            let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: probe.hook)
            XCTAssertTrue(try record.save(export(old, record.gate)))
            let before = probe.count
            XCTAssertTrue(try record.save(export(new, record.gate)))
            XCTAssertEqual(probe.steps[before...].map(\.description),
                           ["snapshot.tmp.create", "snapshot.tmp.write", "snapshot.tmp.fsync", "snapshot.rename",
                            "dir.fsync", "counters.write", "counters.fsync"])
        }
        var outcomes: [String: Int] = [:]
        for stepIndex in 0..<7 {
            var actions: [StorageHookAction] = [.crashBefore, .crashAfter]
            if stepIndex == 1 || stepIndex == 5 {
                actions += [0, 1, 11, 12, 16, 40, 67, 68, 100].map { .tornWrite(bytes: $0) }
            }
            for action in actions {
                let root = try scratchRoot()
                let script = StepScript()
                var record: SessionRecord? = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key,
                                                                      hook: script.hook)
                XCTAssertTrue(try record!.save(export(old, record!.gate)))
                script.at(script.count + stepIndex, action)
                XCTAssertThrowsError(try record!.save(export(new, record!.gate)), "step \(stepIndex) \(action)") {
                    guard case .simulatedCrash = $0 as? StorageError else { return XCTFail("\($0)") }
                }
                XCTAssertThrowsError(try record!.save(export(new, record!.gate)), "a dead process writes nothing") {
                    XCTAssertEqual($0 as? StorageError, .afterCrash)
                }
                record = nil

                let reopened = try SessionRecord.open(root: root, id: Fixtures.id)
                do {
                    let loaded = try reopened.loadSnapshot()
                    if loaded == old {
                        outcomes["old", default: 0] += 1
                        XCTAssertLessThan(stepIndex, 6, "after the clean mark was written whole, the new one is the snapshot")
                    } else {
                        XCTAssertEqual(loaded, new)
                        outcomes["new", default: 0] += 1
                        XCTAssertGreaterThanOrEqual(stepIndex, 5)
                    }
                } catch RecordError.notResumable(let reason) {
                    // The new file is in place and the clean mark still names the old one.
                    guard case .snapshotDoesNotMatch = reason else { return XCTFail("step \(stepIndex) \(action): \(reason)") }
                    XCTAssertGreaterThanOrEqual(stepIndex, 3)
                    outcomes["neither", default: 0] += 1
                }
                reopened.close()
            }
        }
        XCTAssertGreaterThan(outcomes["old", default: 0], 0)
        XCTAssertGreaterThan(outcomes["new", default: 0], 0)
        XCTAssertGreaterThan(outcomes["neither", default: 0], 0)
    }

    /// A crash at every step of making a record: what is left is a whole record or one that the
    /// open refuses by naming the missing part. No number was handed out either way.
    func testACrashAtEveryStepOfCreate() throws {
        let probe = StepScript()
        _ = try SessionRecord.create(root: try scratchRoot(), meta: Fixtures.meta(), key: Fixtures.key, hook: probe.hook)
        let total = probe.count
        XCTAssertEqual(probe.steps.first?.description, "root.mkdir")
        XCTAssertEqual(probe.steps.last?.description, "root.fsync")
        var whole = 0
        for stepIndex in 0..<total {
            for action: StorageHookAction in [.crashBefore, .crashAfter, .tornWrite(bytes: 5)] {
                let root = try scratchRoot()
                let script = StepScript()
                script.at(stepIndex, action)
                XCTAssertThrowsError(try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: script.hook))
                do {
                    let record = try SessionRecord.open(root: root, id: Fixtures.id)
                    XCTAssertEqual(record.state, .dirty)
                    XCTAssertEqual(record.gate.reservedLimits, .sessionStart)
                    XCTAssertEqual(try record.readKey(), Fixtures.key)
                    whole += 1
                } catch let error as RecordError {
                    if error == .notProtected, crashedBeforeProtection(probe.steps, at: stepIndex, action) { continue }
                    guard case .missing = error else { return XCTFail("step \(stepIndex): \(error)") }
                }
            }
        }
        XCTAssertGreaterThan(whole, 0)
    }

    func testDelete() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        XCTAssertTrue(try record.save(export(Fixtures.minimalSnapshot(), record.gate)))
        try record.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/" + Fixtures.id.description))
        XCTAssertEqual(SessionStore.sessionIDs(root: root), [])
        XCTAssertFalse(try record.store.exists)
    }
}
