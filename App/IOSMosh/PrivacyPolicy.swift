import Foundation

/// The page "Privacy" under Settings (App Review Guideline 5.1.1(i): the privacy policy must also
/// be "within the app in an easily accessible manner"). Its text is the repository's own
/// `PRIVACY.md`, which App/project.yml copies into the app, so that it shows without a network;
/// the page also gives the policy's address on GitHub, where its current version is.
enum PrivacyPolicy {
    static let resource = "PRIVACY.md"
    static let url = AppTexts.sourceURL + "/blob/main/PRIVACY.md"

    /// `PRIVACY.md` as it is in the file (only the final newline dropped), or "" when it is not
    /// in the bundle.
    static func text(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: resource, withExtension: nil),
              let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8) else { return "" }
        while text.last?.isNewline == true { text.removeLast() }
        return text
    }

    /// The page: where the policy is online, then the whole file.
    static func page(bundle: Bundle = .main) -> String {
        """
        The privacy policy of iOS-mosh, as it was when this version was built (the file \
        PRIVACY.md in the source code). Its current version is at \(url)


        \(text(bundle: bundle))
        """
    }
}
