import MoshCrypto
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import IOSMosh

/// The guard on the debug launch arguments (docs/notes/multi-session/DESIGN.md section 7,
/// `DebugLaunch.swift`; A21, LC-16): a request makes a record only when no stored record names
/// its server, and each of the two requests is handed out once per process. On a temporary root.
///
/// The async test and `makeRecord` are `@MainActor` (step 13c): off the main actor XCTest
/// sometimes did not record a failure that came after an `await` (step 11, docs/MAC.md).
final class DebugLaunchTests: XCTestCase {
    private var base: URL!
    private var root: String!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("debug-launch-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func request(port: UInt16, host: String = "127.0.0.1") throws -> DebugLaunch.Request {
        DebugLaunch.Request(
            endpoint: SessionEndpoint(host: host, port: port, key: try Base64Key(bytes: [UInt8](repeating: 7, count: 16))),
            serverStartSize: TerminalRemoteState.defaultServerSize)
    }

    /// A record as a debug session makes it (`openSession`: `meta.address` is the endpoint's
    /// host, `meta.port` its port).
    @MainActor
    private func makeRecord(address: String, port: UInt16) async throws {
        let key = try Base64Key(bytes: [UInt8](repeating: 9, count: 16))
        let meta = SessionMeta(createdAt: 1, hostName: address, address: address, port: port, user: "",
                               serverStartSize: TerminalSize(width: 80, height: 24), serverPID: 0, serverStartTime: 0)
        let coordinator = try ResumeCoordinator.create(
            root: root, meta: meta, key: key, storesKey: false, initialSize: TerminalSize(width: 80, height: 24),
            options: SessionLauncher.options(address: meta.address, port: meta.port))
        await coordinator.close()
    }

    @MainActor
    func testADebugRequestIsRefusedWhenARecordNamesItsServer() async throws {
        let named = try request(port: 62750)
        let otherPort = try request(port: 62751)
        let otherAddress = try request(port: 62750, host: "127.0.0.2")

        // No record: handed out.
        XCTAssertEqual(DebugLaunch.storedServers(root: root), [])
        XCTAssertNotNil(DebugLaunch.Handout(name: "test", once: false).take(named, root: root), "no record names it")

        try await makeRecord(address: "127.0.0.1", port: 62750)
        XCTAssertEqual(DebugLaunch.storedServers(root: root), [DebugLaunch.Server(address: "127.0.0.1", port: 62750)])

        // The rule itself.
        let stored = DebugLaunch.storedServers(root: root)
        XCTAssertFalse(DebugLaunch.mayHandOut(named, handedOutBefore: false, storedServers: stored),
                       "a stored record names its address and port")
        XCTAssertTrue(DebugLaunch.mayHandOut(otherPort, handedOutBefore: false, storedServers: stored), "another port")
        XCTAssertTrue(DebugLaunch.mayHandOut(otherAddress, handedOutBefore: false, storedServers: stored), "another address")

        // Through a hand-out of each kind, never handed out before.
        for once in [false, true] {
            XCTAssertNil(DebugLaunch.Handout(name: "test", once: once).take(named, root: root),
                         "refused while a record names its server (once: \(once))")
            XCTAssertNotNil(DebugLaunch.Handout(name: "test", once: once).take(otherPort, root: root),
                            "another server is handed out (once: \(once))")
        }
        XCTAssertNil(DebugLaunch.Handout(name: "test", once: false).take(nil, root: root), "no request, nothing")
    }

    func testTheFallbackRequestIsHandedOutOnce() throws {
        let fallback = try request(port: 62760)
        XCTAssertTrue(DebugLaunch.mayHandOut(fallback, handedOutBefore: false, storedServers: []))
        XCTAssertFalse(DebugLaunch.mayHandOut(fallback, handedOutBefore: true, storedServers: []),
                       "handed out before")

        let once = DebugLaunch.Handout(name: "test fallback", once: true)
        XCTAssertNotNil(once.take(fallback, root: root), "the first fallback gets the server")
        XCTAssertNil(once.take(fallback, root: root), "a second fallback in the same process gets none")
        XCTAssertNil(once.take(try request(port: 62761), root: root), "nor any other")
    }

    /// Step 10 (review-steps-2-4.md R24-S4, step 9's review): the `-debugMosh*` request is handed
    /// out once per process too, like the fallback request, in `DebugLaunch` itself and so for
    /// every reader. The stored-record check alone misses a record forgotten while its server
    /// runs and one whose `meta` cannot be read; before this step only `SceneDelegate` kept the
    /// session request to the first root of the process. A hand-out of that kind refuses its
    /// second take (`testTheFallbackRequestIsHandedOutOnce`).
    func testBothDebugRequestsAreHandedOutOncePerProcess() {
        XCTAssertTrue(DebugLaunch.sessionHandout.once, "the -debugMosh* request is handed out once per process")
        XCTAssertTrue(DebugLaunch.fallbackHandout.once, "the -debugFallback* request is handed out once per process")
    }
}
