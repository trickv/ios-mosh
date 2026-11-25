// AES-128 on whole 16-byte blocks, with no chaining mode. OCB3 is built on top of this.
//
// Apple platforms: CommonCrypto (`CCCrypt`, ECB, no padding).
// Linux: the raw block permutation of swift-crypto's CryptoExtras (BoringSSL).
// The Apple branch cannot be compiled in the Linux dev container; keep it small and literal.

#if canImport(CommonCrypto)
import CommonCrypto
#elseif canImport(CryptoExtras)
import CryptoExtras
#else
#error("MoshCrypto needs CommonCrypto (Apple) or swift-crypto's CryptoExtras (Linux)")
#endif

/// AES-128 applied independently to each 16-byte block of a buffer (ECB, no padding).
///
/// This is a building block, not an encryption mode: never use it on its own.
public struct AESBlock: Sendable {
    /// AES block size in bytes.
    public static let blockSize = 16
    /// AES-128 key size in bytes.
    public static let keySize = 16

    #if canImport(CommonCrypto)
    private let key: [UInt8]
    #else
    private let key: SymmetricKey
    #endif

    /// - Parameter key: exactly 16 bytes.
    public init(key: [UInt8]) throws {
        guard key.count == Self.keySize else { throw MoshCryptoError.invalidKeyLength(key.count) }
        #if canImport(CommonCrypto)
        self.key = key
        #else
        self.key = SymmetricKey(data: key)
        #endif
    }

    /// Encrypts every 16-byte block of `blocks` in place. The count must be a multiple of 16.
    public func encrypt(_ blocks: inout [UInt8]) throws {
        try crypt(&blocks, encrypting: true)
    }

    /// Decrypts every 16-byte block of `blocks` in place. The count must be a multiple of 16.
    public func decrypt(_ blocks: inout [UInt8]) throws {
        try crypt(&blocks, encrypting: false)
    }

    #if canImport(CommonCrypto)

    private func crypt(_ blocks: inout [UInt8], encrypting: Bool) throws {
        let count = blocks.count
        guard count % Self.blockSize == 0 else { throw MoshCryptoError.invalidBlockLength(count) }
        if count == 0 { return }
        var moved = 0
        // ECB has no state between blocks, so one call covers the whole buffer.
        // CommonCrypto allows the input and output buffers to be the same.
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            blocks.withUnsafeMutableBytes { buffer in
                CCCrypt(
                    CCOperation(encrypting ? kCCEncrypt : kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, keyBytes.count,
                    nil,
                    buffer.baseAddress, count,
                    buffer.baseAddress, count,
                    &moved)
            }
        }
        guard Int(status) == Int(kCCSuccess), moved == count else {
            throw MoshCryptoError.aesFailure(Int(status))
        }
    }

    #else

    private func crypt(_ blocks: inout [UInt8], encrypting: Bool) throws {
        let count = blocks.count
        guard count % Self.blockSize == 0 else { throw MoshCryptoError.invalidBlockLength(count) }
        if count == 0 { return }
        let key = self.key
        try blocks.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset < count {
                var block = UnsafeMutableBufferPointer(rebasing: buffer[offset..<(offset + Self.blockSize)])
                if encrypting {
                    try AES.permute(&block, key: key)
                } else {
                    try AES.inversePermute(&block, key: key)
                }
                offset += Self.blockSize
            }
        }
    }

    #endif
}
