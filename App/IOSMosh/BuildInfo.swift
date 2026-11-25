import Foundation

/// Which build this is. scripts/mac.sh stamps the commit count and SHA, so the
/// About page and the logs agree on what is installed.
enum BuildInfo {
    static var version: String { string("CFBundleShortVersionString") }
    static var build: String { string("CFBundleVersion") }
    static var gitSHA: String { string("IOSMoshGitSHA") }
    static var summary: String { "\(version) (\(build)) \(gitSHA)" }

    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "unknown"
    }
}
