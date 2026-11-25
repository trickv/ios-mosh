import Foundation
import MoshKeys
import MoshTestSupport
import XCTest

final class KeyStoreTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var store: FileKeyStore!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory(label: "keystore")
        store = FileKeyStore(directory: scratch.file("keys"))
    }

    override func tearDown() {
        scratch.remove()
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    func testGeneratedKeyPairIsConsistent() throws {
        let pair = KeyGenerator.generateEd25519()
        XCTAssertEqual(pair.privateKey.count, 32)
        XCTAssertEqual(pair.publicKey.count, 32)
        XCTAssertNotEqual(pair.privateKey, KeyGenerator.generateEd25519().privateKey)

        let rebuilt = try Ed25519KeyPair(privateKey: pair.privateKey)
        XCTAssertEqual(rebuilt.publicKey, pair.publicKey)

        XCTAssertThrowsError(try Ed25519KeyPair(privateKey: Data(count: 31))) {
            XCTAssertEqual($0 as? Ed25519KeyPair.KeyError, .invalidPrivateKey)
        }
    }

    func testRFC8032Vector() throws {
        // RFC 8032 section 7.1, test 1.
        let secret = Data(bytes(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        let pair = try Ed25519KeyPair(privateKey: secret)
        XCTAssertEqual(
            hex(pair.publicKey), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        XCTAssertEqual(
            try pair.openSSHPublicKey(comment: "rfc").line,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea rfc")
    }

    func testEmptyStoreListsNothing() throws {
        XCTAssertEqual(try store.list(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertNil(try store.key(named: "none"))
    }

    func testGenerateListLoadDelete() throws {
        let created = try store.generate(name: "phone", comment: "ios-mosh@phone")
        XCTAssertEqual(created.name, "phone")
        XCTAssertEqual(created.comment, "ios-mosh@phone")
        XCTAssertTrue(created.authorizedKeysLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(created.authorizedKeysLine.hasSuffix(" ios-mosh@phone"))
        XCTAssertEqual(created.fingerprint, created.publicKey.fingerprint)

        try store.generate(name: "a-second.key_2", comment: "")
        // A second instance on the same directory sees the same keys, sorted by name.
        let reopened = FileKeyStore(directory: store.directory)
        let listed = try reopened.list()
        XCTAssertEqual(listed.map(\.name), ["a-second.key_2", "phone"])
        XCTAssertEqual(listed[1], created)
        XCTAssertEqual(try reopened.key(named: "phone"), created)

        let secret = try reopened.loadPrivateKey(name: "phone")
        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(try Ed25519KeyPair(privateKey: secret).publicKey, created.publicKey.ed25519PublicKey)

        try reopened.delete(name: "phone")
        XCTAssertEqual(try store.list().map(\.name), ["a-second.key_2"])
        XCTAssertThrowsError(try store.loadPrivateKey(name: "phone")) {
            XCTAssertEqual($0 as? KeyStoreError, .notFound("phone"))
        }
        XCTAssertThrowsError(try store.delete(name: "phone")) {
            XCTAssertEqual($0 as? KeyStoreError, .notFound("phone"))
        }
    }

    func testFileModes() throws {
        try store.generate(name: "k", comment: "c")
        let directory = store.directory.path
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(directory + "/k.key"), 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: directory + "/k.key")).count, 32)
        let line = try String(contentsOfFile: directory + "/k.pub", encoding: .utf8)
        XCTAssertTrue(line.hasSuffix(" c\n"))
    }

    func testPrivateKeyModeDoesNotDependOnTheUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        try store.generate(name: "open-umask", comment: "")
        XCTAssertEqual(try mode(store.directory.path + "/open-umask.key"), 0o600)
        umask(0o777)
        // The directory exists by now; a umask that masks everything must not make the key
        // unreadable for its owner either.
        try store.generate(name: "closed-umask", comment: "")
        XCTAssertEqual(try mode(store.directory.path + "/closed-umask.key"), 0o600)
        XCTAssertEqual(try store.loadPrivateKey(name: "closed-umask").count, 32)
    }

    func testAnExistingKeyIsNeverOverwritten() throws {
        let first = try store.generate(name: "k", comment: "one")
        let secret = try store.loadPrivateKey(name: "k")
        XCTAssertThrowsError(try store.generate(name: "k", comment: "two")) {
            XCTAssertEqual($0 as? KeyStoreError, .alreadyExists("k"))
        }
        XCTAssertEqual(try store.loadPrivateKey(name: "k"), secret)
        XCTAssertEqual(try store.list(), [first])
    }

    func testNamesAreValidated() throws {
        for bad in ["", ".", "..", ".hidden", "a/b", "../x", "a b", "ä", String(repeating: "x", count: 65), "a\n"] {
            XCTAssertFalse(KeyName.isValid(bad), bad)
            XCTAssertThrowsError(try store.generate(name: bad, comment: ""), bad) {
                XCTAssertEqual($0 as? KeyStoreError, .invalidName(bad))
            }
            XCTAssertThrowsError(try store.loadPrivateKey(name: bad), bad)
            XCTAssertThrowsError(try store.delete(name: bad), bad)
        }
        for good in ["a", "A-1_b.c", String(repeating: "x", count: 64)] {
            XCTAssertTrue(KeyName.isValid(good), good)
        }
        XCTAssertEqual(try store.list(), [])
    }

    func testBadCommentIsRefusedBeforeAnythingIsWritten() throws {
        XCTAssertThrowsError(try store.generate(name: "k", comment: "two\nlines")) {
            XCTAssertEqual($0 as? KeyStoreError, .invalidComment)
        }
        XCTAssertEqual(try store.list(), [])
    }

    func testCorruptFilesAreReported() throws {
        try store.generate(name: "k", comment: "")
        let directory = store.directory.path
        try Data(count: 5).write(to: URL(fileURLWithPath: directory + "/k.key"))
        XCTAssertThrowsError(try store.loadPrivateKey(name: "k")) {
            XCTAssertEqual($0 as? KeyStoreError, .corrupt("k"))
        }
        try Data("not a key\n".utf8).write(to: URL(fileURLWithPath: directory + "/k.pub"))
        XCTAssertThrowsError(try store.list()) {
            XCTAssertEqual($0 as? KeyStoreError, .corrupt("k"))
        }
    }

    // MARK: - Against OpenSSH

    func testFingerprintEqualsSSHKeygen() throws {
        guard ToolRunner.which("ssh-keygen") != nil else { throw XCTSkip("ssh-keygen not in PATH") }
        let key = try store.generate(name: "k", comment: "ios-mosh@test device")
        // -l prints "<bits> <fingerprint> <comment> (<type>)".
        let output = try ToolRunner.check("ssh-keygen", ["-lf", store.directory.path + "/k.pub"])
        let fields = output.split(separator: " ")
        XCTAssertEqual(fields.first, "256")
        XCTAssertEqual(String(fields[1]), key.fingerprint)
        XCTAssertTrue(output.hasSuffix("ios-mosh@test device (ED25519)\n"), output)
    }

    func testSSHKeygenKeysParseAndMatchItsFingerprint() throws {
        guard ToolRunner.which("ssh-keygen") != nil else { throw XCTSkip("ssh-keygen not in PATH") }
        for type in ["ed25519", "ecdsa", "rsa"] {
            let file = scratch.file("id_\(type)").path
            try ToolRunner.check("ssh-keygen", ["-q", "-t", type, "-N", "", "-C", "made by \(type)", "-f", file])
            let line = try String(contentsOfFile: file + ".pub", encoding: .utf8)
            let key = try OpenSSHPublicKey(line: line)
            XCTAssertEqual(key.comment, "made by \(type)")
            XCTAssertEqual(key.line + "\n", line)
            let listed = try ToolRunner.check("ssh-keygen", ["-lf", file + ".pub"])
            XCTAssertEqual(String(listed.split(separator: " ")[1]), key.fingerprint, type)
        }
    }

    func testOpenSSHAcceptsTheGeneratedLine() throws {
        guard ToolRunner.which("ssh-keygen") != nil else { throw XCTSkip("ssh-keygen not in PATH") }
        // ssh-keygen reads an authorized_keys file line by line with -lf; it fails on a line
        // it cannot parse.
        let one = try store.generate(name: "one", comment: "first key")
        let two = try store.generate(name: "two", comment: "")
        let file = scratch.file("authorized_keys")
        try Data((one.authorizedKeysLine + "\n" + two.authorizedKeysLine + "\n").utf8).write(to: file)
        let listed = try ToolRunner.check("ssh-keygen", ["-lf", file.path])
        let lines = listed.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(one.fingerprint))
        XCTAssertTrue(lines[1].contains(two.fingerprint))
    }
}
