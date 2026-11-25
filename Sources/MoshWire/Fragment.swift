// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Fragments: port of Network::Fragment, Fragmenter and FragmentAssembly
// (mosh src/network/transportfragment.cc).
//
// An instruction is serialized, compressed with zlib and cut into fragments, one per datagram:
//
//     8 bytes   instruction id, big-endian
//     2 bytes   big-endian (final << 15) | fragment number
//     n bytes   contents: a slice of the compressed instruction

/// One fragment of a compressed instruction.
public struct Fragment: Equatable, Sendable {
    /// `Fragment::frag_header_len`: 8 (id) + 2 (final flag and fragment number).
    public static let headerLength = 10
    /// Largest fragment number: 15 bits.
    public static let maxFragmentNum = 0x7FFF

    /// Instruction id: the same in every fragment of one instruction.
    public let id: UInt64
    /// Position of this fragment, from 0. At most `maxFragmentNum`.
    public let fragmentNum: UInt16
    /// True for the last fragment of the instruction.
    public let isFinal: Bool
    /// A slice of the compressed instruction.
    public let contents: [UInt8]

    /// Throws `WireError.fragmentNumberOutOfRange` if `fragmentNum` is above `maxFragmentNum`.
    public init(id: UInt64, fragmentNum: Int, isFinal: Bool, contents: [UInt8]) throws {
        guard fragmentNum >= 0, fragmentNum <= Self.maxFragmentNum else {
            throw WireError.fragmentNumberOutOfRange(fragmentNum)
        }
        self.id = id
        self.fragmentNum = UInt16(fragmentNum)
        self.isFinal = isFinal
        self.contents = contents
    }

    /// Parses a packet payload. mosh: `Fragment::Fragment( const string &x )`.
    public init(serialized: [UInt8]) throws {
        guard serialized.count >= Self.headerLength else {
            throw WireError.fragmentTooShort(serialized.count)
        }
        var id: UInt64 = 0
        for i in 0..<8 {
            id = (id << 8) | UInt64(serialized[i])
        }
        let combined = (UInt16(serialized[8]) << 8) | UInt16(serialized[9])
        self.id = id
        self.fragmentNum = combined & 0x7FFF
        self.isFinal = (combined & 0x8000) != 0
        self.contents = Array(serialized[Self.headerLength...])
    }

    /// The packet payload. mosh: `Fragment::tostring`.
    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerLength + contents.count)
        for i in 0..<8 {
            out.append(UInt8(truncatingIfNeeded: id >> UInt64(56 - 8 * i)))
        }
        let combined = (isFinal ? UInt16(0x8000) : 0) | fragmentNum
        out.append(UInt8(truncatingIfNeeded: combined >> 8))
        out.append(UInt8(truncatingIfNeeded: combined))
        out.append(contentsOf: contents)
        return out
    }
}

/// Cuts an instruction into fragments. mosh: `Fragmenter::make_fragments`.
///
/// Unlike mosh's `Fragmenter`, this one holds no state: the caller supplies the instruction id.
/// mosh takes the next id whenever the instruction differs from the previous one in anything but
/// its diff (`old_num`, `new_num`, `ack_num`, `throwaway_num`, `chaff`, `protocol_version`) or the
/// MTU changed; it starts at 1. The rule the receiver relies on is weaker: **two different
/// instructions, or two different fragmentations of one instruction, must never share an id**,
/// because the receiver matches fragments by id and position alone. A fresh id for every call is
/// always correct. A resumed session must not go back to ids it has used before.
public enum Fragmenter {
    /// Fragments for `instruction`: serialized, compressed, and cut into slices of at most
    /// `contentsBudget` bytes. There is always at least one fragment, and only the last is final.
    ///
    /// - Parameters:
    ///   - id: instruction id for every fragment. See the type's notes on uniqueness.
    ///   - contentsBudget: room for fragment contents in one datagram, normally
    ///     `WireConstants.fragmentContentsBudget(datagramMTU:)`.
    public static func makeFragments(instruction: Instruction, id: UInt64, contentsBudget: Int) throws -> [Fragment] {
        try split(compressed: try Compressor.compress(instruction.serialized()), id: id, contentsBudget: contentsBudget)
    }

    /// Cuts an already compressed instruction. An empty payload gives no fragments, as in mosh
    /// (zlib output is never empty, so this does not happen for an instruction).
    public static func split(compressed payload: [UInt8], id: UInt64, contentsBudget: Int) throws -> [Fragment] {
        guard contentsBudget >= 1 else { throw WireError.fragmentBudgetTooSmall(contentsBudget) }
        let count = (payload.count + contentsBudget - 1) / contentsBudget
        guard count <= Fragment.maxFragmentNum + 1 else { throw WireError.tooManyFragments(count) }
        var fragments: [Fragment] = []
        fragments.reserveCapacity(count)
        var start = 0
        for number in 0..<count {
            let end = min(start + contentsBudget, payload.count)
            fragments.append(try Fragment(
                id: id, fragmentNum: number, isFinal: end == payload.count,
                contents: Array(payload[start..<end])))
            start = end
        }
        return fragments
    }
}

/// Collects the fragments of one instruction. mosh: `FragmentAssembly`.
///
/// The rules are mosh's:
/// - A fragment whose id differs from the current one starts a new assembly and discards whatever
///   was collected (any different id, lower ones too).
/// - Fragments of the current id may arrive in any order. A duplicate is ignored if it is equal to
///   the one held.
/// - The instruction is complete when the final fragment has arrived and as many fragments are
///   held as it announces.
/// - After a completed instruction has been taken, the current id stays. If all its fragments
///   arrive again (a retransmission), it completes again; the transport above discards the
///   repeated instruction by its `newNum`.
///
/// Input that would trip one of mosh's assertions throws a `WireError` and leaves the assembly as
/// it was.
public struct FragmentAssembly: Sendable {
    private var fragments: [Fragment?] = []
    /// mosh starts with `current_id( -1 )`.
    private var currentID = UInt64.max
    private var fragmentsArrived = 0
    /// -1 while the final fragment has not arrived.
    private var fragmentsTotal = -1

    public init() {}

    /// True when every fragment of the current instruction has arrived and it can be taken.
    public var isComplete: Bool { fragmentsArrived == fragmentsTotal }

    /// Adds a fragment. Returns true when the instruction is complete; take it with
    /// `takeInstruction()` before adding more. mosh: `add_fragment`.
    public mutating func add(_ fragment: Fragment) throws -> Bool {
        let number = Int(fragment.fragmentNum)
        if currentID != fragment.id {
            // "see if this is a totally new packet"
            fragments = [Fragment?](repeating: nil, count: number + 1)
            fragments[number] = fragment
            fragmentsArrived = 1
            fragmentsTotal = -1
            currentID = fragment.id
        } else {
            // Work out the result first, so that a rejected fragment changes nothing.
            var held = false
            if fragments.count > number, let existing = fragments[number] {
                // "make sure new version is same as what we already have"
                guard existing == fragment else {
                    throw WireError.conflictingFragment(id: fragment.id, fragmentNum: fragment.fragmentNum)
                }
                held = true
            }
            let newCount = max(fragments.count, number + 1)
            let newArrived = held ? fragmentsArrived : fragmentsArrived + 1
            let newTotal = fragment.isFinal ? number + 1 : fragmentsTotal
            if fragment.isFinal, newCount > newTotal {
                throw WireError.fragmentOutOfRange(id: fragment.id, fragmentNum: fragment.fragmentNum)
            }
            if newTotal != -1, newArrived > newTotal {
                throw WireError.fragmentOutOfRange(id: fragment.id, fragmentNum: fragment.fragmentNum)
            }
            if !held {
                if fragments.count < newCount {
                    fragments.append(contentsOf: [Fragment?](repeating: nil, count: newCount - fragments.count))
                }
                fragments[number] = fragment
                fragmentsArrived = newArrived
            }
        }

        if fragment.isFinal {
            fragmentsTotal = number + 1
        }
        return fragmentsArrived == fragmentsTotal
    }

    /// The compressed instruction: the contents of all fragments in order. Resets the assembly
    /// (the current id stays). Throws `WireError.assemblyIncomplete` if fragments are missing.
    public mutating func takeCompressed() throws -> [UInt8] {
        guard fragmentsArrived == fragmentsTotal else { throw WireError.assemblyIncomplete }
        defer {
            fragments = []
            fragmentsArrived = 0
            fragmentsTotal = -1
        }
        var encoded: [UInt8] = []
        for index in 0..<fragmentsTotal {
            // A hole is possible when a stray fragment numbered beyond the final one was counted.
            guard index < fragments.count, let fragment = fragments[index] else {
                throw WireError.assemblyIncomplete
            }
            encoded.append(contentsOf: fragment.contents)
        }
        return encoded
    }

    /// The completed instruction: fragments joined, expanded with zlib and decoded. Resets the
    /// assembly whether or not that succeeds. mosh: `get_assembly`.
    public mutating func takeInstruction() throws -> Instruction {
        try Instruction(serialized: try Compressor.uncompress(try takeCompressed()))
    }
}
