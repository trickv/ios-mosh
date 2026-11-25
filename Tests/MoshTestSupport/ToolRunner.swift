import Foundation

/// Runs a command-line tool (ssh-keygen, tmux, ...) and collects its output. Test code only.
public enum ToolRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    public enum ToolError: Error, CustomStringConvertible {
        case notFound(String)
        case failed(command: String, status: Int32, stderr: String)

        public var description: String {
            switch self {
            case .notFound(let tool): return "tool not found in PATH: \(tool)"
            case .failed(let command, let status, let stderr):
                return "\(command) exited with \(status): \(stderr)"
            }
        }
    }

    /// The full path of a tool found in PATH, nil if there is none.
    public static func which(_ tool: String) -> String? {
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs the tool to completion. A non-zero exit status is returned, not thrown.
    public static func run(
        _ tool: String, _ arguments: [String] = [], environment: [String: String]? = nil,
        stdin: String? = nil
    ) throws -> Output {
        guard let executable = which(tool) else { throw ToolError.notFound(tool) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Read both pipes to the end before waiting, on two threads, so a tool that fills one
        // pipe while we read the other cannot block.
        let errData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        // group.wait() orders the write on the other thread before the read below.
        group.wait()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData.data, as: UTF8.self))
    }

    /// Carries the bytes of the second pipe from the reading thread to the caller.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs the tool and throws unless it exits with 0. Returns its standard output.
    @discardableResult
    public static func check(
        _ tool: String, _ arguments: [String] = [], environment: [String: String]? = nil,
        stdin: String? = nil
    ) throws -> String {
        let output = try run(tool, arguments, environment: environment, stdin: stdin)
        guard output.status == 0 else {
            throw ToolError.failed(
                command: ([tool] + arguments).joined(separator: " "), status: output.status,
                stderr: output.stderr)
        }
        return output.stdout
    }
}
