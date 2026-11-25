import MoshCrypto
import MoshWire
import XCTest
@testable import MoshTransport

/// A client datagram as the server would see it.
struct ClientDatagram {
    var seq: UInt64
    var timestamp: UInt16
    var timestampReply: UInt16
    var fragment: Fragment
    var length: Int
}

/// A client instruction, reassembled, with the facts of the datagrams that carried it.
struct ClientInstruction {
    var instruction: Instruction
    var fragmentID: UInt64
    var sequences: [UInt64]
    var timestamp: UInt16
    var timestampReply: UInt16

    var oldNum: UInt64 { instruction.oldNum }
    var newNum: UInt64 { instruction.newNum }
    var ackNum: UInt64 { instruction.ackNum }
    var throwawayNum: UInt64 { instruction.throwawayNum }
    var diff: [UInt8] { instruction.diff }
    /// The diff decoded.
    var input: [UserInstruction] { (try? UserMessage(serialized: instruction.diff).instructions) ?? [] }
}

/// A scripted mosh server made from MoshWire and MoshCrypto: it builds server datagrams by hand
/// and decodes what the client sends.
struct FakeServer {
    static let key = try! Base64Key(printable: "zr0jtuYVKJnfJHP/XOOsbQ")
    let cipher = try! MoshCipher(key: FakeServer.key)
    var nextSeq: UInt64 = 0
    var nextFragmentID: UInt64 = 1
    var assembly = FragmentAssembly()

    /// One instruction as datagrams (one per fragment).
    mutating func datagrams(
        old: UInt64,
        new: UInt64,
        ack: UInt64,
        throwaway: UInt64,
        diff: [UInt8] = [],
        timestamp: UInt16 = 0,
        timestampReply: UInt16 = Timestamp16.none,
        contentsBudget: Int = 1214,
        protocolVersion: UInt32 = 2
    ) -> [[UInt8]] {
        var instruction = Instruction(oldNum: old, newNum: new, ackNum: ack, throwawayNum: throwaway, diff: diff, chaff: [])
        instruction.protocolVersion = protocolVersion
        let id = nextFragmentID
        nextFragmentID += 1
        let fragments = try! Fragmenter.makeFragments(instruction: instruction, id: id, contentsBudget: contentsBudget)
        return fragments.map { fragment in
            packet(payload: fragment.serialized(), timestamp: timestamp, timestampReply: timestampReply)
        }
    }

    /// One encrypted server datagram with any payload.
    mutating func packet(payload: [UInt8], timestamp: UInt16 = 0, timestampReply: UInt16 = Timestamp16.none, seq: UInt64? = nil, direction: Direction = .toClient) -> [UInt8] {
        let number: UInt64
        if let seq {
            number = seq
        } else {
            number = nextSeq
            nextSeq += 1
        }
        let packet = Packet(seq: number, direction: direction, timestamp: timestamp, timestampReply: timestampReply, payload: payload)
        return try! packet.encrypted(with: cipher)
    }

    func open(_ datagram: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> ClientDatagram? {
        guard let packet = try? Packet(decrypting: datagram, with: cipher), let fragment = try? Fragment(serialized: packet.payload) else {
            XCTFail("the client sent a datagram that does not decode", file: file, line: line)
            return nil
        }
        XCTAssertEqual(packet.direction, .toServer, file: file, line: line)
        return ClientDatagram(seq: packet.seq, timestamp: packet.timestamp, timestampReply: packet.timestampReply, fragment: fragment, length: datagram.count)
    }

    /// Reassembles the instructions in a batch of client datagrams.
    mutating func read(_ datagrams: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) -> [ClientInstruction] {
        var out: [ClientInstruction] = []
        var sequences: [UInt64] = []
        var first: ClientDatagram?
        for datagram in datagrams {
            guard let opened = open(datagram, file: file, line: line) else { continue }
            if opened.fragment.fragmentNum == 0 {
                sequences = []
                first = opened
            }
            sequences.append(opened.seq)
            guard (try? assembly.add(opened.fragment)) == true, let instruction = try? assembly.takeInstruction() else { continue }
            out.append(ClientInstruction(
                instruction: instruction,
                fragmentID: opened.fragment.id,
                sequences: sequences,
                timestamp: first?.timestamp ?? opened.timestamp,
                timestampReply: first?.timestampReply ?? opened.timestampReply
            ))
        }
        return out
    }
}

func hostBytes(_ text: String) -> [UInt8] {
    HostMessage(instructions: [.hostBytes(Array(text.utf8))]).serialized()
}

/// A core, a fake server, a gate and a clock that only moves when told to.
struct Harness {
    typealias Core = TransportCore<OpaqueRemoteState>

    /// The fake clock starts well above zero, as the core requires.
    static let start: UInt64 = 1_000_000

    var core: Core
    var server = FakeServer()
    var gate: any DurabilityGate
    var now: UInt64 = Harness.start
    var events: [TransportEvent] = []
    var lastWakeup: UInt64?
    /// Every sequence number the client has used, in order.
    var sequences: [UInt64] = []

    static func configuration(limit: Int = TransportConstants.defaultUnacknowledgedInputLimit, family: AddressFamily = .ipv4) -> TransportConfiguration {
        TransportConfiguration(family: family, unacknowledgedInputLimit: limit, makeChaff: { [] })
    }

    init(size: TerminalSize? = TerminalSize(width: 80, height: 24), gate: any DurabilityGate = InMemoryGate(), configuration: TransportConfiguration = Harness.configuration()) {
        self.gate = gate
        core = Core(cipher: server.cipher, gate: gate, configuration: configuration, initialSize: size, now: now)
    }

    init(restoring snapshot: TransportSnapshot<OpaqueRemoteState>, gate: any DurabilityGate, currentSize: TerminalSize?, now: UInt64 = Harness.start) throws {
        self.gate = gate
        self.now = now
        core = try Core(restoring: snapshot, cipher: server.cipher, gate: gate, configuration: Harness.configuration(), currentSize: currentSize, now: now)
    }

    /// Ticks at the current time and returns the instructions sent.
    @discardableResult
    mutating func tick(file: StaticString = #filePath, line: UInt = #line) -> [ClientInstruction] {
        let output = core.tick(now: now)
        events.append(contentsOf: output.events)
        lastWakeup = output.nextWakeup
        for datagram in output.datagrams {
            if let opened = server.open(datagram, file: file, line: line) {
                sequences.append(opened.seq)
            }
        }
        return server.read(output.datagrams, file: file, line: line)
    }

    /// Ticks and returns the raw datagrams.
    mutating func tickRaw() -> [[UInt8]] {
        let output = core.tick(now: now)
        events.append(contentsOf: output.events)
        lastWakeup = output.nextWakeup
        return output.datagrams
    }

    /// Moves the clock and ticks.
    @discardableResult
    mutating func advance(_ milliseconds: UInt64, file: StaticString = #filePath, line: UInt = #line) -> [ClientInstruction] {
        now += milliseconds
        return tick(file: file, line: line)
    }

    /// Jumps to the wake-up time the core asked for and ticks.
    @discardableResult
    mutating func advanceToWakeup(file: StaticString = #filePath, line: UInt = #line) -> [ClientInstruction] {
        guard let wakeup = lastWakeup else {
            XCTFail("no wake-up is set", file: file, line: line)
            return []
        }
        now = max(now, wakeup)
        return tick(file: file, line: line)
    }

    /// Delivers one server instruction at the current time (no tick).
    @discardableResult
    mutating func deliver(
        old: UInt64,
        new: UInt64,
        ack: UInt64,
        throwaway: UInt64,
        diff: [UInt8] = [],
        timestamp: UInt16 = 0,
        timestampReply: UInt16 = Timestamp16.none
    ) -> [ReceiveResult] {
        let datagrams = server.datagrams(old: old, new: new, ack: ack, throwaway: throwaway, diff: diff, timestamp: timestamp, timestampReply: timestampReply)
        return datagrams.map { core.receive(datagram: $0, now: now) }
    }

    /// Types text and ticks at the current time, which starts the sender's minimum-delay clock.
    @discardableResult
    mutating func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [ClientInstruction] {
        XCTAssertTrue(core.type(Array(text.utf8)), file: file, line: line)
        return tick(file: file, line: line)
    }

    /// `connect()`, then our delayed ack (state 2) and the server's ack of it. Afterwards nothing
    /// is pending in either direction: the client's acknowledged state is 2, the server's newest
    /// state is 2, the clock is 110 ms after the start, SRTT is 10 ms (send interval 20 ms,
    /// timeout 50 ms) and the next empty ack is due 3000 ms later.
    mutating func connectAndSettle(file: StaticString = #filePath, line: UInt = #line) {
        connect(file: file, line: line)
        tick(file: file, line: line)
        let ack = advance(100, file: file, line: line)
        XCTAssertEqual(ack.count, 1, file: file, line: line)
        XCTAssertEqual(ack.first?.newNum, 2, file: file, line: line)
        deliver(old: 1, new: 2, ack: 2, throwaway: 1)
        XCTAssertTrue(tick(file: file, line: line).isEmpty, file: file, line: line)
        XCTAssertEqual(core.sentStateNumbers, [2], file: file, line: line)
        XCTAssertEqual(core.heldRemoteStateNumbers, [1, 2], file: file, line: line)
    }

    /// The first exchange of every session: the client announces its size as state 1 and the
    /// server answers with its state 1, acknowledging ours. Leaves the clock 10 ms later.
    mutating func connect(file: StaticString = #filePath, line: UInt = #line) {
        let first = tick(file: file, line: line)
        XCTAssertEqual(first.count, 1, file: file, line: line)
        now += 10
        deliver(old: 0, new: 1, ack: first.first?.newNum ?? 1, throwaway: 0, diff: hostBytes("hello"), timestampReply: first.first?.timestamp ?? Timestamp16.none)
    }
}
