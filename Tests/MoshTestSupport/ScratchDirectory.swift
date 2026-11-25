import Foundation

/// A fresh directory under the system's temporary directory, removed by `remove()`.
/// Typical use: create in `setUp`, call `remove()` in `tearDown`.
public struct ScratchDirectory: Sendable {
    public let url: URL

    public init(label: String = "moshkit") throws {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.url = url
    }

    public var path: String { url.path }

    public func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
