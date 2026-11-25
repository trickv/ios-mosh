// The parser state machine and the UTF-8 decoder. Expectations are derived from
// mosh 1.4.0 src/terminal/parserstate.cc and parser.cc.

import XCTest
@testable import MoshTerminal

final class ParserTests: XCTestCase {
    typealias K = ParserActionKind

    /// Actions as text: the mosh action name, plus the character in hex when present.
    private func describe(_ actions: [ParserAction]) -> [String] {
        return actions.map { a in
            a.charPresent ? "\(a.kind.name)(\(String(a.ch, radix: 16)))" : a.kind.name
        }
    }

    private func run(_ scalars: [UInt32]) -> (actions: [String], state: ParserState) {
        var p = Parser()
        var actions: [ParserAction] = []
        for ch in scalars { p.input(ch, into: &actions) }
        return (describe(actions), p.state)
    }

    private func scalars(_ s: String) -> [UInt32] { return s.unicodeScalars.map { $0.value } }

    // MARK: Sequences

    func testSequences() {
        let table: [(input: String, actions: [String], state: ParserState, line: UInt)] = [
            ("a", ["Print(61)"], .ground, #line),
            ("\n", ["Execute(a)"], .ground, #line),
            ("\u{0}", ["Execute(0)"], .ground, #line),
            ("\u{7F}", ["Print(7f)"], .ground, #line),
            ("é日", ["Print(e9)", "Print(65e5)"], .ground, #line),
            ("\u{1B}", ["Clear"], .escape, #line),
            ("\u{1B}[", ["Clear", "Clear"], .csiEntry, #line),
            ("\u{1B}[1;2m", ["Clear", "Clear", "Param(31)", "Param(3b)", "Param(32)", "CSI_Dispatch(6d)"], .ground, #line),
            ("\u{1B}[m", ["Clear", "Clear", "CSI_Dispatch(6d)"], .ground, #line),
            ("\u{1B}[?25h", ["Clear", "Clear", "Collect(3f)", "Param(32)", "Param(35)", "CSI_Dispatch(68)"], .ground, #line),
            ("\u{1B}[>c", ["Clear", "Clear", "Collect(3e)", "CSI_Dispatch(63)"], .ground, #line),
            ("\u{1B}[1 q", ["Clear", "Clear", "Param(31)", "Collect(20)", "CSI_Dispatch(71)"], .ground, #line),
            ("\u{1B}[!p", ["Clear", "Clear", "Collect(21)", "CSI_Dispatch(70)"], .ground, #line),
            // a parameter after an intermediate, a colon, a private marker after a parameter: ignore to the final
            ("\u{1B}[ 1q", ["Clear", "Clear", "Collect(20)"], .ground, #line),
            ("\u{1B}[1:2m", ["Clear", "Clear", "Param(31)"], .ground, #line),
            ("\u{1B}[:", ["Clear", "Clear"], .csiIgnore, #line),
            ("\u{1B}[1?h", ["Clear", "Clear", "Param(31)"], .ground, #line),
            // C0 controls are executed inside a CSI; CAN and SUB abort it; ESC restarts
            ("\u{1B}[1\n2m", ["Clear", "Clear", "Param(31)", "Execute(a)", "Param(32)", "CSI_Dispatch(6d)"], .ground, #line),
            ("\u{1B}[1\u{18}m", ["Clear", "Clear", "Param(31)", "Execute(18)", "Print(6d)"], .ground, #line),
            ("\u{1B}[1\u{1A}", ["Clear", "Clear", "Param(31)", "Execute(1a)"], .ground, #line),
            ("\u{1B}[1\u{1B}[2m", ["Clear", "Clear", "Param(31)", "Clear", "Clear", "Param(32)", "CSI_Dispatch(6d)"], .ground, #line),
            ("\u{1B}[\u{7F}m", ["Clear", "Clear", "CSI_Dispatch(6d)"], .ground, #line),
            // escape sequences
            ("\u{1B}7", ["Clear", "Esc_Dispatch(37)"], .ground, #line),
            ("\u{1B}M", ["Clear", "Esc_Dispatch(4d)"], .ground, #line),
            ("\u{1B}(B", ["Clear", "Collect(28)", "Esc_Dispatch(42)"], .ground, #line),
            ("\u{1B}#8", ["Clear", "Collect(23)", "Esc_Dispatch(38)"], .ground, #line),
            ("\u{1B} #8", ["Clear", "Collect(20)", "Collect(23)", "Esc_Dispatch(38)"], .ground, #line),
            ("\u{1B}\n", ["Clear", "Execute(a)"], .escape, #line),
            ("\u{1B}\u{1B}", ["Clear", "Clear"], .escape, #line),
            ("\u{1B}\u{7F}", ["Clear"], .escape, #line),
            // OSC: BEL, ST (ESC \ and U+009C) and any other anywhere transition end it
            ("\u{1B}]0;t\u{7}", ["Clear", "OSC_Start", "OSC_Put(30)", "OSC_Put(3b)", "OSC_Put(74)", "OSC_End"], .ground, #line),
            ("\u{1B}]x\u{1B}\\", ["Clear", "OSC_Start", "OSC_Put(78)", "OSC_End", "Clear", "Esc_Dispatch(5c)"], .ground, #line),
            ("\u{1B}]x\u{9C}", ["Clear", "OSC_Start", "OSC_Put(78)", "OSC_End"], .ground, #line),
            ("\u{1B}]x\u{18}", ["Clear", "OSC_Start", "OSC_Put(78)", "OSC_End", "Execute(18)"], .ground, #line),
            ("\u{1B}]a\nb\u{7F}日", ["Clear", "OSC_Start", "OSC_Put(61)", "OSC_Put(62)", "OSC_Put(7f)", "OSC_Put(65e5)"], .oscString, #line),
            ("\u{1B}]a\u{9D}b", ["Clear", "OSC_Start", "OSC_Put(61)", "OSC_End", "OSC_Start", "OSC_Put(62)"], .oscString, #line),
            // DCS: hook, put, unhook
            ("\u{1B}P1$qx\n\u{1B}\\", ["Clear", "Clear", "Param(31)", "Collect(24)", "Hook", "Put(78)", "Put(a)", "Unhook",
                                         "Clear", "Esc_Dispatch(5c)"], .ground, #line),
            ("\u{1B}P:x\u{9C}", ["Clear", "Clear"], .ground, #line),
            ("\u{1B}P1:", ["Clear", "Clear", "Param(31)"], .dcsIgnore, #line),
            ("\u{1B}Pq\u{9C}", ["Clear", "Clear", "Hook", "Unhook"], .ground, #line),
            ("\u{1B}P\n", ["Clear", "Clear"], .dcsEntry, #line),
            // SOS, PM, APC swallow everything up to ST
            ("\u{1B}Xabc\n\u{1B}\\", ["Clear", "Clear", "Esc_Dispatch(5c)"], .ground, #line),
            ("\u{1B}^a", ["Clear"], .sosPmApcString, #line),
            ("\u{1B}_a\u{9C}b", ["Clear", "Print(62)"], .ground, #line),
            // C1 controls
            ("\u{84}", ["Execute(84)"], .ground, #line),
            ("\u{9B}1m", ["Clear", "Param(31)", "CSI_Dispatch(6d)"], .ground, #line),
            ("\u{9D}t\u{7}", ["OSC_Start", "OSC_Put(74)", "OSC_End"], .ground, #line),
            ("\u{90}", ["Clear"], .dcsEntry, #line),
            ("\u{98}", [], .sosPmApcString, #line),
            ("\u{9E}", [], .sosPmApcString, #line),
            ("\u{9F}", [], .sosPmApcString, #line),
            ("\u{9C}", [], .ground, #line),
            ("\u{1B}[1\u{85}", ["Clear", "Clear", "Param(31)", "Execute(85)"], .ground, #line),
            // code points from U+00A0 are classified like 'A' in every state
            ("\u{1B}[1é", ["Clear", "Clear", "Param(31)", "CSI_Dispatch(e9)"], .ground, #line),
            ("\u{1B}[日", ["Clear", "Clear", "CSI_Dispatch(65e5)"], .ground, #line),
            ("\u{1B}é", ["Clear", "Esc_Dispatch(e9)"], .ground, #line),
            ("\u{1B}(日", ["Clear", "Collect(28)", "Esc_Dispatch(65e5)"], .ground, #line),
            ("\u{1B}Pé", ["Clear", "Clear", "Hook"], .dcsPassthrough, #line),
            ("\u{1B}Pqé", ["Clear", "Clear", "Hook", "Put(e9)"], .dcsPassthrough, #line),
        ]
        for row in table {
            let r = run(scalars(row.input))
            XCTAssertEqual(r.actions, row.actions, "actions for \(row.input.debugDescription)", line: row.line)
            XCTAssertEqual(r.state, row.state, "state after \(row.input.debugDescription)", line: row.line)
        }
    }

    // MARK: Full transition table

    /// One rule of a state: characters `lo...hi` give `action` and move to `next`
    /// (nil: stay). Characters without a rule do nothing.
    private struct Rule {
        var lo: UInt32, hi: UInt32
        var action: K
        var next: ParserState?
        init(_ lo: UInt32, _ hi: UInt32, _ action: K, _ next: ParserState? = nil) {
            self.lo = lo; self.hi = hi; self.action = action; self.next = next
        }
    }

    /// The "anywhere" transitions, checked before a state's own rules.
    private let anywhere: [Rule] = [
        Rule(0x18, 0x18, .execute, .ground), Rule(0x1A, 0x1A, .execute, .ground),
        Rule(0x80, 0x8F, .execute, .ground), Rule(0x91, 0x97, .execute, .ground),
        Rule(0x99, 0x9A, .execute, .ground),
        Rule(0x9C, 0x9C, .ignore, .ground),
        Rule(0x1B, 0x1B, .ignore, .escape),
        Rule(0x98, 0x98, .ignore, .sosPmApcString), Rule(0x9E, 0x9F, .ignore, .sosPmApcString),
        Rule(0x90, 0x90, .ignore, .dcsEntry),
        Rule(0x9D, 0x9D, .ignore, .oscString),
        Rule(0x9B, 0x9B, .ignore, .csiEntry),
    ]

    /// C0 controls that are not anywhere transitions: 00-17, 19, 1C-1F.
    private func c0(_ action: K) -> [Rule] {
        return [Rule(0x00, 0x17, action), Rule(0x19, 0x19, action), Rule(0x1C, 0x1F, action)]
    }

    /// The state's own rules, from parserstate.cc, for characters below U+00A0.
    private func rules(_ s: ParserState) -> [Rule] {
        switch s {
        case .ground:
            return c0(.execute) + [Rule(0x20, 0x7F, .print)]
        case .escape:
            return c0(.execute) + [
                Rule(0x20, 0x2F, .collect, .escapeIntermediate),
                Rule(0x30, 0x4F, .escDispatch, .ground), Rule(0x51, 0x57, .escDispatch, .ground),
                Rule(0x59, 0x5A, .escDispatch, .ground), Rule(0x5C, 0x5C, .escDispatch, .ground),
                Rule(0x60, 0x7E, .escDispatch, .ground),
                Rule(0x5B, 0x5B, .ignore, .csiEntry), Rule(0x5D, 0x5D, .ignore, .oscString),
                Rule(0x50, 0x50, .ignore, .dcsEntry),
                Rule(0x58, 0x58, .ignore, .sosPmApcString), Rule(0x5E, 0x5F, .ignore, .sosPmApcString),
            ]
        case .escapeIntermediate:
            return c0(.execute) + [Rule(0x20, 0x2F, .collect), Rule(0x30, 0x7E, .escDispatch, .ground)]
        case .csiEntry:
            return c0(.execute) + [
                Rule(0x40, 0x7E, .csiDispatch, .ground),
                Rule(0x30, 0x39, .param, .csiParam), Rule(0x3B, 0x3B, .param, .csiParam),
                Rule(0x3C, 0x3F, .collect, .csiParam),
                Rule(0x3A, 0x3A, .ignore, .csiIgnore),
                Rule(0x20, 0x2F, .collect, .csiIntermediate),
            ]
        case .csiParam:
            return c0(.execute) + [
                Rule(0x30, 0x39, .param), Rule(0x3B, 0x3B, .param),
                Rule(0x3A, 0x3A, .ignore, .csiIgnore), Rule(0x3C, 0x3F, .ignore, .csiIgnore),
                Rule(0x20, 0x2F, .collect, .csiIntermediate),
                Rule(0x40, 0x7E, .csiDispatch, .ground),
            ]
        case .csiIntermediate:
            return c0(.execute) + [
                Rule(0x20, 0x2F, .collect),
                Rule(0x40, 0x7E, .csiDispatch, .ground),
                Rule(0x30, 0x3F, .ignore, .csiIgnore),
            ]
        case .csiIgnore:
            return c0(.execute) + [Rule(0x40, 0x7E, .ignore, .ground)]
        case .dcsEntry:
            return [
                Rule(0x20, 0x2F, .collect, .dcsIntermediate),
                Rule(0x3A, 0x3A, .ignore, .dcsIgnore),
                Rule(0x30, 0x39, .param, .dcsParam), Rule(0x3B, 0x3B, .param, .dcsParam),
                Rule(0x3C, 0x3F, .collect, .dcsParam),
                Rule(0x40, 0x7E, .ignore, .dcsPassthrough),
            ]
        case .dcsParam:
            return [
                Rule(0x30, 0x39, .param), Rule(0x3B, 0x3B, .param),
                Rule(0x3A, 0x3A, .ignore, .dcsIgnore), Rule(0x3C, 0x3F, .ignore, .dcsIgnore),
                Rule(0x20, 0x2F, .collect, .dcsIntermediate),
                Rule(0x40, 0x7E, .ignore, .dcsPassthrough),
            ]
        case .dcsIntermediate:
            return [
                Rule(0x20, 0x2F, .collect),
                Rule(0x40, 0x7E, .ignore, .dcsPassthrough),
                Rule(0x30, 0x3F, .ignore, .dcsIgnore),
            ]
        case .dcsPassthrough:
            return c0(.put) + [Rule(0x20, 0x7E, .put)]
        case .dcsIgnore, .sosPmApcString:
            return []
        case .oscString:
            return [Rule(0x20, 0x7F, .oscPut), Rule(0x07, 0x07, .ignore, .ground)]
        }
    }

    /// A character sequence that takes a fresh parser into each state.
    private let entry: [ParserState: [UInt32]] = [
        .ground: [],
        .escape: [0x1B],
        .escapeIntermediate: [0x1B, 0x20],
        .csiEntry: [0x1B, 0x5B],
        .csiParam: [0x1B, 0x5B, 0x31],
        .csiIntermediate: [0x1B, 0x5B, 0x20],
        .csiIgnore: [0x1B, 0x5B, 0x3A],
        .dcsEntry: [0x1B, 0x50],
        .dcsParam: [0x1B, 0x50, 0x31],
        .dcsIntermediate: [0x1B, 0x50, 0x20],
        .dcsPassthrough: [0x1B, 0x50, 0x71],
        .dcsIgnore: [0x1B, 0x50, 0x3A],
        .oscString: [0x1B, 0x5D],
        .sosPmApcString: [0x1B, 0x58],
    ]

    private func enterAction(_ s: ParserState) -> K {
        switch s {
        case .escape, .csiEntry, .dcsEntry: return .clear
        case .dcsPassthrough: return .hook
        case .oscString: return .oscStart
        default: return .ignore
        }
    }

    private func exitAction(_ s: ParserState) -> K {
        switch s {
        case .dcsPassthrough: return .unhook
        case .oscString: return .oscEnd
        default: return .ignore
        }
    }

    /// Every state against every character U+0000...U+00FF and some higher ones.
    func testTransitionTable() {
        var chars = Array(UInt32(0)...UInt32(0xFF))
        chars += [0x100, 0x3042, 0xFFFD, 0x1F600, 0x10FFFF]
        var checked = 0
        for state in ParserState.allCases {
            let stateRules = rules(state)
            for ch in chars {
                // expectation
                var action: K = .ignore
                var next: ParserState? = nil
                if let r = anywhere.first(where: { $0.lo <= ch && ch <= $0.hi }) {
                    action = r.action
                    next = r.next
                } else {
                    let classified: UInt32 = ch >= 0xA0 ? 0x41 : ch
                    // first matching rule wins, as in the chains of ifs in parserstate.cc
                    if let r = stateRules.first(where: { $0.lo <= classified && classified <= $0.hi }) {
                        action = r.action
                        next = r.next
                    }
                }
                var expected: [ParserAction] = []
                if let n = next {
                    if exitAction(state) != .ignore { expected.append(ParserAction(exitAction(state))) }
                    if action != .ignore { expected.append(ParserAction(action, ch: ch)) }
                    if enterAction(n) != .ignore { expected.append(ParserAction(enterAction(n))) }
                } else if action != .ignore {
                    expected.append(ParserAction(action, ch: ch))
                }

                var p = Parser()
                var scratch: [ParserAction] = []
                for c in entry[state]! { p.input(c, into: &scratch) }
                XCTAssertEqual(p.state, state, "entry sequence for \(state.name)")
                var actual: [ParserAction] = []
                p.input(ch, into: &actual)
                XCTAssertEqual(actual, expected, "\(state.name) + U+\(String(ch, radix: 16))")
                XCTAssertEqual(p.state, next ?? state, "\(state.name) + U+\(String(ch, radix: 16))")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 14 * 261)
    }

    func testResetInput() {
        var p = UTF8Parser()
        var actions: [ParserAction] = []
        for b in [0x1B, 0x5B, 0x31, 0xE2, 0x82] as [UInt8] { p.input(b, into: &actions) }
        XCTAssertEqual(p.parser.state, .csiParam)
        XCTAssertEqual(p.pendingBytes, [0xE2, 0x82])
        p.resetInput()
        XCTAssertEqual(p.parser.state, .ground)
        XCTAssertEqual(p.pendingBytes, [])
        XCTAssertEqual(p, UTF8Parser())
    }

    // MARK: UTF-8

    /// Wide characters that come out of the UTF-8 stage, and the bytes left pending.
    private func decode(_ bytes: [UInt8]) -> (chars: [UInt32], pending: [UInt8]) {
        var p = UTF8Parser()
        var out: [UInt32] = []
        for b in bytes {
            let d = p.decode(b)
            if d.count > 0 { out.append(d.first) }
            if d.count > 1 { out.append(d.second) }
        }
        return (out, p.pendingBytes)
    }

    func testUTF8() {
        let R: UInt32 = 0xFFFD
        let table: [(bytes: [UInt8], chars: [UInt32], pending: [UInt8], line: UInt)] = [
            // well formed
            ([0x41], [0x41], [], #line),
            ([0x00], [0x00], [], #line),
            ([0x7F], [0x7F], [], #line),
            ([0xC2, 0x80], [0x80], [], #line),
            ([0xC2, 0x9B], [0x9B], [], #line),
            ([0xC3, 0xA9], [0xE9], [], #line),
            ([0xDF, 0xBF], [0x7FF], [], #line),
            ([0xE0, 0xA0, 0x80], [0x800], [], #line),
            ([0xE2, 0x82, 0xAC], [0x20AC], [], #line),
            ([0xED, 0x9F, 0xBF], [0xD7FF], [], #line),
            ([0xEE, 0x80, 0x80], [0xE000], [], #line),
            ([0xEF, 0xBF, 0xBD], [R], [], #line),
            ([0xEF, 0xBF, 0xBF], [0xFFFF], [], #line),
            ([0xF0, 0x90, 0x80, 0x80], [0x10000], [], #line),
            ([0xF0, 0x9F, 0x98, 0x80], [0x1F600], [], #line),
            ([0xF4, 0x8F, 0xBF, 0xBF], [0x10FFFF], [], #line),
            // incomplete at the end of input: nothing yet, bytes kept
            ([0xC3], [], [0xC3], #line),
            ([0xE2, 0x82], [], [0xE2, 0x82], #line),
            ([0xF0, 0x9F, 0x98], [], [0xF0, 0x9F, 0x98], #line),
            ([0xFD, 0xBF, 0xBF, 0xBF, 0xBF], [], [0xFD, 0xBF, 0xBF, 0xBF, 0xBF], #line),
            // E0 80 is still "incomplete" for glibc: the overlong form is only rejected with its last byte
            ([0xE0, 0x80], [], [0xE0, 0x80], #line),
            ([0xED, 0xA0], [], [0xED, 0xA0], #line),
            // bytes that cannot start a character
            ([0x80], [R], [], #line),
            ([0xBF], [R], [], #line),
            ([0xC0], [R], [], #line),
            ([0xC1], [R], [], #line),
            ([0xFE], [R], [], #line),
            ([0xFF], [R], [], #line),
            ([0xC0, 0x80], [R, R], [], #line),
            ([0xC1, 0xBF], [R, R], [], #line),
            // a sequence cut short by another character: one U+FFFD, then that character
            ([0xC3, 0x41], [R, 0x41], [], #line),
            ([0xE2, 0x82, 0x41], [R, 0x41], [], #line),
            ([0xF0, 0x9F, 0x98, 0x41], [R, 0x41], [], #line),
            ([0xE2, 0x1B], [R, 0x1B], [], #line),
            ([0xE2, 0x00], [R, 0x00], [], #line),
            ([0xC3, 0xC3, 0xA9], [R, 0xE9], [], #line),
            ([0xE2, 0x82, 0xE2, 0x82, 0xAC], [R, 0x20AC], [], #line),
            ([0xE2, 0xE2], [R], [0xE2], #line),
            ([0xF0, 0x9F, 0x98, 0xFF], [R, R], [], #line),
            // overlong forms: one U+FFFD for the sequence up to the failing byte, one for that byte
            ([0xE0, 0x80, 0x80], [R, R], [], #line),
            ([0xE0, 0x9F, 0xBF], [R, R], [], #line),
            ([0xF0, 0x80, 0x80, 0x80], [R, R], [], #line),
            ([0xF0, 0x8F, 0xBF, 0xBF], [R, R], [], #line),
            ([0xF8, 0x80, 0x80, 0x80, 0x80], [R, R], [], #line),
            ([0xF8, 0x87, 0xBF, 0xBF, 0xBF], [R, R], [], #line),
            ([0xFC, 0x80, 0x80, 0x80, 0x80, 0x80], [R, R], [], #line),
            ([0xFC, 0x83, 0xBF, 0xBF, 0xBF, 0xBF], [R, R], [], #line),
            // surrogates
            ([0xED, 0xA0, 0x80], [R, R], [], #line),
            ([0xED, 0xBF, 0xBF], [R, R], [], #line),
            // above U+10FFFF, and the 5- and 6-byte forms: glibc decodes them, mosh makes one U+FFFD
            ([0xF4, 0x90, 0x80, 0x80], [R], [], #line),
            ([0xF7, 0xBF, 0xBF, 0xBF], [R], [], #line),
            ([0xF8, 0x88, 0x80, 0x80, 0x80], [R], [], #line),
            ([0xFB, 0xBF, 0xBF, 0xBF, 0xBF], [R], [], #line),
            ([0xFC, 0x84, 0x80, 0x80, 0x80, 0x80], [R], [], #line),
            ([0xFD, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF], [R], [], #line),
            // a mix
            ([0x61, 0x80, 0x62, 0xE2, 0x82, 0xAC, 0xFF, 0x63], [0x61, R, 0x62, 0x20AC, R, 0x63], [], #line),
        ]
        for row in table {
            let r = decode(row.bytes)
            let name = row.bytes.map { String($0, radix: 16) }.joined(separator: " ")
            XCTAssertEqual(r.chars.map { String($0, radix: 16) }, row.chars.map { String($0, radix: 16) },
                           "characters for \(name)", line: row.line)
            XCTAssertEqual(r.pending, row.pending, "pending bytes for \(name)", line: row.line)
        }
    }

    /// The same bytes give the same characters however they are split into writes.
    func testUTF8ThroughTheParser() {
        var p = UTF8Parser()
        var actions: [ParserAction] = []
        for b in Array("a日\u{301}".utf8) + [0xE2, 0x41, 0xC2, 0x85] { p.input(b, into: &actions) }
        XCTAssertEqual(describe(actions), ["Print(61)", "Print(65e5)", "Print(301)", "Print(fffd)", "Print(41)", "Execute(85)"])
    }
}
