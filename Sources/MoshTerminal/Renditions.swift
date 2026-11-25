// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Renditions` (src/terminal/terminalframebuffer.{h,cc}).

/// The pen: colours and attributes of a cell or of the draw state.
///
/// Colour encoding, exactly as mosh stores it in two 25-bit bit-fields:
///  - `0`: default colour.
///  - foreground `30...37`, background `40...47`: the eight ANSI colours.
///  - foreground `30 + n`, background `40 + n` for `n` in `0...255`: the 256-colour
///    palette. Indices 0...7 are therefore the same values as the ANSI colours, and the
///    bright colours (SGR 90...97, 100...107) are stored as palette indices 8...15.
///  - bit 24 set (`trueColorMask`): 24-bit colour, `0x1RRGGBB`.
public struct Renditions: Equatable, Hashable, Sendable {
    /// mosh `Renditions::attribute_type`. The raw value is the bit number in `attributes`.
    /// `faint` exists in mosh's enum but nothing ever sets it.
    public enum Attribute: UInt8, CaseIterable, Sendable {
        case bold = 0, faint, italic, underlined, blink, inverse, invisible
    }

    public static let trueColorMask: UInt32 = 0x100_0000
    /// Both colour fields are `uint64_t : 25` bit-fields in mosh. Assignments truncate.
    public static let colorFieldMask: UInt32 = 0x1FF_FFFF

    /// Raw 25-bit value, see the type's documentation.
    public var foregroundColor: UInt32
    /// Raw 25-bit value, see the type's documentation.
    public var backgroundColor: UInt32
    /// Bit set indexed by `Attribute.rawValue`.
    public var attributes: UInt8

    /// mosh `Renditions( color_type s_background )`: default foreground, the given
    /// background, no attributes. Erased cells are built with this (background colour erase).
    public init(background: UInt32) {
        foregroundColor = 0
        backgroundColor = background & Renditions.colorFieldMask
        attributes = 0
    }

    /// Rebuild from raw field values (serialization).
    public init(rawForeground: UInt32, rawBackground: UInt32, rawAttributes: UInt8) {
        foregroundColor = rawForeground & Renditions.colorFieldMask
        backgroundColor = rawBackground & Renditions.colorFieldMask
        attributes = rawAttributes
    }

    public static func makeTrueColor(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 {
        // `true_color_mask | (r << 16) | (g << 8) | b` on 32-bit unsigned ints. The
        // components are not clamped to 255 by mosh; out-of-range values smear into the
        // neighbouring component and the top bits are later lost in the 25-bit field.
        return trueColorMask | (r &<< 16) | (g &<< 8) | b
    }

    public static func isTrueColor(_ color: UInt32) -> Bool {
        return (color & trueColorMask) != 0
    }

    /// mosh `set_foreground_color( int num )`. `num` is the bit pattern of mosh's `int`:
    /// a palette index `0...255`, or a value from `makeTrueColor`. Anything else is ignored.
    public mutating func setForegroundColor(_ num: UInt32) {
        // `(0 <= num) && (num <= 255)` on a signed int: a pattern with bit 31 set is
        // negative there and above 255 here, so both tests agree.
        if num <= 255 {
            foregroundColor = 30 + num
        } else if Renditions.isTrueColor(num) {
            foregroundColor = num & Renditions.colorFieldMask
        }
    }

    /// mosh `set_background_color( int num )`.
    public mutating func setBackgroundColor(_ num: UInt32) {
        if num <= 255 {
            backgroundColor = 40 + num
        } else if Renditions.isTrueColor(num) {
            backgroundColor = num & Renditions.colorFieldMask
        }
    }

    /// mosh `set_rendition( color_type num )`: one SGR parameter outside the 38/48 forms.
    public mutating func setRendition(_ num: UInt32) {
        if num == 0 {
            clearAttributes()
            foregroundColor = 0
            backgroundColor = 0
            return
        }

        if num == 39 {
            foregroundColor = 0
            return
        } else if num == 49 {
            backgroundColor = 0
            return
        }

        if 30 <= num && num <= 37 { // foreground colour in 8-colour set
            foregroundColor = num
            return
        } else if 40 <= num && num <= 47 { // background colour in 8-colour set
            backgroundColor = num
            return
        } else if 90 <= num && num <= 97 { // foreground colour in 16-colour set
            foregroundColor = num - 90 + 38
            return
        } else if 100 <= num && num <= 107 { // background colour in 16-colour set
            backgroundColor = num - 100 + 48
            return
        }

        let value = num < 9
        switch num {
        case 1, 22: setAttribute(.bold, value)
        case 3, 23: setAttribute(.italic, value)
        case 4, 24: setAttribute(.underlined, value)
        case 5, 25: setAttribute(.blink, value)
        case 7, 27: setAttribute(.inverse, value)
        case 8, 28: setAttribute(.invisible, value)
        default: break // ignore unknown rendition
        }
    }

    public mutating func setAttribute(_ attr: Attribute, _ val: Bool) {
        if val {
            attributes |= (1 << attr.rawValue)
        } else {
            attributes &= ~(1 << attr.rawValue)
        }
    }

    public func getAttribute(_ attr: Attribute) -> Bool {
        return attributes & (1 << attr.rawValue) != 0
    }

    public mutating func clearAttributes() {
        attributes = 0
    }

    /// mosh `Renditions::sgr()`: the escape sequence that selects this pen from any pen.
    /// Always starts with a reset. ASCII only.
    public func sgr() -> String {
        var ret = "\u{1B}[0"
        if getAttribute(.bold) { ret += ";1" }
        if getAttribute(.italic) { ret += ";3" }
        if getAttribute(.underlined) { ret += ";4" }
        if getAttribute(.blink) { ret += ";5" }
        if getAttribute(.inverse) { ret += ";7" }
        if getAttribute(.invisible) { ret += ";8" }

        if foregroundColor != 0 {
            if Renditions.isTrueColor(foregroundColor) {
                ret += ";38;2;\((foregroundColor >> 16) & 0xff);\((foregroundColor >> 8) & 0xff);\(foregroundColor & 0xff)"
            } else if foregroundColor > 37 { // use 256-colour set
                ret += ";38;5;\(foregroundColor - 30)"
            } else { // ANSI foreground colour
                ret += ";\(foregroundColor)"
            }
        }
        if backgroundColor != 0 {
            if Renditions.isTrueColor(backgroundColor) {
                ret += ";48;2;\((backgroundColor >> 16) & 0xff);\((backgroundColor >> 8) & 0xff);\(backgroundColor & 0xff)"
            } else if backgroundColor > 47 { // use 256-colour set
                ret += ";48;5;\(backgroundColor - 40)"
            } else { // ANSI background colour
                ret += ";\(backgroundColor)"
            }
        }
        ret += "m"
        return ret
    }
}
