import Foundation

/// A public key in OpenSSH's one-line text form, `ssh-ed25519 AAAA... comment`, which is what
/// `~/.ssh/authorized_keys`, `ssh-keygen -y` and `*.pub` files hold.
///
/// The middle field is the base64 of the wire blob (RFC 4253 section 6.6): `string keytype`
/// followed by the fields of that key type. For Ed25519 that is one `string` with the 32-byte
/// public key (RFC 8709 section 4). Other key types are kept as an opaque blob, which is all
/// that fingerprints and the known-hosts store need.
public struct OpenSSHPublicKey: Equatable, Hashable, Sendable {
    public static let ed25519KeyType = "ssh-ed25519"

    /// The key type named inside the blob, for example `ssh-ed25519`.
    public let keyType: String
    /// The wire blob.
    public let blob: Data
    /// Free text after the key. Never contains a line break or another control character.
    public let comment: String

    public enum ParseError: Error, Equatable, Sendable {
        /// The line does not have a key type and a base64 field.
        case malformedLine
        /// The second field is not base64.
        case invalidBase64
        /// The blob is truncated, has trailing bytes, or an Ed25519 key that is not 32 bytes.
        case malformedBlob
        /// The key type in front of the base64 differs from the one inside the blob.
        case keyTypeMismatch(line: String, blob: String)
        /// The comment contains a control character (a line break would add a second line to
        /// `authorized_keys`).
        case invalidComment
    }

    /// A key from its wire blob.
    public init(blob: Data, comment: String = "") throws {
        var reader = SSHWireReader(blob)
        guard let typeBytes = reader.readString(), !typeBytes.isEmpty,
            typeBytes.allSatisfy({ $0 > 0x20 && $0 < 0x7f })
        else { throw ParseError.malformedBlob }
        let type = String(decoding: typeBytes, as: UTF8.self)
        if type == Self.ed25519KeyType {
            guard let key = reader.readString(), key.count == 32, reader.isAtEnd else {
                throw ParseError.malformedBlob
            }
        } else {
            guard !reader.isAtEnd else { throw ParseError.malformedBlob }
        }
        guard Self.isValidComment(comment) else { throw ParseError.invalidComment }
        self.keyType = type
        self.blob = blob
        self.comment = comment
    }

    /// An Ed25519 key from its 32 raw public key bytes.
    public init(ed25519PublicKey: Data, comment: String = "") throws {
        guard ed25519PublicKey.count == 32 else { throw ParseError.malformedBlob }
        var writer = SSHWireWriter()
        writer.writeString(Self.ed25519KeyType)
        writer.writeString(ed25519PublicKey)
        try self.init(blob: Data(writer.bytes), comment: comment)
    }

    /// Parses `keytype base64 [comment]`. Leading and trailing white space is ignored and the
    /// comment may contain spaces. Lines with an `authorized_keys` options prefix are not
    /// accepted.
    public init(line: String) throws {
        // Work on scalars: Swift treats "\r\n" as one Character.
        let isBlank: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        var rest = Substring.UnicodeScalarView(line.unicodeScalars)
        while let last = rest.last, last == "\n" || last == "\r" || isBlank(last) { rest.removeLast() }
        rest = rest.drop(while: isBlank)
        let type = rest.prefix(while: { !isBlank($0) })
        rest = rest.dropFirst(type.count).drop(while: isBlank)
        let encoded = rest.prefix(while: { !isBlank($0) })
        rest = rest.dropFirst(encoded.count).drop(while: isBlank)
        guard !type.isEmpty, !encoded.isEmpty else { throw ParseError.malformedLine }
        guard let blob = Data(base64Encoded: String(encoded)) else { throw ParseError.invalidBase64 }
        try self.init(blob: blob, comment: String(String.UnicodeScalarView(rest)))
        guard keyType == String(type) else {
            throw ParseError.keyTypeMismatch(line: String(type), blob: keyType)
        }
    }

    /// The same key with another comment.
    public func withComment(_ comment: String) throws -> OpenSSHPublicKey {
        try OpenSSHPublicKey(blob: blob, comment: comment)
    }

    /// `keytype base64 comment`, without a line break. This is the `authorized_keys` line.
    public var line: String {
        let head = keyType + " " + blob.base64EncodedString()
        return comment.isEmpty ? head : head + " " + comment
    }

    /// The 32 raw bytes of an Ed25519 key, nil for other key types.
    public var ed25519PublicKey: Data? {
        guard keyType == Self.ed25519KeyType else { return nil }
        var reader = SSHWireReader(blob)
        _ = reader.readString()
        return reader.readString().map { Data($0) }
    }

    /// `SHA256:` fingerprint, as `ssh-keygen -lf` prints it.
    public var fingerprint: String { Fingerprint.sha256(ofBlob: blob) }

    /// A comment must stay on its line: no control characters, including the Unicode line
    /// separators.
    public static func isValidComment(_ comment: String) -> Bool {
        comment.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && !(0x80...0x9f).contains(scalar.value)
                && scalar.value != 0x2028 && scalar.value != 0x2029
        }
    }

    // Two keys are the same key when the blobs are equal; the comment is a label.
    public static func == (lhs: OpenSSHPublicKey, rhs: OpenSSHPublicKey) -> Bool {
        lhs.blob == rhs.blob
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(blob)
    }
}
