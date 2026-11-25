import XCTest
import MoshTestSupport
import MoshWire

/// Encodings compared byte for byte with protoc.
///
/// Every hex string below was produced once in the dev container (libprotoc 3.21.12) from mosh
/// 1.4.0's own .proto files, with the text-format message given above it:
///
///     printf '%s' "$TEXT" | protoc -I /opt/mosh-src/src/protobufs --encode=$TYPE \
///         /opt/mosh-src/src/protobufs/$FILE | od -An -v -tx1 | tr -d ' \n'
///
/// Each vector is checked in both directions: our encoder gives exactly these bytes, and our
/// decoder gives back the message.
final class ProtocVectorTests: XCTestCase {
    private func check(_ message: Instruction, _ expected: String, line: UInt = #line) throws {
        XCTAssertEqual(hex(message.serialized()), expected, "encode", line: line)
        XCTAssertEqual(try Instruction(serialized: bytes(hex: expected)), message, "decode", line: line)
    }

    private func check(_ message: UserMessage, _ expected: String, line: UInt = #line) throws {
        XCTAssertEqual(hex(message.serialized()), expected, "encode", line: line)
        XCTAssertEqual(try UserMessage(serialized: bytes(hex: expected)), message, "decode", line: line)
    }

    private func check(_ message: HostMessage, _ expected: String, line: UInt = #line) throws {
        XCTAssertEqual(hex(message.serialized()), expected, "encode", line: line)
        XCTAssertEqual(try HostMessage(serialized: bytes(hex: expected)), message, "decode", line: line)
    }

    // MARK: The two byte strings of the plan's appendix

    /// ClientBuffers.UserMessage: instruction { [ClientBuffers.keystroke] { keys: "a" } }
    func testKeystrokeA() throws {
        try check(UserMessage(instructions: [.keystroke(Array("a".utf8))]), "0a051203220161")
        XCTAssertEqual(UserMessage(instructions: [.keystroke([0x61])]).serialized(),
                       [0x0A, 0x05, 0x12, 0x03, 0x22, 0x01, 0x61])
    }

    /// ClientBuffers.UserMessage: instruction { [ClientBuffers.resize] { width: 80 height: 24 } }
    func testResize80x24() throws {
        try check(UserMessage(instructions: [.resize(width: 80, height: 24)]), "0a061a0428503018")
        XCTAssertEqual(UserMessage(instructions: [.resize(width: 80, height: 24)]).serialized(),
                       [0x0A, 0x06, 0x1A, 0x04, 0x28, 0x50, 0x30, 0x18])
    }

    // MARK: TransportBuffers.Instruction

    /// protocol_version: 2 old_num: 3 new_num: 4 ack_num: 5 throwaway_num: 1
    /// diff: "\x0a\x05\x12\x03\x22\x01\x61" chaff: "\x00\xff\x10\x80"
    func testInstructionWithAllFields() throws {
        try check(
            Instruction(protocolVersion: 2, oldNum: 3, newNum: 4, ackNum: 5, throwawayNum: 1,
                        diff: bytes(hex: "0a051203220161"), chaff: [0x00, 0xFF, 0x10, 0x80]),
            "0802100318042005280132070a0512032201613a0400ff1080")
    }

    /// The first instruction a client sends (stmclient.cc: state 1 is a Resize), without chaff.
    /// protocol_version: 2 old_num: 0 new_num: 1 ack_num: 0 throwaway_num: 0
    /// diff: "\x0a\x06\x1a\x04\x28\x50\x30\x18" chaff: ""
    func testFirstClientInstruction() throws {
        let diff = UserMessage(instructions: [.resize(width: 80, height: 24)]).serialized()
        try check(
            Instruction(oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0, diff: diff, chaff: []),
            "0802100018012000280032080a061a04285030183a00")
    }

    /// Fields that are set to zero or to the empty string are still written (proto2 "optional").
    /// protocol_version: 2 old_num: 0 new_num: 0 ack_num: 0 throwaway_num: 0 diff: "" chaff: ""
    func testInstructionWithZerosAndEmptyStrings() throws {
        try check(
            Instruction(protocolVersion: 2, oldNum: 0, newNum: 0, ackNum: 0, throwawayNum: 0, diff: [], chaff: []),
            "0802100018002000280032003a00")
    }

    /// State numbers of 2^64 - 1 (the shutdown sequence) and the largest uint32.
    /// protocol_version: 4294967295 old_num: 18446744073709551615 new_num: 18446744073709551615
    /// ack_num: 18446744073709551615 throwaway_num: 18446744073709551615 diff: ""
    /// chaff: "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
    func testInstructionWithMaximumNumbers() throws {
        XCTAssertEqual(Instruction.shutdownNum, 18446744073709551615)
        try check(
            Instruction(protocolVersion: .max, oldNum: .max, newNum: Instruction.shutdownNum, ackNum: .max,
                        throwawayNum: .max, diff: [], chaff: Array(1...16)),
            "08ffffffff0f10ffffffffffffffffff0118ffffffffffffffffff0120ffffffffffffffffff01"
                + "28ffffffffffffffffff0132003a100102030405060708090a0b0c0d0e0f10")
    }

    /// Varints on both sides of the one-byte and two-byte limits.
    /// protocol_version: 2 old_num: 127 new_num: 128 ack_num: 16383 throwaway_num: 16384
    /// diff: "x" chaff: "y"
    func testInstructionWithVarintBoundaries() throws {
        try check(
            Instruction(oldNum: 127, newNum: 128, ackNum: 16383, throwawayNum: 16384,
                        diff: Array("x".utf8), chaff: Array("y".utf8)),
            "0802107f18800120ff7f288080013201783a0179")
    }

    /// Large varints, and a diff long enough (130 bytes) for a two-byte length.
    /// protocol_version: 2 old_num: 9223372036854775807 new_num: 9223372036854775808
    /// ack_num: 4294967296 throwaway_num: 72057594037927936
    /// diff: "0123456789" thirteen times  chaff: "\xff"
    func testInstructionWithLargeVarintsAndLongDiff() throws {
        let diff = Array(String(repeating: "0123456789", count: 13).utf8)
        try check(
            Instruction(oldNum: (1 << 63) - 1, newNum: 1 << 63, ackNum: 1 << 32, throwawayNum: 1 << 56,
                        diff: diff, chaff: [0xFF]),
            "080210ffffffffffffffff7f188080808080808080800120808080801028808080808080808001328201"
                + hex(diff) + "3a01ff")
    }

    // MARK: ClientBuffers.UserMessage

    /// instruction { [ClientBuffers.keystroke] { keys: "ls -l\r" } }
    /// instruction { [ClientBuffers.resize] { width: 132 height: 43 } }
    /// instruction { [ClientBuffers.keystroke] { keys: "\x00\x1b[A\xff\x7f" } }
    /// instruction { [ClientBuffers.keystroke] { keys: "" } }
    /// instruction { [ClientBuffers.resize] { width: 80 height: 24 } }
    func testUserMessageWithSeveralInstructions() throws {
        try check(
            UserMessage(instructions: [
                .keystroke(Array("ls -l\r".utf8)),
                .resize(width: 132, height: 43),
                .keystroke([0x00, 0x1B, 0x5B, 0x41, 0xFF, 0x7F]),
                .keystroke([]),
                .resize(width: 80, height: 24),
            ]),
            "0a0a120822066c73202d6c0d0a071a05288401302b0a0a12082206001b5b41ff7f0a04120222000a061a0428503018")
    }

    /// int32 extremes: a negative int32 is written as a ten-byte varint.
    /// instruction { [ClientBuffers.resize] { width: 2147483647 height: -1 } }
    /// instruction { [ClientBuffers.resize] { width: -2147483648 height: 0 } }
    /// instruction { [ClientBuffers.resize] { width: 65535 height: 300 } }
    func testUserMessageWithResizeExtremes() throws {
        try check(
            UserMessage(instructions: [
                .resize(width: .max, height: -1),
                .resize(width: .min, height: 0),
                .resize(width: 65535, height: 300),
            ]),
            "0a131a1128ffffffff0730ffffffffffffffffff010a0f1a0d2880808080f8ffffffff0130000a091a0728ffff0330ac02")
    }

    // MARK: HostBuffers.HostMessage

    /// The three kinds in the order a server writes them (Complete::diff_from).
    /// instruction { [HostBuffers.echoack] { echo_ack_num: 7 } }
    /// instruction { [HostBuffers.resize] { width: 80 height: 24 } }
    /// instruction { [HostBuffers.hostbytes] { hoststring: "\x1b[?25l\r\x1b[Khello-42\r\n$ \x1b[?25h" } }
    func testHostMessageWithEchoAckResizeAndHostBytes() throws {
        try check(
            HostMessage(instructions: [
                .echoAck(7),
                .resize(width: 80, height: 24),
                .hostBytes(Array("\u{1B}[?25l\r\u{1B}[Khello-42\r\n$ \u{1B}[?25h".utf8)),
            ]),
            "0a043a0240070a061a04285030180a20121e221c1b5b3f32356c0d1b5b4b68656c6c6f2d34320d0a24201b5b3f323568")
    }

    /// instruction { [HostBuffers.echoack] { echo_ack_num: 18446744073709551615 } }
    /// instruction { [HostBuffers.echoack] { echo_ack_num: 0 } }
    /// instruction { [HostBuffers.echoack] { echo_ack_num: 300 } }
    func testHostMessageWithEchoAckExtremes() throws {
        try check(
            HostMessage(instructions: [.echoAck(.max), .echoAck(0), .echoAck(300)]),
            "0a0d3a0b40ffffffffffffffffff010a043a0240000a053a0340ac02")
    }

    /// Host bytes of 300 bytes (every byte value; two-byte lengths at three levels), a resize and
    /// an empty host string.
    /// instruction { [HostBuffers.hostbytes] { hoststring: bytes 0, 1, ... 255, 0, ... 43 } }
    /// instruction { [HostBuffers.resize] { width: 200 height: 60 } }
    /// instruction { [HostBuffers.hostbytes] { hoststring: "" } }
    func testHostMessageWithLongHostBytes() throws {
        let long = (0..<300).map { UInt8($0 % 256) }
        try check(
            HostMessage(instructions: [
                .hostBytes(long),
                .resize(width: 200, height: 60),
                .hostBytes([]),
            ]),
            "0ab20212af0222ac02" + hex(long) + "0a071a0528c801303c0a0412022200")
    }

    /// A message with no instructions is zero bytes, for both kinds; and a diff of zero bytes
    /// decodes to a message with no instructions.
    func testEmptyMessages() throws {
        try check(HostMessage(), "")
        try check(UserMessage(), "")
    }
}
