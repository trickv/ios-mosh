// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Port of mosh 1.4.0 `Terminal::UserInput` (src/terminal/terminaluserinput.{cc,h}).

/// Translates the user's cursor keys. mosh applies user bytes to the *server's*
/// terminal; a client never feeds them to its copies of the remote state, so this
/// stays in `ground` there. It is part of `Emulator` for completeness.
///
/// "The user will always be in application mode. If stm is not in application mode,
/// convert user's cursor control function to an ANSI cursor control sequence."
public struct UserInput: Equatable, Sendable {
    public enum State: UInt8, Sendable {
        case ground, esc, ss3

        /// mosh's enumerator name.
        public var name: String {
            switch self {
            case .ground: return "Ground"
            case .esc: return "ESC"
            case .ss3: return "SS3"
            }
        }
    }

    public internal(set) var state: State = .ground

    public init() {}

    /// Rebuild from field values (serialization).
    public init(state: State) {
        self.state = state
    }

    /// mosh `UserInput::input`: the bytes to send to the host for one user byte.
    public mutating func input(_ c: UInt8, applicationModeCursorKeys: Bool) -> [UInt8] {
        // We need to look ahead one byte in the SS3 state to see if
        // the next byte will be A, B, C, or D (cursor control keys).
        switch state {
        case .ground:
            if c == 0x1B { // ESC
                state = .esc
            }
            return [c]

        case .esc:
            if c == UInt8(ascii: "O") { // ESC O = 7-bit SS3
                state = .ss3
                return []
            }
            state = .ground
            return [c]

        case .ss3:
            state = .ground
            if !applicationModeCursorKeys && c >= UInt8(ascii: "A") && c <= UInt8(ascii: "D") {
                return [UInt8(ascii: "["), c]
            } else {
                return [UInt8(ascii: "O"), c]
            }
        }
    }
}
