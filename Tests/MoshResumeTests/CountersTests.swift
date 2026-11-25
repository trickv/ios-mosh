import MoshTransport
import XCTest
@testable import MoshResume

final class CountersTests: XCTestCase {
    private func slot(_ generation: UInt64, _ limits: GateCounters = GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025),
                      _ state: RecordState = .dirty, id: SessionID = Fixtures.id) -> CountersSlot {
        CountersSlot(generation: generation, sessionID: id, limits: limits, state: state)
    }

    /// The bytes at the two slot places for a pair of slots, each put where its generation says.
    private func places(_ slots: CountersSlot...) -> [[UInt8]] {
        var result: [[UInt8]] = [[], []]
        for slot in slots {
            result[CountersFile.slotIndex(forGeneration: slot.generation)] = slot.encoded()
        }
        return result
    }

    private func read(_ places: [[UInt8]]) throws -> CountersReading {
        try CountersFile.read(slot0: places[0], slot1: places[1], sessionID: Fixtures.id)
    }

    func testSlotLayout() throws {
        let bytes = slot(0x0102_0304_0506_0708, GateCounters(sequence: 0x1111, state: 0x2222, fragmentID: 0x3333),
                         .clean(snapshotID: 0x4444)).encoded()
        XCTAssertEqual(bytes.count, 68)
        XCTAssertEqual(Array(bytes[0..<8]), Array("MRc1".utf8) + [1, 0, 0, 0])
        XCTAssertEqual(Array(bytes[8..<16]), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Array(bytes[16..<32]), Fixtures.id.bytes)
        XCTAssertEqual(Array(bytes[32..<34]), [0x11, 0x11])
        XCTAssertEqual(Array(bytes[40..<42]), [0x22, 0x22])
        XCTAssertEqual(Array(bytes[48..<50]), [0x33, 0x33])
        XCTAssertEqual(Array(bytes[56..<58]), [0x44, 0x44])
        XCTAssertEqual(slot(1, .sessionStart, .dirty).encoded()[6], 1)
        XCTAssertEqual(slot(1, .sessionStart, .ended).encoded()[6], 2)
    }

    func testSlotRoundTrip() throws {
        let limits = [GateCounters.sessionStart, GateCounters(sequence: .max, state: .max, fragmentID: .max),
                      GateCounters(sequence: 65_536, state: 1_025, fragmentID: 2_049)]
        let states: [RecordState] = [.dirty, .ended, .clean(snapshotID: 1), .clean(snapshotID: .max)]
        for generation: UInt64 in [1, 2, 77, .max] {
            for limit in limits {
                for state in states {
                    let original = slot(generation, limit, state)
                    XCTAssertEqual(try CountersSlot(encoded: original.encoded(), expecting: Fixtures.id), original)
                }
            }
        }
    }

    func testSlotStrictChecksBehindTheChecksum() {
        func mutated(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
            var bytes = slot(5, .sessionStart, .clean(snapshotID: 9)).encoded()
            change(&bytes)
            return withFixedChecksum(bytes)
        }
        XCTAssertNoThrow(try CountersSlot(encoded: mutated { _ in }, expecting: Fixtures.id))
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[4] = 2 }, expecting: Fixtures.id), "version")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[6] = 3 }, expecting: Fixtures.id), "state 3")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[6] = 1 }, expecting: Fixtures.id), "dirty with a snapshot id")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[6] = 2 }, expecting: Fixtures.id), "ended with a snapshot id")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[56] = 0 }, expecting: Fixtures.id), "clean without a snapshot id")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[7] = 1 }, expecting: Fixtures.id), "reserved")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[8] = 0 }, expecting: Fixtures.id), "generation 0")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { $0[0] = 0x4E }, expecting: Fixtures.id), "magic")
        XCTAssertThrowsError(try CountersSlot(encoded: mutated { _ in }, expecting: Fixtures.otherID)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.counters, .wrongSession))
        }
    }

    func testInitialImage() throws {
        let image = CountersFile.initialImage(sessionID: Fixtures.id)
        XCTAssertEqual(image.count, 8192)
        let reading = try CountersFile.read(slot0: Array(image[0..<68]), slot1: Array(image[4096..<4164]), sessionID: Fixtures.id)
        XCTAssertEqual(reading, CountersReading(generation: 2, limits: .sessionStart, state: .dirty, validSlots: 2))
        XCTAssertTrue(image[68..<4096].allSatisfy { $0 == 0 })
        XCTAssertTrue(image[4164...].allSatisfy { $0 == 0 })
    }

    func testTheNewerValidSlotWins() throws {
        let low = GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025)
        let high = GateCounters(sequence: 131_072, state: 1_025, fragmentID: 1_025)
        XCTAssertEqual(try read(places(slot(4, low, .dirty), slot(5, high, .clean(snapshotID: 3)))),
                       CountersReading(generation: 5, limits: high, state: .clean(snapshotID: 3), validSlots: 2))
        XCTAssertEqual(try read(places(slot(6, high, .dirty), slot(5, low, .clean(snapshotID: 3)))),
                       CountersReading(generation: 6, limits: high, state: .dirty, validSlots: 2))
        XCTAssertEqual(try read(places(slot(5, low, .ended))),
                       CountersReading(generation: 5, limits: low, state: .ended, validSlots: 1))
    }

    func testContradictingSlotsAreRefused() {
        let low = GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025)
        for higher in [GateCounters(sequence: 65_537, state: 1_025, fragmentID: 1_025),
                       GateCounters(sequence: 65_536, state: 1_026, fragmentID: 1_025),
                       GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_026)] {
            XCTAssertThrowsError(try read(places(slot(4, higher), slot(5, low))), "a newer slot with a lower limit")
            XCTAssertNoThrow(try read(places(slot(4, low), slot(5, higher))))
        }
        XCTAssertThrowsError(try read(places(slot(4), slot(7))), "generations that are not neighbours")
        XCTAssertThrowsError(try read(places(slot(2), slot(5))))
        // A slot in the place of the other one does not count.
        let misplaced = [slot(5).encoded(), slot(4).encoded()]
        XCTAssertThrowsError(try read(misplaced))
        XCTAssertEqual(try read([slot(5).encoded(), slot(5).encoded()]).validSlots, 1)
        XCTAssertThrowsError(try read([[], []]))
        XCTAssertThrowsError(try read([[UInt8](repeating: 0, count: 68), [UInt8](repeating: 0, count: 68)]))
    }

    func testASlotOfAnotherSessionDoesNotCount() throws {
        let foreign = slot(5, GateCounters(sequence: 1 << 40, state: 1 << 40, fragmentID: 1 << 40), .clean(snapshotID: 1), id: Fixtures.otherID)
        let reading = try read(places(slot(4), foreign))
        XCTAssertEqual(reading.generation, 4)
        XCTAssertEqual(reading.state, .dirty)
        XCTAssertEqual(reading.validSlots, 1)
    }

    /// Every byte of each slot, damaged in every bit: the damaged slot is never used. The reading
    /// is the other slot's, and with the other slot damaged too there is no reading.
    func testDamageInOneSlotFallsBackToTheOther() throws {
        let older = slot(8, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .clean(snapshotID: 77))
        let newer = slot(9, GateCounters(sequence: 131_072, state: 2_049, fragmentID: 1_025), .dirty)
        let good = places(older, newer)
        var checked = 0
        for damagedSlot in 0..<2 {
            let survivor = damagedSlot == 0 ? newer : older
            for index in 0..<CountersFile.slotSize {
                for value in damagedValues(of: good[damagedSlot][index]) {
                    var bad = good
                    bad[damagedSlot][index] = value
                    let reading = try read(bad)
                    XCTAssertEqual(reading, CountersReading(generation: survivor.generation, limits: survivor.limits,
                                                            state: survivor.state, validSlots: 1),
                                   "slot \(damagedSlot) byte \(index) = \(value)")
                    var both = bad
                    both[1 - damagedSlot][index] = good[1 - damagedSlot][index] ^ 0x10
                    XCTAssertThrowsError(try read(both), "both slots damaged at byte \(index)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 2 * 68 * 8)
    }

    /// A write of the next generation over the older slot, cut after any number of bytes: the
    /// reading is what it was before the write or what it is after it, never a third thing.
    func testATornSlotWriteLeavesTheOldReadingOrGivesTheNewOne() throws {
        let cases: [(CountersSlot, CountersSlot, CountersSlot)] = [
            // (older, newer, the write that is torn: generation newer + 1 over the older slot)
            (slot(8, .sessionStart, .dirty), slot(9, .sessionStart, .dirty),
             slot(10, GateCounters(sequence: 65_536, state: 1, fragmentID: 1), .dirty)),
            (slot(3, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .dirty),
             slot(4, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .dirty),
             slot(5, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .clean(snapshotID: 0xABCD_EF01_2345_6789))),
            (slot(254, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .dirty),
             slot(255, GateCounters(sequence: 65_536, state: 1_025, fragmentID: 1_025), .clean(snapshotID: 5)),
             slot(256, GateCounters(sequence: 131_072, state: 2_049, fragmentID: 2_049), .dirty)),
        ]
        for (older, newer, write) in cases {
            let before = places(older, newer)
            let after = places(newer, write)
            let readingBefore = try read(before)
            let readingAfter = try read(after)
            XCTAssertEqual(readingBefore.generation, newer.generation)
            XCTAssertEqual(readingAfter.generation, write.generation)
            let target = CountersFile.slotIndex(forGeneration: write.generation)
            let new = write.encoded()
            for length in 0...CountersFile.slotSize {
                var torn = before
                torn[target].replaceSubrange(0..<length, with: new[0..<length])
                let reading = try read(torn)
                if torn[target] == new {
                    XCTAssertEqual(reading, readingAfter, "complete at \(length)")
                } else if torn[target] == before[target] {
                    XCTAssertEqual(reading, readingBefore, "unchanged at \(length)")
                } else {
                    // The slot is neither: it must not count, and the newer slot of before is used.
                    XCTAssertEqual(reading, CountersReading(generation: newer.generation, limits: newer.limits,
                                                            state: newer.state, validSlots: 1), "torn at \(length)")
                }
            }
            // The file itself cut short at any length inside the second slot: slot 0 alone.
            for length in 0..<CountersFile.slotSize {
                var cut = after
                cut[1] = Array(cut[1][0..<length])
                let survivor = [newer, write].first { CountersFile.slotIndex(forGeneration: $0.generation) == 0 }!
                XCTAssertEqual(try read(cut).generation, survivor.generation)
                XCTAssertEqual(try read(cut).validSlots, 1)
            }
        }
    }
}
