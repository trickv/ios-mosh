import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import IOSMosh

/// The host list's session states (docs/PLAN.md M8, Design 4 "Session list"). No test names the
/// dirty case: resume stage 2 (M9) renames it. A record that was only created is dirty in stage 1
/// and is taken from the core instead (`testEveryOtherStateIsDead`).
///
/// The async tests and `makeRecord` (it checks the shutdown's answer after an `await`) are
/// `@MainActor` (step 13c): off the main actor XCTest sometimes did not record a failure that
/// came after an `await` (step 11, docs/MAC.md), so such a test could pass with broken code.
final class SessionListTests: XCTestCase {
    private var root: String!
    private var linksURL: URL!
    private var keys: SessionKeychain!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("list-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions").path
        linksURL = base.appendingPathComponent("session-hosts.json")
        keys = SessionKeychain(service: "us.v9n.ios-mosh.tests.session-keys.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: linksURL.deletingLastPathComponent())
        keys.deleteAll()
    }

    func testStatesFromTheCounters() {
        XCTAssertEqual(ListedSessionState.derive(.state(.clean(snapshotID: 7)), isLive: false), .resumable)
        XCTAssertEqual(ListedSessionState.derive(.state(.ended), isLive: false), .ended)
        XCTAssertEqual(ListedSessionState.derive(.unreadable, isLive: false), .unreadable)
    }

    /// Every state but clean and ended is "dead". Stage 1's other state (dirty) comes from a
    /// record that was only created; resume stage 2 (step 9) changes what such a record lists as.
    func testEveryOtherStateIsDead() throws {
        let record = try SessionRecord.create(root: root, meta: DeviceProbe.meta(), key: nil)
        defer { try? record.delete() }
        let state = record.state
        if case .clean = state { XCTFail("a record that was only created is not clean") }
        XCTAssertNotEqual(state, .ended)
        XCTAssertEqual(ListedSessionState.derive(.state(state), isLive: false), .dead, "\(state)")
        XCTAssertEqual(ListedSessionState.derive(.state(state), isLive: true), .live)
    }

    func testTheOpenSessionIsLiveWhateverItsRecordSays() {
        for reading: ListedSessionState.Reading in [.state(.clean(snapshotID: 1)), .state(.ended), .unreadable] {
            XCTAssertEqual(ListedSessionState.derive(reading, isLive: true), .live, "\(reading)")
        }
    }

    func testIdentifiersAndLabelsAreDistinct() {
        let all: [ListedSessionState] = [.live, .resumable, .ended, .dead, .unreadable]
        XCTAssertEqual(Set(all.map(\.identifier)).count, all.count)
        XCTAssertEqual(Set(all.map(\.label)).count, all.count)
        XCTAssertFalse(all.map(\.identifier).contains("none"), "\"none\" is the row without a record")
    }

    func testWaitingText() {
        XCTAssertEqual(SessionList.waitingText("the record is in use"),
                       "A session is waiting: the record is in use. It is tried again when the app becomes active.")
    }

    func testEndSessionSaysWhyTheSessionWasKept() {
        XCTAssertEqual(SessionListViewController.notEnded(.hostNotReached, host: "h.example"),
                       "H.example could not be reached with this device's key. The session is kept; try again later, or use Forget.")
        XCTAssertTrue(SessionListViewController.notEnded(.notThere(atSessionAddress: false), host: "h")
            .contains("another address"))
        XCTAssertTrue(SessionListViewController.notEnded(.notAnswered, host: "h").contains("no usable answer"))
    }

    /// A record ended on purpose (a shutdown without its answer), linked to a saved host, and
    /// one of no saved host: the first is the host's session, the second is listed apart. Read
    /// without the coordinator: the record is not changed and can still be opened by it.
    @MainActor
    func testRecordsAreReadAndGroupedByHost() async throws {
        let host = SavedHost(name: "h", host: "example.org", user: "u")
        let ended = try await makeRecord(createdAt: 2, pid: 43, endIt: true)
        SessionFiles.link(ended.id, to: host.id, linksURL: linksURL)
        let other = try await makeRecord(createdAt: 1, pid: 44, endIt: true)
        let before = try SessionStore(root: root, id: ended.id).readCounters()

        let sessions = SessionList.load(root: root, linksURL: linksURL, liveID: nil)
        XCTAssertEqual(sessions.map(\.id), [ended.id, other.id], "newest first")
        XCTAssertEqual(sessions.map(\.state), [.ended, .ended])
        XCTAssertEqual(sessions.first?.meta, ended)
        XCTAssertNotNil(sessions.first?.lastUsed)
        XCTAssertEqual(try SessionStore(root: root, id: ended.id).readCounters(), before, "nothing written")

        let grouped = SessionList.group(sessions, hosts: [host])
        XCTAssertEqual(grouped.byHost[host.id]?.id, ended.id)
        XCTAssertEqual(grouped.other.map(\.id), [other.id])
        XCTAssertTrue(SessionList.group(sessions, hosts: []).byHost.isEmpty, "a deleted host's session is listed apart")

        let live = SessionList.load(root: root, linksURL: linksURL, liveID: other.id)
        XCTAssertEqual(live.map(\.state), [.ended, .live])
    }

    @MainActor
    func testANewerSessionOfTheSameHostIsTheOneShown() async throws {
        let host = SavedHost(name: "h", host: "example.org", user: "u")
        let older = try await makeRecord(createdAt: 1, pid: 50, endIt: true)
        let newer = try await makeRecord(createdAt: 5, pid: 51, endIt: true)
        SessionFiles.link(older.id, to: host.id, linksURL: linksURL)
        SessionFiles.link(newer.id, to: host.id, linksURL: linksURL)
        let grouped = SessionList.group(SessionList.load(root: root, linksURL: linksURL, liveID: nil), hosts: [host])
        XCTAssertEqual(grouped.byHost[host.id]?.id, newer.id)
        XCTAssertTrue(grouped.other.isEmpty)
    }

    /// DESIGN.md 4.1 and D3: every session of a saved host is a row under it, oldest first by
    /// `meta.createdAt` (ties by id, a record without `meta` last), numbered from 1; a host without
    /// sessions is a row with none; the sessions of no saved host are section 1. Replaces
    /// `testANewerSessionOfTheSameHostIsTheOneShown` once `group` goes (step 4): the screen still
    /// uses `group` in step 3, so that test stays until then.
    @MainActor
    func testEverySessionOfAHostIsARowOldestFirst() async throws {
        let host = SavedHost(name: "h", host: "example.org", user: "u")
        let empty = SavedHost(name: "e", host: "example.net", user: "u")
        let middle = try await makeRecord(createdAt: 3, pid: 60, endIt: true)
        let newest = try await makeRecord(createdAt: 5, pid: 61, endIt: true)
        let oldest = try await makeRecord(createdAt: 1, pid: 62, endIt: true)
        let apart = try await makeRecord(createdAt: 2, pid: 63, endIt: true)
        for meta in [middle, newest, oldest] { SessionFiles.link(meta.id, to: host.id, linksURL: linksURL) }
        let sessions = SessionList.load(root: root, linksURL: linksURL, liveID: nil)
        func listed(_ meta: SessionMeta) throws -> ListedSession {
            try XCTUnwrap(sessions.first { $0.id == meta.id })
        }

        let rows = SessionList.rows(hosts: [host, empty], sessions: sessions, last: nil)
        XCTAssertEqual(rows.count, 2, "a session of no saved host makes section 1")
        XCTAssertEqual(rows.first, [
            .host(host, sessions: 3),
            .session(try listed(oldest), host: host, number: 1, isLast: false),
            .session(try listed(middle), host: host, number: 2, isLast: false),
            .session(try listed(newest), host: host, number: 3, isLast: false),
            .host(empty, sessions: 0),
        ])
        XCTAssertEqual(rows.last, [.session(try listed(apart), host: nil, number: 1, isLast: false)])

        XCTAssertEqual(SessionList.rows(hosts: [], sessions: [], last: nil), [[.noHosts]])
        XCTAssertEqual(SessionList.rows(hosts: [], sessions: sessions, last: nil).first, [.noHosts],
                       "a deleted host's sessions are listed apart")
        XCTAssertEqual(SessionList.rows(hosts: [], sessions: sessions, last: nil).last?.count, 4)

        // Ties by id, a record without `meta` last.
        let ids = (0..<3).map { _ in SessionID.random() }.sorted { $0.description < $1.description }
        func bare(_ id: SessionID, _ createdAt: UInt64?) -> ListedSession {
            ListedSession(id: id, hostID: host.id,
                          meta: createdAt.map {
                              SessionMeta(id: id, createdAt: $0, hostName: "h", address: "127.0.0.1", port: 9,
                                          serverStartSize: TerminalSize(width: 80, height: 24))
                          },
                          state: .resumable, lastUsed: nil)
        }
        let tied = SessionList.rows(hosts: [host], sessions: [bare(ids[0], nil), bare(ids[2], 7), bare(ids[1], 7)],
                                    last: nil)
        XCTAssertEqual(tied, [[
            .host(host, sessions: 3),
            .session(bare(ids[1], 7), host: host, number: 1, isLast: false),
            .session(bare(ids[2], 7), host: host, number: 2, isLast: false),
            .session(bare(ids[0], nil), host: host, number: 3, isLast: false),
        ]])
    }

    /// DESIGN.md 2.2: what this process is doing beats the files, in this order: on screen,
    /// ending, being saved.
    func testOnScreenBeatsEndingBeatsParkingBeatsTheFiles() {
        let readings: [ListedSessionState.Reading] = [.state(.clean(snapshotID: 1)), .state(.ended), .unreadable]
        for reading in readings {
            for isEnding in [false, true] {
                for isParking in [false, true] {
                    XCTAssertEqual(ListedSessionState.derive(reading, isLive: true, isEnding: isEnding, isParking: isParking),
                                   .live, "\(reading) \(isEnding) \(isParking)")
                }
                XCTAssertEqual(ListedSessionState.derive(reading, isLive: false, isEnding: true, isParking: isEnding),
                               .ending, "ending beats parking and the files: \(reading)")
            }
            XCTAssertEqual(ListedSessionState.derive(reading, isLive: false, isEnding: false, isParking: true),
                           .parking, "parking beats the files: \(reading)")
        }
        XCTAssertEqual(ListedSessionState.derive(.state(.clean(snapshotID: 1)), isLive: false, isEnding: false,
                                                 isParking: false), .resumable)
        let all: [ListedSessionState] = [.live, .ending, .parking, .resumable, .ended, .dead, .unreadable]
        XCTAssertEqual(Set(all.map(\.identifier)).count, all.count)
        XCTAssertEqual(Set(all.map(\.label)).count, all.count)
        XCTAssertEqual(ListedSessionState.ending.identifier, "ending")
        XCTAssertEqual(ListedSessionState.parking.identifier, "parking")
    }

    /// DESIGN.md 4.1: the dot is on the one row whose id is the last looked-at one, not on the
    /// other sessions of its host, and on none when the id names no listed session.
    func testOnlyTheLastLookedAtRowHasTheDot() {
        let host = SavedHost(name: "h", host: "example.org", user: "u")
        let sessions = (1...3).map { _ in
            ListedSession(id: .random(), hostID: host.id, meta: nil, state: .resumable, lastUsed: nil)
        }
        let apart = ListedSession(id: .random(), hostID: nil, meta: nil, state: .resumable, lastUsed: nil)
        func dots(_ last: SessionID?) -> [SessionID] {
            SessionList.rows(hosts: [host], sessions: sessions + [apart], last: last).joined().compactMap {
                if case let .session(session, _, _, isLast) = $0, isLast { return session.id }
                return nil
            }
        }
        for session in sessions + [apart] {
            XCTAssertEqual(dots(session.id), [session.id])
        }
        XCTAssertEqual(dots(nil), [])
        XCTAssertEqual(dots(.random()), [], "an id of no listed session marks no row")
    }

    /// DESIGN.md 4.3: the second line counts whole minutes, so it changes at most once a minute.
    func testTheStateLineMovesOncePerMinute() {
        let used = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ state: ListedSessionState, after seconds: TimeInterval) -> String {
            SessionList.stateLine(ListedSession(id: .random(), hostID: nil, meta: nil, state: state, lastUsed: used),
                                  now: used.addingTimeInterval(seconds))
        }
        XCTAssertEqual(line(.resumable, after: 0), "last used just now")
        XCTAssertEqual(line(.resumable, after: 59), "last used just now")
        XCTAssertEqual(line(.resumable, after: 60), "last used 1 min ago")
        for second in stride(from: 300.0, to: 360, by: 1) {
            XCTAssertEqual(line(.resumable, after: second), "last used 5 min ago", "\(second) s")
        }
        XCTAssertEqual(line(.resumable, after: 360), "last used 6 min ago")
        XCTAssertEqual(line(.dead, after: 330), "Could not be resumed · last used 5 min ago")
        XCTAssertEqual(line(.ended, after: 330), "Ended, server not yet stopped")
        XCTAssertEqual(line(.unreadable, after: 330), "Cannot be read now")
        XCTAssertEqual(line(.parking, after: 330), "Saving…")
        XCTAssertEqual(line(.ending, after: 330), "Ending…")
        XCTAssertEqual(line(.live, after: 330), "Connected")
    }

    /// BRIEF.md item 11 (step 13b): a resumable or dead row says how long ago the session was
    /// started, then when it was last used, "started 2 h ago · last used just now".
    func testTheSecondLineSaysTheStartFirst() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let used = started.addingTimeInterval(2 * 3600 + 600)
        let now = used.addingTimeInterval(30)
        XCTAssertEqual(SessionList.stateLine(listed(.resumable, started: started, used: used), now: now),
                       "started 2 h ago · last used just now")
        XCTAssertEqual(SessionList.stateLine(listed(.dead, started: started, used: used), now: now),
                       "Could not be resumed · started 2 h ago · last used just now")
        XCTAssertEqual(SessionList.timesText(started: started, used: used, now: now),
                       "started 2 h ago · last used just now")
    }

    /// The start is the record's creation time (`meta.createdAt`), not its last use, counted in
    /// the words and units of "last used": "just now" in the first minute, then whole minutes,
    /// hours and days.
    func testTheStartIsWhenTheRecordWasMade() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        func line(after seconds: TimeInterval, usedAgo: TimeInterval = 0) -> String {
            let now = started.addingTimeInterval(seconds)
            return SessionList.stateLine(listed(.resumable, started: started, used: now.addingTimeInterval(-usedAgo)),
                                         now: now)
        }
        XCTAssertEqual(line(after: 0), "started just now · last used just now")
        XCTAssertEqual(line(after: 59), "started just now · last used just now")
        XCTAssertEqual(line(after: 60), "started 1 min ago · last used just now")
        XCTAssertEqual(line(after: 330, usedAgo: 120), "started 5 min ago · last used 2 min ago")
        XCTAssertEqual(line(after: 3 * 3600 + 59 * 60), "started 3 h ago · last used just now")
        XCTAssertEqual(line(after: 86_400, usedAgo: 3600), "started 1 day ago · last used 1 h ago")
        XCTAssertEqual(line(after: 3 * 86_400 + 5, usedAgo: 300), "started 3 days ago · last used 5 min ago")
        // Two idle sessions of one host, both last used just now, differ by their start.
        let now = started.addingTimeInterval(7200)
        let older = SessionList.stateLine(listed(.resumable, started: started, used: now), now: now)
        let newer = SessionList.stateLine(listed(.resumable, started: now.addingTimeInterval(-600), used: now), now: now)
        XCTAssertEqual(older, "started 2 h ago · last used just now")
        XCTAssertEqual(newer, "started 10 min ago · last used just now")
    }

    /// The rows that show a state keep their line with a start known; without `meta` the line is
    /// as before step 13b; a part that is not known is left out.
    func testOtherStatesKeepTheirLine() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let now = started.addingTimeInterval(7200)
        let kept: [(ListedSessionState, String)] = [
            (.ended, "Ended, server not yet stopped"), (.unreadable, "Cannot be read now"),
            (.parking, "Saving…"), (.ending, "Ending…"), (.live, "Connected"),
        ]
        for (state, text) in kept {
            XCTAssertEqual(SessionList.stateLine(listed(state, started: started, used: now), now: now), text, "\(state)")
        }
        XCTAssertEqual(SessionList.stateLine(listed(.resumable, started: nil, used: now), now: now), "last used just now")
        XCTAssertEqual(SessionList.stateLine(listed(.resumable, started: started, used: nil), now: now), "started 2 h ago")
        XCTAssertEqual(SessionList.stateLine(listed(.dead, started: started, used: nil), now: now),
                       "Could not be resumed · started 2 h ago")
        XCTAssertEqual(SessionList.stateLine(listed(.resumable, started: nil, used: nil), now: now), "Resumable")
        XCTAssertEqual(SessionList.stateLine(listed(.dead, started: nil, used: nil), now: now), "Could not be resumed")
    }

    /// A listed session with a `meta` made at `started` (none when nil).
    private func listed(_ state: ListedSessionState, started: Date?, used: Date?) -> ListedSession {
        let id = SessionID.random()
        return ListedSession(id: id, hostID: nil,
                             meta: started.map {
                                 SessionMeta(id: id, createdAt: UInt64($0.timeIntervalSince1970), hostName: "h",
                                             address: "127.0.0.1", port: 9, serverStartSize: TerminalSize(width: 80, height: 24))
                             },
                             state: state, lastUsed: used)
    }

    /// A record as the app makes it (key in the Keychain), optionally ended on purpose.
    @MainActor
    private func makeRecord(createdAt: UInt64, pid: UInt32, endIt: Bool) async throws -> SessionMeta {
        let key = try Base64Key(bytes: [UInt8](repeating: UInt8(pid & 0xFF), count: 16))
        let meta = SessionMeta(createdAt: createdAt, hostName: "h", address: "127.0.0.1", port: 9, user: "u",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: pid, serverStartTime: 1000)
        try keys.store(key, for: meta.id)
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        if endIt {
            let accepted = await coordinator.shutdown()
            XCTAssertTrue(accepted)
        }
        await coordinator.close()
        return meta
    }
}
