#if DEBUG
import Foundation
import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import Security
import UIKit

/// Phone self-test, device part (docs/RESUME.md "Needs the Mac or the phone"): what only a real
/// device can answer about the session record, read back the way the app sees it.
///
/// - the file protection class of a record's directory and of `meta`, `counters`, `lock` and
///   `snapshot`, and the backup exclusion of the directory (`AppleRecordProtection`);
/// - the Keychain accessibility class of a session key item, read back after `store`;
/// - the cost of a save (`SessionRecord.save`) and of the first datagram after it
///   (`willSendDatagram`, "dirty" in both slots), on the device's storage;
/// - the errno of `lstat` on a missing file (R20);
/// - the boot identifier `kern.bootsessionuuid`, read twice, with the validity check of resume
///   stage 2 (docs/notes/stage2/DESIGN.md section 8; section 12, step 0).
///
/// Everything it writes is its own and is removed again: a throwaway record under
/// `Application Support/smoke-probe/` (never `sessions/`, so the cold start never sees it) and a
/// throwaway Keychain item in a service of its own. Of the app's own items it reads attributes
/// only (count and accessibility class), never a key, never record contents. The snapshot it
/// saves is made up here. Debug builds only; started by `SmokeProbe`.
///
/// `SMOKE_LOCKED_SAVE=1` adds the locked pass: the owner locks the phone after the launch; once
/// `isProtectedDataAvailable` is false and a control file of class "complete" is unreadable
/// (iOS drops that class key about 10 s after the lock), the same save, a reopen of a closed
/// record and a Keychain read run again. The result says "ok", "not locked - invalid" (the
/// checks did not run locked: proves nothing) or "locked - a check failed".
enum DeviceProbe {
    static let keychainService = "us.v9n.ios-mosh.smoke-probe"
    static let saves = 20

    static var root: String {
        AppFiles.supportDirectory.appendingPathComponent("smoke-probe", isDirectory: true).path
    }

    // MARK: Unlocked pass

    /// Runs the checks with the device as it is now and removes what it made.
    static func run(root: String = DeviceProbe.root, saves: Int = DeviceProbe.saves,
                    keychainService: String = DeviceProbe.keychainService) -> [String: Any] {
        try? FileManager.default.removeItem(atPath: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var result: [String: Any] = [:]
        result["protectedDataAvailable"] = protectedDataAvailable()
        result["record"] = recordChecks(root: root, saves: saves)
        result["keychain"] = keychainChecks(service: keychainService)
        result["lstatMissing"] = lstatErrno(root + "/no-such-file")
        result["bootIdentifier"] = bootIdentifierCheck()
        // Resume stage 2's device figures (StageTwoProbe); like the boot identifier, not in "ok".
        result["stage2"] = StageTwoProbe.timings(directory: root + "/stage2")
        // The boot identifier is not part of "ok": it is a question about the device for resume
        // stage 2 (its own "valid"), not a check of what stage 1 needs.
        result["ok"] = isOK(result)
        return result
    }

    // MARK: Boot identifier

    /// The per-boot value resume stage 2 keys an open record to (docs/notes/stage2/DESIGN.md,
    /// section 8; section 12, step 0 asks the phone whether an app can read it and whether it is
    /// new at each boot).
    static let bootIdentifierName = "kern.bootsessionuuid"

    /// What one read of the sysctl gave: its bytes as returned, or the errno of the call that
    /// failed (`step` "size" for the call that asks for the length, "read" for the value).
    enum BootIdentifierRead: Equatable {
        case bytes([UInt8])
        case failed(errno: Int32, step: String)
    }

    /// One read through `sysctlbyname`, the API section 8 names. Never crashes and never makes
    /// up a value: a refusal or a missing name comes back as `.failed` with its errno.
    static func readBootIdentifier() -> BootIdentifierRead {
        var size = 0
        guard sysctlbyname(bootIdentifierName, nil, &size, nil, 0) == 0 else {
            return .failed(errno: errno, step: "size")
        }
        guard size > 0 else { return .bytes([]) }
        // A UUID is 37 bytes with its NUL; anything far longer is not one, but is still shown.
        var buffer = [UInt8](repeating: 0, count: min(size, 4096))
        var length = buffer.count
        guard sysctlbyname(bootIdentifierName, &buffer, &length, nil, 0) == 0 else {
            return .failed(errno: errno, step: "read")
        }
        return .bytes(Array(buffer.prefix(length)))
    }

    /// The text section 8 checks: one trailing NUL removed, then white space at both ends.
    static func bootIdentifierText(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        if bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exactly 36 characters, hexadecimal digits in groups of 8-4-4-4-12 joined by hyphens.
    static func isUUIDText(_ text: String) -> Bool {
        let characters = Array(text.unicodeScalars)
        guard characters.count == 36 else { return false }
        for (index, character) in characters.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if character != "-" { return false }
            } else if !("0"..."9").contains(character) && !("a"..."f").contains(character)
                        && !("A"..."F").contains(character) {
                return false
            }
        }
        return true
    }

    /// Not the nil UUID (and not empty): some digit is not 0.
    static func isNotZeroUUIDText(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 != "0" && $0 != "-" }
    }

    /// The digest section 8 stores: 64-bit FNV-1a over the lower-case text, 0 mapped to 1.
    static func bootDigest(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash == 0 ? 1 : hash
    }

    /// Two reads of the boot identifier and what section 8 says about them: "valid" only when
    /// both reads gave a well-formed UUID that is not all zeros and the two agree. `status` says
    /// in words what was found; `value` is there only if the first read gave bytes.
    static func bootIdentifierCheck(read: () -> BootIdentifierRead = readBootIdentifier) -> [String: Any] {
        let reads = [read(), read()]
        var texts: [String] = []
        var failure: (errno: Int32, step: String)?
        var readsOut: [[String: Any]] = []
        for one in reads {
            switch one {
            case .bytes(let bytes):
                let text = bootIdentifierText(bytes)
                texts.append(text)
                readsOut.append(["readable": true, "bytes": bytes.count, "value": text,
                                 "wellFormed": isUUIDText(text), "notZero": isNotZeroUUIDText(text)])
            case .failed(let code, let step):
                if failure == nil { failure = (code, step) }
                readsOut.append(["readable": false, "errno": Int(code), "error": String(cString: strerror(code)),
                                 "step": step])
            }
        }
        var out: [String: Any] = ["name": bootIdentifierName, "api": "sysctlbyname", "reads": readsOut]
        let readable = texts.count == reads.count
        let wellFormed = readable && texts.allSatisfy(isUUIDText)
        let notZero = readable && texts.allSatisfy(isNotZeroUUIDText)
        let readsEqual = readable && Set(texts.map { $0.lowercased() }).count == 1
        let valid = wellFormed && notZero && readsEqual
        if let first = texts.first, case .bytes = reads[0] { out["value"] = first }
        out["readable"] = readable
        out["wellFormed"] = wellFormed
        out["notZero"] = notZero
        out["readsEqual"] = readsEqual
        out["valid"] = valid
        if valid, let first = texts.first {
            out["digest"] = String(format: "%016llx", bootDigest(first))
        }
        let status: String
        if let failure {
            let what = failure.errno == ENOENT ? "not there" : "read refused"
            status = "\(what): errno \(failure.errno) (\(String(cString: strerror(failure.errno)))) at the \(failure.step) step"
        } else if texts.contains(where: \.isEmpty) {
            status = "empty"
        } else if !wellFormed {
            status = "not a UUID"
        } else if !notZero {
            status = "the nil UUID"
        } else if !readsEqual {
            status = "two reads differ"
        } else {
            status = "ok: a well-formed UUID, not zero, the same in two reads"
        }
        out["status"] = status
        return out
    }

    /// A record state as the probe prints it. Only the states the probe's verdicts look for are
    /// named; every other state prints itself, so the core can rename or add states (resume
    /// stage 2, docs/notes/stage2/DESIGN.md section 12, step 0) without breaking this build.
    static func stateName(_ state: RecordState) -> String {
        switch state {
        case .clean: return "clean"
        case .ended: return "ended"
        default: return "\(state)"
        }
    }

    private static func recordChecks(root: String, saves: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        let createStart = Date()
        let record: SessionRecord
        do {
            record = try SessionRecord.create(root: root, meta: meta(), key: nil)
        } catch {
            return ["error": "create: \(error)"]
        }
        out["createMs"] = milliseconds(since: createStart)
        var saveMs: [Double] = []
        var datagramMs: [Double] = []
        var cleanCount = 0
        do {
            let reserveStart = Date()
            _ = try record.gate.takeSequenceNumber()
            out["firstReservationMs"] = milliseconds(since: reserveStart)
            let snapshot = sampleSnapshot()
            for _ in 0..<saves {
                let start = Date()
                let export = SessionExport(snapshot: snapshot,
                                           cleanToken: CleanToken(datagramsPassed: record.gate.datagramsPassed))
                if try record.save(export) { cleanCount += 1 }
                saveMs.append(milliseconds(since: start))
                let sendStart = Date()
                try record.gate.willSendDatagram()
                datagramMs.append(milliseconds(since: sendStart))
            }
        } catch {
            out["error"] = "save: \(error)"
        }
        out["saves"] = saves
        out["cleanSaves"] = cleanCount
        out["saveMs"] = summary(saveMs)
        out["firstDatagramAfterSaveMs"] = summary(datagramMs)
        let directory = record.store.directory
        out["protection"] = protectionClasses(directory: directory)
        out["excludedFromBackup"] = excludedFromBackup(directory)
        out["verify"] = (try? AppleRecordProtection().verify(directory: directory)) ?? false
        out["snapshotBytes"] = (try? FileManager.default.attributesOfItem(atPath: directory + "/snapshot"))?[.size] as? Int ?? -1
        do {
            try record.delete()
            out["deleted"] = !FileManager.default.fileExists(atPath: directory)
        } catch {
            out["deleted"] = false
            out["deleteError"] = "\(error)"
        }
        return out
    }

    private static func keychainChecks(service: String) -> [String: Any] {
        var out: [String: Any] = [:]
        let probe = SessionKeychain(service: service)
        probe.deleteAll()
        let id = SessionID.random()
        do {
            let key = try Base64Key(bytes: (0..<16).map { _ in UInt8.random(in: 0...255) })
            try probe.store(key, for: id)
            let accessible = try probe.accessibility(for: id)
            out["probeItem"] = accessibleName(accessible)
            out["probeItemMatches"] = accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            out["probeKeyReadsBack"] = (try probe.key(for: id)) == key
        } catch {
            out["error"] = "\(error)"
        }
        try? probe.delete(id)
        out["probeItemRemoved"] = (try? probe.accessibility(for: id)) == nil
        // The app's own items: attributes only.
        out["appSessionKeys"] = accessibleNames(service: SessionKeychain.defaultService)
        out["appDeviceKeys"] = accessibleNames(service: KeychainKeyStore.defaultService)
        return out
    }

    // MARK: Locked pass

    /// What a locked pass says.
    enum LockedVerdict: String {
        /// The checks ran while the device was locked in the data-protection sense, before and
        /// after, and every check passed.
        case ok = "ok"
        /// The checks did not run while the device was locked (protected data available, or the
        /// control file of class "complete" readable, before or after them): the run proves
        /// nothing about saving while locked.
        case invalid = "not locked - invalid"
        /// The device was locked throughout and a check failed: a real finding.
        case failed = "locked - a check failed"
    }

    /// Locked in the sense that matters: iOS says protected data is unavailable and a file of
    /// class "complete" cannot be read. Either alone is not enough.
    static func isLocked(protectedDataAvailable: Bool?, controlReadable: Bool?) -> Bool {
        protectedDataAvailable == false && controlReadable == false
    }

    /// The verdict of a locked pass from its result. Anything that does not show the device
    /// locked before and after the checks is invalid, whatever the checks said.
    static func lockedVerdict(_ out: [String: Any]) -> LockedVerdict {
        guard isLocked(protectedDataAvailable: out["protectedDataAvailable"] as? Bool,
                       controlReadable: out["controlCompleteReadable"] as? Bool),
              isLocked(protectedDataAvailable: out["protectedDataAvailableAfter"] as? Bool,
                       controlReadable: out["controlCompleteReadableAfter"] as? Bool) else { return .invalid }
        let passed = out["saveError"] == nil && out["saveClean"] as? Bool == true
            && out["reopen"] as? String == "clean" && out["reopenSnapshotLoads"] as? Bool == true
            && out["createWhileLocked"] as? Bool == true && out["keychainReadable"] as? Bool == true
        return passed ? .ok : .failed
    }

    /// Why a pass ended without the device locked, with what was seen (seconds after the pass
    /// started; "never" for what did not happen).
    static func notLockedMessage(reason: String, observed: [String: Any]) -> String {
        func at(_ key: String) -> String {
            (observed[key] as? Int).map { "\($0) s" } ?? "never"
        }
        let available = (observed["lastProtectedDataAvailable"] as? Bool).map { "\($0)" } ?? "unknown"
        let readable = (observed["lastControlReadable"] as? Bool).map { "\($0)" } ?? "unknown"
        return "\(reason); not locked: last isProtectedDataAvailable \(available), last control file readable "
            + "\(readable); background at \(at("backgroundAt")), protectedDataWillBecomeUnavailable at "
            + "\(at("willBecomeUnavailableAt")), protected data first unavailable at \(at("firstUnavailableAt")), "
            + "control file first unreadable at \(at("firstControlUnreadableAt"))"
    }

    /// Prepares while unlocked, then (kept alive by a background task) polls until the device is
    /// locked in the data-protection sense, runs the locked checks and hands the result to
    /// `done`. Gives up after `limit` seconds in total, or when the background time is nearly
    /// over, with an invalid result that names what was observed.
    static func runLocked(root: String = DeviceProbe.root, limit: TimeInterval = 600,
                          done: @escaping @Sendable ([String: Any]) -> Void) {
        let lockedRoot = root + "-locked"
        try? FileManager.default.removeItem(atPath: lockedRoot)
        var prep: [String: Any] = [:]
        // Prepared while unlocked: an open record (saved once), a closed record saved clean to
        // reopen, a control file of class "complete", a Keychain item.
        let control = lockedRoot + "/control-complete"
        let open: SessionRecord
        let closedID: SessionID
        let keychain = SessionKeychain(service: keychainService)
        keychain.deleteAll()
        let keyID = SessionID.random()
        do {
            try FileManager.default.createDirectory(atPath: lockedRoot, withIntermediateDirectories: true)
            try Data("control".utf8).write(to: URL(fileURLWithPath: control), options: .completeFileProtection)
            open = try SessionRecord.create(root: lockedRoot, meta: meta(), key: nil)
            _ = try open.save(SessionExport(snapshot: sampleSnapshot(),
                                            cleanToken: CleanToken(datagramsPassed: open.gate.datagramsPassed)))
            // Saved clean before it is closed, so the reopen while locked must read "clean" and
            // load the snapshot. (A record that was only created reads "dirty": the counters of
            // a new record say so.)
            let closed = try SessionRecord.create(root: lockedRoot, meta: meta(), key: nil)
            closedID = closed.id
            guard try closed.save(SessionExport(snapshot: sampleSnapshot(),
                                                cleanToken: CleanToken(datagramsPassed: closed.gate.datagramsPassed)))
            else { throw ProbeError.notClean }
            closed.close()
            try keychain.store(try Base64Key(bytes: Array(repeating: 7, count: 16)), for: keyID)
        } catch {
            prep["error"] = "prepare: \(error)"
            try? FileManager.default.removeItem(atPath: lockedRoot)
            keychain.deleteAll()
            done(["prepared": prep, "verdict": LockedVerdict.invalid.rawValue, "ok": false])
            return
        }

        let state = LockedRun(open: open, closedID: closedID, keyID: keyID, keychain: keychain,
                              root: lockedRoot, control: control, done: done)
        state.start(limit: limit)
    }

    private enum ProbeError: Error { case notClean }

    /// One locked pass: owns the background task, the observers and the poll; finishes once.
    private final class LockedRun: @unchecked Sendable {
        /// Seconds between two looks at the lock state.
        static let pollInterval: TimeInterval = 0.5
        /// Background time left at which the pass gives up rather than be cut off.
        static let backgroundReserve: TimeInterval = 5

        let open: SessionRecord
        let closedID: SessionID
        let keyID: SessionID
        let keychain: SessionKeychain
        let root: String
        let control: String
        let done: @Sendable ([String: Any]) -> Void
        // Main queue only.
        private var task: UIBackgroundTaskIdentifier = .invalid
        private var observers: [NSObjectProtocol] = []
        private var timer: DispatchSourceTimer?
        private var finished = false
        private var checking = false
        private var observed: [String: Any] = [:]
        private let started = Date()

        init(open: SessionRecord, closedID: SessionID, keyID: SessionID, keychain: SessionKeychain, root: String,
             control: String, done: @escaping @Sendable ([String: Any]) -> Void) {
            self.open = open
            self.closedID = closedID
            self.keyID = keyID
            self.keychain = keychain
            self.root = root
            self.control = control
            self.done = done
        }

        private var elapsed: Int { Int(Date().timeIntervalSince(started)) }

        private func note(_ key: String) {
            if observed[key] == nil { observed[key] = elapsed }
        }

        func start(limit: TimeInterval) {
            DispatchQueue.main.async { [self] in
                // Begun while in the foreground; its time counts from the move to the background.
                // iOS documents no figure for it (read `backgroundTimeRemaining`).
                task = UIApplication.shared.beginBackgroundTask(withName: "smoke-locked") { [self] in
                    finishNow(invalid("background time expired"))
                }
                let center = NotificationCenter.default
                let events: [(Notification.Name, String)] = [
                    (UIApplication.willResignActiveNotification, "resignActiveAt"),
                    (UIApplication.didEnterBackgroundNotification, "backgroundAt"),
                    (UIApplication.protectedDataWillBecomeUnavailableNotification, "willBecomeUnavailableAt"),
                    (UIApplication.protectedDataDidBecomeAvailableNotification, "didBecomeAvailableAt"),
                    (UIApplication.willEnterForegroundNotification, "foregroundAt"),
                ]
                for (name, key) in events {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [self] _ in
                        note(key)
                    })
                }
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
                timer.setEventHandler { [self] in poll(limit: limit) }
                self.timer = timer
                timer.resume()
            }
        }

        /// Main queue. Starts the checks once the device is locked; gives up at the limits.
        private func poll(limit: TimeInterval) {
            guard !finished, !checking else { return }
            let available = UIApplication.shared.isProtectedDataAvailable
            let readable = FileManager.default.contents(atPath: control) != nil
            observed["lastProtectedDataAvailable"] = available
            observed["lastControlReadable"] = readable
            if !available { note("firstUnavailableAt") }
            if !readable { note("firstControlUnreadableAt") }
            if DeviceProbe.isLocked(protectedDataAvailable: available, controlReadable: readable) {
                checking = true
                observed["lockedAt"] = elapsed
                DispatchQueue.global().async { [self] in
                    let out = checks()
                    DispatchQueue.main.async { [self] in finishNow(out) }
                }
                return
            }
            let application = UIApplication.shared
            if application.applicationState == .background,
               application.backgroundTimeRemaining < Self.backgroundReserve {
                finishNow(invalid("background time nearly over (\(Int(application.backgroundTimeRemaining)) s left)"))
            } else if Date().timeIntervalSince(started) > limit {
                finishNow(invalid("no lock within \(Int(limit)) s"))
            }
        }

        private func invalid(_ reason: String) -> [String: Any] {
            observed["secondsAfterStart"] = elapsed
            return ["error": DeviceProbe.notLockedMessage(reason: reason, observed: observed), "observed": observed]
        }

        /// Background queue.
        private func checks() -> [String: Any] {
            var out: [String: Any] = [:]
            out["secondsAfterLaunch"] = Int(Date().timeIntervalSince(started))
            out["protectedDataAvailable"] = DeviceProbe.protectedDataAvailable()
            out["controlCompleteReadable"] = FileManager.default.contents(atPath: control) != nil
            do {
                let start = Date()
                let clean = try open.save(SessionExport(snapshot: DeviceProbe.sampleSnapshot(),
                                                        cleanToken: CleanToken(datagramsPassed: open.gate.datagramsPassed)))
                out["saveMs"] = DeviceProbe.milliseconds(since: start)
                out["saveClean"] = clean
                let sendStart = Date()
                try open.gate.willSendDatagram()
                out["firstDatagramAfterSaveMs"] = DeviceProbe.milliseconds(since: sendStart)
            } catch {
                out["saveError"] = "\(error)"
            }
            do {
                let reopened = try SessionRecord.open(root: root, id: closedID)
                out["reopen"] = DeviceProbe.stateName(reopened.state)
                do {
                    _ = try reopened.loadSnapshot()
                    out["reopenSnapshotLoads"] = true
                } catch {
                    out["reopenSnapshotLoads"] = false
                    out["reopenSnapshotError"] = "\(error)"
                }
                reopened.close()
            } catch {
                out["reopenError"] = "\(error)"
            }
            do {
                let fresh = try SessionRecord.create(root: root, meta: DeviceProbe.meta(), key: nil)
                out["createWhileLocked"] = true
                try? fresh.delete()
            } catch {
                out["createWhileLocked"] = false
                out["createError"] = "\(error)"
            }
            do {
                out["keychainReadable"] = try keychain.key(for: keyID) != nil
            } catch {
                out["keychainReadable"] = false
                out["keychainError"] = "\(error)"
            }
            out["lstatMissing"] = DeviceProbe.lstatErrno(root + "/no-such-file")
            // Still locked after the checks, or the checks may have run unlocked.
            out["protectedDataAvailableAfter"] = DeviceProbe.protectedDataAvailable()
            out["controlCompleteReadableAfter"] = FileManager.default.contents(atPath: control) != nil
            return out
        }

        /// Main queue: synchronous, so that the expiration handler ends the task before it returns.
        private func finishNow(_ result: [String: Any]) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            var result = result
            var observedNow = observed
            observedNow["secondsAfterStart"] = elapsed
            if UIApplication.shared.applicationState == .background {
                observedNow["backgroundTimeRemaining"] = Int(UIApplication.shared.backgroundTimeRemaining)
            }
            result["observed"] = observedNow
            let verdict = DeviceProbe.lockedVerdict(result)
            result["verdict"] = verdict.rawValue
            result["ok"] = verdict == .ok
            open.close()
            keychain.deleteAll()
            // Removal waits for the next unlock if the device is locked; the next run
            // removes leftovers first.
            try? FileManager.default.removeItem(atPath: root)
            done(result)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
    }

    // MARK: Pieces

    static func meta() -> SessionMeta {
        SessionMeta(id: SessionID.random(), createdAt: UInt64(Date().timeIntervalSince1970), hostName: "smoke-probe",
                    address: "127.0.0.1", port: 9, user: "", remoteCommand: "",
                    serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 0, serverStartTime: 0)
    }

    /// A snapshot of the size a real one has: an 80x24 screen full of text. Its counters are a
    /// real session's after state 1 was sent and acknowledged (A = 1): the first unused datagram
    /// sequence number, state number and fragment id are each above what a session starts with
    /// (`GateCounters.sessionStart`), and the state counter is above A, which the codec checks
    /// on load (build 182 refused a sample with state 1 on the phone).
    static func sampleSnapshot() -> SessionSnapshot {
        var terminal = TerminalState(width: 80, height: 24)
        let line = String(repeating: "0123456789", count: 8)
        _ = terminal.act(Array((0..<30).map { "\($0) \(line)\r\n" }.joined().utf8))
        let transport = TransportSnapshot<TerminalRemoteState>(
            acknowledgedStateNumber: 1, pendingInput: [],
            remoteStates: [NumberedRemoteState(number: 1, state: TerminalRemoteState(terminal: terminal))],
            highestAckSent: 1, terminalSize: TerminalSize(width: 80, height: 24),
            usedCounters: GateCounters(sequence: 2, state: 2, fragmentID: 2), receiverExpectedSequence: 1)
        return SessionSnapshot(transport: transport, clipboard: ClipboardPolicy())
    }

    static func protectionClasses(directory: String) -> [String: String] {
        var out: [String: String] = [:]
        for (name, path) in [("directory", directory), ("meta", directory + "/meta"), ("counters", directory + "/counters"),
                             ("lock", directory + "/lock"), ("snapshot", directory + "/snapshot")] {
            let value = (try? FileManager.default.attributesOfItem(atPath: path))?[.protectionKey] as? FileProtectionType
            out[name] = protectionName(value)
        }
        return out
    }

    static func protectionName(_ type: FileProtectionType?) -> String {
        guard let type else { return "none" }
        switch type {
        case .complete: return "complete"
        case .completeUnlessOpen: return "completeUnlessOpen"
        case .completeUntilFirstUserAuthentication: return "completeUntilFirstUserAuthentication"
        case .none: return "noProtection"
        default: return type.rawValue
        }
    }

    static func accessibleName(_ value: String?) -> String {
        guard let value else { return "missing" }
        let names: [(CFString, String)] = [
            (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, "AfterFirstUnlockThisDeviceOnly"),
            (kSecAttrAccessibleAfterFirstUnlock, "AfterFirstUnlock"),
            (kSecAttrAccessibleWhenUnlockedThisDeviceOnly, "WhenUnlockedThisDeviceOnly"),
            (kSecAttrAccessibleWhenUnlocked, "WhenUnlocked"),
            (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, "WhenPasscodeSetThisDeviceOnly"),
        ]
        return names.first { ($0.0 as String) == value }?.1 ?? value
    }

    /// Count of items per accessibility class in a service; attributes only.
    static func accessibleNames(service: String) -> [String: Int] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return status == errSecItemNotFound ? [:] : ["OSStatus \(status)": 0] }
        var counts: [String: Int] = [:]
        for item in result as? [[String: Any]] ?? [] {
            counts[accessibleName(item[kSecAttrAccessible as String] as? String), default: 0] += 1
        }
        return counts
    }

    static func excludedFromBackup(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    static func lstatErrno(_ path: String) -> [String: Any] {
        var info = stat()
        let status = lstat(path, &info)
        let code = status == 0 ? 0 : errno
        return ["result": Int(status), "errno": Int(code), "isENOENT": code == ENOENT]
    }

    static func protectedDataAvailable() -> Bool {
        if Thread.isMainThread { return UIApplication.shared.isProtectedDataAvailable }
        return DispatchQueue.main.sync { UIApplication.shared.isProtectedDataAvailable }
    }

    static func milliseconds(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1_000_000).rounded() / 1000
    }

    /// Minimum, median, 90th percentile and maximum in ms (nearest rank), and the count.
    static func summary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        return ["n": sorted.count, "min": sorted[0], "median": rank(0.5), "p90": rank(0.9), "max": sorted[sorted.count - 1]]
    }

    /// The unlocked pass is fine when every class, the exclusion and the Keychain class are the
    /// plan's and every save ended clean.
    static func isOK(_ result: [String: Any]) -> Bool {
        guard let record = result["record"] as? [String: Any], record["error"] == nil,
              let keychain = result["keychain"] as? [String: Any], keychain["error"] == nil,
              let classes = record["protection"] as? [String: String] else { return false }
        let wanted = protectionName(.completeUntilFirstUserAuthentication)
        return classes.values.allSatisfy { $0 == wanted }
            && record["excludedFromBackup"] as? Bool == true && record["verify"] as? Bool == true
            && record["cleanSaves"] as? Int == record["saves"] as? Int && record["deleted"] as? Bool == true
            && keychain["probeItemMatches"] as? Bool == true && keychain["probeItemRemoved"] as? Bool == true
    }
}
#endif
