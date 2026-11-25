import XCTest
import MoshTestSupport
import MoshWire

final class ProtoLiteTests: XCTestCase {
    func testVarintEncodings() {
        let cases: [(UInt64, String)] = [
            (0, "00"),
            (1, "01"),
            (127, "7f"),
            (128, "8001"),
            (300, "ac02"),
            (16383, "ff7f"),
            (16384, "808001"),
            (UInt64(UInt32.max), "ffffffff0f"),
            (1 << 32, "8080808010"),
            ((1 << 63) - 1, "ffffffffffffffff7f"),
            (1 << 63, "80808080808080808001"),
            (UInt64.max, "ffffffffffffffffff01"),
        ]
        for (value, expected) in cases {
            var writer = ProtoWriter()
            writer.appendVarint(value)
            XCTAssertEqual(hex(writer.bytes), expected, "\(value)")
            var reader = ProtoReader(bytes(hex: expected))
            XCTAssertEqual(try reader.readVarint(), value)
            XCTAssertTrue(reader.isAtEnd)
        }
    }

    func testVarintRoundTripsAroundEveryBoundary() throws {
        for shift in 0..<64 {
            for delta: UInt64 in [0, 1] {
                let value = (UInt64(1) << UInt64(shift)) &- delta
                var writer = ProtoWriter()
                writer.appendVarint(value)
                XCTAssertLessThanOrEqual(writer.bytes.count, 10)
                var reader = ProtoReader(writer.bytes)
                XCTAssertEqual(try reader.readVarint(), value)
            }
        }
    }

    func testMalformedVarints() {
        // Ends while the continuation bit is set.
        var truncated = ProtoReader(bytes(hex: "ffff"))
        XCTAssertThrowsError(try truncated.readVarint()) { XCTAssertEqual($0 as? ProtoError, .truncated) }
        var empty = ProtoReader([])
        XCTAssertThrowsError(try empty.readVarint()) { XCTAssertEqual($0 as? ProtoError, .truncated) }
        // Eleven bytes.
        var tooLong = ProtoReader(bytes(hex: "ffffffffffffffffffff01"))
        XCTAssertThrowsError(try tooLong.readVarint()) { XCTAssertEqual($0 as? ProtoError, .malformedVarint) }
    }

    func testFieldsAndTags() throws {
        var writer = ProtoWriter()
        writer.appendVarintField(1, 150)
        writer.appendBytesField(2, Array("testing".utf8))
        writer.appendInt32Field(3, -2)
        writer.appendVarintField(536_870_911, 1) // largest field number, 2^29 - 1
        XCTAssertEqual(hex(writer.bytes), "089601" + "120774657374696e67" + "18feffffffffffffffff01" + "f8ffffff0f01")

        var reader = ProtoReader(writer.bytes)
        var tag = try XCTUnwrap(try reader.readTag())
        XCTAssertEqual(tag.field, 1)
        XCTAssertEqual(tag.type, .varint)
        XCTAssertEqual(try reader.readVarint(), 150)
        tag = try XCTUnwrap(try reader.readTag())
        XCTAssertEqual(tag.field, 2)
        XCTAssertEqual(tag.type, .lengthDelimited)
        XCTAssertEqual(try reader.readBytes(), Array("testing".utf8))
        tag = try XCTUnwrap(try reader.readTag())
        XCTAssertEqual(tag.field, 3)
        XCTAssertEqual(Int32(truncatingIfNeeded: try reader.readVarint()), -2)
        tag = try XCTUnwrap(try reader.readTag())
        XCTAssertEqual(tag.field, 536_870_911)
        XCTAssertEqual(try reader.readVarint(), 1)
        XCTAssertNil(try reader.readTag())
        XCTAssertTrue(reader.isAtEnd)
    }

    func testInvalidTags() {
        // Field number 0.
        var zero = ProtoReader(bytes(hex: "0001"))
        XCTAssertThrowsError(try zero.readTag()) { XCTAssertEqual($0 as? ProtoError, .invalidTag(0)) }
        // Wire types 6 and 7 do not exist.
        var six = ProtoReader(bytes(hex: "0e01"))
        XCTAssertThrowsError(try six.readTag()) { XCTAssertEqual($0 as? ProtoError, .invalidTag(0x0E)) }
        var seven = ProtoReader(bytes(hex: "0f01"))
        XCTAssertThrowsError(try seven.readTag())
        // A tag that does not fit in 32 bits.
        var huge = ProtoReader(bytes(hex: "8080808010"))
        XCTAssertThrowsError(try huge.readTag())
    }

    func testSkipsEveryWireType() throws {
        // varint, fixed64, length-delimited, group (with a nested group and every type inside),
        // fixed32, then a field we want.
        let input = bytes(hex:
            "5001"                      // field 10 varint 1
            + "59 0102030405060708"     // field 11 fixed64
            + "62 03 aabbcc"            // field 12 bytes
            + "6b"                      // field 13 start group
            + "08 96 01"                //   field 1 varint 150
            + "13 0d 01020304 14"       //   field 2 group { field 1 fixed32 } end group 2
            + "1a 02 6869"              //   field 3 bytes
            + "6c"                      // field 13 end group
            + "75 01020304"             // field 14 fixed32
            + "08 2a")                  // field 1 varint 42
        var reader = ProtoReader(input)
        var found: UInt64? = nil
        var skipped: [UInt32] = []
        while let tag = try reader.readTag() {
            if tag.field == 1, tag.type == .varint {
                found = try reader.readVarint()
            } else {
                skipped.append(tag.field)
                try reader.skipValue(field: tag.field, type: tag.type)
            }
        }
        XCTAssertEqual(found, 42)
        XCTAssertEqual(skipped, [10, 11, 12, 13, 14])
    }

    func testSkipFailsOnTruncatedOrUnbalancedInput() {
        func skipAll(_ text: String) throws {
            var reader = ProtoReader(bytes(hex: text))
            while let tag = try reader.readTag() {
                try reader.skipValue(field: tag.field, type: tag.type)
            }
        }
        XCTAssertThrowsError(try skipAll("59 01020304")) { XCTAssertEqual($0 as? ProtoError, .truncated) }      // fixed64 cut
        XCTAssertThrowsError(try skipAll("75 0102")) { XCTAssertEqual($0 as? ProtoError, .truncated) }          // fixed32 cut
        XCTAssertThrowsError(try skipAll("62 05 aabb")) { XCTAssertEqual($0 as? ProtoError, .truncated) }       // bytes cut
        XCTAssertThrowsError(try skipAll("62 ffffffffffffffffff01")) { XCTAssertEqual($0 as? ProtoError, .truncated) } // absurd length
        XCTAssertThrowsError(try skipAll("50")) { XCTAssertEqual($0 as? ProtoError, .truncated) }               // varint missing
        XCTAssertThrowsError(try skipAll("6b 0801")) { XCTAssertEqual($0 as? ProtoError, .truncated) }          // group never ends
        XCTAssertThrowsError(try skipAll("6c")) { XCTAssertEqual($0 as? ProtoError, .unexpectedEndGroup) }      // end without start
        XCTAssertThrowsError(try skipAll("6b 74")) { XCTAssertEqual($0 as? ProtoError, .unexpectedEndGroup) }   // end of another group
        XCTAssertNoThrow(try skipAll(""))
        XCTAssertNoThrow(try skipAll("6b 6c"))
    }

    func testDeeplyNestedGroupsAreRefused() {
        // 200 nested start-group tags for field 1, then the matching ends.
        let input = [UInt8](repeating: 0x0B, count: 200) + [UInt8](repeating: 0x0C, count: 200)
        var reader = ProtoReader(input)
        XCTAssertThrowsError(try {
            while let tag = try reader.readTag() {
                try reader.skipValue(field: tag.field, type: tag.type)
            }
        }()) { XCTAssertEqual($0 as? ProtoError, .nestingTooDeep) }
    }

    func testReadBytes() throws {
        var reader = ProtoReader(bytes(hex: "00 03 010203 05 0102"))
        XCTAssertEqual(try reader.readBytes(), [])
        XCTAssertEqual(try reader.readBytes(), [1, 2, 3])
        XCTAssertThrowsError(try reader.readBytes()) { XCTAssertEqual($0 as? ProtoError, .truncated) }
    }
}
