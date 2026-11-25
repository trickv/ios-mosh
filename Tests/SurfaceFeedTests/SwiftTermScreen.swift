// SwiftTerm's terminal without a view, set up the way the app's surface sets up its
// `TerminalView`: scrollback off (`changeScrollback(nil)`), everything else at SwiftTerm's
// defaults. Only SwiftTerm's public API is used, because that is all the app has.
//
// (SwiftTerm's `HeadlessTerminal` class is not used: it does not exist on iOS and it
// always owns a `LocalProcess`. Its terminal is this same `Terminal` class with a
// delegate, which is also what SwiftTerm's own tests build.)

import Foundation
import SwiftTerm

/// A SwiftTerm `Terminal` plus a record of everything it told its delegate.
final class SwiftTermScreen: TerminalDelegate {
    private(set) var terminal: Terminal!

    /// Bytes the terminal wanted to send to the host (replies, mouse reports, paste).
    var sent: [UInt8] = []
    /// Number of BEL the terminal reported.
    var bells = 0
    /// Titles and icon titles the terminal reported.
    var titles: [String] = []
    /// OSC 52 writes the terminal reported.
    var clipboardWrites = 0
    /// Number of `sizeChanged` callbacks.
    var sizeChanges = 0

    /// The options the app's surface must create its `TerminalView` with.
    ///
    /// `regionalIndicatorWidth: .narrow`: glibc, and so the server, counts one column for
    /// a regional indicator symbol. SwiftTerm's default is two.
    static func appOptions(cols: Int, rows: Int) -> TerminalOptions {
        return TerminalOptions(cols: cols, rows: rows, regionalIndicatorWidth: .narrow)
    }

    /// `keepScrollback` leaves SwiftTerm's own 500 lines on, which the app never does;
    /// it exists to show what `changeScrollback(nil)` prevents.
    init(cols: Int, rows: Int, options: TerminalOptions? = nil, keepScrollback: Bool = false) {
        var o = options ?? SwiftTermScreen.appOptions(cols: cols, rows: rows)
        o.cols = cols
        o.rows = rows
        terminal = Terminal(delegate: self, options: o)
        // What the surface does when it creates the view. `TerminalView.changeScrollback`
        // forwards to this method.
        if !keepScrollback {
            terminal.changeScrollback(nil)
        }
    }

    var cols: Int { return terminal.cols }
    var rows: Int { return terminal.rows }

    func feed(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
    }

    func feed(_ text: String) {
        terminal.feed(byteArray: Array(text.utf8))
    }

    /// What the view does when its bounds change: resize the terminal's buffers.
    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }

    var cursor: (x: Int, y: Int) {
        return terminal.getCursorLocation()
    }

    /// The scalar values SwiftTerm holds in a cell. An untouched or erased cell is
    /// `[0]`; the right half of a wide character is `[0]` with width 0.
    func scalars(col: Int, row: Int) -> [UInt32] {
        guard let cd = terminal.getCharData(col: col, row: row) else { return [] }
        return cd.getText().unicodeScalars.map { $0.value }
    }

    func width(col: Int, row: Int) -> Int {
        guard let cd = terminal.getCharData(col: col, row: row) else { return -1 }
        return Int(cd.width)
    }

    func attribute(col: Int, row: Int) -> Attribute? {
        return terminal.getCharData(col: col, row: row)?.attribute
    }

    /// One row as text: an empty cell is a space, the right half of a wide character is
    /// left out, trailing spaces are trimmed.
    func rowText(_ row: Int) -> String {
        var s = String.UnicodeScalarView()
        for col in 0..<cols {
            guard let cd = terminal.getCharData(col: col, row: row) else { continue }
            if cd.width == 0 { continue }
            for u in cd.getText().unicodeScalars {
                s.append(u.value == 0 ? " " : u)
            }
        }
        var text = String(s)
        while text.unicodeScalars.last == " " { text.unicodeScalars.removeLast() }
        return text
    }

    var text: [String] {
        return (0..<rows).map { rowText($0) }
    }

    /// Ask the terminal for a DEC private mode with DECRQM (`CSI ? n $ p`). The answer is
    /// `CSI ? n ; s $ y` with s = 1 set, 2 reset, 0 not recognised, 3 and 4 permanently
    /// set and reset. Returns s, or nil if there was no answer.
    func privateMode(_ n: Int) -> Int? {
        let before = sent.count
        feed("\u{1B}[?\(n)$p")
        let reply = Array(sent[before...])
        sent.removeSubrange(before...)
        let prefix = Array("\u{1B}[?\(n);".utf8)
        guard reply.count == prefix.count + 3, Array(reply[..<prefix.count]) == prefix,
              reply[reply.count - 2] == 0x24, reply[reply.count - 1] == 0x79 else { return nil }
        return Int(reply[prefix.count]) - 0x30
    }

    /// Cursor visibility as the terminal reports it (DECTCEM, mode 25).
    var cursorVisible: Bool? {
        guard let s = privateMode(25) else { return nil }
        return s == 1 || s == 3
    }

    // MARK: TerminalDelegate

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    func bell(source: Terminal) {
        bells += 1
    }

    func setTerminalTitle(source: Terminal, title: String) {
        titles.append(title)
    }

    func setTerminalIconTitle(source: Terminal, title: String) {
        titles.append(title)
    }

    func clipboardCopy(source: Terminal, content: TerminalData) {
        clipboardWrites += 1
    }

    func sizeChanged(source: Terminal) {
        sizeChanges += 1
    }
}
