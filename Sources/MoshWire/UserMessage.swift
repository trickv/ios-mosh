// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// ClientBuffers.UserMessage (mosh src/protobufs/userinput.proto): what a client's diff contains.
//
//     message UserMessage { repeated Instruction instruction = 1; }
//     message Instruction { extensions 2 to max; }
//     message Keystroke { optional bytes keys = 4; }
//     message ResizeMessage { optional int32 width = 5; optional int32 height = 6; }
//     extend Instruction {
//       optional Keystroke keystroke = 2;
//       optional ResizeMessage resize = 3;
//     }

/// One entry of a `UserMessage`.
public enum UserInstruction: Equatable, Sendable {
    /// Bytes typed by the user, in order. mosh's client joins consecutive bytes into one keystroke
    /// instruction (`UserStream::diff_from`).
    case keystroke([UInt8])
    /// The client's terminal now has this size, in character cells.
    case resize(width: Int32, height: Int32)
}

/// The diff a client sends: user input since the state the diff is based on.
public struct UserMessage: Equatable, Sendable {
    public var instructions: [UserInstruction]

    public init(instructions: [UserInstruction] = []) {
        self.instructions = instructions
    }

    /// Parses protobuf bytes the way mosh's server reads them (`UserStream::apply_string`): an
    /// instruction with a keystroke is a keystroke, otherwise one with a resize is a resize, and
    /// an instruction with neither is dropped.
    public init(serialized: [UInt8]) throws {
        var instructions: [UserInstruction] = []
        var reader = ProtoReader(serialized)
        while let tag = try reader.readTag() {
            guard tag.field == 1, tag.type == .lengthDelimited else {
                try reader.skipValue(field: tag.field, type: tag.type)
                continue
            }
            var keys: [UInt8]? = nil
            var size: ResizeFields? = nil
            var inner = ProtoReader(try reader.readBytes())
            while let innerTag = try inner.readTag() {
                switch (innerTag.field, innerTag.type) {
                case (2, .lengthDelimited):
                    keys = try parseBytesMessage(try inner.readBytes(), field: 4, mergingInto: keys)
                case (3, .lengthDelimited):
                    size = try ResizeFields(parsing: try inner.readBytes(), mergingInto: size)
                default:
                    try inner.skipValue(field: innerTag.field, type: innerTag.type)
                }
            }
            if let keys {
                instructions.append(.keystroke(keys))
            } else if let size {
                instructions.append(.resize(width: size.width, height: size.height))
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
            case .keystroke(let keys):
                var message = ProtoWriter()
                message.appendBytesField(4, keys)
                inner.appendBytesField(2, message.bytes)
            case .resize(let width, let height):
                inner.appendBytesField(3, ResizeFields(width: width, height: height).serialized())
            }
            writer.appendBytesField(1, inner.bytes)
        }
        return writer.bytes
    }
}

// MARK: - Pieces shared with HostMessage

/// `ResizeMessage { optional int32 width = 5; optional int32 height = 6; }`. The definition is the
/// same in userinput.proto and hostinput.proto.
struct ResizeFields {
    var width: Int32 = 0
    var height: Int32 = 0

    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    /// Parses one occurrence of the embedded message. protobuf merges repeated occurrences of an
    /// optional message field, so the fields of `earlier` survive unless this occurrence sets them.
    init(parsing bytes: [UInt8], mergingInto earlier: ResizeFields?) throws {
        if let earlier { self = earlier }
        var reader = ProtoReader(bytes)
        while let tag = try reader.readTag() {
            switch (tag.field, tag.type) {
            case (5, .varint): width = Int32(truncatingIfNeeded: try reader.readVarint())
            case (6, .varint): height = Int32(truncatingIfNeeded: try reader.readVarint())
            default: try reader.skipValue(field: tag.field, type: tag.type)
            }
        }
    }

    /// Both fields are always written, as mosh sets both.
    func serialized() -> [UInt8] {
        var writer = ProtoWriter()
        writer.appendInt32Field(5, width)
        writer.appendInt32Field(6, height)
        return writer.bytes
    }
}

/// Parses an embedded message that has a single optional `bytes` field (`Keystroke.keys`,
/// `HostBytes.hoststring`). A message without the field gives the empty string, which is what
/// protobuf's accessor returns. `earlier` is the value from an earlier occurrence of the message.
func parseBytesMessage(_ bytes: [UInt8], field: UInt32, mergingInto earlier: [UInt8]?) throws -> [UInt8] {
    var value = earlier ?? []
    var reader = ProtoReader(bytes)
    while let tag = try reader.readTag() {
        if tag.field == field, tag.type == .lengthDelimited {
            value = try reader.readBytes()
        } else {
            try reader.skipValue(field: tag.field, type: tag.type)
        }
    }
    return value
}
