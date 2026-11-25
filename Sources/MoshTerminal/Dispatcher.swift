// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Dispatcher` (src/terminal/terminaldispatcher.{cc,h})
// and of `Dispatcher::OSC_dispatch` (src/terminal/terminalfunctions.cc).

/// mosh `Function_Type`.
public enum FunctionType: Sendable {
    case escape, csi, control
}

/// Collects the parameters, intermediates and OSC string of the sequence being parsed
/// and looks up the function a finished sequence names.
///
/// All of this is state that outlives a sequence: nothing is cleared when a sequence is
/// dispatched, only when the next one starts (`clear`, `oscStart`). After `ESC [ 1 m`
/// the dispatcher still holds `params = "1"` and `dispatchChars = "m"`. mosh's
/// `Dispatcher::operator==` compares all six fields; so does the synthesized `==`.
public struct Dispatcher: Equatable, Sendable {
    /// Largest accepted parameter value. Larger values read as "absent" (-1):
    /// "prevent evil escape sequences from causing long loops".
    public static let paramMax = 65535
    /// Limit of the OSC string, in characters.
    public static let maximumClipboardSize = 16 * 1024

    /// The raw parameter characters (digits and ';'), at most 100.
    public internal(set) var params: [UInt8] = []
    /// The parameters as parsed by the last `getparam` / `paramCount`. Stale between a
    /// `clear` and the next of those calls: `clear` only resets `parsed`.
    public internal(set) var parsedParams: [Int] = []
    public internal(set) var parsed: Bool = false

    /// Intermediate characters and, after a dispatch, the final character. At most 8,
    /// only characters up to 255.
    public internal(set) var dispatchChars: [UInt8] = []
    /// The characters of the OSC string in progress or last finished.
    public internal(set) var oscString: [UInt32] = []

    /// The reply string (DA, DSR, translated user keys). `Emulator.readOctetsToHost`
    /// empties it.
    public var terminalToHost: [UInt8] = []

    public init() {}

    /// Rebuild from field values (serialization).
    public init(params: [UInt8], parsedParams: [Int], parsed: Bool, dispatchChars: [UInt8],
                oscString: [UInt32], terminalToHost: [UInt8]) {
        self.params = params
        self.parsedParams = parsedParams
        self.parsed = parsed
        self.dispatchChars = dispatchChars
        self.oscString = oscString
        self.terminalToHost = terminalToHost
    }

    /// mosh `newparamchar`.
    mutating func newParamChar(_ ch: UInt32) {
        if params.count < 100 {
            // enough for 16 five-char params plus 15 semicolons
            params.append(UInt8(truncatingIfNeeded: ch))
        }
        parsed = false
    }

    /// mosh `collect`.
    mutating func collect(_ ch: UInt32) {
        if dispatchChars.count < 8 // never should need more than 2
            && ch <= 255 { // ignore non-8-bit
            dispatchChars.append(UInt8(ch))
        }
    }

    /// mosh `clear`. Does not touch `parsedParams`.
    mutating func clear() {
        params.removeAll(keepingCapacity: true)
        dispatchChars.removeAll(keepingCapacity: true)
        parsed = false
    }

    /// One segment of the parameter string, as mosh reads it with `strtol`: -1 when
    /// empty, when above `paramMax`, or when it overflows a `long`.
    private static func parseSegment(_ digits: ArraySlice<UInt8>) -> Int {
        if digits.isEmpty { return -1 }
        var val = 0
        for d in digits {
            val = val * 10 + Int(d &- 0x30)
            if val > paramMax { return -1 } // can only grow from here
        }
        return val
    }

    /// mosh `parse_params`: one value per ';'-separated segment, so always at least one.
    private mutating func parseParams() {
        if parsed {
            return
        }

        parsedParams.removeAll(keepingCapacity: true)
        var segmentBegin = params.startIndex
        while let segmentEnd = params[segmentBegin...].firstIndex(of: 0x3B) {
            parsedParams.append(Dispatcher.parseSegment(params[segmentBegin..<segmentEnd]))
            segmentBegin = segmentEnd + 1
        }
        // get last param
        parsedParams.append(Dispatcher.parseSegment(params[segmentBegin...]))

        parsed = true
    }

    /// mosh `getparam( N, defaultval )`. A parameter that is absent, empty, zero or out
    /// of range gives the default.
    public mutating func getparam(_ n: Int, _ defaultval: Int) -> Int {
        var ret = defaultval
        if !parsed {
            parseParams()
        }

        if parsedParams.count > n {
            ret = parsedParams[n]
        }

        if ret < 1 { ret = defaultval }

        return ret
    }

    /// mosh `param_count`.
    public mutating func paramCount() -> Int {
        if !parsed {
            parseParams()
        }

        return parsedParams.count
    }

    /// mosh `Dispatcher::dispatch`: run the function registered for this sequence, or
    /// clear the wrap flag if there is none.
    mutating func dispatch(_ type: FunctionType, ch: UInt32, fb: inout Framebuffer) {
        // add final char to dispatch key
        if type == .escape || type == .csi {
            collect(ch)
        }

        let function: TerminalFunction?
        switch type {
        case .escape: function = DispatchRegistry.shared.escape[dispatchChars]
        case .csi: function = DispatchRegistry.shared.csi[dispatchChars]
        case .control:
            // mosh asserts ch <= 255; the parser only executes C0 and C1 controls.
            function = DispatchRegistry.shared.control[UInt8(truncatingIfNeeded: ch)]
        }

        guard let f = function else {
            // unknown function
            fb.ds.nextPrintWillWrap = false
            return
        }
        if f.clearsWrapState {
            fb.ds.nextPrintWillWrap = false
        }
        f.function(&fb, &self)
    }

    /// mosh `OSC_put`.
    mutating func oscPut(_ ch: UInt32) {
        if oscString.count < Dispatcher.maximumClipboardSize {
            oscString.append(ch)
        }
    }

    /// mosh `OSC_start`.
    mutating func oscStart() {
        oscString.removeAll(keepingCapacity: true)
    }

    /// mosh `Dispatcher::OSC_dispatch`: the clipboard (`52;c;`) and the titles (`0;`,
    /// `1;`, `2;`, and a bare `;` which counts as `0;`). Everything else is ignored.
    ///
    /// The title is cut so that command and title together are at most 256 characters.
    /// The clipboard takes the whole rest of the string (the OSC string itself is capped
    /// at `maximumClipboardSize`), undecoded: it is the base64 text.
    mutating func oscDispatch(fb: inout Framebuffer) {
        // handle osc copy clipboard sequence 52;c;
        if oscString.count >= 5 && oscString[0] == 0x35 /* 5 */
            && oscString[1] == 0x32 /* 2 */ && oscString[2] == 0x3B /* ; */
            && oscString[3] == 0x63 /* c */ && oscString[4] == 0x3B /* ; */ {
            fb.setClipboard(Array(oscString[5...]))
            // handle osc terminal title sequence
        } else if oscString.count >= 1 {
            var cmdNum = -1
            var offset = 0
            if oscString[0] == 0x3B {
                // OSC of the form "\033];<title>\007"
                cmdNum = 0 // treat it as as a zero
                offset = 1
            } else if oscString.count >= 2 && oscString[1] == 0x3B {
                // OSC of the form "\033]X;<title>\007" where X can be:
                // 0: set icon name and window title
                // 1: set icon name
                // 2: set window title
                cmdNum = Int(oscString[0]) - 0x30
                offset = 2
            }
            let setIcon = cmdNum == 0 || cmdNum == 1
            let setTitle = cmdNum == 0 || cmdNum == 2
            if setIcon || setTitle {
                fb.setTitleInitialized()
                let titleLength = min(oscString.count, 256)
                let newTitle = Array(oscString[offset..<titleLength])
                if setIcon { fb.setIconName(newTitle) }
                if setTitle { fb.setWindowTitle(newTitle) }
            }
        }
    }
}
