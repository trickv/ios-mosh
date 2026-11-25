import Foundation
import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import IOSMosh

/// A session row's preview (docs/notes/multi-session/DESIGN.md 4.2, step 5): the window title,
/// else the last line of the stored screen, else "Session"; read from the record's snapshot
/// without the lock and never written; decoded again only when the file changed. On a temporary
/// root and Keychain service; the snapshots are made with the record's own codec.
///
/// The async test is `@MainActor` (step 13c): off the main actor XCTest sometimes did not
/// record a failure that came after an `await` (step 11, docs/MAC.md).
final class SessionPreviewTests: XCTestCase {
    private var root: String!
    private var keys: SessionKeychain!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)").path
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        keys.deleteAll()
    }

    func testATitleWinsElseTheLastLine() {
        let screen = ["$ make", "  compiling foo.c  ", "", "   "]
        XCTAssertEqual(SessionPreview.text(title: "build box", rows: screen), "build box", "the title wins")
        XCTAssertEqual(SessionPreview.text(title: nil, rows: screen), "compiling foo.c",
                       "no title: the last line that is not empty, trimmed")
        XCTAssertEqual(SessionPreview.text(title: " \t ", rows: screen), "compiling foo.c", "a blank title is no title")
        XCTAssertEqual(SessionPreview.text(title: "a\u{1B}b\u{07}c\u{9B}d", rows: screen), "abcd",
                       "control characters are removed from the title")
        XCTAssertEqual(SessionPreview.text(title: String(repeating: "x", count: 200), rows: screen),
                       String(repeating: "x", count: 80), "at most 80 characters")
        XCTAssertEqual(SessionPreview.text(title: nil, rows: ["", "  "]), "Session", "an empty screen")
        XCTAssertEqual(SessionPreview.text(title: nil, rows: []), "Session")
    }

    @MainActor
    func testReadGivesNoPreviewAndNeverWrites() async throws {
        let key = try Base64Key(bytes: [UInt8](repeating: 6, count: 16))
        let meta = SessionMeta(createdAt: 1, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 42, serverStartTime: 1000)
        try keys.store(key, for: meta.id)
        // The coordinator holds the record (its lock) for the whole test.
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        let directory = SessionStore(root: root, id: meta.id).directory
        let snapshot = directory + "/snapshot"
        XCTAssertThrowsError(try SessionRecord.open(root: root, id: meta.id), "the record is held")

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot), "a new record has no snapshot")
        let counters = try Data(contentsOf: URL(fileURLWithPath: directory + "/counters"))
        XCTAssertNil(try readUnchanged(directory, meta.id), "a missing file")

        try Data("not a snapshot at all, but long enough to have a header".utf8).write(to: URL(fileURLWithPath: snapshot))
        XCTAssertNil(try readUnchanged(directory, meta.id), "garbage")

        let other = SessionID.random()
        try Data(Self.snapshotBytes(for: other, screen: "\u{1B}]2;someone else\u{07}theirs"))
            .write(to: URL(fileURLWithPath: snapshot))
        XCTAssertNil(try readUnchanged(directory, meta.id), "another session's snapshot")

        try Data(Self.snapshotBytes(for: meta.id, screen: "\u{1B}]2;build box\u{07}$ make\r\nok\r\n"))
            .write(to: URL(fileURLWithPath: snapshot))
        let content = try readUnchanged(directory, meta.id)
        XCTAssertEqual(content?.title, "build box", "its own snapshot, read while the coordinator holds the record")
        XCTAssertEqual(content.map { SessionPreview.text(title: nil, rows: $0.rows) }, "ok")

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: directory + "/counters")), counters,
                       "the counters are byte-equal")
        await coordinator.close()
    }

    func testTheCacheDecodesAgainOnlyWhenTheFileChanged() throws {
        let id = SessionID.random()
        let directory = SessionStore(root: root, id: id).directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let snapshot = directory + "/snapshot"
        var decodes = 0
        let cache = SessionPreviewCache(read: { path, id in
            decodes += 1
            return SessionPreview.read(path: path, id: id)
        })
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(cache.text(root: root, id: id), "Session", "no file")
        XCTAssertEqual(decodes, 0, "nothing to decode")

        try write(Self.snapshotBytes(for: id, screen: "\u{1B}]2;one\u{07}"), to: snapshot, modified: start)
        XCTAssertEqual(cache.text(root: root, id: id), "one")
        XCTAssertEqual(cache.text(root: root, id: id), "one")
        XCTAssertEqual(decodes, 1, "decoded once while the file stays as it was")

        // A new snapshot of another size.
        try write(Self.snapshotBytes(for: id, screen: "\u{1B}]2;two, longer\u{07}"), to: snapshot,
                  modified: start.addingTimeInterval(60))
        XCTAssertEqual(cache.text(root: root, id: id), "two, longer", "a changed size is read again")
        XCTAssertEqual(decodes, 2)

        // A new snapshot of the same size, only its date differs.
        try write(Self.snapshotBytes(for: id, screen: "\u{1B}]2;two, later!\u{07}"), to: snapshot,
                  modified: start.addingTimeInterval(120))
        XCTAssertEqual(cache.text(root: root, id: id), "two, later!", "a changed date is read again")
        XCTAssertEqual(cache.text(root: root, id: id), "two, later!")
        XCTAssertEqual(decodes, 3)

        cache.keep(only: [])
        XCTAssertEqual(cache.text(root: root, id: id), "two, later!")
        XCTAssertEqual(decodes, 4, "the entry of a session that went is dropped")
    }

    // MARK: Helpers

    /// `SessionPreview.read`, and every file of the record byte-equal before and after.
    private func readUnchanged(_ directory: String, _ id: SessionID) throws -> SessionPreview.Content? {
        let before = try contents(directory)
        let content = SessionPreview.read(root: root, id: id)
        XCTAssertEqual(try contents(directory), before, "the read wrote nothing")
        return content
    }

    private func contents(_ directory: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name))
        }
        return files
    }

    private func write(_ bytes: [UInt8], to path: String, modified: Date) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    /// A stored snapshot of `id` whose one remote state is an 80x24 terminal that was given
    /// `screen` as host bytes.
    static func snapshotBytes(for id: SessionID, screen: String) -> [UInt8] {
        var terminal = TerminalState(width: 80, height: 24)
        _ = terminal.act(Array(screen.utf8))
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 0, pendingInput: [],
            remoteStates: [NumberedRemoteState(number: 0, state: TerminalRemoteState(terminal: terminal))],
            highestAckSent: 0, terminalSize: TerminalSize(width: 80, height: 24),
            usedCounters: GateCounters(sequence: 1, state: 1, fragmentID: 1), receiverExpectedSequence: 0)
        let stored = StoredSnapshot(id: 1, snapshot: SessionSnapshot(transport: transport, clipboard: ClipboardPolicy()))
        return SnapshotCodec.encode(stored, sessionID: id)
    }
}
