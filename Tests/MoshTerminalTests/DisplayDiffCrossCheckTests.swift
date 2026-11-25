// Byte equality of `DisplayDiff.newFrame` with mosh 1.4.0's own `Display::new_frame`.
//
// The same host bytes, resizes and copies go through mosh's `Terminal::Complete`
// (Support/moshref.cc) and through the port. For every pair of states (saved, current)
// both sides print the bytes of `new_frame`, for an initialized and a not initialized
// terminal. Some pairs are then applied: a copy of the saved state takes the diff, as a
// client's copy does, and the complete dump of the result is compared as well (and
// becomes the state the script goes on with).
//
// Byte equality needs more than equal screens: the scroll shortcut of `new_frame`
// depends on which lines share a row object and on the rows' generation numbers.

#if os(Linux)
import Foundation
import XCTest
import MoshTerminal

final class DisplayDiffCrossCheckTests: XCTestCase {
    private func caseCount(_ standard: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["MOSH_FUZZ_CASES"], let n = Int(s), n > 0 { return n }
        return standard
    }

    /// One history with several (saved, current) pairs. Returns the script and, for each
    /// output block, what it is.
    private func makeCase(seed: UInt64, variants: Bool) -> [RefOp] {
        var scenario = DiffScenario(seed: seed)
        var ops: [RefOp] = [scenario.start]
        for _ in 0..<scenario.fuzz.int(6) { ops += scenario.step() }
        ops.append(.save)
        let pairs = 6 + scenario.fuzz.int(6)
        for _ in 0..<pairs {
            for _ in 0..<(1 + scenario.fuzz.int(3)) { ops += scenario.step() }
            ops.append(.diff(initialized: true))
            ops.append(.diff(initialized: false))
            if variants {
                let display = DisplayDiff(hasECH: scenario.fuzz.chance(50), hasBCE: scenario.fuzz.chance(50),
                                          hasTitle: scenario.fuzz.chance(50))
                ops.append(.diff(initialized: scenario.fuzz.chance(80), display: display))
            }
            switch scenario.fuzz.int(10) {
            case 0..<2:
                // go on from what a client holds after this diff
                ops.append(.applyDiff(initialized: true))
                ops.append(.dump)
                ops.append(.reply)
                ops.append(.save)
            case 2..<3:
                ops.append(.applyDiff(initialized: false))
                ops.append(.dump)
                ops.append(.reply)
                ops.append(.save)
            case 3..<5:
                break // keep the older base, as a server does while acks are late
            default:
                ops.append(.save)
            }
        }
        return ops
    }

    private func run(seeds: Range<UInt64>, variants: Bool) throws -> (diffs: Int, matched: Int, failures: [String]) {
        var diffs = 0
        var matched = 0
        var failures: [String] = []
        // Several cases per moshref process.
        var batch: [(seed: UInt64, ops: [RefOp])] = []
        func flush() throws {
            if batch.isEmpty { return }
            let all = batch.flatMap { $0.ops }
            let expected = try MoshRef.reference(all)
            let actual = MoshRef.port(all)
            XCTAssertEqual(expected.count, actual.count, "number of output blocks")
            var block = 0
            for (seed, ops) in batch {
                for op in ops where op.producesBlock {
                    defer { block += 1 }
                    guard block < expected.count, block < actual.count else { continue }
                    let same = expected[block] == actual[block]
                    if case .diff(let initialized, let display) = op {
                        diffs += 1
                        if same { matched += 1 }
                        if !same {
                            failures.append("seed \(seed) diff(initialized: \(initialized), \(display)):\n"
                                + "  mosh: \(String(decoding: expected[block], as: UTF8.self))"
                                + "  port: \(String(decoding: actual[block], as: UTF8.self))")
                        }
                    } else if !same {
                        failures.append("seed \(seed) \(op): " + MoshRef.firstDifference(expected[block], actual[block]))
                    }
                }
            }
            batch = []
        }
        for seed in seeds {
            batch.append((seed, makeCase(seed: seed, variants: variants)))
            if batch.count == 50 { try flush() }
        }
        try flush()
        return (diffs, matched, failures)
    }

    /// The server's configuration: `Display( false )`.
    func testNewFrameBytesEqualMosh() throws {
        let n = UInt64(caseCount(300))
        let r = try run(seeds: 1..<(n + 1), variants: false)
        print("DisplayDiffCrossCheck: new_frame output identical to mosh for \(r.matched) of \(r.diffs) pairs")
        for f in r.failures.prefix(5) { XCTFail(f) }
        XCTAssertEqual(r.matched, r.diffs)
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures.count) differences")
        XCTAssertGreaterThanOrEqual(r.diffs, 50)
    }

    /// The hand-worked examples of DisplayDiffTests are what mosh writes.
    func testExamplesAreWhatMoshWrites() throws {
        var ops: [RefOp] = []
        for e in DisplayDiffExample.all {
            ops += [.new(e.width, e.height), .text(e.base), .save, .text(e.change), .diff(initialized: e.initialized)]
        }
        let blocks = try MoshRef.reference(ops)
        XCTAssertEqual(blocks.count, DisplayDiffExample.all.count)
        for (e, block) in zip(DisplayDiffExample.all, blocks) {
            XCTAssertEqual(String(decoding: block, as: UTF8.self), "diff [\(MoshRef.hexString(Array(e.expected.utf8)))]\n", e.name)
        }
    }

    /// The comparison must notice a display that behaves differently: here the port runs
    /// without ECH while mosh has it.
    func testCrossCheckDetectsADifferentDisplay() throws {
        var differing = 0
        var total = 0
        for seed in UInt64(1)..<21 {
            let ops = makeCase(seed: seed, variants: false)
            let portOps: [RefOp] = ops.map {
                if case .diff(let initialized, _) = $0 {
                    return .diff(initialized: initialized, display: DisplayDiff(hasECH: false))
                }
                return $0
            }
            let expected = try MoshRef.reference(ops)
            let actual = MoshRef.port(portOps)
            XCTAssertEqual(expected.count, actual.count)
            for (e, a) in zip(expected, actual) {
                total += 1
                if e != a { differing += 1 }
            }
        }
        XCTAssertGreaterThan(differing, 20, "of \(total) blocks")
    }

    /// Other capability flags (a client painting a terminal without ECH, BCE or titles).
    func testNewFrameBytesEqualMoshWithOtherCapabilities() throws {
        let n = UInt64(caseCount(60))
        let r = try run(seeds: 100_000..<(100_000 + n), variants: true)
        print("DisplayDiffCrossCheck: with capability variants, identical for \(r.matched) of \(r.diffs) pairs")
        for f in r.failures.prefix(5) { XCTFail(f) }
        XCTAssertEqual(r.matched, r.diffs)
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures.count) differences")
    }
}
#endif
