import Foundation

/// The two SSH wire primitives a public key blob is made of (RFC 4251 section 5):
/// `uint32` big-endian, and `string` = `uint32` length followed by that many bytes.
public struct SSHWireWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func writeString<S: Sequence>(_ content: S) where S.Element == UInt8 {
        let array = Array(content)
        writeUInt32(UInt32(array.count))
        bytes.append(contentsOf: array)
    }

    public mutating func writeString(_ text: String) {
        writeString(Array(text.utf8))
    }
}

/// Reads `uint32` and `string` values. Every read returns nil when the input is too short and
/// then leaves the position unchanged, so a caller can treat nil as "malformed" or "need more".
public struct SSHWireReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    public mutating func readString() -> [UInt8]? {
        let start = offset
        guard let length = readUInt32(), let content = readBytes(Int(length)) else {
            offset = start
            return nil
        }
        return content
    }
}
