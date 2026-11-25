import XCTest

/// The App Store screenshots (docs/notes/publication/screenshots.md): the Debug app on the
/// simulator against scripts/mosh-spawner.py, with demo data only. Skipped unless the test
/// runner's environment has STORE_SCREENSHOTS=1 (scripts/sim-test.sh passes
/// TEST_RUNNER_STORE_SCREENSHOTS=1 on as STORE_SCREENSHOTS), so the normal suite never runs it.
///
/// Every picture is the whole screen (`XCUIScreen.main`, status bar included) at the device's
/// native pixel size, kept as a PNG attachment named `NN-name`; scripts/sim-test.sh exports them
/// to ~/ios-mosh-out/attachments (manifest.json maps the names to the files).
///
/// Demo data only: the shell runs with HOME in a throwaway directory under /tmp, a made-up user
/// "alex" in the prompt and in git, and the hosts' fields are changed to build.example.net and
/// web-01.example.net before any picture shows them. The spawner's sshd needs 127.0.0.1 and the
/// Mac's own user to log in, so the host "build" carries those only until its sessions run; the
/// parked sessions resume from their own records, not from the host's fields.
final class StoreScreenshots: XCTestCase {
    /// Where the demo lives on the Mac; removed and made again by every run.
    private let demoRoot = "/tmp/iosmosh-store-demo"

    override func setUp() {
        continueAfterFailure = false
    }

    func testStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STORE_SCREENSHOTS"] == "1",
                          "App Store screenshots: run with TEST_RUNNER_STORE_SCREENSHOTS=1 (docs/notes/publication/screenshots.md)")
        let spawner = try MoshSpawner.fromEnvironment()
        let app = XCUIApplication()
        // Dark: the terminal is black in either mode, and in dark mode the status bar over it is
        // white (in light mode its dark text vanishes on the terminal's black). Put back after.
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock { XCUIDevice.shared.appearance = appearance }

        // Session 1 on the host "build": a shell in a small demo repository.
        let first = try openSession(app, spawner: spawner, name: "build")
        defer { first.servers.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        // Again with the app running: set before the launch only, the app still came up light.
        XCUIDevice.shared.appearance = .dark
        settle()
        let screen = app.otherElements["screenText"]
        type(app, environmentLine())
        type(app, "rm -rf \(demoRoot); mkdir -p $HOME/webapp/static $HOME/webapp/templates $HOME/webapp/tests && cd $HOME/webapp && git init -q -b main && echo repo-made")
        expect(screen, containsLine: "repo-made", timeout: 15)
        type(app, #"c() { git add -A && git commit -qm "$1"; }; echo '# webapp' > README.md; c 'Initial commit'; printf 'flask==3.1.0\ngunicorn==23.0.0\n' > requirements.txt; c 'Pin dependencies'; echo '<h1>webapp</h1>' > templates/index.html; echo 'body { font: 16px sans-serif; }' > static/style.css; c 'Add templates and static assets'; echo step-2"#)
        expect(screen, containsLine: "step-2", timeout: 20)
        type(app, Self.appPyLine + #"; c 'Add items API and health check'; echo step-3"#)
        expect(screen, containsLine: "step-3", timeout: 20)
        type(app, #"printf '#!/bin/sh\nset -e\nrsync -az ./ web-01.example.net:/srv/webapp/\n' > deploy.sh; chmod +x deploy.sh; c 'Add deploy script'; printf 'test:\n\tpython3 -m pytest tests\n' > Makefile; echo 'def test_health(): pass' > tests/test_app.py; c 'Run the tests with make test'; echo '## Usage' >> README.md; echo 'TODO: rate limits' > NOTES.md; echo step-4"#)
        expect(screen, containsLine: "step-4", timeout: 20)
        type(app, #"printf '\033]2;webapp\007'; exec /bin/bash --norc --noprofile"#)
        expect(screen, contains: "alex@build:~/webapp$", timeout: 15)
        type(app, "clear")
        waitFor(screenRows(screen).first?.hasPrefix("alex@build:~/webapp$") == true, "a cleared screen", timeout: 10)
        type(app, "ls")
        expect(screen, contains: "requirements.txt", timeout: 10)
        type(app, "git log --oneline --decorate")
        expect(screen, contains: "Initial commit", timeout: 10)
        type(app, "git status -sb")
        expect(screen, contains: "NOTES.md", timeout: 10)
        openKeyBar(app)
        settle()
        checkNoPrivateText(screen)
        shoot("01-terminal")

        // Session 2 on the same host: a tap on a host row that has a session starts another one.
        let back = app.navigationBars.buttons["Hosts"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the back button")
        back.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")
        let before = Set(try spawner.sshdServers())
        app.cells["host-build"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the second session's terminal")
        expect(screen, contains: "$", timeout: 30)
        var added: [Int32] = []
        waitFor({ added = ((try? spawner.sshdServers()) ?? []).filter { !before.contains($0) }; return added.count == 1 }(),
                "a second server", timeout: 15)
        defer { added.forEach { try? spawner.stopSSHDServer(pid: $0) } }
        type(app, environmentLine())
        type(app, #"cd $HOME/webapp && printf '\033]2;vim app.py\007' && exec /bin/bash --norc --noprofile"#)
        expect(screen, contains: "alex@build:~/webapp$", timeout: 15)
        type(app, "clear; vim -u NONE -N -i NONE -n -c 'syntax on' -c 'set bg=dark nu ls=2 ru' app.py")
        expect(screen, contains: "def health():", timeout: 15)
        app.typeText("12G")
        openKeyBar(app)
        settle()
        checkNoPrivateText(screen)
        shoot("03-vim")
        back.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "the host list")

        // The second host: demo values only, never connected.
        addHost(app, fields: ["name": "web-01", "host": "web-01.example.net", "user": "alex"])
        // The first host's fields become demo values; its sessions run on from their records.
        openEditor(app, row: "host-build")
        setField(app, "host", "build.example.net")
        setField(app, "port", "")
        setField(app, "user", "alex")
        setField(app, "serverPath", "")
        setField(app, "udpPorts", "60001:60010")
        setField(app, "remoteCommand", "")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list")

        // The Hosts list: two hosts, two sessions under the first, the dot on the last one used.
        let session1 = app.cells["session-build-1"], session2 = app.cells["session-build-2"]
        waitFor((session1.value as? String) == "resumable" && (session2.value as? String) == "resumable",
                "both sessions parked (\(session1.value ?? "nil"), \(session2.value ?? "nil"))", timeout: 20)
        XCTAssertTrue(app.cells["host-build"].staticTexts["alex@build.example.net"].waitForExistence(timeout: 10),
                      "the host row shows the demo address")
        XCTAssertTrue(app.cells["host-web-01"].staticTexts["alex@web-01.example.net"].exists)
        XCTAssertTrue(session1.staticTexts["webapp"].exists, "the first session's title")
        XCTAssertTrue(session2.staticTexts["vim app.py"].exists, "the second session's title")
        checkNoPrivateLabels(app)
        settle()
        shoot("02-hosts")

        // The host editor with the demo values, no keyboard.
        openEditor(app, row: "host-build")
        settle()
        checkNoPrivateLabels(app)
        shoot("04-host-editor")
        app.navigationBars.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), "back in the list")

        // The swipe on a session row: End Session and Forget.
        session1.swipeRight()
        XCTAssertTrue(app.buttons["End Session"].waitForExistence(timeout: 5), "the swipe's End Session")
        XCTAssertTrue(app.buttons["Forget"].exists, "the swipe's Forget")
        settle()
        shoot("05-swipe")
        app.navigationBars["Hosts"].tap()  // closes the swipe without acting
        settle()

        // Settings: font size, themes, cursor.
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.tables["settings"].waitForExistence(timeout: 10), "Settings")
        settle()
        shoot("06-settings")
    }

    // MARK: Helpers

    /// The shell's environment: HOME in the demo directory, the made-up user in the prompt and in
    /// git, no config of the Mac's user (no global or system git config, no rc files).
    private func environmentLine() -> String {
        // cd first: the prompt's \w would otherwise show the Mac user's home until the next cd.
        "cd /tmp && export BASH_SILENCE_DEPRECATION_WARNING=1 HOME=\(demoRoot)/alex CLICOLOR=1 GIT_PAGER=cat"
            + " GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1"
            + " GIT_AUTHOR_NAME=Alex GIT_AUTHOR_EMAIL=alex@example.net GIT_COMMITTER_NAME=Alex GIT_COMMITTER_EMAIL=alex@example.net"
            + #" PS1='\[\e[1;32m\]alex@build\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '"#
    }

    /// app.py of the demo repository, kept under 50 columns so that vim with line numbers does
    /// not wrap on a phone.
    private static let appPyLine: String = {
        let lines = [
            "from flask import Flask, abort, jsonify",
            "",
            "app = Flask(__name__)",
            "VERSION = \"1.4.2\"",
            "ITEMS = {1: \"keyboard\", 2: \"terminal\"}",
            "",
            "",
            "@app.route(\"/health\")",
            "def health():",
            "    return jsonify(status=\"ok\", version=VERSION)",
            "",
            "",
            "@app.route(\"/api/items/<int:item_id>\")",
            "def item(item_id):",
            "    # TODO: read from the database",
            "    name = ITEMS.get(item_id)",
            "    if name is None:",
            "        abort(404)",
            "    return jsonify(id=item_id, name=name)",
            "",
            "",
            "if __name__ == \"__main__\":",
            "    app.run(port=8080, debug=True)",
        ]
        return "printf '%s\\n' " + lines.map { "'\($0)'" }.joined(separator: " ") + " > app.py"
    }()

    /// The simulator counts the Mac's keyboard as a hardware keyboard, so the key bar starts
    /// folded into its "Keys" button; a tap opens it, as a user with a keyboard would.
    private func openKeyBar(_ app: XCUIApplication) {
        let expand = app.buttons["keyBar.expand"]
        if expand.exists && expand.isHittable {
            expand.tap()
            XCTAssertTrue(app.buttons["keyBar.esc"].waitForExistence(timeout: 5) || app.otherElements["keyBar.scroll"].exists,
                          "the key bar opened")
        }
    }

    private func type(_ app: XCUIApplication, _ line: String) {
        app.typeText(line + "\n")
    }

    /// Clears a field of the host editor and types `text` ("" leaves it empty, showing its
    /// placeholder).
    private func setField(_ app: XCUIApplication, _ key: String, _ text: String) {
        if !text.isEmpty {
            replaceText(app, field: "field.\(key)", with: text)
            return
        }
        let field = app.textFields["field.\(key)"]
        scrollTo(app, field)
        field.tap()
        waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true, "field.\(key) has the keyboard focus")
        let clear = field.buttons.firstMatch
        if clear.exists {
            clear.tap()
            waitFor(!clear.exists, "field.\(key) cleared")
        }
    }

    /// Lets the display tick and the list's refresh draw what was just typed or tapped.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    /// What must never show: the spawner's address and the Mac's own user and home.
    private var forbidden: [String] {
        var words = ["127.0.0.1", "/Users/", "ios-mosh-sshd", "62700"]
        if let user = try? MoshSpawner.fromEnvironment().sshd().user, !user.isEmpty { words.append(user) }
        return words
    }

    private func checkNoPrivateText(_ screen: XCUIElement) {
        let text = (screen.value as? String) ?? ""
        for word in forbidden {
            XCTAssertFalse(text.contains(word), "the terminal shows a private word (\(word.count) characters)")
        }
    }

    private func checkNoPrivateLabels(_ app: XCUIApplication) {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
            + app.textFields.allElementsBoundByIndex.compactMap { $0.value as? String }
        for word in forbidden {
            XCTAssertFalse(labels.contains { $0.contains(word) }, "the screen shows a private word (\(word.count) characters)")
        }
    }

    /// Dark mode, checked on the screen itself: setting it once did not always reach the app
    /// (a run on the iPhone 17 Pro Max simulator came out light although the log said "Setting
    /// appearance mode to Dark"). Light and dark are told apart by the pixel at the middle of the
    /// screen's bottom tenth: the list's or editor's background, or the keyboard's.
    private func makeDark() {
        for _ in 0..<5 {
            if isDark() { return }
            XCUIDevice.shared.appearance = .light
            settle()
            XCUIDevice.shared.appearance = .dark
            settle()
        }
        XCTAssertTrue(isDark(), "the simulator shows dark mode")
    }

    private func isDark() -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage,
              let pixel = image.cropping(to: CGRect(x: image.width / 2, y: image.height * 95 / 100, width: 1, height: 1))
        else { return false }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn && rgba[0] < 100 && rgba[1] < 100 && rgba[2] < 100
    }

    /// The whole screen at native pixels, in dark mode, kept as a PNG attachment.
    private func shoot(_ name: String) {
        makeDark()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name + ".png",
                                       payload: shot.pngRepresentation, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
