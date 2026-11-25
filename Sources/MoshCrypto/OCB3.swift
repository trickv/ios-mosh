// OCB3 authenticated encryption, written from the pseudocode of RFC 7253 section 4.
// AES-128, 128-bit tag. mosh uses a 96-bit nonce and no associated data; the RFC's
// sample vectors also need associated data and both are supported here.

/// A 128-bit block as two big-endian halves. Doubling and XOR are then plain integer operations.
struct Block128: Equatable, Sendable {
    var hi: UInt64
    var lo: UInt64

    static let zero = Block128(hi: 0, lo: 0)

    init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    /// Reads 16 bytes of `bytes` starting at `offset`.
    init(_ bytes: [UInt8], at offset: Int = 0) {
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for i in 0..<8 {
            hi = (hi << 8) | UInt64(bytes[offset + i])
            lo = (lo << 8) | UInt64(bytes[offset + 8 + i])
        }
        self.hi = hi
        self.lo = lo
    }

    /// Writes the 16 bytes into `bytes` starting at `offset`.
    func store(into bytes: inout [UInt8], at offset: Int = 0) {
        for i in 0..<8 {
            let shift = UInt64(56 - 8 * i)
            bytes[offset + i] = UInt8(truncatingIfNeeded: hi >> shift)
            bytes[offset + 8 + i] = UInt8(truncatingIfNeeded: lo >> shift)
        }
    }

    var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        store(into: &out)
        return out
    }

    static func ^ (a: Block128, b: Block128) -> Block128 {
        Block128(hi: a.hi ^ b.hi, lo: a.lo ^ b.lo)
    }

    static func ^= (a: inout Block128, b: Block128) {
        a.hi ^= b.hi
        a.lo ^= b.lo
    }

    /// RFC 7253 `double(S)`: multiplication by x in GF(2^128). No branch on the data.
    func doubled() -> Block128 {
        let carry = hi >> 63
        return Block128(hi: (hi << 1) | (lo >> 63), lo: (lo << 1) ^ (carry &* 0x87))
    }
}

/// OCB3 (RFC 7253) with AES-128 and a 128-bit tag.
public struct OCB3: Sendable {
    /// Tag length in bytes. Only 128-bit tags are implemented.
    public static let tagLength = 16
    /// Longest nonce the RFC allows, in bytes (120 bits). mosh uses 12.
    public static let maxNonceLength = 15

    private let aes: AESBlock
    /// `L_*`, `L_$` and `L_0 ... L_63` of the RFC. 64 entries cover any length an `Int` can express.
    let lStar: Block128
    let lDollar: Block128
    let l: [Block128]

    /// - Parameter key: exactly 16 bytes.
    public init(key: [UInt8]) throws {
        let aes = try AESBlock(key: key)
        var zero = [UInt8](repeating: 0, count: 16)
        try aes.encrypt(&zero)
        let lStar = Block128(zero)
        let lDollar = lStar.doubled()
        var table: [Block128] = []
        table.reserveCapacity(64)
        var next = lDollar.doubled()
        for _ in 0..<64 {
            table.append(next)
            next = next.doubled()
        }
        self.aes = aes
        self.lStar = lStar
        self.lDollar = lDollar
        self.l = table
    }

    /// OCB-ENCRYPT. Returns the ciphertext followed by the 16-byte tag.
    ///
    /// The caller must never use the same nonce twice under one key.
    /// - Parameter nonce: 1 to 15 bytes.
    public func seal(nonce: [UInt8], plaintext: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        var offset = try initialOffset(nonce: nonce)
        var checksum = Block128.zero
        let fullBlocks = plaintext.count / 16
        let fullLength = fullBlocks * 16
        let remainder = plaintext.count - fullLength

        var out: [UInt8] = []
        out.reserveCapacity(plaintext.count + Self.tagLength)

        if fullBlocks > 0 {
            var buffer = Array(plaintext[0..<fullLength])
            var offsets: [Block128] = []
            offsets.reserveCapacity(fullBlocks)
            for i in 0..<fullBlocks {
                offset ^= l[(i + 1).trailingZeroBitCount]
                offsets.append(offset)
                let block = Block128(buffer, at: i * 16)
                checksum ^= block
                (block ^ offset).store(into: &buffer, at: i * 16)
            }
            try aes.encrypt(&buffer)
            for i in 0..<fullBlocks {
                (Block128(buffer, at: i * 16) ^ offsets[i]).store(into: &buffer, at: i * 16)
            }
            out.append(contentsOf: buffer)
        }

        if remainder > 0 {
            offset ^= lStar
            var pad = offset.bytes
            try aes.encrypt(&pad)
            var last = [UInt8](repeating: 0, count: 16)
            for j in 0..<remainder {
                let p = plaintext[fullLength + j]
                out.append(p ^ pad[j])
                last[j] = p
            }
            last[remainder] = 0x80
            checksum ^= Block128(last)
        }

        let tag = try self.tag(checksum: checksum, offset: offset, associatedData: associatedData)
        out.append(contentsOf: tag.bytes)
        return out
    }

    /// OCB-DECRYPT. `ciphertext` ends with the 16-byte tag.
    ///
    /// Throws `MoshCryptoError.authenticationFailed` when the tag does not verify; no plaintext is
    /// returned in that case. The tag comparison takes the same time whatever the data.
    public func open(nonce: [UInt8], ciphertext: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        guard ciphertext.count >= Self.tagLength else {
            throw MoshCryptoError.ciphertextTooShort(ciphertext.count)
        }
        var offset = try initialOffset(nonce: nonce)
        var checksum = Block128.zero
        let bodyLength = ciphertext.count - Self.tagLength
        let fullBlocks = bodyLength / 16
        let fullLength = fullBlocks * 16
        let remainder = bodyLength - fullLength

        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(bodyLength)

        if fullBlocks > 0 {
            var buffer = Array(ciphertext[0..<fullLength])
            var offsets: [Block128] = []
            offsets.reserveCapacity(fullBlocks)
            for i in 0..<fullBlocks {
                offset ^= l[(i + 1).trailingZeroBitCount]
                offsets.append(offset)
                (Block128(buffer, at: i * 16) ^ offset).store(into: &buffer, at: i * 16)
            }
            try aes.decrypt(&buffer)
            for i in 0..<fullBlocks {
                let block = Block128(buffer, at: i * 16) ^ offsets[i]
                checksum ^= block
                block.store(into: &buffer, at: i * 16)
            }
            plaintext.append(contentsOf: buffer)
        }

        if remainder > 0 {
            offset ^= lStar
            var pad = offset.bytes
            try aes.encrypt(&pad)
            var last = [UInt8](repeating: 0, count: 16)
            for j in 0..<remainder {
                let p = ciphertext[fullLength + j] ^ pad[j]
                plaintext.append(p)
                last[j] = p
            }
            last[remainder] = 0x80
            checksum ^= Block128(last)
        }

        let expected = try self.tag(checksum: checksum, offset: offset, associatedData: associatedData)
        let received = Block128(ciphertext, at: bodyLength)
        // Constant time: both halves are always compared, with no early exit.
        let difference = (expected.hi ^ received.hi) | (expected.lo ^ received.lo)
        guard difference == 0 else { throw MoshCryptoError.authenticationFailed }
        return plaintext
    }

    // MARK: - Pieces of the RFC pseudocode (internal so tests can check the RFC's intermediate values)

    /// `Offset_0` for a nonce: the nonce formatting, `Ktop`, `Stretch` and the shift by `bottom`.
    func initialOffset(nonce: [UInt8]) throws -> Block128 {
        guard nonce.count >= 1, nonce.count <= Self.maxNonceLength else {
            throw MoshCryptoError.invalidNonceLength(nonce.count)
        }
        // Nonce = num2str(TAGLEN mod 128, 7) || zeros(120 - bitlen(N)) || 1 || N.
        // TAGLEN is 128, so the first seven bits are zero.
        var block = [UInt8](repeating: 0, count: 16)
        block[15 - nonce.count] = 0x01
        for (i, byte) in nonce.enumerated() {
            block[16 - nonce.count + i] = byte
        }
        let bottom = Int(block[15] & 0x3F)
        block[15] &= 0xC0
        try aes.encrypt(&block) // Ktop
        // Stretch = Ktop || (Ktop[1..64] xor Ktop[9..72])
        var stretch = block
        for i in 0..<8 {
            stretch.append(block[i] ^ block[i + 1])
        }
        // Offset_0 = Stretch[1+bottom .. 128+bottom]
        let byteShift = bottom / 8
        let bitShift = bottom % 8
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            let high = stretch[i + byteShift]
            if bitShift == 0 {
                out[i] = high
            } else {
                out[i] = (high << UInt8(bitShift)) | (stretch[i + byteShift + 1] >> UInt8(8 - bitShift))
            }
        }
        return Block128(out)
    }

    /// RFC 7253 section 4.1, HASH(K, A).
    func hash(_ data: [UInt8]) throws -> Block128 {
        if data.isEmpty { return .zero }
        var sum = Block128.zero
        var offset = Block128.zero
        let fullBlocks = data.count / 16
        let fullLength = fullBlocks * 16
        let remainder = data.count - fullLength

        if fullBlocks > 0 {
            var buffer = Array(data[0..<fullLength])
            for i in 0..<fullBlocks {
                offset ^= l[(i + 1).trailingZeroBitCount]
                (Block128(buffer, at: i * 16) ^ offset).store(into: &buffer, at: i * 16)
            }
            try aes.encrypt(&buffer)
            for i in 0..<fullBlocks {
                sum ^= Block128(buffer, at: i * 16)
            }
        }

        if remainder > 0 {
            offset ^= lStar
            var last = [UInt8](repeating: 0, count: 16)
            for j in 0..<remainder {
                last[j] = data[fullLength + j]
            }
            last[remainder] = 0x80
            var input = (Block128(last) ^ offset).bytes
            try aes.encrypt(&input)
            sum ^= Block128(input)
        }
        return sum
    }

    /// `Tag = ENCIPHER(K, Checksum xor Offset xor L_$) xor HASH(K, A)`.
    private func tag(checksum: Block128, offset: Block128, associatedData: [UInt8]) throws -> Block128 {
        var block = (checksum ^ offset ^ lDollar).bytes
        try aes.encrypt(&block)
        return Block128(block) ^ (try hash(associatedData))
    }
}
