import XCTest
import MoshTestSupport
@testable import MoshCrypto

/// RFC 7253 appendix A, and everything in mosh 1.4.0's src/tests/ocb-aes.cc.
final class OCB3Tests: XCTestCase {
    // MARK: RFC 7253 appendix A

    /// "K : 000102030405060708090A0B0C0D0E0F", tag length 128 bits.
    private let rfcKey = "000102030405060708090A0B0C0D0E0F"

    /// The 16 (N, A, P, C) tuples of RFC 7253 appendix A, copied from the RFC text.
    private let rfcVectors: [(n: String, a: String, p: String, c: String)] = [
        ("BBAA99887766554433221100",
         "",
         "",
         "785407BFFFC8AD9EDCC5520AC9111EE6"),
        ("BBAA99887766554433221101",
         "0001020304050607",
         "0001020304050607",
         "6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009"),
        ("BBAA99887766554433221102",
         "0001020304050607",
         "",
         "81017F8203F081277152FADE694A0A00"),
        ("BBAA99887766554433221103",
         "",
         "0001020304050607",
         "45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9"),
        ("BBAA99887766554433221104",
         "000102030405060708090A0B0C0D0E0F",
         "000102030405060708090A0B0C0D0E0F",
         "571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5 701C1CCEC8FC3358"),
        ("BBAA99887766554433221105",
         "000102030405060708090A0B0C0D0E0F",
         "",
         "8CF761B6902EF764462AD86498CA6B97"),
        ("BBAA99887766554433221106",
         "",
         "000102030405060708090A0B0C0D0E0F",
         "5CE88EC2E0692706A915C00AEB8B2396F40E1C743F52436B DF06D8FA1ECA343D"),
        ("BBAA99887766554433221107",
         "000102030405060708090A0B0C0D0E0F1011121314151617",
         "000102030405060708090A0B0C0D0E0F1011121314151617",
         "1CA2207308C87C010756104D8840CE1952F09673A448A122 C92C62241051F57356D7F3C90BB0E07F"),
        ("BBAA99887766554433221108",
         "000102030405060708090A0B0C0D0E0F1011121314151617",
         "",
         "6DC225A071FC1B9F7C69F93B0F1E10DE"),
        ("BBAA99887766554433221109",
         "",
         "000102030405060708090A0B0C0D0E0F1011121314151617",
         "221BD0DE7FA6FE993ECCD769460A0AF2D6CDED0C395B1C3C E725F32494B9F914D85C0B1EB38357FF"),
        ("BBAA9988776655443322110A",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F",
         "BD6F6C496201C69296C11EFD138A467ABD3C707924B964DE AFFC40319AF5A48540FBBA186C5553C68AD9F592A79A4240"),
        ("BBAA9988776655443322110B",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F",
         "",
         "FE80690BEE8A485D11F32965BC9D2A32"),
        ("BBAA9988776655443322110C",
         "",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F",
         "2942BFC773BDA23CABC6ACFD9BFD5835BD300F0973792EF4 6040C53F1432BCDFB5E1DDE3BC18A5F840B52E653444D5DF"),
        ("BBAA9988776655443322110D",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F2021222324252627",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F2021222324252627",
         """
         D5CA91748410C1751FF8A2F618255B68A0A12E093FF45460
         6E59F9C1D0DDC54B65E8628E568BAD7AED07BA06A4A69483
         A7035490C5769E60
         """),
        ("BBAA9988776655443322110E",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F2021222324252627",
         "",
         "C5CD9D1850C141E358649994EE701B68"),
        ("BBAA9988776655443322110F",
         "",
         "000102030405060708090A0B0C0D0E0F1011121314151617 18191A1B1C1D1E1F2021222324252627",
         """
         4412923493C57D5DE0D700F753CCE0D1D2D95060122E9F15
         A5DDBFC5787E50B5CC55EE507BCB084E479AD363AC366B95
         A98CA5F3000B1479
         """),
    ]

    func testRFC7253SampleVectors() throws {
        XCTAssertEqual(rfcVectors.count, 16)
        let ocb = try OCB3(key: bytes(hex: rfcKey))
        for (index, vector) in rfcVectors.enumerated() {
            let nonce = bytes(hex: vector.n)
            let associated = bytes(hex: vector.a)
            let plaintext = bytes(hex: vector.p)
            let ciphertext = bytes(hex: vector.c)
            XCTAssertEqual(ciphertext.count, plaintext.count + 16, "vector \(index)")

            let sealed = try ocb.seal(nonce: nonce, plaintext: plaintext, associatedData: associated)
            XCTAssertEqual(hex(sealed), hex(ciphertext), "encrypt, vector \(index)")

            let opened = try ocb.open(nonce: nonce, ciphertext: ciphertext, associatedData: associated)
            XCTAssertEqual(hex(opened), hex(plaintext), "decrypt, vector \(index)")
        }
    }

    /// "several internal values generated during the OCB-ENCRYPT computation for the last test
    /// vector listed above".
    func testRFC7253InternalValues() throws {
        let ocb = try OCB3(key: bytes(hex: rfcKey))
        XCTAssertEqual(hex(ocb.lStar.bytes), "c6a13b37878f5b826f4f8162a1c8d879")
        XCTAssertEqual(hex(ocb.lDollar.bytes), "8d42766f0f1eb704de9f02c54391b075")
        XCTAssertEqual(hex(ocb.l[0].bytes), "1a84ecde1e3d6e09bd3e058a8723606d")
        XCTAssertEqual(hex(ocb.l[1].bytes), "3509d9bc3c7adc137a7c0b150e46c0da")
        let offset0 = try ocb.initialOffset(nonce: bytes(hex: "BBAA9988776655443322110F"))
        XCTAssertEqual(hex(offset0.bytes), "587ef72716eab6dd3219f8092d517d69")
        let offset1 = offset0 ^ ocb.l[0]
        XCTAssertEqual(hex(offset1.bytes), "42fa1bf908d7d8d48f27fd83aa721d04")
        let offset2 = offset1 ^ ocb.l[1]
        XCTAssertEqual(hex(offset2.bytes), "77f3c24534ad04c7f55bf696a434ddde")
        let offsetStar = offset2 ^ ocb.lStar
        XCTAssertEqual(hex(offsetStar.bytes), "b152f972b3225f459a1477f405fc05a7")
    }

    /// The iterative algorithm at the end of RFC 7253 appendix A, for AEAD_AES_128_OCB_TAGLEN128.
    func testRFC7253IterativeAlgorithm() throws {
        // K = zeros(KEYLEN-8) || num2str(TAGLEN,8)
        var key = [UInt8](repeating: 0, count: 16)
        key[15] = 128
        let ocb = try OCB3(key: key)

        func nonce(_ value: Int) -> [UInt8] {
            // num2str(value, 96)
            var out = [UInt8](repeating: 0, count: 12)
            out[10] = UInt8(value >> 8)
            out[11] = UInt8(value & 0xFF)
            return out
        }

        var c: [UInt8] = []
        for i in 0..<128 {
            let s = [UInt8](repeating: 0, count: i)
            c += try ocb.seal(nonce: nonce(3 * i + 1), plaintext: s, associatedData: s)
            c += try ocb.seal(nonce: nonce(3 * i + 2), plaintext: s, associatedData: [])
            c += try ocb.seal(nonce: nonce(3 * i + 3), plaintext: [], associatedData: s)
        }
        XCTAssertEqual(c.count, 22400)
        let output = try ocb.seal(nonce: nonce(385), plaintext: [], associatedData: c)
        XCTAssertEqual(hex(output), "67e944d23256c5e0b6c61fa22fdf1ea2")
    }

    // MARK: mosh src/tests/ocb-aes.cc

    /// `test_all_vectors`: each vector encrypts to the expected ciphertext, decrypts back, and 64
    /// single-bit corruptions of the ciphertext are all rejected.
    func testMoshVectors() throws {
        XCTAssertEqual(moshOCBVectors.count, 21)
        var generator = SystemRandomNumberGenerator()
        for (index, vector) in moshOCBVectors.enumerated() {
            let ocb = try OCB3(key: bytes(hex: vector.key))
            let nonce = bytes(hex: vector.nonce)
            let associated = bytes(hex: vector.associatedData)
            let plaintext = bytes(hex: vector.plaintext)
            let ciphertext = bytes(hex: vector.ciphertext)
            XCTAssertEqual(nonce.count, 12)
            XCTAssertEqual(ciphertext.count, plaintext.count + 16, "vector \(index)")

            let sealed = try ocb.seal(nonce: nonce, plaintext: plaintext, associatedData: associated)
            XCTAssertEqual(hex(sealed), hex(ciphertext), "encrypt, vector \(index)")

            let opened = try ocb.open(nonce: nonce, ciphertext: ciphertext, associatedData: associated)
            XCTAssertEqual(hex(opened), hex(plaintext), "decrypt, vector \(index)")

            // "Try some bad ciphertexts and make sure they don't validate."
            for _ in 0..<64 {
                var bad = ciphertext
                bad[Int.random(in: 0..<bad.count, using: &generator)] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &generator)
                XCTAssertThrowsError(try ocb.open(nonce: nonce, ciphertext: bad, associatedData: associated)) { error in
                    XCTAssertEqual(error as? MoshCryptoError, .authenticationFailed, "vector \(index)")
                }
            }
        }
    }

    /// `test_iterative`: the iterative test of draft-krovetz-ocb-03 (all-zero key, nonce = eleven
    /// zero bytes and the loop counter), which differs from the one in the final RFC.
    func testMoshIterative() throws {
        let ocb = try OCB3(key: [UInt8](repeating: 0, count: 16))
        var nonce = [UInt8](repeating: 0, count: 12)
        var accumulator: [UInt8] = []
        for i in 0..<128 {
            let s = [UInt8](repeating: 0, count: i)
            nonce[11] = UInt8(i)
            accumulator += try ocb.seal(nonce: nonce, plaintext: s, associatedData: s)
            accumulator += try ocb.seal(nonce: nonce, plaintext: s, associatedData: [])
            accumulator += try ocb.seal(nonce: nonce, plaintext: [], associatedData: s)
        }
        XCTAssertEqual(accumulator.count, 22400)
        nonce[11] = 0
        let output = try ocb.seal(nonce: nonce, plaintext: [], associatedData: accumulator)
        XCTAssertEqual(hex(output), "b2b41cbf9b05037da7f16c24a35c1c94")
    }

    // MARK: Edges

    func testEveryLengthRoundTripsAndRejectsCorruption() throws {
        let ocb = try OCB3(key: bytes(hex: "0F0E0D0C0B0A09080706050403020100"))
        let nonce = bytes(hex: "000000000102030405060708")
        for length in 0...100 {
            let plaintext = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
            let sealed = try ocb.seal(nonce: nonce, plaintext: plaintext)
            XCTAssertEqual(sealed.count, length + 16)
            XCTAssertEqual(try ocb.open(nonce: nonce, ciphertext: sealed), plaintext)
            // Every byte matters, the tag included.
            for position in 0..<sealed.count {
                var bad = sealed
                bad[position] ^= 0x01
                XCTAssertThrowsError(try ocb.open(nonce: nonce, ciphertext: bad))
            }
            // A different nonce or different associated data does not verify.
            var otherNonce = nonce
            otherNonce[11] ^= 0x40
            XCTAssertThrowsError(try ocb.open(nonce: otherNonce, ciphertext: sealed))
            XCTAssertThrowsError(try ocb.open(nonce: nonce, ciphertext: sealed, associatedData: [0]))
        }
    }

    func testRejectsBadSizes() throws {
        XCTAssertThrowsError(try OCB3(key: [UInt8](repeating: 0, count: 15))) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidKeyLength(15))
        }
        XCTAssertThrowsError(try OCB3(key: [UInt8](repeating: 0, count: 32)))
        let ocb = try OCB3(key: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try ocb.seal(nonce: [], plaintext: [1])) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidNonceLength(0))
        }
        XCTAssertThrowsError(try ocb.seal(nonce: [UInt8](repeating: 0, count: 16), plaintext: [1]))
        XCTAssertThrowsError(try ocb.open(nonce: [UInt8](repeating: 0, count: 12), ciphertext: [UInt8](repeating: 0, count: 15))) { error in
            XCTAssertEqual(error as? MoshCryptoError, .ciphertextTooShort(15))
        }
    }

    /// The L table index is the number of trailing zeros of the block number, so a text of more
    /// than 2^k blocks reaches L_k. 70 blocks reach L_6.
    func testLongTextUsesHigherLValues() throws {
        let ocb = try OCB3(key: bytes(hex: rfcKey))
        let nonce = bytes(hex: "BBAA99887766554433221100")
        let plaintext = (0..<(70 * 16 + 5)).map { UInt8(truncatingIfNeeded: $0) }
        let sealed = try ocb.seal(nonce: nonce, plaintext: plaintext, associatedData: plaintext)
        XCTAssertEqual(try ocb.open(nonce: nonce, ciphertext: sealed, associatedData: plaintext), plaintext)
    }
}
