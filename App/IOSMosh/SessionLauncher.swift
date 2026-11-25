import Foundation
import MoshBootstrap
import MoshCrypto
import MoshKeys
import MoshResume
import MoshSession
import MoshTransport

/// A cold start that cannot continue the stored session (docs/PLAN.md section 3, "Fallback";
/// docs/RESUME.md, "What a cold start can say"). Nothing was sent under the old key.
struct SessionFallback {
    var id: SessionID
    /// Why, for the user: shown under `ColdStartFallback.userMessage`.
    var reason: String
    /// The record's `meta` (the old server's pid and start time for the identity check before
    /// it is killed), if it could be read.
    var meta: SessionMeta?
    /// False for a session that was ended on purpose: no new session, only the old server
    /// killed if it is still there, and the record deleted.
    var wantsNewSession: Bool
    /// The record is already gone.
    var recordDeleted: Bool
}

/// What the app does at launch about a stored session.
enum LaunchDecision {
    /// No record: the normal start screen.
    case nothing
    /// The stored session continues; `start()` it.
    case resumed(ResumeCoordinator)
    case fallback(SessionFallback)
    /// Nothing can be decided now (device locked, the record in use, a storage error). The
    /// record is untouched; the app tries again when it becomes active again.
    case retryLater(String)
}

enum SessionLauncher {
    /// The launch target (docs/notes/multi-session/DESIGN.md 2.5, D1): the session he looked at
    /// last, and no other record, also when the list was on screen when the app went away. None
    /// when there is no such id, when it is among the ended records (`ended`: finished in the
    /// background and never opened, 3.5 L6, D4), or when its record is not among the stored ones
    /// (`stored`, the directories under the root; review-steps-2-4.md R24-S3: "last looked at"
    /// can outlive its record, for example when `removeOrphans` could not list the Keychain).
    ///
    /// Pure. Called only by `launch`, which the launch (`SceneDelegate.makeRoot`) and the
    /// launch's retry (W6, through `retry`) call, and nothing else.
    static func launchTarget(last: SessionID?, ended: Set<SessionID>, stored: Set<SessionID>) -> SessionID? {
        guard let last, !ended.contains(last), stored.contains(last) else { return nil }
        return last
    }

    /// What the launch does about the stored sessions (DESIGN.md 2.5, 3.5 L2 to L7): the cold
    /// start of the launch target, through `coldStart(root:id:keys:options:)`, and of no other
    /// record. `last`: "last looked at" (`SessionFiles.lastLookedAt()`); `ended`: the ended
    /// records (`endedRecords`), which the launch finishes elsewhere.
    ///
    /// - No target: `.nothing`; no record is opened, written or deleted (L4, L6).
    /// - A target that turns out not to be a record (the cold start deleted the directory, it
    ///   had no `meta`): forgotten, then `.nothing`; no other record is tried (L7).
    /// - Otherwise the target's own answer: `.resumed` (L2), `.fallback` (L3), `.retryLater`
    ///   (L5).
    ///
    /// Returns the target with the decision, so that a "try again later" names the session it
    /// waits for.
    static func launch(root: String = SessionFiles.root, keys: SessionKeychain = .shared,
                       last: SessionID?, ended: Set<SessionID>) -> (target: SessionID?, decision: LaunchDecision) {
        let stored = Set(SessionStore.sessionIDs(root: root))
        guard let target = launchTarget(last: last, ended: ended, stored: stored) else {
            let why: String
            if let last {
                why = ended.contains(last) ? "\(last) was ended" : "the record of \(last) is not there"
            } else {
                why = "no session was looked at last"
            }
            DebugLog.shared.log("launch: no session is opened (\(why); \(stored.count) stored)")
            return (nil, .nothing)
        }
        DebugLog.shared.log("launch: the target is \(target), the session looked at last")
        let decision = coldStart(root: root, id: target, keys: keys, options: coldStartOptions(root: root, id: target))
        if case .fallback(let fallback) = decision, fallback.recordDeleted, fallback.meta == nil {
            DebugLog.shared.log("cold start: \(target) was not a record (\(fallback.reason)); deleted")
            SessionFiles.forget(target, root: root, keys: keys)
            return (target, .nothing)
        }
        return (target, decision)
    }

    /// The launch's retry (DESIGN.md 3.5 W6), after its settle and its gate, in the same
    /// main-actor turn as its push (`SceneDelegate`): `launch` for the target as it is now, but
    /// only while the launch still waits (a tap, an end or a forget may have dropped the wait
    /// while the retry waited for the settle, 2.2) and only when the session looked at last is
    /// not being ended (`busy.ending`: "Ending…" opens nothing, 3.2 S8). Otherwise nil: no record
    /// is opened and `ended` is not asked; a wait that still stands is asked for again at the
    /// next activation.
    @MainActor
    static func retry(root: String = SessionFiles.root, keys: SessionKeychain = .shared, activity: SessionActivity,
                      last: SessionID?, ended: () -> Set<SessionID>) -> (target: SessionID?, decision: LaunchDecision)? {
        guard let waitedFor = activity.busy.waiting else {
            DebugLog.shared.log("cold start: the retry opens nothing: the launch no longer waits")
            return nil
        }
        if let last, activity.busy.ending.contains(last) {
            DebugLog.shared.log("cold start: the retry opens nothing: \(last) is being ended (the launch waited for \(waitedFor))")
            return nil
        }
        return launch(root: root, keys: keys, last: last, ended: ended())
    }

    /// The cold start of one record. Its duration, from the Keychain read to the decision, goes
    /// to the log (docs/notes/multi-session/DESIGN.md risk 1: every unpark is one, on the main
    /// thread; above about 100 ms it moves off it).
    static func coldStart(root: String, id: SessionID, keys: SessionKeychain,
                          options: ResumeCoordinator.Options) -> LaunchDecision {
        let began = DispatchTime.now().uptimeNanoseconds
        let decision = decide(root: root, id: id, keys: keys, options: options)
        let micros = (DispatchTime.now().uptimeNanoseconds - began) / 1_000
        let outcome: String
        switch decision {
        case .nothing: outcome = "nothing"
        case .resumed: outcome = "resumed"
        case .fallback: outcome = "fallback"
        case .retryLater: outcome = "retry later"
        }
        DebugLog.shared.log("cold start: \(id): \(outcome) in \(micros / 1_000).\(micros % 1_000 / 100) ms")
        return decision
    }

    private static func decide(root: String, id: SessionID, keys: SessionKeychain,
                               options: ResumeCoordinator.Options) -> LaunchDecision {
        // The key first (docs/RESUME.md: on iOS the app reads it from the Keychain and passes it
        // as `.provided`; "interaction not allowed" means coldStart is not called at all).
        let key: Base64Key?
        do {
            key = try keys.key(for: id)
        } catch SessionKeychain.Failure.malformed {
            // Not a state that a later try repairs (review M6-6): as without a key.
            DebugLog.shared.log("cold start: \(id): the Keychain item is not a key")
            key = nil
        } catch {
            DebugLog.shared.log("cold start: \(id): key not readable now: \(error)")
            return .retryLater("\(error)")
        }
        guard let key else {
            // The record without its key: not resumable (docs/PLAN.md section 3: a record needs
            // key, counters and meta). Nothing is written to the record here and nothing is
            // sent; the fallback deletes it once a new session exists.
            let store = SessionStore(root: root, id: id)
            let meta = try? store.readMeta()
            let ended = (try? store.readCounters())?.state == .ended
            DebugLog.shared.log("cold start: \(id): no key in the Keychain; fallback")
            return .fallback(SessionFallback(id: id, reason: "the session key is not in the Keychain", meta: meta,
                                             wantsNewSession: !ended, recordDeleted: false))
        }
        switch ResumeCoordinator.coldStart(root: root, id: id, key: .provided(key), currentSize: nil, options: options) {
        case .resumed(let coordinator):
            DebugLog.shared.log("cold start: \(id): resumed")
            return .resumed(coordinator)
        case .fallback(let fallback):
            DebugLog.shared.log("cold start: \(id): fallback (\(fallback.reason)); record deleted \(fallback.recordDeleted)")
            return .fallback(SessionFallback(id: id, reason: fallback.reason.description, meta: fallback.meta,
                                             wantsNewSession: fallback.wantsNewSession,
                                             recordDeleted: fallback.recordDeleted))
        case .retryLater(let retry):
            DebugLog.shared.log("cold start: \(id): retry later (\(retry))")
            return .retryLater(retry.description)
        }
    }

    /// The coordinator options of every app session: Network.framework datagrams to the
    /// record's address and port, and the session's local echo (M10; not in the record, so it
    /// is passed at every `create` and every cold start; a fallback's new session is a
    /// `create`). Everything else is the package's default (file protection and backup
    /// exclusion of the platform, the default reservation blocks).
    static func options(address: String, port: UInt16, clipboard: ClipboardPolicy = ClipboardPolicy(),
                        localEcho: LocalEcho = .standard) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.clipboard = clipboard
        options.makeTransport = { try NWDatagramTransport(host: address, port: port) }
        options.prediction = localEcho.settings
        return options
    }

    /// The options for a cold start of one record: its address and port come from `meta`,
    /// read before the lock is taken only to build the transport factory (`coldStart` reads
    /// `meta` again under the lock and builds the session from that); local echo from the
    /// saved host the record is linked to, as the terminal screen reads it
    /// (`LocalEcho.forSession`).
    static func coldStartOptions(root: String, id: SessionID) -> ResumeCoordinator.Options {
        let meta = try? SessionStore(root: root, id: id).readMeta()
        return options(address: meta?.address ?? "127.0.0.1", port: meta?.port ?? 1,
                       localEcho: LocalEcho.forSession(host: SessionFiles.host(of: id)))
    }

    /// The server's identity as the record has it, for the identity check before a kill.
    static func serverIdentity(_ meta: SessionMeta?) -> ServerIdentity? {
        guard let meta, meta.serverPID != 0, meta.serverPID <= UInt32(Int32.max), meta.serverStartTime != 0 else { return nil }
        return ServerIdentity(pid: Int32(meta.serverPID),
                              startTime: Date(timeIntervalSince1970: TimeInterval(meta.serverStartTime)))
    }

    /// A session ended on purpose whose record is still there (`FallbackReason.ended`): the
    /// shutdown request may never have arrived, so the old server is killed if the identity
    /// check passes (key login only, no prompts). The record is the only place that holds the
    /// server's pid and start time, so it is deleted only when there is nothing left to do
    /// with them (`OldServerOutcome.mayForget`, review M6-4); otherwise it stays "ended" and
    /// the next launch tries again.
    static func finishEnded(_ fallback: SessionFallback, host: SavedHost?) async {
        let outcome = await stopOldServer(meta: fallback.meta, host: host)
        guard !fallback.recordDeleted else { return }
        if outcome.mayForget {
            SessionFiles.forget(fallback.id)
        } else {
            DebugLog.shared.log("cold start: ended session \(fallback.id) kept for the next launch (\(outcome))")
        }
    }

    /// Tries to stop the `mosh-server` of a session that is over: silent key login to the saved
    /// host, then `killServer`, which signals only after the identity check passed on the same
    /// connection.
    static func stopOldServer(meta: SessionMeta?, host: SavedHost?) async -> OldServerOutcome {
        guard let meta, let host, let identity = serverIdentity(meta) else {
            await reportForUITests(.nothingToAsk)
            return .nothingToAsk
        }
        let connection: SSHConnection
        do {
            let privateKey = try KeychainKeyStore().loadPrivateKey(name: host.keyName)
            connection = try await SSHConnection.connect(
                to: host.target, privateKey: privateKey, knownHosts: AppFiles.knownHosts, interaction: .silent)
        } catch {
            DebugLog.shared.log("old server \(identity.pid): host not reached: \(error)")
            await reportForUITests(.hostNotReached)
            return .hostNotReached
        }
        let outcome: OldServerOutcome
        do {
            try await connection.killServer(pid: identity.pid, expectedStartTime: identity.startTime)
            DebugLog.shared.log("old server \(identity.pid): killed")
            outcome = .killed
        } catch BootstrapError.identityCheckFailed(let mismatch) {
            // "Not there" is proof only at the machine the session was on (review M6-1).
            let same = !meta.address.isEmpty && connection.remoteAddress == meta.address
            DebugLog.shared.log("old server \(identity.pid): not killed, check failed (\(mismatch)), at the session's address: \(same)")
            outcome = .notThere(atSessionAddress: same)
        } catch {
            DebugLog.shared.log("old server \(identity.pid): not killed: \(error)")
            outcome = .notAnswered
        }
        await connection.close()
        await reportForUITests(outcome)
        return outcome
    }

    /// UI-test launches report the outcome to the spawner (`old-server-killed`, ...), so a test
    /// can tell an identity-checked kill from a server that exited by itself. Off the cooperative
    /// pool: the report is a blocking socket call.
    private static func reportForUITests(_ outcome: OldServerOutcome) async {
        await Task.detached { UITestMarks.send("old-server-" + outcome.identifier) }.value
    }

    /// The records of sessions that were ended on purpose and are still there (the shutdown
    /// did not finish, or the old server could not be asked yet). Read without the coordinator:
    /// nothing is resumed and nothing is written. None of them is a launch target.
    static func endedRecords(root: String = SessionFiles.root) -> [SessionFallback] {
        SessionStore.sessionIDs(root: root).compactMap { id in
            let store = SessionStore(root: root, id: id)
            guard (try? store.readCounters())?.state == .ended else { return nil }
            return SessionFallback(id: id, reason: "the session was ended", meta: try? store.readMeta(),
                                   wantsNewSession: false, recordDeleted: false)
        }
    }
}

/// What the attempt to stop the server of a session that is over found.
enum OldServerOutcome: Equatable {
    /// No saved host, or the record has no pid and start time: there is nobody to ask, now or
    /// later.
    case nothingToAsk
    case killed
    /// The identity check failed: no such process, or not this session's server. Proof that
    /// the server is gone only at the session's own address.
    case notThere(atSessionAddress: Bool)
    case hostNotReached
    /// Logged in, but the check or the kill gave no answer that can be used.
    case notAnswered

    /// For UI-test marks and logs.
    var identifier: String {
        switch self {
        case .nothingToAsk: return "nothing-to-ask"
        case .killed: return "killed"
        case .notThere(let atSessionAddress): return atSessionAddress ? "not-there" : "not-there-elsewhere"
        case .hostNotReached: return "host-not-reached"
        case .notAnswered: return "not-answered"
        }
    }

    /// Whether the record, and with it the server's pid and start time, may be deleted: only
    /// when the server is stopped or provably gone, or when the record cannot help to stop it.
    var mayForget: Bool {
        switch self {
        case .nothingToAsk, .killed: return true
        case .notThere(let atSessionAddress): return atSessionAddress
        case .hostNotReached, .notAnswered: return false
        }
    }
}
