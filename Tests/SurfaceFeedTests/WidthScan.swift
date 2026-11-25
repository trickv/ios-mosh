// What SwiftTerm does with every Unicode scalar value, measured through its public API,
// next to the glibc width the mosh model uses.

import Foundation
import MoshTerminal
import SwiftTerm

enum WidthScan {
    /// What SwiftTerm does with one scalar printed at column 0 of an empty row.
    /// 0: nothing is stored and the cursor does not move (a combining character with
    /// nothing to join, or a character it drops); 1 and 2: columns the cursor advanced.
    ///
    /// Measured for every scalar the mosh model can put on the screen (glibc width 0, 1
    /// or 2; 287,279 values); -1 here for the others. Each one: cursor home, erase the
    /// line, the scalar, a cursor position report request; 1024 scalars per feed.
    ///
    /// The terminal has the app's options (`SwiftTermScreen.appOptions`).
    static let swiftTermWidths: [Int8] = measure(options: nil, only: nil)

    static func measure(options: TerminalOptions?, only: ClosedRange<UInt32>?) -> [Int8] {
        let screen = SwiftTermScreen(cols: 8, rows: 2, options: options)
        var widths = [Int8](repeating: -1, count: 0x110000)
        var batch: [UInt32] = []
        var bytes: [UInt8] = []

        func flush() {
            screen.sent.removeAll(keepingCapacity: true)
            screen.feed(bytes)
            // Replies are ESC [ 1 ; <col> R.
            var i = 0
            var n = 0
            let sent = screen.sent
            while i + 5 < sent.count + 0 && n < batch.count {
                precondition(sent[i] == 0x1B && sent[i + 1] == 0x5B && sent[i + 2] == 0x31 && sent[i + 3] == 0x3B,
                             "unexpected cursor report")
                let col = Int(sent[i + 4]) - 0x30
                precondition(sent[i + 5] == 0x52, "unexpected cursor report")
                widths[Int(batch[n])] = Int8(col - 1)
                n += 1
                i += 6
            }
            precondition(n == batch.count, "\(batch.count) scalars, \(n) cursor reports")
            batch.removeAll(keepingCapacity: true)
            bytes.removeAll(keepingCapacity: true)
        }

        for v in only ?? UInt32(0x20)...0x10FFFF {
            if moshWidth(v) < 0 { continue }
            bytes.append(contentsOf: Array("\u{1B}[H\u{1B}[2K".utf8))
            Cell.appendUTF8(v, to: &bytes)
            bytes.append(contentsOf: Array("\u{1B}[6n".utf8))
            batch.append(v)
            if batch.count == 1024 { flush() }
        }
        flush()
        return widths
    }

    /// What the mosh model does with a scalar (`Emulator::print`): 1 or 2 columns, 0 for
    /// a combining character, -1 for one it drops.
    static func moshWidth(_ v: UInt32) -> Int {
        if (v >= 0x20 && v <= 0x7E) || (v >= 0xA0 && v <= 0xFF) { return 1 }
        return WCWidth.wcwidth(v)
    }

    static func hex(_ v: UInt32) -> String {
        return "U+" + String(v, radix: 16, uppercase: true).leftPad(4)
    }
}

extension String {
    func leftPad(_ n: Int) -> String {
        return count >= n ? self : String(repeating: "0", count: n - count) + self
    }
}
