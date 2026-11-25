import Foundation
import MoshBootstrap
import MoshResume

/// Where resumable sessions live, and the app's bookkeeping around `MoshResume`'s records.
///
/// - Records: `Application Support/sessions/<session id>/` (docs/PLAN.md section 3), made,
///   opened and deleted only by `ResumeCoordinator`.
/// - Keys: `SessionKeychain` (the record has no `key` file on iOS).
/// - Links: `Application Support/session-hosts.json` says which saved host a session was
///   started from, so that a fallback can bootstrap again with the host's settings (SSH
///   port, key, server path, locale; `SessionMeta` holds only the host name, address, user
///   and remote command). A session without a link (a debug launch) has no host.
enum SessionFiles {
    static var root: String {
        AppFiles.supportDirectory.appendingPathComponent("sessions", isDirectory: true).path
    }

    static var linksURL: URL { AppFiles.supportDirectory.appendingPathComponent("session-hosts.json") }

    // MARK: Links

    private struct LinksFile: Codable {
        var version: Int
        /// Session id (lowercase UUID) to saved host id.
        var links: [String: UUID]
        /// The session he looked at last (docs/notes/multi-session/DESIGN.md 2.5), a session id
        /// (lowercase UUID). Optional, so that a file written before it existed decodes as
        /// "none"; the version stays 1 and an older build ignores the key.
        var lastLookedAt: String?
    }

    /// Every read-change-write of the file goes under this one lock (A15 of the lifecycle
    /// map): `finishEnded` forgets off the main thread while a new session links on it, and
    /// without the lock one of the two writes is lost.
    private static let fileLock = NSLock()

    private static var emptyFile: LinksFile { LinksFile(version: 1, links: [:], lastLookedAt: nil) }

    /// The file as stored. Only "there is no such file" is an empty file (review-steps-2-4.md,
    /// R24-S2, as `HostStore.load`); a file that exists but cannot be read now, cannot be
    /// decoded or has another version is `.failure` with a short reason (no path, nothing of
    /// its contents), and nothing may be written over it.
    private static func loadFile(_ linksURL: URL) -> Result<LinksFile, UnusableLinksFile> {
        let data: Data
        do {
            data = try Data(contentsOf: linksURL)
        } catch {
            var info = stat()
            if lstat(linksURL.path, &info) != 0, errno == ENOENT { return .success(emptyFile) }
            let ns = error as NSError
            return .failure(UnusableLinksFile(reason: "cannot be read (\(ns.domain) \(ns.code))"))
        }
        guard let file = try? JSONDecoder().decode(LinksFile.self, from: data) else {
            return .failure(UnusableLinksFile(reason: "cannot be decoded (\(data.count) bytes)"))
        }
        guard file.version == 1 else {
            return .failure(UnusableLinksFile(reason: "has version \(file.version)"))
        }
        return .success(file)
    }

    private struct UnusableLinksFile: Error {
        let reason: String
    }

    /// For the readers: a file that cannot be used now reads as empty, as before; only the
    /// writers keep away from it (`update`).
    private static func loadLinks(_ linksURL: URL) -> [String: UUID] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return (try? loadFile(linksURL).get())?.links ?? [:]
    }

    private static func saveFile(_ file: LinksFile, _ linksURL: URL) {
        do {
            try FileManager.default.createDirectory(at: linksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: linksURL, options: .atomic)
        } catch {
            DebugLog.shared.log("session files: links not saved: \(error)")
        }
    }

    /// Reads the file, lets `change` change it and writes it back when `change` says it
    /// changed something, all under `fileLock`. A file that exists but cannot be used now is
    /// left exactly as it is: the change is skipped and logged (`what` says which), never
    /// written over the links it may still hold (R24-S2).
    private static func update(_ linksURL: URL, _ what: @autoclosure () -> String, _ change: (inout LinksFile) -> Bool) {
        fileLock.lock()
        defer { fileLock.unlock() }
        switch loadFile(linksURL) {
        case .success(var file):
            if change(&file) { saveFile(file, linksURL) }
        case .failure(let unusable):
            DebugLog.shared.log("session files: session-hosts.json \(unusable.reason): \(what()) skipped, the file is left as it is")
        }
    }

    static func link(_ id: SessionID, to host: UUID?, linksURL: URL = linksURL) {
        update(linksURL, "link of \(id)") { file in
            file.links[id.description] = host
            return true
        }
    }

    // MARK: Last looked at

    /// The session he looked at last (the green dot; the launch's target from a later step),
    /// if any. Nothing checks here that its record still exists.
    static func lastLookedAt(linksURL: URL = linksURL) -> SessionID? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return (try? loadFile(linksURL).get())?.lastLookedAt.flatMap(SessionID.init)
    }

    /// Stores `id` as the session looked at last (`attach`: a coordinator became a screen's
    /// session); nil clears it.
    static func setLastLookedAt(_ id: SessionID?, linksURL: URL = linksURL) {
        update(linksURL, "last looked at \(id?.description ?? "none")") { file in
            let text = id?.description
            guard file.lastLookedAt != text else { return false }
            file.lastLookedAt = text
            return true
        }
    }

    /// Clears "last looked at" when it names `id`, and only then (DESIGN.md 2.5: the one
    /// function that clears it).
    static func clearLastLookedAt(ifNamed id: SessionID, linksURL: URL = linksURL) {
        update(linksURL, "clearing last looked at of \(id)") { clearLastLookedAt(ifNamed: id, in: &$0) }
    }

    private static func clearLastLookedAt(ifNamed id: SessionID, in file: inout LinksFile) -> Bool {
        guard file.lastLookedAt == id.description else { return false }
        file.lastLookedAt = nil
        return true
    }

    /// The saved host id a session is linked to (for the tests).
    static func linkedHostID(of id: SessionID, linksURL: URL = linksURL) -> UUID? {
        loadLinks(linksURL)[id.description]
    }

    /// Every link, for the host list.
    static func links(linksURL: URL = linksURL) -> [SessionID: UUID] {
        var result: [SessionID: UUID] = [:]
        for (text, host) in loadLinks(linksURL) {
            if let id = SessionID(text) { result[id] = host }
        }
        return result
    }

    /// The saved host a session was started from, if it is still saved.
    static func host(of id: SessionID, hosts: HostStore = HostStore()) -> SavedHost? {
        guard let hostID = loadLinks(linksURL)[id.description] else { return nil }
        return (try? hosts.load())?.first { $0.id == hostID }
    }

    // MARK: Removing

    /// Removes a session for good: its record (under its lock), its key, its link and "last
    /// looked at" if it names the session. The record goes first: a record without a key is a
    /// fallback, a key without a record is an orphan that the next launch removes.
    /// - Returns: false if the record could not be deleted now (in use, or a storage error); the
    ///   key and link are then kept.
    @discardableResult
    static func forget(_ id: SessionID, root: String = root, keys: SessionKeychain = .shared,
                       linksURL: URL = linksURL) -> Bool {
        do {
            try ResumeCoordinator.deleteRecord(root: root, id: id)
        } catch {
            DebugLog.shared.log("session files: record \(id) not deleted: \(error)")
            return false
        }
        do {
            try keys.delete(id)
        } catch {
            DebugLog.shared.log("session files: key of \(id) not deleted: \(error)")
        }
        update(linksURL, "removing the link of \(id)") { file in
            // Written when either the link or "last looked at" went: a session without a link
            // (a debug session) can still be the one he looked at last.
            let linkRemoved = file.links.removeValue(forKey: id.description) != nil
            let cleared = clearLastLookedAt(ifNamed: id, in: &file)
            return linkRemoved || cleared
        }
        DebugLog.shared.log("session files: \(id) forgotten")
        return true
    }

    /// Keys, links and a "last looked at" id whose record directory is known to be gone (a
    /// restore from a backup brings Keychain items back without the excluded record; a crash
    /// between storing the key and making the record). Anything that cannot be decided now is
    /// left alone.
    static func removeOrphans(root: String = root, keys: SessionKeychain = .shared, linksURL: URL = linksURL) {
        let keyIDs: [SessionID]
        do {
            keyIDs = try keys.sessionIDs()
        } catch {
            DebugLog.shared.log("session files: keys not listed: \(error)")
            return
        }
        update(linksURL, "removing orphan links") { file in
            var changed = false
            let lastLookedAt = file.lastLookedAt.flatMap(SessionID.init).map { [$0] } ?? []
            for id in Set(keyIDs + file.links.keys.compactMap(SessionID.init) + lastLookedAt) {
                guard let exists = try? SessionStore(root: root, id: id).exists, !exists else { continue }
                try? keys.delete(id)
                if file.links.removeValue(forKey: id.description) != nil { changed = true }
                if clearLastLookedAt(ifNamed: id, in: &file) { changed = true }
                DebugLog.shared.log("session files: orphan key, link or last looked-at id of \(id) removed")
            }
            return changed
        }
    }

    /// Whether a launch deletes every session record, key and link before it starts (review
    /// M6-11). Only a UI-test launch that asks for it with `-uiTestingResetSessions 1`, as
    /// `AppFiles` waits for `-uiTestingReset 1`; `-uiTestingKeepSessions 1` (the relaunches of
    /// the resume tests) wins over it. A Debug build on the phone launched with `-uiTesting 1`
    /// alone keeps its sessions.
    static func resetsSessionsForUITests(uiTesting: Bool, resetSessions: Bool, keepSessions: Bool) -> Bool {
        uiTesting && resetSessions && !keepSessions
    }

    /// UI tests: a launch with `-uiTesting 1 -uiTestingResetSessions 1` starts without sessions
    /// (`resetsSessionsForUITests`).
    static func resetForUITestsIfAsked() {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard resetsSessionsForUITests(uiTesting: UITestSupport.isUITesting,
                                       resetSessions: defaults.bool(forKey: "uiTestingResetSessions"),
                                       keepSessions: defaults.bool(forKey: "uiTestingKeepSessions")) else { return }
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(at: linksURL)
        SessionKeychain.shared.deleteAll()
        #endif
    }

    /// UI tests: `-uiTestingCountersMode 000` makes the `counters` file of every record
    /// unreadable before the cold start, as a locked device makes it (`EACCES` instead of
    /// `EPERM`): the cold start says "try again later" and the host list shows the record as
    /// "cannot be read now". `-uiTestingCountersMode 600` makes them readable again. Only the
    /// file's mode changes, never its bytes; nothing in the resume core is bypassed. Debug builds
    /// and UI-test launches only.
    static func applyCountersModeForUITestsIfAsked() {
        #if DEBUG
        guard UITestSupport.isUITesting,
              let text = UserDefaults.standard.string(forKey: "uiTestingCountersMode"),
              let mode = mode_t(text, radix: 8), mode <= 0o777 else { return }
        for id in SessionStore.sessionIDs(root: root) {
            let path = (SessionStore(root: root, id: id).directory as NSString).appendingPathComponent("counters")
            let result = chmod(path, mode)
            DebugLog.shared.log("ui tests: counters of \(id) mode \(text): \(result == 0 ? "set" : "errno \(errno)")")
        }
        #endif
    }
}
