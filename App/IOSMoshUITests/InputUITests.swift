import XCTest

/// M7 (docs/PLAN.md section 5 and "App, on charlie's simulator"): the key bar, paste and
/// OSC 52, each against a real mosh-server from scripts/mosh-spawner.py running `/bin/sh`.
/// Bytes are checked where the remote program sees them: in `cat -v`, or by what the shell
/// does with them.

/// A session in the app against a fresh server; the key bar forced expanded (no hardware
/// keyboard, whatever the simulator says).
struct InputSession {
    let app: XCUIApplication
    let screen: XCUIElement
    let spawner: MoshSpawner
    let server: MoshSpawner.Server

    static func launch(_ test: XCTestCase, hardwareKeyboard: Bool = false,
                       extraArguments: [String] = []) throws -> InputSession {
        let spawner = try MoshSpawner.fromEnvironment()
        // Just before launch: a server exits after 60 s without a client.
        let server = try spawner.newServer()
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTesting", "1", "-uiTestingResetSessions", "1",
            "-uiTestingHardwareKeyboard", hardwareKeyboard ? "1" : "0",
            "-debugMoshPort", String(server.port),
            "-debugMoshKey", server.key,
        ] + extraArguments
        app.launch()
        let screen = app.otherElements["screenText"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "screenText element missing")
        test.expect(screen, contains: "$", timeout: 15)
        return InputSession(app: app, screen: screen, spawner: spawner, server: server)
    }

    func stop() {
        spawner.stop(pid: server.pid)
    }

    func key(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "keyBar.\(name)").firstMatch
    }

    func tap(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = key(name)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "key bar key \(name) missing", file: file, line: line)
        element.tap()
    }

    /// Scrolls the key bar's scrolling part until `name` is on screen, only as far as needed.
    /// By finger-speed drags (`dragKeyBar`), not `swipeLeft()`: XCUITest's swipe puts the
    /// finger down and lifts it 33 ms later with all of its movement in that last event, so
    /// UIKit can hand it to the key under it as a tap before the scroll view sees a drag (the
    /// 2026-11-19 stray "~": "tilde down", "tilde up-inside", then the drag 16 ms later; 2 in
    /// 15 runs). No finger moves like that; a drag at 400 points a second is a scroll every time.
    func scrollKeyBar(toShow name: String) {
        let scroll = app.scrollViews["keyBar.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "key bar scroll part missing")
        for _ in 0..<8 where !key(name).isHittable { dragKeyBar(towardsEnd: true) }
        XCTAssertTrue(key(name).isHittable, "key bar key \(name) not reachable")
    }

    /// One drag over the scrolling part, starting on whatever key is there, 150 points (less
    /// towards the start: the finger stops at the screen's edge), at 400 points a second, held
    /// still for a moment at the end (no fling).
    func dragKeyBar(towardsEnd: Bool) {
        let scroll = app.scrollViews["keyBar.scroll"]
        let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: towardsEnd ? 0.8 : 0.2, dy: 0.5))
        let to = from.withOffset(CGVector(dx: towardsEnd ? -150 : 150, dy: 0))
        from.press(forDuration: 0, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 400),
                   thenHoldForDuration: 0.2)
    }

    func screenshot(_ test: XCTestCase, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }
}

extension XCTestCase {
    /// Polls until at least `count` rows are exactly `line`.
    func expect(
        _ screen: XCUIElement, rows line: String, count: Int, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line sourceLine: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (screen.value as? String) ?? ""
            let found = last.split(separator: "\n", omittingEmptySubsequences: false).filter { $0 == Substring(line) }.count
            if found >= count { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("fewer than \(count) rows are \"\(line)\". Screen:\n\(last)", file: file, line: sourceLine)
    }

    /// Polls a label until its text contains `text`.
    func expect(
        label element: XCUIElement, contains text: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if element.exists {
                last = element.label
                if last.contains(text) { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("\(element) does not show \"\(text)\" (last: \"\(last)\")", file: file, line: line)
    }

    /// Empties the screen, so later checks see only new rows.
    func clearScreen(_ session: InputSession, file: StaticString = #filePath, line: UInt = #line) {
        session.app.typeText("clear\n")
        let deadline = Date().addingTimeInterval(10)
        var last = ""
        while Date() < deadline {
            last = (session.screen.value as? String) ?? ""
            let rows = last.split(separator: "\n").filter { !$0.isEmpty }
            if rows == ["$"] { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("the screen was not cleared. Screen:\n\(last)", file: file, line: line)
    }
}

final class KeyBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        keepDiagnosticsIfFailed()
        super.tearDown()
    }

    /// Sticky Ctrl, then "c" from the keyboard: ^C interrupts `sleep 60` and the shell takes
    /// the next command long before the sleep would end. Ctrl is cleared after the key.
    func testCtrlCInterruptsASleep() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        XCTAssertTrue(session.app.otherElements["keyBar"].waitForExistence(timeout: 5), "no key bar")

        session.app.typeText("sleep 60\n")
        expect(session.screen, contains: "sleep 60", timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        session.tap("ctrl")
        XCTAssertEqual(session.key("ctrl").value as? String, "on", "Ctrl is sticky")
        session.app.typeText("c")
        XCTAssertEqual(session.key("ctrl").value as? String, "off", "Ctrl is cleared after one key")
        session.app.typeText("echo after-$((2+3))\n")
        expect(session.screen, containsLine: "after-5", timeout: 10)
        session.screenshot(self, "ctrl-c")
    }

    /// Arrow up recalls the previous command: its output appears a second time.
    func testArrowUpRecallsThePreviousCommand() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        session.app.typeText("echo up-$((3+4))\n")
        expect(session.screen, rows: "up-7", count: 1)
        session.tap("up")
        expect(session.screen, contains: "$ echo up-$((3+4))", timeout: 10)
        session.app.typeText("\n")
        expect(session.screen, rows: "up-7", count: 2)
    }

    /// Tab completes a file name that only exists in a new temporary directory.
    func testTabCompletesAFileName() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        session.app.typeText("cd \"$(mktemp -d)\" && touch tabdone-file && echo ready-$((5+5))\n")
        expect(session.screen, containsLine: "ready-10")
        session.app.typeText("ls tabd")
        session.tap("tab")
        expect(session.screen, contains: "$ ls tabdone-file", timeout: 10)
        session.app.typeText("\n")
        expect(session.screen, containsLine: "tabdone-file")
    }

    /// What each key sends, as `cat -v` shows it. Cursor keys follow the remote program's
    /// cursor-key mode (mosh-server translates the client's application-mode arrows).
    func testKeysArriveAsTheRightBytes() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }

        // Normal cursor-key mode.
        session.app.typeText("printf '\\033[?1l'; cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("esc")
        session.app.typeText("\n")
        expect(session.screen, rows: "^[", count: 2)
        session.tap("up")
        session.tap("left")
        session.app.typeText("\n")
        expect(session.screen, rows: "^[[A^[[D", count: 2)
        session.tap("tab")
        session.app.typeText("x\n")
        expect(session.screen, rows: "\tx".replacingOccurrences(of: "\t", with: "        "), count: 1)
        // Sticky Alt sends ESC before the next key.
        session.tap("alt")
        XCTAssertEqual(session.key("alt").value as? String, "on")
        session.app.typeText("y\n")
        expect(session.screen, rows: "^[y", count: 2)
        XCTAssertEqual(session.key("alt").value as? String, "off")
        session.tap("pipe")
        session.tap("tilde")
        session.app.typeText("\n")
        expect(session.screen, rows: "|~", count: 2)
        session.scrollKeyBar(toShow: "tmuxPrefix")
        session.tap("pageUp")
        session.tap("pageDown")
        session.tap("tmuxPrefix")
        session.app.typeText("\n")
        expect(session.screen, rows: "^[[5~^[[6~^B", count: 2)
        // Ctrl-D ends cat (Ctrl is in the fixed part).
        session.tap("ctrl")
        session.app.typeText("d")
        session.app.typeText("echo done-$((1+1))\n")
        expect(session.screen, containsLine: "done-2")

        // Application cursor-key mode: the arrows arrive as ESC O.
        clearScreen(session)
        session.app.typeText("printf '\\033[?1h'; cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("up")
        session.tap("right")
        session.app.typeText("\n")
        expect(session.screen, rows: "^[OA^[OC", count: 1)
        session.screenshot(self, "keys-cat-v")
    }

    /// A drag over the scrolling part scrolls it and sends no key, also when it starts on a key
    /// and at either end of the bar (the drags of `scrollKeyBar`). Two rounds to the end and
    /// back, then a line: `cat -v` gets that line and nothing before it.
    func testADragOnTheKeyBarSendsNoKey() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        session.app.typeText("cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        let scroll = session.app.scrollViews["keyBar.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "key bar scroll part missing")
        for _ in 0..<2 {
            // About 480 points of bar: four drags of 150 reach the end, then push against it.
            for _ in 0..<4 { session.dragKeyBar(towardsEnd: true) }
            XCTAssertTrue(session.key("hideKeyboard").isHittable, "the drags reach the end of the bar")
            // Back: the bar sits at the screen's right edge, so a drag that way moves about 30
            // points before the finger leaves the screen; then one more against the start.
            for _ in 0..<24 where !session.key("alt").isHittable { session.dragKeyBar(towardsEnd: false) }
            XCTAssertTrue(session.key("alt").isHittable, "the drags reach the start of the bar")
            session.dragKeyBar(towardsEnd: false)
        }
        session.app.typeText("drags-done\n")
        // The tty's echo and cat's copy: two rows that are exactly the line.
        expect(session.screen, rows: "drags-done", count: 2)
        session.screenshot(self, "key-bar-drags")
    }

    /// With a hardware keyboard the bar collapses to one "Keys" button, which opens it.
    func testTheBarCollapsesWithAHardwareKeyboard() throws {
        let session = try InputSession.launch(self, hardwareKeyboard: true)
        defer { session.stop() }
        let expand = session.key("expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "no Keys button")
        XCTAssertFalse(session.key("esc").isHittable, "Esc hidden while collapsed")
        expand.tap()
        XCTAssertTrue(session.key("esc").waitForExistence(timeout: 5))
        XCTAssertTrue(session.key("esc").isHittable, "Esc shown after Keys")
    }
}

final class PasteUITests: XCTestCase {
    /// "alpha-1\nbeta-2", put on the pasteboard by the app itself through OSC 52 (the app wrote
    /// it, so reading it back shows no iOS paste prompt).
    static let base64 = "YWxwaGEtMQpiZXRhLTI="

    override func setUp() {
        continueAfterFailure = false
    }

    private func seed(_ session: InputSession) {
        session.app.typeText("printf '\\033]52;c;%s\\a' \(Self.base64)\n")
        expect(label: session.app.staticTexts["clipboardToast"], contains: "Copied 14 bytes")
    }

    /// The remote asked for bracketed paste: the paste arrives between ESC [ 200 ~ and
    /// ESC [ 201 ~, its newline kept. Paste key and Cmd-V.
    func testABracketedPaste() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        seed(session)
        // No tty echo: the echo of a pasted line and cat's copy of the line before it would
        // interleave on the screen.
        session.app.typeText("stty -echo; printf '\\033[?2004h'; cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("paste")
        session.app.typeText("\n")
        expect(session.screen, rows: "^[[200~alpha-1", count: 1)
        expect(session.screen, rows: "beta-2^[[201~", count: 1)

        // A Command key combination is ignored by the simulator until a character key has
        // come from the hardware-keyboard path: "q" first, so the line starts with it.
        session.app.typeKey("q", modifierFlags: [])
        session.app.typeKey("v", modifierFlags: .command)
        session.app.typeText("\n")
        expect(session.screen, rows: "q^[[200~alpha-1", count: 1)
        expect(session.screen, rows: "beta-2^[[201~", count: 2)
        session.screenshot(self, "paste-bracketed")
    }

    /// Without bracketed paste the text arrives plain, its newline as Return.
    func testAPlainPaste() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        seed(session)
        session.app.typeText("stty -echo; printf '\\033[?2004l'; cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("paste")
        session.app.typeText("\n")
        expect(session.screen, rows: "alpha-1", count: 1)
        expect(session.screen, rows: "beta-2", count: 1)
        let text = (session.screen.value as? String) ?? ""
        XCTAssertFalse(text.contains("200~"), "no bracketed-paste markers:\n\(text)")
        session.screenshot(self, "paste-plain")
    }
}

final class ClipboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// OSC 52 from the host sets the iOS clipboard: the toast says how much, and pasting
    /// into `cat -v` gives the text back, so the pasteboard holds what the app wrote.
    func testOSC52SetsTheClipboard() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        // "osc52-ok-99"
        session.app.typeText("printf '\\033]52;c;%s\\a' b3NjNTItb2stOTk=\n")
        expect(label: session.app.staticTexts["clipboardToast"], contains: "Copied 11 bytes")
        session.app.typeText("cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("paste")
        session.app.typeText("\n")
        expect(session.screen, rows: "osc52-ok-99", count: 2)
        session.screenshot(self, "osc52")
    }

    /// Data that is not strict base64 is not written and says so.
    func testInvalidOSC52IsReported() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        session.app.typeText("printf '\\033]52;c;%s\\a' 'not*base64'\n")
        expect(label: session.app.staticTexts["clipboardToast"], contains: "invalid or truncated")
    }
}

final class SwipePagingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// With the host's option on and mouse mode off, a swipe down sends PgUp and a swipe up
    /// PgDn (docs/PLAN.md section 5, "Selection and touch").
    func testSwipesSendPageKeys() throws {
        let session = try InputSession.launch(self, extraArguments: ["-debugSwipePaging", "1"])
        defer { session.stop() }
        session.app.typeText("cat -v\n")
        Thread.sleep(forTimeInterval: 1)
        let terminal = session.app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "terminal view")
        terminal.swipeDown()
        terminal.swipeUp()
        session.app.typeText("\n")
        expect(session.screen, rows: "^[[5~^[[6~", count: 1)
        session.screenshot(self, "swipe-paging")
    }
}

final class SelectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Long-press opens the edit menu; Select All, then Copy, puts the screen's text on the
    /// pasteboard (docs/PLAN.md section 5, "Selection and touch"). Checked by pasting it into
    /// a file on the host and counting the line.
    private func selectAllAndCopy(_ session: InputSession, file: StaticString = #filePath, line: UInt = #line) {
        let terminal = session.app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "terminal view", file: file, line: line)
        terminal.press(forDuration: 1.2)
        let selectAll = session.app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Select All in the edit menu", file: file, line: line)
        selectAll.tap()
        terminal.press(forDuration: 1.2)
        let copy = session.app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy in the edit menu", file: file, line: line)
        copy.tap()
    }

    /// Pastes the pasteboard into a file on the host and prints how many of its lines are
    /// `line`.
    private func countPasted(_ session: InputSession, line: String, tag: String) {
        session.app.typeText("f=$(mktemp); cat > \"$f\"\n")
        Thread.sleep(forTimeInterval: 1)
        session.tap("paste")
        session.app.typeText("\n")
        session.tap("ctrl")
        session.app.typeText("d")
        clearScreen(session)
        session.app.typeText("echo \(tag)-$(grep -c '^\(line) *$' \"$f\")\n")
    }

    func testSelectAllAndCopy() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        clearScreen(session)
        session.app.typeText("echo sel-$((6*7))\n")
        expect(session.screen, containsLine: "sel-42")
        selectAllAndCopy(session)
        countPasted(session, line: "sel-42", tag: "hits")
        expect(session.screen, containsLine: "hits-1")
    }

    /// The same while the remote program has mouse mode on (tmux or vim with `mouse on`).
    func testSelectAllAndCopyWithMouseModeOn() throws {
        let session = try InputSession.launch(self)
        defer { session.stop() }
        clearScreen(session)
        // cat swallows the mouse reports the presses send.
        session.app.typeText("echo mouse-$((6*7)); printf '\\033[?1000h'; cat > /dev/null\n")
        expect(session.screen, containsLine: "mouse-42")
        selectAllAndCopy(session)
        session.tap("ctrl")
        session.app.typeText("c")
        session.app.typeText("printf '\\033[?1000l'\n")
        countPasted(session, line: "mouse-42", tag: "hits")
        expect(session.screen, containsLine: "hits-1")
        session.screenshot(self, "selection-mouse-mode")
    }
}

final class BellUITests: XCTestCase {
    /// A bell on the host rings once per bell (docs/PLAN.md section 5, M7: bell as a haptic). A
    /// haptic cannot be seen on the simulator; UI-test launches count the rings in `bellRings`.
    func testTheBellRings() throws {
        continueAfterFailure = false
        let session = try InputSession.launch(self)
        defer { session.stop() }
        let rings = session.app.descendants(matching: .any)["bellRings"].firstMatch
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        XCTAssertEqual(rings.value as? String, "0")
        session.app.typeText("printf '\\a'; echo rang-$((1+1))\n")
        expect(session.screen, containsLine: "rang-2")
        waitFor((rings.value as? String) == "1", "one ring (is \(rings.value ?? "nil"))")
        Thread.sleep(forTimeInterval: 0.5)
        session.app.typeText("printf '\\a'\n")
        waitFor((rings.value as? String) == "2", "a second ring (is \(rings.value ?? "nil"))")
    }
}
