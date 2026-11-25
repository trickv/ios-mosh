import XCTest
@testable import MoshTerminal

let ESC = "\u{1B}"
let CSI = "\u{1B}["

/// A terminal of the given size after `input` (UTF-8).
func terminal(_ width: Int, _ height: Int, _ input: String = "") -> TerminalState {
    var t = TerminalState(width: width, height: height)
    t.act(Array(input.utf8))
    return t
}

extension TerminalState {
    /// Feed a string (UTF-8) and return the reply as a string.
    @discardableResult
    mutating func feed(_ s: String) -> String {
        return String(decoding: act(Array(s.utf8)), as: UTF8.self)
    }

    var fb: Framebuffer { return framebuffer }
    var cursor: [Int] { return [framebuffer.ds.cursorRow, framebuffer.ds.cursorCol] }

    /// The cell at a position.
    func cell(_ row: Int, _ col: Int) -> Cell {
        return framebuffer.rows[row].cells[col]
    }

    /// Contents of one cell as UTF-8 bytes.
    func contents(_ row: Int, _ col: Int) -> [UInt8] {
        return cell(row, col).contents
    }

    /// The visible text of each line, as mosh's display would print it.
    var screenBytes: [[UInt8]] {
        return (0..<framebuffer.ds.height).map { framebuffer.rowText($0) }
    }
}

/// Assert the visible text. An expected line may leave out trailing blanks; the
/// comparison is on UTF-8 bytes.
func XCTAssertScreen(_ t: TerminalState, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
    let actual = t.screenBytes
    XCTAssertEqual(actual.count, expected.count, "number of lines", file: file, line: line)
    for (y, want) in expected.enumerated() where y < actual.count {
        var bytes = Array(want.utf8)
        let have = actual[y]
        if bytes.count < have.count { bytes += Array(repeating: 0x20, count: have.count - bytes.count) }
        XCTAssertEqual(have, bytes,
                       "line \(y): \"\(String(decoding: have, as: UTF8.self))\" is not \"\(want)\"",
                       file: file, line: line)
    }
}

func utf8(_ s: String) -> [UInt8] { return Array(s.utf8) }
