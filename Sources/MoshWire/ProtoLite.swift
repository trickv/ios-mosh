// A minimal protobuf wire-format reader and writer: just what mosh's three small proto2
// files need. Varints, length-delimited fields, and skipping of everything else.

/// Protobuf wire types.
public enum ProtoWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// Errors from `ProtoReader`. Any of them means the message is not valid protobuf.
public enum ProtoError: Error, Equatable, Sendable {
    /// The input ended inside a field.
    case truncated
    /// A varint ran past ten bytes.
    case malformedVarint
    /// A tag with field number 0, a field number above 2^29 - 1, or wire type 6 or 7.
    case invalidTag(UInt64)
    /// An end-group tag with no matching start.
    case unexpectedEndGroup
    /// Groups nested deeper than protobuf's own limit of 100.
    case nestingTooDeep
}

/// Appends protobuf fields to a byte array. Fields must be written in field-number order to
/// match what protoc-generated code produces.
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Base-128 varint, least significant group first.
    public mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func appendTag(field: UInt32, type: ProtoWireType) {
        appendVarint((UInt64(field) << 3) | UInt64(type.rawValue))
    }

    /// A `uint32` or `uint64` field.
    public mutating func appendVarintField(_ field: UInt32, _ value: UInt64) {
        appendTag(field: field, type: .varint)
        appendVarint(value)
    }

    /// An `int32` field. Negative values are sign-extended to 64 bits (ten bytes), as protobuf does.
    public mutating func appendInt32Field(_ field: UInt32, _ value: Int32) {
        appendVarintField(field, UInt64(bitPattern: Int64(value)))
    }

    /// A `bytes` field or an embedded message that is already serialized.
    public mutating func appendBytesField<Bytes: Collection>(_ field: UInt32, _ value: Bytes) where Bytes.Element == UInt8 {
        appendTag(field: field, type: .lengthDelimited)
        appendVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }
}

/// Reads protobuf fields from a byte array.
///
///     var reader = ProtoReader(bytes)
///     while let tag = try reader.readTag() {
///         switch (tag.field, tag.type) {
///         case (1, .varint): x = try reader.readVarint()
///         default: try reader.skipValue(field: tag.field, type: tag.type)
///         }
///     }
///
/// A known field number with an unexpected wire type is skipped like an unknown field, which is
/// what protobuf's own parser does.
public struct ProtoReader: Sendable {
    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.index = 0
        self.end = bytes.count
    }

    public init(_ slice: ArraySlice<UInt8>) {
        self.init(Array(slice))
    }

    public var isAtEnd: Bool { index >= end }

    /// The next field's number and wire type, or nil at the end of the input.
    public mutating func readTag() throws -> (field: UInt32, type: ProtoWireType)? {
        if isAtEnd { return nil }
        let tag = try readVarint()
        let fieldNumber = tag >> 3
        guard tag <= UInt64(UInt32.max), fieldNumber >= 1,
              let type = ProtoWireType(rawValue: UInt8(tag & 7)) else {
            throw ProtoError.invalidTag(tag)
        }
        return (UInt32(fieldNumber), type)
    }

    /// A varint of up to ten bytes. Bits beyond the 64th are dropped, as protobuf does.
    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard index < end else { throw ProtoError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError.malformedVarint
    }

    /// The contents of a length-delimited field.
    public mutating func readBytes() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(end - index) else { throw ProtoError.truncated }
        let start = index
        index += Int(length)
        return Array(bytes[start..<index])
    }

    /// Skips the value of a field whose tag was just read.
    public mutating func skipValue(field: UInt32, type: ProtoWireType) throws {
        try skipValue(field: field, type: type, depth: 0)
    }

    private mutating func skipValue(field: UInt32, type: ProtoWireType, depth: Int) throws {
        switch type {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try skipBytes(8)
        case .fixed32:
            try skipBytes(4)
        case .lengthDelimited:
            let length = try readVarint()
            guard length <= UInt64(end - index) else { throw ProtoError.truncated }
            index += Int(length)
        case .startGroup:
            guard depth < 100 else { throw ProtoError.nestingTooDeep }
            while true {
                guard let inner = try readTag() else { throw ProtoError.truncated }
                if inner.type == .endGroup {
                    guard inner.field == field else { throw ProtoError.unexpectedEndGroup }
                    return
                }
                try skipValue(field: inner.field, type: inner.type, depth: depth + 1)
            }
        case .endGroup:
            throw ProtoError.unexpectedEndGroup
        }
    }

    private mutating func skipBytes(_ count: Int) throws {
        guard count <= end - index else { throw ProtoError.truncated }
        index += count
    }
}
