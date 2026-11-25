// The differential fuzz of the prediction engine (docs/notes/m10/DESIGN.md 7.2): seeded
// command scripts run through mosh's own engine (mosh-oracle predict) and the port; every
// dump (engine state after each command, the shown frame after each frame) must be equal.
// Case count: MOSH_FUZZ_CASES (default 100 cases of 300 commands, see DESIGN.md progress, step 4). Linux only.

#if os(Linux)
import Foundation
import XCTest
@testable import MoshTerminal

final class PredictionCrossCheckTests: XCTestCase {
    private var caseCount: Int {
        if let s = ProcessInfo.processInfo.environment["MOSH_FUZZ_CASES"], let n = Int(s), n > 0 { return n }
        return 100
    }

    func testFuzzAgainstMosh() throws {
        var coverage = PredictionCoverage()
        let start = Date()
        for seed in 0..<UInt64(caseCount) {
            var fuzz = PredictionFuzz(seed: seed)
            let commands = fuzz.makeCase(steps: 300)
            if let d = try PredictComparison.firstDifference(commands) {
                let index = Int(d.split(separator: " ").dropFirst().first.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) } ?? commands.count)
                let upTo = commands.prefix(index + 1).map { $0.line }.joined(separator: "\n")
                XCTFail("seed \(seed): \(d)\ncommands:\n\(upTo)")
                return
            }
            // coverage, from the port's dumps (equal to mosh's)
            var harness = PredictHarness()
            var previous: PredictionDump?
            var last: PredictCommand?
            for c in commands {
                let d = harness.run(c)
                if let d = d {
                    if let p = previous, let l = last {
                        coverage.observe(l, before: p, after: d.engine, shown: harness.shown, server: harness.server.framebuffer,
                                         width: d.engine.lastWidth, height: d.engine.lastHeight)
                    }
                    previous = d.engine
                } else {
                    last = c
                }
            }
        }
        print("PredictionCrossCheckTests: \(caseCount) cases in \(Int(Date().timeIntervalSince(start))) s (oracle \(Int(PredictComparison.oracleSeconds)) s, compare \(Int(PredictComparison.compareSeconds)) s); coverage: \(coverage)")
        XCTAssertEqual(coverage.missing, [], "branches the generator no longer reaches")
    }
}
#endif
