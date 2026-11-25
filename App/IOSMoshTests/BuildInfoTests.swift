import XCTest
@testable import IOSMosh

final class BuildInfoTests: XCTestCase {
    func testVersionKeysArePresent() {
        XCTAssertNotEqual(BuildInfo.version, "unknown")
        XCTAssertNotEqual(BuildInfo.build, "unknown")
        XCTAssertNotEqual(BuildInfo.gitSHA, "unknown")
        XCTAssertFalse(BuildInfo.gitSHA.contains("$("), "build setting was not expanded")
    }
}
