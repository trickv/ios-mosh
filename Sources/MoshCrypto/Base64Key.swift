// The 128-bit session key as mosh prints and parses it: 22 base64 characters, the two
// padding characters left off. Port of Base64Key in mosh's src/crypto/crypto.cc and of
// src/crypto/base64.cc (which only handles this one size).

/// A mosh session key: 16 bytes, printed as 22 base64 characters.
public struct Base64Key: Equatable, Sendable, CustomStringConvertible {
    /// Key length in bytes.
    public static let length = 16
    /// Length of the printable form in characters.
    public static let printableLength = 22

    /// The 16 key bytes.
    public let bytes: [UInt8]

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// - Parameter bytes: exactly 16 bytes.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.length else { throw MoshCryptoError.invalidKeyLength(bytes.count) }
        self.bytes = bytes
    }

    /// Parses the form printed by `mosh-server` in its `MOSH CONNECT <port> <key>` line.
    ///
    /// Same checks as mosh: exactly 22 characters, all from the base64 alphabet, and the text must
    /// be the canonical encoding of the decoded key. The last character carries only two key bits;
    /// mosh rejects a key whose other four bits are set, and so does this.
    public init(printable: String) throws {
        let text = Array(printable.utf8)
        guard text.count == Self.printableLength else {
            throw MoshCryptoError.invalidBase64Key("Key must be 22 letters long.")
        }
        var out: [UInt8] = []
        out.reserveCapacity(Self.length)
        var accumulator: UInt32 = 0
        for (i, character) in text.enumerated() {
            guard let sixBits = Self.sixBits(character) else {
                throw MoshCryptoError.invalidBase64Key("Key must be well-formed base64.")
            }
            accumulator = (accumulator << 6) | UInt32(sixBits)
            if i % 4 == 3 {
                out.append(UInt8(truncatingIfNeeded: accumulator >> 16))
                out.append(UInt8(truncatingIfNeeded: accumulator >> 8))
                out.append(UInt8(truncatingIfNeeded: accumulator))
                accumulator = 0
            }
        }
        // Two characters are left in the accumulator: 12 bits, of which the top 8 are the last byte.
        out.append(UInt8(truncatingIfNeeded: accumulator >> 4))
        self.bytes = out
        // "to catch changes after the first 128 bits"
        guard Array(self.printable.utf8) == text else {
            throw MoshCryptoError.invalidBase64Key("Base64 key was not encoded 128-bit key.")
        }
    }

    /// The 22-character form.
    public var printable: String {
        var out: [UInt8] = []
        out.reserveCapacity(Self.printableLength)
        var index = 0
        for _ in 0..<5 {
            let group = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8) | UInt32(bytes[index + 2])
            out.append(Self.alphabet[Int((group >> 18) & 0x3F)])
            out.append(Self.alphabet[Int((group >> 12) & 0x3F)])
            out.append(Self.alphabet[Int((group >> 6) & 0x3F)])
            out.append(Self.alphabet[Int(group & 0x3F)])
            index += 3
        }
        let last = bytes[15]
        out.append(Self.alphabet[Int((last >> 2) & 0x3F)])
        out.append(Self.alphabet[Int((last << 4) & 0x3F)])
        return String(decoding: out, as: UTF8.self)
    }

    /// A new random key from the system's secure random generator. The client never needs this
    /// (the server makes the key); tests and tools that play the server do.
    public static func random() -> Base64Key {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for _ in 0..<length {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return Base64Key(unchecked: bytes)
    }

    /// Does not reveal the key, so that a key never reaches a log by accident. Use `printable`.
    public var description: String { "Base64Key(<redacted>)" }

    private init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }

    private static func sixBits(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
