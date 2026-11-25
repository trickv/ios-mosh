// A UDP port on 127.0.0.1 that reads every datagram and answers none: a mosh-server whose
// UDP traffic is blocked, for the "MOSH CONNECT seen, no UDP reply in 15 s" row.

#if canImport(Glibc) || canImport(Musl) || canImport(Darwin)

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

public final class UDPSink: @unchecked Sendable {
    /// The bound port.
    public let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var count = 0
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    /// Binds a socket to 127.0.0.1 on a free port and starts reading on a thread of its own.
    public init() throws {
        #if canImport(Darwin)
        let datagram = SOCK_DGRAM
        #else
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #endif
        let descriptor = socket(AF_INET, datagram, 0)
        guard descriptor >= 0 else { throw UDPTestSocket.SocketError(operation: "socket", code: errno) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0, named == 0 else {
            let code = errno
            _ = close(descriptor)
            throw UDPTestSocket.SocketError(operation: "bind", code: code)
        }
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in self.run() }
        thread.start()
    }

    deinit {
        stop()
    }

    /// Datagrams read so far.
    public var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 50) > 0 else { continue }
            let read = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if read >= 0 {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        done.signal()
    }

    /// Stops reading and closes the socket.
    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        done.wait()
        _ = close(descriptor)
    }
}

#endif
