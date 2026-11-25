// A seeded generator of terminal histories for the display and serialization tests:
// what a server-side terminal sees between two states it sends. It mixes the wild
// sequences of `TerminalFuzz` with output shaped like real programs (lines that scroll,
// text that wraps, a full-screen program repainting parts of the screen, scrolling
// regions, mode changes, titles, clipboard, bells, resizes), so that every branch of
// `Display::new_frame` is taken often: the scroll shortcut, ECH and EL, wrapped rows,
// the full repaint after a resize.

import MoshTerminal

struct DiffScenario {
    var fuzz: TerminalFuzz
    private(set) var width: Int
    private(set) var height: Int

    static let sizes: [(Int, Int)] = [
        (80, 24), (80, 24), (80, 24), (40, 12), (40, 12), (20, 6), (20, 6), (10, 4), (33, 9), (16, 5),
        (132, 43), (5, 3), (2, 2), (1, 1), (3, 1), (1, 4), (8, 2),
    ]

    static let words = ["ls", "total", "drwxr-xr-x", "README.md", "Package.swift", "--", "héllo", "日本語", "漢字",
                        "🙂", "e\u{301}", "a\u{308}\u{301}", "│", "──", "error:", "warning", "0", "42", "~", "$"]

    init(seed: UInt64) {
        fuzz = TerminalFuzz(seed: seed)
        let size = fuzz.pick(DiffScenario.sizes)
        width = size.0
        height = size.1
    }

    /// The first operation of a script.
    var start: RefOp { return .new(width, height) }

    private mutating func word() -> String {
        if fuzz.chance(70) {
            var s = ""
            for _ in 0..<(1 + fuzz.int(9)) { s.unicodeScalars.append(Unicode.Scalar(UInt8(0x61 + fuzz.int(26)))) }
            return s
        }
        return fuzz.pick(DiffScenario.words)
    }

    private mutating func text(_ maxColumns: Int) -> String {
        var s = ""
        var n = 0
        let limit = 1 + fuzz.int(max(1, maxColumns))
        while n < limit {
            let w = word()
            s += w
            n += w.unicodeScalars.count
            if fuzz.chance(80) { s += " "; n += 1 }
        }
        return s
    }

    private mutating func simpleSGR() -> String {
        switch fuzz.int(8) {
        case 0: return "\u{1B}[0m"
        case 1: return "\u{1B}[1m"
        case 2: return "\u{1B}[\(30 + fuzz.int(8))m"
        case 3: return "\u{1B}[\(40 + fuzz.int(8))m"
        case 4: return "\u{1B}[38;5;\(fuzz.int(256));48;5;\(fuzz.int(256))m"
        case 5: return "\u{1B}[7m"
        case 6: return "\u{1B}[38;2;\(fuzz.int(256));\(fuzz.int(256));\(fuzz.int(256))m"
        default: return "\u{1B}[m"
        }
    }

    /// The operations between two states.
    mutating func step() -> [RefOp] {
        let e = "\u{1B}"
        var s = ""
        switch fuzz.int(100) {
        case 0..<22:
            var bytes: [UInt8] = []
            for _ in 0..<(1 + fuzz.int(3)) { bytes += fuzz.chunk(width, height) }
            return [.bytes(bytes)]
        case 22..<42:
            // lines of output, as from a shell command: scrolls once the screen is full
            for _ in 0..<(1 + fuzz.int(fuzz.chance(15) ? height + 3 : 4)) {
                if fuzz.chance(25) { s += simpleSGR() }
                s += text(fuzz.chance(10) ? width * 2 : width - 1) + "\r\n"
            }
        case 42..<52:
            // text that runs over the right margin, in pieces
            for _ in 0..<(1 + fuzz.int(3)) {
                if fuzz.chance(30) { s += simpleSGR() }
                s += text(width + width / 2)
            }
        case 52..<66:
            // a full-screen program repainting some places
            for _ in 0..<(1 + fuzz.int(6)) {
                s += "\(e)[\(1 + fuzz.int(height));\(1 + fuzz.int(width))H"
                if fuzz.chance(50) { s += simpleSGR() }
                switch fuzz.int(8) {
                case 0: s += "\(e)[K"
                case 1: s += "\(e)[\(fuzz.int(width + 2))X"
                case 2: s += "\(e)[J"
                case 3: s += "\(e)[1K"
                case 4: s += "\(e)[\(fuzz.int(4))P"
                case 5: s += "\(e)[\(fuzz.int(4))@"
                default: s += text(width / 2)
                }
            }
        case 66..<74:
            // scrolling inside a region, or of the whole screen
            let top = 1 + fuzz.int(height)
            let bottom = top + fuzz.int(height - top + 1)
            if fuzz.chance(60) { s += "\(e)[\(top);\(bottom)r" }
            s += "\(e)[\(1 + fuzz.int(height));1H"
            switch fuzz.int(7) {
            case 0: s += String(repeating: "\n", count: 1 + fuzz.int(height + 1))
            case 1: s += String(repeating: "\(e)M", count: 1 + fuzz.int(3))
            case 2: s += "\(e)[\(1 + fuzz.int(3))S"
            case 3: s += "\(e)[\(1 + fuzz.int(3))T"
            case 4: s += "\(e)[\(1 + fuzz.int(3))L"
            case 5: s += "\(e)[\(1 + fuzz.int(3))M"
            default: s += "\(e)[\(height);1H" + String(repeating: "\n", count: 1 + fuzz.int(height + 1)) + text(width)
            }
            if fuzz.chance(70) { s += "\(e)[r" }
        case 74..<80:
            let modes = ["25", "25", "5", "2004", "9", "1000", "1001", "1002", "1003", "1004", "1005", "1006", "1015",
                         "1007", "1", "6", "7", "4"]
            s = "\(e)[" + (fuzz.chance(92) ? "?" : "") + fuzz.pick(modes) + fuzz.pick(["h", "l"])
        case 80..<86:
            switch fuzz.int(6) {
            case 0: s = "\u{7}"
            case 1: s = "\(e)]0;" + text(20) + "\u{7}"
            case 2: s = "\(e)]1;" + text(10) + "\u{7}"
            case 3: s = "\(e)]2;" + text(30) + "\(e)\\"
            case 4: s = "\(e)]52;c;" + text(40).filter { $0 != " " } + "\u{7}"
            default: s = "\u{7}\u{7}"
            }
        case 86..<91:
            let w = fuzz.chance(30) ? fuzz.pick(DiffScenario.sizes).0 : max(1, width + fuzz.int(9) - 4)
            let h = fuzz.chance(30) ? fuzz.pick(DiffScenario.sizes).1 : max(1, height + fuzz.int(5) - 2)
            width = w
            height = h
            return [.resize(w, h)]
        case 91..<94:
            return [.echoAck(UInt64(fuzz.int(1_000_000)))]
        case 94..<97:
            s = fuzz.pick(["\(e)[2J", "\(e)[H\(e)[2J", "\(e)c", "\(e)[!p", "\(e)[H", "\(e)[0m", "\(e)7", "\(e)8"])
        default:
            // the cursor in the last column and the bottom-right corner
            s = "\(e)[\(fuzz.chance(50) ? height : 1 + fuzz.int(height));\(max(1, width - fuzz.int(3)))H" + text(3)
        }
        return [.bytes(Array(s.utf8))]
    }

    /// Apply a step's operations to a state (what `MoshRef.port` does for these cases).
    static func apply(_ ops: [RefOp], to state: inout TerminalState) {
        for op in ops {
            switch op {
            case .bytes(let b): state.act(b)
            case .resize(let w, let h): state.resize(width: w, height: h)
            case .echoAck(let n): state.applyEchoAck(n)
            default: preconditionFailure("not a state operation")
            }
        }
    }
}
