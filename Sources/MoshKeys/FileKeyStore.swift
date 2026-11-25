import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A key store in a directory, for tests and `moshcli`. The app keeps its keys in the Keychain.
///
/// Each key is two files: `<name>.key` with the 32-byte private key (mode 600, created
/// exclusively so that a key is never overwritten) and `<name>.pub` with the OpenSSH public key
/// line. The directory is created with mode 700.
public final class FileKeyStore: KeyStore {
    public let directory: URL

    private static let privateSuffix = ".key"
    private static let publicSuffix = ".pub"

    public init(directory: URL) {
        self.directory = directory
    }

    public func list() throws -> [StoredKey] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            // A store that was never written to is an empty store.
            if !FileManager.default.fileExists(atPath: directory.path) { return [] }
            throw KeyStoreError.io("cannot list \(directory.path): \(error)")
        }
        var keys: [StoredKey] = []
        for file in names.sorted() where file.hasSuffix(Self.publicSuffix) {
            let name = String(file.dropLast(Self.publicSuffix.count))
            guard KeyName.isValid(name) else { continue }
            keys.append(try readPublic(name: name))
        }
        return keys
    }

    @discardableResult
    public func generate(name: String, comment: String) throws -> StoredKey {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        guard OpenSSHPublicKey.isValidComment(comment) else { throw KeyStoreError.invalidComment }
        try createDirectory()

        let pair = KeyGenerator.generateEd25519()
        let publicKey: OpenSSHPublicKey
        do {
            publicKey = try pair.openSSHPublicKey(comment: comment)
        } catch {
            throw KeyStoreError.invalidComment
        }

        let privatePath = path(name, Self.privateSuffix)
        let publicPath = path(name, Self.publicSuffix)
        try Self.writeExclusive(pair.privateKey, to: privatePath, mode: 0o600, name: name)
        do {
            // A leftover public file without a private key is not a key; replace it.
            try? FileManager.default.removeItem(atPath: publicPath)
            try Self.writeExclusive(Data((publicKey.line + "\n").utf8), to: publicPath, mode: 0o644, name: name)
        } catch {
            try? FileManager.default.removeItem(atPath: privatePath)
            throw error
        }
        return StoredKey(name: name, publicKey: publicKey)
    }

    public func loadPrivateKey(name: String) throws -> Data {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        let privatePath = path(name, Self.privateSuffix)
        guard let data = FileManager.default.contents(atPath: privatePath) else {
            throw KeyStoreError.notFound(name)
        }
        guard (try? Ed25519KeyPair(privateKey: data)) != nil else { throw KeyStoreError.corrupt(name) }
        return data
    }

    public func delete(name: String) throws {
        guard KeyName.isValid(name) else { throw KeyStoreError.invalidName(name) }
        let privatePath = path(name, Self.privateSuffix)
        let publicPath = path(name, Self.publicSuffix)
        let manager = FileManager.default
        guard manager.fileExists(atPath: privatePath) || manager.fileExists(atPath: publicPath) else {
            throw KeyStoreError.notFound(name)
        }
        for file in [privatePath, publicPath] where manager.fileExists(atPath: file) {
            do {
                try manager.removeItem(atPath: file)
            } catch {
                throw KeyStoreError.io("cannot remove \(file): \(error)")
            }
        }
    }

    // MARK: - Files

    private func path(_ name: String, _ suffix: String) -> String {
        directory.appendingPathComponent(name + suffix).path
    }

    private func readPublic(name: String) throws -> StoredKey {
        guard let data = FileManager.default.contents(atPath: path(name, Self.publicSuffix)),
            let key = try? OpenSSHPublicKey(line: String(decoding: data, as: UTF8.self))
        else { throw KeyStoreError.corrupt(name) }
        return StoredKey(name: name, publicKey: key)
    }

    private func createDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw KeyStoreError.io("cannot create \(directory.path): \(error)")
        }
    }

    /// Creates the file with its final mode in one step (`O_CREAT | O_EXCL`), so the private key
    /// is at no time readable by others and an existing key is never replaced.
    private static func writeExclusive(_ data: Data, to path: String, mode: mode_t, name: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw KeyStoreError.alreadyExists(name) }
            throw KeyStoreError.io("cannot create \(path): errno \(errno)")
        }
        // The mode given to open() is reduced by the umask; set it exactly.
        var failure: String? = fchmod(descriptor, mode) == 0 ? nil : "fchmod errno \(errno)"
        if failure == nil {
            failure = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
                var written = 0
                while written < buffer.count {
                    let result = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        return "write errno \(errno)"
                    }
                    written += result
                }
                return nil
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = "fsync errno \(errno)" }
        _ = close(descriptor)
        if let failure {
            unlink(path)
            throw KeyStoreError.io("cannot write \(path): \(failure)")
        }
    }
}
