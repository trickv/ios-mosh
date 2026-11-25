// The predict mode of mosh-oracle, checked against the worked example of the prediction
// spec (docs/notes/m10/mosh-prediction.md 5.4): the epochs, guesses and shown frame of
// each step, read from the oracle's raw JSON. This proves the oracle drives mosh's engine
// the way stmclient does before the Swift port is compared with it (DESIGN.md 8, step 1).

#if os(Linux)
import Foundation
import XCTest

final class PredictOracleTests: XCTestCase {
    private struct Dump {
        let engine: [String: Any]
        let shown: [String: Any]?

        var predictionEpoch: String { engine["prediction_epoch"] as? String ?? "?" }
        var confirmedEpoch: String { engine["confirmed_epoch"] as? String ?? "?" }
        /// [exp, row, col, active, tentative, prediction_time]
        var cursors: [[Any]] { engine["cursors"] as? [[Any]] ?? [] }
        /// Active cells as (row, col, tentative epoch, expiration frame, contents).
        var activeCells: [(row: Int, col: Int, epoch: String, exp: String, text: String)] {
            var out: [(Int, Int, String, String, String)] = []
            for row in engine["overlays"] as? [[String: Any]] ?? [] {
                let r = row["row"] as? Int ?? -1
                for cell in row["cells"] as? [[Any]] ?? [] where cell[1] as? Bool == true {
                    let replacement = cell[6] as? [String: Any] ?? [:]
                    let bytes = Data(base64Encoded: replacement["c"] as? String ?? "") ?? Data()
                    out.append((r, cell[0] as? Int ?? -1, cell[3] as? String ?? "?", cell[2] as? String ?? "?",
                                String(decoding: bytes, as: UTF8.self)))
                }
            }
            return out
        }

        /// The text of one row of the shown frame (runs of FORMAT.md 5.4, empty cells as spaces).
        func shownRow(_ y: Int) -> String? {
            guard let rows = shown?["rows"] as? [[[String: Any]]], y < rows.count else { return nil }
            var s = ""
            for run in rows[y] {
                if let t = run["t"] as? String { s += t }
                if let e = run["e"] as? Int { s += String(repeating: " ", count: e) }
                if let c = run["c"] as? [String] { s += c.map { $0.isEmpty ? " " : $0 }.joined() }
            }
            return s
        }
    }

    private func dumps(_ commands: [String]) throws -> [Dump] {
        let lines = try PredictOracle.run(commands)
        var out: [Dump] = []
        for (command, line) in zip(commands, lines) {
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
            if command == "dump" {
                XCTAssertEqual(obj["dump"] as? Int, out.count + 1)
                out.append(Dump(engine: try XCTUnwrap(obj["engine"] as? [String: Any]), shown: obj["shown"] as? [String: Any]))
            } else {
                XCTAssertEqual(obj["ok"] as? String, String(command.split(separator: " ")[0]), line)
            }
        }
        return out
    }

    private func hex(_ s: String) -> String { PredictOracle.hex(Array(s.utf8)) }

    /// Spec 5.4: adaptive, slow link (send interval 250), insert mode, 80x24, a prompt at
    /// row 5 col 2, `local_frame_sent` 10.
    func testWorkedExample() throws {
        let d = try dumps([
            "new 80 24", "time 1000", "recv 0 250",
            "host " + hex("\u{1b}[6;1H$ "),
            "frame", "dump",                                   // 1: first cull
            "read 10 " + hex("l"), "dump",                     // 2: l
            "read 10 " + hex("s"), "dump",                     // 3: s
            "frame", "dump",                                   // 3b: a frame before the echo
            "time 1300", "host " + hex("ls"), "echoack 11", "recv 11 250",
            "frame", "dump",                                   // 4: echo with echo ack 11
            "read 11 " + hex("-"), "frame", "dump",            // 4b: - shown at once
            "read 11 " + hex("\r"), "dump",                    // 5: Return
            "read 12 " + hex("x"), "dump",                     // 5b: x in epoch 3
            "time 1600", "host " + hex("-\r\ny"), "echoack 13", "recv 13 250",
            "frame", "dump",                                   // 6: the server shows y
        ])
        XCTAssertEqual(d.count, 9)
        guard d.count == 9 else { return }

        // 1. size 0x0 differs from 80x24: reset, prediction_epoch 2 (toc:446-451, 410-414).
        XCTAssertEqual(d[0].predictionEpoch, "2")
        XCTAssertEqual(d[0].confirmedEpoch, "0")
        XCTAssertEqual(d[0].shownRow(5)?.hasPrefix("$  "), true)

        // 2. l: a cursor pushed at (5,2), exp 11, epoch 2, moved to col 3; cell (5,2) = l.
        XCTAssertEqual(d[1].predictionEpoch, "2")
        XCTAssertEqual(d[1].cursors.count, 1)
        if let c = d[1].cursors.first {
            XCTAssertEqual(c[0] as? String, "11")
            XCTAssertEqual(c[1] as? Int, 5)
            XCTAssertEqual(c[2] as? Int, 3)
            XCTAssertEqual(c[4] as? String, "2")
        }
        let l = d[1].activeCells.first { $0.row == 5 && $0.col == 2 }
        XCTAssertEqual(l?.text, "l")
        XCTAssertEqual(l?.epoch, "2")
        XCTAssertEqual(l?.exp, "11")
        // cells (5,3..79) shifted right, all epoch 2, exp 11
        XCTAssertEqual(d[1].activeCells.filter { $0.row == 5 }.count, 78)
        XCTAssertTrue(d[1].activeCells.allSatisfy { $0.epoch == "2" && $0.exp == "11" })

        // 3. s: same epoch, (5,3) = s, cursor col 4; still not drawn.
        XCTAssertEqual(d[2].predictionEpoch, "2")
        XCTAssertEqual(d[2].activeCells.first { $0.row == 5 && $0.col == 3 }?.text, "s")
        XCTAssertEqual(d[2].cursors.last?[2] as? Int, 4)
        XCTAssertEqual(d[3].confirmedEpoch, "0")
        XCTAssertEqual(d[3].shownRow(5)?.hasPrefix("$  "), true, "tentative guesses are not drawn")

        // 4. echo ack 11 and ls on the screen: l and s Correct, confirmed_epoch 2.
        XCTAssertEqual(d[4].confirmedEpoch, "2")
        XCTAssertEqual(d[4].predictionEpoch, "2")
        XCTAssertTrue(d[4].activeCells.isEmpty)
        XCTAssertEqual(d[4].shownRow(5)?.hasPrefix("$ ls "), true)
        // From now on epoch-2 guesses are drawn at once: - shows immediately.
        XCTAssertEqual(d[5].shownRow(5)?.hasPrefix("$ ls- "), true)

        // 5. Return: become_tentative, epoch 3; a new cursor (6,0) in epoch 3.
        XCTAssertEqual(d[6].predictionEpoch, "3")
        XCTAssertEqual(d[6].confirmedEpoch, "2")
        if let c = d[6].cursors.last {
            XCTAssertEqual(c[1] as? Int, 6)
            XCTAssertEqual(c[2] as? Int, 0)
            XCTAssertEqual(c[4] as? String, "3")
        } else {
            XCTFail("no cursor after Return")
        }
        // x is a guess of epoch 3, not drawn (confirmed 2 < 3).
        let x = d[7].activeCells.first { $0.row == 6 && $0.col == 0 }
        XCTAssertEqual(x?.text, "x")
        XCTAssertEqual(x?.epoch, "3")

        // 6. The server shows y at (6,0) once the echo ack reaches x's state: x is
        // IncorrectOrExpired and tentative, kill_epoch(3): epoch 4, the epoch-3 guesses go.
        XCTAssertEqual(d[8].predictionEpoch, "4")
        XCTAssertEqual(d[8].confirmedEpoch, "2")
        XCTAssertFalse(d[8].activeCells.contains { $0.epoch == "3" })
        XCTAssertFalse(d[8].cursors.contains { ($0[4] as? String) == "3" && ($0[1] as? Int) == 6 && ($0[2] as? Int) == 0 })
        XCTAssertEqual(d[8].shownRow(6)?.hasPrefix("y "), true)
        XCTAssertEqual(d[8].shownRow(5)?.hasPrefix("$ ls- "), true)
    }

    /// A bad command is an error line and exit 65, so a broken script cannot pass quietly.
    func testBadCommandFails() throws {
        XCTAssertEqual(try PredictOracle.run(["new 1 1"]), ["{\"ok\":\"new\"}"])   // skips without the mosh tree
        XCTAssertThrowsError(try PredictOracle.run(["new 4 2", "nonsense"]))
        XCTAssertThrowsError(try PredictOracle.run(["dump"]))
    }
}
#endif
