// Walks a corpus case as the app's surface would: the terminal model applies the
// recorded diffs, `SurfaceFeed` turns the states into bytes for SwiftTerm, and after every
// feed SwiftTerm's screen is compared with the mosh framebuffer.

import Foundation
import MoshTerminal
import MoshTestSupport
import SwiftTerm

/// What was compared, and what was left out and why.
struct SurfaceTally {
    var cases = 0
    var states = 0
    var feeds = 0
    var emptyFeeds = 0
    var fullRepaints = 0
    var feedBytes = 0
    var cells = 0
    var cellFields = 0
    var cursors = 0
    var modeFields = 0
    /// Feeds that switched focus events on and made SwiftTerm send `ESC [ I`.
    var focusReports = 0
    /// Comparisons not made, or made against something other than the framebuffer, by reason.
    var exclusions: [String: Int] = [:]

    mutating func exclude(_ reason: String) {
        exclusions[reason, default: 0] += 1
    }

    var comparisons: Int { return cellFields + cursors * 3 + modeFields }

    var summary: String {
        var s = "\(cases) cases, \(states) states, \(feeds) feeds (\(fullRepaints) full repaints, \(emptyFeeds) empty), "
            + "\(feedBytes) bytes; compared \(cells) cells (\(cellFields) fields), \(cursors) cursors, "
            + "\(modeFields) mode fields = \(comparisons) comparisons; \(focusReports) focus reports; exclusions: "
        if exclusions.isEmpty {
            s += "none"
        } else {
            s += exclusions.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: "; ")
        }
        return s
    }
}

/// Which states are fed.
enum WalkMode {
    /// Every state.
    case every
    /// Only every nth state, and the last one.
    case everyNth(Int)
    /// Every state, with `invalidate()` before randomly chosen feeds (about one in four).
    case invalidating(seed: UInt64)
}

/// SplitMix64, so that a seed means the same on every machine.
struct SeededGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SurfaceExclusion {
    static let wideInLastColumn = "a wide character in the last column: SwiftTerm cannot hold one, the cell is blank"
    static let mouseHighlight = "mouse mode 1001 (highlight tracking) is not implemented by SwiftTerm: reporting is off"
}

extension SurfaceExclusion {
    static let zeroWidthNotStored = "a zero-width format character (Grapheme_Cluster_Break=Control: U+200B, "
        + "U+FEFF, U+E0001) is not stored by SwiftTerm; it is invisible"
    /// The characters of that class the corpus contains.
    static let notStored: Set<UInt32> = [0x200B, 0xFEFF, 0xE0001]
    static let selectorLeftOut = "the feed leaves out U+FE0F in a one-column cell (U+FE0E in a two-column cell): "
        + "SwiftTerm would change the cell's width"
    static let oneColumn = "a framebuffer one column wide is not fed: SwiftTerm's minimum is two columns"
}

enum SurfaceWalk {
    /// The client's states in the order they arrive: `(instruction index, state)`.
    static func states(_ c: GoldenCase) -> [TerminalState] {
        var byNum: [UInt64: TerminalState] = [0: TerminalState(width: c.width, height: c.height)]
        var inOrder: [TerminalState] = []
        for instruction in c.instructions {
            var s = byNum[instruction.oldNum]!
            if !instruction.diff.isEmpty {
                for op in instruction.ops {
                    switch op {
                    case .hostBytes(let bytes): _ = s.act(bytes)
                    case .resize(let w, let h): _ = s.resize(width: w, height: h)
                    case .echoAck(let n): s.applyEchoAck(n)
                    }
                }
            }
            byNum[instruction.newNum] = s
            inOrder.append(s)
        }
        return inOrder
    }

    /// Walk one case. Returns the differences found (at most `limit`), each with the
    /// instruction it was found after.
    static func run(_ c: GoldenCase, mode: WalkMode, tally: inout SurfaceTally, limit: Int = 6) -> [String] {
        let states = SurfaceWalk.states(c)
        tally.cases += 1
        tally.states += states.count

        let screen = SwiftTermScreen(cols: c.width, rows: c.height)
        var feed = SurfaceFeed()
        var generator = SeededGenerator(state: 0)
        if case .invalidating(let seed) = mode {
            // A different sequence for every case.
            generator = SeededGenerator(state: seed ^ c.name.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) })
        }
        var failures: [String] = []

        for (i, state) in states.enumerated() {
            if case .everyNth(let n) = mode, (i + 1) % n != 0, i != states.count - 1 {
                continue
            }
            let fb = state.framebuffer
            if fb.ds.width < 2 {
                tally.exclude(SurfaceExclusion.oneColumn)
                continue
            }
            // The view resizes SwiftTerm's buffer; SwiftTerm calls `sizeChanged`; the
            // surface answers with `invalidate()`.
            // (`TerminalViewDelegate.sizeChanged`; the `Terminal` itself has nothing to
            // report when its owner resizes it.)
            if fb.ds.width != screen.cols || fb.ds.height != screen.rows {
                screen.resize(cols: fb.ds.width, rows: fb.ds.height)
                feed.invalidate()
            }
            if case .invalidating = mode, generator.next() % 4 == 0 {
                feed.invalidate()
            }
            let full = feed.needsFullRepaint(to: fb)
            let focusTurnedOn = fb.ds.mouseFocusEvent && !(feed.lastShown?.ds.mouseFocusEvent ?? false)
            let bytes = feed.feed(to: fb)
            tally.feeds += 1
            tally.feedBytes += bytes.count
            if full { tally.fullRepaints += 1 }
            if bytes.isEmpty { tally.emptyFeeds += 1 }
            screen.feed(bytes)

            var found: [String] = []
            if focusTurnedOn && screen.sent == [0x1B, 0x5B, 0x49] {
                // SwiftTerm reports its focus state when the mode is switched on. The
                // app sends this to the host like any other input.
                tally.focusReports += 1
                screen.sent.removeAll()
            }
            if !screen.sent.isEmpty {
                found.append("the feed made SwiftTerm send \(SurfaceComparison.escaped(screen.sent))")
                screen.sent.removeAll()
            }
            if screen.bells != 0 || !screen.titles.isEmpty || screen.clipboardWrites != 0 {
                found.append("the feed rang the bell, set a title or wrote the clipboard")
                screen.bells = 0
                screen.titles.removeAll()
                screen.clipboardWrites = 0
            }
            SurfaceComparison.compare(screen, fb, tally: &tally, found: &found, limit: limit)
            if !found.isEmpty {
                for f in found where failures.count < limit {
                    failures.append("\(c.name) after instruction \(i + 1) of \(states.count)"
                        + (full ? " (full repaint)" : "") + ": \(f)")
                }
                if failures.count >= limit {
                    failures.append("\(c.name): last feed was \(SurfaceComparison.escaped(bytes.prefix(400)))")
                    return failures
                }
            }
        }
        return failures
    }
}

enum SurfaceComparison {
    static func escaped<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var s = ""
        for b in bytes {
            switch b {
            case 0x1B: s += "\\e"
            case 0x0D: s += "\\r"
            case 0x0A: s += "\\n"
            case 0x20...0x7E: s += String(UnicodeScalar(b))
            default: s += "\\x" + String(b, radix: 16).leftPad(2)
            }
        }
        return s
    }

    static func scalars(_ contents: [UInt8]) -> [UInt32] {
        return String(decoding: contents, as: UTF8.self).unicodeScalars.map { $0.value }
    }

    static func hex(_ values: [UInt32]) -> String {
        return "[" + values.map(WidthScan.hex).joined(separator: " ") + "]"
    }

    /// The colour SwiftTerm should hold for one of mosh's colour fields.
    static func color(_ raw: UInt32, base: UInt32) -> Attribute.Color {
        if raw == 0 {
            // SwiftTerm's default pen has `.defaultColor` in both fields
            // (`.defaultInvertedColor` appears only in its `Attribute.empty`).
            return .defaultColor
        }
        if Renditions.isTrueColor(raw) {
            return .trueColor(red: UInt8((raw >> 16) & 0xFF), green: UInt8((raw >> 8) & 0xFF), blue: UInt8(raw & 0xFF))
        }
        return .ansi256(code: UInt8(truncatingIfNeeded: raw - base))
    }

    static func style(_ r: Renditions) -> CharacterStyle {
        var s: CharacterStyle = []
        if r.getAttribute(.bold) { s.insert(.bold) }
        if r.getAttribute(.italic) { s.insert(.italic) }
        if r.getAttribute(.underlined) { s.insert(.underline) }
        if r.getAttribute(.blink) { s.insert(.blink) }
        if r.getAttribute(.inverse) { s.insert(.inverse) }
        if r.getAttribute(.invisible) { s.insert(.invisible) }
        return s
    }

    static func mouseMode(_ m: MouseReportingMode) -> Terminal.MouseMode {
        switch m {
        case .none: return .off
        case .x10: return .x10
        case .vt220: return .vt200
        case .vt220Hilight: return .off
        case .btnEvent: return .buttonEventTracking
        case .anyEvent: return .anyEvent
        }
    }

    /// Compare SwiftTerm's screen and modes with a framebuffer.
    static func compare(_ screen: SwiftTermScreen, _ fb: Framebuffer, tally: inout SurfaceTally,
                        found: inout [String], limit: Int) {
        let terminal = screen.terminal!
        let width = fb.ds.width
        let height = fb.ds.height
        if screen.cols != width || screen.rows != height {
            found.append("SwiftTerm is \(screen.cols)x\(screen.rows), the framebuffer \(width)x\(height)")
            return
        }

        func note(_ s: @autoclosure () -> String) {
            if found.count < limit { found.append(s()) }
        }

        for y in 0..<height {
            let cells = fb.rows[y].cells
            var x = 0
            while x < width {
                let cell = cells[x]
                guard let cd = terminal.getCharData(col: x, row: y) else {
                    note("row \(y) col \(x): SwiftTerm has no cell")
                    x += 1
                    continue
                }
                let got = cd.getText().unicodeScalars.map { $0.value }
                tally.cells += 1

                if cell.wide && x == width - 1 {
                    // The feed switches autowrap off around it; SwiftTerm drops a wide
                    // character that does not fit. mosh's own client would let the real
                    // terminal wrap it onto the next row.
                    tally.exclude(SurfaceExclusion.wideInLastColumn)
                    tally.cellFields += 1
                    if !(got == [0] || got == [0x20]) {
                        note("row \(y) col \(x): a wide character in the last column should leave a blank, "
                            + "SwiftTerm has \(hex(got))")
                    }
                    x += 1
                    continue
                }

                // Characters.
                tally.cellFields += 1
                if cell.isEmpty {
                    if !(got == [0] || got == [0x20]) {
                        note("row \(y) col \(x): empty cell, SwiftTerm has \(hex(got))")
                    }
                } else {
                    let expected = (cell.fallback ? [0xA0] : []) + scalars(cell.contents)
                    let selector: UInt32 = cell.wide ? 0xFE0E : 0xFE0F
                    let fed = expected.filter { $0 != selector }
                    if fed != expected {
                        tally.exclude(SurfaceExclusion.selectorLeftOut)
                    }
                    if got != fed, got == fed.filter({ !SurfaceExclusion.notStored.contains($0) }) {
                        tally.exclude(SurfaceExclusion.zeroWidthNotStored)
                    } else if got != fed {
                        note("row \(y) col \(x): characters \(hex(expected)), SwiftTerm has \(hex(got))")
                    }
                }

                // Width, and the right half of a wide character.
                tally.cellFields += 1
                if Int(cd.width) != cell.width {
                    note("row \(y) col \(x): width \(cell.width), SwiftTerm has \(cd.width) for \(hex(got))")
                } else if cell.wide {
                    tally.cellFields += 1
                    let tail = terminal.getCharData(col: x + 1, row: y)
                    let tailText = tail?.getText().unicodeScalars.map { $0.value } ?? []
                    if tail?.width != 0 || tailText != [0] {
                        note("row \(y) col \(x + 1): right half of a wide character, SwiftTerm has width "
                            + "\(tail?.width ?? -1) \(hex(tailText))")
                    }
                }

                // Attributes.
                let r = cell.renditions
                let a = cd.attribute
                tally.cellFields += 3
                let fg = color(r.foregroundColor, base: 30)
                let bg = color(r.backgroundColor, base: 40)
                if a.fg != fg {
                    note("row \(y) col \(x): foreground \(fg), SwiftTerm has \(a.fg) (\(hex(got)))")
                }
                if a.bg != bg {
                    note("row \(y) col \(x): background \(bg), SwiftTerm has \(a.bg) (\(hex(got)))")
                }
                if a.style != style(r) {
                    note("row \(y) col \(x): style \(style(r).rawValue), SwiftTerm has \(a.style.rawValue) (\(hex(got)))")
                }

                x += cell.width
            }
        }

        // Cursor.
        tally.cursors += 1
        let cursor = screen.cursor
        if cursor.x != fb.ds.cursorCol || cursor.y != fb.ds.cursorRow {
            note("cursor at row \(fb.ds.cursorRow) col \(fb.ds.cursorCol), SwiftTerm has row \(cursor.y) col \(cursor.x)")
        }
        if screen.cursorVisible != fb.ds.cursorVisible {
            note("cursor visible \(fb.ds.cursorVisible), SwiftTerm reports \(String(describing: screen.cursorVisible))")
        }

        // No scrollback: the first row of the buffer is the first row on screen.
        tally.modeFields += 1
        if terminal.getTopVisibleRow() != 0 {
            note("SwiftTerm keeps scrollback: its screen starts at buffer row \(terminal.getTopVisibleRow())")
        }

        // Modes.
        tally.modeFields += 8
        if fb.ds.mouseReportingMode == .vt220Hilight {
            tally.exclude(SurfaceExclusion.mouseHighlight)
        }
        if terminal.mouseMode != mouseMode(fb.ds.mouseReportingMode) {
            note("mouse mode \(fb.ds.mouseReportingMode), SwiftTerm has \(terminal.mouseMode)")
        }
        if terminal.bracketedPasteMode != fb.ds.bracketedPaste {
            note("bracketed paste \(fb.ds.bracketedPaste), SwiftTerm has \(terminal.bracketedPasteMode)")
        }
        if !terminal.applicationCursor {
            note("SwiftTerm is not in application cursor key mode")
        }
        func mode(_ n: Int, _ expected: Bool, _ name: String) {
            let s = screen.privateMode(n)
            if s != (expected ? 1 : 2) {
                note("\(name) (mode \(n)) \(expected), SwiftTerm reports \(String(describing: s))")
            }
        }
        mode(1004, fb.ds.mouseFocusEvent, "focus events")
        mode(1005, fb.ds.mouseEncodingMode == .utf8, "UTF-8 mouse encoding")
        mode(1006, fb.ds.mouseEncodingMode == .sgr, "SGR mouse encoding")
        mode(1015, fb.ds.mouseEncodingMode == .urxvt, "urxvt mouse encoding")
        mode(5, fb.ds.reverseVideo, "reverse video")
    }
}
