// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::DrawState` and `Terminal::SavedCursor`
// (src/terminal/terminalframebuffer.{h,cc}).

/// mosh `SavedCursor`: what DECSC saves and DECRC restores.
public struct SavedCursor: Equatable, Sendable {
    public var cursorCol: Int
    public var cursorRow: Int
    public var renditions: Renditions
    public var autoWrapMode: Bool
    public var originMode: Bool

    public init() {
        cursorCol = 0
        cursorRow = 0
        renditions = Renditions(background: 0)
        autoWrapMode = true
        originMode = false
    }
}

/// mosh `DrawState::MouseReportingMode`. The raw value is the DEC private mode number.
public enum MouseReportingMode: Int, Sendable {
    case none = 0
    case x10 = 9
    case vt220 = 1000
    case vt220Hilight = 1001
    case btnEvent = 1002
    case anyEvent = 1003
}

/// mosh `DrawState::MouseEncodingMode`. The raw value is the DEC private mode number.
public enum MouseEncodingMode: Int, Sendable {
    case `default` = 0
    case utf8 = 1005
    case sgr = 1006
    case urxvt = 1015
}

/// Cursor, pen, tabs, scrolling region and modes: everything in a framebuffer that is
/// not cells or titles. All fields of mosh's `DrawState` are here, including the ones
/// its `operator==` ignores.
///
/// Synthesized `==` compares every field. `moshEquals` is mosh's `operator==`.
public struct DrawState: Equatable, Sendable {
    public internal(set) var width: Int
    public internal(set) var height: Int

    public internal(set) var cursorCol: Int
    public internal(set) var cursorRow: Int
    /// The cell that receives the next combining character. (-1, -1) after a resize
    /// that left it off screen.
    public internal(set) var combiningCharCol: Int
    public internal(set) var combiningCharRow: Int

    /// True until TBC 3 (`CSI 3 g`). While true, a resize gives new columns the default
    /// stops at every eighth column.
    public internal(set) var defaultTabs: Bool
    public internal(set) var tabs: [Bool]

    public internal(set) var scrollingRegionTopRow: Int
    public internal(set) var scrollingRegionBottomRow: Int

    /// The pen. A diff starts from the pen of its base state.
    public internal(set) var renditions: Renditions

    public internal(set) var save: SavedCursor

    public var nextPrintWillWrap: Bool
    public var originMode: Bool
    public var autoWrapMode: Bool
    public var insertMode: Bool
    public var cursorVisible: Bool
    public var reverseVideo: Bool
    public var bracketedPaste: Bool
    public var mouseReportingMode: MouseReportingMode
    public var mouseFocusEvent: Bool // 1004
    public var mouseAlternateScroll: Bool // 1007
    public var mouseEncodingMode: MouseEncodingMode
    public var applicationModeCursorKeys: Bool

    /// mosh `DrawState( s_width, s_height )`.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cursorCol = 0
        cursorRow = 0
        combiningCharCol = 0
        combiningCharRow = 0
        defaultTabs = true
        tabs = Array(repeating: false, count: width)
        scrollingRegionTopRow = 0
        scrollingRegionBottomRow = height - 1
        renditions = Renditions(background: 0)
        save = SavedCursor()
        nextPrintWillWrap = false
        originMode = false
        autoWrapMode = true
        insertMode = false
        cursorVisible = true
        reverseVideo = false
        bracketedPaste = false
        mouseReportingMode = .none
        mouseFocusEvent = false
        mouseAlternateScroll = false
        mouseEncodingMode = .default
        applicationModeCursorKeys = false
        reinitializeTabs(0)
    }

    private mutating func reinitializeTabs(_ start: Int) {
        // mosh asserts default_tabs here.
        var i = start
        while i < tabs.count {
            tabs[i] = (i % 8) == 0
            i += 1
        }
    }

    private mutating func newGrapheme() {
        combiningCharCol = cursorCol
        combiningCharRow = cursorRow
    }

    private mutating func snapCursorToBorder() {
        if cursorRow < limitTop { cursorRow = limitTop }
        if cursorRow > limitBottom { cursorRow = limitBottom }
        if cursorCol < 0 { cursorCol = 0 }
        if cursorCol >= width { cursorCol = width - 1 }
    }

    /// mosh `move_row( N, relative )`. An absolute row counts from `limitTop`.
    public mutating func moveRow(_ n: Int, relative: Bool = false) {
        if relative {
            cursorRow += n
        } else {
            cursorRow = n + limitTop
        }

        snapCursorToBorder()
        newGrapheme()
        nextPrintWillWrap = false
    }

    /// mosh `move_col( N, relative, implicit )`. `implicit` is the move a printed
    /// character makes: it may leave the wrap flag set.
    public mutating func moveCol(_ n: Int, relative: Bool = false, implicit: Bool = false) {
        if implicit {
            newGrapheme()
        }

        if relative {
            cursorCol += n
        } else {
            cursorCol = n
        }

        if implicit {
            nextPrintWillWrap = (cursorCol >= width)
        }

        snapCursorToBorder()
        if !implicit {
            newGrapheme()
            nextPrintWillWrap = false
        }
    }

    /// mosh `set_tab`: a stop at the cursor column.
    public mutating func setTab() {
        tabs[cursorCol] = true
    }

    public mutating func clearTab(_ col: Int) {
        tabs[col] = false
    }

    /// Default tabs cannot be restored without resetting the draw state.
    public mutating func clearDefaultTabs() {
        defaultTabs = false
    }

    /// mosh `get_next_tab( count )`: the column of the `count`-th stop after the cursor
    /// (-1 if there is none), or for a negative count the stop before it (0 if none).
    public func getNextTab(_ count: Int) -> Int {
        var count = count
        if count >= 0 {
            var i = cursorCol + 1
            while i < width {
                if tabs[i] {
                    count -= 1
                    if count == 0 { return i }
                }
                i += 1
            }
            return -1
        }
        var i = cursorCol - 1
        while i > 0 {
            if tabs[i] {
                count += 1
                if count == 0 { return i }
            }
            i -= 1
        }
        return 0
    }

    /// mosh `set_scrolling_region( top, bottom )`, zero-based and inclusive.
    public mutating func setScrollingRegion(top: Int, bottom: Int) {
        if height < 1 {
            return
        }

        scrollingRegionTopRow = top
        scrollingRegionBottomRow = bottom

        if scrollingRegionTopRow < 0 { scrollingRegionTopRow = 0 }
        if scrollingRegionBottomRow >= height { scrollingRegionBottomRow = height - 1 }

        if scrollingRegionBottomRow < scrollingRegionTopRow {
            scrollingRegionBottomRow = scrollingRegionTopRow
        }
        // real rule requires TWO-line scrolling region

        if originMode {
            snapCursorToBorder()
            newGrapheme()
        }
    }

    public var limitTop: Int {
        return originMode ? scrollingRegionTopRow : 0
    }

    public var limitBottom: Int {
        return originMode ? scrollingRegionBottomRow : height - 1
    }

    public mutating func setForegroundColor(_ x: UInt32) { renditions.setForegroundColor(x) }
    public mutating func setBackgroundColor(_ x: UInt32) { renditions.setBackgroundColor(x) }
    public mutating func addRendition(_ x: UInt32) { renditions.setRendition(x) }
    /// mosh `get_background_rendition`: the background erased cells take.
    public var backgroundRendition: UInt32 { return renditions.backgroundColor }

    /// mosh `save_cursor` (DECSC).
    public mutating func saveCursor() {
        save.cursorCol = cursorCol
        save.cursorRow = cursorRow
        save.renditions = renditions
        save.autoWrapMode = autoWrapMode
        save.originMode = originMode
    }

    /// mosh `restore_cursor` (DECRC). Does not touch the wrap flag.
    public mutating func restoreCursor() {
        cursorCol = save.cursorCol
        cursorRow = save.cursorRow
        renditions = save.renditions
        autoWrapMode = save.autoWrapMode
        originMode = save.originMode

        snapCursorToBorder() // we could have resized in between
        newGrapheme()
    }

    public mutating func clearSavedCursor() {
        save = SavedCursor()
    }

    /// mosh `DrawState::resize`.
    mutating func resize(width sWidth: Int, height sHeight: Int) {
        if width != sWidth || height != sHeight {
            // reset entire scrolling region on any resize
            scrollingRegionTopRow = 0
            scrollingRegionBottomRow = sHeight - 1
        }

        // tabs.resize( s_width )
        if sWidth < tabs.count {
            tabs.removeLast(tabs.count - sWidth)
        } else if sWidth > tabs.count {
            tabs.append(contentsOf: repeatElement(false, count: sWidth - tabs.count))
        }
        if defaultTabs {
            reinitializeTabs(width)
        }

        width = sWidth
        height = sHeight

        snapCursorToBorder()

        // saved cursor will be snapped to border on restore

        // invalidate combining char cell if necessary
        if combiningCharCol >= width || combiningCharRow >= height {
            combiningCharCol = -1
            combiningCharRow = -1
        }
    }

    /// mosh `DrawState::operator==`: "only compare fields that affect display".
    /// Not compared: combining cell, tabs, scrolling region, saved cursor, wrap flag,
    /// origin, autowrap and insert modes, application cursor keys.
    public func moshEquals(_ x: DrawState) -> Bool {
        return width == x.width && height == x.height && cursorCol == x.cursorCol
            && cursorRow == x.cursorRow && cursorVisible == x.cursorVisible
            && reverseVideo == x.reverseVideo && renditions == x.renditions
            && bracketedPaste == x.bracketedPaste && mouseReportingMode == x.mouseReportingMode
            && mouseFocusEvent == x.mouseFocusEvent && mouseAlternateScroll == x.mouseAlternateScroll
            && mouseEncodingMode == x.mouseEncodingMode
    }
}
