import XCTest

/// Settings > Privacy shows the privacy policy from the app itself (App Review Guideline 5.1.1(i):
/// "within the app in an easily accessible manner"): the bundled PRIVACY.md, with no network
/// needed, and the policy's address on GitHub.
final class PrivacyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSettingsLeadsToThePrivacyPolicy() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let row = app.cells["settings.privacy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Privacy row")
        row.tap()
        let page = app.textViews["privacyText"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the Privacy page")
        XCTAssertTrue(app.navigationBars["Privacy"].exists, "titled Privacy")
        let text = (page.value as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("The privacy policy of iOS-mosh, as it was when this version was built (the file "
                                     + "PRIVACY.md in the source code). Its current version is at "
                                     + "https://github.com/trickv/ios-mosh/blob/main/PRIVACY.md\n\n\n"
                                     + "# iOS-mosh privacy policy\n"), String(text.prefix(400)))
        XCTAssertTrue(text.contains("- The app collects no data. Nothing you enter or do in the app reaches the developer."),
                      String(text.prefix(1200)))
        XCTAssertTrue(text.contains("**Passwords are not stored.**"))
        XCTAssertTrue(text.hasSuffix("open an issue at https://github.com/trickv/ios-mosh/issues"), String(text.suffix(300)))
        attachScreenshot(app, "privacy")
        app.navigationBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tables["settings"].waitForExistence(timeout: 5), "back on Settings")
    }
}
