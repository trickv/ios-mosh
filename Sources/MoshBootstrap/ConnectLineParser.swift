// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

/// Finds what `mosh-server new` prints when it starts, in the byte stream of the SSH channel.
///
/// The server writes (mosh 1.4.0, `mosh-server.cc` `run_server`):
///
///     MOSH CONNECT <udp port> <22 base64 characters>
///     ...licence text...
///     [mosh-server detached, pid = <N>]
///
/// With a pty the stream uses CR LF, stderr is merged into it, and a message of the day or a
/// shell banner may come first. Data arrives in arbitrary pieces, so a line can be split across
/// calls to `feed`. The parser works on bytes and line by line, removes every CR, and matches
/// the first line of the form `^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\s*$`, as the `mosh`
/// wrapper script does.
public struct ConnectLineParser: Sendable {
    public struct Connect: Equatable, Sendable {
        /// The UDP port the server listens on.
        public let port: Int
        /// The session key as printed: 22 base64 characters for 16 bytes, without padding.
        public let key: String

        public init(port: Int, key: String) {
            self.port = port
            self.key = key
        }
    }

    /// A reason for a missing `MOSH CONNECT` that can be read from the output.
    public enum StartFailure: Equatable, Sendable {
        /// The shell could not find or run the server program.
        case serverNotFound
        /// `mosh-server needs a UTF-8 native locale to run.`
        case localeMissing
    }

    /// The first `MOSH CONNECT` line seen.
    public private(set) var connect: Connect?
    /// The pid from the first `[mosh-server detached, pid = N]` line seen.
    public private(set) var serverPID: Int32?

    private var pending: [UInt8] = []
    private var lines: [String] = []
    private var retainedBytes = 0
    private let maxRetainedBytes: Int
    /// A line longer than this is cut; nothing the server prints comes close.
    private static let maxLineBytes = 8192

    /// - Parameter maxRetainedBytes: how much output `text` keeps (the newest lines).
    public init(maxRetainedBytes: Int = 16 * 1024) {
        self.maxRetainedBytes = max(maxRetainedBytes, 256)
    }

    /// Both lines have been seen.
    public var isComplete: Bool { connect != nil && serverPID != nil }

    /// The output so far as text: complete lines plus the unfinished last one, CR removed,
    /// joined with LF. Only the newest part is kept if the host printed a lot.
    public var text: String {
        var all = lines
        if !pending.isEmpty { all.append(Self.decode(pending)) }
        return all.joined(separator: "\n")
    }

    /// Adds received bytes.
    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes {
            if byte == 0x0a {
                completeLine()
            } else if byte != 0x0d, pending.count < Self.maxLineBytes {
                pending.append(byte)
            }
        }
    }

    public mutating func feed(_ text: String) {
        feed(text.utf8)
    }

    /// The stream has ended: an unfinished last line counts as a line.
    public mutating func finish() {
        if !pending.isEmpty { completeLine() }
    }

    /// What the output says about why there is no `MOSH CONNECT`, if it says anything.
    public var startFailure: StartFailure? {
        Self.recognizeFailure(in: text)
    }

    private mutating func completeLine() {
        let line = Self.decode(pending)
        pending.removeAll(keepingCapacity: true)
        if connect == nil, let found = Self.parseConnectLine(line) { connect = found }
        if serverPID == nil, let pid = Self.parseDetachedLine(line) { serverPID = pid }
        lines.append(line)
        retainedBytes += line.utf8.count + 1
        while retainedBytes > maxRetainedBytes, lines.count > 1 {
            retainedBytes -= lines.removeFirst().utf8.count + 1
        }
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Line matchers

    /// `^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\s*$`. The line must not contain a line break; CR
    /// characters anywhere in it are ignored.
    public static func parseConnectLine(_ line: String) -> Connect? {
        var bytes = line.utf8.filter { $0 != 0x0d }
        while let last = bytes.last, last == 0x20 || last == 0x09 || last == 0x0b || last == 0x0c {
            bytes.removeLast()
        }
        let prefix = Array("MOSH CONNECT ".utf8)
        guard bytes.count > prefix.count, bytes.starts(with: prefix) else { return nil }
        let rest = bytes[prefix.count...]
        let digits = rest.prefix(while: isDigit)
        guard !digits.isEmpty, digits.count <= 5 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard afterDigits.first == 0x20 else { return nil }
        let key = afterDigits.dropFirst()
        guard key.count == 22, key.allSatisfy(isBase64) else { return nil }
        guard let port = Int(String(decoding: digits, as: UTF8.self)), port >= 1, port <= 65535 else { return nil }
        return Connect(port: port, key: String(decoding: key, as: UTF8.self))
    }

    /// The pid in `[mosh-server detached, pid = N]`, anywhere in the line.
    public static func parseDetachedLine(_ line: String) -> Int32? {
        let bytes = Array(line.utf8)
        let marker = Array("[mosh-server detached, pid = ".utf8)
        guard bytes.count > marker.count else { return nil }
        var start = 0
        while start + marker.count < bytes.count {
            if bytes[start..<(start + marker.count)].elementsEqual(marker) {
                let rest = bytes[(start + marker.count)...]
                let digits = rest.prefix(while: isDigit)
                if !digits.isEmpty, digits.count <= 10, rest.dropFirst(digits.count).first == UInt8(ascii: "]"),
                    let pid = Int32(String(decoding: digits, as: UTF8.self)), pid > 0
                {
                    return pid
                }
            }
            start += 1
        }
        return nil
    }

    /// Recognises the failure texts of the plan's error table in server or shell output.
    ///
    /// The locale message is checked first: when the locale is missing, mosh-server also runs
    /// `locale`, which prints "No such file or directory" lines of its own.
    public static func recognizeFailure(in text: String) -> StartFailure? {
        let lowered = text.lowercased()
        if lowered.contains("needs a utf-8 native locale") { return .localeMissing }
        // sh, dash: "mosh-server: not found". bash, zsh: "command not found". A path that does
        // not exist: "No such file or directory". fish: "Unknown command". csh: "Command not found."
        for phrase in ["command not found", ": not found", "no such file or directory", "unknown command"] {
            if lowered.contains(phrase) { return .serverNotFound }
        }
        return nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
            || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "+")
    }
}
