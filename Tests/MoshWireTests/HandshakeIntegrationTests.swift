import XCTest
import Foundation
import MoshCrypto
import MoshTestSupport
import MoshWire

// MoshServerProcess exists on Linux and macOS only (it needs Foundation.Process).
#if os(Linux) || os(macOS)

/// M1's exit test: the handshake against a real mosh-server, in this process.
///
/// The client side is put together from MoshCrypto and MoshWire alone, over a plain UDP socket;
/// there is no transport yet. Skipped where mosh-server is not installed.
final class HandshakeIntegrationTests: XCTestCase {
    private func milliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    /// The first instruction of a mosh client (stmclient.cc `main_init`, transportsender-impl.h):
    /// state 0 is empty and already "sent"; state 1 adds a Resize with the window size. So the
    /// first datagram says old_num 0, new_num 1, ack_num 0, throwaway_num 0, and its diff is a
    /// UserMessage with one resize. mosh's fragmenter numbers its first instruction 1.
    private func firstClientInstruction(width: Int32, height: Int32) -> Instruction {
        Instruction(
            oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0,
            diff: UserMessage(instructions: [.resize(width: width, height: height)]).serialized(),
            chaff: Instruction.makeChaff())
    }

    func testFirstServerDatagramDecryptsAndDecodes() throws {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        // The command starts when the server hears from its first client.
        let server = try MoshServerProcess(command: ["/bin/sh", "-c", "printf hello-m1; sleep 30"])
        defer { server.stop() }

        let cipher = try MoshCipher(key: try Base64Key(printable: server.key))
        let socket = try UDPTestSocket(port: server.port)
        defer { socket.close() }

        // The server's terminal starts at 80 x 24; another size makes it answer with a Resize.
        let instruction = firstClientInstruction(width: 100, height: 30)
        let budget = WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: budget)
        XCTAssertEqual(fragments.count, 1)

        var nextSeq: UInt64 = 0
        var lastSentTimestamp: UInt16 = 0
        func send() throws {
            for fragment in fragments {
                lastSentTimestamp = Timestamp16.now(milliseconds: milliseconds())
                let packet = Packet(seq: nextSeq, direction: .toServer, timestamp: lastSentTimestamp,
                                    timestampReply: Timestamp16.none, payload: fragment.serialized())
                nextSeq += 1 // never the same sequence number twice under one key
                let datagram = try packet.encrypted(with: cipher)
                XCTAssertLessThanOrEqual(datagram.count, WireConstants.ipv4DatagramMTU)
                try socket.send(datagram)
            }
        }
        try send()

        var assembly = FragmentAssembly()
        var datagramsReceived = 0
        var firstInstruction: Instruction? = nil
        var firstMessage: HostMessage? = nil
        var sawResize = false
        var sawMarker = false
        var allHostBytes: [UInt8] = []
        let deadline = Date().addingTimeInterval(15)
        var lastSend = Date()

        while Date() < deadline, !(sawResize && sawMarker) {
            guard let datagram = try socket.receive(timeoutMilliseconds: 250) else {
                // Nothing yet. Loopback does not lose datagrams, but a loaded machine may be slow:
                // say it again every second until the server has answered once.
                if firstInstruction == nil, Date().timeIntervalSince(lastSend) >= 1 {
                    try send()
                    lastSend = Date()
                }
                continue
            }
            datagramsReceived += 1

            // Every datagram from the server must authenticate under the session key.
            let packet = try Packet(decrypting: datagram, with: cipher)
            XCTAssertEqual(packet.direction, .toClient)
            let fragment = try Fragment(serialized: packet.payload)

            if datagramsReceived == 1 {
                XCTAssertEqual(packet.seq, 0, "the server's first datagram has sequence number 0")
                XCTAssertNotEqual(packet.timestamp, Timestamp16.none)
                // The server answers our timestamp, advanced by the time it held it (under a second,
                // or it sends "none").
                if packet.timestampReply != Timestamp16.none {
                    XCTAssertLessThan(Timestamp16.difference(packet.timestampReply, lastSentTimestamp), 1000)
                }
                // The first instruction is small: one fragment, final.
                XCTAssertEqual(fragment.fragmentNum, 0)
                XCTAssertTrue(fragment.isFinal)
            }

            guard try assembly.add(fragment) else { continue }
            let received = try assembly.takeInstruction()
            let message = try HostMessage(serialized: received.diff)

            if firstInstruction == nil {
                XCTAssertEqual(datagramsReceived, 1, "the first datagram is a whole instruction")
                firstInstruction = received
                firstMessage = message
            }
            for hostInstruction in message.instructions {
                switch hostInstruction {
                case .resize(let width, let height):
                    if width == 100 && height == 30 { sawResize = true }
                case .hostBytes(let bytes):
                    allHostBytes += bytes
                    if String(decoding: allHostBytes, as: UTF8.self).contains("hello-m1") { sawMarker = true }
                case .echoAck:
                    break
                }
            }
        }

        // The first server datagram decrypted and decoded.
        let first = try XCTUnwrap(firstInstruction, "no datagram from the server within 15 s")
        XCTAssertNotNil(firstMessage)
        XCTAssertEqual(first.protocolVersion, WireConstants.protocolVersion)
        XCTAssertEqual(first.oldNum, 0, "based on the empty state")
        XCTAssertGreaterThan(first.newNum, 0)
        // It acknowledges our state 1: the server decrypted, reassembled, expanded and decoded our
        // instruction, so it accepted our encryption and our encoding.
        XCTAssertEqual(first.ackNum, 1)
        XCTAssertEqual(first.throwawayNum, 0)
        XCTAssertLessThanOrEqual(first.chaff.count, Instruction.maxChaffLength)
        // And it acted on the diff inside: it resized its terminal to what we asked for ...
        XCTAssertTrue(sawResize, "no Resize to 100 x 30 from the server")
        // ... and ran the command, whose output came back as host bytes.
        XCTAssertTrue(sawMarker, "command output not seen; host bytes so far: \(String(decoding: allHostBytes, as: UTF8.self).debugDescription)")
        XCTAssertTrue(server.isAlive)
    }

    /// The other side of "a reply proves it accepted our encryption": under a wrong key the server
    /// says nothing at all.
    func testServerIgnoresDatagramsUnderAWrongKey() throws {
        guard MoshServerProcess.locate() != nil else { throw XCTSkip("mosh-server is not in PATH") }
        let server = try MoshServerProcess(command: ["/bin/sh", "-c", "sleep 30"])
        defer { server.stop() }

        var wrongKeyBytes = try Base64Key(printable: server.key).bytes
        wrongKeyBytes[0] ^= 0x01
        let wrongCipher = try MoshCipher(key: try Base64Key(bytes: wrongKeyBytes))
        let socket = try UDPTestSocket(port: server.port)
        defer { socket.close() }

        let fragments = try Fragmenter.makeFragments(
            instruction: firstClientInstruction(width: 80, height: 24), id: 1,
            contentsBudget: WireConstants.fragmentContentsBudget(datagramMTU: WireConstants.ipv4DatagramMTU))
        let packet = Packet(seq: 0, direction: .toServer, timestamp: Timestamp16.now(milliseconds: milliseconds()),
                            timestampReply: Timestamp16.none, payload: fragments[0].serialized())
        try socket.send(try packet.encrypted(with: wrongCipher))
        XCTAssertNil(try socket.receive(timeoutMilliseconds: 700))
        XCTAssertTrue(server.isAlive)

        // The same server still answers the right key (and the wrong datagram did not use up
        // sequence number 0: it never authenticated).
        let cipher = try MoshCipher(key: try Base64Key(printable: server.key))
        try socket.send(try packet.encrypted(with: cipher))
        let reply = try XCTUnwrap(try socket.receive(timeoutMilliseconds: 5000), "no reply under the right key")
        XCTAssertEqual(try Packet(decrypting: reply, with: cipher).direction, .toClient)
    }
}

#endif
