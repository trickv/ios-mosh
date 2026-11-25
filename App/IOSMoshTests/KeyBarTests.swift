@testable import IOSMosh
import XCTest

/// The tmux prefix setting of the key bar (docs/PLAN.md section 5: configurable, default C-b).
final class KeyBarTests: XCTestCase {
    func testPrefixBytes() {
        XCTAssertEqual(KeyBarView.prefixBytes("C-b"), [0x02])
        XCTAssertEqual(KeyBarView.prefixBytes("c-a"), [0x01])
        XCTAssertEqual(KeyBarView.prefixBytes("C-A"), [0x01])
        XCTAssertEqual(KeyBarView.prefixBytes(" C-] "), [0x1D])
        XCTAssertEqual(KeyBarView.prefixBytes("C-@"), [0x00])
        XCTAssertNil(KeyBarView.prefixBytes("b"))
        XCTAssertNil(KeyBarView.prefixBytes("C-bb"))
        XCTAssertNil(KeyBarView.prefixBytes("C-1"))
        XCTAssertNil(KeyBarView.prefixBytes("M-b"))
    }

    func testPrefixLabel() {
        XCTAssertEqual(KeyBarView.label(forPrefix: [0x02]), "^B")
        XCTAssertEqual(KeyBarView.label(forPrefix: [0x01]), "^A")
        XCTAssertEqual(KeyBarView.label(forPrefix: [0x41]), "Prefix")
    }
}
