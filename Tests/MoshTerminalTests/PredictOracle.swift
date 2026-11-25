// Runs a command script through `mosh-oracle predict`: mosh 1.4.0's own prediction engine
// (frontend/terminaloverlay.o of the dev container's mosh tree), for the M10 differential
// tests (docs/notes/m10/DESIGN.md 7.1, Tools/mosh-oracle/FORMAT.md section 11). Linux only:
// it builds and starts processes.

#if os(Linux)
import Foundation
import XCTest

enum PredictOracle {
    static let moshSource = ProcessInfo.processInfo.environment["MOSH_SRC"] ?? "/opt/mosh-src"

    private struct BuildFailure: Error, CustomStringConvertible {
        var description: String
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                            stdin: URL? = nil, stdout: URL? = nil) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment = environment { p.environment = environment }
        p.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("predict-oracle-stderr-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0...UInt64.max))")
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        p.standardError = try FileHandle(forWritingTo: errURL)
        if let stdout = stdout {
            _ = FileManager.default.createFile(atPath: stdout.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        try p.run()
        p.waitUntilExit()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (p.terminationStatus, err)
    }

    /// Path of the oracle built once per process into a temporary directory (`ORACLE_OUT`),
    /// or why there is none: an `XCTSkip` without the built mosh tree (not the dev
    /// container), a failure when the build fails.
    private static let tool: Result<String, Error> = {
        let needed = ["src/frontend/terminaloverlay.o", "src/terminal/libmoshterminal.a",
                      "src/statesync/libmoshstatesync.a", "src/protobufs/libmoshprotos.a", "src/util/libmoshutil.a"]
        for path in needed where !FileManager.default.fileExists(atPath: moshSource + "/" + path) {
            return .failure(XCTSkip("no built mosh tree at \(moshSource) (\(path) missing; this test runs in the dev container)"))
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = repo.appendingPathComponent("Tools/mosh-oracle/build.sh")
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("predict-oracle-\(ProcessInfo.processInfo.processIdentifier)")
        var env = ProcessInfo.processInfo.environment
        env["ORACLE_OUT"] = outDir.path
        env["MOSH_SRC"] = moshSource
        do {
            let r = try run("/bin/bash", [build.path], environment: env)
            guard r.status == 0 else {
                return .failure(BuildFailure(description: "Tools/mosh-oracle/build.sh failed:\n\(r.stderr)"))
            }
        } catch {
            return .failure(BuildFailure(description: "cannot run Tools/mosh-oracle/build.sh: \(error)"))
        }
        return .success(outDir.appendingPathComponent("mosh-oracle").path)
    }()

    /// Lowercase hex of bytes, the `HEX` of the command grammar.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Run one script (one command per element) and return the reply lines, one per
    /// command. A nonzero exit (65: a bad command) throws with the last reply.
    static func run(_ commands: [String]) throws -> [String] {
        let path = try tool.get()
        let tmp = FileManager.default.temporaryDirectory
        let tag = "\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0...UInt64.max))"
        let inURL = tmp.appendingPathComponent("predict-oracle-in-\(tag)")
        let outURL = tmp.appendingPathComponent("predict-oracle-out-\(tag)")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try Data(commands.map { $0 + "\n" }.joined().utf8).write(to: inURL)
        let r = try run(path, ["predict"], stdin: inURL, stdout: outURL)
        let text = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard r.status == 0 else {
            throw NSError(domain: "mosh-oracle", code: Int(r.status), userInfo: [
                NSLocalizedDescriptionKey: "mosh-oracle predict exited with \(r.status): \(lines.last ?? "") \(r.stderr)"])
        }
        guard lines.count == commands.count else {
            throw NSError(domain: "mosh-oracle", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "mosh-oracle predict replied \(lines.count) lines to \(commands.count) commands"])
        }
        return lines
    }
}
#endif
