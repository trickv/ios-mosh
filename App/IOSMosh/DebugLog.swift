import Foundation

/// Rolling debug log in Documents/. scripts/deploy.sh --logs copies it off the
/// phone, so a reported problem can be read without anyone sending anything.
/// Never log keys, passwords or typed input.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    static let fileName = "debug.log"
    private static let maxBytes = 512 * 1024

    private let queue = DispatchQueue(label: "us.v9n.ios-mosh.debuglog")
    private let url: URL
    private let oldURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent(Self.fileName)
        oldURL = documents.appendingPathComponent(Self.fileName + ".1")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ message: @autoclosure () -> String) {
        let text = message()
        let stamp = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: stamp)) \(text)\n"
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
            }
        }
    }

    /// Blocks until everything logged so far is on disk.
    func flush() {
        queue.sync {}
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > Self.maxBytes else { return }
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }
}
