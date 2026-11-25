// The script language of `moshcli connect` (docs/PLAN.md "Test tools"): one command per line.
import Foundation

/// One line of a script.
enum ScriptCommand: Equatable {
    /// `type TEXT` and `key NAME`: bytes to send as keystrokes.
    case type([UInt8])
    /// `resize W H`
    case resize(width: Int, height: Int)
    /// `wait-ack [TIMEOUT_MS]`: until the server has acknowledged everything typed.
    case waitAck(timeout: UInt64)
    /// `expect TEXT TIMEOUT_MS`: TEXT appears in the host bytes received since the last expect.
    case expect([UInt8], timeout: UInt64)
    /// `expect-screen TEXT TIMEOUT_MS`: a row of the newest screen contains TEXT.
    case expectScreen(String, timeout: UInt64)
    /// `settle MS`: no new server state for MS.
    case settle(UInt64)
    /// `sleep MS`
    case sleep(UInt64)
    /// `rebind`: replace the socket (new source port).
    case rebind
    /// `quiesce` and `quiesce --after-send`
    case quiesce(afterSend: Bool)
    /// `resume`: continue after a quiesce with the same connection object.
    case resume
    /// `resume-mem [--drop-first N]`: export the state, discard the connection object, build a
    /// new one from the exported value with a gate that starts at the old reserved limits and a
    /// new socket. Quiesces first if the script has not. With `--drop-first N` the first N
    /// datagrams of the new connection are not sent.
    case resumeMem(dropFirst: Int)
    /// `dump-screen FILE`: the rendered screen, one line per row.
    case dumpScreen(String)
    /// `dump-bytes FILE`: every host-bytes string received so far, raw.
    case dumpBytes(String)
    /// `shutdown`: ask the server to end the session and wait for its acknowledgment.
    case shutdown
    /// `expect-display TEXT TIMEOUT_MS`: like `expect-screen`, on the shown frame (local echo).
    case expectDisplay(String, timeout: UInt64)
    /// `expect-predicted TEXT TIMEOUT_MS`: one sample in which the shown frame contains TEXT and
    /// the remote screen does not.
    case expectPredicted(String, timeout: UInt64)
    /// `expect-display-settled TIMEOUT_MS`: the shown frame equals the remote screen.
    case expectDisplaySettled(timeout: UInt64)
    /// `expect-underlined TEXT TIMEOUT_MS`: TEXT is on a row of the shown frame, every cell of it
    /// underlined.
    case expectUnderlined(String, timeout: UInt64)
    /// `dump-display FILE`: as `dump-screen`, from the shown frame.
    case dumpDisplay(String)
}

struct ScriptLine: Equatable {
    /// 1-based line number in the script file.
    var number: Int
    var text: String
    var command: ScriptCommand
}

struct ScriptError: Error, CustomStringConvertible, Equatable {
    var line: Int
    var message: String
    var description: String { "script line \(line): \(message)" }
}

enum Script {
    static let defaultWaitAckTimeout: UInt64 = 30_000

    static let help = """
        Script commands, one per line (# starts a comment line):
          type TEXT               keystrokes; escapes \\n \\r \\t \\e \\\\ \\s (space) \\xHH
          key NAME                enter tab esc up down left right pgup pgdn ctrl-<letter>
          resize W H
          wait-ack [TIMEOUT_MS]   until the server acknowledged everything typed (default 30000)
          expect TEXT TIMEOUT_MS  TEXT (same escapes) appears in the host bytes received since
                                  the previous expect; exit 1 on timeout
          expect-screen TEXT TIMEOUT_MS
                                  a row of the newest rendered screen contains TEXT (same
                                  escapes); exit 1 on timeout. Text that scrolled off or was
                                  overwritten is not found: use expect for that
          settle MS               no new server state for MS
          sleep MS
          rebind                  replace the socket (new source port)
          quiesce                 stop sending, close the socket
          quiesce --after-send    send the pending state, read nothing more, then quiesce
          resume                  continue after quiesce with the same connection object
          resume-mem [--drop-first N]
                                  export the state, discard the connection, continue in a new
                                  connection object (new gate block, new socket); with
                                  --drop-first the first N datagrams after the resume are lost
          dump-screen FILE        write the rendered screen, one line per row, trailing blanks
                                  cut (the form of tmux capture-pane -p)
          dump-bytes FILE         write the accumulated host bytes (raw)
          shutdown                clean client-initiated shutdown
          expect-display TEXT TIMEOUT_MS
                                  like expect-screen, on the shown frame (with local echo's
                                  guesses; the remote screen without --predict)
          expect-predicted TEXT TIMEOUT_MS
                                  one sample in which the shown frame has TEXT on a row and
                                  the remote screen has not: a guess
          expect-display-settled TIMEOUT_MS
                                  the shown frame equals the remote screen: no guess drawn
          expect-underlined TEXT TIMEOUT_MS
                                  TEXT is on a row of the shown frame and every cell of it is
                                  underlined (one cell per character)
          dump-display FILE       as dump-screen, from the shown frame

        """

    /// Parses a whole script. Blank lines and lines starting with `#` are skipped.
    static func parse(_ text: String) throws -> [ScriptLine] {
        var lines: [ScriptLine] = []
        var number = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            var line = Substring(raw)
            if line.hasSuffix("\r") { line = line.dropLast() }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            do {
                lines.append(ScriptLine(number: number, text: String(trimmed), command: try parseLine(trimmed)))
            } catch let error as ScriptError {
                throw ScriptError(line: number, message: error.message)
            }
        }
        return lines
    }

    private static func fail(_ message: String) -> ScriptError {
        ScriptError(line: 0, message: message)
    }

    private static func parseLine(_ line: Substring) throws -> ScriptCommand {
        let name: Substring
        let rest: Substring
        if let space = line.firstIndex(of: " ") {
            name = line[..<space]
            rest = line[line.index(after: space)...]
        } else {
            name = line
            rest = ""
        }
        let words = rest.split(separator: " ")

        func milliseconds(_ word: Substring?, _ what: String) throws -> UInt64 {
            guard let word, let value = UInt64(word), value <= 86_400_000 else {
                throw fail("\(name) needs \(what) in milliseconds")
            }
            return value
        }

        switch name {
        case "type":
            // Everything after the one space, trailing spaces included.
            let bytes = try unescape(rest)
            guard !bytes.isEmpty else { throw fail("type needs text") }
            return .type(bytes)
        case "key":
            guard words.count == 1 else { throw fail("key needs one name") }
            return .type(try keyBytes(words[0]))
        case "resize":
            guard words.count == 2, let width = Int(words[0]), let height = Int(words[1]),
                  (1...UInt16.max.asInt).contains(width), (1...UInt16.max.asInt).contains(height) else {
                throw fail("resize needs a width and a height")
            }
            return .resize(width: width, height: height)
        case "wait-ack":
            guard words.count <= 1 else { throw fail("wait-ack takes at most a timeout") }
            return .waitAck(timeout: words.isEmpty ? defaultWaitAckTimeout : try milliseconds(words.first, "a timeout"))
        case "expect":
            // The last word is the timeout; the text is everything before it.
            guard let lastSpace = rest.lastIndex(of: " ") else { throw fail("expect needs a text and a timeout") }
            let timeout = try milliseconds(rest[rest.index(after: lastSpace)...], "a timeout")
            let bytes = try unescape(rest[..<lastSpace])
            guard !bytes.isEmpty else { throw fail("expect needs a text") }
            return .expect(bytes, timeout: timeout)
        case "expect-screen":
            guard let lastSpace = rest.lastIndex(of: " ") else { throw fail("expect-screen needs a text and a timeout") }
            let timeout = try milliseconds(rest[rest.index(after: lastSpace)...], "a timeout")
            let bytes = try unescape(rest[..<lastSpace])
            guard !bytes.isEmpty else { throw fail("expect-screen needs a text") }
            guard let text = String(bytes: bytes, encoding: .utf8) else { throw fail("expect-screen needs UTF-8 text") }
            return .expectScreen(text, timeout: timeout)
        case "expect-display", "expect-predicted", "expect-underlined":
            guard let lastSpace = rest.lastIndex(of: " ") else { throw fail("\(name) needs a text and a timeout") }
            let timeout = try milliseconds(rest[rest.index(after: lastSpace)...], "a timeout")
            let bytes = try unescape(rest[..<lastSpace])
            guard !bytes.isEmpty else { throw fail("\(name) needs a text") }
            guard let text = String(bytes: bytes, encoding: .utf8) else { throw fail("\(name) needs UTF-8 text") }
            switch name {
            case "expect-display": return .expectDisplay(text, timeout: timeout)
            case "expect-predicted": return .expectPredicted(text, timeout: timeout)
            default: return .expectUnderlined(text, timeout: timeout)
            }
        case "expect-display-settled":
            guard words.count == 1 else { throw fail("expect-display-settled needs a timeout") }
            return .expectDisplaySettled(timeout: try milliseconds(words.first, "a timeout"))
        case "dump-display":
            guard !rest.isEmpty else { throw fail("dump-display needs a file") }
            return .dumpDisplay(String(rest))
        case "settle":
            guard words.count == 1 else { throw fail("settle needs a time") }
            return .settle(try milliseconds(words.first, "a time"))
        case "sleep":
            guard words.count == 1 else { throw fail("sleep needs a time") }
            return .sleep(try milliseconds(words.first, "a time"))
        case "rebind":
            guard words.isEmpty else { throw fail("rebind takes no argument") }
            return .rebind
        case "quiesce":
            if words.isEmpty { return .quiesce(afterSend: false) }
            guard words == ["--after-send"] else { throw fail("quiesce takes only --after-send") }
            return .quiesce(afterSend: true)
        case "resume":
            guard words.isEmpty else { throw fail("resume takes no argument") }
            return .resume
        case "resume-mem":
            if words.isEmpty { return .resumeMem(dropFirst: 0) }
            guard words.count == 2, words[0] == "--drop-first", let count = Int(words[1]), count >= 0 else {
                throw fail("resume-mem takes only --drop-first N")
            }
            return .resumeMem(dropFirst: count)
        case "dump-screen":
            guard !rest.isEmpty else { throw fail("dump-screen needs a file") }
            return .dumpScreen(String(rest))
        case "dump-bytes":
            guard !rest.isEmpty else { throw fail("dump-bytes needs a file") }
            return .dumpBytes(String(rest))
        case "shutdown":
            guard words.isEmpty else { throw fail("shutdown takes no argument") }
            return .shutdown
        default:
            throw fail("unknown command \(name)")
        }
    }

    /// C-style escapes: `\n`, `\r`, `\t`, `\e` (ESC), `\\`, `\s` (a space, for text that must end
    /// in one where an editor would strip it), `\xHH`. Everything else is UTF-8 as written.
    static func unescape(_ text: Substring) throws -> [UInt8] {
        var out: [UInt8] = []
        let bytes = Array(text.utf8)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                continue
            }
            guard index < bytes.count else { throw fail("a backslash at the end of the text") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): out.append(0x0a)
            case UInt8(ascii: "r"): out.append(0x0d)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "e"): out.append(0x1b)
            case UInt8(ascii: "s"): out.append(0x20)
            case UInt8(ascii: "\\"): out.append(0x5c)
            case UInt8(ascii: "x"):
                guard index + 1 < bytes.count, let high = hex(bytes[index]), let low = hex(bytes[index + 1]) else {
                    throw fail("\\x needs two hex digits")
                }
                out.append(high << 4 | low)
                index += 2
            default:
                throw fail("unknown escape \\\(String(UnicodeScalar(escape)))")
            }
        }
        return out
    }

    /// The bytes a named key sends. Arrow keys are in normal cursor-key mode (`ESC [ A`): without
    /// the terminal model moshcli does not know whether the application switched to `ESC O A`.
    static func keyBytes(_ name: Substring) throws -> [UInt8] {
        switch name {
        case "enter": return [0x0d]
        case "tab": return [0x09]
        case "esc": return [0x1b]
        case "up": return Array("\u{1b}[A".utf8)
        case "down": return Array("\u{1b}[B".utf8)
        case "right": return Array("\u{1b}[C".utf8)
        case "left": return Array("\u{1b}[D".utf8)
        case "pgup": return Array("\u{1b}[5~".utf8)
        case "pgdn": return Array("\u{1b}[6~".utf8)
        default:
            let bytes = Array(name.utf8)
            if name.hasPrefix("ctrl-"), bytes.count == 6 {
                let letter = bytes[5] | 0x20
                if (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter) {
                    return [letter & 0x1f]
                }
            }
            throw fail("unknown key \(name)")
        }
    }
}

private extension UInt16 {
    var asInt: Int { Int(self) }
}
