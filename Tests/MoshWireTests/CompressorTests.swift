import XCTest
import MoshTestSupport
import MoshWire

final class CompressorTests: XCTestCase {
    /// Buffers produced by real zlib: Python's `zlib.compress(data, level)` in the dev container
    /// (zlib 1.3). Levels 9 and 0 show that any valid zlib stream is accepted, not only our own.
    private let pythonVectors: [(name: String, plain: [UInt8], compressed: String)] = [
        ("empty", [], "789c030000000001"),
        ("hello", Array("hello, mosh".utf8), "789ccb48cdc9c9d751c8cd2fce000018a10418"),
        ("first instruction", bytes(hex: "0802100018012000280032080a061a04285030183a00"),
         "789ce360126090605460d06030e2e0629362d1083090b0620000105301de"),
        ("1000 x a", [UInt8](repeating: 0x61, count: 1000), "789c4b4c1c05a360140c770000f9d87af8"),
        ("level 9", Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20).utf8),
         "78da0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb29848c2a"
            + "1e553caa98da8a0147a5431c"),
        ("level 0 (stored)", (0...255).map { UInt8($0) },
         "7801010001fffe" + hex((0...255).map { UInt8($0) }) + "adf67f81"),
    ]

    func testUncompressesBuffersMadeByRealZlib() throws {
        for vector in pythonVectors {
            XCTAssertEqual(try Compressor.uncompress(bytes(hex: vector.compressed)), vector.plain, vector.name)
        }
    }

    /// mosh calls `compress()`, which is zlib's default level; so does Python's default. The dev
    /// container's zlib gives the same bytes for both, which shows the framing is the same. (Another
    /// zlib version may choose different deflate bytes for the same level, so only the level-default
    /// vectors are compared, and only where the library is the one that made them.)
    func testCompressGivesAZlibStream() throws {
        for vector in pythonVectors {
            let compressed = try Compressor.compress(vector.plain)
            // RFC 1950: CM = 8 (deflate), 32K window; CMF * 256 + FLG is a multiple of 31.
            XCTAssertEqual(compressed[0], 0x78, vector.name)
            XCTAssertEqual((Int(compressed[0]) * 256 + Int(compressed[1])) % 31, 0, vector.name)
            // Default compression level: FLEVEL = 2, so the second byte is 0x9C.
            XCTAssertEqual(compressed[1], 0x9C, vector.name)
            // The last four bytes are the Adler-32 of the plain data, big-endian.
            XCTAssertEqual(Array(compressed.suffix(4)), adler32(vector.plain), vector.name)
            XCTAssertEqual(try Compressor.uncompress(compressed), vector.plain, vector.name)
        }
        #if os(Linux)
        for vector in pythonVectors.prefix(4) {
            XCTAssertEqual(hex(try Compressor.compress(vector.plain)), vector.compressed, vector.name)
        }
        #endif
    }

    private func adler32(_ data: [UInt8]) -> [UInt8] {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let value = (b << 16) | a
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    func testRoundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 2, 15, 16, 17, 255, 256, 1000, 1023, 1024, 1025, 4095, 4096, 4097, 70_000, 300_000] {
            // Random bytes do not compress; zeros compress about a thousand times. Both must come back.
            let random = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(try Compressor.uncompress(try Compressor.compress(random)), random, "random \(length)")
            let zeros = [UInt8](repeating: 0, count: length)
            XCTAssertEqual(try Compressor.uncompress(try Compressor.compress(zeros)), zeros, "zeros \(length)")
            let text: [UInt8] = (0..<length).map { (index: Int) -> UInt8 in
                let value: Int = 0x20 + (index * 7 + index / 13) % 90
                return UInt8(value)
            }
            XCTAssertEqual(try Compressor.uncompress(try Compressor.compress(text)), text, "text \(length)")
        }
    }

    func testDamagedInputIsRejected() throws {
        let plain = Array(String(repeating: "mosh ", count: 200).utf8)
        let good = try Compressor.compress(plain)

        // Cut short at every length.
        for length in 0..<good.count {
            XCTAssertThrowsError(try Compressor.uncompress(Array(good[0..<length])), "length \(length)") { error in
                guard case .decompressionFailed? = error as? WireError else { return XCTFail("\(error)") }
            }
        }
        // A wrong checksum.
        var badChecksum = good
        badChecksum[badChecksum.count - 1] ^= 0x01
        XCTAssertThrowsError(try Compressor.uncompress(badChecksum))
        // A wrong header.
        var badHeader = good
        badHeader[0] = 0x00
        XCTAssertThrowsError(try Compressor.uncompress(badHeader))
        // Not zlib at all.
        XCTAssertThrowsError(try Compressor.uncompress(Array("plain text, not zlib".utf8)))
        XCTAssertThrowsError(try Compressor.uncompress([]))
        // A raw deflate stream and a gzip stream are not accepted either: mosh uses the zlib wrapper.
        XCTAssertThrowsError(try Compressor.uncompress(Array(good[2..<(good.count - 4)])))
        XCTAssertThrowsError(try Compressor.uncompress(bytes(hex: "1f8b0800000000000003030000000000000000")))
    }

    /// zlib's `uncompress` stops at the end of the stream and ignores what follows; mosh inherits that.
    func testBytesAfterTheStreamAreIgnored() throws {
        let plain = Array("hello, mosh".utf8)
        let good = try Compressor.compress(plain)
        XCTAssertEqual(try Compressor.uncompress(good + [0xDE, 0xAD, 0xBE, 0xEF]), plain)
    }

    /// mosh's 4 MiB buffer: exactly 4 MiB expands, one byte more does not, and we refuse to send
    /// what no peer could expand.
    func testSizeLimit() throws {
        XCTAssertEqual(Compressor.bufferSize, 2048 * 2048)
        XCTAssertEqual(Compressor.bufferSize, 4_194_304)

        let atLimit = [UInt8](repeating: 0x20, count: Compressor.bufferSize)
        let compressed = try Compressor.compress(atLimit)
        XCTAssertLessThan(compressed.count, 8192)
        XCTAssertEqual(try Compressor.uncompress(compressed).count, Compressor.bufferSize)

        let overLimit = [UInt8](repeating: 0x20, count: Compressor.bufferSize + 1)
        XCTAssertThrowsError(try Compressor.compress(overLimit)) { error in
            XCTAssertEqual(error as? WireError, .instructionTooLarge(Compressor.bufferSize + 1))
        }
    }

    /// A zlib stream that expands to one byte more than 4 MiB, made by real zlib: Python's
    /// `zlib.compress(b" " * 4194305)` gives 4100 bytes. Rather than embed them, build the same
    /// stream here from stored deflate blocks, which need no compressor.
    func testStreamThatExpandsPastTheLimitIsRejected() throws {
        func storedStream(count: Int) -> [UInt8] {
            var out: [UInt8] = [0x78, 0x01]
            var remaining = count
            var a: UInt32 = 1
            var b: UInt32 = 0
            repeat {
                let chunk = min(remaining, 65535)
                remaining -= chunk
                out.append(remaining == 0 ? 0x01 : 0x00) // BFINAL, BTYPE = 00 (stored)
                out.append(UInt8(chunk & 0xFF))
                out.append(UInt8(chunk >> 8))
                out.append(UInt8(~chunk & 0xFF))
                out.append(UInt8((~chunk >> 8) & 0xFF))
                out.append(contentsOf: [UInt8](repeating: 0x20, count: chunk))
                for _ in 0..<chunk {
                    a = (a + 0x20) % 65521
                    b = (b + a) % 65521
                }
            } while remaining > 0
            let adler = (b << 16) | a
            out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
            return out
        }
        // The builder is right: a small stream and one of exactly 4 MiB expand.
        XCTAssertEqual(try Compressor.uncompress(storedStream(count: 70_000)), [UInt8](repeating: 0x20, count: 70_000))
        XCTAssertEqual(try Compressor.uncompress(storedStream(count: Compressor.bufferSize)).count, Compressor.bufferSize)
        // One byte more does not.
        XCTAssertThrowsError(try Compressor.uncompress(storedStream(count: Compressor.bufferSize + 1))) { error in
            guard case .decompressionFailed? = error as? WireError else { return XCTFail("\(error)") }
        }
    }
}
