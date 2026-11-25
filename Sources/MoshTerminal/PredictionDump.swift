// The whole state of a PredictionEngine as plain values, field for field the "engine"
// object of `mosh-oracle predict`'s dump line (Tools/mosh-oracle/FORMAT.md section 11), so
// the differential tests can compare the port with mosh's engine after every command.
// Internal: for tests only.

struct PredictionDump: Equatable, Sendable {
    struct Cursor: Equatable, Sendable {
        var expirationFrame: UInt64
        var row: Int
        var col: Int
        var active: Bool
        var tentativeUntilEpoch: UInt64
        var predictionTime: UInt64
    }

    struct OverlayCell: Equatable, Sendable {
        var col: Int
        var active: Bool
        var expirationFrame: UInt64
        var tentativeUntilEpoch: UInt64
        var predictionTime: UInt64
        var unknown: Bool
        var replacement: Cell
        var originalContents: [Cell]
    }

    struct OverlayRow: Equatable, Sendable {
        var row: Int
        var cells: [OverlayCell]
    }

    var predictionEpoch: UInt64
    var confirmedEpoch: UInt64
    var flagging: Bool
    var srttTrigger: Bool
    var glitchTrigger: UInt32
    var lastQuickConfirmation: UInt64
    var sendInterval: UInt32
    var lastHeight: Int
    var lastWidth: Int
    var localFrameSent: UInt64
    var localFrameAcked: UInt64
    var localFrameLateAcked: UInt64
    var lastByte: UInt8
    /// mosh's state class name, as `parser_state` of FORMAT.md
    var parserState: String
    var parserBuf: [UInt8]
    var display: String
    var overwrite: Bool
    var active: Bool
    var waitTime: Int
    var cursors: [Cursor]
    var overlays: [OverlayRow]

    init(predictionEpoch: UInt64, confirmedEpoch: UInt64, flagging: Bool, srttTrigger: Bool, glitchTrigger: UInt32,
         lastQuickConfirmation: UInt64, sendInterval: UInt32, lastHeight: Int, lastWidth: Int,
         localFrameSent: UInt64, localFrameAcked: UInt64, localFrameLateAcked: UInt64, lastByte: UInt8,
         parserState: String, parserBuf: [UInt8], display: String, overwrite: Bool, active: Bool, waitTime: Int,
         cursors: [Cursor], overlays: [OverlayRow]) {
        self.predictionEpoch = predictionEpoch
        self.confirmedEpoch = confirmedEpoch
        self.flagging = flagging
        self.srttTrigger = srttTrigger
        self.glitchTrigger = glitchTrigger
        self.lastQuickConfirmation = lastQuickConfirmation
        self.sendInterval = sendInterval
        self.lastHeight = lastHeight
        self.lastWidth = lastWidth
        self.localFrameSent = localFrameSent
        self.localFrameAcked = localFrameAcked
        self.localFrameLateAcked = localFrameLateAcked
        self.lastByte = lastByte
        self.parserState = parserState
        self.parserBuf = parserBuf
        self.display = display
        self.overwrite = overwrite
        self.active = active
        self.waitTime = waitTime
        self.cursors = cursors
        self.overlays = overlays
    }

    init(_ e: PredictionEngine) {
        self.init(
            predictionEpoch: e.predictionEpoch, confirmedEpoch: e.confirmedEpoch, flagging: e.flagging,
            srttTrigger: e.srttTrigger, glitchTrigger: e.glitchTrigger, lastQuickConfirmation: e.lastQuickConfirmation,
            sendInterval: e.sendInterval, lastHeight: e.lastHeight, lastWidth: e.lastWidth,
            localFrameSent: e.localFrameSent, localFrameAcked: e.localFrameAcked,
            localFrameLateAcked: e.localFrameLateAcked, lastByte: e.lastByte,
            parserState: e.parser.parser.state.name, parserBuf: e.parser.pendingBytes,
            display: e.settings.display.rawValue, overwrite: e.settings.overwrite, active: e.isActive,
            waitTime: e.waitTime(),
            cursors: e.cursors.map {
                Cursor(expirationFrame: $0.expirationFrame, row: $0.row, col: $0.col, active: $0.active,
                       tentativeUntilEpoch: $0.tentativeUntilEpoch, predictionTime: $0.predictionTime)
            },
            overlays: e.overlays.map { r in
                OverlayRow(row: r.rowNum, cells: r.cells.map {
                    OverlayCell(col: $0.col, active: $0.active, expirationFrame: $0.expirationFrame,
                                tentativeUntilEpoch: $0.tentativeUntilEpoch, predictionTime: $0.predictionTime,
                                unknown: $0.unknown, replacement: $0.replacement, originalContents: $0.originalContents)
                })
            })
    }

    /// The name of the first field that differs, for a readable test failure.
    func firstDifference(_ other: PredictionDump) -> String? {
        let fields: [(String, Bool)] = [
            ("prediction_epoch", predictionEpoch == other.predictionEpoch),
            ("confirmed_epoch", confirmedEpoch == other.confirmedEpoch),
            ("flagging", flagging == other.flagging),
            ("srtt_trigger", srttTrigger == other.srttTrigger),
            ("glitch_trigger", glitchTrigger == other.glitchTrigger),
            ("last_quick_confirmation", lastQuickConfirmation == other.lastQuickConfirmation),
            ("send_interval", sendInterval == other.sendInterval),
            ("last_height", lastHeight == other.lastHeight),
            ("last_width", lastWidth == other.lastWidth),
            ("local_frame_sent", localFrameSent == other.localFrameSent),
            ("local_frame_acked", localFrameAcked == other.localFrameAcked),
            ("local_frame_late_acked", localFrameLateAcked == other.localFrameLateAcked),
            ("last_byte", lastByte == other.lastByte),
            ("parser_state", parserState == other.parserState),
            ("parser_buf", parserBuf == other.parserBuf),
            ("display", display == other.display),
            ("overwrite", overwrite == other.overwrite),
            ("active", active == other.active),
            ("wait_time", waitTime == other.waitTime),
        ]
        if let f = fields.first(where: { !$0.1 }) {
            return f.0
        }
        if cursors != other.cursors {
            return "cursors: \(cursors) vs \(other.cursors)"
        }
        if overlays.count != other.overlays.count {
            return "overlays: \(overlays.count) rows vs \(other.overlays.count)"
        }
        for (a, b) in zip(overlays, other.overlays) where a != b {
            if a.row != b.row || a.cells.count != b.cells.count {
                return "overlay row \(a.row) (\(a.cells.count) cells) vs \(b.row) (\(b.cells.count) cells)"
            }
            for (x, y) in zip(a.cells, b.cells) where x != y {
                return "overlay row \(a.row) col \(x.col): \(x) vs \(y)"
            }
        }
        return nil
    }
}
