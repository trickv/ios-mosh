import Foundation
import MoshSession
import MoshTransport
import XCTest
@testable import MoshResume

/// What a test knows about a record's past, over all the processes that used it: the numbers
/// that were handed out, the datagrams that passed, and what was exported when.
final class GateModel {
    /// One above the highest number handed out, per counter (0: none yet).
    var used = GateCounters(sequence: 0, state: 0, fragmentID: 0)
    /// Datagrams that passed the gate (`willSendDatagram()` returned), over all generations.
    var passed: UInt64 = 0
    /// For each export, by its marker: `passed` at that moment.
    var passedAtExport: [UInt64: UInt64] = [:]
    var nextMarker: UInt64 = 1
    /// The marker of the last save that returned true and after which nothing passed.
    var lastCleanMarker: UInt64?

    func note(_ counter: WritableKeyPath<GateCounters, UInt64>, _ number: UInt64, _ what: String,
              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(number, used[keyPath: counter], "\(what): a number was handed out twice", file: file, line: line)
        used[keyPath: counter] = max(used[keyPath: counter], number + 1)
    }
}

enum GateOp: Equatable {
    /// A new state in one datagram: state number, fragment id, sequence number, dirty.
    case send
    /// A retransmission: a sequence number and the dirty rule only.
    case resend
    /// Export and save at once: must be clean afterwards.
    case save
    /// Export, a datagram, then the save: must be refused.
    case staleSave
    case beginSending
}

/// Small blocks, so that a short script crosses many block boundaries.
let testBlocks = GateCounters(sequence: 3, state: 2, fragmentID: 4)

let gateScript: [GateOp] = [
    .send, .send, .resend, .save, .send, .resend, .resend, .send, .staleSave, .save, .save, .send,
    .beginSending, .send, .send, .resend, .save, .beginSending, .send,
]

extension XCTestCase {
    func perform(_ op: GateOp, on record: SessionRecord, _ model: GateModel, _ what: String) throws {
        let gate = record.gate
        func datagram(newState: Bool) throws {
            if newState {
                model.note(\.state, try gate.takeStateNumber(), what)
                model.note(\.fragmentID, try gate.takeFragmentID(), what)
            }
            let sequence = try gate.takeSequenceNumber()
            model.note(\.sequence, sequence, what)
            XCTAssertLessThan(sequence, gate.reservedLimits.sequence, what)
            try gate.willSendDatagram()
            model.passed += 1
            model.lastCleanMarker = nil
            XCTAssertTrue(gate.isDirty, what)
        }
        func export() -> SessionExport {
            var snapshot = Fixtures.minimalSnapshot()
            let marker = model.nextMarker
            model.nextMarker += 1
            snapshot.transport.receiverExpectedSequence = marker
            model.passedAtExport[marker] = model.passed
            return SessionExport(snapshot: snapshot, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
        }
        switch op {
        case .send:
            try datagram(newState: true)
        case .resend:
            try datagram(newState: false)
        case .save:
            let exported = export()
            let clean = try record.save(exported)
            XCTAssertTrue(clean, what)
            model.lastCleanMarker = exported.snapshot.transport.receiverExpectedSequence
            XCTAssertFalse(gate.isDirty, what)
        case .staleSave:
            let exported = export()
            try datagram(newState: false)
            let clean = try record.save(exported)
            XCTAssertFalse(clean, "\(what): a clean mark for a snapshot older than a datagram")
            XCTAssertTrue(gate.isDirty, what)
        case .beginSending:
            try gate.beginSending()
            model.lastCleanMarker = nil
        }
    }

    /// What must hold for a record whatever happened to the processes that used it.
    /// Returns the marker of the snapshot the record would resume from, if any.
    @discardableResult
    func verify(_ record: SessionRecord, _ model: GateModel, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) -> UInt64? {
        let limits = record.gate.reservedLimits
        XCTAssertGreaterThanOrEqual(limits.sequence, model.used.sequence, "\(what): sequence numbers would repeat (N1)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(limits.state, model.used.state, "\(what): state numbers would repeat (N2)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(limits.fragmentID, model.used.fragmentID, "\(what): fragment ids would repeat (N4)", file: file, line: line)
        do {
            let snapshot = try record.loadSnapshot()
            let marker = snapshot.transport.receiverExpectedSequence
            XCTAssertEqual(model.passedAtExport[marker], model.passed,
                           "\(what): the record resumes from snapshot \(marker), and datagrams passed after it was taken (N2)",
                           file: file, line: line)
            return marker
        } catch RecordError.notResumable {
            return nil
        } catch RecordError.missing(.snapshot) {
            XCTFail("\(what): clean without a snapshot", file: file, line: line)
            return nil
        } catch {
            XCTFail("\(what): \(error)", file: file, line: line)
            return nil
        }
    }

    /// The same for the bytes of a counters file: with either slot wiped, what is read is still safe.
    ///
    /// - Parameter mayBeUnreadable: true right after a write that failed half way: that slot is
    ///   already bad, and losing the other one as well leaves no reading at all (a dead record,
    ///   which is safe).
    func verifyWithOneSlotLost(directory: String, _ model: GateModel, _ what: String, mayBeUnreadable: Bool = false,
                               snapshotMarker: (UInt64) -> UInt64?) throws {
        let image = Array(try Data(contentsOf: URL(fileURLWithPath: directory + "/counters")))
        XCTAssertEqual(image.count, CountersFile.fileSize)
        let slots = (0..<2).map { Array(image[CountersFile.offset(ofSlot: $0)..<(CountersFile.offset(ofSlot: $0) + CountersFile.slotSize)]) }
        for lost in 0..<2 {
            var damaged = slots
            damaged[lost] = [UInt8](repeating: 0, count: CountersFile.slotSize)
            let reading: CountersReading
            do {
                reading = try CountersFile.read(slot0: damaged[0], slot1: damaged[1], sessionID: Fixtures.id)
            } catch {
                XCTAssertTrue(mayBeUnreadable, "\(what), slot \(lost) lost: \(error)")
                continue
            }
            XCTAssertGreaterThanOrEqual(reading.limits.sequence, model.used.sequence, "\(what), slot \(lost) lost: N1")
            XCTAssertGreaterThanOrEqual(reading.limits.state, model.used.state, "\(what), slot \(lost) lost: N2")
            XCTAssertGreaterThanOrEqual(reading.limits.fragmentID, model.used.fragmentID, "\(what), slot \(lost) lost: N4")
            if case .clean(let id) = reading.state, let marker = snapshotMarker(id) {
                XCTAssertEqual(model.passedAtExport[marker], model.passed,
                               "\(what), slot \(lost) lost: clean for snapshot \(marker), which is older than a datagram")
            }
        }
    }
}

final class FileBackedGateTests: XCTestCase {
    private func newRecord(blocks: GateCounters = testBlocks, hook: StorageHook? = nil) throws -> (SessionRecord, String) {
        let root = try scratchRoot("gate")
        return (try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, blocks: blocks, hook: hook), root)
    }

    private func slotsOnDisk(_ record: SessionRecord) throws -> [CountersSlot?] {
        let image = Array(try Data(contentsOf: URL(fileURLWithPath: record.store.directory + "/counters")))
        return (0..<2).map {
            try? CountersSlot(encoded: Array(image[CountersFile.offset(ofSlot: $0)..<(CountersFile.offset(ofSlot: $0) + 68)]),
                              expecting: record.id)
        }
    }

    // MARK: The protocol's rules

    func testNumbersStartWhereASessionStartsAndNeverRepeat() throws {
        let (record, _) = try newRecord()
        let gate = record.gate
        XCTAssertEqual(gate.reservedLimits, .sessionStart)
        XCTAssertEqual(try (0..<10).map { _ in try gate.takeSequenceNumber() }, Array(0..<10))
        XCTAssertEqual(try (0..<5).map { _ in try gate.takeStateNumber() }, Array(1..<6))
        XCTAssertEqual(try (0..<9).map { _ in try gate.takeFragmentID() }, Array(1..<10))
        XCTAssertEqual(gate.reservedLimits, GateCounters(sequence: 12, state: 7, fragmentID: 13))
        XCTAssertEqual(gate.datagramsPassed, 0)
    }

    func testDefaultBlocksAreThePlans() throws {
        let (record, _) = try newRecord(blocks: FileBackedGate.defaultBlocks)
        _ = try record.gate.takeSequenceNumber()
        _ = try record.gate.takeStateNumber()
        _ = try record.gate.takeFragmentID()
        XCTAssertEqual(record.gate.reservedLimits, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025))
    }

    /// Reserve ahead: when a number is handed out, both slots on disk already hold a limit above it.
    func testALimitIsInBothSlotsBeforeANumberBelowItIsUsed() throws {
        let script = StepScript()
        let (record, _) = try newRecord(hook: script.hook)
        let before = script.count
        for _ in 0..<20 {
            let number = try record.gate.takeSequenceNumber()
            let slots = try slotsOnDisk(record)
            XCTAssertEqual(slots.compactMap { $0 }.count, 2)
            for slot in slots {
                XCTAssertGreaterThan(slot!.limits.sequence, number)
            }
        }
        // 7 blocks of 3, each two writes with an fsync after each write.
        let steps = script.steps[before...].map(\.description)
        XCTAssertEqual(steps.count, 7 * 4)
        XCTAssertEqual(Array(steps.prefix(4)), ["counters.write", "counters.fsync", "counters.write", "counters.fsync"])
    }

    /// Dirty before send: when `willSendDatagram()` returns, both slots say "dirty".
    func testDirtyIsInBothSlotsBeforeADatagramPasses() throws {
        let script = StepScript()
        let (record, _) = try newRecord(hook: script.hook)
        let gate = record.gate
        try gate.willSendDatagram()
        XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.dirty, .dirty])
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 1))))
        guard case .clean(let id) = record.state else { return XCTFail("not clean") }
        XCTAssertEqual(Set(try slotsOnDisk(record).map { $0?.state }), [.dirty, .clean(snapshotID: id)],
                       "the clean mark is in one slot; the other still says dirty")
        XCTAssertFalse(gate.isDirty)

        let before = script.count
        try gate.willSendDatagram()
        XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.dirty, .dirty])
        XCTAssertEqual(script.steps[before...].map(\.description),
                       ["counters.write", "counters.fsync", "counters.write", "counters.fsync"])
        XCTAssertTrue(gate.isDirty)
        // Later datagrams write nothing.
        let afterFirst = script.count
        for _ in 0..<5 { try gate.willSendDatagram() }
        XCTAssertEqual(script.count, afterFirst)
        XCTAssertEqual(gate.datagramsPassed, 7)
    }

    func testCleanOnlyIfNothingWasSentSinceTheExport() throws {
        let (record, _) = try newRecord()
        let gate = record.gate
        try gate.willSendDatagram()
        let token = CleanToken(datagramsPassed: gate.datagramsPassed)
        try gate.willSendDatagram()
        XCTAssertFalse(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: token)))
        XCTAssertEqual(record.state, .dirty)
        XCTAssertThrowsError(try record.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .notResumable(.dirty)) }
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(),
                                                    cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))))
        XCTAssertNoThrow(try record.loadSnapshot())
    }

    /// There is no clean mark without a stored snapshot: the gate does not take the protocol's
    /// `markClean` on its own word.
    func testNoCleanMarkWithoutAStoredSnapshot() throws {
        let (record, _) = try newRecord()
        let gate = record.gate
        XCTAssertThrowsError(try gate.markClean(ifDatagramsPassed: 0)) { XCTAssertEqual($0 as? FileGateError, .noSnapshotStored) }
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        try gate.willSendDatagram()
        // The snapshot stored before that datagram does not count any more.
        XCTAssertThrowsError(try gate.markClean(ifDatagramsPassed: 1)) { XCTAssertEqual($0 as? FileGateError, .noSnapshotStored) }
        XCTAssertEqual(record.state, .dirty)
        XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.dirty, .dirty])
    }

    func testAnEndedRecordIsNeverCleanAgainButStillSends() throws {
        let (record, root) = try newRecord()
        let gate = record.gate
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        try gate.markEnded()
        XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.ended, .ended])
        XCTAssertTrue(gate.isDirty)
        XCTAssertFalse(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        let number = try gate.takeSequenceNumber()
        try gate.willSendDatagram()
        try gate.beginSending()
        XCTAssertEqual(record.state, .ended)
        XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.ended, .ended])
        XCTAssertThrowsError(try record.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .notResumable(.ended)) }
        record.close()
        let again = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
        XCTAssertEqual(again.state, .ended)
        XCTAssertGreaterThan(try again.gate.takeSequenceNumber(), number)
    }

    func testExhaustion() throws {
        let root = try scratchRoot()
        let store = SessionStore(root: root, id: Fixtures.id)
        let lock = try store.create(meta: Fixtures.meta(), key: nil)
        let high = GateCounters(sequence: .max - 4, state: .max - 4, fragmentID: .max - 4)
        try Data(CountersFile.initialImage(sessionID: Fixtures.id, limits: high))
            .write(to: URL(fileURLWithPath: store.directory + "/counters"))
        let gate = try FileBackedGate(store: store, lock: lock, blocks: testBlocks)
        XCTAssertEqual(try gate.takeSequenceNumber(), .max - 4)
        XCTAssertEqual(try gate.takeSequenceNumber(), .max - 3)
        XCTAssertEqual(try gate.takeSequenceNumber(), .max - 2)
        XCTAssertThrowsError(try gate.takeSequenceNumber()) { XCTAssertEqual($0 as? GateError, .exhausted) }
        XCTAssertThrowsError(try gate.beginSending()) { XCTAssertEqual($0 as? GateError, .exhausted) }
    }

    // MARK: A new process

    /// A new gate for the same record starts at the old one's reserved limits: above every
    /// number the old one handed out, wherever in its blocks it was.
    func testANewGateStartsAtTheReservedLimits() throws {
        let (first, root) = try newRecord()
        let model = GateModel()
        for op in [GateOp.send, .send, .resend, .send] { try perform(op, on: first, model, "first") }
        let limits = first.gate.reservedLimits
        first.close()
        let second = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
        XCTAssertEqual(second.gate.reservedLimits, limits)
        XCTAssertEqual(try second.gate.takeSequenceNumber(), limits.sequence)
        XCTAssertEqual(try second.gate.takeStateNumber(), limits.state)
        XCTAssertEqual(try second.gate.takeFragmentID(), limits.fragmentID)
        XCTAssertEqual(second.gate.datagramsPassed, 0)
        verify(second, model, "second")
    }

    func testBeginSendingReservesAndDirtiesInOneChange() throws {
        let script = StepScript()
        let (record, _) = try newRecord(hook: script.hook)
        XCTAssertTrue(try record.save(SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 0))))
        let before = script.count
        try record.gate.beginSending()
        XCTAssertEqual(script.count - before, 4)
        XCTAssertEqual(record.state, .dirty)
        XCTAssertEqual(record.gate.reservedLimits, GateCounters(sequence: 3, state: 3, fragmentID: 5))
        _ = try record.gate.takeStateNumber()
        _ = try record.gate.takeFragmentID()
        _ = try record.gate.takeSequenceNumber()
        try record.gate.willSendDatagram()
        XCTAssertEqual(script.count - before, 4, "the first datagram after a cold start needs no further write")
        XCTAssertThrowsError(try record.loadSnapshot()) { XCTAssertEqual($0 as? RecordError, .notResumable(.dirty)) }
    }

    /// The whole script without a crash; after every operation the record is closed and opened
    /// again, as if every operation were the last one of its process.
    func testTheScriptWithAReopenAfterEveryOperation() throws {
        var (record, root) = try newRecord()
        let model = GateModel()
        var resumable = 0
        for (index, op) in gateScript.enumerated() {
            try perform(op, on: record, model, "op \(index)")
            record.close()
            record = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
            let marker = verify(record, model, "after op \(index) \(op)")
            XCTAssertEqual(marker, model.lastCleanMarker, "after op \(index) \(op): a saved snapshot is the one resumed from")
            if marker != nil { resumable += 1 }
        }
        XCTAssertEqual(resumable, 4)
    }

    // MARK: Crashes

    /// The process is killed at every step of the script (before it, after it, and for a write
    /// with only some of its bytes on disk). A new process opens the record: its numbers are
    /// above every number handed out before, and it resumes only from a snapshot that no
    /// datagram followed. Then the new process is killed too, somewhere, and a third one checks
    /// the same.
    func testACrashAtEveryStepNeverReusesANumberOrResumesAStaleSnapshot() throws {
        let probe = StepScript()
        do {
            let (record, _) = try newRecord(hook: probe.hook)
            let model = GateModel()
            for (index, op) in gateScript.enumerated() { try perform(op, on: record, model, "probe op \(index)") }
        }
        let total = probe.count
        XCTAssertGreaterThan(total, 80)
        var generator = SplitMix64(seed: 0xC0FFEE)
        var runs = 0
        var resumed = 0
        var secondCrashes = 0

        for stepIndex in 0..<total {
            var actions: [StorageHookAction] = [.crashBefore, .crashAfter]
            if probe.steps[stepIndex].operation == .write {
                actions += [1, 6, 7, 8, 16, 33, 57, 64, 67].map { .tornWrite(bytes: $0) }
            }
            for action in actions {
                let what = "crash \(action) at step \(stepIndex) (\(probe.steps[stepIndex]))"
                let root = try scratchRoot("gate")
                let model = GateModel()
                let script = StepScript()
                script.at(stepIndex, action)

                // First process.
                var crashed = false
                do {
                    let record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key,
                                                          blocks: testBlocks, hook: script.hook)
                    for (index, op) in gateScript.enumerated() { try perform(op, on: record, model, "\(what), op \(index)") }
                } catch StorageError.simulatedCrash {
                    crashed = true
                }
                XCTAssertTrue(crashed, what)
                runs += 1

                // Second process: opens what is on disk, checks, goes on, and is killed as well.
                let second = StepScript()
                let secondModelStart = model.passed
                do {
                    let record: SessionRecord
                    do {
                        record = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks, hook: second.hook)
                    } catch RecordError.missing {
                        // Killed while the record was being made: nothing can have been handed out.
                        XCTAssertEqual(model.used, GateCounters(sequence: 0, state: 0, fragmentID: 0), what)
                        continue
                    } catch RecordError.notProtected where crashedBeforeProtection(probe.steps, at: stepIndex, action) {
                        // Killed before the new directory was taken out of the backup (Apple platforms).
                        XCTAssertEqual(model.used, GateCounters(sequence: 0, state: 0, fragmentID: 0), what)
                        continue
                    }
                    if verify(record, model, what) != nil { resumed += 1 }
                    second.at(Int.random(in: 0..<40, using: &generator),
                              [.crashBefore, .crashAfter, .tornWrite(bytes: Int.random(in: 0...68, using: &generator))]
                                .randomElement(using: &generator)!)
                    for (index, op) in gateScript.enumerated() { try perform(op, on: record, model, "\(what), second process, op \(index)") }
                    XCTFail("\(what): the second process was not killed")
                } catch StorageError.simulatedCrash {
                    secondCrashes += 1
                }
                XCTAssertGreaterThanOrEqual(model.passed, secondModelStart)

                // Third process.
                let third = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
                verify(third, model, "\(what), then a second crash")
                try perform(.send, on: third, model, "\(what), third process")
                try perform(.save, on: third, model, "\(what), third process")
                XCTAssertEqual(verify(third, model, "\(what), third process"), model.lastCleanMarker)
                third.close()
            }
        }
        XCTAssertGreaterThan(runs, 500)
        XCTAssertGreaterThan(resumed, 20, "some crashes leave a record that resumes")
        XCTAssertGreaterThan(secondCrashes, 400)
    }

    /// A slot that goes bad at rest (not torn by a crash: lost later) never makes the record
    /// less safe: after every operation of the script, with either slot wiped, the limits read
    /// are above every number handed out, and "clean" is read only for a snapshot that no
    /// datagram followed.
    func testLosingEitherSlotAfterAnyOperationIsSafe() throws {
        let (record, _) = try newRecord()
        let model = GateModel()
        var markers: [UInt64: UInt64] = [:]   // snapshot id -> marker
        for (index, op) in gateScript.enumerated() {
            try perform(op, on: record, model, "op \(index)")
            if case .clean(let id) = record.state, let marker = model.lastCleanMarker { markers[id] = marker }
            try verifyWithOneSlotLost(directory: record.store.directory, model, "after op \(index) \(op)") { markers[$0] }
        }
        XCTAssertEqual(markers.count, 4)
    }

    // MARK: Failures that are not crashes

    /// A step fails (the device is locked, the disk is full) at every step of the script, with
    /// some of a write's bytes on disk. The call throws, the script repeats the operation, and
    /// everything holds as if nothing had happened, also for a slot lost at that moment.
    func testAFailedStepIsRepeatedWithoutHarm() throws {
        let probe = StepScript()
        do {
            let (record, _) = try newRecord(hook: probe.hook)
            let model = GateModel()
            for (index, op) in gateScript.enumerated() { try perform(op, on: record, model, "probe op \(index)") }
        }
        let created = probe.steps.firstIndex { $0.description == "root.fsync" }! + 1
        var failures = 0
        for stepIndex in created..<probe.count {
            for bytes in [0, 30, 68] {
                let what = "failure at step \(stepIndex) (\(probe.steps[stepIndex])) after \(bytes) bytes"
                let script = StepScript()
                script.at(stepIndex, .fail(errno: EPERM, bytes: bytes))
                let (record, root) = try newRecord(hook: script.hook)
                let model = GateModel()
                var markers: [UInt64: UInt64] = [:]
                for (index, op) in gateScript.enumerated() {
                    var done = false
                    var attempts = 0
                    while !done {
                        attempts += 1
                        do {
                            try performAtomically(op, on: record, model, "\(what), op \(index)")
                            done = true
                        } catch StorageError.io(_, let code) {
                            XCTAssertEqual(code, EPERM)
                            failures += 1
                            XCTAssertLessThan(attempts, 3, what)
                            try verifyWithOneSlotLost(directory: record.store.directory, model, "\(what), right after it",
                                                      mayBeUnreadable: true) { markers[$0] }
                        }
                    }
                    if case .clean(let id) = record.state, let marker = model.lastCleanMarker { markers[id] = marker }
                    try verifyWithOneSlotLost(directory: record.store.directory, model, "\(what), after op \(index)") { markers[$0] }
                }
                record.close()
                let reopened = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
                XCTAssertEqual(verify(reopened, model, what), model.lastCleanMarker)
                reopened.close()
            }
        }
        XCTAssertGreaterThan(failures, 200)
    }

    /// `perform` for the failure test: the parts of an operation that already happened are not
    /// repeated when a later part failed (a number that was handed out stays handed out).
    private func performAtomically(_ op: GateOp, on record: SessionRecord, _ model: GateModel, _ what: String) throws {
        let gate = record.gate
        switch op {
        case .send, .resend:
            // Retried from the start: the numbers taken before the failure are burnt, as in the Outbox.
            try perform(op, on: record, model, what)
        case .save, .beginSending:
            try perform(op, on: record, model, what)
        case .staleSave:
            // The datagram in the middle must not be counted twice: do the parts by hand.
            var snapshot = Fixtures.minimalSnapshot()
            let marker = model.nextMarker
            model.nextMarker += 1
            snapshot.transport.receiverExpectedSequence = marker
            model.passedAtExport[marker] = model.passed
            let exported = SessionExport(snapshot: snapshot, cleanToken: CleanToken(datagramsPassed: gate.datagramsPassed))
            var sent = false
            while !sent {
                do {
                    try perform(.resend, on: record, model, what)
                    sent = true
                } catch StorageError.io {}
            }
            var saved: Bool?
            while saved == nil {
                do {
                    saved = try record.save(exported)
                } catch StorageError.io {}
            }
            XCTAssertEqual(saved, false, what)
        }
    }

    /// The clean mark's write fails half way, and "clean" may be on disk. The next datagram must
    /// not rely on what the gate believed before: it writes "dirty" to both slots first.
    func testAFailedCleanMarkIsFollowedByADurableDirty() throws {
        for bytes in [0, 7, 40, 68] {
            let script = StepScript()
            let (record, root) = try newRecord(hook: script.hook)
            let gate = record.gate
            try gate.willSendDatagram()
            // save: create, write, fsync, rename, fsync of the directory, then the counters write.
            script.at(script.count + 5, .fail(errno: EIO, bytes: bytes))
            let exported = SessionExport(snapshot: Fixtures.minimalSnapshot(), cleanToken: CleanToken(datagramsPassed: 1))
            XCTAssertThrowsError(try record.save(exported)) {
                XCTAssertEqual($0 as? StorageError, .io(step: "counters.write", errno: EIO))
            }
            XCTAssertTrue(gate.isDirty, "the gate does not claim a clean mark it could not finish")
            XCTAssertEqual(record.state, .dirty)
            let before = script.count
            try gate.willSendDatagram()
            XCTAssertEqual(script.count - before, 4, "dirty is written again, to both slots (\(bytes) bytes)")
            XCTAssertEqual(try slotsOnDisk(record).map { $0?.state }, [.dirty, .dirty])
            record.close()
            let reopened = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
            XCTAssertEqual(reopened.state, .dirty)
        }
    }

    /// The fsync after the clean mark fails: "clean" is on disk, the gate says dirty. If the
    /// process dies now, the record resumes, and that is right: no datagram followed the snapshot.
    func testACleanMarkWhoseFsyncFailedIsStillATrueMark() throws {
        let script = StepScript()
        let (record, root) = try newRecord(hook: script.hook)
        try record.gate.willSendDatagram()
        script.at(script.count + 6, .fail(errno: EIO))
        let exported = SessionExport(snapshot: Fixtures.richSnapshot(), cleanToken: CleanToken(datagramsPassed: 1))
        XCTAssertThrowsError(try record.save(exported))
        XCTAssertTrue(record.gate.isDirty)
        record.close()
        let reopened = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
        XCTAssertEqual(try reopened.loadSnapshot(), Fixtures.richSnapshot())
    }

    /// Limits written by a failed reservation stay on disk; later writes must not go below them
    /// (a newer slot with a lower limit would make the file contradict itself).
    func testLimitsOnDiskNeverGoDownAfterAFailedReservation() throws {
        let script = StepScript()
        let (record, root) = try newRecord(hook: script.hook)
        let gate = record.gate
        // The first of the two slot writes succeeds, the second fails.
        script.at(script.count + 2, .fail(errno: ENOSPC))
        XCTAssertThrowsError(try gate.takeSequenceNumber())
        XCTAssertEqual(gate.reservedLimits, .sessionStart, "not reserved until both slots hold it")
        try gate.willSendDatagram()
        XCTAssertNoThrow(try record.store.readCounters())
        XCTAssertEqual(gate.reservedLimits.sequence, 3, "the write of dirty carried the raised limit into both slots")
        XCTAssertEqual(try gate.takeSequenceNumber(), 0)
        record.close()
        let reopened = try SessionRecord.open(root: root, id: Fixtures.id, blocks: testBlocks)
        XCTAssertEqual(reopened.gate.reservedLimits.sequence, 3)
    }

    // MARK: Threads

    func testConcurrentUseHandsOutEachNumberOnce() throws {
        let (record, _) = try newRecord(blocks: GateCounters(sequence: 50, state: 50, fragmentID: 50))
        let gate = record.gate
        let lock = NSLock()
        var numbers: [UInt64] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            var mine: [UInt64] = []
            for _ in 0..<500 {
                mine.append(try! gate.takeSequenceNumber())
                try! gate.willSendDatagram()
            }
            lock.lock()
            numbers += mine
            lock.unlock()
        }
        XCTAssertEqual(numbers.sorted(), Array(0..<4000))
        XCTAssertEqual(gate.datagramsPassed, 4000)
    }
}
