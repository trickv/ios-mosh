import MoshSession
import MoshTerminal
import MoshTransport

/// A snapshot as it is stored: the session's exported state and the id that the clean mark in
/// `counters` must name for it to be used.
public struct StoredSnapshot: Equatable, Sendable {
    /// Not 0. Chosen at random for every snapshot that is written.
    public var id: UInt64
    public var snapshot: SessionSnapshot

    public init(id: UInt64, snapshot: SessionSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}

/// The byte format of the `snapshot` part (docs/RESUME.md has the same description).
///
/// Inside the frame of `PartFrame`, magic "MRs1", version 1, all integers little-endian:
///
///     16 bytes  session id
///     u64       snapshot id (not 0)
///     u8        version of the terminal serialization (`TerminalSerialization.version`)
///     u8        flags: bit 0 a terminal size follows (`terminalSize` is not nil),
///                      bit 1 clipboard writing is enabled, bit 2 `lastSeen` is present,
///                      bit 3 `lastWrittenHash` is present; bits 4-7 are 0
///     u16       0
///     u64       acknowledgedStateNumber (A)
///     u64       highestAckSent
///     u64 * 3   usedCounters: sequence, state, fragment id
///     u64       receiverExpectedSequence
///     u16 * 2   terminalSize width, height (0, 0 without bit 0)
///     u64       clipboard lastWrittenHash (0 without bit 3)
///     u32 n, n * u32                      clipboard lastSeen (n = 0 without bit 2)
///     u32 e     number of pending input events, then items until e events are read:
///                 0x00, u32 k (>= 1), k bytes    k byte events
///                 0x01, u16 width, u16 height    a resize event
///               (two 0x00 items never follow each other: the encoding of a list is unique)
///     u32 r     number of distinct rows, then r * (u32 length, the bytes of `Row.serialized()`)
///     u32 s     number of held remote states (>= 1), ascending by number, each:
///                 u64      state number
///                 u64      discardedReplyBytes
///                 u64      echoAckRegressions
///                 u32 length, the bytes of `TerminalState.serializedWithoutRows()`
///                 u32 h, h * u32   the row of each line, as an index into the row table
///
/// Rows are stored once and shared: the states the receiver holds differ in a few lines, and
/// which lines share a row object is part of the terminal state (the display diff's scroll
/// shortcut uses it). Row indices are given in order of first use, so a row table has one
/// encoding and no unused row.
///
/// Decoding is strict. Beyond the shape it checks what `TransportCore(restoring:)` relies on: the
/// state numbers ascend, none is 2^64 - 1, the state `highestAckSent` is held, the used state
/// counter is above `A`, the used sequence counter is at most 2^63.
public enum SnapshotCodec {
    static let magic = Array("MRs1".utf8)
    public static let formatVersion: UInt16 = 1
    /// A resume needs a few kilobytes. A file above this is not read at all.
    public static let maxFileSize = 256 << 20

    public static func encode(_ stored: StoredSnapshot, sessionID: SessionID) -> [UInt8] {
        precondition(stored.id != 0, "snapshot id 0 means no snapshot")
        let transport = stored.snapshot.transport
        let clipboard = stored.snapshot.clipboard
        var body = RecordWriter()
        body.raw(sessionID.bytes)
        body.u64(stored.id)
        body.u8(TerminalSerialization.version)
        var flags: UInt8 = 0
        if transport.terminalSize != nil { flags |= 1 }
        if clipboard.isEnabled { flags |= 2 }
        if clipboard.lastSeen != nil { flags |= 4 }
        if clipboard.lastWrittenHash != nil { flags |= 8 }
        body.u8(flags)
        body.u16(0)
        body.u64(transport.acknowledgedStateNumber)
        body.u64(transport.highestAckSent)
        body.u64(transport.usedCounters.sequence)
        body.u64(transport.usedCounters.state)
        body.u64(transport.usedCounters.fragmentID)
        body.u64(transport.receiverExpectedSequence)
        body.u16(transport.terminalSize?.width ?? 0)
        body.u16(transport.terminalSize?.height ?? 0)
        body.u64(clipboard.lastWrittenHash ?? 0)
        let lastSeen = clipboard.lastSeen ?? []
        body.u32(UInt32(lastSeen.count))
        for point in lastSeen { body.u32(point) }

        // Pending input: runs of bytes, and resizes.
        body.u32(UInt32(transport.pendingInput.count))
        var run: [UInt8] = []
        func flush(_ run: inout [UInt8], into body: inout RecordWriter) {
            guard !run.isEmpty else { return }
            body.u8(0)
            body.block(run)
            run.removeAll(keepingCapacity: true)
        }
        for event in transport.pendingInput {
            switch event {
            case .byte(let byte):
                run.append(byte)
            case .resize(let size):
                flush(&run, into: &body)
                body.u8(1)
                body.u16(size.width)
                body.u16(size.height)
            }
        }
        flush(&run, into: &body)

        // Rows, each distinct row object once, in order of first use.
        var rowIndex: [ObjectIdentifier: UInt32] = [:]
        var rowTable = RecordWriter()
        var states = RecordWriter()
        for held in transport.remoteStates {
            states.u64(held.number)
            states.u64(held.state.discardedReplyBytes)
            states.u64(held.state.echoAckRegressions)
            states.block(held.state.terminal.serializedWithoutRows())
            let rows = held.state.terminal.framebuffer.rows
            states.u32(UInt32(rows.count))
            for row in rows {
                let key = ObjectIdentifier(row)
                if let index = rowIndex[key] {
                    states.u32(index)
                } else {
                    let index = UInt32(rowIndex.count)
                    rowIndex[key] = index
                    rowTable.block(row.serialized())
                    states.u32(index)
                }
            }
        }
        body.u32(UInt32(rowIndex.count))
        body.raw(rowTable.bytes)
        body.u32(UInt32(transport.remoteStates.count))
        body.raw(states.bytes)
        return PartFrame.wrap(magic: magic, version: formatVersion, body: body.bytes)
    }

    /// - Throws: `RecordFormatError` with part `.snapshot`.
    public static func decode(_ bytes: [UInt8], expecting expected: SessionID) throws -> StoredSnapshot {
        let body = try PartFrame.unwrap(bytes, part: .snapshot, magic: magic, version: formatVersion)
        var reader = RecordReader(body, part: .snapshot)
        guard try reader.raw(SessionID.length) == expected.bytes else { throw reader.fail(.wrongSession) }
        let id = try reader.u64()
        guard id != 0 else { throw reader.invalid("snapshot id 0") }
        let terminalVersion = try reader.u8()
        guard terminalVersion == TerminalSerialization.version else {
            throw reader.invalid("terminal serialization version \(terminalVersion)")
        }
        let flags = try reader.u8()
        guard flags & 0xF0 == 0 else { throw reader.invalid("unknown flags \(flags)") }
        guard try reader.u16() == 0 else { throw reader.invalid("reserved field is not 0") }
        let acknowledged = try reader.u64()
        let highestAckSent = try reader.u64()
        let used = GateCounters(sequence: try reader.u64(), state: try reader.u64(), fragmentID: try reader.u64())
        let receiverExpectedSequence = try reader.u64()
        let width = try reader.u16()
        let height = try reader.u16()
        let terminalSize: TerminalSize?
        if flags & 1 != 0 {
            guard width >= 1, height >= 1 else { throw reader.invalid("terminal size \(width)x\(height)") }
            terminalSize = TerminalSize(width: width, height: height)
        } else {
            guard width == 0, height == 0 else { throw reader.invalid("a terminal size without its flag") }
            terminalSize = nil
        }
        let hash = try reader.u64()
        guard flags & 8 != 0 || hash == 0 else { throw reader.invalid("a clipboard hash without its flag") }
        let seenCount = try reader.count(minimumSize: 4)
        guard flags & 4 != 0 || seenCount == 0 else { throw reader.invalid("a clipboard text without its flag") }
        var lastSeen: [UInt32] = []
        lastSeen.reserveCapacity(seenCount)
        for _ in 0..<seenCount { lastSeen.append(try reader.u32()) }

        let eventCount = Int(try reader.u32())
        guard eventCount <= reader.remaining else { throw reader.fail(.truncated) }
        var pending: [UserEvent] = []
        pending.reserveCapacity(eventCount)
        var lastWasRun = false
        while pending.count < eventCount {
            switch try reader.u8() {
            case 0:
                guard !lastWasRun else { throw reader.invalid("two byte runs in a row") }
                let run = try reader.block()
                guard !run.isEmpty else { throw reader.invalid("an empty byte run") }
                guard run.count <= eventCount - pending.count else { throw reader.invalid("more input than announced") }
                pending.append(contentsOf: run.lazy.map(UserEvent.byte))
                lastWasRun = true
            case 1:
                let w = try reader.u16()
                let h = try reader.u16()
                guard w >= 1, h >= 1 else { throw reader.invalid("resize to \(w)x\(h)") }
                pending.append(.resize(TerminalSize(width: w, height: h)))
                lastWasRun = false
            case let tag:
                throw reader.invalid("input item \(tag)")
            }
        }

        let rowCount = try reader.count(minimumSize: 4)
        var rows: [Row] = []
        rows.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            let rowBytes = try reader.block()
            do {
                rows.append(try Row(serialized: rowBytes))
            } catch {
                throw reader.invalid("row \(rows.count): \(error)")
            }
        }

        let stateCount = try reader.count(minimumSize: 32)
        guard stateCount >= 1 else { throw reader.invalid("no remote state") }
        var remoteStates: [NumberedRemoteState<TerminalRemoteState>] = []
        remoteStates.reserveCapacity(stateCount)
        var rowsUsed = 0
        for _ in 0..<stateCount {
            let number = try reader.u64()
            guard number != UInt64.max else { throw reader.invalid("state number 2^64 - 1") }
            if let last = remoteStates.last, number <= last.number {
                throw reader.invalid("state numbers do not ascend")
            }
            let discardedReplyBytes = try reader.u64()
            let echoAckRegressions = try reader.u64()
            let skeleton = try reader.block()
            let lineCount = try reader.count(minimumSize: 4)
            var lines: [Row] = []
            lines.reserveCapacity(lineCount)
            for _ in 0..<lineCount {
                let index = Int(try reader.u32())
                guard index <= rowsUsed, index < rows.count else { throw reader.invalid("row index \(index)") }
                if index == rowsUsed { rowsUsed += 1 }
                lines.append(rows[index])
            }
            let terminal: TerminalState
            do {
                terminal = try TerminalState(serializedWithoutRows: skeleton, rows: lines)
            } catch {
                throw reader.invalid("state \(number): \(error)")
            }
            remoteStates.append(NumberedRemoteState(
                number: number,
                state: TerminalRemoteState(terminal: terminal, discardedReplyBytes: discardedReplyBytes,
                                           echoAckRegressions: echoAckRegressions)))
        }
        guard rowsUsed == rows.count else { throw reader.invalid("\(rows.count - rowsUsed) rows are not used") }
        try reader.finish()

        // What the import relies on (TransportCore.init(restoring:) checks the same again).
        guard remoteStates.contains(where: { $0.number == highestAckSent }) else {
            throw reader.invalid("the state \(highestAckSent) that was acknowledged is not held")
        }
        guard used.state > acknowledged else { throw reader.invalid("used state counter is not above A") }
        guard used.sequence <= UInt64(1) << 63 else { throw reader.invalid("used sequence counter beyond 63 bits") }

        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: acknowledged,
            pendingInput: pending,
            remoteStates: remoteStates,
            highestAckSent: highestAckSent,
            terminalSize: terminalSize,
            usedCounters: used,
            receiverExpectedSequence: receiverExpectedSequence)
        let clipboard = ClipboardPolicy(isEnabled: flags & 2 != 0,
                                        lastSeen: flags & 4 != 0 ? lastSeen : nil,
                                        lastWrittenHash: flags & 8 != 0 ? hash : nil)
        return StoredSnapshot(id: id, snapshot: SessionSnapshot(transport: transport, clipboard: clipboard))
    }
}
