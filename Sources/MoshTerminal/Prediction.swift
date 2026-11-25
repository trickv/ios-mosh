// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0's prediction engine (local echo): src/frontend/terminaloverlay.{h,cc},
// abbreviated toh and toc below. Design: docs/notes/m10/DESIGN.md; the behaviour line by
// line: docs/notes/m10/mosh-prediction.md ("the spec").
//
// Rules of the port (DESIGN.md 2.2): every uint64_t subtraction of mosh is `&-` on UInt64;
// list order is array order; the engine's cells are written only through
// `Framebuffer.withMutableCell`, which copies a shared row as mosh's get_mutable_cell does.

/// mosh `Overlay::Validity` (toh:52-58).
enum PredictionValidity: Sendable {
    case pending, correct, correctNoCredit, incorrectOrExpired, inactive
}

/// The bound checks that mosh asserts (toc:151-152, 751-754; toh:242). In a debug build a
/// failing check traps, as mosh-client aborts; in a release build it returns false and the
/// caller skips only the action it guards (deviation D3). `trapsOnFailure` lets a test run
/// the release behaviour in a debug build.
enum PredictionBounds {
    nonisolated(unsafe) static var trapsOnFailure = true

    static func check(_ condition: Bool, _ what: @autoclosure () -> String) -> Bool {
        if condition { return true }
        if trapsOnFailure { assertionFailure("prediction bound check failed: \(what())") }
        return false
    }
}

/// mosh `ConditionalCursorMove` (toh:84-95) with its base class `ConditionalOverlay`
/// (toh:60-82) folded in: the same fields, the same initial values.
struct ConditionalCursorMove: Equatable, Sendable {
    var expirationFrame: UInt64
    var col: Int
    /// "represents a prediction at all" (toh:70)
    var active: Bool = false
    /// when to show (toh:71)
    var tentativeUntilEpoch: UInt64
    /// used to find long-pending predictions; `uint64_t( -1 )` at construction (toh:71)
    var predictionTime: UInt64 = .max
    var row: Int

    /// toh:92-94
    init(expirationFrame: UInt64, row: Int, col: Int, tentativeUntilEpoch: UInt64) {
        self.expirationFrame = expirationFrame
        self.col = col
        self.tentativeUntilEpoch = tentativeUntilEpoch
        self.row = row
    }

    /// toh:76
    func tentative(_ confirmedEpoch: UInt64) -> Bool { return tentativeUntilEpoch > confirmedEpoch }

    /// toh:77: `col` and `prediction_time` stay.
    mutating func reset() {
        expirationFrame = .max
        tentativeUntilEpoch = .max
        active = false
    }

    /// toh:78-81
    mutating func expire(_ exp: UInt64, now: UInt64) {
        expirationFrame = exp
        predictionTime = now
    }

    /// toc:116-139. mosh's `early_ack` is unused (toc:117), so it is not passed.
    func validity(_ fb: Framebuffer, lateAck: UInt64) -> PredictionValidity {
        if !active {
            return .inactive
        }
        if row >= fb.ds.height || col >= fb.ds.width {
            return .incorrectOrExpired
        }
        if lateAck >= expirationFrame {
            if fb.ds.cursorCol == col && fb.ds.cursorRow == row {
                return .correct
            }
            return .incorrectOrExpired
        }
        return .pending
    }

    /// toc:141-157. The two bound asserts (toc:151-152) follow D3; the origin-mode assert
    /// (toc:153) is not ported in any build (D2): the cursor is moved as mosh moves it
    /// after the assert, counting from the scroll region top in origin mode.
    func apply(_ fb: inout Framebuffer, confirmedEpoch: UInt64) {
        if !active {
            return
        }
        if tentative(confirmedEpoch) {
            return
        }
        guard PredictionBounds.check(row < fb.ds.height && row >= 0, "cursor row \(row)"),
              PredictionBounds.check(col < fb.ds.width && col >= 0, "cursor col \(col)") else {
            return
        }
        fb.ds.moveRow(row, relative: false)
        fb.ds.moveCol(col, relative: false, implicit: false)
    }
}

/// mosh `ConditionalOverlayCell` (toh:97-125) with `ConditionalOverlay` folded in.
struct ConditionalOverlayCell: Equatable, Sendable {
    var expirationFrame: UInt64
    var col: Int
    var active: Bool = false
    var tentativeUntilEpoch: UInt64
    var predictionTime: UInt64 = .max
    /// `replacement( 0 )`: `Cell( 0 )` (toh:110)
    var replacement = Cell(backgroundColor: 0)
    var unknown = false
    /// "we don't give credit for correct predictions that match the original contents"
    var originalContents: [Cell] = []

    /// toh:108-113
    init(expirationFrame: UInt64, col: Int, tentativeUntilEpoch: UInt64) {
        self.expirationFrame = expirationFrame
        self.col = col
        self.tentativeUntilEpoch = tentativeUntilEpoch
    }

    /// toh:76
    func tentative(_ confirmedEpoch: UInt64) -> Bool { return tentativeUntilEpoch > confirmedEpoch }

    /// toh:78-81
    mutating func expire(_ exp: UInt64, now: UInt64) {
        expirationFrame = exp
        predictionTime = now
    }

    /// `ConditionalOverlay::reset` (toh:77).
    private mutating func resetBase() {
        expirationFrame = .max
        tentativeUntilEpoch = .max
        active = false
    }

    /// toh:115. `replacement` is NOT cleared (spec quirk 5).
    mutating func reset() {
        unknown = false
        originalContents.removeAll()
        resetBase()
    }

    /// toh:116-124
    mutating func resetWithOrig() {
        if !active || unknown {
            reset()
            return
        }
        originalContents.append(replacement)
        resetBase()
    }

    /// toc:74-114. `early_ack` unused in mosh, not passed.
    func validity(_ fb: Framebuffer, row: Int, lateAck: UInt64) -> PredictionValidity {
        if !active {
            return .inactive
        }
        if row >= fb.ds.height || col >= fb.ds.width {
            return .incorrectOrExpired
        }
        // mosh reads the cell here (toc:88, `.at()` would throw on a negative index).
        guard PredictionBounds.check(row >= 0 && col >= 0, "cell (\(row),\(col))") else {
            return .incorrectOrExpired
        }
        let current = fb.getCell(row, col)

        // see if it hasn't been updated yet
        if lateAck < expirationFrame {
            return .pending
        }
        if unknown {
            return .correctNoCredit
        }
        if replacement.isBlank {  // too easy for this to trigger falsely
            return .correctNoCredit
        }
        if current.contentsMatch(replacement) {
            if originalContents.contains(where: { $0.contentsMatch(replacement) }) {
                return .correctNoCredit
            }
            return .correct
        }
        return .incorrectOrExpired
    }

    /// toc:43-72 (spec 8).
    func apply(_ fb: inout Framebuffer, confirmedEpoch: UInt64, row: Int, flag: Bool) {
        var flag = flag
        if !active || row >= fb.ds.height || col >= fb.ds.width {
            return
        }
        if tentative(confirmedEpoch) {
            return
        }
        guard PredictionBounds.check(row >= 0 && col >= 0, "cell (\(row),\(col))") else {
            return
        }
        if replacement.isBlank && fb.getCell(row, col).isBlank {
            flag = false
        }
        if unknown {
            if flag && col != fb.ds.width - 1 {
                fb.withMutableCell(row, col) { $0.renditions.setAttribute(.underlined, true) }
            }
            return
        }
        if fb.getCell(row, col) != replacement {
            let replacement = self.replacement
            fb.withMutableCell(row, col) { $0 = replacement }
            if flag {
                fb.withMutableCell(row, col) { $0.renditions.setAttribute(.underlined, true) }
            }
        }
    }
}

/// mosh `ConditionalOverlayRow` (toh:127-137).
struct ConditionalOverlayRow: Equatable, Sendable {
    var rowNum: Int
    var cells: [ConditionalOverlayCell]

    /// toh:136
    init(rowNum: Int) {
        self.rowNum = rowNum
        self.cells = []
    }

    /// toc:347-354: every cell, in column order.
    func apply(_ fb: inout Framebuffer, confirmedEpoch: UInt64, flag: Bool) {
        for cell in cells {
            cell.apply(&fb, confirmedEpoch: confirmedEpoch, row: rowNum, flag: flag)
        }
    }
}


/// mosh `PredictionEngine::DisplayPreference` (toh:253-258), named as the values of
/// MOSH_PREDICTION_DISPLAY (sth:109-125).
public enum PredictionDisplay: String, CaseIterable, Sendable {
    case always, never, adaptive, experimental
}

/// The two user settings of mosh's engine.
public struct PredictionSettings: Equatable, Sendable {
    /// mosh's default is adaptive (toh:305).
    public var display: PredictionDisplay
    /// MOSH_PREDICTION_OVERWRITE == "yes" (sth:121-124); mosh's default is off (toh:306).
    public var overwrite: Bool

    public init(display: PredictionDisplay = .adaptive, overwrite: Bool = false) {
        self.display = display
        self.overwrite = overwrite
    }

    /// Display `never`: the package default (deviation D5).
    public static let off = PredictionSettings(display: .never)
}

public struct PredictionEngine: Equatable, Sendable {
    // toh:203-213: all `static const uint64_t` in mosh.
    static let srttTriggerLow: UInt64 = 20          // <= ms cures SRTT trigger to show predictions
    static let srttTriggerHigh: UInt64 = 30         // > ms starts SRTT trigger
    static let flagTriggerLow: UInt64 = 50          // <= ms cures flagging
    static let flagTriggerHigh: UInt64 = 80         // > ms starts flagging
    static let glitchThreshold: UInt64 = 250        // prediction outstanding this long is glitch
    static let glitchRepairCount: UInt64 = 10       // non-glitches required to cure glitch trigger
    static let glitchRepairMinInterval: UInt64 = 150 // required time in between non-glitches
    static let glitchFlagThreshold: UInt64 = 5000   // prediction outstanding this long => underline

    /// stc:325: a read of more than this many bytes is a paste and is not predicted.
    public static let pasteThreshold = 100

    /// mosh `INT_MAX`, what `wait_time()` returns when no timing test is due.
    public static let noWait = Int(Int32.max)

    // Fields of toh:215-262, initial values of toh:294-307.
    /// mosh `char last_byte`; only ever compared for equality.
    var lastByte: UInt8 = 0
    var parser = UTF8Parser()
    var overlays: [ConditionalOverlayRow] = []
    var cursors: [ConditionalCursorMove] = []
    var localFrameSent: UInt64 = 0
    var localFrameAcked: UInt64 = 0
    var localFrameLateAcked: UInt64 = 0
    var predictionEpoch: UInt64 = 1
    var confirmedEpoch: UInt64 = 0
    /// whether we are underlining predictions
    var flagging = false
    /// show predictions because of slow round trip time
    var srttTrigger = false
    /// show predictions temporarily because of long-pending prediction (`unsigned int`)
    var glitchTrigger: UInt32 = 0
    var lastQuickConfirmation: UInt64 = 0
    /// `unsigned int send_interval`
    var sendInterval: UInt32 = 250
    var lastHeight = 0
    var lastWidth = 0

    public private(set) var settings: PredictionSettings

    public init(settings: PredictionSettings = PredictionSettings()) {
        self.settings = settings
    }

    // MARK: Setters (toh:272-285)

    public mutating func setDisplayPreference(_ display: PredictionDisplay) { settings.display = display }
    public mutating func setPredictOverwrite(_ on: Bool) { settings.overwrite = on }
    public mutating func setLocalFrameSent(_ n: UInt64) { localFrameSent = n }
    public mutating func setLocalFrameAcked(_ n: UInt64) { localFrameAcked = n }
    public mutating func setLocalFrameLateAcked(_ n: UInt64) { localFrameLateAcked = n }
    public mutating func setSendInterval(_ ms: UInt32) { sendInterval = ms }

    // MARK: Small rules

    /// toh:266-269: are there any timing-based triggers that haven't fired yet?
    private var timingTestsNecessary: Bool {
        return !(glitchTrigger > 0 && flagging)
    }

    /// toh:287-292: 50 or INT_MAX.
    public func waitTime() -> Int {
        return (timingTestsNecessary && isActive) ? 50 : PredictionEngine.noWait
    }

    /// toc:913-932
    public var isActive: Bool {
        if !cursors.isEmpty {
            return true
        }
        for row in overlays {
            for cell in row.cells where cell.active {
                return true
            }
        }
        return false
    }

    /// toc:901-911
    private mutating func becomeTentative() {
        if settings.display != .experimental {
            predictionEpoch &+= 1
        }
    }

    /// toc:410-417: parser, `last_byte` and the triggers stay.
    public mutating func reset() {
        cursors.removeAll()
        overlays.removeAll()
        becomeTentative()
    }

    /// mosh `cursor()` (toh:242): the last cursor move. mosh asserts the list is not empty;
    /// every caller runs after `initCursor`, so it cannot be (D3: checked in debug).
    private var lastCursor: Int {
        _ = PredictionBounds.check(!cursors.isEmpty, "cursor() on an empty list")
        return cursors.count - 1
    }

    /// toc:628-650: the index of the first row with this number, or a new row of `width`
    /// cells `(0, i, prediction_epoch)` appended.
    private mutating func getOrMakeRow(_ rowNum: Int, _ numCols: Int) -> Int {
        if let i = overlays.firstIndex(where: { $0.rowNum == rowNum }) {
            return i
        }
        var r = ConditionalOverlayRow(rowNum: rowNum)
        r.cells.reserveCapacity(numCols)
        for i in 0..<max(numCols, 0) {
            r.cells.append(ConditionalOverlayCell(expirationFrame: 0, col: i, tentativeUntilEpoch: predictionEpoch))
        }
        overlays.append(r)
        return overlays.count - 1
    }

    /// toc:419-438
    private mutating func initCursor(_ fb: Framebuffer) {
        if cursors.isEmpty {
            // initialize new cursor prediction
            var c = ConditionalCursorMove(expirationFrame: localFrameSent &+ 1, row: fb.ds.cursorRow,
                                          col: fb.ds.cursorCol, tentativeUntilEpoch: predictionEpoch)
            c.active = true
            cursors.append(c)
        } else if cursors[cursors.count - 1].tentativeUntilEpoch != predictionEpoch {
            let last = cursors[cursors.count - 1]
            var c = ConditionalCursorMove(expirationFrame: localFrameSent &+ 1, row: last.row,
                                          col: last.col, tentativeUntilEpoch: predictionEpoch)
            c.active = true
            cursors.append(c)
        }
    }

    /// The cursor move `initCursor` left at the end of the list, made sure in release
    /// builds too (D3).
    private mutating func ensureCursor(_ fb: Framebuffer) {
        if cursors.isEmpty {
            initCursor(fb)
        }
    }

    // MARK: kill_epoch (toc:378-408, spec 5.3)

    private mutating func killEpoch(_ epoch: UInt64, _ fb: Framebuffer) {
        cursors.removeAll { $0.tentative(epoch &- 1) }

        var c = ConditionalCursorMove(expirationFrame: localFrameSent &+ 1, row: fb.ds.cursorRow,
                                      col: fb.ds.cursorCol, tentativeUntilEpoch: predictionEpoch)
        c.active = true
        cursors.append(c)

        for i in overlays.indices {
            for j in overlays[i].cells.indices where overlays[i].cells[j].tentative(epoch &- 1) {
                overlays[i].cells[j].reset()
            }
        }

        becomeTentative()
    }

    // MARK: cull (toc:440-626, spec 7)

    public mutating func cull(_ fb: Framebuffer, now: UInt64) {
        if settings.display == .never {
            return
        }

        if lastHeight != fb.ds.height || lastWidth != fb.ds.width {
            lastHeight = fb.ds.height
            lastWidth = fb.ds.width
            reset()
        }

        let interval = UInt64(sendInterval)
        // control srtt_trigger with hysteresis
        if interval > PredictionEngine.srttTriggerHigh {
            srttTrigger = true
        } else if srttTrigger && interval <= PredictionEngine.srttTriggerLow // 20 ms is current minimum value
                    && !isActive { // only turn off when no predictions being shown
            srttTrigger = false
        }

        // control underlining with hysteresis
        if interval > PredictionEngine.flagTriggerHigh {
            flagging = true
        } else if interval <= PredictionEngine.flagTriggerLow {
            flagging = false
        }

        // really big glitches also activate underlining
        if UInt64(glitchTrigger) > PredictionEngine.glitchRepairCount {
            flagging = true
        }

        // go through cell predictions
        var i = 0
        while i < overlays.count {
            let rowNum = overlays[i].rowNum
            if rowNum < 0 || rowNum >= fb.ds.height {
                overlays.remove(at: i)
                continue
            }

            var j = 0
            while j < overlays[i].cells.count {
                switch overlays[i].cells[j].validity(fb, row: rowNum, lateAck: localFrameLateAcked) {
                case .incorrectOrExpired:
                    if overlays[i].cells[j].tentative(confirmedEpoch) {
                        if settings.display == .experimental {
                            overlays[i].cells[j].reset()
                        } else {
                            // resets cells of every row, this one included, and the loop goes on
                            killEpoch(overlays[i].cells[j].tentativeUntilEpoch, fb)
                        }
                    } else {
                        if settings.display == .experimental {
                            overlays[i].cells[j].reset()
                        } else {
                            reset()
                            return
                        }
                    }
                case .correct:
                    let cell = overlays[i].cells[j]
                    if cell.tentativeUntilEpoch > confirmedEpoch {
                        confirmedEpoch = cell.tentativeUntilEpoch
                    }

                    // When predictions come in quickly, slowly take away the glitch trigger.
                    if now &- cell.predictionTime < PredictionEngine.glitchThreshold
                        && (glitchTrigger > 0 && now &- PredictionEngine.glitchRepairMinInterval >= lastQuickConfirmation) {
                        glitchTrigger -= 1
                        lastQuickConfirmation = now
                    }

                    // match rest of row to the actual renditions
                    let actual = fb.getCell(rowNum, cell.col).renditions
                    for k in j..<overlays[i].cells.count {
                        overlays[i].cells[k].replacement.renditions = actual
                    }

                    // fallthrough
                    overlays[i].cells[j].reset()
                case .correctNoCredit:
                    overlays[i].cells[j].reset()
                case .pending:
                    // When a prediction takes a long time to be confirmed, we activate the
                    // predictions even if SRTT is low
                    let age = now &- overlays[i].cells[j].predictionTime
                    if age >= PredictionEngine.glitchFlagThreshold {
                        glitchTrigger = UInt32(PredictionEngine.glitchRepairCount * 2) // display and underline
                    } else if age >= PredictionEngine.glitchThreshold
                                && UInt64(glitchTrigger) < PredictionEngine.glitchRepairCount {
                        glitchTrigger = UInt32(PredictionEngine.glitchRepairCount) // just display
                    }
                case .inactive:
                    break
                }
                j += 1
            }
            i += 1
        }

        // go through cursor predictions
        if !cursors.isEmpty
            && cursors[cursors.count - 1].validity(fb, lateAck: localFrameLateAcked) == .incorrectOrExpired {
            if settings.display == .experimental {
                cursors.removeAll()
            } else {
                reset()
                return
            }
        }

        cursors.removeAll { $0.validity(fb, lateAck: localFrameLateAcked) != .pending }
    }

    // MARK: apply (toc:356-376, spec 8)

    public func apply(_ fb: inout Framebuffer) {
        if settings.display == .never
            || !(srttTrigger || glitchTrigger != 0 || settings.display == .always || settings.display == .experimental) {
            return
        }
        for c in cursors {
            c.apply(&fb, confirmedEpoch: confirmedEpoch)
        }
        for row in overlays {
            row.apply(&fb, confirmedEpoch: confirmedEpoch, flag: flagging)
        }
    }

    // MARK: new_user_byte (toc:652-862, spec 6)

    public mutating func newUserByte(_ theByte: UInt8, _ fb: Framebuffer, now: UInt64) {
        if settings.display == .never {
            return
        }
        if settings.display == .experimental {
            predictionEpoch = confirmedEpoch
        }

        cull(fb, now: now)

        // translate application-mode cursor control function to ANSI cursor control sequence
        var theByte = theByte
        if lastByte == 0x1B && theByte == UInt8(ascii: "O") {
            theByte = UInt8(ascii: "[")
        }
        lastByte = theByte

        var actions: [ParserAction] = []
        parser.input(theByte, into: &actions)

        for act in actions {
            switch act.kind {
            case .print:
                // make new prediction
                initCursor(fb)
                assert(act.charPresent)
                let ch = act.ch
                if ch == 0x7F {
                    backspace(fb, now: now)
                } else if ch < 0x20 || WCWidth.wcwidth(ch) != 1 {
                    // unknown print
                    becomeTentative()
                } else {
                    printable(ch, fb, now: now)
                }
            case .execute:
                if act.charPresent && act.ch == 0x0D { // CR
                    becomeTentative()
                    newlineCarriageReturn(fb, now: now)
                } else {
                    becomeTentative()
                }
            case .escDispatch:
                becomeTentative()
            case .csiDispatch:
                if act.charPresent && act.ch == UInt32(UInt8(ascii: "C")) { // right arrow
                    initCursor(fb)
                    let c = lastCursor
                    if cursors[c].col < fb.ds.width - 1 {
                        cursors[c].col += 1
                        cursors[c].expire(localFrameSent &+ 1, now: now)
                    }
                } else if act.charPresent && act.ch == UInt32(UInt8(ascii: "D")) { // left arrow
                    initCursor(fb)
                    let c = lastCursor
                    if cursors[c].col > 0 {
                        cursors[c].col -= 1
                        cursors[c].expire(localFrameSent &+ 1, now: now)
                    }
                } else {
                    becomeTentative()
                }
            default:
                break
            }
        }
    }

    /// toc:698-744: backspace (0x7f as a Print).
    private mutating func backspace(_ fb: Framebuffer, now: UInt64) {
        ensureCursor(fb)
        let r = getOrMakeRow(cursors[lastCursor].row, fb.ds.width)  // even at col 0 (quirk 22)
        let c = lastCursor
        guard cursors[c].col > 0 else { return }
        cursors[c].col -= 1
        cursors[c].expire(localFrameSent &+ 1, now: now)
        let row = cursors[c].row
        let col = cursors[c].col
        let width = fb.ds.width
        guard PredictionBounds.check(col < overlays[r].cells.count, "backspace col \(col)") else { return }

        if settings.overwrite {
            var cell = overlays[r].cells[col]
            cell.resetWithOrig()
            cell.active = true
            cell.tentativeUntilEpoch = predictionEpoch
            cell.expire(localFrameSent &+ 1, now: now)
            let orig = fb.getCell()  // the frame's cursor cell, not the predicted one (quirk 3)
            cell.originalContents.append(orig)
            cell.replacement = orig
            cell.replacement.contents = []
            cell.replacement.append(0x20)
            overlays[r].cells[col] = cell
        } else {
            // mosh reads fb.get_cell( cursor().row, i ), which throws out of range
            guard PredictionBounds.check(row >= 0 && row < fb.ds.height && width <= overlays[r].cells.count,
                                         "backspace row \(row)") else { return }
            var i = col
            while i < width {
                var cell = overlays[r].cells[i]
                cell.resetWithOrig()
                cell.active = true
                cell.tentativeUntilEpoch = predictionEpoch
                cell.expire(localFrameSent &+ 1, now: now)
                cell.originalContents.append(fb.getCell(row, i))

                if i + 2 < width {  // quirk 4
                    let next = overlays[r].cells[i + 1]
                    let nextActual = fb.getCell(row, i + 1)
                    if next.active {
                        if next.unknown {
                            cell.unknown = true
                        } else {
                            cell.unknown = false
                            cell.replacement = next.replacement
                        }
                    } else {
                        cell.unknown = false
                        cell.replacement = nextActual
                    }
                } else {
                    cell.unknown = true
                }
                overlays[r].cells[i] = cell
                i += 1
            }
        }
    }

    /// toc:750-830: a printable character of width 1.
    private mutating func printable(_ ch: UInt32, _ fb: Framebuffer, now: UInt64) {
        ensureCursor(fb)
        let c = lastCursor
        // toc:751-754; D3: in release the byte is not predicted.
        guard PredictionBounds.check(cursors[c].row >= 0, "cursor row \(cursors[c].row) < 0"),
              PredictionBounds.check(cursors[c].col >= 0, "cursor col \(cursors[c].col) < 0"),
              PredictionBounds.check(cursors[c].row < fb.ds.height, "cursor row \(cursors[c].row) >= height"),
              PredictionBounds.check(cursors[c].col < fb.ds.width, "cursor col \(cursors[c].col) >= width") else {
            return
        }

        let r = getOrMakeRow(cursors[c].row, fb.ds.width)
        let width = fb.ds.width
        guard PredictionBounds.check(width <= overlays[r].cells.count, "row width") else { return }

        if cursors[c].col + 1 >= width {
            // prediction in the last column is tricky
            // e.g., emacs will show wrap character, shell will just put the character there
            becomeTentative()
        }

        let row = cursors[c].row
        let col = cursors[c].col

        // do the insert
        let rightmost = settings.overwrite ? col : width - 1
        var i = rightmost
        while i > col {
            var cell = overlays[r].cells[i]
            cell.resetWithOrig()
            cell.active = true
            cell.tentativeUntilEpoch = predictionEpoch
            cell.expire(localFrameSent &+ 1, now: now)
            cell.originalContents.append(fb.getCell(row, i))

            let prev = overlays[r].cells[i - 1]
            let prevActual = fb.getCell(row, i - 1)

            if i == width - 1 {
                cell.unknown = true
            } else if prev.active {
                if prev.unknown {
                    cell.unknown = true
                } else {
                    cell.unknown = false
                    cell.replacement = prev.replacement
                }
            } else {
                cell.unknown = false
                cell.replacement = prevActual
            }
            overlays[r].cells[i] = cell
            i -= 1
        }

        var cell = overlays[r].cells[col]
        cell.resetWithOrig()
        cell.active = true
        cell.tentativeUntilEpoch = predictionEpoch
        cell.expire(localFrameSent &+ 1, now: now)
        cell.replacement.renditions = fb.ds.renditions

        // heuristic: match renditions of character to the left
        if col > 0 {
            let prev = overlays[r].cells[col - 1]
            let prevActual = fb.getCell(row, col - 1)
            if prev.active && !prev.unknown {
                cell.replacement.renditions = prev.replacement.renditions
            } else {
                cell.replacement.renditions = prevActual.renditions
            }
        }

        cell.replacement.contents = []
        cell.replacement.append(ch)
        cell.originalContents.append(fb.getCell(row, col))
        overlays[r].cells[col] = cell

        cursors[c].expire(localFrameSent &+ 1, now: now)

        // do we need to wrap?
        if cursors[c].col < width - 1 {
            cursors[c].col += 1
        } else {
            becomeTentative()
            newlineCarriageReturn(fb, now: now)
        }
    }

    // MARK: newline_carriage_return (toc:864-899, spec 6.6)

    /// mosh reads `timestamp()` here again; within one step it is the same frozen value,
    /// so the caller's `now` is passed. No `expire` of the cursor (quirk 7).
    private mutating func newlineCarriageReturn(_ fb: Framebuffer, now: UInt64) {
        initCursor(fb)
        ensureCursor(fb)
        let c = lastCursor
        cursors[c].col = 0
        if cursors[c].row == fb.ds.height - 1 {
            // Don't try to predict scroll until we have versioned cell predictions

            // make blank prediction for last row
            let r = getOrMakeRow(cursors[c].row, fb.ds.width)
            for j in overlays[r].cells.indices {
                overlays[r].cells[j].active = true
                overlays[r].cells[j].tentativeUntilEpoch = predictionEpoch
                overlays[r].cells[j].expire(localFrameSent &+ 1, now: now)
                overlays[r].cells[j].replacement.contents = []  // quirk 6: renditions and unknown stay
            }
        } else {
            cursors[c].row += 1
        }
    }

    // MARK: stmclient's use of the engine

    /// stc:322-334 without the escape-key logic: `set_local_frame_sent( lastSent )`, then a
    /// paste (more than 100 bytes) resets and predicts nothing, otherwise `new_user_byte`
    /// for each byte, all with the same frame and the same time.
    public mutating func newUserRead(_ bytes: [UInt8], lastSent: UInt64, _ fb: Framebuffer, now: UInt64) {
        setLocalFrameSent(lastSent)
        let paste = bytes.count > PredictionEngine.pasteThreshold
        if paste {
            reset()
        }
        if !paste {
            for b in bytes {
                newUserByte(b, fb, now: now)
            }
        }
    }

    /// stc:274-277 with `OverlayManager::apply` (toc:333-340) without notifications and
    /// title (D1): a copy of `remote`, culled, then drawn on.
    public mutating func overlay(_ remote: Framebuffer, now: UInt64) -> Framebuffer {
        var f = remote
        cull(f, now: now)
        apply(&f)
        return f
    }
}
