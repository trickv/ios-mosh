import MoshBootstrap
import XCTest
@testable import IOSMosh

/// The port message (docs/notes/multi-session/DESIGN.md 3.1 H3, step 13; review LC-17): a server
/// start that failed because the host's UDP port range is full is told by mosh's own untranslated
/// words "Failed binding to", never by the words of the host's language.
final class PortRangeFullTests: XCTestCase {
    /// What `mosh-server new -s -p 62798:62799` prints on a host in German when both ports are
    /// taken (mosh 1.4.0: `network.cc:348` for each of the two binds, 273, 283;
    /// `mosh-server.cc:368-371`), as it comes through the pty ("\r\n").
    private let germanFullRange = [
        "Failed binding to 127.0.0.1:62799",
        "Error binding to IP 127.0.0.1: bind: Die Adresse wird bereits verwendet",
        "Failed binding to 0.0.0.0:62799",
        "Error binding to any interface: bind: Die Adresse wird bereits verwendet",
        "Network exception: bind: Die Adresse wird bereits verwendet",
    ].joined(separator: "\r\n") + "\r\n"

    func testFiveLinesOfAFullRangeGiveTheMessage() throws {
        let range = try XCTUnwrap(UDPPortRange("62798:62799"))
        let message = PortRangeFull.message(output: germanFullRange, host: "hg", range: range)
        XCTAssertEqual(message, "No free UDP port on hg in 62798:62799. Each session uses one: end a session on this host, "
                                + "or widen UDP ports in the host's settings.",
                       "the five lines of a -s server in German")

        // The same lines with "\n" only (a host without a pty's line discipline), and indented.
        let plain = germanFullRange.replacingOccurrences(of: "\r\n", with: "\n  ")
        XCTAssertNotNil(PortRangeFull.message(output: plain, host: "hg", range: range), "\"\\n\" line ends, indented")

        // A host whose settings name no range: mosh's own default.
        XCTAssertEqual(PortRangeFull.message(output: germanFullRange, host: "box", range: nil)?.hasPrefix(
            "No free UDP port on box in 60001:60999."), true, "mosh's default range (network.h:136-137)")
        // A single port.
        XCTAssertEqual(PortRangeFull.message(output: germanFullRange, host: "box", range: UDPPortRange(port: 60010))?.hasPrefix(
            "No free UDP port on box in 60010."), true, "one port")

        // In a fallback the banner also names the row to end.
        XCTAssertTrue(PortRangeFull.fallbackNote(host: "hg").contains("Could not be resumed"))
        XCTAssertTrue(PortRangeFull.fallbackNote(host: "hg").contains("under hg"))
    }

    func testAnotherStartFailureGivesNoMessage() throws {
        let range = try XCTUnwrap(UDPPortRange("62798:62799"))
        let others = [
            // A range mosh cannot parse: thrown before any bind.
            "Network exception: Invalid port range: Success\r\n",
            // No pty for the session.
            "forkpty: Keine Geräte mehr verfügbar\r\n",
            "Crypto exception: Could not open /dev/urandom\r\n",
            // A missing locale (classified apart as `.localeMissing`, but the text must not
            // read as a full range either).
            "mosh-server needs a UTF-8 native locale to run.\r\n\r\nUnfortunately, the local environment "
                + "(LC_ALL=xx_XX.UTF-8) specifies\r\nthe character set \"US-ASCII\",\r\n",
            // The words "binding" and the port without mosh's literal at the line start.
            "Error binding to any interface: bind: Die Adresse wird bereits verwendet\r\n",
            "note: Failed binding to 127.0.0.1:62799 is what a full range prints\r\n",
            "",
        ]
        for output in others {
            XCTAssertNil(PortRangeFull.message(output: output, host: "hg", range: range), "no port message for: \(output)")
        }
    }
}
