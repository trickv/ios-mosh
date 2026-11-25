// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Display` and `Terminal::FrameState`
// (src/terminal/terminaldisplay.{cc,h}, terminaldisplayinit.cc), and of
// `Terminal::Complete::diff_from` / `init_diff` (src/statesync/completeterminal.cc).
//
// `newFrame` writes the escape sequences that turn one framebuffer into another. It is
// what mosh-server puts into the `hostbytes` of a state diff, and what a client uses to
// paint its real terminal.
//
// Which `Display` the server uses: `Complete` holds `Terminal::Display display` built
// with `display( false )`, i.e. `use_environment == false`. In that case the constructor
// in terminaldisplayinit.cc reads no terminfo and leaves `has_ech = true`,
// `has_bce = true`, `has_title = true`, `smcup = rmcup = NULL`. That is the default
// configuration here (`DisplayDiff.server`). `Complete::diff_from` always calls
// `new_frame( true, existing.fb, this.fb )`; `initialized == false` is used only by a
// client that repaints its own terminal from scratch.
//
// The output is meant to be byte-identical to mosh's. The tests compare it with mosh's
// own `Display::new_frame` (Tests/MoshTerminalTests/Support/moshref.cc).
//
// What `new_frame` looks at in the two framebuffers, and what it does not:
// - rows by object identity first (`Framebuffer.rows[i] === ...`), then by
//   `Row.moshEquals` (generation and cells) for scroll detection, then cell by cell;
// - of the draw state only: size, cursor position and visibility, reverse video, the pen
//   (`renditions`), bracketed paste, mouse reporting, focus and encoding modes;
// - bell count (one BEL however far it moved), icon name and window title (only once the
//   target's `titleInitialized` is set), clipboard.
// It does not transmit: origin mode, insert mode, autowrap mode, the scrolling region,
// tabs, the saved cursor, `nextPrintWillWrap`, the combining-character position,
// application cursor keys, `mouseAlternateScroll` (?1007, although mosh's
// `DrawState::operator==` compares it), a cell hidden under a wide character, and the
// `fallback` flag (a fallback cell is sent as a no-break space plus its combining
// characters). The output assumes the receiving terminal has those modes at their
// defaults, which is true for a terminal that only ever received `new_frame` output.

/// mosh `Terminal::Display`: writes the difference between two framebuffers.
public struct DisplayDiff: Equatable, Sendable {
    /// The terminal has ECH (`ESC [ n X`). mosh: "erase character is part of vt200 but
    /// not supported by tmux".
    public var hasECH: Bool
    /// "erases result in cell filled with background color"
    public var hasBCE: Bool
    /// "supports window title and icon name"
    public var hasTitle: Bool
    /// Write for SwiftTerm instead of for the wire: the rules of `SurfaceFeed`, which is
    /// the only user. Off, the output is mosh's, byte for byte.
    var surface = false

    public init(hasECH: Bool = true, hasBCE: Bool = true, hasTitle: Bool = true) {
        self.hasECH = hasECH
        self.hasBCE = hasBCE
        self.hasTitle = hasTitle
    }

    /// The configuration of the `Display` inside mosh-server's `Complete`
    /// (`Display( false )`: ECH, BCE and titles all on).
    public static let server = DisplayDiff()

    /// mosh `Display::new_frame` in the server's configuration.
    ///
    /// - Parameters:
    ///   - initialized: false means the receiving terminal is in an unknown state: the
    ///     output resets the scrolling region, clears the screen and repaints everything.
    ///     A size difference between the two framebuffers forces the same path.
    ///   - last: the state the receiving terminal is in.
    ///   - f: the state it should be in afterwards.
    public static func newFrame(initialized: Bool, from last: Framebuffer, to f: Framebuffer) -> [UInt8] {
        return server.newFrame(initialized: initialized, from: last, to: f)
    }

    /// mosh `Display::open` without `smcup` (the server's `Display` has none).
    public static let open: [UInt8] = Array("\u{1B}[?1h".utf8)

    /// mosh `Display::close` without `rmcup`.
    public static let close: [UInt8] = Array(("\u{1B}[?1l\u{1B}[0m\u{1B}[?25h"
        + "\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1001l\u{1B}[?1000l"
        + "\u{1B}[?1015l\u{1B}[?1006l\u{1B}[?1005l").utf8)

    /// mosh `initial_rendition()`.
    private static let initialRendition = Renditions(background: 0)

    /// mosh `Display::new_frame`.
    public func newFrame(initialized initiallyInitialized: Bool, from last: Framebuffer, to f: Framebuffer) -> [UInt8] {
        var initialized = initiallyInitialized
        var frame = FrameState(last: last)

        // has bell been rung?
        if !surface && f.bellCount != last.bellCount {
            frame.append(0x07)
        }

        // has icon name or window title changed?
        if hasTitle && !surface && f.titleInitialized
            && (!initialized || f.iconName != last.iconName || f.windowTitle != last.windowTitle) {
            // set icon name and window title
            if f.iconName == f.windowTitle {
                // write combined Icon Name and Window Title
                frame.append("\u{1B}]0;")
                frame.append(codePoints: f.windowTitle)
                frame.append(0x07)
                // ST is more correct, but BEL more widely supported
            } else {
                // write Icon Name
                frame.append("\u{1B}]1;")
                frame.append(codePoints: f.iconName)
                frame.append(0x07)

                frame.append("\u{1B}]2;")
                frame.append(codePoints: f.windowTitle)
                frame.append(0x07)
            }
        }

        // has clipboard changed?
        if !surface && f.clipboard != last.clipboard {
            frame.append("\u{1B}]52;c;")
            frame.append(codePoints: f.clipboard)
            frame.append(0x07)
        }

        // has reverse video state changed?
        if !initialized || f.ds.reverseVideo != last.ds.reverseVideo {
            // set reverse video
            frame.append(f.ds.reverseVideo ? "\u{1B}[?5h" : "\u{1B}[?5l")
        }

        // has size changed?
        if !initialized || f.ds.width != last.ds.width || f.ds.height != last.ds.height {
            // reset scrolling region
            frame.append("\u{1B}[r")

            // clear screen
            frame.append("\u{1B}[0m\u{1B}[H\u{1B}[2J")
            initialized = false
            frame.cursorX = 0
            frame.cursorY = 0
            frame.currentRendition = DisplayDiff.initialRendition
        } else {
            frame.cursorX = last.ds.cursorCol
            frame.cursorY = last.ds.cursorRow
            frame.currentRendition = last.ds.renditions
        }

        // is cursor visibility initialized?
        if !initialized {
            frame.cursorVisible = false
            frame.append("\u{1B}[?25l")
        }

        var frameY = 0
        var blankRow: Row? = nil
        var rows = last.rows
        // Extend rows if we've gotten a resize and new is wider than old
        if last.ds.width < f.ds.width {
            let filler = Cell(backgroundColor: f.ds.backgroundRendition)
            for i in rows.indices {
                let copy = Row(copying: rows[i])
                if copy.cells.count < f.ds.width {
                    copy.cells.append(contentsOf: repeatElement(filler, count: f.ds.width - copy.cells.count))
                }
                rows[i] = copy
            }
        }
        // Add rows if we've gotten a resize and new is taller than old
        if rows.count < f.ds.height {
            // get a proper blank row
            let blank = Row(width: f.ds.width, backgroundColor: 0)
            blankRow = blank
            rows.append(contentsOf: repeatElement(blank, count: f.ds.height - rows.count))
        }

        // Surface rule: anything written from here on can move the cursor.
        let lengthBeforeRows = frame.str.count

        // shortcut -- has display moved up by a certain number of lines?
        if initialized {
            var linesScrolled = 0
            var scrollHeight = 0

            let newRow = f.rows[0]
            for row in 0..<f.ds.height {
                let oldRow = rows[row]
                if !(newRow === oldRow || newRow.moshEquals(oldRow)) {
                    continue
                }
                // if row 0, we're looking at ourselves and probably didn't scroll
                if row == 0 {
                    break
                }
                // found a scroll
                linesScrolled = row
                scrollHeight = 1

                // how big is the region that was scrolled?
                var regionHeight = 1
                while linesScrolled + regionHeight < f.ds.height {
                    if f.rows[regionHeight].moshEquals(rows[linesScrolled + regionHeight]) {
                        scrollHeight = regionHeight + 1
                    } else {
                        break
                    }
                    regionHeight += 1
                }

                break
            }

            if scrollHeight != 0 {
                frameY = scrollHeight

                if linesScrolled != 0 {
                    // Now we need a proper blank row.
                    let blank: Row
                    if let b = blankRow {
                        blank = b
                    } else {
                        blank = Row(width: f.ds.width, backgroundColor: 0)
                        blankRow = blank
                    }
                    frame.updateRendition(DisplayDiff.initialRendition, force: true)

                    let topMargin = 0
                    let bottomMargin = topMargin + linesScrolled + scrollHeight - 1

                    // mosh: assert( bottom_margin < f.ds.get_height() ). True by
                    // construction: scrollHeight <= height - linesScrolled.

                    // Common case: if we're already on the bottom line and we're scrolling
                    // the whole screen, just do a CR and LFs.
                    if scrollHeight + linesScrolled == f.ds.height && frame.cursorY + 1 == f.ds.height {
                        frame.append(0x0D)
                        frame.append(count: linesScrolled, 0x0A)
                        frame.cursorX = 0
                    } else {
                        // set scrolling region
                        frame.append("\u{1B}[")
                        frame.append(decimal: topMargin + 1)
                        frame.append(0x3B)
                        frame.append(decimal: bottomMargin + 1)
                        frame.append(0x72) // r

                        // go to bottom of scrolling region
                        frame.cursorX = -1
                        frame.cursorY = -1
                        frame.appendSilentMove(bottomMargin, 0)

                        // scroll
                        frame.append(count: linesScrolled, 0x0A)

                        // reset scrolling region
                        frame.append("\u{1B}[r")
                        // invalidate cursor position after unsetting scrolling region
                        frame.cursorX = -1
                        frame.cursorY = -1
                    }

                    // do the move in our local index
                    var i = topMargin
                    while i <= bottomMargin {
                        if i + linesScrolled <= bottomMargin {
                            rows[i] = rows[i + linesScrolled]
                        } else {
                            rows[i] = blank
                        }
                        i += 1
                    }
                }
            }
        }

        // Now update the display, row by row
        var wrap = false
        while frameY < f.ds.height {
            wrap = putRow(initialized: initialized, frame: &frame, f: f, frameY: frameY, oldRow: rows[frameY], wrap: wrap)
            frameY += 1
        }

        // has cursor location changed?
        if surface {
            // Surface rule: the cursor is placed with an absolute position, and also
            // whenever something was drawn. mosh's count of backspaces is one short
            // after the last column was written, and the terminal's column after a
            // guarded cell is not known.
            if !initialized || f.ds.cursorRow != frame.cursorY || f.ds.cursorCol != frame.cursorX
                || frame.str.count != lengthBeforeRows {
                frame.cursorX = -1
                frame.cursorY = -1
                frame.appendMove(f.ds.cursorRow, f.ds.cursorCol)
            }
        } else if !initialized || f.ds.cursorRow != frame.cursorY || f.ds.cursorCol != frame.cursorX {
            frame.appendMove(f.ds.cursorRow, f.ds.cursorCol)
        }

        // has cursor visibility changed?
        if !initialized || f.ds.cursorVisible != frame.cursorVisible {
            frame.append(f.ds.cursorVisible ? "\u{1B}[?25h" : "\u{1B}[?25l")
        }

        // have renditions changed?
        frame.updateRendition(f.ds.renditions, force: !initialized)

        // has bracketed paste mode changed?
        if !initialized || f.ds.bracketedPaste != last.ds.bracketedPaste {
            frame.append(f.ds.bracketedPaste ? "\u{1B}[?2004h" : "\u{1B}[?2004l")
        }

        // has mouse reporting mode changed?
        // Surface rule: SwiftTerm has no highlight tracking (mode 1001, which needs an
        // answer from the application for every click); for it that mode is "off".
        var mouseMode = f.ds.mouseReportingMode
        var lastMouseMode = last.ds.mouseReportingMode
        if surface {
            if mouseMode == .vt220Hilight { mouseMode = .none }
            if lastMouseMode == .vt220Hilight { lastMouseMode = .none }
        }
        if !initialized || mouseMode != lastMouseMode {
            if mouseMode == .none {
                frame.append("\u{1B}[?1003l")
                frame.append("\u{1B}[?1002l")
                if !surface {
                    frame.append("\u{1B}[?1001l")
                }
                frame.append("\u{1B}[?1000l")
            } else {
                if lastMouseMode != .none {
                    frame.append("\u{1B}[?")
                    frame.append(decimal: lastMouseMode.rawValue)
                    frame.append(0x6C) // l
                }
                frame.append("\u{1B}[?")
                frame.append(decimal: mouseMode.rawValue)
                frame.append(0x68) // h
            }
        }

        // has mouse focus mode changed?
        // Surface rule: only a real change is written, also in a full repaint. SwiftTerm
        // answers every `?1004h` with a focus report for the host, and it keeps the mode
        // when it resizes its buffer.
        if (!initialized && !surface) || f.ds.mouseFocusEvent != last.ds.mouseFocusEvent {
            frame.append(f.ds.mouseFocusEvent ? "\u{1B}[?1004h" : "\u{1B}[?1004l")
        }

        // has mouse encoding mode changed?
        if !initialized || f.ds.mouseEncodingMode != last.ds.mouseEncodingMode {
            if f.ds.mouseEncodingMode == .default {
                frame.append("\u{1B}[?1015l")
                frame.append("\u{1B}[?1006l")
                frame.append("\u{1B}[?1005l")
            } else {
                if last.ds.mouseEncodingMode != .default {
                    frame.append("\u{1B}[?")
                    frame.append(decimal: last.ds.mouseEncodingMode.rawValue)
                    frame.append(0x6C) // l
                }
                frame.append("\u{1B}[?")
                frame.append(decimal: f.ds.mouseEncodingMode.rawValue)
                frame.append(0x68) // h
            }
        }

        return frame.str
    }

    /// mosh `Display::put_row`. Returns true when the row was left by letting the
    /// receiving terminal's cursor wrap, so the next row must start by printing its
    /// first cell.
    private func putRow(initialized: Bool, frame: inout FrameState, f: Framebuffer, frameY: Int,
                        oldRow: Row, wrap: Bool) -> Bool {
        var frameX = 0

        let row = f.rows[frameY]
        let cells = row.cells
        let oldCells = oldRow.cells

        // Surface rules: the cell after a guarded cell is always drawn, and a row whose
        // last written cell was guarded does not end by autowrap.
        var redrawNext = false
        var lastCellGuarded = false

        // If we're forced to write the first column because of wrap, go ahead and do so.
        if wrap {
            let cell = cells[0]
            frame.updateRendition(cell.renditions)
            frame.appendCell(cell)
            frameX += cell.width
            frame.cursorX += cell.width
            // Surface rule, as for any narrow cell drawn over a wide one (below).
            if surface && initialized && oldCells[0].wide && !cell.wide {
                redrawNext = true
            }
        }

        // If rows are the same object, we don't need to do anything at all.
        if initialized && row === oldRow {
            return false
        }

        let wrapThis = row.wrap
        let rowWidth = f.ds.width
        var clearCount = 0
        var wroteLastCell = false
        var blankRenditions = DisplayDiff.initialRendition

        // iterate for every cell
        while frameX < rowWidth {
            let cell = cells[frameX]

            // Does cell need to be drawn?  Skip all this.
            if initialized && clearCount == 0 && !redrawNext && cell == oldCells[frameX] {
                frameX += cell.width
                continue
            }
            redrawNext = false

            // Slurp up all the empty cells
            if cell.isEmpty {
                if clearCount == 0 {
                    blankRenditions = cell.renditions
                }
                if cell.renditions == blankRenditions {
                    // Remember run of blank cells
                    clearCount += 1
                    frameX += 1
                    continue
                }
            }

            // Clear or write cells within the row (not to end).
            if clearCount != 0 {
                // Move to the right position.
                frame.appendSilentMove(frameY, frameX - clearCount)
                frame.updateRendition(blankRenditions)
                let canUseErase = hasBCE || frame.currentRendition == DisplayDiff.initialRendition
                if canUseErase && hasECH && clearCount > 4 {
                    frame.append("\u{1B}[")
                    frame.append(decimal: clearCount)
                    frame.append(0x58) // X
                } else {
                    frame.append(count: clearCount, 0x20)
                    frame.cursorX = frameX
                }
                clearCount = 0
                // If the current character is *another* empty cell in a different
                // rendition, we restart counting and continue here
                if cell.isEmpty {
                    blankRenditions = cell.renditions
                    clearCount = 1
                    frameX += 1
                    continue
                }
            }

            // Now draw a character cell.
            // Move to the right position.
            let cellWidth = cell.width
            // If we are about to print the last character in a wrapping row, trash the
            // cursor position to force explicit positioning. We do this because our input
            // terminal state may have the cursor on the autowrap column ("column 81"),
            // but our output terminal states always snap the cursor to the true last
            // column ("column 80"), and we want to be able to apply the diff to either,
            // for verification.
            if wrapThis && frameX + cellWidth >= rowWidth {
                frame.cursorX = -1
                frame.cursorY = -1
            }
            if surface && !SurfaceFeed.isTrusted(cell) {
                // Surface rule: a guarded cell. The terminal may give the character
                // another width, or join it to its neighbour. Position explicitly before
                // and after it; erase its columns first, so that nothing stale stays if
                // the terminal draws it narrower; and at the right margin switch
                // autowrap off, so that a character the terminal thinks is wider is
                // dropped instead of wrapping (and scrolling the screen on the last row).
                frame.cursorX = -1
                frame.cursorY = -1
                frame.appendSilentMove(frameY, frameX)
                frame.updateRendition(cell.renditions)
                let atMargin = frameX + cellWidth >= rowWidth
                if frameX + cellWidth > rowWidth {
                    // A wide character in the last column (mosh can hold one; a real
                    // terminal would wrap it). It cannot be shown: leave a blank. It
                    // must not be sent either: the terminal would drop the character
                    // and join its combining characters to the cell on the left.
                    frame.append("\u{1B}[X")
                } else {
                    if atMargin {
                        frame.append("\u{1B}[?7l")
                    }
                    frame.append(cellWidth == 2 ? "\u{1B}[2X" : "\u{1B}[X")
                    SurfaceFeed.printGuarded(cell, into: &frame.str)
                    if atMargin {
                        frame.append("\u{1B}[?7h")
                    }
                }
                frameX += cellWidth
                frame.cursorX = -1
                frame.cursorY = -1
                redrawNext = true
                lastCellGuarded = true
            } else {
                if surface && initialized && oldCells[frameX].wide {
                    // Surface rule: a narrow cell over the left half of what was a wide
                    // character. The terminal turns the right half into a blank that
                    // keeps the wide character's pen; mosh's cell there is unchanged
                    // and would not be drawn.
                    redrawNext = true
                }
                frame.appendSilentMove(frameY, frameX)
                frame.updateRendition(cell.renditions)
                frame.appendCell(cell)
                frameX += cellWidth
                frame.cursorX += cellWidth
                lastCellGuarded = false
            }
            if frameX >= rowWidth {
                wroteLastCell = true
            }
        }

        // End of line.

        // Clear or write empty cells at EOL.
        if clearCount != 0 {
            // Move to the right position.
            frame.appendSilentMove(frameY, frameX - clearCount)
            frame.updateRendition(blankRenditions)

            let canUseErase = hasBCE || frame.currentRendition == DisplayDiff.initialRendition
            if canUseErase && !wrapThis {
                frame.append("\u{1B}[K")
            } else {
                frame.append(count: clearCount, 0x20)
                frame.cursorX = frameX
                wroteLastCell = true
                lastCellGuarded = false
            }
        }

        if !(wroteLastCell && frameY < f.ds.height - 1) {
            return false
        }
        // To hint that a word-select should group the end of one line with the beginning
        // of the next, we let the real cursor actually wrap around in cases where it
        // wrapped around for us.
        // Surface rule: autowrap is used only between two trusted cells. After a guarded
        // cell the terminal's column is not known, and the first character of the next
        // row must not join the last one of this row.
        let mayWrap = !surface || (!lastCellGuarded && SurfaceFeed.isTrusted(f.rows[frameY + 1].cells[0]))
        if wrapThis && mayWrap {
            // Update our cursor, and ask for wrap on the next row.
            frame.cursorX = 0
            frame.cursorY += 1
            return true
        }
        if frame.cursorY == -1 {
            // Surface rule (never the case for mosh's own output: the last cell was
            // written from a known position). The next thing drawn positions itself.
            return false
        }
        // Resort to CR/LF and update our cursor.
        frame.append(0x0D)
        frame.append(0x0A)
        frame.cursorX = 0
        frame.cursorY += 1
        return false
    }
}

/// mosh `Terminal::FrameState`: "variables used within a new_frame". The output so far
/// and what the receiving terminal's cursor, pen and cursor visibility are after it.
/// A cursor coordinate of -1 means "unknown", which forces an absolute move.
private struct FrameState {
    var str: [UInt8] = []
    var cursorX = 0
    var cursorY = 0
    var currentRendition = Renditions(background: 0)
    var cursorVisible: Bool

    init(last: Framebuffer) {
        cursorVisible = last.ds.cursorVisible
        // Preallocate for better performance. Make a guess -- doesn't matter for
        // correctness. (mosh reserves width * height * 4, which is far more than a
        // typical diff needs.)
        str.reserveCapacity(256)
    }

    mutating func append(_ c: UInt8) {
        str.append(c)
    }

    mutating func append(count: Int, _ c: UInt8) {
        if count > 0 {
            str.append(contentsOf: repeatElement(c, count: count))
        }
    }

    mutating func append(_ s: StaticString) {
        s.withUTF8Buffer { str.append(contentsOf: $0) }
    }

    /// A title or the clipboard: each code point in UTF-8 (mosh `append( wchar_t )`).
    mutating func append(codePoints: [UInt32]) {
        for c in codePoints {
            Cell.appendUTF8(c, to: &str)
        }
    }

    /// `snprintf( "%d" )`.
    mutating func append(decimal value: Int) {
        if value < 0 {
            str.append(0x2D)
        }
        var magnitude = value.magnitude
        if magnitude < 10 {
            str.append(UInt8(0x30 + magnitude))
            return
        }
        var digits: [UInt8] = []
        while magnitude > 0 {
            digits.append(UInt8(0x30 + magnitude % 10))
            magnitude /= 10
        }
        str.append(contentsOf: digits.reversed())
    }

    mutating func appendCell(_ cell: Cell) {
        cell.printGrapheme(into: &str)
    }

    /// mosh `FrameState::append_silent_move`: move, hiding the cursor first.
    mutating func appendSilentMove(_ y: Int, _ x: Int) {
        if cursorX == x && cursorY == y {
            return
        }
        // turn off cursor if necessary before moving cursor
        if cursorVisible {
            append("\u{1B}[?25l")
            cursorVisible = false
        }
        appendMove(y, x)
    }

    /// mosh `FrameState::append_move`.
    mutating func appendMove(_ y: Int, _ x: Int) {
        let lastX = cursorX
        let lastY = cursorY
        cursorX = x
        cursorY = y
        // Only optimize if cursor pos is known
        if lastX != -1 && lastY != -1 {
            // Can we use CR and/or LF?  They're cheap and easier to trace.
            if x == 0 && y - lastY >= 0 && y - lastY < 5 {
                if lastX != 0 {
                    append(0x0D)
                }
                append(count: y - lastY, 0x0A)
                return
            }
            // Backspaces are good too.
            if y == lastY && x - lastX < 0 && x - lastX > -5 {
                append(count: lastX - x, 0x08)
                return
            }
            // More optimizations are possible.
        }
        append("\u{1B}[")
        append(decimal: y + 1)
        append(0x3B)
        append(decimal: x + 1)
        append(0x48) // H
    }

    /// mosh `FrameState::update_rendition`.
    mutating func updateRendition(_ r: Renditions, force: Bool = false) {
        if force || currentRendition != r {
            // print renditions
            str.append(contentsOf: r.sgr().utf8)
            currentRendition = r
        }
    }
}

// MARK: - Complete::diff_from

/// What mosh's `Complete::diff_from` puts into a `HostMessage`, in the order of its
/// instructions: echo ack, resize, host bytes. A field is nil when the instruction is
/// absent. (This module does not depend on the wire format; the session layer turns
/// this into protobuf and back.)
public struct TerminalDiff: Equatable, Sendable {
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var echoAck: UInt64?
    public var resize: Size?
    public var hostBytes: [UInt8]?

    public init(echoAck: UInt64? = nil, resize: Size? = nil, hostBytes: [UInt8]? = nil) {
        self.echoAck = echoAck
        self.resize = resize
        self.hostBytes = hostBytes
    }

    /// No instruction at all (mosh then serializes an empty `HostMessage`).
    public var isEmpty: Bool {
        return echoAck == nil && resize == nil && hostBytes == nil
    }
}

extension TerminalState {
    /// mosh `Complete::diff_from( existing )`: the instructions that turn `existing`
    /// into this state.
    ///
    /// Like mosh, the framebuffers are compared with mosh's `operator==` (row objects by
    /// identity), and the host bytes are left out when `new_frame` produces nothing.
    /// mosh asserts that the echo ack does not go backwards; this port sends the new
    /// value whenever it differs.
    public func diff(from existing: TerminalState) -> TerminalDiff {
        var out = TerminalDiff()

        if existing.echoAck != echoAck {
            out.echoAck = echoAck
        }

        let fb = terminal.fb
        let existingFb = existing.terminal.fb
        if !existingFb.moshEquals(fb) {
            if existingFb.ds.width != fb.ds.width || existingFb.ds.height != fb.ds.height {
                out.resize = TerminalDiff.Size(width: fb.ds.width, height: fb.ds.height)
            }
            let update = DisplayDiff.newFrame(initialized: true, from: existingFb, to: fb)
            if !update.isEmpty {
                out.hostBytes = update
            }
        }

        return out
    }

    /// mosh `Complete::init_diff`: the diff from a new terminal of the same size.
    public func initDiff() -> TerminalDiff {
        return diff(from: TerminalState(width: terminal.fb.ds.width, height: terminal.fb.ds.height))
    }

    /// Apply a diff in the order mosh's `Complete::apply_string` meets the instructions
    /// that `diff_from` writes: echo ack, resize, host bytes. Returns the terminal's
    /// reply to the host, which is empty for anything `new_frame` wrote (mosh's client
    /// asserts that).
    @discardableResult
    public mutating func apply(_ diff: TerminalDiff) -> [UInt8] {
        var reply: [UInt8] = []
        if let n = diff.echoAck {
            applyEchoAck(n)
        }
        if let size = diff.resize {
            reply += resize(width: size.width, height: size.height)
        }
        if let bytes = diff.hostBytes {
            reply += act(bytes)
        }
        return reply
    }
}
