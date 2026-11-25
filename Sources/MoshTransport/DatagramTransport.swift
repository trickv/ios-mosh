/// What a `DatagramTransport` reports to its owner.
public enum DatagramTransportEvent: Equatable, Sendable {
    /// One datagram arrived.
    case received([UInt8])
    /// A datagram was refused as too long for the path (`EMSGSIZE`). The owner switches to
    /// smaller datagrams.
    case messageTooLong
    /// A datagram could not be sent for another reason (no route, network down, ...). The
    /// transport may still work later.
    case sendFailed(String)
    /// The transport cannot be used any more. The owner replaces it.
    case unusable(String)
}

/// One UDP "socket" to the server: a disposable path for datagrams.
///
/// The owner (`MoshConnection`) replaces a transport with a new one whenever the path may have
/// changed (mosh's port hop, a return to the foreground, a better or a failed network path). It
/// keeps the old one open until the first authentic datagram arrives on the new one, then closes
/// it. The server follows the client to the new source address.
///
/// The protocol has no file descriptors in it: `POSIXDatagramTransport` implements it with a
/// socket, an iOS implementation wraps `NWConnection` (`receiveMessage` feeds the handler,
/// `send(content:completion:)` reports failures through it, `.failed` and `.waiting` states map
/// to `.unusable` and `.sendFailed`).
public protocol DatagramTransport: AnyObject, Sendable {
    /// Starts delivery. Called once, before the first `send`. The handler is called from a
    /// thread of the transport's choosing, one call at a time, and never after `close()` returned
    /// on that same thread; a late call from another thread is possible and must be tolerated.
    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void)

    /// Sends one datagram without blocking. A datagram that cannot be sent now is dropped; the
    /// protocol on top retransmits.
    func send(_ datagram: [UInt8])

    /// Stops delivery and releases the socket. Further calls of `send` do nothing.
    func close()
}

/// Why a transport could not be opened.
public enum DatagramTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The host is not a numeric IPv4 or IPv6 address.
    case notANumericAddress(String)
    /// A system call failed.
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .notANumericAddress(let host): return "not a numeric IP address: \(host)"
        case .system(let operation, let code): return "\(operation) failed with errno \(code)"
        }
    }
}
