import Foundation
import MoshCrypto
import MoshResume
import MoshTransport
import XCTest
@testable import IOSMosh

/// `session-hosts.json` with "last looked at" (docs/notes/multi-session/DESIGN.md 2.5 and
/// section 7, `SessionFiles.swift`): `forget` and `removeOrphans` clear the id, an older file
/// decodes, and every read-change-write is under one lock (A15). On a temporary root, Keychain
/// service and links file. The class is not named after the file: `SessionFilesTests` (the
/// tests of `forget` and `removeOrphans` from review M6-10) is in `SessionResumeTests.swift`.
///
/// The async tests and `makeSession` are `@MainActor` (step 13c): off the main actor XCTest
/// sometimes did not record a failure that came after an `await` (step 11, docs/MAC.md), so
/// such a test could pass with broken code.
final class SessionLinksFileTests: XCTestCase {
    private var root: String!
    private var keys: SessionKeychain!
    private var linksURL: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions").path
        linksURL = base.appendingPathComponent("session-hosts.json")
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: linksURL.deletingLastPathComponent())
        keys.deleteAll()
    }

    /// A record as the app makes it, with its key in the Keychain and, if asked, a link.
    @MainActor
    private func makeSession(record: Bool = true, key: Bool = true, link: Bool) async throws -> SessionID {
        let sessionKey = try Base64Key(bytes: [UInt8](repeating: 5, count: 16))
        let meta = SessionMeta(createdAt: 1, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 42, serverStartTime: 1000)
        if key { try keys.store(sessionKey, for: meta.id) }
        if link { SessionFiles.link(meta.id, to: UUID(), linksURL: linksURL) }
        if record {
            let coordinator = try ResumeCoordinator.create(
                root: root, meta: meta, key: sessionKey, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
                options: SessionLauncher.options(address: meta.address, port: meta.port))
            await coordinator.close()
        }
        return meta.id
    }

    private var last: SessionID? { SessionFiles.lastLookedAt(linksURL: linksURL) }

    @MainActor
    func testForgetClearsLastLookedAtWithAndWithoutALink() async throws {
        for linked in [true, false] {
            let id = try await makeSession(link: linked)
            let other = try await makeSession(link: true)

            SessionFiles.setLastLookedAt(id, linksURL: linksURL)
            XCTAssertEqual(last, id, "stored (linked: \(linked))")
            XCTAssertTrue(SessionFiles.forget(other, root: root, keys: keys, linksURL: linksURL))
            XCTAssertEqual(last, id, "forgetting another session leaves it (linked: \(linked))")

            XCTAssertTrue(SessionFiles.forget(id, root: root, keys: keys, linksURL: linksURL))
            XCTAssertNil(last, "forget clears the id it names (linked: \(linked))")
            XCTAssertNil(SessionFiles.linkedHostID(of: id, linksURL: linksURL))
        }

        // The one clearing function clears only the id it is given.
        let kept = try await makeSession(link: false)
        SessionFiles.setLastLookedAt(kept, linksURL: linksURL)
        SessionFiles.clearLastLookedAt(ifNamed: SessionID.random(), linksURL: linksURL)
        XCTAssertEqual(last, kept)
        SessionFiles.clearLastLookedAt(ifNamed: kept, linksURL: linksURL)
        XCTAssertNil(last)
    }

    @MainActor
    func testRemoveOrphansClearsAnIdWithoutARecord() async throws {
        // No record, no key, no link: only "last looked at" names it.
        let gone = SessionID.random()
        SessionFiles.setLastLookedAt(gone, linksURL: linksURL)
        let complete = try await makeSession(link: true)
        SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)
        XCTAssertNil(last, "an id without a record is cleared")
        XCTAssertNotNil(SessionFiles.linkedHostID(of: complete, linksURL: linksURL), "the other link stays")

        // An id with a record stays, linked or not.
        for linked in [true, false] {
            let id = try await makeSession(link: linked)
            SessionFiles.setLastLookedAt(id, linksURL: linksURL)
            SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)
            XCTAssertEqual(last, id, "a record is no orphan (linked: \(linked))")
        }

        // The record of the id named goes (a restore without it): the id goes too.
        let restored = try await makeSession(record: false, key: true, link: false)
        SessionFiles.setLastLookedAt(restored, linksURL: linksURL)
        SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)
        XCTAssertNil(last, "a key without a record and the id that names it are orphans")
        XCTAssertNil(try keys.key(for: restored))
    }

    func testAFileWithoutTheKeyDecodes() throws {
        // A file as the app wrote it before "last looked at" existed.
        let id = SessionID.random()
        let host = UUID()
        try FileManager.default.createDirectory(at: linksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "{\"version\":1,\"links\":{\"\(id.description)\":\"\(host.uuidString)\"}}"
        try Data(old.utf8).write(to: linksURL)

        XCTAssertEqual(SessionFiles.linkedHostID(of: id, linksURL: linksURL), host, "the old file's link is read")
        XCTAssertEqual(SessionFiles.links(linksURL: linksURL), [id: host])
        XCTAssertNil(last, "no key: no session looked at")

        // Written back with the id, the link is kept.
        SessionFiles.setLastLookedAt(id, linksURL: linksURL)
        XCTAssertEqual(last, id)
        XCTAssertEqual(SessionFiles.linkedHostID(of: id, linksURL: linksURL), host)
        // Cleared, the key is left out again (an old build reads the same shape).
        SessionFiles.setLastLookedAt(nil, linksURL: linksURL)
        let text = String(decoding: try Data(contentsOf: linksURL), as: UTF8.self)
        XCTAssertFalse(text.contains("lastLookedAt"), text)
    }

    func testLinkAndForgetFromTwoThreadsLoseNothing() throws {
        let pairs = 200
        let forgotten = (0..<pairs).map { _ in SessionID.random() }
        let linked = (0..<pairs).map { _ in SessionID.random() }
        for id in forgotten { SessionFiles.link(id, to: UUID(), linksURL: linksURL) }
        XCTAssertEqual(SessionFiles.links(linksURL: linksURL).count, pairs)

        let root = self.root!, keys = self.keys!, linksURL = self.linksURL!
        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        // `forget` off the main thread (as `finishEnded`), `link` on another (as `openSession`).
        done.enter()
        Thread.detachNewThread {
            start.wait()
            for id in forgotten {
                SessionFiles.forget(id, root: root, keys: keys, linksURL: linksURL)
            }
            done.leave()
        }
        done.enter()
        Thread.detachNewThread {
            start.wait()
            for id in linked {
                SessionFiles.link(id, to: UUID(), linksURL: linksURL)
            }
            done.leave()
        }
        start.signal()
        start.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 120), .success, "both threads finished")

        let links = SessionFiles.links(linksURL: linksURL)
        let lostLinks = linked.filter { links[$0] == nil }.count
        let revived = forgotten.filter { links[$0] != nil }.count
        XCTAssertEqual(lostLinks, 0, "links lost to a concurrent forget")
        XCTAssertEqual(revived, 0, "forgotten links written back by a concurrent link")
        XCTAssertEqual(links.count, pairs)
    }

    // MARK: A file that exists but cannot be used is never written over (R24-S2, step 4c)

    /// Every writer of the file, once each: a link, "last looked at" set and cleared, a forget
    /// (of a session that has a record) and the orphan sweep.
    private func runEveryWriter(forgetting forgotten: SessionID) {
        SessionFiles.link(SessionID.random(), to: UUID(), linksURL: linksURL)
        SessionFiles.setLastLookedAt(SessionID.random(), linksURL: linksURL)
        SessionFiles.setLastLookedAt(nil, linksURL: linksURL)
        SessionFiles.clearLastLookedAt(ifNamed: forgotten, linksURL: linksURL)
        XCTAssertTrue(SessionFiles.forget(forgotten, root: root, keys: keys, linksURL: linksURL),
                      "the record and key go; only the file is left alone")
        SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)
    }

    private func setMode(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: linksURL.path)
    }

    /// The file cannot be read now (mode 000, as a storage or protection error makes it): no
    /// writer replaces it, and once it is readable again every link and "last looked at" are
    /// as they were. Readers meanwhile see no links, as before.
    @MainActor
    func testAnUnreadableLinksFileKeepsItsLinks() async throws {
        let kept = try await makeSession(link: true)
        let forgotten = try await makeSession(link: true)
        SessionFiles.setLastLookedAt(kept, linksURL: linksURL)
        let before = SessionFiles.links(linksURL: linksURL)
        XCTAssertEqual(before.count, 2)
        let bytes = try Data(contentsOf: linksURL)

        try setMode(0o000)
        defer { try? setMode(0o600) }
        XCTAssertThrowsError(try Data(contentsOf: linksURL), "the file cannot be read now")
        XCTAssertEqual(SessionFiles.links(linksURL: linksURL), [:], "a reader sees no links meanwhile")
        runEveryWriter(forgetting: forgotten)

        try setMode(0o600)
        XCTAssertEqual(try Data(contentsOf: linksURL), bytes, "the file was not written")
        XCTAssertEqual(SessionFiles.links(linksURL: linksURL), before, "every link survived")
        XCTAssertEqual(last, kept, "and the session looked at last")
        XCTAssertNil(try keys.key(for: forgotten), "the forgotten session's key is gone")

        // Readable again, the file is written as before: the sweep drops the forgotten link.
        SessionFiles.removeOrphans(root: root, keys: keys, linksURL: linksURL)
        XCTAssertNil(SessionFiles.linkedHostID(of: forgotten, linksURL: linksURL))
        XCTAssertEqual(SessionFiles.linkedHostID(of: kept, linksURL: linksURL), before[kept])
    }

    /// The file is there but damaged (cut short, not JSON) or of another version (a newer
    /// build's): no writer replaces it, byte for byte, so the links it holds are still there for
    /// whatever can read them. Readers see no links, as before.
    @MainActor
    func testADamagedLinksFileKeepsItsLinks() async throws {
        let fresh = try await makeSession(link: false)
        let host = UUID()
        let id = SessionID.random()
        let whole = "{\"version\":1,\"links\":{\"\(id.description)\":\"\(host.uuidString)\"},\"lastLookedAt\":\"\(id.description)\"}"
        let damaged: [(String, Data)] = [
            ("cut short", Data(whole.utf8.prefix(40))),
            ("not JSON", Data([0x00, 0xff, 0x13, 0x37])),
            ("another version", Data(whole.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)),
        ]
        // Collected and checked once after the loop: in this async test a second failed
        // assertion was not always recorded (step 4c's control runs), one list always is.
        var writtenOver: [String] = []
        for (what, bytes) in damaged {
            try bytes.write(to: linksURL)
            XCTAssertEqual(SessionFiles.links(linksURL: linksURL), [:], "a reader sees no links (\(what))")
            XCTAssertNil(last, "nor a session looked at (\(what))")
            let session = try await makeSession(link: false)
            runEveryWriter(forgetting: session)
            if try Data(contentsOf: linksURL) != bytes { writtenOver.append(what) }
        }
        XCTAssertEqual(writtenOver, [], "no damaged file was written over")
        // The newer build's file still holds its link.
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: linksURL)) as? [String: Any]
        XCTAssertEqual((kept?["links"] as? [String: String])?[id.description], host.uuidString)

        // Only "no such file" is an empty file: then the writers write.
        try FileManager.default.removeItem(at: linksURL)
        SessionFiles.setLastLookedAt(fresh, linksURL: linksURL)
        XCTAssertEqual(last, fresh, "a missing file is written")
    }
}
