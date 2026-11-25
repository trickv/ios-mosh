// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Sizes that are fixed by mosh 1.4.0. Each one names the constant it was copied from.

import MoshCrypto

/// Protocol version and datagram size constants of mosh 1.4.0.
public enum WireConstants {
    /// `Network::MOSH_PROTOCOL_VERSION` (network.h), "bumped for echo-ack". The receiver refuses an
    /// instruction with any other value ("mosh protocol version mismatch").
    public static let protocolVersion: UInt32 = 2

    // MARK: Datagram size (mosh calls the largest UDP payload it will send "MTU")

    /// `Connection::DEFAULT_IPV4_MTU`: the IP packet size mosh assumes on IPv4.
    public static let defaultIPv4MTU = 1280
    /// `Connection::DEFAULT_IPV6_MTU`: the IP packet size mosh assumes on IPv6 (the guaranteed minimum).
    public static let defaultIPv6MTU = 1280
    /// `Connection::IPV4_HEADER_LEN`: 20 (IP) + 8 (UDP).
    public static let ipv4HeaderLength = 28
    /// `Connection::IPV6_HEADER_LEN`: 40 (IPv6) + 16 (two minimum-sized extension headers) + 8 (UDP).
    public static let ipv6HeaderLength = 64

    /// Largest datagram to an IPv4 address: 1280 - 28 = 1252 bytes (`Connection::set_MTU`).
    public static let ipv4DatagramMTU = defaultIPv4MTU - ipv4HeaderLength
    /// Largest datagram to an IPv6 address: 1280 - 64 = 1216 bytes (`Connection::set_MTU`).
    public static let ipv6DatagramMTU = defaultIPv6MTU - ipv6HeaderLength

    /// `Connection::DEFAULT_SEND_MTU` = 500, the "payload MTU of last resort".
    ///
    /// When each value applies to a client (network.cc):
    /// - The client constructor starts at 500 and, before it returns, calls `set_MTU` with the
    ///   address family of the server. So a client sends with 1252 (IPv4) or 1216 (IPv6) from its
    ///   first datagram.
    /// - If `sendto` fails with `EMSGSIZE`, the MTU drops to 500. Nothing raises it again: mosh
    ///   keeps 500 for the rest of the life of that `Connection`, across port hops too.
    public static let defaultSendMTU = 500

    // MARK: Overhead inside a datagram

    /// `Connection::ADDED_BYTES`: 8 (sequence number / nonce) + 4 (two 16-bit timestamps).
    public static let connectionAddedBytes = 12
    /// `Crypto::Session::ADDED_BYTES`: the 16-byte OCB tag.
    public static let sessionAddedBytes = MoshCipher.tagLength
    /// `Fragment::frag_header_len`: 8 (instruction id) + 2 (final flag and fragment number).
    public static let fragmentHeaderLength = Fragment.headerLength
    /// Everything a datagram carries besides fragment contents: 12 + 16 + 10 = 38 bytes.
    public static let datagramOverhead = connectionAddedBytes + sessionAddedBytes + fragmentHeaderLength

    /// `Crypto::Session::RECEIVE_MTU`: the receive buffer. A larger datagram is refused.
    public static let receiveMTU = MoshCipher.receiveMTU

    /// Bytes of compressed instruction that fit in one fragment for a datagram MTU:
    /// 1214 for IPv4, 1178 for IPv6, 462 for the fallback of 500.
    public static func fragmentContentsBudget(datagramMTU: Int) -> Int {
        datagramMTU - datagramOverhead
    }
}
