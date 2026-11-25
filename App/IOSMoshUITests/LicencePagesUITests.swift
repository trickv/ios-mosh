import XCTest

/// Settings > About leads to the licence pages (docs/notes/publication/licence.md section 5,
/// items 1, 2 and 5), and each shows its text.
final class LicencePagesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openAbout() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.cells["settings.about"].waitForExistence(timeout: 5))
        app.cells["settings.about"].tap()
        let about = app.textViews["aboutText"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        let aboutText = (about.value as? String) ?? ""
        XCTAssertTrue(aboutText.contains("Copyright (C) 2026 Patrick van Staveren. Portions Copyright 2012 "
                                         + "Keith Winstein and the mosh authors (https://mosh.org), ported from "
                                         + "mosh 1.4.0."), aboutText)
        return app
    }

    /// About > "GNU General Public License v3": the full GPL text, from its first heading on.
    func testAboutLeadsToTheGPLText() {
        let app = openAbout()
        XCTAssertTrue(app.buttons["about.gpl"].waitForExistence(timeout: 5))
        app.buttons["about.gpl"].tap()
        let page = app.textViews["gplText"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let text = (page.value as? String) ?? ""
        XCTAssertTrue(text.contains("GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"),
                      String(text.prefix(400)))
        XCTAssertTrue(text.contains("Preamble"))
        XCTAssertTrue(text.contains("END OF TERMS AND CONDITIONS"))
        attachScreenshot(app, "gpl")
        app.navigationBars.buttons["About"].tap()
        XCTAssertTrue(app.textViews["aboutText"].waitForExistence(timeout: 5), "back on About")
    }

    /// About > "App Store permission": COPYING.iOS, the owner's section 7 permission first, then
    /// mosh's own statement.
    func testAboutLeadsToTheAppStorePermission() {
        let app = openAbout()
        XCTAssertTrue(app.buttons["about.appStore"].waitForExistence(timeout: 5))
        app.buttons["about.appStore"].tap()
        let page = app.textViews["appStorePermissionText"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let text = (page.value as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("Additional permission under GNU GPL version 3 section 7\n\n"
                                     + "iOS-mosh is Copyright (C) 2026 Patrick van Staveren. As the copyright "
                                     + "holder of iOS-mosh's own code"), String(text.prefix(400)))
        XCTAssertTrue(text.contains("The Mosh developers are aware that the terms of service that apply to\n"
                                    + "apps distributed via Apple's App Store services may conflict with"),
                      String(text.suffix(900)))
        XCTAssertTrue(text.hasSuffix("not object to your distribution of Mosh through the App Store."))
        attachScreenshot(app, "app-store-permission")
        app.navigationBars.buttons["About"].tap()
        XCTAssertTrue(app.textViews["aboutText"].waitForExistence(timeout: 5), "back on About")
    }

    /// About > "Third-party licences": a package's licence (SwiftTerm's MIT notice) and a NOTICE
    /// (SwiftNIO's), in full.
    func testAboutLeadsToTheThirdPartyLicences() {
        let app = openAbout()
        XCTAssertTrue(app.buttons["about.thirdParty"].waitForExistence(timeout: 5))
        app.buttons["about.thirdParty"].tap()
        let page = app.textViews["thirdPartyText"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let text = (page.value as? String) ?? ""
        XCTAssertTrue(text.contains("• SwiftTerm 1.99.3, https://github.com/migueldeicaza/SwiftTerm.git"),
                      String(text.prefix(1500)))
        XCTAssertTrue(text.contains("=== SwiftTerm 1.99.3, LICENSE ===\n\nCopyright (c) 2019-2026 Miguel de Icaza"))
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge, to any person obtaining"))
        XCTAssertTrue(text.contains("=== swift-nio 2.105.0, NOTICE.txt ==="))
        XCTAssertTrue(text.contains("The SwiftNIO Project licenses this file to you under the Apache License"))
        attachScreenshot(app, "third-party")
    }
}
