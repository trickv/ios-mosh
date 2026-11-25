import CoreText
@testable import IOSMosh
import UIKit
import XCTest

/// The bundled terminal font (docs/PLAN.md section 5, App/Fonts/README.md): the four Hack Nerd
/// Font Mono faces load from the app bundle by name, are fixed pitch, are the right weight and
/// slant, and have the powerline glyphs; the terminal view draws with them at every size.
final class TerminalFontTests: XCTestCase {
    private let powerline: [UniChar] = [0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3]

    func testTheFourFacesLoadFromTheBundleByName() throws {
        XCTAssertEqual(TerminalFont.faceNames.count, 4)
        for (name, file) in zip(TerminalFont.faceNames, TerminalFont.fileNames) {
            let bundled = try XCTUnwrap(Bundle.main.url(forResource: file, withExtension: "ttf",
                                                        subdirectory: TerminalFont.folder), file)
            let font = try XCTUnwrap(UIFont(name: name, size: 12), "\(name) is registered")
            XCTAssertEqual(font.fontName, name)
            XCTAssertEqual(font.familyName, TerminalFont.familyName)
            // Loaded from the file in the bundle, not from a font installed elsewhere.
            let url = try XCTUnwrap(CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL, name)
            XCTAssertEqual(url.resolvingSymlinksInPath().standardizedFileURL,
                           bundled.resolvingSymlinksInPath().standardizedFileURL, name)
        }
        XCTAssertEqual(Set(UIFont.fontNames(forFamilyName: TerminalFont.familyName)), Set(TerminalFont.faceNames))
    }

    func testTheFacesAreFixedPitchWithTheRightWeightAndSlant() throws {
        let faces = TerminalFont.faces(size: 12)
        XCTAssertEqual(faces.all.map(\.fontName), TerminalFont.faceNames, "no fallback face")
        let expected: [(bold: Bool, italic: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        var widths: [CGFloat] = []
        for (font, traits) in zip(faces.all, expected) {
            let ctFont = font as CTFont
            let symbolic = CTFontGetSymbolicTraits(ctFont)
            XCTAssertTrue(symbolic.contains(.traitMonoSpace), "\(font.fontName) says it is monospaced")
            XCTAssertEqual(symbolic.contains(.traitBold), traits.bold, "\(font.fontName) bold")
            XCTAssertEqual(symbolic.contains(.traitItalic), traits.italic, "\(font.fontName) italic")
            // Every glyph one cell wide: ASCII of all shapes, a box-drawing line and the powerline
            // glyphs have the same advance.
            let sample: [UniChar] = Array("iW_m@|0".utf16) + [0x2500] + powerline
            var glyphs = [CGGlyph](repeating: 0, count: sample.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(ctFont, sample, &glyphs, sample.count), font.fontName)
            var advances = [CGSize](repeating: .zero, count: sample.count)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
            let width = try XCTUnwrap(advances.first?.width)
            XCTAssertGreaterThan(width, 0)
            for (index, advance) in advances.enumerated() {
                XCTAssertEqual(advance.width, width, accuracy: 0.001,
                               "\(font.fontName): U+\(String(sample[index], radix: 16, uppercase: true))")
            }
            widths.append(width)
        }
        XCTAssertEqual(Set(widths).count, 1, "all four faces have one cell width: \(widths)")
    }

    func testEveryFaceHasThePowerlineGlyphs() throws {
        for font in TerminalFont.faces(size: 14).all {
            var glyphs = [CGGlyph](repeating: 0, count: powerline.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, powerline, &glyphs, powerline.count),
                          "\(font.fontName) maps U+E0B0 to U+E0B3")
            XCTAssertFalse(glyphs.contains(0), "\(font.fontName): \(glyphs)")
            XCTAssertEqual(Set(glyphs).count, 4, "four different glyphs in \(font.fontName)")
            // A glyph with a shape, not an empty one: its outline has a size.
            var boxes = [CGRect](repeating: .zero, count: glyphs.count)
            CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, glyphs, &boxes, glyphs.count)
            for box in boxes { XCTAssertGreaterThan(box.width * box.height, 0, "\(font.fontName): \(boxes)") }
        }
    }

    @MainActor
    func testTheTerminalViewDrawsWithTheBundledFacesAtEverySize() throws {
        let surface = SwiftTermSurface()
        XCTAssertTrue(surface.appearanceDescription().contains(
            "font=HackNFM-Regular,HackNFM-Bold,HackNFM-Italic,HackNFM-BoldItalic@12 "),
                      surface.appearanceDescription())
        for size in [AppSettings.fontSizeRange.lowerBound, 13, AppSettings.fontSizeRange.upperBound] {
            surface.fontSize = size
            XCTAssertEqual(surface.fontSize, size)
            XCTAssertTrue(surface.appearanceDescription().contains(
                "font=HackNFM-Regular,HackNFM-Bold,HackNFM-Italic,HackNFM-BoldItalic@\(Int(size)) "),
                          surface.appearanceDescription())
        }
    }

    func testTheLicencesAreInTheBundleAndOnTheAboutPage() throws {
        let texts = TerminalFont.licenceTexts()
        // Hack (MIT, Bitstream Vera), Nerd Fonts (MIT, OFL), and the licences of the glyph sets.
        for needle in ["Copyright (c) 2018 Source Foundry Authors", "BITSTREAM VERA LICENSE",
                       "SIL OPEN FONT LICENSE Version 1.1", "Attribution 4.0 International",
                       "Apache License", "Version 2.0, January 2004", "Kim Silkebækken",
                       "with Reserved Font Name Pomicons", "Fonticons, Inc.", "Pictogrammers Free License",
                       "This is free and unencumbered software released into the public domain",
                       "Copyright (c) 2023 GitHub Inc.", "Copyright (c) 2015 konpa",
                       "Copyright (c) 2017 André Luiz Gava", "Copyright (c) 2014 Jesse Weed",
                       "Copyright (c) 2013 Joe Loughry", "Copyright (c) 2016 Ryan L McIntyre",
                       "Erik Flowers"] {
            XCTAssertTrue(texts.contains(needle), needle)
        }
        XCTAssertEqual(texts.components(separatedBy: "=== ").count - 1, 18, "every file of App/Fonts/licenses")
        let about = AppTexts.about(version: "0.1", build: "1", sha: "abcdef0")
        XCTAssertTrue(about.contains("• Hack Nerd Font Mono (the terminal font), Nerd Fonts v3.5.1"), about)
        XCTAssertTrue(about.contains("Font licences"))
        XCTAssertTrue(about.contains("=== Hack-LICENSE.md ==="))
        XCTAssertTrue(about.contains("Attribution 4.0 International"))
    }
}
