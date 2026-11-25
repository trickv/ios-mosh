// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Packet framing: port of Network::Packet and of the 16-bit timestamp helpers
// (mosh src/network/network.cc).
//
// Plaintext of a datagram:
//
//     2 bytes   timestamp, big-endian: sender's clock in ms, mod 65536
//     2 bytes   timestamp_reply, big-endian: the peer's timestamp being answered, or 0xFFFF
//     n bytes   payload: one serialized Fragment
//
// The sequence number and the direction are not in the plaintext; they are the datagram's nonce.

import MoshCrypto

/// One mosh datagram before encryption or after decryption.
public struct Packet: Equatable, Sendable {
    /// Bytes of timestamps in front of the payload.
    public static let headerLength = 4

    /// Sequence number: the low 63 bits of the nonce. Never reuse one in the same direction under
    /// the same key.
    public var seq: UInt64
    public var direction: Direction
    /// The sender's `Timestamp16.now(milliseconds:)` when it sent the packet.
    public var timestamp: UInt16
    /// The timestamp the sender last received from its peer, advanced by the time it held it; or
    /// `Timestamp16.none`. The peer measures the round-trip time from it.
    public var timestampReply: UInt16
    /// One serialized `Fragment`.
    public var payload: [UInt8]

    public init(seq: UInt64, direction: Direction, timestamp: UInt16, timestampReply: UInt16, payload: [UInt8]) {
        self.seq = seq
        self.direction = direction
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }

    /// Reads a decrypted datagram. mosh: `Packet::Packet( const Message & )`.
    ///
    /// Throws `WireError.packetTooShort` when the plaintext cannot hold the timestamps.
    public init(_ opened: OpenedDatagram) throws {
        let text = opened.plaintext
        guard text.count >= Self.headerLength else { throw WireError.packetTooShort(text.count) }
        self.seq = opened.seq
        self.direction = opened.direction
        self.timestamp = (UInt16(text[0]) << 8) | UInt16(text[1])
        self.timestampReply = (UInt16(text[2]) << 8) | UInt16(text[3])
        self.payload = Array(text[Self.headerLength...])
    }

    /// The plaintext: both timestamps, then the payload. mosh: `Packet::toMessage`.
    public func plaintext() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerLength + payload.count)
        out.append(UInt8(truncatingIfNeeded: timestamp >> 8))
        out.append(UInt8(truncatingIfNeeded: timestamp))
        out.append(UInt8(truncatingIfNeeded: timestampReply >> 8))
        out.append(UInt8(truncatingIfNeeded: timestampReply))
        out.append(contentsOf: payload)
        return out
    }

    /// The encrypted datagram for this packet.
    public func encrypted(with cipher: MoshCipher) throws -> [UInt8] {
        try cipher.encrypt(seq: seq, direction: direction, plaintext: plaintext())
    }

    /// Authenticates, decrypts and parses a datagram. It does not check the direction or the order
    /// of sequence numbers; mosh's `Connection::recv_one` does both after this step.
    public init(decrypting datagram: [UInt8], with cipher: MoshCipher) throws {
        try self.init(try cipher.decrypt(datagram))
    }
}

/// mosh's 16-bit millisecond timestamps (`Network::timestamp16`, `Network::timestamp_diff`).
public enum Timestamp16 {
    /// 0xFFFF: "no timestamp". Never sent as a `timestamp`; as a `timestampReply` it means there is
    /// nothing to answer.
    public static let none: UInt16 = 0xFFFF

    /// A clock reading in milliseconds as a 16-bit timestamp: the value mod 65536, except that
    /// 0xFFFF becomes 0 because it is reserved. mosh: `timestamp16`.
    public static func now(milliseconds: UInt64) -> UInt16 {
        let value = UInt16(truncatingIfNeeded: milliseconds)
        return value == none ? 0 : value
    }

    /// Milliseconds from `old` to `new`, mod 65536. mosh: `timestamp_diff`.
    public static func difference(_ new: UInt16, _ old: UInt16) -> UInt16 {
        new &- old
    }
}
