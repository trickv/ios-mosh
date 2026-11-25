#if DEBUG
import Foundation
import MoshKeys
import Network

/// Phone self-test, M0 version: prove that the phone reaches the smoke container on
/// yellow over TCP and UDP, that environment variables arrive through devicectl,
/// and that the result file can be copied off the phone.
///
/// Started by scripts/deploy.sh --smoke with SMOKE_RUN_ID, SMOKE_HOST, SMOKE_PORT
/// (the container's sshd) and SMOKE_UDP_PORT (a UDP echo). Writes
/// Documents/smoke.json. It reads and writes no stored host, key or session.
///
/// It also runs `DeviceProbe` (record file protection, backup exclusion, Keychain class, cost
/// of a save), whose throwaway record and Keychain item are its own, under "device". With
/// SMOKE_LOCKED_SAVE=1 the locked pass follows and smoke.json is written again with "locked".
/// With SMOKE_WRITE_KILL=1 the app writes `WriteKillProbe`'s records after smoke.json and kills
/// itself; the next probe launch publishes them as "writeKill". "devicePublicKey" is the device
/// key's public line when there is a device key.
enum SmokeProbe {
    static let fileName = "smoke.json"

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let runID = env["SMOKE_RUN_ID"], !runID.isEmpty else { return }
        let host = env["SMOKE_HOST"] ?? ""
        let tcpPort = UInt16(env["SMOKE_PORT"] ?? "") ?? 0
        let udpPort = UInt16(env["SMOKE_UDP_PORT"] ?? "") ?? 0
        DebugLog.shared.log("smoke \(runID): start host=\(host) tcp=\(tcpPort) udp=\(udpPort)")

        Task.detached {
            var result: [String: Any] = [
                "runId": runID,
                "stage": "m0-network",
                "build": BuildInfo.summary,
                "host": host,
            ]
            let device = DeviceProbe.run()
            result["device"] = device
            let bootDigest = (device["bootIdentifier"] as? [String: Any])?["digest"] as? String
            // Records an earlier SMOKE_WRITE_KILL launch left (StageTwoProbe.swift).
            if let readBack = WriteKillProbe.readBackIfPresent(bootDigestNow: bootDigest) {
                result["writeKill"] = readBack
            }
            // Public, for the sitting's throwaway smoke host (docs/MAC.md); read only, never made here.
            if let line = (try? KeychainKeyStore().key(named: DeviceKey.name))?.authorizedKeysLine {
                result["devicePublicKey"] = line
            }
            let writeKill = env["SMOKE_WRITE_KILL"] == "1"
            let locked = env["SMOKE_LOCKED_SAVE"] == "1"
            if locked {
                // Prepared now, before the owner locks the phone; the result is merged into the
                // smoke.json on disk when the pass ends.
                result["locked"] = ["pending": true]
                DebugLog.shared.log("smoke \(runID): locked pass waits for the device to lock")
                DeviceProbe.runLocked { lockedResult in
                    var again = read() ?? ["runId": runID]
                    again["locked"] = lockedResult
                    again["lockedFinished"] = ISO8601DateFormatter().string(from: Date())
                    write(again)
                    DebugLog.shared.log("smoke \(runID): locked pass done verdict=\(lockedResult["verdict"] ?? "?")")
                    DebugLog.shared.flush()
                }
            }
            write(result)
            let tcp = await tcpBanner(host: host, port: tcpPort)
            result["tcp"] = tcp
            let udp = await udpEcho(host: host, port: udpPort, payload: "ping \(runID)")
            result["udp"] = udp
            result["ok"] = (tcp["ok"] as? Bool == true) && (udp["ok"] as? Bool == true)
                && (device["ok"] as? Bool == true)
            result["finished"] = ISO8601DateFormatter().string(from: Date())
            // A locked pass that already ended (slow network) keeps its result.
            if let onDisk = read(), let done = onDisk["locked"] as? [String: Any], done["pending"] == nil {
                result["locked"] = done
                result["lockedFinished"] = onDisk["lockedFinished"]
            }
            write(result)
            DebugLog.shared.log("smoke \(runID): done ok=\(result["ok"] ?? false) device=\(device["ok"] ?? false)")
            if writeKill {
                let written = WriteKillProbe.write(runID: runID, bootDigest: bootDigest ?? "unknown")
                result["writeKillWritten"] = written
                write(result)
                DebugLog.shared.log("smoke \(runID): wrote \(written) write-kill records, SIGKILL now")
                DebugLog.shared.flush()
                kill(getpid(), SIGKILL)
            }
            DebugLog.shared.flush()
        }
    }

    private static var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
    }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: resultURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ result: [String: Any]) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(fileName)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Connects and reads the first bytes (sshd sends its version line at once).
    private static func tcpBanner(host: String, port: UInt16) async -> [String: Any] {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            return ["ok": false, "error": "no host or port"]
        }
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let outcome: Outcome = await withOutcome(timeout: 15, connection: connection) { finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, error in
                        if let data, !data.isEmpty {
                            finish(.success(String(decoding: data, as: UTF8.self)))
                        } else {
                            finish(.failure("receive: \(error.map { "\($0)" } ?? "no data")"))
                        }
                    }
                case .failed(let error): finish(.failure("failed: \(error)"))
                case .waiting(let error): DebugLog.shared.log("smoke tcp waiting: \(error)")
                default: break
                }
            }
        }
        return report(outcome, since: start, key: "banner")
    }

    private static func udpEcho(host: String, port: UInt16, payload: String) async -> [String: Any] {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            return ["ok": false, "error": "no host or port"]
        }
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let outcome: Outcome = await withOutcome(timeout: 10, connection: connection) { finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receiveMessage { data, _, _, error in
                        if let data, !data.isEmpty {
                            finish(.success(String(decoding: data, as: UTF8.self)))
                        } else {
                            finish(.failure("receive: \(error.map { "\($0)" } ?? "no data")"))
                        }
                    }
                    // UDP can drop: send the datagram a few times.
                    for delay in [0.0, 1.0, 2.5, 5.0] {
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
                        }
                    }
                case .failed(let error): finish(.failure("failed: \(error)"))
                case .waiting(let error): DebugLog.shared.log("smoke udp waiting: \(error)")
                default: break
                }
            }
        }
        var result = report(outcome, since: start, key: "reply")
        if case .success(let reply) = outcome, reply != payload {
            result["ok"] = false
            result["error"] = "reply differs from payload"
        }
        return result
    }

    private enum Outcome {
        case success(String)
        case failure(String)
    }

    private static func report(_ outcome: Outcome, since start: Date, key: String) -> [String: Any] {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        switch outcome {
        case .success(let text):
            return ["ok": true, "ms": ms, key: text.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .failure(let error):
            return ["ok": false, "ms": ms, "error": error]
        }
    }

    /// Runs `body`, which must call `finish` once; a timeout finishes it otherwise.
    private static func withOutcome(
        timeout: TimeInterval,
        connection: NWConnection,
        _ body: @escaping (@escaping (Outcome) -> Void) -> Void
    ) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let lock = NSLock()
            var done = false
            let finish: (Outcome) -> Void = { outcome in
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            body(finish)
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure("timeout after \(Int(timeout)) s"))
            }
        }
    }
}
#endif
