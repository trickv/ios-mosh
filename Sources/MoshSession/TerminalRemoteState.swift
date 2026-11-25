// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import MoshTerminal
import MoshTransport
import MoshWire

/// The glue between the transport and the terminal model: a remote state that is a mosh
/// `Terminal::Complete`. `MoshTransport` and `MoshTerminal` do not know each other; this type
/// is the only place where a `HostMessage` meets a `TerminalState`.
///
/// Port of `Complete::apply_string` (mosh 1.4.0 src/statesync/completeterminal.cc:104-122):
///
///     HostBuffers::HostMessage input;
///     fatal_assert( input.ParseFromString( diff ) );
///     for ( int i = 0; i < input.instruction_size(); i++ ) {
///       if ( input.instruction( i ).HasExtension( hostbytes ) ) {
///         string terminal_to_host = act( ...hoststring() );
///         assert( terminal_to_host.empty() ); /* server never interrogates client terminal */
///       } else if ( input.instruction( i ).HasExtension( resize ) ) {
///         act( Resize( ...width(), ...height() ) );
///       } else if ( input.instruction( i ).HasExtension( echoack ) ) {
///         assert( inst_echo_ack_num >= echo_ack );
///         echo_ack = inst_echo_ack_num;
///       }
///     }
///
/// The order of preference within one instruction (host bytes, then resize, then echo ack) is
/// applied by `HostMessage(serialized:)`, which drops an instruction with none of the three,
/// as the loop above does nothing for it.
///
/// Where mosh aborts, this port goes on (a client that aborts loses the session; a remote state
/// that follows the server keeps it):
/// - A diff that does not parse (`fatal_assert`): `apply(diff:)` throws, so the transport drops
///   the instruction and stores no state (`RemoteState` contract). Nothing is half-applied: the
///   message is decoded completely before anything is changed.
/// - A non-empty reply to host bytes (`assert`): discarded. `Display::new_frame` never writes a
///   query, so a correct server never causes one. Counted in `discardedReplyBytes` for tests.
/// - An echo ack that goes backwards (`assert`): stored as given, like `TerminalState`
///   (`applyEchoAck`). Counted in `echoAckRegressions`.
/// - A resize to a size that is not positive (`assert` in `Framebuffer`): ignored by
///   `TerminalState.resize`.
///
/// Value semantics: `TerminalState` is a value type whose rows are shared copy-on-write, so the
/// transport's "copy state `old_num`, apply the diff to the copy" is cheap and never changes the
/// base.
public struct TerminalRemoteState: RemoteState, Equatable {
    /// mosh-server's size when it cannot read one from its tty (mosh-server.cc:411-420).
    public static let defaultServerSize = TerminalSize(width: 80, height: 24)

    /// The terminal: screen, parser, echo ack.
    public private(set) var terminal: TerminalState
    /// Bytes the terminal answered to host bytes and that were dropped (mosh asserts there are
    /// none). Summed over the path from state 0 to this state.
    public private(set) var discardedReplyBytes: UInt64 = 0
    /// How often an echo ack lower than the one held arrived (mosh asserts it never does).
    public private(set) var echoAckRegressions: UInt64 = 0

    /// State 0 for a server that started at 80x24 (`RemoteState` needs a plain initializer).
    /// A session uses `init(serverStartSize:)` instead.
    public init() {
        self.init(serverStartSize: Self.defaultServerSize)
    }

    /// State 0: a blank terminal of the size the server's own terminal had when it started.
    ///
    /// It must be the server's size, because the server's first diff is built from its state 0
    /// (`Complete terminal( window_size.ws_col, window_size.ws_row )`, mosh-server.cc:423) and
    /// carries a resize only when the size changed (completeterminal.cc:83-88). mosh's client
    /// uses its own window size (`Terminal::Complete local_terminal( ws_col, ws_row )`,
    /// stmclient.cc:254), which is the same thing because its SSH pty had that size. Over SSH
    /// that is the pty size of the bootstrap; a server started without a tty uses 80x24.
    public init(serverStartSize: TerminalSize) {
        terminal = TerminalState(width: Int(serverStartSize.width), height: Int(serverStartSize.height))
    }

    /// Wraps a terminal state (a restored snapshot, a test). The two diagnostic counters are
    /// given when a stored state is read back, so that a snapshot loses nothing.
    public init(terminal: TerminalState, discardedReplyBytes: UInt64 = 0, echoAckRegressions: UInt64 = 0) {
        self.terminal = terminal
        self.discardedReplyBytes = discardedReplyBytes
        self.echoAckRegressions = echoAckRegressions
    }

    /// The screen.
    public var framebuffer: Framebuffer { terminal.framebuffer }

    /// The newest echo ack: every client state up to this number has been shown by the server's
    /// terminal (mosh `get_echo_ack`; the prediction engine's "late ack").
    public var echoAck: UInt64 { terminal.echoAck }

    /// The screen's size.
    public var size: TerminalSize {
        TerminalSize(width: framebuffer.ds.width, height: framebuffer.ds.height)
    }

    // MARK: RemoteState

    public mutating func apply(diff: [UInt8]) throws {
        apply(try HostMessage(serialized: diff))
    }

    /// Applies a decoded `HostMessage`, instruction by instruction, in order.
    public mutating func apply(_ message: HostMessage) {
        for instruction in message.instructions {
            switch instruction {
            case .hostBytes(let bytes):
                // `act` runs every byte through the parser (whose state continues from the base
                // state: a sequence may span diffs) and returns `read_octets_to_host`.
                let reply = terminal.act(bytes)
                discardedReplyBytes &+= UInt64(reply.count)
            case .resize(let width, let height):
                // mosh `act( Resize( w, h ) )`: `Emulator::resize`, not a parser input. The
                // reply (always empty) is dropped as in mosh, which ignores `act`'s result here.
                terminal.resize(width: Int(width), height: Int(height))
            case .echoAck(let number):
                if number < terminal.echoAck {
                    echoAckRegressions &+= 1
                }
                terminal.applyEchoAck(number)
            }
        }
    }

    // MARK: Equality

    /// Equal terminals; the diagnostic counters are not compared.
    public static func == (a: TerminalRemoteState, b: TerminalRemoteState) -> Bool {
        a.terminal == b.terminal
    }
}
