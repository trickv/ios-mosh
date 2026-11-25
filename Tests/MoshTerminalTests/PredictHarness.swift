// The Swift twin of `mosh-oracle predict` (Tools/mosh-oracle/FORMAT.md section 11): the
// same commands run with TerminalState as the server, a Framebuffer as the shown frame and
// the ported PredictionEngine, and the comparison of every dump line with the oracle's
// (docs/notes/m10/DESIGN.md 7.1). Linux only, like the oracle.

#if os(Linux)
import Foundation
import XCTest
import MoshTestSupport
@testable import MoshTerminal

/// One command of the predict grammar.
enum PredictCommand: Equatable {
    case new(Int, Int)
    case display(PredictionDisplay)
    case overwrite(Bool)
    case time(UInt64)
    case host([UInt8])
    case hostResize(Int, Int)
    case echoAck(UInt64)
    case recv(acked: UInt64, sendInterval: UInt32)
    case read(sent: UInt64, [UInt8])
    case frame
    case reset
    case dump

    var line: String {
        switch self {
        case .new(let w, let h): return "new \(w) \(h)"
        case .display(let d): return "display \(d.rawValue)"
        case .overwrite(let b): return "overwrite \(b ? 1 : 0)"
        case .time(let t): return "time \(t)"
        case .host(let b): return "host \(PredictOracle.hex(b))"
        case .hostResize(let w, let h): return "hostresize \(w) \(h)"
        case .echoAck(let n): return "echoack \(n)"
        case .recv(let a, let si): return "recv \(a) \(si)"
        case .read(let s, let b): return "read \(s) \(PredictOracle.hex(b))"
        case .frame: return "frame"
        case .reset: return "reset"
        case .dump: return "dump"
        }
    }
}

/// What one `dump` holds on the Swift side.
struct PredictHarnessDump {
    var engine: PredictionDump
    /// The shown frame if it changed since the previous dump (only `new` and `frame`).
    var shown: Framebuffer?
}

struct PredictHarness {
    private(set) var server = TerminalState(width: 1, height: 1)
    private(set) var shown = Framebuffer(width: 1, height: 1)
    private(set) var engine = PredictionEngine()
    private(set) var now: UInt64 = 0
    private var shownChanged = false

    /// Run one command; a `dump` returns its dump.
    mutating func run(_ c: PredictCommand) -> PredictHarnessDump? {
        switch c {
        case .new(let w, let h):
            server = TerminalState(width: w, height: h)
            shown = Framebuffer(width: w, height: h)     // stc:245
            engine = PredictionEngine()                   // toh:294-307, display adaptive
            shownChanged = true
        case .display(let d): engine.setDisplayPreference(d)
        case .overwrite(let b): engine.setPredictOverwrite(b)
        case .time(let t): now = t
        case .host(let b): server.act(b)
        case .hostResize(let w, let h): server.resize(width: w, height: h)
        case .echoAck(let n): server.applyEchoAck(n)
        case .recv(let acked, let si):                    // stc:298-300
            engine.setLocalFrameAcked(acked)
            engine.setSendInterval(si)
            engine.setLocalFrameLateAcked(server.echoAck)
        case .read(let sent, let bytes):                  // stc:322-334
            engine.newUserRead(bytes, lastSent: sent, shown, now: now)
        case .frame:                                      // stc:274-287
            shown = engine.overlay(server.framebuffer, now: now)
            shownChanged = true
        case .reset: engine.reset()
        case .dump:
            let d = PredictHarnessDump(engine: PredictionDump(engine), shown: shownChanged ? shown : nil)
            shownChanged = false
            return d
        }
        return nil
    }
}

extension PredictionDump {
    private static func u(_ v: UInt64) -> String { "\"\(v)\"" }

    private static func cellJSON(_ c: Cell) -> String {
        var r: [String] = []
        if c.renditions.foregroundColor != 0 { r.append("\"fg\":\(c.renditions.foregroundColor)") }
        if c.renditions.backgroundColor != 0 { r.append("\"bg\":\(c.renditions.backgroundColor)") }
        if c.renditions.attributes != 0 { r.append("\"at\":\(c.renditions.attributes)") }
        return "{\"c\":\"\(Data(c.contents).base64EncodedString())\",\"r\":{\(r.joined(separator: ","))},\"w\":\(c.wide),\"f\":\(c.fallback),\"x\":\(c.wrap)}"
    }

    /// This dump as `mosh-oracle predict` writes its "engine" object (FORMAT.md 11).
    var oracleJSON: String {
        var o = "{\"prediction_epoch\":\(PredictionDump.u(predictionEpoch)),\"confirmed_epoch\":\(PredictionDump.u(confirmedEpoch))"
        o += ",\"flagging\":\(flagging),\"srtt_trigger\":\(srttTrigger),\"glitch_trigger\":\(glitchTrigger)"
        o += ",\"last_quick_confirmation\":\(PredictionDump.u(lastQuickConfirmation)),\"send_interval\":\(sendInterval)"
        o += ",\"last_height\":\(lastHeight),\"last_width\":\(lastWidth)"
        o += ",\"local_frame_sent\":\(PredictionDump.u(localFrameSent)),\"local_frame_acked\":\(PredictionDump.u(localFrameAcked))"
        o += ",\"local_frame_late_acked\":\(PredictionDump.u(localFrameLateAcked)),\"last_byte\":\(lastByte)"
        o += ",\"parser_state\":\"\(parserState)\",\"parser_buf\":\"\(PredictOracle.hex(parserBuf))\""
        o += ",\"display\":\"\(display)\",\"overwrite\":\(overwrite),\"active\":\(active),\"wait_time\":\(waitTime)"
        var cs: [String] = []
        for c in cursors {
            let fields: [String] = [PredictionDump.u(c.expirationFrame), String(c.row), String(c.col), String(c.active),
                                    PredictionDump.u(c.tentativeUntilEpoch), PredictionDump.u(c.predictionTime)]
            cs.append("[" + fields.joined(separator: ",") + "]")
        }
        o += ",\"cursors\":[" + cs.joined(separator: ",") + "]"
        var rows: [String] = []
        for r in overlays {
            var cells: [String] = []
            for c in r.cells {
                let originals: [String] = c.originalContents.map { PredictionDump.cellJSON($0) }
                let fields: [String] = [String(c.col), String(c.active), PredictionDump.u(c.expirationFrame),
                                        PredictionDump.u(c.tentativeUntilEpoch), PredictionDump.u(c.predictionTime),
                                        String(c.unknown), PredictionDump.cellJSON(c.replacement),
                                        "[" + originals.joined(separator: ",") + "]"]
                cells.append("[" + fields.joined(separator: ",") + "]")
            }
            rows.append("{\"row\":\(r.row),\"cells\":[" + cells.joined(separator: ",") + "]}")
        }
        o += ",\"overlays\":[" + rows.joined(separator: ",") + "]}"
        return o
    }
}

enum PredictComparison {
    struct ParseError: Error, CustomStringConvertible { var description: String }

    private static func u64(_ v: JSONValue?, _ what: String) throws -> UInt64 {
        guard let s = v?.stringValue, let n = UInt64(s) else { throw ParseError(description: "\(what) is not a \"U\"") }
        return n
    }

    private static func int(_ v: JSONValue?, _ what: String) throws -> Int {
        guard let n = v?.intValue else { throw ParseError(description: "\(what) is not a number") }
        return n
    }

    private static func bool(_ v: JSONValue?, _ what: String) throws -> Bool {
        guard let b = v?.boolValue else { throw ParseError(description: "\(what) is not a bool") }
        return b
    }

    private static func cell(_ v: JSONValue?) throws -> Cell {
        guard let o = v, let c = o["c"]?.stringValue, let bytes = Data(base64Encoded: c) else {
            throw ParseError(description: "bad CELL")
        }
        let r = o["r"]
        let fg = UInt32(r?["fg"]?.intValue ?? 0), bg = UInt32(r?["bg"]?.intValue ?? 0), at = UInt8(r?["at"]?.intValue ?? 0)
        return Cell(contents: Array(bytes), renditions: Renditions(rawForeground: fg, rawBackground: bg, rawAttributes: at),
                    wide: try bool(o["w"], "w"), fallback: try bool(o["f"], "f"), wrap: try bool(o["x"], "x"))
    }

    private static func hexBytes(_ s: String) throws -> [UInt8] {
        let a = Array(s.utf8)
        guard a.count % 2 == 0 else { throw ParseError(description: "odd hex") }
        var out: [UInt8] = []
        var i = 0
        while i < a.count {
            guard let b = UInt8(String(decoding: a[i..<i + 2], as: UTF8.self), radix: 16) else {
                throw ParseError(description: "bad hex")
            }
            out.append(b)
            i += 2
        }
        return out
    }

    /// A full state line (rows as an array) as the delta form GoldenState reads: rows as
    /// an object listing every row, which FORMAT.md 5.1 allows against any previous state.
    static func asDeltaLine(_ line: JSONValue) throws -> JSONValue {
        guard let members = line.members else { throw ParseError(description: "shown is not an object") }
        return .object(members.map { m in
            guard m.key == "rows", let rows = m.value.elements else { return m }
            return (key: "rows", value: .object(rows.enumerated().map { (key: String($0.offset), value: $0.element) }))
        })
    }

    /// The text of the "engine" object of a dump line.
    static func engineText(_ line: String) -> Substring? {
        guard let a = line.range(of: ",\"engine\":"), let b = line.range(of: ",\"shown\":", options: .backwards) else {
            return nil
        }
        return line[a.upperBound..<b.lowerBound]
    }

    static func isNullShown(_ line: String) -> Bool { line.hasSuffix(",\"shown\":null}") }

    /// The oracle's "engine" object as a PredictionDump.
    static func engine(_ e: JSONValue) throws -> PredictionDump {
        var cursors: [PredictionDump.Cursor] = []
        for c in e["cursors"]?.elements ?? [] {
            guard let a = c.elements, a.count == 6 else { throw ParseError(description: "bad cursor") }
            cursors.append(PredictionDump.Cursor(expirationFrame: try u64(a[0], "exp"), row: try int(a[1], "row"),
                                                 col: try int(a[2], "col"), active: try bool(a[3], "active"),
                                                 tentativeUntilEpoch: try u64(a[4], "tentative"),
                                                 predictionTime: try u64(a[5], "prediction_time")))
        }
        var rows: [PredictionDump.OverlayRow] = []
        for r in e["overlays"]?.elements ?? [] {
            var cells: [PredictionDump.OverlayCell] = []
            for c in r["cells"]?.elements ?? [] {
                guard let a = c.elements, a.count == 8 else { throw ParseError(description: "bad overlay cell") }
                cells.append(PredictionDump.OverlayCell(
                    col: try int(a[0], "col"), active: try bool(a[1], "active"), expirationFrame: try u64(a[2], "exp"),
                    tentativeUntilEpoch: try u64(a[3], "tentative"), predictionTime: try u64(a[4], "prediction_time"),
                    unknown: try bool(a[5], "unknown"), replacement: try cell(a[6]),
                    originalContents: try (a[7].elements ?? []).map { try cell($0) }))
            }
            rows.append(PredictionDump.OverlayRow(row: try int(r["row"], "row"), cells: cells))
        }
        return PredictionDump(
            predictionEpoch: try u64(e["prediction_epoch"], "prediction_epoch"),
            confirmedEpoch: try u64(e["confirmed_epoch"], "confirmed_epoch"),
            flagging: try bool(e["flagging"], "flagging"), srttTrigger: try bool(e["srtt_trigger"], "srtt_trigger"),
            glitchTrigger: UInt32(try int(e["glitch_trigger"], "glitch_trigger")),
            lastQuickConfirmation: try u64(e["last_quick_confirmation"], "last_quick_confirmation"),
            sendInterval: UInt32(try int(e["send_interval"], "send_interval")),
            lastHeight: try int(e["last_height"], "last_height"), lastWidth: try int(e["last_width"], "last_width"),
            localFrameSent: try u64(e["local_frame_sent"], "local_frame_sent"),
            localFrameAcked: try u64(e["local_frame_acked"], "local_frame_acked"),
            localFrameLateAcked: try u64(e["local_frame_late_acked"], "local_frame_late_acked"),
            lastByte: UInt8(try int(e["last_byte"], "last_byte")),
            parserState: e["parser_state"]?.stringValue ?? "?",
            parserBuf: try hexBytes(e["parser_buf"]?.stringValue ?? "?"),
            display: e["display"]?.stringValue ?? "?", overwrite: try bool(e["overwrite"], "overwrite"),
            active: try bool(e["active"], "active"), waitTime: try int(e["wait_time"], "wait_time"),
            cursors: cursors, overlays: rows)
    }

    /// Run `commands` through the oracle and the harness. nil if every dump is equal,
    /// else the first difference, with the command number.
    /// Seconds spent in the oracle process and in the comparison, for the fuzz's budget.
    nonisolated(unsafe) static var oracleSeconds = 0.0
    nonisolated(unsafe) static var compareSeconds = 0.0

    static func firstDifference(_ commands: [PredictCommand]) throws -> String? {
        let t0 = Date()
        let lines = try PredictOracle.run(commands.map { $0.line })
        let t1 = Date()
        oracleSeconds += t1.timeIntervalSince(t0)
        defer { compareSeconds += Date().timeIntervalSince(t1) }
        var harness = PredictHarness()
        var tally = CorpusTally()
        for (i, (c, line)) in zip(commands, lines).enumerated() {
            let mine = harness.run(c)
            guard c == .dump else { continue }
            guard let mine = mine else { return "command \(i): no harness dump" }
            // Fast path: the port's dump written as the oracle writes it, compared as text.
            if let theirs = engineText(line), theirs == mine.engine.oracleJSON, isNullShown(line), mine.shown == nil {
                continue
            }
            let j = try JSONValue.parse(Array(line.utf8))
            guard let e = j["engine"] else { return "command \(i): no engine in \(line.prefix(200))" }
            let theirs = try engine(e)
            if let d = mine.engine.firstDifference(theirs) {
                return "command \(i) (dump): engine \(d)\n  port:  \(mine.engine)\n  mosh:  \(theirs)"
            }
            let s = j["shown"]
            if case .null? = s {
                if mine.shown != nil { return "command \(i): the port's shown frame changed, mosh's did not" }
                continue
            }
            guard let s = s, let shown = mine.shown else {
                return "command \(i): mosh's shown frame changed, the port's did not"
            }
            var golden = GoldenState(width: shown.ds.width, height: shown.ds.height)
            try golden.apply(line: asDeltaLine(s))
            let state = TerminalState(parser: UTF8Parser(),
                                      terminal: Emulator(fb: shown, dispatch: Dispatcher(), user: UserInput()), echoAck: 0)
            if let d = CorpusComparison.firstDifference(state, golden, tally: &tally) {
                return "command \(i) (dump): shown \(d)"
            }
        }
        return nil
    }
}
#endif
