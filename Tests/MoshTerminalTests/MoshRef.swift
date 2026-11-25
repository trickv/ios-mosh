// Runs the same operations through mosh's own terminal (Support/moshref.cc, built from
// the mosh 1.4.0 tree in the dev container) and through the Swift port, and returns both
// outputs for comparison. Linux only: it starts processes.

#if os(Linux)
import Foundation
import XCTest
import MoshTerminal

enum MoshRef {
    static let moshSource = ProcessInfo.processInfo.environment["MOSH_SRC"] ?? "/opt/mosh-src"

    static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    private static func run(_ executable: String, _ arguments: [String], stdin: URL? = nil, stdout: URL? = nil)
        throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshref-stderr-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0...UInt64.max))")
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

    private struct BuildFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// Path of the built reference tool, or why there is none: an `XCTSkip` when there
    /// is no mosh tree (not the dev container), a failure when the tool does not build.
    private static let tool: Result<String, Error> = {
        let lib = moshSource + "/src/terminal/libmoshterminal.a"
        guard FileManager.default.fileExists(atPath: lib) else {
            return .failure(XCTSkip("no built mosh tree at \(moshSource) (this test runs in the dev container)"))
        }
        let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support")
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshref-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            let r = try run("/bin/bash", [support.appendingPathComponent("build-moshref.sh").path, outDir.path])
            guard r.status == 0 else {
                return .failure(BuildFailure(description: "build-moshref.sh failed:\n\(r.stderr)"))
            }
        } catch {
            return .failure(BuildFailure(description: "cannot run build-moshref.sh: \(error)"))
        }
        return .success(outDir.appendingPathComponent("moshref").path)
    }()

    /// Run a script through mosh's terminal. One element per `dump`, `cmp` and `reply`.
    static func reference(_ ops: [RefOp]) throws -> [[UInt8]] {
        let path = try tool.get()
        var script = ""
        for op in ops {
            switch op {
            case .new(let w, let h): script += "new \(w) \(h)\n"
            case .bytes(let b): script += "bytes \(hexString(b))\n"
            case .resize(let w, let h): script += "resize \(w) \(h)\n"
            case .echoAck(let n): script += "echoack \(n)\n"
            case .userBytes(let b): script += "userbytes \(hexString(b))\n"
            case .save: script += "save\n"
            case .drop: script += "drop\n"
            case .dump: script += "dump\n"
            case .cmp: script += "cmp\n"
            case .reply: script += "reply\n"
            case .diff(let i, let d):
                script += "diff \(i ? 1 : 0) \(d.hasECH ? 1 : 0) \(d.hasBCE ? 1 : 0) \(d.hasTitle ? 1 : 0)\n"
            case .applyDiff(let i): script += "applydiff \(i ? 1 : 0)\n"
            }
        }
        let tmp = FileManager.default.temporaryDirectory
        let tag = "\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0...UInt64.max))"
        let inURL = tmp.appendingPathComponent("moshref-in-\(tag)")
        let outURL = tmp.appendingPathComponent("moshref-out-\(tag)")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try Data(script.utf8).write(to: inURL)
        let r = try run(path, [], stdin: inURL, stdout: outURL)
        guard r.status == 0 else {
            throw NSError(domain: "moshref", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: "moshref exited with \(r.status): \(r.stderr)"])
        }
        return splitBlocks(Array(try Data(contentsOf: outURL)))
    }

    /// Run the same script through the Swift port, in the same output format.
    static func port(_ ops: [RefOp]) -> [[UInt8]] {
        var cur = TerminalState(width: 80, height: 24)
        var saved: TerminalState? = nil
        var reply: [UInt8] = []
        var blocks: [[UInt8]] = []
        for op in ops {
            switch op {
            case .new(let w, let h):
                saved = nil
                cur = TerminalState(width: w, height: h)
                reply = []
            case .bytes(let b): reply += cur.act(b)
            case .resize(let w, let h): reply += cur.resize(width: w, height: h)
            case .echoAck(let n): cur.applyEchoAck(n)
            case .userBytes(let b): for c in b { reply += cur.actUserByte(c) }
            case .save: saved = cur
            case .drop: saved = nil
            case .dump: blocks.append(Array(cur.debugDump().utf8))
            case .cmp:
                if let s = saved {
                    var line = "cmp mosh_eq=\(cur.moshEquals(s) ? 1 : 0) same_rows=["
                    let a = cur.framebuffer.rows
                    let b = s.framebuffer.rows
                    for y in 0..<min(a.count, b.count) { line += a[y] === b[y] ? "1" : "0" }
                    line += "]\n"
                    blocks.append(Array(line.utf8))
                } else {
                    blocks.append(Array("cmp no saved state\n".utf8))
                }
            case .reply:
                blocks.append(Array("reply [\(hexString(reply))]\n".utf8))
                reply = []
            case .diff(let initialized, let display):
                guard let s = saved else { preconditionFailure("diff without a saved state") }
                let update = display.newFrame(initialized: initialized, from: s.framebuffer, to: cur.framebuffer)
                blocks.append(Array("diff [\(hexString(update))]\n".utf8))
            case .applyDiff(let initialized):
                guard let s = saved else { preconditionFailure("applydiff without a saved state") }
                let update = DisplayDiff.newFrame(initialized: initialized, from: s.framebuffer, to: cur.framebuffer)
                var next = s
                let (w, h) = (cur.framebuffer.ds.width, cur.framebuffer.ds.height)
                if w != s.framebuffer.ds.width || h != s.framebuffer.ds.height {
                    reply += next.resize(width: w, height: h)
                }
                reply += next.act(update)
                cur = next
            }
        }
        return blocks
    }

    private static func splitBlocks(_ output: [UInt8]) -> [[UInt8]] {
        let marker = Array("=== end\n".utf8)
        var blocks: [[UInt8]] = []
        var current: [UInt8] = []
        var lineStart = 0
        var i = 0
        while i < output.count {
            if output[i] == 0x0A {
                let line = output[lineStart...i]
                if line.elementsEqual(marker) {
                    blocks.append(current)
                    current = []
                } else {
                    current.append(contentsOf: line)
                }
                lineStart = i + 1
            }
            i += 1
        }
        return blocks
    }

    /// The first line where two dumps differ, for a failure message.
    static func firstDifference(_ expected: [UInt8], _ actual: [UInt8]) -> String {
        let e = expected.split(separator: 0x0A, omittingEmptySubsequences: false)
        let a = actual.split(separator: 0x0A, omittingEmptySubsequences: false)
        for i in 0..<max(e.count, a.count) {
            let el = i < e.count ? Array(e[i]) : nil
            let al = i < a.count ? Array(a[i]) : nil
            if el != al {
                let es = el.map { String(decoding: $0, as: UTF8.self) } ?? "<missing>"
                let aS = al.map { String(decoding: $0, as: UTF8.self) } ?? "<missing>"
                return "line \(i + 1):\n  mosh: \(es)\n  port: \(aS)"
            }
        }
        return "no difference"
    }
}
#endif
