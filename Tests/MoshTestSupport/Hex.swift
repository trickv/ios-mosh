// Shared test helpers. Each helper lives in its own file so parallel work does not collide.

/// Bytes from a hex string. Spaces and newlines are ignored. Traps on bad input (test code).
public func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var high: UInt8? = nil
    for c in hex.utf8 {
        let v: UInt8
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
        case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"): continue
        default: preconditionFailure("bad hex digit")
        }
        if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
    }
    precondition(high == nil, "odd number of hex digits")
    return out
}

/// Lowercase hex of bytes.
public func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
    return String(decoding: out, as: UTF8.self)
}
