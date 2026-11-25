import Foundation
import MoshBootstrap

/// A saved host: the per-host fields of docs/PLAN.md, Design 4 ("Per-host fields").
struct SavedHost: Codable, Equatable, Identifiable {
    var id: UUID
    /// Shown in the host list; the host name when empty.
    var name: String
    /// Host name or IP address, as typed. Also the name its host key is remembered under.
    var host: String
    var port: Int
    var user: String
    /// The key store name of the key to log in with (M5: always the device key).
    var keyName: String
    /// Server prefix or path; empty for `mosh-server` on the PATH.
    var serverPath: String
    var locale: String
    /// `60001` or `60001:60010`; empty for the server's default.
    var udpPortRange: String
    /// Run instead of the login shell; empty for none.
    var remoteCommand: String
    var allowClipboardWrite: Bool
    var swipeSendsPaging: Bool
    /// M10: mosh's `--predict` and `--predict-overwrite` for this host.
    var localEcho: LocalEcho

    init(
        id: UUID = UUID(), name: String = "", host: String = "", port: Int = 22, user: String = "",
        keyName: String = DeviceKey.name, serverPath: String = "",
        locale: String = MoshServerCommand.defaultLocale, udpPortRange: String = "",
        remoteCommand: String = "", allowClipboardWrite: Bool = true, swipeSendsPaging: Bool = false,
        localEcho: LocalEcho = .standard
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.keyName = keyName
        self.serverPath = serverPath
        self.locale = locale
        self.udpPortRange = udpPortRange
        self.remoteCommand = remoteCommand
        self.allowClipboardWrite = allowClipboardWrite
        self.swipeSendsPaging = swipeSendsPaging
        self.localEcho = localEcho
    }

    /// Hosts saved before M10 have no `localEcho`: they get mosh's default (Adaptive). Every
    /// other field is required, as before.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        user = try container.decode(String.self, forKey: .user)
        keyName = try container.decode(String.self, forKey: .keyName)
        serverPath = try container.decode(String.self, forKey: .serverPath)
        locale = try container.decode(String.self, forKey: .locale)
        udpPortRange = try container.decode(String.self, forKey: .udpPortRange)
        remoteCommand = try container.decode(String.self, forKey: .remoteCommand)
        allowClipboardWrite = try container.decode(Bool.self, forKey: .allowClipboardWrite)
        swipeSendsPaging = try container.decode(Bool.self, forKey: .swipeSendsPaging)
        localEcho = try container.decodeIfPresent(LocalEcho.self, forKey: .localEcho) ?? .standard
    }

    /// The remote command presets of Design 4.
    static let remoteCommandPresets = ["tmux new -A -s main", "tmux new -A -s $(hostname -s)"]

    var displayName: String { name.isEmpty ? host : name }

    var target: SSHTarget { SSHTarget(host: host, port: port, user: user) }

    /// The `mosh-server new` settings. Nil port range when the field is empty.
    func serverCommand() throws -> MoshServerCommand {
        var range: UDPPortRange?
        let rangeText = udpPortRange.trimmingCharacters(in: .whitespaces)
        if !rangeText.isEmpty {
            guard let parsed = UDPPortRange(rangeText) else { throw ValidationError("UDP ports: \"\(rangeText)\" is not a port or a range like 60001:60010") }
            range = parsed
        }
        return MoshServerCommand(serverPath: serverPath, locale: locale, portRange: range,
                                 remoteCommand: remoteCommand)
    }

    struct ValidationError: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Nil when the host can be saved; otherwise what is wrong, for the user.
    func validationError() -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is missing." }
        if host.contains(where: { $0.isWhitespace }) { return "Host must not contain spaces." }
        if !(1...65535).contains(port) { return "SSH port must be between 1 and 65535." }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return "User is missing." }
        do {
            _ = try serverCommand().commandLine()
        } catch let error as ValidationError {
            return error.description
        } catch MoshServerCommand.CommandError.invalidLocale(let locale) {
            return "Locale: \"\(locale)\" is not a locale name."
        } catch MoshServerCommand.CommandError.unrepresentable(let field) {
            return "\(field) must not contain a line break."
        } catch {
            return "\(error)"
        }
        return nil
    }
}

/// The saved hosts, in a JSON file in Application Support (the plan does not say where;
/// this is the simplest place that is not shown in the Files app). Written atomically on
/// every change. A file that cannot be read is an error, never an empty list, so a bad
/// file is not overwritten by the next save.
final class HostStore {
    private struct FileFormat: Codable {
        var version: Int
        var hosts: [SavedHost]
    }

    enum StoreError: Error, CustomStringConvertible {
        case unreadable(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .unreadable(let text): return "The saved hosts cannot be read: \(text)"
            case .writeFailed(let text): return "The hosts cannot be saved: \(text)"
            }
        }
    }

    let fileURL: URL

    init(fileURL: URL = AppFiles.hostsURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [SavedHost] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) { return [] }
            throw StoreError.unreadable("\(error)")
        }
        do {
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            guard file.version == 1 else { throw StoreError.unreadable("unknown version \(file.version)") }
            return file.hosts
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable("\(error)")
        }
    }

    func save(_ hosts: [SavedHost]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(FileFormat(version: 1, hosts: hosts))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed("\(error)")
        }
    }

    /// Adds the host, or replaces the one with its id.
    func upsert(_ host: SavedHost) throws {
        var hosts = try load()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try save(hosts)
        NotificationCenter.default.post(name: LocalEcho.hostSaved, object: host)
    }

    func delete(id: UUID) throws {
        var hosts = try load()
        hosts.removeAll { $0.id == id }
        try save(hosts)
    }
}

/// Where the app keeps its files.
enum AppFiles {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var hostsURL: URL { supportDirectory.appendingPathComponent("hosts.json") }
    static var knownHostsURL: URL { supportDirectory.appendingPathComponent("known_hosts.json") }

    static let knownHosts = KnownHosts(fileURL: knownHostsURL)

    /// UI tests start some launches with `-uiTestingReset 1`: no saved hosts and no known
    /// host keys. Keys are kept (a test checks that the device key survives launches).
    static func resetForUITestsIfAsked() {
        #if DEBUG
        guard UITestSupport.isUITesting, UserDefaults.standard.bool(forKey: "uiTestingReset") else { return }
        try? FileManager.default.removeItem(at: hostsURL)
        try? FileManager.default.removeItem(at: knownHostsURL)
        #endif
    }
}
