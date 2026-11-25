import XCTest
import MoshTestSupport
import MoshCrypto

/// Known answers for long texts, from an independent implementation.
///
/// The RFC's and mosh's vectors stop at 512 bytes (32 blocks), which reaches the offset value L_5.
/// A full mosh datagram is 78 blocks and reaches L_6. These answers were produced once in the dev
/// container by a small C program that drives OpenSSL 3.0.13 (`EVP_aes_128_ocb`, 12-byte nonce,
/// 16-byte tag); the same program reproduced RFC 7253's second sample vector, which shows it uses
/// OpenSSL correctly. Inputs are made by rule, so only the outputs are stored:
///
///     key        a0 a1 ... af
///     nonce      00 00 00 00 14 15 ... 1b      (the shape of a mosh nonce)
///     plaintext  byte i = (7 i + 3) mod 256
///     associated byte i = (5 i + 1) mod 256
final class OCB3LongTextTests: XCTestCase {
    private let key = (0..<16).map { UInt8(0xA0 + $0) }
    private let nonce: [UInt8] = (0..<12).map { $0 < 4 ? 0 : UInt8(0x10 + $0) }

    private func plaintext(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    }

    private func associatedData(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) }
    }

    /// 1228 bytes: the plaintext of a full IPv4 mosh datagram (1252 - 8 - 16). Whole ciphertext.
    func testFullDatagramSizedText() throws {
        let ocb = try OCB3(key: key)
        let expected = bytes(hex: fullDatagramCiphertext + fullDatagramTag)
        let sealed = try ocb.seal(nonce: nonce, plaintext: plaintext(1228))
        XCTAssertEqual(hex(sealed), hex(expected))
        XCTAssertEqual(try ocb.open(nonce: nonce, ciphertext: expected), plaintext(1228))

        // The same through MoshCipher: this nonce is direction 0, sequence number 0x1415161718191a1b.
        let cipher = try MoshCipher(key: try Base64Key(bytes: key))
        let datagram = try cipher.encrypt(seq: 0x1415_1617_1819_1A1B, direction: .toServer, plaintext: plaintext(1228))
        XCTAssertEqual(datagram.count, 1252)
        XCTAssertEqual(hex(datagram), "1415161718191a1b" + hex(expected))
    }

    /// (plaintext length, associated data length, first 8 ciphertext bytes, last 8, tag)
    private let answers: [(Int, Int, String, String, String)] = [
        (1024, 0, "f374309343532c24", "2d991ac5e5a471bd", "b5b1b3d177a4e1a0a4bc29e338ab3e11"),
        (1039, 0, "f374309343532c24", "3f7cd0ce834c0199", "3c54125fddce3b3f1b6f744cae5a62b7"),
        (1040, 0, "f374309343532c24", "2aefa53b6f51b486", "2683a0539c0e4537a0816bfcc17b9c86"),
        (2024, 0, "f374309343532c24", "227bcd241e5e811b", "6832f13640dadf98862ecb39d492a80d"),
        (2048, 0, "f374309343532c24", "78d73dcd6d5edae3", "3b48b03dbf198905538a55fb567d912c"),
        (4101, 0, "f374309343532c24", "66fe6735df34e6ae", "c9ecdcc0b41973543557fde114adb10e"),
        (16384, 0, "f374309343532c24", "8e007181f537cb87", "c09ef9b584acb3e21fb8a1fe7655339e"),
        (70001, 0, "f374309343532c24", "e3f4d98c56c68fe3", "fc10fce82aba57f4882af8119cbecb91"),
        (100, 1300, "f374309343532c24", "fd1c87769ff042ed", "ec2fe553c5f29318a06d878ec9ffe29b"),
        (0, 4200, "", "", "bd781d4cb2f024942da5a0a40c37dd6c"),
        (333, 2049, "f374309343532c24", "0bcc0ea5c15ebf31", "5ed3f991d0357087dfae9ad97b6cfaff"),
    ]

    /// Lengths up to 70001 bytes (4376 blocks, up to L_12), with and without associated data.
    func testLongTexts() throws {
        let ocb = try OCB3(key: key)
        for (length, associatedLength, first, last, tag) in answers {
            let plain = plaintext(length)
            let associated = associatedData(associatedLength)
            let sealed = try ocb.seal(nonce: nonce, plaintext: plain, associatedData: associated)
            XCTAssertEqual(sealed.count, length + 16)
            XCTAssertEqual(hex(sealed.suffix(16)), tag, "tag, \(length) + \(associatedLength)")
            XCTAssertEqual(hex(sealed.prefix(min(8, length))), first, "start, \(length) + \(associatedLength)")
            XCTAssertEqual(hex(sealed.dropLast(16).suffix(8)), last, "end, \(length) + \(associatedLength)")
            XCTAssertEqual(try ocb.open(nonce: nonce, ciphertext: sealed, associatedData: associated), plain)
        }
    }

    private let fullDatagramTag = "734f7a7c4ccd623c2d72bb9aceebafa1"
    private let fullDatagramCiphertext = """
        f374309343532c247077f702b7ed1935d3c70aa750061e3c4136765ae0b243fb03ab96528f587d6c31746b58df38e425
        8fc114ffcc0c03c2b74b89130cb3f98985e3ffc8ea29dd74dcafdcd5b3d7af01b47e643c0072d5024df51247fd1c8776
        1fa13fb16cac53f1ee5ebadf0b3f63c649767955973e29ce4c00eeba88255ec0079fd6e1b104fb94084749ba66ac1feb
        eb53c698ef476e3583cda25ebc1ba947e3e1f556fbf5dd692dc8ff5180ec6af5ae34b8e33db832e68f1582077f8a4c46
        f7240f5c10674c65f80de2ea2c5c78f036dc2d26530bf8e923412d0605b715cc842c07c009e070baa1225d291b909cb6
        6e0035dd1dec952a74c3b7a6fbb69d5bcaab9a136a3177a09b96ab2aeba0f7925034ca33792e575938f1f674b786f93f
        eb4d8059a8a76300df097a0d24b475f679e277761d0e8ceb39680d0c7bdbf7835802a7c2bcb5df7083a3a5c983589d6a
        ea54bdb428bc8ca8553c4e827bb7818d010fb0193b60c4127b6fe22d651009f4e062bded5cb98ee1420eafbc3739997b
        fbfd4887153c7114f553a52ca6f15751ec912fa8fd4a356aa4badb111db03a054adb64c5adeabcc00203ab1b12890bf9
        334c3f170782e810312600a491f6799c71308bf361240e167d0bc578f1d6073cbc79dade680d9f589c16d9d935e93777
        1b0b1b7e195d4a83dc4a30a2f83698cb7f222e4d5be6ce3380aaf45da592a9e6a67d640e835e858680605c217de495a4
        787e20cd1a1e0b9eb89af4d52ad6ece1764dc0acd3981135220c9518b10a01fcfc231d8429e778a666dc22deafbb2b62
        411cfad8c4463fba55a6107282243ab1d5f646719d1d1879a8ec79a837cb82fb7509feb052d050524407af0ac4216f64
        36eb825b1f172c9002d191136951212628609f6f6fe4cbbeb1e5947f72dae3fbe70fc6a442b276de702efd739bfd23d4
        6cffdc17c37e15e01b6eedf9563a6fc7c315cf4ad0e8671860831460473aca6782709b8ca30e4cba1f8867c0e5627856
        ae89aedc71e29f4f37e2b5734ca4a17faa68f6c83f6e1d3dfa633e51c9284f78e2dbe577665fbab0dd17917c0e2e337d
        ca9aac19a06b9948321c84468c885297986a87b8538d59cacfdd41368437a883fe59800ab01ec630b13fd13fc3e6ceaf
        ba77862a89563fab5b8d2686800249513646944d625f00d79d776c74d9c68ad9961c5444ea9d804eb978f1d537e8af3d
        075d50ae27b2593ba03462c04533c0a1d1310e0f9be3a137cfec6fcd9b3d2924f2621051c1921ac2de82f1f5e62dbb5f
        08998d6aab43b6c1891ce7e32c6bd117d8745b5dd16d5959ee09cc3fab63a901123eb7849b483a2d765ddd47e587315f
        3cd9a58fc79cd2466315fc8eb67147b3d8ee9871863332470685308951cb2855cb101505feabec1bc6b99417ddee8429
        36fa171d92bfd32e2d991ac5e5a471bd9f39ccca675f742d2aefa53b6f51b4868e63055df3407cd82fb20d91e5ab02fa
        9913e3e0acc166067734c518a3fe7e1e6fb78add869742f17642d8fce20a6a657242340bc1b79f9555195832c04ed152
        a06e382750f456beeeadd677b336f0d8ecb1c405f592bb1dfba0f2818e67e6668abe532ebe0ed7f73da47f957c0b7f0c
        7b122ae895f57374f748449a6146f038887cf011ce0f4e98039d30f9131678ad3f2f184f806c4855f346fdfe6629fef9
        229812951e1bf7ae988a9309602a02e905494019de06f55b52b64d1d
        """
}
