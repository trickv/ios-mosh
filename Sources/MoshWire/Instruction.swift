// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// TransportBuffers.Instruction (mosh src/protobufs/transportinstruction.proto):
//
//     message Instruction {
//       optional uint32 protocol_version = 1;
//       optional uint64 old_num = 2;
//       optional uint64 new_num = 3;
//       optional uint64 ack_num = 4;
//       optional uint64 throwaway_num = 5;
//       optional bytes diff = 6;
//       optional bytes chaff = 7;
//     }

/// One transport instruction: "take state `oldNum`, apply `diff`, call the result `newNum`".
///
/// mosh's sender sets all seven fields on every instruction (`TransportSender::send_in_fragments`),
/// so `serialized()` always writes all seven, including zeros and empty strings. That makes the
/// bytes equal to what mosh (and protoc) produce for the same values. On decoding, a missing
/// field takes its protobuf default: 0 or empty.
public struct Instruction: Equatable, Sendable {
    /// Must be `WireConstants.protocolVersion` (2). mosh's receiver refuses anything else.
    public var protocolVersion: UInt32
    /// The state the diff is based on. The receiver must still hold it, or it drops the instruction.
    public var oldNum: UInt64
    /// The number of the state the diff leads to. `Instruction.shutdownNum` announces shutdown.
    public var newNum: UInt64
    /// The newest state of the other side that the sender has received.
    public var ackNum: UInt64
    /// The receiver may forget every state below this one.
    public var throwawayNum: UInt64
    /// A serialized `UserMessage` (client to server) or `HostMessage` (server to client). May be empty.
    public var diff: [UInt8]
    /// 0 to 16 random bytes that hide the length of short instructions. Ignored by the receiver.
    public var chaff: [UInt8]

    /// `new_num` (and the `ack_num` that answers it) of the shutdown sequence: 2^64 - 1.
    public static let shutdownNum = UInt64.max
    /// mosh's `CHAFF_MAX`: chaff is `prng.uint8() % 17` bytes long.
    public static let maxChaffLength = 16

    public init(
        protocolVersion: UInt32 = WireConstants.protocolVersion,
        oldNum: UInt64,
        newNum: UInt64,
        ackNum: UInt64,
        throwawayNum: UInt64,
        diff: [UInt8] = [],
        chaff: [UInt8] = []
    ) {
        self.protocolVersion = protocolVersion
        self.oldNum = oldNum
        self.newNum = newNum
        self.ackNum = ackNum
        self.throwawayNum = throwawayNum
        self.diff = diff
        self.chaff = chaff
    }

    /// Parses protobuf bytes. Unknown fields are skipped. If a field occurs twice the last one wins.
    public init(serialized: [UInt8]) throws {
        self.init(protocolVersion: 0, oldNum: 0, newNum: 0, ackNum: 0, throwawayNum: 0)
        var reader = ProtoReader(serialized)
        while let tag = try reader.readTag() {
            switch (tag.field, tag.type) {
            case (1, .varint): protocolVersion = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (2, .varint): oldNum = try reader.readVarint()
            case (3, .varint): newNum = try reader.readVarint()
            case (4, .varint): ackNum = try reader.readVarint()
            case (5, .varint): throwawayNum = try reader.readVarint()
            case (6, .lengthDelimited): diff = try reader.readBytes()
            case (7, .lengthDelimited): chaff = try reader.readBytes()
            default: try reader.skipValue(field: tag.field, type: tag.type)
            }
        }
    }

    /// The protobuf bytes, all seven fields in field order.
    public func serialized() -> [UInt8] {
        var writer = ProtoWriter()
        writer.appendVarintField(1, UInt64(protocolVersion))
        writer.appendVarintField(2, oldNum)
        writer.appendVarintField(3, newNum)
        writer.appendVarintField(4, ackNum)
        writer.appendVarintField(5, throwawayNum)
        writer.appendBytesField(6, diff)
        writer.appendBytesField(7, chaff)
        return writer.bytes
    }

    /// Chaff as mosh makes it (`TransportSender::make_chaff`): a random length from 0 to 16, random
    /// bytes, from the system's secure generator.
    public static func makeChaff() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return makeChaff(using: &generator)
    }

    /// `makeChaff()` with a caller-supplied generator, for tests that need fixed bytes.
    public static func makeChaff<G: RandomNumberGenerator>(using generator: inout G) -> [UInt8] {
        let length = Int(UInt8.random(in: UInt8.min...UInt8.max, using: &generator)) % (maxChaffLength + 1)
        return (0..<length).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }
}
