// Counts and logs the datagrams of a moshcli session, across all its sockets and connections.
import Foundation
import MoshTransport

/// What `--seq-log` and the soak summary need: every client-to-server sequence number in the
/// order it was handed to a socket, and how many datagrams went each way.
final class WireTap: @unchecked Sendable {
    private let lock = NSLock()
    private var seqLog: FileHandle?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var dropped: UInt64 = 0
    private var sockets: UInt64 = 0
    private var dropNext = 0
    private let lossPercent: Int
    private var lost: UInt64 = 0
    /// `--delay-ms`: every datagram is held this long in each direction.
    let delayMs: Int

    /// - Parameter seqLogPath: a file to append one decimal sequence number per line to. It is
    ///   created if it does not exist and never truncated, so that several process generations
    ///   of one session can share it.
    /// - Parameter lossPercent: `--loss`: this share of the datagrams, in each direction, is
    ///   thrown away here (an outgoing one after it was logged and counted by the gate, an
    ///   incoming one before the session sees it). To the protocol that is a lossy network.
    /// - Parameter delayMs: `--delay-ms`: each socket holds every datagram this long in each
    ///   direction (after `--loss`), in order.
    init(seqLogPath: String?, lossPercent: Int = 0, delayMs: Int = 0) throws {
        self.lossPercent = lossPercent
        self.delayMs = delayMs
        if let seqLogPath {
            if !FileManager.default.fileExists(atPath: seqLogPath) {
                guard FileManager.default.createFile(atPath: seqLogPath, contents: nil) else {
                    throw CLIError("cannot create \(seqLogPath)")
                }
            }
            guard let handle = FileHandle(forWritingAtPath: seqLogPath) else {
                throw CLIError("cannot open \(seqLogPath) for writing")
            }
            handle.seekToEndOfFile()
            seqLog = handle
        }
    }

    struct Counts: Equatable {
        /// Datagrams handed to a socket.
        var sent: UInt64
        var received: UInt64
        /// Datagrams withheld on purpose (`resume-mem --drop-first`).
        var dropped: UInt64
        /// Sockets opened so far.
        var sockets: UInt64
        /// Datagrams thrown away by `--loss`, both directions.
        var lost: UInt64 = 0
    }

    var counts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return Counts(sent: sent, received: received, dropped: dropped, sockets: sockets, lost: lost)
    }

    /// The next `count` datagrams are logged but not sent.
    func dropNextDatagrams(_ count: Int) {
        lock.lock()
        dropNext = count
        lock.unlock()
    }

    /// Opens a socket to the server, wrapped so that its datagrams are counted.
    func open(host: String, port: UInt16) throws -> any DatagramTransport {
        let inner = try POSIXDatagramTransport(host: host, port: port)
        lock.lock()
        sockets += 1
        lock.unlock()
        return TappedTransport(inner: inner, tap: self)
    }

    /// Logs the sequence number of an outgoing datagram (its first 8 bytes, big-endian; the top
    /// bit is the direction and is 0 from a client). Returns false if the datagram must be
    /// withheld. A withheld datagram is logged too: its number is used up all the same.
    fileprivate func willSend(_ datagram: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let seqLog, datagram.count >= 8 {
            var seq: UInt64 = 0
            for byte in datagram[0..<8] {
                seq = seq << 8 | UInt64(byte)
            }
            seqLog.write(Data("\(seq)\n".utf8))
        }
        if dropNext > 0 {
            dropNext -= 1
            dropped += 1
            return false
        }
        if lossPercent > 0, Int.random(in: 0..<100) < lossPercent {
            lost += 1
            return false
        }
        sent += 1
        return true
    }

    /// False if the datagram is to be thrown away (`--loss`).
    fileprivate func didReceive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if lossPercent > 0, Int.random(in: 0..<100) < lossPercent {
            lost += 1
            return false
        }
        received += 1
        return true
    }
}

/// A `DatagramTransport` that reports to a `WireTap`, and with `--delay-ms` holds every
/// datagram that long in each direction.
///
/// The delay is one serial queue per socket: datagrams leave in the order they came, and a
/// datagram that `--loss` throws away is not queued. `close()` empties the queue: nothing
/// queued is sent or handed to the handler after it (the contract of `DatagramTransport`,
/// which `MoshConnection` relies on for replaced sockets and quiesce).
private final class TappedTransport: DatagramTransport, @unchecked Sendable {
    private let inner: any DatagramTransport
    private let tap: WireTap
    private let delay: DispatchTimeInterval?
    private let queue = DispatchQueue(label: "moshcli.delay")
    private let lock = NSLock()
    private var closed = false

    init(inner: any DatagramTransport, tap: WireTap) {
        self.inner = inner
        self.tap = tap
        delay = tap.delayMs > 0 ? .milliseconds(tap.delayMs) : nil
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Runs `body` after the delay unless the socket was closed meanwhile.
    private func later(_ body: @escaping () -> Void) {
        guard let delay else { body(); return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Under the lock, so that `close()` cannot return between the check and the call.
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.closed else { return }
            body()
        }
    }

    func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {
        let tap = self.tap
        inner.start { [weak self] event in
            if case .received = event, !tap.didReceive() {
                return
            }
            guard let self else { return }
            if self.delay == nil {
                handler(event)
            } else {
                self.later { handler(event) }
            }
        }
    }

    func send(_ datagram: [UInt8]) {
        guard !isClosed, tap.willSend(datagram) else { return }
        let inner = self.inner
        later { inner.send(datagram) }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        inner.close()
    }
}

/// An error with a message for the user.
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
