# Research: mosh_resume

> Addresses, ports and details of the author's own network were removed before publication.

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

From the mosh-1.4.0 source, a restarted client can resume a session only if it has kept the following. (a) A UDP seq/nonce counter that is strictly higher than any it used before. If the counter is reused, AES-OCB nonces repeat. Also, the server ignores packets with seq < expected_receiver_seq for roaming and keep-alive purposes, so it never re-targets the new socket. (b) The exact remote Terminal::Complete state (display-equivalent) for every ack_num it may have sent at or above the server's last throwaway. The server diffs only from its acked front state or from recently sent states. It deletes every state below the highest ack it received, and drops any diff whose old_num the client does not hold, with no error. (c) Its own UserStream log. Every new input state must have a new_num greater than all nums sent before, and must extend the content of the last state it ever sent. Otherwise the server either drops the input without notice (duplicate or out-of-order num) or hits assert() in UserStream::diff_from. asserts are compiled in: there is no NDEBUG in configure.ac, and the packaged 1.4.0 binary contains the assert strings. A failed assert calls abort() and kills mosh-server, so the session is lost. (d) An acked front num at least as high as any throwaway_num it sent. If it is lower, the server cannot find the reference state and ignores all client input from then on. Blink (blinksh/mosh branches mosh-1.4 and mosh+blink, iosclient.cc + restoration.proto) uses freeze-then-snapshot. On app suspend it writes Esc Ctrl-Z, serialises seq, all received_states and sent_states (init_diff), and current_state, then exits the thread without sending. That is sound only if no packet is ever sent after the snapshot is taken and the snapshot is never reused. A write-ahead design is also sound and costs almost nothing: persist input before sending it, and persist a remote state before acking it, inside the existing 100 ms ACK_DELAY. Losing the remote state can be recovered with a client-only trick: send a resize, then accept the full-repaint diff the server sends after it.

## details

## 0. Sources read
Files are at mobile-shell/mosh tag mosh-1.4.0 unless noted:
- src/network/networktransport-impl.h
- src/network/transportsender{.h,-impl.h}
- src/network/network.cc / network.h
- src/network/transportfragment.cc
- src/crypto/crypto.cc
- src/statesync/user{.h,.cc}
- src/statesync/completeterminal{.h,.cc}
- src/terminal/terminalframebuffer{.h,.cc}, terminaldisplay.cc, terminaldisplayinit.cc
- src/frontend/mosh-server.cc
- configure.ac

Master vs 1.4.0 (39 commits, last one 2026-03-22): mostly clang-format, C++17 and typedef modernisation. The one semantic change is "Add OSC8 hyperlink support" (06182189 and follow-ups, 2026-03-22), which changes cell state and the Display output, so a client emulator must parse OSC 8 when the server is built from master. Also 4306b7cd "Use pipe to communicate between client and server at startup", which affects bootstrap only. Transport and sync logic is unchanged.

## 1. Protocol mechanics (quoted)

### Client datagram layer (network.cc)
- The nonce is `seq( Crypto::unique() )`, a process-static counter starting at 0 that throws "Counter wrapped" on wrap. The direction bit is bit 63 (`DIRECTION_MASK = uint64_t(1) << 63`).
- recv_one:
  - `dos_assert( p.direction == (server ? TO_SERVER : TO_CLIENT) )`.
  - `if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */ return p.payload; }`. The payload is still processed by the transport. However, timestamps, `has_remote_addr = true`, `last_heard` and the roaming update `remote_addr = packet_remote_addr` are all skipped.
  - Otherwise `expected_receiver_seq = p.seq + 1`.
- The server detaches after `SERVER_ASSOCIATION_TIMEOUT = 40000` ms (`has_remote_addr = false`) and then sends nothing.
- Consequence: a restarted client whose seq is at or below the old maximum is never roamed to and gets no replies until its seq passes the old maximum. Repeating a nonce under the same AES-128-OCB key (Session::encrypt) is also a cryptographic break.
- Timestamps (16-bit, `timestamp16()`) are only echoed back, and `if ( R < 5000 )` filters bogus RTT samples. Restarted timestamps are therefore harmless and do not need to be persisted.

### Fragments (transportfragment.cc)
- The client's `Fragmenter() : next_instruction_id( 0 )` increments for each new instruction.
- On the server, `FragmentAssembly::add_fragment`: `if ( current_id != frag.id )` it starts a new assembly. Otherwise, if that fragment index is already present, it runs `assert( fragments.at( frag.fragment_num ) == frag )`.
- get_assembly clears the fragments after a packet completes, so reusing an id after a complete packet is harmless. Reusing the id of a half-assembled multi-fragment instruction, with different content, aborts the server. Persist or jump next_instruction_id; this is cheap.

### Transport::recv (both sides)
The order of operations is:
1. `sender.process_acknowledgment_through( inst.ack_num() )`.
2. If `inst.new_num() == i->num` for any held state, `return` (duplicate dropped).
3. Look up old_num in received_states. If it is not found: `return; /* this is security-sensitive and part of how we enforce idempotency */`. This drop is silent and no ack is generated for it.
4. `process_throwaway_until( inst.throwaway_num() )` erases states with `num < throwaway_num`, then `fatal_assert( received_states.size() > 0 )`. A throwaway greater than every held num aborts the peer. A throwaway greater than old_num also invalidates the reference iterator. Invariant: throwaway_num ≤ old_num.
5. Queue limit: `if ( received_states.size() > 1024 )`. If `now < receiver_quench_timer`, the new state is discarded; otherwise `receiver_quench_timer = now + 15000` and the state is accepted. In practice that is one state per 15 s.
6. `new_state = *reference_state; new_state.num = inst.new_num(); apply_string(diff)`.
7. If any held num is greater than new_num, the state is inserted in sorted position and the function returns. It is not acked and not exposed as the latest state, so the server never processes it as input.
8. Otherwise `push_back`, `sender.set_ack_num( received_states.back().num )`, `remote_heard`, `set_data_ack`.

`get_remote_diff()` (used by the server for user input) runs `received_states.back().state.diff_from( last_receiver_state )`, then `subtract(&received_states.front().state)` on every state, then sets `last_receiver_state = back`.

### TransportSender
- sent_states: front is the known acked state, back is the last sent state.
- `process_acknowledgment_through(ack)` first checks that ack is present ("Ignore ack if we have culled the state"). If it is, it erases every sent state with `num < ack_num`.
- `add_sent_state` caps the list: `if ( sent_states.size() > 32 )` erase the 16th-from-last entry ("erase state from middle of queue"). Front is never removed.
- `update_assumed_receiver_state` takes the last sent state younger than `connection->timeout() + ACK_DELAY`. RTO is `SRTT + 4*RTTVAR`, clamped to [50, 1000] ms, and ACK_DELAY is 100. If no sent state is that young, front is used.
- `attempt_prospective_resend_optimization` often falls back to front (`resend_diff.size() <= proposed` or `<1000` and `<100` bytes longer).
- `send_in_fragments`: `old_num = assumed_receiver_state->num`, `ack_num = ack_num`, `throwaway_num = sent_states.front().num`.
- new_num:
  - `send_to_receiver` sends `back.num+1` if current_state differs from back, otherwise it resends `back.num`.
  - `send_empty_ack` also allocates a new num, `back.num + 1`, with an unchanged state.
  - `ACK_INTERVAL = 3000` ms: the server keeps sending an empty ack, and so creating a new sent state, every 3 s while it is associated.
- `rationalize_states` subtracts front from current_state and from every sent state, so content is always relative to front.
- Retransmission happens at `back.timestamp + send_interval` (20..250 ms) while the receiver is assumed behind. It happens at `back.timestamp + timeout + ACK_DELAY` while current differs from front, but only while `last_heard + ACTIVE_RETRY_TIMEOUT(10000) > now`.

### UserStream (user.cc)
- `subtract`: for each prefix event, `assert(!actions.empty()); assert(*i == actions.front()); pop_front`.
- `diff_from(existing)`: for each existing event, `assert( my_it != actions.end() ); assert( *i == *my_it );`, then serialises the remaining events as Keystroke and Resize instructions.
- `apply_string` appends events (`fatal_assert(ParseFromString)`).
- `operator==` compares the actions deque. `init_diff = diff_from(UserStream())` gives an exact round-trip.

### mosh-server serve()
- When `network.get_remote_state_num() != last_remote_num`, it runs `us.apply_string( network.get_remote_diff() )` and feeds each action to the terminal (only the last of consecutive Resizes goes to TIOCSWINSZ). It then calls `register_input_frame(last_remote_num, now)` and `set_current_state(terminal)`.
- Input bytes are therefore applied exactly once: the events in back beyond last_receiver_state.

### asserts
- configure.ac has no NDEBUG; it only adds hardening flags (`-D_FORTIFY_SOURCE=2`, `-fstack-protector-all`, PIE, relro).
- `strings /usr/bin/mosh-server` on the box (the distribution's mosh 1.4.0 package) contains "my_it != actions.end()", "*i == actions.front()", "!actions.empty()", "received_states.size() > 0", "fragments.at( frag.fragment_num ) == frag".
- A failed assert() means abort(), so mosh-server dies with the session and the shell gets SIGHUP. fatal_assert also aborts. dos_assert throws a non-fatal CryptoException (logged and ignored in serve()).

### Complete (completeterminal.cc)
- `diff_from(existing)`:
  1. An echoack instruction if echo_ack differs (`assert(get_echo_ack() >= existing.get_echo_ack())`).
  2. If the fb differs: a resize instruction if width or height differ, then `hostbytes = display.new_frame(true, existing.get_fb(), terminal.get_fb())`.
- `init_diff = diff_from(Complete(same w,h))`. It contains no resize instruction, so the restorer must create the Complete at the saved width and height.
- `apply_string` processes hostbytes through the emulator, resize via act(Resize), and echoack with `assert(inst_echo_ack_num >= echo_ack)`.
- `operator==` is `terminal == x.terminal && echo_ack == x.echo_ack`, where Emulator== is `fb == x.fb`. Framebuffer== covers rows, window_title, clipboard, bell_count and ds. Row== is `gen == x.gen && cells == x.cells`, and gen is a process-global counter (`static uint64_t gen_counter`), so a reconstructed state is never == to the original.
- On the client this does not matter: client-side Transport never compares RemoteState. The server computes diffs from its own copies, so all that matters is that the client fb is display-equivalent for applying escape strings.
- `compare()` (verbose debugging) checks only size, cells and cursor.

### Display::new_frame
- Order of output: bell (count differs); title/icon if `has_title && is_title_initialized && (!initialized || changed)`; OSC 52 clipboard if changed; reverse video ?5 if changed. Then, if the size differs: `"\033[r"` + `"\033[0m\033[H\033[2J"`, `initialized=false`, and every row is repainted. Then ?25 cursor visibility, the final cursor move, SGR, ?2004, mouse modes 1000–1003, ?1004, and mouse encoding.
- With the same size, the server assumes the client's cursor position equals `last.ds` cursor and its current SGR equals `last.ds.get_renditions()`.
- `Display(false)` keeps `has_title(true)`. It is set to false only in the use_environment branch, so titles are part of init_diff.

## 2. Answers

### (1) Monotonic counters
| counter | rule | effect if violated |
|---|---|---|
| Datagram seq (Crypto::unique) | Must be greater than every seq ever used with this key. | Nonce reuse breaks OCB confidentiality and integrity. With seq ≤ server expected_receiver_seq−1, the server processes the payload but does not roam, set has_remote_addr or update last_heard. After 40 s the server is detached and silent. |
| new_num of client states carrying new content | Must be greater than the maximum num ever sent, including empty-ack nums. | Equal to a held num: dropped as a duplicate. Lower than a held num: inserted out of order and never processed. Input is lost without any error. |
| Fragment instruction id | Should differ from the server's current_id. | Can trip `assert(fragments.at(n)==frag)` and abort the server, but only if the server was mid-assembly. |
| throwaway_num | Must be ≤ old_num and ≤ the persisted front. | Above every held num: fatal_assert abort on the server. Front persisted lower than a throwaway already sent: the reference is missing and all input is ignored forever. |

Guarantee: keep a persisted high-water record `{seq_reserved, num_reserved, frag_id_reserved}`. Before using value v ≥ reserved, write `reserved = v + R` (for example R = 2^16 for seq and 2^10 for num) and fsync (atomic rename). On resume, start at the reserved values. Gaps in seq and num are legal: the server only compares them.

### (2) Server→client
- The server's diffs use `old_num ∈ {its sent_states.front().num = highest client ack it received} ∪ {sent states younger than RTO+100ms}`. After any pause longer than about 1.1 s, only front is used.
- The resumed client must hold the exact display-equivalent Complete for every ack_num it ever transmitted that is ≥ the last throwaway_num it received. This is because the server's front is the highest ack that actually arrived, and packet loss means that can be any of them.
- If the client persisted N but had acked N+k: when the server received ack N+k, process_acknowledgment_through erased every state below N+k. Every later diff then has old_num ≥ N+k, and the client's recv hits `!found → return`. The screen freezes for good while the server keeps retransmitting (for 10 s after it last heard from the client, then empty acks every 3 s).
- State 0 is not kept once anything above 0 is acked. An ack for an unknown num is ignored. Nothing in the protocol lets the client request a diff from an arbitrary base.
- Recovery (client-only, derived from code, not tested):
  1. Send a Resize to a size different from the server front's size. The server's next diff from front contains [echoack?] + resize + a hostbytes payload that starts with bell/title/clipboard/reverse-video items only if those changed, followed by "\033[r\033[0m\033[H\033[2J" and a full repaint of rows, cursor, SGR and modes.
  2. Change Transport::recv so that when old_num is not found and the diff contains a resize instruction, it applies the diff onto the best available base (the last persisted state, else a blank one). Accept it as new_num and ack it. From then on the session is normal.
  3. Fields this does not repair: title, icon, clipboard and reverse video if they are unchanged between front and current, plus bell_count. These are cosmetic. Avoid triggering a spurious OSC 52 copy from this path.
  4. To guarantee a size change, send (w, h−1) and then later (w, h) as separate frames. serve() applies only the last of consecutive Resizes within one diff, and the diff is computed against front's size anyway.
  5. This sends SIGWINCH to the remote app, which then redraws.

### (3) Client→server
- The server keeps received_states from its last received throwaway (= the client's front at send time) up to M, its maximum received num. last_receiver_state is state M.
- A resumed client must:
  - send old_num = a num the server still holds (the persisted acked front A ≥ last throwaway sent; A is held because the server acked it and erases only below the throwaway);
  - send a diff that encodes the events after A of a content C that extends the content of every state ever transmitted (C ⊇ S_L, where L is the last sent num);
  - use a new_num greater than L.
- Then `back.diff_from(last_receiver_state)` yields exactly the events after M. Retransmitted keystrokes are deduplicated by the prefix logic, so delivery is exactly-once.
- If C does not extend S_M (for example, keys were sent but not persisted, then new keys were typed after restart): `assert(*i == *my_it)` or `assert(my_it != actions.end())` aborts mosh-server. With NDEBUG it is undefined behaviour.
- If the new nums are ≤ M: input is dropped without notice, then the next state with num > M aborts.
- Keys that were un-acked at death:
  - persisted before sending: resent and applied exactly once;
  - sent but not persisted, and received by the server: fatal on the next new input;
  - sent, not persisted, not received: silently lost.
- Required sent-side shape after resume: `sent_states = [ {num=A, content=∅ (relative)}, …optional…, {num=L', content=S_L relative to A} ]`, `current_state = S_L + new events`, with the next num above num_reserved. A simpler variant: `sent_states=[{A,∅}]`, `current_state=S_L`, with `back.num` forced to the reserved floor, because new_num = back.num+1 needs back.num ≥ L. Note that the Blink restore constructor sets ack_num=0 and last_heard=0. That is harmless: ack 0 is ignored as culled.

### (4) Freeze then snapshot
This is sufficient if all of the following hold:
- (i) Not a single datagram is sent after the snapshot is taken.
- (ii) The snapshot is restored at most once. It must be invalidated durably, or have its counters bumped durably, before the first packet after resume. Otherwise a later crash restores a stale snapshot and reuses seq and nums.
- (iii) The app is never killed between the last send and the snapshot. A crash while in the foreground, or the 2 s suspend timeout Blink uses, breaks this.

Snapshot contents:
- server IP and port (address family);
- the 22-char base64 key;
- next seq (with a reserve margin);
- next fragment id;
- sent_states: num and content (or prefix length) for front and for back;
- current_state events relative to front;
- the last transmitted ack_num and the set of transmitted acks ≥ the last received throwaway;
- every received_state with num in that set, at minimum: (num, width, height, init_diff bytes). Blink stores all received_states;
- the client's last_receiver_state, which equals the latest received state;
- optional: timestamp ages (Blink stores offsets), SRTT/RTTVAR, the last window size sent, and app-level local display state.

### (5) Crash-safe write-ahead variant
Rules:
- Acking state n requires n to be durable; implement as `set_ack_num(durable_num)` instead of `received_states.back().num`.
- Sending throwaway t requires t to be durable as the front.
- Sending content requires the content and the reserved num/seq ranges to be durable.

Costs:
- The client already delays data acks by ACK_DELAY = 100 ms, and the server assumes receipt for RTO+100 ms (≥150 ms) before falling back to front. A fsync that finishes within about 100 ms therefore causes no extra retransmissions and no larger diffs.
- Slower persistence makes the server resend diffs from front: larger diffs, more packets, `next_send_time = back.ts + timeout + ACK_DELAY`.
- The server's sent_states cap of 32 erases from the middle, so a lagging front stays available.
- Server received_states, the client-to-server queue, grows only if throwaway lags. The 1024 cap with a 15 s quench equals about 51 min of 3 s empty acks, so it does not apply if front is persisted promptly.
- Client memory holds received states from the server's throwaway, which is the client's durable ack.

The scheme is sound. Avoid fsync on every frame by journaling the wire diffs `(old_num, new_num, diff)` and checkpointing init_diff snapshots periodically.

### (6) Compact serialisation
- Use `(num, w, h, init_diff())` and restore with `Complete c(w,h); c.apply_string(init_diff)`. This reproduces the cells, cursor, renditions, DrawState display flags (reverse video, cursor visible, bracketed paste, mouse modes and encoding), title, icon, clipboard and echo_ack.
- bell_count becomes 0 or 1 instead of N. That is harmless, because bells are relative.
- It is not `operator==` equal to the original (Row::gen differs), and nothing on the client needs that.
- Hidden DrawState that is not covered (tabs, origin mode, insert mode, saved cursor, next_print_will_wrap) is never set by server diffs except transient scroll regions that are reset. In practice it is default; this is unverified.
- The width and height must be the saved ones, not the current window size. Blink uses the current window size and relies on its follow-up Resize to repaint.
- zlib-compress the result (mosh already uses a compressor).

### (7) Blink
- Code is in blinksh/mosh: the default branch is `ios` (stale since 2016); the restoration code is on `mosh-1.4` (2022-11-29) and `mosh+blink` (2026-03-14, the same mechanism).
- restoration.proto: `Context{required uint64 seq=1; required bytes current_state_patch=2; repeated TimestampedState received_states=3; repeated TimestampedState sent_states=4}` and `TimestampedState{optional uint64 num; optional uint64 timestamp; required bytes patch}`.
- Save: in iosclient.cc process_user_input, on escape 0x1E followed by 0x1a it collects `network->get_received_states()` and `get_sent_states()` (init_diff for each, plus age offsets) and `current_state.diff_from(blank)`. It calls `network->start_shutdown()` (sets flags only), `states.set_seq(Crypto::seq())`, then `state_callback(...)` and `pthread_exit`. A duplicate path exists on SIGINFO.
- Crypto: the counter is `static __thread`, with `Crypto::seq()` and `set_seq()` added.
- Restore (main_init):
  1. `Crypto::set_seq(context.seq())`.
  2. Each received state becomes `Complete(window_size->ws_col, ws_row).apply_string(patch)`.
  3. Each sent state becomes `UserStream.apply_string(patch)`.
  4. A new Transport constructor takes `(blank-with-current_state_patch, last restored terminal, key, ip, port, sent_states, received_states)`; the sender is restored with `ack_num(0)`, `last_heard(0)` and a new Fragmenter.
  5. It then pushes `Resize(ws_col, ws_row)`.
- App side (blinksh/blink, branch `raw`):
  - `BlinkMosh.suspend()` in Blink/Commands/mosh/mosh.swift calls `device.pauseViewOutput()`, writes "\u{1e}\u{1a}", and waits on a semaphore for 2.0 s; on failure it resumes output.
  - `onStateEncoded` calls `putEncodedState`.
  - TermSessionPayload.suspend calls `takeEncodedState` into `_snapshot`; encode(with:) archives the snapshot as a sibling key in NSKeyedArchiver; start or resumeFromSuspended calls `putEncodedState` again; MoshParams' NSCoding deliberately omits the snapshot.
  - It is triggered from TermController.suspendSession(with:), SceneDelegate sceneDidDisconnect → machine.suspend, and `suspendActiveMachines`.
- Known issues:
  - #768 "Mosh never resumes successfully" (closed as old in 2024; it sat in "reconnecting" forever while a new mosh connected at once);
  - #2047 "Mosh unresponsive on tab after app restores from background" (closed 2025-11, fixed in commits 49c1583e and ec341c6cc);
  - #2176 (open 2026-05) "Mosh restore stucked until returning to tab".
- Structural limits:
  - only freeze-on-suspend; a crash or a missed or late suspend loses the session or uses a stale snapshot;
  - restore uses the current window size instead of the saved one;
  - all received_states are stored (up to 1024 full screens);
  - no persistence of the fragment id.

## 3. Resume design spec (iOS-mosh)

### Persisted record
Write it atomically: either a WAL with CRC, or a temp file + rename, using file protection CompleteUntilFirstUserAuthentication.
| field | when written | invariant |
|---|---|---|
| host, ip, port, af, key | at bootstrap | immutable |
| seq_reserved | before seq reaches it | every seq used is below seq_reserved; resume starts at seq_reserved |
| num_reserved | before the sender allocates num ≥ it (including empty acks) | resume back.num := num_reserved−1 |
| frag_id_reserved | same pattern | resume next_instruction_id := it |
| front_num (A) | before any packet carries throwaway = A | sent throwaway ≤ persisted A ≤ server's held states |
| input log: events after A, plus last_sent_len and last_sent_num | before any packet carries those events | content after resume extends S_L |
| remote states {num, w, h, init_diff or base+diff journal} | before acking num | every transmitted ack ≥ last received throwaway is on disk |
| last_rx_throwaway | at receipt | garbage-collect on-disk states below it |
| acks_sent set ≥ last_rx_throwaway | before send (implied by the ack rule) | resume received_states ⊇ these |
| window size last sent, title/clipboard (UI) | lazily | optional |

### Resume procedure
1. Load the record and bump all reserves durably.
2. Build received_states from the stored states, each with its saved w and h; set last_receiver_state = max.
3. sent_states = [{A, ∅}] plus a back with num_reserved−1 and content S_L.
4. current_state = S_L.
5. Send. Optionally push a Resize of the current size.
6. If no diff is accepted within about 2 s after receiving server packets, assume the old_num state is missing and run the resize-repaint recovery (two-step size change) with the patched recv.

### Integration test (local mosh-server 1.4.0)
Kill the client at random points (mid-typing, with un-acked keys, mid-paste with multiple fragments). Assert that:
- the mosh-server pid survives;
- each keystroke reaches the pty exactly once;
- the screen converges.

## findings

### 1. assert compilation

**topic:** assert compilation

#### claim

mosh-server release builds keep assert() active (no NDEBUG), so if a resumed client violates the UserStream prefix invariant, mosh-server calls abort() and the session is lost.

#### evidence

configure.ac mosh-1.4.0 lines 125-157 add only hardening flags; `strings /usr/bin/mosh-server` (the distribution's mosh 1.4.0 package) contains 'my_it != actions.end()', '*i == actions.front()', 'received_states.size() > 0'

**confidence:** high

### 2. client->server prefix requirement

**topic:** client->server prefix requirement

#### claim

The server computes input as back.diff_from(last_receiver_state), and UserStream::diff_from asserts that the previous state is a prefix. New client content must therefore extend everything the client ever sent.

#### evidence

networktransport-impl.h get_remote_diff: `string ret( received_states.back().state.diff_from( last_receiver_state ) );`; user.cc diff_from: `assert( my_it != actions.end() ); assert( *i == *my_it );`

**confidence:** high

### 3. missing reference state

**topic:** missing reference state

#### claim

A diff whose old_num the receiver does not hold is dropped without notice and without an ack, so a client that has lost the server's reference state freezes for good.

**evidence:** networktransport-impl.h recv: `if ( !found ) { ... return; /* this is security-sensitive and part of how we enforce idempotency */ }`

**confidence:** high

### 4. ack culls server states

**topic:** ack culls server states

#### claim

When an ack is received, the sender erases every sent state below it. If the client acked N+k but persisted only N, the server never again diffs from N.

**evidence:** transportsender-impl.h process_acknowledgment_through: `if ( i->num < ack_num ) { sent_states.erase( i ); }`

**confidence:** high

### 5. server diff base

**topic:** server diff base

#### claim

The server diffs from the newest sent state younger than RTO+ACK_DELAY (RTO is 50 to 1000 ms), otherwise from front, the highest state the client acked.

#### evidence

transportsender-impl.h update_assumed_receiver_state: `if ( uint64_t(now - i->timestamp) < connection->timeout() + ACK_DELAY )`; network.cc timeout(): MIN_RTO 50, MAX_RTO 1000

**confidence:** high

### 6. seq / roaming

**topic:** seq / roaming

#### claim

Packets with seq below the server's expected_receiver_seq are still processed, but they do not set has_remote_addr, last_heard or remote_addr. A restarted client with a reset counter is never roamed to, and after 40 s the server detaches and goes silent.

#### evidence

network.cc recv_one: `if ( p.seq < expected_receiver_seq ) { /* don't use (but do return) out-of-order packets for timestamp or targeting */ return p.payload; }`; SERVER_ASSOCIATION_TIMEOUT = 40000

**confidence:** high

### 7. nonce

**topic:** nonce

#### claim

The nonce is a process-static counter starting at 0, and AES-OCB encryption uses it directly. Without persistence, a restarted client reuses nonces under the same key.

**evidence:** crypto.cc `uint64_t Crypto::unique( void ) { static uint64_t counter = 0; ...}`; network.h Packet ctor `seq( Crypto::unique() )`

**confidence:** high

### 8. duplicate/out-of-order nums

**topic:** duplicate/out-of-order nums

#### claim

A state whose new_num is already held is dropped. A state with a lower num than one held is inserted but never becomes back, so it is never processed as input.

#### evidence

networktransport-impl.h: `if ( inst.new_num() == i->num ) { return; }` and `if ( i->num > new_state.num ) { received_states.insert( i, new_state ); ... return; }`

**confidence:** high

### 9. throwaway

**topic:** throwaway

**claim:** A throwaway_num above every held state triggers fatal_assert, so the peer aborts. Invariant: throwaway_num ≤ old_num.

**evidence:** networktransport-impl.h process_throwaway_until: `fatal_assert( received_states.size() > 0 );`; fatal_assert.h calls abort()

**confidence:** high

### 10. queue limits

**topic:** queue limits

#### claim

The receiver caps received_states at 1024, after which it accepts one state per 15 s. The sender caps sent_states at 32 by erasing from the middle, never the front.

#### evidence

networktransport-impl.h `if ( received_states.size() > 1024 )`, `receiver_quench_timer = now + 15000`; transportsender-impl.h add_sent_state `if ( sent_states.size() > 32 )` erase 16th from end

**confidence:** high

### 11. empty acks consume nums

**topic:** empty acks consume nums

**claim:** Every empty ack allocates a new state num, and one is sent every 3 s. Persisted num high-water marks must account for these.

**evidence:** transportsender-impl.h send_empty_ack: `uint64_t new_num = sent_states.back().num + 1;`; ACK_INTERVAL = 3000

**confidence:** high

### 12. Complete equality

**topic:** Complete equality

#### claim

Complete::operator== compares the full Framebuffer, including Row::gen, a process-global counter. A reconstructed state is never == to the original; the client never needs that equality.

#### evidence

completeterminal.cc `return (terminal == x.terminal) && (echo_ack == x.echo_ack);`; terminalframebuffer.h Row==: `gen == x.gen && cells == x.cells`; terminalframebuffer.cc `static uint64_t gen_counter = 0;`

**confidence:** high

### 13. init_diff

**topic:** init_diff

#### claim

init_diff diffs against a blank Complete of the same size, so it has no resize instruction. The restorer must recreate the state at the saved width and height. It does include echo_ack, title, clipboard, reverse video, modes, cursor and renditions.

#### evidence

completeterminal.cc `return diff_from( Complete( get_fb().ds.get_width(), get_fb().ds.get_height() ));`; terminaldisplay.cc new_frame checks

**confidence:** high

### 14. resize forces full repaint

**topic:** resize forces full repaint

#### claim

When the size differs from the reference, the server's diff contains a resize instruction and then a clear screen plus a full repaint. A patched client can use this to recover from a lost reference state.

#### evidence

completeterminal.cc diff_from adds resize when width/height differ; terminaldisplay.cc: `frame.append( "\033[0m\033[H\033[2J" ); initialized = false;`

**confidence:** medium

### 15. fragment id

**topic:** fragment id

#### claim

The client's fragment instruction id restarts at 0. If it matches the id of a half-assembled server packet with different content, the server's assert aborts it.

#### evidence

transportfragment.h `Fragmenter() : next_instruction_id( 0 )`; transportfragment.cc add_fragment `assert( fragments.at( frag.fragment_num ) == frag );`

**confidence:** medium

### 16. Blink mechanism

**topic:** Blink mechanism

#### claim

Blink snapshots only when told to suspend: the app writes Esc Ctrl-Z, and the client saves seq, all received and sent states (init_diff), and current_state, then exits the thread without sending. Restore sets the seq, rebuilds states at the current window size, and pushes a Resize.

#### evidence

blinksh/mosh branch mosh-1.4 src/frontend/iosclient.cc lines ~368-410 and main_init 234-290; src/protobufs/restoration.proto; blinksh/blink raw Blink/Commands/mosh/mosh.swift suspend(): `self.device.write(String("\(self.escapeKey)\u{1a}"))`, 2.0 s semaphore

**confidence:** high

### 17. Blink persistence

**topic:** Blink persistence

#### claim

Blink keeps the snapshot as a sibling key in the NSKeyedArchiver scene archive, outside MoshParams' NSCoding. The snapshot is taken on scene background or disconnect.

#### evidence

blinksh/blink Blink/Terminal/TermSessionPayload.swift: `coder.bk_encode(_snapshot, for: TermSessionPayloadKey.snapshot)`; TermController.suspendSession(with:); SceneDelegate sceneDidDisconnect → machine.suspend()

**confidence:** high

### 18. Blink known issues

**topic:** Blink known issues

**claim:** Blink has a history of mosh sessions that fail to restore or hang after the app comes back from the background.

#### evidence

blinksh/blink issues #768 'Mosh never resumes successfully', #2047 'Mosh unresponsive on tab after app restores from background' (fixed 49c1583e, ec341c6cc), #2176 (open 2026-05) 'Mosh restore stucked until returning to tab'

**confidence:** high

### 19. upstream master

**topic:** upstream master

#### claim

mosh master since 1.4.0 has no transport or statesync semantic changes. It is mostly reformatting, plus OSC 8 hyperlink support (2026-03-22) and a startup-pipe change.

#### evidence

gh api compare mosh-1.4.0...master: commits 3acaa1c4 'clang-format Mosh', 06182189 'Add OSC8 hyperlink support', 4306b7cd 'Use pipe to communicate between client and server at startup'

**confidence:** high

## recommendations

- Implement write-ahead persistence in a forked client Transport. Ack a remote state only once it is durable (set_ack_num(durable_num)). Persist front_num before it is sent as a throwaway. Persist new input events before transmitting them. Fsync inside the existing 100 ms ACK_DELAY window so the protocol costs nothing extra.
- Persist high-water reservations for seq, state num and fragment id in jumps (seq += 2^16, num += 2^10). Bump them durably on every resume, before the first packet goes out.
- Store remote states as (num, width, height, zlib(init_diff)). Restore with Complete(saved_w, saved_h).apply_string(), not with the current window size. Keep only states whose num is in the set of acks you transmitted that are ≥ the last throwaway you received; a journal of wire diffs plus periodic checkpoints is cheaper than per-frame snapshots.
- On resume, set sent_states=[{A,∅}], back.num = num_reserved-1 with content = the last-sent input content relative to A, and current_state = that content plus new input. This keeps the server's UserStream prefix asserts satisfied and delivers input exactly once.
- Add a recovery path to the patched client recv(). If no diff is applicable after resume, send a resize in two steps, first (w,h-1) and then (w,h). Accept a diff with an unknown old_num if it contains a Resize instruction (a full repaint), apply it onto the best base available, and suppress OSC 52 side effects while doing so.
- Also take a freeze-then-snapshot at sceneDidEnterBackground, as Blink does, for fast resume. Still treat the WAL as the source of truth, and invalidate or bump the snapshot durably before sending after resume.
- Write an integration test against the local mosh-server 1.4.0. SIGKILL the client at random points: mid-typing, with un-acked keys, and mid multi-fragment paste. Check that the server pid survives, the pty sees each byte exactly once, and the screen converges. Run the server with -v to see 'Ignoring'/'Received' logs.

## risks

- Sending even one keystroke state whose content was not persisted, then restarting, makes mosh-server abort() through the UserStream::diff_from assert and kills the user's remote shell. Only the next new input after restart triggers it, and it fails completely.
- Reusing a nonce, by restoring a stale snapshot or not persisting seq, breaks AES-OCB confidentiality and integrity. It also stops the server from roaming to the new socket.
- Persisting an ack-front below a throwaway already sent leaves client→server input silently ignored forever. Nothing reports the error.
- Persisting a remote state older than the latest transmitted ack leaves the screen frozen permanently unless the resize-repaint recovery hack is implemented.
- The resize-repaint recovery leaves title, clipboard, reverse video and bell count as they were if they did not change on the server, and it sends SIGWINCH to the remote application.
- Restoring a Complete at the current window size instead of the saved size, as Blink does, gives a wrong-size reference until a repaint.
- Master-built servers emit OSC 8 hyperlinks in diffs, so the client emulator must support them, or the diff semantics will differ from the server's model.
- iOS may kill the app before a snapshot taken on suspend finishes (Blink waits only 2 s), and file-protection classes can block writes while the device is locked.

## unverified

- The resize-triggered full-repaint recovery has not been tested against a real server. It is derived from reading Complete::diff_from and Display::new_frame.
- Not proven that hidden DrawState in a fresh emulator never affects how later server diffs are interpreted: tabs, origin mode, insert mode, saved cursor, next_print_will_wrap.
- Whether every distro or Homebrew mosh-server build keeps asserts enabled. Confirmed only for configure.ac and the binary of the distribution's mosh 1.4.0 package.
- Whether Blink rewrites or clears the on-disk archived snapshot after a warm or cold resume. If it does not, a later crash restores a stale snapshot and reuses seq.
- The exact contents of Blink fix commits 49c1583e and ec341c6cc (not read).
- Whether the mosh+blink branch (2026-03) differs from mosh-1.4 in restore details beyond the grep match (set_seq, init_diff, 0x1a path all present).
- That the server's 16-bit timestamps tolerate a restarted client clock in every case. The code reading suggests they do (R < 5000 filter, timestamps echoed only).

