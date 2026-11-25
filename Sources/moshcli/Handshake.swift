// moshcli handshake: the first step of a mosh session, by hand.
//
// Sends the first instruction of a mosh client to a running mosh-server, waits for the server's
// first datagram, and prints what is in it. It proves that key, encryption, packet framing,
// fragments, zlib and protobuf all agree with the real server. It is not a session: it never
// acknowledges anything, and it uses a blocking UDP socket of its own (the transport comes later).
//
// What mosh's client sends first (src/frontend/stmclient.cc main_init, transportsender-impl.h):
// the sender starts with state 0 (empty) as already sent; the client then appends a Resize with
// its window size, which makes state 1. The first instruction is therefore
//     old_num 0, new_num 1, ack_num 0, throwaway_num 0, diff = UserMessage { resize }, chaff
// in fragment id 1 (mosh's fragmenter counts from 1) and in the datagram with sequence number 0.

import Foundation
import MoshCrypto
import MoshWire
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

private let handshakeUsage = """
    usage: moshcli handshake --host H --port P --key K [--width W] [--height H]
                             [--timeout SECONDS] [--count N] [--first-seq N]

      --host H         server address (IPv4 or IPv6) or name
      --port P         UDP port from "MOSH CONNECT <port> <key>"
      --key K          the 22-character key; if absent, the environment variable MOSH_KEY is used
      --width W        terminal width to announce (default 80)
      --height H       terminal height to announce (default 24)
      --timeout S      give up after this many seconds without a complete instruction (default 10)
      --count N        print the first N instructions from the server instead of only one
      --first-seq N    sequence number of the first datagram (default 0)

    Use it once per server. A sequence number must never be used twice with one key, and the
    server ignores the source address of datagrams numbered below ones it has already seen; to
    talk to the same server again, pass --first-seq with a number above every one used so far.
    Exit status: 0 the server answered and the answer decoded, 1 it did not, 2 bad arguments.

    """

private struct HandshakeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct HandshakeOptions {
    var host = ""
    var port = ""
    var key = ""
    var width: Int32 = 80
    var height: Int32 = 24
    var timeout: Double = 10
    var count = 1
    var firstSeq: UInt64 = 0

    /// Returns nil (after printing the reason) when the arguments are not usable.
    static func parse(_ arguments: [String]) -> HandshakeOptions? {
        var options = HandshakeOptions()
        var index = 0
        func fail(_ message: String) -> HandshakeOptions? {
            FileHandle.standardError.write(Data("moshcli handshake: \(message)\n\(handshakeUsage)".utf8))
            return nil
        }
        while index < arguments.count {
            let name = arguments[index]
            if name == "--help" || name == "-h" {
                print(handshakeUsage, terminator: "")
                return nil
            }
            guard index + 1 < arguments.count else { return fail("\(name) needs a value") }
            let value = arguments[index + 1]
            index += 2
            switch name {
            case "--host": options.host = value
            case "--port": options.port = value
            case "--key": options.key = value
            case "--width":
                guard let number = Int32(value), number > 0 else { return fail("bad width \(value)") }
                options.width = number
            case "--height":
                guard let number = Int32(value), number > 0 else { return fail("bad height \(value)") }
                options.height = number
            case "--timeout":
                guard let number = Double(value), number > 0 else { return fail("bad timeout \(value)") }
                options.timeout = number
            case "--count":
                guard let number = Int(value), number > 0 else { return fail("bad count \(value)") }
                options.count = number
            case "--first-seq":
                guard let number = UInt64(value), number <= MoshCipher.maxSequence else { return fail("bad first-seq \(value)") }
                options.firstSeq = number
            default:
                return fail("unknown option \(name)")
            }
        }
        if options.key.isEmpty {
            options.key = ProcessInfo.processInfo.environment["MOSH_KEY"] ?? ""
        }
        if options.host.isEmpty { return fail("--host is required") }
        if (UInt16(options.port) ?? 0) == 0 { return fail("--port must be 1 to 65535") }
        if options.key.isEmpty { return fail("--key (or MOSH_KEY) is required") }
        return options
    }
}

/// A connected, blocking UDP socket. Just enough for one question and one answer.
private struct HandshakeSocket {
    let descriptor: Int32
    let isIPv6: Bool
    /// The address in numeric form: what a name resolved to.
    let address: String

    static func open(host: String, port: String) throws -> HandshakeSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_DGRAM
        #else
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #endif
        var results: UnsafeMutablePointer<addrinfo>? = nil
        let status = getaddrinfo(host, port, &hints, &results)
        guard status == 0, let first = results else {
            throw HandshakeFailure("cannot resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(results) }

        var lastError = "no address"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if descriptor >= 0 {
                if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let named = getnameinfo(
                        info.pointee.ai_addr, info.pointee.ai_addrlen,
                        &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST)
                    return HandshakeSocket(
                        descriptor: descriptor, isIPv6: info.pointee.ai_family == AF_INET6,
                        address: named == 0 ? String(cString: numeric) : host)
                }
                lastError = "connect: " + String(cString: strerror(errno))
                close(descriptor)
            } else {
                lastError = "socket: " + String(cString: strerror(errno))
            }
            candidate = info.pointee.ai_next
        }
        throw HandshakeFailure("cannot reach \(host): \(lastError)")
    }

    func send(_ bytes: [UInt8]) throws {
        let sent = bytes.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            return Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #elseif canImport(Glibc)
            return Glibc.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #else
            return Musl.send(descriptor, buffer.baseAddress, buffer.count, 0)
            #endif
        }
        guard sent == bytes.count else {
            throw HandshakeFailure("send: " + String(cString: strerror(errno)))
        }
    }

    /// One datagram, or nil when none arrived in time.
    func receive(timeoutMilliseconds: Int) throws -> [UInt8]? {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollDescriptor, 1, Int32(max(0, timeoutMilliseconds)))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { return nil }
            throw HandshakeFailure("poll: " + String(cString: strerror(errno)))
        }
        // One byte more than mosh's receive buffer, to notice an oversize datagram.
        var buffer = [UInt8](repeating: 0, count: MoshCipher.receiveMTU + 1)
        let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else {
            let code = errno
            if code == ECONNREFUSED {
                // The ICMP answer to our datagram. A UDP "connect" always succeeds, so a name with
                // several addresses is not retried on the next one.
                throw HandshakeFailure("nothing listens on \(address) at that port (connection refused). "
                    + "mosh-server listens on one address; give that address instead of a name")
            }
            throw HandshakeFailure("recv: " + String(cString: strerror(code)))
        }
        buffer.removeSubrange(count...)
        return buffer
    }

    func shutDown() {
        close(descriptor)
    }
}

/// Bytes as a quoted string: printable ASCII as it is, the rest as escapes.
private func quoted(_ bytes: [UInt8]) -> String {
    var out = "\""
    for byte in bytes {
        switch byte {
        case 0x1B: out += "\\e"
        case 0x0D: out += "\\r"
        case 0x0A: out += "\\n"
        case 0x09: out += "\\t"
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            let digits = String(byte, radix: 16)
            out += "\\x" + (digits.count == 1 ? "0" : "") + digits
        }
    }
    return out + "\""
}

private func describe(_ instruction: Instruction) -> String {
    func number(_ value: UInt64) -> String {
        value == Instruction.shutdownNum ? "\(value) (shutdown)" : "\(value)"
    }
    return "protocol_version=\(instruction.protocolVersion) old_num=\(number(instruction.oldNum)) "
        + "new_num=\(number(instruction.newNum)) ack_num=\(number(instruction.ackNum)) "
        + "throwaway_num=\(number(instruction.throwawayNum)) "
        + "diff=\(instruction.diff.count) bytes chaff=\(instruction.chaff.count) bytes"
}

private func currentMilliseconds() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}

/// The `handshake` subcommand. See the usage text.
func handshakeCommand(_ arguments: [String]) async throws -> Int32 {
    guard let options = HandshakeOptions.parse(arguments) else {
        return arguments.contains("--help") || arguments.contains("-h") ? 0 : 2
    }
    // Line by line, so that the output keeps its order next to error messages when it is piped.
    setvbuf(stdout, nil, _IOLBF, 0)
    let cipher: MoshCipher
    do {
        cipher = try MoshCipher(key: try Base64Key(printable: options.key))
    } catch {
        FileHandle.standardError.write(Data("moshcli handshake: bad key: \(error)\n".utf8))
        return 2
    }

    let socket = try HandshakeSocket.open(host: options.host, port: options.port)
    defer { socket.shutDown() }
    // Connection::set_MTU: the datagram size follows the address family of the server.
    let datagramMTU = socket.isIPv6 ? WireConstants.ipv6DatagramMTU : WireConstants.ipv4DatagramMTU
    let budget = WireConstants.fragmentContentsBudget(datagramMTU: datagramMTU)
    print("server: \(socket.address) port \(options.port) (\(socket.isIPv6 ? "IPv6" : "IPv4"), datagram MTU \(datagramMTU), fragment contents up to \(budget) bytes)")

    let userMessage = UserMessage(instructions: [.resize(width: options.width, height: options.height)])
    var nextSeq = options.firstSeq
    var nextFragmentID: UInt64 = 1

    /// Sends state 1 once. A repeat is a new instruction on the wire (new chaff), so it takes the
    /// next fragment id, as mosh's fragmenter would, and the next sequence numbers.
    func sendFirstInstruction() throws {
        let instruction = Instruction(
            oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0,
            diff: userMessage.serialized(), chaff: Instruction.makeChaff())
        let fragments = try Fragmenter.makeFragments(instruction: instruction, id: nextFragmentID, contentsBudget: budget)
        nextFragmentID += 1
        for fragment in fragments {
            let packet = Packet(
                seq: nextSeq, direction: .toServer,
                timestamp: Timestamp16.now(milliseconds: currentMilliseconds()),
                timestampReply: Timestamp16.none, payload: fragment.serialized())
            nextSeq += 1
            let datagram = try packet.encrypted(with: cipher)
            try socket.send(datagram)
            print("sent: seq=\(packet.seq) timestamp=\(packet.timestamp) fragment id=\(fragment.id) num=\(fragment.fragmentNum) final=\(fragment.isFinal) datagram=\(datagram.count) bytes")
        }
        print("  instruction: \(describe(instruction))")
        print("  user message: resize \(options.width)x\(options.height) (\(hexString(userMessage.serialized())))")
    }

    try sendFirstInstruction()
    var lastSend = Date()
    let deadline = Date().addingTimeInterval(options.timeout)
    var assembly = FragmentAssembly()
    var printed = 0
    var seenStates = Set<UInt64>()
    var acknowledged = false

    while printed < options.count {
        let now = Date()
        if now >= deadline { break }
        let wait = min(deadline.timeIntervalSince(now), 0.25)
        guard let datagram = try socket.receive(timeoutMilliseconds: Int(wait * 1000) + 1) else {
            // mosh retransmits after its retransmission timeout, which starts at one second.
            if printed == 0, Date().timeIntervalSince(lastSend) >= 1 {
                try sendFirstInstruction()
                lastSend = Date()
            }
            continue
        }

        let packet: Packet
        do {
            packet = try Packet(decrypting: datagram, with: cipher)
        } catch {
            print("received: \(datagram.count) bytes that do not decrypt (\(error)); ignored")
            continue
        }
        guard packet.direction == .toClient else {
            print("received: a datagram marked client-to-server; ignored")
            continue
        }
        let fragment = try Fragment(serialized: packet.payload)
        let reply = packet.timestampReply == Timestamp16.none ? "none" : "\(packet.timestampReply)"
        print("received: datagram=\(datagram.count) bytes seq=\(packet.seq) timestamp=\(packet.timestamp) timestamp_reply=\(reply) fragment id=\(fragment.id) num=\(fragment.fragmentNum) final=\(fragment.isFinal) contents=\(fragment.contents.count) bytes")

        guard try assembly.add(fragment) else { continue }
        let instruction = try assembly.takeInstruction()
        // Without acknowledgments the server repeats itself; show each state once.
        guard seenStates.insert(instruction.newNum).inserted else { continue }
        print("  instruction: \(describe(instruction))")
        guard instruction.protocolVersion == WireConstants.protocolVersion else {
            throw HandshakeFailure("mosh protocol version mismatch: the server speaks \(instruction.protocolVersion)")
        }
        // Our only state is number 1. An ack_num of 1 says the server decrypted and decoded it.
        if instruction.ackNum == 1 { acknowledged = true }
        let message = try HostMessage(serialized: instruction.diff)
        print("  host message: \(message.instructions.count) instruction\(message.instructions.count == 1 ? "" : "s")")
        for (index, hostInstruction) in message.instructions.enumerated() {
            switch hostInstruction {
            case .hostBytes(let bytes):
                print("    [\(index)] hostbytes \(bytes.count) bytes: \(quoted(bytes))")
            case .resize(let width, let height):
                print("    [\(index)] resize \(width)x\(height)")
            case .echoAck(let number):
                print("    [\(index)] echoack \(number)")
            }
        }
        printed += 1
    }

    guard printed > 0 else {
        throw HandshakeFailure("no answer from the server within \(options.timeout) seconds (wrong key or port, UDP blocked, or the server has gone)")
    }
    let decoded = "\(printed) instruction\(printed == 1 ? "" : "s") from the server decoded"
    if acknowledged {
        print("handshake ok: the server acknowledged our state 1; \(decoded)")
    } else {
        print("handshake ok: \(decoded) (the server did not acknowledge state 1; it may know this client already)")
    }
    return 0
}

private func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for (index, byte) in bytes.enumerated() {
        if index > 0 { out.append(UInt8(ascii: " ")) }
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 15)])
    }
    return String(decoding: out, as: UTF8.self)
}
