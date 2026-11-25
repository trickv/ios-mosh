import CryptoKit
import XCTest
@testable import IOSMosh

/// The licence pages under About (docs/notes/publication/licence.md section 5, items 1 to 3 and
/// 5): the GPL text, the licence and NOTICE files of every package the build resolves, the
/// copyright notice, and the App Store permission (COPYING.iOS).
final class LicencePagesTests: XCTestCase {
    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable {
                let revision: String
                let version: String?
            }
            let identity: String
            let location: String
            let state: State
        }
        let pins: [Pin]
    }

    /// The repository's Package.resolved, copied into this test bundle (App/project.yml).
    private func resolvedPins() throws -> [Resolved.Pin] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Package", withExtension: "resolved"),
                                "Package.resolved is a resource of the test bundle")
        return try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins
    }

    /// licence.md 5.1: the GPL itself ships in the app (a link to gnu.org is not a copy).
    func testTheGPLTextIsInTheAppAndOnItsPage() {
        let text = LicencePages.gplText()
        XCTAssertTrue(text.hasPrefix("                    GNU GENERAL PUBLIC LICENSE\n"
                                     + "                       Version 3, 29 June 2007\n"), String(text.prefix(200)))
        for needle in ["Preamble", "TERMS AND CONDITIONS", "15. Disclaimer of Warranty.",
                       "END OF TERMS AND CONDITIONS", "How to Apply These Terms to Your New Programs"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
        XCTAssertGreaterThan(text.count, 30000, "the whole licence, not an excerpt")
        let page = LicencePages.gplPage()
        XCTAssertTrue(page.contains("version 3 or (at your option) any later version"))
        XCTAssertTrue(page.hasSuffix(text))
    }

    /// licence.md 5.2: every package of the build's Package.resolved has its licence file in the
    /// app, at the pinned version and revision, and each of its files is on the third-party page
    /// in full. Fails when scripts/gen-licences.py was not run after a change of the packages.
    func testEveryResolvedPackageHasItsLicenceInTheApp() throws {
        let pins = try resolvedPins()
        XCTAssertGreaterThanOrEqual(pins.count, 12)
        let packages = LicencePages.packages()
        let page = LicencePages.thirdPartyPage()
        XCTAssertFalse(page.contains("(missing)"))
        for pin in pins {
            guard let package = packages.first(where: { $0.identity == pin.identity }) else {
                XCTFail("\(pin.identity) \(pin.state.version ?? "") has no licence text in the app")
                continue
            }
            XCTAssertEqual(package.location, pin.location, pin.identity)
            XCTAssertEqual(package.version, pin.state.version ?? "", pin.identity)
            XCTAssertEqual(package.revision, pin.state.revision, pin.identity)
            XCTAssertTrue(package.files.contains { !$0.uppercased().hasPrefix("NOTICE") },
                          "\(pin.identity): a licence file, not only a NOTICE")
            for file in package.files {
                guard let text = LicencePages.text(of: file, in: package) else {
                    XCTFail("\(pin.identity): \(file) is not in the app")
                    continue
                }
                XCTAssertTrue(page.contains("\(LicencePages.heading(of: file, in: package))\n\n\(text)"),
                              "\(pin.identity): \(file) in full on the page")
            }
        }
        XCTAssertEqual(Set(packages.map(\.identity)), Set(pins.map(\.identity)),
                       "the app lists exactly the resolved packages")
        // Known lines: SwiftTerm's MIT notice and SwiftNIO's NOTICE.
        XCTAssertTrue(page.contains("Copyright (c) 2019-2026 Miguel de Icaza"))
        XCTAssertTrue(page.contains("Permission is hereby granted, free of charge, to any person obtaining"))
        XCTAssertTrue(page.contains("The SwiftNIO Project licenses this file to you under the Apache License"))
        XCTAssertTrue(page.contains("=== swift-nio 2.105.0, NOTICE.txt ==="))
    }

    /// mosh 1.4.0's COPYING.iOS, byte for byte (755 bytes, SHA-256 8042495d...8199), as quoted in
    /// licence.md section 2.
    private static let moshCopyingIOS = """
    The Mosh developers are aware that the terms of service that apply to
    apps distributed via Apple's App Store services may conflict with
    rights granted under Mosh's license, the GNU General Public License,
    version 3. The Mosh copyright holders do not wish this conflict to
    prevent the otherwise-compliant distribution of Mosh-derived apps via
    the App Store. Therefore, we have committed not to pursue any license
    violation that results solely from the conflict between the GPLv3 and
    the Apple App Store terms of service. In other words, as long as you
    comply with the GPL in all other respects, including its requirements
    to provide users with source code and the text of the license, we will
    not object to your distribution of Mosh through the App Store.

    """
    private static let moshCopyingIOSSHA256 = "8042495ddc8d99b883335d53552554eccf825fc1f0ba487d0f8e6656baaa8199"

    /// licence.md 5.5: COPYING.iOS ships in the app, starts with the owner's section 7 permission
    /// and ends with mosh's own COPYING.iOS unchanged, and the page shows the whole file.
    func testTheAppStorePermissionEndsWithMoshsStatementUnchanged() throws {
        let data = try XCTUnwrap(LicencePages.appStorePermissionData(), "COPYING.iOS is in the app")
        let mosh = Data(Self.moshCopyingIOS.utf8)
        XCTAssertEqual(mosh.count, 755)
        XCTAssertEqual(SHA256.hash(data: mosh).map { String(format: "%02x", $0) }.joined(),
                       Self.moshCopyingIOSSHA256, "the reference text in this test is mosh's file")
        XCTAssertGreaterThan(data.count, mosh.count)
        let tail = data.suffix(mosh.count)
        XCTAssertEqual(SHA256.hash(data: tail).map { String(format: "%02x", $0) }.joined(),
                       Self.moshCopyingIOSSHA256, "the bundled COPYING.iOS ends with mosh's statement unchanged")
        XCTAssertEqual(tail, mosh)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("Additional permission under GNU GPL version 3 section 7\n\n"
                                     + "iOS-mosh is Copyright (C) 2026 Patrick van Staveren. As the copyright "
                                     + "holder of iOS-mosh's own code, including the Swift code in this "
                                     + "repository that is ported from mosh, I give this additional permission"),
                      String(text.prefix(300)))
        XCTAssertTrue(text.contains("It is reproduced here, unchanged, from the file COPYING.iOS of mosh 1.4.0:\n\n"
                                    + Self.moshCopyingIOS))
        let page = LicencePages.appStorePermissionPage()
        XCTAssertEqual(page + "\n", text, "the page is the whole file")
    }

    /// licence.md 5.3: the copyright notice names the owner and mosh's holders, and says the code
    /// is ported from mosh, not that it follows it.
    func testAboutNamesTheCopyrightHolders() {
        let about = AppTexts.about(version: "0.2", build: "1", sha: "abcdef0")
        XCTAssertTrue(about.contains(
            "Copyright (C) 2026 Patrick van Staveren. Portions Copyright 2012 Keith Winstein and the "
            + "mosh authors (https://mosh.org), ported from mosh 1.4.0."), about)
        XCTAssertTrue(about.contains("ported from mosh 1.4.0 (https://mosh.org), GPL version 3 or later"))
        XCTAssertFalse(about.contains("the iOS-mosh authors"))
        XCTAssertFalse(about.contains("follow mosh"))
        XCTAssertTrue(about.contains("\"GNU General Public License v3\""))
        XCTAssertTrue(about.contains("\"Third-party licences\""))
    }
}
