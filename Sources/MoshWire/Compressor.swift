// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// zlib framing of instructions: port of Network::Compressor (mosh src/network/compressor.cc),
// which calls zlib's one-shot compress() and uncompress(). The data on the wire is therefore a
// zlib stream (RFC 1950: two header bytes, deflate data, Adler-32), made at zlib's default level.

import CZlib

/// zlib `compress` and `uncompress` with mosh's size limit.
public enum Compressor {
    /// mosh's `Compressor::BUFFER_SIZE` = 2048 * 2048 bytes (4 MiB), "effective limit on terminal
    /// size". mosh compresses into and expands into a buffer of this size, so a peer cannot
    /// receive an instruction that is larger than this once expanded.
    public static let bufferSize = 2048 * 2048

    /// zlib `compress()` of `input`.
    ///
    /// Throws `WireError.compressionFailed` when zlib fails, and `WireError.instructionTooLarge` when
    /// `input` is larger than `bufferSize`: mosh could compress that if the result fits, but no mosh
    /// peer could expand it again, so the instruction would never be accepted.
    public static func compress(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count <= bufferSize else { throw WireError.instructionTooLarge(input.count) }
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = zlibCompress(&output, &length, input)
        guard status == Z_OK else { throw WireError.compressionFailed(status) }
        output.removeSubrange(Int(length)...)
        return output
    }

    /// zlib `uncompress()` of `input`.
    ///
    /// Throws `WireError.decompressionFailed` when the data is damaged or cut short, or when it
    /// expands to more than `bufferSize` bytes. Like zlib's `uncompress`, it accepts extra bytes
    /// after the end of the zlib stream and ignores them.
    public static func uncompress(_ input: [UInt8]) throws -> [UInt8] {
        // mosh always expands into its 4 MiB buffer. Start small and grow up to the same limit, so
        // that the usual instruction of a few hundred bytes does not cost 4 MiB.
        var capacity = min(bufferSize, max(1024, input.count * 4))
        while true {
            var length = uLong(capacity)
            var output = [UInt8](repeating: 0, count: capacity)
            let status = zlibUncompress(&output, &length, input)
            if status == Z_OK {
                output.removeSubrange(Int(length)...)
                return output
            }
            // Z_BUF_ERROR: the output buffer is too small. (Input that is cut short gives
            // Z_DATA_ERROR from uncompress, or Z_BUF_ERROR only once the buffer is full.)
            guard status == Z_BUF_ERROR, capacity < bufferSize else {
                throw WireError.decompressionFailed(status)
            }
            capacity = min(bufferSize, capacity * 4)
        }
    }
}

// zlib's functions have the names of the methods above. These wrappers sit at file scope, where
// the plain names mean the C functions.

private func zlibCompress(_ output: inout [UInt8], _ length: inout uLong, _ input: [UInt8]) -> Int32 {
    compress(&output, &length, input, uLong(input.count))
}

private func zlibUncompress(_ output: inout [UInt8], _ length: inout uLong, _ input: [UInt8]) -> Int32 {
    uncompress(&output, &length, input, uLong(input.count))
}
