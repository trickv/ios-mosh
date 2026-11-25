import Foundation
import MoshResume

/// A session record's state as the host list shows it (docs/PLAN.md Design 4, "Session list":
/// live, resumable, ended, dead; docs/notes/multi-session/DESIGN.md 2.2 adds ending and parking).
///
/// The label is a hint read from the files without the coordinator (nothing is locked,
/// resumed or written). What a tap does is never decided from it: every tap on a record that
/// is not live goes through `SessionLauncher.coldStart` (the coordinator), which says resume,
/// fallback or "try again later".
enum ListedSessionState: Equatable {
    /// This process has the session open now.
    case live
    /// A shutdown this process started is in flight (DESIGN.md 2.2, "Ending").
    case ending
    /// Its park is in flight: the save before its lock is released (DESIGN.md 2.3).
    case parking
    /// Clean for its snapshot: a cold start resumes it.
    case resumable
    /// Ended on purpose; its server is not known to be stopped yet (docs/RESUME.md,
    /// `.fallback(.ended)`).
    case ended
    /// Not resumable: a cold start falls back to a new session.
    case dead
    /// The counters cannot be read now (device locked, a storage error, a damaged record).
    case unreadable

    /// What the counters say, as far as the list is concerned.
    enum Reading: Equatable {
        case state(RecordState)
        case unreadable
    }

    /// The one place that turns a record into a list state. What this process is doing to the
    /// session beats its files, in this order: on screen, ending, being saved (DESIGN.md 2.2).
    static func derive(_ reading: Reading, isLive: Bool, isEnding: Bool = false,
                       isParking: Bool = false) -> ListedSessionState {
        if isLive { return .live }
        if isEnding { return .ending }
        if isParking { return .parking }
        switch reading {
        case .unreadable:
            return .unreadable
        case .state(.clean(_)):
            return .resumable
        case .state(.ended):
            return .ended
        case .state:
            // Every other state is "dead". In stage 1 that is the dirty record, which falls back
            // (docs/RESUME.md, "What a cold start can say"). No case is named here, so the core
            // can rename or add states (resume stage 2, docs/notes/stage2/DESIGN.md section 12,
            // step 0) without breaking this build; step 9 gives the stage 2 states their labels.
            return .dead
        }
    }

    /// For UI tests (the row's accessibility value) and logs.
    var identifier: String {
        switch self {
        case .live: return "live"
        case .ending: return "ending"
        case .parking: return "parking"
        case .resumable: return "resumable"
        case .ended: return "ended"
        case .dead: return "dead"
        case .unreadable: return "unreadable"
        }
    }

    /// For the user, in the row.
    var label: String {
        switch self {
        case .live: return "Connected"
        case .ending: return "Ending…"
        case .parking: return "Saving…"
        case .resumable: return "Resumable"
        case .ended: return "Ended, server not yet stopped"
        case .dead: return "Cannot be resumed"
        case .unreadable: return "Cannot be read now"
        }
    }
}

/// One record on disk, for the host list.
struct ListedSession: Equatable {
    var id: SessionID
    /// The saved host it was started from (`SessionFiles` links), if any.
    var hostID: UUID?
    var meta: SessionMeta?
    var state: ListedSessionState
    /// The newest modification time of the record's files: the last save or state change.
    var lastUsed: Date?

    /// When the record was made (`meta.createdAt`, whole seconds), if its `meta` could be read.
    var started: Date? {
        meta.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) }
    }
}

/// One row of the list (DESIGN.md 4.1).
enum ListRow: Equatable {
    /// "No hosts yet": section 0 when there is no saved host.
    case noHosts
    /// A saved host and how many sessions are listed under it.
    case host(SavedHost, sessions: Int)
    /// A session: under its saved host (`host` set), or among the sessions of no saved host.
    case session(ListedSession, host: SavedHost?, number: Int, isLast: Bool)
}

/// The host list's view of the records (docs/PLAN.md Design 4, "Session list"). Reads only:
/// `meta`, the counters' state and file dates, never under the record's lock.
enum SessionList {
    /// The cold start's "try again later" (review M6-6): shown on the host list until a later
    /// cold start decides something else. Set by `SceneDelegate` and by a tap on a row.
    static var waitingReason: String?

    static func waitingText(_ reason: String) -> String {
        "A session is waiting: \(reason). It is tried again when the app becomes active."
    }

    /// Every record under `root`, newest first.
    static func load(root: String = SessionFiles.root, linksURL: URL = SessionFiles.linksURL,
                     liveID: SessionID?) -> [ListedSession] {
        let links = SessionFiles.links(linksURL: linksURL)
        return SessionStore.sessionIDs(root: root).map { id in
            let store = SessionStore(root: root, id: id)
            let reading: ListedSessionState.Reading
            if let counters = try? store.readCounters() {
                reading = .state(counters.state)
            } else {
                reading = .unreadable
            }
            return ListedSession(id: id, hostID: links[id], meta: try? store.readMeta(),
                                 state: .derive(reading, isLive: id == liveID),
                                 lastUsed: lastModified(directory: store.directory))
        }.sorted { ($0.meta?.createdAt ?? .max) > ($1.meta?.createdAt ?? .max) }
    }

    /// The newest session of each saved host, and the sessions of no saved host (a debug
    /// session, a deleted host), newest first.
    static func group(_ sessions: [ListedSession], hosts: [SavedHost]) -> (byHost: [UUID: ListedSession], other: [ListedSession]) {
        let known = Set(hosts.map(\.id))
        var byHost: [UUID: ListedSession] = [:]
        var other: [ListedSession] = []
        for session in sessions {
            if let hostID = session.hostID, known.contains(hostID) {
                if byHost[hostID] == nil { byHost[hostID] = session }
            } else {
                other.append(session)
            }
        }
        return (byHost, other)
    }

    /// The rows of the list (DESIGN.md 4.1): section 0 is every saved host in the given order,
    /// each followed by all its sessions, oldest first by `meta.createdAt` (ties by id, a record
    /// without `meta` last; D3), or `.noHosts`; section 1, present only when there are any, is the
    /// sessions of no saved host, in the order given (`load`: newest first, as today). `number`
    /// counts a host's rows from 1 (the identifier `session-<host>-<n>`); `isLast` is the one row
    /// whose id is `last` (the dot). Replaces `group` once the screen draws these (step 4).
    static func rows(hosts: [SavedHost], sessions: [ListedSession], last: SessionID?) -> [[ListRow]] {
        let known = Set(hosts.map(\.id))
        var byHost: [UUID: [ListedSession]] = [:]
        var other: [ListedSession] = []
        for session in sessions {
            if let hostID = session.hostID, known.contains(hostID) {
                byHost[hostID, default: []].append(session)
            } else {
                other.append(session)
            }
        }
        var saved: [ListRow] = hosts.isEmpty ? [.noHosts] : []
        for host in hosts {
            let mine = (byHost[host.id] ?? []).sorted(by: oldestFirst)
            saved.append(.host(host, sessions: mine.count))
            for (index, session) in mine.enumerated() {
                saved.append(.session(session, host: host, number: index + 1, isLast: session.id == last))
            }
        }
        guard !other.isEmpty else { return [saved] }
        return [saved, other.enumerated().map { index, session in
            .session(session, host: nil, number: index + 1, isLast: session.id == last)
        }]
    }

    /// D3: oldest first by `meta.createdAt`, ties by id, a record without `meta` last.
    private static func oldestFirst(_ a: ListedSession, _ b: ListedSession) -> Bool {
        switch (a.meta?.createdAt, b.meta?.createdAt) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.id.description < b.id.description
        }
    }

    /// A session row's second line (DESIGN.md 4.3). The times are counted in whole minutes, so
    /// the text changes at most once a minute. A resumable or dead row says how long ago the
    /// session was started, then when it was last used (BRIEF.md item 11: two idle sessions of
    /// one host differ by their age); the other states keep their label.
    static func stateLine(_ session: ListedSession, now: Date) -> String {
        let times = timesText(started: session.started, used: session.lastUsed, now: now)
        switch session.state {
        case .live, .ending, .parking, .ended, .unreadable:
            return session.state.label
        case .resumable:
            return times ?? "Resumable"
        case .dead:
            return "Could not be resumed" + (times.map { " · " + $0 } ?? "")
        }
    }

    /// "started 2 h ago · last used just now": the start first, each in `relativeTime`'s words; a
    /// part that is not known is left out, nil when neither is.
    static func timesText(started: Date?, used: Date?, now: Date) -> String? {
        let parts = [started.map { "started " + relativeTime(since: $0, now: now) },
                     used.map { "last used " + relativeTime(since: $0, now: now) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "just now" under a minute, then "5 min ago", "3 h ago", "2 days ago"; whole units only.
    static func relativeTime(since date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    private static func lastModified(directory: String) -> Date? {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.compactMap { name in
            (try? url.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.max()
    }
}
