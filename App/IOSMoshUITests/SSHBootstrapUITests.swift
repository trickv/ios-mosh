import XCTest

/// The whole M5 path in the app: a saved host, the SSH bootstrap with the device key
/// against the throwaway sshd that scripts/mosh-spawner.py runs on 127.0.0.1 (--sshd),
/// the host key prompt, mosh-server, `hello-42`, and leaving the screen ends the session
/// and frees it.
final class SSHBootstrapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSavedHostBootstrapsToHello42() throws {
        let spawner = try MoshSpawner.fromEnvironment()
        let sshd = try spawner.sshd()
        XCTAssertEqual(try spawner.sshdServers(), [], "no servers left from an earlier run")

        let app = XCUIApplication()
        // No saved hosts and no known host keys: the host key is a first contact.
        app.launchArguments += ["-uiTesting", "1", "-uiTestingResetSessions", "1", "-uiTestingReset", "1"]
        app.launch()

        // The throwaway sshd accepts this device's key, and only through its own
        // authorized_keys file.
        let key = readDeviceKey(app)
        try spawner.authorize(publicKeyLine: key.line)

        addHost(app, fields: [
            "name": "sshd", "host": "127.0.0.1", "port": String(sshd.port), "user": sshd.user,
            // A non-login shell's PATH has no Homebrew: the error table's fix.
            "serverPath": sshd.serverPath, "udpPorts": sshd.udpPorts,
            // A plain shell with a "$" prompt, whatever the login shell's rc files do.
            "remoteCommand": "/bin/sh",
        ])
        let row = app.cells["host-sshd"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        // First contact: the fingerprint is shown and must be the sshd's.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "host key prompt")
        let shown = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(shown.contains(sshd.hostKeyFingerprint), "prompt shows \(sshd.hostKeyFingerprint):\n\(shown)")
        alert.buttons["Trust"].tap()

        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        expect(screen, contains: "$", timeout: 30)
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "no error banner")
        app.typeText("echo hello-$((6*7))\n")
        expect(screen, containsLine: "hello-42", timeout: 15)
        XCTAssertEqual(try spawner.sshdServers().count, 1, "one mosh-server started over SSH")
        attachScreenshot(app, "ssh-hello-42")

        // Leaving the screen ends the session on the server and frees the screen.
        endSessionFromTerminal(app)
        let live = app.otherElements["liveTerminals"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        waitFor((live.value as? String) == "0", "terminal screen freed (liveTerminals \(live.value ?? "nil"))")
        waitFor((try? spawner.sshdServers()) == [], "mosh-server ended", timeout: 15)

        // Second connect: the key is known now, so there is no prompt.
        app.cells["host-sshd"].tap()
        expect(screen, contains: "$", timeout: 30)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no host key prompt for a known host")
        app.typeText("echo again-$((6*7))\n")
        expect(screen, containsLine: "again-42", timeout: 15)
        endSessionFromTerminal(app)
        waitFor((try? spawner.sshdServers()) == [], "second mosh-server ended", timeout: 15)
    }
}
