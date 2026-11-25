#if DEBUG
import Foundation
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport

/// Phone figures for resume stage 2 (docs/notes/stage2/DESIGN.md section 15, "not settled from
/// the sources") that today's build can take without the journal, which does not exist yet:
///
/// - the time of a small `write()` on the device's file system with data protection: 1,000
///   appends of 64 bytes to one file (a journal record is 31 to 95 bytes, section 9), and the
///   protection class that file got;
/// - a 15 KB checkpoint written and renamed without a sync (a compaction, section 7) and with
///   the full syncs of a seal (`F_FULLFSYNC` of the file, rename, `F_FULLFSYNC` of the directory);
/// - the snapshot codec and the applier in this (debug) build: encode and decode of the probe's
///   80x24 snapshot, `TerminalState.act` of 3,000 bytes. The phone runs debug builds only, so
///   these are the debug figures section 9 lacks for the device, not release ones.
///
/// Everything is written in a directory of its own under the probe's root and removed with it.
/// Debug builds only; run by `DeviceProbe.run`.
enum StageTwoProbe {
    static let appends = 1_000
    static let appendBytes = 64
    static let checkpointBytes = 15 * 1024
    static let checkpointRuns = 10
    static let codecRuns = 20

    static func timings(directory: String) -> [String: Any] {
        let fm = FileManager.default
        try? fm.removeItem(atPath: directory)
        defer { try? fm.removeItem(atPath: directory) }
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch {
            return ["error": "directory: \(error)"]
        }
        var out: [String: Any] = [:]
        out["append"] = appendTiming(path: directory + "/journal-probe")
        out["checkpoint"] = checkpointTiming(directory: directory)
        out["codec"] = codecTiming()
        return out
    }

    /// 1,000 `write()` calls of 64 bytes to a file opened with `O_APPEND`, no sync.
    static func appendTiming(path: String) -> [String: Any] {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard fd >= 0 else { return ["error": "open: errno \(errno)"] }
        var times: [Double] = []
        var failed = 0
        let record = [UInt8](repeating: 0x61, count: appendBytes)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<appends {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let written = record.withUnsafeBytes { write(fd, $0.baseAddress, appendBytes) }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            if written != appendBytes { failed += 1 }
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        close(fd)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? -1
        let protection = (try? FileManager.default.attributesOfItem(atPath: path))?[.protectionKey] as? FileProtectionType
        return ["n": appends, "bytes": appendBytes, "failed": failed, "fileBytes": size, "totalMs": totalMs,
                "eachMs": DeviceProbe.summary(times), "protection": DeviceProbe.protectionName(protection)]
    }

    /// A 15 KB file written to a temporary name and renamed over `checkpoint`, ten times without
    /// a sync and ten times with the syncs of a seal.
    static func checkpointTiming(directory: String) -> [String: Any] {
        let bytes = [UInt8](repeating: 0x63, count: checkpointBytes)
        var plain: [Double] = []
        var sealed: [Double] = []
        var errors: [String] = []
        for synced in [false, true] {
            for _ in 0..<checkpointRuns {
                let t0 = DispatchTime.now().uptimeNanoseconds
                if let error = writeCheckpoint(bytes, directory: directory, synced: synced) {
                    errors.append(error)
                    continue
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if synced { sealed.append(ms) } else { plain.append(ms) }
            }
        }
        var out: [String: Any] = ["bytes": checkpointBytes, "writeRenameMs": DeviceProbe.summary(plain),
                                  "writeFullSyncRenameDirSyncMs": DeviceProbe.summary(sealed)]
        if let first = errors.first { out["error"] = first; out["errors"] = errors.count }
        return out
    }

    private static func writeCheckpoint(_ bytes: [UInt8], directory: String, synced: Bool) -> String? {
        let temporary = directory + "/checkpoint.tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return "open: errno \(errno)" }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        if written != bytes.count { close(fd); return "write: errno \(errno)" }
        if synced, fcntl(fd, F_FULLFSYNC) != 0 { let code = errno; close(fd); return "F_FULLFSYNC: errno \(code)" }
        close(fd)
        guard rename(temporary, directory + "/checkpoint") == 0 else { return "rename: errno \(errno)" }
        if synced {
            let dir = open(directory, O_RDONLY)
            guard dir >= 0 else { return "open directory: errno \(errno)" }
            defer { close(dir) }
            if fcntl(dir, F_FULLFSYNC) != 0 { return "F_FULLFSYNC directory: errno \(errno)" }
        }
        return nil
    }

    /// Encode and decode of the probe's snapshot, and the applier over 3,000 bytes of text.
    static func codecTiming() -> [String: Any] {
        let sessionID = SessionID.random()
        // The probe's sample: its used counters are above its acknowledged state, as a session's
        // export always has them (the codec refuses anything else).
        let stored = StoredSnapshot(id: 1, snapshot: DeviceProbe.sampleSnapshot())
        var encodeMs: [Double] = []
        var decodeMs: [Double] = []
        var actMs: [Double] = []
        var encoded: [UInt8] = []
        var decodeError: String?
        let line = String(repeating: "abcdefghij", count: 7) + "\r\n"
        let text = Array(String(repeating: line, count: 42).utf8.prefix(3_000))
        for _ in 0..<codecRuns {
            var t0 = DispatchTime.now().uptimeNanoseconds
            encoded = SnapshotCodec.encode(stored, sessionID: sessionID)
            encodeMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            t0 = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try SnapshotCodec.decode(encoded, expecting: sessionID)
            } catch {
                decodeError = "\(error)"
            }
            decodeMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            var terminal = TerminalState(width: 80, height: 24)
            t0 = DispatchTime.now().uptimeNanoseconds
            _ = terminal.act(text)
            actMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        var out: [String: Any] = ["build": "debug", "snapshotBytes": encoded.count, "encodeMs": DeviceProbe.summary(encodeMs),
                                  "decodeMs": DeviceProbe.summary(decodeMs), "actBytes": text.count,
                                  "actMs": DeviceProbe.summary(actMs)]
        if let decodeError { out["decodeError"] = decodeError }
        return out
    }
}

/// "Write, kill, read back" (DESIGN.md section 15, the premise of stage 2: that a `write()` that
/// returned survives the death of the process on iOS). A launch with `SMOKE_WRITE_KILL=1` writes
/// 100 records of 64 bytes with plain `write()` calls and no sync, then sends itself SIGKILL. The
/// next probe launch reads them back, publishes what it found and removes the file.
///
/// A record is 60 bytes of text, "wk1 <run id, 12> <index, 4 digits> <boot digest, 16 hex>"
/// padded with ".", then the FNV-1a 32-bit hash of those 60 bytes, little-endian.
enum WriteKillProbe {
    static let count = 100
    static let recordBytes = 64

    static var directory: String {
        AppFiles.supportDirectory.appendingPathComponent("smoke-writekill", isDirectory: true).path
    }

    static func record(index: Int, runID: String, bootDigest: String) -> [UInt8] {
        let run = String((runID + String(repeating: "-", count: 12)).prefix(12))
        let digest = String((bootDigest + String(repeating: "0", count: 16)).prefix(16))
        var text = Array("wk1 \(run) \(String(format: "%04d", index)) \(digest) ".utf8)
        text += [UInt8](repeating: UInt8(ascii: "."), count: max(0, 60 - text.count))
        text = Array(text.prefix(60))
        let hash = fnv32(text)
        return text + [UInt8(hash & 0xff), UInt8((hash >> 8) & 0xff), UInt8((hash >> 16) & 0xff), UInt8(hash >> 24)]
    }

    static func fnv32(_ bytes: [UInt8]) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// Writes the records, one `write()` each, no sync. Returns how many calls wrote all 64 bytes.
    static func write(directory: String = WriteKillProbe.directory, runID: String, bootDigest: String) -> Int {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(directory + "/records", O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var done = 0
        for index in 0..<count {
            let bytes = record(index: index, runID: runID, bootDigest: bootDigest)
            if bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, bytes.count) }) == bytes.count { done += 1 }
        }
        return done
    }

    /// What a file of records says: how many whole records, how many of them intact (hash, prefix,
    /// one run id, indices 0, 1, 2, ... in order), the bytes of a torn tail, and the boot digest
    /// the first record names compared with `bootDigestNow`.
    static func verify(_ data: [UInt8], bootDigestNow: String?) -> [String: Any] {
        let whole = data.count / recordBytes
        var intact = 0
        var runID: String?
        var written: String?
        for index in 0..<whole {
            let bytes = Array(data[(index * recordBytes)..<((index + 1) * recordBytes)])
            let text = Array(bytes.prefix(60))
            let stored = UInt32(bytes[60]) | UInt32(bytes[61]) << 8 | UInt32(bytes[62]) << 16 | UInt32(bytes[63]) << 24
            guard stored == fnv32(text), let line = String(bytes: text, encoding: .ascii) else { continue }
            let fields = line.split(separator: " ")
            guard fields.count >= 4, fields[0] == "wk1", fields[2] == String(format: "%04d", index) else { continue }
            if runID == nil { runID = String(fields[1]); written = String(fields[3]) }
            guard String(fields[1]) == runID else { continue }
            intact += 1
        }
        var out: [String: Any] = ["expected": count, "records": whole, "intact": intact,
                                  "tornBytes": data.count - whole * recordBytes]
        if let runID { out["runId"] = runID }
        if let written { out["bootDigestWritten"] = written }
        if let bootDigestNow { out["bootDigestNow"] = bootDigestNow }
        let sameBoot = written != nil && written == bootDigestNow
        out["sameBoot"] = sameBoot
        let ok = whole == count && intact == count && data.count == count * recordBytes
        out["ok"] = ok
        out["verdict"] = ok ? "ok: \(intact) of \(count) records read back" + (sameBoot ? ", same boot" : ", boot not known to be the same")
            : "lost or damaged: \(intact) of \(count) intact, \(whole) whole records, \(data.count - whole * recordBytes) torn bytes"
        return out
    }

    /// The records of an earlier `SMOKE_WRITE_KILL` launch, verified, and the file removed; nil
    /// when there is none.
    static func readBackIfPresent(directory: String = WriteKillProbe.directory, bootDigestNow: String?) -> [String: Any]? {
        let path = directory + "/records"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        return verify(Array(data), bootDigestNow: bootDigestNow)
    }
}
#endif
