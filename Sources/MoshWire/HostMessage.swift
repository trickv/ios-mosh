// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// HostBuffers.HostMessage (mosh src/protobufs/hostinput.proto): what a server's diff contains.
//
//     message HostMessage { repeated Instruction instruction = 1; }
//     message Instruction { extensions 2 to max; }
//     message HostBytes { optional bytes hoststring = 4; }
//     message ResizeMessage { optional int32 width = 5; optional int32 height = 6; }
//     message EchoAck { optional uint64 echo_ack_num = 8; }
//     extend Instruction {
//       optional HostBytes hostbytes = 2;
//       optional ResizeMessage resize = 3;
//       optional EchoAck echoack = 7;
//     }

/// One entry of a `HostMessage`.
public enum HostInstruction: Equatable, Sendable {
    /// Terminal output: bytes with escape sequences that turn the framebuffer of the state the
    /// diff is based on into the new one (made by mosh's `Display::new_frame`).
    case hostBytes([UInt8])
    /// The server's terminal now has this size, in character cells.
    case resize(width: Int32, height: Int32)
    /// The server's terminal has shown the effect of every client state up to this number.
    case echoAck(UInt64)
}

/// The diff a server sends. The instructions are applied in order (`Complete::apply_string`).
///
/// The server writes them in this order when present: echo ack, resize, host bytes
/// (`Complete::diff_from`).
public struct HostMessage: Equatable, Sendable {
    public var instructions: [HostInstruction]

    public init(instructions: [HostInstruction] = []) {
        self.instructions = instructions
    }

    /// Parses protobuf bytes the way mosh's client reads them (`Complete::apply_string`): an
    /// instruction with host bytes is host bytes, otherwise one with a resize is a resize,
    /// otherwise one with an echo ack is an echo ack. An instruction with none of them is dropped.
    public init(serialized: [UInt8]) throws {
        var instructions: [HostInstruction] = []
        var reader = ProtoReader(serialized)
        while let tag = try reader.readTag() {
            guard tag.field == 1, tag.type == .lengthDelimited else {
                try reader.skipValue(field: tag.field, type: tag.type)
                continue
            }
            var hostString: [UInt8]? = nil
            var size: ResizeFields? = nil
            var echoAck: UInt64? = nil
            var inner = ProtoReader(try reader.readBytes())
            while let innerTag = try inner.readTag() {
                switch (innerTag.field, innerTag.type) {
                case (2, .lengthDelimited):
                    hostString = try parseBytesMessage(try inner.readBytes(), field: 4, mergingInto: hostString)
                case (3, .lengthDelimited):
                    size = try ResizeFields(parsing: try inner.readBytes(), mergingInto: size)
                case (7, .lengthDelimited):
                    var value = echoAck ?? 0
                    var message = ProtoReader(try inner.readBytes())
                    while let messageTag = try message.readTag() {
                        if messageTag.field == 8, messageTag.type == .varint {
                            value = try message.readVarint()
                        } else {
                            try message.skipValue(field: messageTag.field, type: messageTag.type)
                        }
                    }
                    echoAck = value
                default:
                    try inner.skipValue(field: innerTag.field, type: innerTag.type)
                }
            }
            if let hostString {
                instructions.append(.hostBytes(hostString))
            } else if let size {
                instructions.append(.resize(width: size.width, height: size.height))
            } else if let echoAck {
                instructions.append(.echoAck(echoAck))
            }
        }
        self.instructions = instructions
    }

    /// The protobuf bytes. A message with no instructions is zero bytes long.
    public func serialized() -> [UInt8] {
        var writer = ProtoWriter()
        for instruction in instructions {
            var inner = ProtoWriter()
            switch instruction {
            case .hostBytes(let hostString):
                var message = ProtoWriter()
                message.appendBytesField(4, hostString)
                inner.appendBytesField(2, message.bytes)
            case .resize(let width, let height):
                inner.appendBytesField(3, ResizeFields(width: width, height: height).serialized())
            case .echoAck(let number):
                var message = ProtoWriter()
                message.appendVarintField(8, number)
                inner.appendBytesField(7, message.bytes)
            }
            writer.appendBytesField(1, inner.bytes)
        }
        return writer.bytes
    }
}
