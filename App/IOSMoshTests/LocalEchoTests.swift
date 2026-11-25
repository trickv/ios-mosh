@testable import IOSMosh
import MoshResume
import MoshSession
import MoshTerminal
import XCTest

/// Local echo in the app (M10, docs/notes/m10/DESIGN.md section 5): the per-host setting and
/// the frame the terminal screen draws.
final class LocalEchoTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: The setting

    func testTheDefaultIsMoshsAdaptiveWithInsert() {
        XCTAssertEqual(LocalEcho.standard, LocalEcho(mode: .adaptive, overwrite: false))
        XCTAssertEqual(SavedHost().localEcho, .standard, "a new host")
        XCTAssertEqual(LocalEcho.standard.settings, PredictionSettings(), "the core's mosh default (toh:305-306)")
        XCTAssertEqual(LocalEcho.forSession(host: nil), .standard, "a session without a host, no launch argument")
    }

    func testTheOfferedModesAndTheOverwriteSwitchAreOneConstantEach() {
        // Trick, 2026-11-19: Adaptive, Always, Never for now; Experimental and overwrite open.
        XCTAssertEqual(LocalEcho.offeredModes, [.adaptive, .always, .never])
        XCTAssertFalse(LocalEcho.offersOverwrite)
        XCTAssertEqual(LocalEcho.offeredModes.first, LocalEcho.standard.mode, "the default is listed first")
        // mosh's own words (mosh.pl:98-103).
        XCTAssertEqual(LocalEcho.Mode.adaptive.detail, "Local echo for slower links (mosh's default).")
        XCTAssertEqual(LocalEcho.Mode.always.detail, "Use local echo even on fast links.")
        XCTAssertEqual(LocalEcho.Mode.never.detail, "Never use local echo.")
        XCTAssertEqual(LocalEcho.Mode.experimental.detail, "Aggressively echo even when incorrect.")
        XCTAssertEqual(LocalEcho.overwriteTitle, "Prediction overwrites instead of inserting")
        XCTAssertEqual(Set(LocalEcho.Mode.allCases.map(\.title)).count, LocalEcho.Mode.allCases.count)
    }

    func testEachModeMapsToTheCoresSettings() {
        for mode in LocalEcho.Mode.allCases {
            XCTAssertEqual(mode.display.rawValue, mode.rawValue, "mosh's names on both sides")
            for overwrite in [false, true] {
                XCTAssertEqual(LocalEcho(mode: mode, overwrite: overwrite).settings,
                               PredictionSettings(display: mode.display, overwrite: overwrite))
            }
        }
        XCTAssertEqual(LocalEcho(mode: .never).settings, .off)
        XCTAssertEqual(SessionLauncher.options(address: "127.0.0.1", port: 60001,
                                               localEcho: LocalEcho(mode: .always)).prediction,
                       PredictionSettings(display: .always),
                       "every create and cold start passes the setting in Options.prediction")
        XCTAssertEqual(SessionLauncher.options(address: "127.0.0.1", port: 60001).prediction, PredictionSettings(),
                       "without one: mosh's default, not the package's off")
    }

    func testTheSettingIsStoredPerHostAndHoldsOnlyTheChoice() throws {
        let store = HostStore(fileURL: directory.appendingPathComponent("hosts.json"))
        let a = SavedHost(name: "a", host: "a.example", user: "u", localEcho: LocalEcho(mode: .never))
        let b = SavedHost(name: "b", host: "b.example", user: "u", localEcho: LocalEcho(mode: .always, overwrite: true))
        let c = SavedHost(name: "c", host: "c.example", user: "u")
        try store.save([a, b, c])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.localEcho), [a.localEcho, b.localEcho, .standard])

        // What is written for it is the choice and nothing else: no frame, no guess.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        let hosts = try XCTUnwrap(json?["hosts"] as? [[String: Any]])
        for host in hosts {
            let echo = try XCTUnwrap(host["localEcho"] as? [String: Any])
            XCTAssertEqual(Set(echo.keys), ["mode", "overwrite"])
        }
        XCTAssertEqual((hosts[0]["localEcho"] as? [String: Any])?["mode"] as? String, "never")
    }

    func testHostsSavedBeforeLocalEchoGetAdaptive() throws {
        let url = directory.appendingPathComponent("hosts.json")
        let id = UUID()
        // The file as the app wrote it before M10.
        let old = """
        {"hosts":[{"allowClipboardWrite":true,"host":"box.example","id":"\(id.uuidString)","keyName":"device",\
        "locale":"en_US.UTF-8","name":"box","port":22,"remoteCommand":"","serverPath":"","swipeSendsPaging":false,\
        "udpPortRange":"","user":"alice"}],"version":1}
        """
        try Data(old.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        let hosts = try store.load()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].id, id)
        XCTAssertEqual(hosts[0].user, "alice")
        XCTAssertEqual(hosts[0].localEcho, .standard)
        // Saved again, it carries the setting from then on.
        try store.save(hosts)
        XCTAssertEqual(try store.load()[0].localEcho, .standard)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"localEcho\""))

        // A mode this build does not know reads as the default; the host list stays readable.
        let unknown = old.replacingOccurrences(of: "\"user\":\"alice\"",
                                               with: "\"user\":\"alice\",\"localEcho\":{\"mode\":\"psychic\",\"overwrite\":true}")
        try Data(unknown.utf8).write(to: url)
        XCTAssertEqual(try store.load()[0].localEcho, LocalEcho(mode: .adaptive, overwrite: true))

        // Any other missing field is still an error, as before.
        try Data(old.replacingOccurrences(of: "\"user\":\"alice\"", with: "\"x\":1").utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }

    func testSavingAHostAnnouncesIt() throws {
        let store = HostStore(fileURL: directory.appendingPathComponent("hosts.json"))
        let host = SavedHost(name: "a", host: "a.example", user: "u", localEcho: LocalEcho(mode: .never))
        let announced = expectation(forNotification: LocalEcho.hostSaved, object: nil) { notification in
            (notification.object as? SavedHost) == host
        }
        try store.upsert(host)
        wait(for: [announced], timeout: 1)
    }

    // MARK: The frame to draw (design section 5 item 2)

    private func frame(_ width: Int) -> Framebuffer { Framebuffer(width: width, height: 2) }

    private func display(_ serial: UInt64, _ width: Int, guesses: Bool = true) -> DisplayFrame {
        DisplayFrame(serial: serial, number: serial, framebuffer: frame(width), hasPredictions: guesses)
    }

    func testInNeverModeTheScreenIsDrawnAndADisplayIgnored() {
        var frames = FrameToDraw(display: .never)
        XCTAssertNil(frames.framebuffer)
        frames.take(screen: frame(10))
        XCTAssertEqual(frames.framebuffer, frame(10))
        let serial = frames.serial
        frames.take(display: display(1, 11))
        XCTAssertEqual(frames.framebuffer, frame(10))
        XCTAssertEqual(frames.serial, serial, "nothing new to draw")
        XCTAssertFalse(frames.hasPredictions)
        frames.take(screen: frame(12))
        XCTAssertEqual(frames.framebuffer, frame(12))
        XCTAssertEqual(frames.remote, frame(12))
    }

    func testWithLocalEchoOnlyADisplayReplacesTheFrameOnceOneCame() {
        for mode in [PredictionDisplay.adaptive, .always, .experimental] {
            var frames = FrameToDraw(display: mode)
            // Before the session's first .display nothing with a guess was drawn: the screen is.
            frames.take(screen: frame(10))
            XCTAssertEqual(frames.framebuffer, frame(10), "\(mode)")
            frames.take(display: display(1, 11, guesses: true))
            XCTAssertEqual(frames.framebuffer, frame(11), "\(mode)")
            XCTAssertTrue(frames.hasPredictions)
            // A .screen before its .display: the guesses stay on the screen.
            let serial = frames.serial
            frames.take(screen: frame(12))
            XCTAssertEqual(frames.framebuffer, frame(11), "\(mode): a frame without its guesses must never be drawn")
            XCTAssertEqual(frames.serial, serial, "\(mode): nothing new to draw")
            XCTAssertEqual(frames.remote, frame(12), "the server's screen is kept")
            frames.take(display: display(2, 12, guesses: false))
            XCTAssertEqual(frames.framebuffer, frame(12))
            XCTAssertFalse(frames.hasPredictions)
            XCTAssertNotEqual(frames.serial, serial, "\(mode): the tick draws it")
        }
    }

    func testASwitchToNeverDrawsTheServersScreenAtOnce() {
        var frames = FrameToDraw(display: .adaptive)
        frames.take(display: display(1, 11, guesses: true))
        frames.take(screen: frame(12))
        XCTAssertEqual(frames.framebuffer, frame(11))
        frames.setDisplay(.never)
        XCTAssertEqual(frames.framebuffer, frame(12), "no guess left on the screen")
        XCTAssertFalse(frames.hasPredictions)
        // The session's last .display after its switch (and any late one) is not drawn.
        frames.take(display: display(2, 13, guesses: true))
        XCTAssertEqual(frames.framebuffer, frame(12))
    }

    func testASwitchFromNeverDrawsTheScreenUntilTheFirstDisplay() {
        var frames = FrameToDraw(display: .never)
        frames.take(screen: frame(10))
        frames.setDisplay(.always)
        frames.take(screen: frame(11))
        XCTAssertEqual(frames.framebuffer, frame(11))
        frames.take(display: display(1, 11, guesses: true))
        frames.take(screen: frame(12))
        XCTAssertEqual(frames.framebuffer, frame(11))
        // Between two modes that both echo, the rule stays.
        frames.setDisplay(.adaptive)
        frames.take(screen: frame(13))
        XCTAssertEqual(frames.framebuffer, frame(11))
    }

    func testANewSessionDrawsItsScreenUntilItsFirstDisplay() {
        var frames = FrameToDraw(display: .adaptive)
        frames.take(display: display(1, 11))
        frames.newSession()
        frames.take(screen: frame(20))
        XCTAssertEqual(frames.framebuffer, frame(20))
        frames.take(display: display(1, 21))
        frames.take(screen: frame(22))
        XCTAssertEqual(frames.framebuffer, frame(21))
    }
}
