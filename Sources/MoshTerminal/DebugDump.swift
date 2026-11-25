// A stable text form of the whole state, for tests and for locating differences against
// mosh itself. Tests/MoshTerminalTests/Support/moshref.cc prints the same format from
// mosh's own `Terminal::Complete`; keep the two in step.
//
// The output is ASCII only. Format, one item per line:
//
//   complete echo_ack=N input_history=[FRAME@TIME,...]
//   parser state=NAME utf8_buf=[HEX]
//   dispatch params="..." parsed=B parsed_params=[N,...] dispatch_chars=[HEX] terminal_to_host=[HEX]
//   osc_string len=N "TEXT"
//   user state=NAME
//   fb width=W height=H bell_count=N title_initialized=B
//   icon_name len=N "TEXT"
//   window_title len=N "TEXT"
//   clipboard len=N "TEXT"
//   cursor row=R col=C combining_row=R combining_col=C
//   scrolling_region top=T bottom=B
//   tabs default=B stops=[COL,...]
//   pen fg=N bg=N attrs=HH
//   saved cursor_row=R cursor_col=C auto_wrap=B origin=B fg=N bg=N attrs=HH
//   modes next_print_will_wrap=B origin=B auto_wrap=B insert=B cursor_visible=B
//         reverse_video=B bracketed_paste=B mouse_reporting=N mouse_focus_event=B
//         mouse_alternate_scroll=B mouse_encoding=N application_cursor_keys=B   (one line)
//   row Y obj=K gen=K wrap=B text="TEXT"
//     CELLS
//
// B is 0 or 1. HEX is lowercase hex bytes without separators. Colours are the raw values
// of `Renditions`. TEXT of a title is its code points: printable ASCII as is, except
// `"` and `\`; everything else as \u{HEX}. TEXT of a row is what mosh's display would
// print (skipping the cell after a wide one), bytes outside printable ASCII as \xHH.
//
// `obj=K`: K is the first line of this screen that is the same row object (mosh: the
// same `shared_ptr` target). `gen=K`: K is the first line of this screen whose row has
// the same generation number. Absolute generation numbers are not printed: they depend
// on the history of the whole process.
//
// CELLS is the row's cells from the left, separated by spaces, equal neighbours merged
// as `COUNT*CELL`. A cell is `CONTENTS:FG:BG:ATTRS:FLAGS` with CONTENTS the UTF-8 bytes
// in hex (`-` when empty), ATTRS two hex digits, FLAGS the letters `w` (wide),
// `f` (fallback), `r` (wrap) or `-`.

extension TerminalState {
    /// Every field of the state in a stable text form (see the top of DebugDump.swift).
    public func debugDump() -> String {
        var out = ""
        out += "complete echo_ack=\(echoAck) input_history=["
        out += inputHistory.map { "\($0.frameNum)@\($0.timestamp)" }.joined(separator: ",")
        out += "]\n"
        out += "parser state=\(parser.parser.state.name) utf8_buf=[\(DebugDump.hex(parser.pendingBytes))]\n"
        let d = terminal.dispatch
        out += "dispatch params=\"\(String(decoding: d.params, as: UTF8.self))\" parsed=\(DebugDump.bit(d.parsed))"
        out += " parsed_params=[\(d.parsedParams.map { String($0) }.joined(separator: ","))]"
        out += " dispatch_chars=[\(DebugDump.hex(d.dispatchChars))]"
        out += " terminal_to_host=[\(DebugDump.hex(d.terminalToHost))]\n"
        out += "osc_string \(DebugDump.title(d.oscString))\n"
        out += "user state=\(terminal.user.state.name)\n"
        out += terminal.fb.debugDump()
        return out
    }
}

extension Framebuffer {
    /// The framebuffer part of `TerminalState.debugDump()`: the lines from `fb` on.
    public func debugDump() -> String {
        var out = ""
        out += "fb width=\(ds.width) height=\(ds.height) bell_count=\(bellCount)"
        out += " title_initialized=\(DebugDump.bit(titleInitialized))\n"
        out += "icon_name \(DebugDump.title(iconName))\n"
        out += "window_title \(DebugDump.title(windowTitle))\n"
        out += "clipboard \(DebugDump.title(clipboard))\n"
        out += "cursor row=\(ds.cursorRow) col=\(ds.cursorCol)"
        out += " combining_row=\(ds.combiningCharRow) combining_col=\(ds.combiningCharCol)\n"
        out += "scrolling_region top=\(ds.scrollingRegionTopRow) bottom=\(ds.scrollingRegionBottomRow)\n"
        var stops: [String] = []
        for (i, t) in ds.tabs.enumerated() where t { stops.append(String(i)) }
        out += "tabs default=\(DebugDump.bit(ds.defaultTabs)) stops=[\(stops.joined(separator: ","))]\n"
        out += "pen \(DebugDump.renditions(ds.renditions))\n"
        out += "saved cursor_row=\(ds.save.cursorRow) cursor_col=\(ds.save.cursorCol)"
        out += " auto_wrap=\(DebugDump.bit(ds.save.autoWrapMode)) origin=\(DebugDump.bit(ds.save.originMode))"
        out += " \(DebugDump.renditions(ds.save.renditions))\n"
        out += "modes next_print_will_wrap=\(DebugDump.bit(ds.nextPrintWillWrap))"
        out += " origin=\(DebugDump.bit(ds.originMode))"
        out += " auto_wrap=\(DebugDump.bit(ds.autoWrapMode))"
        out += " insert=\(DebugDump.bit(ds.insertMode))"
        out += " cursor_visible=\(DebugDump.bit(ds.cursorVisible))"
        out += " reverse_video=\(DebugDump.bit(ds.reverseVideo))"
        out += " bracketed_paste=\(DebugDump.bit(ds.bracketedPaste))"
        out += " mouse_reporting=\(ds.mouseReportingMode.rawValue)"
        out += " mouse_focus_event=\(DebugDump.bit(ds.mouseFocusEvent))"
        out += " mouse_alternate_scroll=\(DebugDump.bit(ds.mouseAlternateScroll))"
        out += " mouse_encoding=\(ds.mouseEncodingMode.rawValue)"
        out += " application_cursor_keys=\(DebugDump.bit(ds.applicationModeCursorKeys))\n"

        for y in rows.indices {
            let row = rows[y]
            var obj = y
            var gen = y
            for k in 0..<y where rows[k] === row { obj = k; break }
            for k in 0..<y where rows[k].gen == row.gen { gen = k; break }
            out += "row \(y) obj=\(obj) gen=\(gen) wrap=\(DebugDump.bit(row.wrap))"
            out += " text=\"\(DebugDump.rowText(row))\"\n"
            out += "  \(DebugDump.cells(row))\n"
        }
        return out
    }

    /// The visible text of line `y` as mosh's display would write it: one grapheme per
    /// cell, a space for an empty cell, the cell after a wide character skipped. UTF-8.
    public func rowText(_ y: Int) -> [UInt8] {
        return DebugDump.rowBytes(rows[y])
    }
}

enum DebugDump {
    static func bit(_ b: Bool) -> String { return b ? "1" : "0" }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private static let hexDigitsUpper = Array("0123456789ABCDEF".utf8)

    static func hex(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func title(_ t: [UInt32]) -> String {
        var out = "len=\(t.count) \""
        for c in t {
            if c >= 0x20 && c <= 0x7E && c != 0x22 && c != 0x5C {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(c)))
            } else {
                out += "\\u{\(String(c, radix: 16, uppercase: true))}"
            }
        }
        out += "\""
        return out
    }

    static func renditions(_ r: Renditions) -> String {
        return "fg=\(r.foregroundColor) bg=\(r.backgroundColor) attrs=\(hex([r.attributes]))"
    }

    static func rowBytes(_ row: Row) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = 0
        while x < row.cells.count {
            row.cells[x].printGrapheme(into: &bytes)
            x += row.cells[x].width
        }
        return bytes
    }

    static func rowText(_ row: Row) -> String {
        var out: [UInt8] = []
        for b in rowBytes(row) {
            if b >= 0x20 && b <= 0x7E && b != 0x22 && b != 0x5C {
                out.append(b)
            } else {
                out.append(0x5C)
                out.append(UInt8(ascii: "x"))
                out.append(hexDigitsUpper[Int(b >> 4)])
                out.append(hexDigitsUpper[Int(b & 15)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func cell(_ c: Cell) -> String {
        var flags = ""
        if c.wide { flags += "w" }
        if c.fallback { flags += "f" }
        if c.wrap { flags += "r" }
        if flags.isEmpty { flags = "-" }
        let contents = c.contents.isEmpty ? "-" : hex(c.contents)
        return "\(contents):\(c.renditions.foregroundColor):\(c.renditions.backgroundColor)"
            + ":\(hex([c.renditions.attributes])):\(flags)"
    }

    static func cells(_ row: Row) -> String {
        var parts: [String] = []
        var i = 0
        let cells = row.cells
        while i < cells.count {
            var j = i + 1
            while j < cells.count && cells[j] == cells[i] { j += 1 }
            let text = cell(cells[i])
            parts.append(j - i > 1 ? "\(j - i)*\(text)" : text)
            i = j
        }
        return parts.joined(separator: " ")
    }
}
