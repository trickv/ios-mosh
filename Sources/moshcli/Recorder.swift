// `--record DIR`: the corpus format shared with Tools/mosh-oracle (docs/PLAN.md, "Execution notes
// for Run 1"). Do not change it without changing the oracle.
import Foundation
import MoshTransport
import MoshWire

/// Writes `meta.json` and `instructions.jsonl`.
///
/// `meta.json`: `{"format":1,"width":W,"height":H}`, the size the client announced first.
/// `instructions.jsonl`: one line per applied server instruction, in arrival order:
/// `{"old_num":N,"new_num":M,"diff_b64":"...","ops":[...]}`. `diff_b64` is the raw
/// `Instruction.diff` (a serialized `HostMessage`); `ops` is the same message decoded, each element
/// one of `{"hostbytes_b64":"..."}`, `{"resize":[w,h]}`, `{"echo_ack":n}`. Each `new_num` appears
/// once.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let instructions: FileHandle

    init(directory: String, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let meta = "{\"format\":1,\"width\":\(width),\"height\":\(height)}\n"
        try Data(meta.utf8).write(to: URL(fileURLWithPath: directory + "/meta.json"))
        let path = directory + "/instructions.jsonl"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw CLIError("cannot create \(path)")
        }
        instructions = handle
    }

    /// One line of `instructions.jsonl`, without the newline.
    static func line(for applied: AppliedInstruction, message: HostMessage) -> String {
        var ops: [String] = []
        for instruction in message.instructions {
            switch instruction {
            case .hostBytes(let bytes):
                ops.append("{\"hostbytes_b64\":\"\(Data(bytes).base64EncodedString())\"}")
            case .resize(let width, let height):
                ops.append("{\"resize\":[\(width),\(height)]}")
            case .echoAck(let number):
                ops.append("{\"echo_ack\":\(number)}")
            }
        }
        return "{\"old_num\":\(applied.oldNum),\"new_num\":\(applied.newNum),"
            + "\"diff_b64\":\"\(Data(applied.diff).base64EncodedString())\","
            + "\"ops\":[\(ops.joined(separator: ","))]}"
    }

    func record(_ applied: AppliedInstruction, message: HostMessage) {
        let line = Self.line(for: applied, message: message) + "\n"
        lock.lock()
        instructions.write(Data(line.utf8))
        lock.unlock()
    }
}
