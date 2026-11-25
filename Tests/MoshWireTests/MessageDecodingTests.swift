import XCTest
import MoshTestSupport
import MoshWire

/// Decoder behaviour that the protoc vectors do not reach: defaults, unknown fields, repeated
/// fields, mosh's order of preference between extensions, and damaged input.
final class MessageDecodingTests: XCTestCase {
    // MARK: Instruction

    func testInstructionDefaultsWhenFieldsAreMissing() throws {
        let empty = try Instruction(serialized: [])
        XCTAssertEqual(empty, Instruction(protocolVersion: 0, oldNum: 0, newNum: 0, ackNum: 0, throwawayNum: 0))
        // Only new_num present.
        let partial = try Instruction(serialized: bytes(hex: "1807"))
        XCTAssertEqual(partial.newNum, 7)
        XCTAssertEqual(partial.protocolVersion, 0)
        XCTAssertEqual(partial.diff, [])
    }

    func testInstructionDefaultInitializerUsesProtocolVersion2() {
        let instruction = Instruction(oldNum: 1, newNum: 2, ackNum: 3, throwawayNum: 0)
        XCTAssertEqual(instruction.protocolVersion, 2)
        XCTAssertEqual(WireConstants.protocolVersion, 2)
        XCTAssertEqual(hex(instruction.serialized()), "0802100118022003280032003a00")
    }

    func testInstructionSkipsUnknownFieldsAndTakesTheLastOfRepeatedOnes() throws {
        let input = bytes(hex:
            "0802"                  // protocol_version 2
            + "4a 03 010203"        // unknown field 9, bytes
            + "1005"                // old_num 5
            + "5501020304"          // unknown field 10, fixed32
            + "1006"                // old_num again: 6 wins
            + "1809"                // new_num 9
            + "3201 aa"             // diff aa
            + "3202 bbcc"           // diff again: bbcc wins
            + "610102030405060708") // unknown field 12, fixed64
        let instruction = try Instruction(serialized: input)
        XCTAssertEqual(instruction, Instruction(protocolVersion: 2, oldNum: 6, newNum: 9, ackNum: 0, throwawayNum: 0,
                                                diff: [0xBB, 0xCC], chaff: []))
    }

    func testInstructionFieldWithWrongWireTypeIsSkipped() throws {
        // old_num (field 2) as a length-delimited field, and diff (field 6) as a varint.
        let instruction = try Instruction(serialized: bytes(hex: "0802" + "1202ffff" + "3005" + "1803"))
        XCTAssertEqual(instruction.oldNum, 0)
        XCTAssertEqual(instruction.diff, [])
        XCTAssertEqual(instruction.newNum, 3)
    }

    func testInstructionProtocolVersionIsTruncatedTo32Bits() throws {
        // protobuf reads a uint32 field from a longer varint by dropping the high bits.
        let instruction = try Instruction(serialized: bytes(hex: "08 82808080 10"))
        XCTAssertEqual(instruction.protocolVersion, 2)
    }

    func testDamagedInstructionsThrow() {
        XCTAssertThrowsError(try Instruction(serialized: bytes(hex: "08")))             // varint missing
        XCTAssertThrowsError(try Instruction(serialized: bytes(hex: "0802 3205 0102"))) // diff cut short
        XCTAssertThrowsError(try Instruction(serialized: bytes(hex: "0802 00")))        // field number 0
        XCTAssertThrowsError(try Instruction(serialized: bytes(hex: "0802 0c")))        // stray end group
        XCTAssertThrowsError(try Instruction(serialized: bytes(hex: "ffffffffffffffffffffff")))
    }

    func testRandomInstructionsRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            func number() -> UInt64 {
                // Spread over all varint lengths.
                UInt64.random(in: 0...UInt64.max, using: &generator) >> UInt64.random(in: 0..<64, using: &generator)
            }
            let diffLength = Int.random(in: 0..<400, using: &generator)
            let instruction = Instruction(
                protocolVersion: UInt32(truncatingIfNeeded: number()),
                oldNum: number(), newNum: number(), ackNum: number(), throwawayNum: number(),
                diff: (0..<diffLength).map { _ in UInt8.random(in: 0...255, using: &generator) },
                chaff: Instruction.makeChaff(using: &generator))
            XCTAssertEqual(try Instruction(serialized: instruction.serialized()), instruction)
        }
    }

    func testChaffIsZeroToSixteenBytes() {
        var lengths = Set<Int>()
        for _ in 0..<2000 {
            let chaff = Instruction.makeChaff()
            XCTAssertLessThanOrEqual(chaff.count, 16)
            lengths.insert(chaff.count)
        }
        XCTAssertEqual(lengths, Set(0...16))
        XCTAssertEqual(Instruction.maxChaffLength, 16)
    }

    // MARK: UserMessage

    func testUserMessagePrefersKeystrokeOverResize() throws {
        // One instruction that carries both extensions. UserStream::apply_string tests for the
        // keystroke first.
        let both = bytes(hex: "0a0b" + "1a0428503018" + "1203220161")
        XCTAssertEqual(try UserMessage(serialized: both), UserMessage(instructions: [.keystroke([0x61])]))
    }

    func testUserMessageDropsInstructionsWithoutKnownExtension() throws {
        // empty instruction; instruction with unknown extension 9; a real keystroke
        let input = bytes(hex: "0a00" + "0a044a020102" + "0a051203220162")
        XCTAssertEqual(try UserMessage(serialized: input), UserMessage(instructions: [.keystroke([0x62])]))
    }

    func testUserMessageEmbeddedDefaultsAndMerging() throws {
        // Keystroke present but without keys: empty string.
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: "0a021200")), UserMessage(instructions: [.keystroke([])]))
        // Resize with only a width: height is 0.
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: "0a041a022850")),
                       UserMessage(instructions: [.resize(width: 80, height: 0)]))
        // The resize extension twice in one instruction: protobuf merges them field by field.
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: "0a08" + "1a022850" + "1a023018")),
                       UserMessage(instructions: [.resize(width: 80, height: 24)]))
        // The keystroke extension twice: the last keys win.
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: "0a0a" + "1203220161" + "1203220162")),
                       UserMessage(instructions: [.keystroke([0x62])]))
        // A second keystroke occurrence without keys keeps the earlier keys.
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: "0a07" + "1203220161" + "1200")),
                       UserMessage(instructions: [.keystroke([0x61])]))
    }

    func testUserMessageSkipsUnknownTopLevelFields() throws {
        let input = bytes(hex: "1005" + "0a051203220161" + "1a03616263")
        XCTAssertEqual(try UserMessage(serialized: input), UserMessage(instructions: [.keystroke([0x61])]))
    }

    func testDamagedUserMessagesThrow() {
        XCTAssertThrowsError(try UserMessage(serialized: bytes(hex: "0a05120322")))        // outer length too long
        XCTAssertThrowsError(try UserMessage(serialized: bytes(hex: "0a05120322056161")))  // inner length too long
        XCTAssertThrowsError(try UserMessage(serialized: bytes(hex: "0a03120322")))        // keys length missing
    }

    // MARK: HostMessage

    func testHostMessagePreference() throws {
        // Complete::apply_string tests hostbytes, then resize, then echoack.
        let hostBytes = "12032201" + "78"       // hostbytes "x"
        let resize = "1a0428503018"             // resize 80x24
        let echoAck = "3a024005"                // echoack 5
        func message(_ parts: String...) throws -> HostMessage {
            let inner = bytes(hex: parts.joined())
            return try HostMessage(serialized: [0x0A, UInt8(inner.count)] + inner)
        }
        XCTAssertEqual(try message(echoAck, resize, hostBytes), HostMessage(instructions: [.hostBytes([0x78])]))
        XCTAssertEqual(try message(echoAck, resize), HostMessage(instructions: [.resize(width: 80, height: 24)]))
        XCTAssertEqual(try message(echoAck), HostMessage(instructions: [.echoAck(5)]))
        XCTAssertEqual(try message(), HostMessage(instructions: []))
    }

    func testHostMessageEmbeddedDefaults() throws {
        XCTAssertEqual(try HostMessage(serialized: bytes(hex: "0a021200")), HostMessage(instructions: [.hostBytes([])]))
        XCTAssertEqual(try HostMessage(serialized: bytes(hex: "0a021a00")),
                       HostMessage(instructions: [.resize(width: 0, height: 0)]))
        XCTAssertEqual(try HostMessage(serialized: bytes(hex: "0a023a00")), HostMessage(instructions: [.echoAck(0)]))
        // Unknown fields inside the embedded messages are skipped.
        XCTAssertEqual(try HostMessage(serialized: bytes(hex: "0a06" + "3a04" + "0801" + "4009")),
                       HostMessage(instructions: [.echoAck(9)]))
    }

    func testRandomMessagesRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        func randomBytes() -> [UInt8] {
            (0..<Int.random(in: 0..<300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        for _ in 0..<200 {
            var host = HostMessage()
            var user = UserMessage()
            for _ in 0..<Int.random(in: 0..<6, using: &generator) {
                switch Int.random(in: 0..<3, using: &generator) {
                case 0:
                    host.instructions.append(.hostBytes(randomBytes()))
                    user.instructions.append(.keystroke(randomBytes()))
                case 1:
                    let width = Int32.random(in: Int32.min...Int32.max, using: &generator)
                    let height = Int32.random(in: -5...500, using: &generator)
                    host.instructions.append(.resize(width: width, height: height))
                    user.instructions.append(.resize(width: height, height: width))
                default:
                    host.instructions.append(.echoAck(UInt64.random(in: 0...UInt64.max, using: &generator)))
                }
            }
            XCTAssertEqual(try HostMessage(serialized: host.serialized()), host)
            XCTAssertEqual(try UserMessage(serialized: user.serialized()), user)
        }
    }
}
