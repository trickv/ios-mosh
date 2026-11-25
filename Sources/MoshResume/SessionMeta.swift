import MoshCrypto
import MoshSession
import MoshTransport

/// The name of a session record: 16 random bytes, written as a UUID. It is the directory name,
/// the Keychain account on iOS, and it is repeated inside every part of the record, so that a
/// part copied into another session's directory is refused.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public static let length = 16

    public let bytes: [UInt8]

    /// Nil unless exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    /// A new random id (a version 4 UUID).
    public static func random() -> SessionID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random(using generator: inout some RandomNumberGenerator) -> SessionID {
        var bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return SessionID(bytes: bytes)!
    }

    /// From the form `description` gives. Lowercase only, so that one id has one directory name.
    public init?(_ text: String) {
        let characters = Array(text.utf8)
        guard characters.count == 36 else { return nil }
        var bytes: [UInt8] = []
        var high: UInt8?
        for (index, character) in characters.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard character == UInt8(ascii: "-") else { return nil }
                continue
            }
            let nibble: UInt8
            switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = character - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = character - UInt8(ascii: "a") + 10
            default: return nil
            }
            if let first = high {
                bytes.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, lowercase.
    public var description: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            if [4, 6, 8, 10].contains(index) { text.append(UInt8(ascii: "-")) }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}

/// What a cold start needs to know about a session besides its key, counters and snapshot
/// (docs/PLAN.md section 3, `meta`). Written once, when the record is made.
public struct SessionMeta: Equatable, Sendable {
    /// Longest string, in UTF-8 bytes.
    public static let maxStringBytes = 4096

    public var id: SessionID
    /// Seconds since 1970.
    public var createdAt: UInt64
    /// The host as the user named it (for the session list and for a new bootstrap).
    public var hostName: String
    /// The numeric address the datagrams go to (`SessionEndpoint.host`).
    public var address: String
    /// The server's UDP port.
    public var port: UInt16
    public var user: String
    /// The host entry's remote command (empty: the login shell), for the fallback's bootstrap.
    public var remoteCommand: String
    /// The size the server's terminal had when it started (the size of remote state 0).
    public var serverStartSize: TerminalSize
    /// The process id of `mosh-server`; 0 if not known.
    public var serverPID: UInt32
    /// The server process's start time as the host reports it (opaque; 0 if not known). With
    /// the pid it identifies the process for the fallback's kill.
    public var serverStartTime: UInt64

    public init(
        id: SessionID = .random(),
        createdAt: UInt64,
        hostName: String,
        address: String,
        port: UInt16,
        user: String = "",
        remoteCommand: String = "",
        serverStartSize: TerminalSize,
        serverPID: UInt32 = 0,
        serverStartTime: UInt64 = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.hostName = hostName
        self.address = address
        self.port = port
        self.user = user
        self.remoteCommand = remoteCommand
        self.serverStartSize = serverStartSize
        self.serverPID = serverPID
        self.serverStartTime = serverStartTime
    }

    /// Where the session's datagrams go.
    public func endpoint(key: Base64Key) -> SessionEndpoint {
        SessionEndpoint(host: address, port: port, key: key)
    }
}

extension SessionMeta {
    static let magic = Array("MRm1".utf8)
    public static let formatVersion: UInt16 = 1

    /// Throws `invalid` for a value the format cannot hold (a string that is too long, an empty
    /// address, port 0).
    public func encoded() throws -> [UInt8] {
        try validate()
        var body = RecordWriter()
        body.raw(id.bytes)
        body.u64(createdAt)
        body.u16(port)
        body.u16(serverStartSize.width)
        body.u16(serverStartSize.height)
        body.u16(0)
        body.u32(serverPID)
        body.u64(serverStartTime)
        body.string(hostName)
        body.string(address)
        body.string(user)
        body.string(remoteCommand)
        return PartFrame.wrap(magic: Self.magic, version: Self.formatVersion, body: body.bytes)
    }

    private func validate() throws {
        func invalid(_ text: String) -> RecordFormatError { RecordFormatError(.meta, .invalid(text)) }
        guard !address.isEmpty else { throw invalid("the address is empty") }
        guard port != 0 else { throw invalid("the port is 0") }
        for text in [hostName, address, user, remoteCommand] where text.utf8.count > Self.maxStringBytes {
            throw invalid("a string is longer than \(Self.maxStringBytes) bytes")
        }
    }

    /// - Parameter expecting: the id of the directory the bytes were read from.
    public init(encoded bytes: [UInt8], expecting expected: SessionID? = nil) throws {
        let body = try PartFrame.unwrap(bytes, part: .meta, magic: Self.magic, version: Self.formatVersion)
        var reader = RecordReader(body, part: .meta)
        guard let id = SessionID(bytes: try reader.raw(SessionID.length)) else { throw reader.fail(.truncated) }
        let createdAt = try reader.u64()
        let port = try reader.u16()
        let width = try reader.u16()
        let height = try reader.u16()
        guard try reader.u16() == 0 else { throw reader.invalid("reserved field is not 0") }
        let serverPID = try reader.u32()
        let serverStartTime = try reader.u64()
        let hostName = try reader.string()
        let address = try reader.string()
        let user = try reader.string()
        let remoteCommand = try reader.string()
        try reader.finish()
        guard width >= 1, height >= 1 else { throw reader.invalid("server start size \(width)x\(height)") }
        if let expected, expected != id { throw reader.fail(.wrongSession) }
        self.init(id: id, createdAt: createdAt, hostName: hostName, address: address, port: port, user: user,
                  remoteCommand: remoteCommand, serverStartSize: TerminalSize(width: width, height: height),
                  serverPID: serverPID, serverStartTime: serverStartTime)
        try validate()
    }
}

/// The `key` part: the session key, for platforms without a keychain (Linux, `moshcli`). On iOS
/// the key is a Keychain item whose account is the session id, and this file is not written.
public enum StoredKey {
    static let magic = Array("MRk1".utf8)
    public static let formatVersion: UInt16 = 1

    public static func encode(_ key: Base64Key, id: SessionID) -> [UInt8] {
        PartFrame.wrap(magic: magic, version: formatVersion, body: id.bytes + key.bytes)
    }

    public static func decode(_ bytes: [UInt8], expecting expected: SessionID) throws -> Base64Key {
        let body = try PartFrame.unwrap(bytes, part: .key, magic: magic, version: formatVersion)
        var reader = RecordReader(body, part: .key)
        let id = try reader.raw(SessionID.length)
        let keyBytes = try reader.raw(Base64Key.length)
        try reader.finish()
        guard id == expected.bytes else { throw reader.fail(.wrongSession) }
        do {
            return try Base64Key(bytes: keyBytes)
        } catch {
            throw reader.invalid("the key is not usable: \(error)")
        }
    }
}
