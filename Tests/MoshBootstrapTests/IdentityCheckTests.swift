import Foundation
import MoshBootstrap
import XCTest

final class IdentityCheckTests: XCTestCase {
    /// 2026-11-12 04:17:33 UTC.
    static let start = Date(timeIntervalSince1970: 1_794_457_053)

    // Samples of `LC_ALL=C ps -p PID -o user= -o lstart= -o comm=`.
    // Linux, procps-ng 4.0.4 (taken in the dev container).
    static let linux = "trick    Thu Nov 12 04:17:33 2026 mosh-server\n"
    static let linuxLongUser = "moshite+ Thu Nov 12 04:17:33 2026 mosh-server\n"
    static let linuxOtherProgram = "root     Thu Nov 12 04:17:33 2026 my sleep\n"
    static let linuxSingleDigitDay = "trick    Mon Nov  2 23:59:59 2026 mosh-server\n"
    // macOS: a wider user column and the full path in comm.
    static let macOS = "trick            Thu Nov 12 04:17:33 2026 /opt/homebrew/bin/mosh-server\n"
    static let macOSPathWithSpaces = "trick            Thu Nov 12 04:17:33 2026 /Users/trick/My Tools/bin/mosh-server\n"
    static let macOSOtherProgram = "trick            Thu Nov 12 04:17:33 2026 /bin/zsh\n"

    func testCommand() {
        XCTAssertEqual(
            IdentityCheck.psCommand(pid: 4242), "TZ=UTC0 LC_ALL=C ps -p 4242 -o user= -o lstart= -o comm=")
        XCTAssertEqual(
            IdentityCheck.remoteCommand(pid: 4242),
            "sh -c 'TZ=UTC0 LC_ALL=C ps -p 4242 -o user= -o lstart= -o comm='")
    }

    func testParsesLinux() throws {
        let identity = try XCTUnwrap(IdentityCheck.parse(Self.linux))
        XCTAssertEqual(identity.user, "trick")
        XCTAssertEqual(identity.startTime, Self.start)
        XCTAssertEqual(identity.command, "mosh-server")
        XCTAssertEqual(identity.commandBasename, "mosh-server")

        let other = try XCTUnwrap(IdentityCheck.parse(Self.linuxOtherProgram))
        XCTAssertEqual(other.user, "root")
        XCTAssertEqual(other.command, "my sleep", "comm keeps its spaces")

        let early = try XCTUnwrap(IdentityCheck.parse(Self.linuxSingleDigitDay))
        // 2026-11-02 23:59:59 UTC.
        XCTAssertEqual(early.startTime, Date(timeIntervalSince1970: 1_793_663_999))
    }

    func testParsesMacOS() throws {
        let identity = try XCTUnwrap(IdentityCheck.parse(Self.macOS))
        XCTAssertEqual(identity.user, "trick")
        XCTAssertEqual(identity.startTime, Self.start)
        XCTAssertEqual(identity.command, "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(identity.commandBasename, "mosh-server")

        let spaced = try XCTUnwrap(IdentityCheck.parse(Self.macOSPathWithSpaces))
        XCTAssertEqual(spaced.command, "/Users/trick/My Tools/bin/mosh-server")
        XCTAssertEqual(spaced.commandBasename, "mosh-server")
    }

    func testParsesWithCRLFAndSurroundingLines() throws {
        let noisy = "Agent pid 77\r\n" + Self.linux.replacingOccurrences(of: "\n", with: "\r\n") + "bye\r\n"
        XCTAssertEqual(try XCTUnwrap(IdentityCheck.parse(noisy)).command, "mosh-server")
    }

    func testRejectsWhatIsNotAPsLine() {
        for bad in [
            "", "\n", "   ", "trick", "trick Thu Nov 12 04:17:33 2026",
            "trick Thu Nov 12 04:17:33 2026 ",
            "trick Xyz Nov 12 04:17:33 2026 mosh-server",
            "trick Thu Foo 12 04:17:33 2026 mosh-server",
            "trick Thu Nov 32 04:17:33 2026 mosh-server",
            "trick Thu Nov 12 24:17:33 2026 mosh-server",
            "trick Thu Nov 12 04:60:33 2026 mosh-server",
            "trick Thu Nov 12 04:17 2026 mosh-server",
            "trick Thu Nov 12 04:17:33 1969 mosh-server",
            "error: process ID list syntax error",
            "ps: illegal option -- o",
        ] {
            XCTAssertNil(IdentityCheck.parse(bad), bad)
        }
    }

    func testDateArithmetic() throws {
        func time(_ text: String) throws -> TimeInterval {
            try XCTUnwrap(IdentityCheck.parse("u \(text) mosh-server")).startTime.timeIntervalSince1970
        }
        XCTAssertEqual(try time("Thu Jan  1 00:00:00 1970"), 0)
        XCTAssertEqual(try time("Sat Jan  1 00:00:00 2000"), 946_684_800)
        XCTAssertEqual(try time("Tue Feb 29 12:00:00 2000"), 951_825_600)
        XCTAssertEqual(try time("Thu Feb 29 23:59:59 2024"), 1_709_251_199)
        XCTAssertEqual(try time("Fri Mar  1 00:00:00 2024"), 1_709_251_200)
        XCTAssertEqual(try time("Wed Dec 31 23:59:59 2025"), 1_767_225_599)
        XCTAssertEqual(try time("Tue Jan 19 03:14:08 2038"), 2_147_483_648)
        XCTAssertEqual(try time("Fri Jan  1 00:00:00 2100"), 4_102_444_800)
    }

    func testPassRule() throws {
        func verdict(_ output: String, user: String = "trick", start: Date = IdentityCheckTests.start) -> IdentityVerdict {
            IdentityCheck.evaluate(psOutput: output, loginUser: user, expectedStartTime: start)
        }
        XCTAssertTrue(verdict(Self.linux).isPassed)
        XCTAssertTrue(verdict(Self.macOS).isPassed)
        XCTAssertTrue(verdict(Self.macOSPathWithSpaces).isPassed)

        // No such process: ps prints nothing.
        XCTAssertEqual(verdict(""), .failed(.noSuchProcess))
        XCTAssertEqual(verdict("\n"), .failed(.noSuchProcess))
        // Another user's process.
        XCTAssertEqual(verdict(Self.linux, user: "alice"), .failed(.wrongUser(found: "trick")))
        XCTAssertEqual(verdict(Self.linuxOtherProgram), .failed(.wrongUser(found: "root")))
        // The pid now belongs to another program.
        XCTAssertEqual(verdict(Self.macOSOtherProgram), .failed(.notMoshServer(found: "/bin/zsh")))
        XCTAssertEqual(
            verdict("trick Thu Nov 12 04:17:33 2026 mosh-server <defunct>"),
            .failed(.notMoshServer(found: "mosh-server <defunct>")))
        XCTAssertEqual(
            verdict("trick Thu Nov 12 04:17:33 2026 not-mosh-server"),
            .failed(.notMoshServer(found: "not-mosh-server")))
        // Something that is not ps output.
        XCTAssertEqual(verdict("ps: command not found"), .failed(.unreadable(output: "ps: command not found")))
    }

    func testStartTimeTolerance() {
        func verdict(offset: TimeInterval) -> IdentityVerdict {
            IdentityCheck.evaluate(
                psOutput: Self.linux, loginUser: "trick", expectedStartTime: Self.start.addingTimeInterval(offset))
        }
        for offset: TimeInterval in [0, 1, -1, 2, -2] {
            XCTAssertTrue(verdict(offset: offset).isPassed, "\(offset)")
        }
        for offset: TimeInterval in [3, -3, 60, -3600, 86400] {
            XCTAssertEqual(verdict(offset: offset), .failed(.startTimeDiffers(found: Self.start)), "\(offset)")
        }
    }

    func testTruncatedUserNames() {
        XCTAssertTrue(IdentityCheck.userMatches(psUser: "trick", loginUser: "trick"))
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "trick", loginUser: "tricky"))
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "Trick", loginUser: "trick"))
        // procps: "moshitestuser" is shown as "moshite+".
        XCTAssertTrue(IdentityCheck.userMatches(psUser: "moshite+", loginUser: "moshitestuser"))
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "moshite+", loginUser: "moshite"), "nothing was cut off")
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "moshite+", loginUser: "another-user"))
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "+", loginUser: "anyone"))
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "", loginUser: ""), "an empty column is never a match")
        // A numeric uid (very old procps) is not a name.
        XCTAssertFalse(IdentityCheck.userMatches(psUser: "1000", loginUser: "trick"))

        let verdict = IdentityCheck.evaluate(
            psOutput: Self.linuxLongUser, loginUser: "moshitestuser", expectedStartTime: Self.start)
        XCTAssertTrue(verdict.isPassed)
    }

    func testProbeResultTable() {
        let identity = ProcessIdentity(user: "trick", startTime: Self.start, command: "mosh-server")

        let ended = ProbeResult.from(verdict: .failed(.noSuchProcess), savedAddress: "10.0.0.5", sshAddress: "10.0.0.5")
        XCTAssertEqual(ended, .sessionEnded(.noSuchProcess))
        XCTAssertEqual(ended.action, .startNewSession)

        let reused = ProbeResult.from(
            verdict: .failed(.notMoshServer(found: "bash")), savedAddress: "10.0.0.5", sshAddress: "10.0.0.5")
        XCTAssertEqual(reused.action, .startNewSession)

        let blocked = ProbeResult.from(verdict: .passed(identity), savedAddress: "10.0.0.5", sshAddress: "10.0.0.5")
        XCTAssertEqual(blocked, .udpBlocked)
        XCTAssertEqual(blocked.action, .informAndKeepSession)
        XCTAssertTrue(blocked.meaning.contains("UDP is blocked"))

        let elsewhere = ProbeResult.from(
            verdict: .passed(identity), savedAddress: "192.168.1.5", sshAddress: "100.101.102.103")
        XCTAssertEqual(
            elsewhere, .serverBoundToUnreachableAddress(savedAddress: "192.168.1.5", sshAddress: "100.101.102.103"))
        XCTAssertEqual(elsewhere.action, .informAndKeepSession)
        XCTAssertTrue(elsewhere.meaning.contains("192.168.1.5"))
        XCTAssertEqual(elsewhere.hint?.contains("Tailscale"), true)

        let unreachable = ProbeResult.hostUnreachable(.connectTimedOut(seconds: 10))
        XCTAssertEqual(unreachable.action, .keepWaiting)
        XCTAssertNil(unreachable.hint)
    }

    // MARK: Review M6-1: "ended" needs the session's own machine

    private static let everyMismatch: [IdentityMismatch] = [
        .noSuchProcess, .wrongUser(found: "root"), .notMoshServer(found: "bash"),
        .startTimeDiffers(found: Date(timeIntervalSince1970: 5)), .unreadable(output: "?"),
    ]

    func testAFailedCheckAtTheSessionsAddressIsEnded() {
        for mismatch in Self.everyMismatch {
            if case .unreadable = mismatch { continue }
            let result = ProbeResult.from(verdict: .failed(mismatch), savedAddress: "10.0.0.5", sshAddress: "10.0.0.5")
            XCTAssertEqual(result, .sessionEnded(mismatch))
            XCTAssertEqual(result.action, .startNewSession)
        }
    }

    func testAFailedCheckAtAnotherAddressIsUnknownAndKeepsTheSession() {
        for mismatch in Self.everyMismatch {
            let result = ProbeResult.from(verdict: .failed(mismatch), savedAddress: "10.0.0.5", sshAddress: "10.0.0.6")
            XCTAssertEqual(
                result, .unknown(.askedAnotherAddress(savedAddress: "10.0.0.5", sshAddress: "10.0.0.6", mismatch)))
            XCTAssertEqual(result.action, .informAndKeepSession, "\(mismatch)")
            XCTAssertTrue(result.meaning.contains("another machine"))
            XCTAssertTrue(result.meaning.contains("10.0.0.6"))
            XCTAssertNotNil(result.hint)
        }
    }

    func testAnUnreadableAnswerIsUnknownEvenAtTheSessionsAddress() {
        let result = ProbeResult.from(
            verdict: .failed(.unreadable(output: "ps: not found")), savedAddress: "10.0.0.5", sshAddress: "10.0.0.5")
        XCTAssertEqual(result, .unknown(.unreadableAnswer(sshAddress: "10.0.0.5")))
        XCTAssertEqual(result.action, .informAndKeepSession)
    }

    func testWithoutASavedAddressNothingIsProven() {
        // Two empty strings are equal, but name no machine.
        for ssh in ["", "10.0.0.5"] {
            let result = ProbeResult.from(verdict: .failed(.noSuchProcess), savedAddress: "", sshAddress: ssh)
            XCTAssertEqual(result, .unknown(.noSavedAddress(sshAddress: ssh)))
            XCTAssertEqual(result.action, .informAndKeepSession)
        }
        let identity = ProcessIdentity(user: "trick", startTime: Self.start, command: "mosh-server")
        let passed = ProbeResult.from(verdict: .passed(identity), savedAddress: "", sshAddress: "")
        XCTAssertNotEqual(passed, .udpBlocked)
        XCTAssertEqual(passed.action, .informAndKeepSession)
    }

    func testOnlyEndedStartsANewSession() {
        let identity = ProcessIdentity(user: "trick", startTime: Self.start, command: "mosh-server")
        let verdicts = Self.everyMismatch.map(IdentityVerdict.failed) + [.passed(identity)]
        for verdict in verdicts {
            for (saved, ssh) in [("10.0.0.5", "10.0.0.5"), ("10.0.0.5", "10.0.0.6"), ("", "10.0.0.5"), ("", "")] {
                let result = ProbeResult.from(verdict: verdict, savedAddress: saved, sshAddress: ssh)
                if result.action == .startNewSession {
                    guard case .sessionEnded = result else { return XCTFail("\(result)") }
                    XCTAssertEqual(saved, ssh)
                    XCTAssertFalse(saved.isEmpty)
                    XCTAssertFalse(verdict.isPassed)
                }
            }
        }
    }
}
