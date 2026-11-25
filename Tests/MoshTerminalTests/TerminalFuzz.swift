// The operations of a test script (also understood by Support/moshref.cc) and a seeded
// generator of terminal output. Platform neutral: the tests that need mosh itself are
// Linux only, the property tests that use the same generator are not.

import MoshTerminal

/// One operation of a cross-check script. See the command list in Support/moshref.cc.
enum RefOp {
    case new(Int, Int)
    case bytes([UInt8])
    case resize(Int, Int)
    case echoAck(UInt64)
    case userBytes([UInt8])
    case save
    case drop
    case dump
    case cmp
    case reply
    /// `Display::new_frame( initialized, saved, current )` as a "diff [HEX]" block.
    case diff(initialized: Bool, display: DisplayDiff = .server)
    /// Apply that diff to a copy of the saved state; the copy becomes the current state.
    case applyDiff(initialized: Bool)

    /// Host bytes from a string (UTF-8).
    static func text(_ s: String) -> RefOp { return .bytes(Array(s.utf8)) }

    var producesBlock: Bool {
        switch self {
        case .dump, .cmp, .reply, .diff: return true
        default: return false
        }
    }
}

/// Deterministic generator of terminal input (SplitMix64).
struct TerminalFuzz {
    var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ n: Int) -> Int { return Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { return a[int(a.count)] }
    mutating func chance(_ percent: Int) -> Bool { return int(100) < percent }

    static let unicodeSamples: [String] = [
        "é", "ß", "\u{A0}", "\u{AD}", "日", "本", "語", "한", "🙂", "👍", "\u{301}", "\u{308}", "\u{20DD}", "\u{200D}",
        "\u{FE0F}", "\u{200B}", "│", "─", "█", "Ω", "\u{FFFD}", "\u{FFFF}", "\u{7F}", "\u{85}", "\u{9B}", "\u{9C}",
        "\u{84}", "\u{8D}", "\u{88}", "\u{1F1EE}", "\u{3000}", "ａ", "\u{1160}", "\u{E0100}", "\u{10FFFF}",
    ]
    static let csiFinals = Array("ABCDHfJKLMPXSTdG`@rmhlgcnIZpqstuz~".utf8)
    static let escFinals = Array("78cDEHM=>\\Z0AB12".utf8)

    mutating func param(_ width: Int, _ height: Int) -> String {
        switch int(12) {
        case 0: return ""
        case 1: return "0"
        case 2: return "1"
        case 3: return "2"
        case 4: return String(width)
        case 5: return String(height)
        case 6: return String(int(width + 3))
        case 7: return String(int(height + 3))
        case 8: return "65535"
        case 9: return "65536"
        case 10: return String(int(300))
        default: return String(int(10))
        }
    }

    mutating func sgr() -> String {
        var parts: [String] = []
        for _ in 0..<(1 + int(4)) {
            switch int(10) {
            case 0: parts.append(String(int(110)))
            case 1: parts.append("38;5;\(int(300))")
            case 2: parts.append("48;5;\(int(256))")
            case 3: parts.append("38;2;\(int(256));\(int(256));\(int(256))")
            case 4: parts.append("48;2;\(int(400));\(int(256));\(int(70000))")
            case 5: parts.append(pick(["0", "", "1", "3", "4", "5", "7", "8", "22", "27", "39", "49"]))
            case 6: parts.append(String(30 + int(8)))
            case 7: parts.append(String(40 + int(8)))
            case 8: parts.append(String(90 + int(18)))
            default: parts.append(pick(["38", "48", "38;5", "38;2", "48;2;1", "2", "21"]))
            }
        }
        return "\u{1B}[" + parts.joined(separator: ";") + "m"
    }

    mutating func chunk(_ width: Int, _ height: Int) -> [UInt8] {
        let e = "\u{1B}"
        var s = ""
        switch int(100) {
        case 0..<28:
            for _ in 0..<(1 + int(12)) { s.unicodeScalars.append(Unicode.Scalar(UInt8(0x20 + int(95)))) }
        case 28..<40:
            for _ in 0..<(1 + int(4)) { s += pick(TerminalFuzz.unicodeSamples) }
        case 40..<50:
            s = pick(["\r", "\n", "\r\n", "\u{8}", "\t", "\u{7}", "\u{B}", "\u{C}", "\u{0}", "\u{18}", "\u{1A}", "\u{E}", "\u{F}"])
        case 50..<70:
            let final = Unicode.Scalar(pick(TerminalFuzz.csiFinals))
            var p: [String] = []
            for _ in 0..<int(4) { p.append(param(width, height)) }
            s = "\(e)[" + pick(["", "", "", "", "?", ">", "!", " ", "="]) + p.joined(separator: ";")
            s += pick(["", "", "", "", "", "!", " ", "$"])
            s.unicodeScalars.append(final)
        case 70..<78:
            s = sgr()
        case 78..<84:
            let modes = ["1", "3", "5", "6", "7", "9", "25", "1000", "1001", "1002", "1003", "1004", "1005", "1006", "1007", "1015", "2004", "4", "20"]
            var p: [String] = []
            for _ in 0..<(1 + int(3)) { p.append(pick(modes)) }
            s = "\(e)[" + pick(["?", "?", "?", ""]) + p.joined(separator: ";") + pick(["h", "l"])
        case 84..<89:
            s = e + pick(["", "", "#", "(", " "])
            s.unicodeScalars.append(Unicode.Scalar(pick(TerminalFuzz.escFinals)))
        case 89..<94:
            var body = ""
            for _ in 0..<int(12) { body += chance(15) ? pick(TerminalFuzz.unicodeSamples) : String(Unicode.Scalar(UInt8(0x20 + int(95)))) }
            s = "\(e)]" + pick(["0;", "1;", "2;", ";", "52;c;", "52;;", "3;", "", "0", "10;"]) + body + pick(["\u{7}", "\(e)\\", "\u{9C}", "\u{18}", ""])
        case 94..<97:
            s = e + pick(["P", "X", "^", "_"]) + pick(["", "1;2", "$q", ":"]) + "x\ny" + pick(["\(e)\\", "\u{9C}", ""])
        default:
            // incomplete or damaged sequences
            s = pick(["\(e)[", "\(e)[1;", "\(e)]0;x", "\(e)", "\(e)[?", "\(e)[1:2", "\(e)[ ", "\(e)#"])
        }
        var bytes = Array(s.utf8)
        if chance(4) && !bytes.isEmpty {
            // damage a byte
            bytes[int(bytes.count)] = UInt8(truncatingIfNeeded: next())
        }
        return bytes
    }

    mutating func makeCase() -> [RefOp] {
        var width = pick([1, 2, 3, 5, 8, 10, 16, 20, 33])
        var height = pick([1, 2, 3, 4, 6, 9])
        var ops: [RefOp] = [.new(width, height)]
        let steps = 20 + int(60)
        var haveSaved = false
        for step in 0..<steps {
            switch int(100) {
            case 0..<3:
                width = max(1, width + int(7) - 3)
                height = max(1, height + int(5) - 2)
                ops.append(.resize(width, height))
            case 3..<5:
                ops.append(.save)
                haveSaved = true
            case 5..<8:
                if haveSaved { ops.append(.cmp) }
            case 8..<9:
                ops.append(.echoAck(next()))
            case 9..<10:
                ops.append(.userBytes(Array(pick(["\u{1B}OA", "a", "\u{1B}", "O", "\u{1B}[B", "\u{1B}OQ"]).utf8)))
            default:
                // several chunks in one write, so that sequences span chunk borders
                var bytes: [UInt8] = []
                for _ in 0..<(1 + int(3)) { bytes += chunk(width, height) }
                ops.append(.bytes(bytes))
            }
            if step % 16 == 15 { ops.append(.dump) }
        }
        if haveSaved { ops.append(.cmp) }
        return ops
    }

    mutating func makeByteSoupCase() -> [RefOp] {
        let width = pick([4, 10, 40])
        let height = pick([2, 5])
        var ops: [RefOp] = [.new(width, height)]
        for _ in 0..<8 {
            var bytes: [UInt8] = []
            let n = 1 + int(60)
            for _ in 0..<n {
                switch int(10) {
                case 0..<3: bytes.append(UInt8(truncatingIfNeeded: next())) // anything
                case 3..<5: bytes.append(UInt8(0x80 + int(0x40))) // continuation
                case 5..<7: bytes.append(UInt8(0xC0 + int(0x40))) // lead
                case 7: bytes.append(pick([0xE0, 0xED, 0xF0, 0xF4, 0xF8, 0xFC, 0xC2, 0xEF]))
                case 8: bytes.append(pick([0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF]))
                default: bytes.append(UInt8(0x20 + int(95)))
                }
            }
            ops.append(.bytes(bytes))
            ops.append(.dump)
        }
        return ops
    }
}
