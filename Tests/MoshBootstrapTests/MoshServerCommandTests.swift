import MoshBootstrap
import MoshTestSupport
import XCTest

final class MoshServerCommandTests: XCTestCase {
    func testDefaultCommand() throws {
        XCTAssertEqual(
            try MoshServerCommand().commandLine(),
            "mosh-server new -c 256 -s -l LANG=en_US.UTF-8")
    }

    func testLocaleAndPortRange() throws {
        var command = MoshServerCommand(locale: "C.UTF-8", portRange: UDPPortRange(low: 60001, high: 60010))
        XCTAssertEqual(try command.commandLine(), "mosh-server new -c 256 -s -l LANG=C.UTF-8 -p 60001:60010")
        command.portRange = UDPPortRange(port: 61000)
        command.locale = " de_DE.UTF-8@euro "
        XCTAssertEqual(try command.commandLine(), "mosh-server new -c 256 -s -l LANG=de_DE.UTF-8@euro -p 61000")
    }

    func testLocaleIsValidated() {
        for bad in ["", "  ", "en_US.UTF-8; reboot", "$(id)", "a b", "x'y", "é"] {
            XCTAssertThrowsError(try MoshServerCommand(locale: bad).commandLine(), bad) {
                XCTAssertEqual($0 as? MoshServerCommand.CommandError, .invalidLocale(bad))
            }
        }
    }

    func testPortRangeParsing() {
        XCTAssertEqual(UDPPortRange("60001"), UDPPortRange(low: 60001, high: 60001))
        XCTAssertEqual(UDPPortRange(" 60001 : 60999 ")?.argument, "60001:60999")
        XCTAssertEqual(UDPPortRange("1:65535")?.argument, "1:65535")
        XCTAssertEqual(UDPPortRange("7")?.argument, "7")
        for bad in ["", ":", "0", "65536", "60010:60001", "60001:", ":60001", "a", "1:2:3", "-1", "6e4", "+5", "123456"] {
            XCTAssertNil(UDPPortRange(bad), bad)
        }
        XCTAssertNil(UDPPortRange(low: 0, high: 10))
        XCTAssertNil(UDPPortRange(low: 10, high: 9))
        XCTAssertNil(UDPPortRange(low: 10, high: 65536))
        let range = UDPPortRange(low: 10, high: 12)!
        XCTAssertTrue(range.contains(10) && range.contains(12))
        XCTAssertFalse(range.contains(9) || range.contains(13))
    }

    func testServerPathForms() throws {
        func word(_ path: String) throws -> String { try MoshServerCommand(serverPath: path).serverWord() }
        XCTAssertEqual(try word(""), "mosh-server")
        XCTAssertEqual(try word("   "), "mosh-server")
        // A program path.
        XCTAssertEqual(try word("/opt/homebrew/bin/mosh-server"), "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(try word("/opt/mosh/bin/mosh-server-1.4"), "/opt/mosh/bin/mosh-server-1.4")
        // A program name without a slash is looked up in PATH.
        XCTAssertEqual(try word("mosh-server-1.4"), "mosh-server-1.4")
        XCTAssertEqual(try word("my server"), "'my server'")
        // A directory (prefix).
        XCTAssertEqual(try word("/opt/homebrew/bin"), "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(try word("/opt/homebrew/bin/"), "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(try word("/opt/mosh-server/"), "/opt/mosh-server/mosh-server")
        XCTAssertEqual(try word("/"), "/mosh-server")
        // Quoting.
        XCTAssertEqual(try word("/Users/me/My Tools/mosh-server"), "'/Users/me/My Tools/mosh-server'")
        XCTAssertEqual(try word("/tmp/it's"), "'/tmp/it'\\''s/mosh-server'")
        XCTAssertEqual(try word("/tmp/$(reboot)/mosh-server"), "'/tmp/$(reboot)/mosh-server'")
        // The tilde stays outside the quotes.
        XCTAssertEqual(try word("~/bin/mosh-server"), "~/bin/mosh-server")
        XCTAssertEqual(try word("~/.local/bin"), "~/.local/bin/mosh-server")
        XCTAssertEqual(try word("~/my tools/"), "~/'my tools/mosh-server'")
        XCTAssertThrowsError(try word("/a\nb")) {
            XCTAssertEqual($0 as? MoshServerCommand.CommandError, .unrepresentable(field: "serverPath"))
        }
    }

    func testRemoteCommandForms() throws {
        var command = MoshServerCommand(remoteCommand: "tmux new -A -s main")
        XCTAssertEqual(
            try command.commandLine(),
            "mosh-server new -c 256 -s -l LANG=en_US.UTF-8 -- sh -c 'exec \"${SHELL:-/bin/sh}\" -lc \"$1\"' sh 'tmux new -A -s main'"
        )
        command.remoteCommandShell = .sh
        XCTAssertEqual(
            try command.commandLine(),
            "mosh-server new -c 256 -s -l LANG=en_US.UTF-8 -- sh -c 'tmux new -A -s main'")

        command.remoteCommand = "tmux new -A -s $(hostname -s) || echo 'no tmux'"
        XCTAssertEqual(
            try command.commandLine(),
            "mosh-server new -c 256 -s -l LANG=en_US.UTF-8 -- sh -c 'tmux new -A -s $(hostname -s) || echo '\\''no tmux'\\'''"
        )
        command.remoteCommand = "  "
        XCTAssertEqual(try command.commandLine(), "mosh-server new -c 256 -s -l LANG=en_US.UTF-8")
        command.remoteCommand = "a\nb"
        XCTAssertThrowsError(try command.commandLine()) {
            XCTAssertEqual($0 as? MoshServerCommand.CommandError, .unrepresentable(field: "remoteCommand"))
        }
    }

    func testEverythingTogether() throws {
        let command = MoshServerCommand(
            serverPath: "/opt/homebrew/bin", locale: "C.UTF-8", portRange: UDPPortRange("60001:60005"),
            remoteCommand: "tmux new -A -s main", remoteCommandShell: .sh)
        XCTAssertEqual(
            try command.commandLine(),
            "/opt/homebrew/bin/mosh-server new -c 256 -s -l LANG=C.UTF-8 -p 60001:60005 -- sh -c 'tmux new -A -s main'"
        )
    }

    // MARK: - Through real shells

    /// Runs the command line the way sshd does (`$SHELL -c line`), with a stand-in for
    /// mosh-server that prints its arguments one per line, and returns them.
    private func arguments(of command: MoshServerCommand, shell: String, scratch: ScratchDirectory) throws -> [String] {
        let output = try ToolRunner.run(
            shell, ["-c", try command.commandLine()],
            environment: ["HOME": scratch.path, "PATH": scratch.path + ":/usr/bin:/bin"])
        XCTAssertEqual(output.status, 0, output.stderr)
        return output.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testArgumentsReachTheServerUnchanged() throws {
        let scratch = try ScratchDirectory(label: "servercmd")
        defer { scratch.remove() }
        // The stand-in runs the words after "--" like mosh-server does: with execvp, no shell.
        let fake = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
        for directory in [scratch.path, scratch.path + "/odd dir $x 'q'"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let file = directory + "/mosh-server"
            try Data(fake.utf8).write(to: URL(fileURLWithPath: file))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        }

        let remote = "tmux new -A -s $(hostname -s) ; echo \"it's\" `id` * ~ \\ $HOME"
        var tested = 0
        for shell in ["sh", "bash", "dash", "zsh", "fish"] where ToolRunner.which(shell) != nil {
            tested += 1
            // Found through PATH; remote command through plain sh.
            var command = MoshServerCommand(
                locale: "C.UTF-8", portRange: UDPPortRange("60001:60002"), remoteCommand: remote,
                remoteCommandShell: .sh)
            XCTAssertEqual(
                try arguments(of: command, shell: shell, scratch: scratch),
                ["new", "-c", "256", "-s", "-l", "LANG=C.UTF-8", "-p", "60001:60002", "--", "sh", "-c", remote],
                shell)

            // A directory with spaces, a dollar sign and quotes; remote command through the
            // login shell.
            command.serverPath = scratch.path + "/odd dir $x 'q'"
            command.remoteCommandShell = .loginShell
            XCTAssertEqual(
                try arguments(of: command, shell: shell, scratch: scratch),
                [
                    "new", "-c", "256", "-s", "-l", "LANG=C.UTF-8", "-p", "60001:60002", "--", "sh", "-c",
                    "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"", "sh", remote,
                ], shell)

            // "~/" is expanded by the login shell (HOME is the scratch directory).
            command.serverPath = "~/odd dir $x 'q'/"
            command.remoteCommand = ""
            XCTAssertEqual(
                try arguments(of: command, shell: shell, scratch: scratch),
                ["new", "-c", "256", "-s", "-l", "LANG=C.UTF-8", "-p", "60001:60002"], shell)
        }
        if tested == 0 { throw XCTSkip("no shell found") }
    }

    /// The remote command is interpreted once, by the shell inside the session.
    func testRemoteCommandIsInterpretedByTheInnerShell() throws {
        let scratch = try ScratchDirectory(label: "servercmd")
        defer { scratch.remove() }
        // This stand-in does what mosh-server does with the words after "--": execvp.
        let fake = "#!/bin/sh\nwhile [ \"$1\" != -- ]; do shift; done\nshift\nexec \"$@\"\n"
        let file = scratch.path + "/mosh-server"
        try Data(fake.utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)

        for mode in [MoshServerCommand.RemoteCommandShell.sh, .loginShell] {
            let command = MoshServerCommand(
                remoteCommand: "printf '%s|' $(echo one two) \"$((6*7))\" 'a b'; echo done", remoteCommandShell: mode)
            let output = try ToolRunner.run(
                "sh", ["-c", try command.commandLine()],
                environment: ["HOME": scratch.path, "PATH": scratch.path + ":/usr/bin:/bin", "SHELL": "/bin/sh"])
            XCTAssertEqual(output.status, 0, output.stderr)
            XCTAssertEqual(output.stdout, "one|two|42|a b|done\n", "\(mode)")
        }
    }
}
