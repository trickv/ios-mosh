// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 src/terminal/parser.{cc,h}, parserstate.{cc,h},
// parserstatefamily.h, parsertransition.h and parseraction.{cc,h}.
//
// The state machine is Paul Williams's DEC ANSI parser as mosh implements it, with
// mosh's deviations kept:
//  - every code point from U+00A0 up is classified like 'A' (0x41) in every state, so
//    it prints in Ground, is an OSC character in an OSC string, and *terminates* a CSI
//    or an ESC sequence (as an unknown final character);
//  - C1 controls U+0080...U+009F act from any state ("anywhere" rule);
//  - an OSC string ends at BEL, ST (U+009C) or any anywhere transition (ESC, CAN, ...).

/// mosh's parser actions (`Parser::Action` subclasses). `ignore` is never delivered.
public enum ParserActionKind: UInt8, Sendable, CaseIterable {
    case ignore
    case print
    case execute
    case clear
    case collect
    case param
    case escDispatch
    case csiDispatch
    case hook
    case put
    case unhook
    case oscStart
    case oscPut
    case oscEnd

    /// mosh `Action::name()`.
    public var name: String {
        switch self {
        case .ignore: return "Ignore"
        case .print: return "Print"
        case .execute: return "Execute"
        case .clear: return "Clear"
        case .collect: return "Collect"
        case .param: return "Param"
        case .escDispatch: return "Esc_Dispatch"
        case .csiDispatch: return "CSI_Dispatch"
        case .hook: return "Hook"
        case .put: return "Put"
        case .unhook: return "Unhook"
        case .oscStart: return "OSC_Start"
        case .oscPut: return "OSC_Put"
        case .oscEnd: return "OSC_End"
        }
    }
}

/// One action with the character that caused it. Entry and exit actions of a state
/// (`clear`, `hook`, `unhook`, `oscStart`, `oscEnd`) carry no character:
/// `charPresent` is false and `ch` is `ParserAction.noChar` (mosh's `ch = -1`).
public struct ParserAction: Equatable, Sendable {
    public static let noChar: UInt32 = 0xFFFF_FFFF

    public var kind: ParserActionKind
    public var ch: UInt32
    public var charPresent: Bool

    public init(_ kind: ParserActionKind, ch: UInt32) {
        self.kind = kind
        self.ch = ch
        self.charPresent = true
    }

    public init(_ kind: ParserActionKind) {
        self.kind = kind
        self.ch = ParserAction.noChar
        self.charPresent = false
    }
}

/// The parser states (`Parser::StateFamily`).
public enum ParserState: UInt8, Sendable, CaseIterable {
    case ground
    case escape
    case escapeIntermediate
    case csiEntry
    case csiParam
    case csiIntermediate
    case csiIgnore
    case dcsEntry
    case dcsParam
    case dcsIntermediate
    case dcsPassthrough
    case dcsIgnore
    case oscString
    case sosPmApcString

    /// The name of mosh's state class.
    public var name: String {
        switch self {
        case .ground: return "Ground"
        case .escape: return "Escape"
        case .escapeIntermediate: return "Escape_Intermediate"
        case .csiEntry: return "CSI_Entry"
        case .csiParam: return "CSI_Param"
        case .csiIntermediate: return "CSI_Intermediate"
        case .csiIgnore: return "CSI_Ignore"
        case .dcsEntry: return "DCS_Entry"
        case .dcsParam: return "DCS_Param"
        case .dcsIntermediate: return "DCS_Intermediate"
        case .dcsPassthrough: return "DCS_Passthrough"
        case .dcsIgnore: return "DCS_Ignore"
        case .oscString: return "OSC_String"
        case .sosPmApcString: return "SOS_PM_APC_String"
        }
    }

    /// mosh `State::enter()`.
    var enterAction: ParserActionKind {
        switch self {
        case .escape, .csiEntry, .dcsEntry: return .clear
        case .dcsPassthrough: return .hook
        case .oscString: return .oscStart
        default: return .ignore
        }
    }

    /// mosh `State::exit()`.
    var exitAction: ParserActionKind {
        switch self {
        case .dcsPassthrough: return .unhook
        case .oscString: return .oscEnd
        default: return .ignore
        }
    }
}

/// mosh `Parser::Transition`: an action and an optional new state.
struct ParserTransition {
    var action: ParserActionKind
    var nextState: ParserState?

    init(_ action: ParserActionKind = .ignore, _ nextState: ParserState? = nil) {
        self.action = action
        self.nextState = nextState
    }
}

/// What one character does: up to three actions, in order (exit of the old state, the
/// transition's action, entry of the new state). `ignore` entries are to be skipped.
struct ParserStep {
    var exit: ParserActionKind = .ignore
    var action: ParserActionKind = .ignore
    var enter: ParserActionKind = .ignore
}

/// mosh `Parser::Parser`: the state machine over wide characters.
public struct Parser: Equatable, Sendable {
    public internal(set) var state: ParserState = .ground

    public init() {}

    /// mosh `State::anywhere_rule`.
    private static func anywhereRule(_ ch: UInt32) -> ParserTransition {
        if ch == 0x18 || ch == 0x1A
            || (0x80 <= ch && ch <= 0x8F)
            || (0x91 <= ch && ch <= 0x97)
            || ch == 0x99 || ch == 0x9A {
            return ParserTransition(.execute, .ground)
        } else if ch == 0x9C {
            return ParserTransition(.ignore, .ground)
        } else if ch == 0x1B {
            return ParserTransition(.ignore, .escape)
        } else if ch == 0x98 || ch == 0x9E || ch == 0x9F {
            return ParserTransition(.ignore, .sosPmApcString)
        } else if ch == 0x90 {
            return ParserTransition(.ignore, .dcsEntry)
        } else if ch == 0x9D {
            return ParserTransition(.ignore, .oscString)
        } else if ch == 0x9B {
            return ParserTransition(.ignore, .csiEntry)
        }
        return ParserTransition()
    }

    private static func c0Prime(_ ch: UInt32) -> Bool {
        return ch <= 0x17 || ch == 0x19 || (0x1C <= ch && ch <= 0x1F)
    }

    private static func glgr(_ ch: UInt32) -> Bool {
        return (0x20 <= ch && ch <= 0x7F) // GL area
            || (0xA0 <= ch && ch <= 0xFF) // GR area
    }

    /// mosh `<State>::input_state_rule`, one case per state class.
    private static func inputStateRule(_ state: ParserState, _ ch: UInt32) -> ParserTransition {
        switch state {
        case .ground:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if glgr(ch) { return ParserTransition(.print) }
            return ParserTransition()

        case .escape:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect, .escapeIntermediate) }
            if (0x30 <= ch && ch <= 0x4F)
                || (0x51 <= ch && ch <= 0x57)
                || ch == 0x59
                || ch == 0x5A
                || ch == 0x5C
                || (0x60 <= ch && ch <= 0x7E) {
                return ParserTransition(.escDispatch, .ground)
            }
            if ch == 0x5B { return ParserTransition(.ignore, .csiEntry) }
            if ch == 0x5D { return ParserTransition(.ignore, .oscString) }
            if ch == 0x50 { return ParserTransition(.ignore, .dcsEntry) }
            if ch == 0x58 || ch == 0x5E || ch == 0x5F { return ParserTransition(.ignore, .sosPmApcString) }
            return ParserTransition()

        case .escapeIntermediate:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect) }
            if 0x30 <= ch && ch <= 0x7E { return ParserTransition(.escDispatch, .ground) }
            return ParserTransition()

        case .csiEntry:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.csiDispatch, .ground) }
            if (0x30 <= ch && ch <= 0x39) || ch == 0x3B { return ParserTransition(.param, .csiParam) }
            if 0x3C <= ch && ch <= 0x3F { return ParserTransition(.collect, .csiParam) }
            if ch == 0x3A { return ParserTransition(.ignore, .csiIgnore) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect, .csiIntermediate) }
            return ParserTransition()

        case .csiParam:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if (0x30 <= ch && ch <= 0x39) || ch == 0x3B { return ParserTransition(.param) }
            if ch == 0x3A || (0x3C <= ch && ch <= 0x3F) { return ParserTransition(.ignore, .csiIgnore) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect, .csiIntermediate) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.csiDispatch, .ground) }
            return ParserTransition()

        case .csiIntermediate:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.csiDispatch, .ground) }
            if 0x30 <= ch && ch <= 0x3F { return ParserTransition(.ignore, .csiIgnore) }
            return ParserTransition()

        case .csiIgnore:
            if c0Prime(ch) { return ParserTransition(.execute) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.ignore, .ground) }
            return ParserTransition()

        case .dcsEntry:
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect, .dcsIntermediate) }
            if ch == 0x3A { return ParserTransition(.ignore, .dcsIgnore) }
            if (0x30 <= ch && ch <= 0x39) || ch == 0x3B { return ParserTransition(.param, .dcsParam) }
            if 0x3C <= ch && ch <= 0x3F { return ParserTransition(.collect, .dcsParam) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.ignore, .dcsPassthrough) }
            return ParserTransition()

        case .dcsParam:
            if (0x30 <= ch && ch <= 0x39) || ch == 0x3B { return ParserTransition(.param) }
            if ch == 0x3A || (0x3C <= ch && ch <= 0x3F) { return ParserTransition(.ignore, .dcsIgnore) }
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect, .dcsIntermediate) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.ignore, .dcsPassthrough) }
            return ParserTransition()

        case .dcsIntermediate:
            if 0x20 <= ch && ch <= 0x2F { return ParserTransition(.collect) }
            if 0x40 <= ch && ch <= 0x7E { return ParserTransition(.ignore, .dcsPassthrough) }
            if 0x30 <= ch && ch <= 0x3F { return ParserTransition(.ignore, .dcsIgnore) }
            return ParserTransition()

        case .dcsPassthrough:
            if c0Prime(ch) || (0x20 <= ch && ch <= 0x7E) { return ParserTransition(.put) }
            if ch == 0x9C { return ParserTransition(.ignore, .ground) }
            return ParserTransition()

        case .dcsIgnore:
            if ch == 0x9C { return ParserTransition(.ignore, .ground) }
            return ParserTransition()

        case .oscString:
            if 0x20 <= ch && ch <= 0x7F { return ParserTransition(.oscPut) }
            if ch == 0x9C || ch == 0x07 { return ParserTransition(.ignore, .ground) } // 0x07 is xterm non-ANSI variant
            return ParserTransition()

        case .sosPmApcString:
            if ch == 0x9C { return ParserTransition(.ignore, .ground) }
            return ParserTransition()
        }
    }

    /// mosh `State::input`.
    private static func transition(_ state: ParserState, _ ch: UInt32) -> ParserTransition {
        // Check for immediate transitions.
        let anywhere = anywhereRule(ch)
        if anywhere.nextState != nil {
            return anywhere
        }
        // Normal X.364 state machine.
        // Parse high Unicode codepoints like 'A'.
        return inputStateRule(state, ch >= 0xA0 ? 0x41 : ch)
    }

    /// mosh `Parser::input( wchar_t, Actions & )` without the vector: the (up to three)
    /// actions for `ch`, all of them about `ch` where a character is present.
    mutating func step(_ ch: UInt32) -> ParserStep {
        let tx = Parser.transition(state, ch)
        var result = ParserStep()
        if let next = tx.nextState {
            result.exit = state.exitAction
            result.action = tx.action
            result.enter = next.enterAction
            state = next
        } else {
            result.action = tx.action
        }
        return result
    }

    /// mosh `Parser::input( wchar_t ch, Actions &ret )`: appends the actions for `ch`.
    public mutating func input(_ ch: UInt32, into actions: inout [ParserAction]) {
        let s = step(ch)
        if s.exit != .ignore { actions.append(ParserAction(s.exit)) }
        if s.action != .ignore { actions.append(ParserAction(s.action, ch: ch)) }
        if s.enter != .ignore { actions.append(ParserAction(s.enter)) }
    }

    /// mosh `Parser::reset_input`.
    public mutating func resetInput() {
        state = .ground
    }
}

// MARK: - UTF-8 input

/// Result of glibc's `mbrtowc` on a buffer, starting from the initial shift state.
enum MBResult: Equatable {
    /// Return value 0: the buffer starts with a NUL byte.
    case nul
    /// A character of `length` bytes. `value` can be above U+10FFFF.
    case character(length: Int, value: UInt32)
    /// Return value -1 (EILSEQ).
    case invalid
    /// Return value -2: a prefix of a possibly valid character.
    case incomplete
}

/// glibc 2.39 `mbrtowc` in a UTF-8 locale, for `n` in 1...8 bytes and an initial state.
/// mosh's UTF-8 handling is whatever this function does (parser.cc), so its quirks are
/// part of the port:
///  - lead bytes 0xC2...0xFD are accepted: glibc still decodes the 5- and 6-byte forms
///    of the original UTF-8 (values up to 0x7FFFFFFF). mosh maps everything above
///    U+10FFFF to U+FFFD afterwards, as one character;
///  - 0x80...0xC1, 0xFE and 0xFF are invalid as a first byte;
///  - a buffer shorter than the lead byte asks for is "incomplete" as long as the bytes
///    after the lead are continuation bytes. Overlong forms and surrogates are only
///    rejected when the last byte arrives (E0 80 is incomplete, E0 80 80 is invalid);
///  - overlong forms of three or more bytes and U+D800...U+DFFF are invalid.
/// Checked against the real function by `GlibcConformanceTests`.
func glibcMbrtowc(_ bytes: UInt64, count n: Int) -> MBResult {
    // `bytes` holds the buffer with its first byte in the low 8 bits.
    @inline(__always) func byte(_ i: Int) -> UInt32 {
        return UInt32(truncatingIfNeeded: bytes >> (8 * UInt64(i))) & 0xFF
    }

    let b0 = byte(0)
    if b0 < 0x80 {
        return b0 == 0 ? .nul : .character(length: 1, value: b0)
    }

    let cnt: Int
    var ch: UInt32
    if b0 >= 0xC2 && b0 < 0xE0 {
        cnt = 2
        ch = b0 & 0x1F
    } else if (b0 & 0xF0) == 0xE0 {
        cnt = 3
        ch = b0 & 0x0F
    } else if (b0 & 0xF8) == 0xF0 {
        cnt = 4
        ch = b0 & 0x07
    } else if (b0 & 0xFC) == 0xF8 {
        cnt = 5
        ch = b0 & 0x03
    } else if (b0 & 0xFE) == 0xFC {
        cnt = 6
        ch = b0 & 0x01
    } else {
        return .invalid
    }

    if n < cnt {
        // Not enough input. But before reporting that, check that all the bytes are correct.
        var i = 1
        while i < n {
            if (byte(i) & 0xC0) != 0x80 { return .invalid }
            i += 1
        }
        return .incomplete
    }

    var i = 1
    while i < cnt {
        let b = byte(i)
        if (b & 0xC0) != 0x80 { return .invalid }
        ch = (ch << 6) | (b & 0x3F)
        i += 1
    }

    // An overlong form: the value would have fitted in a shorter sequence.
    if cnt > 2 && (ch >> UInt32(5 * cnt - 4)) == 0 { return .invalid }
    // Surrogates are not characters.
    if ch >= 0xD800 && ch <= 0xDFFF { return .invalid }

    return .character(length: cnt, value: ch)
}

/// mosh `Parser::UTF8Parser`: bytes in, parser actions out.
///
/// mosh collects bytes in an 8-byte buffer and calls `mbrtowc` on the whole buffer after
/// every byte. An invalid buffer gives one U+FFFD for everything before its last byte,
/// and the last byte is tried again on its own. So `E2 82 41` is U+FFFD then 'A', and an
/// overlong `E0 80 80` is U+FFFD (for `E0 80` + the failing byte) and another U+FFFD (the
/// last 0x80 alone).
public struct UTF8Parser: Equatable, Sendable {
    public static let bufSize = 8

    public internal(set) var parser = Parser()
    /// The collected bytes of an incomplete character, first byte in the low 8 bits.
    /// Bytes at and above `bufLen` are kept at zero (mosh leaves stale bytes there; they
    /// are never read).
    var bufBits: UInt64 = 0
    public internal(set) var bufLen: Int = 0

    public init() {}

    /// The bytes of an incomplete multibyte character collected so far.
    public var pendingBytes: [UInt8] {
        return (0..<bufLen).map { UInt8(truncatingIfNeeded: bufBits >> (8 * UInt64($0))) }
    }

    /// Rebuild from field values (serialization). `pendingBytes` must be at most 7 bytes.
    public init(state: ParserState, pendingBytes: [UInt8]) {
        precondition(pendingBytes.count < UTF8Parser.bufSize)
        parser.state = state
        for (i, b) in pendingBytes.enumerated() {
            bufBits |= UInt64(b) << (8 * UInt64(i))
        }
        bufLen = pendingBytes.count
    }

    /// Up to two wide characters produced by one input byte.
    struct Decoded {
        var count: Int = 0
        var first: UInt32 = 0
        var second: UInt32 = 0

        mutating func append(_ ch: UInt32) {
            if count == 0 { first = ch } else { second = ch }
            count += 1
        }
    }

    /// The UTF-8 part of mosh `UTF8Parser::input`: the wide characters that this byte
    /// completes (none, one, or two when an invalid sequence is followed by a byte that
    /// is a character by itself).
    mutating func decode(_ c: UInt8) -> Decoded {
        var out = Decoded()

        // 1-byte UTF-8 character, aka ASCII?  Cheat.
        if bufLen == 0 && c <= 0x7F {
            out.append(UInt32(c))
            return out
        }

        bufBits |= UInt64(c) << (8 * UInt64(bufLen))
        bufLen += 1

        var totalBytesParsed = 0
        let origBufLen = bufLen

        // this routine is somewhat complicated in order to comply with
        // Unicode 6.0, section 3.9, "Best Practices for using U+FFFD"
        while totalBytesParsed != origBufLen {
            var pwc: UInt32
            var bytesParsed: Int

            switch glibcMbrtowc(bufBits, count: bufLen) {
            case .nul:
                // character was NUL, accept and clear buffer
                bufLen = 0
                bufBits = 0
                pwc = 0
                bytesParsed = 1
            case .invalid:
                // invalid sequence, use replacement character and try again with last char
                if bufLen > 1 {
                    bufBits = (bufBits >> (8 * UInt64(bufLen - 1))) & 0xFF
                    bytesParsed = bufLen - 1
                    bufLen = 1
                } else {
                    bufBits = 0
                    bufLen = 0
                    bytesParsed = 1
                }
                pwc = 0xFFFD
            case .incomplete:
                // can't parse incomplete multibyte character
                totalBytesParsed += bufLen
                continue
            case .character(let length, let value):
                // parsed into pwc, accept
                bufBits = length >= 8 ? 0 : bufBits >> (8 * UInt64(length))
                bufLen -= length
                pwc = value
                bytesParsed = length
            }

            if pwc > 0x10FFFF { // outside Unicode range
                pwc = 0xFFFD
            }

            if pwc >= 0xD800 && pwc <= 0xDFFF { // surrogate code point
                pwc = 0xFFFD
            }

            out.append(pwc)

            totalBytesParsed += bytesParsed
        }
        return out
    }

    /// mosh `UTF8Parser::input( char c, Actions &ret )`: appends the actions for one byte.
    public mutating func input(_ c: UInt8, into actions: inout [ParserAction]) {
        let d = decode(c)
        if d.count > 0 { parser.input(d.first, into: &actions) }
        if d.count > 1 { parser.input(d.second, into: &actions) }
    }

    /// mosh `UTF8Parser::reset_input`: back to Ground with an empty buffer.
    public mutating func resetInput() {
        parser.resetInput()
        bufBits = 0
        bufLen = 0
    }
}
