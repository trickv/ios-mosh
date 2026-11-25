// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Cell` and `Terminal::Row`
// (src/terminal/terminalframebuffer.{h,cc}).

import Foundation // NSLock for the generation counter

/// One character cell.
///
/// `contents` is the UTF-8 encoding of the base character followed by its combining
/// characters, as mosh stores it in a `std::string`. It is compared byte-wise. Never
/// turn it into a `String` to compare: `String ==` uses canonical equivalence.
public struct Cell: Equatable, Sendable {
    public var contents: [UInt8]
    public var renditions: Renditions
    /// The cell holds a double-width character. The cell to its right is an ordinary
    /// blank cell that drawing skips; mosh keeps no continuation marker.
    public var wide: Bool
    /// The first character is a combining character (drawn on a no-break space).
    public var fallback: Bool
    /// Soft-wrap mark. mosh keeps it in the *last cell* of a row (`Row::get_wrap`), but
    /// every cell has the bit: `Row::delete_cell` can move a set bit to another column.
    public var wrap: Bool

    /// mosh `Cell( color_type background_color )`.
    public init(backgroundColor: UInt32) {
        contents = []
        renditions = Renditions(background: backgroundColor)
        wide = false
        fallback = false
        wrap = false
    }

    /// Rebuild from field values (serialization).
    public init(contents: [UInt8], renditions: Renditions, wide: Bool, fallback: Bool, wrap: Bool) {
        self.contents = contents
        self.renditions = renditions
        self.wide = wide
        self.fallback = fallback
        self.wrap = wrap
    }

    /// mosh `Cell::reset`.
    public mutating func reset(backgroundColor: UInt32) {
        contents.removeAll(keepingCapacity: false)
        renditions = Renditions(background: backgroundColor)
        wide = false
        fallback = false
        wrap = false
    }

    public var isEmpty: Bool { return contents.isEmpty }

    /// mosh `Cell::full`: "32 seems like a reasonable limit on combining characters".
    /// The limit is in bytes and is checked before an append, so contents can reach 35.
    public var isFull: Bool { return contents.count >= 32 }

    /// mosh `Cell::is_blank`: empty, a space, or a no-break space.
    public var isBlank: Bool {
        return contents.isEmpty || contents == [0x20] || contents == [0xC2, 0xA0]
    }

    /// mosh `Cell::contents_match`.
    public func contentsMatch(_ other: Cell) -> Bool {
        return (isBlank && other.isBlank) || contents == other.contents
    }

    /// Number of columns the cell covers: mosh `Cell::get_width`.
    public var width: Int { return wide ? 2 : 1 }

    /// mosh `Cell::append( wchar_t )`: append the UTF-8 form of `c`, as glibc's `wcrtomb`
    /// writes it in a UTF-8 locale. The parser only delivers Unicode scalar values.
    public mutating func append(_ c: UInt32) {
        Cell.appendUTF8(c, to: &contents)
    }

    /// mosh `Cell::append_to_str`.
    public static func appendUTF8(_ c: UInt32, to dest: inout [UInt8]) {
        if c <= 0x7F {
            dest.append(UInt8(c))
        } else if c <= 0x7FF {
            dest.append(UInt8(0xC0 | (c >> 6)))
            dest.append(UInt8(0x80 | (c & 0x3F)))
        } else if c <= 0xFFFF {
            dest.append(UInt8(0xE0 | (c >> 12)))
            dest.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            dest.append(UInt8(0x80 | (c & 0x3F)))
        } else {
            dest.append(UInt8(0xF0 | ((c >> 18) & 0x07)))
            dest.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
            dest.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            dest.append(UInt8(0x80 | (c & 0x3F)))
        }
    }

    /// mosh `Cell::print_grapheme`: what the display writes for this cell. An empty cell
    /// is a space; a fallback cell gets a no-break space before its combining characters.
    public func printGrapheme(into output: inout [UInt8]) {
        if contents.isEmpty {
            output.append(0x20)
            return
        }
        if fallback {
            output.append(0xC2)
            output.append(0xA0)
        }
        output.append(contentsOf: contents)
    }

    /// mosh `Cell::isprint_iso8859_1`.
    public static func isPrintISO8859_1(_ c: UInt32) -> Bool {
        return (c <= 0xFF && c >= 0xA0) || (c <= 0x7E && c >= 0x20)
    }

    /// mosh `Cell::compare`: true if the cells differ in a way mosh's own verification
    /// counts (grapheme, width, renditions, wrap; not fallback alone). mosh also prints
    /// the difference to stderr; this port does not.
    public func compare(_ other: Cell) -> Bool {
        var ret = false
        var grapheme: [UInt8] = []
        var otherGrapheme: [UInt8] = []
        printGrapheme(into: &grapheme)
        other.printGrapheme(into: &otherGrapheme)
        if grapheme != otherGrapheme { ret = true }
        if wide != other.wide { ret = true }
        if renditions != other.renditions { ret = true }
        if wrap != other.wrap { ret = true }
        return ret
    }
}

/// mosh `Row::get_gen`: a process-wide counter. Every newly built row and every
/// `Row.reset` takes the next value; a copy keeps the value of its source. mosh's
/// `Row::operator==` requires equal generations, so two rows with equal cells but
/// different histories are *not* equal for `Display::new_frame`'s scroll detection.
///
/// Only the equality pattern of generations is meaningful. The numbers themselves depend
/// on everything the process did before.
public enum RowGeneration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    /// The next unused generation number.
    public static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let g = counter
        counter &+= 1
        return g
    }

    /// Make sure numbers handed out from now on are above `floor` (for a loader that
    /// restores rows with their saved generations).
    public static func reserve(through floor: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if counter <= floor { counter = floor &+ 1 }
    }
}

/// One screen row: mosh `Terminal::Row`, held through `shared_ptr<Row>` there.
///
/// A row object is shared between framebuffer copies (and between several lines of one
/// framebuffer: all lines of a new or reset screen are the same object). `Framebuffer`
/// copies a row before writing to it when it is not the only owner, like mosh's
/// `get_mutable_row`. Object identity (`===`) is therefore mosh's row pointer equality.
///
/// The class is immutable from outside this module. Inside, it is only mutated through
/// a `Framebuffer` that has checked it is the sole owner, which is what makes the
/// `@unchecked Sendable` sound (the usual copy-on-write argument).
public final class Row: @unchecked Sendable {
    public internal(set) var cells: [Cell]
    /// Generation number, see `RowGeneration`.
    public internal(set) var gen: UInt64

    /// mosh `Row( s_width, background_color )`: a blank row with a new generation.
    public init(width: Int, backgroundColor: UInt32) {
        cells = Array(repeating: Cell(backgroundColor: backgroundColor), count: width)
        gen = RowGeneration.next()
    }

    /// mosh's implicit copy constructor: same cells, same generation, new identity.
    public init(copying other: Row) {
        cells = other.cells
        gen = other.gen
    }

    /// Rebuild from field values (serialization). Call `RowGeneration.reserve` with the
    /// largest restored generation so that new rows stay distinct.
    public init(cells: [Cell], gen: UInt64) {
        self.cells = cells
        self.gen = gen
    }

    /// mosh `Row::insert_cell`.
    func insertCell(_ col: Int, backgroundColor: UInt32) {
        cells.insert(Cell(backgroundColor: backgroundColor), at: col)
        cells.removeLast()
    }

    /// mosh `Row::delete_cell`. The old last cell, soft-wrap bit included, moves left.
    func deleteCell(_ col: Int, backgroundColor: UInt32) {
        cells.append(Cell(backgroundColor: backgroundColor))
        cells.remove(at: col)
    }

    /// mosh `Row::reset`: takes a new generation.
    func reset(backgroundColor: UInt32) {
        gen = RowGeneration.next()
        for i in cells.indices {
            cells[i].reset(backgroundColor: backgroundColor)
        }
    }

    /// mosh `Row::get_wrap` / `set_wrap`: the soft-wrap bit of the last cell.
    public internal(set) var wrap: Bool {
        get { return cells[cells.count - 1].wrap }
        set { cells[cells.count - 1].wrap = newValue }
    }

    /// mosh `Row::operator==`: same generation and equal cells.
    public func moshEquals(_ x: Row) -> Bool {
        return gen == x.gen && cells == x.cells
    }
}
