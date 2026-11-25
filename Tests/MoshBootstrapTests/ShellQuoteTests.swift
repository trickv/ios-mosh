import MoshBootstrap
import MoshTestSupport
import XCTest

final class ShellQuoteTests: XCTestCase {
    func testPlainWordsStayAsTheyAre() {
        for word in ["mosh-server", "/opt/homebrew/bin/mosh-server", "LANG=en_US.UTF-8", "60001:60010", "a@b", "x,y+z"] {
            XCTAssertEqual(ShellQuote.quote(word), word)
        }
    }

    func testEverythingElseIsSingleQuoted() {
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.quote("two words"), "'two words'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote("'"), "''\\'''")
        XCTAssertEqual(ShellQuote.quote("$(reboot)"), "'$(reboot)'")
        XCTAssertEqual(ShellQuote.quote("`id`"), "'`id`'")
        XCTAssertEqual(ShellQuote.quote("a;b"), "'a;b'")
        XCTAssertEqual(ShellQuote.quote("~/bin"), "'~/bin'")
        XCTAssertEqual(ShellQuote.quote("=ls"), "'=ls'")
        XCTAssertEqual(ShellQuote.quote("a*b?"), "'a*b?'")
        XCTAssertEqual(ShellQuote.quote("x\ny"), "'x\ny'")
        XCTAssertEqual(ShellQuote.quote("é"), "'é'")
        XCTAssertEqual(ShellQuote.alwaysQuote("plain"), "'plain'")
        XCTAssertEqual(ShellQuote.join(["a", "b c", ""]), "a 'b c' ''")
    }

    func testRepresentable() {
        XCTAssertTrue(ShellQuote.isRepresentable("tmux new -A -s $(hostname -s)"))
        XCTAssertFalse(ShellQuote.isRepresentable("a\u{0}b"))
        XCTAssertFalse(ShellQuote.isRepresentable("a\nb"))
        XCTAssertTrue(ShellQuote.isRepresentable("a\nb", allowLineBreaks: true))
    }

    /// The real shells must read a quoted word back as the original text.
    func testRoundTripThroughRealShells() throws {
        let samples = [
            "", "plain", "two words", "it's", "''", "'\"'", "$HOME $(id) `id` ${x}", "a;b&c|d>e<f",
            "back\\slash \\' \\\\", "tab\there", "new\nline", "glob * ? [a-z] {a,b}", "~ ~root =ls",
            "!history ^x^y", "# not a comment", "é 日本 🙂", "-n", "%1",
        ]
        var tested = 0
        for shell in ["sh", "bash", "dash", "zsh", "fish"] {
            guard ToolRunner.which(shell) != nil else { continue }
            tested += 1
            for sample in samples {
                let command = "printf %s " + ShellQuote.quote(sample)
                let output = try ToolRunner.run(shell, ["-c", command])
                XCTAssertEqual(output.status, 0, "\(shell): \(command)")
                XCTAssertEqual(output.stdout, sample, "\(shell): \(command)")
            }
        }
        if tested == 0 { throw XCTSkip("no shell found") }
    }
}
