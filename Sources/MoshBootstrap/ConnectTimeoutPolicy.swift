/// What kind of address a host field names, as far as its text tells.
public enum AddressClass: Equatable, Sendable {
    /// 127.0.0.0/8, ::1, `localhost`.
    case loopback
    /// 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7.
    case privateNetwork
    /// 169.254.0.0/16, fe80::/10.
    case linkLocal
    /// Any other IP address, including 100.64.0.0/10 (Tailscale): a VPN is not a local network
    /// to iOS.
    case publicAddress
    /// A name that can only be resolved on the local network: `*.local` (mDNS) or a single label
    /// (`nas`).
    case localName
    /// Any other DNS name. Where it points is not known before it is resolved.
    case name

    /// Whether iOS's Local Network privacy applies to a connection to it.
    public var isLocalNetwork: Bool {
        switch self {
        case .privateNetwork, .linkLocal, .localName: return true
        case .loopback, .publicAddress, .name: return false
        }
    }
}

/// How long a TCP connect may take.
///
/// The first connection to a device on the local network makes iOS show the Local Network
/// alert, and the connection waits until it is answered. 30 seconds give the user time to read
/// and answer it; everywhere else 10 seconds are enough to call a host unreachable.
public enum ConnectTimeoutPolicy {
    public static let standardSeconds = 10
    public static let localNetworkSeconds = 30

    public static func timeoutSeconds(forHost host: String) -> Int {
        addressClass(ofHost: host).isLocalNetwork ? localNetworkSeconds : standardSeconds
    }

    public static func addressClass(ofHost host: String) -> AddressClass {
        var text = host.lowercased().filter { $0 != " " }
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        // An IPv6 zone ("fe80::1%en0") does not change the class.
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        while text.count > 1, text.hasSuffix(".") { text.removeLast() }

        if let v4 = parseIPv4(text) { return classify(v4) }
        if text.contains(":") {
            return classifyIPv6(text) ?? .name
        }
        if text == "localhost" || text.hasSuffix(".localhost") { return .loopback }
        if text.hasSuffix(".local") || (!text.isEmpty && !text.contains(".")) { return .localName }
        return .name
    }

    /// Strict dotted quad: four decimal numbers from 0 to 255.
    static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func classify(_ v4: [UInt8]) -> AddressClass {
        switch (v4[0], v4[1]) {
        case (127, _): return .loopback
        case (10, _): return .privateNetwork
        case (172, 16...31): return .privateNetwork
        case (192, 168): return .privateNetwork
        case (169, 254): return .linkLocal
        default: return .publicAddress
        }
    }

    /// Classifies an IPv6 literal by its first group; nil if the text is not one.
    private static func classifyIPv6(_ text: String) -> AddressClass? {
        let allowed = text.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) || byte == UInt8(ascii: ":")
                || byte == UInt8(ascii: ".")
        }
        guard allowed, text.utf8.filter({ $0 == UInt8(ascii: ":") }).count >= 2 else { return nil }
        if text == "::1" { return .loopback }
        // IPv4-mapped (::ffff:192.168.1.5) and IPv4-compatible forms take the class of the
        // embedded address.
        if let lastColon = text.lastIndex(of: ":"),
            let v4 = parseIPv4(String(text[text.index(after: lastColon)...])),
            text.hasPrefix("::")
        {
            return classify(v4)
        }
        if text.hasPrefix("::") { return .publicAddress }
        let firstGroup = text.prefix(while: { $0 != ":" })
        guard !firstGroup.isEmpty, firstGroup.count <= 4, let value = UInt16(firstGroup, radix: 16) else {
            return nil
        }
        if value & 0xffc0 == 0xfe80 { return .linkLocal }
        if value & 0xfe00 == 0xfc00 { return .privateNetwork }
        return .publicAddress
    }
}
