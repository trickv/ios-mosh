import MoshBootstrap
import MoshKeys
import XCTest

final class ServerKexInitTests: XCTestCase {
    /// Builds what a server sends first: its identification line and a KEXINIT packet.
    private func stream(
        banner: String = "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20\r\n",
        kex: String = "sntrup761x25519-sha512@openssh.com,curve25519-sha256,ecdh-sha2-nistp256",
        hostKey: String = "rsa-sha2-512,rsa-sha2-256,ssh-ed25519",
        c2s: String = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com",
        s2c: String = "aes128-ctr,aes256-gcm@openssh.com",
        messageType: UInt8 = 20, padding: Int = 6
    ) -> [UInt8] {
        var payload = SSHWireWriter()
        var bytes: [UInt8] = [messageType] + Array(repeating: 0xab, count: 16)
        for list in [kex, hostKey, c2s, s2c, "hmac-sha2-256", "hmac-sha2-256", "none", "none", "", ""] {
            payload = SSHWireWriter()
            payload.writeString(list)
            bytes += payload.bytes
        }
        bytes += [0, 0, 0, 0, 0]  // first_kex_packet_follows, reserved
        var packet = SSHWireWriter()
        packet.writeUInt32(UInt32(1 + bytes.count + padding))
        return Array(banner.utf8) + packet.bytes + [UInt8(padding)] + bytes + Array(repeating: 0, count: padding)
    }

    func testParsesIdentificationAndLists() {
        let expected = ServerAlgorithms(
            identification: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20",
            keyExchange: ["sntrup761x25519-sha512@openssh.com", "curve25519-sha256", "ecdh-sha2-nistp256"],
            hostKey: ["rsa-sha2-512", "rsa-sha2-256", "ssh-ed25519"],
            encryptionClientToServer: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"],
            encryptionServerToClient: ["aes128-ctr", "aes256-gcm@openssh.com"])
        XCTAssertEqual(ServerKexInitParser.parse(stream()), .parsed(expected))
        XCTAssertNil(expected.mismatch)
        // More data after the packet (the next packet) does not matter.
        XCTAssertEqual(ServerKexInitParser.parse(stream() + [1, 2, 3, 4, 5]), .parsed(expected))
    }

    func testEveryPrefixNeedsMoreData() {
        let bytes = stream()
        for length in 0..<bytes.count {
            XCTAssertEqual(ServerKexInitParser.parse(Array(bytes[..<length])), .needMoreData, "prefix \(length)")
        }
    }

    func testIncrementalFeeding() {
        let bytes = stream(hostKey: "rsa-sha2-512,rsa-sha2-256")
        for chunk in [1, 7, 64, bytes.count] {
            var parser = ServerKexInitParser()
            var index = 0
            while index < bytes.count {
                let end = min(index + chunk, bytes.count)
                parser.feed(bytes[index..<end])
                index = end
            }
            guard case .parsed(let algorithms) = parser.state else { return XCTFail("chunk \(chunk): \(parser.state)") }
            XCTAssertEqual(algorithms.hostKey, ["rsa-sha2-512", "rsa-sha2-256"])
            XCTAssertEqual(algorithms.mismatch, .hostKey)
            // Further data is ignored once it is done.
            XCTAssertEqual(parser.feed([0xff, 0xff]), parser.state)
        }
    }

    func testLinesBeforeTheIdentificationAreSkipped() {
        // RFC 4253 section 4.2 allows other lines first; a bare LF line end is tolerated.
        let bytes = stream(banner: "Welcome to the bastion\r\nNo trespassing\nSSH-2.0-dropbear_2022.83\n")
        guard case .parsed(let algorithms) = ServerKexInitParser.parse(bytes) else { return XCTFail() }
        XCTAssertEqual(algorithms.identification, "SSH-2.0-dropbear_2022.83")
    }

    func testEmptyListsAndMismatches() {
        guard case .parsed(let none) = ServerKexInitParser.parse(stream(kex: "", hostKey: "", c2s: "", s2c: "")) else {
            return XCTFail()
        }
        XCTAssertEqual(none.hostKey, [])
        XCTAssertEqual(none.mismatch, .hostKey)
        guard case .parsed(let oldKex) = ServerKexInitParser.parse(stream(kex: "diffie-hellman-group1-sha1")) else {
            return XCTFail()
        }
        XCTAssertEqual(oldKex.mismatch, .keyExchange)
        guard case .parsed(let oldCipher) = ServerKexInitParser.parse(stream(c2s: "aes128-cbc,3des-cbc")) else {
            return XCTFail()
        }
        XCTAssertEqual(oldCipher.mismatch, .encryption)
    }

    func testRejectsWhatIsNotAKexInit() {
        XCTAssertEqual(ServerKexInitParser.parse(stream(messageType: 21)), .invalid)
        // An absurd packet length.
        XCTAssertEqual(
            ServerKexInitParser.parse(Array("SSH-2.0-x\r\n".utf8) + [0x7f, 0xff, 0xff, 0xff, 4]), .invalid)
        XCTAssertEqual(ServerKexInitParser.parse(Array("SSH-2.0-x\r\n".utf8) + [0, 0, 0, 1, 0]), .invalid)
        // Padding longer than the packet.
        XCTAssertEqual(
            ServerKexInitParser.parse(Array("SSH-2.0-x\r\n".utf8) + [0, 0, 0, 20, 200] + Array(repeating: 20, count: 19)),
            .invalid)
        // A name-list that runs past the payload.
        var truncated = stream()
        let lengthOffset = "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20\r\n".utf8.count + 4 + 1 + 17
        truncated[lengthOffset] = 0x7f
        XCTAssertEqual(ServerKexInitParser.parse(truncated), .invalid)
        // An HTTP server, or noise without end.
        var parser = ServerKexInitParser()
        XCTAssertEqual(parser.feed(Array(repeating: UInt8(ascii: "x"), count: 9000)), .invalid)
        parser = ServerKexInitParser()
        for _ in 0..<700 { parser.feed(Array("HTTP/1.1 400 Bad Request\r\n".utf8) + Array(repeating: 0x41, count: 80)) }
        XCTAssertEqual(parser.state, .invalid)
    }

    func testClientListsAreTheOnesTheLibraryOffers() {
        // swift-nio-ssh 0.15.1. The RSA-only integration test proves the host key list against
        // the real library.
        XCTAssertTrue(ClientAlgorithms.hostKey.contains("ssh-ed25519"))
        XCTAssertFalse(ClientAlgorithms.hostKey.contains { $0.contains("rsa") })
        XCTAssertTrue(ClientAlgorithms.keyExchange.contains("curve25519-sha256"))
        XCTAssertEqual(ClientAlgorithms.encryption, ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"])
    }
}
