// moshcli: test executable, see docs/PLAN.md "Test tools".
// Each subcommand lives in its own file and is listed here.
import Foundation

typealias Subcommand = (_ arguments: [String]) async throws -> Int32

let subcommands: [(name: String, summary: String, run: Subcommand)] = [
    ("handshake", "send the first client instruction to a mosh-server and print its first answer", handshakeCommand),
    ("connect", "run a script (type, expect, rebind, quiesce, resume-mem, ...) against a mosh-server", connectCommand),
    ("resume", "continue a session from its record (cold start) and run a script on it", resumeCommand),
    ("bootstrap", "log in over SSH, start mosh-server and run a script on the session", bootstrapCommand),
    ("soak", "type a marker line every 2 to 3 s for some minutes and measure how long each takes to come back", soakCommand),
]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first, let command = subcommands.first(where: { $0.name == name }) else {
    FileHandle.standardError.write(Data("usage: moshcli <subcommand> [options]\n".utf8))
    for c in subcommands { FileHandle.standardError.write(Data("  \(c.name)  \(c.summary)\n".utf8)) }
    exit(2)
}
do {
    let code = try await command.run(Array(arguments.dropFirst()))
    StorageWatch.dieIfCrashPlayed()
    exit(code)
} catch {
    StorageWatch.dieIfCrashPlayed()
    FileHandle.standardError.write(Data("moshcli \(name): \(error)\n".utf8))
    exit(1)
}
