import Foundation
import MoshBootstrap
import MoshKeys
import MoshTestSupport
import XCTest

final class KnownHostsTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var store: KnownHosts!
    private var keyA: OpenSSHPublicKey!
    private var keyB: OpenSSHPublicKey!

    /// Counts how often the first-contact question is asked.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [HostKeyPrompt] = []
        func record(_ prompt: HostKeyPrompt) {
            lock.lock()
            prompts.append(prompt)
            lock.unlock()
        }
        var all: [HostKeyPrompt] {
            lock.lock()
            defer { lock.unlock() }
            return prompts
        }
    }

    override func setUpWithError() throws {
        scratch = try ScratchDirectory(label: "knownhosts")
        store = KnownHosts(fileURL: scratch.file("state/known_hosts.json"))
        keyA = try KeyGenerator.generateEd25519().openSSHPublicKey(comment: "a")
        keyB = try KeyGenerator.generateEd25519().openSSHPublicKey(comment: "b")
    }

    override func tearDown() {
        scratch.remove()
    }

    func testEmptyStore() throws {
        XCTAssertEqual(try store.entries(), [])
        XCTAssertNil(try store.lookup(host: "example.org", port: 22))
        XCTAssertEqual(try store.check(host: "example.org", port: 22, key: keyA), .unknown)
        XCTAssertFalse(try store.remove(host: "example.org", port: 22))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testTrustLookupRemove() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = try store.trust(host: "Example.ORG", port: 22, key: keyA, now: when)
        XCTAssertEqual(entry.host, "example.org")
        XCTAssertEqual(entry.keyType, "ssh-ed25519")
        XCTAssertEqual(entry.publicKey, keyA.blob.base64EncodedString())
        XCTAssertEqual(entry.fingerprint, keyA.fingerprint)
        XCTAssertEqual(entry.firstSeen, when)

        // A second store object on the same file sees it: the store is the file.
        let reopened = KnownHosts(fileURL: store.fileURL)
        XCTAssertEqual(try reopened.lookup(host: "EXAMPLE.org", port: 22), entry)
        XCTAssertEqual(try reopened.check(host: "example.org", port: 22, key: keyA), .trusted)
        XCTAssertEqual(try reopened.check(host: "example.org", port: 22, key: keyB), .changed(known: entry))
        // Host and port together are the key.
        XCTAssertEqual(try reopened.check(host: "example.org", port: 2222, key: keyA), .unknown)
        XCTAssertEqual(try reopened.check(host: "other.org", port: 22, key: keyA), .unknown)

        // Trusting the same key again changes nothing, not even the date.
        XCTAssertEqual(try store.trust(host: "example.org", port: 22, key: keyA, now: Date()), entry)
        XCTAssertEqual(try store.entries(), [entry])

        try store.trust(host: "example.org", port: 2222, key: keyB, now: when)
        XCTAssertEqual(try store.entries().map(\.port), [22, 2222])
        XCTAssertTrue(try store.remove(host: "example.ORG", port: 22))
        XCTAssertEqual(try store.entries().map(\.port), [2222])
        XCTAssertEqual(try store.check(host: "example.org", port: 22, key: keyB), .unknown)
    }

    func testAnEntryIsNeverReplaced() throws {
        try store.trust(host: "h", port: 22, key: keyA)
        XCTAssertThrowsError(try store.trust(host: "h", port: 22, key: keyB)) {
            XCTAssertEqual(
                $0 as? KnownHostsError,
                .hostKeyChanged(
                    host: "h", port: 22, knownFingerprint: keyA.fingerprint, presentedFingerprint: keyB.fingerprint))
        }
        XCTAssertEqual(try store.check(host: "h", port: 22, key: keyA), .trusted)
    }

    func testFileFormat() throws {
        try store.trust(host: "h", port: 22, key: keyA, now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try Data(contentsOf: store.fileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let hosts = try XCTUnwrap(json["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0]["host"] as? String, "h")
        XCTAssertEqual(hosts[0]["port"] as? Int, 22)
        XCTAssertEqual(hosts[0]["keyType"] as? String, "ssh-ed25519")
        XCTAssertEqual(hosts[0]["publicKey"] as? String, keyA.blob.base64EncodedString())
        XCTAssertEqual(hosts[0]["fingerprint"] as? String, keyA.fingerprint)
        XCTAssertEqual(hosts[0]["firstSeen"] as? String, "2027-01-15T08:00:00Z")
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAnUnreadableFileIsAnErrorNotAnEmptyStore() throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for content in ["", "{", "[]", "{\"version\": 2, \"hosts\": []}", "{\"version\": 1}"] {
            try Data(content.utf8).write(to: store.fileURL)
            XCTAssertThrowsError(try store.check(host: "h", port: 22, key: keyA), content) { error in
                guard case .unreadable = error as? KnownHostsError else {
                    return XCTFail("\(content): \(error)")
                }
            }
            XCTAssertThrowsError(try store.trust(host: "h", port: 22, key: keyA), content)
            // The broken file is left alone.
            XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), content)
        }
    }

    // MARK: - verify (trust on first use)

    func testFirstContactAsksOnceAndRemembers() async throws {
        let asked = Asked()
        try await store.verify(host: "Host.Example", port: 2222, key: keyA) { prompt in
            asked.record(prompt)
            return true
        }
        XCTAssertEqual(
            asked.all,
            [HostKeyPrompt(host: "host.example", port: 2222, keyType: "ssh-ed25519", fingerprint: keyA.fingerprint)])
        XCTAssertEqual(try store.check(host: "host.example", port: 2222, key: keyA), .trusted)

        // The second contact is silent.
        try await store.verify(host: "host.example", port: 2222, key: keyA) { prompt in
            asked.record(prompt)
            return false
        }
        XCTAssertEqual(asked.all.count, 1)
    }

    func testDecliningFirstContactRemembersNothing() async throws {
        do {
            try await store.verify(host: "h", port: 22, key: keyA) { _ in false }
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? KnownHostsError, .notTrusted(host: "h", port: 22, fingerprint: keyA.fingerprint))
        }
        XCTAssertEqual(try store.entries(), [])
    }

    func testChangedKeyIsRefusedWithoutAsking() async throws {
        try store.trust(host: "h", port: 22, key: keyA)
        let asked = Asked()
        do {
            try await store.verify(host: "h", port: 22, key: keyB) { prompt in
                asked.record(prompt)
                return true
            }
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(
                error as? KnownHostsError,
                .hostKeyChanged(
                    host: "h", port: 22, knownFingerprint: keyA.fingerprint, presentedFingerprint: keyB.fingerprint))
        }
        XCTAssertEqual(asked.all, [], "a changed key is refused, never offered for trust")
        XCTAssertEqual(try store.check(host: "h", port: 22, key: keyA), .trusted)
    }

    func testAKeyOfAnotherTypeIsAlsoAChange() async throws {
        // One host and port has one key. A host that suddenly shows an RSA or ECDSA key is not
        // treated as a first contact.
        try store.trust(host: "h", port: 22, key: keyA)
        let ecdsa = try OpenSSHPublicKey(
            line:
                "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFklecny4/KxoeX05kldlSxic264mKdweRBycZbrlnJUCTnT6LOrL10Clr2836NJplXdy8NDhG5PZhK4hi8aP74="
        )
        do {
            try await store.verify(host: "h", port: 22, key: ecdsa) { _ in true }
            XCTFail("must throw")
        } catch {
            guard case .hostKeyChanged = error as? KnownHostsError else { return XCTFail("\(error)") }
        }
    }
}
