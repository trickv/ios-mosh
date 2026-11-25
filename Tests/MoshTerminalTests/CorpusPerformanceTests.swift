// Step 4c: how long the terminal model takes on the whole golden corpus, and what a copy
// of a state costs. The bounds asserted are generous (a debug build on a shared machine);
// the measured numbers are printed.

import Foundation
import XCTest
import MoshTestSupport
@testable import MoshTerminal

final class CorpusPerformanceTests: XCTestCase {
    static func milliseconds(_ s: Double) -> String {
        return String(format: "%.1f ms", s * 1000)
    }

    static func perItem(_ s: Double, _ n: Int) -> String {
        let ns = s / Double(n) * 1e9
        return ns >= 10_000 ? String(format: "%.1f us", ns / 1000) : String(format: "%.0f ns", ns)
    }

    /// The client's work for the whole corpus: copy the base state, apply the diff, keep
    /// the result (every state is kept, as the comparison run does). Then the server's:
    /// one terminal reads everything the programs wrote. No comparison in either.
    func testApplyingTheWholeCorpusTakesAtMostAFewSeconds() throws {
        let cases = try CorpusTests.corpus.get()

        var instructions = 0
        var diffBytes = 0
        var kept = 0
        let clientTime = CorpusTests.seconds {
            for c in cases {
                var states: [UInt64: TerminalState] = [0: TerminalState(width: c.width, height: c.height)]
                for instruction in c.instructions {
                    var s = states[instruction.oldNum]!
                    if !instruction.diff.isEmpty {
                        for op in instruction.ops {
                            switch op {
                            case .hostBytes(let bytes):
                                diffBytes += bytes.count
                                _ = s.act(bytes)
                            case .resize(let w, let h): s.resize(width: w, height: h)
                            case .echoAck(let n): s.applyEchoAck(n)
                            }
                        }
                    }
                    states[instruction.newNum] = s
                    instructions += 1
                }
                kept += states.count
            }
        }

        var steps = 0
        var sessionBytes = 0
        let serverTime = CorpusTests.seconds {
            for c in cases {
                var server = TerminalState(width: c.width, height: c.height)
                var clock: UInt64 = 1000
                for step in c.session {
                    if case .bytes(let b) = step { sessionBytes += b.count }
                    _ = CorpusRun.step(&server, step, clock: &clock)
                    steps += 1
                }
            }
        }

        // The sender's work: every recorded diff computed again from the server's states.
        var frames = 0
        var frameTime = 0.0
        for c in cases {
            var tally = CorpusTally()
            _ = try CorpusRun.server(c, compare: false, tally: &tally) { number, server, sent in
                let base = sent[Int(c.instructions[number - 1].oldNum)]
                frameTime += CorpusTests.seconds { _ = server.diff(from: base) }
                frames += 1
            }
        }

        print("corpus performance (this build): client applies \(instructions) instructions (\(diffBytes) bytes of diffs, "
            + "\(kept) states kept) in \(CorpusPerformanceTests.milliseconds(clientTime)), "
            + "\(CorpusPerformanceTests.perItem(clientTime, instructions)) per instruction, "
            + "\(CorpusPerformanceTests.perItem(clientTime, max(diffBytes, 1))) per byte; "
            + "server reads \(steps) session lines (\(sessionBytes) bytes) in \(CorpusPerformanceTests.milliseconds(serverTime)), "
            + "\(CorpusPerformanceTests.perItem(serverTime, max(sessionBytes, 1))) per byte; "
            + "\(frames) diff(from:) in \(CorpusPerformanceTests.milliseconds(frameTime)), "
            + "\(CorpusPerformanceTests.perItem(frameTime, frames)) each")
        XCTAssertLessThan(clientTime, 5, "applying the whole corpus on the client side")
        XCTAssertLessThan(serverTime, 5, "reading the whole corpus on the server side")
        XCTAssertLessThan(frameTime, 5, "computing every diff of the corpus")
    }

    /// A state is a value; the receiver keeps one per state number. A copy must not copy
    /// the screen, and the first write to a copy must copy one row, not all of them.
    func testCostOfCopyingAState() throws {
        let cases = try CorpusTests.corpus.get()
        // The largest screen of the corpus with every cell in use: text in a new colour
        // every five cells, an accented letter (two bytes) every seventh cell.
        guard let c = cases.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }
        var state = TerminalState(width: c.width, height: c.height)
        var paint: [UInt8] = []
        for y in 0..<c.height {
            paint += Array("\u{1B}[\(y + 1);1H".utf8)
            for x in 0..<c.width {
                if x % 5 == 0 { paint += Array("\u{1B}[38;5;\((x + y) % 256);4\(y % 8)m".utf8) }
                paint += x % 7 == 3 ? [0xC3, 0xA9] : [UInt8(0x41 + (x + y) % 26)]
            }
        }
        _ = state.act(paint + Array("\u{1B}[\(c.height / 2);\(c.width / 2)H".utf8))
        let fullest = state.framebuffer.rows.reduce(0) { $0 + $1.cells.filter { !$0.isEmpty }.count }
        XCTAssertEqual(fullest, c.width * c.height)
        let width = state.framebuffer.ds.width, height = state.framebuffer.ds.height

        // 1. A plain copy.
        let copies = 100_000
        var held: [TerminalState] = []
        held.reserveCapacity(copies)
        let copyTime = CorpusTests.seconds {
            for _ in 0..<copies { held.append(state) }
        }
        XCTAssertTrue(held[copies - 1].framebuffer.rows[0] === state.framebuffer.rows[0], "a copy shares the rows")
        held.removeAll()

        // 2. A copy and one printed character, which is the first write to the copy:
        //    the array of row references is duplicated and one row is copied.
        let writes = 20_000
        let x: [UInt8] = [0x78]
        var distinctRows = 0
        let copyAndWriteTime = CorpusTests.seconds {
            for _ in 0..<writes {
                var copy = state
                _ = copy.act(x)
                if copy.framebuffer.rows[copy.framebuffer.ds.cursorRow] !== state.framebuffer.rows[copy.framebuffer.ds.cursorRow] {
                    distinctRows += 1
                }
            }
        }
        XCTAssertEqual(distinctRows, writes, "the written row is the copy's own")
        var copy = state
        _ = copy.act(x)
        let shared = zip(copy.framebuffer.rows, state.framebuffer.rows).filter { $0 === $1 }.count
        XCTAssertEqual(shared, height - 1, "all other rows are still shared")

        // 3. For comparison, the same character on a state nobody else holds. (The cursor
        //    is sent home each time so that the line never wraps or scrolls.)
        var alone = state
        _ = alone.act(x)
        let home: [UInt8] = [0x0D, 0x78]
        let writeTime = CorpusTests.seconds {
            for _ in 0..<writes { _ = alone.act(home) }
        }

        // 4. The serialized form.
        let blob = state.serialized()
        let rounds = 50
        let encodeTime = CorpusTests.seconds {
            for _ in 0..<rounds { _ = state.serialized() }
        }
        var decoded = state
        let decodeTime = try CorpusTests.seconds {
            for _ in 0..<rounds { decoded = try TerminalState(serialized: blob) }
        }
        XCTAssertEqual(decoded, state)

        let rowBytes = width * MemoryLayout<Cell>.stride
        print("state copy (\(width)x\(height), all \(fullest) cells in use, this build): "
            + "copy \(CorpusPerformanceTests.perItem(copyTime, copies)) "
            + "(\(MemoryLayout<TerminalState>.size) bytes inline, no screen memory); "
            + "copy + first write \(CorpusPerformanceTests.perItem(copyAndWriteTime, writes)) "
            + "(\(height) row references and one row of \(width) cells x \(MemoryLayout<Cell>.stride) bytes = \(rowBytes) bytes "
            + "plus the cells' contents); "
            + "the same write (CR + one character) on an unshared state \(CorpusPerformanceTests.perItem(writeTime, writes)); "
            + "serialized \(blob.count) bytes, encode \(CorpusPerformanceTests.perItem(encodeTime, rounds)), "
            + "decode \(CorpusPerformanceTests.perItem(decodeTime, rounds))")
        XCTAssertLessThan(copyTime / Double(copies), 20e-6, "a copy must not depend on the size of the screen")
        XCTAssertLessThan(copyAndWriteTime / Double(writes), 500e-6)
    }
}
