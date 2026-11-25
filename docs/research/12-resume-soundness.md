# Resume soundness review

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## reviews

### 1. item

**lens:** sender

#### verdict

Checked against mosh 1.4.0, stage 1's client-to-server design holds: a correctly built step 5 cannot make mosh-server assert, repeat a nonce, duplicate or drop sent input, or hang for good. No blockers. Three majors are details the plan leaves implicit (when pending is computed, the order of the dirty writes, what FRONT records); each needs one sentence and a test.

#### issues

##### 1. Snapshot can pair a new A with an input list still counted from the old front

**severity:** major

**title:** Snapshot can pair a new A with an input list still counted from the old front

###### problem

process_acknowledgment_through (transportsender-impl.h) advances the front without trimming events; trimming happens later in rationalize_states, called from calculate_timers. A faithful port that quiesces between an ack and the next tick stores the new A with events still counted from the old front. On resume the server receives those events twice: UserStream::diff_from (user.cc, via Transport::get_remote_diff) asserts if the server holds a later state; otherwise the keystrokes are applied twice.

###### fix

Add to 'Quiesce before snapshot': rationalize first; pending = current minus the front state's events; do not snapshot unless the front's list is empty. Add a fake-clock test: deliver an ack, snapshot with no tick in between, resume, compare pending.

**verified:** True

##### 2. Stage 2: FRONT must record an input offset

**severity:** major

**title:** Stage 2: FRONT must record an input offset

###### problem

The INPUT and FRONT rules are right in direction, but restore needs 'input since state F', and journal order cannot give it. Input typed between sending F and receiving its ack is appended before FRONT(F) yet is not part of F. Restoring or compacting by record position drops those events, so the resumed state is shorter than one the server already applied: assert in UserStream::diff_from (user.cc).

###### fix

Define FRONT(num, inputCount), with inputCount the cumulative number of INPUT records contained in that state; pending = INPUT records after that count. CHECKPOINT carries the same pair. State that Resize events are INPUT records, kept in order.

**verified:** True

##### 3. dirty = 0 can land after a send made since the snapshot was captured

**severity:** major

**title:** dirty = 0 can land after a send made since the snapshot was captured

###### problem

mosh has one send point (connection->send in send_in_fragments, reached only from tick; hop_port in network.cc sends nothing), so a gate there covers timers, retransmits and Resize. The gap is ordering. If sceneDidBecomeActive runs while the snapshot write is suspended, dirty = 1 is written, new input goes out, then quiesce finishes with dirty = 0. A kill before the next send leaves a stale snapshot marked valid, which is N2. The window is narrow, and there is no code yet to confirm it against.

###### fix

Add a gate rule: dirty = 0 is written only if no datagram passed the gate since capture, checked in the same critical section. Lifecycle events are handled strictly in order. Add a kill-loop case: quiesce, immediate return, type, SIGKILL.

**verified:** False

##### 4. After resume, a lost first datagram is retried only after 3 s

**severity:** minor

**title:** After resume, a lost first datagram is retried only after 3 s

###### problem

calculate_timers (transportsender-impl.h) retries at the retransmit timeout only while last_heard + 10 s > now. A rebuilt sender has no recent last_heard, so the next attempt comes from the 3000 ms ack timer. Not a hang, but a visible stall when the first datagram is lost on network wake-up, and the 5 s liveness check can fail under loss.

###### fix

Step 5: set the sender's last_heard to now, which gives retries about every 1.1 s for 10 s. Also start injected clocks well above zero; mosh's 0 and -1 timer sentinels assume that.

**verified:** True

##### 5. An ack for a state not in sentStates must be ignored

**severity:** minor

**title:** An ack for a state not in sentStates must be ignored

###### problem

If the server replies before it has accepted nextNum (a lost fragment of a large pending paste, or quench), its ack_num is a pre-kill state between A and nextNum. mosh ignores acks for states it does not hold (process_acknowledgment_through). A port that drops everything below the ack loses A and then sends old_num = nextNum, which the server lacks: permanent hang. Separately, with nothing pending the first datagram is an empty ack numbered nextNum + 1 (send_empty_ack).

###### fix

List 'ack for an unknown state number is ignored' as an invariant with a unit test. Reword step 5: new_num is nextNum, or nextNum + 1 when nothing is pending.

**verified:** True

##### 6. N3 is narrower and nastier than the table says

**severity:** minor

**title:** N3 is narrower and nastier than the table says

###### problem

Transport::recv (networktransport-impl.h) returns early when old_num is missing, so a high throwaway alone does nothing. With old_num held and throwaway_num above it, the reference state is erased and then dereferenced. That is undefined behaviour, unless every state is gone, when the fatal_assert fires.

###### fix

N3 row and gate: throwaway_num <= old_num on every instruction. Guard test: a held old_num with throwaway above all states, so the server's exit is deterministic.

**verified:** True

#### confirmed

- Q1: the server always holds A. It acked A and erases only below a received throwaway_num, which never exceeds the client's front (Transport::recv, send_in_fragments).
- Q1: step 5 numbering matches send_to_receiver and update_assumed_receiver_state; old timestamps force old_num = A.
- Q1: quench delays nextNum by at most 15 s; not a permanent hang.
- Q2: no duplication. The serve loop applies only back().diff_from(last_receiver_state); late pre-kill datagrams sort below nextNum and are never applied.
- Q4: restarting at the reserved limits is sufficient. FragmentAssembly resets on any id change, so pre-kill partials cannot mix with resumed fragments.
- Q5: recv_one accepts the sequence jump and retargets before any transport check; a stale timestamp is overwritten by the first resumed datagram.
- N2 asserts are live: configure.ac sets no NDEBUG. Appendix constants for this direction match network.h and transportsender.h.

### 2. item

**lens:** receiver

#### verdict

Stage 1 holds in the server-to-client direction. After silence the server diffs from `sent_states.front()`, which the snapshot always contains, and an ack for a culled state is ignored harmlessly. I found no permanent hang or server abort here, provided the snapshot is faithful; it currently omits the pen. The PID check, the health probe and one stage 2 rule also need changes.

#### issues

##### 1. Framebuffer and snapshot omit the pen (current rendition)

**severity:** major

**title:** Framebuffer and snapshot omit the pen (current rendition)

###### problem

`Display::new_frame` (terminal/terminaldisplay.cc) starts each diff with `frame.current_rendition = last_frame.ds.get_renditions()` and ends with `update_rendition(f.ds.get_renditions())`. The server omits the SGR when the first cells match the base's pen. A state rebuilt without the pen prints those cells in default colours and the server never corrects them: a wrong screen that persists. 'SGR always rebuilt from ESC[0m' in the appendix hides this.

###### fix

Add `pen` to Framebuffer and the snapshot. Full per-state list: width, height, cells (contents, renditions, wide, fallback, wrap), cursor position and visibility, reverse video, pen, bracketed paste, mouse reporting mode, focus events, mouse encoding, icon name, window title, clipboard, bell count, echo ack.

**verified:** True

##### 2. PID check cannot tell the old server from another mosh-server

**severity:** major

**title:** PID check cannot tell the old server from another mosh-server

###### problem

`run_server` (frontend/mosh-server.cc) prints the pid line to stderr from the parent after `fork()` and after `MOSH CONNECT` (stdout), before the parent exits, so it precedes channel close. Nothing else identifies the process. `comm` matches any mosh-server: after a reboot or PID wrap, the fallback and 'End session' can kill another session of the same user, and ServerProbe calls a dead server 'UDP blocked'.

###### fix

At bootstrap, store `ps -p PID -o lstart=` from a second channel. Before any kill, and in ServerProbe, require the login user, a `mosh-server` basename and a start time within 2 s of the stored one. Otherwise never kill.

**verified:** True

##### 3. ServerProbe: 'PID alive' has other causes; a lost base state has no exit

**severity:** major

**title:** ServerProbe: 'PID alive' has other causes; a lost base state has no exit

###### problem

(a) `-s` binds the server to the SSH_CONNECTION address (`get_SSH_IP`, mosh-server.cc); the saved IP can be unreachable from another network while SSH by name works. (b) `Connection::recv` (network.cc) returns before `has_remote_addr = true` when `seq < expected_receiver_seq`, so a client sequence regression leaves a detached server silent. (c) Lost base: datagrams authenticate, the 15 s trigger never fires, the screen freezes while keystrokes still reach the shell. (d) 'PID gone' includes a shell exit while away; the server leaves after 10 s unacknowledged (`shutdown_ack_timed_out`).

###### fix

Add these rows. Compare the probe's resolved address with the saved IP. Treat an instruction with `old_num == throwaway_num` and `old_num` not held as unrecoverable: go to the fallback. Time the banner from the last accepted state. Word 'PID gone' as 'ended or host restarted'.

**verified:** True

##### 4. Stage 2 restore and CHECKPOINT rules can lose a base state

**severity:** major

**title:** Stage 2 restore and CHECKPOINT rules can lose a base state

###### problem

`Transport::recv` (network/networktransport-impl.h) accepts a state only if `old_num` is held. A held state's base is often below the last throwaway (10 built on 5, then throwaway 10), so filtering to 'at or above the last REMOTE_THROWAWAY' before applying loses it. A CHECKPOINT holding only the throwaway state drops acked states; the server's front may be one of them, and it then diffs from a state the client lacks, for good. `send_empty_ack` states (every 3 s, empty diff) are acked too.

###### fix

CHECKPOINT holds every held remote state. Restore replays all REMOTE records after it in append order, including empty-diff ones and those below the last REMOTE_THROWAWAY, then prunes. A state number once sent as `ack_num` is kept until a REMOTE_THROWAWAY passes it.

**verified:** True

##### 5. `ps -o comm=` may not print exactly `mosh-server`

**severity:** major

**title:** `ps -o comm=` may not print exactly `mosh-server`

###### problem

Not confirmed: this is `ps` behaviour and I had no macOS host. On macOS `comm` prints argv[0], a full path when the host entry sets a server path such as `/opt/homebrew/bin/mosh-server`, as the plan's error table recommends. An exact match then fails, ServerProbe says 'server gone', and the fallback discards a live session and leaves its server running.

**fix:** Compare the basename and let the stored start time carry the identity check. Run the probe tests against a macOS host as well.

**verified:** False

##### 6. Appendix corrections

**severity:** minor

**title:** Appendix corrections

###### problem

From `new_frame` and terminalframebuffer.h: titles use OSC 1 plus OSC 2 when icon name and window title differ. Mouse mode can be `?9` (X10); turning reporting off sends `?1003l ?1002l ?1001l ?1000l`. ECH and EL arrive under a coloured pen (`has_bce` true), so erased cells take its background. Receiver cap (`recv`): above 1024 held states one more is accepted, then new ones are dropped for 15 s.

###### fix

Add OSC 1/2, `?9h`, the mouse-off sequence and background-colour erase to the applier list and corpus. Reword the receiver row. Add 'server shutdown gives up after 16 sends or 10 s'.

**verified:** True

#### confirmed

- After silence over RTO + 100 ms the server diffs from `sent_states.front()` (`update_assumed_receiver_state`).
- The 32-state cull erases the 16th state from the end; never the front or the newest.
- The front is always in the snapshot: the client acked it and prunes only below the server's front. Lost acks just leave it older.
- `process_acknowledgment_through` ignores an ack for a culled state; the cold-start `ack_num` is safe.
- After 40 s of silence the server stops sending; it re-attaches on the next authenticated datagram with a higher sequence number.
- Shutdown: `new_num` = 2^64 - 1; the reply is `ack_num` = 2^64 - 1 on an ordinary instruction; otherwise the server exits after 16 sends or 10 s. The plan matches.
- Constants confirmed: RTO 50-1000 ms, send interval 20-250, ack delay 100, ack interval 3000, port hop 10 s, association 40 s, first client 60 s.

