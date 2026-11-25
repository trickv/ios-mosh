import XCTest
@testable import IOSMosh

/// The app's privacy manifest and its privacy page.
final class PrivacyTests: XCTestCase {
    /// The categories of required reason API and their reasons, as Apple lists them under
    /// NSPrivacyAccessedAPIType (developer.apple.com/documentation/bundleresources/
    /// app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype, read
    /// 2026-11-24).
    private static let appleReasons: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
    ]

    /// `PrivacyInfo.xcprivacy` is at the top of the app bundle (Apple: "the required file name for
    /// bundled privacy manifests"), parses as a property list, says no tracking and no collected
    /// data, and declares exactly the app's own required reason APIs: user defaults for its own
    /// settings, file timestamps of its own files (C617.1) and shown on a session row (DDA9.1).
    func testThePrivacyManifestIsInTheAppAndDeclaresWhatTheAppUses() throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let manifest = try XCTUnwrap(plist as? [String: Any], "a dictionary at the top")
        XCTAssertEqual(Set(manifest.keys), ["NSPrivacyTracking", "NSPrivacyTrackingDomains",
                                            "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, "no tracking")
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, "no tracking domains")
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "no collected data")
        let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for entry in types {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String], type)
            XCTAssertNil(declared[type], "\(type) once")
            declared[type] = reasons
            let allowed = try XCTUnwrap(Self.appleReasons[type], "\(type) is one of Apple's categories")
            XCTAssertTrue(Set(reasons).isSubset(of: allowed), "\(type): \(reasons) are reasons of that category")
        }
        XCTAssertEqual(declared, ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                                  "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "DDA9.1"]])
    }

    /// The page under Settings > Privacy: where the policy is online, then the bundled PRIVACY.md
    /// in full.
    func testThePrivacyPageIsTheBundledPolicy() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PRIVACY", withExtension: "md"), "PRIVACY.md is in the app")
        var file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(file.hasPrefix("# iOS-mosh privacy policy\n"), String(file.prefix(100)))
        XCTAssertTrue(file.contains("The app collects no data."))
        while file.last?.isNewline == true { file.removeLast() }
        XCTAssertEqual(PrivacyPolicy.text(), file)
        XCTAssertEqual(PrivacyPolicy.url, "https://github.com/trickv/ios-mosh/blob/main/PRIVACY.md")
        let page = PrivacyPolicy.page()
        XCTAssertTrue(page.contains("Its current version is at https://github.com/trickv/ios-mosh/blob/main/PRIVACY.md"))
        XCTAssertTrue(page.hasSuffix("\n\n\n" + file), String(page.prefix(300)))
    }
}

/// The colours of the bars over the terminal screen (`TerminalBars`): for every theme of Settings,
/// as the terminal draws it, the bars' text can be read (WCAG 2 contrast ratio at least 4.5), and a
/// light terminal gets black text, a dark one white.
final class TerminalBarsTests: XCTestCase {
    func testTheBarsOverEveryThemeCanBeRead() {
        // System: SwiftTerm draws it black (TerminalBarsUITests checks that on the screen); the
        // other themes draw their own background.
        let drawn: [(String, RGB, Bool)] = TerminalTheme.all.map { theme in
            let background = theme.background ?? RGB(0x000000)
            return (theme.id, background, theme.id != "tangoLight")
        } + [("white", RGB(0xFFFFFF), false), ("dark grey", RGB(0x666666), true), ("mid grey", RGB(0x777777), false), ("light grey", RGB(0xBBBBBB), false)]
        for (name, background, light) in drawn {
            let bars = TerminalBars(background: background)
            XCTAssertEqual(bars.background, background, name)
            XCTAssertEqual(bars.lightText, light, "\(name): light text on \(background)")
            XCTAssertEqual(bars.text, light ? RGB(0xFFFFFF) : RGB(0x000000), name)
            XCTAssertGreaterThanOrEqual(TerminalBars.contrast(bars.text, background), 4.5, "\(name) can be read")
        }
        XCTAssertEqual(TerminalBars.contrast(RGB(0x000000), RGB(0xFFFFFF)), 21, accuracy: 0.001)
        XCTAssertEqual(TerminalBars(background: RGB(0x2E3436)).testDescription,
                       "background=#2E3436 text=#FFFFFF status=light")
    }
}
