import Darwin
import XCTest

/// A real mosh session in the app: a mosh-server from scripts/mosh-spawner.py,
/// the app's NWDatagramTransport, MoshSession and SwiftTermSurface.
final class SessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// M5's first UI test (docs/PLAN.md): type `echo hello-$((6*7))`, expect `hello-42`.
    /// The typed line does not contain `hello-42`; only the shell's answer does.
    func testHello42() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        // Just before launch: a server exits after 60 s without a client.
        let server = try spawner.newServer()
        defer { spawner.stop(pid: server.pid) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTesting", "1", "-uiTestingResetSessions", "1",
            "-debugMoshPort", String(server.port),
            "-debugMoshKey", server.key,
        ]
        app.launch()

        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        // The shell's prompt (PS1 "$ ") proves the first state came from the server.
        expect(screen, contains: "$", timeout: 15)

        app.typeText("echo hello-$((6*7))\n")
        expect(screen, containsLine: "hello-42", timeout: 15)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no error banner")
        XCTAssertTrue(try spawner.isAlive(pid: server.pid), "the server still runs")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "hello-42"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCTestCase {
    /// Polls the screen text until one row is exactly `line` (trailing blanks are
    /// already trimmed by the app).
    func expect(
        _ screen: XCUIElement, containsLine line: String, timeout: TimeInterval = 8,
        file: StaticString = #filePath, line sourceLine: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (screen.value as? String) ?? ""
            if last.split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(line)) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("no row is \"\(line)\". Screen:\n\(last)", file: file, line: sourceLine)
    }

    // MARK: Sessions on the spawner's sshd, shared by the UI-test classes

    // docs/notes/multi-session/DESIGN.md section 8 and step 5b: every UI-test class that starts a
    // session on the spawner's sshd starts it through these, so the teardown that `openSession`
    // registers stops what it leaves.

    /// Ends the session on screen from the terminal and waits for the host list: the "…" button
    /// (`sessionMenu`, no menu: a tap asks at once) and "End Session" in the confirmation
    /// (DESIGN.md 5.2, step 6).
    func endSessionFromTerminal(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.navigationBars.buttons["sessionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the \"…\" button", file: file, line: line)
        menu.tap()
        let confirm = app.alerts["End Session?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation", file: file, line: line)
        confirm.buttons["End Session"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list",
                      file: file, line: line)
    }

    /// The terminal's rows (`screenText`). Named so that it does not clash with the `rows(_:)`
    /// that `AppearanceUITests`, `BannerLayoutUITests` and `ResumeUITests` declare.
    func screenRows(_ screen: XCUIElement) -> [String] {
        ((screen.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A fresh launch, a host for the spawner's sshd, a session to it; returns the `pid-$$` row
    /// and the server's pid.
    func openSession(_ app: XCUIApplication, spawner: MoshSpawner, name: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (pidLine: String, servers: [Int32]) {
        let sshd = try spawner.sshd()
        XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run", file: file, line: line)
        // Whatever this test leaves running (a session sent to the background, or one the app
        // was killed with) is stopped when it ends, so the next test starts without it.
        addTeardownBlock { spawner.stopLeftoverServers() }
        try spawner.clearMarks()
        app.launchArguments = ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1", "-uiTestingSpawnerPort", String(spawner.port)]
        app.launch()
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)
        addHost(app, fields: [
            "name": name, "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ], file: file, line: line)
        let row = app.cells["host-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(row.value as? String, "none", "no session yet", file: file, line: line)
        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "host key prompt", file: file, line: line)
        alert.buttons["Trust"].tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing", file: file, line: line)
        expect(screen, contains: "$", timeout: 30)
        app.typeText("echo pid-$$\n")
        var pidLine = ""
        waitFor({ pidLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !pidLine.isEmpty }(),
                "the shell's pid", timeout: 15, file: file, line: line)
        let servers = try spawner.sshdServers()
        XCTAssertEqual(servers.count, 1, file: file, line: line)
        return (pidLine, servers)
    }

    /// `openSession`, then Home, a clean save and the process killed: the record is resumable
    /// and its server runs on.
    func startSavedSession(_ app: XCUIApplication, spawner: MoshSpawner, name: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> (pidLine: String, servers: [Int32]) {
        let opened = try openSession(app, spawner: spawner, name: name, file: file, line: line)
        XCUIDevice.shared.press(.home)
        waitFor((try? spawner.marks())?.contains("background-clean") == true, "a clean snapshot",
                timeout: 15, file: file, line: line)
        app.terminate()
        XCTAssertEqual(try spawner.sshdServers(), opened.servers, "the server outlives the app", file: file, line: line)
        return opened
    }

    /// With the app on the list (no reset): a second host with the same sshd fields as
    /// `openSession`'s under another name, a tap on it, the session's shell. No host key prompt:
    /// known hosts are keyed by host and port, so the first host's trust covers it. Clears the
    /// marks first. Returns the `pid-$$` row and the new server's pid.
    func openSessionOnAnotherHost(_ app: XCUIApplication, spawner: MoshSpawner, name: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> (pidLine: String, server: Int32) {
        let sshd = try spawner.sshd()
        let before = Set(try spawner.sshdServers())
        try spawner.clearMarks()
        addHost(app, fields: [
            "name": name, "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts, "remoteCommand": "/bin/sh",
        ], file: file, line: line)
        let row = app.cells["host-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(row.value as? String, "none", "no session yet", file: file, line: line)
        row.tap()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "screenText element missing", file: file, line: line)
        expect(screen, contains: "$", timeout: 30)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no host key prompt for a known host and port", file: file, line: line)
        app.typeText("echo pid-$$\n")
        var pidLine = ""
        waitFor({ pidLine = screenRows(screen).first { $0.hasPrefix("pid-") } ?? ""; return !pidLine.isEmpty }(),
                "the shell's pid", timeout: 15, file: file, line: line)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { !before.contains($0) }; return added.count == 1 }(),
                "one new server (before: \(before.sorted()))", timeout: 15, file: file, line: line)
        return (pidLine, added.first ?? 0)
    }

    /// Relaunch with the stored records and hosts, straight to the host list. `animations`: UIKit's
    /// animations stay on (`-uiTestingAnimations 1`; such a launch may take up to a minute).
    func relaunchShowingTheList(_ app: XCUIApplication, spawner: MoshSpawner, animations: Bool = false) {
        app.launchArguments = ["-uiTesting", "1", "-uiTestingKeepSessions", "1", "-uiTestingSkipColdStart", "1",
                               "-uiTestingSpawnerPort", String(spawner.port)]
            + (animations ? ["-uiTestingAnimations", "1"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: animations ? 60 : 15), "the host list")
        XCTAssertFalse(app.otherElements["screenText"].exists, "no terminal at launch")
    }
}

/// Client for scripts/mosh-spawner.py, which scripts/sim-test.sh runs on the Mac and
/// announces as MOSH_SPAWNER_URL (http://127.0.0.1:PORT). Plain HTTP/1.0 over a
/// POSIX socket: the test runner is an iOS app, and App Transport Security would
/// have a say over URLSession's plain-HTTP loads.
struct MoshSpawner {
    struct Server: Decodable {
        let port: UInt16
        let key: String
        let pid: Int32
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let port: UInt16

    static func fromEnvironment() throws -> MoshSpawner {
        guard let url = ProcessInfo.processInfo.environment["MOSH_SPAWNER_URL"],
              let components = URLComponents(string: url), components.host == "127.0.0.1",
              let port = components.port, let port16 = UInt16(exactly: port)
        else {
            throw Failure(description: "MOSH_SPAWNER_URL is not set: run the UI tests with scripts/sim-test.sh, which starts scripts/mosh-spawner.py")
        }
        return MoshSpawner(port: port16)
    }

    func newServer() throws -> Server {
        try JSONDecoder().decode(Server.self, from: get("/new"))
    }

    /// A server behind the spawner's delaying UDP relay (`port` is the relay's): every
    /// datagram is held `delayMs` in each direction. `program`: one of the spawner's fixed
    /// programs instead of /bin/sh.
    func newServer(delayMs: Int, program: String? = nil) throws -> Server {
        var path = "/new?delay_ms=\(delayMs)"
        if let program { path += "&program=\(program)" }
        return try JSONDecoder().decode(Server.self, from: get(path))
    }

    func isAlive(pid: Int32) throws -> Bool {
        struct Alive: Decodable { let alive: Bool }
        return try JSONDecoder().decode(Alive.self, from: get("/alive?pid=\(pid)")).alive
    }

    func stop(pid: Int32) {
        _ = try? get("/stop?pid=\(pid)")
    }

    /// The throwaway sshd that scripts/sim-test.sh asks the spawner to run (--sshd).
    struct SSHD: Decodable {
        let port: Int
        let user: String
        let hostKeyFingerprint: String
        let udpPorts: String
        let serverPath: String
    }

    func sshd() throws -> SSHD {
        try JSONDecoder().decode(SSHD.self, from: get("/sshd"))
    }

    /// Adds a public key line to the throwaway sshd's own authorized_keys (never to a
    /// real one).
    func authorize(publicKeyLine: String) throws {
        // Everything but letters and digits encoded: "+" would otherwise read as a space.
        let encoded = publicKeyLine.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        _ = try get("/sshd/authorize?key=\(encoded)")
    }

    /// mosh-servers started through the throwaway sshd (they use its UDP port range).
    func sshdServers() throws -> [Int32] {
        struct Servers: Decodable { let pids: [Int32] }
        return try JSONDecoder().decode(Servers.self, from: get("/sshd/servers")).pids
    }

    /// Kills one of the throwaway sshd's mosh-servers (a server gone while the app was away).
    func stopSSHDServer(pid: Int32) throws {
        _ = try get("/sshd/stop?pid=\(pid)")
    }

    /// Kills every mosh-server of the throwaway sshd's port range that is still running (the
    /// spawner's SIGKILL also ends a SIGSTOPped one) and waits, up to `timeout`, until
    /// `/sshd/servers` lists none. A session a test leaves behind (the app sent to the
    /// background, or killed) keeps its server, and the next `openSession` would find it. Used
    /// as a teardown; it never fails a test itself: the caller checks `sshdServers()`.
    func stopLeftoverServers(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while let servers = try? sshdServers(), !servers.isEmpty, Date() < deadline {
            servers.forEach { try? stopSSHDServer(pid: $0) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// SIGSTOP (`"STOP"`) or SIGCONT (`"CONT"`) to one of the throwaway sshd's mosh-servers: a
    /// server that cannot answer, as behind a dead network, and the same server back.
    /// - Returns: false if `pid` is not one of those servers.
    @discardableResult
    func signalSSHDServer(pid: Int32, _ signal: String) throws -> Bool {
        struct Reply: Decodable { let signalled: Bool }
        return try JSONDecoder().decode(Reply.self, from: get("/sshd/signal?pid=\(pid)&sig=\(signal)")).signalled
    }

    /// Holds (SIGSTOP) or releases (SIGCONT) the throwaway sshd itself: while it is held a new
    /// connection waits unanswered, so the app's host key question comes only after the release.
    func holdSSHD(_ on: Bool) throws {
        _ = try get("/sshd/hold?on=\(on ? 1 : 0)")
    }

    /// What the app reported (UITestMarks), in order.
    func marks() throws -> [String] {
        struct Marks: Decodable { let events: [String] }
        return try JSONDecoder().decode(Marks.self, from: get("/marks")).events
    }

    func clearMarks() throws {
        _ = try get("/marks/clear")
    }

    /// GET on 127.0.0.1:port; returns the body of a 200 answer.
    func get(_ path: String) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: errno \(errno)") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure(description: "connect to the spawner on port \(port): errno \(errno)") }
        let request = Array("GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else {
            throw Failure(description: "write to the spawner: errno \(errno)")
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw Failure(description: "read from the spawner: errno \(errno)") }
            if count == 0 { break }
            response.append(contentsOf: buffer[0..<count])
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw Failure(description: "no HTTP answer from the spawner")
        }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let body = response[split.upperBound...]
        guard head.hasPrefix("HTTP/1.0 200") || head.hasPrefix("HTTP/1.1 200") else {
            throw Failure(description: "spawner \(path): \(head.split(separator: "\r\n").first ?? "") \(String(decoding: body, as: UTF8.self))")
        }
        return Data(body)
    }
}
