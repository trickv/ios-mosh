import Foundation

/// What the platform must do to a session directory so that a device restore cannot bring an
/// old record back (review finding A-2).
///
/// Why it matters: the session key is a Keychain item of class "after first unlock, this device
/// only", and such an item is restored to the same device from that device's backup. If the
/// record's directory were in the backup too, a restore would put back `counters` with old
/// limits and an old clean mark next to a key that has been used past them: a resume would
/// reuse sequence numbers under that key (N1), and state numbers if the server still lives
/// (N2). The plan's rule "a key without its files deletes the record" covers this only if the
/// directory is not in the backup. So the directory is excluded when it is made, a record that
/// cannot be excluded is not made, and a record that is found not excluded is never resumed.
///
/// `SessionStore` calls `apply` right after it made the directory (storage step `dir.protect`),
/// before any file exists in it, and `verify` whenever a record is opened.
public protocol RecordProtection: Sendable {
    /// Excludes the directory from backups (and sets the platform's file protection). The
    /// directory was just made and is empty.
    /// - Throws: if it could not be done. The record is then not made.
    func apply(directory: String) throws

    /// Whether the directory is excluded from backups now.
    /// - Returns: false if it is not: the record may have come out of a backup and is never
    ///   resumed (the cold start deletes it and falls back).
    /// - Throws: if that cannot be found out now (the device is locked): "try again later".
    func verify(directory: String) throws -> Bool
}

/// For platforms without device backups (Linux: `moshcli`, the tests). Does nothing and says
/// yes. Explicitly not the Apple code: on Linux Foundation's `setResourceValues` returns
/// without error and the value reads back nil, which would make every record look restored.
public struct NoRecordProtection: RecordProtection {
    public init() {}
    public func apply(directory: String) throws {}
    public func verify(directory: String) throws -> Bool { true }
}

#if canImport(Darwin)
/// Apple platforms: the directory is excluded from iCloud and local backups
/// (`isExcludedFromBackup`), and on iOS it gets the protection class "until first user
/// authentication", which files made in it inherit (the plan's class for the record, so that a
/// session can be saved while the device is locked).
///
/// NEEDS THE MAC / THE PHONE (written on Linux, where this branch is not compiled):
/// - compile, and `RecordProtectionTests.testTheAppleProtectionReadsBack` under macOS
///   `swift test` (the attribute reads back after a create and after a snapshot replace);
/// - on the phone: the protection class reads back on the directory and on `counters` and
///   `snapshot`, and one backup and restore to the same phone ends in "record deleted", not in
///   a resume.
/// `verify` checks the backup exclusion only. The protection class is not a condition for a
/// resume: a wrong class cannot reuse a number, and the simulator does not report one.
public struct AppleRecordProtection: RecordProtection {
    public init() {}

    public func apply(directory: String) throws {
        var url = URL(fileURLWithPath: directory, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory)
        #endif
    }

    public func verify(directory: String) throws -> Bool {
        // A new URL value each time: resource values are cached per URL.
        var url = URL(fileURLWithPath: directory, isDirectory: true)
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup == true
    }
}
#endif

public enum RecordProtections {
    /// What a record gets when nothing else is said: the Apple protection on Apple platforms,
    /// none elsewhere.
    public static var platform: any RecordProtection {
        #if canImport(Darwin)
        return AppleRecordProtection()
        #else
        return NoRecordProtection()
        #endif
    }
}
