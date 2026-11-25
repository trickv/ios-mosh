/// The UDP port or port range for `mosh-server -p`.
public struct UDPPortRange: Equatable, Hashable, Sendable {
    public let low: Int
    public let high: Int

    /// nil unless `1 <= low <= high <= 65535`.
    public init?(low: Int, high: Int) {
        guard low >= 1, high <= 65535, low <= high else { return nil }
        self.low = low
        self.high = high
    }

    public init?(port: Int) {
        self.init(low: port, high: port)
    }

    /// Parses `PORT` or `PORT:PORT2`, the forms `mosh-server -p` takes
    /// (`Connection::parse_portrange` in mosh's `network.cc`). White space around is ignored.
    public init?(_ text: String) {
        let trimmed = text.filter { $0 != " " && $0 != "\t" }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        func number(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.count <= 5, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int(part)
        }
        switch parts.count {
        case 1:
            guard let port = number(parts[0]) else { return nil }
            self.init(low: port, high: port)
        case 2:
            guard let low = number(parts[0]), let high = number(parts[1]) else { return nil }
            self.init(low: low, high: high)
        default:
            return nil
        }
    }

    /// The argument for `-p`.
    public var argument: String {
        low == high ? "\(low)" : "\(low):\(high)"
    }

    public func contains(_ port: Int) -> Bool {
        port >= low && port <= high
    }
}

/// Builds the command line that starts the server on the host:
///
///     <server> new -c 256 -s -l LANG=<locale> [-p <range>] [-- <remote command>]
///
/// The line is sent as an SSH `exec` request, so the host runs it as `$SHELL -c '<line>'` with
/// the user's login shell. Every part that comes from the user is one single-quoted word (see
/// `ShellQuote`), so no login shell expands or splits it.
///
/// **Server path.** `serverPath` is the per-host field "server prefix or path". It names one
/// program and is never a command with arguments:
/// - empty: `mosh-server`, found through the PATH of a non-login shell;
/// - no slash (`mosh-server-1.4`): a program name, found through the same PATH;
/// - a path whose last component starts with `mosh-server`
///   (`/opt/homebrew/bin/mosh-server`): the program itself;
/// - any other path, or one ending in a slash (`/opt/homebrew/bin`, `~/.local/bin/`): the
///   directory that holds the program, and `/mosh-server` is appended.
/// A leading `~/` is left outside the quotes so the login shell expands it to the home
/// directory.
///
/// **Remote command.** `mosh-server` does not run the text after `--` through a shell: it calls
/// `execvp` with those words. The remote command of a host (`tmux new -A -s $(hostname -s)`) is
/// meant to be a shell command, so it is passed as ONE quoted word to a shell that mosh-server
/// starts inside the session:
///
/// - `.loginShell` (the default): `-- sh -c 'exec "${SHELL:-/bin/sh}" -lc "$1"' sh '<command>'`.
///   The small `sh` script replaces itself with the user's own shell as a login shell, which
///   then interprets the command. A login shell reads the profile, so the command sees the same
///   PATH as an interactive login (on a Mac with Homebrew that is where `tmux` lives), and
///   `$(...)`, `;`, `&&`, pipes and quotes in the command mean what they mean in that shell.
///   Needs a login shell that accepts `-l -c` (sh, bash, zsh, ksh, dash, fish do; tcsh does not).
/// - `.sh`: `-- sh -c '<command>'`. Plain POSIX `sh`, no profile. For hosts whose login shell
///   cannot do `-lc`.
///
/// In both forms the outer login shell sees only single-quoted words, so the command is expanded
/// exactly once, inside the mosh session, and never by the shell that starts `mosh-server`.
public struct MoshServerCommand: Equatable, Sendable {
    public enum RemoteCommandShell: String, Equatable, Sendable, Codable {
        case loginShell
        case sh
    }

    public enum CommandError: Error, Equatable, Sendable {
        /// The named field contains a NUL byte or a line break, which cannot be sent through a
        /// shell command line.
        case unrepresentable(field: String)
        /// The locale is empty or contains characters outside `A-Z a-z 0-9 . _ - @`.
        case invalidLocale(String)
    }

    public static let defaultLocale = "en_US.UTF-8"
    public static let defaultServerName = "mosh-server"

    /// Server prefix or path; empty for the default.
    public var serverPath: String
    /// Value for `LANG` on the host. Must name a UTF-8 locale that exists there.
    public var locale: String
    public var portRange: UDPPortRange?
    /// Shell command to run in the session instead of the login shell; empty for none.
    public var remoteCommand: String
    public var remoteCommandShell: RemoteCommandShell

    public init(
        serverPath: String = "", locale: String = MoshServerCommand.defaultLocale,
        portRange: UDPPortRange? = nil, remoteCommand: String = "",
        remoteCommandShell: RemoteCommandShell = .loginShell
    ) {
        self.serverPath = serverPath
        self.locale = locale
        self.portRange = portRange
        self.remoteCommand = remoteCommand
        self.remoteCommandShell = remoteCommandShell
    }

    /// The script that hands the remote command to the user's login shell. `$1` is the command.
    static let loginShellTrampoline = "exec \"${SHELL:-/bin/sh}\" -lc \"$1\""

    /// The program word of the command line, quoted.
    public func serverWord() throws -> String {
        let trimmed = Self.trim(serverPath)
        guard ShellQuote.isRepresentable(trimmed) else {
            throw CommandError.unrepresentable(field: "serverPath")
        }
        if trimmed.isEmpty { return Self.defaultServerName }

        var path = trimmed
        if path.contains("/") {
            let endsWithSlash = path.hasSuffix("/")
            let lastComponent = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            if endsWithSlash || !lastComponent.hasPrefix(Self.defaultServerName) {
                // A directory (prefix): the program is inside it.
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                path += path.hasSuffix("/") ? Self.defaultServerName : "/" + Self.defaultServerName
            }
        }
        if path.hasPrefix("~/") {
            // The tilde must stay outside the quotes to be expanded.
            return "~/" + ShellQuote.quote(String(path.dropFirst(2)))
        }
        return ShellQuote.quote(path)
    }

    /// The whole command line for the SSH `exec` request.
    public func commandLine() throws -> String {
        let localeName = Self.trim(locale)
        guard !localeName.isEmpty,
            localeName.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
                    || byte == UInt8(ascii: "@")
            })
        else { throw CommandError.invalidLocale(locale) }

        var words = [try serverWord(), "new", "-c", "256", "-s", "-l", ShellQuote.quote("LANG=" + localeName)]
        if let portRange {
            words += ["-p", portRange.argument]
        }
        let command = Self.trim(remoteCommand)
        if !command.isEmpty {
            // A line break inside the command would be legal for sh but csh ends a quoted
            // string there; a remote command is one line.
            guard ShellQuote.isRepresentable(command) else {
                throw CommandError.unrepresentable(field: "remoteCommand")
            }
            words.append("--")
            switch remoteCommandShell {
            case .loginShell:
                words += ["sh", "-c", ShellQuote.alwaysQuote(Self.loginShellTrampoline), "sh", ShellQuote.alwaysQuote(command)]
            case .sh:
                words += ["sh", "-c", ShellQuote.alwaysQuote(command)]
            }
        }
        return words.joined(separator: " ")
    }

    private static func trim(_ text: String) -> String {
        var scalars = Substring.UnicodeScalarView(text.unicodeScalars)
        let isSpace: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
