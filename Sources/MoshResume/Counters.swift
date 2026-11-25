import MoshTransport

/// Whether a record's snapshot may be used.
public enum RecordState: Equatable, Hashable, Sendable {
    /// No datagram was sent since the snapshot with this id was stored. Only this state allows a
    /// resume, and only with the snapshot that carries the same id.
    case clean(snapshotID: UInt64)
    /// A datagram may have been sent since the last snapshot: what is stored is stale.
    case dirty
    /// The session is over or given up (the user closed it, the fallback took over). Never
    /// resumed. Sending is still safe (the limits hold), so a last shutdown request can go out.
    case ended
}

/// One of the two slots of the `counters` file: the reserved limits and the record's state.
///
///     offset 0   4 bytes   "MRc1"
///            4   u16       format version (1)
///            6   u8        state: 0 clean, 1 dirty, 2 ended
///            7   u8        0
///            8   u64       generation (1 or more; the slot it belongs in is generation mod 2)
///           16   16 bytes  session id
///           32   u64       sequence limit   (seqReserved)
///           40   u64       state limit      (numReserved)
///           48   u64       fragment limit   (fragIdReserved)
///           56   u64       snapshot id: not 0 when clean, 0 otherwise
///           64   u32       CRC-32 of the bytes 0 ..< 64
///
/// All integers little-endian; 68 bytes.
struct CountersSlot: Equatable, Sendable {
    static let magic = Array("MRc1".utf8)
    static let formatVersion: UInt16 = 1
    static let size = 68

    var generation: UInt64
    var sessionID: SessionID
    var limits: GateCounters
    var state: RecordState

    func encoded() -> [UInt8] {
        var writer = RecordWriter()
        writer.bytes.reserveCapacity(Self.size)
        writer.raw(Self.magic)
        writer.u16(Self.formatVersion)
        let snapshotID: UInt64
        switch state {
        case .clean(let id):
            precondition(id != 0, "a clean mark names a snapshot")
            writer.u8(0)
            snapshotID = id
        case .dirty:
            writer.u8(1)
            snapshotID = 0
        case .ended:
            writer.u8(2)
            snapshotID = 0
        }
        writer.u8(0)
        writer.u64(generation)
        writer.raw(sessionID.bytes)
        writer.u64(limits.sequence)
        writer.u64(limits.state)
        writer.u64(limits.fragmentID)
        writer.u64(snapshotID)
        writer.u32(CRC32.checksum(writer.bytes))
        return writer.bytes
    }

    /// Strict: any slot that `encoded()` would not have produced for this session is refused.
    init(encoded bytes: [UInt8], expecting expected: SessionID) throws {
        var reader = RecordReader(bytes, part: .counters)
        guard bytes.count >= Self.size else { throw reader.fail(.truncated) }
        guard bytes.count == Self.size else { throw reader.fail(.trailingBytes) }
        guard try reader.raw(4) == Self.magic else { throw reader.fail(.wrongMagic) }
        let version = try reader.u16()
        let stateByte = try reader.u8()
        let reserved = try reader.u8()
        let generation = try reader.u64()
        let id = try reader.raw(SessionID.length)
        let limits = GateCounters(sequence: try reader.u64(), state: try reader.u64(), fragmentID: try reader.u64())
        let snapshotID = try reader.u64()
        let stored = try reader.u32()
        guard CRC32.checksum(bytes[0..<(Self.size - 4)]) == stored else { throw reader.fail(.checksumMismatch) }
        guard version == Self.formatVersion else { throw reader.fail(.unsupportedVersion(version)) }
        guard reserved == 0 else { throw reader.invalid("reserved byte is \(reserved)") }
        guard generation >= 1 else { throw reader.invalid("generation 0") }
        guard id == expected.bytes else { throw reader.fail(.wrongSession) }
        let state: RecordState
        switch (stateByte, snapshotID) {
        case (0, 1...): state = .clean(snapshotID: snapshotID)
        case (1, 0): state = .dirty
        case (2, 0): state = .ended
        default: throw reader.invalid("state \(stateByte) with snapshot id \(snapshotID)")
        }
        self.init(generation: generation, sessionID: expected, limits: limits, state: state)
    }

    init(generation: UInt64, sessionID: SessionID, limits: GateCounters, state: RecordState) {
        self.generation = generation
        self.sessionID = sessionID
        self.limits = limits
        self.state = state
    }
}

/// What the two slots of a `counters` file say together.
public struct CountersReading: Equatable, Sendable {
    /// The generation of the newest valid slot.
    public var generation: UInt64
    /// Each limit is the highest one any valid slot holds: a restart never begins below a limit
    /// that was ever made durable.
    public var limits: GateCounters
    /// The state of the newest valid slot.
    public var state: RecordState
    /// How many of the two slots were valid (1 or 2).
    public var validSlots: Int
}

/// The layout of the `counters` file and the rule for reading it.
///
/// Slot 0 is at offset 0 and slot 1 at offset 4096, so that the two never share a disk block and
/// a torn write of one cannot damage the other. The file is 8192 bytes; everything outside the
/// slots is zero and is not looked at. A write of generation `g` goes to slot `g mod 2`, in
/// place, followed by an fsync, so the slot that is overwritten is always the older one.
public enum CountersFile {
    public static let slotSize = CountersSlot.size
    public static let slotSpacing = 4096
    public static let fileSize = 2 * slotSpacing

    public static func slotIndex(forGeneration generation: UInt64) -> Int { Int(generation % 2) }
    public static func offset(ofSlot index: Int) -> Int { index * slotSpacing }

    /// The file for a new record: no number reserved yet, dirty (there is no snapshot), written
    /// as generations 1 and 2 so that both slots are valid from the start.
    static func initialImage(sessionID: SessionID, limits: GateCounters = .sessionStart) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: fileSize)
        for generation: UInt64 in [1, 2] {
            let slot = CountersSlot(generation: generation, sessionID: sessionID, limits: limits, state: .dirty)
            let start = offset(ofSlot: slotIndex(forGeneration: generation))
            image.replaceSubrange(start..<(start + slotSize), with: slot.encoded())
        }
        return image
    }

    /// Reads the two slots (the bytes found at each slot's place, possibly fewer than 68).
    ///
    /// A slot counts only if it decodes strictly and sits in the place its generation belongs
    /// in. The newest valid slot gives the state. If both are valid they must be consecutive
    /// generations and the newer one must not hold a lower limit than the older one: anything
    /// else was not written by this code, and the record is refused as a whole.
    ///
    /// - Throws: `RecordFormatError` (part `.counters`) when no slot is valid, or the two
    ///   contradict each other.
    static func read(slot0: [UInt8], slot1: [UInt8], sessionID: SessionID) throws -> CountersReading {
        var valid: [CountersSlot] = []
        var firstError: RecordFormatError?
        for (index, bytes) in [slot0, slot1].enumerated() {
            do {
                let slot = try CountersSlot(encoded: bytes, expecting: sessionID)
                guard slotIndex(forGeneration: slot.generation) == index else {
                    throw RecordFormatError(.counters, .invalid("generation \(slot.generation) in slot \(index)"))
                }
                valid.append(slot)
            } catch let error as RecordFormatError {
                if firstError == nil { firstError = error }
            }
        }
        guard var newest = valid.first else {
            throw firstError ?? RecordFormatError(.counters, .truncated)
        }
        var limits = newest.limits
        if valid.count == 2 {
            let other: CountersSlot
            if valid[1].generation > newest.generation {
                other = newest
                newest = valid[1]
            } else {
                other = valid[1]
            }
            guard newest.generation - other.generation == 1 else {
                throw RecordFormatError(.counters, .invalid("generations \(other.generation) and \(newest.generation)"))
            }
            guard newest.limits.sequence >= other.limits.sequence, newest.limits.state >= other.limits.state,
                  newest.limits.fragmentID >= other.limits.fragmentID else {
                throw RecordFormatError(.counters, .invalid("the newer slot holds a lower limit"))
            }
            limits = newest.limits
        }
        return CountersReading(generation: newest.generation, limits: limits, state: newest.state, validSlots: valid.count)
    }
}
