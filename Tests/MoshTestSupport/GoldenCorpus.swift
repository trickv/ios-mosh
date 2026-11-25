// Loader for the golden corpus of the terminal model
// (`Tests/MoshTerminalTests/Corpus/<case>/`), written from `Tools/mosh-oracle/FORMAT.md`.
// Section numbers in the comments are that document's.
//
// The loader is plain Swift plus Foundation for files and base64. It needs neither the
// oracle nor mosh, so it runs on a Mac too, and it does not import MoshTerminal: the
// types here are the corpus' own description of a state, which a test compares with
// whatever model it has (the terminal model in `MoshTerminalTests`, SwiftTerm in
// `SurfaceFeedTests`).
//
// Everything is checked while loading: unknown keys, wrong types, rows whose runs do
// not add up to the width, a `new_num` used twice and a base that does not exist are
// errors, not something to skip.

import Foundation

// MARK: - Errors

public struct GoldenCorpusError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: - A small JSON reader

/// A JSON value. Objects keep their members in file order.
///
/// Written here instead of using `JSONSerialization` so that the same code runs on Linux
/// and on a Mac, integers up to 2^64-1 stay exact, and `true` can never be read as 1.
public enum JSONValue {
    case null
    case bool(Bool)
    /// An integer that fits `Int64`.
    case int(Int64)
    /// An integer above `Int64.max`.
    case uint(UInt64)
    case double(Double)
    /// The string's scalar values are exactly those of the file (no normalization).
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    /// Parse one JSON document (the whole input).
    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var reader = JSONReader(bytes: bytes)
        reader.skipSpace()
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        if reader.pos != bytes.count { throw reader.fail("text after the value") }
        return value
    }

    /// The member of an object, nil if absent or if this is not an object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        for m in members where m.key == key { return m.value }
        return nil
    }

    public var members: [(key: String, value: JSONValue)]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var elements: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// An integer value as `Int`. nil for anything else, also for 1.0 and 1e3.
    public var intValue: Int? {
        if case .int(let i) = self { return Int(exactly: i) }
        return nil
    }

    public var uint64Value: UInt64? {
        switch self {
        case .int(let i): return UInt64(exactly: i)
        case .uint(let u): return u
        default: return nil
        }
    }
}

private struct JSONReader {
    let bytes: [UInt8]
    var pos = 0

    func fail(_ what: String) -> GoldenCorpusError {
        return GoldenCorpusError("JSON: \(what) at byte \(pos)")
    }

    mutating func skipSpace() {
        while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 {
            pos += 1
        }
    }

    mutating func literal(_ text: StaticString, _ value: JSONValue) throws -> JSONValue {
        let n = text.utf8CodeUnitCount
        guard pos + n <= bytes.count else { throw fail("unexpected end") }
        let matches = text.withUTF8Buffer { buf in (0..<n).allSatisfy { buf[$0] == bytes[pos + $0] } }
        guard matches else { throw fail("unknown literal") }
        pos += n
        return value
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard depth < 64 else { throw fail("nesting too deep") }
        guard pos < bytes.count else { throw fail("unexpected end") }
        switch bytes[pos] {
        case UInt8(ascii: "{"):
            pos += 1
            var members: [(key: String, value: JSONValue)] = []
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
            while true {
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("expected a member name") }
                let key = try string()
                if members.contains(where: { $0.key == key }) { throw fail("member \"\(key)\" twice") }
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                pos += 1
                skipSpace()
                members.append((key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard pos < bytes.count else { throw fail("unexpected end") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
                throw fail("expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            pos += 1
            var elements: [JSONValue] = []
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(elements) }
            while true {
                skipSpace()
                elements.append(try value(depth: depth + 1))
                skipSpace()
                guard pos < bytes.count else { throw fail("unexpected end") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(elements) }
                throw fail("expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        default:
            return try number()
        }
    }

    mutating func number() throws -> JSONValue {
        let start = pos
        var integer = true
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        let digitsStart = pos
        while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        guard pos > digitsStart else { throw fail("expected a value") }
        if pos - digitsStart > 1, bytes[digitsStart] == 0x30 { throw fail("leading zero") }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            integer = false
            pos += 1
            let fraction = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            guard pos > fraction else { throw fail("digits expected after '.'") }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            integer = false
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            let exponent = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            guard pos > exponent else { throw fail("digits expected in the exponent") }
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        if integer {
            if let i = Int64(text) { return .int(i) }
            if let u = UInt64(text) { return .uint(u) }
        }
        guard let d = Double(text) else { throw fail("bad number") }
        return .double(d)
    }

    mutating func hex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail("unexpected end in \\u") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[pos]
            let d: UInt8
            switch c {
            case 0x30...0x39: d = c - 0x30
            case 0x41...0x46: d = c - 0x41 + 10
            case 0x61...0x66: d = c - 0x61 + 10
            default: throw fail("bad hex digit in \\u")
            }
            v = v << 4 | UInt32(d)
            pos += 1
        }
        return v
    }

    /// A string. `pos` is at the opening quote.
    mutating func string() throws -> String {
        pos += 1
        var out: [UInt8] = []
        while true {
            guard pos < bytes.count else { throw fail("unterminated string") }
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: "\"") { break }
            if c < 0x20 { throw fail("control character in a string") }
            if c != UInt8(ascii: "\\") { out.append(c); continue }
            guard pos < bytes.count else { throw fail("unterminated string") }
            let e = bytes[pos]
            pos += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if scalar >= 0xD800, scalar <= 0xDBFF {
                    guard pos + 2 <= bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                        throw fail("high surrogate without a low one")
                    }
                    pos += 2
                    let low = try hex4()
                    guard low >= 0xDC00, low <= 0xDFFF else { throw fail("high surrogate without a low one") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if scalar >= 0xDC00, scalar <= 0xDFFF {
                    throw fail("low surrogate alone")
                }
                guard let u = Unicode.Scalar(scalar) else { throw fail("bad \\u escape") }
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default:
                throw fail("unknown escape")
            }
        }
        let s = String(decoding: out, as: UTF8.self)
        // `String(decoding:)` repairs bad UTF-8 silently; refuse it instead.
        guard Array(s.utf8) == out else { throw fail("string is not valid UTF-8") }
        return s
    }
}

// MARK: - States (section 5)

/// A renditions object (5.3): the three numbers exactly as mosh stores them.
public struct GoldenPen: Equatable, Sendable, CustomStringConvertible {
    public var fg: UInt32
    public var bg: UInt32
    public var at: UInt8

    public init(fg: UInt32 = 0, bg: UInt32 = 0, at: UInt8 = 0) {
        self.fg = fg
        self.bg = bg
        self.at = at
    }

    public var description: String { return "{fg \(fg), bg \(bg), at \(at)}" }
}

/// One cell (5.4). `contents` are the cell's UTF-8 bytes; an empty cell has none.
public struct GoldenCell: Equatable, Sendable, CustomStringConvertible {
    public var contents: [UInt8]
    public var pen: GoldenPen
    public var wide: Bool
    public var fallback: Bool
    public var wrap: Bool

    public init(contents: [UInt8] = [], pen: GoldenPen = GoldenPen(), wide: Bool = false, fallback: Bool = false,
                wrap: Bool = false) {
        self.contents = contents
        self.pen = pen
        self.wide = wide
        self.fallback = fallback
        self.wrap = wrap
    }

    public var description: String {
        var s = "[" + contents.map { String($0, radix: 16) }.joined(separator: " ") + "]"
        s += " \"" + String(decoding: contents, as: UTF8.self) + "\" " + pen.description
        if wide { s += " wide" }
        if fallback { s += " fallback" }
        if wrap { s += " wrap" }
        return s
    }
}

/// The `saved` object (DECSC).
public struct GoldenSavedCursor: Equatable, Sendable, CustomStringConvertible {
    public var row: Int
    public var col: Int
    public var pen: GoldenPen
    public var autoWrapMode: Bool
    public var originMode: Bool

    public init(row: Int = 0, col: Int = 0, pen: GoldenPen = GoldenPen(), autoWrapMode: Bool = true,
                originMode: Bool = false) {
        self.row = row
        self.col = col
        self.pen = pen
        self.autoWrapMode = autoWrapMode
        self.originMode = originMode
    }

    public var description: String {
        return "{cursor [\(row), \(col)], pen \(pen), auto_wrap_mode \(autoWrapMode), origin_mode \(originMode)}"
    }
}

/// The value of one key of a state.
public enum GoldenValue: Equatable, Sendable, CustomStringConvertible {
    case int(Int)
    case uint(UInt64)
    case bool(Bool)
    /// `[row, col]` and the other arrays of integers, also the byte arrays.
    case ints([Int])
    /// A string, as its Unicode scalar values (5.5).
    case text([UInt32])
    /// `parser_state`.
    case name(String)
    case pen(GoldenPen)
    case saved(GoldenSavedCursor)

    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .bool(let b): return String(b)
        case .ints(let a): return "\(a)"
        case .text(let t):
            var s = String.UnicodeScalarView()
            for v in t { s.append(Unicode.Scalar(v) ?? "\u{FFFD}") }
            return "\"\(String(s))\" \(t.map { String($0, radix: 16) })"
        case .name(let n): return n
        case .pen(let p): return p.description
        case .saved(let s): return s.description
        }
    }
}

/// The keys of a state line, in the order of the table in 5.2.
public enum GoldenKey: Int, CaseIterable, Sendable {
    case width, height, cursor, combining, defaultTabs, tabs, scrollRegion, pen, saved
    case nextPrintWillWrap, originMode, autoWrapMode, insertMode, cursorVisible, reverseVideo, bracketedPaste
    case mouseReportingMode, mouseFocusEvent, mouseAlternateScroll, mouseEncodingMode, applicationModeCursorKeys
    case iconName, windowTitle, titleInitialized, clipboard, bellCount, echoAck
    case parserState, utf8Buf, params, dispatchChars, parsed, parsedParams, oscString

    /// The key as written in the files.
    public var jsonName: String {
        switch self {
        case .width: return "width"
        case .height: return "height"
        case .cursor: return "cursor"
        case .combining: return "combining"
        case .defaultTabs: return "default_tabs"
        case .tabs: return "tabs"
        case .scrollRegion: return "scroll_region"
        case .pen: return "pen"
        case .saved: return "saved"
        case .nextPrintWillWrap: return "next_print_will_wrap"
        case .originMode: return "origin_mode"
        case .autoWrapMode: return "auto_wrap_mode"
        case .insertMode: return "insert_mode"
        case .cursorVisible: return "cursor_visible"
        case .reverseVideo: return "reverse_video"
        case .bracketedPaste: return "bracketed_paste"
        case .mouseReportingMode: return "mouse_reporting_mode"
        case .mouseFocusEvent: return "mouse_focus_event"
        case .mouseAlternateScroll: return "mouse_alternate_scroll"
        case .mouseEncodingMode: return "mouse_encoding_mode"
        case .applicationModeCursorKeys: return "application_mode_cursor_keys"
        case .iconName: return "icon_name"
        case .windowTitle: return "window_title"
        case .titleInitialized: return "title_initialized"
        case .clipboard: return "clipboard"
        case .bellCount: return "bell_count"
        case .echoAck: return "echo_ack"
        case .parserState: return "parser_state"
        case .utf8Buf: return "utf8_buf"
        case .params: return "params"
        case .dispatchChars: return "dispatch_chars"
        case .parsed: return "parsed"
        case .parsedParams: return "parsed_params"
        case .oscString: return "osc_string"
        }
    }

    static let byName: [String: GoldenKey] = {
        var d: [String: GoldenKey] = [:]
        for k in GoldenKey.allCases { d[k.jsonName] = k }
        return d
    }()

    /// The names `parser_state` can have.
    public static let parserStates: Set<String> = [
        "Ground", "Escape", "Escape_Intermediate", "CSI_Entry", "CSI_Param", "CSI_Intermediate", "CSI_Ignore",
        "DCS_Entry", "DCS_Param", "DCS_Intermediate", "DCS_Passthrough", "DCS_Ignore", "OSC_String",
        "SOS_PM_APC_String",
    ]
}

/// One complete state: a value for every key and all rows.
public struct GoldenState: Sendable {
    /// `num` of the line. Not part of the state.
    public var num: UInt64
    /// Indexed by `GoldenKey.rawValue`.
    public var values: [GoldenValue]
    /// `height` rows of `width` cells. Rows that did not change share storage with the
    /// previous state's.
    public var rows: [[GoldenCell]]

    public subscript(key: GoldenKey) -> GoldenValue {
        get { return values[key.rawValue] }
        set { values[key.rawValue] = newValue }
    }

    public var width: Int {
        if case .int(let w) = self[.width] { return w }
        return 0
    }

    public var height: Int {
        if case .int(let h) = self[.height] { return h }
        return 0
    }

    public var cursorRow: Int {
        if case .ints(let c) = self[.cursor] { return c[0] }
        return 0
    }

    public var cursorCol: Int {
        if case .ints(let c) = self[.cursor] { return c[1] }
        return 0
    }

    /// The initial state of 5.1 and 5.2: a fresh terminal of the given size.
    public init(width: Int, height: Int) {
        num = 0
        var v = [GoldenValue](repeating: .int(0), count: GoldenKey.allCases.count)
        for key in GoldenKey.allCases {
            let value: GoldenValue
            switch key {
            case .width: value = .int(width)
            case .height: value = .int(height)
            case .cursor, .combining: value = .ints([0, 0])
            case .defaultTabs, .autoWrapMode, .cursorVisible: value = .bool(true)
            case .tabs: value = .ints(Array(stride(from: 0, to: width, by: 8)))
            case .scrollRegion: value = .ints([0, height - 1])
            case .pen: value = .pen(GoldenPen())
            case .saved: value = .saved(GoldenSavedCursor())
            case .nextPrintWillWrap, .originMode, .insertMode, .reverseVideo, .bracketedPaste, .mouseFocusEvent,
                 .mouseAlternateScroll, .applicationModeCursorKeys, .titleInitialized, .parsed:
                value = .bool(false)
            case .mouseReportingMode, .mouseEncodingMode, .bellCount: value = .int(0)
            case .echoAck: value = .uint(0)
            case .iconName, .windowTitle, .clipboard, .params, .oscString: value = .text([])
            case .parserState: value = .name("Ground")
            case .utf8Buf, .dispatchChars, .parsedParams: value = .ints([])
            }
            v[key.rawValue] = value
        }
        values = v
        rows = Array(repeating: Array(repeating: GoldenCell(), count: width), count: height)
    }

    // MARK: Reading a line

    /// Apply one line of `expected.jsonl` or `server.jsonl` to this state (the delta
    /// rule, 5.1). Returns the decoded `reply_b64` of the line, empty if it has none.
    @discardableResult
    public mutating func apply(line: JSONValue) throws -> [UInt8] {
        guard let members = line.members else { throw GoldenCorpusError("a state line is not an object") }
        guard let n = line["num"]?.uint64Value else { throw GoldenCorpusError("state line without num") }
        num = n
        var reply: [UInt8] = []
        var rowsValue: JSONValue?
        var sizeChanged = false

        for (name, value) in members {
            switch name {
            case "num": continue
            case "rows": rowsValue = value
            case "reply_b64":
                guard let s = value.stringValue, let data = Data(base64Encoded: s) else {
                    throw GoldenCorpusError("state \(n): reply_b64 is not base64")
                }
                reply = [UInt8](data)
            default:
                guard let key = GoldenKey.byName[name] else {
                    throw GoldenCorpusError("state \(n): unknown key \"\(name)\"")
                }
                let parsed = try GoldenState.parseValue(key, value, state: n)
                if key == .width || key == .height, parsed != self[key] { sizeChanged = true }
                self[key] = parsed
            }
        }

        let width = self.width, height = self.height
        guard width >= 1, height >= 1 else { throw GoldenCorpusError("state \(n): bad size") }

        if sizeChanged {
            // Every row is listed, each as an array of runs; the old rows are discarded.
            guard let listed = rowsValue?.members, listed.count == height else {
                throw GoldenCorpusError("state \(n): the size changed but rows does not list every row")
            }
            var newRows = [[GoldenCell]?](repeating: nil, count: height)
            for (index, runs) in listed {
                guard let y = Int(index), y >= 0, y < height, String(y) == index, newRows[y] == nil else {
                    throw GoldenCorpusError("state \(n): bad row index \"\(index)\"")
                }
                newRows[y] = try GoldenState.parseRow(runs, width: width, what: "state \(n) row \(y)")
            }
            rows = newRows.map { $0! }
        } else if let rowsValue = rowsValue {
            guard let listed = rowsValue.members else { throw GoldenCorpusError("state \(n): rows is not an object") }
            // Integers refer to the rows as they were before this line.
            let old = rows
            var seen = Set<Int>()
            for (index, value) in listed {
                guard let y = Int(index), y >= 0, y < height, String(y) == index, seen.insert(y).inserted else {
                    throw GoldenCorpusError("state \(n): bad row index \"\(index)\"")
                }
                if let j = value.intValue {
                    guard j >= 0, j < old.count else { throw GoldenCorpusError("state \(n) row \(y): no old row \(j)") }
                    rows[y] = old[j]
                } else {
                    rows[y] = try GoldenState.parseRow(value, width: width, what: "state \(n) row \(y)")
                }
            }
        }
        return reply
    }

    static func intArray(_ value: JSONValue, count: Int? = nil, range: ClosedRange<Int>, _ what: String) throws -> [Int] {
        guard let elements = value.elements else { throw GoldenCorpusError("\(what) is not an array") }
        if let count = count, elements.count != count { throw GoldenCorpusError("\(what) does not have \(count) elements") }
        return try elements.map { e in
            guard let i = e.intValue, range.contains(i) else { throw GoldenCorpusError("\(what): bad element") }
            return i
        }
    }

    static func pen(_ value: JSONValue, _ what: String, extraKeys: Bool = false) throws -> GoldenPen {
        guard let members = value.members else { throw GoldenCorpusError("\(what) is not an object") }
        var p = GoldenPen()
        for (name, v) in members {
            switch name {
            case "fg":
                guard let i = v.intValue, let c = UInt32(exactly: i), c <= 0x1FF_FFFF else { throw GoldenCorpusError("\(what): bad fg") }
                p.fg = c
            case "bg":
                guard let i = v.intValue, let c = UInt32(exactly: i), c <= 0x1FF_FFFF else { throw GoldenCorpusError("\(what): bad bg") }
                p.bg = c
            case "at":
                guard let i = v.intValue, let a = UInt8(exactly: i) else { throw GoldenCorpusError("\(what): bad at") }
                p.at = a
            default:
                if !extraKeys { throw GoldenCorpusError("\(what): unknown member \"\(name)\"") }
            }
        }
        return p
    }

    static func parseValue(_ key: GoldenKey, _ value: JSONValue, state n: UInt64) throws -> GoldenValue {
        let what = "state \(n): \(key.jsonName)"
        switch key {
        case .width, .height:
            guard let i = value.intValue, i >= 1 else { throw GoldenCorpusError("\(what) is not a positive integer") }
            return .int(i)
        case .mouseReportingMode, .mouseEncodingMode, .bellCount:
            guard let i = value.intValue, i >= 0 else { throw GoldenCorpusError("\(what) is not an integer") }
            return .int(i)
        case .echoAck:
            guard let u = value.uint64Value else { throw GoldenCorpusError("\(what) is not an unsigned integer") }
            return .uint(u)
        case .cursor, .scrollRegion:
            return .ints(try intArray(value, count: 2, range: 0...Int(Int32.max), what))
        case .combining:
            return .ints(try intArray(value, count: 2, range: -1...Int(Int32.max), what))
        case .tabs:
            return .ints(try intArray(value, range: 0...Int(Int32.max), what))
        case .utf8Buf, .dispatchChars:
            return .ints(try intArray(value, range: 0...255, what))
        case .parsedParams:
            return .ints(try intArray(value, range: -1...65535, what))
        case .defaultTabs, .nextPrintWillWrap, .originMode, .autoWrapMode, .insertMode, .cursorVisible, .reverseVideo,
             .bracketedPaste, .mouseFocusEvent, .mouseAlternateScroll, .applicationModeCursorKeys, .titleInitialized,
             .parsed:
            guard let b = value.boolValue else { throw GoldenCorpusError("\(what) is not a boolean") }
            return .bool(b)
        case .iconName, .windowTitle, .clipboard, .params, .oscString:
            guard let s = value.stringValue else { throw GoldenCorpusError("\(what) is not a string") }
            return .text(s.unicodeScalars.map { $0.value })
        case .parserState:
            guard let s = value.stringValue, GoldenKey.parserStates.contains(s) else {
                throw GoldenCorpusError("\(what) is not a parser state")
            }
            return .name(s)
        case .pen:
            return .pen(try pen(value, what))
        case .saved:
            guard let members = value.members, members.count == 4, let cursor = value["cursor"], let p = value["pen"],
                  let wrap = value["auto_wrap_mode"]?.boolValue, let origin = value["origin_mode"]?.boolValue else {
                throw GoldenCorpusError("\(what) does not have exactly its four members")
            }
            let c = try intArray(cursor, count: 2, range: 0...Int(Int32.max), what)
            return .saved(GoldenSavedCursor(row: c[0], col: c[1], pen: try pen(p, what), autoWrapMode: wrap,
                                            originMode: origin))
        }
    }

    /// A row: an array of runs whose cell counts add up to `width` (5.4).
    public static func parseRow(_ value: JSONValue, width: Int, what: String) throws -> [GoldenCell] {
        guard let runs = value.elements else { throw GoldenCorpusError("\(what) is neither runs nor a row number") }
        var cells: [GoldenCell] = []
        cells.reserveCapacity(width)
        for run in runs {
            guard let members = run.members else { throw GoldenCorpusError("\(what): a run is not an object") }
            var cell = GoldenCell(pen: try pen(run, what, extraKeys: true))
            var contents: [[UInt8]]?
            var contentKeys = 0
            for (name, v) in members {
                switch name {
                case "fg", "bg", "at": continue
                case "wide", "fallback", "wrap":
                    guard let b = v.boolValue else { throw GoldenCorpusError("\(what): \(name) is not a boolean") }
                    if name == "wide" { cell.wide = b } else if name == "fallback" { cell.fallback = b } else { cell.wrap = b }
                case "t":
                    contentKeys += 1
                    guard let s = v.stringValue, !s.isEmpty else { throw GoldenCorpusError("\(what): bad t") }
                    let bytes = Array(s.utf8)
                    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                        throw GoldenCorpusError("\(what): t holds something that is not printable ASCII")
                    }
                    contents = bytes.map { [$0] }
                case "c":
                    contentKeys += 1
                    guard let strings = v.elements, !strings.isEmpty else { throw GoldenCorpusError("\(what): bad c") }
                    contents = try strings.map { e in
                        guard let s = e.stringValue else { throw GoldenCorpusError("\(what): c element is not a string") }
                        return Array(s.utf8)
                    }
                case "e":
                    contentKeys += 1
                    guard let count = v.intValue, count >= 1, count <= width else { throw GoldenCorpusError("\(what): bad e") }
                    contents = Array(repeating: [], count: count)
                default:
                    throw GoldenCorpusError("\(what): unknown run key \"\(name)\"")
                }
            }
            guard contentKeys == 1, let list = contents else {
                throw GoldenCorpusError("\(what): a run needs exactly one of t, c, e")
            }
            for bytes in list {
                cell.contents = bytes
                cells.append(cell)
            }
        }
        guard cells.count == width else {
            throw GoldenCorpusError("\(what): runs describe \(cells.count) cells, the width is \(width)")
        }
        return cells
    }
}

// MARK: - Session and instructions (sections 3 and 4)

/// One element of `ops`: what `Complete::apply_string` does with one instruction.
public enum GoldenOp: Equatable, Sendable {
    case hostBytes([UInt8])
    case resize(width: Int, height: Int)
    case echoAck(UInt64)
}

/// One line of `instructions.jsonl`.
public struct GoldenInstruction: Sendable {
    public var oldNum: UInt64
    public var newNum: UInt64
    /// The serialized `HostBuffers.HostMessage`; empty for an empty diff.
    public var diff: [UInt8]
    public var ops: [GoldenOp]
}

/// One step of `session.jsonl` (every line but the first).
public enum GoldenSessionStep: Equatable, Sendable {
    case bytes([UInt8])
    case resize(width: Int, height: Int)
    case echoAck(UInt64)
}

/// One case of the corpus, every state rebuilt from the delta lines.
public struct GoldenCase: Sendable {
    public var name: String
    /// Size of state 0 (`meta.json`).
    public var width: Int
    public var height: Int
    /// Empty when the directory has no `session.jsonl` (a live recording).
    public var session: [GoldenSessionStep]
    public var instructions: [GoldenInstruction]
    /// The client's state after each instruction; `expected[i]` belongs to `instructions[i]`.
    public var expected: [GoldenState]
    /// The server's own state after each session step; `server[k]` belongs to `session[k]`.
    public var server: [GoldenState]
    /// What the terminal answered to the host during each session step (`reply_b64`).
    public var replies: [[UInt8]]

    /// The blank terminal both sides start from.
    public var initialState: GoldenState { return GoldenState(width: width, height: height) }
}

public enum GoldenCorpus {
    /// The corpus directory, found from this file's place in the source tree.
    public static let directory: String = {
        var url = URL(fileURLWithPath: #filePath)   // Tests/MoshTestSupport/GoldenCorpus.swift
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("MoshTerminalTests").appendingPathComponent("Corpus").path
    }()

    /// The names of the cases (directories with a `meta.json`), sorted.
    public static func caseNames() throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        return entries.filter { FileManager.default.fileExists(atPath: "\(directory)/\($0)/meta.json") }.sorted()
    }

    public static func loadAll() throws -> [GoldenCase] {
        return try caseNames().map { try load($0) }
    }

    public static func load(_ name: String) throws -> GoldenCase {
        return try load(directory: "\(directory)/\(name)", name: name)
    }

    static func lines(_ path: String) throws -> [JSONValue]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var out: [JSONValue] = []
        var number = 0
        for line in [UInt8](data).split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            number += 1
            do {
                out.append(try JSONValue.parse(Array(line)))
            } catch {
                throw GoldenCorpusError("\(path) line \(number): \(error)")
            }
        }
        return out
    }

    static func base64(_ value: JSONValue?, _ what: String) throws -> [UInt8] {
        guard let s = value?.stringValue, let data = Data(base64Encoded: s) else {
            throw GoldenCorpusError("\(what) is not base64")
        }
        return [UInt8](data)
    }

    static func size(_ value: JSONValue, _ what: String) throws -> (Int, Int) {
        guard let a = value.elements, a.count == 2, let w = a[0].intValue, let h = a[1].intValue, w >= 1, h >= 1 else {
            throw GoldenCorpusError("\(what) is not [w, h]")
        }
        return (w, h)
    }

    /// Load a case from any directory. `meta.json` and `instructions.jsonl` are required.
    public static func load(directory dir: String, name: String) throws -> GoldenCase {
        do {
            return try loadChecked(directory: dir, name: name)
        } catch let e as GoldenCorpusError {
            throw GoldenCorpusError("\(name): \(e.description)")
        }
    }

    private static func loadChecked(directory dir: String, name: String) throws -> GoldenCase {
        guard let metaLines = try lines("\(dir)/meta.json"), metaLines.count == 1 else {
            throw GoldenCorpusError("meta.json is missing or not one line")
        }
        let meta = metaLines[0]
        guard meta["format"]?.intValue == 1 else { throw GoldenCorpusError("meta.json: format is not 1") }
        guard let width = meta["width"]?.intValue, let height = meta["height"]?.intValue, width >= 1, height >= 1 else {
            throw GoldenCorpusError("meta.json: bad size")
        }

        // session.jsonl
        var session: [GoldenSessionStep] = []
        let sessionLines = try lines("\(dir)/session.jsonl")
        if let sessionLines = sessionLines {
            guard let head = sessionLines.first, head["width"]?.intValue == width, head["height"]?.intValue == height else {
                throw GoldenCorpusError("session.jsonl line 1 does not have the size of meta.json")
            }
            for (i, line) in sessionLines.dropFirst().enumerated() {
                let what = "session.jsonl line \(i + 2)"
                let present = ["bytes_b64", "resize", "echo_ack"].filter { line[$0] != nil }
                guard present.count == 1 else { throw GoldenCorpusError("\(what): need exactly one of bytes_b64, resize, echo_ack") }
                if let b = line["bytes_b64"] {
                    session.append(.bytes(try base64(b, "\(what): bytes_b64")))
                } else if let r = line["resize"] {
                    let (w, h) = try size(r, "\(what): resize")
                    session.append(.resize(width: w, height: h))
                } else {
                    guard let n = line["echo_ack"]?.uint64Value else { throw GoldenCorpusError("\(what): bad echo_ack") }
                    session.append(.echoAck(n))
                }
            }
        }

        // instructions.jsonl
        guard let instructionLines = try lines("\(dir)/instructions.jsonl") else {
            throw GoldenCorpusError("instructions.jsonl is missing")
        }
        var instructions: [GoldenInstruction] = []
        var known: Set<UInt64> = [0]
        for (i, line) in instructionLines.enumerated() {
            let what = "instructions.jsonl line \(i + 1)"
            guard let members = line.members, members.count == 4, let old = line["old_num"]?.uint64Value,
                  let new = line["new_num"]?.uint64Value, let opsValue = line["ops"]?.elements else {
                throw GoldenCorpusError("\(what): need old_num, new_num, diff_b64, ops")
            }
            let diff = try base64(line["diff_b64"], "\(what): diff_b64")
            guard known.contains(old) else { throw GoldenCorpusError("\(what): base state \(old) was never received") }
            guard known.insert(new).inserted else { throw GoldenCorpusError("\(what): new_num \(new) appears twice") }
            var ops: [GoldenOp] = []
            for op in opsValue {
                guard let m = op.members, m.count == 1 else { throw GoldenCorpusError("\(what): an op needs exactly one key") }
                switch m[0].key {
                case "hostbytes_b64": ops.append(.hostBytes(try base64(m[0].value, "\(what): hostbytes_b64")))
                case "resize":
                    let (w, h) = try size(m[0].value, "\(what): resize")
                    ops.append(.resize(width: w, height: h))
                case "echo_ack":
                    guard let n = m[0].value.uint64Value else { throw GoldenCorpusError("\(what): bad echo_ack") }
                    ops.append(.echoAck(n))
                default: throw GoldenCorpusError("\(what): unknown op \"\(m[0].key)\"")
                }
            }
            if diff.isEmpty, !ops.isEmpty { throw GoldenCorpusError("\(what): an empty diff with ops") }
            instructions.append(GoldenInstruction(oldNum: old, newNum: new, diff: diff, ops: ops))
        }

        // expected.jsonl
        var expected: [GoldenState] = []
        if let stateLines = try lines("\(dir)/expected.jsonl") {
            guard stateLines.count == instructions.count else {
                throw GoldenCorpusError("expected.jsonl has \(stateLines.count) lines for \(instructions.count) instructions")
            }
            var current = GoldenState(width: width, height: height)
            for (i, line) in stateLines.enumerated() {
                do {
                    let reply = try current.apply(line: line)
                    guard reply.isEmpty else { throw GoldenCorpusError("reply_b64 in a client state") }
                } catch let e as GoldenCorpusError {
                    throw GoldenCorpusError("expected.jsonl line \(i + 1): \(e.description)")
                }
                guard current.num == instructions[i].newNum else {
                    throw GoldenCorpusError("expected.jsonl line \(i + 1): num is not the instruction's new_num")
                }
                expected.append(current)
            }
        }

        // server.jsonl
        var server: [GoldenState] = []
        var replies: [[UInt8]] = []
        if let stateLines = try lines("\(dir)/server.jsonl") {
            guard sessionLines != nil, stateLines.count == session.count else {
                throw GoldenCorpusError("server.jsonl has \(stateLines.count) lines for \(session.count) session steps")
            }
            var current = GoldenState(width: width, height: height)
            for (i, line) in stateLines.enumerated() {
                do {
                    replies.append(try current.apply(line: line))
                } catch let e as GoldenCorpusError {
                    throw GoldenCorpusError("server.jsonl line \(i + 1): \(e.description)")
                }
                guard current.num == UInt64(i + 1) else {
                    throw GoldenCorpusError("server.jsonl line \(i + 1): num is not the state number")
                }
                server.append(current)
            }
        }

        return GoldenCase(name: name, width: width, height: height, session: session, instructions: instructions,
                          expected: expected, server: server, replies: replies)
    }
}
