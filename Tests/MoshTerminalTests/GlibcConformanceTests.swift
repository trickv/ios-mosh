// The two places where the port stands in for the C library that mosh calls:
// `glibcMbrtowc` for mbrtowc() and `WCWidth` for wcwidth(). On Linux they are compared
// with the real functions.

#if canImport(Glibc)
import Glibc
import XCTest
@testable import MoshTerminal

// Swift's Glibc module does not export <wchar.h>. These bind the C symbols directly;
// with only integer and pointer arguments the Swift and C calling conventions agree.
@_silgen_name("wcwidth") private func c_wcwidth(_ c: Int32) -> Int32
@_silgen_name("gnu_get_libc_version") private func c_gnu_get_libc_version() -> UnsafePointer<CChar>
@_silgen_name("mbrtowc") private func c_mbrtowc(_ pwc: UnsafeMutablePointer<Int32>?, _ s: UnsafePointer<CChar>?,
                                                _ n: Int, _ ps: UnsafeMutableRawPointer?) -> Int

final class GlibcConformanceTests: XCTestCase {
    private func useUTF8Locale() throws {
        guard setlocale(LC_ALL, "en_US.UTF-8") != nil || setlocale(LC_ALL, "C.UTF-8") != nil else {
            throw XCTSkip("no UTF-8 locale available")
        }
    }

    /// The real mbrtowc on a fresh state, in the port's result type. `bits` holds the
    /// buffer with its first byte in the low 8 bits.
    private func real(_ bits: UInt64, _ count: Int) -> MBResult {
        // mbstate_t is 8 bytes in glibc; all zero is the initial state
        var ps: (UInt64, UInt64) = (0, 0)
        var wc: Int32 = 0
        var buf = bits.littleEndian
        let r = withUnsafeBytes(of: &buf) { raw in
            withUnsafeMutableBytes(of: &ps) { state in
                c_mbrtowc(&wc, raw.baseAddress!.assumingMemoryBound(to: CChar.self), count, state.baseAddress)
            }
        }
        switch r {
        case 0: return .nul
        case -1: return .invalid
        case -2: return .incomplete
        default: return .character(length: r, value: UInt32(bitPattern: wc))
        }
    }

    func testMbrtowcMatchesGlibc() throws {
        try useUTF8Locale()
        var compared = 0
        var mismatches: [String] = []
        func check(_ bits: UInt64, _ count: Int) {
            compared += 1
            let want = real(bits, count)
            let got = glibcMbrtowc(bits, count: count)
            if want != got && mismatches.count < 20 {
                mismatches.append("\(String(bits, radix: 16)) (\(count) bytes, first byte lowest): glibc \(want), port \(got)")
            }
        }

        // every buffer of one and two bytes, and every three-byte buffer whose first byte
        // asks for three bytes or more
        for a in UInt64(0)...255 { check(a, 1) }
        for a in UInt64(0)...255 { for b in UInt64(0)...255 { check(a | b << 8, 2) } }
        for a in UInt64(0xE0)...255 { for b in UInt64(0)...255 { for c in UInt64(0)...255 { check(a | b << 8 | c << 16, 3) } } }
        // longer buffers: all lead bytes, the values around every boundary in the other positions
        let near: [UInt64] = [0x00, 0x41, 0x7F, 0x80, 0x81, 0x83, 0x84, 0x87, 0x88, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xF4, 0xFF]
        let far: [UInt64] = [0x00, 0x7F, 0x80, 0x8F, 0x90, 0xBF, 0xC0, 0xFF]
        for a in UInt64(0x80)...0xDF { for b in near { for c in near { check(a | b << 8 | c << 16, 3) } } }
        for a in UInt64(0xE0)...255 {
            for b in near { for c in far { for d in far {
                let four = a | b << 8 | c << 16 | d << 24
                check(four, 4)
                for e in far {
                    check(four | e << 32, 5)
                    for f in far { check(four | e << 32 | f << 40, 6) }
                }
            } } }
        }
        XCTAssertEqual(mismatches, [])
        XCTAssertGreaterThan(compared, 2_000_000)
    }

    func testWCWidthTableMatchesGlibc() throws {
        try useUTF8Locale()
        let version = String(cString: c_gnu_get_libc_version())
        guard version == WCWidthTable.glibcVersion else {
            throw XCTSkip("the table is glibc \(WCWidthTable.glibcVersion)'s; this is glibc \(version)")
        }
        var mismatches: [String] = []
        for cp in UInt32(0)...UInt32(0x10FFFF) {
            let want = Int(c_wcwidth(Int32(cp)))
            let got = WCWidth.wcwidth(cp)
            if want != got && mismatches.count < 20 {
                mismatches.append("U+\(String(cp, radix: 16)): glibc \(want), table \(got)")
            }
        }
        XCTAssertEqual(mismatches, [])
    }
}
#endif
