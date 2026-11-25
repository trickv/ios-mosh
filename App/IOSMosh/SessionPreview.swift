import Foundation
import MoshResume
import MoshTerminal

/// What a session row shows as its first line (docs/notes/multi-session/DESIGN.md 4.2): the
/// window title if the host set one, otherwise the last line on the screen that is not empty,
/// otherwise "Session".
///
/// The source is the record's `snapshot` file, read without the record's lock and never
/// written: the file is replaced whole (docs/RESUME.md, R8), so a reader finds the old or the
/// new snapshot. A preview never says anything about a state: every failure (no file, a damaged
/// one, another session's) is "no preview", and the states come from the counters only (R7).
enum SessionPreview {
    /// The first line when there is no preview.
    static let placeholder = "Session"
    /// A title is cut to this many characters.
    static let maxTitleLength = 80
    /// A larger snapshot file gives no preview.
    static let maxFileSize = 1 << 20

    /// What a snapshot's screen offers: the window title (nil when the host never set one) and
    /// the visible rows, top to bottom.
    struct Content: Equatable {
        var title: String?
        var rows: [String]
    }

    /// The row's first line, from plain values (4.2): a title that is not blank, its control
    /// characters removed and cut to 80 characters; else the last row that is not blank,
    /// trimmed; else "Session".
    static func text(title: String?, rows: [String]) -> String {
        if let title {
            let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return String(cleaned.prefix(maxTitleLength)) }
        }
        for row in rows.reversed() {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return placeholder
    }

    /// The path of a record's snapshot file.
    static func snapshotPath(root: String, id: SessionID) -> String {
        SessionStore(root: root, id: id).directory + "/snapshot"
    }

    /// The screen of the record's stored snapshot, or nil (no file, one above 1 MiB, damaged, or
    /// not this session's).
    static func read(root: String, id: SessionID) -> Content? {
        read(path: snapshotPath(root: root, id: id), id: id)
    }

    /// The same, from the snapshot file at `path`. Opens it read-only and takes no lock.
    static func read(path: String, id: SessionID) -> Content? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize,
              let stored = try? SnapshotCodec.decode([UInt8](data), expecting: id),
              let newest = stored.snapshot.transport.remoteStates.last else { return nil }
        // The screen a resume shows first.
        let framebuffer = newest.state.terminal.framebuffer
        // mosh's own display writes a title only once it is initialized
        // (terminal/terminaldisplay.cc:74-77).
        let title = framebuffer.titleInitialized
            ? String(String.UnicodeScalarView(framebuffer.windowTitle.compactMap(Unicode.Scalar.init)))
            : nil
        let rows = (0..<framebuffer.ds.height).map { String(decoding: framebuffer.rowText($0), as: UTF8.self) }
        return Content(title: title, rows: rows)
    }
}

/// The previews of the list's rows, by session id, with the snapshot file's modification date
/// and size (DESIGN.md 4.2): a snapshot is decoded again only when one of them changed. The list
/// asks once per refresh and record, which costs one stat while the file stays as it was.
final class SessionPreviewCache {
    private struct Entry {
        var modified: Date
        var size: UInt64
        var text: String
    }

    private var entries: [SessionID: Entry] = [:]
    private let read: (_ path: String, _ id: SessionID) -> SessionPreview.Content?

    init(read: @escaping (_ path: String, _ id: SessionID) -> SessionPreview.Content? = { SessionPreview.read(path: $0, id: $1) }) {
        self.read = read
    }

    /// The first line of the session's row.
    func text(root: String, id: SessionID) -> String {
        let path = SessionPreview.snapshotPath(root: root, id: id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            entries[id] = nil
            return SessionPreview.placeholder
        }
        if let entry = entries[id], entry.modified == modified, entry.size == size {
            return entry.text
        }
        let content = read(path, id)
        let text = content.map { SessionPreview.text(title: $0.title, rows: $0.rows) } ?? SessionPreview.placeholder
        entries[id] = Entry(modified: modified, size: size, text: text)
        return text
    }

    /// Drops the entries of sessions that are no longer listed.
    func keep(only ids: Set<SessionID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
