// Property tests for `DisplayDiff.newFrame`: a terminal that holds state `a` and is fed
// `newFrame(a, b)` ends up showing `b`.
//
// "Showing b" is mosh's `Framebuffer::operator==` with three adjustments that mosh's own
// design makes necessary (see `DiffComparison`):
// - rows are compared by their cells, not by object identity;
// - a cell is compared by what it draws (`Cell::compare`, mosh's own verification),
//   because an empty cell can come back as a space and a fallback cell comes back as a
//   no-break space with combining characters;
// - `mouseAlternateScroll` and the bell count are not transmitted exactly.
// A few states cannot be reproduced by `new_frame` at all (a wide character in the last
// column and the like). Those pairs are counted and reported, never silently passed; the
// same bytes come out of mosh itself (DisplayDiffCrossCheckTests).

import XCTest
@testable import MoshTerminal

/// The comparison of a terminal that received a diff with the state the diff describes.
struct DiffComparison {
    /// Differences nothing explains: a bug.
    var unexplained: [String] = []
    /// Known limits of mosh's `new_frame` that this pair ran into.
    var limits: Set<String> = []
    /// Fields `new_frame` does not carry (or carries in another form) that differ.
    var hidden: Set<String> = []

    var isClean: Bool { return unexplained.isEmpty && limits.isEmpty }

    static let wideInLastColumn = "a wide character in the last column"
    static let cursorShort = "cursor one column short: bottom-right cell drawn, then backspaces from the pending wrap"
    static let wrapBottomRow = "soft-wrap mark on the bottom row"
    static let wrapHidden = "soft-wrap mark kept in the cell hidden under a wide character"
    static let wrapOneColumn = "soft-wrap mark of a row that a wrap entered, on a terminal one column wide"
    static let iconNameAlone = "icon name changed alone: diff_from sends nothing, mosh's operator== ignores the icon name"
    static let fallbackOverflow = "fallback cell at the 32-byte limit of combining characters"
    static let longTitle = "title of 255 characters (set with OSC ;)"

    /// What a terminal holds in a cell after `print_grapheme` of a fallback cell went
    /// through it: a no-break space, then the combining characters while there is room.
    static func redrawnContents(_ cell: Cell) -> [UInt8] {
        if !cell.fallback { return cell.contents }
        var out: [UInt8] = [0xC2, 0xA0]
        let b = cell.contents
        var i = 0
        while i < b.count {
            var j = i + 1
            while j < b.count && b[j] & 0xC0 == 0x80 { j += 1 }
            if out.count < 32 { out += b[i..<j] }
            i = j
        }
        return out
    }

    /// True if a line has a wide character whose second half would be beyond the margin.
    static func hasWideInLastColumn(_ fb: Framebuffer) -> Bool {
        let w = fb.ds.width
        for row in fb.rows {
            var x = 0
            while x < w {
                let cell = row.cells[x]
                if cell.wide && x + 1 >= w { return true }
                x += cell.width
            }
        }
        return false
    }

    /// - Parameters:
    ///   - c: the terminal after the diff.
    ///   - b: the target of the diff.
    ///   - before: the terminal before the diff.
    ///   - a: the base of the diff.
    ///   - viaDiffFrom: the bytes came from `diff(from:)`, which sends nothing when the
    ///     two framebuffers are equal for mosh's `operator==`.
    init(got c: Framebuffer, want b: Framebuffer, before: Framebuffer, base a: Framebuffer, viaDiffFrom: Bool = false) {
        let w = b.ds.width
        let h = b.ds.height
        guard c.ds.width == w, c.ds.height == h, c.rows.count == h else {
            unexplained.append("size \(c.ds.width)x\(c.ds.height), want \(w)x\(h)")
            return
        }
        // Printing a wide character in the last column makes the receiving terminal
        // wrap first; everything after that is somewhere else.
        if DiffComparison.hasWideInLastColumn(b) {
            limits.insert(DiffComparison.wideInLastColumn)
            return
        }

        // Cells, walking the columns `put_row` walks.
        for y in 0..<h {
            let want = b.rows[y].cells
            let got = c.rows[y].cells
            var x = 0
            var lastVisible = 0
            while x < w {
                let bc = want[x]
                let cc = got[x]
                lastVisible = x
                defer { x += bc.width }
                if cc == bc { continue }
                if cc.renditions != bc.renditions {
                    unexplained.append("(\(y),\(x)) renditions \(cc.renditions), want \(bc.renditions)")
                }
                if cc.wide != bc.wide {
                    unexplained.append("(\(y),\(x)) wide \(cc.wide), want \(bc.wide)")
                }
                if cc.wrap != bc.wrap {
                    if x != w - 1 {
                        hidden.insert("wrap bit of a cell that is not the last of its row")
                    } else if y == h - 1 && bc.wrap {
                        limits.insert(DiffComparison.wrapBottomRow)
                    } else if w == 1 && bc.wrap {
                        // put_row prints the only cell because the row above wrapped
                        // into it, and then does not see that it wrote the last cell
                        limits.insert(DiffComparison.wrapOneColumn)
                    } else {
                        unexplained.append("(\(y),\(x)) wrap \(cc.wrap), want \(bc.wrap)")
                    }
                }
                if cc.contents != bc.contents || cc.fallback != bc.fallback {
                    if bc.fallback {
                        let redrawn = DiffComparison.redrawnContents(bc)
                        if cc.fallback || cc.contents != redrawn {
                            unexplained.append("(\(y),\(x)) contents \(cc.contents) fallback \(cc.fallback), want \(redrawn)")
                        } else if redrawn.count != bc.contents.count + 2 {
                            limits.insert(DiffComparison.fallbackOverflow)
                        } else {
                            hidden.insert("fallback cell: comes back as a no-break space plus the combining characters")
                        }
                    } else if !cc.fallback && bc.contents.isEmpty && cc.contents == [0x20] {
                        hidden.insert("empty cell drawn as a space")
                    } else {
                        unexplained.append("(\(y),\(x)) contents \(cc.contents) fallback \(cc.fallback), want \(bc.contents) fallback \(bc.fallback)")
                    }
                }
            }
            if lastVisible != w - 1 {
                // the last column is under a wide character: so is the row's wrap mark
                if c.rows[y].wrap != b.rows[y].wrap {
                    limits.insert(y == h - 1 && b.rows[y].wrap ? DiffComparison.wrapBottomRow : DiffComparison.wrapHidden)
                }
            }
            // cells under a wide character
            x = 0
            while x < w {
                if want[x].wide && x + 1 < w && got[x + 1] != want[x + 1] {
                    hidden.insert("cell under the right half of a wide character")
                }
                x += want[x].width
            }
        }

        // The draw state fields of mosh's DrawState::operator==.
        let cd = c.ds
        let bd = b.ds
        if cd.cursorRow != bd.cursorRow || cd.cursorCol != bd.cursorCol {
            if cd.cursorRow == bd.cursorRow && bd.cursorRow == h - 1 && cd.cursorCol == bd.cursorCol - 1
                && bd.cursorCol >= w - 4 {
                limits.insert(DiffComparison.cursorShort)
            } else {
                unexplained.append("cursor (\(cd.cursorRow),\(cd.cursorCol)), want (\(bd.cursorRow),\(bd.cursorCol))")
            }
        }
        if cd.cursorVisible != bd.cursorVisible { unexplained.append("cursor visible \(cd.cursorVisible)") }
        if cd.reverseVideo != bd.reverseVideo { unexplained.append("reverse video \(cd.reverseVideo)") }
        if cd.renditions != bd.renditions { unexplained.append("pen \(cd.renditions), want \(bd.renditions)") }
        if cd.bracketedPaste != bd.bracketedPaste { unexplained.append("bracketed paste \(cd.bracketedPaste)") }
        if cd.mouseReportingMode != bd.mouseReportingMode { unexplained.append("mouse reporting \(cd.mouseReportingMode)") }
        if cd.mouseFocusEvent != bd.mouseFocusEvent { unexplained.append("focus events \(cd.mouseFocusEvent)") }
        if cd.mouseEncodingMode != bd.mouseEncodingMode { unexplained.append("mouse encoding \(cd.mouseEncodingMode)") }
        if cd.mouseAlternateScroll != bd.mouseAlternateScroll {
            hidden.insert("mouseAlternateScroll (?1007): compared by mosh's operator== but never sent")
        }

        // Titles, clipboard, bell.
        if b.titleInitialized {
            if c.windowTitle != b.windowTitle || c.iconName != b.iconName {
                if b.windowTitle.count >= 255 || b.iconName.count >= 255 {
                    limits.insert(DiffComparison.longTitle)
                } else if viaDiffFrom && c.windowTitle == b.windowTitle {
                    limits.insert(DiffComparison.iconNameAlone)
                } else {
                    unexplained.append("titles \(c.iconName) / \(c.windowTitle), want \(b.iconName) / \(b.windowTitle)")
                }
            }
            if !c.titleInitialized && !(b.iconName == a.iconName && b.windowTitle == a.windowTitle) && !viaDiffFrom {
                unexplained.append("title not initialized")
            }
        } else if c.windowTitle != before.windowTitle || c.iconName != before.iconName {
            unexplained.append("titles changed although the target has none")
        }
        if c.titleInitialized != b.titleInitialized { hidden.insert("titleInitialized") }
        if c.iconName != b.iconName && !b.titleInitialized { hidden.insert("icon name and window title while the target's are not initialized") }
        if c.clipboard != b.clipboard { unexplained.append("clipboard") }
        if (c.bellCount != before.bellCount) != (b.bellCount != a.bellCount) {
            unexplained.append("bell: \(before.bellCount) -> \(c.bellCount), want a change: \(b.bellCount != a.bellCount)")
        }
        if c.bellCount != b.bellCount { hidden.insert("bell count: one BEL however many rang, counted from the receiver's own count") }

        // Fields new_frame does not carry.
        if cd.nextPrintWillWrap != bd.nextPrintWillWrap { hidden.insert("nextPrintWillWrap") }
        if cd.originMode != bd.originMode { hidden.insert("origin mode") }
        if cd.autoWrapMode != bd.autoWrapMode { hidden.insert("autowrap mode") }
        if cd.insertMode != bd.insertMode { hidden.insert("insert mode") }
        if cd.applicationModeCursorKeys != bd.applicationModeCursorKeys { hidden.insert("application cursor keys") }
        if cd.scrollingRegionTopRow != bd.scrollingRegionTopRow || cd.scrollingRegionBottomRow != bd.scrollingRegionBottomRow {
            hidden.insert("scrolling region")
        }
        if cd.tabs != bd.tabs || cd.defaultTabs != bd.defaultTabs { hidden.insert("tab stops") }
        if cd.save != bd.save { hidden.insert("saved cursor") }
        if cd.combiningCharCol != bd.combiningCharCol || cd.combiningCharRow != bd.combiningCharRow {
            hidden.insert("combining character position")
        }
    }
}

/// Outputs worked out by hand from terminaldisplay.cc. DisplayDiffTests checks the port
/// against them on every platform; DisplayDiffCrossCheckTests checks that mosh itself
/// writes the same bytes, so the expectations are mosh's and not the port's.
struct DisplayDiffExample {
    var name: String
    var width: Int
    var height: Int
    /// Input that leads to the base state, and further input that leads to the target.
    var base: String
    var change: String
    var initialized = true
    var expected: String

    static let all: [DisplayDiffExample] = [
        DisplayDiffExample(name: "text at the cursor needs no move", width: 80, height: 24,
                           base: "", change: "hello", expected: "hello"),
        DisplayDiffExample(name: "the pen is set for the cells and put back", width: 20, height: 4,
                           base: "", change: "\u{1B}[31mred\u{1B}[0m", expected: "\u{1B}[0;31mred\u{1B}[0m"),
        DisplayDiffExample(name: "scroll of the whole screen with the cursor on the bottom line", width: 10, height: 3,
                           base: "a\r\nb\r\nc", change: "\r\nd", expected: "\u{1B}[0m\r\nd"),
        DisplayDiffExample(name: "scroll of the top lines through a scrolling region", width: 10, height: 4,
                           base: "a\r\nb\r\nc\r\nd", change: "\u{1B}[1;3r\u{1B}[3;1H\n\u{1B}[r",
                           expected: "\u{1B}[0m\u{1B}[1;3r\u{1B}[?25l\u{1B}[3;1H\n\u{1B}[r\u{1B}[1;1H\u{1B}[?25h"),
        DisplayDiffExample(name: "icon name equal to window title", width: 20, height: 2,
                           base: "", change: "\u{1B}]0;hi\u{7}", expected: "\u{1B}]0;hi\u{7}"),
        DisplayDiffExample(name: "icon name other than window title", width: 20, height: 2,
                           base: "", change: "\u{1B}]1;i\u{7}\u{1B}]2;w\u{7}", expected: "\u{1B}]1;i\u{7}\u{1B}]2;w\u{7}"),
        DisplayDiffExample(name: "two bells are one, then the clipboard", width: 20, height: 2,
                           base: "", change: "\u{7}\u{7}\u{1B}]52;c;QQ==\u{7}", expected: "\u{7}\u{1B}]52;c;QQ==\u{7}"),
        DisplayDiffExample(name: "ECH for more than four cells, and the cell after the run is drawn again", width: 20, height: 2,
                           base: "abcdefghijklmnop\u{1B}[H", change: "\u{1B}[2G\u{1B}[6X",
                           expected: "\u{1B}[?25l\u{1B}[1;2H\u{1B}[6X\u{1B}[1;8Hh\u{1B}[1;2H\u{1B}[?25h"),
        DisplayDiffExample(name: "EL under the cells' background colour", width: 10, height: 2,
                           base: "", change: "\u{1B}[44m\u{1B}[K", expected: "\u{1B}[0;44m\u{1B}[K"),
        DisplayDiffExample(name: "a wrapped line: explicit move before its last cell, then the receiver wraps", width: 5, height: 3,
                           base: "", change: "abcdefg", expected: "abcd\u{1B}[?25l\u{1B}[1;5Hefg\u{1B}[?25h"),
        DisplayDiffExample(name: "a cell that starts with a combining character", width: 10, height: 2,
                           base: "", change: "\u{301}x", expected: "\u{A0}\u{301}x"),
        DisplayDiffExample(name: "modes in new_frame's order", width: 20, height: 2,
                           base: "\u{1B}[?1000h\u{1B}[?1006h",
                           change: "\u{1B}[?1002h\u{1B}[?1015h\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?25l\u{1B}[?5h",
                           expected: "\u{1B}[?5h\u{1B}[?25l\u{1B}[?2004h\u{1B}[?1000l\u{1B}[?1002h\u{1B}[?1004h\u{1B}[?1006l\u{1B}[?1015h"),
        DisplayDiffExample(name: "bottom-right cell, then a backspace from the column past the margin", width: 10, height: 3,
                           base: "\u{1B}[3;10H", change: "X", expected: "X\u{8}"),
        DisplayDiffExample(name: "repaint of a blank screen", width: 4, height: 2, base: "", change: "", initialized: false,
                           expected: "\u{1B}[?5l\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[?25l\u{1B}[K\n\u{1B}[K\u{1B}[1;1H\u{1B}[?25h\u{1B}[0m"
                               + "\u{1B}[?2004l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1001l\u{1B}[?1000l\u{1B}[?1004l"
                               + "\u{1B}[?1015l\u{1B}[?1006l\u{1B}[?1005l"),
    ]
}

final class DisplayDiffTests: XCTestCase {
    func testExamples() {
        for e in DisplayDiffExample.all {
            let a = terminal(e.width, e.height, e.base)
            var b = a
            b.feed(e.change)
            let update = DisplayDiff.newFrame(initialized: e.initialized, from: a.framebuffer, to: b.framebuffer)
            XCTAssertEqual(String(decoding: update, as: UTF8.self).debugDescription, e.expected.debugDescription, e.name)
            XCTAssertEqual(update, Array(e.expected.utf8), e.name)
        }
    }

    /// mosh's display leaves the receiving terminal's cursor one column short after it
    /// drew the bottom-right cell: it counts the cursor as past the margin and steps
    /// back with backspaces, but the terminal's cursor is still on the last column.
    /// (mosh does the same; see the example above in DisplayDiffCrossCheckTests.)
    func testBottomRightCellLeavesTheCursorOneColumnShort() {
        let a = terminal(10, 3, "\u{1B}[3;10H")
        var b = a
        b.feed("X")
        XCTAssertEqual(b.cursor, [2, 9])
        var receiver = a
        receiver.act(DisplayDiff.newFrame(initialized: true, from: a.framebuffer, to: b.framebuffer))
        XCTAssertEqual(receiver.contents(2, 9), [0x58])
        XCTAssertEqual(receiver.cursor, [2, 8])
    }

    /// `diff(from:)` writes what `Complete::diff_from` writes.
    func testDiffFrom() {
        let a = terminal(10, 3, "abc")
        XCTAssertTrue(a.diff(from: a).isEmpty)

        var b = a
        b.applyEchoAck(5)
        XCTAssertEqual(b.diff(from: a), TerminalDiff(echoAck: 5))

        b.feed("d")
        XCTAssertEqual(b.diff(from: a), TerminalDiff(echoAck: 5, hostBytes: [0x64]))

        b.resize(width: 12, height: 2)
        let d = b.diff(from: a)
        XCTAssertEqual(d.resize, TerminalDiff.Size(width: 12, height: 2))
        XCTAssertEqual(d.hostBytes.map { Array($0.prefix(5)) }, Array("\u{1B}[r\u{1B}[".utf8))

        // ?1007 makes the framebuffers differ for mosh, but new_frame has nothing to say
        var c = a
        c.feed("\u{1B}[?1007h")
        XCTAssertFalse(c.framebuffer.moshEquals(a.framebuffer))
        XCTAssertTrue(c.diff(from: a).isEmpty)

        // the icon name alone: mosh's operator== does not see it, so nothing is sent
        var icon = a
        icon.feed("\u{1B}]2;\u{7}")
        let titled = icon
        icon.feed("\u{1B}]1;name\u{7}")
        XCTAssertTrue(icon.diff(from: titled).isEmpty)
        XCTAssertFalse(DisplayDiff.newFrame(initialized: true, from: titled.framebuffer, to: icon.framebuffer).isEmpty)

        // init_diff is the diff from a blank screen of the same size
        var fresh = TerminalState(width: 10, height: 3)
        fresh.apply(a.initDiff())
        XCTAssertTrue(fresh.framebuffer == a.framebuffer)
    }

    /// A copy of a state as a terminal that only ever received `new_frame` output holds
    /// it: same screen, the modes `new_frame` does not transmit at their defaults, and
    /// the parser between sequences (a server's state can end inside an escape sequence
    /// or a multi-byte character; `new_frame` output never does).
    static func receiverCopy(_ s: TerminalState) -> TerminalState {
        var c = s
        c.resetInput()
        c.terminal.fb.ds.originMode = false
        c.terminal.fb.ds.insertMode = false
        c.terminal.fb.ds.autoWrapMode = true
        c.terminal.fb.ds.nextPrintWillWrap = false
        c.terminal.fb.ds.setScrollingRegion(top: 0, bottom: c.terminal.fb.ds.height - 1)
        return c
    }

    private struct Tally {
        var pairs = 0
        var clean = 0
        var cleanDifferentSize = 0
        var limits: [String: Int] = [:]
        var hidden: [String: Int] = [:]
        var failures: [String] = []
        var regionScrolls = 0
        var erases = 0
        var empty = 0

        var unexplainedCount = 0

        func report(_ name: String) {
            print("\(name): \(pairs) pairs, \(clean) reproduce the target exactly as far as new_frame carries it "
                + "(\(cleanDifferentSize) of them between different sizes), \(unexplainedCount) unexplained")
            for (k, v) in limits.sorted(by: { $0.key < $1.key }) { print("  limit of mosh's new_frame, \(v) pairs: \(k)") }
            for (k, v) in hidden.sorted(by: { $0.key < $1.key }) { print("  hidden difference, \(v) pairs: \(k)") }
            print("  diffs that scrolled with a scrolling region: \(regionScrolls), with ECH or EL: \(erases), empty: \(empty)")
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        if haystack.count < n.count { return false }
        for i in 0...(haystack.count - n.count) where haystack[i] == n[0] {
            if haystack[i..<(i + n.count)].elementsEqual(n) { return true }
        }
        return false
    }

    /// Feed `newFrame(a, b)` to `receiver` (resizing it first when the sizes differ, as
    /// the resize instruction of a diff does) and compare.
    ///
    /// With `display == nil` the bytes come from `diff(from:)` and go through `apply`,
    /// the port of what mosh's server and client do with a pair of states.
    private func applyAndCompare(_ display: DisplayDiff?, initialized: Bool, a: TerminalState, b: TerminalState,
                                 receiver: TerminalState, tally: inout Tally, label: @autoclosure () -> String) -> (TerminalState, Bool) {
        var c = receiver
        var reply: [UInt8] = []
        let update: [UInt8]
        let differentSize = a.framebuffer.ds.width != b.framebuffer.ds.width || a.framebuffer.ds.height != b.framebuffer.ds.height
        if let display = display {
            update = display.newFrame(initialized: initialized, from: a.framebuffer, to: b.framebuffer)
            if differentSize {
                reply += c.resize(width: b.framebuffer.ds.width, height: b.framebuffer.ds.height)
            }
            reply += c.act(update)
        } else {
            let diff = b.diff(from: a)
            update = diff.hostBytes ?? []
            reply += c.apply(diff)
            XCTAssertEqual(diff.resize != nil, differentSize, label())
            XCTAssertEqual(diff.echoAck != nil, a.echoAck != b.echoAck, label())
            XCTAssertEqual(c.echoAck, b.echoAck, label())
            XCTAssertNotEqual(diff.hostBytes, [], "an empty update is left out")
        }
        let r = DiffComparison(got: c.framebuffer, want: b.framebuffer, before: receiver.framebuffer, base: a.framebuffer,
                               viaDiffFrom: display == nil)
        var unexplained = r.unexplained
        // "server never interrogates client terminal"
        if !reply.isEmpty { unexplained.append("the diff made the terminal reply \(reply)") }
        if !unexplained.isEmpty {
            tally.unexplainedCount += 1
            if tally.failures.count < 8 {
                tally.failures.append(label() + ": " + unexplained.prefix(4).joined(separator: "; ")
                    + "\n  diff: " + String(decoding: update, as: UTF8.self).debugDescription)
            }
        }
        tally.pairs += 1
        if r.isClean && reply.isEmpty {
            tally.clean += 1
            if differentSize { tally.cleanDifferentSize += 1 }
        }
        for l in r.limits { tally.limits[l, default: 0] += 1 }
        for l in r.hidden { tally.hidden[l, default: 0] += 1 }
        if update.isEmpty { tally.empty += 1 }
        if initialized && !differentSize && DisplayDiffTests.contains(update, "\u{1B}[r") { tally.regionScrolls += 1 }
        if DisplayDiffTests.contains(update, "\u{1B}[K") || (update.contains(0x58) && DisplayDiffTests.contains(update, "X")) {
            tally.erases += 1
        }
        return (c, r.isClean && reply.isEmpty)
    }

    private func caseCount(_ standard: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["MOSH_FUZZ_CASES"], let n = Int(s), n > 0 { return n }
        return standard
    }

    /// The task's property, for pairs (a, b) out of one history: b is a later state than
    /// a (as in every diff a server sends), sometimes several states later, sometimes
    /// earlier. The receiver is a copy of a itself.
    func testDiffAppliedToACopyOfTheBaseGivesTheTarget() {
        var tally = Tally()
        for seed in UInt64(1)...UInt64(caseCount(500)) {
            var scenario = DiffScenario(seed: seed)
            var server = TerminalState(width: scenario.width, height: scenario.height)
            var history = [server]
            for k in 1...12 {
                for _ in 0..<(1 + scenario.fuzz.int(3)) { DiffScenario.apply(scenario.step(), to: &server) }
                history.append(server)
                let j = scenario.fuzz.chance(70) ? k - 1 : max(0, k - 1 - scenario.fuzz.int(5))
                _ = applyAndCompare(.server, initialized: true, a: history[j], b: server,
                                    receiver: DisplayDiffTests.receiverCopy(history[j]), tally: &tally,
                                    label: "seed \(seed) states \(j) -> \(k)")
                if scenario.fuzz.chance(15) {
                    // backwards
                    _ = applyAndCompare(.server, initialized: true, a: server, b: history[j],
                                        receiver: DisplayDiffTests.receiverCopy(server), tally: &tally,
                                        label: "seed \(seed) states \(k) -> \(j)")
                }
                // a diff from a state to itself is empty
                XCTAssertTrue(DisplayDiff.newFrame(initialized: true, from: server.framebuffer, to: server.framebuffer).isEmpty)
            }
        }
        tally.report("DisplayDiff property, receiver is a copy of the base")
        for f in tally.failures { XCTFail(f) }
        XCTAssertEqual(tally.unexplainedCount, 0)
        XCTAssertGreaterThanOrEqual(tally.clean, 2000)
        XCTAssertGreaterThanOrEqual(tally.cleanDifferentSize, 200)
        XCTAssertGreaterThan(tally.regionScrolls, 50)
    }

    /// The same as a client lives it: its states are made only of diffs. State k is the
    /// client's state j after `apply` of the server's `diff(from:)` between its states j
    /// and k (the ports of `Complete::diff_from` and `apply_string`). When a pair runs into one of mosh's limits the client is put back in
    /// step, because from then on its screen is not the server's.
    func testAClientFollowingDiffsHoldsTheServersStates() {
        var tally = Tally()
        for seed in UInt64(10_001)...UInt64(10_000 + caseCount(300)) {
            var scenario = DiffScenario(seed: seed)
            var server = TerminalState(width: scenario.width, height: scenario.height)
            var history = [server]
            var clients = [server]
            for k in 1...14 {
                for _ in 0..<(1 + scenario.fuzz.int(3)) { DiffScenario.apply(scenario.step(), to: &server) }
                history.append(server)
                let j = scenario.fuzz.chance(70) ? k - 1 : max(0, k - 1 - scenario.fuzz.int(5))

                let (c, clean) = applyAndCompare(nil, initialized: true, a: history[j], b: server,
                                                 receiver: clients[j], tally: &tally,
                                                 label: "seed \(seed) client states \(j) -> \(k)")
                clients.append(clean ? c : DisplayDiffTests.receiverCopy(server))
            }
        }
        tally.report("DisplayDiff property, client following the server's diffs")
        for f in tally.failures { XCTFail(f) }
        XCTAssertEqual(tally.unexplainedCount, 0)
        XCTAssertGreaterThanOrEqual(tally.clean, 2000)
    }

    /// Not initialized: the output must not depend on what the terminal shows. The
    /// receiver is the base with other text, colours, cursor and modes on top.
    func testRepaintGivesTheTargetWhateverTheTerminalShows() {
        var tally = Tally()
        for seed in UInt64(20_001)...UInt64(20_000 + caseCount(150)) {
            var scenario = DiffScenario(seed: seed)
            var server = TerminalState(width: scenario.width, height: scenario.height)
            for k in 1...8 {
                let a = server
                for _ in 0..<(1 + scenario.fuzz.int(3)) { DiffScenario.apply(scenario.step(), to: &server) }
                var receiver = DisplayDiffTests.receiverCopy(a)
                var mess = ""
                for _ in 0..<(1 + scenario.fuzz.int(6)) {
                    switch scenario.fuzz.int(6) {
                    case 0: mess += "\u{1B}[\(1 + scenario.fuzz.int(scenario.height));\(1 + scenario.fuzz.int(scenario.width))H"
                    case 1: mess += "\u{1B}[\(scenario.fuzz.pick([1, 4, 7, 31, 42, 0]))m"
                    case 2: mess += "\u{1B}[?" + scenario.fuzz.pick(["25", "5", "2004", "1000", "1002", "1004", "1006", "1015"])
                        + scenario.fuzz.pick(["h", "l"])
                    case 3: mess += server.framebuffer.titleInitialized ? "\u{1B}]0;other\u{7}" : "x"
                    default: mess += "scribble 日本 " + String(repeating: "z", count: scenario.fuzz.int(scenario.width * 2 + 1))
                    }
                }
                receiver.act(Array(mess.utf8))
                _ = applyAndCompare(.server, initialized: false, a: a, b: server, receiver: receiver, tally: &tally,
                                    label: "seed \(seed) repaint of state \(k)")
            }
        }
        tally.report("DisplayDiff property, repaint (not initialized)")
        for f in tally.failures { XCTFail(f) }
        XCTAssertEqual(tally.unexplainedCount, 0)
        XCTAssertGreaterThanOrEqual(tally.clean, 500)
    }

    /// Terminals without ECH, without BCE, without titles.
    func testOtherCapabilitiesGiveTheSameScreen() {
        var tally = Tally()
        for seed in UInt64(30_001)...UInt64(30_000 + caseCount(100)) {
            var scenario = DiffScenario(seed: seed)
            let display = DisplayDiff(hasECH: scenario.fuzz.chance(50), hasBCE: scenario.fuzz.chance(50), hasTitle: true)
            var server = TerminalState(width: scenario.width, height: scenario.height)
            for k in 1...8 {
                let a = server
                for _ in 0..<(1 + scenario.fuzz.int(3)) { DiffScenario.apply(scenario.step(), to: &server) }
                _ = applyAndCompare(display, initialized: true, a: a, b: server,
                                    receiver: DisplayDiffTests.receiverCopy(a), tally: &tally,
                                    label: "seed \(seed) \(display) state \(k)")
            }
        }
        tally.report("DisplayDiff property, other capabilities")
        for f in tally.failures { XCTFail(f) }
        XCTAssertEqual(tally.unexplainedCount, 0)
        XCTAssertGreaterThanOrEqual(tally.clean, 400)
    }
}
