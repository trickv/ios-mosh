// The byte-level tools every part of a session record is made with: little-endian integers,
// CRC-32, and the frame around `meta`, `key` and `snapshot`. The format is described byte by
// byte in docs/RESUME.md; that file and this code must say the same thing.

/// The parts of a session record (files in the session's directory).
public enum RecordPart: String, Equatable, Sendable, CaseIterable {
    case meta
    case key
    case counters
    case snapshot
}

/// Why bytes read from a session record were not accepted. Decoding never traps: whatever the
/// input, the result is a value or one of these.
public struct RecordFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// The bytes end before the part does.
        case truncated
        /// The first four bytes are not this part's magic number.
        case wrongMagic
        /// A format version this code does not read.
        case unsupportedVersion(UInt16)
        /// The length in the header does not agree with the number of bytes.
        case lengthMismatch
        /// The CRC-32 does not match.
        case checksumMismatch
        /// Bytes are left after the end of the content.
        case trailingBytes
        /// The part belongs to another session than the directory it is in.
        case wrongSession
        /// A value that the format or the session's invariants do not allow.
        case invalid(String)
    }

    public var part: RecordPart
    public var reason: Reason

    public init(_ part: RecordPart, _ reason: Reason) {
        self.part = part
        self.reason = reason
    }

    public var description: String { "\(part.rawValue): \(reason)" }
}

/// CRC-32 as in zlib, PNG and Ethernet (reflected polynomial 0xEDB88320, start value and final
/// XOR 0xFFFFFFFF). `checksum("123456789")` is 0xCBF43926.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Appends little-endian values.
struct RecordWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func raw(_ more: some Sequence<UInt8>) { bytes.append(contentsOf: more) }

    /// `u32` length, then the bytes.
    mutating func block(_ more: [UInt8]) {
        u32(UInt32(more.count))
        bytes.append(contentsOf: more)
    }

    /// `u16` length, then UTF-8. The caller has checked the length (`SessionMeta.maxStringBytes`).
    mutating func string(_ text: String) {
        let utf8 = Array(text.utf8)
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

/// Reads little-endian values and throws `truncated` instead of reading past the end.
struct RecordReader {
    let part: RecordPart
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8], part: RecordPart) {
        self.bytes = bytes
        self.part = part
    }

    var remaining: Int { bytes.count - position }
    var atEnd: Bool { position == bytes.count }

    func fail(_ reason: RecordFormatError.Reason) -> RecordFormatError {
        RecordFormatError(part, reason)
    }

    func invalid(_ text: String) -> RecordFormatError {
        RecordFormatError(part, .invalid(text))
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw fail(.truncated) }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw fail(.truncated) }
        defer { position += 2 }
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw fail(.truncated) }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[position + index]) << UInt32(8 * index)
        }
        position += 4
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw fail(.truncated) }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[position + index]) << UInt64(8 * index)
        }
        position += 8
        return value
    }

    mutating func raw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw fail(.truncated) }
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }

    /// A count of things that each take at least `minimumSize` bytes: refused when the rest of
    /// the input cannot hold that many, so that a damaged count cannot ask for memory.
    mutating func count(minimumSize: Int) throws -> Int {
        let value = Int(try u32())
        guard value <= remaining / max(1, minimumSize) else { throw fail(.truncated) }
        return value
    }

    mutating func block() throws -> [UInt8] {
        let length = Int(try u32())
        return try raw(length)
    }

    mutating func string() throws -> String {
        let utf8 = try raw(Int(try u16()))
        let text = String(decoding: utf8, as: UTF8.self)
        // Strict UTF-8: decoding repairs bad input, so a repaired string differs from its source.
        guard Array(text.utf8) == utf8 else { throw invalid("a string is not UTF-8") }
        return text
    }

    func finish() throws {
        guard atEnd else { throw fail(.trailingBytes) }
    }
}

/// The frame around `meta`, `key` and `snapshot`:
///
///     offset 0   4 bytes  magic
///            4   u16      format version
///            6   u16      0
///            8   u32      n, the length of the body
///           12   n bytes  body
///       12 + n   u32      CRC-32 of the bytes 0 ..< 12 + n
///
/// All integers little-endian. The file is exactly 16 + n bytes long.
enum PartFrame {
    static let headerSize = 12
    static let overhead = 16

    static func wrap(magic: [UInt8], version: UInt16, body: [UInt8]) -> [UInt8] {
        precondition(magic.count == 4)
        var writer = RecordWriter()
        writer.bytes.reserveCapacity(body.count + overhead)
        writer.raw(magic)
        writer.u16(version)
        writer.u16(0)
        writer.u32(UInt32(body.count))
        writer.raw(body)
        writer.u32(CRC32.checksum(writer.bytes))
        return writer.bytes
    }

    /// The body, after every check of the frame.
    static func unwrap(_ bytes: [UInt8], part: RecordPart, magic: [UInt8], version: UInt16) throws -> [UInt8] {
        var reader = RecordReader(bytes, part: part)
        guard bytes.count >= overhead else { throw reader.fail(.truncated) }
        guard try reader.raw(4) == magic else { throw reader.fail(.wrongMagic) }
        let found = try reader.u16()
        let reserved = try reader.u16()
        let length = Int(try reader.u32())
        // The length is compared before the checksum is computed: a wrong length would otherwise
        // be reported as a wrong checksum, and a truncated file is the common damage.
        guard length == bytes.count - overhead else {
            throw reader.fail(length > bytes.count - overhead ? .truncated : .lengthMismatch)
        }
        let body = try reader.raw(length)
        let stored = try reader.u32()
        guard CRC32.checksum(bytes[0..<(headerSize + length)]) == stored else { throw reader.fail(.checksumMismatch) }
        guard found == version else { throw reader.fail(.unsupportedVersion(found)) }
        guard reserved == 0 else { throw reader.invalid("reserved header field is \(reserved)") }
        return body
    }
}
