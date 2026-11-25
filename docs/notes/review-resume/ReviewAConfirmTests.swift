import Foundation
import MoshSession
import MoshTransport
import XCTest
@testable import MoshResume

final class ReviewAConfirmTests: XCTestCase {
    private func export(_ gate: FileBackedGate, epoch: UInt64 = 0) -> SessionExport {
        var s = Fixtures.minimalSnapshot()
        s.transport.receiverExpectedSequence = epoch
        return SessionExport(snapshot: s, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
    }

    /// A-1: create() over an existing record resets the counters under the same key.
    func testCreateOverAnExistingRecordResetsCounters() throws {
        let root = try scratchRoot()
        let first = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        var used: [UInt64] = []
        for _ in 0..<5 { used.append(try first.gate.takeSequenceNumber()); try first.gate.willSendDatagram() }
        first.close()
        let second = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let again = try second.gate.takeSequenceNumber()
        print("CONFIRM A-1 used", used, "after second create:", again, "key equal:", try second.readKey() == Fixtures.key)
        XCTAssertFalse(used.contains(again), "sequence number \(again) handed out twice under one key")
    }

    /// A-2: a second save while clean, killed between the rename and the clean mark, loses a resumable record.
    func testSecondSaveKilledAfterRenameLosesTheCleanRecord() throws {
        let root = try scratchRoot()
        final class Flag: @unchecked Sendable { var armed = false }
        let flag = Flag()
        let hook: StorageHook = { step in
            flag.armed && step.description == "snapshot.rename" ? .crashAfter : .proceed
        }
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, hook: hook)
        _ = try record.gate.takeSequenceNumber(); try record.gate.willSendDatagram()
        XCTAssertTrue(try record.save(export(record.gate)))
        flag.armed = true
        XCTAssertThrowsError(try record.save(export(record.gate)))   // nothing changed since the first save
        record.close()
        let outcome = ResumeCoordinator.coldStart(root: root, id: Fixtures.id, currentSize: nil)
        print("CONFIRM A-2 outcome:", outcome)
        if case .resumed = outcome {} else { XCTFail("a record that was clean and unchanged is not resumed: \(outcome)") }
    }

    /// A-3: two gates on one lock hand out the same numbers.
    func testTwoGatesOnOneLock() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        record.close()
        let store = SessionStore(root: root, id: Fixtures.id)
        let lock = try store.acquireLock()
        let a = try FileBackedGate(store: store, lock: lock)
        let b = try FileBackedGate(store: store, lock: lock)
        let x = try a.takeSequenceNumber(), y = try b.takeSequenceNumber()
        print("CONFIRM A-3", x, y)
        XCTAssertNotEqual(x, y)
    }

    /// A-4: after a refused save, markClean on the gate's own word marks a stale snapshot clean.
    func testStaleStoredSnapshotID() throws {
        let root = try scratchRoot()
        let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key)
        let gate = record.gate
        _ = try gate.takeSequenceNumber(); try gate.willSendDatagram()
        let exported = export(gate, epoch: 1)                       // holds the world after 1 datagram
        _ = try gate.takeSequenceNumber(); try gate.willSendDatagram()   // datagram 2 leaves
        XCTAssertFalse(try record.save(exported))                   // refused, as it must be
        // "there is no clean mark on the gate's own word" (R6):
        let marked = try gate.markClean(ifDatagramsPassed: gate.datagramsPassed)
        record.close()
        let reopened = try SessionRecord.open(root: root, id: Fixtures.id)
        let loaded = try? reopened.loadSnapshot()
        print("CONFIRM A-4 marked:", marked, "loaded epoch:", loaded?.transport.receiverExpectedSequence as Any)
        XCTAssertNil(loaded, "a snapshot older than a datagram was loaded")
    }
}
