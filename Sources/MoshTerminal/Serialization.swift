// A stable binary form of the whole terminal state, for the resume snapshot.
//
// Everything `TerminalState` holds is written: the framebuffer (cells, per-row soft-wrap
// marks, titles, clipboard, bell count), every field of the draw state including the
// ones `Display::new_frame` never transmits (pen, saved cursor, tab stops, scrolling
// region, origin / insert / autowrap modes, pending wrap, combining-character position),
// the parser state with the bytes of an incomplete UTF-8 character, the dispatcher's
// partial sequence (parameters, intermediates, OSC string, pending reply), the user-input
// state, the input history and the echo ack. A state reloaded in the middle of an escape
// sequence continues exactly where it stopped.
//
// Row objects: which lines share a row object is kept, and so are the rows' generation
// numbers (`Row.gen`), because `DisplayDiff.newFrame` uses both for its scroll shortcut.
// Decoding calls `RowGeneration.reserve` so that rows made later stay distinct.
//
// Format, version 1. `varint` is unsigned LEB128 (7 bits per byte, low bits first, at
// most 10 bytes); `zigzag` is a varint of `(n << 1) ^ (n >> 63)`.
//
//   state    := skeleton rows
//   skeleton := u8 version (= 1)
//               u8 flags0   bit 0 nextPrintWillWrap, 1 originMode, 2 autoWrapMode, 3 insertMode,
//                           4 cursorVisible, 5 reverseVideo, 6 bracketedPaste, 7 mouseFocusEvent
//               u8 flags1   bit 0 mouseAlternateScroll, 1 applicationModeCursorKeys, 2 defaultTabs,
//                           3 titleInitialized, 4 dispatcher.parsed, 5 saved autoWrapMode,
//                           6 saved originMode, 7 a tab bitmap follows (otherwise the tab
//                           stops are the default ones, every 8 columns)
//               varint width, height
//               varint cursorCol, cursorRow
//               zigzag combiningCharCol, combiningCharRow            (-1 = none)
//               varint scrollingRegionTopRow, scrollingRegionBottomRow
//               rend                                                  the pen
//               zigzag saved cursorCol, saved cursorRow; rend         the saved cursor
//               varint mouseReportingMode, mouseEncodingMode          (0, 9, 1000...; 0, 1005...)
//               [ (width + 7) / 8 bytes: tab stops, column c is bit c % 8 of byte c / 8 ]
//               varint bellCount
//               points iconName, windowTitle, clipboard
//               varint echoAck
//               varint n, n * (varint frameNum, varint timestamp)     input history
//               u8 parser state (ParserState raw value)
//               u8 k (< 8), k bytes                                   incomplete UTF-8 character
//               bytes params
//               varint n, n * zigzag                                  parsedParams
//               bytes dispatchChars
//               points oscString
//               bytes terminalToHost
//               u8 user-input state
//   rows     := height * line
//   line     := varint 0, row            a row object not seen before
//             | varint n (>= 1)          the same row object as line n - 1
//   row      := varint width, varint gen, items producing exactly `width` cells
//   item     := 0x01 varint n            n empty cells in the current rendition (n >= 1)
//             | 0x02 rend                set the current rendition (starts as the default)
//             | 0x03 varint n            the previous cell n more times (n >= 1)
//             | 0x04 u8 flags, bytes     any cell: flags bit 0 wide, 1 fallback, 2 wrap
//             | 0x05 literal             a wide cell
//             | literal                  a cell without flags
//   literal  := one byte 0x20...0x7E | a lead byte 0xC0...0xF7 and its 1, 2 or 3 following bytes
//   rend     := varint foreground, varint background, u8 attributes   (mosh's encoding)
//   bytes    := varint n, n bytes
//   points   := varint n, n * varint                                  code points
//
// A blank 80x24 screen is about 60 bytes, a full screen of text 2 to 4 KB.
//
// Decoding checks every length against the input and every value against the model's
// invariants (cursor inside the screen, row widths, enum values, ...). It throws
// `TerminalSerializationError`; it does not trap, whatever the input.

/// Why a serialized terminal state was rejected.
public enum TerminalSerializationError: Error, Equatable, Sendable {
    /// The input ends before the state does.
    case truncated
    /// The first byte is not a version this code reads.
    case unsupportedVersion(UInt8)
    /// Bytes are left after the end of the state.
    case trailingBytes
    /// A value is outside what the terminal model allows.
    case invalid(String)
}

/// Constants of the serialized form.
public enum TerminalSerialization {
    /// The version byte written by `TerminalState.serialized()`. Row bytes
    /// (`Row.serialized()`) carry no version of their own; a container that stores rows
    /// apart from the states should record this value once.
    public static let version: UInt8 = 1
    /// Largest width or height the decoder accepts.
    public static let maxDimension = 32767
    /// Largest number of cells in distinct rows of one state that the decoder accepts
    /// (bounds the memory a damaged input can ask for).
    public static let maxCells = 1 << 20
    /// Largest cell contents the decoder accepts, in bytes. mosh stops appending
    /// combining characters at 32 bytes, so real cells stay below 40.
    public static let maxCellBytes = 64
}

// MARK: - Byte writer and reader

private struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    /// A count or coordinate. Never negative in a valid state; a negative value would be
    /// written as a huge number, which the decoder rejects.
    mutating func varint(_ value: Int) { varint(UInt64(truncatingIfNeeded: value)) }

    mutating func zigzag(_ value: Int) {
        let v = Int64(value)
        varint(UInt64(bitPattern: (v << 1) ^ (v >> 63)))
    }

    mutating func byteString(_ b: [UInt8]) {
        varint(b.count)
        bytes.append(contentsOf: b)
    }

    mutating func points(_ p: [UInt32]) {
        varint(p.count)
        for c in p { varint(UInt64(c)) }
    }

    mutating func rend(_ r: Renditions) {
        varint(UInt64(r.foregroundColor))
        varint(UInt64(r.backgroundColor))
        u8(r.attributes)
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { return bytes.count - pos }
    var atEnd: Bool { return pos >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw TerminalSerializationError.truncated }
        let b = bytes[pos]
        pos += 1
        return b
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try u8()
            let part = UInt64(b & 0x7F)
            if shift == 63 && part > 1 { throw TerminalSerializationError.invalid("number too large") }
            result |= part << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw TerminalSerializationError.invalid("number too long") }
        }
    }

    /// A number in `0...max`.
    mutating func int(max: Int, _ what: @autoclosure () -> String) throws -> Int {
        let v = try varint()
        guard v <= UInt64(max) else { throw TerminalSerializationError.invalid("\(what()) out of range") }
        return Int(v)
    }

    /// A signed number in `min...max`.
    mutating func zigzag(min: Int, max: Int, _ what: @autoclosure () -> String) throws -> Int {
        let raw = try varint()
        let v = Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
        guard v >= Int64(min) && v <= Int64(max) else { throw TerminalSerializationError.invalid("\(what()) out of range") }
        return Int(v)
    }

    /// A count of elements that each take at least one byte: more than the input holds
    /// is a truncated input, not a reason to reserve memory.
    mutating func count(max: Int = Int.max, _ what: @autoclosure () -> String) throws -> Int {
        let v = try varint()
        guard v <= UInt64(remaining) else { throw TerminalSerializationError.truncated }
        guard v <= UInt64(max) else { throw TerminalSerializationError.invalid("\(what()) too long") }
        return Int(v)
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0 && n <= remaining else { throw TerminalSerializationError.truncated }
        let out = Array(bytes[pos..<(pos + n)])
        pos += n
        return out
    }

    mutating func byteString(max: Int = Int.max, _ what: @autoclosure () -> String) throws -> [UInt8] {
        let n = try count(max: max, what())
        return try take(n)
    }

    /// Code points as the parser delivers them: Unicode scalar values.
    mutating func points(max: Int = Int.max, _ what: @autoclosure () -> String) throws -> [UInt32] {
        let n = try count(max: max, what())
        var out: [UInt32] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let v = try varint()
            guard v <= 0x10FFFF && !(0xD800...0xDFFF).contains(v) else {
                throw TerminalSerializationError.invalid("\(what()): not a Unicode scalar value")
            }
            out.append(UInt32(v))
        }
        return out
    }

    mutating func rend() throws -> Renditions {
        let fg = try varint()
        let bg = try varint()
        let attributes = try u8()
        guard fg <= UInt64(Renditions.colorFieldMask) && bg <= UInt64(Renditions.colorFieldMask) && attributes < 0x80 else {
            throw TerminalSerializationError.invalid("rendition out of range")
        }
        return Renditions(rawForeground: UInt32(fg), rawBackground: UInt32(bg), rawAttributes: attributes)
    }
}

// MARK: - Rows

private enum RowCoding {
    static let emptyRun: UInt8 = 0x01
    static let setRendition: UInt8 = 0x02
    static let repeatPrevious: UInt8 = 0x03
    static let anyCell: UInt8 = 0x04
    static let wideLiteral: UInt8 = 0x05

    /// Number of bytes that follow a literal's first byte, or nil if the byte cannot
    /// start a literal.
    static func literalTail(_ first: UInt8) -> Int? {
        switch first {
        case 0x20...0x7E: return 0
        case 0xC0...0xDF: return 1
        case 0xE0...0xEF: return 2
        case 0xF0...0xF7: return 3
        default: return nil
        }
    }

    static func isLiteral(_ contents: [UInt8]) -> Bool {
        guard let first = contents.first, let tail = literalTail(first) else { return false }
        return contents.count == 1 + tail
    }

    /// One cell, its rendition already being the current one.
    static func encodeCell(_ cell: Cell, into w: inout ByteWriter) {
        if !cell.fallback && !cell.wrap && isLiteral(cell.contents) {
            if cell.wide { w.u8(wideLiteral) }
            w.bytes.append(contentsOf: cell.contents)
            return
        }
        w.u8(anyCell)
        w.u8((cell.wide ? 1 : 0) | (cell.fallback ? 2 : 0) | (cell.wrap ? 4 : 0))
        w.byteString(cell.contents)
    }

    static func encode(_ row: Row, into w: inout ByteWriter) {
        let cells = row.cells
        w.varint(cells.count)
        w.varint(row.gen)
        var current = Renditions(background: 0)
        var i = 0
        while i < cells.count {
            let cell = cells[i]
            var j = i + 1
            while j < cells.count && cells[j] == cell { j += 1 }
            let run = j - i
            if cell.renditions != current {
                w.u8(setRendition)
                w.rend(cell.renditions)
                current = cell.renditions
            }
            if cell.contents.isEmpty && !cell.wide && !cell.fallback && !cell.wrap {
                w.u8(emptyRun)
                w.varint(run)
            } else {
                let start = w.bytes.count
                encodeCell(cell, into: &w)
                let size = w.bytes.count - start
                if run > 1 {
                    if size * (run - 1) > 2 {
                        w.u8(repeatPrevious)
                        w.varint(run - 1)
                    } else {
                        for _ in 1..<run { encodeCell(cell, into: &w) }
                    }
                }
            }
            i = j
        }
    }

    /// - Parameter expectedWidth: the width the row must have, or nil for any width up
    ///   to `TerminalSerialization.maxDimension`.
    /// - Parameter cellBudget: reduced by the row's width; decoding fails when it would
    ///   go below zero.
    static func decode(_ r: inout ByteReader, expectedWidth: Int?, cellBudget: inout Int) throws -> Row {
        let width = try r.int(max: TerminalSerialization.maxDimension, "row width")
        guard width >= 1 else { throw TerminalSerializationError.invalid("empty row") }
        if let expected = expectedWidth, expected != width {
            throw TerminalSerializationError.invalid("row width \(width), screen width \(expected)")
        }
        guard width <= cellBudget else { throw TerminalSerializationError.invalid("too many cells") }
        cellBudget -= width
        let gen = try r.varint()
        guard gen <= UInt64(1) << 62 else { throw TerminalSerializationError.invalid("row generation out of range") }

        var cells: [Cell] = []
        cells.reserveCapacity(width)
        var current = Renditions(background: 0)
        while cells.count < width {
            let tag = try r.u8()
            switch tag {
            case emptyRun:
                let n = try r.varint()
                guard n >= 1 && n <= UInt64(width - cells.count) else {
                    throw TerminalSerializationError.invalid("run of cells past the row's width")
                }
                var cell = Cell(backgroundColor: 0)
                cell.renditions = current
                cells.append(contentsOf: repeatElement(cell, count: Int(n)))
            case setRendition:
                current = try r.rend()
            case repeatPrevious:
                let n = try r.varint()
                guard let previous = cells.last else {
                    throw TerminalSerializationError.invalid("repeat without a cell before it")
                }
                guard n >= 1 && n <= UInt64(width - cells.count) else {
                    throw TerminalSerializationError.invalid("run of cells past the row's width")
                }
                cells.append(contentsOf: repeatElement(previous, count: Int(n)))
            case anyCell:
                let flags = try r.u8()
                guard flags < 8 else { throw TerminalSerializationError.invalid("unknown cell flags") }
                let contents = try r.byteString(max: TerminalSerialization.maxCellBytes, "cell contents")
                cells.append(Cell(contents: contents, renditions: current, wide: flags & 1 != 0,
                                  fallback: flags & 2 != 0, wrap: flags & 4 != 0))
            default:
                var first = tag
                let wide = tag == wideLiteral
                if wide { first = try r.u8() }
                guard let tail = literalTail(first) else {
                    throw TerminalSerializationError.invalid("unknown row item \(tag)")
                }
                var contents = [first]
                if tail > 0 { contents += try r.take(tail) }
                cells.append(Cell(contents: contents, renditions: current, wide: wide, fallback: false, wrap: false))
            }
        }
        RowGeneration.reserve(through: gen)
        return Row(cells: cells, gen: gen)
    }
}

extension Row {
    /// The row's cells and generation number in the serialized form (`row` in the
    /// format description in Serialization.swift). Two rows give the same bytes exactly
    /// when they are equal for mosh's `Row::operator==` (`moshEquals`), so a snapshot
    /// writer can store each distinct row once and share it between states.
    public func serialized() -> [UInt8] {
        var w = ByteWriter()
        RowCoding.encode(self, into: &w)
        return w.bytes
    }

    /// Decode `serialized()`. The result is a new row object with the saved generation.
    ///
    /// - Parameter width: the width the row must have (the screen's), or nil to accept
    ///   any width up to `TerminalSerialization.maxDimension`.
    public convenience init(serialized bytes: [UInt8], width: Int? = nil) throws {
        var r = ByteReader(bytes)
        var budget = TerminalSerialization.maxDimension
        let row = try RowCoding.decode(&r, expectedWidth: width, cellBudget: &budget)
        guard r.atEnd else { throw TerminalSerializationError.trailingBytes }
        self.init(cells: row.cells, gen: row.gen)
    }
}

// MARK: - State

extension TerminalState {
    /// The whole state in the versioned binary form described at the top of
    /// Serialization.swift.
    public func serialized() -> [UInt8] {
        var w = ByteWriter()
        w.bytes.reserveCapacity(1024)
        encodeSkeleton(into: &w)
        // Lines that share a row object refer to the first line that has it.
        let rows = terminal.fb.rows
        var firstLine: [ObjectIdentifier: Int] = [:]
        for (y, row) in rows.enumerated() {
            if let earlier = firstLine[ObjectIdentifier(row)] {
                w.varint(earlier + 1)
            } else {
                firstLine[ObjectIdentifier(row)] = y
                w.varint(0)
                RowCoding.encode(row, into: &w)
            }
        }
        return w.bytes
    }

    /// Decode `serialized()`. Throws `TerminalSerializationError` for input that is
    /// truncated, damaged or of another version.
    public init(serialized bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        let skeleton = try TerminalState.decodeSkeleton(&r)
        let width = skeleton.ds.width
        let height = skeleton.ds.height
        var rows: [Row] = []
        rows.reserveCapacity(height)
        var budget = TerminalSerialization.maxCells
        for y in 0..<height {
            let ref = try r.varint()
            if ref == 0 {
                rows.append(try RowCoding.decode(&r, expectedWidth: width, cellBudget: &budget))
            } else {
                guard ref <= UInt64(y) else { throw TerminalSerializationError.invalid("line refers to a later line") }
                rows.append(rows[Int(ref) - 1])
            }
        }
        guard r.atEnd else { throw TerminalSerializationError.trailingBytes }
        self = skeleton.state(rows: rows)
    }

    /// Everything except the rows (`skeleton` in the format description), for a snapshot
    /// writer that stores rows on its own and shares them between states. The rows, in
    /// line order, are `framebuffer.rows`; encode each distinct one with
    /// `Row.serialized()`.
    public func serializedWithoutRows() -> [UInt8] {
        var w = ByteWriter()
        encodeSkeleton(into: &w)
        return w.bytes
    }

    /// Rebuild a state from `serializedWithoutRows()` and its rows, one per line. The
    /// same row object may be given for several lines, and to several states.
    public init(serializedWithoutRows bytes: [UInt8], rows: [Row]) throws {
        var r = ByteReader(bytes)
        let skeleton = try TerminalState.decodeSkeleton(&r)
        guard r.atEnd else { throw TerminalSerializationError.trailingBytes }
        guard rows.count == skeleton.ds.height else {
            throw TerminalSerializationError.invalid("\(rows.count) rows for a screen of \(skeleton.ds.height) lines")
        }
        for row in rows where row.cells.count != skeleton.ds.width {
            throw TerminalSerializationError.invalid("row width \(row.cells.count), screen width \(skeleton.ds.width)")
        }
        self = skeleton.state(rows: rows)
    }

    private func encodeSkeleton(into w: inout ByteWriter) {
        let fb = terminal.fb
        let ds = fb.ds
        let dispatch = terminal.dispatch

        var defaultPattern = true
        for (i, tab) in ds.tabs.enumerated() where tab != (i % 8 == 0) {
            defaultPattern = false
            break
        }
        let tabBitmap = !(defaultPattern && ds.tabs.count == ds.width)

        w.u8(TerminalSerialization.version)
        var flags0: UInt8 = 0
        if ds.nextPrintWillWrap { flags0 |= 1 << 0 }
        if ds.originMode { flags0 |= 1 << 1 }
        if ds.autoWrapMode { flags0 |= 1 << 2 }
        if ds.insertMode { flags0 |= 1 << 3 }
        if ds.cursorVisible { flags0 |= 1 << 4 }
        if ds.reverseVideo { flags0 |= 1 << 5 }
        if ds.bracketedPaste { flags0 |= 1 << 6 }
        if ds.mouseFocusEvent { flags0 |= 1 << 7 }
        w.u8(flags0)
        var flags1: UInt8 = 0
        if ds.mouseAlternateScroll { flags1 |= 1 << 0 }
        if ds.applicationModeCursorKeys { flags1 |= 1 << 1 }
        if ds.defaultTabs { flags1 |= 1 << 2 }
        if fb.titleInitialized { flags1 |= 1 << 3 }
        if dispatch.parsed { flags1 |= 1 << 4 }
        if ds.save.autoWrapMode { flags1 |= 1 << 5 }
        if ds.save.originMode { flags1 |= 1 << 6 }
        if tabBitmap { flags1 |= 1 << 7 }
        w.u8(flags1)

        w.varint(ds.width)
        w.varint(ds.height)
        w.varint(ds.cursorCol)
        w.varint(ds.cursorRow)
        w.zigzag(ds.combiningCharCol)
        w.zigzag(ds.combiningCharRow)
        w.varint(ds.scrollingRegionTopRow)
        w.varint(ds.scrollingRegionBottomRow)
        w.rend(ds.renditions)
        w.zigzag(ds.save.cursorCol)
        w.zigzag(ds.save.cursorRow)
        w.rend(ds.save.renditions)
        w.varint(ds.mouseReportingMode.rawValue)
        w.varint(ds.mouseEncodingMode.rawValue)
        if tabBitmap {
            // ds.tabs has ds.width entries in a valid state; write exactly the bytes the
            // decoder reads for this width either way
            var bitmap = [UInt8](repeating: 0, count: (max(ds.width, 0) + 7) / 8)
            for (i, tab) in ds.tabs.enumerated() where tab && i / 8 < bitmap.count {
                bitmap[i / 8] |= 1 << UInt8(i % 8)
            }
            w.bytes.append(contentsOf: bitmap)
        }

        w.varint(UInt64(fb.bellCount))
        w.points(fb.iconName)
        w.points(fb.windowTitle)
        w.points(fb.clipboard)

        w.varint(echoAck)
        w.varint(inputHistory.count)
        for frame in inputHistory {
            w.varint(frame.frameNum)
            w.varint(frame.timestamp)
        }

        w.u8(parser.parser.state.rawValue)
        let pending = parser.pendingBytes
        w.u8(UInt8(truncatingIfNeeded: pending.count))
        w.bytes.append(contentsOf: pending)

        w.byteString(dispatch.params)
        w.varint(dispatch.parsedParams.count)
        for p in dispatch.parsedParams { w.zigzag(p) }
        w.byteString(dispatch.dispatchChars)
        w.points(dispatch.oscString)
        w.byteString(dispatch.terminalToHost)

        w.u8(terminal.user.state.rawValue)
    }

    /// A decoded skeleton: every field of the state except the rows.
    private struct Skeleton {
        var ds: DrawState
        var iconName: [UInt32]
        var windowTitle: [UInt32]
        var clipboard: [UInt32]
        var bellCount: UInt32
        var titleInitialized: Bool
        var echoAck: UInt64
        var inputHistory: [InputFrame]
        var parser: UTF8Parser
        var dispatch: Dispatcher
        var user: UserInput

        /// `rows` must have `ds.height` rows of `ds.width` cells (checked by the callers).
        func state(rows: [Row]) -> TerminalState {
            let fb = Framebuffer(rows: rows, iconName: iconName, windowTitle: windowTitle, clipboard: clipboard,
                                 bellCount: bellCount, titleInitialized: titleInitialized, ds: ds)
            return TerminalState(parser: parser, terminal: Emulator(fb: fb, dispatch: dispatch, user: user),
                                 inputHistory: inputHistory, echoAck: echoAck)
        }
    }

    private static func decodeSkeleton(_ r: inout ByteReader) throws -> Skeleton {
        let version = try r.u8()
        guard version == TerminalSerialization.version else {
            throw TerminalSerializationError.unsupportedVersion(version)
        }
        let flags0 = try r.u8()
        let flags1 = try r.u8()

        let maxDimension = TerminalSerialization.maxDimension
        let width = try r.int(max: maxDimension, "width")
        let height = try r.int(max: maxDimension, "height")
        guard width >= 1 && height >= 1 else { throw TerminalSerializationError.invalid("empty screen") }

        var ds = DrawState(width: width, height: height)
        ds.nextPrintWillWrap = flags0 & (1 << 0) != 0
        ds.originMode = flags0 & (1 << 1) != 0
        ds.autoWrapMode = flags0 & (1 << 2) != 0
        ds.insertMode = flags0 & (1 << 3) != 0
        ds.cursorVisible = flags0 & (1 << 4) != 0
        ds.reverseVideo = flags0 & (1 << 5) != 0
        ds.bracketedPaste = flags0 & (1 << 6) != 0
        ds.mouseFocusEvent = flags0 & (1 << 7) != 0
        ds.mouseAlternateScroll = flags1 & (1 << 0) != 0
        ds.applicationModeCursorKeys = flags1 & (1 << 1) != 0
        ds.defaultTabs = flags1 & (1 << 2) != 0
        let titleInitialized = flags1 & (1 << 3) != 0
        let parsed = flags1 & (1 << 4) != 0

        ds.cursorCol = try r.int(max: width - 1, "cursor column")
        ds.cursorRow = try r.int(max: height - 1, "cursor row")
        ds.combiningCharCol = try r.zigzag(min: -1, max: width - 1, "combining character column")
        ds.combiningCharRow = try r.zigzag(min: -1, max: height - 1, "combining character row")
        ds.scrollingRegionTopRow = try r.int(max: height - 1, "scrolling region")
        ds.scrollingRegionBottomRow = try r.int(max: height - 1, "scrolling region")
        guard ds.scrollingRegionTopRow <= ds.scrollingRegionBottomRow else {
            throw TerminalSerializationError.invalid("scrolling region upside down")
        }
        ds.renditions = try r.rend()
        var save = SavedCursor()
        // a saved cursor can be outside the screen after a resize (it is snapped back
        // when restored), but it is never negative
        save.cursorCol = try r.zigzag(min: 0, max: maxDimension, "saved cursor column")
        save.cursorRow = try r.zigzag(min: 0, max: maxDimension, "saved cursor row")
        save.renditions = try r.rend()
        save.autoWrapMode = flags1 & (1 << 5) != 0
        save.originMode = flags1 & (1 << 6) != 0
        ds.save = save
        guard let reporting = MouseReportingMode(rawValue: try r.int(max: 0xFFFF, "mouse reporting mode")) else {
            throw TerminalSerializationError.invalid("unknown mouse reporting mode")
        }
        ds.mouseReportingMode = reporting
        guard let encoding = MouseEncodingMode(rawValue: try r.int(max: 0xFFFF, "mouse encoding mode")) else {
            throw TerminalSerializationError.invalid("unknown mouse encoding mode")
        }
        ds.mouseEncodingMode = encoding
        if flags1 & (1 << 7) != 0 {
            let bitmap = try r.take((width + 7) / 8)
            var tabs = [Bool](repeating: false, count: width)
            for i in 0..<width where bitmap[i / 8] & (1 << UInt8(i % 8)) != 0 {
                tabs[i] = true
            }
            // bits beyond the width must be zero: one form per state
            if width % 8 != 0 && bitmap[bitmap.count - 1] >> UInt8(width % 8) != 0 {
                throw TerminalSerializationError.invalid("tab stop beyond the width")
            }
            ds.tabs = tabs
        }
        // otherwise DrawState.init has set the default stops

        let bell = try r.varint()
        guard bell <= UInt64(UInt32.max) else { throw TerminalSerializationError.invalid("bell count out of range") }
        let iconName = try r.points("icon name")
        let windowTitle = try r.points("window title")
        let clipboard = try r.points("clipboard")

        let echoAck = try r.varint()
        // each entry takes at least two bytes
        let historyCount = try r.count("input history")
        guard historyCount <= r.remaining / 2 else { throw TerminalSerializationError.truncated }
        var inputHistory: [InputFrame] = []
        inputHistory.reserveCapacity(historyCount)
        for _ in 0..<historyCount {
            let frameNum = try r.varint()
            let timestamp = try r.varint()
            inputHistory.append(InputFrame(frameNum: frameNum, timestamp: timestamp))
        }

        guard let parserState = ParserState(rawValue: try r.u8()) else {
            throw TerminalSerializationError.invalid("unknown parser state")
        }
        let pendingCount = Int(try r.u8())
        guard pendingCount < UTF8Parser.bufSize else {
            throw TerminalSerializationError.invalid("incomplete character too long")
        }
        let pending = try r.take(pendingCount)
        let parser = UTF8Parser(state: parserState, pendingBytes: pending)

        let params = try r.byteString(max: 100, "parameters")
        let parsedCount = try r.count(max: 128, "parsed parameters")
        var parsedParams: [Int] = []
        parsedParams.reserveCapacity(parsedCount)
        for _ in 0..<parsedCount {
            parsedParams.append(try r.zigzag(min: -1, max: Dispatcher.paramMax, "parsed parameter"))
        }
        let dispatchChars = try r.byteString(max: 8, "intermediate characters")
        let oscString = try r.points(max: Dispatcher.maximumClipboardSize, "OSC string")
        let terminalToHost = try r.byteString("reply")
        let dispatch = Dispatcher(params: params, parsedParams: parsedParams, parsed: parsed,
                                  dispatchChars: dispatchChars, oscString: oscString, terminalToHost: terminalToHost)

        guard let userState = UserInput.State(rawValue: try r.u8()) else {
            throw TerminalSerializationError.invalid("unknown user-input state")
        }

        return Skeleton(ds: ds, iconName: iconName, windowTitle: windowTitle, clipboard: clipboard,
                        bellCount: UInt32(bell), titleInitialized: titleInitialized, echoAck: echoAck,
                        inputHistory: inputHistory, parser: parser, dispatch: dispatch,
                        user: UserInput(state: userState))
    }
}
