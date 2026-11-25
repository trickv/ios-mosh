import Foundation

/// What `ps` says about one process.
public struct ProcessIdentity: Equatable, Sendable {
    /// The owner as `ps` prints it. Linux `ps` (procps) cuts names longer than 8 characters to
    /// 7 and a `+`.
    public var user: String
    /// When the process started.
    public var startTime: Date
    /// The `comm` column: the program name on Linux, the full path on macOS.
    public var command: String

    public init(user: String, startTime: Date, command: String) {
        self.user = user
        self.startTime = startTime
        self.command = command
    }

    /// The last path component of `command`.
    public var commandBasename: String {
        command.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? command
    }
}

/// Why a process is not the session's `mosh-server`.
public enum IdentityMismatch: Equatable, Sendable {
    /// `ps` printed nothing: no process has this pid.
    case noSuchProcess
    /// The process belongs to someone else.
    case wrongUser(found: String)
    /// The program is not `mosh-server` (the pid was reused).
    case notMoshServer(found: String)
    /// A `mosh-server` of this user, but started at another time: a different session.
    case startTimeDiffers(found: Date)
    /// `ps` answered with something that is not the expected line.
    case unreadable(output: String)
}

public enum IdentityVerdict: Equatable, Sendable {
    case passed(ProcessIdentity)
    case failed(IdentityMismatch)

    public var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }
}

/// The identity check from the plan (section 4): is the process with the stored pid still the
/// `mosh-server` this app started? Used by the session health probe and before every kill.
///
/// Command: `TZ=UTC0 LC_ALL=C ps -p PID -o user= -o lstart= -o comm=`. `comm` is last because it
/// can contain spaces. It passes when the user is the login user, the basename of `comm` is
/// `mosh-server` and the start time is within 2 s of the stored one. A process that fails the
/// check is never killed.
///
/// `TZ=UTC0` is an addition to the plan's command: `lstart` is printed in the time zone of the
/// process environment, so without it the same process would show a start time one hour off
/// after a daylight saving change on the host, and the stored time would not be an absolute one.
public enum IdentityCheck {
    public static let serverName = "mosh-server"
    public static let startTimeTolerance: TimeInterval = 2

    /// The `ps` invocation, in POSIX `sh` syntax.
    public static func psCommand(pid: Int32) -> String {
        "TZ=UTC0 LC_ALL=C ps -p \(pid) -o user= -o lstart= -o comm="
    }

    /// The command line for an SSH `exec`: wrapped in `sh -c` because the login shell that runs
    /// it may be csh or fish, which do not know `VAR=value command`.
    public static func remoteCommand(pid: Int32) -> String {
        "sh -c " + ShellQuote.alwaysQuote(psCommand(pid: pid))
    }

    /// Parses the output of the `ps` command: `user Www Mmm d HH:MM:SS YYYY comm`, from Linux
    /// (procps) or macOS. Returns nil for empty output and for anything else.
    public static func parse(_ output: String) -> ProcessIdentity? {
        // One process, one line. Take the first line that parses; a login shell may print
        // something of its own around it.
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            if let identity = parseLine(String(rawLine)) { return identity }
        }
        return nil
    }

    static func parseLine(_ line: String) -> ProcessIdentity? {
        // Split off six fields by runs of blanks; the rest, with its inner spaces, is comm.
        var fields: [Substring] = []
        var rest = Substring(line)
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        for _ in 0..<6 {
            rest = rest.drop(while: isBlank)
            let field = rest.prefix(while: { !isBlank($0) })
            guard !field.isEmpty else { return nil }
            fields.append(field)
            rest = rest.dropFirst(field.count)
        }
        rest = rest.drop(while: isBlank)
        while let last = rest.last, isBlank(last) { rest.removeLast() }
        guard !rest.isEmpty else { return nil }

        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard weekdays.contains(String(fields[1])),
            let monthIndex = months.firstIndex(of: String(fields[2])),
            let day = decimal(fields[3], maxDigits: 2), (1...31).contains(day),
            let year = decimal(fields[5], maxDigits: 4), year >= 1970
        else { return nil }
        let clock = fields[4].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3,
            let hour = decimal(clock[0], maxDigits: 2), hour <= 23,
            let minute = decimal(clock[1], maxDigits: 2), minute <= 59,
            let second = decimal(clock[2], maxDigits: 2), second <= 60
        else { return nil }

        let days = daysFromCivil(year: year, month: monthIndex + 1, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second
        return ProcessIdentity(
            user: String(fields[0]), startTime: Date(timeIntervalSince1970: TimeInterval(seconds)),
            command: String(rest))
    }

    /// The pass rule.
    public static func evaluate(
        _ found: ProcessIdentity?, loginUser: String, expectedStartTime: Date
    ) -> IdentityVerdict {
        guard let found else { return .failed(.noSuchProcess) }
        guard userMatches(psUser: found.user, loginUser: loginUser) else {
            return .failed(.wrongUser(found: found.user))
        }
        guard found.commandBasename == serverName else {
            return .failed(.notMoshServer(found: found.command))
        }
        guard abs(found.startTime.timeIntervalSince(expectedStartTime)) <= startTimeTolerance else {
            return .failed(.startTimeDiffers(found: found.startTime))
        }
        return .passed(found)
    }

    /// `ps` output and the pass rule in one step. Empty output is "no such process"; output that
    /// is not a `ps` line is `unreadable` (and so fails).
    public static func evaluate(
        psOutput: String, loginUser: String, expectedStartTime: Date
    ) -> IdentityVerdict {
        let trimmed = psOutput.filter { !$0.isWhitespace }
        if trimmed.isEmpty { return .failed(.noSuchProcess) }
        guard let found = parse(psOutput) else { return .failed(.unreadable(output: psOutput)) }
        return evaluate(found, loginUser: loginUser, expectedStartTime: expectedStartTime)
    }

    /// Whether the user column of `ps` names the login user. procps shows a name that does not
    /// fit its 8-character column as the first 7 characters and `+`; that form matches when it
    /// is a prefix of the login user. (macOS widens the column instead.)
    public static func userMatches(psUser: String, loginUser: String) -> Bool {
        guard !psUser.isEmpty, !loginUser.isEmpty else { return false }
        if psUser == loginUser { return true }
        if psUser.hasSuffix("+") {
            let prefix = psUser.dropLast()
            return !prefix.isEmpty && loginUser.count > prefix.count && loginUser.hasPrefix(prefix)
        }
        return false
    }

    private static func decimal(_ text: Substring, maxDigits: Int) -> Int? {
        guard !text.isEmpty, text.count <= maxDigits, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        return Int(text)
    }

    /// Days from 1970-01-01 to the given date in the proleptic Gregorian calendar.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146097 + dayOfEra - 719468
    }
}

/// The session health probe's result table (plan, section 4).
///
/// The session's server is the process with the record's pid and start time **at the record's
/// address** (the numeric address the datagrams go to, docs/RESUME.md `meta`). A pid means
/// nothing on another machine, so a failed check says "ended" only when SSH reached that same
/// address (review M6-1). Everything else that is not a pass is `unknown`: the session is kept,
/// and nothing is abandoned, deleted or killed because of it.
public enum ProbeResult: Equatable, Sendable {
    /// SSH fails: the host is unreachable.
    case hostUnreachable(BootstrapError)
    /// At the session's own address no process passes the check: the session ended or the host
    /// restarted. This includes the shell exiting while the app was away.
    case sessionEnded(IdentityMismatch)
    /// The check passes, but SSH reached a different address than the saved IP: the server is
    /// bound to the saved IP (`-s`), which this network cannot reach.
    case serverBoundToUnreachableAddress(savedAddress: String, sshAddress: String)
    /// The check passes at the same address: UDP is blocked on this network.
    case udpBlocked
    /// The probe's answer says nothing about the session's server.
    case unknown(Unknown)

    /// Why a probe that got an answer proves nothing.
    public enum Unknown: Equatable, Sendable {
        /// The check failed at a machine other than the session's (the host name now leads
        /// elsewhere, or the saved host was edited). The session's server was not asked.
        case askedAnotherAddress(savedAddress: String, sshAddress: String, IdentityMismatch)
        /// `ps` answered with something that is not its line: neither "there" nor "gone".
        case unreadableAnswer(sshAddress: String)
        /// The record has no address to compare with.
        case noSavedAddress(sshAddress: String)
    }

    /// Combines the identity verdict with the address SSH reached.
    public static func from(verdict: IdentityVerdict, savedAddress: String, sshAddress: String) -> ProbeResult {
        // Only the same, known address proves that the probe ran on the session's server.
        let sameMachine = !savedAddress.isEmpty && savedAddress == sshAddress
        switch verdict {
        case .failed(let mismatch):
            if savedAddress.isEmpty { return .unknown(.noSavedAddress(sshAddress: sshAddress)) }
            guard sameMachine else {
                return .unknown(.askedAnotherAddress(
                    savedAddress: savedAddress, sshAddress: sshAddress, mismatch))
            }
            if case .unreadable = mismatch { return .unknown(.unreadableAnswer(sshAddress: sshAddress)) }
            return .sessionEnded(mismatch)
        case .passed:
            return sameMachine
                ? .udpBlocked
                : .serverBoundToUnreachableAddress(savedAddress: savedAddress, sshAddress: sshAddress)
        }
    }

    public var meaning: String {
        switch self {
        case .hostUnreachable:
            return "The host cannot be reached."
        case .sessionEnded:
            return "The session has ended or the host was restarted."
        case .serverBoundToUnreachableAddress(let saved, let ssh):
            return "The session is still running, but it listens on \(saved), which this network cannot reach (SSH reached \(ssh))."
        case .udpBlocked:
            return "The session is still running, but UDP is blocked on this network."
        case .unknown(.askedAnotherAddress(let saved, let ssh, _)):
            return "The host name now leads to another machine (\(ssh)); the session is on \(saved). The session is kept."
        case .unknown(.unreadableAnswer):
            return "The host did not say whether the session is still running. The session is kept."
        case .unknown(.noSavedAddress):
            return "The session's address is not known, so the host cannot say whether it is still running. The session is kept."
        }
    }

    /// What the app does next.
    public enum Action: Equatable, Sendable {
        /// Keep waiting under the "Last contact" banner.
        case keepWaiting
        /// Mark the record dead and bootstrap a new session (the fallback of section 3). Only
        /// `sessionEnded` gives this.
        case startNewSession
        /// Say what is wrong and keep the session.
        case informAndKeepSession
    }

    public var action: Action {
        switch self {
        case .hostUnreachable: return .keepWaiting
        case .sessionEnded: return .startNewSession
        case .serverBoundToUnreachableAddress, .udpBlocked, .unknown: return .informAndKeepSession
        }
    }

    public var hint: String? {
        switch self {
        case .serverBoundToUnreachableAddress:
            return "Use a host name that works on every network, such as the Tailscale name."
        case .udpBlocked:
            return "Try another network, or set a UDP port range that this network lets through."
        case .unknown(.askedAnotherAddress):
            return "Use a host name that always leads to the same machine, or return to a network where the session's address works."
        case .hostUnreachable, .sessionEnded, .unknown:
            return nil
        }
    }
}
