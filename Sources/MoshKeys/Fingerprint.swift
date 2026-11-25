import Crypto
import Foundation

/// Key fingerprints in the form OpenSSH shows them.
public enum Fingerprint {
    /// `SHA256:` followed by the base64 of the SHA-256 of the wire blob, without `=` padding.
    /// Equal to the second field of `ssh-keygen -lf <file>`.
    public static func sha256(ofBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        var encoded = Data(digest).base64EncodedString()
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return "SHA256:" + encoded
    }
}
