import XCTest
@testable import IOSMosh

/// `-uiTestingBackgroundInset`: when the UI-test hook lays the terminal out again after the
/// background save, and the mark a held size sends.
final class BackgroundLayoutChangeTests: XCTestCase {
    func testNoArgumentMeansNoChange() {
        var change = BackgroundLayoutChange(argument: nil)
        XCTAssertNil(change.inset)
        XCTAssertNil(change.insetAfterSave(clean: true))
    }

    func testAnArgumentThatIsNotAPositiveNumberUpTo200IsIgnored() {
        for bad in ["", "x", "0", "-5", "201", "1e9"] {
            XCTAssertNil(BackgroundLayoutChange(argument: bad).inset, bad)
        }
        XCTAssertEqual(BackgroundLayoutChange(argument: "40").inset, 40)
    }

    func testTheChangeComesOnceAfterACleanSave() {
        var change = BackgroundLayoutChange(argument: "40")
        XCTAssertEqual(change.insetAfterSave(clean: true), 40)
        XCTAssertNil(change.insetAfterSave(clean: true), "once per process: the inset would grow on every trip")
    }

    func testNoChangeAfterASaveThatWasNotClean() {
        var change = BackgroundLayoutChange(argument: "40")
        XCTAssertNil(change.insetAfterSave(clean: false))
        XCTAssertEqual(change.insetAfterSave(clean: true), 40, "the next clean save still gets it")
    }

    func testTheDelayIsTheFlakes() {
        XCTAssertEqual(BackgroundLayoutChange.delay, 0.8)
    }

    /// The spawner accepts 1-64 letters, digits, dots and dashes.
    func testTheHeldMarkNamesTheSizeInCharactersTheSpawnerTakes() {
        let mark = BackgroundLayoutChange.heldMark(columns: 47, rows: 29)
        XCTAssertEqual(mark, "background-size-held-47x29")
        XCTAssertNotNil(mark.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression))
        XCTAssertEqual(BackgroundLayoutChange.heldMark(columns: 65535, rows: 65535).count <= 64, true)
    }
}
