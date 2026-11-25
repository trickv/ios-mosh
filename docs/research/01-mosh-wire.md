# Research: mosh_wire

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

mosh-1.4.0 (2022-10-27) is still the latest release as of 2026-11-11. Master is 39 commits ahead, with commits up to 2026-03-22. None of those commits change the wire protocol: the .proto files have the same md5 on 1.3.2 and master, MOSH_PROTOCOL_VERSION=2 everywhere, and all timing and MTU constants are the same. Master does add OSC 8 hyperlink sequences to the server's hostbytes and switches mosh-server's internal startup to a pipe.

Wire format per datagram: an 8-byte big-endian nonce (bit63 = direction, 1 = TO_CLIENT; the low 63 bits are a per-process counter), then AES-128-OCB3 ciphertext with a 16-byte tag. The OCB nonce is 12 bytes: 4 zero bytes followed by the 8 wire bytes. There is no associated data.

The plaintext is: be16 timestamp, be16 timestamp_reply, be64 fragment id, be16 (final<<15 | frag_num), then a slice of zlib(Instruction protobuf). Instruction.diff carries a UserMessage (client to server) or a HostMessage (server to client). The HostMessage contains VT escape bytes made by Display::new_frame relative to the old_num state. So the client needs a mosh-compatible terminal emulator that keeps a framebuffer for each received state number.

Bootstrap: `ssh -n -tt host -- mosh-server new -c 256 -s [-p P] -l LANG=... [-- cmd]`, then parse `MOSH CONNECT <port> <22-char base64 key>`. Use the IP the SSH TCP connection actually reached.

Biggest finding for the "no background" design: upstream mosh cannot resume after the client process dies. On relaunch you must persist and restore the nonce/sequence counter, which is needed for crypto safety and for server roaming. You must also persist the sender and receiver state lists, otherwise you hit server-side asserts and stale targeting. Blink's mosh fork (branch mosh-1.4) does exactly this with restoration.proto.

Licence: GPLv3+ with an OpenSSL linking exception. COPYING.iOS is a promise not to enforce only the GPL-vs-App-Store-terms conflict.

## details

## 0. Versions
- Releases (gh release list): mosh-1.4.0 Latest 2022-10-27; 1.3.2.95rc2/rc1; 1.3.2 (2017-07-22). There is no release newer than 1.4.0.
- master is 39 commits ahead of 1.4.0, with the last commit on 2026-03-22. These touch the wire/network area:
  - C++17 port.
  - clang-format reformatting (whitespace only in network/crypto).
  - "Use pipe to communicate between client and server at startup" (4306b7c). This is internal to mosh-server: the child is released by closing a pipe instead of writing "\n" to the pty. It fixes an empty line at login and has no wire effect.
  - "client: drop NACL check".
  - "select: use SA_RESTART".
  - "prng: support getrandom & getentropy".
  - OSC 8 hyperlink support (#1360). On master the server's Display::new_frame now emits OSC 8 sequences inside hostbytes (terminaldisplay.cc lines 133-390: `frame.update_hyperlink(...)`).
- The protobuf files are byte-identical on 1.3.2 and master (same md5 for all three .proto files), and no .proto file appears in the 1.4.0...master diff.

## 1. Datagram layout (UDP payload). Integers are big-endian.
Sizes are in bytes.
```
off  len  field
0    8    nonce tail: BE uint64 = (direction<<63) | (seq & 0x7FFF_FFFF_FFFF_FFFF)
          direction: TO_SERVER=0, TO_CLIENT=1 (network.cc DIRECTION_MASK = 1<<63)
8    n    AES-128-OCB ciphertext of plaintext P (same length as P)
8+n  16   OCB tag (Session::ADDED_BYTES = 16 "final OCB block")
```
- OCB nonce (12 bytes): `00 00 00 00 || nonce tail`. From crypto.cc Nonce(uint64): `memset(bytes,0,4); memcpy(bytes+4,&htobe64(val),8)`. On the wire it is `cc_str()` = bytes+4..+8.
- No associated data: `ae_encrypt(ctx, nonce, pt, pt_len, NULL /*ad*/, 0, ct, NULL /*tag appended*/, AE_FINALIZE)`. The tag comes right after the ciphertext.
- Decrypt rejects len < 24: "Ciphertext must contain nonce and tag."
- Plaintext P (Packet::toMessage / Packet(Message)):
```
0   2   timestamp        BE uint16 (ms mod 65536; 0xFFFF reserved = "none", timestamp16() bumps 0xFFFF->0)
2   2   timestamp_reply  BE uint16 (0xFFFF = none)
4   8   fragment id      BE uint64 (transportfragment.cc network_order_string)
12  2   BE uint16 = (final<<15) | fragment_num (fragment_num <= 0x7FFF, fatal_assert)
14  ..  fragment contents = slice of zlib compress() output
```
- dos_assert(P.size() >= 4). Fragment(const string&) uses fatal_assert(size >= 10), which aborts the process, but only for authenticated input.
- Reassembly: concatenate the fragments in order, `uncompress()` (zlib format; Compressor BUFFER_SIZE = 2048*2048 = 4 MiB is the output limit), then parse `TransportBuffers.Instruction`.
- Sender (send_in_fragments) always sets every field:
  - `protocol_version = 2`
  - `old_num` = assumed receiver state num
  - `new_num`
  - `ack_num` = newest remote state num received
  - `throwaway_num` = sent_states.front().num (oldest state the peer must keep)
  - `diff`
  - `chaff` = 0..16 random bytes (`prng.uint8() % 17`)
- transportinstruction.proto (proto2, package TransportBuffers):
```
message Instruction { optional uint32 protocol_version=1; optional uint64 old_num=2; optional uint64 new_num=3;
  optional uint64 ack_num=4; optional uint64 throwaway_num=5; optional bytes diff=6; optional bytes chaff=7; }
```
- Client to server diff = `ClientBuffers.UserMessage { repeated Instruction instruction=1 }`.
  - Instruction has `extensions 2 to max`.
  - `extend Instruction { optional Keystroke keystroke=2; optional ResizeMessage resize=3; }`
  - `Keystroke { optional bytes keys=4 }`
  - `ResizeMessage { optional int32 width=5; optional int32 height=6 }`
- Server to client diff = `HostBuffers.HostMessage { repeated Instruction instruction=1 }`.
  - `extend Instruction { HostBytes hostbytes=2; ResizeMessage resize=3; EchoAck echoack=7 }`
  - `HostBytes { optional bytes hoststring=4 }`
  - `EchoAck { optional uint64 echo_ack_num=8 }`
- Encoding examples (I derived these by hand from the proto definitions):
  - keystroke "a" = `0A 05 12 03 22 01 61`
  - resize 80x24 = `0A 06 1A 04 28 50 30 18`
  - Instruction header for a version-2 packet starts `08 02 10 <old> 18 <new> 20 <ack> 28 <throw> 32 <len> <diff> 3A <len> <chaff>`
  - uint64(-1) is a 10-byte varint `FF FF FF FF FF FF FF FF FF 01`
- UserStream::diff_from merges consecutive bytes into one Keystroke and emits one Resize per resize event.
- Complete::diff_from (server) emits, in this order:
  1. EchoAck, if changed;
  2. Resize, if the framebuffer size differs from the reference state;
  3. HostBytes = `display.new_frame(true, existing.fb, current.fb)`, i.e. escape sequences that turn the old_num framebuffer into the new one.
- The client applies these to its own Terminal::Complete for that state (completeterminal.cc apply_string). `assert(terminal_to_host.empty()) /* server never interrogates client terminal */`.
- Hostbytes may contain:
  - OSC 0/1/2 title;
  - `ESC]52;c;<base64>BEL` when the server framebuffer's clipboard changed (1.4.0+). The server only captures the `52;c;` form, and OSC_put caps the string at MAXIMUM_CLIPBOARD_SIZE = 16*1024 chars;
  - BEL;
  - `ESC[?5h/l`;
  - SGR including truecolor (1.4.0+);
  - OSC 8 (master only).
- Fragmentation (Fragmenter::make_fragments):
  - Fragment payload = MTU - 12 (Connection::ADDED_BYTES: 8 nonce + 4 timestamps) - 16 (OCB) - 10 (fragment header).
  - next_instruction_id starts at 0 and is incremented whenever any of old/new/ack/throwaway/chaff/protocol_version or the MTU changes. The first id is therefore 1. A retransmission of an identical instruction reuses the id.
  - Receiver (FragmentAssembly) keeps only ONE in-progress id. A fragment with a different id discards the partial assembly. The total is known only when the final fragment arrives.
- Receive buffer: Session::RECEIVE_MTU = 2048. MSG_TRUNC throws "Received oversize datagram".

## 2. Constants and timers (1.4.0; identical on 1.3.2 and master)
network.h:
- MOSH_PROTOCOL_VERSION = 2 ("bumped for echo-ack"). A mismatch throws "mosh protocol version mismatch".
- DEFAULT_SEND_MTU = 500. This is the fallback, also used after EMSGSIZE.
- DEFAULT_IPV4_MTU = 1280, IPV4_HEADER_LEN = 28, so MTU = 1252. DEFAULT_IPV6_MTU = 1280, IPV6_HEADER_LEN = 64, so MTU = 1216. Max datagram = MTU, which leaves 1214 (v4) / 1178 (v6) bytes of zlib data per fragment.
- MIN_RTO = 50 ms, MAX_RTO = 1000 ms.
- PORT_RANGE_LOW = 60001, PORT_RANGE_HIGH = 60999.
- SERVER_ASSOCIATION_TIMEOUT = 40000. PORT_HOP_INTERVAL = 10000. MAX_PORTS_OPEN = 10. MAX_OLD_SOCKET_AGE = 60000.
- CONGESTION_TIMESTAMP_PENALTY = 500 ms.

transportsender.h:
- SEND_INTERVAL_MIN = 20, SEND_INTERVAL_MAX = 250, ACK_INTERVAL = 3000, ACK_DELAY = 100, SHUTDOWN_RETRIES = 16, ACTIVE_RETRY_TIMEOUT = 10000.
- SEND_MINDELAY defaults to 8 ms. The client calls `set_send_delay(1)`.
- sent_states is capped at 32; above that it erases the element 16 from the end. Receiver received_states is capped at 1024, with a 15000 ms quench timer.
- Prospective resend: use a diff from the known (acked) state if it is <= the proposed diff, or if it is < 1000 bytes and grows by < 100 bytes.

Other:
- completeterminal.h ECHO_TIMEOUT = 50.
- Server timeout_if_no_client = 60000: "No connection within 60 seconds".
- Client: "Connecting..." after 250 ms; "Timed out waiting for server..." and shutdown at 15000 ms while still_connecting (remote state num == 0). Notification server_late > 6500 ms ("Last contact"), reply_late > 10000 ms. After 60 s the countup refresh slows to ACK_INTERVAL.
- Client NetworkException backoff: sleep 0.2 s. Server spin(): after 10 errors, sleep 0.1 s.

Formulas:
- Timestamps: ms from CLOCK_MONOTONIC (CLOCK_MONOTONIC_RAW on Apple, because MONOTONIC can go backwards after suspend, ticket #1014). timestamp16 = ms % 65536, with 0xFFFF mapped to 0.
- new_packet: if a timestamp was received < 1000 ms ago, `timestamp_reply = saved_ts + (now - received_at)`, used once. Otherwise 0xFFFF.
- On receive: if ts != 0xFFFF, save it. On ECN CE (`tos & 3 == 3`), `saved_timestamp -= 500`.
- If ts_reply != 0xFFFF: `R = (now16 - ts_reply) mod 65536`; samples with R >= 5000 are ignored. First sample: SRTT = R, RTTVAR = R/2. Then RTTVAR = 3/4 RTTVAR + 1/4 |SRTT - R| and SRTT = 7/8 SRTT + 1/8 R. Initial SRTT = 1000, RTTVAR = 500.
- RTO: `timeout() = clamp(ceil(SRTT + 4*RTTVAR), 50, 1000)`.
- send_interval: `clamp(ceil(SRTT/2), 20, 250)`, "roughly two frames per RTT".
- calculate_timers:
  - `pending_data_ack` sets next_ack_time to at most now + 100.
  - If current != last sent: `next_send = max(mindelay_clock + SEND_MINDELAY, last_sent.ts + send_interval)`.
  - Else if current != assumed receiver state and last_heard + 10000 > now: `last_sent.ts + send_interval`.
  - Else if current != acked state and recently heard: `last_sent.ts + timeout() + ACK_DELAY`.
  - Else never.
  - During shutdown, or when ack_num == UINT64_MAX: `next_ack = last_sent.ts + send_interval`.
- Empty ack: every ACK_INTERVAL (3 s), new_num = last + 1 (UINT64_MAX during shutdown). This is effectively the keepalive.
- Assumed receiver state = the newest sent state whose age is < timeout() + ACK_DELAY.

Socket options and roaming:
- `IP_MTU_DISCOVER = IP_PMTUDISC_DONT` where available; `IP_TOS = 0x02` (ECT); `IP_RECVTOS`.
- Server socket: binds the first free port in [60001..60999] or the -p range. It tries the -i/-s IP first, then any address. For an in6addr_any bind it sets `IPV6_V6ONLY = 0`.
- Client port hopping: in send(), if `now - last_port_choice > 10000 && now - last_roundtrip_success > 10000`, open a new socket of the same family (hop_port). Old sockets stay open for receiving, at most 10. All sockets are pruned to the newest once it is older than 60 s. last_roundtrip_success = timestamp of the newest state the server has acked.
- Server targeting: in recv_one, only packets with `seq >= expected_receiver_seq` update the timestamps and RTT and set `remote_addr` = the packet's source ("only client can roam").
- Server stops sending (`has_remote_addr = false`, "Server now detached from client") if nothing has been heard for 40 s. wait_time() then returns INT_MAX, so the server sleeps until a packet arrives.

## 3. Bootstrap recipe (scripts/mosh.pl, mosh-server.cc)
1. mosh.pl runs `ssh -n -tt [-4/-6 only for remote-ip=remote] [-S none -o ProxyCommand='mosh --family=F --fake-proxy -- %h %p'] user@host -- "mosh-server 'new' '-c' '<colors>' '-s' ['-p' 'P[:P2]'] ['-l' 'LANG=..'...] ['--' cmd...]"`.
   - The server command itself is NOT quoted, so a prefix like `MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server` or an absolute path works.
   - colors comes from `mosh-client -c` (terminfo color count); use 256.
   - `-l` is repeated for each of LANG LANGUAGE LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION LC_ALL that is set locally.
   - The default bind is `-s` (bind to the SSH_CONNECTION local IP). `--bind-server=any` omits it; `--bind-server=IP` sends `-i IP`.
2. Parse the ssh stdout+stderr stream line by line:
   - `^MOSH IP (\S+)\s*$` (only from the fake proxy);
   - `^MOSH SSH_CONNECTION ` with 6 words, word 4 = server IP (remote mode);
   - `^MOSH CONNECT (\d+?) ([A-Za-z0-9/+]{22})\s*$`, which is the success line. `\s*` tolerates the `\r` added by the pty.
   - Every other line is printed to the user (motd and errors).
   - If stdin is a tty, mosh-server prints "\r\n" before the CONNECT line.
3. The target IP is the numeric address that the TCP connection to sshd actually reached (the fake ProxyCommand resolves, connects and prints MOSH IP). A native app should take this from its own SSH socket's peer address.
4. mosh-client gets env `MOSH_KEY=<22 chars>`, `MOSH_PREDICTION_DISPLAY`, optionally `MOSH_NO_TERM_INIT`, and args `ip port`.
5. mosh-server new (getopt "@:i:p:c:svl:"):
   - Options: -i IP; -p port/range; -s (SSH_CONNECTION field 3, strips "::ffff:"; if absent, warns and binds any); -c colors; -v; -l NAME=VALUE; -@ swallows its argument. Unknown options print usage but do not exit.
   - Locale: if the native locale is not UTF-8, the server clears the locale variables, applies the -l values and retries. If it still fails: "mosh-server needs a UTF-8 native locale to run." plus `locale` output, exit 1.
   - Then: print `MOSH CONNECT <port> <key>`; fork (the parent prints the version banner and "[mosh-server detached, pid = N]" to stderr, then exits); redirect stdio to /dev/null (unless -v); forkpty using the ssh pty's winsize (80x24 if there is no tty).
   - Child environment: `TERM=xterm-256color` if colors == 256, otherwise `xterm`; `NCURSES_NO_UTF8_ACS=1`; unset STY; IUTF8; chdir $HOME. With no command: motd and a login shell `-$SHELL`.
   - The child BLOCKS until the first client state arrives (1.4.0: the server writes "\n" to the pty; master: pipe).
   - Server exits if no client state arrives within 60 s.
6. Server lifetime:
   - `MOSH_SERVER_NETWORK_TMOUT` (seconds; default 0 = never). Idle shutdown when time since last remote state >= timeout.
   - `MOSH_SERVER_SIGNAL_TMOUT` (seconds; default 0). SIGUSR1 triggers idle shutdown if the timeout is 0 or has been exceeded.
   - With the defaults, a server whose client is gone for days lives forever (asleep). SIGTERM/SIGINT start a shutdown, or exit immediately if there is no remote address.
   - The child closing the pty (EIO/EOF) starts a shutdown.

Failure modes:
- mosh-server not found or not in the non-interactive PATH: there is no CONNECT line, so "Did not find mosh server startup message. (Have you installed mosh on your server?)". The shell prints "command not found" with exit 127. Offer a configurable server path or prefix.
- Bad port range: "Bad UDP port range" (mosh.pl maps it to "Server does not support UDP port range option" when using P:P2).
- Locale error as above. Fix by sending `-l LANG=C.UTF-8` / `en_US.UTF-8`.
- UDP blocked: the client never hears back. 15 s "Timed out waiting for server..."; the server exits after 60 s because there has been no connection.
- IPv6: family is prefer-inet by default. The server binds the SSH_CONNECTION address (v6 is fine). The client socket family follows the target address; client MTU 1216 for v6. FreeBSD rejects IP_RECVTOS on v6.
- Pty size: the client's initial remote state 0 is `Complete(cols, rows)` of the client, while the server's state 0 is the pty size. If those differ but the size after the client's resize equals the server's state 0, no Resize instruction is sent. So request the SSH pty at exactly the client's initial cols and rows. (This is my own inference from diff_from.)

## 4. Compatibility 1.3.2 / 1.4.0 / master
- Same protocol version (2), same protos, same constants and framing, so any combination interoperates.
- 1.3.2 server: no OSC 52 forwarding ("52;c" absent from terminaldisplay.cc) and no truecolor.
- 1.4.0: OSC 52, truecolor SGR, latest-consecutive-resize fix, CLOCK_MONOTONIC_RAW on Apple, syslog.
- master: OSC 8 in hostbytes, so the client emulator must parse or ignore OSC 8. Startup changes are internal only. 1.3.2 also reads MOSH_SERVER_SIGNAL_TMOUT.

## 5. Crypto
- Session: `ae_init(ctx, key, 16, 12 /*nonce*/, 16 /*tag*/)`, i.e. AES-128, OCB3, 96-bit nonce, 128-bit tag.
- ocb_internal.cc is the "OCB Version 3 Reference Code (Optimized C)" by Krovetz (OCB_KEY_LEN 16, OCB_TAG_LEN 16) on OpenSSL, Nettle or Apple CommonCrypto AES. The configure option `openssl-with-openssl-ocb` uses `EVP_aes_128_ocb` with SET_IVLEN 12 / SET_TAG 16, which shows it is the same algorithm as OpenSSL's RFC 7253 OCB.
- Key: 16 bytes, printed as 22-char standard base64 with the "==" stripped. Decode with `key + "=="`. The key must round-trip.
- Nonce uniqueness: `Crypto::unique()` is a process-global counter starting at 0, incremented for every Packet and throwing fatal "Counter wrapped". The client and server share the key; the direction bit separates the two nonce spaces (tests/nonce-incr.cc checks 4M unique nonces). The key is killed after 2^47 encrypted blocks.
- A restarted client that reuses its key MUST resume seq above every value used before. Otherwise it reuses an OCB nonce, which is catastrophic, and the server ignores its packets for targeting.
- Receiver rules, quoted from code:
  - Decrypt failure throws a non-fatal CryptoException "Packet failed integrity check." The loop catches it: the client shows "Crypto exception" and the server logs it.
  - `dos_assert(p.direction == (server ? TO_SERVER : TO_CLIENT)) /* prevent malicious playback to sender */`
  - `if (p.seq < expected_receiver_seq) { /* don't use (but do return) out-of-order packets for timestamp or targeting */ return p.payload; } expected_receiver_seq = p.seq + 1;`. So old or replayed packets are still delivered to the transport.
  - Transport idempotency: drop if `inst.new_num` is already in received_states. Drop if `old_num` is not found ("this is security-sensitive and part of how we enforce idempotency"). Otherwise apply process_throwaway_until(throwaway_num), check the 1024 cap, apply the diff to a copy of the reference state and insert it sorted. Only an append at the end updates ack_num and last_heard.
  - process_acknowledgment_through(ack) erases sent states with num < ack, but only if ack matches a state still held.
- Shutdown: start_shutdown sends instructions with new_num = UINT64_MAX. The peer stores it and acks UINT64_MAX. shutdown_acknowledged = sent_states.front().num == UINT64_MAX. counterparty_shutdown_ack_sent = last ack sent == UINT64_MAX. The sender gives up after 16 tries or 10 s.
- Client quit sequence: escape key 0x1E (Ctrl-^), then "." (MOSH_ESCAPE_KEY overrides it).
- Client startup: the first state pushes `Resize(cols, rows)`. That gives old_num 0, new_num 1, ack 0, throwaway 0. SIGWINCH pushes a Resize.

## 6. Licence
- COPYING: GPLv3. Source headers say "either version 3 of the License, or (at your option) any later version", plus an OpenSSL linking exception.
- COPYING.iOS (verbatim): "The Mosh developers are aware that the terms of service that apply to apps distributed via Apple's App Store services may conflict with rights granted under Mosh's license, the GNU General Public License, version 3. The Mosh copyright holders do not wish this conflict to prevent the otherwise-compliant distribution of Mosh-derived apps via the App Store. Therefore, we have committed not to pursue any license violation that results solely from the conflict between the GPLv3 and the Apple App Store terms of service. In other words, as long as you comply with the GPL in all other respects, including its requirements to provide users with source code and the text of the license, we will not object to your distribution of Mosh through the App Store."
- What it covers: only a promise not to enforce against the GPL-vs-App-Store-ToS conflict, and only for "Mosh-derived apps". It is not a relicensing. The full GPL still applies otherwise: corresponding source, licence text, and a GPL licence for the whole derived app.
- A Swift port or translation of mosh code is likely a derived work. A clean-room implementation from a protocol description may not be, but that is a legal judgement.
- The OCB reference code is under a permissive ISC-style licence plus Rogaway's patent grant.

## 7. Test assets
- src/tests/ocb-aes.cc: draft-krovetz-ocb-03 Appendix A vectors with key 000102..0F and nonce 000102..0B, for example empty AD and PT give tag `197B9C3C441D3C83EAFB2BEF633B9182`. Also an iterative test: zero key, nonce 11 zero bytes + i, i = 0..127, three encryptions each, final tag `B2B41CBF9B05037DA7F16C24A35C1C94`. These test plain 96-bit-nonce OCB.
- RFC 7253 Appendix A vectors (nonce BBAA99887766554433221100 family, tag len 128) should also apply to the same algorithm. They were not in the repo, so I did not check them.
- src/tests/encrypt-decrypt.cc: random sessions, 256 messages each of length < 2048-16, plus bad-decrypt checks.
- src/tests/base64.cc with base64_vector.h: key encoding vectors and bad keys.
- nonce-incr.cc.
- src/examples/encrypt.cc (`encrypt NONCE` < stdin, prints the key on stderr) and decrypt.cc (`decrypt KEY`) can produce golden datagrams on the Linux box.
- src/examples/ntester.cc.
- e2e tests: e2e-test, server-network-timeout.test, server-signal-timeout.test, window-resize.test, network-no-diff.test.
- TESTS = ocb-aes encrypt-decrypt base64 nonce-incr local.test + display tests.
- Running mosh-server 1.4.0 with `-v` (verbose: stdio not closed; logs "[ts] Sent [a=>b] id, frag, ack, throwaway, len, frame rate, timeout, srtt") gives a live interop oracle.

## findings

### 1. releases

**topic:** releases

**claim:** No mosh release newer than 1.4.0 exists. master is 39 commits ahead (latest 2026-03-22, OSC 8). The protobuf files did not change.

#### evidence

gh release list -R mobile-shell/mosh: 'mosh-1.4.0 Latest 2022-10-27'; compare mosh-1.4.0...master lists no src/protobufs/*.proto. md5 of the 3 protos is identical on 1.3.2 and master.

**confidence:** high

### 2. crypto params

**topic:** crypto params

#### claim

AES-128-OCB3 with a 12-byte nonce and a 16-byte tag, no associated data. The tag is appended to the ciphertext and the 8-byte nonce tail is prepended.

#### evidence

src/crypto/crypto.cc: 'ae_init( ctx, key.data(), 16, 12, 16 )'; encrypt: 'return plaintext.nonce.cc_str() + text;'; ae_encrypt(... NULL /*ad*/, 0 ...)

**confidence:** high

### 3. nonce layout

**topic:** nonce layout

**claim:** The 12-byte nonce is 4 zero bytes followed by a BE uint64 of (direction<<63 | seq). Only the last 8 bytes are sent.

#### evidence

crypto.cc Nonce::Nonce(uint64_t): 'memset( bytes, 0, 4 ); memcpy( bytes + 4, &val_net, 8 );'; network.cc 'uint64_t direction_seq = (uint64_t( direction == TO_CLIENT ) << 63) | (seq & SEQUENCE_MASK);'

**confidence:** high

### 4. plaintext header

**topic:** plaintext header

**claim:** The plaintext starts with a BE uint16 timestamp and a BE uint16 timestamp_reply (0xFFFF = none), followed by the fragment.

**evidence:** network.cc Packet::Packet: 'timestamp = be16toh( data[ 0 ] ); timestamp_reply = be16toh( data[ 1 ] );'

**confidence:** high

### 5. fragment header

**topic:** fragment header

#### claim

The fragment header is 10 bytes: BE uint64 id, then BE uint16 (final<<15 | fragment_num). The contents are a slice of zlib compress() of the serialized Instruction.

#### evidence

transportfragment.cc tostring: 'uint16_t combined_fragment_num = ( final << 15 ) | fragment_num;'; make_fragments: 'get_compressor().compress_str( inst.SerializeAsString() )'

**confidence:** high

### 6. replay/out-of-order

**topic:** replay/out-of-order

#### claim

Packets with seq < expected_receiver_seq are still delivered to the transport but do not update timestamps, RTT or the server's target address. Transport idempotency drops duplicate new_num values and unknown old_num values.

#### evidence

network.cc recv_one: 'if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */ return p.payload; }'; networktransport-impl.h: 'return; /* this is security-sensitive and part of how we enforce idempotency */'

**confidence:** high

### 7. timers

**topic:** timers

#### claim

SEND_INTERVAL_MIN=20, SEND_INTERVAL_MAX=250, ACK_INTERVAL=3000, ACK_DELAY=100, SHUTDOWN_RETRIES=16, ACTIVE_RETRY_TIMEOUT=10000, SEND_MINDELAY default 8 (client sets 1). send_interval = clamp(ceil(SRTT/2), 20, 250).

#### evidence

src/network/transportsender.h constants; transportsender-impl.h 'SEND_MINDELAY( 8 )', send_interval(); stmclient.cc 'network->set_send_delay( 1 );'

**confidence:** high

### 8. network constants

**topic:** network constants

#### claim

MTU is 1280 minus 28 (IPv4) or minus 64 (IPv6); fallback 500. RTO is clamped to [50,1000]. Port range 60001-60999. Server association timeout 40 s, port hop 10 s, at most 10 ports, old sockets kept up to 60 s, ECN penalty 500 ms.

**evidence:** src/network/network.h static const values

**confidence:** high

### 9. RTT

**topic:** RTT

#### claim

RTT uses RFC 6298-style SRTT/RTTVAR with alpha 1/8 and beta 1/4. Initial SRTT=1000 and RTTVAR=500. Samples >= 5000 ms are ignored. RTO = ceil(SRTT+4*RTTVAR).

**evidence:** network.cc recv_one 'if ( R < 5000 )'; constructor 'SRTT( 1000 ), RTTVAR( 500 )'; timeout()

**confidence:** high

### 10. bootstrap

**topic:** bootstrap

#### claim

mosh.pl runs: ssh -n -tt [ProxyCommand fake-proxy] host -- mosh-server 'new' '-c' N '-s' ['-p' P] ['-l' VAR=VAL]... ['--' cmd]. It then parses the regex ^MOSH CONNECT (\d+?) ([A-Za-z0-9/+]{22})\s*$ and passes the key to mosh-client in MOSH_KEY.

#### evidence

scripts/mosh.pl (mosh-1.4.0): 'my @sshopts = ( '-n' ); ... push @sshopts, '-tt'; ... my @server = ( 'new' ); push @server, ( '-c', $colors ); push @server, @bind_arguments;' and '$ENV{ 'MOSH_KEY' } = $key;'

**confidence:** high

### 11. server lifetime

**topic:** server lifetime

#### claim

MOSH_SERVER_NETWORK_TMOUT and MOSH_SERVER_SIGNAL_TMOUT are in seconds and default to 0. With the defaults a detached server lives forever. The server exits if no client state arrives within 60 s, and the shell child is not started until the first client state arrives.

#### evidence

mosh-server.cc run_server getenv('MOSH_SERVER_NETWORK_TMOUT'), 'network_timeout_ms = network_timeout * 1000'; serve(): 'static const uint64_t timeout_if_no_client = 60000;' and 'Tell child to start login session.'

**confidence:** high

### 12. TERM/locale

**topic:** TERM/locale

#### claim

The child gets TERM=xterm-256color if -c 256, otherwise xterm, plus NCURSES_NO_UTF8_ACS=1, and STY is unset. The server requires a UTF-8 locale and falls back to the client's -l variables.

**evidence:** mosh-server.cc: 'setenv( "TERM", (colors == 256) ? color_term : default_term, true )'; 'mosh-server needs a UTF-8 native locale to run.'

**confidence:** high

### 13. diff semantics

**topic:** diff semantics

#### claim

The server's diff is a HostMessage whose hostbytes are terminal escape sequences from Display::new_frame relative to the old_num framebuffer. The client must apply them to a mosh-compatible emulator state for each state number.

#### evidence

src/statesync/completeterminal.cc diff_from: 'string update = display.new_frame( true, existing.get_fb(), terminal.get_fb() );'; apply_string: 'act( ...hostbytes ).hoststring() )'

**confidence:** high

### 14. OSC52

**topic:** OSC52

#### claim

The server captures only OSC '52;c;' (at most 16 KiB) and re-emits '\033]52;c;<data>\007' in hostbytes when the clipboard changes. This is new in 1.4.0; 1.3.2 lacks it.

#### evidence

terminalfunctions.cc OSC_dispatch '52;c;'; terminaldisplay.cc 'frame.append( "\033]52;c;" ) ... frame.append( '\007' )'; MAXIMUM_CLIPBOARD_SIZE = 16 * 1024; 1.4.0 release notes 'Support OSC 52 clipboard copy integration'

**confidence:** high

### 15. shutdown

**topic:** shutdown

**claim:** Shutdown sends new_num=UINT64_MAX and treats an ack_num of UINT64_MAX as acknowledgment. It gives up after 16 tries or 10 s.

**evidence:** transportsender-impl.h send_empty_ack 'if ( shutdown_in_progress ) { new_num = uint64_t( -1 ); }'; shutdown_ack_timed_out()

**confidence:** high

### 16. resume after kill

**topic:** resume after kill

#### claim

Upstream mosh-client cannot resume a session after the process dies. Blink's fork adds a restoration.proto (seq, current_state_patch, received_states, sent_states) and a restore Transport constructor for this purpose.

#### evidence

blinksh/mosh branch mosh-1.4: src/protobufs/restoration.proto 'message Context { required uint64 seq = 1; required bytes current_state_patch = 2; repeated TimestampedState received_states = 3; repeated TimestampedState sent_states = 4; }'; networktransport.h restored_sent_states/restored_received_states

**confidence:** high

### 17. licence

**topic:** licence

#### claim

Mosh is GPLv3+ with an OpenSSL exception. COPYING.iOS only promises not to pursue violations that come solely from the GPLv3-vs-App-Store-ToS conflict; all other GPL obligations, including source availability, remain.

#### evidence

COPYING.iOS: 'we have committed not to pursue any license violation that results solely from the conflict between the GPLv3 and the Apple App Store terms of service... as long as you comply with the GPL in all other respects'

**confidence:** high

### 18. test vectors

**topic:** test vectors

#### claim

The repo's OCB tests use draft-krovetz-ocb-03 Appendix A vectors with a 96-bit nonce and a 128-bit tag, plus an iterative test whose final tag is B2B41CBF9B05037DA7F16C24A35C1C94.

#### evidence

src/tests/ocb-aes.cc: '/* Test vectors from http://tools.ietf.org/html/draft-krovetz-ocb-03#appendix-A */' and 'AlignedBuffer correct( TAG_LEN, "\xB2\xB4\x1C\xBF...'

**confidence:** high

## recommendations

- Implement AES-128-OCB3 in Swift on top of CommonCrypto AES-ECB (CryptoKit has no OCB), or vendor the permissively licensed Krovetz OCB C code. Validate it against src/tests/ocb-aes.cc vectors, the iterative tag, and RFC 7253 Appendix A, and do round-trip tests against src/examples/encrypt/decrypt built on the Linux box.
- Persist a write-ahead nonce high-water mark in the Keychain or a protected file: reserve seq in blocks (e.g. +65536) before sending, and resume above the reserved value after relaunch. This keeps OCB safe and makes the server accept the new source address (it only roams when seq >= expected).
- Persist full transport state per session (key, ip, port, seq, sent_states with UserStream contents, received_states with server framebuffers and nums, ack_num, current state). Model it on Blink's restoration.proto, write it synchronously on scenePhase .background, and do not send new states after persisting.
- On relaunch, open a fresh UDP socket (a new source port is fine), restore the transport and immediately send an empty ack or the pending state. Never send old_num 0 or new_num values lower than ones already sent.
- Bootstrap over an in-app SSH library: exec `[env prefix] mosh-server new -c 256 -s -l LANG=en_US.UTF-8 [-p range]` with a pty whose size is exactly the client's initial cols and rows. Parse the CONNECT regex, tolerating \r. Use the SSH socket's numeric peer IP as the UDP target. Close SSH right after parsing.
- Allow a configurable mosh-server path and prefix (e.g. /opt/homebrew/bin/mosh-server, or MOSH_SERVER_NETWORK_TMOUT=N to cap abandoned sessions). Show the user the captured ssh output when there is no CONNECT line.
- Build the client-side terminal model to mosh's Terminal::Complete semantics (port or reimplement mosh's framebuffer and the subset of escapes Display::new_frame emits). It must handle OSC 0/1/2, OSC 52;c (base64 to UIPasteboard), BEL, DECSCNM, truecolor SGR, and ignore or handle OSC 8 from master servers.
- Implement the timers exactly (send_interval, ACK_INTERVAL keepalive, port hop after 10 s with no roundtrip, keep up to 10 receive sockets) and the shutdown handshake only on explicit user exit, never on backgrounding.
- Integration-test against the local mosh-server 1.4.0 with -v (verbose transport logs), using MOSH_SERVER_NETWORK_TMOUT for cleanup. Simulate an app kill by killing the Swift client process, restoring and reconnecting.

## risks

- mosh-server is built with asserts enabled (configure.ac has no NDEBUG). A restored client whose UserStream states are not a prefix extension of what the server last received will trip assert() in UserStream::subtract/diff_from and abort mosh-server, destroying the user's session. Persistence has to be exact.
- Reusing the key with a reset seq counter is OCB nonce reuse (catastrophic). Separately, the server ignores such packets for targeting and keeps replying to the dead address/port.
- If the client's emulator diverges from mosh's terminal semantics (wcwidth, wrap, scroll regions), hostbytes diffs applied to the old_num state will corrupt the screen until those cells are rewritten.
- Pty size mismatch between the SSH bootstrap pty and the client's initial state 0 can suppress the Resize instruction and garble rendering.
- The GPLv3 obligations remain even with COPYING.iOS. Any port or translation of mosh source makes the app GPL and requires publishing full corresponding source. Restrictions from TestFlight or App Store distribution beyond that ToS conflict are not covered.
- The server's fatal_assert on fragments shorter than 10 bytes after decryption, and asserts in FragmentAssembly (e.g. differing duplicate fragment), mean a buggy client can crash the server. Fuzz the Swift encoder against a local server.
- iOS may change the network path (Wi-Fi/cellular) while suspended. Roaming works only if seq continuity is kept. NAT rebinding is handled by the server roaming on any authenticated packet with a fresh seq.
- Blink's restoration code is GPL. Reading it for design is fine, but copying code brings in the GPL as well.

## unverified

- That RFC 7253 Appendix A vectors pass unchanged against mosh's ocb_internal.cc. This is inferred from the OCB3 lineage and from the openssl-with-openssl-ocb build option, but not executed.
- Whether distro mosh-server binaries (Debian/Ubuntu/Homebrew) are actually compiled without NDEBUG. I only checked that configure.ac does not define it.
- The exact behaviour of Blink's restore path, e.g. how it picks old_num/new_num after restore and whether it reserves seq ahead. I only read restoration.proto and the constructor signature.
- Byte-level protobuf encoding examples (e.g. 0A 05 12 03 22 01 61) were derived by hand from the .proto definitions, not captured from a real mosh run.
- The 1.4.0 .proto md5 was not computed directly. It is inferred from the protos being absent from the 1.4.0...master diff and identical on 1.3.2 and master.
- Whether a later SSH-based reconnect can recover a session if the persisted state is lost. Upstream has no such mechanism; the only option would be starting a new mosh-server.

