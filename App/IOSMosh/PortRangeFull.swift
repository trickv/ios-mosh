// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Parts ported to Swift in 2026 from mosh 1.4.0 (the mosh sources are named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

import MoshBootstrap

/// The message for a host whose UDP port range has no free port left (docs/notes/multi-session/
/// DESIGN.md 3.1 H3 and step 13; brief item 10: "sessions per host are limited by the host's UDP
/// port range"). The app does not count sessions: mosh-server takes the first free port of the
/// range and fails when there is none, and this says that in words.
///
/// The app's server command has `-s` (`MoshServerCommand`), so mosh-server binds twice, to the
/// SSH connection's address and then to any, and a full range prints five lines (mosh 1.4.0,
/// `network/network.cc:273`, 283, 348-350; `frontend/mosh-server.cc:368-371`):
///
///     Failed binding to 127.0.0.1:60010
///     Error binding to IP 127.0.0.1: bind: <strerror>
///     Failed binding to :::60010            (the any address; 0.0.0.0 where IPv6 is off)
///     Error binding to any interface: bind: <strerror>
///     Network exception: bind: <strerror>
///
/// `strerror` is in the host's own language (`network/network.h:65-68`), so only the literal
/// "Failed binding to" is matched (review LC-17). It is printed for every bind that fails, so a
/// full range is the likely cause, not a certain one: the banner keeps mosh's own lines beside
/// this message.
enum PortRangeFull {
    /// mosh's own words at the start of the line of every failed bind (`network.cc:348`).
    static let marker = "Failed binding to"

    /// mosh-server's range when the host's settings name none (`network/network.h:136-137`).
    static let defaultRange = "60001:60999"

    /// The banner's first sentences when `output` (what a server start that failed printed) has a
    /// line that starts with "Failed binding to"; nil for any other failure. `host` is the name
    /// the list shows, `range` the host's UDP ports (nil: mosh's default range).
    static func message(output: String, host: String, range: UDPPortRange?) -> String? {
        // Through the pty a line ends in "\r\n", one Character in Swift: `isNewline` covers it.
        let failedBind = output.split(whereSeparator: { $0.isNewline })
            .contains { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(marker) }
        guard failedBind else { return nil }
        let rangeText = range?.argument ?? defaultRange
        return "No free UDP port on \(host) in \(rangeText). Each session uses one: end a session on this host, "
            + "or widen UDP ports in the host's settings."
    }

    /// Added in a fallback (S4, F1, L3): the old server still holds its port, because it is
    /// killed only after the new one has started (review M6-8), so with a full range that row is
    /// the one to end (review LC-17 item 2).
    static func fallbackNote(host: String) -> String {
        "The session that could not be resumed still holds one of its ports: end it on its row under \(host) "
            + "(\"Could not be resumed\"), then try again."
    }
}
