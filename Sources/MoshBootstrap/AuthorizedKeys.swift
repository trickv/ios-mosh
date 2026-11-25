import MoshKeys

/// "Install my key on this host": the command that adds a public key line to
/// `~/.ssh/authorized_keys`.
///
/// The work is done by a fixed POSIX `sh` script. The key reaches it as two arguments, never as
/// part of the script text, and the whole command consists of single-quoted words, so neither
/// the login shell nor `sh` expands anything in the key line or its comment.
///
/// The script
/// - creates `~/.ssh` with mode 700 if it is missing (an existing directory is left as it is),
/// - creates `authorized_keys` with mode 600 if it is missing,
/// - does nothing if a line with the same key type and key data is already there, whatever its
///   comment or options,
/// - otherwise appends the line, after first ending an unterminated last line, so existing
///   content is never changed or joined with the new line.
public enum AuthorizedKeys {
    public enum Outcome: Equatable, Sendable {
        case added
        case alreadyPresent
    }

    public enum InstallError: Error, Equatable, Sendable {
        /// The script ran and reported a failure, or its answer is not understood.
        case failed(exitStatus: Int?, output: String)
    }

    static let addedMarker = "MOSH-KEY-ADDED"
    static let presentMarker = "MOSH-KEY-PRESENT"

    /// `$1` is "keytype base64", `$2` the full line. One line, because csh cannot quote a line
    /// break.
    static let script = [
        "umask 077",
        "d=\"$HOME/.ssh\"",
        "f=\"$d/authorized_keys\"",
        "if [ ! -d \"$d\" ]; then mkdir -p \"$d\" && chmod 700 \"$d\" || exit 71; fi",
        "if [ ! -e \"$f\" ]; then : > \"$f\" && chmod 600 \"$f\" || exit 72; fi",
        "if grep -F -q -- \"$1\" \"$f\"; then echo \(presentMarker); exit 0; fi",
        "if [ -s \"$f\" ] && [ -n \"$(tail -c 1 \"$f\")\" ]; then printf '\\n' >> \"$f\" || exit 73; fi",
        "printf '%s\\n' \"$2\" >> \"$f\" || exit 74",
        "echo \(addedMarker)",
    ].joined(separator: "; ")

    /// The command line for an SSH `exec` request.
    public static func installCommand(for key: OpenSSHPublicKey) -> String {
        let keyData = key.keyType + " " + key.blob.base64EncodedString()
        return [
            "sh", "-c", ShellQuote.alwaysQuote(script), "sh", ShellQuote.alwaysQuote(keyData),
            ShellQuote.alwaysQuote(key.line),
        ].joined(separator: " ")
    }

    /// Reads the script's answer.
    public static func outcome(exitStatus: Int?, output: String) throws -> Outcome {
        if exitStatus == 0 {
            if output.contains(addedMarker) { return .added }
            if output.contains(presentMarker) { return .alreadyPresent }
        }
        throw InstallError.failed(exitStatus: exitStatus, output: output)
    }
}
