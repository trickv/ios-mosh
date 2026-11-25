import Crypto
import Foundation

/// An Ed25519 key pair as raw bytes. The private part is the 32-byte seed
/// (`Curve25519.Signing.PrivateKey.rawRepresentation`), which is what a key store keeps.
public struct Ed25519KeyPair: Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public enum KeyError: Error, Equatable, Sendable {
        /// The private key is not 32 bytes.
        case invalidPrivateKey
    }

    /// Rebuilds the pair from a stored private key.
    public init(privateKey: Data) throws {
        guard privateKey.count == 32,
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        else { throw KeyError.invalidPrivateKey }
        self.privateKey = key.rawRepresentation
        self.publicKey = key.publicKey.rawRepresentation
    }

    /// The public half in OpenSSH form.
    public func openSSHPublicKey(comment: String = "") throws -> OpenSSHPublicKey {
        try OpenSSHPublicKey(ed25519PublicKey: publicKey, comment: comment)
    }
}

public enum KeyGenerator {
    /// A new Ed25519 key pair from the system's random number generator.
    public static func generateEd25519() -> Ed25519KeyPair {
        let key = Curve25519.Signing.PrivateKey()
        // A freshly generated key always round-trips.
        return try! Ed25519KeyPair(privateKey: key.rawRepresentation)
    }
}
