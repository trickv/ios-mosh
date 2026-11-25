import Foundation

/// What a key store tells about one key without revealing the private part.
public struct StoredKey: Equatable, Sendable {
    /// The name the key is stored under, unique in its store.
    public let name: String
    /// The public key; its comment is the one given at generation.
    public let publicKey: OpenSSHPublicKey

    public init(name: String, publicKey: OpenSSHPublicKey) {
        self.name = name
        self.publicKey = publicKey
    }

    public var comment: String { publicKey.comment }
    public var fingerprint: String { publicKey.fingerprint }
    /// The line for `~/.ssh/authorized_keys`.
    public var authorizedKeysLine: String { publicKey.line }

    public static func == (lhs: StoredKey, rhs: StoredKey) -> Bool {
        lhs.name == rhs.name && lhs.publicKey == rhs.publicKey
            && lhs.publicKey.comment == rhs.publicKey.comment
    }
}

public enum KeyStoreError: Error, Equatable, Sendable {
    /// Names are 1 to 64 characters from `A-Z a-z 0-9 . _ -` and do not start with a dot.
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    /// The stored data for this key cannot be read back as a key.
    case corrupt(String)
    /// The comment contains a control character.
    case invalidComment
    case io(String)
}

/// Where the device's SSH keys live. The app uses the Keychain; tests and `moshcli` use
/// `FileKeyStore`. Private keys are 32-byte Ed25519 seeds and never leave the store except
/// through `loadPrivateKey`.
public protocol KeyStore: Sendable {
    /// All keys, sorted by name.
    func list() throws -> [StoredKey]
    /// Creates a new Ed25519 key. Throws `alreadyExists` if the name is taken.
    @discardableResult
    func generate(name: String, comment: String) throws -> StoredKey
    /// The 32-byte private key.
    func loadPrivateKey(name: String) throws -> Data
    /// Removes the key. Throws `notFound` if there is none.
    func delete(name: String) throws
}

extension KeyStore {
    /// The stored key with this name, nil if there is none.
    public func key(named name: String) throws -> StoredKey? {
        try list().first { $0.name == name }
    }
}

public enum KeyName {
    /// Whether a name is acceptable to every store. The rule keeps a name usable as a file name
    /// and as a Keychain account.
    public static func isValid(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), !name.hasPrefix(".") else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}
