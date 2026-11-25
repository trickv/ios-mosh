import MoshWire

/// A terminal size in character cells. Both sides are limited to 1...65535, which also bounds the
/// size of a resize event on the wire.
public struct TerminalSize: Equatable, Hashable, Sendable {
    public var width: UInt16
    public var height: UInt16

    public init(width: UInt16, height: UInt16) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    /// Clamps both values into 1...65535.
    public init(width: Int, height: Int) {
        self.width = UInt16(min(max(width, 1), Int(UInt16.max)))
        self.height = UInt16(min(max(height, 1), Int(UInt16.max)))
    }
}

/// One thing the user did. mosh: `Network::UserEvent` (a byte, or a resize).
public enum UserEvent: Equatable, Hashable, Sendable {
    /// One byte typed (or pasted).
    case byte(UInt8)
    /// The terminal view changed size.
    case resize(TerminalSize)
}

/// The client's local state: everything the user did, in order. mosh: `Network::UserStream`.
///
/// mosh copies the whole stream into every entry of `sent_states` and compares, subtracts and
/// diffs the copies. All of those copies are prefixes of one append-only stream, so this port keeps
/// the stream once and describes a state by the number of events it contains, counted from the
/// start of the session (or from the acknowledged state of an imported snapshot). With that:
///
/// - `a == b` in mosh is `a.end == b.end` here;
/// - `current.diff_from(existing)` is `diff(from: existing.end, to: current.end)`;
/// - `subtract` (drop the prefix the receiver is known to have) is `discard(before:)`.
///
/// The events themselves never change once appended, so "the same end" always means "the same
/// content". The snapshot hazard in mosh (the front advanced by an ack, the lists trimmed only at
/// the next tick) cannot occur: pending input is always `events(from: front.end)`.
struct InputLog: Sendable {
    /// Events from `base` on.
    private var events: [UserEvent] = []
    /// Absolute index of `events[0]`.
    private(set) var base: UInt64 = 0

    /// Absolute index one past the last event: the "state" that contains everything.
    var end: UInt64 { base + UInt64(events.count) }

    mutating func append(_ event: UserEvent) {
        events.append(event)
    }

    mutating func append(bytes: some Sequence<UInt8>) {
        events.append(contentsOf: bytes.lazy.map(UserEvent.byte))
    }

    /// Forgets the events before `index` (mosh: `UserStream::subtract`). Indices stay absolute.
    mutating func discard(before index: UInt64) {
        guard index > base else { return }
        let count = Int(min(index, end) - base)
        events.removeFirst(count)
        base += UInt64(count)
    }

    /// The events in `from..<to`, or nil when the range is not held (reversed, already
    /// discarded, or beyond the end).
    func events(from: UInt64, to: UInt64) -> ArraySlice<UserEvent>? {
        guard from >= base, to >= from, to <= end else { return nil }
        return events[Int(from - base)..<Int(to - base)]
    }

    /// The diff that turns a state ending at `from` into the state ending at `to`: a serialized
    /// `UserMessage`, empty when the two are equal. mosh: `UserStream::diff_from`, including its
    /// rule of joining consecutive bytes into one keystroke instruction.
    func diff(from: UInt64, to: UInt64) -> [UInt8]? {
        guard let slice = events(from: from, to: to) else { return nil }
        return Self.serialize(slice)
    }

    static func serialize(_ events: some Sequence<UserEvent>) -> [UInt8] {
        var instructions: [UserInstruction] = []
        var keys: [UInt8] = []
        for event in events {
            switch event {
            case .byte(let byte):
                keys.append(byte)
            case .resize(let size):
                if !keys.isEmpty {
                    instructions.append(.keystroke(keys))
                    keys.removeAll(keepingCapacity: true)
                }
                instructions.append(.resize(width: Int32(size.width), height: Int32(size.height)))
            }
        }
        if !keys.isEmpty {
            instructions.append(.keystroke(keys))
        }
        guard !instructions.isEmpty else { return [] }
        return UserMessage(instructions: instructions).serialized()
    }
}
