// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Emulator` (src/terminal/terminal.{cc,h}) and of the
// `act_on_terminal` methods in src/terminal/parseraction.cc.

/// The terminal emulator: a framebuffer, the dispatcher and the user-input translator.
///
/// Synthesized `==` compares all three. `moshEquals` is mosh's `operator==`, which
/// compares only the framebuffer ("dispatcher and user are irrelevant for us").
public struct Emulator: Equatable, Sendable {
    public internal(set) var fb: Framebuffer
    public internal(set) var dispatch: Dispatcher
    public internal(set) var user: UserInput

    public init(width: Int, height: Int) {
        fb = Framebuffer(width: width, height: height)
        dispatch = Dispatcher()
        user = UserInput()
    }

    /// Rebuild from field values (serialization).
    public init(fb: Framebuffer, dispatch: Dispatcher, user: UserInput) {
        self.fb = fb
        self.dispatch = dispatch
        self.user = user
    }

    /// mosh `read_octets_to_host`: take the reply string and empty it.
    public mutating func readOctetsToHost() -> [UInt8] {
        let ret = dispatch.terminalToHost
        dispatch.terminalToHost.removeAll(keepingCapacity: false)
        return ret
    }

    /// mosh `Action::act_on_terminal` for every action of the host-side state machine.
    /// `hook`, `put` and `unhook` (DCS strings) do nothing in mosh.
    mutating func act(_ kind: ParserActionKind, ch: UInt32) {
        switch kind {
        case .print: print(ch)
        case .execute: dispatch.dispatch(.control, ch: ch, fb: &fb)
        case .clear: dispatch.clear()
        case .param: dispatch.newParamChar(ch)
        case .collect: dispatch.collect(ch)
        case .csiDispatch: dispatch.dispatch(.csi, ch: ch, fb: &fb)
        case .escDispatch: escDispatch(ch)
        case .oscPut: dispatch.oscPut(ch)
        case .oscStart: dispatch.oscStart()
        case .oscEnd: dispatch.oscDispatch(fb: &fb)
        case .ignore, .hook, .put, .unhook: break
        }
    }

    /// Apply one parser action (the public form of `act_on_terminal`).
    public mutating func act(_ action: ParserAction) {
        act(action.kind, ch: action.ch)
    }

    /// mosh `Parser::UserByte::act_on_terminal`: translate a user byte and queue it for
    /// the host.
    public mutating func actUserByte(_ c: UInt8) {
        dispatch.terminalToHost.append(
            contentsOf: user.input(c, applicationModeCursorKeys: fb.ds.applicationModeCursorKeys))
    }

    /// mosh `Emulator::print`.
    ///
    /// Width comes from `Cell.isPrintISO8859_1` first and `wcwidth` (glibc's table) second;
    /// NUL and anything `wcwidth` rejects (-1) is dropped; width 0 is a combining character.
    mutating func print(_ ch: UInt32) {
        // Check for printing ISO 8859-1 first, it's a cheap way to detect
        // some common narrow characters.
        let chwidth = ch == 0 ? -1 : (Cell.isPrintISO8859_1(ch) ? 1 : WCWidth.wcwidth(ch))

        // `Cell *this_cell = fb.get_mutable_cell();` -- this unshares the cursor row
        // whatever the character is, also for one that is then dropped.
        //
        // mosh carries `this_cell` through the branches below and sets it to NULL where
        // the cursor moved or cells shifted, to fetch it again. In every path it ends up
        // as the cell at the cursor, so this port addresses that cell by index.
        fb.makeRowUnique()

        switch chwidth {
        case 1, // normal character
             2: // wide character
            if fb.ds.autoWrapMode && fb.ds.nextPrintWillWrap {
                fb.rows[fb.makeRowUnique()].wrap = true
                fb.ds.moveCol(0)
                fb.moveRowsAutoscroll(1)
            } else if fb.ds.autoWrapMode
                && chwidth == 2
                && fb.ds.cursorCol == fb.ds.width - 1 {
                // wrap 2-cell chars if no room, even without will-wrap flag
                fb.resetCell()
                fb.rows[fb.makeRowUnique()].wrap = false
                // There doesn't seem to be a consistent way to get the
                // downstream terminal emulator to set the wrap-around
                // copy-and-paste flag on a row that ends with an empty cell
                // because a wide char was wrapped to the next line.
                fb.ds.moveCol(0)
                fb.moveRowsAutoscroll(1)
            }

            if fb.ds.insertMode {
                var i = 0
                while i < chwidth {
                    fb.insertCell(fb.ds.cursorRow, fb.ds.cursorCol)
                    i += 1
                }
            }

            let row = fb.makeRowUnique()
            let col = fb.ds.cursorCol

            fb.rows[row].cells[col].reset(backgroundColor: fb.ds.backgroundRendition)
            fb.rows[row].cells[col].append(ch)
            fb.rows[row].cells[col].wide = (chwidth == 2) // chwidth had better be 1 or 2 here
            fb.rows[row].cells[col].renditions = fb.ds.renditions

            if chwidth == 2 && fb.ds.cursorCol + 1 < fb.ds.width { // erase overlapped cell
                fb.resetCell(fb.ds.cursorRow, fb.ds.cursorCol + 1)
            }

            fb.ds.moveCol(chwidth, relative: true, implicit: true)

        case 0: // combining character
            // can be null if we were resized
            if fb.ds.combiningCharCol < 0
                || fb.ds.combiningCharRow < 0
                || fb.ds.combiningCharCol >= fb.ds.width
                || fb.ds.combiningCharRow >= fb.ds.height {
                break // character is now offscreen
            }
            let row = fb.makeRowUnique(fb.ds.combiningCharRow)
            let col = fb.ds.combiningCharCol

            if fb.rows[row].cells[col].isEmpty {
                // cell starts with combining character
                // ... but isn't necessarily the target for a new
                // base character [e.g. start of line], if the
                // combining character has been cleared with
                // a sequence like ED ("J") or EL ("K")
                fb.rows[row].cells[col].fallback = true
                fb.ds.moveCol(1, relative: true, implicit: true)
            }
            if !fb.rows[row].cells[col].isFull {
                fb.rows[row].cells[col].append(ch)
            }

        default: // -1: unprintable character
            break
        }
    }

    /// mosh `Emulator::Esc_dispatch`.
    private mutating func escDispatch(_ ch: UInt32) {
        // handle 7-bit ESC-encoding of C1 control characters
        if dispatch.dispatchChars.isEmpty && 0x40 <= ch && ch <= 0x5F {
            dispatch.dispatch(.control, ch: ch + 0x40, fb: &fb)
        } else {
            dispatch.dispatch(.escape, ch: ch, fb: &fb)
        }
    }

    /// mosh `Emulator::resize`.
    public mutating func resize(width: Int, height: Int) {
        fb.resize(width: width, height: height)
    }

    /// mosh `Emulator::operator==`: the framebuffers are equal by mosh's rules.
    public func moshEquals(_ x: Emulator) -> Bool {
        return fb.moshEquals(x.fb)
    }
}
