// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import MoshTerminal

/// What to do with the remote clipboard (OSC 52), docs/PLAN.md section 5. Decision logic only;
/// the app's `ClipboardWriter` does the writing to `UIPasteboard.general`.
///
/// Facts from mosh 1.4.0:
/// - The server's emulator keeps only `OSC 52 ; c ; <text>`: the five characters `52;c;` are
///   matched literally and everything after them is the clipboard, undecoded
///   (terminalfunctions.cc:594-600). Other selections (`52;;`, `52;p;`) are dropped there.
/// - The OSC string stops growing at `MAXIMUM_CLIPBOARD_SIZE` = 16 KiB characters
///   (terminaldispatcher.cc:45, 239-241), so a longer copy arrives cut off at 16384 - 5
///   characters of base64, silently.
/// - `Display::new_frame` writes the OSC only when the clipboard differs from the base state's
///   (terminaldisplay.cc:113-122), so copying the same text twice sends nothing the second time
///   (mosh issue 1090). There is no read support on either side.
///
/// Rules (PLAN.md section 5):
/// - Write only when a *live* state changes the field. A repaint of a state the policy has
///   already seen changes nothing. The stored screen of a restored session is observed against
///   the stored policy (`MoshSession.start()`): equal in the normal case, and a write only if
///   the snapshot caught a copy the policy had not seen yet.
/// - Strict base64 and strict UTF-8. Invalid or cut-off data is not written and is reported as
///   `.invalid` ("Clipboard data from the host was invalid or truncated").
/// - A query (`?`) is ignored. The app never reads the iOS clipboard for the remote.
/// - Skip a write whose content hash equals the last one written.
/// - The per-host switch (`isEnabled`) turns writing off.
public struct ClipboardPolicy: Equatable, Sendable {
    /// The longest clipboard field mosh can deliver: the OSC string cap minus `52;c;`. A field
    /// of this length may have been cut off and is treated as truncated.
    public static let truncatedLength = Dispatcher.maximumClipboardSize - 5

    /// What the app should do after a state was observed.
    public enum Decision: Equatable, Sendable {
        /// Write `text` to the pasteboard and show "Copied `byteCount` bytes".
        case write(text: String, byteCount: Int)
        /// Show "Clipboard data from the host was invalid or truncated". Nothing is written.
        case invalid(InvalidReason)
        /// Nothing to do: the field did not change, or the state was not live, or it is
        /// empty, a query, a duplicate of the last write, or writing is switched off.
        case none(Reason)
    }

    public enum InvalidReason: Error, Equatable, Sendable {
        /// At the 16 KiB cap: probably cut off by the server.
        case truncated
        /// Not strict base64.
        case notBase64
        /// Decodes, but not to valid UTF-8.
        case notUTF8
    }

    public enum Reason: Equatable, Sendable {
        case unchanged
        case notLive
        case empty
        case query
        case duplicate
        case disabled
    }

    /// The per-host switch.
    public var isEnabled: Bool
    /// The clipboard field of the last state observed (live or baseline); nil before the first.
    public private(set) var lastSeen: [UInt32]?
    /// FNV-1a 64 of the bytes last written. Stable across processes, so it can be stored with
    /// the session record.
    public private(set) var lastWrittenHash: UInt64?

    public init(isEnabled: Bool = true, lastSeen: [UInt32]? = nil, lastWrittenHash: UInt64? = nil) {
        self.isEnabled = isEnabled
        self.lastSeen = lastSeen
        self.lastWrittenHash = lastWrittenHash
    }

    /// Records the clipboard of a state shown without being live. Never writes. Not for the
    /// first screen of a restored session: that one is observed, so that a copy the stored
    /// policy had not seen is not lost.
    public mutating func baseline(_ clipboard: Framebuffer.Title) {
        lastSeen = clipboard
    }

    /// Observes the clipboard field of a new newest state.
    ///
    /// A change is measured against the last state observed, as mosh's display does between
    /// two frames. Before the first observation the field is compared with an empty one (state
    /// 0 has an empty clipboard).
    public mutating func observe(_ clipboard: Framebuffer.Title, live: Bool) -> Decision {
        guard live else {
            baseline(clipboard)
            return .none(.notLive)
        }
        let previous = lastSeen ?? []
        lastSeen = clipboard
        if clipboard == previous { return .none(.unchanged) }
        if clipboard.isEmpty { return .none(.empty) }
        if clipboard == [0x3F] { return .none(.query) }   // "?"
        guard isEnabled else { return .none(.disabled) }

        let text: String
        let bytes: [UInt8]
        switch Self.decode(clipboard) {
        case .failure(let reason): return .invalid(reason)
        case .success(let decoded): (text, bytes) = decoded
        }
        let hash = Self.fnv1a64(bytes)
        if hash == lastWrittenHash { return .none(.duplicate) }
        lastWrittenHash = hash
        return .write(text: text, byteCount: bytes.count)
    }

    /// Decodes the field: the length check, strict base64, strict UTF-8.
    public static func decode(_ clipboard: Framebuffer.Title) -> Result<(String, [UInt8]), InvalidReason> {
        if clipboard.count >= truncatedLength { return .failure(.truncated) }
        var ascii: [UInt8] = []
        ascii.reserveCapacity(clipboard.count)
        for point in clipboard {
            guard point < 0x80 else { return .failure(.notBase64) }
            ascii.append(UInt8(point))
        }
        guard let bytes = strictBase64Decode(ascii) else { return .failure(.notBase64) }
        let text = String(decoding: bytes, as: UTF8.self)
        // `String(decoding:)` replaces ill-formed sequences with U+FFFD; a round trip that
        // changes the bytes means the input was not valid UTF-8.
        guard text.utf8.elementsEqual(bytes) else { return .failure(.notUTF8) }
        return .success((text, bytes))
    }

    /// RFC 4648 section 4 base64, strictly: length a multiple of 4, only the 64 characters,
    /// `=` only as one or two final characters, and pad bits zero. No whitespace.
    public static func strictBase64Decode(_ text: [UInt8]) -> [UInt8]? {
        guard text.count % 4 == 0 else { return nil }
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return c - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return c - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0") + 52
            case UInt8(ascii: "+"): return 62
            case UInt8(ascii: "/"): return 63
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 4 * 3)
        var index = 0
        while index < text.count {
            let isLast = index + 4 == text.count
            let quad = text[index..<(index + 4)]
            let pad = quad.reversed().prefix { $0 == UInt8(ascii: "=") }.count
            guard pad == 0 || (isLast && pad <= 2) else { return nil }
            var values: [UInt8] = []
            for c in quad.prefix(4 - pad) {
                guard let v = value(c) else { return nil }
                values.append(v)
            }
            switch values.count {
            case 4:
                out.append(values[0] << 2 | values[1] >> 4)
                out.append(values[1] << 4 | values[2] >> 2)
                out.append(values[2] << 6 | values[3])
            case 3:
                guard values[2] & 0x03 == 0 else { return nil }
                out.append(values[0] << 2 | values[1] >> 4)
                out.append(values[1] << 4 | values[2] >> 2)
            case 2:
                guard values[1] & 0x0F == 0 else { return nil }
                out.append(values[0] << 2 | values[1] >> 4)
            default:
                return nil
            }
            index += 4
        }
        return out
    }

    /// FNV-1a, 64 bits.
    public static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
