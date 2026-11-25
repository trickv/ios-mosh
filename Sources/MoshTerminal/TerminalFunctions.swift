// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 src/terminal/terminalfunctions.cc: the routines activated by a
// CSI sequence, an escape sequence or a control character, and their registry.
//
// Every function mosh registers is here, in the order of the source file, including
// those that a server diff never contains.

/// mosh `Terminal::Function`: a routine and whether dispatching it clears the wrap flag.
struct TerminalFunction: Sendable {
    /// The routines of terminalfunctions.cc, one case per C++ function.
    enum Routine: UInt8, Sendable {
        case csiEL
        case csiED
        case csiCursorMove
        case csiDA
        case csiSDA
        case escDECALN
        case ctrlLF
        case ctrlCR
        case ctrlBS
        case ctrlRI
        case ctrlNEL
        case ctrlHT
        case csiCxT
        case ctrlHTS
        case csiTBC
        case csiDECSM
        case csiDECRM
        case csiSM
        case csiRM
        case csiDECSTBM
        case ctrlBEL
        case csiSGR
        case escDECSC
        case escDECRC
        case csiDSR
        case csiIL
        case csiDL
        case csiICH
        case csiDCH
        case csiVPA
        case csiHPA
        case csiECH
        case escRIS
        case csiDECSTR
        case csiSD
        case csiSU
    }

    var routine: Routine
    var clearsWrapState: Bool

    /// mosh `function( fb, dispatch )`.
    func function(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
        switch routine {
        case .csiEL: csiEL(&fb, &dispatch)
        case .csiED: csiED(&fb, &dispatch)
        case .csiCursorMove: csiCursorMove(&fb, &dispatch)
        case .csiDA: csiDA(&fb, &dispatch)
        case .csiSDA: csiSDA(&fb, &dispatch)
        case .escDECALN: escDECALN(&fb, &dispatch)
        case .ctrlLF: ctrlLF(&fb, &dispatch)
        case .ctrlCR: ctrlCR(&fb, &dispatch)
        case .ctrlBS: ctrlBS(&fb, &dispatch)
        case .ctrlRI: ctrlRI(&fb, &dispatch)
        case .ctrlNEL: ctrlNEL(&fb, &dispatch)
        case .ctrlHT: ctrlHT(&fb, &dispatch)
        case .csiCxT: csiCxT(&fb, &dispatch)
        case .ctrlHTS: ctrlHTS(&fb, &dispatch)
        case .csiTBC: csiTBC(&fb, &dispatch)
        case .csiDECSM: csiDECSM(&fb, &dispatch)
        case .csiDECRM: csiDECRM(&fb, &dispatch)
        case .csiSM: csiSM(&fb, &dispatch)
        case .csiRM: csiRM(&fb, &dispatch)
        case .csiDECSTBM: csiDECSTBM(&fb, &dispatch)
        case .ctrlBEL: ctrlBEL(&fb, &dispatch)
        case .csiSGR: csiSGR(&fb, &dispatch)
        case .escDECSC: escDECSC(&fb, &dispatch)
        case .escDECRC: escDECRC(&fb, &dispatch)
        case .csiDSR: csiDSR(&fb, &dispatch)
        case .csiIL: csiIL(&fb, &dispatch)
        case .csiDL: csiDL(&fb, &dispatch)
        case .csiICH: csiICH(&fb, &dispatch)
        case .csiDCH: csiDCH(&fb, &dispatch)
        case .csiVPA: csiVPA(&fb, &dispatch)
        case .csiHPA: csiHPA(&fb, &dispatch)
        case .csiECH: csiECH(&fb, &dispatch)
        case .escRIS: escRIS(&fb, &dispatch)
        case .csiDECSTR: csiDECSTR(&fb, &dispatch)
        case .csiSD: csiSD(&fb, &dispatch)
        case .csiSU: csiSU(&fb, &dispatch)
        }
    }
}

/// mosh `DispatchRegistry`: dispatch characters (intermediates then final) to function.
struct DispatchRegistry: Sendable {
    var escape: [[UInt8]: TerminalFunction] = [:]
    var csi: [[UInt8]: TerminalFunction] = [:]
    var control: [UInt8: TerminalFunction] = [:]

    /// mosh `register_function`. Like `std::map::insert`, the first registration of a
    /// key wins (there are no duplicates).
    private mutating func register(_ type: FunctionType, _ dispatchChars: String,
                                   _ f: TerminalFunction.Routine,
                                   clearsWrapState: Bool = true) {
        let key = Array(dispatchChars.utf8)
        let fn = TerminalFunction(routine: f, clearsWrapState: clearsWrapState)
        switch type {
        case .escape: if escape[key] == nil { escape[key] = fn }
        case .csi: if csi[key] == nil { csi[key] = fn }
        case .control: preconditionFailure("controls are registered by byte")
        }
    }

    private mutating func registerControl(_ byte: UInt8,
                                          _ f: TerminalFunction.Routine,
                                          clearsWrapState: Bool = true) {
        if control[byte] == nil {
            control[byte] = TerminalFunction(routine: f, clearsWrapState: clearsWrapState)
        }
    }

    static let shared: DispatchRegistry = {
        var r = DispatchRegistry()
        r.register(.csi, "K", .csiEL)
        r.register(.csi, "J", .csiED)
        r.register(.csi, "A", .csiCursorMove)
        r.register(.csi, "B", .csiCursorMove)
        r.register(.csi, "C", .csiCursorMove)
        r.register(.csi, "D", .csiCursorMove)
        r.register(.csi, "H", .csiCursorMove)
        r.register(.csi, "f", .csiCursorMove)
        r.register(.csi, "c", .csiDA)
        r.register(.csi, ">c", .csiSDA)
        r.register(.escape, "#8", .escDECALN)
        // same procedure for index, vertical tab, and form feed control codes
        r.registerControl(0x0A, .ctrlLF)
        r.registerControl(0x84, .ctrlLF) // IND
        r.registerControl(0x0B, .ctrlLF) // VT
        r.registerControl(0x0C, .ctrlLF) // FF
        r.registerControl(0x0D, .ctrlCR)
        r.registerControl(0x08, .ctrlBS)
        r.registerControl(0x8D, .ctrlRI)
        r.registerControl(0x85, .ctrlNEL)
        r.registerControl(0x09, .ctrlHT, clearsWrapState: false)
        r.register(.csi, "I", .csiCxT, clearsWrapState: false)
        r.register(.csi, "Z", .csiCxT, clearsWrapState: false)
        r.registerControl(0x88, .ctrlHTS)
        // TBC preserves wrap state
        r.register(.csi, "g", .csiTBC, clearsWrapState: false)
        // These functions don't clear wrap state.
        r.register(.csi, "?h", .csiDECSM, clearsWrapState: false)
        r.register(.csi, "?l", .csiDECRM, clearsWrapState: false)
        r.register(.csi, "h", .csiSM)
        r.register(.csi, "l", .csiRM)
        r.register(.csi, "r", .csiDECSTBM)
        r.registerControl(0x07, .ctrlBEL)
        // changing renditions doesn't clear wrap flag
        r.register(.csi, "m", .csiSGR, clearsWrapState: false)
        r.register(.escape, "7", .escDECSC)
        r.register(.escape, "8", .escDECRC)
        r.register(.csi, "n", .csiDSR)
        r.register(.csi, "L", .csiIL)
        r.register(.csi, "M", .csiDL)
        r.register(.csi, "@", .csiICH)
        r.register(.csi, "P", .csiDCH)
        r.register(.csi, "d", .csiVPA)
        r.register(.csi, "G", .csiHPA) // ECMA-48 name: CHA
        r.register(.csi, "`", .csiHPA) // ECMA-48 name: HPA
        r.register(.csi, "X", .csiECH)
        r.register(.escape, "c", .escRIS)
        r.register(.csi, "!p", .csiDECSTR)
        r.register(.csi, "S", .csiSD)
        r.register(.csi, "T", .csiSU)
        return r
    }()
}

private func clearline(_ fb: inout Framebuffer, _ row: Int, _ start: Int, _ end: Int) {
    var col = start
    while col <= end {
        fb.resetCell(row, col)
        col += 1
    }
}

/// erase in line
private func csiEL(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    switch dispatch.getparam(0, 0) {
    case 0: // default: active position to end of line, inclusive
        clearline(&fb, -1, fb.ds.cursorCol, fb.ds.width - 1)
    case 1: // start of screen to active position, inclusive
        clearline(&fb, -1, 0, fb.ds.cursorCol)
    case 2: // all of line
        fb.resetRow(-1)
    default:
        break
    }
}

/// erase in display
private func csiED(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    switch dispatch.getparam(0, 0) {
    case 0: // active position to end of screen, inclusive
        clearline(&fb, -1, fb.ds.cursorCol, fb.ds.width - 1)
        var y = fb.ds.cursorRow + 1
        while y < fb.ds.height {
            fb.resetRow(y)
            y += 1
        }
    case 1: // start of screen to active position, inclusive
        var y = 0
        while y < fb.ds.cursorRow {
            fb.resetRow(y)
            y += 1
        }
        clearline(&fb, -1, 0, fb.ds.cursorCol)
    case 2: // entire screen
        var y = 0
        while y < fb.ds.height {
            fb.resetRow(y)
            y += 1
        }
    default:
        break
    }
}

/// cursor movement -- relative and absolute
private func csiCursorMove(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let num = dispatch.getparam(0, 1)

    switch dispatch.dispatchChars[0] {
    case UInt8(ascii: "A"):
        fb.ds.moveRow(-num, relative: true)
    case UInt8(ascii: "B"):
        fb.ds.moveRow(num, relative: true)
    case UInt8(ascii: "C"):
        fb.ds.moveCol(num, relative: true)
    case UInt8(ascii: "D"):
        fb.ds.moveCol(-num, relative: true)
    case UInt8(ascii: "H"), UInt8(ascii: "f"):
        fb.ds.moveRow(dispatch.getparam(0, 1) - 1)
        fb.ds.moveCol(dispatch.getparam(1, 1) - 1)
    default:
        break
    }
}

/// device attributes
private func csiDA(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    dispatch.terminalToHost.append(contentsOf: Array("\u{1B}[?62c".utf8)) // plain vt220
}

/// secondary device attributes
private func csiSDA(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    dispatch.terminalToHost.append(contentsOf: Array("\u{1B}[>1;10;0c".utf8)) // plain vt220
}

/// screen alignment diagnostic. Keeps each cell's soft-wrap bit cleared and takes the
/// background of the pen, like every erase; the generation of the rows does not change.
private func escDECALN(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var y = 0
    while y < fb.ds.height {
        var x = 0
        while x < fb.ds.width {
            fb.resetCell(y, x)
            fb.rows[fb.makeRowUnique(y)].cells[x].append(UInt32(UInt8(ascii: "E")))
            x += 1
        }
        y += 1
    }
}

/// line feed
private func ctrlLF(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.moveRowsAutoscroll(1)
}

/// carriage return
private func ctrlCR(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.moveCol(0)
}

/// backspace
private func ctrlBS(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.moveCol(-1, relative: true)
}

/// reverse index -- like a backwards line feed
private func ctrlRI(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.moveRowsAutoscroll(-1)
}

/// newline
private func ctrlNEL(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.moveCol(0)
    fb.moveRowsAutoscroll(1)
}

/// horizontal tab
private func htN(_ fb: inout Framebuffer, _ count: Int) {
    var col = fb.ds.getNextTab(count)
    if col == -1 { // no tabs, go to end of line
        col = fb.ds.width - 1
    }

    // A horizontal tab is the only operation that preserves but
    // does not set the wrap state. It also starts a new grapheme.

    let wrapStateSave = fb.ds.nextPrintWillWrap
    fb.ds.moveCol(col, relative: false)
    fb.ds.nextPrintWillWrap = wrapStateSave
}

private func ctrlHT(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    htN(&fb, 1)
}

/// CHT (`I`) and CBT (`Z`)
private func csiCxT(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var param = dispatch.getparam(0, 1)
    if dispatch.dispatchChars[0] == UInt8(ascii: "Z") {
        param = -param
    }
    if param == 0 {
        return
    }
    htN(&fb, param)
}

/// horizontal tab set
private func ctrlHTS(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.setTab()
}

/// tabulation clear
private func csiTBC(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let param = dispatch.getparam(0, 0)
    switch param {
    case 0: // clear this tab stop
        fb.ds.clearTab(fb.ds.cursorCol)
    case 3: // clear all tab stops
        fb.ds.clearDefaultTabs()
        var x = 0
        while x < fb.ds.width {
            fb.ds.clearTab(x)
            x += 1
        }
    default:
        break
    }
}

/// The boolean DEC private modes (mosh `get_DEC_mode`). Modes 3 and 6 have side effects
/// that happen on set and on reset alike, before the mode itself changes.
private enum DECMode {
    case applicationModeCursorKeys, reverseVideo, originMode, autoWrapMode, cursorVisible
    case mouseFocusEvent, mouseAlternateScroll, bracketedPaste
}

private func getDECMode(_ param: Int, _ fb: inout Framebuffer) -> DECMode? {
    switch param {
    case 1: // cursor key mode
        return .applicationModeCursorKeys
    case 3: // 80/132. Ignore but clear screen.
        // clear screen
        fb.ds.moveRow(0)
        fb.ds.moveCol(0)
        var y = 0
        while y < fb.ds.height {
            fb.resetRow(y)
            y += 1
        }
        return nil
    case 5: // reverse video
        return .reverseVideo
    case 6: // origin
        fb.ds.moveRow(0)
        fb.ds.moveCol(0)
        return .originMode
    case 7: // auto wrap
        return .autoWrapMode
    case 25:
        return .cursorVisible
    case 1004: // xterm mouse focus event
        return .mouseFocusEvent
    case 1007: // xterm mouse alternate scroll
        return .mouseAlternateScroll
    case 2004: // bracketed paste
        return .bracketedPaste
    default:
        break
    }
    return nil
}

/// helper for CSI_DECSM and CSI_DECRM
private func setIfAvailable(_ mode: DECMode?, _ value: Bool, _ fb: inout Framebuffer) {
    guard let mode = mode else { return }
    switch mode {
    case .applicationModeCursorKeys: fb.ds.applicationModeCursorKeys = value
    case .reverseVideo: fb.ds.reverseVideo = value
    case .originMode: fb.ds.originMode = value
    case .autoWrapMode: fb.ds.autoWrapMode = value
    case .cursorVisible: fb.ds.cursorVisible = value
    case .mouseFocusEvent: fb.ds.mouseFocusEvent = value
    case .mouseAlternateScroll: fb.ds.mouseAlternateScroll = value
    case .bracketedPaste: fb.ds.bracketedPaste = value
    }
}

/// set private mode
private func csiDECSM(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var i = 0
    while i < dispatch.paramCount() {
        let param = dispatch.getparam(i, 0)
        if param == 9 || (param >= 1000 && param <= 1003) {
            fb.ds.mouseReportingMode = MouseReportingMode(rawValue: param)!
        } else if param == 1005 || param == 1006 || param == 1015 {
            fb.ds.mouseEncodingMode = MouseEncodingMode(rawValue: param)!
        } else {
            setIfAvailable(getDECMode(param, &fb), true, &fb)
        }
        i += 1
    }
}

/// clear private mode
private func csiDECRM(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var i = 0
    while i < dispatch.paramCount() {
        let param = dispatch.getparam(i, 0)
        if param == 9 || (param >= 1000 && param <= 1003) {
            fb.ds.mouseReportingMode = .none
        } else if param == 1005 || param == 1006 || param == 1015 {
            fb.ds.mouseEncodingMode = .default
        } else {
            setIfAvailable(getDECMode(param, &fb), false, &fb)
        }
        i += 1
    }
}

/// The ANSI modes (mosh `get_ANSI_mode`): only 4, insert/replace mode.
private func setANSIMode(_ param: Int, _ value: Bool, _ fb: inout Framebuffer) {
    if param == 4 { // insert/replace mode
        fb.ds.insertMode = value
    }
}

/// set mode
private func csiSM(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var i = 0
    while i < dispatch.paramCount() {
        setANSIMode(dispatch.getparam(i, 0), true, &fb)
        i += 1
    }
}

/// clear mode
private func csiRM(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var i = 0
    while i < dispatch.paramCount() {
        setANSIMode(dispatch.getparam(i, 0), false, &fb)
        i += 1
    }
}

/// set top and bottom margins
private func csiDECSTBM(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let top = dispatch.getparam(0, 1)
    let bottom = dispatch.getparam(1, fb.ds.height)

    if bottom <= top
        || top > fb.ds.height
        || (top == 0 && bottom == 1) {
        return // invalid, xterm ignores
    }

    fb.ds.setScrollingRegion(top: top - 1, bottom: bottom - 1)
    fb.ds.moveRow(0)
    fb.ds.moveCol(0)
}

/// terminal bell
private func ctrlBEL(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ringBell()
}

/// select graphics rendition -- e.g., bold, blinking, etc.
private func csiSGR(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    var i = 0
    while i < dispatch.paramCount() {
        let rendition = dispatch.getparam(i, 0)
        // We need to special-case the handling of [34]8 ; 5 ; Ps,
        // because Ps of 0 in that case does not mean reset to default, even
        // though it means that otherwise (as usually renditions are applied
        // in order).
        if (rendition == 38 || rendition == 48)
            && (dispatch.paramCount() - i >= 3)
            && (dispatch.getparam(i + 1, -1) == 5) {
            if rendition == 38 {
                fb.ds.setForegroundColor(UInt32(dispatch.getparam(i + 2, 0)))
            } else {
                fb.ds.setBackgroundColor(UInt32(dispatch.getparam(i + 2, 0)))
            }
            i += 2
            i += 1
            continue
        }

        // True color support: ESC[ ... [34]8;2;<r>;<g>;<b> ... m
        if (rendition == 38 || rendition == 48)
            && (dispatch.paramCount() - i >= 5)
            && (dispatch.getparam(i + 1, -1) == 2) {
            let red = UInt32(dispatch.getparam(i + 2, 0))
            let green = UInt32(dispatch.getparam(i + 3, 0))
            let blue = UInt32(dispatch.getparam(i + 4, 0))

            let color = Renditions.makeTrueColor(red, green, blue)

            if rendition == 38 {
                fb.ds.setForegroundColor(color)
            } else {
                fb.ds.setBackgroundColor(color)
            }
            i += 4
            i += 1
            continue
        }

        fb.ds.addRendition(UInt32(rendition))
        i += 1
    }
}

/// save and restore cursor
private func escDECSC(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.saveCursor()
}

private func escDECRC(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.ds.restoreCursor()
}

/// device status report -- e.g., cursor position (used by resize)
private func csiDSR(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let param = dispatch.getparam(0, 0)

    switch param {
    case 5: // device status report requested
        dispatch.terminalToHost.append(contentsOf: Array("\u{1B}[0n".utf8))
    case 6: // report of active position requested
        dispatch.terminalToHost.append(
            contentsOf: Array("\u{1B}[\(fb.ds.cursorRow + 1);\(fb.ds.cursorCol + 1)R".utf8))
    default:
        break
    }
}

/// insert line
private func csiIL(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let lines = dispatch.getparam(0, 1)

    fb.insertLine(fb.ds.cursorRow, lines)

    // vt220 manual and Ecma-48 say to move to first column
    // but xterm and gnome-terminal don't
    fb.ds.moveCol(0)
}

/// delete line
private func csiDL(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let lines = dispatch.getparam(0, 1)

    fb.deleteLine(fb.ds.cursorRow, lines)

    // same story -- xterm and gnome-terminal don't
    // move to first column
    fb.ds.moveCol(0)
}

/// insert characters
private func csiICH(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let cells = dispatch.getparam(0, 1)

    var i = 0
    while i < cells {
        fb.insertCell(fb.ds.cursorRow, fb.ds.cursorCol)
        i += 1
    }
}

/// delete character
private func csiDCH(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let cells = dispatch.getparam(0, 1)

    var i = 0
    while i < cells {
        fb.deleteCell(fb.ds.cursorRow, fb.ds.cursorCol)
        i += 1
    }
}

/// line position absolute
private func csiVPA(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let row = dispatch.getparam(0, 1)
    fb.ds.moveRow(row - 1)
}

/// character position absolute
private func csiHPA(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let col = dispatch.getparam(0, 1)
    fb.ds.moveCol(col - 1)
}

/// erase character
private func csiECH(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    let num = dispatch.getparam(0, 1)
    var limit = fb.ds.cursorCol + num - 1
    if limit >= fb.ds.width {
        limit = fb.ds.width - 1
    }

    clearline(&fb, -1, fb.ds.cursorCol, limit)
}

/// reset to initial state
private func escRIS(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.reset()
}

/// soft reset
private func csiDECSTR(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.softReset()
}

/// scroll down or terminfo indn
private func csiSD(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.scroll(dispatch.getparam(0, 1))
}

/// scroll up or terminfo rin
private func csiSU(_ fb: inout Framebuffer, _ dispatch: inout Dispatcher) {
    fb.scroll(-dispatch.getparam(0, 1))
}
