import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

/// A deterministic generator, so that a failing case can be repeated.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    static let id = SessionID(bytes: Array(0x10..<0x20))!
    static let otherID = SessionID(bytes: Array(0x40..<0x50))!
    static let key = try! Base64Key(bytes: Array(0xA0..<0xB0))

    static func meta(id: SessionID = Fixtures.id, port: UInt16 = 60001) -> SessionMeta {
        SessionMeta(id: id, createdAt: 1_794_000_000, hostName: "höst.example", address: "127.0.0.1", port: port,
                    user: "trick", remoteCommand: "tmux new -A -s main",
                    serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 4242, serverStartTime: 987_654_321)
    }

    /// A terminal that has seen some output.
    static func terminal(_ text: String, width: Int = 40, height: Int = 6) -> TerminalState {
        var state = TerminalState(width: width, height: height)
        _ = state.act(Array(text.utf8))
        return state
    }

    /// A snapshot with several held states that share rows, pending bytes and resizes, and a
    /// clipboard: every field has a value that is not its default.
    static func richSnapshot() -> SessionSnapshot {
        var terminal = Fixtures.terminal("one\r\ntwo \u{1B}[1;31mred\u{1B}[0m\r\n")
        var held: [NumberedRemoteState<TerminalRemoteState>] = []
        held.append(NumberedRemoteState(number: 7, state: TerminalRemoteState(terminal: terminal)))
        _ = terminal.act(Array("three wide \u{4E2D}\u{6587} e\u{301}\r\n\u{1B}]52;c;aGVsbG8=\u{07}".utf8))
        terminal.applyEchoAck(41)
        held.append(NumberedRemoteState(number: 9, state: TerminalRemoteState(terminal: terminal, discardedReplyBytes: 3,
                                                                              echoAckRegressions: 1)))
        _ = terminal.act(Array("four\r\nfive\r\nsix\r\nseven\r\n\u{1B}[".utf8))   // scrolls; ends inside a sequence
        held.append(NumberedRemoteState(number: 12, state: TerminalRemoteState(terminal: terminal)))
        terminal.resize(width: 30, height: 5)
        held.append(NumberedRemoteState(number: 1 << 40, state: TerminalRemoteState(terminal: terminal)))
        let pending: [UserEvent] = Array("ls -l".utf8).map(UserEvent.byte)
            + [.resize(TerminalSize(width: 30, height: 5)), .resize(TerminalSize(width: 31, height: 5)), .byte(0), .byte(255)]
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 1030,
            pendingInput: pending,
            remoteStates: held,
            highestAckSent: 12,
            terminalSize: TerminalSize(width: 31, height: 5),
            usedCounters: GateCounters(sequence: 70_000, state: 1_040, fragmentID: 2_000),
            receiverExpectedSequence: 5_555)
        let clipboard = ClipboardPolicy(isEnabled: false, lastSeen: Array("aGVsbG8=".unicodeScalars.map(\.value)),
                                        lastWrittenHash: 0xDEAD_BEEF_0BAD_F00D)
        return SessionSnapshot(transport: transport, clipboard: clipboard)
    }

    /// The smallest snapshot: a session that never sent or received anything.
    static func minimalSnapshot() -> SessionSnapshot {
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 0,
            pendingInput: [],
            remoteStates: [NumberedRemoteState(number: 0, state: TerminalRemoteState())],
            highestAckSent: 0,
            terminalSize: nil,
            usedCounters: GateCounters(sequence: 0, state: 1, fragmentID: 0),
            receiverExpectedSequence: 0)
        return SessionSnapshot(transport: transport, clipboard: ClipboardPolicy())
    }
}

/// Replaces the CRC at the end of a framed part, so that a test reaches the checks behind it.
func withFixedChecksum(_ bytes: [UInt8]) -> [UInt8] {
    var fixed = Array(bytes.dropLast(4))
    let crc = CRC32.checksum(fixed)
    for shift in stride(from: 0, to: 32, by: 8) {
        fixed.append(UInt8(truncatingIfNeeded: crc >> UInt32(shift)))
    }
    return fixed
}

extension XCTestCase {
    /// A scratch directory removed when the test ends.
    func scratchRoot(_ label: String = "resume") throws -> String {
        let scratch = try ScratchDirectory(label: label)
        addTeardownBlock { scratch.remove() }
        return scratch.path + "/sessions"
    }
}
