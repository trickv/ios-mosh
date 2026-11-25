import Foundation
import MoshKeys
import Security
import UIKit

/// The app's `KeyStore`: each key is one Keychain generic password (docs/PLAN.md, Design 4,
/// "Keys").
///
/// - `kSecAttrService` is the store's service name, `kSecAttrAccount` the key's name.
/// - `kSecValueData` is the 32-byte Ed25519 private key. It is read only by
///   `loadPrivateKey`, never by `list`.
/// - `kSecAttrGeneric` holds the public key line (`ssh-ed25519 AAAA... comment`), so listing
///   needs no secret.
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable: the key never
///   leaves the device, also not through a backup or iCloud Keychain.
///
/// An existing item is never replaced: `generate` adds with `SecItemAdd`, which fails with
/// `errSecDuplicateItem` (reported as `alreadyExists`).
final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    /// The service of the app's own keys. Tests use a service of their own.
    static let defaultService = "us.v9n.ios-mosh.ssh-keys"

    let service: String

    init(service: String = KeychainKeyStore.defaultService) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func list() throws -> [StoredKey] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.error(status, "list") }
        guard let items = result as? [[String: Any]] else { return [] }
        var keys: [StoredKey] = []
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String, KeyName.isValid(name) else { continue }
            guard let data = item[kSecAttrGeneric as String] as? Data,
                  let publicKey = try? OpenSSHPublicKey(line: String(decoding: data, as: UTF8.self))
            else { throw KeyStoreError.corrupt(name) }
            keys.append(StoredKey(name: name, publicKey: publicKey))
        }
        return keys.sorted { $0.name < $1.name }
    }

    @discardableResult
    func generate(name: String, comment: String) throws -> StoredKey {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        guard OpenSSHPublicKey.isValidComment(comment) else { throw KeyStoreError.invalidComment }
        let pair = KeyGenerator.generateEd25519()
        let publicKey: OpenSSHPublicKey
        do {
            publicKey = try pair.openSSHPublicKey(comment: comment)
        } catch {
            throw KeyStoreError.invalidComment
        }
        var item = baseQuery
        item[kSecAttrAccount as String] = name
        item[kSecAttrLabel as String] = "iOS-mosh SSH key \(name)"
        item[kSecAttrGeneric as String] = Data(publicKey.line.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = pair.privateKey
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.alreadyExists(name) }
        guard status == errSecSuccess else { throw Self.error(status, "add") }
        return StoredKey(name: name, publicKey: publicKey)
    }

    func loadPrivateKey(name: String) throws -> Data {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        var query = baseQuery
        query[kSecAttrAccount as String] = name
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeyStoreError.notFound(name) }
        guard status == errSecSuccess else { throw Self.error(status, "read") }
        guard let data = result as? Data, (try? Ed25519KeyPair(privateKey: data)) != nil else {
            throw KeyStoreError.corrupt(name)
        }
        return data
    }

    func delete(name: String) throws {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        var query = baseQuery
        query[kSecAttrAccount as String] = name
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { throw KeyStoreError.notFound(name) }
        guard status == errSecSuccess else { throw Self.error(status, "delete") }
    }

    private static func error(_ status: OSStatus, _ operation: String) -> KeyStoreError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return .io("Keychain \(operation): OSStatus \(status) \(text)")
    }
}

/// The device key: the one key M5 uses for every host (docs/PLAN.md, Design 4). It is made
/// the first time it is needed, with the comment `ios-mosh@<device>`.
enum DeviceKey {
    static let name = "device"

    /// The device key, made now if there is none.
    static func ensure(in store: KeyStore) throws -> StoredKey {
        if let key = try store.key(named: name) { return key }
        do {
            return try store.generate(name: name, comment: comment)
        } catch KeyStoreError.alreadyExists {
            // Made by someone else between the two calls: use that one.
            guard let key = try store.key(named: name) else { throw KeyStoreError.notFound(name) }
            return key
        }
    }

    /// `ios-mosh@<device name>`, with the name reduced to letters, digits and dashes. Since
    /// iOS 16 the name is the model ("iPhone") unless the app has an entitlement it does not
    /// ask for.
    static var comment: String {
        let raw = UIDevice.current.name.lowercased()
        var name = ""
        for scalar in raw.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                name.unicodeScalars.append(scalar)
            } else if !name.hasSuffix("-") {
                name += "-"
            }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "ios-mosh@" + (name.isEmpty ? "iphone" : name)
    }
}
