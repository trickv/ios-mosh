import MoshKeys
import Security
import XCTest
@testable import IOSMosh

/// App-hosted, so the Keychain is the app's (docs/PLAN.md M5). Each test uses a service
/// name of its own and removes every item under it afterwards; the app's real keys
/// (`KeychainKeyStore.defaultService`) are never read or touched.
final class KeychainKeyStoreTests: XCTestCase {
    private var service = ""
    private var store: KeychainKeyStore!

    override func setUp() {
        service = "us.v9n.ios-mosh.tests.\(UUID().uuidString)"
        store = KeychainKeyStore(service: service)
    }

    override func tearDown() {
        // Only this test's service.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        XCTAssertEqual(try store.list(), [], "items left behind")
    }

    func testAnEmptyStoreListsNothing() throws {
        XCTAssertEqual(try store.list(), [])
        XCTAssertNil(try store.key(named: "device"))
        XCTAssertThrowsError(try store.loadPrivateKey(name: "device")) {
            XCTAssertEqual($0 as? KeyStoreError, .notFound("device"))
        }
    }

    func testGenerateStoreAndLoadInANewStoreInstance() throws {
        let made = try store.generate(name: "device", comment: "ios-mosh@test")
        XCTAssertEqual(made.name, "device")
        XCTAssertEqual(made.comment, "ios-mosh@test")
        XCTAssertTrue(made.authorizedKeysLine.hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertTrue(made.fingerprint.hasPrefix("SHA256:"))

        // A new instance, as after a relaunch.
        let again = KeychainKeyStore(service: service)
        XCTAssertEqual(try again.list(), [made])
        let privateKey = try again.loadPrivateKey(name: "device")
        XCTAssertEqual(privateKey.count, 32)
        // The stored private key belongs to the stored public key.
        let pair = try Ed25519KeyPair(privateKey: privateKey)
        XCTAssertEqual(try pair.openSSHPublicKey(comment: "ios-mosh@test"), made.publicKey)
        // Reading twice gives the same key and the same fingerprint.
        XCTAssertEqual(try again.loadPrivateKey(name: "device"), privateKey)
        XCTAssertEqual(try again.key(named: "device")?.fingerprint, made.fingerprint)
    }

    func testASecondGenerateDoesNotReplaceTheKey() throws {
        let first = try store.generate(name: "device", comment: "first")
        let privateKey = try store.loadPrivateKey(name: "device")
        XCTAssertThrowsError(try store.generate(name: "device", comment: "second")) {
            XCTAssertEqual($0 as? KeyStoreError, .alreadyExists("device"))
        }
        XCTAssertEqual(try store.list(), [first])
        XCTAssertEqual(try store.loadPrivateKey(name: "device"), privateKey)
    }

    func testDelete() throws {
        try store.generate(name: "a", comment: "")
        let b = try store.generate(name: "b", comment: "")
        try store.delete(name: "a")
        XCTAssertEqual(try store.list(), [b])
        XCTAssertThrowsError(try store.loadPrivateKey(name: "a")) {
            XCTAssertEqual($0 as? KeyStoreError, .notFound("a"))
        }
        XCTAssertThrowsError(try store.delete(name: "a")) {
            XCTAssertEqual($0 as? KeyStoreError, .notFound("a"))
        }
        try store.delete(name: "b")
        XCTAssertEqual(try store.list(), [])
    }

    func testListIsSortedByName() throws {
        try store.generate(name: "zeta", comment: "")
        try store.generate(name: "alpha", comment: "")
        XCTAssertEqual(try store.list().map(\.name), ["alpha", "zeta"])
    }

    func testInvalidNamesAndCommentsAreRefused() throws {
        XCTAssertThrowsError(try store.generate(name: ".hidden", comment: "")) {
            XCTAssertEqual($0 as? KeyStoreError, .invalidName(".hidden"))
        }
        XCTAssertThrowsError(try store.generate(name: "ok", comment: "two\nlines")) {
            XCTAssertEqual($0 as? KeyStoreError, .invalidComment)
        }
        XCTAssertEqual(try store.list(), [])
    }

    func testStoresAreSeparatedByService() throws {
        try store.generate(name: "device", comment: "")
        let otherService = "us.v9n.ios-mosh.tests.\(UUID().uuidString)"
        let other = KeychainKeyStore(service: otherService)
        XCTAssertEqual(try other.list(), [])
        XCTAssertThrowsError(try other.delete(name: "device"))
        XCTAssertEqual(try store.list().count, 1)
    }

    /// Design 4: `WhenUnlockedThisDeviceOnly`, not synchronised; the private key is the item's
    /// data and the public line is in an attribute.
    func testTheItemIsDeviceOnlyAndNotSynchronised() throws {
        let made = try store.generate(name: "device", comment: "c")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let sync = attributes[kSecAttrSynchronizable as String]
        XCTAssertTrue(sync == nil || (sync as? NSNumber)?.boolValue == false, "synchronizable: \(String(describing: sync))")
        XCTAssertEqual(attributes[kSecAttrGeneric as String] as? Data, Data(made.authorizedKeysLine.utf8))
    }

    func testDeviceKeyIsMadeOnceAndThenKept() throws {
        let first = try DeviceKey.ensure(in: store)
        XCTAssertEqual(first.name, DeviceKey.name)
        XCTAssertTrue(first.comment.hasPrefix("ios-mosh@"))
        XCTAssertTrue(OpenSSHPublicKey.isValidComment(first.comment))
        let second = try DeviceKey.ensure(in: KeychainKeyStore(service: service))
        XCTAssertEqual(second, first)
        XCTAssertEqual(try store.list().count, 1)
    }
}
