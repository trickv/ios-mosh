import MoshBootstrap
import MoshCrypto
import XCTest
@testable import MoshSession

enum BootstrapResultFixture {
    static func make(address: String, port: Int, key: String) -> BootstrapResult {
        BootstrapResult(remoteAddress: address, udpPort: port, sessionKey: key, serverPID: 42, serverStartTime: nil,
                        loginMethod: .publicKey, serverOutput: "")
    }
}

final class SessionEndpointTests: XCTestCase {
    /// The bootstrap result's fields become the endpoint.
    func testEndpointFromABootstrapResult() throws {
        let key = "AAAAAAAAAAAAAAAAAAAAAA"
        let result = BootstrapResultFixture.make(address: "::1", port: 60001, key: key)
        let endpoint = try SessionEndpoint(bootstrap: result)
        XCTAssertEqual(endpoint.host, "::1")
        XCTAssertEqual(endpoint.port, 60001)
        XCTAssertEqual(endpoint.key, try Base64Key(printable: key))
        XCTAssertEqual(endpoint.family, .ipv6)
        XCTAssertThrowsError(try SessionEndpoint(bootstrap: BootstrapResultFixture.make(address: "127.0.0.1", port: 0, key: key)))
        XCTAssertThrowsError(try SessionEndpoint(bootstrap: BootstrapResultFixture.make(address: "127.0.0.1", port: 70000, key: key)))
        XCTAssertThrowsError(try SessionEndpoint(bootstrap: BootstrapResultFixture.make(address: "127.0.0.1", port: 60001, key: "short")))
    }

    func testIPv4Family() throws {
        let endpoint = SessionEndpoint(host: "192.0.2.1", port: 1, key: try Base64Key(printable: "AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertEqual(endpoint.family, .ipv4)
    }
}
