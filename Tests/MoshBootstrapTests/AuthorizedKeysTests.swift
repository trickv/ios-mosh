import Foundation
import MoshBootstrap
import MoshKeys
import MoshTestSupport
import XCTest

/// Runs the install command with local shells, the way sshd would (`$SHELL -c command`), with
/// HOME pointing at a scratch directory.
final class AuthorizedKeysTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var home: String { scratch.path }
    private var sshDirectory: String { home + "/.ssh" }
    private var file: String { home + "/.ssh/authorized_keys" }

    override func setUpWithError() throws {
        scratch = try ScratchDirectory(label: "authkeys")
    }

    override func tearDown() {
        scratch.remove()
    }

    private func newKey(comment: String) throws -> OpenSSHPublicKey {
        try KeyGenerator.generateEd25519().openSSHPublicKey(comment: comment)
    }

    private func install(_ key: OpenSSHPublicKey, shell: String = "sh") throws -> AuthorizedKeys.Outcome {
        let result = try ToolRunner.run(
            shell, ["-c", AuthorizedKeys.installCommand(for: key)],
            environment: ["HOME": home, "PATH": "/usr/bin:/bin"])
        return try AuthorizedKeys.outcome(exitStatus: Int(result.status), output: result.stdout + result.stderr)
    }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
    }

    private func content() throws -> String {
        try String(contentsOfFile: file, encoding: .utf8)
    }

    func testCommandShape() throws {
        let key = try newKey(comment: "it's mine")
        let command = AuthorizedKeys.installCommand(for: key)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertFalse(command.contains("\n"), "csh cannot quote a line break")
        // The key line is an argument, quoted, and not part of the script.
        XCTAssertTrue(command.hasSuffix(" '" + key.line.replacingOccurrences(of: "'", with: "'\\''") + "'"))
    }

    func testCreatesDirectoryAndFileWithTheRightModes() throws {
        let key = try newKey(comment: "ios-mosh@phone")
        let old = umask(0o022)
        defer { umask(old) }
        XCTAssertEqual(try install(key), .added)
        XCTAssertEqual(try mode(sshDirectory), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try content(), key.line + "\n")
    }

    func testInstallingTwiceAddsOneLine() throws {
        let key = try newKey(comment: "ios-mosh@phone")
        XCTAssertEqual(try install(key), .added)
        XCTAssertEqual(try install(key), .alreadyPresent)
        XCTAssertEqual(try install(key), .alreadyPresent)
        XCTAssertEqual(try content(), key.line + "\n")
        // The same key under another comment is the same key.
        XCTAssertEqual(try install(try key.withComment("renamed")), .alreadyPresent)
        XCTAssertEqual(try content(), key.line + "\n")
    }

    func testPreservesExistingContent() throws {
        let other = try newKey(comment: "laptop")
        let existing = "# my keys\n\nfrom=\"10.0.0.*\",no-pty \(other.line)\n"
        try FileManager.default.createDirectory(atPath: sshDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshDirectory)
        try Data(existing.utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)

        let key = try newKey(comment: "ios-mosh@phone")
        XCTAssertEqual(try install(key), .added)
        XCTAssertEqual(try content(), existing + key.line + "\n")
        // An existing directory and file keep the modes their owner gave them.
        XCTAssertEqual(try mode(sshDirectory), 0o755)
        XCTAssertEqual(try mode(file), 0o644)
        // A key that is there with options in front is recognised as present.
        XCTAssertEqual(try install(other), .alreadyPresent)
        XCTAssertEqual(try content(), existing + key.line + "\n")
    }

    func testCompletesAnUnterminatedLastLine() throws {
        let other = try newKey(comment: "laptop")
        try FileManager.default.createDirectory(atPath: sshDirectory, withIntermediateDirectories: true)
        try Data(other.line.utf8).write(to: URL(fileURLWithPath: file))  // no final line break

        let key = try newKey(comment: "phone")
        XCTAssertEqual(try install(key), .added)
        XCTAssertEqual(try content(), other.line + "\n" + key.line + "\n")
    }

    func testEmptyExistingFile() throws {
        try FileManager.default.createDirectory(atPath: sshDirectory, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: file))
        let key = try newKey(comment: "phone")
        XCTAssertEqual(try install(key), .added)
        XCTAssertEqual(try content(), key.line + "\n")
    }

    func testHostileCommentsAreData() throws {
        // Nothing in a comment is run or expanded, by the login shell or by the script.
        let comments = [
            "it's \"quoted\"", "$(touch \(home)/pwned-1)", "`touch \(home)/pwned-2`", "; touch \(home)/pwned-3 ;",
            "a'; touch \(home)/pwned-4; echo '", "$HOME ${HOME} ~ * ? [a-z] \\ \\n %s %d", "-n -e", "é 日本 🙂",
            "| tee \(home)/pwned-5", "> \(home)/pwned-6", "&& touch \(home)/pwned-7", "!! !$ ^a^b",
        ]
        var expected = ""
        var tested = 0
        for shell in ["sh", "bash", "dash", "zsh", "fish"] where ToolRunner.which(shell) != nil {
            tested += 1
            for comment in comments {
                let key = try newKey(comment: comment)
                XCTAssertEqual(try install(key, shell: shell), .added, "\(shell): \(comment)")
                XCTAssertEqual(try install(key, shell: shell), .alreadyPresent, "\(shell): \(comment)")
                expected += key.line + "\n"
            }
        }
        if tested == 0 { throw XCTSkip("no shell found") }
        XCTAssertEqual(try content(), expected)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home).filter { $0.hasPrefix("pwned") }
        XCTAssertEqual(leftovers, [])
        // OpenSSH can read every line back.
        if ToolRunner.which("ssh-keygen") != nil {
            let listed = try ToolRunner.check("ssh-keygen", ["-lf", file])
            XCTAssertEqual(listed.split(separator: "\n").count, tested * comments.count)
        }
    }

    func testFailureIsReported() throws {
        // ~/.ssh is a file: mkdir cannot work.
        try Data("x".utf8).write(to: URL(fileURLWithPath: sshDirectory))
        let key = try newKey(comment: "phone")
        XCTAssertThrowsError(try install(key)) { error in
            guard case .failed(let status, _) = error as? AuthorizedKeys.InstallError else {
                return XCTFail("\(error)")
            }
            XCTAssertNotEqual(status, 0)
        }
    }

    func testOutcomeParsing() throws {
        XCTAssertEqual(try AuthorizedKeys.outcome(exitStatus: 0, output: "MOSH-KEY-ADDED\r\n"), .added)
        XCTAssertEqual(try AuthorizedKeys.outcome(exitStatus: 0, output: "motd\nMOSH-KEY-PRESENT\n"), .alreadyPresent)
        XCTAssertThrowsError(try AuthorizedKeys.outcome(exitStatus: 0, output: ""))
        XCTAssertThrowsError(try AuthorizedKeys.outcome(exitStatus: 74, output: "MOSH-KEY-ADDED"))
        XCTAssertThrowsError(try AuthorizedKeys.outcome(exitStatus: nil, output: "MOSH-KEY-ADDED")) {
            XCTAssertEqual(
                $0 as? AuthorizedKeys.InstallError, .failed(exitStatus: nil, output: "MOSH-KEY-ADDED"))
        }
    }
}
