import MoshKeys

/// The algorithm lists a server announces in its `SSH_MSG_KEXINIT`, the first packet after the
/// version line (RFC 4253 section 7.1). It is sent in clear text.
///
/// swift-nio-ssh reports every failed negotiation as the same `keyExchangeNegotiationFailure`
/// without saying which list had no match. The bootstrap therefore reads the server's lists
/// itself, to tell "this host has only RSA host keys" apart from other mismatches.
public struct ServerAlgorithms: Equatable, Sendable {
    /// For example `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20`.
    public var identification: String
    public var keyExchange: [String]
    public var hostKey: [String]
    public var encryptionClientToServer: [String]
    public var encryptionServerToClient: [String]

    public init(
        identification: String = "", keyExchange: [String] = [], hostKey: [String] = [],
        encryptionClientToServer: [String] = [], encryptionServerToClient: [String] = []
    ) {
        self.identification = identification
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.encryptionClientToServer = encryptionClientToServer
        self.encryptionServerToClient = encryptionServerToClient
    }

    /// Which negotiation has no common algorithm with this client, if any. Checked in the order
    /// that matters to a user: a host with only RSA host keys is the common case.
    public enum Mismatch: Equatable, Sendable {
        case hostKey
        case keyExchange
        case encryption
    }

    public var mismatch: Mismatch? {
        let client = ClientAlgorithms.self
        if !hostKey.contains(where: client.hostKey.contains) { return .hostKey }
        if !keyExchange.contains(where: client.keyExchange.contains) { return .keyExchange }
        if !encryptionClientToServer.contains(where: client.encryption.contains)
            || !encryptionServerToClient.contains(where: client.encryption.contains)
        {
            return .encryption
        }
        return nil
    }
}

/// What swift-nio-ssh 0.15.1 offers as a client. Copied from its source, because the lists are
/// not public: `SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms`,
/// the `keyExchangeAlgorithmNames` in `ECDHCompatibleKey.swift`, and the cipher names in
/// `AESGCM.swift`. Update together with the pinned version.
public enum ClientAlgorithms {
    public static let hostKey: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521",
    ]
    public static let keyExchange: Set<String> = [
        "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384",
        "ecdh-sha2-nistp521",
    ]
    public static let encryption: Set<String> = ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"]
}

/// Reads the server's identification line and `SSH_MSG_KEXINIT` from the start of the TCP
/// stream. Feed it the bytes as they arrive; it keeps a copy only until it is done.
public struct ServerKexInitParser: Sendable {
    public enum State: Equatable, Sendable {
        case needMoreData
        case parsed(ServerAlgorithms)
        /// The stream does not start like an SSH server's. Nothing more will be parsed.
        case invalid
    }

    public private(set) var state: State = .needMoreData
    private var buffer: [UInt8] = []

    /// The identification line may be preceded by other lines and is at most 255 bytes; a
    /// KEXINIT packet is small. Anything beyond this is not an SSH handshake.
    static let maxBytes = 64 * 1024

    public init() {}

    @discardableResult
    public mutating func feed<S: Sequence>(_ bytes: S) -> State where S.Element == UInt8 {
        guard state == .needMoreData else { return state }
        buffer.append(contentsOf: bytes)
        state = Self.parse(buffer)
        if state == .needMoreData, buffer.count > Self.maxBytes { state = .invalid }
        if state != .needMoreData { buffer = [] }
        return state
    }

    /// Parses a prefix of the server's byte stream.
    public static func parse(_ bytes: [UInt8]) -> State {
        // 1. Lines until the one that starts with "SSH-" (RFC 4253 section 4.2).
        var offset = 0
        var identification: String?
        while identification == nil {
            guard let newline = bytes[offset...].firstIndex(of: 0x0a) else {
                return bytes.count - offset > 8192 ? .invalid : .needMoreData
            }
            var line = Array(bytes[offset..<newline])
            if line.last == 0x0d { line.removeLast() }
            offset = newline + 1
            if line.starts(with: Array("SSH-".utf8)) {
                identification = String(decoding: line, as: UTF8.self)
            }
        }

        // 2. One binary packet: uint32 packet_length, byte padding_length, payload, padding.
        var reader = SSHWireReader(bytes[offset...])
        guard let packetLength = reader.readUInt32() else { return .needMoreData }
        guard packetLength >= 2, packetLength <= 35000 else { return .invalid }
        guard let packet = reader.readBytes(Int(packetLength)) else { return .needMoreData }
        let paddingLength = Int(packet[0])
        guard packet.count - 1 - paddingLength >= 17 else { return .invalid }
        let payload = Array(packet[1..<(packet.count - paddingLength)])
        // SSH_MSG_KEXINIT = 20, then a 16-byte cookie, then ten name-lists.
        guard payload[0] == 20 else { return .invalid }
        var lists = SSHWireReader(payload[17...])
        var names: [[String]] = []
        for _ in 0..<10 {
            guard let raw = lists.readString() else { return .invalid }
            names.append(
                String(decoding: raw, as: UTF8.self).split(separator: ",").map(String.init))
        }
        return .parsed(
            ServerAlgorithms(
                identification: identification ?? "", keyExchange: names[0], hostKey: names[1],
                encryptionClientToServer: names[2], encryptionServerToClient: names[3]))
    }
}
