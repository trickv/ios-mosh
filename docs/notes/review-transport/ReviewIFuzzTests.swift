import MoshWire
import XCTest
@testable import MoshTransport

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class FuzzGate: DurabilityGate, @unchecked Sendable {
    let inner: InMemoryGate
    var failures = 0
    init(_ inner: InMemoryGate) { self.inner = inner }
    struct Failure: Error {}
    private func maybeFail() throws { if failures > 0 { failures -= 1; throw Failure() } }
    var reservedLimits: GateCounters { inner.reservedLimits }
    func takeSequenceNumber() throws -> UInt64 { try maybeFail(); return try inner.takeSequenceNumber() }
    func takeStateNumber() throws -> UInt64 { try maybeFail(); return try inner.takeStateNumber() }
    func takeFragmentID() throws -> UInt64 { try maybeFail(); return try inner.takeFragmentID() }
    func willSendDatagram() throws { try maybeFail(); try inner.willSendDatagram() }
    var datagramsPassed: UInt64 { inner.datagramsPassed }
    var isDirty: Bool { inner.isDirty }
    func markClean(ifDatagramsPassed expected: UInt64) throws -> Bool { try inner.markClean(ifDatagramsPassed: expected) }
}

/// What mosh-server does with client instructions, with its asserts as recorded problems.
struct ServerModel {
    var held: [(num: UInt64, events: [UserEvent])] = [(0, [])]
    var lastReceiver: [UserEvent] = []
    var problems: [String] = []
    var ignoredForBase = 0
    var lastSeq: UInt64?
    var lastFragmentID: UInt64?
    var sawShutdown = false
    var clientAck: UInt64 = 0

    static func flatten(_ diff: [UInt8]) -> [UserEvent] {
        guard !diff.isEmpty, let message = try? UserMessage(serialized: diff) else { return [] }
        var out: [UserEvent] = []
        for instruction in message.instructions {
            switch instruction {
            case .keystroke(let keys): out += keys.map(UserEvent.byte)
            case .resize(let w, let h): out.append(.resize(TerminalSize(width: Int(w), height: Int(h))))
            }
        }
        return out
    }

    mutating func wire(_ i: ClientInstruction) {
        for seq in i.sequences {
            if let last = lastSeq, seq <= last { problems.append("N1 seq \(seq) after \(last)") }
            lastSeq = max(lastSeq ?? 0, seq)
        }
        if let last = lastFragmentID, i.fragmentID <= last { problems.append("N4 id \(i.fragmentID) after \(last)") }
        lastFragmentID = max(lastFragmentID ?? 0, i.fragmentID)
        if i.throwawayNum > i.oldNum { problems.append("N3 on the wire \(i.throwawayNum) > \(i.oldNum)") }
    }

    mutating func receive(_ i: ClientInstruction) {
        if i.ackNum != UInt64.max { clientAck = max(clientAck, i.ackNum) }
        if held.contains(where: { $0.num == i.newNum }) { return }
        guard let base = held.first(where: { $0.num == i.oldNum }) else { ignoredForBase += 1; return }
        held.removeAll { $0.num < i.throwawayNum }
        if held.isEmpty { problems.append("fatal_assert: no states left") ; return }
        let state = base.events + Self.flatten(i.diff)
        for other in held {
            if other.num < i.newNum {
                if !(state.count >= other.events.count && Array(state.prefix(other.events.count)) == other.events) {
                    problems.append("N2: state \(i.newNum) (\(state.count)) does not extend \(other.num) (\(other.events.count))")
                }
            } else if !(other.events.count >= state.count && Array(other.events.prefix(state.count)) == state) {
                problems.append("N2: state \(i.newNum) (\(state.count)) is not a prefix of later \(other.num) (\(other.events.count))")
            }
        }
        if let index = held.firstIndex(where: { $0.num > i.newNum }) {
            held.insert((i.newNum, state), at: index)
            return
        }
        held.append((i.newNum, state))
        if !(state.count >= lastReceiver.count && Array(state.prefix(lastReceiver.count)) == lastReceiver) {
            problems.append("N2: diff_from assert at \(i.newNum)")
        }
        lastReceiver = state
        if i.newNum == UInt64.max { sawShutdown = true }
    }

    var ack: UInt64 { held[held.count - 1].num }
}

final class ReviewIFuzzTests: XCTestCase {
    static var globalMaxSent = 0
    func run(seed: UInt64, steps: Int, withShutdown: Bool, withRestore: Bool, verbose: Bool = false, limit: Int = 262_144) -> [String] {
        var rng = SplitMix(state: seed)
        var gate = FuzzGate(InMemoryGate())
        var harness = Harness(gate: gate, configuration: Harness.configuration(limit: limit))
        var model = ServerModel()
        var typed: [UserEvent] = [.resize(TerminalSize(width: 80, height: 24))]
        var serverNum: UInt64 = 0
        var clientHasServerNum = true
        var problems: [String] = []
        var counter = 0
        var loss = 0.2
        var serverSilent = false
        var shutdownStarted = false
        var maxSent = 0

        func note(_ s: String) { if verbose { print("FUZZ[\(seed)] \(harness.now): \(s)") } }

        func pass(_ instructions: [ClientInstruction]) {
            for i in instructions {
                model.wire(i)
                note("client \(i.oldNum)->\(i.newNum == UInt64.max ? "SHUT" : String(i.newNum)) ack \(i.ackNum) tw \(i.throwawayNum) diff \(i.diff.count)")
                if Double.random(in: 0..<1, using: &rng) >= loss { model.receive(i) }
            }
        }
        func tick() {
            var guardCount = 0
            repeat {
                pass(harness.tick())
                guardCount += 1
            } while (harness.lastWakeup.map { $0 <= harness.now } ?? false) && guardCount < 6
            if guardCount >= 6 { problems.append("spin at \(harness.now): wake-up \(String(describing: harness.lastWakeup)) stays due") }
            maxSent = max(maxSent, harness.core.sentStateNumbers.count)
            if harness.core.sentStateNumbers.count > 32 { problems.append("sent states \(harness.core.sentStateNumbers.count)") }
        }
        func serverSend(data: Bool) {
            guard !harness.core.isQuiesced, clientHasServerNum else { return }
            let old = serverNum
            serverNum += 1
            note("server \(old)->\(serverNum) ack \(model.ack)")
            harness.deliver(old: old, new: serverNum, ack: model.ack, throwaway: model.clientAck, diff: data ? hostBytes("x") : [], timestamp: UInt16(truncatingIfNeeded: harness.now), timestampReply: Timestamp16.none)
        }

        for step in 0..<steps {
            if harness.core.isHalted || harness.core.hasEnded { break }
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<30:
                harness.now += UInt64.random(in: 0...60, using: &rng)
                tick()
            case 30..<40:
                if let wake = harness.lastWakeup { harness.now = max(harness.now, wake) } else { harness.now += 100 }
                tick()
            case 40..<45:
                harness.now += UInt64.random(in: 500...4000, using: &rng)
                tick()
            case 45..<65:
                let sizes = [1, 1, 1, 3, 10, 150, 1500]
                let count = sizes[Int.random(in: 0..<sizes.count, using: &rng)]
                var bytes: [UInt8] = []
                for _ in 0..<count { counter += 1; bytes.append(UInt8(truncatingIfNeeded: counter &* 7 &+ counter / 256)) }
                if harness.core.type(bytes) { typed += bytes.map(UserEvent.byte); note("type \(count)") }
                if Bool.random(using: &rng) { tick() }
            case 65..<68:
                counter += 1
                let size = TerminalSize(width: 80 + counter % 50, height: 24 + counter % 7)
                if harness.core.resize(size) { typed.append(.resize(size)) }
            case 68..<85:
                if !serverSilent { serverSend(data: Bool.random(using: &rng)); if Bool.random(using: &rng) { tick() } }
            case 85..<88:
                serverSilent.toggle(); note("server silent \(serverSilent)")
            case 88..<90:
                loss = [0.0, 0.2, 0.6, 1.0][Int.random(in: 0..<4, using: &rng)]; note("loss \(loss)")
            case 90..<93:
                harness.core.socketReplaced(now: harness.now, probe: Bool.random(using: &rng)); tick()
            case 93..<95:
                gate.failures = Int.random(in: 1...4, using: &rng); note("gate failures \(gate.failures)")
            case 95..<98:
                if harness.core.isQuiesced {
                    harness.now += UInt64.random(in: 0...20000, using: &rng)
                    harness.core.unquiesce(now: harness.now); note("unquiesce"); tick()
                } else if Bool.random(using: &rng) {
                    harness.core.quiesce(); note("quiesce")
                } else {
                    pass(server_read(&harness, harness.core.sendPendingNow(now: harness.now)))
                    harness.core.quiesce(); note("send pending + quiesce")
                }
            case 98..<99:
                guard withRestore, !shutdownStarted else { break }
                harness.core.quiesce()
                guard let snapshot = try? harness.core.exportState() else { problems.append("export failed at step \(step)"); break }
                let newGate = FuzzGate(InMemoryGate(startingAt: gate.reservedLimits))
                harness.now += UInt64.random(in: 0...30000, using: &rng)
                let size = Bool.random(using: &rng) ? snapshot.terminalSize : TerminalSize(width: 100, height: 40)
                var restored: Harness
                do { restored = try Harness(restoring: snapshot, gate: newGate, currentSize: size, now: harness.now) } catch { problems.append("restore failed \(error)"); break }
                if size != snapshot.terminalSize, let size { typed.append(.resize(size)) }
                restored.server = harness.server
                restored.events = harness.events
                harness = restored
                gate = newGate
                note("RESTORE A=\(snapshot.acknowledgedStateNumber) pending \(snapshot.pendingInput.count)")
                tick()
            default:
                if withShutdown, step > steps / 2, !shutdownStarted, !harness.core.isQuiesced {
                    harness.core.startShutdown(now: harness.now); shutdownStarted = true; note("SHUTDOWN"); tick()
                }
            }
            if !model.problems.isEmpty { break }
        }
        problems += model.problems
        for event in harness.events {
            if case .internalError(let violation) = event { problems.append("halted: \(violation)") }
        }
        if !shutdownStarted, problems.isEmpty {
            // Settle: no loss, the server answers; everything typed must arrive, in order, once.
            loss = 0
            if harness.core.isQuiesced { harness.core.unquiesce(now: harness.now) }
            var rounds = 0
            while model.lastReceiver.count < typed.count, rounds < 4000 {
                rounds += 1
                if let wake = harness.lastWakeup { harness.now = max(harness.now + 1, min(wake, harness.now + 200)) } else { harness.now += 100 }
                tick()
                if rounds % 3 == 0 { serverSend(data: false); tick() }
            }
            if model.lastReceiver != typed { problems.append("input not delivered: server has \(model.lastReceiver.count) of \(typed.count) events after \(rounds) rounds; same prefix \(Array(typed.prefix(model.lastReceiver.count)) == model.lastReceiver)") }
            problems += model.problems
            for event in harness.events {
                if case .internalError(let violation) = event { problems.append("halted in settle: \(violation)") }
            }
        }
        Self.globalMaxSent = max(Self.globalMaxSent, maxSent)
        if verbose { print("FUZZ[\(seed)] max sent states \(maxSent), ignored for base \(model.ignoredForBase)") }
        return problems
    }

    func server_read(_ harness: inout Harness, _ output: TransportOutput) -> [ClientInstruction] {
        harness.events.append(contentsOf: output.events)
        harness.lastWakeup = output.nextWakeup
        return harness.server.read(output.datagrams)
    }

    func testFuzzNoShutdown() {
        var bad: [String: [UInt64]] = [:]
        for seed in 1...UInt64(400) {
            for p in Set(run(seed: seed, steps: 600, withShutdown: false, withRestore: true)) {
                let key = String(p.prefix(60))
                bad[key, default: []].append(seed)
            }
        }
        for (key, seeds) in bad.sorted(by: { $0.key < $1.key }) { print("FUZZRESULT noshutdown: \(key) :: \(seeds.count) seeds, e.g. \(seeds.prefix(5))") }
        print("FUZZRESULT noshutdown done, max sent states", Self.globalMaxSent)
    }

    func testFuzzWindow() {
        var bad: [String: [UInt64]] = [:]
        for seed in 1...UInt64(300) {
            for p in Set(run(seed: seed, steps: 500, withShutdown: seed % 2 == 0, withRestore: false, limit: 8)) {
                let key = String(p.prefix(60))
                bad[key, default: []].append(seed)
            }
        }
        for (key, seeds) in bad.sorted(by: { $0.key < $1.key }) { print("FUZZRESULT window: \(key) :: \(seeds.count) seeds, e.g. \(seeds.prefix(5))") }
        print("FUZZRESULT window done")
    }

    func testFuzzWithShutdown() {
        var bad: [String: [UInt64]] = [:]
        for seed in 1...UInt64(400) {
            for p in Set(run(seed: seed, steps: 400, withShutdown: true, withRestore: false)) {
                let key = String(p.prefix(60))
                bad[key, default: []].append(seed)
            }
        }
        for (key, seeds) in bad.sorted(by: { $0.key < $1.key }) { print("FUZZRESULT shutdown: \(key) :: \(seeds.count) seeds, e.g. \(seeds.prefix(5))") }
        print("FUZZRESULT shutdown done")
    }
}
