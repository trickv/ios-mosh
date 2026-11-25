import MoshBootstrap
import XCTest

final class ConnectLineParserTests: XCTestCase {
    static let key = "4NeCCgvZFe2RnPgrcU1PQw"

    /// What mosh-server 1.4.0 prints through an sshd pty (CR LF line ends, stderr merged in).
    static let realOutput =
        "\r\n\r\nMOSH CONNECT 60001 \(key)\r\n\r\nmosh-server (mosh 1.4.0) [build mosh 1.4.0]\r\n"
        + "Copyright 2012 Keith Winstein <mosh-devel@mit.edu>\r\n"
        + "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\r\n"
        + "This is free software: you are free to change and redistribute it.\r\n"
        + "There is NO WARRANTY, to the extent permitted by law.\r\n\r\n"
        + "[mosh-server detached, pid = 12345]\r\n"

    func testRealOutput() {
        var parser = ConnectLineParser()
        parser.feed(Self.realOutput)
        XCTAssertEqual(parser.connect, ConnectLineParser.Connect(port: 60001, key: Self.key))
        XCTAssertEqual(parser.serverPID, 12345)
        XCTAssertTrue(parser.isComplete)
        XCTAssertNil(parser.startFailure)
        XCTAssertFalse(parser.text.contains("\r"))
        XCTAssertTrue(parser.text.contains("MOSH CONNECT 60001 \(Self.key)\n"))
    }

    func testEverySplitPointGivesTheSameResult() {
        let bytes = Array(Self.realOutput.utf8)
        for split in 0...bytes.count {
            var parser = ConnectLineParser()
            parser.feed(bytes[..<split])
            parser.feed(bytes[split...])
            XCTAssertEqual(parser.connect?.port, 60001, "split at \(split)")
            XCTAssertEqual(parser.connect?.key, Self.key, "split at \(split)")
            XCTAssertEqual(parser.serverPID, 12345, "split at \(split)")
        }
        // One byte at a time.
        var parser = ConnectLineParser()
        for byte in bytes {
            XCTAssertFalse(parser.isComplete)
            parser.feed([byte])
        }
        XCTAssertTrue(parser.isComplete)
    }

    func testNoiseAroundTheLines() {
        var parser = ConnectLineParser()
        parser.feed("Welcome to Ubuntu 24.04 LTS\r\n * Documentation: https://help.ubuntu.com\r\n")
        parser.feed("\u{1b}[1;32mLast login\u{1b}[0m: Thu Nov 12 from 10.0.0.1\r\n")
        parser.feed("stty: 'standard input': Inappropriate ioctl for device\n")
        XCTAssertNil(parser.connect)
        parser.feed("MOSH CONNECT 61234 \(Self.key)\n")
        XCTAssertEqual(parser.connect?.port, 61234)
        XCTAssertNil(parser.serverPID)
        XCTAssertFalse(parser.isComplete)
        parser.feed("warning: something\r\n[mosh-server detached, pid = 7]\r\nbye\r\n")
        XCTAssertEqual(parser.serverPID, 7)
        XCTAssertTrue(parser.isComplete)
    }

    func testFirstMatchWins() {
        var parser = ConnectLineParser()
        parser.feed("MOSH CONNECT 60001 \(Self.key)\nMOSH CONNECT 60002 AAAAAAAAAAAAAAAAAAAAAA\n")
        parser.feed("[mosh-server detached, pid = 1]\n[mosh-server detached, pid = 2]\n")
        XCTAssertEqual(parser.connect?.port, 60001)
        XCTAssertEqual(parser.serverPID, 1)
    }

    func testUnterminatedLastLineCountsAfterFinish() {
        var parser = ConnectLineParser()
        parser.feed("MOSH CONNECT 60001 \(Self.key)")
        XCTAssertNil(parser.connect, "the line may still grow")
        XCTAssertEqual(parser.text, "MOSH CONNECT 60001 \(Self.key)")
        parser.finish()
        XCTAssertEqual(parser.connect?.port, 60001)
        parser.finish()
        XCTAssertEqual(parser.text, "MOSH CONNECT 60001 \(Self.key)")
    }

    func testConnectLineMatcher() {
        let parse = ConnectLineParser.parseConnectLine
        XCTAssertEqual(parse("MOSH CONNECT 60001 \(Self.key)"), .init(port: 60001, key: Self.key))
        XCTAssertEqual(parse("MOSH CONNECT 1 ab/+AB09ab/+AB09ab/+AB")?.key, "ab/+AB09ab/+AB09ab/+AB")
        XCTAssertEqual(parse("MOSH CONNECT 65535 \(Self.key)  \t ")?.port, 65535)
        XCTAssertEqual(parse("\rMOSH CONNECT 60001 \(Self.key)\r")?.port, 60001)
        XCTAssertEqual(parse("MOSH CONNECT 60001 \(Self.key)\r\r")?.port, 60001)

        XCTAssertNil(parse(" MOSH CONNECT 60001 \(Self.key)"), "must start the line")
        XCTAssertNil(parse("$ MOSH CONNECT 60001 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT 60001 \(Self.key) x"), "nothing but white space may follow")
        XCTAssertNil(parse("MOSH CONNECT 60001 \(Self.key)A"), "23 characters")
        XCTAssertNil(parse("MOSH CONNECT 60001 \(Self.key.dropLast())"), "21 characters")
        XCTAssertNil(parse("MOSH CONNECT 60001 \(Self.key.dropLast())="), "padding is not part of the key")
        XCTAssertNil(parse("MOSH CONNECT 60001 \(Self.key.dropLast())-"))
        XCTAssertNil(parse("MOSH CONNECT  60001 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT 60001  \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT x \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT -1 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT 0 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT 65536 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT 600011 \(Self.key)"))
        XCTAssertNil(parse("MOSH CONNECT"))
        XCTAssertNil(parse("mosh connect 60001 \(Self.key)"))
        XCTAssertNil(parse("MOSH IP 10.0.0.1"))
        XCTAssertNil(parse(""))
    }

    func testDetachedLineMatcher() {
        let parse = ConnectLineParser.parseDetachedLine
        XCTAssertEqual(parse("[mosh-server detached, pid = 4242]"), 4242)
        XCTAssertEqual(parse("noise [mosh-server detached, pid = 1] noise"), 1)
        XCTAssertEqual(parse("[mosh-server detached, pid = 4194304]\r"), 4_194_304)
        XCTAssertNil(parse("[mosh-server detached, pid = ]"))
        XCTAssertNil(parse("[mosh-server detached, pid = 0]"))
        XCTAssertNil(parse("[mosh-server detached, pid = 12"))
        XCTAssertNil(parse("[mosh-server detached, pid = x]"))
        XCTAssertNil(parse("[mosh-server detached, pid = 99999999999]"))
        XCTAssertNil(parse("mosh-server detached, pid = 5"))
        XCTAssertNil(parse(""))
    }

    func testFailureTexts() {
        let recognize = ConnectLineParser.recognizeFailure
        // Collected from the shells in the container and from the mosh 1.4.0 source.
        XCTAssertEqual(recognize("bash: line 1: mosh-server: command not found"), .serverNotFound)
        XCTAssertEqual(recognize("sh: 1: mosh-server: not found"), .serverNotFound)
        XCTAssertEqual(recognize("zsh:1: command not found: mosh-server"), .serverNotFound)
        XCTAssertEqual(recognize("bash: line 1: /nowhere/mosh-server: No such file or directory"), .serverNotFound)
        XCTAssertEqual(recognize("fish: Unknown command: mosh-server"), .serverNotFound)
        XCTAssertEqual(recognize("mosh-server: Command not found."), .serverNotFound)

        let locale =
            "mosh-server needs a UTF-8 native locale to run.\n\n"
            + "Unfortunately, the local environment ([no charset variables]) specifies\n"
            + "the character set \"US-ASCII\",\n\n"
            + "The client-supplied environment (LANG=xx_XX.UTF-8) specifies\n"
            + "the character set \"US-ASCII\".\n\n"
            + "locale: Cannot set LC_CTYPE to default locale: No such file or directory\n"
        XCTAssertEqual(recognize(locale), .localeMissing, "the locale text wins over 'No such file'")

        XCTAssertNil(recognize(Self.realOutput))
        XCTAssertNil(recognize("Network exception: bind: Address already in use"))
        XCTAssertNil(recognize(""))

        var parser = ConnectLineParser()
        parser.feed("bash: line 1: mosh-server: command not found\r\n")
        XCTAssertEqual(parser.startFailure, .serverNotFound)
    }

    func testOnlyTheNewestOutputIsKept() {
        var parser = ConnectLineParser(maxRetainedBytes: 1000)
        for index in 0..<500 { parser.feed("motd line number \(index)\r\n") }
        parser.feed("MOSH CONNECT 60001 \(Self.key)\r\n")
        XCTAssertEqual(parser.connect?.port, 60001)
        XCTAssertLessThanOrEqual(parser.text.utf8.count, 1000)
        XCTAssertTrue(parser.text.hasSuffix("MOSH CONNECT 60001 \(Self.key)"))
        XCTAssertFalse(parser.text.contains("line number 0\n"))
    }

    func testBinaryAndVeryLongLinesDoNotBreakIt() {
        var parser = ConnectLineParser()
        parser.feed([0xff, 0xfe, 0x00, 0x80] + Array(repeating: UInt8(ascii: "x"), count: 100_000))
        parser.feed("\nMOSH CONNECT 60001 \(Self.key)\n")
        XCTAssertEqual(parser.connect?.port, 60001)
        XCTAssertLessThan(parser.text.utf8.count, 20_000)
    }
}
