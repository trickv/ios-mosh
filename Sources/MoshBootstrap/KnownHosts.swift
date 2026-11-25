import Foundation
import MoshKeys

/// One remembered host key.
public struct KnownHost: Codable, Equatable, Sendable {
    /// The host as the user typed it, in lower case.
    public var host: String
    public var port: Int
    /// For example `ssh-ed25519`.
    public var keyType: String
    /// The base64 of the key's wire blob (the middle field of an OpenSSH public key line).
    public var publicKey: String
    /// `SHA256:...`, as `ssh-keygen -lf` prints it. Kept for display; the blob decides.
    public var fingerprint: String
    public var firstSeen: Date

    public init(host: String, port: Int, key: OpenSSHPublicKey, firstSeen: Date) {
        self.host = KnownHosts.normalize(host)
        self.port = port
        self.keyType = key.keyType
        self.publicKey = key.blob.base64EncodedString()
        self.fingerprint = key.fingerprint
        self.firstSeen = firstSeen
    }
}

/// What the store says about a key a host presents.
public enum HostKeyVerdict: Equatable, Sendable {
    /// The key is the remembered one.
    case trusted
    /// Nothing is remembered for this host and port.
    case unknown
    /// Another key is remembered. The connection must be refused.
    case changed(known: KnownHost)
}

/// What the user is shown on first contact.
public struct HostKeyPrompt: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    /// `SHA256:...`
    public let fingerprint: String

    public init(host: String, port: Int, keyType: String, fingerprint: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
    }
}

public enum KnownHostsError: Error, Equatable, Sendable {
    /// The host presented a key that differs from the remembered one.
    case hostKeyChanged(host: String, port: Int, knownFingerprint: String, presentedFingerprint: String)
    /// The user did not accept the key of an unknown host.
    case notTrusted(host: String, port: Int, fingerprint: String)
    /// The file exists but cannot be read as a known-hosts store. It is never treated as empty:
    /// that would silently turn every host back into a first contact.
    case unreadable(String)
    case writeFailed(String)
}

/// The app's known-hosts store: a JSON file with one key per host and port.
///
/// Trust on first use. An unknown key goes to a callback that shows the fingerprint and
/// decides. A key that differs from the remembered one is refused, whatever its type: one host
/// and port has exactly one key until the user removes the entry.
public final class KnownHosts: @unchecked Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var hosts: [KnownHost]
    }

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Hosts are compared without regard to case.
    public static func normalize(_ host: String) -> String {
        host.lowercased()
    }

    /// All entries, in the order they were added.
    public func entries() throws -> [KnownHost] {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    public func lookup(host: String, port: Int) throws -> KnownHost? {
        let name = Self.normalize(host)
        return try entries().first { $0.host == name && $0.port == port }
    }

    /// Compares a presented key with the store. Changes nothing.
    public func check(host: String, port: Int, key: OpenSSHPublicKey) throws -> HostKeyVerdict {
        guard let known = try lookup(host: host, port: port) else { return .unknown }
        return known.publicKey == key.blob.base64EncodedString() ? .trusted : .changed(known: known)
    }

    /// Remembers the key for the host. Throws `hostKeyChanged` if another key is remembered;
    /// an entry is only ever replaced after `remove`.
    @discardableResult
    public func trust(host: String, port: Int, key: OpenSSHPublicKey, now: Date = Date()) throws -> KnownHost {
        lock.lock()
        defer { lock.unlock() }
        var hosts = try load()
        let entry = KnownHost(host: host, port: port, key: key, firstSeen: now)
        if let known = hosts.first(where: { $0.host == entry.host && $0.port == port }) {
            if known.publicKey == entry.publicKey { return known }
            throw KnownHostsError.hostKeyChanged(
                host: entry.host, port: port, knownFingerprint: known.fingerprint,
                presentedFingerprint: entry.fingerprint)
        }
        hosts.append(entry)
        try save(hosts)
        return entry
    }

    /// Forgets the host. Returns whether there was an entry.
    @discardableResult
    public func remove(host: String, port: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var hosts = try load()
        let name = Self.normalize(host)
        let before = hosts.count
        hosts.removeAll { $0.host == name && $0.port == port }
        guard hosts.count != before else { return false }
        try save(hosts)
        return true
    }

    /// The whole host key check of a connection: a remembered key passes silently, a different
    /// one throws `hostKeyChanged` with both fingerprints, and an unknown one is shown to
    /// `confirm`, which decides whether it is remembered (`true`) or the connection is refused.
    public func verify(
        host: String, port: Int, key: OpenSSHPublicKey,
        confirm: @Sendable (HostKeyPrompt) async -> Bool
    ) async throws {
        switch try check(host: host, port: port, key: key) {
        case .trusted:
            return
        case .changed(let known):
            throw KnownHostsError.hostKeyChanged(
                host: known.host, port: port, knownFingerprint: known.fingerprint,
                presentedFingerprint: key.fingerprint)
        case .unknown:
            let prompt = HostKeyPrompt(
                host: Self.normalize(host), port: port, keyType: key.keyType, fingerprint: key.fingerprint)
            guard await confirm(prompt) else {
                throw KnownHostsError.notTrusted(host: prompt.host, port: port, fingerprint: key.fingerprint)
            }
            try trust(host: host, port: port, key: key)
        }
    }

    // MARK: - File

    private func load() throws -> [KnownHost] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) { return [] }
            throw KnownHostsError.unreadable("\(fileURL.path): \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(FileFormat.self, from: data)
            guard file.version == 1 else {
                throw KnownHostsError.unreadable("\(fileURL.path): unknown version \(file.version)")
            }
            return file.hosts
        } catch let error as KnownHostsError {
            throw error
        } catch {
            throw KnownHostsError.unreadable("\(fileURL.path): \(error)")
        }
    }

    private func save(_ hosts: [KnownHost]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(FileFormat(version: 1, hosts: hosts))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw KnownHostsError.writeFailed("\(fileURL.path): \(error)")
        }
    }
}
