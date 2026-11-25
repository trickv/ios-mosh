import Foundation

/// The licence pages under Settings > About (docs/notes/publication/licence.md section 5, items 1,
/// 2 and 5): the GPL text of the program, the App Store permission, and the licence and NOTICE
/// files of every Swift package the build resolves. All texts are read from the bundle, never
/// typed into the code:
/// - `LICENSE` is the repository's own `LICENSE` (App/project.yml copies it into the app);
/// - `COPYING.iOS` is the repository's own `COPYING.iOS` (likewise);
/// - `ThirdPartyLicences/` is written by `scripts/gen-licences.py` from `Package.resolved` and the
///   packages' own files at exactly the pinned revisions, with `packages.json` listing them.
enum LicencePages {
    static let gplResource = "LICENSE"
    static let thirdPartyFolder = "ThirdPartyLicences"

    /// One entry of `ThirdPartyLicences/packages.json`.
    struct Package: Decodable, Equatable {
        let identity: String
        let name: String
        let location: String
        let version: String
        let revision: String
        /// The licence and NOTICE files of the package, as they are named in its repository.
        let files: [String]
    }

    private struct Manifest: Decodable {
        let packages: [Package]
    }

    /// The full GPL text (`LICENSE`) as it is in the file (only the final newline dropped), or ""
    /// when it is not in the bundle.
    static func gplText(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: gplResource, withExtension: nil),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        while text.last?.isNewline == true { text.removeLast() }
        return text
    }

    /// The packages listed in the bundle's `packages.json`, in its order; empty when it is missing.
    static func packages(bundle: Bundle = .main) -> [Package] {
        guard let url = bundle.url(forResource: "packages", withExtension: "json", subdirectory: thirdPartyFolder),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.packages
    }

    /// One licence or NOTICE file of a package, as shipped; nil when it is not in the bundle.
    static func text(of file: String, in package: Package, bundle: Bundle = .main) -> String? {
        guard let url = bundle.resourceURL?.appendingPathComponent(thirdPartyFolder)
            .appendingPathComponent(package.identity).appendingPathComponent(file),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        return clean.isEmpty ? nil : clean
    }

    /// The heading of one file on the third-party page.
    static func heading(of file: String, in package: Package) -> String {
        "=== \(package.name) \(package.version), \(file) ==="
    }

    /// The page "GNU General Public License v3".
    static func gplPage(bundle: Bundle = .main) -> String {
        """
        iOS-mosh is distributed under the GNU General Public License, version 3 or (at your \
        option) any later version. This is the full text of version 3.


        \(gplText(bundle: bundle))
        """
    }

    /// `COPYING.iOS` at the top of the repository (App/project.yml copies it into the app): the
    /// owner's additional permission under GPLv3 section 7 for the App Store and TestFlight,
    /// followed by mosh's own COPYING.iOS, unchanged (docs/notes/publication/licence.md item 5).
    static let appStorePermissionResource = "COPYING.iOS"

    /// `COPYING.iOS` byte for byte, or nil when it is not in the bundle.
    static func appStorePermissionData(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: appStorePermissionResource, withExtension: nil) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The page "App Store permission": `COPYING.iOS` as it is in the file (only the final newline
    /// dropped), or "" when it is not in the bundle.
    static func appStorePermissionPage(bundle: Bundle = .main) -> String {
        guard let data = appStorePermissionData(bundle: bundle),
              var text = String(data: data, encoding: .utf8) else { return "" }
        while text.last?.isNewline == true { text.removeLast() }
        return text
    }

    /// The page "Third-party licences": every package, then each of its files in full.
    static func thirdPartyPage(bundle: Bundle = .main) -> String {
        let packages = packages(bundle: bundle)
        let list = packages.map { "• \($0.name) \($0.version), \($0.location)" }.joined(separator: "\n")
        let texts = packages.flatMap { package in
            package.files.map { file in
                "\(heading(of: file, in: package))\n\n\(text(of: file, in: package, bundle: bundle) ?? "(missing)")"
            }
        }.joined(separator: "\n\n\n")
        return """
        The app is built with these Swift packages, at exactly these versions (the build's \
        Package.resolved). Not every one of them is linked into the app on iOS; their licences \
        are all here. Each package's licence file and, where it has one, its NOTICE file follow \
        in full, as they are in that version. The licences of the terminal font are on the About \
        page.

        \(list)


        \(texts)
        """
    }
}
