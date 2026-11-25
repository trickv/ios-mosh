#if canImport(Network)
import Dispatch
import Foundation
import Network

/// A `DatagramTransport` on Network.framework (`NWConnection` with UDP), for the app.
///
/// It keeps the contract of `POSIXDatagramTransport`, with these differences, all on purpose:
///
/// - **Connected, not unconnected.** An `NWConnection` has one remote endpoint and receives only
///   datagrams from it. mosh's client socket is unconnected and takes anything, because only the
///   session key says who the sender is. mosh-server always answers from the address and port
///   the client sent to (it does not hop ports itself), so nothing the server sends is lost; a
///   datagram from anywhere else would fail authentication anyway.
/// - **States instead of errno on every send.** `.waiting` (no usable path now; Network.framework
///   moves the same connection back to `.ready` when one appears) is reported once as
///   `.sendFailed`, and datagrams are dropped meanwhile. `.failed` (the connection is dead) is
///   reported once as `.unusable`, and the owner replaces the transport. These two mappings are
///   the ones the `DatagramTransport` protocol documents.
///
/// Like the POSIX transport, each instance is a new socket with a new source port: the owner's
/// socket replacement (mosh's port hop) is "make a new transport", nothing else.
///
/// Changes of the network path are not watched here: the app watches them (`NWPathMonitor`
/// in its `PathWatcher`) and asks the session for a new socket with `replaceSocket()`.
public final class NWDatagramTransport: DatagramTransport, @unchecked Sendable {
    /// The address family of the server address.
    public let family: AddressFamily

    private let connection: NWConnection
    private let queue: DispatchQueue
    /// Guards everything below. Network.framework calls back on `queue`; `send` and `close` come
    /// from the owner's actor, on any thread.
    private let lock = NSLock()
    private var handler: (@Sendable (DatagramTransportEvent) -> Void)?
    private var started = false
    private var closed = false
    /// The last state seen by the state handler; decides whether a send is attempted.
    private var state: NWConnection.State = .setup
    /// `.unusable` is reported at most once per transport: the owner opens a new one on it, and
    /// a second report from the same dead connection would make it open another for nothing.
    private var reportedUnusable = false
    /// `.sendFailed` for `.waiting` is reported once per stay in that state, not per datagram.
    private var reportedWaiting = false
    /// Receives that completed with a POSIX error since the last datagram.
    private var consecutiveReceiveErrors = 0

    /// How many receive errors in a row are answered with an immediate new receive.
    static let immediateReceiveRetries = 3
    /// The pause before the next receive once that many errors came in a row.
    static let receiveRetryDelayMilliseconds = 100

    /// How long to wait, in milliseconds, before the next `receiveMessage` after
    /// `consecutiveErrors` receives in a row completed with an error (0: no error, a datagram).
    ///
    /// An ICMP error for an earlier send is one error and then quiet, so the first few are
    /// followed at once. A connection that completes every receive with an error while it
    /// stays `.ready` or `.waiting` would spin on the queue: from then on there is a pause.
    static func receiveRearmDelay(consecutiveErrors: Int) -> Int {
        consecutiveErrors > immediateReceiveRetries ? receiveRetryDelayMilliseconds : 0
    }

    /// Sends ECT(0), as mosh does with `IP_TOS` 0x02 ("ECN-capable transport only"). A content
    /// context is immutable and can be shared by all sends.
    private static let datagramContext: NWConnection.ContentContext = {
        let ip = NWProtocolIP.Metadata()
        ip.ecn = .ect0
        return NWConnection.ContentContext(identifier: "mosh-datagram", metadata: [ip])
    }()

    /// A transport for datagrams to `host`, which must be a numeric IPv4 or IPv6 address (an IPv6
    /// address may carry a zone: `fe80::1%en0`). No name lookups happen, here or later: the
    /// endpoint is built from a parsed address, never from a host name string, so
    /// Network.framework has nothing to resolve.
    ///
    /// Throws `DatagramTransportError.notANumericAddress` like `POSIXDatagramTransport`. It never
    /// throws `.system`: nothing is opened until `start`.
    public init(host: String, port: UInt16) throws {
        // `IPv4Address("")` is nil already; the explicit check keeps the rule visible and equal
        // to the POSIX transport's.
        guard !host.isEmpty else { throw DatagramTransportError.notANumericAddress(host) }
        // Any port is taken, as by the POSIX transport (port 0 simply gets no answer).
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let address: NWEndpoint.Host
        // IPv4 first: `IPv6Address` would not take a dotted quad, but the order makes the family
        // decision obvious. IPv4Address accepts the same short forms as inet_aton ("127.1"),
        // as getaddrinfo with AI_NUMERICHOST does for the POSIX transport.
        if let v4 = IPv4Address(host) {
            address = .ipv4(v4)
            family = .ipv4
        } else if let v6 = IPv6Address(host) {
            // Also IPv4-mapped addresses (`::ffff:a.b.c.d`): AF_INET6 for getaddrinfo as well.
            address = .ipv6(v6)
            family = .ipv6
        } else {
            throw DatagramTransportError.notANumericAddress(host)
        }

        let parameters = NWParameters.udp
        // Path MTU discovery is left at the system default, as the POSIX transport does on
        // Darwin (it disables it on Linux only). A datagram too large for the path comes back as
        // EMSGSIZE in the send completion and is reported as `.messageTooLong`.
        connection = NWConnection(to: .hostPort(host: address, port: nwPort), using: parameters)
        queue = DispatchQueue(label: "mosh.nw-datagram-transport")
    }

    deinit {
        close()
    }

    public func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {
        lock.lock()
        guard !closed, !started else {
            lock.unlock()
            return
        }
        started = true
        self.handler = handler
        lock.unlock()

        // The handlers hold the transport weakly: the connection keeps its handlers until it is
        // cancelled, and the transport must be able to go away (deinit closes it) on its own.
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        connection.start(queue: queue)
        receiveNext()
    }

    public func send(_ datagram: [UInt8]) {
        lock.lock()
        guard !closed, started else {
            lock.unlock()
            return
        }
        // Sends during `.setup` and `.preparing` are queued by Network.framework and go out as
        // soon as the connection is ready (a few milliseconds on a usable path). Dropping them
        // instead would delay the first datagram of every new socket by a retransmission
        // timeout. In `.waiting`, `.failed` and `.cancelled` the datagram cannot leave now and
        // is dropped, as the protocol says; mosh retransmits.
        switch state {
        case .setup, .preparing, .ready:
            break
        default:
            lock.unlock()
            return
        }
        lock.unlock()

        connection.send(
            content: Data(datagram),
            contentContext: Self.datagramContext,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.sendCompleted(with: error)
            }
        )
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        handler = nil
        let wasStarted = started
        lock.unlock()
        // cancel() releases the socket. Completions and receives still pending are called with
        // ECANCELED afterwards, on `queue`; they find no handler and do nothing.
        if wasStarted {
            connection.cancel()
        }
    }

    // MARK: Callbacks (on `queue`)

    /// The handler, or nil once closed. Read under the lock and called outside it, like the
    /// POSIX transport: a call that read it just before `close()` may still run once, on this
    /// queue, which the protocol allows ("a late call from another thread").
    private func currentHandler() -> (@Sendable (DatagramTransportEvent) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : handler
    }

    private func stateChanged(_ newState: NWConnection.State) {
        lock.lock()
        state = newState
        var event: DatagramTransportEvent?
        switch newState {
        case .ready:
            reportedWaiting = false
        case .waiting(let error):
            if !reportedWaiting {
                reportedWaiting = true
                event = .sendFailed("no usable network path: \(error)")
            }
        case .failed(let error):
            if !reportedUnusable {
                reportedUnusable = true
                event = .unusable("connection failed: \(error)")
            }
        default:
            break
        }
        let handler = closed ? nil : self.handler
        lock.unlock()
        if let event {
            handler?(event)
        }
    }

    /// Maps a send error the way the POSIX transport maps `sendto`'s errno.
    private func sendCompleted(with error: NWError) {
        let event: DatagramTransportEvent?
        switch error {
        case .posix(.EMSGSIZE):
            event = .messageTooLong
        case .posix(.EAGAIN), .posix(.ECANCELED):
            // EAGAIN: the POSIX transport drops these silently too. ECANCELED: the send was
            // still pending when the transport was closed (or failed, already reported).
            event = nil
        default:
            event = .sendFailed("\(error)")
        }
        if let event {
            currentHandler()?(event)
        }
    }

    /// One `receiveMessage` at a time, re-armed after each datagram, so the handler gets one
    /// call at a time and in arrival order.
    private func receiveNext() {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty, let handler = self.currentHandler() {
                handler(.received([UInt8](content)))
            }
            guard self.currentHandler() != nil else { return }
            let delay = self.noteReceive(failed: error != nil)
            if let error {
                switch error {
                case .posix:
                    // An ICMP error for an earlier send (ECONNREFUSED when the server's port is
                    // closed, EHOSTUNREACH, ...) arrives here on a connected UDP socket. Like the
                    // POSIX transport, it says nothing about the next datagram: keep receiving.
                    // A connection that really died goes to `.failed` and is reported there; it
                    // also completes every receive with an error, so stop re-arming then, or
                    // this would spin.
                    if self.isDead() { return }
                default:
                    // DNS or TLS errors cannot happen on a UDP connection to a numeric address.
                    // If one does, the connection is in an unknown state: let the owner replace it.
                    self.reportUnusable("receive failed: \(error)")
                    return
                }
            }
            if delay == 0 {
                self.receiveNext()
            } else {
                // Weak, like the handlers: a waiting retry must not keep the transport alive.
                // After `close()` it finds no handler and does not receive.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    guard let self, self.currentHandler() != nil else { return }
                    self.receiveNext()
                }
            }
        }
    }

    /// Counts receive errors in a row and says how long to wait before the next receive.
    private func noteReceive(failed: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        consecutiveReceiveErrors = failed ? consecutiveReceiveErrors + 1 : 0
        return Self.receiveRearmDelay(consecutiveErrors: consecutiveReceiveErrors)
    }

    private func isDead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    private func reportUnusable(_ description: String) {
        lock.lock()
        let first = !reportedUnusable
        reportedUnusable = true
        let handler = closed ? nil : self.handler
        lock.unlock()
        if first {
            handler?(.unusable(description))
        }
    }
}
#endif
