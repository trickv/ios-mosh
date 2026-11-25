import XCTest
import MoshTestSupport
import MoshCrypto
import MoshWire

final class PacketTests: XCTestCase {
    func testPlaintextLayout() throws {
        let packet = Packet(seq: 5, direction: .toServer, timestamp: 0x1234, timestampReply: 0xFFFF,
                            payload: [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(hex(packet.plaintext()), "1234" + "ffff" + "aabbcc")

        let parsed = try Packet(OpenedDatagram(direction: .toClient, seq: 9, plaintext: bytes(hex: "0001" + "fffe" + "0102")))
        XCTAssertEqual(parsed, Packet(seq: 9, direction: .toClient, timestamp: 1, timestampReply: 0xFFFE, payload: [1, 2]))

        // Four bytes are enough: an empty payload.
        let bare = try Packet(OpenedDatagram(direction: .toClient, seq: 0, plaintext: bytes(hex: "abcd" + "ef01")))
        XCTAssertEqual(bare.timestamp, 0xABCD)
        XCTAssertEqual(bare.timestampReply, 0xEF01)
        XCTAssertEqual(bare.payload, [])
        XCTAssertEqual(Packet.headerLength, 4)
    }

    func testTooShortPlaintextIsRejected() {
        // mosh: dos_assert( message.text.size() >= 2 * sizeof( uint16_t ) )
        for length in 0..<4 {
            let opened = OpenedDatagram(direction: .toClient, seq: 1, plaintext: [UInt8](repeating: 0, count: length))
            XCTAssertThrowsError(try Packet(opened)) { error in
                XCTAssertEqual(error as? WireError, .packetTooShort(length))
            }
        }
    }

    func testEncryptDecryptRoundTrip() throws {
        let cipher = try MoshCipher(key: .random())
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let packet = Packet(
                seq: UInt64.random(in: 0...MoshCipher.maxSequence, using: &generator),
                direction: Bool.random(using: &generator) ? .toClient : .toServer,
                timestamp: UInt16.random(in: 0...UInt16.max, using: &generator),
                timestampReply: UInt16.random(in: 0...UInt16.max, using: &generator),
                payload: (0..<Int.random(in: 0..<1300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let datagram = try packet.encrypted(with: cipher)
            XCTAssertEqual(datagram.count, packet.payload.count + WireConstants.connectionAddedBytes + WireConstants.sessionAddedBytes)
            XCTAssertEqual(try Packet(decrypting: datagram, with: cipher), packet)
        }
        // A datagram that authenticates but is too short to be a packet.
        let runt = try cipher.encrypt(seq: 1, direction: .toClient, plaintext: [1, 2, 3])
        XCTAssertThrowsError(try Packet(decrypting: runt, with: cipher)) { error in
            XCTAssertEqual(error as? WireError, .packetTooShort(3))
        }
        // One that does not authenticate.
        XCTAssertThrowsError(try Packet(decrypting: [UInt8](repeating: 0, count: 40), with: cipher)) { error in
            XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed)
        }
    }

    /// The whole path of one instruction: fragments, packets, datagrams, and back.
    func testInstructionThroughDatagrams() throws {
        let cipher = try MoshCipher(key: .random())
        var generator = SystemRandomNumberGenerator()
        let diff = HostMessage(instructions: [
            .echoAck(3),
            .resize(width: 132, height: 50),
            .hostBytes((0..<5000).map { _ in UInt8.random(in: 0...255, using: &generator) }),
        ]).serialized()
        let instruction = Instruction(oldNum: 4, newNum: 5, ackNum: 3, throwawayNum: 2, diff: diff,
                                      chaff: Instruction.makeChaff())
        let budget = WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 12, contentsBudget: budget)
        XCTAssertGreaterThan(fragments.count, 3)

        var seq: UInt64 = 100
        var datagrams: [[UInt8]] = []
        for fragment in fragments {
            let packet = Packet(seq: seq, direction: .toClient, timestamp: Timestamp16.now(milliseconds: 123_456 + seq),
                                timestampReply: Timestamp16.none, payload: fragment.serialized())
            seq += 1
            let datagram = try packet.encrypted(with: cipher)
            // No datagram is larger than the MTU it was cut for, and all but the last fill it.
            XCTAssertLessThanOrEqual(datagram.count, WireConstants.ipv4DatagramMTU)
            datagrams.append(datagram)
        }
        for datagram in datagrams.dropLast() {
            XCTAssertEqual(datagram.count, WireConstants.ipv4DatagramMTU)
        }

        var assembly = FragmentAssembly()
        var received: Instruction? = nil
        for datagram in datagrams.shuffled() {
            let packet = try Packet(decrypting: datagram, with: cipher)
            XCTAssertEqual(packet.direction, .toClient)
            if try assembly.add(try Fragment(serialized: packet.payload)) {
                received = try assembly.takeInstruction()
            }
        }
        XCTAssertEqual(received, instruction)
        XCTAssertEqual(try HostMessage(serialized: try XCTUnwrap(received).diff).instructions.count, 3)
    }

    // MARK: Timestamps

    func testTimestamp16() {
        XCTAssertEqual(Timestamp16.none, 0xFFFF)
        XCTAssertEqual(Timestamp16.now(milliseconds: 0), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 1), 1)
        XCTAssertEqual(Timestamp16.now(milliseconds: 65534), 65534)
        // 0xFFFF is reserved: mosh's timestamp16() bumps it, and the uint16 wraps to 0.
        XCTAssertEqual(Timestamp16.now(milliseconds: 65535), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 65536), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 65537), 1)
        XCTAssertEqual(Timestamp16.now(milliseconds: 3 * 65536 + 65535), 0)
        XCTAssertEqual(Timestamp16.now(milliseconds: 1_700_000_000_123), UInt16(1_700_000_000_123 % 65536))
        XCTAssertEqual(Timestamp16.now(milliseconds: UInt64.max), 0)
        for ms: UInt64 in stride(from: 0, to: 200_000, by: 7) {
            XCTAssertNotEqual(Timestamp16.now(milliseconds: ms), Timestamp16.none)
        }
    }

    func testTimestampDifference() {
        // mosh: int diff = tsnew - tsold; if ( diff < 0 ) diff += 65536;
        func reference(_ new: UInt16, _ old: UInt16) -> UInt16 {
            var diff = Int(new) - Int(old)
            if diff < 0 { diff += 65536 }
            return UInt16(diff)
        }
        XCTAssertEqual(Timestamp16.difference(100, 40), 60)
        XCTAssertEqual(Timestamp16.difference(40, 40), 0)
        XCTAssertEqual(Timestamp16.difference(5, 65530), 11)       // the clock wrapped
        XCTAssertEqual(Timestamp16.difference(0, 65535), 1)
        XCTAssertEqual(Timestamp16.difference(40, 100), 65476)     // "new" is older: a large value, ignored above 5000
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<10_000 {
            let new = UInt16.random(in: 0...UInt16.max, using: &generator)
            let old = UInt16.random(in: 0...UInt16.max, using: &generator)
            XCTAssertEqual(Timestamp16.difference(new, old), reference(new, old))
        }
    }

    // MARK: Constants (network.h, crypto.h, transportfragment.h of mosh 1.4.0)

    func testWireConstants() {
        XCTAssertEqual(WireConstants.protocolVersion, 2)                // MOSH_PROTOCOL_VERSION
        XCTAssertEqual(WireConstants.defaultSendMTU, 500)               // DEFAULT_SEND_MTU
        XCTAssertEqual(WireConstants.defaultIPv4MTU, 1280)              // DEFAULT_IPV4_MTU
        XCTAssertEqual(WireConstants.defaultIPv6MTU, 1280)              // DEFAULT_IPV6_MTU
        XCTAssertEqual(WireConstants.ipv4HeaderLength, 28)              // IPV4_HEADER_LEN = 20 + 8
        XCTAssertEqual(WireConstants.ipv6HeaderLength, 64)              // IPV6_HEADER_LEN = 40 + 16 + 8
        XCTAssertEqual(WireConstants.ipv4DatagramMTU, 1252)             // set_MTU( AF_INET )
        XCTAssertEqual(WireConstants.ipv6DatagramMTU, 1216)             // set_MTU( AF_INET6 )
        XCTAssertEqual(WireConstants.connectionAddedBytes, 12)          // Connection::ADDED_BYTES = 8 + 4
        XCTAssertEqual(WireConstants.sessionAddedBytes, 16)             // Crypto::Session::ADDED_BYTES
        XCTAssertEqual(WireConstants.fragmentHeaderLength, 10)          // Fragment::frag_header_len
        XCTAssertEqual(WireConstants.datagramOverhead, 38)
        XCTAssertEqual(WireConstants.receiveMTU, 2048)                  // Crypto::Session::RECEIVE_MTU
        // Fragment contents per datagram: MTU - 12 - 16 (send_in_fragments) - 10 (make_fragments).
        XCTAssertEqual(WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU), 1214)
        XCTAssertEqual(WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv6DatagramMTU), 1178)
        XCTAssertEqual(WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.defaultSendMTU), 462)
        // The nonce is counted in Connection::ADDED_BYTES, the tag in Session::ADDED_BYTES.
        XCTAssertEqual(MoshCipher.overhead + Packet.headerLength + Fragment.headerLength, WireConstants.datagramOverhead)
    }
}
