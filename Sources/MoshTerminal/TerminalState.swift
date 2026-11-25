// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::Complete` (src/statesync/completeterminal.{cc,h}):
// the complete terminal, a UTF-8 parser feeding actions to an emulator, plus the echo
// acknowledgement. A mosh client holds one of these per received state number (up to
// 1024) and builds a new one by applying the server's diff to a copy of the base state.
//
// How `Complete::apply_string( diff )` maps to this type
// ------------------------------------------------------
// `diff` is a serialized `HostBuffers::HostMessage` (decoded elsewhere: this module does
// not know protobuf). Its instructions are applied in order. For each instruction mosh
// tests the extensions in this order and takes the first that is present:
//
//   1. `hostbytes` (field 4, `hoststring`)  ->  `state.act(hoststring)`
//        The bytes go through the parser and the emulator. The returned reply
//        (`terminal_to_host`) is discarded: "server never interrogates client terminal".
//        mosh asserts that it is empty; `act` returns it so that the caller can check.
//   2. `resize` (field 5, `width`, `height`) ->  `state.resize(width:height:)`
//        mosh's `Parser::Resize` action. Not a parser input: an escape sequence cut in
//        two by a resize continues afterwards. The reply is discarded here too.
//   3. `echoack` (field 6, `echo_ack_num`)   ->  `state.applyEchoAck(echo_ack_num)`
//        Stores the number. mosh asserts that it does not go backwards.
//
// An instruction with none of the three does nothing. The server writes at most one
// echo ack, then at most one resize, then at most one hostbytes per diff
// (`Complete::diff_from`), but `apply_string` accepts any sequence.
//
// The caller copies the base state first (`var next = base`); copies are cheap, rows are
// shared until written. The diff's bytes rely on the base state's hidden state: its pen,
// its cursor and wrap flag, its scrolling region, and the parser itself.

/// mosh `Terminal::Complete`.
///
/// Synthesized `==` is structural equality over every stored field (cell contents
/// byte-wise; row identity and generation numbers ignored, see `Framebuffer`).
/// `moshEquals` is mosh's `operator==`.
public struct TerminalState: Equatable, Sendable {
    /// Late-ack delay of `setEchoAck(now:)`, in milliseconds (mosh `ECHO_TIMEOUT`).
    public static let echoTimeout: UInt64 = 50

    /// mosh `input_history` entry: a user-input frame number and when it arrived.
    public struct InputFrame: Equatable, Sendable {
        public var frameNum: UInt64
        public var timestamp: UInt64

        public init(frameNum: UInt64, timestamp: UInt64) {
            self.frameNum = frameNum
            self.timestamp = timestamp
        }
    }

    public internal(set) var parser: UTF8Parser
    public internal(set) var terminal: Emulator
    /// Server side only (which user input the screen already reflects is decided
    /// there). Always empty in a client's copy of a remote state.
    public internal(set) var inputHistory: [InputFrame]
    public internal(set) var echoAck: UInt64

    /// mosh `Complete( width, height )`.
    public init(width: Int, height: Int) {
        parser = UTF8Parser()
        terminal = Emulator(width: width, height: height)
        inputHistory = []
        echoAck = 0
    }

    /// Rebuild from field values (serialization).
    public init(parser: UTF8Parser, terminal: Emulator, inputHistory: [InputFrame] = [], echoAck: UInt64) {
        self.parser = parser
        self.terminal = terminal
        self.inputHistory = inputHistory
        self.echoAck = echoAck
    }

    /// The screen (mosh `get_fb`).
    public var framebuffer: Framebuffer { return terminal.fb }

    // MARK: Applying a diff

    /// mosh `Complete::act( const string & )`: feed host bytes to the terminal.
    /// Returns the terminal's reply to the host and empties it (mosh
    /// `read_octets_to_host`); a client drops the result.
    @discardableResult
    public mutating func act<S: Sequence>(_ bytes: S) -> [UInt8] where S.Element == UInt8 {
        for byte in bytes {
            // parse octet into up to three actions per character
            let decoded = parser.decode(byte)
            if decoded.count > 0 { input(decoded.first) }
            if decoded.count > 1 { input(decoded.second) }
        }
        return terminal.readOctetsToHost()
    }

    /// One wide character through the state machine, its actions applied at once.
    private mutating func input(_ ch: UInt32) {
        let step = parser.parser.step(ch)
        if step.exit != .ignore { terminal.act(step.exit, ch: ParserAction.noChar) }
        if step.action != .ignore { terminal.act(step.action, ch: ch) }
        if step.enter != .ignore { terminal.act(step.enter, ch: ParserAction.noChar) }
    }

    /// mosh `Complete::act( Resize( width, height ) )`. Returns the pending reply like
    /// `act` (normally empty).
    ///
    /// mosh aborts on a size that is not positive (an assertion). This port ignores such
    /// a resize instead: the state is left unchanged.
    @discardableResult
    public mutating func resize(width: Int, height: Int) -> [UInt8] {
        if width > 0 && height > 0 {
            terminal.resize(width: width, height: height)
        }
        return terminal.readOctetsToHost()
    }

    /// The `echoack` branch of `Complete::apply_string`: record the server's echo
    /// acknowledgement. mosh asserts `n >= echoAck`; this port stores the value as given.
    public mutating func applyEchoAck(_ n: UInt64) {
        echoAck = n
    }

    /// mosh `Complete::act( UserByte( c ) )`: a user keystroke, as the *server* applies
    /// it. Returns the bytes to write to the host. A client does not call this on
    /// remote states.
    @discardableResult
    public mutating func actUserByte(_ c: UInt8) -> [UInt8] {
        terminal.actUserByte(c)
        return terminal.readOctetsToHost()
    }

    /// mosh `Complete::reset_input`: parser back to Ground, incomplete UTF-8 dropped.
    public mutating func resetInput() {
        parser.resetInput()
    }

    // MARK: Server-side echo acknowledgement (not used by a client)

    /// mosh `Complete::set_echo_ack( now )`. Returns true if the echo ack changed.
    public mutating func setEchoAck(now: UInt64) -> Bool {
        var newestEchoAck: UInt64 = 0

        for i in inputHistory {
            // unsigned arithmetic as in mosh: `now - ECHO_TIMEOUT` wraps below 50
            if i.timestamp <= now &- TerminalState.echoTimeout {
                newestEchoAck = i.frameNum
            }
        }

        inputHistory.removeAll { $0.frameNum < newestEchoAck }

        let ret = echoAck != newestEchoAck
        echoAck = newestEchoAck
        return ret
    }

    /// mosh `Complete::register_input_frame`.
    public mutating func registerInputFrame(_ n: UInt64, now: UInt64) {
        inputHistory.append(InputFrame(frameNum: n, timestamp: now))
    }

    /// mosh `Complete::wait_time( now )`: milliseconds until the next echo ack is due,
    /// `Int32.max` (mosh `INT_MAX`) if nothing is pending.
    public func waitTime(now: UInt64) -> Int {
        if inputHistory.count < 2 {
            return Int(Int32.max)
        }

        let nextEchoAckTime = inputHistory[1].timestamp &+ TerminalState.echoTimeout
        if nextEchoAckTime <= now {
            return 0
        }
        return Int(truncatingIfNeeded: Int32(truncatingIfNeeded: nextEchoAckTime &- now))
    }

    // MARK: Comparison

    /// mosh `Complete::operator==`: `terminal == x.terminal && echo_ack == x.echo_ack`,
    /// where the terminals are compared by `Framebuffer.moshEquals` (row identity).
    /// The parser, the dispatcher and the user-input state are not compared.
    public func moshEquals(_ x: TerminalState) -> Bool {
        return terminal.moshEquals(x.terminal) && echoAck == x.echoAck
    }

    /// mosh `Complete::compare`: true if the screens differ in size, in any cell
    /// (`Cell.compare`) or in the cursor position. mosh also prints the differences.
    public func compare(_ other: TerminalState) -> Bool {
        var ret = false
        let fb = terminal.fb
        let otherFb = other.terminal.fb

        if fb.ds.height != otherFb.ds.height || fb.ds.width != otherFb.ds.width {
            return true
        }

        for y in 0..<fb.ds.height {
            for x in 0..<fb.ds.width {
                if fb.rows[y].cells[x].compare(otherFb.rows[y].cells[x]) {
                    ret = true
                }
            }
        }

        if fb.ds.cursorRow != otherFb.ds.cursorRow || fb.ds.cursorCol != otherFb.ds.cursorCol {
            ret = true
        }
        // XXX should compare other terminal state too (mouse mode, bell. etc.)

        return ret
    }
}
