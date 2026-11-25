/// Quoting for text that a remote shell will read.
///
/// Everything this module sends as an SSH `exec` command is run as `$SHELL -c '<command>'` by
/// the user's login shell, which may be sh, bash, zsh, fish or csh. Single quotes are the one
/// form all of them read the same way: no expansion of any kind inside, and no way to write a
/// single quote inside. A single quote in the text is therefore written as `'\''` (close the
/// quote, an escaped quote, open again), which also means the same in all of these shells.
public enum ShellQuote {
    /// One shell word that evaluates to exactly `text`. Words made only of characters that no
    /// shell treats specially are returned as they are, so ordinary commands stay readable.
    public static func quote(_ text: String) -> String {
        let bytes = Array(text.utf8)
        if let first = bytes.first, isPlain(first),
            bytes.allSatisfy({ isPlain($0) || $0 == UInt8(ascii: "=") })
        {
            return text
        }
        return alwaysQuote(text)
    }

    /// The same, but always wrapped in single quotes.
    public static func alwaysQuote(_ text: String) -> String {
        var out = "'"
        for character in text {
            if character == "'" {
                out += "'\\''"
            } else {
                out.append(character)
            }
        }
        out += "'"
        return out
    }

    /// Several words joined with spaces, each quoted.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// Whether the text can be sent through a shell command line at all. A NUL byte cannot be
    /// part of a command line argument, and csh ends a quoted string at a line break.
    public static func isRepresentable(_ text: String, allowLineBreaks: Bool = false) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar.value == 0 { return false }
            if !allowLineBreaks, scalar == "\n" || scalar == "\r" { return false }
            return true
        }
    }

    // Letters, digits and the punctuation that is plain in sh, bash, zsh, fish and csh, in any
    // position of a word. "~" is left out (a leading "~" is expanded), and "=" is plain only
    // after the first character (zsh expands a leading "=").
    private static func isPlain(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"),
            UInt8(ascii: ":"), UInt8(ascii: ","), UInt8(ascii: "+"), UInt8(ascii: "@"):
            return true
        default:
            return false
        }
    }
}
