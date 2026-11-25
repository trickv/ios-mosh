import MoshSession
import MoshTerminal
import MoshTestSupport
import MoshTransport
import XCTest
@testable import MoshResume

final class SnapshotCodecTests: XCTestCase {
    private func roundTrip(_ snapshot: SessionSnapshot, id: UInt64 = 0x0123_4567_89AB_CDEF,
                           file: StaticString = #filePath, line: UInt = #line) throws -> StoredSnapshot {
        let stored = StoredSnapshot(id: id, snapshot: snapshot)
        let bytes = SnapshotCodec.encode(stored, sessionID: Fixtures.id)
        let decoded = try SnapshotCodec.decode(bytes, expecting: Fixtures.id)
        XCTAssertEqual(decoded, stored, file: file, line: line)
        XCTAssertEqual(SnapshotCodec.encode(decoded, sessionID: Fixtures.id), bytes, "the encoding is stable", file: file, line: line)
        return decoded
    }

    func testMinimalSnapshotRoundTrip() throws {
        _ = try roundTrip(Fixtures.minimalSnapshot(), id: 1)
        _ = try roundTrip(Fixtures.minimalSnapshot(), id: .max)
    }

    /// Every field, with a value that is not its default, comes back, including the two fields
    /// the transport review added and the diagnostic counters `==` does not look at.
    func testRichSnapshotRoundTripFieldByField() throws {
        let original = Fixtures.richSnapshot()
        let decoded = try roundTrip(original).snapshot
        let a = original.transport
        let b = decoded.transport
        XCTAssertEqual(b.acknowledgedStateNumber, 1030)
        XCTAssertEqual(b.pendingInput, a.pendingInput)
        XCTAssertEqual(b.pendingInput.count, 9)
        XCTAssertEqual(b.highestAckSent, 12)
        XCTAssertEqual(b.terminalSize, TerminalSize(width: 31, height: 5))
        XCTAssertEqual(b.usedCounters, GateCounters(sequence: 70_000, state: 1_040, fragmentID: 2_000))
        XCTAssertEqual(b.receiverExpectedSequence, 5_555)
        XCTAssertEqual(b.remoteStates.map(\.number), [7, 9, 12, 1 << 40])
        for (mine, theirs) in zip(b.remoteStates, a.remoteStates) {
            XCTAssertEqual(mine.state.terminal, theirs.state.terminal)
            XCTAssertEqual(mine.state.terminal.serialized(), theirs.state.terminal.serialized(), "byte for byte, generations included")
            XCTAssertEqual(mine.state.discardedReplyBytes, theirs.state.discardedReplyBytes)
            XCTAssertEqual(mine.state.echoAckRegressions, theirs.state.echoAckRegressions)
        }
        XCTAssertEqual(b.remoteStates[1].state.discardedReplyBytes, 3)
        XCTAssertEqual(b.remoteStates[1].state.echoAckRegressions, 1)
        XCTAssertEqual(b.remoteStates[1].state.echoAck, 41)
        XCTAssertEqual(b.remoteStates[3].state.size, TerminalSize(width: 30, height: 5))
        XCTAssertEqual(decoded.clipboard.isEnabled, false)
        XCTAssertEqual(decoded.clipboard.lastSeen, original.clipboard.lastSeen)
        XCTAssertEqual(decoded.clipboard.lastWrittenHash, 0xDEAD_BEEF_0BAD_F00D)
        XCTAssertFalse(b.remoteStates[1].state.framebuffer.clipboard.isEmpty, "the OSC 52 field is in the state")

        // A state reloaded in the middle of an escape sequence continues where it stopped.
        var continued = b.remoteStates[2].state.terminal
        var reference = a.remoteStates[2].state.terminal
        _ = continued.act(Array("7mX\u{1B}[0m".utf8))
        _ = reference.act(Array("7mX\u{1B}[0m".utf8))
        XCTAssertEqual(continued, reference)
    }

    func testOptionalFieldsInEveryCombination() throws {
        for size in [nil, TerminalSize(width: 1, height: 1), TerminalSize(width: 65535, height: 65535)] {
            for enabled in [true, false] {
                for seen: [UInt32]? in [nil, [], [0x41, 0x10FFFF]] {
                    for hash: UInt64? in [nil, 0, .max] {
                        var snapshot = Fixtures.minimalSnapshot()
                        snapshot.transport.terminalSize = size
                        snapshot.clipboard = ClipboardPolicy(isEnabled: enabled, lastSeen: seen, lastWrittenHash: hash)
                        let decoded = try roundTrip(snapshot).snapshot
                        XCTAssertEqual(decoded.clipboard.lastSeen, seen)
                        XCTAssertEqual(decoded.clipboard.lastWrittenHash, hash)
                    }
                }
            }
        }
    }

    func testPendingInputShapes() throws {
        let r = UserEvent.resize(TerminalSize(width: 100, height: 30))
        let shapes: [[UserEvent]] = [
            [], [.byte(0)], [r], [r, r], [.byte(1), r], [r, .byte(1)], [.byte(1), .byte(2), r, .byte(3), r, r, .byte(4)],
            (0..<70_000).map { .byte(UInt8(truncatingIfNeeded: $0)) },
        ]
        for shape in shapes {
            var snapshot = Fixtures.minimalSnapshot()
            snapshot.transport.pendingInput = shape
            XCTAssertEqual(try roundTrip(snapshot).snapshot.transport.pendingInput, shape)
        }
    }

    func testExtremeNumbers() throws {
        var snapshot = Fixtures.minimalSnapshot()
        snapshot.transport.acknowledgedStateNumber = .max - 2
        snapshot.transport.usedCounters = GateCounters(sequence: 1 << 63, state: .max, fragmentID: .max)
        snapshot.transport.receiverExpectedSequence = .max
        snapshot.transport.remoteStates = [NumberedRemoteState(number: .max - 1, state: TerminalRemoteState())]
        snapshot.transport.highestAckSent = .max - 1
        _ = try roundTrip(snapshot)
    }

    /// Lines that share a row object, inside a state and between states, still do after a
    /// reload, and lines that did not, do not. The file holds each row once.
    func testRowSharingIsKept() throws {
        let original = Fixtures.richSnapshot()
        let decoded = try roundTrip(original).snapshot
        func identities(_ snapshot: SessionSnapshot) -> [[ObjectIdentifier]] {
            snapshot.transport.remoteStates.map { $0.state.framebuffer.rows.map { ObjectIdentifier($0) } }
        }
        /// The sharing pattern: each row object named by the order of its first appearance.
        func pattern(_ ids: [[ObjectIdentifier]]) -> [[Int]] {
            var names: [ObjectIdentifier: Int] = [:]
            return ids.map { $0.map { id in
                if let name = names[id] { return name }
                names[id] = names.count
                return names.count - 1
            } }
        }
        let before = pattern(identities(original))
        let after = pattern(identities(decoded))
        XCTAssertEqual(after, before)
        let distinct = Set(before.joined()).count
        let lines = before.joined().count
        XCTAssertLessThan(distinct, lines, "the fixture shares rows between its states")
    }

    func testAnotherSessionsSnapshotIsRefused() {
        let bytes = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: Fixtures.richSnapshot()), sessionID: Fixtures.id)
        XCTAssertThrowsError(try SnapshotCodec.decode(bytes, expecting: Fixtures.otherID)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.snapshot, .wrongSession))
        }
    }

    /// Snapshots the import would refuse or, worse, accept wrongly are refused by the decoder.
    func testInconsistentSnapshotsAreRefused() {
        func refused(_ what: String, _ change: (inout SessionSnapshot) -> Void, line: UInt = #line) {
            var snapshot = Fixtures.richSnapshot()
            change(&snapshot)
            let bytes = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: snapshot), sessionID: Fixtures.id)
            XCTAssertThrowsError(try SnapshotCodec.decode(bytes, expecting: Fixtures.id), what, line: line) {
                guard let error = $0 as? RecordFormatError, case .invalid = error.reason else {
                    XCTFail("\(what): \($0)", line: line); return
                }
            }
        }
        refused("no remote state") { $0.transport.remoteStates = [] }
        refused("state numbers not ascending") { $0.transport.remoteStates.swapAt(0, 1) }
        refused("a state number twice") { $0.transport.remoteStates[1].number = 7 }
        refused("state number 2^64 - 1") { $0.transport.remoteStates[3].number = .max }
        refused("the acknowledged remote state is not held") { $0.transport.highestAckSent = 8 }
        refused("used state counter not above A") { $0.transport.usedCounters.state = 1030 }
        refused("used sequence counter beyond 63 bits") { $0.transport.usedCounters.sequence = (1 << 63) + 1 }
    }

    /// The shape checks behind the checksum, on a file with a valid frame.
    func testStrictChecksBehindTheChecksum() throws {
        let stored = StoredSnapshot(id: 5, snapshot: Fixtures.richSnapshot())
        let good = SnapshotCodec.encode(stored, sessionID: Fixtures.id)
        func mutated(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
            var bytes = good
            change(&bytes)
            return withFixedChecksum(bytes)
        }
        // Body offsets + 12: id 12, snapshot id 28, terminal version 36, flags 37, reserved 38,
        // A 40, highest ack 48, used 56/64/72, expected 80, size 88/90, hash 92, lastSeen count 100.
        XCTAssertNoThrow(try SnapshotCodec.decode(mutated { _ in }, expecting: Fixtures.id))
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { for i in 28..<36 { $0[i] = 0 } }, expecting: Fixtures.id), "snapshot id 0")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[36] = 2 }, expecting: Fixtures.id), "terminal version")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[37] |= 0x10 }, expecting: Fixtures.id), "unknown flag")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[38] = 1 }, expecting: Fixtures.id), "reserved")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[37] &= ~1 }, expecting: Fixtures.id), "size without flag")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[88] = 0; $0[89] = 0 }, expecting: Fixtures.id), "width 0")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[37] &= ~8 }, expecting: Fixtures.id), "hash without flag")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[37] &= ~4 }, expecting: Fixtures.id), "text without flag")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[4] = 9 }, expecting: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.snapshot, .unsupportedVersion(9)))
        }
        // The pending input of the fixture starts after the 8 code points of lastSeen:
        // count at 136, then item 0x00 with run length 5.
        let input = 104 + 4 * 8
        XCTAssertEqual(Array(good[input..<(input + 9)]), [9, 0, 0, 0, 0, 5, 0, 0, 0])
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[input] = 8 }, expecting: Fixtures.id), "fewer events announced than stored")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[input + 4] = 2 }, expecting: Fixtures.id), "unknown item")
        XCTAssertThrowsError(try SnapshotCodec.decode(mutated { $0[input + 5] = 0 }, expecting: Fixtures.id), "empty run")

        // Two byte runs in a row say the same as one: only one of the two forms is read.
        var split = Fixtures.minimalSnapshot()
        split.transport.pendingInput = [.byte(1), .byte(2)]
        let joined = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: split), sessionID: Fixtures.id)
        // Its input: count 2, 0x00, length 2, 1, 2. Rewrite as 0x00 len 1 [1], 0x00 len 1 [2].
        let at = 104
        XCTAssertEqual(Array(joined[at..<(at + 11)]), [2, 0, 0, 0, 0, 2, 0, 0, 0, 1, 2])
        var body = Array(joined[12..<(joined.count - 4)])
        body.replaceSubrange((at - 12 + 4)..<(at - 12 + 11), with: [0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 2])
        let twoRuns = PartFrame.wrap(magic: Array("MRs1".utf8), version: 1, body: body)
        XCTAssertThrowsError(try SnapshotCodec.decode(twoRuns, expecting: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.snapshot, .invalid("two byte runs in a row")))
        }
    }

    /// Every byte of the file damaged: refused (this is the checksum's work).
    func testEveryDamagedByteIsRejected() throws {
        let bytes = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: Fixtures.richSnapshot()), sessionID: Fixtures.id)
        XCTAssertGreaterThan(bytes.count, 400)
        for index in bytes.indices {
            for value in [bytes[index] ^ 0x01, bytes[index] ^ 0x80, bytes[index] ^ 0xFF] {
                var damaged = bytes
                damaged[index] = value
                XCTAssertThrowsError(try SnapshotCodec.decode(damaged, expecting: Fixtures.id), "byte \(index) = \(value)")
            }
        }
    }

    func testEveryTruncationIsRejected() throws {
        let bytes = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: Fixtures.richSnapshot()), sessionID: Fixtures.id)
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try SnapshotCodec.decode(Array(bytes[0..<length]), expecting: Fixtures.id), "cut at \(length)")
        }
        XCTAssertThrowsError(try SnapshotCodec.decode(bytes + [0], expecting: Fixtures.id))
        // Cut inside the body with the frame made consistent again: the body's own checks.
        let body = Array(bytes[12..<(bytes.count - 4)])
        for length in 0..<body.count {
            let framed = PartFrame.wrap(magic: Array("MRs1".utf8), version: 1, body: Array(body[0..<length]))
            XCTAssertThrowsError(try SnapshotCodec.decode(framed, expecting: Fixtures.id), "body cut at \(length)")
        }
        XCTAssertThrowsError(try SnapshotCodec.decode(PartFrame.wrap(magic: Array("MRs1".utf8), version: 1, body: body + [0]),
                                                      expecting: Fixtures.id))
    }

    /// Damage that a checksum would not catch (the checksum is recomputed): the decoder throws or
    /// returns a snapshot, and never traps or hangs. A snapshot it does return encodes again.
    func testDamageBehindTheChecksumNeverTraps() throws {
        let bytes = SnapshotCodec.encode(StoredSnapshot(id: 5, snapshot: Fixtures.richSnapshot()), sessionID: Fixtures.id)
        var generator = SplitMix64(seed: 0x5EED)
        var accepted = 0
        var refused = 0
        func attempt(_ damaged: [UInt8]) {
            do {
                let decoded = try SnapshotCodec.decode(withFixedChecksum(damaged), expecting: Fixtures.id)
                _ = SnapshotCodec.encode(decoded, sessionID: Fixtures.id)
                accepted += 1
            } catch is RecordFormatError {
                refused += 1
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
        for index in 12..<(bytes.count - 4) {
            for value in [bytes[index] ^ 0x01, bytes[index] ^ 0x80, 0x00, 0xFF] where value != bytes[index] {
                var damaged = bytes
                damaged[index] = value
                attempt(damaged)
            }
        }
        for _ in 0..<3000 {
            var damaged = bytes
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                damaged[Int.random(in: 12..<(bytes.count - 4), using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            attempt(damaged)
        }
        XCTAssertGreaterThan(refused, 0)
        XCTAssertGreaterThan(accepted, 0, "a changed cell is still a snapshot")
    }

    /// The plan's test (Verification, "From M6"): the corpus run with every held state saved and
    /// reloaded between every pair of diffs ends in the same states as the run that never left
    /// memory (which `TerminalRemoteStateTests` compares with mosh's own emulator).
    func testCorpusRunWithAReloadBetweenEveryPairOfDiffs() throws {
        let cases = try GoldenCorpus.loadAll()
        XCTAssertGreaterThanOrEqual(cases.count, 38)
        var reloads = 0
        for c in cases {
            let start = TerminalRemoteState(serverStartSize: TerminalSize(width: c.width, height: c.height))
            var reference: [UInt64: TerminalRemoteState] = [0: start]
            var reloaded: [UInt64: TerminalRemoteState] = [0: start]
            for (i, instruction) in c.instructions.enumerated() {
                let what = "\(c.name) instruction \(i + 1)"
                guard var a = reference[instruction.oldNum], var b = reloaded[instruction.oldNum] else {
                    XCTFail("\(what): base state missing"); return
                }
                if !instruction.diff.isEmpty {
                    try a.apply(diff: instruction.diff)
                    try b.apply(diff: instruction.diff)
                }
                reference[instruction.newNum] = a
                reloaded[instruction.newNum] = b

                // Store what a receiver would hold (the newest few states) and read it back.
                let held = reloaded.keys.sorted().suffix(6)
                var snapshot = Fixtures.minimalSnapshot()
                snapshot.transport.remoteStates = held.map { NumberedRemoteState(number: $0, state: reloaded[$0]!) }
                snapshot.transport.highestAckSent = held.last!
                let bytes = SnapshotCodec.encode(StoredSnapshot(id: 1, snapshot: snapshot), sessionID: Fixtures.id)
                let decoded = try SnapshotCodec.decode(bytes, expecting: Fixtures.id).snapshot
                for state in decoded.transport.remoteStates {
                    guard state.state.terminal == reference[state.number]?.terminal else {
                        XCTFail("\(what): state \(state.number) differs after a reload"); return
                    }
                    reloaded[state.number] = state.state
                }
                reloads += 1
            }
        }
        XCTAssertGreaterThan(reloads, 2000)
    }
}
