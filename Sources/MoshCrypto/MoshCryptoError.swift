/// Errors thrown by MoshCrypto.
public enum MoshCryptoError: Error, Equatable, Sendable {
    /// The AES key is not 16 bytes.
    case invalidKeyLength(Int)
    /// The OCB nonce is not 1 to 15 bytes.
    case invalidNonceLength(Int)
    /// A buffer handed to `AESBlock` is not a whole number of 16-byte blocks.
    case invalidBlockLength(Int)
    /// An OCB ciphertext is shorter than its 16-byte tag.
    case ciphertextTooShort(Int)
    /// A mosh datagram is shorter than nonce plus tag (24 bytes).
    /// mosh: "Ciphertext must contain nonce and tag."
    case datagramTooShort(Int)
    /// The tag did not verify. mosh: "Packet failed integrity check."
    case authenticationFailed
    /// A sequence number does not fit in 63 bits. mosh masks it silently, which would repeat a nonce.
    case sequenceOutOfRange(UInt64)
    /// A printable session key was rejected. The text is mosh's own message for the same condition.
    case invalidBase64Key(String)
    /// The platform AES primitive reported a failure.
    case aesFailure(Int)
}
