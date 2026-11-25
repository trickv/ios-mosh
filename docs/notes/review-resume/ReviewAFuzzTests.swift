import Foundation
import MoshSession
import MoshTransport
import XCTest
@testable import MoshResume

final class ReviewAFuzzTests: XCTestCase {
    final class Box: @unchecked Sendable {
        var rng: SplitMix64
        var stepsLeft: Int
        var failRate: UInt64
        init(seed: UInt64, steps: Int, failRate: UInt64) { rng = SplitMix64(seed: seed); stepsLeft = steps; self.failRate = failRate }
    }

    func runOne(seed: UInt64) throws -> String? {
        var rng = SplitMix64(seed: seed)
        let root = try scratchRoot("fuzz\(seed)")
        let blocks = GateCounters(sequence: 3, state: 2, fragmentID: 4)
        var floors = GateCounters.sessionStart      // first number not yet handed out, at least
        var totalDatagrams: UInt64 = 0
        var endedForSure = false
        var first = true
        let dir = root + "/" + Fixtures.id.description
        var trace: [String] = []
        for life in 0..<6 {
            let box = Box(seed: rng.next(), steps: Int(rng.next() % 60), failRate: rng.next() % 3 == 0 ? 0 : 12)
            let hook: StorageHook = { step in
                if box.stepsLeft == 0 {
                    box.stepsLeft = -1
                    switch box.rng.next() % 3 {
                    case 0: return .crashBefore
                    case 1: return .crashAfter
                    default: return .tornWrite(bytes: Int(box.rng.next() % 70))
                    }
                }
                box.stepsLeft -= 1
                if box.failRate > 0, box.rng.next() % 100 < box.failRate {
                    return .fail(errno: EIO, bytes: Int(box.rng.next() % 70))
                }
                return .proceed
            }
            let record: SessionRecord
            do {
                if first {
                    // creation without faults
                    record = try SessionRecord.create(root: root, meta: Fixtures.meta(), key: Fixtures.key, blocks: blocks, hook: nil)
                    record.close()
                    first = false
                    continue
                }
                record = try SessionRecord.open(root: root, id: Fixtures.id, blocks: blocks, hook: hook)
            } catch {
                return "seed \(seed) life \(life): open failed \(error) trace \(trace.suffix(40))"
            }
            // verify
            let limits = record.gate.reservedLimits
            if limits.sequence < floors.sequence || limits.state < floors.state || limits.fragmentID < floors.fragmentID {
                return "seed \(seed) life \(life): limits \(limits) below used \(floors) trace \(trace.suffix(60))"
            }
            var loaded = false
            do {
                let snap = try record.loadSnapshot()
                loaded = true
                if snap.transport.receiverExpectedSequence != totalDatagrams {
                    return "seed \(seed) life \(life): STALE snapshot epoch \(snap.transport.receiverExpectedSequence) vs \(totalDatagrams) trace \(trace.suffix(60))"
                }
                if endedForSure { return "seed \(seed) life \(life): ended record resumed trace \(trace.suffix(60))" }
            } catch {}
            trace.append("L\(life)\(loaded ? "R" : "")")
            let gate = record.gate
            var staleToken: CleanToken? = nil
            var staleEpoch: UInt64 = 0
            ops: for _ in 0..<Int(rng.next() % 25) {
                let op = rng.next() % 12
                do {
                    switch op {
                    case 0, 1:
                        let n = try gate.takeSequenceNumber(); trace.append("q\(n)")
                        if n < floors.sequence { return "seed \(seed): seq \(n) reused (floor \(floors.sequence)) trace \(trace.suffix(60))" }
                        floors.sequence = n + 1
                    case 2:
                        let n = try gate.takeStateNumber(); trace.append("s\(n)")
                        if n < floors.state { return "seed \(seed): state \(n) reused trace \(trace.suffix(60))" }
                        floors.state = n + 1
                    case 3:
                        let n = try gate.takeFragmentID(); trace.append("f\(n)")
                        if n < floors.fragmentID { return "seed \(seed): frag \(n) reused trace \(trace.suffix(60))" }
                        floors.fragmentID = n + 1
                    case 4, 5:
                        try gate.willSendDatagram(); totalDatagrams += 1; trace.append("D")
                    case 6, 7:
                        var s = Fixtures.minimalSnapshot()
                        s.transport.receiverExpectedSequence = totalDatagrams
                        staleToken = CleanToken(datagramsPassed: gate.datagramsPassed); staleEpoch = totalDatagrams
                        trace.append("save?")
                        let ok = try record.save(SessionExport(snapshot: s, cleanToken: staleToken!))
                        trace.append("save=\(ok)")
                    case 8:
                        guard let token = staleToken else { continue }
                        var s = Fixtures.minimalSnapshot()
                        s.transport.receiverExpectedSequence = staleEpoch
                        trace.append("ssave?")
                        let ok = try record.save(SessionExport(snapshot: s, cleanToken: token))
                        trace.append("ssave=\(ok)")
                    case 9:
                        try gate.markDirty(); trace.append("dirty")
                    case 10:
                        try gate.beginSending(); trace.append("begin")
                    default:
                        if rng.next() % 6 == 0 { trace.append("end?"); try gate.markEnded(); endedForSure = true; trace.append("ended") }
                    }
                } catch let error as StorageError {
                    switch error {
                    case .io: trace.append("io"); continue
                    default: trace.append("CRASH"); break ops
                    }
                } catch {
                    trace.append("err(\(error))")
                }
            }
            record.close()
            // at-rest damage of one slot, if both are valid
            if rng.next() % 3 == 0, let reading = try? SessionStore(root: root, id: Fixtures.id).readCounters(), reading.validSlots == 2 {
                let which = Int(rng.next() % 2)
                let handle = FileHandle(forUpdatingAtPath: dir + "/counters")!
                handle.seek(toFileOffset: UInt64(which * 4096 + 20))
                handle.write(Data([0xFF, 0x00, 0xFF]))
                try handle.close()
                trace.append("LOSE\(which)")
            }
        }
        return nil
    }

    func testFuzz() throws {
        var failures = 0
        for seed in 1...UInt64(3000) {
            if let message = try runOne(seed: seed) {
                failures += 1
                print("FUZZFAIL", message)
                if failures > 8 { break }
            }
        }
        XCTAssertEqual(failures, 0)
    }
}
