import XCTest
import MoshTestSupport
import MoshCrypto

final class AESBlockTests: XCTestCase {
    /// FIPS 197 appendix C.1 (AES-128).
    func testFIPS197Vector() throws {
        let aes = try AESBlock(key: bytes(hex: "000102030405060708090a0b0c0d0e0f"))
        var block = bytes(hex: "00112233445566778899aabbccddeeff")
        try aes.encrypt(&block)
        XCTAssertEqual(hex(block), "69c4e0d86a7b0430d8cdb78070b4c55a")
        try aes.decrypt(&block)
        XCTAssertEqual(hex(block), "00112233445566778899aabbccddeeff")
    }

    /// FIPS 197 appendix B.
    func testFIPS197AppendixB() throws {
        let aes = try AESBlock(key: bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c"))
        var block = bytes(hex: "3243f6a8885a308d313198a2e0370734")
        try aes.encrypt(&block)
        XCTAssertEqual(hex(block), "3925841d02dc09fbdc118597196a0b32")
    }

    /// Several blocks in one call are handled independently (ECB), in both directions.
    func testSeveralBlocks() throws {
        let aes = try AESBlock(key: bytes(hex: "000102030405060708090a0b0c0d0e0f"))
        let one = bytes(hex: "00112233445566778899aabbccddeeff")
        var three = one + [UInt8](repeating: 0, count: 16) + one
        try aes.encrypt(&three)
        XCTAssertEqual(hex(three[0..<16]), "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(hex(three[32..<48]), "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertNotEqual(hex(three[16..<32]), "69c4e0d86a7b0430d8cdb78070b4c55a")
        try aes.decrypt(&three)
        XCTAssertEqual(three, one + [UInt8](repeating: 0, count: 16) + one)

        var empty: [UInt8] = []
        try aes.encrypt(&empty)
        XCTAssertEqual(empty, [])
    }

    func testRejectsBadSizes() throws {
        XCTAssertThrowsError(try AESBlock(key: [UInt8](repeating: 0, count: 24))) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidKeyLength(24))
        }
        XCTAssertThrowsError(try AESBlock(key: []))
        let aes = try AESBlock(key: [UInt8](repeating: 0, count: 16))
        var short = [UInt8](repeating: 0, count: 15)
        XCTAssertThrowsError(try aes.encrypt(&short)) { error in
            XCTAssertEqual(error as? MoshCryptoError, .invalidBlockLength(15))
        }
        var long = [UInt8](repeating: 0, count: 17)
        XCTAssertThrowsError(try aes.decrypt(&long))
    }
}
