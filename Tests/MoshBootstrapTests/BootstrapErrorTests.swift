import MoshBootstrap
import XCTest

final class ConnectTimeoutPolicyTests: XCTestCase {
    func testAddressClasses() {
        let cases: [(String, AddressClass)] = [
            ("127.0.0.1", .loopback), ("127.255.255.254", .loopback), ("::1", .loopback), ("[::1]", .loopback),
            ("localhost", .loopback), ("LocalHost.", .loopback),
            ("10.0.0.1", .privateNetwork), ("10.255.255.255", .privateNetwork),
            ("172.16.0.1", .privateNetwork), ("172.31.255.255", .privateNetwork),
            ("192.168.1.20", .privateNetwork), ("fd12:3456:789a::1", .privateNetwork), ("fc00::1", .privateNetwork),
            ("::ffff:192.168.1.5", .privateNetwork),
            ("169.254.10.20", .linkLocal), ("fe80::1", .linkLocal), ("fe80::1%en0", .linkLocal),
            ("[FE80::abcd%en0]", .linkLocal), ("febf::1", .linkLocal),
            ("8.8.8.8", .publicAddress), ("172.15.0.1", .publicAddress), ("172.32.0.1", .publicAddress),
            ("192.169.0.1", .publicAddress), ("11.0.0.1", .publicAddress), ("169.253.0.1", .publicAddress),
            // Tailscale's range is a VPN, not a local network.
            ("100.64.0.1", .publicAddress),
            ("2001:db8::1", .publicAddress), ("fec0::1", .publicAddress), ("::ffff:8.8.8.8", .publicAddress),
            ("nas.local", .localName), ("NAS.Local.", .localName), ("charlie", .localName),
            ("example.org", .name), ("host.tailnet.ts.net", .name), ("10.0.0", .name), ("1.2.3.4.5", .name),
            ("256.1.1.1", .name), ("10.0.0.01x", .name),
        ]
        for (host, expected) in cases {
            XCTAssertEqual(ConnectTimeoutPolicy.addressClass(ofHost: host), expected, host)
        }
    }

    func testTimeouts() {
        for host in ["192.168.1.20", "10.1.2.3", "172.20.0.9", "169.254.1.1", "fe80::1%en0", "fd00::5", "nas.local", "charlie"] {
            XCTAssertEqual(ConnectTimeoutPolicy.timeoutSeconds(forHost: host), 30, host)
        }
        for host in ["8.8.8.8", "100.64.0.1", "example.org", "127.0.0.1", "localhost", "2001:db8::1", "::1"] {
            XCTAssertEqual(ConnectTimeoutPolicy.timeoutSeconds(forHost: host), 10, host)
        }
    }
}

final class BootstrapErrorTests: XCTestCase {
    private func classify(_ evidence: BootstrapEvidence) -> BootstrapError {
        BootstrapError.classify(evidence)
    }

    // MARK: - The rows of the plan's error table

    func testRow1ServerNotFound() {
        // "No MOSH CONNECT, exit 127 or 'not found'".
        let bash = "bash: line 1: mosh-server: command not found\n"
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: 127, output: bash)),
            .serverNotFound(output: bash))
        // Exit status 127 alone is enough.
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: 127, output: "")),
            .serverNotFound(output: ""))
        // csh exits with 1 but says so; an exit status may also be missing.
        let csh = "mosh-server: Command not found.\n"
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: 1, output: csh)), .serverNotFound(output: csh))
        let path = "bash: line 1: /nowhere/mosh-server: No such file or directory\n"
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: nil, output: path)),
            .serverNotFound(output: path))

        let error = BootstrapError.serverNotFound(output: bash)
        XCTAssertTrue(error.message.contains("PATH of a non-login shell"))
        XCTAssertEqual(error.suggestedFix?.contains("/opt/homebrew/bin/mosh-server"), true)
        XCTAssertEqual(error.output, bash)
    }

    func testRow2LocaleMissing() {
        let output =
            "mosh-server needs a UTF-8 native locale to run.\n\nUnfortunately, the local environment ...\n"
            + "locale: Cannot set LC_CTYPE to default locale: No such file or directory\n"
        let error = classify(
            BootstrapEvidence(stage: .serverStart, locale: "xx_XX.UTF-8", exitStatus: 1, output: output))
        XCTAssertEqual(error, .localeMissing(locale: "xx_XX.UTF-8", output: output))
        XCTAssertTrue(error.message.contains("xx_XX.UTF-8"))
        XCTAssertEqual(error.suggestedFix?.contains("C.UTF-8"), true)
        // Even with exit status 127 the locale text decides.
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, locale: "x", exitStatus: 127, output: output)),
            .localeMissing(locale: "x", output: output))
    }

    func testRow3UDPBlockedHasItsText() {
        // Raised by the session layer; only the case and its text live here.
        let error = BootstrapError.udpBlocked(port: 60001)
        XCTAssertTrue(error.message.contains("UDP is blocked"))
        XCTAssertTrue(error.message.contains("60001"))
        XCTAssertEqual(error.suggestedFix?.contains("port range"), true)
        XCTAssertEqual(error.suggestedFix?.contains("firewall"), true)
    }

    func testRow4KeyRejected() {
        var trace = AuthenticationTrace(methodsOffered: [.publicKey, .password], keyAvailable: true, keyRejected: true)
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .authentication, authentication: trace)),
            .keyRejected(passwordLoginOffered: true))
        // Also when the user then cancelled the password prompt.
        trace.promptCancelled = true
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .authentication, authentication: trace)),
            .keyRejected(passwordLoginOffered: true))
        trace = AuthenticationTrace(methodsOffered: [.publicKey], keyAvailable: true, keyRejected: true)
        let error = classify(BootstrapEvidence(stage: .authentication, authentication: trace))
        XCTAssertEqual(error, .keyRejected(passwordLoginOffered: false))
        XCTAssertEqual(error.suggestedFix?.contains("authorized_keys"), true)
        XCTAssertEqual(error.suggestedFix?.contains("does not take passwords"), true)
        XCTAssertEqual(
            BootstrapError.keyRejected(passwordLoginOffered: true).suggestedFix?.contains("log in with the password"),
            true)
    }

    func testRow5PasswordRejected() {
        var trace = AuthenticationTrace(methodsOffered: [.publicKey, .password], passwordsRejected: 1)
        XCTAssertEqual(classify(BootstrapEvidence(stage: .authentication, authentication: trace)), .passwordRejected)
        // A rejected key before the wrong password does not change the answer.
        trace.keyAvailable = true
        trace.keyRejected = true
        trace.passwordsRejected = 3
        trace.promptCancelled = true
        let error = classify(BootstrapEvidence(stage: .authentication, authentication: trace))
        XCTAssertEqual(error, .passwordRejected)
        XCTAssertEqual(error.message, "Wrong password.")
    }

    func testRow6HostKeyChanged() {
        let failure = KnownHostsError.hostKeyChanged(
            host: "h", port: 22, knownFingerprint: "SHA256:old", presentedFingerprint: "SHA256:new")
        let error = classify(BootstrapEvidence(stage: .hostKeyCheck, hostKeyFailure: failure))
        XCTAssertEqual(error, .hostKeyChanged(knownFingerprint: "SHA256:old", presentedFingerprint: "SHA256:new"))
        XCTAssertTrue(error.message.contains("SHA256:old"))
        XCTAssertTrue(error.message.contains("SHA256:new"))
        XCTAssertTrue(error.message.contains("refused"))
    }

    func testRow7NoSharedHostKeyAlgorithm() {
        // What OpenSSH 9.6 announces with only an RSA host key.
        let rsaOnly = ServerAlgorithms(
            identification: "SSH-2.0-OpenSSH_9.6p1",
            keyExchange: ["sntrup761x25519-sha512@openssh.com", "curve25519-sha256", "ecdh-sha2-nistp256"],
            hostKey: ["rsa-sha2-512", "rsa-sha2-256"],
            encryptionClientToServer: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"],
            encryptionServerToClient: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"])
        XCTAssertEqual(rsaOnly.mismatch, .hostKey)
        let error = classify(
            BootstrapEvidence(
                stage: .keyExchange, sshFailure: .algorithmNegotiation, serverAlgorithms: rsaOnly))
        XCTAssertEqual(error, .noSharedHostKeyAlgorithm(serverOffers: ["rsa-sha2-512", "rsa-sha2-256"]))
        XCTAssertEqual(error.message, "The host offers only RSA host keys. They are not supported.")
        XCTAssertEqual(error.suggestedFix?.contains("Ed25519"), true)

        // Other mismatches are not blamed on the host key.
        var oldKex = rsaOnly
        oldKex.hostKey = ["ssh-ed25519"]
        oldKex.keyExchange = ["diffie-hellman-group14-sha1"]
        XCTAssertEqual(oldKex.mismatch, .keyExchange)
        XCTAssertEqual(
            classify(
                BootstrapEvidence(
                    stage: .keyExchange, sshFailure: .algorithmNegotiation, serverAlgorithms: oldKex)),
            .noSharedAlgorithm(kind: "key exchange", serverOffers: ["diffie-hellman-group14-sha1"]))
        var oldCipher = rsaOnly
        oldCipher.hostKey = ["ecdsa-sha2-nistp256"]
        oldCipher.encryptionServerToClient = ["aes128-ctr"]
        XCTAssertEqual(oldCipher.mismatch, .encryption)
        var fine = rsaOnly
        fine.hostKey = ["rsa-sha2-512", "ssh-ed25519"]
        XCTAssertNil(fine.mismatch)
        // Without the server's lists the failure is reported, but not as an RSA problem.
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .keyExchange, sshFailure: .algorithmNegotiation)),
            .noSharedAlgorithm(kind: "SSH", serverOffers: []))
    }

    func testRow8UnsupportedLoginMethod() {
        // keyboard-interactive only: swift-nio-ssh drops the unknown method, the set is empty.
        var trace = AuthenticationTrace(methodsOffered: [], keyAvailable: true)
        let error = classify(BootstrapEvidence(stage: .authentication, authentication: trace))
        XCTAssertEqual(error, .unsupportedLoginMethod)
        XCTAssertTrue(error.message.contains("does not support"))
        // hostbased only is just as unusable.
        trace.methodsOffered = [.hostBased]
        XCTAssertEqual(classify(BootstrapEvidence(stage: .authentication, authentication: trace)), .unsupportedLoginMethod)
    }

    func testRow9LocalNetworkDenied() {
        // "WaitingForConnectivity event, then connect timeout, on a private or link-local
        // address." Cannot happen on Linux; the classifier is what is tested.
        let events: [ConnectivityEvent] = [
            .waitingForConnectivity(reason: "POSIXErrorCode(rawValue: 50): Network is down"),
            .connectTimeout(seconds: 30),
        ]
        for host in ["192.168.1.20", "10.0.0.7", "172.16.5.5", "169.254.3.4", "fe80::1%en0", "nas.local"] {
            let error = classify(BootstrapEvidence(stage: .connect, host: host, connectivity: events))
            XCTAssertEqual(error, .localNetworkDenied, host)
            XCTAssertEqual(error.suggestedFix?.contains("Local Network"), true)
        }
        // The same events towards a public address are an ordinary timeout.
        for host in ["8.8.8.8", "example.org", "100.64.0.1"] {
            XCTAssertEqual(
                classify(
                    BootstrapEvidence(
                        stage: .connect, host: host,
                        connectivity: [.waitingForConnectivity(reason: "x"), .connectTimeout(seconds: 10)])),
                .connectTimedOut(seconds: 10), host)
        }
        // A timeout without the waiting event is an ordinary timeout too.
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .connect, host: "192.168.1.20", connectivity: [.connectTimeout(seconds: 30)])),
            .connectTimedOut(seconds: 30))
    }

    // MARK: - The rest

    func testConnectFailures() {
        XCTAssertEqual(
            classify(
                BootstrapEvidence(stage: .connect, host: "h", connectivity: [.connectFailed(reason: "connection refused")])),
            .connectFailed(reason: "connection refused"))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .connect, host: "192.168.0.9", timedOut: true)),
            .connectTimedOut(seconds: 30))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .connect, host: "example.org", timedOut: true)),
            .connectTimedOut(seconds: 10))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .connect, host: "h", errorDescription: "no route")),
            .connectFailed(reason: "no route"))
    }

    func testHostKeyDeclinedAndStoreTrouble() {
        XCTAssertEqual(
            classify(
                BootstrapEvidence(
                    stage: .hostKeyCheck, hostKeyFailure: .notTrusted(host: "h", port: 22, fingerprint: "SHA256:x"))),
            .hostKeyNotTrusted(fingerprint: "SHA256:x"))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .hostKeyCheck, hostKeyFailure: .unreadable("bad json"))),
            .knownHostsUnavailable("bad json"))
    }

    func testAuthenticationOtherOutcomes() {
        // Password only host, no key: the prompt was cancelled.
        XCTAssertEqual(
            classify(
                BootstrapEvidence(
                    stage: .authentication,
                    authentication: AuthenticationTrace(methodsOffered: [.password], promptCancelled: true))),
            .cancelled)
        // Key only host, no key.
        XCTAssertEqual(
            classify(
                BootstrapEvidence(stage: .authentication, authentication: AuthenticationTrace(methodsOffered: [.publicKey]))),
            .keyRequired)
        // The host stopped answering after it rejected the key.
        XCTAssertEqual(
            classify(
                BootstrapEvidence(
                    stage: .authentication,
                    authentication: AuthenticationTrace(
                        methodsOffered: [.publicKey, .password], keyAvailable: true, keyRejected: true),
                    timedOut: true)),
            .timedOut(stage: .authentication))
        // The connection dropped before the host named its methods.
        XCTAssertEqual(classify(BootstrapEvidence(stage: .authentication)), .connectionLost(stage: .authentication))
    }

    func testServerStartOtherOutcomes() {
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, timedOut: true)), .timedOut(stage: .serverStart))
        // A hung command that printed something is still a timeout.
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, output: "Loading profile...\n", timedOut: true)),
            .timedOut(stage: .serverStart))
        let bind = "Network exception: bind: Address already in use\n"
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: 1, output: bind)),
            .serverStartFailed(exitStatus: 1, output: bind))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .serverStart, exitStatus: 0, output: "")),
            .serverStartFailed(exitStatus: 0, output: ""))
        XCTAssertEqual(classify(BootstrapEvidence(stage: .serverStart)), .connectionLost(stage: .serverStart))
    }

    func testGenericOutcomes() {
        XCTAssertEqual(classify(BootstrapEvidence(stage: .serverStart, exitStatus: 127, cancelled: true)), .cancelled)
        XCTAssertEqual(classify(BootstrapEvidence(stage: .keyExchange, timedOut: true)), .timedOut(stage: .keyExchange))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .identityCheck, timedOut: true)), .timedOut(stage: .identityCheck))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .command, sshFailure: .connectionClosed)), .connectionLost(stage: .command))
        XCTAssertEqual(
            classify(
                BootstrapEvidence(
                    stage: .keyExchange, sshFailure: .protocolError,
                    errorDescription: "NIOSSHError.invalidExchangeHashSignature")),
            .sshFailure(description: "NIOSSHError.invalidExchangeHashSignature"))
        XCTAssertEqual(
            classify(BootstrapEvidence(stage: .keyExchange, errorDescription: "read: connection reset")),
            .sshFailure(description: "read: connection reset"))
    }

    func testEveryErrorHasAMessage() {
        let all: [BootstrapError] = [
            .serverNotFound(output: "o"), .localeMissing(locale: "l", output: "o"), .udpBlocked(port: 1),
            .keyRejected(passwordLoginOffered: true), .keyRejected(passwordLoginOffered: false), .passwordRejected,
            .hostKeyChanged(knownFingerprint: "a", presentedFingerprint: "b"),
            .noSharedHostKeyAlgorithm(serverOffers: ["ssh-dss"]), .noSharedHostKeyAlgorithm(serverOffers: []),
            .unsupportedLoginMethod, .localNetworkDenied, .hostKeyNotTrusted(fingerprint: "f"), .keyRequired,
            .connectFailed(reason: "r"), .connectTimedOut(seconds: 10), .timedOut(stage: .connect),
            .timedOut(stage: .keyExchange), .timedOut(stage: .authentication), .timedOut(stage: .serverStart),
            .timedOut(stage: .identityCheck), .serverStartFailed(exitStatus: 1, output: "o"),
            .serverStartFailed(exitStatus: nil, output: ""), .noSharedAlgorithm(kind: "k", serverOffers: []),
            .connectionLost(stage: .command), .sshFailure(description: "d"), .invalidConfiguration("c"),
            .knownHostsUnavailable("k"), .identityCheckFailed(.noSuchProcess), .cancelled,
        ]
        for error in all {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
            XCTAssertTrue(error.description.hasPrefix(error.message))
            if let fix = error.suggestedFix { XCTAssertFalse(fix.isEmpty) }
        }
        // The nine rows of the table all tell the user what to do.
        for error in all.prefix(11) {
            XCTAssertNotNil(error.suggestedFix, "\(error)")
        }
        XCTAssertEqual(
            BootstrapError.noSharedHostKeyAlgorithm(serverOffers: ["ssh-dss"]).message,
            "The host offers no host key type this app supports (it offers ssh-dss).")
    }
}
