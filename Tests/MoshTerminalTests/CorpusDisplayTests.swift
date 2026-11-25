// The golden corpus, display side: `DisplayDiff.newFrame` and `TerminalState.diff(from:)`
// against the diffs a mosh 1.4.0 server computed (`instructions.jsonl`).
//
// The recorded diff of instruction k is `diff_from( server state old_num )` evaluated on
// server state `new_num` (Tools/mosh-oracle/README.md, "Reproducing the recorded diffs
// byte for byte"). So the exact test builds the server's states from `session.jsonl`, as
// one history, and expects every byte to be equal: `testServerDiffsEqualTheRecordedDiffs`.
//
// The client's states are not the server's (README, "Things about mosh 1.4.0 that the
// corpus shows"), so `newFrame` between two client states is a different question with
// a different answer. `testNewFrameBetweenClientStates` asks it anyway, counts the
// instructions whose bytes differ and attributes every one of them to a named piece of
// information that only the server has.

import Foundation
import XCTest
import MoshTestSupport
@testable import MoshTerminal

extension TerminalDiff {
    /// The ops of an instruction as `diff_from` writes them: at most one echo ack, then
    /// at most one resize, then at most one hostbytes. nil for any other shape.
    init?(ops: [GoldenOp]) {
        self.init()
        var stage = 0
        for op in ops {
            switch op {
            case .echoAck(let n):
                guard stage < 1 else { return nil }
                stage = 1
                echoAck = n
            case .resize(let w, let h):
                guard stage < 2 else { return nil }
                stage = 2
                resize = Size(width: w, height: h)
            case .hostBytes(let b):
                guard stage < 3 else { return nil }
                stage = 3
                hostBytes = b
            }
        }
    }

    var summary: String {
        var parts: [String] = []
        if let n = echoAck { parts.append("echo_ack \(n)") }
        if let r = resize { parts.append("resize [\(r.width), \(r.height)]") }
        if let b = hostBytes { parts.append("hostbytes (\(b.count) bytes) \(CorpusComparison.escaped(b))") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }
}

final class CorpusDisplayTests: XCTestCase {
    func cases() throws -> [GoldenCase] {
        return try CorpusTests.corpus.get()
    }

    struct ServerDiffCount {
        var instructions = 0
        var emptyDiffs = 0
        var withEchoAck = 0
        var withResize = 0
        var withHostBytes = 0
        var singleHostBytes = 0
        var hostBytesTotal = 0
        /// Instructions between whose two states the icon name changed and mosh sent no
        /// host bytes. A property of the corpus, the same in every mode.
        var iconNameChangedNothingSent = 0
        /// The one class of legitimate difference of `diff(from:)` (see
        /// `testServerDiffsWhenEveryStateIsItsOwnBlob`): the port sends the titles and
        /// mosh sent nothing, or the reverse.
        var titlesSentByThePortOnly: [String] = []
        var titlesSentByMoshOnly: [String] = []
        var mismatches: [String] = []
    }

    /// What `new_frame` writes when the icon name or the window title changed.
    static func titleBytes(_ fb: Framebuffer) -> [UInt8] {
        var out: [UInt8] = []
        func osc(_ n: String, _ text: [UInt32]) {
            out += Array("\u{1B}]\(n);".utf8)
            for c in text { Cell.appendUTF8(c, to: &out) }
            out.append(0x07)
        }
        if fb.iconName == fb.windowTitle {
            osc("0", fb.windowTitle)
        } else {
            osc("1", fb.iconName)
            osc("2", fb.windowTitle)
        }
        return out
    }

    /// Build the server's states from the session and compare, for every instruction,
    /// what the port would send with what mosh sent.
    func serverDiffs(reload: CorpusReload) throws -> ServerDiffCount {
        var count = ServerDiffCount()
        for c in try cases() {
            var tally = CorpusTally()
            var caseFailed = false
            _ = try CorpusRun.server(c, reload: reload, compare: false, tally: &tally) { number, server, sent in
                let instruction = c.instructions[number - 1]
                let what = "\(c.name) instruction \(number) (old_num \(instruction.oldNum))"
                XCTAssertEqual(instruction.newNum, UInt64(number), "\(c.name): generated cases number their states 1, 2, 3")
                guard let recorded = TerminalDiff(ops: instruction.ops) else {
                    XCTFail("\(what): ops are not in the order diff_from writes them")
                    return
                }
                let base = sent[Int(instruction.oldNum)]
                count.instructions += 1
                if recorded.isEmpty { count.emptyDiffs += 1 }
                if recorded.echoAck != nil { count.withEchoAck += 1 }
                if recorded.resize != nil { count.withResize += 1 }
                if let b = recorded.hostBytes { count.withHostBytes += 1; count.hostBytesTotal += b.count }
                let iconNameChanged = base.framebuffer.iconName != server.framebuffer.iconName
                if iconNameChanged && recorded.hostBytes == nil { count.iconNameChangedNothingSent += 1 }

                // Complete::diff_from: all three instructions.
                let diff = server.diff(from: base)
                if diff != recorded {
                    // The class: nothing differs but the presence of the host bytes, the
                    // icon name changed, and the host bytes present are the titles alone.
                    var portRest = diff, moshRest = recorded
                    portRest.hostBytes = nil
                    moshRest.hostBytes = nil
                    let titles = CorpusDisplayTests.titleBytes(server.framebuffer)
                    if portRest == moshRest, iconNameChanged, diff.hostBytes == titles, recorded.hostBytes == nil {
                        count.titlesSentByThePortOnly.append(what)
                    } else if portRest == moshRest, iconNameChanged, diff.hostBytes == nil, recorded.hostBytes == titles {
                        count.titlesSentByMoshOnly.append(what)
                    } else if !caseFailed {
                        caseFailed = true
                        count.mismatches.append("\(what): diff(from:) gives \(diff.summary), mosh sent \(recorded.summary)")
                    }
                }

                // Display::new_frame alone, where the diff is nothing but its output.
                if instruction.ops.count == 1, let bytes = recorded.hostBytes {
                    count.singleHostBytes += 1
                    let frame = DisplayDiff.newFrame(initialized: true, from: base.framebuffer, to: server.framebuffer)
                    if frame != bytes, !caseFailed {
                        caseFailed = true
                        let at = zip(frame, bytes).prefix { $0 == $1 }.count
                        count.mismatches.append("\(what): newFrame differs "
                            + "from byte \(at): \(CorpusComparison.escaped(frame)), mosh sent \(CorpusComparison.escaped(bytes))")
                    }
                }
            }
        }
        return count
    }

    func report(_ title: String, _ count: ServerDiffCount) {
        print("\(title): \(count.instructions) instructions (\(count.emptyDiffs) empty, "
            + "\(count.withEchoAck) with an echo ack, \(count.withResize) with a resize, \(count.withHostBytes) with hostbytes, "
            + "\(count.hostBytesTotal) bytes); newFrame alone compared for \(count.singleHostBytes) single-hostbytes instructions; "
            + "icon name changed and nothing sent: \(count.iconNameChangedNothingSent); "
            + "titles sent by the port only: \(count.titlesSentByThePortOnly.count) \(count.titlesSentByThePortOnly); "
            + "by mosh only: \(count.titlesSentByMoshOnly.count) \(count.titlesSentByMoshOnly); "
            + "\(count.mismatches.count) cases differ")
    }

    /// Step 4b, exact: with the server's states, every recorded diff is reproduced.
    func testServerDiffsEqualTheRecordedDiffs() throws {
        let count = try serverDiffs(reload: .none)
        for m in count.mismatches { XCTFail(m) }
        XCTAssertEqual(count.titlesSentByThePortOnly, [])
        XCTAssertEqual(count.titlesSentByMoshOnly, [])
        XCTAssertGreaterThan(count.singleHostBytes, 2000)
        report("corpus diffs from server states", count)
    }

    /// The same when the server's terminal and every kept state are reloaded the way a
    /// snapshot stores them: the skeleton of each state plus one copy of every distinct
    /// row. Rows that were one object are one object again, so `diff(from:)` makes the
    /// decisions mosh made and every recorded diff is reproduced.
    func testServerDiffsEqualTheRecordedDiffsWhenStatesAreReloadedWithSharedRows() throws {
        let count = try serverDiffs(reload: .sharedRows)
        for m in count.mismatches { XCTFail(m) }
        XCTAssertEqual(count.titlesSentByThePortOnly, [])
        XCTAssertEqual(count.titlesSentByMoshOnly, [])
        report("corpus diffs from server states reloaded with shared rows", count)
    }

    /// The same when every state is decoded from its own blob. `newFrame` is still equal
    /// byte for byte (row generations survive, so the same scrolls are found). For
    /// `diff(from:)` there is one class of difference, and it is counted exactly here.
    ///
    /// mosh's `diff_from` calls `new_frame` only if `Framebuffer::operator==` fails. That
    /// operator compares the row *pointers* and ignores the icon name. When only the icon
    /// name changed between two states, the live states share all their rows, the
    /// framebuffers are "equal" and mosh sends nothing (the icon name goes out with the
    /// next diff that has another reason). Two states decoded from two blobs share no row
    /// object, so `moshEquals` fails, `newFrame` runs and writes the two titles. The
    /// result on the receiver is the state the server actually has; it is a difference
    /// from mosh's bytes, not an error. It concerns a sender of terminal states only; a
    /// mosh client never calls `diff(from:)` on the states it receives.
    func testServerDiffsWhenEveryStateIsItsOwnBlob() throws {
        let count = try serverDiffs(reload: .blobs)
        for m in count.mismatches { XCTFail(m) }
        XCTAssertEqual(count.titlesSentByMoshOnly, [])
        // Exactly the instructions where the icon name changed and mosh sent nothing.
        XCTAssertEqual(count.titlesSentByThePortOnly.count, count.iconNameChangedNothingSent)
        XCTAssertGreaterThan(count.titlesSentByThePortOnly.count, 0, "the corpus has cases of this class (syn-osc, syn-invisible)")
        report("corpus diffs from server states, each its own blob", count)
    }

    // MARK: Step 4b on the client's states

    /// A framebuffer with the rows of one state and everything else of another.
    static func framebuffer(rows: [Row], rest fb: Framebuffer) -> Framebuffer {
        return Framebuffer(rows: rows, iconName: fb.iconName, windowTitle: fb.windowTitle, clipboard: fb.clipboard,
                           bellCount: fb.bellCount, titleInitialized: fb.titleInitialized, ds: fb.ds)
    }

    /// The client's cells in rows that have the server's generations and the server's
    /// pattern of shared row objects (between the two states and within each).
    static func withServerIdentity(_ client: [Framebuffer], _ server: [Framebuffer]) -> [[Row]] {
        var made: [ObjectIdentifier: [Row]] = [:]
        return zip(client, server).map { c, s in
            zip(c.rows, s.rows).map { clientRow, serverRow -> Row in
                let id = ObjectIdentifier(serverRow)
                if let known = made[id]?.first(where: { $0.cells == clientRow.cells }) { return known }
                let row = Row(cells: clientRow.cells, gen: serverRow.gen)
                made[id, default: []].append(row)
                return row
            }
        }
    }

    static let wideInLastColumn = "wide character in the last column"
    static let underWide = "cell under the right half of a wide character"
    static let emptyVersusSpace = "empty cell versus space"
    static let wrapBit = "soft-wrap bit"
    static let fallbackCell = "fallback cell"

    /// The kinds of cell that the client's screen holds differently from the server's.
    /// All are mosh's own behaviour (Tools/mosh-oracle/README.md, "Things about mosh
    /// 1.4.0 that the corpus shows"); anything else is reported as "other".
    static func cellDifferenceKinds(_ c: Framebuffer, _ s: Framebuffer) -> Set<String> {
        var kinds = Set<String>()
        let width = s.ds.width
        for y in 0..<min(c.rows.count, s.rows.count) {
            let cr = c.rows[y], sr = s.rows[y]
            if cr === sr || cr.cells == sr.cells { continue }
            // The server has a wide character in the last column. The receiving terminal
            // wraps before printing it: the last column stays empty and the character
            // lands at the start of the next line.
            let wideLastHere = sr.cells[width - 1].wide
            let wideLastAbove = y > 0 && s.rows[y - 1].cells[width - 1].wide
            for x in 0..<width where cr.cells[x] != sr.cells[x] {
                let a = cr.cells[x], b = sr.cells[x]
                if (wideLastHere && x == width - 1) || (wideLastAbove && x < 2) {
                    kinds.insert(wideInLastColumn)
                } else if x > 0 && (cr.cells[x - 1].wide || sr.cells[x - 1].wide) && a.wide == b.wide {
                    kinds.insert(underWide)
                } else if a.renditions == b.renditions && a.wide == b.wide && a.wrap == b.wrap
                    && ((a.contents.isEmpty && b.contents == [0x20]) || (b.contents.isEmpty && a.contents == [0x20])) {
                    kinds.insert(emptyVersusSpace)
                } else if a.contents == b.contents && a.renditions == b.renditions && a.wide == b.wide && a.fallback == b.fallback {
                    kinds.insert(wrapBit)
                } else if a.fallback != b.fallback {
                    kinds.insert(fallbackCell)
                } else {
                    kinds.insert("other: row \(y) column \(x), client \(CorpusComparison.cell(a)), server \(CorpusComparison.cell(b))")
                }
            }
        }
        return kinds
    }

    /// nil if the client's cursor is the server's; "one column left" for mosh's known
    /// displacement (after `new_frame` printed into the last column, it counts its
    /// backspaces or its "no move needed" from the column past the margin, while the
    /// receiving terminal's cursor stayed on the last column); otherwise a description.
    static func cursorDifference(client c: Framebuffer, server s: Framebuffer) -> String? {
        if c.ds.cursorRow == s.ds.cursorRow && c.ds.cursorCol == s.ds.cursorCol { return nil }
        if c.ds.cursorRow == s.ds.cursorRow && c.ds.cursorCol + 1 == s.ds.cursorCol { return "one column left" }
        return "client [\(c.ds.cursorRow), \(c.ds.cursorCol)], server [\(s.ds.cursorRow), \(s.ds.cursorCol)]"
    }

    /// What `new_frame` can transmit, other than the rows and the cursor position.
    static func sameOutsideRowsAndCursor(_ a: Framebuffer, _ b: Framebuffer) -> Bool {
        return a.iconName == b.iconName && a.windowTitle == b.windowTitle && a.titleInitialized == b.titleInitialized
            && a.clipboard == b.clipboard && a.ds.width == b.ds.width && a.ds.height == b.ds.height
            && a.ds.cursorVisible == b.ds.cursorVisible && a.ds.renditions == b.ds.renditions
            && a.ds.reverseVideo == b.ds.reverseVideo && a.ds.bracketedPaste == b.ds.bracketedPaste
            && a.ds.mouseReportingMode == b.ds.mouseReportingMode && a.ds.mouseFocusEvent == b.ds.mouseFocusEvent
            && a.ds.mouseEncodingMode == b.ds.mouseEncodingMode
    }

    /// Step 4b as the task words it: `newFrame` between the *client's* states number
    /// old_num and new_num, against the recorded host bytes.
    ///
    /// The recorded bytes were computed by the server from the server's states, and a
    /// mosh client's state is not the server's (mosh's own emulator, fed mosh's own
    /// diffs, ends up with these differences; the corpus tests above prove the port has
    /// exactly the same ones). So byte equality cannot hold everywhere. This test counts
    /// where it does not, and attributes every such instruction to information that only
    /// the server has, by putting that information back and getting the recorded bytes:
    ///
    /// - "row identity and generation": the client's cells in rows that carry the
    ///   server's generation numbers and sharing give the recorded bytes. `new_frame`
    ///   finds scrolls by row generation; the client's rows have their own history (a
    ///   row the server replaced was only repainted in place on the client, and the
    ///   reverse).
    /// - "cells": the server's rows with everything else from the client give the
    ///   recorded bytes, and every differing cell is of a named kind: an empty cell that
    ///   is a space on the other side (the diff erases with spaces or ECH/EL depending
    ///   on run lengths), the cell hidden under the right half of a wide character, a
    ///   soft-wrap bit, a fallback cell, a wide character in the last column.
    /// - "cursor": the client's rows with everything else from the server give the
    ///   recorded bytes, and the only field that differs is the cursor, one column left
    ///   of the server's.
    ///
    /// It also applies each frame computed from the client's states to the client's old
    /// state: the result must be the client's new state in everything `new_frame`
    /// transmits, except that the cursor can again end one column left.
    func testNewFrameBetweenClientStates() throws {
        var single = 0
        var equal = 0
        var classes: [String: Int] = [:]
        var examples: [String: String] = [:]
        var unexplained: [String] = []
        var appliedExactly = 0
        var appliedCursorLeft = 0

        for c in try cases() {
            var tally = CorpusTally()
            let client = try CorpusRun.client(c, tally: &tally).states
            var server: [TerminalState] = [TerminalState(width: c.width, height: c.height)]
            _ = try CorpusRun.server(c, compare: false, tally: &tally) { _, state, _ in server.append(state) }

            for (i, instruction) in c.instructions.enumerated() {
                guard instruction.ops.count == 1, case .hostBytes(let recorded) = instruction.ops[0] else { continue }
                single += 1
                let what = "\(c.name) instruction \(i + 1) (old_num \(instruction.oldNum))"
                let cOld = client[instruction.oldNum]!.framebuffer, cNew = client[instruction.newNum]!.framebuffer
                let sOld = server[Int(instruction.oldNum)].framebuffer, sNew = server[Int(instruction.newNum)].framebuffer
                let frame = DisplayDiff.newFrame(initialized: true, from: cOld, to: cNew)

                // What the frame does to the client's own old state.
                var applied = client[instruction.oldNum]!
                let reply = applied.act(frame)
                let result = applied.framebuffer
                let cursor = CorpusDisplayTests.cursorDifference(client: result, server: cNew)
                if !reply.isEmpty || result.rows.map({ $0.cells }) != cNew.rows.map({ $0.cells })
                    || !CorpusDisplayTests.sameOutsideRowsAndCursor(result, cNew)
                    || (result.bellCount != cOld.bellCount) != (cNew.bellCount != cOld.bellCount) {
                    unexplained.append("\(what): the frame between the client's states does not turn the old one into the new one: "
                        + CorpusComparison.escaped(frame, limit: 300))
                } else if cursor == nil {
                    appliedExactly += 1
                } else if cursor == "one column left" {
                    appliedCursorLeft += 1
                } else {
                    unexplained.append("\(what): applying the frame between the client's states leaves the cursor wrong: \(cursor!)")
                }

                // The bytes against the recorded ones.
                if frame == recorded {
                    equal += 1
                    continue
                }
                let ident = CorpusDisplayTests.withServerIdentity([cOld, cNew], [sOld, sNew])
                let withServerIdentity = DisplayDiff.newFrame(
                    initialized: true, from: CorpusDisplayTests.framebuffer(rows: ident[0], rest: cOld),
                    to: CorpusDisplayTests.framebuffer(rows: ident[1], rest: cNew))
                let withServerRows = DisplayDiff.newFrame(
                    initialized: true, from: CorpusDisplayTests.framebuffer(rows: sOld.rows, rest: cOld),
                    to: CorpusDisplayTests.framebuffer(rows: sNew.rows, rest: cNew))
                let withServerRest = DisplayDiff.newFrame(
                    initialized: true, from: CorpusDisplayTests.framebuffer(rows: cOld.rows, rest: sOld),
                    to: CorpusDisplayTests.framebuffer(rows: cNew.rows, rest: sNew))

                let kinds = CorpusDisplayTests.cellDifferenceKinds(cOld, sOld).union(CorpusDisplayTests.cellDifferenceKinds(cNew, sNew))
                let cursors = [CorpusDisplayTests.cursorDifference(client: cOld, server: sOld),
                               CorpusDisplayTests.cursorDifference(client: cNew, server: sNew)].compactMap { $0 }
                let restIsCursorOnly = CorpusDisplayTests.sameOutsideRowsAndCursor(cOld, sOld)
                    && CorpusDisplayTests.sameOutsideRowsAndCursor(cNew, sNew)
                    && (cOld.bellCount != cNew.bellCount) == (sOld.bellCount != sNew.bellCount)
                    && !cursors.isEmpty && cursors.allSatisfy { $0 == "one column left" }
                let kindsAreNamed = !kinds.isEmpty && !kinds.contains { $0.hasPrefix("other") }

                var name: String
                if withServerIdentity == recorded {
                    name = "row identity and generation"
                } else if withServerRows == recorded {
                    name = "cells: " + kinds.sorted().joined(separator: " + ")
                    if !kindsAreNamed { unexplained.append("\(what): \(name)") }
                } else if withServerRest == recorded {
                    name = "cursor one column left"
                    if !restIsCursorOnly { unexplained.append("\(what): differs outside the rows in more than the cursor") }
                } else {
                    // Neither part alone is enough; both together are the server's states,
                    // which give the recorded bytes (testServerDiffsEqualTheRecordedDiffs).
                    name = "cursor one column left, and cells: " + kinds.sorted().joined(separator: " + ")
                    if !kindsAreNamed || !restIsCursorOnly { unexplained.append("\(what): \(name)") }
                }
                classes[name, default: 0] += 1
                if examples[name] == nil {
                    examples[name] = "\(what): client states give \(CorpusComparison.escaped(frame, limit: 160)), "
                        + "mosh sent \(CorpusComparison.escaped(recorded, limit: 160))"
                }
            }
        }

        for u in unexplained.prefix(10) { XCTFail(u) }
        XCTAssertEqual(unexplained.count, 0)
        XCTAssertEqual(equal + classes.values.reduce(0, +), single)
        XCTAssertEqual(appliedExactly + appliedCursorLeft, single - unexplained.count)
        print("corpus newFrame between client states: \(single) single-hostbytes instructions, \(equal) byte-equal "
            + "to the recorded diff, \(single - equal) differ, \(unexplained.count) unexplained")
        for (name, n) in classes.sorted(by: { $0.key < $1.key }) {
            print("  \(n) x \(name)\n      e.g. \(examples[name]!)")
        }
        print("  applied to the client's old state: \(appliedExactly) give the new state, "
            + "\(appliedCursorLeft) give it with the cursor one column left")
    }

    /// The figures quoted in Tools/mosh-oracle/README.md ("Things about mosh 1.4.0 that
    /// the corpus shows"), counted from the port's own two runs so that they can be
    /// checked again when the corpus changes.
    func testFiguresOfTheCorpus() throws {
        var cases = 0, states = 0, synthetic = 0
        var oldBase = 0, emptyDiffs = 0, syntheticEmptyDiffs = 0
        var cursorLeft = 0, spaceForEmpty = 0, pendingWrap = 0, fallback = 0
        for c in try self.cases() {
            var tally = CorpusTally()
            let client = try CorpusRun.client(c, tally: &tally).states
            var server: [TerminalState] = [TerminalState(width: c.width, height: c.height)]
            _ = try CorpusRun.server(c, compare: false, tally: &tally) { _, state, _ in server.append(state) }
            cases += 1
            for instruction in c.instructions {
                states += 1
                let isSynthetic = c.name.hasPrefix("syn-")
                if isSynthetic { synthetic += 1 }
                if instruction.newNum - instruction.oldNum >= 2 { oldBase += 1 }
                if instruction.diff.isEmpty {
                    emptyDiffs += 1
                    if isSynthetic { syntheticEmptyDiffs += 1 }
                }
                let cl = client[instruction.newNum]!.framebuffer, sv = server[Int(instruction.newNum)].framebuffer
                if CorpusDisplayTests.cursorDifference(client: cl, server: sv) == "one column left" { cursorLeft += 1 }
                if cl.ds.nextPrintWillWrap { pendingWrap += 1 }
                var hasSpace = false, hasFallback = false
                for (cr, sr) in zip(cl.rows, sv.rows) {
                    if cr.cells.contains(where: { $0.fallback }) { hasFallback = true }
                    if cr === sr || cr.cells == sr.cells { continue }
                    for (a, b) in zip(cr.cells, sr.cells) where a.contents == [0x20] && b.contents.isEmpty { hasSpace = true }
                }
                if hasSpace { spaceForEmpty += 1 }
                if hasFallback { fallback += 1 }
            }
        }
        print("corpus figures: \(states) states in \(cases) cases; \(oldBase) instructions with a base 2 or more states old; "
            + "\(emptyDiffs) empty diffs (\(syntheticEmptyDiffs) of the \(synthetic) syn-* instructions); "
            + "\(cursorLeft) client states with the cursor one column left of the server's; "
            + "\(spaceForEmpty) client states with a space where the server's cell is empty; "
            + "\(pendingWrap) client states with a pending wrap; \(fallback) client states with a fallback cell")
        XCTAssertEqual(pendingWrap, 0, "README, item 2")
        XCTAssertEqual(fallback, 0, "README, item 11")
        XCTAssertGreaterThan(cursorLeft, 0)
        XCTAssertGreaterThan(spaceForEmpty, 0)
        XCTAssertGreaterThan(oldBase, 0)
    }
}
