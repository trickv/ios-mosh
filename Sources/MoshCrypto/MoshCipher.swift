// mosh's datagram encryption: port of Crypto::Session and Crypto::Nonce (src/crypto/crypto.cc)
// and of the nonce layout in Network::Packet (src/network/network.cc).
//
// On the wire:   8 bytes   big-endian (direction << 63) | sequence number
//                n bytes   AES-128-OCB3 ciphertext
//               16 bytes   tag
// The OCB nonce is 12 bytes: four zero bytes, then the eight bytes above. No associated data.

/// Who a datagram is for. mosh: `Network::Direction`.
public enum Direction: UInt8, Sendable {
    /// Sent by the client. The direction bit of the nonce is 0.
    case toServer = 0
    /// Sent by the server. The direction bit of the nonce is 1.
    case toClient = 1
}

/// A datagram after authentication and decryption.
public struct OpenedDatagram: Equatable, Sendable {
    /// Direction bit of the nonce. A client must drop anything that is not `.toClient`
    /// (mosh: "prevent malicious playback to sender").
    public let direction: Direction
    /// Sequence number: the low 63 bits of the nonce.
    public let seq: UInt64
    /// The decrypted payload (timestamps and one fragment; see MoshWire).
    public let plaintext: [UInt8]

    public init(direction: Direction, seq: UInt64, plaintext: [UInt8]) {
        self.direction = direction
        self.seq = seq
        self.plaintext = plaintext
    }
}

/// Encrypts and decrypts mosh datagrams under one session key.
///
/// The cipher keeps no state. In particular it has **no sequence counter**: the caller passes the
/// sequence number of every datagram and is responsible for never using one twice in the same
/// direction under the same key, across restarts too. Reuse is OCB nonce reuse, which breaks both
/// secrecy and authenticity. The transport takes its numbers from a durability gate for this
/// reason. (mosh also stops a session after 2^47 encrypted blocks; that limit, about 2 PB, is not
/// tracked here.)
public struct MoshCipher: Sendable {
    /// Bytes of nonce at the start of a datagram.
    public static let nonceLength = 8
    /// Bytes of tag at the end of a datagram. mosh: `Crypto::Session::ADDED_BYTES`.
    public static let tagLength = 16
    /// Shortest datagram that can be valid: nonce and tag around an empty plaintext.
    public static let minimumDatagramLength = 24
    /// What a datagram adds to its plaintext: nonce and tag.
    public static let overhead = 24
    /// Largest sequence number: 63 bits. The top bit of the nonce is the direction.
    public static let maxSequence: UInt64 = (1 << 63) - 1
    /// Size of mosh's receive buffer (`Crypto::Session::RECEIVE_MTU`). A peer rejects any larger
    /// datagram ("Received oversize datagram"); use the same size to receive.
    public static let receiveMTU = 2048

    private let ocb: OCB3

    public init(key: Base64Key) throws {
        self.ocb = try OCB3(key: key.bytes)
    }

    /// Builds the datagram for one plaintext.
    ///
    /// - Parameters:
    ///   - seq: sequence number, at most `maxSequence`. Never reuse one for the same direction and key.
    ///   - direction: `.toServer` for everything a client sends.
    public func encrypt(seq: UInt64, direction: Direction, plaintext: [UInt8]) throws -> [UInt8] {
        guard seq <= Self.maxSequence else { throw MoshCryptoError.sequenceOutOfRange(seq) }
        let value = (UInt64(direction.rawValue) << 63) | seq
        var nonce = [UInt8](repeating: 0, count: 4 + Self.nonceLength)
        for i in 0..<Self.nonceLength {
            nonce[4 + i] = UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * i))
        }
        var datagram = Array(nonce[4...])
        datagram.reserveCapacity(plaintext.count + Self.overhead)
        datagram.append(contentsOf: try ocb.seal(nonce: nonce, plaintext: plaintext))
        return datagram
    }

    /// Authenticates and decrypts a datagram.
    ///
    /// Throws `MoshCryptoError.datagramTooShort` for anything under 24 bytes and
    /// `MoshCryptoError.authenticationFailed` when the tag does not verify (wrong key, damaged or
    /// forged datagram). It does not check the direction or the order of sequence numbers; that is
    /// the receiver's job.
    public func decrypt(_ datagram: [UInt8]) throws -> OpenedDatagram {
        guard datagram.count >= Self.minimumDatagramLength else {
            throw MoshCryptoError.datagramTooShort(datagram.count)
        }
        var nonce = [UInt8](repeating: 0, count: 4)
        nonce.append(contentsOf: datagram[0..<Self.nonceLength])
        let plaintext = try ocb.open(nonce: nonce, ciphertext: Array(datagram[Self.nonceLength...]))
        var value: UInt64 = 0
        for i in 0..<Self.nonceLength {
            value = (value << 8) | UInt64(datagram[i])
        }
        return OpenedDatagram(
            direction: (value >> 63) == 1 ? .toClient : .toServer,
            seq: value & Self.maxSequence,
            plaintext: plaintext)
    }
}
