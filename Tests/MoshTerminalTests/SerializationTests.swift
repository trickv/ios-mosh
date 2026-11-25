// Tests of the serialized terminal state (Sources/MoshTerminal/Serialization.swift).

import XCTest
@testable import MoshTerminal

final class SerializationTests: XCTestCase {
    private func caseCount(_ standard: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["MOSH_FUZZ_CASES"], let n = Int(s), n > 0 { return n }
        return standard
    }

    /// Structural equality, the same sharing of row objects between lines, the same
    /// generation numbers, and the same bytes when serialized again.
    private func assertSame(_ reloaded: TerminalState, _ original: TerminalState, _ label: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard reloaded == original else {
            XCTFail("\(label()): reloaded state differs\n" + MoshRefText.firstDifference(original.debugDump(), reloaded.debugDump()),
                    file: file, line: line)
            return
        }
        let a = original.framebuffer.rows
        let b = reloaded.framebuffer.rows
        for y in a.indices {
            XCTAssertEqual(a[y].gen, b[y].gen, "\(label()): generation of line \(y)", file: file, line: line)
            for z in 0..<y where (a[y] === a[z]) != (b[y] === b[z]) {
                XCTFail("\(label()): lines \(z) and \(y) share a row in one state only", file: file, line: line)
            }
        }
    }

    private func reload(_ s: TerminalState, _ label: @autoclosure () -> String,
                        file: StaticString = #filePath, line: UInt = #line) -> TerminalState {
        let blob = s.serialized()
        do {
            let r = try TerminalState(serialized: blob)
            XCTAssertEqual(r.serialized(), blob, "\(label()): serializing the reloaded state gives other bytes", file: file, line: line)
            return r
        } catch {
            XCTFail("\(label()): a serialized state was rejected: \(error)", file: file, line: line)
            return s
        }
    }

    // MARK: Round trip

    /// Every state of generated histories survives the round trip, and a terminal that
    /// is reloaded after every piece of input ends up like one that never was. The
    /// pieces are cut at random bytes, so states in the middle of escape sequences and
    /// of multi-byte characters are saved and reloaded all the time.
    func testRoundTripAndContinuation() {
        var states = 0
        var midSequence = 0
        var midCharacter = 0
        for seed in UInt64(40_001)...UInt64(40_000 + caseCount(120)) {
            var scenario = DiffScenario(seed: seed)
            var original = TerminalState(width: scenario.width, height: scenario.height)
            var reloaded = original
            var previous = original
            var previousReloaded = original
            for step in 0..<16 {
                for op in scenario.step() {
                    guard case .bytes(let bytes) = op else {
                        DiffScenario.apply([op], to: &original)
                        DiffScenario.apply([op], to: &reloaded)
                        reloaded = reload(reloaded, "seed \(seed) step \(step)")
                        continue
                    }
                    // feed in two or three pieces, reloading one terminal in between
                    var cuts = [0, bytes.count]
                    for _ in 0..<(1 + scenario.fuzz.int(2)) where bytes.count > 1 { cuts.append(1 + scenario.fuzz.int(bytes.count - 1)) }
                    cuts.sort()
                    for i in 1..<cuts.count where cuts[i] > cuts[i - 1] {
                        let piece = bytes[cuts[i - 1]..<cuts[i]]
                        let r1 = original.act(piece)
                        let r2 = reloaded.act(piece)
                        XCTAssertEqual(r1, r2, "seed \(seed) step \(step): replies differ")
                        if reloaded.parser.parser.state != .ground { midSequence += 1 }
                        if reloaded.parser.bufLen != 0 { midCharacter += 1 }
                        reloaded = reload(reloaded, "seed \(seed) step \(step)")
                        states += 1
                    }
                }
                // The twin made its own rows, so its generation numbers are its own; the
                // contents and the pattern of shared rows are the original's.
                XCTAssertTrue(reloaded == original, "seed \(seed) step \(step):\n"
                    + MoshRefText.firstDifference(original.debugDump(), reloaded.debugDump()))

                // The original itself, reloaded: generations too, and a diff between two
                // reloaded states has the bytes of the diff between the originals.
                let currentReloaded = reload(original, "seed \(seed) step \(step)")
                assertSame(currentReloaded, original, "seed \(seed) step \(step)")
                let want = DisplayDiff.newFrame(initialized: true, from: previous.framebuffer, to: original.framebuffer)
                let got = DisplayDiff.newFrame(initialized: true, from: previousReloaded.framebuffer, to: currentReloaded.framebuffer)
                XCTAssertEqual(got, want, "seed \(seed) step \(step): newFrame between reloaded states")
                previous = original
                previousReloaded = currentReloaded
            }
        }
        print("Serialization: \(states) states reloaded, \(midSequence) of them inside an escape sequence, "
            + "\(midCharacter) inside a multi-byte character")
        XCTAssertGreaterThan(midSequence, 200)
        XCTAssertGreaterThan(midCharacter, 50)
    }

    /// One input with every kind of sequence, cut at every byte.
    func testReloadAtEveryByte() {
        let input = Array(("plain \u{1B}[1;38;5;196;48;2;1;2;3mcolour\u{1B}[m \u{1B}]0;title ✓\u{7}\u{1B}]52;c;aGk=\u{1B}\\"
            + "wide 日本 🙂 e\u{301}\u{308} \u{301}x\r\n\u{1B}[2;5r\u{1B}[?6h\u{1B}[3;4H\u{1B}7\u{1B}[4h\u{1B}[?7l"
            + "\u{1B}P1;2$qdcs\u{1B}\\\u{1B}[6n\u{1B}[c\u{1B}H\t\u{1B}[3g\u{1B}8\u{1B}[?1000;1006;2004h"
            + "\u{1B}(0\u{1B}#8\u{9B}5Cé\u{1B}[!p\u{1B}[10;10Hend").utf8)
        var whole = TerminalState(width: 20, height: 6)
        let wholeReply = whole.act(input)
        XCTAssertFalse(wholeReply.isEmpty)
        for cut in 0...input.count {
            var s = TerminalState(width: 20, height: 6)
            var reply = s.act(input[..<cut])
            s = reload(s, "cut at \(cut)")
            reply += s.act(input[cut...])
            XCTAssertEqual(reply, wholeReply, "cut at \(cut)")
            XCTAssertTrue(s == whole, "cut at \(cut):\n" + MoshRefText.firstDifference(whole.debugDump(), s.debugDump()))
        }
    }

    /// Server-side fields are part of the state too.
    func testEchoAckInputHistoryAndUserInputState() {
        var s = TerminalState(width: 10, height: 3)
        s.registerInputFrame(7, now: 1000)
        s.registerInputFrame(9, now: 1040)
        _ = s.setEchoAck(now: 1060)
        s.actUserByte(0x1B)
        s.actUserByte(0x4F)
        XCTAssertEqual(s.terminal.user.state, .ss3)
        let r = reload(s, "server-side state")
        assertSame(r, s, "server-side state")
        XCTAssertEqual(r.echoAck, s.echoAck)
        XCTAssertEqual(r.inputHistory, s.inputHistory)
        XCTAssertFalse(r.inputHistory.isEmpty)

        var big = TerminalState(width: 3, height: 1)
        big.applyEchoAck(UInt64.max)
        XCTAssertEqual(reload(big, "largest echo ack").echoAck, UInt64.max)
    }

    // MARK: Format

    /// The format is pinned: these bytes are version 1 of a 4x2 screen showing "A".
    func testVersion1Bytes() throws {
        let golden: [UInt8] = [
            0x01, // version
            0x14, // autowrap, cursor visible
            0x24, // default tabs, saved autowrap
            0x04, 0x02, // 4 columns, 2 lines
            0x01, 0x00, // cursor column 1, row 0
            0x00, 0x00, // combining character at (0, 0)
            0x00, 0x01, // scrolling region 0...1
            0x00, 0x00, 0x00, // pen
            0x00, 0x00, 0x00, 0x00, 0x00, // saved cursor (0, 0), default rendition
            0x00, 0x00, // no mouse reporting, default mouse encoding
            0x00, // bell count
            0x00, 0x00, 0x00, // icon name, window title, clipboard
            0x00, // echo ack
            0x00, // input history
            0x00, 0x00, // parser in Ground, no incomplete character
            0x00, 0x00, 0x00, 0x00, 0x00, // params, parsed params, intermediates, OSC string, reply
            0x00, // user input in Ground
            0x00, 0x04, 0x05, 0x41, 0x01, 0x03, // line 0: a new row, 4 wide, generation 5: "A", 3 empty cells
            0x00, 0x04, 0x05, 0x01, 0x04, // line 1: a new row, 4 wide, generation 5: 4 empty cells
        ]
        let decoded = try TerminalState(serialized: golden)
        var expected = TerminalState(width: 4, height: 2)
        expected.act([0x41])
        XCTAssertTrue(decoded == expected, MoshRefText.firstDifference(expected.debugDump(), decoded.debugDump()))
        XCTAssertEqual(decoded.debugDump(), expected.debugDump())
        XCTAssertEqual(decoded.framebuffer.rows.map { $0.gen }, [5, 5])
        XCTAssertFalse(decoded.framebuffer.rows[0] === decoded.framebuffer.rows[1])
        XCTAssertEqual(decoded.serialized(), golden)
        XCTAssertEqual(TerminalSerialization.version, 1)

        // the same screen with both lines one row object
        var shared = Array(golden[..<35])
        shared += [0x00, 0x04, 0x07, 0x01, 0x04, 0x01]
        let blank = try TerminalState(serialized: shared)
        XCTAssertTrue(blank.framebuffer.rows[0] === blank.framebuffer.rows[1])
        XCTAssertEqual(blank.framebuffer.rows[0].gen, 7)
        // a row made after loading has a generation above every loaded one
        XCTAssertGreaterThan(Row(width: 1, backgroundColor: 0).gen, 7)
    }

    func testSizes() throws {
        let blank = TerminalState(width: 80, height: 24)
        let blankSize = blank.serialized().count
        XCTAssertLessThan(blankSize, 100)

        // a screen as an editor paints it: line numbers, coloured words, a status line
        var editor = TerminalState(width: 80, height: 24)
        var fuzz = TerminalFuzz(seed: 7)
        var s = "\u{1B}]0;vim Package.swift\u{7}\u{1B}[H"
        for y in 0..<23 {
            s += "\u{1B}[\(y + 1);1H\u{1B}[38;5;130m\(String(repeating: " ", count: y < 9 ? 2 : 1))\(y + 1) \u{1B}[m"
            var column = 4
            while column < 72 {
                let n = 2 + fuzz.int(9)
                if fuzz.chance(30) { s += "\u{1B}[38;5;\(fuzz.int(256))m" }
                for _ in 0..<n { s.unicodeScalars.append(Unicode.Scalar(UInt8(0x61 + fuzz.int(26)))) }
                s += "\u{1B}[m "
                column += n + 1
            }
        }
        s += "\u{1B}[24;1H\u{1B}[7mPackage.swift [+]                                             12,34         All\u{1B}[m"
        editor.act(Array(s.utf8))
        let editorBlob = editor.serialized()
        XCTAssertLessThan(editorBlob.count, 4096)
        XCTAssertTrue(try TerminalState(serialized: editorBlob) == editor)

        // every cell a different wide character with its own colours
        var dense = TerminalState(width: 80, height: 24)
        var d = ""
        for i in 0..<(40 * 24) {
            d += "\u{1B}[38;2;\(i % 256);\(i / 7 % 256);9;48;5;\(i % 255)m"
            d.unicodeScalars.append(Unicode.Scalar(UInt32(0x4E00 + i))!)
        }
        dense.act(Array(d.utf8))
        let denseSize = dense.serialized().count
        XCTAssertLessThan(denseSize, 24 * 1024)
        print("Serialization: blank 80x24 is \(blankSize) bytes, an editor screen \(editorBlob.count) bytes, "
            + "960 wide characters each in its own colours \(denseSize) bytes")
    }

    func testVersionTruncationAndTrailingBytes() {
        var s = TerminalState(width: 12, height: 4)
        s.act(Array("héllo \u{1B}[31mred 日本\r\n\u{1B}]2;t\u{7}\u{1B}[5".utf8))
        let blob = s.serialized()

        XCTAssertThrowsError(try TerminalState(serialized: [])) {
            XCTAssertEqual($0 as? TerminalSerializationError, .truncated)
        }
        var other = blob
        other[0] = 2
        XCTAssertThrowsError(try TerminalState(serialized: other)) {
            XCTAssertEqual($0 as? TerminalSerializationError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try TerminalState(serialized: blob + [0])) {
            XCTAssertEqual($0 as? TerminalSerializationError, .trailingBytes)
        }
        // every proper prefix is rejected
        for n in 0..<blob.count {
            XCTAssertThrowsError(try TerminalState(serialized: Array(blob[..<n])), "prefix of \(n) bytes") {
                XCTAssertTrue($0 is TerminalSerializationError)
            }
        }
    }

    // MARK: Rows on their own

    /// What a snapshot writer does: the skeleton of each state, and every distinct row
    /// stored once and given back as one object to all the states that had it.
    func testRowsSharedBetweenStates() throws {
        var total = 0
        var stored = 0
        for seed in UInt64(50_001)...UInt64(50_040) {
            var scenario = DiffScenario(seed: seed)
            var server = TerminalState(width: scenario.width, height: scenario.height)
            var held: [TerminalState] = [server]
            for _ in 0..<6 {
                for _ in 0..<(1 + scenario.fuzz.int(2)) { DiffScenario.apply(scenario.step(), to: &server) }
                held.append(server)
            }

            // write
            var table: [[UInt8]] = []
            var index: [[UInt8]: Int] = [:]
            var skeletons: [[UInt8]] = []
            var lines: [[Int]] = []
            for state in held {
                skeletons.append(state.serializedWithoutRows())
                var refs: [Int] = []
                for row in state.framebuffer.rows {
                    let bytes = row.serialized()
                    total += 1
                    if let i = index[bytes] {
                        refs.append(i)
                    } else {
                        index[bytes] = table.count
                        refs.append(table.count)
                        table.append(bytes)
                        stored += 1
                    }
                }
                lines.append(refs)
            }

            // read
            let widths = held.map { $0.framebuffer.ds.width }
            var rows: [Row?] = Array(repeating: nil, count: table.count)
            var loaded: [TerminalState] = []
            for (n, skeleton) in skeletons.enumerated() {
                var stateRows: [Row] = []
                for i in lines[n] {
                    if rows[i] == nil { rows[i] = try Row(serialized: table[i], width: widths[n]) }
                    stateRows.append(rows[i]!)
                }
                loaded.append(try TerminalState(serializedWithoutRows: skeleton, rows: stateRows))
            }

            for n in held.indices {
                XCTAssertTrue(loaded[n] == held[n], "seed \(seed) state \(n)")
                for y in held[n].framebuffer.rows.indices {
                    XCTAssertEqual(loaded[n].framebuffer.rows[y].gen, held[n].framebuffer.rows[y].gen)
                }
                if n > 0 {
                    // rows shared between two states before are shared again
                    let (a0, b0) = (held[n - 1].framebuffer.rows, held[n].framebuffer.rows)
                    let (a1, b1) = (loaded[n - 1].framebuffer.rows, loaded[n].framebuffer.rows)
                    for y in 0..<min(a0.count, b0.count) where a0[y] === b0[y] {
                        XCTAssertTrue(a1[y] === b1[y], "seed \(seed) states \(n - 1) and \(n) line \(y)")
                    }
                    XCTAssertEqual(DisplayDiff.newFrame(initialized: true, from: loaded[n - 1].framebuffer, to: loaded[n].framebuffer),
                                   DisplayDiff.newFrame(initialized: true, from: held[n - 1].framebuffer, to: held[n].framebuffer),
                                   "seed \(seed) diff \(n - 1) -> \(n)")
                }
            }
        }
        print("Serialization: \(total) lines in held states stored as \(stored) rows")
        XCTAssertLessThan(stored, total / 2)
    }

    func testRowErrors() throws {
        var s = TerminalState(width: 6, height: 2)
        s.act(Array("a日\u{301}".utf8))
        let row = s.framebuffer.rows[0]
        let bytes = row.serialized()
        let back = try Row(serialized: bytes)
        XCTAssertEqual(back.cells, row.cells)
        XCTAssertEqual(back.gen, row.gen)
        XCTAssertTrue(back.moshEquals(row))
        XCTAssertNoThrow(try Row(serialized: bytes, width: 6))
        XCTAssertThrowsError(try Row(serialized: bytes, width: 7))
        XCTAssertThrowsError(try Row(serialized: bytes + [0x20])) {
            XCTAssertEqual($0 as? TerminalSerializationError, .trailingBytes)
        }
        for n in 0..<bytes.count {
            XCTAssertThrowsError(try Row(serialized: Array(bytes[..<n])))
        }

        let skeleton = s.serializedWithoutRows()
        XCTAssertNoThrow(try TerminalState(serializedWithoutRows: skeleton, rows: s.framebuffer.rows))
        XCTAssertThrowsError(try TerminalState(serializedWithoutRows: skeleton, rows: [row]))
        XCTAssertThrowsError(try TerminalState(serializedWithoutRows: skeleton, rows: [row, Row(width: 5, backgroundColor: 0)]))
        XCTAssertThrowsError(try TerminalState(serializedWithoutRows: skeleton + [0], rows: s.framebuffer.rows))
        // the full form is the skeleton followed by the rows
        XCTAssertEqual(Array(s.serialized().prefix(skeleton.count)), skeleton)
    }

    // MARK: Damaged input

    /// Use a decoded state the way the app would: any broken invariant traps here.
    private func exercise(_ decoded: TerminalState) {
        var s = decoded
        _ = s.debugDump()
        let fresh = TerminalState(width: s.framebuffer.ds.width, height: s.framebuffer.ds.height)
        _ = DisplayDiff.newFrame(initialized: true, from: fresh.framebuffer, to: s.framebuffer)
        _ = DisplayDiff.newFrame(initialized: true, from: s.framebuffer, to: fresh.framebuffer)
        _ = DisplayDiff.newFrame(initialized: false, from: s.framebuffer, to: s.framebuffer)
        _ = s.diff(from: decoded)
        let again = s.serialized()
        if let back = try? TerminalState(serialized: again) {
            XCTAssertTrue(back == s, "a decoded state does not survive its own round trip")
        } else {
            XCTFail("a decoded state serializes to bytes the decoder rejects")
        }
        let h = s.framebuffer.ds.height
        let input = "1;2H3;4mx\u{7}\u{1B}\\y\u{301}\u{80}\u{BF}\t\u{1B}8z\u{1B}[r" + String(repeating: "\n", count: min(h, 50) + 1)
            + "日本\u{1B}[3g\u{1B}H\u{1B}[?6h\u{1B}[2;3r\u{1B}M\u{1B}[5@\u{1B}[2P\u{1B}[4L\u{1B}[3M\u{1B}[9X\u{1B}[1J\u{1B}[6n"
            + "\u{1B}[I\u{1B}[Z\u{1B}[4h wide 日 \u{1B}[?7l\u{1B}[999C漢\u{1B}7\u{1B}c\u{1B}[!p"
        s.act(Array(input.utf8))
        s.actUserByte(0x1B)
        s.resize(width: 3, height: 2)
        s.act(Array("\u{301}abc日\u{1B}8\t".utf8))
        s.resize(width: 9, height: 5)
        s.act(Array("\u{301}\u{1B}8\tq".utf8))
        _ = s.debugDump()
        _ = s.serialized()
    }

    /// 10,000 damaged blobs: the decoder throws its own error or returns a state that
    /// can be used; it never traps.
    func testDamagedInputNeverTraps() {
        // valid blobs of many kinds of state
        var blobs: [[UInt8]] = []
        for seed in UInt64(60_001)...UInt64(60_060) {
            var scenario = DiffScenario(seed: seed)
            var s = TerminalState(width: scenario.width, height: scenario.height)
            for _ in 0..<(2 + scenario.fuzz.int(20)) { DiffScenario.apply(scenario.step(), to: &s) }
            if scenario.fuzz.chance(50) { s.act(scenario.fuzz.chunk(scenario.width, scenario.height).prefix(3)) }
            blobs.append(s.serialized())
        }

        var fuzz = TerminalFuzz(seed: 99)
        var rejected = 0
        var accepted = 0
        var acceptedChanged = 0
        let total = max(10_000, caseCount(10_000))
        for n in 0..<total {
            let original = fuzz.pick(blobs)
            var blob = original
            switch fuzz.int(10) {
            case 0:
                blob = Array(blob.prefix(fuzz.int(blob.count)))
            case 1:
                blob.remove(at: fuzz.int(blob.count))
            case 2:
                blob.insert(UInt8(truncatingIfNeeded: fuzz.next()), at: fuzz.int(blob.count + 1))
            case 3:
                // a length or coordinate becomes huge
                let at = fuzz.int(blob.count)
                blob.replaceSubrange(at..<(at + 1), with: [0xFF, 0xFF, 0xFF, 0xFF, UInt8(fuzz.int(256))])
            case 4:
                // damage in the fixed part, where every byte is a field
                for _ in 0..<(1 + fuzz.int(2)) { blob[fuzz.int(min(blob.count, 40))] = UInt8(truncatingIfNeeded: fuzz.next()) }
            case 5:
                // a piece of another state
                let other = fuzz.pick(blobs)
                let at = fuzz.int(blob.count)
                blob = Array(blob[..<at]) + Array(other[min(at, other.count)...])
            case 6:
                blob[fuzz.int(blob.count)] ^= UInt8(1) << UInt8(fuzz.int(8))
            default:
                for _ in 0..<(1 + fuzz.int(4)) { blob[fuzz.int(blob.count)] = UInt8(truncatingIfNeeded: fuzz.next()) }
            }
            do {
                let state = try TerminalState(serialized: blob)
                accepted += 1
                if blob != original { acceptedChanged += 1 }
                exercise(state)
            } catch is TerminalSerializationError {
                rejected += 1
            } catch {
                XCTFail("blob \(n): unexpected error \(error)")
            }
            // rows on their own
            if n % 4 == 0 {
                let piece = Array(blob.suffix(fuzz.int(min(blob.count, 60) + 1)))
                if let row = try? Row(serialized: piece) {
                    XCTAssertEqual(try? Row(serialized: row.serialized()).cells, row.cells)
                }
            }
        }
        print("Serialization: \(total) damaged blobs, \(rejected) rejected, \(accepted) decoded to a usable state "
            + "(\(acceptedChanged) of those from changed bytes)")
        XCTAssertEqual(rejected + accepted, total)
        XCTAssertGreaterThan(rejected, total / 4)
        XCTAssertGreaterThan(acceptedChanged, total / 20)
    }

    /// Values that are well-formed but outside the model are rejected, each by name.
    func testInvalidValuesAreRejected() throws {
        let valid = TerminalState(width: 4, height: 2).serialized()
        XCTAssertNoThrow(try TerminalState(serialized: valid))
        func rejects(_ what: String, _ change: (inout [UInt8]) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var blob = valid
            change(&blob)
            XCTAssertThrowsError(try TerminalState(serialized: blob), what, file: file, line: line) {
                XCTAssertTrue($0 is TerminalSerializationError, what, file: file, line: line)
            }
        }
        // offsets as in testVersion1Bytes
        rejects("width 0") { $0[3] = 0 }
        rejects("height 0") { $0[4] = 0 }
        rejects("width other than the rows'") { $0[3] = 5 }
        rejects("cursor column beyond the width") { $0[5] = 4 }
        rejects("cursor row beyond the height") { $0[6] = 2 }
        rejects("combining column beyond the width") { $0[7] = 8 }
        rejects("combining row -2") { $0[8] = 3 }
        rejects("scrolling region upside down") { $0[9] = 1; $0[10] = 0 }
        rejects("scrolling region beyond the height") { $0[10] = 2 }
        rejects("attribute bit 7") { $0[13] = 0x80 }
        rejects("negative saved cursor") { $0[14] = 1 }
        rejects("unknown mouse reporting mode") { $0[19] = 5 }
        rejects("unknown mouse encoding mode") { $0[20] = 7 }
        rejects("unknown parser state") { $0[27] = 14 }
        rejects("8 pending bytes") { $0[28] = 8 }
        rejects("unknown user-input state") { $0[34] = 3 }
        rejects("a surrogate in the title") { $0.replaceSubrange(23..<24, with: [0x01, 0x80, 0xB0, 0x03]) }
        rejects("a code point above U+10FFFF") { $0.replaceSubrange(23..<24, with: [0x01, 0x80, 0x80, 0x44]) }
        rejects("a screen larger than the largest size") { $0.replaceSubrange(3..<4, with: [0x80, 0x80, 0x02]) }

        // 32767 x 32767: accepted while the lines share rows, refused once the distinct
        // rows hold more than TerminalSerialization.maxCells cells
        var huge = Array(valid[..<35])
        huge.replaceSubrange(3..<5, with: [0xFF, 0xFF, 0x01, 0xFF, 0xFF, 0x01])
        let blankRow: [UInt8] = [0x00, 0xFF, 0xFF, 0x01, 0x00, 0x01, 0xFF, 0xFF, 0x01]
        var sharedRows = huge + blankRow
        for _ in 1..<32767 { sharedRows.append(0x01) }
        let big = try TerminalState(serialized: sharedRows)
        XCTAssertEqual(big.framebuffer.rows.count, 32767)
        XCTAssertTrue(big.framebuffer.rows[0] === big.framebuffer.rows[32766])
        var ownRows = huge
        for _ in 0..<40 { ownRows += blankRow }
        XCTAssertThrowsError(try TerminalState(serialized: ownRows)) {
            XCTAssertEqual($0 as? TerminalSerializationError, .invalid("too many cells"))
        }
    }
}

/// The first line where two dumps differ.
enum MoshRefText {
    static func firstDifference(_ expected: String, _ actual: String) -> String {
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<max(e.count, a.count) {
            let el = i < e.count ? String(e[i]) : "<missing>"
            let al = i < a.count ? String(a[i]) : "<missing>"
            if el != al { return "line \(i + 1):\n  want: \(el)\n  have: \(al)" }
        }
        return "no difference in the dump"
    }
}
