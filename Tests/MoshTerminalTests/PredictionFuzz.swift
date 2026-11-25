// Seeded generator of prediction-engine command scripts (docs/notes/m10/DESIGN.md 7.2) and
// the coverage counters read from the dumps. Linux only, like the oracle it feeds.

#if os(Linux)
import Foundation
@testable import MoshTerminal

struct PredictionFuzz {
    var rng: TerminalFuzz
    private(set) var commands: [PredictCommand] = []

    // The generator's model of the session.
    private var width = 1, height = 1
    private var now: UInt64 = 0
    private var sent: UInt64 = 0
    private var typedSinceSend: [UInt8] = []
    /// Sent states not answered by the server yet, oldest first, with their bytes.
    private var unanswered: [(num: UInt64, bytes: [UInt8])] = []
    private var answered: UInt64 = 0
    private var echoAck: UInt64 = 0
    private var acked: UInt64 = 0
    private var overwrite = false
    private var pendingKeys: [UInt8] = []

    init(seed: UInt64) {
        rng = TerminalFuzz(seed: seed)
    }

    /// Small sizes, so that the last column and the last row are frequent; 10x3 and 5x2
    /// weighted up, as confirmations (which need room to type) are rare on the tiniest.
    static let sizes: [(Int, Int)] = [(1, 1), (2, 2), (3, 3), (5, 2), (5, 2), (10, 3), (10, 3), (10, 3)]
    static let sendIntervals: [UInt32] = [20, 21, 30, 31, 50, 51, 80, 81, 150, 250]
    static let timeSteps: [UInt64] = [0, 1, 49, 50, 51, 149, 150, 151, 249, 250, 251, 4999, 5000, 5001]

    /// The key classes of DESIGN.md 7.2 (test-tools 7 item 4).
    static let keys: [[UInt8]] = [
        Array("a".utf8), Array("b".utf8), Array("x".utf8), Array(" ".utf8), Array("é".utf8), Array("語".utf8),
        Array("\u{301}".utf8), [0x7F], [0x7F, 0x7F], [0x0D], [0x0A], [0x09], Array("\u{1b}[C".utf8), Array("\u{1b}[D".utf8),
        Array("\u{1b}OC".utf8), Array("\u{1b}OD".utf8), Array("\u{1b}[5C".utf8), Array("\u{1b}[A".utf8),
        Array("\u{1b}[3~".utf8), Array("\u{1b}x".utf8), Array("\u{1b}Oh".utf8), [0x03], [0xC3], [0xFF],
    ]

    private mutating func emit(_ c: PredictCommand) {
        commands.append(c)
        commands.append(.dump)
    }

    /// One case: setup, then `steps` drawn commands, each followed by a dump.
    mutating func makeCase(steps: Int) -> [PredictCommand] {
        commands = []
        let large = rng.chance(4)
        if large {
            (width, height) = rng.chance(50) ? (80, 24) : (132, 50)
        } else {
            (width, height) = rng.pick(PredictionFuzz.sizes)
        }
        let count = large ? min(steps, 30) : steps
        emit(.new(width, height))
        let mode = rng.int(100)
        let display: PredictionDisplay = mode < 40 ? .adaptive : mode < 70 ? .always : mode < 90 ? .experimental : .never
        emit(.display(display))
        overwrite = rng.chance(30)
        if overwrite { emit(.overwrite(true)) }
        now = rng.chance(10) ? UInt64(rng.int(150)) : (1 << 24) + UInt64(rng.int(100_000))
        emit(.time(now))
        sent = UInt64(rng.int(5))
        unanswered = []
        answered = sent
        echoAck = 0
        acked = 0
        typedSinceSend = []
        pendingKeys = []
        var host: [UInt8] = []
        for _ in 0..<rng.int(4) { host += rng.chunk(width, height) }
        // keep the server out of origin mode (D2: mosh's assert must not fire in the oracle)
        host += Array("\u{1b}[?6l".utf8)
        emit(.host(host))
        emit(.recv(acked: 0, sendInterval: rng.pick(PredictionFuzz.sendIntervals)))
        emit(.frame)

        var sinceFrame = 0
        for _ in 0..<count {
            if sinceFrame >= 6 {
                emit(.frame)
                sinceFrame = 0
                continue
            }
            let r = rng.int(100)
            switch r {
            case 0..<30: read()
            case 30..<40: send()
            case 40..<52: hostReaction()
            case 52..<58:
                if echoAck < answered {
                    echoAck += UInt64(rng.int(Int(answered - echoAck)) + 1)
                    emit(.echoAck(echoAck))
                }
            case 58..<66:
                if acked < sent && rng.chance(70) { acked += UInt64(rng.int(Int(sent - acked)) + 1) }
                emit(.recv(acked: acked, sendInterval: rng.pick(PredictionFuzz.sendIntervals)))
            case 66..<76:
                now += rng.chance(80) ? rng.pick(PredictionFuzz.timeSteps) : UInt64(rng.int(6000))
                emit(.time(now))
            case 76..<96:
                emit(.frame)
                sinceFrame = 0
                continue
            case 96..<98:
                if rng.chance(40) {
                    let w = max(1, width + rng.int(3) - 1), h = max(1, height + rng.int(3) - 1)
                    width = w
                    height = h
                    emit(.hostResize(w, h))
                    emit(.reset)
                } else {
                    emit(.overwrite(rng.chance(50)))
                }
            default:
                if rng.chance(30) {
                    cursorOnly()
                } else if rng.chance(30) {
                    emit(.display(rng.pick(PredictionDisplay.allCases)))
                } else {
                    emit(.reset)
                }
            }
            sinceFrame += 1
        }
        emit(.frame)
        return commands
    }

    /// A read: 1-4 bytes of the key stream (sequences may be cut across reads), or a paste.
    private mutating func read() {
        var bytes: [UInt8]
        if rng.chance(3) {
            bytes = (0..<(101 + rng.int(50))).map { _ in UInt8(0x61 + rng.int(26)) }
        } else {
            while pendingKeys.count < 4 {
                // printable letters 40%, as typing is, the other classes 60%
                pendingKeys += rng.chance(40) ? [UInt8(0x61 + rng.int(26))] : rng.pick(PredictionFuzz.keys)
            }
            let n = 1 + rng.int(4)
            bytes = Array(pendingKeys.prefix(n))
            pendingKeys.removeFirst(n)
        }
        typedSinceSend += bytes
        emit(.read(sent: sent, bytes))
    }

    /// A state that holds only a cursor key, answered by a server that does not move its
    /// cursor: the newest cursor guess is judged wrong with no cell guess pending, which is
    /// the cursor check's full reset (toc:596-613). Older states are taken as answered
    /// without output first, so that no wrong cell guess resets earlier in the cull.
    private mutating func cursorOnly() {
        send()
        unanswered = []
        answered = sent
        emit(.reset)
        let key = rng.pick([Array("\u{1b}[C".utf8), Array("\u{1b}[D".utf8)])
        typedSinceSend = key
        emit(.read(sent: sent, key))
        send()
        unanswered = []
        answered = sent
        emit(.host([]))
        echoAck = answered
        emit(.echoAck(echoAck))
        if acked < answered { acked = answered }
        emit(.recv(acked: acked, sendInterval: rng.pick(PredictionFuzz.sendIntervals)))
        emit(.frame)
    }

    /// The client sends a state holding the bytes typed since the last one; sometimes a
    /// number is burned.
    private mutating func send() {
        sent += rng.chance(10) ? 2 : 1
        unanswered.append((sent, typedSinceSend))
        typedSinceSend = []
    }

    /// The server's answer to the oldest unanswered state: an echo, a wrong echo, a partial
    /// echo, or unrelated output.
    private mutating func hostReaction() {
        var out: [UInt8] = []
        if let first = unanswered.first {
            unanswered.removeFirst()
            answered = first.num
            switch rng.int(20) {
            case 0..<9: out = echo(first.bytes)
            case 9..<13: out = Array("\u{1b}[3\(1 + rng.int(6))m".utf8) + echo(first.bytes) + Array("\u{1b}[m".utf8)
            case 13..<15: out = echo(first.bytes).map { $0 >= 0x61 && $0 <= 0x7A ? ($0 == 0x7A ? 0x61 : $0 + 1) : $0 }
            case 15..<17: out = Array(echo(first.bytes).prefix(rng.int(3)))
            default: out = unrelated()
            }
            emit(.host(out))
            // the server's echo ack follows its echo (ECHO_TIMEOUT later), and the client
            // hears it
            if rng.chance(60) {
                echoAck = answered
                emit(.echoAck(echoAck))
                if acked < answered { acked = answered }
                now += UInt64(rng.int(80))
                emit(.time(now))
                emit(.recv(acked: acked, sendInterval: rng.pick(PredictionFuzz.sendIntervals)))
            }
        } else {
            emit(.host(unrelated()))
        }
    }

    private func echo(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in bytes {
            switch b {
            case 0x7F: out += [0x08, 0x20, 0x08]
            case 0x0D: out += Array("\r\n$ ".utf8)
            default: out.append(b)
            }
        }
        return out
    }

    private mutating func unrelated() -> [UInt8] {
        switch rng.int(3) {
        case 0: return Array("\u{1b}7\u{1b}[1;1H12:3\(rng.int(10))\u{1b}8".utf8)
        case 1: return Array("\r\n".utf8)
        default: return rng.chunk(width, height)
        }
    }
}

/// Coverage of the branches of DESIGN.md 7.2, read from consecutive dumps of the port
/// (equal to mosh's when the cross-check passes).
struct PredictionCoverage: CustomStringConvertible {
    var counts: [String: Int] = [:]
    static let names = [
        "epoch confirmed", "epoch killed", "kill resets cells right of the judged one", "full reset on a frame",
        "cursor check full reset", "glitch 10", "glitch 20", "glitch decremented", "flagging on", "flagging off",
        "srtt on", "srtt off", "unknown cell underlined", "last-column guess", "blank last-row prediction",
        "paste reset", "experimental single-cell reset", "renditions copied along the row",
        "backspace next active unknown", "backspace next active known", "backspace next inactive",
        "overwrite backspace", "ESC O rewrite moved the cursor",
    ]

    mutating func hit(_ name: String) { counts[name, default: 0] += 1 }

    var missing: [String] { return PredictionCoverage.names.filter { (counts[$0] ?? 0) == 0 } }

    var description: String {
        return PredictionCoverage.names.map { "\($0): \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    private static func activeCells(_ d: PredictionDump) -> Int {
        return d.overlays.reduce(0) { $0 + $1.cells.filter { $0.active }.count }
    }

    /// `before` and `after` are the dumps around `command`; `shown` the frame after it.
    mutating func observe(_ command: PredictCommand, before: PredictionDump, after: PredictionDump,
                          shown: Framebuffer, server: Framebuffer, width: Int, height: Int) {
        if after.confirmedEpoch > before.confirmedEpoch { hit("epoch confirmed") }
        if after.flagging && !before.flagging { hit("flagging on") }
        if !after.flagging && before.flagging { hit("flagging off") }
        if after.srttTrigger && !before.srttTrigger { hit("srtt on") }
        if !after.srttTrigger && before.srttTrigger { hit("srtt off") }
        if after.glitchTrigger == 10 && before.glitchTrigger != 10 { hit("glitch 10") }
        if after.glitchTrigger == 20 && before.glitchTrigger != 20 { hit("glitch 20") }
        if after.glitchTrigger + 1 == before.glitchTrigger { hit("glitch decremented") }

        switch command {
        case .frame:
            let sameSize = before.lastWidth == after.lastWidth && before.lastHeight == after.lastHeight
            if sameSize && after.predictionEpoch > before.predictionEpoch && !after.overlays.isEmpty
                && after.overlays.count == before.overlays.count {
                hit("epoch killed")
                for (rb, ra) in zip(before.overlays, after.overlays) {
                    let reset = zip(rb.cells, ra.cells).filter { $0.active && !$1.active }.count
                    if reset >= 2 { hit("kill resets cells right of the judged one") }
                }
            }
            if sameSize && after.predictionEpoch > before.predictionEpoch && after.overlays.isEmpty && after.cursors.isEmpty {
                if PredictionCoverage.activeCells(before) > 0 { hit("full reset on a frame") }
                // the cursor check's reset (toc:596-613): no cell guess was wrong and confirmed,
                // and the newest cursor guess is wrong on this frame
                if let c = before.cursors.last {
                    var move = ConditionalCursorMove(expirationFrame: c.expirationFrame, row: c.row, col: c.col,
                                                     tentativeUntilEpoch: c.tentativeUntilEpoch)
                    move.active = c.active
                    let wrongConfirmedCell = before.overlays.contains { r in
                        r.row >= 0 && r.row < server.ds.height && r.cells.contains { d in
                            var cell = ConditionalOverlayCell(expirationFrame: d.expirationFrame, col: d.col,
                                                              tentativeUntilEpoch: d.tentativeUntilEpoch)
                            cell.active = d.active
                            cell.unknown = d.unknown
                            cell.replacement = d.replacement
                            cell.originalContents = d.originalContents
                            return cell.validity(server, row: r.row, lateAck: before.localFrameLateAcked) == .incorrectOrExpired
                                && !cell.tentative(before.confirmedEpoch)
                        }
                    }
                    if !wrongConfirmedCell
                        && move.validity(server, lateAck: before.localFrameLateAcked) == .incorrectOrExpired {
                        hit("cursor check full reset")
                    }
                }
            }
            if after.display == "experimental" && after.overlays.count == before.overlays.count
                && PredictionCoverage.activeCells(after) < PredictionCoverage.activeCells(before)
                && after.predictionEpoch == before.predictionEpoch {
                hit("experimental single-cell reset")
            }
            for (rb, ra) in zip(before.overlays, after.overlays) where rb.row == ra.row {
                if zip(rb.cells, ra.cells).contains(where: { $0.replacement.renditions != $1.replacement.renditions }) {
                    hit("renditions copied along the row")
                }
            }
        case .read(_, let bytes):
            if bytes.count > PredictionEngine.pasteThreshold && after.overlays.isEmpty { hit("paste reset") }
            if (before.lastByte == 0x1B && bytes.first == UInt8(ascii: "O"))
                || zip(bytes, bytes.dropFirst()).contains(where: { $0 == 0x1B && $1 == UInt8(ascii: "O") }) {
                if let a = after.cursors.last, let b = before.cursors.last, a.col != b.col { hit("ESC O rewrite moved the cursor") }
            }
            if bytes.contains(0x7F), let cur = after.cursors.last {
                if after.overwrite {
                    if let row = after.overlays.first(where: { $0.row == cur.row }), cur.col < row.cells.count,
                       row.cells[cur.col].active && row.cells[cur.col].replacement.contents == [0x20] {
                        hit("overwrite backspace")
                    }
                } else if cur.col < width - 2 {
                    let rb = before.overlays.first(where: { $0.row == cur.row })
                    for i in cur.col..<(width - 2) {
                        guard let rb = rb, i + 1 < rb.cells.count else {
                            hit("backspace next inactive")
                            continue
                        }
                        let next = rb.cells[i + 1]
                        if next.active && next.unknown { hit("backspace next active unknown") }
                        else if next.active { hit("backspace next active known") }
                        else { hit("backspace next inactive") }
                    }
                }
            }
            for row in after.overlays {
                if let c = row.cells.last, row.cells.count == width, c.active, !c.unknown, !c.replacement.contents.isEmpty {
                    hit("last-column guess")
                }
                if row.row == height - 1 && row.cells.count == width
                    && row.cells.allSatisfy({ $0.active && $0.replacement.contents.isEmpty }) {
                    hit("blank last-row prediction")
                }
            }
        default:
            break
        }

        if case .frame = command, after.flagging {
            for row in after.overlays where row.row < shown.ds.height {
                for c in row.cells where c.active && c.unknown && c.tentativeUntilEpoch <= after.confirmedEpoch
                    && c.col < shown.ds.width - 1 && shown.getCell(row.row, c.col).renditions.getAttribute(.underlined) {
                    hit("unknown cell underlined")
                }
            }
        }
    }
}
#endif
