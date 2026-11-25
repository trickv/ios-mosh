import MoshCrypto
import MoshTransport
import XCTest
@testable import MoshResume

final class RecordFormatTests: XCTestCase {
    func testCRC32CheckValue() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
        XCTAssertEqual(CRC32.checksum([0]), 0xD202_EF8D)
    }

    func testIntegersAreLittleEndian() throws {
        var writer = RecordWriter()
        writer.u16(0x0102)
        writer.u32(0x0304_0506)
        writer.u64(0x0708_090A_0B0C_0D0E)
        XCTAssertEqual(writer.bytes, [2, 1, 6, 5, 4, 3, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 9, 8, 7])
        var reader = RecordReader(writer.bytes, part: .meta)
        XCTAssertEqual(try reader.u16(), 0x0102)
        XCTAssertEqual(try reader.u32(), 0x0304_0506)
        XCTAssertEqual(try reader.u64(), 0x0708_090A_0B0C_0D0E)
        XCTAssertNoThrow(try reader.finish())
        XCTAssertThrowsError(try reader.u8())
    }

    func testSessionIDTextRoundTrip() {
        XCTAssertEqual(Fixtures.id.description, "10111213-1415-1617-1819-1a1b1c1d1e1f")
        XCTAssertEqual(SessionID(Fixtures.id.description), Fixtures.id)
        var generator = SplitMix64(seed: 1)
        for _ in 0..<50 {
            let id = SessionID.random(using: &generator)
            XCTAssertEqual(SessionID(id.description), id)
            XCTAssertEqual(id.bytes[6] >> 4, 4)
        }
        XCTAssertNil(SessionID("10111213-1415-1617-1819-1A1B1C1D1E1F"), "uppercase would be a second name for one id")
        XCTAssertNil(SessionID("10111213141516171819-1a1b1c1d1e1f----"))
        XCTAssertNil(SessionID("lock"))
        XCTAssertNil(SessionID(bytes: [1, 2, 3]))
        XCTAssertNotEqual(SessionID.random(), SessionID.random())
    }

    // MARK: meta

    func testMetaRoundTrip() throws {
        let meta = Fixtures.meta()
        let bytes = try meta.encoded()
        XCTAssertEqual(try SessionMeta(encoded: bytes, expecting: Fixtures.id), meta)
        XCTAssertEqual(try SessionMeta(encoded: bytes), meta)
        XCTAssertEqual(Array(bytes[0..<4]), Array("MRm1".utf8))
        XCTAssertEqual(bytes.count, 16 + 16 + 8 + 8 + 4 + 8 + 2 + 13 + 2 + 9 + 2 + 5 + 2 + 19)

        var plain = SessionMeta(id: Fixtures.id, createdAt: 0, hostName: "", address: "::1", port: 1,
                                serverStartSize: TerminalSize(width: 1, height: 1))
        XCTAssertEqual(try SessionMeta(encoded: try plain.encoded()), plain)
        plain.port = 65535
        plain.serverPID = .max
        plain.serverStartTime = .max
        plain.createdAt = .max
        plain.serverStartSize = TerminalSize(width: 65535, height: 65535)
        XCTAssertEqual(try SessionMeta(encoded: try plain.encoded()), plain)
    }

    func testMetaRefusesWhatItCannotHold() {
        var meta = Fixtures.meta()
        meta.address = ""
        XCTAssertThrowsError(try meta.encoded())
        meta = Fixtures.meta()
        meta.port = 0
        XCTAssertThrowsError(try meta.encoded())
        meta = Fixtures.meta()
        meta.remoteCommand = String(repeating: "x", count: SessionMeta.maxStringBytes + 1)
        XCTAssertThrowsError(try meta.encoded())
        meta.remoteCommand = String(repeating: "x", count: SessionMeta.maxStringBytes)
        XCTAssertNoThrow(try meta.encoded())
    }

    func testMetaOfAnotherSessionIsRefused() throws {
        let bytes = try Fixtures.meta().encoded()
        XCTAssertThrowsError(try SessionMeta(encoded: bytes, expecting: Fixtures.otherID)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.meta, .wrongSession))
        }
    }

    func testMetaStrictChecksBehindTheChecksum() throws {
        let good = try Fixtures.meta().encoded()
        // Offsets in the file: body starts at 12; id 12..<28, created 28..<36, port 36, size 38 and 40,
        // reserved 42, pid 44, start time 48, then the strings.
        func mutated(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
            var bytes = good
            change(&bytes)
            return withFixedChecksum(bytes)
        }
        XCTAssertNoThrow(try SessionMeta(encoded: mutated { _ in }))
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[36] = 0; $0[37] = 0 }), "port 0")
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[38] = 0; $0[39] = 0 }), "width 0")
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[40] = 0; $0[41] = 0 }), "height 0")
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[42] = 1 }), "reserved")
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[6] = 1 }), "reserved header field")
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[4] = 2 })) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.meta, .unsupportedVersion(2)))
        }
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[58] = 0xFF }), "host name is not UTF-8")
        // A string length that runs into the next field, with the frame still consistent.
        XCTAssertThrowsError(try SessionMeta(encoded: mutated { $0[56] += 1 }))
        // Bytes after the last string, inside the frame.
        var longer = Array(good.dropLast(4)) + [0]
        longer[8] += 1
        XCTAssertThrowsError(try SessionMeta(encoded: withFixedChecksum(longer + [0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.meta, .trailingBytes))
        }
    }

    // MARK: key

    func testKeyRoundTrip() throws {
        let bytes = StoredKey.encode(Fixtures.key, id: Fixtures.id)
        XCTAssertEqual(bytes.count, 16 + 16 + 16)
        XCTAssertEqual(try StoredKey.decode(bytes, expecting: Fixtures.id), Fixtures.key)
        XCTAssertThrowsError(try StoredKey.decode(bytes, expecting: Fixtures.otherID)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.key, .wrongSession))
        }
    }

    // MARK: damage

    /// Every byte of `meta` and `key`, changed in every one of its bits and to 0 and 0xFF: refused.
    func testEveryDamagedByteIsRejected() throws {
        let meta = try Fixtures.meta().encoded()
        let key = StoredKey.encode(Fixtures.key, id: Fixtures.id)
        var checked = 0
        for index in meta.indices {
            for value in damagedValues(of: meta[index]) {
                var bytes = meta
                bytes[index] = value
                XCTAssertThrowsError(try SessionMeta(encoded: bytes, expecting: Fixtures.id), "meta byte \(index) = \(value)")
                checked += 1
            }
        }
        for index in key.indices {
            for value in damagedValues(of: key[index]) {
                var bytes = key
                bytes[index] = value
                XCTAssertThrowsError(try StoredKey.decode(bytes, expecting: Fixtures.id), "key byte \(index) = \(value)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 8 * (meta.count + key.count))
    }

    /// A file cut at any length, or with bytes added, is refused.
    func testEveryTruncationIsRejected() throws {
        let meta = try Fixtures.meta().encoded()
        let key = StoredKey.encode(Fixtures.key, id: Fixtures.id)
        for length in 0..<meta.count {
            XCTAssertThrowsError(try SessionMeta(encoded: Array(meta[0..<length]), expecting: Fixtures.id), "meta cut at \(length)")
        }
        for length in 0..<key.count {
            XCTAssertThrowsError(try StoredKey.decode(Array(key[0..<length]), expecting: Fixtures.id), "key cut at \(length)")
        }
        XCTAssertThrowsError(try SessionMeta(encoded: meta + [0]))
        XCTAssertThrowsError(try StoredKey.decode(key + [0], expecting: Fixtures.id))
        XCTAssertThrowsError(try SessionMeta(encoded: meta + meta))
    }

    func testAPartIsNotTakenForAnother() throws {
        let meta = try Fixtures.meta().encoded()
        let key = StoredKey.encode(Fixtures.key, id: Fixtures.id)
        XCTAssertThrowsError(try StoredKey.decode(meta, expecting: Fixtures.id)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.key, .wrongMagic))
        }
        XCTAssertThrowsError(try SessionMeta(encoded: key)) {
            XCTAssertEqual($0 as? RecordFormatError, RecordFormatError(.meta, .wrongMagic))
        }
        XCTAssertThrowsError(try SnapshotCodec.decode(meta, expecting: Fixtures.id))
    }
}

/// The values a damaged byte is tried with: each single-bit flip, 0 and 0xFF.
func damagedValues(of byte: UInt8) -> [UInt8] {
    var values = Set((0..<8).map { byte ^ (1 << UInt8($0)) })
    values.insert(0)
    values.insert(0xFF)
    values.remove(byte)
    return values.sorted()
}
