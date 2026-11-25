import MoshCrypto
import MoshWire
import XCTest
@testable import MoshTransport

/// The receive path: `Transport::recv` and `Connection::recv_one` (mosh 1.4.0).
final class ReceiverTests: XCTestCase {
    private func advanced(_ events: [TransportEvent]) -> [UInt64] {
        events.compactMap { if case .remoteStateAdvanced(let number) = $0 { return number } else { return nil } }
    }

    private func protocolErrors(_ events: [TransportEvent]) -> Int {
        events.filter { if case .peerProtocolError = $0 { return true } else { return false } }.count
    }

    func testStatesInOrder() {
        var harness = Harness()
        harness.tick()
        XCTAssertEqual(harness.core.newestRemoteState.number, 0)
        XCTAssertEqual(harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a")), [.authentic])
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 0, diff: hostBytes("b"))
        harness.deliver(old: 2, new: 3, ack: 1, throwaway: 0, diff: hostBytes("c"))
        harness.tick()
        XCTAssertEqual(advanced(harness.events), [1, 2, 3])
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("abc".utf8))
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [0, 1, 2, 3])
        XCTAssertEqual(harness.core.acknowledgmentNumber, 3)
        // The ack for the data goes out after the ack delay and names the newest state.
        let ack = harness.advance(100)
        XCTAssertEqual(ack.first?.ackNum, 3)
    }

    func testADiffIsAppliedToACopyOfItsBaseState() {
        var harness = Harness()
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 0, diff: hostBytes("b"))
        // State 3 is built on state 1, not on the newest state.
        harness.deliver(old: 1, new: 3, ack: 1, throwaway: 0, diff: hostBytes("c"))
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("ac".utf8))
    }

    func testDuplicateStateIsIgnored() {
        var harness = Harness()
        harness.tick()
        let datagrams = harness.server.datagrams(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        XCTAssertEqual(harness.core.receive(datagram: datagrams[0], now: harness.now), .authentic)
        // The same datagram again (a replay): authentic, but below the expected sequence number.
        XCTAssertEqual(harness.core.receive(datagram: datagrams[0], now: harness.now), .authenticOutOfOrder)
        // The same state number in a new datagram with other content: also ignored.
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("ZZZ"))
        harness.tick()
        XCTAssertEqual(advanced(harness.events), [1])
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [0, 1])
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("a".utf8))
        XCTAssertEqual(protocolErrors(harness.events), 0)
    }

    func testOutOfOrderStateIsKeptButNotAcknowledged() {
        var harness = Harness()
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        harness.deliver(old: 1, new: 3, ack: 1, throwaway: 0, diff: hostBytes("c"))
        // State 2 arrives after state 3.
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 0, diff: hostBytes("b"))
        harness.tick()
        XCTAssertEqual(advanced(harness.events), [1, 3], "no news for a state older than the newest")
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [0, 1, 2, 3], "inserted in its sorted place")
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
        XCTAssertEqual(harness.core.acknowledgmentNumber, 3)
        // It can serve as a base later.
        harness.deliver(old: 2, new: 4, ack: 1, throwaway: 0, diff: hostBytes("d"))
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, Array("abd".utf8))
    }

    func testAppliedInstructionsAreReportedOnRequest() {
        var configuration = Harness.configuration()
        configuration.reportsInstructions = true
        var harness = Harness(configuration: configuration)
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        harness.deliver(old: 1, new: 3, ack: 1, throwaway: 0, diff: hostBytes("c"))
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 0) // late, empty
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 0, diff: hostBytes("dup")) // duplicate
        harness.deliver(old: 9, new: 10, ack: 1, throwaway: 0, diff: hostBytes("no base"))
        harness.tick()
        let applied = harness.events.compactMap { event -> AppliedInstruction? in
            if case .instructionApplied(let instruction) = event { return instruction } else { return nil }
        }
        XCTAssertEqual(applied, [
            AppliedInstruction(oldNum: 0, newNum: 1, diff: hostBytes("a")),
            AppliedInstruction(oldNum: 1, newNum: 3, diff: hostBytes("c")),
            AppliedInstruction(oldNum: 1, newNum: 2, diff: []),
        ])
        XCTAssertEqual(harness.events.first, .instructionApplied(applied[0]))
        XCTAssertEqual(advanced(harness.events), [1, 3])
    }

    func testUnknownBaseStateIsIgnored() {
        var harness = Harness()
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        // State 5 has not arrived (yet): the instruction built on it cannot be used.
        harness.deliver(old: 5, new: 6, ack: 1, throwaway: 0, diff: hostBytes("x"))
        harness.tick()
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [0, 1])
        XCTAssertEqual(harness.core.acknowledgmentNumber, 1)
        XCTAssertEqual(advanced(harness.events), [1])
        XCTAssertFalse(harness.events.contains { if case .baseStateLost = $0 { return true } else { return false } })
    }

    func testThrowawayDropsOlderStates() {
        var harness = Harness()
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        harness.deliver(old: 1, new: 2, ack: 1, throwaway: 1, diff: hostBytes("b"))
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [1, 2])
        harness.deliver(old: 2, new: 3, ack: 1, throwaway: 2, diff: hostBytes("c"))
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [2, 3])
        // A dropped state is no base any more.
        harness.deliver(old: 1, new: 9, ack: 1, throwaway: 1, diff: hostBytes("x"))
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [2, 3])
        // throwaway_num above old_num would make mosh erase the state it is about to copy.
        // Here the instruction is dropped and nothing is erased.
        harness.deliver(old: 2, new: 4, ack: 1, throwaway: 3, diff: hostBytes("y"))
        harness.tick()
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [2, 3])
        XCTAssertEqual(protocolErrors(harness.events), 1)
        XCTAssertFalse(harness.events.contains { if case .baseStateLost = $0 { return true } else { return false } })
    }

    func testMultiFragmentInstruction() {
        var harness = Harness()
        harness.tick()
        // Bytes that do not compress, so that the instruction needs several fragments.
        var value: UInt32 = 99
        var noise: [UInt8] = []
        for _ in 0..<3000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            noise.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        let diff = HostMessage(instructions: [.hostBytes(noise)]).serialized()
        let datagrams = harness.server.datagrams(old: 0, new: 1, ack: 1, throwaway: 0, diff: diff, contentsBudget: 500)
        XCTAssertGreaterThan(datagrams.count, 4)
        for datagram in datagrams.dropLast() {
            XCTAssertEqual(harness.core.receive(datagram: datagram, now: harness.now), .authentic)
            XCTAssertEqual(harness.core.newestRemoteState.number, 0, "incomplete")
        }
        harness.core.receive(datagram: datagrams[datagrams.count - 1], now: harness.now)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1)
        XCTAssertEqual(harness.core.newestRemoteState.state.hostBytes, noise)

        // Fragments in any order, with a repeat.
        let second = harness.server.datagrams(old: 1, new: 2, ack: 1, throwaway: 0, diff: diff, contentsBudget: 500)
        for datagram in second.reversed() + [second[0]] {
            harness.core.receive(datagram: datagram, now: harness.now)
        }
        XCTAssertEqual(harness.core.newestRemoteState.number, 2)

        // A fragment of another instruction in the middle discards the unfinished one.
        let third = harness.server.datagrams(old: 2, new: 3, ack: 1, throwaway: 0, diff: diff, contentsBudget: 500)
        let fourth = harness.server.datagrams(old: 2, new: 4, ack: 1, throwaway: 0, diff: hostBytes("short"))
        for datagram in third.dropLast() {
            harness.core.receive(datagram: datagram, now: harness.now)
        }
        harness.core.receive(datagram: fourth[0], now: harness.now)
        harness.core.receive(datagram: third[third.count - 1], now: harness.now)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [0, 1, 2, 4])
        harness.tick()
        XCTAssertEqual(protocolErrors(harness.events), 0)
    }

    /// "Do not accept state if our queue is full": above 1024 held states one more is accepted and
    /// then nothing for 15 s.
    func testQuenchRule() {
        var harness = Harness()
        harness.tick()
        for number in 1...1024 {
            harness.deliver(old: UInt64(number - 1), new: UInt64(number), ack: 1, throwaway: 0)
        }
        XCTAssertEqual(harness.core.heldRemoteStateNumbers.count, 1025)
        // 1025 states are held: this one is still taken and starts the 15 s window.
        harness.deliver(old: 1024, new: 1025, ack: 1, throwaway: 0)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1025)
        let quenchedAt = harness.now
        harness.deliver(old: 1025, new: 1026, ack: 1, throwaway: 0)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1025, "dropped")
        XCTAssertEqual(harness.core.acknowledgmentNumber, 1025)
        harness.now = quenchedAt + 14_999
        harness.deliver(old: 1025, new: 1027, ack: 1, throwaway: 0)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1025, "still dropped")
        // When the window is over one more is taken, and the next window starts.
        harness.now = quenchedAt + 15_000
        harness.deliver(old: 1025, new: 1028, ack: 1, throwaway: 0)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1028)
        harness.deliver(old: 1028, new: 1029, ack: 1, throwaway: 0)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1028)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers.count, 1027)

        // A throwaway that shrinks the list ends the quench at once: the check comes after it.
        harness.deliver(old: 1028, new: 1030, ack: 1, throwaway: 1000)
        XCTAssertEqual(harness.core.newestRemoteState.number, 1030)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers.first, 1000)
        harness.tick()
        XCTAssertEqual(protocolErrors(harness.events), 0)
    }

    func testServerShutdownIsAcknowledgedAndReported() throws {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500
        harness.events.removeAll()
        let shutdownAt = harness.now
        harness.deliver(old: 2, new: UInt64.max, ack: 2, throwaway: 2, diff: hostBytes("[exited]"))
        // The ack leaves one send interval after the last send, which is long past: at once.
        let ack = harness.tick()
        XCTAssertEqual(harness.events, [.serverShutdown, .serverShutdownAcknowledged])
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack.first?.ackNum, UInt64.max)
        XCTAssertEqual(ack.first?.newNum, 3, "an ordinary instruction carries the ack")
        XCTAssertEqual(ack.first?.oldNum, 2)
        XCTAssertEqual(ack.first?.throwawayNum, 2)

        // 2^64 - 1 stays out of the state list and the counters.
        XCTAssertEqual(harness.core.newestRemoteState.number, 2)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [1, 2])
        XCTAssertTrue(harness.core.serverHasShutDown)
        XCTAssertEqual(harness.core.finalRemoteState?.hostBytes, Array("hello[exited]".utf8))

        // Nothing more is sent, and input is refused.
        XCTAssertNil(harness.lastWakeup)
        XCTAssertFalse(harness.core.type([0x61]))
        XCTAssertFalse(harness.core.resize(TerminalSize(width: 10, height: 10)))
        harness.now += 60_000
        XCTAssertTrue(harness.tick().isEmpty)

        // The server repeats the shutdown if our ack was lost: it is acknowledged again, without
        // a second event.
        harness.events.removeAll()
        harness.deliver(old: 2, new: UInt64.max, ack: 2, throwaway: 2, diff: hostBytes("[exited]"))
        let again = harness.tick()
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.ackNum, UInt64.max)
        XCTAssertEqual(again.first?.newNum, 4)
        XCTAssertEqual(harness.events, [])
        XCTAssertNil(harness.lastWakeup)
        XCTAssertGreaterThan(harness.now, shutdownAt)

        // A finished session cannot be exported.
        harness.core.quiesce()
        XCTAssertThrowsError(try harness.core.exportState()) { error in
            XCTAssertEqual(error as? SnapshotError, .sessionEnded)
        }
    }

    func testServerShutdownOnAnUnknownBaseIsStillAcknowledged() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500
        harness.deliver(old: 77, new: UInt64.max, ack: 2, throwaway: 77, diff: hostBytes("bye"))
        let ack = harness.tick()
        XCTAssertEqual(ack.first?.ackNum, UInt64.max)
        XCTAssertTrue(harness.events.contains(.serverShutdown))
        XCTAssertNil(harness.core.finalRemoteState, "the last screen cannot be built")
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [1, 2])
    }

    func testBaseStateLostIsReportedOnce() {
        var harness = Harness()
        harness.connectAndSettle()
        // The server builds on its state 7, which it believes we hold (it is also its
        // throwaway_num), and we do not: nothing it sends can ever be applied.
        harness.deliver(old: 7, new: 8, ack: 2, throwaway: 7, diff: hostBytes("x"))
        harness.deliver(old: 7, new: 9, ack: 2, throwaway: 7, diff: hostBytes("y"))
        harness.tick()
        XCTAssertEqual(harness.events.filter { $0 == .baseStateLost(serverBase: 7) }.count, 1)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [1, 2], "nothing is damaged")
        XCTAssertFalse(harness.core.isHalted)
    }

    func testALateInstructionOnADroppedBaseIsNotALostBase() {
        var harness = Harness()
        harness.tick()
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, diff: hostBytes("a"))
        // An instruction from the time when the server's base was state 1 is delayed.
        let late = harness.server.datagrams(old: 1, new: 2, ack: 1, throwaway: 1, diff: hostBytes("b"))
        harness.deliver(old: 1, new: 3, ack: 1, throwaway: 1, diff: hostBytes("c"))
        harness.deliver(old: 3, new: 4, ack: 1, throwaway: 3, diff: hostBytes("d"))
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [3, 4])
        // It arrives now: old_num = throwaway_num = 1, and state 1 is gone. But the server has
        // moved its base on since (we saw throwaway_num 3), so this says nothing.
        XCTAssertEqual(harness.core.receive(datagram: late[0], now: harness.now), .authenticOutOfOrder)
        harness.tick()
        XCTAssertFalse(harness.events.contains { if case .baseStateLost = $0 { return true } else { return false } })
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [3, 4])
    }

    func testGarbageAndTruncatedDatagramsAreRejected() {
        var harness = Harness()
        harness.connectAndSettle()
        let before = harness.core.heldRemoteStateNumbers
        for length in [0, 1, 8, 23, 24, 25, 64, 1500, 70_000] {
            let garbage = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            XCTAssertEqual(harness.core.receive(datagram: garbage, now: harness.now), .rejected, "length \(length)")
        }
        let good = harness.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 2, diff: hostBytes("x"))[0]
        for cut in [1, 2, 16, good.count - 8, good.count - 1] {
            XCTAssertEqual(harness.core.receive(datagram: Array(good.dropLast(cut)), now: harness.now), .rejected, "cut \(cut)")
        }
        var flipped = good
        flipped[good.count / 2] ^= 0x01
        XCTAssertEqual(harness.core.receive(datagram: flipped, now: harness.now), .rejected)
        var nonce = good
        nonce[7] ^= 0x01
        XCTAssertEqual(harness.core.receive(datagram: nonce, now: harness.now), .rejected)

        // Our own datagram reflected back (right key, wrong direction).
        harness.type("a")
        let own = { () -> [[UInt8]] in harness.now += 20; return harness.tickRaw() }()
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(harness.core.receive(datagram: own[0], now: harness.now), .rejected)

        // Another key.
        let other = try! MoshCipher(key: Base64Key(bytes: [UInt8](repeating: 9, count: 16)))
        let foreign = try! Packet(seq: 99, direction: .toClient, timestamp: 0, timestampReply: 0, payload: [UInt8](repeating: 0, count: 30)).encrypted(with: other)
        XCTAssertEqual(harness.core.receive(datagram: foreign, now: harness.now), .rejected)

        harness.tick()
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, before)
        XCTAssertEqual(protocolErrors(harness.events), 0)
        // The untouched datagram is still good.
        XCTAssertEqual(harness.core.receive(datagram: good, now: harness.now), .authentic)
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
    }

    func testAuthenticNonsenseIsDroppedWithoutACrash() {
        var harness = Harness()
        harness.connectAndSettle()
        let before = harness.core.heldRemoteStateNumbers

        // Too short for a fragment header (mosh: fatal_assert).
        let short = harness.server.packet(payload: [1, 2, 3])
        XCTAssertEqual(harness.core.receive(datagram: short, now: harness.now), .authentic)
        // A whole fragment whose contents are not zlib data.
        let notZlib = harness.server.packet(payload: try! Fragment(id: 500, fragmentNum: 0, isFinal: true, contents: [0xDE, 0xAD, 0xBE, 0xEF]).serialized())
        harness.core.receive(datagram: notZlib, now: harness.now)
        // zlib data that is not an Instruction.
        let notProto = harness.server.packet(payload: try! Fragment(id: 501, fragmentNum: 0, isFinal: true, contents: try! Compressor.compress([0xFF, 0xFF, 0xFF])).serialized())
        harness.core.receive(datagram: notProto, now: harness.now)
        // An empty payload and an empty datagram body.
        harness.core.receive(datagram: harness.server.packet(payload: []), now: harness.now)
        // The wrong protocol version.
        for datagram in harness.server.datagrams(old: 2, new: 3, ack: 2, throwaway: 2, diff: hostBytes("x"), protocolVersion: 3) {
            harness.core.receive(datagram: datagram, now: harness.now)
        }
        // A diff that is not a HostMessage: the state is not stored and not acknowledged.
        harness.deliver(old: 2, new: 3, ack: 2, throwaway: 2, diff: [0xFF, 0xFF, 0xFF, 0xFF])
        // Fragment numbers out of range for the assembly.
        let far = harness.server.packet(payload: try! Fragment(id: 502, fragmentNum: 0x7FFF, isFinal: true, contents: [1]).serialized())
        harness.core.receive(datagram: far, now: harness.now)
        let conflicting = harness.server.packet(payload: try! Fragment(id: 502, fragmentNum: 3, isFinal: true, contents: [1]).serialized())
        harness.core.receive(datagram: conflicting, now: harness.now)

        harness.tick()
        // (The instruction with the bad diff still carried a valid throwaway_num of 2.)
        XCTAssertEqual(before, [1, 2])
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, [2])
        XCTAssertEqual(harness.core.acknowledgmentNumber, 2)
        XCTAssertGreaterThanOrEqual(protocolErrors(harness.events), 5)
        XCTAssertFalse(harness.core.isHalted)
        // The session goes on.
        harness.deliver(old: 2, new: 3, ack: 2, throwaway: 2, diff: hostBytes("fine"))
        XCTAssertEqual(harness.core.newestRemoteState.number, 3)
    }

    func testRandomDatagramsNeverCrash() {
        var harness = Harness()
        harness.connectAndSettle()
        var value: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            return value
        }
        var number: UInt64 = 3
        for round in 0..<1500 {
            // Authentic packets with random payloads, and authentic instructions with random
            // numbers: everything a hostile server could do short of valid traffic.
            let length = Int(next() % 60)
            let payload = (0..<length).map { _ in UInt8(truncatingIfNeeded: next()) }
            harness.core.receive(datagram: harness.server.packet(payload: payload), now: harness.now)
            let numbers = (0..<4).map { _ in round % 3 == 0 ? next() : next() % 8 }
            harness.deliver(old: numbers[0], new: numbers[1], ack: numbers[2], throwaway: numbers[3], diff: round % 2 == 0 ? hostBytes("r") : payload)
            if round % 50 == 0 {
                harness.deliver(old: harness.core.newestRemoteState.number, new: harness.core.newestRemoteState.number + 1000, ack: number, throwaway: 0)
                number += 1
            }
            harness.now += next() % 40
            harness.tick()
            harness.events.removeAll(keepingCapacity: true)
            if harness.core.serverHasShutDown { break }
        }
        XCTAssertFalse(harness.core.isHalted, "nothing a peer sends can break a send-side invariant")
        XCTAssertFalse(harness.core.heldRemoteStateNumbers.isEmpty)
        XCTAssertEqual(harness.core.heldRemoteStateNumbers, harness.core.heldRemoteStateNumbers.sorted())
    }

    func testClientShutdownIsRepeatedThenTimesOut() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500
        let startedAt = harness.now
        harness.core.startShutdown(now: harness.now)
        XCTAssertFalse(harness.core.type([0x61]), "no input after the shutdown began")
        var sent: [ClientInstruction] = harness.tick()
        var times: [UInt64] = []
        while !harness.events.contains(.shutdownTimedOut), harness.now < startedAt + 20_000 {
            for instruction in sent {
                XCTAssertEqual(instruction.newNum, UInt64.max)
                XCTAssertEqual(instruction.oldNum, 2)
                XCTAssertEqual(instruction.throwawayNum, 2)
                times.append(harness.now - startedAt)
            }
            guard harness.lastWakeup != nil else { break }
            sent = harness.advanceToWakeup()
        }
        // SHUTDOWN_RETRIES: 16 sends, one send interval (20 ms) apart, then the client gives up.
        XCTAssertEqual(times.count, 16)
        XCTAssertEqual(Array(times.prefix(3)), [0, 20, 40])
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
        XCTAssertTrue(harness.core.hasEnded)
        XCTAssertNil(harness.lastWakeup)
        harness.now += 5000
        XCTAssertTrue(harness.tick().isEmpty)
    }

    func testClientShutdownAcknowledged() {
        var harness = Harness()
        harness.connectAndSettle()
        harness.now += 500
        harness.core.startShutdown(now: harness.now)
        let sent = harness.tick()
        XCTAssertEqual(sent.first?.newNum, UInt64.max)
        harness.now += 10
        harness.deliver(old: 2, new: 3, ack: UInt64.max, throwaway: 2)
        XCTAssertTrue(harness.tick().isEmpty)
        XCTAssertEqual(harness.events.filter { $0 == .shutdownAcknowledged }.count, 1)
        XCTAssertTrue(harness.core.hasEnded)
        XCTAssertEqual(harness.core.acknowledgedStateNumber, UInt64.max)
        XCTAssertNil(harness.lastWakeup)
    }

    func testClientShutdownTimesOutAfterTenSecondsOnASlowLink() {
        var harness = Harness()
        let first = harness.tick()
        // A 400 ms round trip: send interval 200 ms, so 16 tries would take only 3 s. Use a link
        // where the interval is at its 250 ms maximum and check the count limit there too.
        harness.now += 400
        harness.deliver(old: 0, new: 1, ack: 1, throwaway: 0, timestampReply: first.first?.timestamp ?? 0)
        harness.tick()
        let startedAt = harness.now
        harness.core.startShutdown(now: harness.now)
        var count = harness.tick().count
        while let wakeup = harness.lastWakeup, wakeup < startedAt + 30_000 {
            count += harness.advanceToWakeup().count
        }
        XCTAssertEqual(count, 16)
        XCTAssertTrue(harness.events.contains(.shutdownTimedOut))
        XCTAssertLessThanOrEqual(harness.now, startedAt + 10_000)
    }

    func testOpaqueRemoteStateKeepsOperationsAndIsBounded() throws {
        var state = OpaqueRemoteState()
        try state.apply(diff: HostMessage(instructions: [.echoAck(5), .resize(width: 100, height: 30), .hostBytes(Array("hello-".utf8))]).serialized())
        try state.apply(diff: hostBytes("42\r\n"))
        XCTAssertEqual(state.echoAck, 5)
        XCTAssertEqual(state.size, TerminalSize(width: 100, height: 30))
        XCTAssertEqual(state.operationCount, 4)
        XCTAssertTrue(state.hostBytesContain("hello-42"))
        XCTAssertFalse(state.hostBytesContain("hello-43"))
        XCTAssertThrowsError(try state.apply(diff: [0xFF]))
        for _ in 0..<(OpaqueRemoteState.retainedOperationLimit + 10) {
            try state.apply(diff: hostBytes("x"))
        }
        XCTAssertEqual(state.operations.count, OpaqueRemoteState.retainedOperationLimit)
        XCTAssertEqual(state.hostByteCount, UInt64(10 + OpaqueRemoteState.retainedOperationLimit + 10))
    }
}
