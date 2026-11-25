import MoshTerminal
import MoshTestSupport
import SwiftTerm
import XCTest

/// The rules of `SurfaceFeed` one by one, each against SwiftTerm.
final class SurfaceFeedRuleTests: XCTestCase {
    private func state(_ width: Int, _ height: Int, _ text: String = "") -> TerminalState {
        var s = TerminalState(width: width, height: height)
        _ = s.act(Array(text.utf8))
        return s
    }

    private func bytes(_ s: String) -> [UInt8] {
        return Array(s.utf8)
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// Feed, give the bytes to SwiftTerm, and require that SwiftTerm shows the framebuffer.
    @discardableResult
    private func show(_ s: TerminalState, _ feed: inout SurfaceFeed, _ screen: SwiftTermScreen,
                      file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        let out = feed.feed(to: s.framebuffer)
        screen.feed(out)
        var tally = SurfaceTally()
        var found: [String] = []
        SurfaceComparison.compare(screen, s.framebuffer, tally: &tally, found: &found, limit: 5)
        XCTAssertEqual(found, [], "feed: \(SurfaceComparison.escaped(out))", file: file, line: line)
        return out
    }

    // MARK: Full repaint, invalidate, size

    func testTheFirstFeedIsAResetClearAndFullRepaint() {
        let s = state(20, 4, "hello\r\nworld")
        var feed = SurfaceFeed()
        XCTAssertNil(feed.lastShown)
        XCTAssertTrue(feed.needsFullRepaint(to: s.framebuffer))
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        let out = show(s, &feed, screen)
        let start = bytes("\u{1B}[?1h\u{1B}[?7h\u{1B}[?5l\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[?25l")
        XCTAssertEqual(Array(out.prefix(start.count)), start, SurfaceComparison.escaped(out))
        XCTAssertEqual(screen.text, ["hello", "world", "", ""])
        XCTAssertEqual(feed.lastShown, s.framebuffer)

        // The same framebuffer again: nothing to do.
        XCTAssertFalse(feed.needsFullRepaint(to: s.framebuffer))
        XCTAssertEqual(feed.feed(to: s.framebuffer), [])
    }

    func testInvalidateMakesTheNextFeedAFullRepaint() {
        var s = state(20, 4, "hello")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)

        // SwiftTerm's screen is damaged behind the feed's back, as after a resize of its
        // buffer. Without `invalidate()` the feed would not repair it.
        screen.feed("\u{1B}[2J\u{1B}[3;3Hgarbage\u{1B}[1;4r\u{1B}[?1l")
        XCTAssertEqual(feed.feed(to: s.framebuffer), [])
        feed.invalidate()
        XCTAssertTrue(feed.needsFullRepaint(to: s.framebuffer))
        let out = show(s, &feed, screen)
        XCTAssertTrue(contains(out, bytes("\u{1B}[2J")))
        XCTAssertEqual(screen.text, ["hello", "", "", ""])
        XCTAssertTrue(screen.terminal.applicationCursor)

        // After that, small diffs again.
        _ = s.act(bytes("!"))
        let small = show(s, &feed, screen)
        XCTAssertFalse(contains(small, bytes("\u{1B}[2J")))
        XCTAssertLessThan(small.count, 16, SurfaceComparison.escaped(small))
    }

    func testASizeDifferenceIsHandledLikeInvalidate() {
        var s = state(20, 4, "one\r\ntwo\r\nthree")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)

        _ = s.resize(width: 30, height: 6)
        _ = s.act(bytes(" and more"))
        XCTAssertTrue(feed.needsFullRepaint(to: s.framebuffer))
        // The view resizes SwiftTerm; the feed is not told.
        screen.resize(cols: 30, rows: 6)
        let out = show(s, &feed, screen)
        XCTAssertEqual(Array(out.prefix(SurfaceFeed.fullRepaintPrefix.count)), SurfaceFeed.fullRepaintPrefix)
        XCTAssertTrue(contains(out, bytes("\u{1B}[2J")))
        XCTAssertEqual(screen.text, ["one", "two", "three and more", "", "", ""])
    }

    // MARK: Scrollback

    /// The feed scrolls SwiftTerm's screen (new_frame's scroll shortcut). With the
    /// surface's `changeScrollback(nil)` nothing is kept; without it SwiftTerm fills its
    /// own scrollback with what scrolled off.
    func testSwiftTermKeepsNoScrollback() {
        var s = state(20, 4)
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        let withScrollback = SwiftTermScreen(cols: 20, rows: 4, keepScrollback: true)
        var scrolls = 0
        for i in 0..<30 {
            _ = s.act(bytes("line \(i)\r\n"))
            let out = feed.feed(to: s.framebuffer)
            if out.contains(0x0A) && !contains(out, bytes("\u{1B}[2J")) { scrolls += 1 }
            screen.feed(out)
            withScrollback.feed(out)
        }
        XCTAssertGreaterThan(scrolls, 20)
        XCTAssertEqual(screen.text, ["line 27", "line 28", "line 29", ""])
        XCTAssertEqual(screen.terminal.getTopVisibleRow(), 0)
        XCTAssertGreaterThan(withScrollback.terminal.getTopVisibleRow(), 20,
                             "the check for scrollback in SurfaceComparison would not notice it")
    }

    // MARK: Cursor keys

    func testCursorKeysGoOutAsSS3AfterEveryFullRepaint() {
        let s = state(20, 4, "x")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        // A new SwiftTerm terminal sends ESC [ A.
        XCTAssertFalse(screen.terminal.applicationCursor)

        // What SwiftTerm's iOS view sends for the up arrow (iOSTerminalView.swift).
        func upArrow() -> [UInt8] {
            return screen.terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        }

        show(s, &feed, screen)
        XCTAssertEqual(upArrow(), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(screen.privateMode(1), 1)

        // The three calls the surface must never make reset the mode. If SwiftTerm's
        // state is lost that way, `invalidate()` and the next feed bring it back.
        screen.terminal.softReset()
        XCTAssertEqual(upArrow(), [0x1B, 0x5B, 0x41], "softReset no longer resets cursor key mode; update the plan")
        feed.invalidate()
        show(s, &feed, screen)
        XCTAssertEqual(upArrow(), [0x1B, 0x4F, 0x41])

        screen.terminal.resetToInitialState()
        XCTAssertEqual(upArrow(), [0x1B, 0x5B, 0x41])
        feed.invalidate()
        show(s, &feed, screen)
        XCTAssertEqual(upArrow(), [0x1B, 0x4F, 0x41])

        // The mosh framebuffer's own cursor key mode is not what decides: the server
        // translates. An application that asks for normal cursor keys changes nothing.
        var t = s
        _ = t.act(bytes("\u{1B}[?1l"))
        show(t, &feed, screen)
        XCTAssertEqual(upArrow(), [0x1B, 0x4F, 0x41])
    }

    // MARK: Title, bell, clipboard

    func testTitleBellAndClipboardAreNeverInTheFeed() {
        var s = state(20, 4)
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)

        _ = s.act(bytes("\u{1B}]0;a title\u{07}\u{07}\u{07}\u{1B}]52;c;aGVsbG8=\u{07}text"))
        let fb = s.framebuffer
        XCTAssertEqual(fb.windowTitle, "a title".unicodeScalars.map { $0.value })
        XCTAssertEqual(fb.bellCount, 2)
        XCTAssertEqual(fb.clipboard, "aGVsbG8=".unicodeScalars.map { $0.value })

        // mosh's own writer sends all three.
        let wire = DisplayDiff.newFrame(initialized: true, from: feed.lastShown!, to: fb)
        XCTAssertTrue(contains(wire, [0x07]))
        XCTAssertTrue(contains(wire, bytes("\u{1B}]0;a title")))
        XCTAssertTrue(contains(wire, bytes("\u{1B}]52;c;aGVsbG8=")))

        for full in [false, true] {
            var f = feed
            if full { f.invalidate() }
            let out = f.feed(to: fb)
            XCTAssertFalse(out.contains(0x07), SurfaceComparison.escaped(out))
            XCTAssertFalse(contains(out, [0x1B, 0x5D]), SurfaceComparison.escaped(out))
            XCTAssertTrue(contains(out, bytes("text")))
            screen.feed(out)
            XCTAssertEqual(screen.bells, 0)
            XCTAssertEqual(screen.titles, [])
            XCTAssertEqual(screen.clipboardWrites, 0)
        }

        // A change of title, bell or clipboard alone gives an empty feed.
        feed = SurfaceFeed()
        _ = feed.feed(to: fb)
        _ = s.act(bytes("\u{1B}]2;other\u{07}\u{07}\u{1B}]52;c;eA==\u{07}"))
        XCTAssertNotEqual(s.framebuffer.windowTitle, fb.windowTitle)
        XCTAssertEqual(feed.feed(to: s.framebuffer), [])
    }

    // MARK: Modes

    func testMouseModesReachSwiftTerm() {
        var s = state(20, 4, "x")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.mouseMode, .off)

        func click() -> [UInt8] {
            screen.sent.removeAll()
            let flags = screen.terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
            screen.terminal.sendEvent(buttonFlags: flags, x: 2, y: 1)
            defer { screen.sent.removeAll() }
            return screen.sent
        }

        let modes: [(Int, Terminal.MouseMode)] = [
            (9, .x10), (1000, .vt200), (1002, .buttonEventTracking), (1003, .anyEvent),
        ]
        for (number, expected) in modes {
            _ = s.act(bytes("\u{1B}[?\(number)h"))
            show(s, &feed, screen)
            XCTAssertEqual(screen.terminal.mouseMode, expected, "mode \(number)")
            // X10 encoding: ESC [ M, button + 32, column + 33, row + 33.
            XCTAssertEqual(click(), [0x1B, 0x5B, 0x4D, 32, 35, 34], "mode \(number)")
        }

        // SGR encoding, as tmux and vim ask for.
        _ = s.act(bytes("\u{1B}[?1006h"))
        show(s, &feed, screen)
        XCTAssertEqual(click(), bytes("\u{1B}[<0;3;2M"))

        // A full repaint keeps both.
        feed.invalidate()
        show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.mouseMode, .anyEvent)
        XCTAssertEqual(click(), bytes("\u{1B}[<0;3;2M"))

        _ = s.act(bytes("\u{1B}[?1003l\u{1B}[?1006l"))
        show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.mouseMode, .off)
    }

    /// SwiftTerm has no highlight tracking. The feed gives it "off" instead, and never
    /// writes mode 1001 (SwiftTerm logs every sequence it does not handle).
    func testMouseHighlightTrackingIsOffForSwiftTerm() {
        var s = state(20, 4, "x")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        _ = s.act(bytes("\u{1B}[?1000h"))
        show(s, &feed, screen)
        _ = s.act(bytes("\u{1B}[?1001h"))
        XCTAssertEqual(s.framebuffer.ds.mouseReportingMode, .vt220Hilight)
        var out = show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.mouseMode, .off)
        XCTAssertFalse(contains(out, bytes("1001")), SurfaceComparison.escaped(out))
        feed.invalidate()
        out = show(s, &feed, screen)
        XCTAssertFalse(contains(out, bytes("1001")), SurfaceComparison.escaped(out))
        _ = s.act(bytes("\u{1B}[?1002h"))
        out = show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.mouseMode, .buttonEventTracking)
        XCTAssertFalse(contains(out, bytes("1001")), SurfaceComparison.escaped(out))
    }

    func testBracketedPasteReachesSwiftTerm() {
        var s = state(20, 4, "x")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)
        XCTAssertFalse(screen.terminal.bracketedPasteMode)
        _ = s.act(bytes("\u{1B}[?2004h"))
        show(s, &feed, screen)
        XCTAssertTrue(screen.terminal.bracketedPasteMode)
        XCTAssertEqual(screen.privateMode(2004), 1)
        feed.invalidate()
        show(s, &feed, screen)
        XCTAssertTrue(screen.terminal.bracketedPasteMode)
        _ = s.act(bytes("\u{1B}[?2004l"))
        show(s, &feed, screen)
        XCTAssertFalse(screen.terminal.bracketedPasteMode)
    }

    /// Focus events: SwiftTerm reports its focus state once when the mode is switched on
    /// (the app passes that to the host as input) and then on every focus change. A full
    /// repaint must not make it report again.
    func testFocusEventsReachSwiftTermAndAFullRepaintDoesNotRepeatTheReport() {
        var s = state(20, 4, "x")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 20, rows: 4)
        show(s, &feed, screen)
        screen.terminal.setTerminalFocus(false)
        XCTAssertEqual(screen.sent, [])

        _ = s.act(bytes("\u{1B}[?1004h"))
        screen.feed(feed.feed(to: s.framebuffer))
        XCTAssertEqual(screen.sent, bytes("\u{1B}[O"), "the report SwiftTerm sends when the mode is switched on")
        screen.sent.removeAll()
        XCTAssertEqual(screen.privateMode(1004), 1)

        screen.terminal.setTerminalFocus(true)
        XCTAssertEqual(screen.sent, bytes("\u{1B}[I"))
        screen.sent.removeAll()

        feed.invalidate()
        let out = feed.feed(to: s.framebuffer)
        screen.feed(out)
        XCTAssertEqual(screen.sent, [], "a full repaint repeated the focus report")
        XCTAssertFalse(contains(out, bytes("1004")))
        XCTAssertEqual(screen.privateMode(1004), 1)

        _ = s.act(bytes("\u{1B}[?1004l"))
        show(s, &feed, screen)
        screen.terminal.setTerminalFocus(false)
        XCTAssertEqual(screen.sent, [])
    }

    // MARK: Wide and combining characters

    /// After every wide character and every cell with a combining character the next
    /// thing in the feed is a cursor position.
    func testAnExplicitCursorPositionFollowsEveryWideAndCombiningCharacter() {
        let text = "a\u{6F22}\u{5B57}b e\u{0301}x \u{1F600}!"
        let s = state(30, 3, text)
        let fb = s.framebuffer
        XCTAssertTrue(fb.rows[0].cells[1].wide)
        XCTAssertEqual(fb.rows[0].cells[7].contents, Array("e\u{0301}".utf8))

        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 30, rows: 3)
        let out = show(s, &feed, screen)

        func followedByPosition(_ grapheme: String, _ row: Int, _ col: Int) {
            let want = bytes(grapheme) + bytes("\u{1B}[\(row);\(col)H")
            XCTAssertTrue(contains(out, want), "no cursor position after \(grapheme): \(SurfaceComparison.escaped(out))")
        }
        followedByPosition("\u{6F22}", 1, 4)
        followedByPosition("\u{5B57}", 1, 6)
        followedByPosition("e\u{0301}", 1, 9)
        followedByPosition("\u{1F600}", 1, 13)

        // mosh's own writer has none of them.
        let wire = DisplayDiff.newFrame(initialized: false, from: Framebuffer(width: 30, height: 3), to: fb)
        XCTAssertTrue(contains(wire, bytes(text)))
        XCTAssertFalse(contains(out, bytes(text)))
        XCTAssertEqual(screen.cursor.x, fb.ds.cursorCol)
    }

    /// A row of nothing but ASCII and the other trusted ranges is written as mosh writes
    /// it, without a position per cell.
    func testTrustedCellsAreWrittenAsARun() {
        let text = "caf\u{00E9} \u{2500}\u{2500}\u{2524} \u{03B1}\u{03B2} \u{2192} \u{28FF}"
        let s = state(30, 3, text)
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 30, rows: 3)
        let out = show(s, &feed, screen)
        XCTAssertTrue(contains(out, bytes(text)), SurfaceComparison.escaped(out))
    }

    /// mosh can hold a wide character in the last column (here: autowrap off). A real
    /// terminal wraps it. SwiftTerm must not: on the bottom row that would scroll the
    /// screen.
    func testAWideCharacterInTheLastColumnDoesNotWrapOrScroll() {
        let s = state(10, 3, "top\r\nmid\r\n\u{1B}[?7lbottom\u{1B}[3;10H\u{6F22}")
        let fb = s.framebuffer
        XCTAssertTrue(fb.rows[2].cells[9].wide, "the model no longer puts a wide character into the last column")
        XCTAssertEqual(fb.rows[2].cells[9].contents, Array("\u{6F22}".utf8))

        for full in [true, false] {
            var feed = SurfaceFeed()
            let screen = SwiftTermScreen(cols: 10, rows: 3)
            if !full {
                show(state(10, 3, "top\r\nmid\r\nbottom"), &feed, screen)
            }
            let out = feed.feed(to: fb)
            screen.feed(out)
            var tally = SurfaceTally()
            var found: [String] = []
            SurfaceComparison.compare(screen, fb, tally: &tally, found: &found, limit: 5)
            XCTAssertEqual(found, [], SurfaceComparison.escaped(out))
            XCTAssertEqual(tally.exclusions, [SurfaceExclusion.wideInLastColumn: 1])
            XCTAssertEqual(screen.text, ["top", "mid", "bottom"])
            XCTAssertEqual(screen.privateMode(7), 1, "autowrap must be on again after the feed")
        }
    }

    // MARK: Soft wrap

    /// Wrapped lines use SwiftTerm's autowrap, so SwiftTerm knows the rows belong
    /// together and copied text has no newline in it.
    func testSoftWrapMarksReachSwiftTerm() {
        let long = String(repeating: "abcdefghij", count: 3) + "tail"
        var s = state(10, 6, long + "\r\nnext")
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 10, rows: 6)
        show(s, &feed, screen)
        func wrapped() -> [Bool] {
            return (0..<6).map { screen.terminal.getLine(row: $0)?.isWrapped ?? false }
        }
        // SwiftTerm marks the row that continues the one above it.
        XCTAssertEqual(wrapped(), [false, true, true, true, false, false])

        // Also in a diff.
        _ = s.act(bytes("\r\n" + String(repeating: "0123456789", count: 2)))
        show(s, &feed, screen)
        // The screen scrolled by one row; the new long line is on rows 4 and 5.
        XCTAssertEqual(screen.text, ["abcdefghij", "abcdefghij", "tail", "next", "0123456789", "0123456789"])
        XCTAssertEqual(Array(wrapped()[2...]), [true, false, false, true])
    }

    /// Known gap: after a guarded cell the feed does not rely on autowrap, so a row that
    /// ends in a wide character passes no soft-wrap mark to SwiftTerm.
    func testARowEndingInAWideCharacterLosesItsSoftWrapMark() {
        let s = state(10, 3, String(repeating: "\u{6F22}", count: 7))
        XCTAssertTrue(s.framebuffer.rows[0].wrap)
        var feed = SurfaceFeed()
        let screen = SwiftTermScreen(cols: 10, rows: 3)
        show(s, &feed, screen)
        XCTAssertEqual(screen.terminal.getLine(row: 1)?.isWrapped, false,
                       "the soft-wrap mark now survives a wide character: remove the known gap")
    }

    // MARK: Skipping

    /// From any shown state to any newer one: 40 states of a small session, every pair.
    func testAnyNewerStateCanFollowAnyShownState() {
        var states: [TerminalState] = [state(24, 6)]
        let script = [
            "$ ls\r\n", "\u{1B}[1;32mfile\u{1B}[0m  other\r\n", "$ vi\r\n", "\u{1B}[2J\u{1B}[H~\r\n~\r\n~",
            "\u{1B}[6;1H\u{1B}[7m-- INSERT --\u{1B}[0m", "\u{1B}[1;1Hhello \u{6F22}\u{5B57} w\u{0308}orld",
            "\u{1B}[?25l", "\u{1B}[2;1H\u{1B}[44m\u{1B}[K\u{1B}[0m", "\u{1B}[?25h\u{1B}[?1000h\u{1B}[?1006h",
            "\u{1B}[3;5H\u{1B}[38;5;200mx\u{1B}[48;2;1;2;3my\u{1B}[0m", "\u{1B}[1;5r\u{1B}[5;1H\n\n\u{1B}[r",
            "\u{1B}[?2004h\u{1B}[H\u{1B}[2Kdone", "\u{1B}[?1000l\u{1B}[6;20Hend\r\n\r\n",
        ]
        for (i, step) in script.enumerated() {
            for piece in [step, "\u{1B}[\(i % 6 + 1);\(i * 3 % 24 + 1)H", "\(i)"] {
                var next = states[states.count - 1]
                _ = next.act(bytes(piece))
                states.append(next)
            }
        }
        XCTAssertEqual(states.count, 40)
        var pairs = 0
        for from in 0..<states.count {
            let screen = SwiftTermScreen(cols: 24, rows: 6)
            var base = SurfaceFeed()
            show(states[from], &base, screen)
            for to in (from + 1)..<max(from + 1, states.count) {
                // Each jump starts again from `from`: bring SwiftTerm back first.
                var feed = base
                feed.invalidate()
                show(states[from], &feed, screen)
                show(states[to], &feed, screen)
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 780)
    }

    // MARK: The comparison itself

    /// The comparison used by all these tests notices a wrong character, width, colour,
    /// style, cursor, cursor visibility and each mode.
    func testTheComparisonNoticesAWrongScreen() {
        let s = state(20, 4, "\u{1B}[1;31mhello\u{1B}[0m \u{6F22}")
        let damage: [(String, String)] = [
            ("\u{1B}7\u{1B}[1;2HE\u{1B}8", "characters"),
            ("\u{1B}7\u{1B}[1;7Hab\u{1B}8", "width"),
            ("\u{1B}7\u{1B}[1;1H\u{1B}[1;32mh\u{1B}8", "foreground"),
            ("\u{1B}7\u{1B}[1;1H\u{1B}[1;31;44mh\u{1B}8", "background"),
            ("\u{1B}7\u{1B}[1;1H\u{1B}[0;31mh\u{1B}8", "style"),
            ("\u{1B}7\u{1B}[2;1H\u{1B}[41m\u{1B}[K\u{1B}8", "background"),
            ("\u{1B}[C", "cursor at"),
            ("\u{1B}[?25l", "cursor visible"),
            ("\u{1B}[?1000h", "mouse mode"),
            ("\u{1B}[?2004h", "bracketed paste"),
            ("\u{1B}[?1l", "application cursor"),
            ("\u{1B}[?1004h", "focus events"),
            ("\u{1B}[?1006h", "SGR mouse encoding"),
            ("\u{1B}[?5h", "reverse video"),
        ]
        for (sequence, expected) in damage {
            var feed = SurfaceFeed()
            let screen = SwiftTermScreen(cols: 20, rows: 4)
            show(s, &feed, screen)
            screen.feed(sequence)
            var tally = SurfaceTally()
            var found: [String] = []
            SurfaceComparison.compare(screen, s.framebuffer, tally: &tally, found: &found, limit: 5)
            XCTAssertTrue(found.contains { $0.contains(expected) },
                          "\(SurfaceComparison.escaped(Array(sequence.utf8))) was not noticed as \(expected): \(found)")
        }
    }

    // MARK: visibleText

    func testVisibleText() {
        let s = state(12, 5, "plain   \r\n  two  words\r\n\u{6F22}\u{5B57}x e\u{0301}\r\n\u{1B}[4;3H\u{0301}z\u{1B}[8mhid\u{1B}[0m")
        XCTAssertEqual(visibleText(of: s.framebuffer), [
            "plain",
            "  two  words",
            "\u{6F22}\u{5B57}x e\u{0301}",
            "  \u{00A0}\u{0301}zhid",
            "",
        ])
        XCTAssertEqual(SurfaceFeed.visibleText(of: Framebuffer(width: 3, height: 2)), ["", ""])
    }

    /// For the four recorded sessions that must pass completely, the text of the last
    /// screen is the text SwiftTerm shows.
    func testVisibleTextEqualsSwiftTermsText() throws {
        for name in SurfaceFeedCorpusTests.mustPassCompletely {
            let c = try GoldenCorpus.load(name)
            let states = SurfaceWalk.states(c)
            var feed = SurfaceFeed()
            var compared = 0
            for s in [states[states.count / 2], states[states.count - 1]] {
                let fb = s.framebuffer
                let screen = SwiftTermScreen(cols: fb.ds.width, rows: fb.ds.height)
                feed.invalidate()
                screen.feed(feed.feed(to: fb))
                XCTAssertEqual(visibleText(of: fb), screen.text, name)
                compared += 1
            }
            XCTAssertEqual(compared, 2)
            XCTAssertFalse(visibleText(of: states[states.count - 1].framebuffer).allSatisfy { $0.isEmpty }, name)
        }
    }
}
