// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// The bytes the app gives to SwiftTerm so that SwiftTerm's screen shows a mosh
// framebuffer (docs/PLAN.md, Design 2, "Drawing").
//
// The feed is `DisplayDiff.newFrame` (the port of mosh's `Display::new_frame`, which is
// what a mosh client writes to its own terminal) with a few rules added. The rules are
// applied inside the writer (`DisplayDiff.surface`), not by rewriting its output:
// adding a cursor position after a character needs the writer's own idea of where the
// cursor is and what it will rely on next (autowrap, a carriage return, backspaces), and
// that is not recoverable from the bytes without parsing them again with a second
// terminal model. With the flag off the writer's output is mosh's, byte for byte, and
// the tests that compare it with mosh keep covering the shared code.
//
// The rules:
//
// 1. Trusted and guarded cells. SwiftTerm has its own width table and joins characters
//    into grapheme clusters by its own rules; mosh's cells follow glibc's `wcwidth`. A
//    cell is *trusted* when it is empty or holds one narrow character from the ranges in
//    `isTrustedNarrow` (ASCII and the common single-width blocks), which the tests check
//    scalar by scalar against SwiftTerm: width 1, never joined to a neighbour. Every
//    other cell is *guarded*: every wide character, every cell with a combining
//    character, and every narrow character outside those ranges. For a guarded cell the
//    feed
//      - positions the cursor explicitly before it and after it (so SwiftTerm starts a
//        new grapheme, and a different width cannot shift the rest of the row);
//      - erases the cell's columns first (if SwiftTerm draws the character narrower, or
//        attaches it to the cell on its left, nothing stale stays behind);
//      - always redraws the next cell (if SwiftTerm drew the character wider, it took
//        that cell; drawing it again gives it back, at the price of the wider
//        character, which SwiftTerm then blanks);
//      - switches autowrap off around it at the right margin (a character SwiftTerm
//        thinks does not fit is dropped; with autowrap on it would wrap, and scroll the
//        whole screen on the bottom row);
//      - never relies on autowrap after it: the next row starts with a cursor position.
//        The soft-wrap mark of such a row is not passed on to SwiftTerm;
//      - leaves out a variation selector that would make SwiftTerm change the cell's
//        width (`printGuarded`).
//    A wide character in the last column (mosh can hold one) is not sent at all: the
//    feed leaves a blank there. And a narrow cell drawn over the left half of what was
//    a wide character is followed by a redraw of the next cell, because SwiftTerm turns
//    the right half into a blank that keeps the wide character's pen.
// 2. The feed ends with an absolute cursor position whenever anything was drawn.
// 3. Title, bell and OSC 52 are not in the feed. The app reads `windowTitle`,
//    `iconName`, `bellCount` and `clipboard` from the framebuffer.
// 4. Mouse reporting and encoding, bracketed paste, focus events, cursor visibility and
//    reverse video are passed through as `new_frame` writes them, with two exceptions.
//    Focus events are written only when they change, also in a full repaint: SwiftTerm
//    answers every `ESC [ ? 1004 h` with a focus report for the host. Mouse mode 1001
//    (highlight tracking), which SwiftTerm does not have, is "off".
// 5. A full repaint (the first feed, after `invalidate()`, or when the size differs from
//    the last framebuffer shown) starts with `ESC [ ? 1 h` (application cursor keys, so
//    that SwiftTerm sends arrows as `ESC O A`..`D`; mosh's `Display::open`) and
//    `ESC [ ? 7 h` (autowrap, which the feed relies on), then `new_frame`'s own reset:
//    scrolling region, pen, clear screen, every cell, every mode.
// 6. Any newer framebuffer can follow any shown one; states in between need not be fed.
//
// The feed assumes that SwiftTerm receives nothing else: its origin mode, insert mode,
// margins and character sets stay at their defaults because the feed never changes
// them. It also assumes one `SurfaceFeed` per SwiftTerm terminal (a new terminal needs a
// new value), a terminal of the framebuffer's size, and SwiftTerm's option
// `regionalIndicatorWidth: .narrow` (glibc counts one column for a regional indicator;
// with SwiftTerm's default of two the feed still keeps the row intact, but the symbol
// is blanked).

/// Produces the bytes that take SwiftTerm from the last framebuffer it was given to the
/// next one. A value: copy it to try a feed without committing to it.
public struct SurfaceFeed: Sendable {
    /// The framebuffer SwiftTerm shows if every returned feed was passed to it; nil
    /// before the first feed.
    public private(set) var lastShown: Framebuffer?
    /// False when SwiftTerm's screen can no longer be assumed to show `lastShown`.
    public private(set) var isInitialized = false

    public init() {}

    /// What a full repaint starts with: application cursor keys and autowrap on.
    public static let fullRepaintPrefix: [UInt8] = Array("\u{1B}[?1h\u{1B}[?7h".utf8)

    private static let writer: DisplayDiff = {
        var d = DisplayDiff.server
        d.surface = true
        return d
    }()

    /// SwiftTerm's screen is no longer what was last fed (it resized its buffer: call
    /// this from `sizeChanged`). The next feed resets, clears and repaints everything.
    public mutating func invalidate() {
        isInitialized = false
    }

    /// True if the next feed to this framebuffer will be a full repaint.
    public func needsFullRepaint(to framebuffer: Framebuffer) -> Bool {
        guard isInitialized, let last = lastShown else { return true }
        return last.ds.width != framebuffer.ds.width || last.ds.height != framebuffer.ds.height
    }

    /// The bytes for SwiftTerm's `feed(byteArray:)` that make it show `framebuffer`.
    /// Empty when nothing visible changed. The framebuffer is remembered as shown.
    public mutating func feed(to framebuffer: Framebuffer) -> [UInt8] {
        let full = needsFullRepaint(to: framebuffer)
        // The modes SwiftTerm is in are those of the last framebuffer shown, also after
        // `invalidate()`: a resize does not change them.
        let last = lastShown ?? Framebuffer(width: framebuffer.ds.width, height: framebuffer.ds.height)
        var bytes: [UInt8] = []
        if full {
            bytes = SurfaceFeed.fullRepaintPrefix
        }
        bytes += SurfaceFeed.writer.newFrame(initialized: !full, from: last, to: framebuffer)
        lastShown = framebuffer
        isInitialized = true
        return bytes
    }

    // MARK: Trusted cells

    /// A cell the feed prints without guarding it (rule 1): empty, or one narrow
    /// character from `isTrustedNarrow`.
    static func isTrusted(_ cell: Cell) -> Bool {
        if cell.wide || cell.fallback { return false }
        let c = cell.contents
        switch c.count {
        case 0:
            return true
        case 1:
            return c[0] >= 0x20 && c[0] <= 0x7E
        case 2:
            let v = (UInt32(c[0] & 0x1F) << 6) | UInt32(c[1] & 0x3F)
            return c[0] & 0xE0 == 0xC0 && isTrustedNarrow(v)
        case 3:
            let v = (UInt32(c[0] & 0x0F) << 12) | (UInt32(c[1] & 0x3F) << 6) | UInt32(c[2] & 0x3F)
            return c[0] & 0xF0 == 0xE0 && isTrustedNarrow(v)
        default:
            return false
        }
    }

    /// Scalar values that are one column wide for glibc and for SwiftTerm and that
    /// SwiftTerm never joins to the character before them. `SurfaceFeedTests` checks
    /// every value of these ranges that the mosh model can put into a cell of its own.
    /// A range may contain unassigned or combining code points; those never are the only
    /// character of a cell that is not a fallback cell.
    public static func isTrustedNarrow(_ v: UInt32) -> Bool {
        for r in trustedNarrowRanges where r.contains(v) {
            return true
        }
        return false
    }

    /// See `isTrustedNarrow`.
    public static let trustedNarrowRanges: [ClosedRange<UInt32>] = [
        0x0020...0x007E, // ASCII
        0x00A1...0x00AC, // Latin-1 without the no-break space and the soft hyphen
        0x00AE...0x02FF, // Latin-1, Latin Extended-A and -B, IPA, modifier letters
        0x0370...0x03FF, // Greek
        0x0400...0x052F, // Cyrillic
        0x2010...0x2027, // dashes, quotation marks, bullets, ellipsis
        0x2030...0x205E, // per mille, primes, other punctuation
        0x2190...0x21FF, // arrows
        0x2500...0x259F, // box drawing, block elements
        0x2800...0x28FF, // Braille patterns
        0xE0A0...0xE0D4, // Powerline symbols (private use)
    ]

    /// What the feed writes for a guarded cell: `Cell.printGrapheme` without the
    /// variation selector that would make SwiftTerm change the width of the cell.
    /// SwiftTerm widens a one-column symbol to two columns when U+FE0F (emoji
    /// presentation) follows it, and narrows a two-column one when U+FE0E (text
    /// presentation) follows; glibc, and so the server's layout, does neither.
    static func printGuarded(_ cell: Cell, into output: inout [UInt8]) {
        // U+FE0E is EF B8 8E, U+FE0F is EF B8 8F.
        let selector: UInt8 = cell.wide ? 0x8E : 0x8F
        let c = cell.contents
        var hasSelector = false
        if c.count >= 4 {
            for i in 0..<(c.count - 2) where c[i] == 0xEF && c[i + 1] == 0xB8 && c[i + 2] == selector {
                hasSelector = true
                break
            }
        }
        if !hasSelector {
            cell.printGrapheme(into: &output)
            return
        }
        if cell.fallback {
            output.append(0xC2)
            output.append(0xA0)
        }
        var i = 0
        while i < c.count {
            if i + 2 < c.count && c[i] == 0xEF && c[i + 1] == 0xB8 && c[i + 2] == selector {
                i += 3
            } else {
                output.append(c[i])
                i += 1
            }
        }
    }

    // MARK: Text

    /// The screen as text, one string per row: an empty cell is a space, the column
    /// under the right half of a wide character is left out, a combining character
    /// without a base stands on a no-break space (as mosh draws it), trailing spaces
    /// are removed. For tests and for the app's screen-text accessibility hook.
    public static func visibleText(of framebuffer: Framebuffer) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(framebuffer.ds.height)
        var bytes: [UInt8] = []
        for row in framebuffer.rows.prefix(framebuffer.ds.height) {
            bytes.removeAll(keepingCapacity: true)
            let cells = row.cells
            var x = 0
            while x < cells.count {
                cells[x].printGrapheme(into: &bytes)
                x += cells[x].width
            }
            while bytes.last == 0x20 {
                bytes.removeLast()
            }
            lines.append(String(decoding: bytes, as: UTF8.self))
        }
        return lines
    }
}

/// The screen as text; see `SurfaceFeed.visibleText(of:)`.
public func visibleText(of framebuffer: Framebuffer) -> [String] {
    return SurfaceFeed.visibleText(of: framebuffer)
}
