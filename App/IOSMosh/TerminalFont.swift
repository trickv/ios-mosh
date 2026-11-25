import CoreText
import UIKit

/// The terminal's font (docs/PLAN.md section 5: a bundled monospace font with powerline glyphs):
/// Hack Nerd Font Mono, Nerd Fonts v3.5.1, four faces in `App/Fonts` (provenance, hashes and
/// licences in `App/Fonts/README.md`). iOS registers them from `UIAppFonts` in Info.plist; they
/// are loaded here by PostScript name. Bold and italic text use the real bold and italic faces,
/// not faces derived by SwiftTerm.
enum TerminalFont {
    static let familyName = "Hack Nerd Font Mono"
    /// PostScript names, as in the fonts' name tables.
    static let regularName = "HackNFM-Regular"
    static let boldName = "HackNFM-Bold"
    static let italicName = "HackNFM-Italic"
    static let boldItalicName = "HackNFM-BoldItalic"
    static let faceNames = [regularName, boldName, italicName, boldItalicName]
    /// The bundle folder that holds the font files and `licenses/`.
    static let folder = "Fonts"
    static let fileNames = ["HackNerdFontMono-Regular", "HackNerdFontMono-Bold",
                            "HackNerdFontMono-Italic", "HackNerdFontMono-BoldItalic"]

    /// The faces the terminal draws with, at one size.
    struct Faces {
        let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont

        var all: [UIFont] { [normal, bold, italic, boldItalic] }

        /// UI tests: `Regular,Bold,Italic,BoldItalic@size` with the PostScript names.
        var summary: String {
            all.map(\.fontName).joined(separator: ",") + "@\(Int(normal.pointSize.rounded()))"
        }
    }

    /// The four bundled faces at `size`. A face that does not load (it should never happen: the
    /// files are in the bundle) falls back to the monospaced system font of that weight and slant,
    /// so the terminal still draws; the fallback shows in `Faces.summary`.
    static func faces(size: CGFloat) -> Faces {
        func face(_ name: String, bold: Bool, italic: Bool) -> UIFont {
            if let font = UIFont(name: name, size: size) { return font }
            let system = UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
            guard italic, let descriptor = system.fontDescriptor.withSymbolicTraits(
                system.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return system }
            return UIFont(descriptor: descriptor, size: size)
        }
        return Faces(normal: face(regularName, bold: false, italic: false),
                     bold: face(boldName, bold: true, italic: false),
                     italic: face(italicName, bold: false, italic: true),
                     boldItalic: face(boldItalicName, bold: true, italic: true))
    }

    /// The licence texts of the font and of every glyph set in it, from the bundle, each under its
    /// file name, in file-name order. Empty if the folder is missing.
    static func licenceTexts(bundle: Bundle = .main) -> String {
        guard let urls = bundle.urls(forResourcesWithExtension: nil, subdirectory: folder + "/licenses") else {
            return ""
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
            return "=== \(url.lastPathComponent) ===\n\n\(clean)"
        }.joined(separator: "\n\n\n")
    }

    /// The Font Licences page: what the font is and where it comes from, then every licence text.
    static func licencePage(bundle: Bundle = .main) -> String {
        """
        The terminal draws with \(familyName) (Hack 3.003 with the Nerd Fonts v3.5.1 glyphs, \
        https://github.com/ryanoasis/nerd-fonts). Hack: MIT License and Bitstream Vera License \
        (https://github.com/source-foundry/Hack). Glyph sets: Powerline Symbols, Powerline Extra \
        Symbols, Octicons, Devicons, Font Awesome Extension, Seti UI, IEC Power Symbols (MIT); \
        Codicons by Microsoft (https://github.com/microsoft/vscode-codicons) and Font Awesome \
        Free by Fonticons, Inc. (https://fontawesome.com) (CC BY 4.0, \
        https://creativecommons.org/licenses/by/4.0/; glyphs resized into the font); Material Design Icons (Apache License 2.0); \
        Pomicons and Weather Icons (SIL Open Font License 1.1); Font Logos (The Unlicense). \
        The font files are shipped as released and are not covered by this program's GPL \
        licence. Their licence texts follow.


        \(licenceTexts(bundle: bundle))
        """
    }
}
