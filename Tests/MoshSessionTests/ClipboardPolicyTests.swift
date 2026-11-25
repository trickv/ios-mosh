import Foundation
import MoshTerminal
import MoshWire
import XCTest
@testable import MoshSession

/// docs/PLAN.md section 5, "OSC 52".
final class ClipboardPolicyTests: XCTestCase {
    private func field(_ text: String) -> Framebuffer.Title {
        text.unicodeScalars.map { $0.value }
    }

    private func field(base64Of text: String) -> Framebuffer.Title {
        field(Data(text.utf8).base64EncodedString())
    }

    func testALiveChangeIsWritten() {
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe(field(base64Of: "hello"), live: true), .write(text: "hello", byteCount: 5))
        XCTAssertEqual(policy.observe(field(base64Of: "héllo ✓"), live: true),
                       .write(text: "héllo ✓", byteCount: Array("héllo ✓".utf8).count))
    }

    func testAnUnchangedFieldIsNotWrittenAgain() {
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe(field(base64Of: "a"), live: true), .write(text: "a", byteCount: 1))
        XCTAssertEqual(policy.observe(field(base64Of: "a"), live: true), .none(.unchanged))
        XCTAssertEqual(policy.observe(field(base64Of: "a"), live: true), .none(.unchanged))
    }

    func testAResumeRepaintIsNeverWritten() {
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe(field(base64Of: "secret"), live: false), .none(.notLive))
        // The same field on the next live state is not a change.
        XCTAssertEqual(policy.observe(field(base64Of: "secret"), live: true), .none(.unchanged))
        // A real change after the repaint is.
        XCTAssertEqual(policy.observe(field(base64Of: "new"), live: true), .write(text: "new", byteCount: 3))
        policy.baseline(field(base64Of: "other"))
        XCTAssertEqual(policy.observe(field(base64Of: "other"), live: true), .none(.unchanged))
    }

    func testTheSameContentAsTheLastWriteIsSkipped() {
        // A restored policy remembers the hash of the last write; the field reappearing (for
        // example after an empty one) is not written twice.
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe(field(base64Of: "x"), live: true), .write(text: "x", byteCount: 1))
        XCTAssertEqual(policy.observe([], live: true), .none(.empty))
        XCTAssertEqual(policy.observe(field(base64Of: "x"), live: true), .none(.duplicate))
        XCTAssertEqual(policy.observe(field(base64Of: "y"), live: true), .write(text: "y", byteCount: 1))
        XCTAssertEqual(policy.observe(field(base64Of: "x"), live: true), .write(text: "x", byteCount: 1))

        var restored = ClipboardPolicy(lastWrittenHash: policy.lastWrittenHash)
        XCTAssertEqual(restored.observe(field(base64Of: "x"), live: true), .none(.duplicate))
    }

    func testAQueryIsIgnored() {
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe(field("?"), live: true), .none(.query))
    }

    func testAnEmptyFieldIsIgnored() {
        var policy = ClipboardPolicy()
        XCTAssertEqual(policy.observe([], live: true), .none(.unchanged), "state 0 is empty too")
        _ = policy.observe(field(base64Of: "a"), live: true)
        XCTAssertEqual(policy.observe([], live: true), .none(.empty))
    }

    func testThePerHostSwitchTurnsWritingOff() {
        var policy = ClipboardPolicy(isEnabled: false)
        XCTAssertEqual(policy.observe(field(base64Of: "a"), live: true), .none(.disabled))
        policy.isEnabled = true
        XCTAssertEqual(policy.observe(field(base64Of: "b"), live: true), .write(text: "b", byteCount: 1))
    }

    func testInvalidBase64IsReported() {
        for bad in ["aGk", "aGk=a", "a===", "aG=k", "aGk!", "aG k", "aGk=\n", "aGl=", "aR==", "=aGk", "é123"] {
            var policy = ClipboardPolicy()
            XCTAssertEqual(policy.observe(field(bad), live: true), .invalid(.notBase64), bad)
        }
    }

    func testInvalidUTF8IsReported() {
        for bytes: [UInt8] in [[0xFF], [0xC3], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0x61, 0xE2, 0x82]] {
            var policy = ClipboardPolicy()
            let b64 = Data(bytes).base64EncodedString()
            XCTAssertEqual(policy.observe(field(b64), live: true), .invalid(.notUTF8), b64)
        }
    }

    func testAFieldAtTheCapIsTruncated() {
        // mosh's OSC string stops at 16384 characters (terminaldispatcher.cc:239), "52;c;"
        // included: a field of 16379 characters may have been cut.
        XCTAssertEqual(ClipboardPolicy.truncatedLength, 16379)
        var policy = ClipboardPolicy()
        let atCap = Framebuffer.Title(repeating: UInt32(UInt8(ascii: "A")), count: 16379)
        XCTAssertEqual(policy.observe(atCap, live: true), .invalid(.truncated))
        let justBelow = field(String(repeating: "QUFB", count: 4094))   // 16376 characters
        XCTAssertEqual(policy.observe(justBelow, live: true), .write(text: String(repeating: "AAA", count: 4094), byteCount: 12282))
    }

    func testStrictBase64AgainstFoundation() {
        var generator = SystemRandomNumberGenerator()
        for length in 0..<70 {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let encoded = Data(bytes).base64EncodedString()
            XCTAssertEqual(ClipboardPolicy.strictBase64Decode(Array(encoded.utf8)), bytes, encoded)
        }
    }

    func testFNVIsStable() {
        // Published FNV-1a 64 test values.
        XCTAssertEqual(ClipboardPolicy.fnv1a64([]), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(ClipboardPolicy.fnv1a64(Array("a".utf8)), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(ClipboardPolicy.fnv1a64(Array("foobar".utf8)), 0x8594_4171_f739_67e8)
    }

    /// The whole path: an OSC 52 in the host bytes of a server diff, through the adapter, into
    /// the policy, the way `MoshSession` does it.
    func testAnOSC52FromTheServerReachesThePolicy() throws {
        var state = TerminalRemoteState()
        var policy = ClipboardPolicy()
        let b64 = Data("copied text".utf8).base64EncodedString()
        try state.apply(diff: HostMessage(instructions: [.hostBytes(Array("\u{1B}]52;c;\(b64)\u{07}".utf8))]).serialized())
        XCTAssertEqual(policy.observe(state.framebuffer.clipboard, live: true), .write(text: "copied text", byteCount: 11))
        // tmux's default "52;;" form is dropped by the emulator, as by mosh's.
        let before = state.framebuffer.clipboard
        try state.apply(diff: HostMessage(instructions: [.hostBytes(Array("\u{1B}]52;;\(b64)\u{07}".utf8))]).serialized())
        XCTAssertEqual(state.framebuffer.clipboard, before)
    }
}
