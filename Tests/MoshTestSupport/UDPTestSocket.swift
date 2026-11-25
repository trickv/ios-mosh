// A minimal blocking UDP socket for tests that talk to a server on 127.0.0.1 without the real
// transport (MoshTransport has its own sockets; this one exists so that tests of lower layers do
// not depend on it).

#if canImport(Glibc) || canImport(Musl) || canImport(Darwin)

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

/// A UDP socket connected to one IPv4 address and port.
public final class UDPTestSocket {
    public struct SocketError: Error, CustomStringConvertible {
        public let operation: String
        public let code: Int32
        public var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    private var descriptor: Int32

    /// Opens a socket and connects it, so that only datagrams from that address are received.
    /// - Parameter host: an IPv4 address in dotted form.
    public init(host: String = "127.0.0.1", port: UInt16) throws {
        #if canImport(Darwin)
        let datagram = SOCK_DGRAM
        #else
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #endif
        descriptor = socket(AF_INET, datagram, 0)
        guard descriptor >= 0 else { throw SocketError(operation: "socket", code: errno) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            closeDescriptor()
            throw SocketError(operation: "inet_pton(\(host))", code: EINVAL)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            closeDescriptor()
            throw SocketError(operation: "connect", code: code)
        }
    }

    deinit {
        closeDescriptor()
    }

    /// Sends one datagram.
    public func send(_ bytes: [UInt8]) throws {
        let sent = bytes.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            return Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #elseif canImport(Glibc)
            return Glibc.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #else
            return Musl.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #endif
        }
        guard sent == bytes.count else { throw SocketError(operation: "send", code: errno) }
    }

    /// Waits for one datagram. Returns nil if none arrives within the timeout.
    /// - Parameter maxLength: longer datagrams are cut off. mosh never sends more than 2048 bytes.
    public func receive(timeoutMilliseconds: Int, maxLength: Int = 2048) throws -> [UInt8]? {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollDescriptor, 1, Int32(max(0, timeoutMilliseconds)))
        if ready == 0 { return nil }
        guard ready > 0 else {
            if errno == EINTR { return nil }
            throw SocketError(operation: "poll", code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else {
            // A connected UDP socket reports an ICMP "port unreachable" as ECONNREFUSED.
            throw SocketError(operation: "recv", code: errno)
        }
        buffer.removeSubrange(count...)
        return buffer
    }

    /// Closes the socket. Further calls fail.
    public func close() {
        closeDescriptor()
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #else
            _ = Musl.close(descriptor)
            #endif
            descriptor = -1
        }
    }
}

#endif
