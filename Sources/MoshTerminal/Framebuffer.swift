// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Framebuffer` (src/terminal/terminalframebuffer.{h,cc}).

/// A screen: rows of cells, the draw state, titles, clipboard and bell count.
///
/// A value type with cheap copies. A copy shares the array of row references; the first
/// write through one copy duplicates that array (one reference per line), and then only
/// the row that is written to (see `makeRowUnique`). This is mosh's own scheme
/// (`shared_ptr<Row>`, copied in `get_mutable_row` when `!unique()`), kept exactly
/// because mosh's `operator==` and `Display::new_frame` look at row identity.
///
/// Titles and the clipboard are sequences of code points (`std::vector<wchar_t>` in
/// mosh), not strings.
///
/// `==` is structural: all fields, cells compared by value, row identity and generation
/// numbers ignored. `moshEquals` is mosh's `operator==`.
public struct Framebuffer: Equatable, Sendable {
    public typealias Title = [UInt32]

    /// One reference per line. Lines can share a row object, also within one screen.
    public internal(set) var rows: [Row]
    public internal(set) var iconName: Title
    public internal(set) var windowTitle: Title
    public internal(set) var clipboard: Title
    /// `unsigned int` in mosh; wraps.
    public internal(set) var bellCount: UInt32
    /// True once an OSC has set the icon name or the window title.
    public internal(set) var titleInitialized: Bool
    public var ds: DrawState

    /// mosh `Framebuffer( s_width, s_height )`. All lines are one shared blank row.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "framebuffer size must be positive")
        iconName = []
        windowTitle = []
        clipboard = []
        bellCount = 0
        titleInitialized = false
        ds = DrawState(width: width, height: height)
        rows = Array(repeating: Row(width: width, backgroundColor: 0), count: height)
    }

    /// Rebuild from field values (serialization). `rows.count` must equal `ds.height`
    /// and every row must have `ds.width` cells.
    public init(rows: [Row], iconName: Title, windowTitle: Title, clipboard: Title,
                bellCount: UInt32, titleInitialized: Bool, ds: DrawState) {
        precondition(rows.count == ds.height && rows.allSatisfy { $0.cells.count == ds.width },
                     "rows do not match the draw state's size")
        self.rows = rows
        self.iconName = iconName
        self.windowTitle = windowTitle
        self.clipboard = clipboard
        self.bellCount = bellCount
        self.titleInitialized = titleInitialized
        self.ds = ds
    }

    // MARK: Row access

    private func newRow() -> Row {
        return Row(width: ds.width, backgroundColor: ds.backgroundRendition)
    }

    /// mosh `get_row( row )`; -1 means the cursor row.
    public func getRow(_ row: Int = -1) -> Row {
        return rows[row == -1 ? ds.cursorRow : row]
    }

    /// mosh `get_cell( row, col )`; -1 means the cursor position.
    public func getCell(_ row: Int = -1, _ col: Int = -1) -> Cell {
        let r = row == -1 ? ds.cursorRow : row
        let c = col == -1 ? ds.cursorCol : col
        return rows[r].cells[c]
    }

    /// mosh `get_mutable_row( row )`: if the row object has another owner, replace it by
    /// a copy. Returns the resolved row index. Callers then write through `rows[index]`
    /// and must not keep a reference to the row object across another call (a second
    /// owner would force a copy and the kept reference would be the stale one).
    ///
    /// Like mosh, this unshares the row even if nothing is written afterwards.
    @discardableResult
    mutating func makeRowUnique(_ row: Int = -1) -> Int {
        let r = row == -1 ? ds.cursorRow : row
        if !isKnownUniquelyReferenced(&rows[r]) {
            rows[r] = Row(copying: rows[r])
        }
        return r
    }

    /// mosh `get_mutable_cell( row, col )` (tfb:430-436): unshare the row (a copy keeps its
    /// generation, as mosh's copied `Row` does), then write the cell. -1 means the cursor
    /// row or column. The prediction overlay writes only through this, so it never reaches
    /// a row another framebuffer holds.
    @discardableResult
    mutating func withMutableCell<T>(_ row: Int, _ col: Int, _ body: (inout Cell) -> T) -> T {
        let r = makeRowUnique(row)
        let c = col == -1 ? ds.cursorCol : col
        return body(&rows[r].cells[c])
    }

    /// mosh `reset_cell( get_mutable_cell( row, col ) )`.
    mutating func resetCell(_ row: Int = -1, _ col: Int = -1) {
        let r = makeRowUnique(row)
        let c = col == -1 ? ds.cursorCol : col
        rows[r].cells[c].reset(backgroundColor: ds.backgroundRendition)
    }

    /// mosh `reset_row( get_mutable_row( row ) )`.
    mutating func resetRow(_ row: Int = -1) {
        let r = makeRowUnique(row)
        rows[r].reset(backgroundColor: ds.backgroundRendition)
    }

    // MARK: Scrolling

    /// mosh `scroll( N )`: positive moves the scrolling region's text up.
    public mutating func scroll(_ n: Int) {
        if n >= 0 {
            deleteLine(ds.scrollingRegionTopRow, n)
        } else {
            insertLine(ds.scrollingRegionTopRow, -n)
        }
    }

    /// mosh `move_rows_autoscroll( rows )`: move the cursor down (or up), scrolling the
    /// region when the cursor would leave it.
    public mutating func moveRowsAutoscroll(_ rows: Int) {
        // don't scroll if outside the scrolling region
        if ds.cursorRow < ds.scrollingRegionTopRow || ds.cursorRow > ds.scrollingRegionBottomRow {
            ds.moveRow(rows, relative: true)
            return
        }

        if ds.cursorRow + rows > ds.scrollingRegionBottomRow {
            let n = ds.cursorRow + rows - ds.scrollingRegionBottomRow
            scroll(n)
            ds.moveRow(-n, relative: true)
        } else if ds.cursorRow + rows < ds.scrollingRegionTopRow {
            let n = ds.cursorRow + rows - ds.scrollingRegionTopRow
            scroll(n)
            ds.moveRow(-n, relative: true)
        }

        ds.moveRow(rows, relative: true)
    }

    /// mosh `insert_line( before_row, count )`. The inserted lines are one shared row.
    public mutating func insertLine(_ beforeRow: Int, _ count: Int) {
        if beforeRow < ds.scrollingRegionTopRow || beforeRow > ds.scrollingRegionBottomRow + 1 {
            return
        }

        var scroll = ds.scrollingRegionBottomRow + 1 - beforeRow
        if count < scroll {
            scroll = count
        }

        if scroll == 0 {
            return
        }

        // delete old rows
        let start = ds.scrollingRegionBottomRow + 1 - scroll
        rows.removeSubrange(start..<(start + scroll))
        // insert new rows
        rows.insert(contentsOf: repeatElement(newRow(), count: scroll), at: beforeRow)
    }

    /// mosh `delete_line( row, count )`. The lines added at the bottom are one shared row.
    public mutating func deleteLine(_ row: Int, _ count: Int) {
        if row < ds.scrollingRegionTopRow || row > ds.scrollingRegionBottomRow {
            return
        }

        var scroll = ds.scrollingRegionBottomRow + 1 - row
        if count < scroll {
            scroll = count
        }

        if scroll == 0 {
            return
        }

        // delete old rows
        rows.removeSubrange(row..<(row + scroll))
        // insert a block of dummy rows
        let start = ds.scrollingRegionBottomRow + 1 - scroll
        rows.insert(contentsOf: repeatElement(newRow(), count: scroll), at: start)
    }

    // MARK: Cells

    /// mosh `insert_cell( row, col )`: shift right, the last cell falls off.
    public mutating func insertCell(_ row: Int, _ col: Int) {
        let r = makeRowUnique(row)
        rows[r].insertCell(col, backgroundColor: ds.backgroundRendition)
    }

    /// mosh `delete_cell( row, col )`: shift left, a blank cell enters at the end.
    public mutating func deleteCell(_ row: Int, _ col: Int) {
        let r = makeRowUnique(row)
        rows[r].deleteCell(col, backgroundColor: ds.backgroundRendition)
    }

    // MARK: Resets

    /// mosh `Framebuffer::reset` (RIS). Keeps the bell count, the icon name and
    /// `titleInitialized`; clears the window title and the clipboard.
    public mutating func reset() {
        let width = ds.width
        let height = ds.height
        ds = DrawState(width: width, height: height)
        rows = Array(repeating: newRow(), count: height)
        windowTitle.removeAll()
        clipboard.removeAll()
        // do not reset bell_count
    }

    /// mosh `Framebuffer::soft_reset` (DECSTR).
    public mutating func softReset() {
        ds.insertMode = false
        ds.originMode = false
        ds.cursorVisible = true // per xterm and gnome-terminal
        ds.applicationModeCursorKeys = false
        ds.setScrollingRegion(top: 0, bottom: ds.height - 1)
        ds.addRendition(0)
        ds.clearSavedCursor()
    }

    // MARK: Titles, clipboard, bell

    mutating func setTitleInitialized() { titleInitialized = true }
    mutating func setIconName(_ s: Title) { iconName = s }
    mutating func setWindowTitle(_ s: Title) { windowTitle = s }
    mutating func setClipboard(_ s: Title) { clipboard = s }

    /// mosh `prefix_window_title` (the client's "[mosh] " prefix while the network is
    /// down). The icon name gets the prefix too if it was equal to the title.
    public mutating func prefixWindowTitle(_ s: Title) {
        if iconName == windowTitle {
            // preserve equivalence
            iconName.insert(contentsOf: s, at: 0)
        }
        windowTitle.insert(contentsOf: s, at: 0)
    }

    mutating func ringBell() { bellCount &+= 1 }

    // MARK: Resize

    /// mosh `Framebuffer::resize`. Lines are cut or added at the bottom. On a width
    /// change every kept row is replaced by a copy (same generation) without its
    /// soft-wrap mark. A blank row is built in every case, so a generation number is
    /// used up even when nothing changes.
    public mutating func resize(width sWidth: Int, height sHeight: Int) {
        precondition(sWidth > 0 && sHeight > 0, "framebuffer size must be positive")

        let oldHeight = ds.height
        let oldWidth = ds.width
        ds.resize(width: sWidth, height: sHeight)

        let blankRow = newRow()
        if oldHeight != sHeight {
            if sHeight < rows.count {
                rows.removeLast(rows.count - sHeight)
            } else {
                rows.append(contentsOf: repeatElement(blankRow, count: sHeight - rows.count))
            }
        }
        if oldWidth == sWidth {
            return
        }
        var i = 0
        while i < rows.count && rows[i] !== blankRow {
            let copy = Row(copying: rows[i])
            copy.wrap = false
            let bg = ds.backgroundRendition
            if sWidth < copy.cells.count {
                copy.cells.removeLast(copy.cells.count - sWidth)
            } else {
                copy.cells.append(contentsOf: repeatElement(Cell(backgroundColor: bg), count: sWidth - copy.cells.count))
            }
            rows[i] = copy
            i += 1
        }
    }

    // MARK: Equality

    /// Structural equality over every field. Rows are compared cell by cell; whether two
    /// lines are the same object, and their generation numbers, are not compared.
    public static func == (a: Framebuffer, b: Framebuffer) -> Bool {
        if !(a.ds == b.ds && a.bellCount == b.bellCount && a.titleInitialized == b.titleInitialized
            && a.iconName == b.iconName && a.windowTitle == b.windowTitle && a.clipboard == b.clipboard
            && a.rows.count == b.rows.count) {
            return false
        }
        for i in a.rows.indices {
            let x = a.rows[i]
            let y = b.rows[i]
            if x !== y && x.cells != y.cells { return false }
        }
        return true
    }

    /// mosh `Framebuffer::operator==`: the *same row objects* line by line, equal window
    /// title, clipboard and bell count, and `DrawState::operator==`. The icon name and
    /// `title_initialized` are not compared. A framebuffer that was written to and
    /// restored to the same contents is not equal to its former self.
    public func moshEquals(_ x: Framebuffer) -> Bool {
        if rows.count != x.rows.count { return false }
        for i in rows.indices where rows[i] !== x.rows[i] { return false }
        return windowTitle == x.windowTitle && clipboard == x.clipboard
            && bellCount == x.bellCount && ds.moshEquals(x.ds)
    }
}
