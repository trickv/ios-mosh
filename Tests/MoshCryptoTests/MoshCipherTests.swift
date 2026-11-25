import XCTest
import MoshTestSupport
@testable import MoshCrypto

/// mosh's datagram encryption. The round-trip test follows src/tests/encrypt-decrypt.cc.
final class MoshCipherTests: XCTestCase {
    private func randomBytes(_ count: Int, using generator: inout SystemRandomNumberGenerator) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// encrypt-decrypt.cc: sessions with a random key and a random first nonce, messages of
    /// random length below 2048 - 16, and now and then a random buffer that must not decrypt.
    /// (Fewer sessions than mosh's 64 x 256, to keep a debug build quick.)
    func testRoundTripsLikeMoshEncryptDecrypt() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<8 {
            let key = Base64Key.random()
            let encryption = try MoshCipher(key: key)
            let decryption = try MoshCipher(key: try Base64Key(printable: key.printable))
            var nonceValue = UInt64.random(in: 0...(UInt64.max - 64), using: &generator)
            for _ in 0..<48 {
                let direction: Direction = (nonceValue >> 63) == 1 ? .toClient : .toServer
                let seq = nonceValue & MoshCipher.maxSequence
                let plaintext = randomBytes(Int.random(in: 0..<(2048 - 16), using: &generator), using: &generator)

                let datagram = try encryption.encrypt(seq: seq, direction: direction, plaintext: plaintext)
                XCTAssertEqual(datagram.count, plaintext.count + 24)

                let opened = try decryption.decrypt(datagram)
                XCTAssertEqual(opened.direction, direction)
                XCTAssertEqual(opened.seq, seq)
                XCTAssertEqual(opened.plaintext, plaintext)

                nonceValue += 1
                if UInt8.random(in: 0...255, using: &generator) % 16 == 0 {
                    let bad = randomBytes(Int.random(in: 0..<(2048 - 16), using: &generator), using: &generator)
                    XCTAssertThrowsError(try decryption.decrypt(bad))
                }
            }
        }
    }

    /// The layout on the wire: big-endian nonce, then exactly what OCB3 gives for the 12-byte nonce
    /// "four zero bytes + those eight" and no associated data.
    func testDatagramLayout() throws {
        let key = try Base64Key(bytes: bytes(hex: "000102030405060708090a0b0c0d0e0f"))
        let cipher = try MoshCipher(key: key)
        let ocb = try OCB3(key: key.bytes)
        let plaintext = Array("hello, mosh".utf8)

        let toServer = try cipher.encrypt(seq: 0x0102030405060708, direction: .toServer, plaintext: plaintext)
        XCTAssertEqual(hex(toServer[0..<8]), "0102030405060708")
        XCTAssertEqual(
            Array(toServer[8...]),
            try ocb.seal(nonce: bytes(hex: "000000000102030405060708"), plaintext: plaintext))

        let toClient = try cipher.encrypt(seq: 0x0102030405060708, direction: .toClient, plaintext: plaintext)
        XCTAssertEqual(hex(toClient[0..<8]), "8102030405060708")
        XCTAssertEqual(
            Array(toClient[8...]),
            try ocb.seal(nonce: bytes(hex: "000000008102030405060708"), plaintext: plaintext))

        let first = try cipher.encrypt(seq: 0, direction: .toServer, plaintext: [])
        XCTAssertEqual(first.count, 24)
        XCTAssertEqual(hex(first[0..<8]), "0000000000000000")
        // The first mosh vector's key, a zero nonce and no data: the tag alone.
        XCTAssertEqual(Array(first[8...]), try ocb.seal(nonce: [UInt8](repeating: 0, count: 12), plaintext: []))

        let last = try cipher.encrypt(seq: MoshCipher.maxSequence, direction: .toClient, plaintext: [])
        XCTAssertEqual(hex(last[0..<8]), "ffffffffffffffff")
        let opened = try cipher.decrypt(last)
        XCTAssertEqual(opened.seq, MoshCipher.maxSequence)
        XCTAssertEqual(opened.direction, .toClient)
    }

    func testSequenceMustFitIn63Bits() throws {
        let cipher = try MoshCipher(key: .random())
        XCTAssertThrowsError(try cipher.encrypt(seq: 1 << 63, direction: .toServer, plaintext: [])) { error in
            XCTAssertEqual(error as? MoshCryptoError, .sequenceOutOfRange(1 << 63))
        }
        XCTAssertThrowsError(try cipher.encrypt(seq: .max, direction: .toClient, plaintext: [1]))
    }

    func testTamperedDatagramIsRejected() throws {
        let cipher = try MoshCipher(key: .random())
        let datagram = try cipher.encrypt(seq: 7, direction: .toServer, plaintext: Array("some payload bytes".utf8))
        // Any single flipped bit: in the nonce (sequence or direction), the ciphertext or the tag.
        for position in 0..<datagram.count {
            for bit in 0..<8 {
                var bad = datagram
                bad[position] ^= UInt8(1) << UInt8(bit)
                XCTAssertThrowsError(try cipher.decrypt(bad), "byte \(position) bit \(bit)") { error in
                    XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed)
                }
            }
        }
        // Extra bytes at the end.
        XCTAssertThrowsError(try cipher.decrypt(datagram + [0]))
        // The original still decrypts.
        XCTAssertEqual(try cipher.decrypt(datagram).plaintext, Array("some payload bytes".utf8))
    }

    func testTruncatedDatagramIsRejected() throws {
        let cipher = try MoshCipher(key: .random())
        let datagram = try cipher.encrypt(seq: 1, direction: .toClient, plaintext: Array("0123456789abcdefXYZ".utf8))
        for length in 0..<datagram.count {
            let truncated = Array(datagram[0..<length])
            XCTAssertThrowsError(try cipher.decrypt(truncated), "length \(length)") { error in
                if length < 24 {
                    // mosh: "Ciphertext must contain nonce and tag."
                    XCTAssertEqual(error as? MoshCryptoError, .datagramTooShort(length))
                } else {
                    XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed)
                }
            }
        }
        // Cut at the front instead.
        XCTAssertThrowsError(try cipher.decrypt(Array(datagram.dropFirst())))
        XCTAssertThrowsError(try cipher.decrypt([]))
        // 24 bytes of zeros: long enough, but not authentic.
        XCTAssertThrowsError(try cipher.decrypt([UInt8](repeating: 0, count: 24))) { error in
            XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed)
        }
    }

    func testWrongKeyIsRejected() throws {
        let right = try MoshCipher(key: try Base64Key(printable: "AQIECBAgQID+/fv379+/fw"))
        // One key bit different.
        let wrong = try MoshCipher(key: try Base64Key(printable: "AQIECBAgQID+/fv379+/fg"))
        for length in [0, 1, 15, 16, 17, 100] {
            let plaintext = [UInt8](repeating: 0x61, count: length)
            let datagram = try right.encrypt(seq: 3, direction: .toServer, plaintext: plaintext)
            XCTAssertEqual(try right.decrypt(datagram).plaintext, plaintext)
            XCTAssertThrowsError(try wrong.decrypt(datagram)) { error in
                XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed)
            }
        }
    }

    func testConstantsAreMoshs() {
        XCTAssertEqual(MoshCipher.nonceLength, 8)
        XCTAssertEqual(MoshCipher.tagLength, 16)          // Crypto::Session::ADDED_BYTES
        XCTAssertEqual(MoshCipher.minimumDatagramLength, 24)
        XCTAssertEqual(MoshCipher.overhead, 24)
        XCTAssertEqual(MoshCipher.receiveMTU, 2048)       // Crypto::Session::RECEIVE_MTU
        XCTAssertEqual(MoshCipher.maxSequence, 0x7FFF_FFFF_FFFF_FFFF)
    }
}
