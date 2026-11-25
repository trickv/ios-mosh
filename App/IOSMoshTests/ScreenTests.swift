import MoshBootstrap
import MoshCrypto
import MoshKeys
import MoshSession
import Security
import UIKit
import XCTest
@testable import IOSMosh

/// App-hosted tests of the M5 screens' logic: host persistence, the keys screen's Copy,
/// and that a terminal screen is freed after it is left.
final class HostStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHostsSurviveANewStoreAndCanBeEditedAndDeleted() throws {
        let url = directory.appendingPathComponent("hosts.json")
        let store = HostStore(fileURL: url)
        XCTAssertEqual(try store.load(), [])
        var a = SavedHost(name: "a", host: "a.example", user: "me")
        let b = SavedHost(name: "b", host: "10.0.0.2", port: 2222, user: "you", udpPortRange: "60001:60010",
                          remoteCommand: "tmux new -A -s main")
        try store.upsert(a)
        try store.upsert(b)
        XCTAssertEqual(try HostStore(fileURL: url).load(), [a, b])
        a.name = "renamed"
        try store.upsert(a)
        XCTAssertEqual(try HostStore(fileURL: url).load(), [a, b])
        try store.delete(id: a.id)
        XCTAssertEqual(try HostStore(fileURL: url).load(), [b])
    }

    func testAnUnreadableFileIsAnErrorNotAnEmptyList() throws {
        let url = directory.appendingPathComponent("hosts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try HostStore(fileURL: url).load())
        XCTAssertThrowsError(try HostStore(fileURL: url).upsert(SavedHost(host: "h", user: "u")))
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8), "a bad file is never overwritten")
    }

    func testValidation() {
        XCTAssertNil(SavedHost(host: "h", user: "u").validationError())
        XCTAssertNotNil(SavedHost(host: "", user: "u").validationError())
        XCTAssertNotNil(SavedHost(host: "h", user: "").validationError())
        XCTAssertNotNil(SavedHost(host: "h h", user: "u").validationError())
        XCTAssertNotNil(SavedHost(host: "h", port: 0, user: "u").validationError())
        XCTAssertNotNil(SavedHost(host: "h", port: 70000, user: "u").validationError())
        XCTAssertNotNil(SavedHost(host: "h", user: "u", locale: "en US").validationError())
        XCTAssertNotNil(SavedHost(host: "h", user: "u", udpPortRange: "abc").validationError())
        XCTAssertNil(SavedHost(host: "h", user: "u", udpPortRange: "60001").validationError())
        XCTAssertNotNil(SavedHost(host: "h", user: "u", remoteCommand: "a\nb").validationError())
        XCTAssertEqual(try SavedHost(host: "h", user: "u", udpPortRange: "61000:61010").serverCommand().portRange,
                       UDPPortRange(low: 61000, high: 61010))
    }
}

final class KeysScreenTests: XCTestCase {
    private var service = ""

    override func setUp() {
        service = "us.v9n.ios-mosh.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    /// docs/PLAN.md M5: the Keys screen's Copy action puts a line starting
    /// `ssh-ed25519 AAAA` on the pasteboard.
    func testCopyPutsThePublicKeyLineOnThePasteboard() throws {
        let screen = KeysViewController(store: KeychainKeyStore(service: service))
        screen.loadViewIfNeeded()
        let key = try XCTUnwrap(screen.key)
        UIPasteboard.general.string = ""
        let copied = try XCTUnwrap(screen.copyPublicKey())
        XCTAssertEqual(copied, key.authorizedKeysLine)
        let pasted = try XCTUnwrap(UIPasteboard.general.string)
        XCTAssertTrue(pasted.hasPrefix("ssh-ed25519 AAAA"), pasted)
        XCTAssertEqual(pasted, key.authorizedKeysLine)
        XCTAssertTrue(pasted.hasSuffix(" " + DeviceKey.comment))
    }
}

final class TerminalScreenTests: XCTestCase {
    /// The display link used to keep the controller (and its session) alive for ever.
    func testATerminalScreenIsFreedAfterItIsLeft() throws {
        weak var weakController: TerminalViewController?
        let before = TerminalViewController.liveCount
        autoreleasepool {
            // A session to a port where nothing listens; it never gets a reply.
            let request = DebugLaunch.Request(
                endpoint: SessionEndpoint(host: "127.0.0.1", port: 9, key: try! Base64Key(printable: "AAAAAAAAAAAAAAAAAAAAAA")),
                serverStartSize: TerminalRemoteState.defaultServerSize)
            let controller = TerminalViewController(start: .debug(request))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.loadViewIfNeeded()
            controller.view.layoutIfNeeded()
            // Let the display link tick a few times.
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(TerminalViewController.liveCount, before + 1)
            controller.endSession()
            window.rootViewController = nil
            window.isHidden = true
            weakController = controller
        }
        let deadline = Date().addingTimeInterval(5)
        while weakController != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakController, "the controller is still alive after it was left")
        XCTAssertEqual(TerminalViewController.liveCount, before)
    }
}
