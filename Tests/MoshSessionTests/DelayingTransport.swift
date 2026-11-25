import Dispatch
import Foundation
import MoshTransport

/// A test `DatagramTransport` around `POSIXDatagramTransport`: every datagram is held `delayMs`
/// in each direction (order kept), and inbound datagrams can be dropped for a while. For the
/// local echo wiring tests, which need a round trip long enough to see a guess before its echo.
///
/// `close()` empties both queues: nothing queued is sent or handed to the handler afterwards
/// (DatagramTransport.swift: no handler call and no send after `close()`).
final class DelayingTransport: DatagramTransport, @unchecked Sendable {
    private let inner: POSIXDatagramTransport
    private let delayMs: Int
    private let queue = DispatchQueue(label: "DelayingTransport")
    private let lock = NSLock()
    private var closed = false
    private var droppingInbound = false

    init(host: String, port: UInt16, delayMs: Int) throws {
        inner = try POSIXDatagramTransport(host: host, port: port)
        self.delayMs = delayMs
    }

    /// While true, every datagram from the server is dropped on arrival.
    var dropsInbound: Bool {
        get { lock.lock(); defer { lock.unlock() }; return droppingInbound }
        set { lock.lock(); droppingInbound = newValue; lock.unlock() }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {
        inner.start { [weak self] event in
            guard let self, !self.isClosed else { return }
            if case .received = event, self.dropsInbound { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.delayMs)) { [weak self] in
                guard let self, !self.isClosed else { return }
                handler(event)
            }
        }
    }

    func send(_ datagram: [UInt8]) {
        guard !isClosed else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.inner.send(datagram)
        }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        inner.close()
    }
}

/// Holds the latest `DelayingTransport` a session made, so a test can switch its drop on.
final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DelayingTransport?
    var transport: DelayingTransport? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
