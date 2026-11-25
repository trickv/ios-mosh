import Foundation
import MoshKeys
import MoshTestSupport
import XCTest

final class OpenSSHPublicKeyTests: XCTestCase {
    // Made with `ssh-keygen -t ed25519|rsa|ecdsa` and read back with `ssh-keygen -lf`
    // (OpenSSH 9.6).
    static let ed25519Line =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGxtVQ7WZh/d59n87Hi4WmB0yaob71ggJidlwhws25m vector one@host"
    static let ed25519Fingerprint = "SHA256:s+qzOTCQK7sqcLG1J8/ddMDaX+9s94qocvDkENNGsbA"
    static let rsaLine =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCZx8kaB1Tf6q7/jW8sgWBUNbyFW+ETevar3zyLLasJtupHUw9AnItkT/z6XSjOXUrqKDZVdIOMzCXNkiCbwjF7oX4KLxasuYzofjGG5cn4Uzx8FI8st2mHRuven2DBTIIYjHcWE7tWhgsEwBqRBzQzsT1A4ilf3TF8JgbyNQ2UJIzp+7nvXoxERCuFQFCnEqIS+CTsJE0t23KCJYpBq1SF5B3rXsroBCG5fJ+beqnx2o06wUlRB0b1HqoGLHXJQKLpsPCrgg5AA1+IcLvEsnt8JwMHlMQk0vSqyTswLrHzYUJKIZPQvf+OFQmrZ6VExynquInwFA3APp4gC1O4SP9V rsa-vector"
    static let rsaFingerprint = "SHA256:z+fNV+B1u3F/pJBr/Kfy0f8CK+8/ITJQyMEyWwBEk4U"
    static let ecdsaLine =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFklecny4/KxoeX05kldlSxic264mKdweRBycZbrlnJUCTnT6LOrL10Clr2836NJplXdy8NDhG5PZhK4hi8aP74= ecdsa-vector"
    static let ecdsaFingerprint = "SHA256:x9jRAVZEMhiAzJ7+KezKoYNDWjxoFM3ETd7H31d3Xd0"

    func testParsesEd25519Line() throws {
        let key = try OpenSSHPublicKey(line: Self.ed25519Line)
        XCTAssertEqual(key.keyType, "ssh-ed25519")
        XCTAssertEqual(key.comment, "vector one@host")
        XCTAssertEqual(key.blob.count, 51)
        XCTAssertEqual(key.ed25519PublicKey?.count, 32)
        XCTAssertEqual(key.line, Self.ed25519Line)
        XCTAssertEqual(key.fingerprint, Self.ed25519Fingerprint)
    }

    func testWireBlobLayout() throws {
        let raw = Data((0..<32).map { UInt8($0) })
        let key = try OpenSSHPublicKey(ed25519PublicKey: raw, comment: "c")
        // string "ssh-ed25519" then string of the 32 key bytes.
        let expected = bytes(hex: "0000000b 7373682d65643235353139 00000020") + Array(raw)
        XCTAssertEqual(Array(key.blob), expected)
        XCTAssertEqual(key.ed25519PublicKey, raw)
        XCTAssertTrue(key.line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(key.line.hasSuffix(" c"))

        let decoded = try OpenSSHPublicKey(blob: key.blob)
        XCTAssertEqual(decoded.keyType, "ssh-ed25519")
        XCTAssertEqual(decoded.ed25519PublicKey, raw)
        XCTAssertEqual(decoded.comment, "")
        XCTAssertEqual(decoded.line, "ssh-ed25519 " + key.blob.base64EncodedString())
    }

    func testOtherKeyTypesKeepTheirBlob() throws {
        let rsa = try OpenSSHPublicKey(line: Self.rsaLine)
        XCTAssertEqual(rsa.keyType, "ssh-rsa")
        XCTAssertNil(rsa.ed25519PublicKey)
        XCTAssertEqual(rsa.fingerprint, Self.rsaFingerprint)
        XCTAssertEqual(rsa.line, Self.rsaLine)

        let ecdsa = try OpenSSHPublicKey(line: Self.ecdsaLine)
        XCTAssertEqual(ecdsa.keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(ecdsa.fingerprint, Self.ecdsaFingerprint)
        XCTAssertEqual(ecdsa.line, Self.ecdsaLine)
    }

    func testLineParsingToleratesWhitespace() throws {
        let fields = Self.ed25519Line.split(separator: " ", maxSplits: 2).map(String.init)
        let messy = "  \(fields[0])\t\(fields[1])   two  words \r\n"
        let key = try OpenSSHPublicKey(line: messy)
        XCTAssertEqual(key.comment, "two  words")
        XCTAssertEqual(key.fingerprint, Self.ed25519Fingerprint)

        let bare = try OpenSSHPublicKey(line: "\(fields[0]) \(fields[1])")
        XCTAssertEqual(bare.comment, "")
        XCTAssertEqual(bare.line, "\(fields[0]) \(fields[1])")
    }

    func testRejectsMalformedInput() {
        let base64 = Self.ed25519Line.split(separator: " ")[1]
        XCTAssertThrowsError(try OpenSSHPublicKey(line: "")) {
            XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .malformedLine)
        }
        XCTAssertThrowsError(try OpenSSHPublicKey(line: "ssh-ed25519")) {
            XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .malformedLine)
        }
        XCTAssertThrowsError(try OpenSSHPublicKey(line: "ssh-ed25519 !!!! x")) {
            XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .invalidBase64)
        }
        XCTAssertThrowsError(try OpenSSHPublicKey(line: "ssh-rsa \(base64) x")) {
            XCTAssertEqual(
                $0 as? OpenSSHPublicKey.ParseError, .keyTypeMismatch(line: "ssh-rsa", blob: "ssh-ed25519"))
        }
        // Truncated blob, trailing bytes, wrong key length, empty type.
        let good = Array(try! OpenSSHPublicKey(line: Self.ed25519Line).blob)
        for bad in [Array(good.dropLast()), good + [0], Array(good.prefix(15)), [0, 0, 0, 0], []] {
            XCTAssertThrowsError(try OpenSSHPublicKey(blob: Data(bad))) {
                XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .malformedBlob)
            }
        }
        XCTAssertThrowsError(try OpenSSHPublicKey(ed25519PublicKey: Data(count: 31))) {
            XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .malformedBlob)
        }
    }

    func testRejectsCommentsThatLeaveTheLine() throws {
        let raw = Data(count: 32)
        for bad in ["a\nb", "a\rb", "tab\there", "nul\u{0}", "del\u{7f}", "ls\u{2028}x", "c1\u{85}x"] {
            XCTAssertThrowsError(try OpenSSHPublicKey(ed25519PublicKey: raw, comment: bad), bad) {
                XCTAssertEqual($0 as? OpenSSHPublicKey.ParseError, .invalidComment)
            }
        }
        // Quotes, spaces and non-ASCII text are fine: the line is data, not shell input.
        let odd = "it's \"mine\" $(x) `y` ; é 日本"
        let key = try OpenSSHPublicKey(ed25519PublicKey: raw, comment: odd)
        XCTAssertEqual(try OpenSSHPublicKey(line: key.line).comment, odd)
        XCTAssertEqual(try key.withComment("other").comment, "other")
    }

    func testEqualityIgnoresTheComment() throws {
        let a = try OpenSSHPublicKey(line: Self.ed25519Line)
        let b = try a.withComment("renamed")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNotEqual(a, try OpenSSHPublicKey(line: Self.rsaLine))
    }

    func testFingerprintHasNoPadding() {
        // SHA-256 is 32 bytes, so the padded base64 would end in one "=".
        let fingerprint = Fingerprint.sha256(ofBlob: Data("x".utf8))
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(fingerprint.count, 7 + 43)
        XCTAssertFalse(fingerprint.contains("="))
    }

    func testWireReaderAndWriter() {
        var writer = SSHWireWriter()
        writer.writeUInt32(0x0102_0304)
        writer.writeString("ab")
        writer.writeString([UInt8]())
        XCTAssertEqual(writer.bytes, [1, 2, 3, 4, 0, 0, 0, 2, 0x61, 0x62, 0, 0, 0, 0])

        var reader = SSHWireReader(writer.bytes)
        XCTAssertEqual(reader.readUInt32(), 0x0102_0304)
        XCTAssertEqual(reader.readString(), [0x61, 0x62])
        XCTAssertEqual(reader.readString(), [])
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertNil(reader.readUInt32())

        // A length that runs past the end reads nothing and does not move.
        var short = SSHWireReader([0, 0, 0, 5, 1, 2])
        XCTAssertNil(short.readString())
        XCTAssertEqual(short.offset, 0)
        var huge = SSHWireReader([0xff, 0xff, 0xff, 0xff, 1])
        XCTAssertNil(huge.readString())
        XCTAssertEqual(huge.offset, 0)
    }
}
