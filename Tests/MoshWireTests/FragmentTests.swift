import XCTest
import MoshTestSupport
import MoshWire

final class FragmentTests: XCTestCase {
    // MARK: Helpers

    /// An instruction whose diff does not compress, so that it needs several fragments.
    private func bigInstruction(diffLength: Int, newNum: UInt64 = 2) -> Instruction {
        var generator = SystemRandomNumberGenerator()
        let diff = (0..<diffLength).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Instruction(oldNum: 1, newNum: newNum, ackNum: 7, throwawayNum: 1, diff: diff,
                           chaff: Instruction.makeChaff(using: &generator))
    }

    private func smallInstruction(newNum: UInt64) -> Instruction {
        Instruction(oldNum: 0, newNum: newNum, ackNum: 0, throwawayNum: 0,
                    diff: UserMessage(instructions: [.keystroke(Array("x".utf8))]).serialized(), chaff: [1, 2, 3])
    }

    /// Feeds fragments in the given order; returns what `add` said for each.
    private func feed(_ assembly: inout FragmentAssembly, _ fragments: [Fragment]) throws -> [Bool] {
        try fragments.map { try assembly.add($0) }
    }

    // MARK: Fragment

    func testFragmentWireFormat() throws {
        let fragment = try Fragment(id: 0x0102030405060708, fragmentNum: 0x1234, isFinal: false, contents: [0xAA, 0xBB])
        XCTAssertEqual(hex(fragment.serialized()), "0102030405060708" + "1234" + "aabb")
        let final = try Fragment(id: 1, fragmentNum: 0, isFinal: true, contents: [])
        XCTAssertEqual(hex(final.serialized()), "0000000000000001" + "8000")
        let last = try Fragment(id: .max, fragmentNum: 0x7FFF, isFinal: true, contents: [0])
        XCTAssertEqual(hex(last.serialized()), "ffffffffffffffff" + "ffff" + "00")

        for original in [fragment, final, last] {
            XCTAssertEqual(try Fragment(serialized: original.serialized()), original)
        }
        let parsed = try Fragment(serialized: bytes(hex: "00000000000000ff" + "8003" + "010203"))
        XCTAssertEqual(parsed.id, 255)
        XCTAssertEqual(parsed.fragmentNum, 3)
        XCTAssertTrue(parsed.isFinal)
        XCTAssertEqual(parsed.contents, [1, 2, 3])
        XCTAssertEqual(Fragment.headerLength, 10)
    }

    func testFragmentRejectsBadInput() {
        // mosh: fatal_assert( x.size() >= frag_header_len )
        for length in 0..<10 {
            XCTAssertThrowsError(try Fragment(serialized: [UInt8](repeating: 0, count: length))) { error in
                XCTAssertEqual(error as? WireError, .fragmentTooShort(length))
            }
        }
        XCTAssertNoThrow(try Fragment(serialized: [UInt8](repeating: 0, count: 10)))
        // mosh: fatal_assert( !( fragment_num & 0x8000 ) )
        XCTAssertThrowsError(try Fragment(id: 1, fragmentNum: 0x8000, isFinal: false, contents: [])) { error in
            XCTAssertEqual(error as? WireError, .fragmentNumberOutOfRange(0x8000))
        }
        XCTAssertThrowsError(try Fragment(id: 1, fragmentNum: -1, isFinal: false, contents: []))
    }

    // MARK: Fragmenter

    func testSmallInstructionIsOneFinalFragment() throws {
        let instruction = smallInstruction(newNum: 1)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: 1214)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].id, 1)
        XCTAssertEqual(fragments[0].fragmentNum, 0)
        XCTAssertTrue(fragments[0].isFinal)
        XCTAssertEqual(fragments[0].contents, try Compressor.compress(instruction.serialized()))

        var assembly = FragmentAssembly()
        XCTAssertTrue(try assembly.add(fragments[0]))
        XCTAssertEqual(try assembly.takeInstruction(), instruction)
    }

    func testFragmenterCutsAtTheBudget() throws {
        let instruction = bigInstruction(diffLength: 5000)
        let compressed = try Compressor.compress(instruction.serialized())
        for budget in [1, 7, 100, 462, 1178, 1214, compressed.count - 1, compressed.count, compressed.count + 1] {
            let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 42, contentsBudget: budget)
            XCTAssertEqual(fragments.count, (compressed.count + budget - 1) / budget, "budget \(budget)")
            for (index, fragment) in fragments.enumerated() {
                XCTAssertEqual(fragment.id, 42)
                XCTAssertEqual(Int(fragment.fragmentNum), index)
                XCTAssertEqual(fragment.isFinal, index == fragments.count - 1)
                // Every fragment but the last is full; the last is not empty.
                if index < fragments.count - 1 {
                    XCTAssertEqual(fragment.contents.count, budget)
                } else {
                    XCTAssertGreaterThan(fragment.contents.count, 0)
                    XCTAssertLessThanOrEqual(fragment.contents.count, budget)
                }
            }
            XCTAssertEqual(fragments.flatMap(\.contents), compressed)
        }
    }

    func testFragmenterLimits() throws {
        let instruction = bigInstruction(diffLength: 40_000)
        XCTAssertThrowsError(try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: 0)) { error in
            XCTAssertEqual(error as? WireError, .fragmentBudgetTooSmall(0))
        }
        XCTAssertThrowsError(try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: -5))
        // More than 32768 fragments cannot be numbered.
        XCTAssertThrowsError(try Fragmenter.makeFragments(instruction: instruction, id: 1, contentsBudget: 1)) { error in
            guard case .tooManyFragments? = error as? WireError else { return XCTFail("\(error)") }
        }
        // Exactly 32768 fragments can.
        let payload = [UInt8](repeating: 9, count: 32768)
        let most = try Fragmenter.split(compressed: payload, id: 1, contentsBudget: 1)
        XCTAssertEqual(most.count, 32768)
        XCTAssertEqual(most.last?.fragmentNum, 0x7FFF)
        XCTAssertEqual(most.last?.isFinal, true)
        XCTAssertThrowsError(try Fragmenter.split(compressed: payload + [9], id: 1, contentsBudget: 1))
        // mosh: an empty payload gives no fragments.
        XCTAssertEqual(try Fragmenter.split(compressed: [], id: 1, contentsBudget: 100), [])
    }

    // MARK: Round trips

    func testMultiFragmentRoundTripInOrder() throws {
        let instruction = bigInstruction(diffLength: 6000)
        // The three budgets a client uses: IPv4, IPv6, and the fallback MTU of 500.
        for datagramMTU in [WireConstants.ipv4DatagramMTU, WireConstants.ipv6DatagramMTU, WireConstants.defaultSendMTU] {
            let budget = WireConstants.fragmentContentsBudget(datagramMTU: datagramMTU)
            let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 9, contentsBudget: budget)
            XCTAssertGreaterThan(fragments.count, 4)
            var assembly = FragmentAssembly()
            let results = try feed(&assembly, fragments)
            XCTAssertEqual(results, [Bool](repeating: false, count: fragments.count - 1) + [true])
            XCTAssertTrue(assembly.isComplete)
            XCTAssertEqual(try assembly.takeInstruction(), instruction)
            XCTAssertFalse(assembly.isComplete)
        }
    }

    func testFragmentsSurviveSerialization() throws {
        let instruction = bigInstruction(diffLength: 3000)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 77, contentsBudget: 462)
        var assembly = FragmentAssembly()
        var complete = false
        for fragment in fragments {
            let wire = fragment.serialized()
            XCTAssertLessThanOrEqual(wire.count, 462 + Fragment.headerLength)
            complete = try assembly.add(try Fragment(serialized: wire))
        }
        XCTAssertTrue(complete)
        XCTAssertEqual(try assembly.takeInstruction(), instruction)
    }

    func testOutOfOrderFragments() throws {
        let instruction = bigInstruction(diffLength: 4000)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 5, contentsBudget: 500)
        XCTAssertGreaterThanOrEqual(fragments.count, 8)

        // Reversed: the final fragment arrives first.
        var reversed = FragmentAssembly()
        let reversedResults = try feed(&reversed, fragments.reversed())
        XCTAssertEqual(reversedResults, [Bool](repeating: false, count: fragments.count - 1) + [true])
        XCTAssertEqual(try reversed.takeInstruction(), instruction)

        // Random orders.
        for _ in 0..<50 {
            var assembly = FragmentAssembly()
            let results = try feed(&assembly, fragments.shuffled())
            XCTAssertEqual(results, [Bool](repeating: false, count: fragments.count - 1) + [true])
            XCTAssertEqual(try assembly.takeInstruction(), instruction)
        }
    }

    func testDuplicateFragments() throws {
        let instruction = bigInstruction(diffLength: 2500)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 5, contentsBudget: 500)
        XCTAssertGreaterThanOrEqual(fragments.count, 5)
        let last = fragments.count - 1

        var assembly = FragmentAssembly()
        // Each fragment twice, the final one before the rest and again in the middle.
        XCTAssertFalse(try assembly.add(fragments[last]))
        XCTAssertFalse(try assembly.add(fragments[last]))
        for fragment in fragments[1..<last] {
            XCTAssertFalse(try assembly.add(fragment))
            XCTAssertFalse(try assembly.add(fragment))
            XCTAssertFalse(try assembly.add(fragments[last]))
        }
        // Duplicates did not count: the instruction is complete only with the missing fragment.
        XCTAssertFalse(assembly.isComplete)
        XCTAssertThrowsError(try assembly.takeInstruction()) { error in
            XCTAssertEqual(error as? WireError, .assemblyIncomplete)
        }
    }

    func testDuplicatesThenCompletion() throws {
        let instruction = bigInstruction(diffLength: 2500)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 5, contentsBudget: 500)
        var assembly = FragmentAssembly()
        var order = fragments + fragments.dropFirst()   // all but the first, twice
        order.removeFirst()
        order.shuffle()
        for fragment in order {
            XCTAssertFalse(try assembly.add(fragment))
        }
        XCTAssertTrue(try assembly.add(fragments[0]))
        // A duplicate that arrives while the complete instruction waits still says "complete".
        XCTAssertTrue(try assembly.add(fragments[1]))
        XCTAssertEqual(try assembly.takeInstruction(), instruction)
    }

    func testNewInstructionIDMidAssemblyDiscardsTheOldOne() throws {
        let first = bigInstruction(diffLength: 3000, newNum: 2)
        let second = bigInstruction(diffLength: 3000, newNum: 3)
        let firstFragments = try Fragmenter.makeFragments(instruction: first, id: 10, contentsBudget: 500)
        let secondFragments = try Fragmenter.makeFragments(instruction: second, id: 11, contentsBudget: 500)
        XCTAssertGreaterThanOrEqual(firstFragments.count, 6)

        var assembly = FragmentAssembly()
        // All of the first instruction but its last fragment.
        for fragment in firstFragments.dropLast() {
            XCTAssertFalse(try assembly.add(fragment))
        }
        // The second instruction starts: the first is forgotten.
        XCTAssertFalse(try assembly.add(secondFragments[0]))
        // The missing fragment of the first instruction arrives late. Its id differs from the
        // current one again, so it starts a new assembly of its own and discards the second.
        XCTAssertFalse(try assembly.add(firstFragments[firstFragments.count - 1]))
        XCTAssertFalse(assembly.isComplete)
        // The second instruction, complete, in order.
        let results = try feed(&assembly, secondFragments)
        XCTAssertEqual(results.last, true)
        XCTAssertEqual(results.dropLast().contains(true), false)
        XCTAssertEqual(try assembly.takeInstruction(), second)
    }

    func testOlderIDAlsoStartsANewAssembly() throws {
        // mosh compares ids for inequality only: a lower id replaces a higher one.
        let old = smallInstruction(newNum: 5)
        let new = bigInstruction(diffLength: 3000, newNum: 6)
        let oldFragments = try Fragmenter.makeFragments(instruction: old, id: 3, contentsBudget: 500)
        let newFragments = try Fragmenter.makeFragments(instruction: new, id: 4, contentsBudget: 500)
        var assembly = FragmentAssembly()
        XCTAssertFalse(try assembly.add(newFragments[0]))
        XCTAssertTrue(try assembly.add(oldFragments[0]))
        XCTAssertEqual(try assembly.takeInstruction(), old)
    }

    func testInterleavedSingleFragmentInstructions() throws {
        var assembly = FragmentAssembly()
        for number in 1...20 as ClosedRange<UInt64> {
            let instruction = smallInstruction(newNum: number)
            let fragments = try Fragmenter.makeFragments(instruction: instruction, id: number, contentsBudget: 1214)
            XCTAssertEqual(fragments.count, 1)
            XCTAssertTrue(try assembly.add(fragments[0]))
            XCTAssertEqual(try assembly.takeInstruction(), instruction)
        }
    }

    /// mosh keeps the current id after `get_assembly`. A retransmission with the same id therefore
    /// assembles again from nothing, and the instruction is delivered a second time.
    func testRetransmissionWithTheSameIDCompletesAgain() throws {
        let single = smallInstruction(newNum: 4)
        let singleFragment = try Fragmenter.makeFragments(instruction: single, id: 8, contentsBudget: 1214)[0]
        var assembly = FragmentAssembly()
        XCTAssertTrue(try assembly.add(singleFragment))
        XCTAssertEqual(try assembly.takeInstruction(), single)
        XCTAssertTrue(try assembly.add(singleFragment))
        XCTAssertEqual(try assembly.takeInstruction(), single)

        let multi = bigInstruction(diffLength: 2000)
        let fragments = try Fragmenter.makeFragments(instruction: multi, id: 9, contentsBudget: 500)
        XCTAssertEqual(try feed(&assembly, fragments).last, true)
        XCTAssertEqual(try assembly.takeInstruction(), multi)
        // One stray duplicate of the completed instruction is not an instruction.
        XCTAssertFalse(try assembly.add(fragments[1]))
        XCTAssertThrowsError(try assembly.takeInstruction())
        // All of them again are.
        XCTAssertFalse(try assembly.add(fragments[0]))
        for fragment in fragments.dropFirst(2).dropLast() {
            XCTAssertFalse(try assembly.add(fragment))
        }
        XCTAssertTrue(try assembly.add(fragments[fragments.count - 1]))
        XCTAssertEqual(try assembly.takeInstruction(), multi)
    }

    func testFirstFragmentIDCanBeAnything() throws {
        // mosh's assembly starts with current_id = -1 (2^64 - 1). A first instruction with that
        // very id still assembles.
        for id in [UInt64.max, 0, 1] {
            let instruction = bigInstruction(diffLength: 1500)
            let fragments = try Fragmenter.makeFragments(instruction: instruction, id: id, contentsBudget: 500)
            var assembly = FragmentAssembly()
            XCTAssertEqual(try feed(&assembly, fragments.shuffled()).last, true)
            XCTAssertEqual(try assembly.takeInstruction(), instruction)
        }
    }

    // MARK: Input that trips an assertion in mosh

    func testConflictingDuplicateIsRejectedAndChangesNothing() throws {
        let instruction = bigInstruction(diffLength: 2000)
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: 6, contentsBudget: 500)
        var assembly = FragmentAssembly()
        XCTAssertFalse(try assembly.add(fragments[0]))
        XCTAssertFalse(try assembly.add(fragments[1]))

        // Same id and number, other contents.
        let impostor = try Fragment(id: 6, fragmentNum: 1, isFinal: false, contents: [1, 2, 3])
        XCTAssertThrowsError(try assembly.add(impostor)) { error in
            XCTAssertEqual(error as? WireError, .conflictingFragment(id: 6, fragmentNum: 1))
        }
        // Same id, number and contents, but marked final.
        let wronglyFinal = try Fragment(id: 6, fragmentNum: 1, isFinal: true, contents: fragments[1].contents)
        XCTAssertThrowsError(try assembly.add(wronglyFinal)) { error in
            XCTAssertEqual(error as? WireError, .conflictingFragment(id: 6, fragmentNum: 1))
        }
        // The assembly is intact.
        XCTAssertEqual(try feed(&assembly, Array(fragments.dropFirst(2))).last, true)
        XCTAssertEqual(try assembly.takeInstruction(), instruction)
    }

    func testFinalFragmentBelowAHeldFragmentIsRejected() throws {
        var assembly = FragmentAssembly()
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 3, isFinal: false, contents: [3])))
        // "Final" at number 1 while fragment 3 is held: mosh asserts fragments.size() <= fragments_total.
        XCTAssertThrowsError(try assembly.add(try Fragment(id: 6, fragmentNum: 1, isFinal: true, contents: [1]))) { error in
            XCTAssertEqual(error as? WireError, .fragmentOutOfRange(id: 6, fragmentNum: 1))
        }
        // Unchanged: the real fragments still assemble.
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 0, isFinal: false, contents: [0])))
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 1, isFinal: false, contents: [1])))
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 2, isFinal: false, contents: [2])))
        XCTAssertTrue(try assembly.add(try Fragment(id: 6, fragmentNum: 4, isFinal: true, contents: [4])))
        XCTAssertEqual(try assembly.takeCompressed(), [0, 1, 2, 3, 4])
    }

    func testTooManyFragmentsForTheAnnouncedTotalIsRejected() throws {
        var assembly = FragmentAssembly()
        // Total is 2.
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 1, isFinal: true, contents: [1])))
        // A fragment numbered past the total is counted by mosh; it makes the count reach the total
        // while fragment 0 is missing.
        XCTAssertTrue(try assembly.add(try Fragment(id: 6, fragmentNum: 5, isFinal: false, contents: [5])))
        // mosh would then trip assert( fragments.at( i ).initialized ) in get_assembly.
        XCTAssertThrowsError(try assembly.takeCompressed()) { error in
            XCTAssertEqual(error as? WireError, .assemblyIncomplete)
        }
        // Taking resets: the same instruction can still arrive properly.
        XCTAssertFalse(try assembly.add(try Fragment(id: 6, fragmentNum: 0, isFinal: false, contents: [0])))
        XCTAssertTrue(try assembly.add(try Fragment(id: 6, fragmentNum: 1, isFinal: true, contents: [1])))
        XCTAssertEqual(try assembly.takeCompressed(), [0, 1])

        // One fragment more than the total: mosh asserts fragments_arrived <= fragments_total.
        var second = FragmentAssembly()
        XCTAssertFalse(try second.add(try Fragment(id: 7, fragmentNum: 0, isFinal: false, contents: [0])))
        XCTAssertTrue(try second.add(try Fragment(id: 7, fragmentNum: 1, isFinal: true, contents: [1])))
        XCTAssertThrowsError(try second.add(try Fragment(id: 7, fragmentNum: 2, isFinal: false, contents: [2]))) { error in
            XCTAssertEqual(error as? WireError, .fragmentOutOfRange(id: 7, fragmentNum: 2))
        }
        XCTAssertEqual(try second.takeCompressed(), [0, 1])
    }

    func testTakingBeforeCompletionThrows() throws {
        var assembly = FragmentAssembly()
        XCTAssertFalse(assembly.isComplete)
        XCTAssertThrowsError(try assembly.takeInstruction()) { error in
            XCTAssertEqual(error as? WireError, .assemblyIncomplete)
        }
        XCTAssertFalse(try assembly.add(try Fragment(id: 1, fragmentNum: 0, isFinal: false, contents: [1])))
        XCTAssertThrowsError(try assembly.takeCompressed())
    }

    func testDamagedContentsThrowAndTheAssemblyRecovers() throws {
        var assembly = FragmentAssembly()
        // Complete, but not zlib.
        XCTAssertTrue(try assembly.add(try Fragment(id: 1, fragmentNum: 0, isFinal: true, contents: Array("not zlib".utf8))))
        XCTAssertThrowsError(try assembly.takeInstruction()) { error in
            guard case .decompressionFailed? = error as? WireError else { return XCTFail("\(error)") }
        }
        // zlib, but not an Instruction (a lone tag byte).
        let garbage = try Compressor.compress([0x08])
        XCTAssertTrue(try assembly.add(try Fragment(id: 2, fragmentNum: 0, isFinal: true, contents: garbage)))
        XCTAssertThrowsError(try assembly.takeInstruction()) { error in
            XCTAssertEqual(error as? ProtoError, .truncated)
        }
        // A good instruction afterwards.
        let instruction = smallInstruction(newNum: 9)
        let fragment = try Fragmenter.makeFragments(instruction: instruction, id: 3, contentsBudget: 1214)[0]
        XCTAssertTrue(try assembly.add(fragment))
        XCTAssertEqual(try assembly.takeInstruction(), instruction)
    }
}
