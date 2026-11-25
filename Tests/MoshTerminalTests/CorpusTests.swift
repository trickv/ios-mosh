// The golden corpus: the Swift terminal model against mosh 1.4.0's own emulator.
//
// `Tests/MoshTerminalTests/Corpus/<case>/` holds, per case, what a mosh server sent
// (`instructions.jsonl`), the complete state of mosh's client after each instruction
// (`expected.jsonl`), the program output the server read (`session.jsonl`) and the
// server's own complete state after each read (`server.jsonl`). The files were written by
// `Tools/mosh-oracle`, which is mosh's code; `Tools/mosh-oracle/FORMAT.md` defines them.
// The loader is `Tests/MoshTestSupport/GoldenCorpus.swift`.
//
// Nothing here needs the oracle or mosh, so these tests also run on a Mac.
//
// The comparison is complete: after every instruction (client) and after every session
// line (server), each of the 34 keys of the dump and each field of each cell is compared.
// There is no tolerance and no key is skipped. `CorpusComparison.firstDifference` is the
// only place that decides what "equal" means.

import Foundation
import XCTest
import MoshTestSupport
@testable import MoshTerminal

// MARK: - Comparing a terminal with a state of the corpus

/// How much was compared.
struct CorpusTally {
    var cases = 0
    var states = 0
    /// Keys of the table in FORMAT.md 5.2 (34 per state).
    var keys = 0
    var cells = 0

    /// Seven fields per cell: contents, fg, bg, at, wide, fallback, wrap.
    var fields: Int { return keys + cells * 7 }

    var summary: String {
        return "\(cases) cases, \(states) states, \(keys) keys and \(cells) cells compared (\(fields) fields)"
    }
}

/// The first place where a terminal is not the state the oracle printed.
struct CorpusDifference: CustomStringConvertible {
    var field: String
    var row: Int?
    var col: Int?
    var expected: String
    var actual: String

    var description: String {
        var s = "field \(field)"
        if let row = row { s += ", row \(row)" }
        if let col = col { s += ", column \(col)" }
        return s + ": expected \(expected), actual \(actual)"
    }
}

extension TerminalState {
    /// The value of one key of the dump, read from the fields the oracle reads from mosh
    /// (FORMAT.md 5.2).
    func goldenValue(_ key: GoldenKey) -> GoldenValue {
        let fb = terminal.fb
        let ds = fb.ds
        let dp = terminal.dispatch
        switch key {
        case .width: return .int(ds.width)
        case .height: return .int(ds.height)
        case .cursor: return .ints([ds.cursorRow, ds.cursorCol])
        case .combining: return .ints([ds.combiningCharRow, ds.combiningCharCol])
        case .defaultTabs: return .bool(ds.defaultTabs)
        case .tabs: return .ints(ds.tabs.indices.filter { ds.tabs[$0] })
        case .scrollRegion: return .ints([ds.scrollingRegionTopRow, ds.scrollingRegionBottomRow])
        case .pen: return .pen(CorpusComparison.pen(ds.renditions))
        case .saved:
            return .saved(GoldenSavedCursor(row: ds.save.cursorRow, col: ds.save.cursorCol,
                                            pen: CorpusComparison.pen(ds.save.renditions),
                                            autoWrapMode: ds.save.autoWrapMode, originMode: ds.save.originMode))
        case .nextPrintWillWrap: return .bool(ds.nextPrintWillWrap)
        case .originMode: return .bool(ds.originMode)
        case .autoWrapMode: return .bool(ds.autoWrapMode)
        case .insertMode: return .bool(ds.insertMode)
        case .cursorVisible: return .bool(ds.cursorVisible)
        case .reverseVideo: return .bool(ds.reverseVideo)
        case .bracketedPaste: return .bool(ds.bracketedPaste)
        case .mouseReportingMode: return .int(ds.mouseReportingMode.rawValue)
        case .mouseFocusEvent: return .bool(ds.mouseFocusEvent)
        case .mouseAlternateScroll: return .bool(ds.mouseAlternateScroll)
        case .mouseEncodingMode: return .int(ds.mouseEncodingMode.rawValue)
        case .applicationModeCursorKeys: return .bool(ds.applicationModeCursorKeys)
        case .iconName: return .text(fb.iconName)
        case .windowTitle: return .text(fb.windowTitle)
        case .titleInitialized: return .bool(fb.titleInitialized)
        case .clipboard: return .text(fb.clipboard)
        case .bellCount: return .int(Int(fb.bellCount))
        case .echoAck: return .uint(echoAck)
        case .parserState: return .name(parser.parser.state.name)
        case .utf8Buf: return .ints(parser.pendingBytes.map { Int($0) })
        case .params: return .text(dp.params.map { UInt32($0) })
        case .dispatchChars: return .ints(dp.dispatchChars.map { Int($0) })
        case .parsed: return .bool(dp.parsed)
        case .parsedParams: return .ints(dp.parsedParams)
        case .oscString: return .text(dp.oscString)
        }
    }
}

enum CorpusComparison {
    static func pen(_ r: Renditions) -> GoldenPen {
        return GoldenPen(fg: r.foregroundColor, bg: r.backgroundColor, at: r.attributes)
    }

    static func cell(_ c: Cell) -> GoldenCell {
        return GoldenCell(contents: c.contents, pen: pen(c.renditions), wide: c.wide, fallback: c.fallback, wrap: c.wrap)
    }

    /// Compare every key and every cell. nil if the terminal is exactly the state.
    static func firstDifference(_ state: TerminalState, _ golden: GoldenState, tally: inout CorpusTally) -> CorpusDifference? {
        tally.states += 1
        for key in GoldenKey.allCases {
            tally.keys += 1
            let actual = state.goldenValue(key)
            let expected = golden[key]
            if actual != expected {
                return CorpusDifference(field: key.jsonName, row: nil, col: nil, expected: expected.description,
                                        actual: actual.description)
            }
        }

        let fb = state.terminal.fb
        // Not in the dump as such, but FORMAT.md says the vector has `width` elements.
        if fb.ds.tabs.count != fb.ds.width {
            return CorpusDifference(field: "tabs (length of the vector)", row: nil, col: nil,
                                    expected: String(fb.ds.width), actual: String(fb.ds.tabs.count))
        }
        if fb.rows.count != golden.rows.count {
            return CorpusDifference(field: "rows (number of rows)", row: nil, col: nil,
                                    expected: String(golden.rows.count), actual: String(fb.rows.count))
        }
        for y in 0..<fb.rows.count {
            let cells = fb.rows[y].cells
            let want = golden.rows[y]
            if cells.count != want.count {
                return CorpusDifference(field: "rows (number of cells)", row: y, col: nil,
                                        expected: String(want.count), actual: String(cells.count))
            }
            tally.cells += cells.count
            let difference: CorpusDifference? = cells.withUnsafeBufferPointer { have in
                want.withUnsafeBufferPointer { want in
                    for x in 0..<have.count {
                        if let field = differingField(have[x], want[x]) {
                            return CorpusDifference(field: "cell." + field, row: y, col: x,
                                                    expected: want[x].description, actual: cell(have[x]).description)
                        }
                    }
                    return nil
                }
            }
            if let difference = difference { return difference }
        }
        return nil
    }

    /// The first of the seven cell fields that differs. Contents are compared as bytes.
    static func differingField(_ have: Cell, _ want: GoldenCell) -> String? {
        if have.contents != want.contents { return "contents" }
        if have.renditions.foregroundColor != want.pen.fg { return "fg" }
        if have.renditions.backgroundColor != want.pen.bg { return "bg" }
        if have.renditions.attributes != want.pen.at { return "at" }
        if have.wide != want.wide { return "wide" }
        if have.fallback != want.fallback { return "fallback" }
        if have.wrap != want.wrap { return "wrap" }
        return nil
    }

    /// Bytes for a message: printable ASCII as it is, ESC as `\e`, the rest as `\xNN`.
    static func escaped(_ bytes: [UInt8], limit: Int = 1500) -> String {
        var s = ""
        for b in bytes.prefix(limit) {
            switch b {
            case 0x1B: s += "\\e"
            case 0x5C: s += "\\\\"
            case 0x20...0x7E: s += String(UnicodeScalar(b))
            default: s += "\\x" + (b < 16 ? "0" : "") + String(b, radix: 16)
            }
        }
        if bytes.count > limit { s += " ... (\(bytes.count) bytes in all)" }
        return s
    }

    static func describe(_ ops: [GoldenOp]) -> String {
        if ops.isEmpty { return "an empty diff (the state is a copy of its base)" }
        return ops.map { op -> String in
            switch op {
            case .hostBytes(let b): return "hostbytes (\(b.count) bytes) \(escaped(b))"
            case .resize(let w, let h): return "resize [\(w), \(h)]"
            case .echoAck(let n): return "echo_ack \(n)"
            }
        }.joined(separator: "; ")
    }
}

// MARK: - The two simulations (FORMAT.md section 7)

/// How the server simulation keeps its states between uses.
enum CorpusReload {
    /// As live values: copies share their row objects, as mosh's states do.
    case none
    /// Every state is its own blob (`serialized()` / `init(serialized:)`). Cells, row
    /// generations and the sharing of rows *within* a state survive; two states decoded
    /// from two blobs share no row object.
    case blobs
    /// The snapshot writer's pattern: `serializedWithoutRows()` plus one stored copy of
    /// every distinct `Row.serialized()`, so rows that mosh's `Row::operator==` calls
    /// equal are one object again after loading, across states.
    case sharedRows
}

/// The row store of `CorpusReload.sharedRows`.
final class RowTable {
    private var rows: [[UInt8]: Row] = [:]

    var count: Int { return rows.count }

    func reload(_ s: TerminalState) throws -> TerminalState {
        let width = s.framebuffer.ds.width
        let loaded = try s.framebuffer.rows.map { row -> Row in
            let bytes = row.serialized()
            if let known = rows[bytes] { return known }
            let fresh = try Row(serialized: bytes, width: width)
            rows[bytes] = fresh
            return fresh
        }
        return try TerminalState(serializedWithoutRows: s.serializedWithoutRows(), rows: loaded)
    }
}

enum CorpusRun {
    /// The client simulation, identical to `mosh-oracle apply`: copy state `old_num`,
    /// apply the ops in order unless the diff is empty, store as `new_num`, compare with
    /// the same line of expected.jsonl.
    ///
    /// With `reload`, a state only ever exists as its serialized bytes between uses: the
    /// base is decoded before the diff is applied, and what is compared and kept is the
    /// decoded form of the result.
    ///
    /// Returns the states by number and, if the case does not match, a description of
    /// the first difference.
    static func client(_ c: GoldenCase, reload: Bool = false, tally: inout CorpusTally) throws
        -> (states: [UInt64: TerminalState], failure: String?) {
        var states: [UInt64: TerminalState] = [0: TerminalState(width: c.width, height: c.height)]
        var blobs: [UInt64: [UInt8]] = [:]
        if reload { blobs[0] = states[0]!.serialized() }
        tally.cases += 1

        for (i, instruction) in c.instructions.enumerated() {
            let what = "\(c.name) instruction \(i + 1) (old_num \(instruction.oldNum), new_num \(instruction.newNum))"
            var s: TerminalState
            if reload {
                s = try TerminalState(serialized: blobs[instruction.oldNum]!)
            } else {
                s = states[instruction.oldNum]!
            }
            if !instruction.diff.isEmpty {
                for op in instruction.ops {
                    switch op {
                    case .hostBytes(let bytes):
                        let reply = s.act(bytes)
                        if !reply.isEmpty {
                            // mosh's client asserts this ("server never interrogates client terminal").
                            return (states, "\(what): the terminal replied \(CorpusComparison.escaped(reply)) to "
                                + CorpusComparison.describe(instruction.ops))
                        }
                    case .resize(let w, let h): s.resize(width: w, height: h)
                    case .echoAck(let n): s.applyEchoAck(n)
                    }
                }
            }
            if reload {
                let blob = s.serialized()
                blobs[instruction.newNum] = blob
                s = try TerminalState(serialized: blob)
            }
            states[instruction.newNum] = s

            guard i < c.expected.count else { continue }
            if let d = CorpusComparison.firstDifference(s, c.expected[i], tally: &tally) {
                return (states, "\(what): \(d). Diff being applied: \(CorpusComparison.describe(instruction.ops))")
            }
        }
        return (states, nil)
    }

    /// One session step applied as `mosh-oracle`'s `session_step` does it. Returns the
    /// terminal's reply to the host.
    static func step(_ server: inout TerminalState, _ step: GoldenSessionStep, clock: inout UInt64) -> [UInt8] {
        switch step {
        case .bytes(let bytes):
            return server.act(bytes)
        case .resize(let w, let h):
            // The oracle drops what `act( Resize )` returns.
            server.resize(width: w, height: h)
            return []
        case .echoAck(let n):
            // As the server does: note the input frame, and acknowledge it 50 ms later.
            server.registerInputFrame(n, now: clock)
            clock += 1000
            _ = server.setEchoAck(now: clock)
            clock += 1000
            return []
        }
    }

    static func describe(_ step: GoldenSessionStep) -> String {
        switch step {
        case .bytes(let b): return "bytes (\(b.count)) \(CorpusComparison.escaped(b))"
        case .resize(let w, let h): return "resize [\(w), \(h)]"
        case .echoAck(let n): return "echo_ack \(n)"
        }
    }

    /// The server simulation, identical to `mosh-oracle server`: one terminal reads the
    /// session line by line and is compared with server.jsonl after each, replies
    /// included. `sent[n]` is the server's state number n, as `gen` keeps them.
    ///
    /// With `reload`, the terminal is serialized and decoded before and after every step
    /// and the kept states are decoded from their bytes (see `CorpusReload`).
    static func server(_ c: GoldenCase, reload: CorpusReload = .none, compare: Bool = true, tally: inout CorpusTally,
                       each: (_ number: Int, _ server: TerminalState, _ sent: [TerminalState]) throws -> Void = { _, _, _ in })
        throws -> String? {
        let table = RowTable()
        func reloaded(_ s: TerminalState) throws -> TerminalState {
            switch reload {
            case .none: return s
            case .blobs: return try TerminalState(serialized: s.serialized())
            case .sharedRows: return try table.reload(s)
            }
        }
        var server = TerminalState(width: c.width, height: c.height)
        var sent: [TerminalState] = [try reloaded(server)]
        var clock: UInt64 = 1000
        tally.cases += 1

        for (k, sessionStep) in c.session.enumerated() {
            let what = "\(c.name) session line \(k + 2) (server state \(k + 1))"
            server = try reloaded(server)
            let reply = step(&server, sessionStep, clock: &clock)
            server = try reloaded(server)

            if compare {
                if let d = CorpusComparison.firstDifference(server, c.server[k], tally: &tally) {
                    return "\(what): \(d). Input: \(describe(sessionStep))"
                }
                if reply != c.replies[k] {
                    return "\(what): field reply_b64: expected \(CorpusComparison.escaped(c.replies[k])), "
                        + "actual \(CorpusComparison.escaped(reply)). Input: \(describe(sessionStep))"
                }
            }
            try each(k + 1, server, sent)
            sent.append(try reloaded(server))
        }
        return nil
    }
}

// MARK: - A decoder for diff_b64, to check `ops`

/// The few lines of protobuf needed to read a `HostBuffers.HostMessage`
/// (mosh `src/protobufs/hostinput.proto`) into ops, as FORMAT.md section 4 describes.
/// MoshTerminal does not know the wire format; this keeps the test independent of
/// MoshWire.
enum HostMessageReader {
    struct Malformed: Error {}

    struct Reader {
        var bytes: ArraySlice<UInt8>

        var atEnd: Bool { return bytes.isEmpty }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let b = bytes.popFirst() {
                value |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { break }
            }
            throw Malformed()
        }

        mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
            let n = Int(try varint())
            guard n <= bytes.count else { throw Malformed() }
            let out = bytes.prefix(n)
            bytes = bytes.dropFirst(n)
            return out
        }

        /// The next field: its number and either a varint or a length-delimited value.
        mutating func field() throws -> (number: UInt64, varint: UInt64?, data: ArraySlice<UInt8>?) {
            let tag = try varint()
            switch tag & 7 {
            case 0: return (tag >> 3, try varint(), nil)
            case 2: return (tag >> 3, nil, try lengthDelimited())
            default: throw Malformed()
            }
        }
    }

    static func ops(_ diff: [UInt8]) throws -> [GoldenOp] {
        var out: [GoldenOp] = []
        var message = Reader(bytes: diff[...])
        while !message.atEnd {
            let f = try message.field()
            guard f.number == 1, let instructionBytes = f.data else { throw Malformed() }
            var hostBytes: [UInt8]?
            var resize: (Int, Int)?
            var echoAck: UInt64?
            var instruction = Reader(bytes: instructionBytes)
            while !instruction.atEnd {
                let e = try instruction.field()
                guard let data = e.data else { throw Malformed() }
                var inner = Reader(bytes: data)
                switch e.number {
                case 2:
                    var s: [UInt8] = []
                    while !inner.atEnd {
                        let g = try inner.field()
                        if g.number == 4, let d = g.data { s = Array(d) }
                    }
                    hostBytes = s
                case 3:
                    var w = 0, h = 0
                    while !inner.atEnd {
                        let g = try inner.field()
                        if g.number == 5, let v = g.varint { w = Int(Int32(truncatingIfNeeded: v)) }
                        if g.number == 6, let v = g.varint { h = Int(Int32(truncatingIfNeeded: v)) }
                    }
                    resize = (w, h)
                case 7:
                    var n: UInt64 = 0
                    while !inner.atEnd {
                        let g = try inner.field()
                        if g.number == 8, let v = g.varint { n = v }
                    }
                    echoAck = n
                default:
                    throw Malformed()
                }
            }
            // apply_string takes the first extension present, in this order.
            if let b = hostBytes {
                out.append(.hostBytes(b))
            } else if let r = resize {
                out.append(.resize(width: r.0, height: r.1))
            } else if let n = echoAck {
                out.append(.echoAck(n))
            }
        }
        return out
    }
}

// MARK: - Tests

final class CorpusTests: XCTestCase {
    /// The corpus is read once for all tests of this class.
    static let corpus: Result<[GoldenCase], Error> = Result { try GoldenCorpus.loadAll() }

    func cases() throws -> [GoldenCase] {
        return try CorpusTests.corpus.get()
    }

    static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    // MARK: The loader

    func testCorpusLoads() throws {
        let cases = try self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 38, "the corpus has at least its 38 first cases")
        var instructions = 0
        for c in cases {
            XCTAssertFalse(c.instructions.isEmpty, c.name)
            XCTAssertEqual(c.expected.count, c.instructions.count, c.name)
            XCTAssertEqual(c.server.count, c.session.count, c.name)
            XCTAssertEqual(c.session.count, c.instructions.count, "\(c.name): one instruction per session line")
            for state in c.expected + c.server {
                XCTAssertEqual(state.rows.count, state.height, c.name)
                XCTAssertTrue(state.rows.allSatisfy { $0.count == state.width }, c.name)
            }
            instructions += c.instructions.count
        }
        XCTAssertGreaterThanOrEqual(instructions, 2916)
        print("corpus: \(cases.count) cases, \(instructions) instructions")
    }

    /// The worked example of FORMAT.md section 6, read by the loader.
    func testLoaderOnTheWorkedExampleOfTheFormat() throws {
        let lines = [
            #"{"num":1,"cursor":[0,2],"combining":[0,1],"rows":{"0":[{"t":"hi"},{"e":8}]}}"#,
            #"{"num":2,"cursor":[1,0],"combining":[1,0],"params":"0","dispatch_chars":[109],"parsed":true,"parsed_params":[0],"rows":{"0":[{"t":"hi"},{"t":"R","fg":31,"at":1},{"e":7}]}}"#,
            #"{"num":3,"cursor":[1,3],"combining":[1,2],"pen":{"bg":44},"params":"25","dispatch_chars":[63,104],"parsed_params":[25],"rows":{"1":[{"c":["漢"],"wide":true},{"e":1},{"c":["e\#u{301}"]},{"e":7,"bg":44}]}}"#,
            #"{"num":4,"cursor":[2,0],"combining":[2,0],"pen":{},"rows":{"0":1,"1":[{"t":"last"},{"e":6}]}}"#,
            #"{"num":5,"cursor_visible":false,"window_title":"t","title_initialized":true,"dispatch_chars":[63,108],"osc_string":"2;t"}"#,
            #"{"num":6,"width":12,"params":"1005","parsed_params":[1005],"rows":{"0":[{"c":["漢"],"wide":true},{"e":1},{"c":["e\#u{301}"]},{"e":7,"bg":44},{"e":2}],"1":[{"t":"last"},{"e":8}],"2":[{"e":12}]}}"#,
            #"{"num":7,"echo_ack":4}"#,
            #"{"num":8}"#,
        ]
        var state = GoldenState(width: 10, height: 3)
        XCTAssertEqual(state[.tabs], .ints([0, 8]))
        XCTAssertEqual(state[.scrollRegion], .ints([0, 2]))
        var states: [GoldenState] = []
        for line in lines {
            try state.apply(line: try JSONValue.parse(Array(line.utf8)))
            states.append(state)
        }
        XCTAssertEqual(states[0].rows[0].map { $0.contents }, [[0x68], [0x69]] + Array(repeating: [], count: 8))
        XCTAssertEqual(states[1].rows[0][2], GoldenCell(contents: [0x52], pen: GoldenPen(fg: 31, at: 1)))
        XCTAssertEqual(states[1][.parsedParams], .ints([0]))
        // 漢 is one wide cell, its right half an empty cell; e + U+0301 is one cell of three bytes.
        XCTAssertEqual(states[2].rows[1][0], GoldenCell(contents: [0xE6, 0xBC, 0xA2], wide: true))
        XCTAssertEqual(states[2].rows[1][1], GoldenCell())
        XCTAssertEqual(states[2].rows[1][2].contents, [0x65, 0xCC, 0x81])
        XCTAssertEqual(states[2].rows[1][9], GoldenCell(pen: GoldenPen(bg: 44)))
        XCTAssertEqual(states[2][.pen], .pen(GoldenPen(bg: 44)))
        XCTAssertEqual(states[2][.parsed], .bool(true), "a key that is absent keeps its value")
        // The scroll: row 0 is what row 1 was, row 2 is unchanged.
        XCTAssertEqual(states[3].rows[0], states[2].rows[1])
        XCTAssertEqual(states[3].rows[1].prefix(4).map { $0.contents }, [[0x6C], [0x61], [0x73], [0x74]])
        XCTAssertEqual(states[3].rows[2], states[2].rows[2])
        XCTAssertEqual(states[3][.pen], .pen(GoldenPen()))
        XCTAssertEqual(states[4][.windowTitle], .text([0x74]))
        XCTAssertEqual(states[4][.oscString], .text([0x32, 0x3B, 0x74]))
        XCTAssertEqual(states[5].width, 12)
        XCTAssertEqual(states[5].height, 3)
        XCTAssertEqual(states[5].rows.map { $0.count }, [12, 12, 12])
        XCTAssertEqual(states[5][.tabs], .ints([0, 8]))
        XCTAssertEqual(states[6][.echoAck], .uint(4))
        XCTAssertEqual(states[7][.echoAck], .uint(4))
        XCTAssertEqual(states[7].rows, states[5].rows)
    }

    func testLoaderRejectsWhatTheFormatForbids() throws {
        func apply(_ line: String) throws {
            var state = GoldenState(width: 4, height: 2)
            try state.apply(line: try JSONValue.parse(Array(line.utf8)))
        }
        XCTAssertNoThrow(try apply(#"{"num":1,"rows":{"0":[{"t":"ab"},{"e":2}]}}"#))
        XCTAssertThrowsError(try apply(#"{"num":1,"rows":{"0":[{"t":"ab"},{"e":3}]}}"#), "five cells in a row of four")
        XCTAssertThrowsError(try apply(#"{"num":1,"rows":{"0":[{"t":"ab","e":2},{"e":2}]}}"#), "two content keys")
        XCTAssertThrowsError(try apply(#"{"num":1,"rows":{"2":[{"e":4}]}}"#), "row out of range")
        XCTAssertThrowsError(try apply(#"{"num":1,"rows":{"0":5}}"#), "no such old row")
        XCTAssertThrowsError(try apply(#"{"num":1,"colour":3}"#), "unknown key")
        XCTAssertThrowsError(try apply(#"{"num":1,"cursor_visible":0}"#), "a number is not a boolean")
        XCTAssertThrowsError(try apply(#"{"num":1,"width":5}"#), "a new size without all rows")
        XCTAssertThrowsError(try apply(#"{"num":1,"parser_state":"Nowhere"}"#))
        XCTAssertThrowsError(try apply(#"{"cursor":[0,0]}"#), "no num")
        XCTAssertThrowsError(try JSONValue.parse(Array(#"{"a":1,"a":2}"#.utf8)), "a member twice")
        XCTAssertThrowsError(try JSONValue.parse(Array(#"{"a":1} x"#.utf8)))
        XCTAssertThrowsError(try JSONValue.parse(Array(#"{"a":"\ud800"}"#.utf8)), "lone surrogate")
        // Escapes, a surrogate pair, and an integer above Int64.
        let v = try JSONValue.parse(Array(#"{"s":"a\u007f😀\"\\","n":18446744073709551615}"#.utf8))
        XCTAssertEqual(v["s"]?.stringValue.map { $0.unicodeScalars.map { $0.value } }, [0x61, 0x7F, 0x1F600, 0x22, 0x5C])
        XCTAssertEqual(v["n"]?.uint64Value, UInt64.max)
        XCTAssertNil(v["n"]?.intValue)
    }

    /// `ops` is `diff_b64` decoded: the client simulation may use either.
    func testOpsAreTheDecodedDiff() throws {
        var checked = 0
        for c in try cases() {
            for (i, instruction) in c.instructions.enumerated() {
                let decoded = try HostMessageReader.ops(instruction.diff)
                XCTAssertEqual(decoded, instruction.ops, "\(c.name) instruction \(i + 1)")
                checked += 1
            }
        }
        print("corpus: ops equal the decoded diff_b64 in \(checked) instructions")
    }

    // MARK: The comparison itself

    /// Every way a `GoldenValue` can be wrong by one component.
    static func mutations(_ v: GoldenValue) -> [GoldenValue] {
        func pens(_ p: GoldenPen) -> [GoldenPen] {
            return [GoldenPen(fg: p.fg ^ 1, bg: p.bg, at: p.at), GoldenPen(fg: p.fg, bg: p.bg ^ 1, at: p.at),
                    GoldenPen(fg: p.fg, bg: p.bg, at: p.at ^ 1)]
        }
        switch v {
        case .int(let n): return [.int(n + 1)]
        case .uint(let n): return [.uint(n + 1)]
        case .bool(let b): return [.bool(!b)]
        case .ints(let a):
            var out: [GoldenValue] = [.ints(a + [0])]
            for i in a.indices {
                var b = a
                b[i] += 1
                out.append(.ints(b))
            }
            if !a.isEmpty { out.append(.ints(Array(a.dropLast()))) }
            return out
        case .text(let a):
            var out: [GoldenValue] = [.text(a + [0x78])]
            if !a.isEmpty {
                var b = a
                b[0] ^= 1
                out.append(.text(b))
                out.append(.text(Array(a.dropLast())))
            }
            return out
        case .name(let n): return [.name(n == "Ground" ? "Escape" : "Ground")]
        case .pen(let p): return pens(p).map { .pen($0) }
        case .saved(let c):
            var out: [GoldenSavedCursor] = []
            var m = c; m.row += 1; out.append(m)
            m = c; m.col += 1; out.append(m)
            m = c; m.autoWrapMode.toggle(); out.append(m)
            m = c; m.originMode.toggle(); out.append(m)
            for p in pens(c.pen) { m = c; m.pen = p; out.append(m) }
            return out.map { .saved($0) }
        }
    }

    /// The comparison is the instrument, so it is tested too: a state that is wrong in
    /// any single component of any of the 34 keys, or in any of the seven fields of a
    /// cell, is reported, and with the right field, row and column.
    func testTheComparisonNoticesEveryField() throws {
        let cases = try self.cases()
        var keyMutations = 0
        var cellMutations = 0
        // A state late in a full-screen case and one in the middle of an escape sequence.
        for name in ["syn-split", "syn-sgr", "syn-modes", "syn-osc"] {
            guard let c = cases.first(where: { $0.name == name }) else {
                XCTFail("no case \(name)")
                continue
            }
            var tally = CorpusTally()
            var picked: [(TerminalState, GoldenState)] = []
            _ = try CorpusRun.server(c, compare: false, tally: &tally) { number, server, _ in
                if number == c.server.count || number == c.server.count / 2 || number == 3 {
                    picked.append((server, c.server[number - 1]))
                }
            }
            for (state, golden) in picked {
                XCTAssertNil(CorpusComparison.firstDifference(state, golden, tally: &tally))
                for key in GoldenKey.allCases where key != .width && key != .height {
                    for wrong in CorpusTests.mutations(golden[key]) {
                        var g = golden
                        g[key] = wrong
                        let d = CorpusComparison.firstDifference(state, g, tally: &tally)
                        XCTAssertEqual(d?.field, key.jsonName, "\(name): \(key.jsonName) changed to \(wrong)")
                        XCTAssertNil(d?.row)
                        keyMutations += 1
                    }
                }
                // width and height also decide the shape of `rows`; whichever is reported
                // first, the state is not accepted.
                for key in [GoldenKey.width, .height] {
                    var g = golden
                    g[key] = CorpusTests.mutations(golden[key])[0]
                    XCTAssertEqual(CorpusComparison.firstDifference(state, g, tally: &tally)?.field, key.jsonName)
                    keyMutations += 1
                }
                var g = golden
                g.rows.removeLast()
                XCTAssertEqual(CorpusComparison.firstDifference(state, g, tally: &tally)?.field, "rows (number of rows)")
                g = golden
                g.rows[0].removeLast()
                XCTAssertEqual(CorpusComparison.firstDifference(state, g, tally: &tally)?.field, "rows (number of cells)")

                let h = golden.height, w = golden.width
                for (y, x) in [(0, 0), (0, w - 1), (h / 2, w / 2), (h - 1, 0), (h - 1, w - 1)] {
                    let cell = golden.rows[y][x]
                    var wrong: [(String, GoldenCell)] = []
                    var m = cell; m.contents.append(0x78); wrong.append(("contents", m))
                    m = cell; m.contents = cell.contents.isEmpty ? [0x20] : Array(cell.contents.dropLast()); wrong.append(("contents", m))
                    m = cell; m.pen.fg ^= 1; wrong.append(("fg", m))
                    m = cell; m.pen.bg ^= 1; wrong.append(("bg", m))
                    m = cell; m.pen.at ^= 1; wrong.append(("at", m))
                    m = cell; m.wide.toggle(); wrong.append(("wide", m))
                    m = cell; m.fallback.toggle(); wrong.append(("fallback", m))
                    m = cell; m.wrap.toggle(); wrong.append(("wrap", m))
                    for (field, wrongCell) in wrong {
                        var g = golden
                        g.rows[y][x] = wrongCell
                        let d = CorpusComparison.firstDifference(state, g, tally: &tally)
                        XCTAssertEqual(d?.field, "cell." + field, "\(name) row \(y) column \(x)")
                        XCTAssertEqual(d?.row, y)
                        XCTAssertEqual(d?.col, x)
                        cellMutations += 1
                    }
                }
            }
        }
        print("corpus comparison self-test: \(keyMutations) wrong keys and \(cellMutations) wrong cells, all reported")
    }

    /// A key that never changes in the corpus would be compared without being tested.
    /// Every key takes at least two values somewhere, and so does every field of a cell.
    func testEveryKeyAndCellFieldVariesInTheCorpus() throws {
        let cases = try self.cases()
        var first: [GoldenValue?] = Array(repeating: nil, count: GoldenKey.allCases.count)
        var varies = Array(repeating: false, count: GoldenKey.allCases.count)
        var cellFields = Set<String>()
        let blank = GoldenCell()
        for c in cases {
            for state in c.server + c.expected {
                for key in GoldenKey.allCases where !varies[key.rawValue] {
                    if let f = first[key.rawValue] {
                        if f != state[key] { varies[key.rawValue] = true }
                    } else {
                        first[key.rawValue] = state[key]
                    }
                }
            }
        }
        // Cells: the server's states, until every field has been seen with a value other
        // than its default (fallback cells are rare and never survive to the end of a case).
        search: for c in cases {
            for state in c.server {
                for row in state.rows {
                    for cell in row where cell != blank {
                        if !cell.contents.isEmpty { cellFields.insert("contents") }
                        if cell.pen.fg != 0 { cellFields.insert("fg") }
                        if cell.pen.bg != 0 { cellFields.insert("bg") }
                        if cell.pen.at != 0 { cellFields.insert("at") }
                        if cell.wide { cellFields.insert("wide") }
                        if cell.fallback { cellFields.insert("fallback") }
                        if cell.wrap { cellFields.insert("wrap") }
                    }
                }
                if cellFields.count == 7 { break search }
            }
        }
        let constant = GoldenKey.allCases.filter { !varies[$0.rawValue] }.map { $0.jsonName }
        XCTAssertEqual(constant, [], "keys with one value in the whole corpus")
        XCTAssertEqual(cellFields.sorted(), ["at", "bg", "contents", "fallback", "fg", "wide", "wrap"])
    }

    // MARK: Step 3: the port against the oracle

    /// Every case, every instruction, every field: the client's state is mosh's.
    func testClientStatesEqualTheOracle() throws {
        var tally = CorpusTally()
        var failed: [String] = []
        for c in try cases() {
            let result = try CorpusRun.client(c, tally: &tally)
            if let failure = result.failure {
                failed.append(c.name)
                XCTFail(failure)
            }
        }
        print("corpus client: \(tally.summary); \(failed.count) cases differ \(failed)")
    }

    /// The server's side: the terminal reads what the programs wrote, one read at a
    /// time. This is where the parser stops inside sequences and where tabs, the saved
    /// cursor, insert and origin mode move; a client never sees those.
    func testServerStatesEqualTheOracle() throws {
        var tally = CorpusTally()
        var failed: [String] = []
        for c in try cases() {
            if let failure = try CorpusRun.server(c, tally: &tally) {
                failed.append(c.name)
                XCTFail(failure)
            }
        }
        print("corpus server: \(tally.summary); \(failed.count) cases differ \(failed)")
    }

    // MARK: Step 4a: reload

    func testClientStatesEqualTheOracleWhenEveryStateIsReloaded() throws {
        var tally = CorpusTally()
        var failed: [String] = []
        for c in try cases() {
            let result = try CorpusRun.client(c, reload: true, tally: &tally)
            if let failure = result.failure {
                failed.append(c.name)
                XCTFail("reloaded: " + failure)
            }
        }
        print("corpus client, every state serialized and decoded before each use: \(tally.summary); "
            + "\(failed.count) cases differ \(failed)")
    }

    func testServerStatesEqualTheOracleWhenEveryStateIsReloaded() throws {
        var tally = CorpusTally()
        var failed: [String] = []
        for c in try cases() {
            if let failure = try CorpusRun.server(c, reload: .blobs, tally: &tally) {
                failed.append(c.name)
                XCTFail("reloaded: " + failure)
            }
        }
        print("corpus server, the terminal serialized and decoded around every read: \(tally.summary); "
            + "\(failed.count) cases differ \(failed)")
    }
}
