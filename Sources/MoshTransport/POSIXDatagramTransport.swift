#if canImport(Glibc) || canImport(Darwin) || canImport(Musl)
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

/// A `DatagramTransport` on a non-blocking UDP socket (Linux and macOS; also usable on iOS, where
/// `NWConnection` is preferred).
///
/// Like mosh's client socket it is not connected: datagrams go out with `sendto` and anything
/// that arrives is delivered, because only the session key says who the sender is.
public final class POSIXDatagramTransport: DatagramTransport, @unchecked Sendable {
    /// The address family of the server address.
    public let family: AddressFamily

    private let lock = NSLock()
    private var descriptor: Int32
    private var address: sockaddr_storage
    private let addressLength: socklen_t
    private var source: DispatchSourceRead?
    private var handler: (@Sendable (DatagramTransportEvent) -> Void)?
    private var closed = false
    private let queue: DispatchQueue

    /// Opens a socket for datagrams to `host`, which must be a numeric IPv4 or IPv6 address
    /// (an IPv6 address may carry a zone: `fe80::1%eth0`). No name lookups happen here.
    public init(host: String, port: UInt16) throws {
        // Darwin's getaddrinfo takes "" as "no host" and answers with the loopback address.
        guard !host.isEmpty else { throw DatagramTransportError.notANumericAddress(host) }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #else
        hints.ai_socktype = SOCK_DGRAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let info = list else {
            throw DatagramTransportError.notANumericAddress(host)
        }
        defer { freeaddrinfo(list) }

        switch info.pointee.ai_family {
        case AF_INET: family = .ipv4
        case AF_INET6: family = .ipv6
        default: throw DatagramTransportError.notANumericAddress(host)
        }
        var storage = sockaddr_storage()
        let length = Int(info.pointee.ai_addrlen)
        guard length <= MemoryLayout<sockaddr_storage>.size, let raw = info.pointee.ai_addr else {
            throw DatagramTransportError.notANumericAddress(host)
        }
        withUnsafeMutableBytes(of: &storage) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: raw, count: length))
        }
        address = storage
        addressLength = socklen_t(length)

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, 0)
        guard fd >= 0 else { throw DatagramTransportError.system(operation: "socket", code: errno) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = Self.closeDescriptor(fd)
            throw DatagramTransportError.system(operation: "fcntl", code: code)
        }
        #if os(Linux)
        // mosh: "Disable path MTU discovery": let the network fragment instead of failing.
        var discover = Int32(IP_PMTUDISC_DONT)
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MTU_DISCOVER, &discover, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // mosh: "ECN-capable transport only". Failure does not matter.
        var tos: Int32 = 0x02
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        // A send on a dead path must not kill the process.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        descriptor = fd
        queue = DispatchQueue(label: "mosh.posix-datagram-transport")
    }

    deinit {
        close()
    }

    public func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, source == nil else { return }
        self.handler = handler
        let fd = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(fd)
        }
        source.setCancelHandler {
            _ = Self.closeDescriptor(fd)
        }
        self.source = source
        source.resume()
    }

    public func send(_ datagram: [UInt8]) {
        // The lock is held across sendto (which never blocks), so that close() cannot release
        // the descriptor, and the system hand its number to another socket, in between.
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let fd = descriptor
        var destination = address
        let length = addressLength
        let handler = self.handler
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                datagram.withUnsafeBytes { bytes in
                    sendto(fd, bytes.baseAddress, bytes.count, Self.sendFlags, target, length)
                }
            }
        }
        let code = errno
        lock.unlock()

        guard sent != datagram.count else { return }
        if code == EMSGSIZE {
            handler?(.messageTooLong)
        } else if code != EAGAIN && code != EWOULDBLOCK {
            handler?(.sendFailed(String(cString: strerror(code))))
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        handler = nil
        if let source {
            // The cancel handler closes the descriptor once no event handler is running.
            source.cancel()
            self.source = nil
        } else {
            _ = Self.closeDescriptor(descriptor)
        }
        descriptor = -1
    }

    /// Reads everything that is waiting.
    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            lock.lock()
            let handler = closed ? nil : self.handler
            lock.unlock()
            guard let handler else { return }
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress, bytes.count, Self.receiveFlags)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                // EAGAIN: nothing left. ECONNREFUSED and friends: an ICMP error for an earlier
                // send, which says nothing about the next datagram.
                return
            }
            handler(.received(Array(buffer[0..<count])))
        }
    }

    private static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.close(fd)
        #elseif canImport(Musl)
        return Musl.close(fd)
        #else
        return Darwin.close(fd)
        #endif
    }

    private static var sendFlags: Int32 {
        #if os(Linux)
        return Int32(MSG_DONTWAIT) | Int32(MSG_NOSIGNAL)
        #else
        return Int32(MSG_DONTWAIT)
        #endif
    }

    private static var receiveFlags: Int32 { Int32(MSG_DONTWAIT) }
}
#endif
