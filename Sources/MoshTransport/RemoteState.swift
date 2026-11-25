import MoshWire

/// The state the server keeps for us (for a terminal: the screen), as the transport sees it.
///
/// The transport holds one value per received state number and builds a new one by copying the
/// value numbered `old_num` and applying the instruction's diff to the copy
/// (mosh: `Transport::recv`, "apply diff to reference state"). A conforming type must therefore
/// have value semantics: changing a copy never changes the original.
///
/// `MoshTransport` does not know what a terminal is. The adapter that decodes the diff and drives
/// the emulator lives in `MoshSession`.
public protocol RemoteState: Sendable {
    /// The state numbered 0: what both sides hold before anything was sent.
    init()

    /// Applies `Instruction.diff`: a serialized `HostBuffers.HostMessage`. Never called with an
    /// empty diff (mosh skips `apply_string` for those). If it throws, the instruction is dropped
    /// and the state is not stored.
    mutating func apply(diff: [UInt8]) throws
}

/// A remote state that does not interpret anything: it remembers the decoded operations.
/// For tests and `moshcli`, where "did these bytes arrive" is the question.
///
/// Only the most recent `retainedOperationLimit` operations are kept, so a long session does not
/// grow without bound; the counters cover everything since state 0.
public struct OpaqueRemoteState: RemoteState, Equatable {
    /// How many operations a state keeps.
    public static let retainedOperationLimit = 4096

    /// The most recent operations applied on the way from state 0 to this state, oldest first.
    public private(set) var operations: [HostInstruction] = []
    /// Number of operations applied since state 0.
    public private(set) var operationCount: UInt64 = 0
    /// Number of host bytes applied since state 0.
    public private(set) var hostByteCount: UInt64 = 0
    /// The last echo ack applied, if any.
    public private(set) var echoAck: UInt64?
    /// The last size the server announced, if any.
    public private(set) var size: TerminalSize?

    public init() {}

    public mutating func apply(diff: [UInt8]) throws {
        let message = try HostMessage(serialized: diff)
        for instruction in message.instructions {
            operationCount += 1
            switch instruction {
            case .hostBytes(let bytes):
                hostByteCount += UInt64(bytes.count)
            case .echoAck(let number):
                echoAck = number
            case .resize(let width, let height):
                size = TerminalSize(width: Int(width), height: Int(height))
            }
            operations.append(instruction)
        }
        if operations.count > Self.retainedOperationLimit {
            operations.removeFirst(operations.count - Self.retainedOperationLimit)
        }
    }

    /// The retained host bytes, joined in order.
    public var hostBytes: [UInt8] {
        var out: [UInt8] = []
        for case .hostBytes(let bytes) in operations {
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// Whether the retained host bytes contain `needle` as a contiguous run.
    public func hostBytesContain(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        let haystack = hostBytes
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// Whether the retained host bytes contain the UTF-8 bytes of `text`.
    public func hostBytesContain(_ text: String) -> Bool {
        hostBytesContain(Array(text.utf8))
    }
}
