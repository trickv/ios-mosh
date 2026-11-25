import Foundation
import MoshCrypto
import MoshResume
import Security

/// The session keys of resumable sessions (docs/PLAN.md section 3, "Session record": "Keychain
/// item, account = uuid, `AfterFirstUnlockThisDeviceOnly`, 16-byte session key").
///
/// On iOS the record has no `key` file (`ResumeCoordinator.create(storesKey: false)`): the key
/// is one generic password per session, account = the session id, value = the 16 key bytes,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. "After first
/// unlock" so that a session can be saved and resumed while the device is locked after its
/// first unlock (the record's files have the matching file protection); "this device only"
/// so that it never reaches another device. A restore to the same device brings the item back
/// without the record's files (they are excluded from backups): such an item is an orphan and
/// is deleted at the next launch (`SessionFiles.removeOrphans`).
///
/// The key is never logged and never shown.
/// Not `final` only so that the app's unit tests can answer `key(for:)` with `.locked` (the
/// simulator cannot lock its Keychain); the app has no subclass.
class SessionKeychain: @unchecked Sendable {
    static let defaultService = "us.v9n.ios-mosh.session-keys"
    static let shared = SessionKeychain()

    enum Failure: Error, CustomStringConvertible {
        /// `errSecInteractionNotAllowed`: the device is locked (before its first unlock). Try
        /// again later; never a reason to give a session up (docs/PLAN.md section 3).
        case locked
        case io(String)
        /// There is an item, but it is not a 16-byte key. Time does not repair that: for a
        /// cold start it is the same as no key (review M6-6).
        case malformed

        var description: String {
            switch self {
            case .malformed: return "the stored session key is not 16 bytes"
            case .locked: return "the Keychain cannot be read now (device locked)"
            case .io(let text): return text
            }
        }
    }

    let service: String

    init(service: String = SessionKeychain.defaultService) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Stores the key of a new session. An item for the id must not exist (ids are random).
    func store(_ key: Base64Key, for id: SessionID) throws {
        var item = baseQuery
        item[kSecAttrAccount as String] = id.description
        item[kSecAttrLabel as String] = "iOS-mosh session key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(key.bytes)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.failure(status, "add") }
    }

    /// The key of a session; nil if there is no item for it.
    /// - Throws: `.locked` when the device is locked, `.io` for another Keychain error (neither
    ///   means "no key": try again later), `.malformed` for an item that is not a key.
    func key(for id: SessionID) throws -> Base64Key? {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.description
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status, "read") }
        guard let data = result as? Data, let key = try? Base64Key(bytes: [UInt8](data)) else {
            throw Failure.malformed
        }
        return key
    }

    /// The accessibility class an item has (for the tests: it must be the plan's).
    func accessibility(for id: SessionID) throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.description
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status, "read attributes") }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    /// The ids that have a key.
    func sessionIDs() throws -> [SessionID] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.failure(status, "list") }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(SessionID.init) }
    }

    /// Deletes the key of a session; nothing if there is none.
    func delete(_ id: SessionID) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.description
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status, "delete") }
    }

    /// Deletes every session key of this service (UI-test reset).
    func deleteAll() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func failure(_ status: OSStatus, _ operation: String) -> Failure {
        if status == errSecInteractionNotAllowed { return .locked }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return .io("Keychain \(operation): OSStatus \(status) \(text)")
    }
}
