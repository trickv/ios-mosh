import XCTest
import MoshTestSupport
import MoshCrypto

/// Port of mosh 1.4.0's src/tests/base64.cc.
final class Base64KeyTests: XCTestCase {
    /// `static_base64_vector`: the output of mosh's src/tests/genbase64.pl (which fills
    /// base64_vector.h's table at build time), run once in the dev container. mosh keys drop the
    /// trailing "==", so the printable form is the first 22 characters.
    private let vectors: [(native: String, encoded: String)] = [
        ("00000000000000000000000000000000", "AAAAAAAAAAAAAAAAAAAAAA=="),
        ("ffffffffffffffffffffffffffffffff", "/////////////////////w=="),
        ("000000000000000000000000000000ff", "AAAAAAAAAAAAAAAAAAAA/w=="),
        ("ffffffffffffffffffffffffffffff00", "////////////////////AA=="),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "qqqqqqqqqqqqqqqqqqqqqg=="),
        ("aaaaaaaaaaaaaaaa5555555555555555", "qqqqqqqqqqpVVVVVVVVVVQ=="),
        ("5555555555555555aaaaaaaaaaaaaaaa", "VVVVVVVVVVWqqqqqqqqqqg=="),
        ("0102040810204080fefdfbf7efdfbf7f", "AQIECBAgQID+/fv379+/fw=="),
    ]

    func testVectors() throws {
        for row in vectors {
            XCTAssertTrue(row.encoded.hasSuffix("=="))
            let printable = String(row.encoded.dropLast(2))
            XCTAssertEqual(printable.count, 22)

            let fromBytes = try Base64Key(bytes: bytes(hex: row.native))
            XCTAssertEqual(fromBytes.printable, printable)

            let fromText = try Base64Key(printable: printable)
            XCTAssertEqual(hex(fromText.bytes), row.native)
            XCTAssertEqual(fromText, fromBytes)
        }
    }

    /// "try 0..255 in the last byte; make sure the final two characters are output properly"
    func testEveryLastByte() throws {
        var source = [UInt8](repeating: 0, count: 16)
        for i in 0...255 {
            source[15] = UInt8(i)
            let key = try Base64Key(bytes: source)
            XCTAssertEqual(key.printable.utf8.count, 22)
            XCTAssertEqual(try Base64Key(printable: key.printable).bytes, source)
        }
    }

    /// "randomly try keys"
    func testRandomKeys() throws {
        for _ in 0..<4096 {
            let key1 = Base64Key.random()
            let key2 = try Base64Key(printable: key1.printable)
            XCTAssertEqual(key1.printable, key2.printable)
            XCTAssertEqual(key1.bytes, key2.bytes)
        }
        XCTAssertNotEqual(Base64Key.random(), Base64Key.random())
    }

    /// mosh's `bad_keys`. Those rows are 24-character strings handed to `base64_decode`; the key
    /// parser sees the same text without the "==" it adds itself, and the ones that are not 22
    /// characters long fail on the length.
    func testBadKeys() {
        let badKeys = [
            "",
            "AAAAAAAAAAAAAAAAAAAAAA=",
            "AAAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAAAAAAAAAAAAAA~=",
            "AAAAAAAAAAAAAAAAAAAAAA=~",
            "~AAAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAAAAAAAAAAAA~A==",
            "AAAAAAAAAAAAAAAAAAAAA~==",
            "AAAAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAA~AAAAAAAAAAA==",
            "AAAAAAAAAA==",
            // The same with the padding left off, as a key appears in MOSH CONNECT.
            "~AAAAAAAAAAAAAAAAAAAAA",
            "AAAAAAAAAAAAAAAAAAAA~A",
            "AAAAAAAAAAAAAAAAAAAAA~",
            "AAAAAAAAAA~AAAAAAAAAAA",
            "AAAAAAAAAAAAAAAAAAAAA",
            "AAAAAAAAAAAAAAAAAAAAAAA",
            "AAAAAAAAAAAAAAAAAAAAA=",
            "AAAAAAAAAAAAAAAAAAAA==",
            "AAAAAAAAAAAAAAAAAAAAA ",
            "AAAAAAAAAAAAAAAAAAAAA\n",
            "AAAAAAAAAAAAAAAAAAAAA-",
            "AAAAAAAAAAAAAAAAAAAAA_",
            "AAAAAAAAAAAAAAAAAAAAAé",
        ]
        for text in badKeys {
            XCTAssertThrowsError(try Base64Key(printable: text), "accepted \(text.debugDescription)") { error in
                guard case .invalidBase64Key? = error as? MoshCryptoError else {
                    return XCTFail("unexpected error \(error) for \(text.debugDescription)")
                }
            }
        }
    }

    /// The 22nd character carries two key bits and four bits that must be zero. mosh rejects a
    /// key with any of the four set ("to catch changes after the first 128 bits").
    func testRejectsNonCanonicalLastCharacter() throws {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var accepted: [Character] = []
        for character in alphabet {
            let text = "AAAAAAAAAAAAAAAAAAAAA" + String(character)
            if let key = try? Base64Key(printable: text) {
                accepted.append(character)
                XCTAssertEqual(key.printable, text)
            } else {
                XCTAssertThrowsError(try Base64Key(printable: text)) { error in
                    XCTAssertEqual(error as? MoshCryptoError,
                                   .invalidBase64Key("Base64 key was not encoded 128-bit key."))
                }
            }
        }
        XCTAssertEqual(accepted, ["A", "Q", "g", "w"])
    }

    func testErrorMessagesAreMoshs() {
        XCTAssertThrowsError(try Base64Key(printable: "short")) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidBase64Key("Key must be 22 letters long."))
        }
        XCTAssertThrowsError(try Base64Key(printable: "AAAAAAAAAA~AAAAAAAAAAA")) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidBase64Key("Key must be well-formed base64."))
        }
        XCTAssertThrowsError(try Base64Key(bytes: [1, 2, 3])) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidKeyLength(3))
        }
    }

    func testDescriptionDoesNotRevealTheKey() throws {
        let key = try Base64Key(printable: "AQIECBAgQID+/fv379+/fw")
        XCTAssertFalse("\(key)".contains("AQIECBAgQID"))
        XCTAssertFalse(String(describing: key).contains("AQIE"))
    }
}
