# Resume stage 2 (M9): the write-ahead journal

> Addresses, ports and details of the author's own network were removed before publication.

Design for milestone M9 of `docs/PLAN.md`: "Kill at random instants, 500 iterations, no server
abort, no lost input". Design only: nothing in this file is built or run. Stage 1 as built is
in `docs/RESUME.md`; this file says what changes, how to build it step by step, and why a kill
at any instant is safe.

Conventions:

- Code references are to `main` at `30a8bc9`, by function name; line numbers will move.
- Changed after the review (`REVIEW.md`, `REFUTATION.md`; the finding is named where a rule
  comes from one). Line numbers given with those changes are at `42c4d11`.
- mosh references are to mosh 1.4.0 as read in `/opt/mosh-src/src` (the same bytes as
  `.refs/mosh/src`), written `file:line`.
- The asserts of `mosh-server` are live. The source tree builds with `CPPFLAGS` empty and
  `CXXFLAGS = -g -O2` (`/opt/mosh-src/Makefile`), so there is no `NDEBUG`, and the packaged
  binary (`/usr/bin/mosh-server`, the distribution's mosh 1.4.0 package) contains the strings
  `my_it != actions.end()`, `*i == actions.front()`, `received_states.size() > 0` and
  `fragments.at( frag.fragment_num ) == frag`. The stage 1 guard tests end the real server
  with two of them (`docs/RESUME.md`, "Stage 1 results").
- "Front": the newest client state the server acknowledged (mosh: `sent_states.front()`),
  written `A`. "The server's front": the newest server state the client acknowledged, as the
  server knows it.

Contents: 0 summary, 1 what mosh-server does, 2 the model, 3 records and bytes, 4 write-ahead
rules, 5 restore, 6 proof obligations, 7 compaction and sealing, 8 reboot, 9 cost, 10 API
changes, 11 tests, 12 implementation plan, 13 differences from the plan's sketch, 14 attacks on
this design, 15 open questions and what the source did not settle.

## 0. Summary

Stage 1 keeps a snapshot and a dirty flag: once a datagram leaves after the snapshot, the
record is worthless until the next snapshot. Stage 2 keeps a redo log instead.

1. **Log before apply.** The transport's durable state (the front and its input count, the
   input stream, the held remote states, "the server shut down") changes in memory only after
   a record of the change has been appended to `journal.<g>` and `write()` has returned. A
   datagram is built from memory, so nothing on the wire can run ahead of the journal.
   The send point checks it again from its own books (`throwaway_num` at or below the
   journaled front, `ack_num` a journaled state, every input event of the diff journaled).
2. **Numbers stay where they are.** Sequence numbers, state numbers and fragment ids come
   from `counters` (reserve ahead, both slots, full sync), exactly as in stage 1. The journal
   never supplies a number.
3. **Restore is replay.** A cold start reads the newest journal generation, cuts a torn last
   record, loads the `CHECKPOINT` (the stage 1 snapshot body) and replays the records through
   the functions that applied them live. The sender starts with the front alone and sends
   everything after it under a new state number; `mosh-server` drops what it already has,
   because it applies only the difference from the newest state it holds (section 1, fact S6).
4. **Open before append.** Appends are not synced. Before the first append after a synced
   checkpoint, both `counters` slots say `open(boot)` (full sync). An open record is resumed
   only in the boot that wrote it; then every completed `write()` is in the file. Leaving the
   foreground writes a synced checkpoint and the mark `sealed`, which survives a reboot, as
   stage 1's clean snapshot does.
5. **Only the last record can be torn.** A record that runs past the end of the file is cut.
   Anything else that fails a check is damage, and a damaged journal is never resumed.

What does not change: the reservation rules and the two-slot `counters` file (R1 to R3, R9 to
R11, R13 to R16), the lock (R12), the backup exclusion (R19), `meta` and the key, "ended", the
fallback and the probe.

## 1. What mosh-server does

Every rule below rests on these facts. `s2c` is server to client, `c2s` client to server.

| # | Fact | Source |
|---|---|---|
| S1 | The server holds a list of client states, starting with state 0 (empty input). An instruction is handled in this order: (a) its `ack_num` is given to the sender; (b) if a state numbered `new_num` is held, return; (c) if no state numbered `old_num` is held, return; (d) erase every held state below `throwaway_num`; (e) queue limit; (f) new state = copy of state `old_num` plus the diff; (g) insert in number order; only if it is the newest: `ack_num` to send := its number | `network/networktransport-impl.h:43-52`, `:83`, `:88-95`, `:97-111`, `:118`, `:120-131`, `:133-140`, `:142-165` |
| S2 | Step (d) erases, then `fatal_assert( received_states.size() > 0 )`. With `old_num` held and `throwaway_num` above it, the reference state is erased and then copied at `:134` (undefined behaviour); with nothing left, the server aborts. This is N3 | `networktransport-impl.h:169-184`, `:134` |
| S3 | Client states are erased only by step (d). Nothing else removes one | `networktransport-impl.h:171-181` is the only `received_states.erase` |
| S4 | The server's `ack_num` is the number of the newest client state it holds | `networktransport-impl.h:159-160`, `network/transportsender-impl.h:327`, `:397-402` |
| S5 | An ack for a state the sender does not hold is ignored; otherwise every sent state below it is erased, so the sender's front is the newest state the peer acknowledged that the sender still held | `transportsender-impl.h:357-380` |
| S6 | Input reaches the pty only as `received_states.back().state.diff_from( last_receiver_state )`, and only when the newest state's number changed. `diff_from` asserts that the old state is a prefix of the new one; afterwards every held state has the oldest held state subtracted, which asserts that the oldest is a prefix of each. A state with a shorter or different input list than one the server holds is N2 The server's echo ack has an assert of its own (`completeterminal.cc:77`), fed with the number of the newest held client state (`mosh-server.cc:769`); the list is sorted, so it holds whatever numbers a client sends, as long as the list is never emptied (N3). | `frontend/mosh-server.cc:733-738`, `networktransport-impl.h:186-204`, `statesync/user.cc:61-71` (asserts at `:68-69`), `user.cc:44-59` (asserts at `:55-56`) |
| S7 | The server's instruction: `old_num` = its assumed receiver state, `throwaway_num` = its front, `ack_num` as S4. The assumed state is the front, moved forward over states sent less than RTO + 100 ms ago; after that silence it is the front. RTO is at most 1000 ms | `transportsender-impl.h:319-330`, `:269-292`, `:406-425`, `network/network.h:133-134`, `network/transportsender.h:55` |
| S8 | The server keeps at most 32 sent states; above that it erases the 16th from the end, never the front | `transportsender-impl.h:227-236` |
| S9 | An empty ack is a new state: `new_num = sent_states.back().num + 1`, every 3000 ms when nothing else is sent. Both sides do this | `transportsender-impl.h:205-225`, `transportsender.h:54` |
| S10 | A datagram numbered below `expected_receiver_seq` is still handed to the transport, but takes no part in timing and does not move the server to a new address. Any number at or above it is accepted, however large the jump, and the server then answers to the datagram's source address | `network/network.cc:515-519`, `:555-572` |
| S11 | Decryption checks the tag only; there is no replay window besides S10. The sender's nonce is a counter | `crypto/crypto.cc:250-286`, `:64-72`, `network.h:84-88` |
| S12 | After 40 s without a client datagram the server stops sending (`has_remote_addr = false`) and its `tick` and `wait_time` do nothing; the next authentic in-order datagram attaches it again. It exits for lack of a client only while it has never received a client state (60 s, counted from the timestamp of state 0, which is the server's start: `networktransport-impl.h:47`, `mosh-server.cc:914-919`), or when `MOSH_SERVER_NETWORK_TMOUT` is set | `network.cc:418-422`, `network.h:139`, `transportsender-impl.h:140-142`, `:157-159`, `mosh-server.cc:682`, `:914-919`, `:383-395`, `:857-863` |
| S13 | A fragment with a new id clears the assembly. The same id and fragment number with other content is an assert (N4). Two more live asserts on the same path (`:118`, `:123`: more fragments than the final one announced) are also reached only when one id carries two instructions | `network/transportfragment.cc:91-128` (`:94-100`, `:103-106`) |
| S14 | The server's shutdown is `new_num` = 2^64 - 1, repeated until the client's `ack_num` = 2^64 - 1 arrives, at most 16 sends or 10 s; then it exits either way. A client's shutdown is answered by one instruction with `ack_num` = 2^64 - 1, after which the server exits | `transportsender-impl.h:214-217`, `:248-251`, `:382-395`, `transportsender.h:56-57`, `:150-151`, `mosh-server.cc:880-893` |
| S15 | The server's states are full terminals; a diff is made by `Complete::diff_from` from the base state, and applied by the client to its copy of that base. The parser state continues from the base | `statesync/completeterminal.cc:72-97`, `:104-122` |

Three consequences used all through:

- **The server holds a client state as long as no instruction with a higher `throwaway_num`
  was processed** (S1, S3). The client's `throwaway_num` is always its front
  (`TransportCore.sendInFragments`, `throwawayNum: sentStates[0].num`).
- **A state the server has is never applied twice** (S1b, S6): a new state that contains the
  old input as a prefix adds only what follows it.
- **After silence the server builds on its front** (S7), which is a state the client sent as
  `ack_num` (S5).

## 2. The model

The client's state has a durable part and a part that a restart may forget.

| Durable (journaled) | Why a restart needs it |
|---|---|
| The front `A` and the number of input events it contains | The base of the first diff, and where pending input starts (N2, N3) |
| The input stream (bytes and resizes, in order) | A new state must contain every event an earlier state contained (N2) |
| Every held remote state, with its number | The server builds on any state the client acknowledged (S7) |
| "The server announced the end of the session" | A session that is over must not be continued or bootstrapped again |

| Forgotten | Safe value after a restart |
|---|---|
| Sent states above the front, the assumed receiver state | None: the sender holds the front alone. The server may hold more; they are never used as a base and are erased by a later `throwaway_num` |
| Sequence number, state number, fragment id | The reserved limits in `counters` (R2) |
| RTT, timers, saved timestamp, pending data ack, quench timer, MTU fallback | Fresh, as in `TransportCore.init(restoring:)` today |
| Partial fragment assembly | Empty |
| Expected receive sequence | The highest value in the journal (a lower bound, section 5) |
| The highest `ack_num` sent | The newest held remote state |

Notation for the proofs: `J` is the journal as the sequence of completed appends. `M` is the
memory of the live process. `S` is what a restart finds.

- **L0.** `durable(M) = replay(J)` at every instant: a transition is applied to memory only
  after its append returned, and replay calls the same apply functions (section 4.3).
- **L1.** `S = J + p`, where `p` is a prefix (possibly empty, possibly all) of the records of
  the append that was in progress at the kill (or of one that failed earlier and could not be
  cut back, J10). A record cut short is removed by the reader (section 3.4). No datagram was
  ever built from a state that contains `p`.

So a restart finds the dead process's last durable state, or that state plus transitions the
process had decided on and not yet acted on. Section 6 shows both are safe.

## 3. Records and bytes

### 3.1 Files of a record

| File | Content | Written |
|---|---|---|
| `meta`, `key`, `lock` | Unchanged | |
| `counters` | Two slots, slot format version 2 (version 1 is still read) | In place, one slot per write |
| `journal.<g>` | Header, one `CHECKPOINT`, then records. `g` is 1, 2, ... in decimal without leading zeros | Appended; replaced as a whole by `journal.<g+1>` |
| `journal.<g>.tmp` | A new generation being made. Never read; removed at the next start | |
| `snapshot` | Stage 1 only. Read when a stage 1 record is opened, removed when it becomes a stage 2 record | |

All integers are little-endian; CRC-32 is the one of `RecordFormat.swift`.

### 3.2 Journal header (52 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic `MRj1` |
| 4 | 2 | Format version, 1 |
| 6 | 2 | 0 |
| 8 | 16 | Session id |
| 24 | 8 | Generation `g` (equals the number in the file name) |
| 32 | 8 | `inputBase`: how many input events, counted from the record's first state, the checkpoint's acknowledged state contains |
| 40 | 4 | `inputWindow`: the `unacknowledgedInputLimit` in force when the file was made (1 or more) |
| 44 | 4 | 0 |
| 48 | 4 | CRC-32 of bytes 0 to 47 |

Input events are counted absolutely for the life of a record: the first event of a new session
(its initial Resize) has index 0. `inputBase` ties a generation to that count, so records can
be copied from one generation to the next byte for byte (section 7).

### 3.3 Record frame

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `n`: length of type and payload, 1 to 67,108,864 |
| 4 | 4 | Bitwise NOT of `n` |
| 8 | 1 | Type |
| 9 | `n` - 1 | Payload |
| 8 + n | 4 | CRC-32 of bytes 0 to 8 + n - 1 of this frame |

A frame is 12 + n bytes. The length is stored twice so that a damaged length cannot pass for a
record that runs past the end of the file (3.4).

| Type | Name | Payload | Frame size |
|---|---|---|---|
| 1 | `CHECKPOINT` | The snapshot body of `docs/RESUME.md` ("`snapshot` body"), unchanged; its "snapshot id" is the checkpoint id | 13 + body (289 for a new blank 80x24 session) |
| 2 | `INPUT` | `u64 firstIndex` (absolute index of the first event), `u32 e` (1 or more), then input items until `e` events are read, in the snapshot's item coding (`00`, `u32 k`, `k` bytes; `01`, `u16` width, `u16` height) | 31 for one key, 30 for a resize |
| 3 | `FRONT` | `u64 number` (not 2^64 - 1), `u64 inputCount` (absolute), `u64 receiverSequence` | 37 |
| 4 | `REMOTE` | `u64 oldNum`, `u64 newNum` (not 2^64 - 1), `u64 throwawayNum` (at most `oldNum`), `u64 receiverSequence`, `u32 d`, `d` bytes: the instruction's diff as received | 49 + d |
| 5 | `THROWAWAY` | `u64 throwawayNum`, `u64 receiverSequence` | 29 |
| 6 | `SERVER_SHUTDOWN` | `u64 receiverSequence` | 21 |

`receiverSequence` is the transport's expected receive sequence (`expectedReceiverSeq`) after
the datagram that caused the record.

Limits: an `INPUT` payload holds at most 1 MiB of events (a larger `type` call becomes several
`INPUT` records in one append); a `REMOTE` diff is at most 4 MiB (mosh's own limit,
`Compressor.swift`); a `CHECKPOINT` at most 64 MiB. Appends are refused once a generation holds
16 MiB after its checkpoint (`journalFull`; reached only if compaction keeps failing). `FRONT`
and `THROWAWAY` frames are admitted past that limit: they are 37 and 29 bytes, and they are
what makes the next checkpoint smaller. Without them a generation whose pending input is too
large for a `CHECKPOINT` could never shrink again (R2-5).

Record types compared with the plan's list:

- `INPUT`, `FRONT`, `REMOTE`, `CHECKPOINT`, `SERVER_SHUTDOWN`: kept.
- `REMOTE_THROWAWAY` is dropped as a record of its own. The throwaway number is a field of the
  instruction and is stored in its `REMOTE` record; replay prunes at the same place the live
  code did. `THROWAWAY` exists for the two cases in which mosh acts on a throwaway and stores
  no state: the queue is full (`networktransport-impl.h:118` runs before `:120-131`), or the
  diff does not apply (our port drops the instruction, `TransportCore.process`). Without it the
  replayed receiver would hold more states than the live one did. That would be harmless, but
  L0 would no longer be an equality, and the tests compare with equality.
- No record for the client's own shutdown: "ended" is written to `counters` before the first
  shutdown datagram, as today (C7, R16), and an ended record is never resumed.
- No clipboard record (section 5, step 9).

### 3.4 Reading a journal: torn or damaged

`write()` of a regular file can be cut short by a kill, but what reaches the file is then a
prefix of what was written. So only the last record can be incomplete, and "incomplete" always
means "the file ends before the record does".

```
header: fewer than 52 bytes, wrong magic, version, CRC, session id or generation -> DAMAGED
pos = 52
loop:
    rest = fileSize - pos
    rest == 0                       -> end
    rest < 8                        -> TORN at pos
    n, c = u32 at pos, u32 at pos+4
    c != ~n, or n == 0, or n > max  -> DAMAGED
    rest < 12 + n                   -> TORN at pos
    CRC of [pos, pos+8+n) differs   -> DAMAGED
    decode type and payload strictly; unknown type, trailing bytes, bad value -> DAMAGED
    pos += 12 + n
the first record is not a CHECKPOINT, or a later one is -> DAMAGED
```

- TORN: the records before `pos` are the journal. The file is cut to `pos` (`ftruncate`)
  before anything is appended to it; a kill before the cut leaves the same torn tail for the
  next start. The cut belongs to the file it was found in: the `Journal` object
  holds (generation, `pos`) and cuts when the gate is armed (J14). Nobody else keeps the
  offset, and no generation is made while a cut is pending (S-3).
- DAMAGED: the record is not resumed (`FallbackReason.damaged`). A complete record with a bad
  checksum is never "the end of the log": the records after it were acted on, and dropping
  them would resume from a state older than what the server has seen (N2).

Replay checks each record against the state built so far, and a failure ends the cold start
in a fallback as well (`.snapshotRefused`: the bytes were sound, their content was not):
`INPUT.firstIndex` equals the number of events so far; `FRONT.number` is above the current
front and `inputCount` is between the current front's count and the number of events;
`REMOTE.oldNum` is held, `newNum` is not, `throwawayNum <= oldNum`, the diff applies;
a `THROWAWAY` leaves at least one held state (the core's list is never empty,
`TransportCore.swift:77`; S-4); `SERVER_SHUTDOWN` is the last record.

### 3.5 Record states: what replaces the dirty flag

The state byte of a `counters` slot gets one new value, and the slot's format version becomes
2. The slot keeps its 68 bytes and its layout (`Counters.swift`); the field at offset 56 is
the checkpoint id or the boot digest.

| Version | State byte | Field at 56 | Swift | Meaning |
|---|---|---|---|---|
| 1 | 0 | snapshot id | `.clean(snapshotID:)` | Stage 1: resumable from the file `snapshot` with that id |
| 1 | 1 | 0 | `.dead` | Stage 1 "dirty": not resumable, a new session is owed |
| 1, 2 | 2 | 0 | `.ended` | Ended on purpose: not resumable, nothing owed |
| 2 | 0 | checkpoint id, not 0 | `.sealed(checkpointID:)` | The newest journal is exactly one synced `CHECKPOINT` with that id. Resumable in any boot |
| 2 | 1 | 0 | `.dead` | Given up (a fallback, `abandon()`, a lost base state, a halted transport): a new session is owed |
| 2 | 3 | boot digest; 0 if unknown | `.open(boot:)` | The newest journal may hold appends that were never synced, made in that boot. Resumable in that boot only |

A reading is the newest valid slot of either version (the rule of R15 is unchanged). Stage 2
writes version 2 only.

| From | Event | To | Written |
|---|---|---|---|
| (no record) | `create` | `open(b)` | `journal.1` with the initial checkpoint, then the initial `counters` image (both slots) |
| `open(b)` | Leaving the foreground, seal done | `sealed(id)` | A synced generation, then one slot |
| `sealed(id)` | On an armed gate (J14), the first append or the rename of a generation is about to happen: `start()`, a return to the foreground, input in the background | `open(b)` | Both slots, full sync each, before the append or the rename |
| `clean(id)` (stage 1) | `start()` only (`beginSending()`), after the conversion's generation has its name (3.6) | `open(b)` | Both slots, full sync each |
| any but `ended` | Given up | `dead` | Both slots. Final from the call on (J15) |
| any | Shutdown asked for, or the server ended the session | `ended` | Both slots (R16 unchanged) |

**Final marks (J15).** `ended` and `dead` are never left for `open` or `sealed` (`ended` may
replace `dead`; nothing replaces `ended`). Each is an intent the gate takes before its first
slot write (`markEnded()`, `markDead()`). From then on every slot write of that gate writes
it, whatever caused the write: the mark itself, `record`, a reservation, `willSendDatagram()`.
So a mark that failed half way with the process alive is completed by the next write and is
never covered by `open` (R16 for `ended`; R2-1 for `dead`).

**Armed (J14).** A gate is *armed* when its journal file is whole, is the authority of the
record and is the file the gate appends to. `create` returns an armed gate. The gate of a
record opened by a cold start is unarmed, and `beginSending()` is the one call that arms it,
in this order: the journal cuts its torn tail, a stage 1 record gets its generation
(3.6), `open(b)` and the new reservations go to both slots. An unarmed gate appends nothing,
makes and renames no generation and writes neither `open` nor `sealed`: `record`,
`markOpen()`, `seal` and `compact` throw `notArmed` and write nothing. It writes `ended` and
`dead` only. So until `start()` has succeeded, the state on disk is the one the cold start
found, or a final one. This one rule closes every door by which an unconverted stage 1 record
or an uncut journal could be appended to or marked `open`: input given to a restoring
initializer (R2-2; there is no such parameter any more, section 5), `shutdown()` before
`start()` (S-1), `enterBackground()` before `start()` (S-3), and any caller that holds the
public `SessionRecord.gate`.

There is no state "dirty because a datagram left". A datagram alone never makes a record
stale: what the server learns from it (state numbers, an `ack_num`, input) is all in the
journal already.

### 3.6 Compatibility

**A stage 1 record on a stage 2 build** (the owner's phone has them now). It is opened by
stage 1's rules and turned into a stage 2 record by `start()`:

| Stage 1 record | Stage 2 cold start |
|---|---|
| `clean(id)` with `snapshot` id `id` | Resumed. `coldStart` reads `snapshot` as the checkpoint (`inputBase` 0, no records) and writes nothing; journal files in the directory are not looked at. `start()` then: writes a generation from that checkpoint, numbered above any that exists (normally `journal.1`; temporary file, rename; no sync, the next mark is `open`), writes `open(b)` with new reservations to both slots, removes `snapshot` and lower generations. A kill before the slots are written leaves a valid stage 1 record (and a journal that the next start supersedes); after it, a stage 2 record |
| `clean(id)`, `snapshot` missing or another id | Fallback, as today (R7) |
| dirty | `dead`: fallback with `FallbackReason.givenUp`, as today's `.dirty`. A session that died in the foreground under stage 1 stays lost; its journal was never written |
| ended | Ended, as today |

The same rules cover a record made by a build between steps 8 and 9 of section 12 (stage 1
states, with journal files that were never the authority): the state decides, the journal
files are ignored and replaced. Until `start()` has armed the gate, nothing is appended to such
a file
and no `open` is written beside it (J14).

**A stage 2 record on a stage 1 build** can happen only when an older build is installed over
a newer one (`scripts/deploy.sh` with an older checkout; the app's files are kept). The old
build reads `counters` with `CountersSlot.init(encoded:)`, which refuses format version 2
(`unsupportedVersion`), so both slots are invalid, no gate is made and nothing can be sent
under the key: N1 to N4 hold. What the old build then does is not pretty: its cold start takes
the path "not a record", removes the files it knows, fails to remove the directory because of
`journal.<g>` (`SessionStore.delete` ends with `rmdir`), and reports a fallback with
`recordDeleted` false; the app bootstraps a new session and tries to forget the old one, which
fails again. The leftover directory has no `meta` and sorts first at every launch of the old
build (review M6-5, open). A stage 2 build that finds such a directory later deletes it (no
`counters`). Decision: downgrading below stage 2 with a session record present is not
supported; end the session first. See section 15.

**A stage 2 record on a build of steps 6 to 8** of section 12 (the same downgrade). Those
builds read version 2 slots and run stage 1's code, so they do make a gate. They are safe by
the rule of step 6, not by the refusal above: a slot that says `open` or `sealed` is treated
like dirty (never resumed, a new session is owed), and its limits count, so the gate's first
reservation is above them (R2). Step 6 has the test (S-5).

Stage 2's `SessionStore.delete` removes `journal.*` as well.

## 4. Write-ahead rules

### 4.1 What must be on disk before a datagram, field by field

| Field of the datagram | Must be recorded first | Kind of write | Enforced by |
|---|---|---|---|
| Sequence number | A limit above it, in both `counters` slots | Full sync, once per 65,536 | `FileBackedGate.take` (R1), `Outbox.send` (`sequenceNotReserved`). Unchanged |
| Fragment id | The same, once per 1,024 | Full sync | The same (`fragmentIDNotReserved`). Unchanged |
| `new_num` | The same, once per 1,024. A restart never reuses a number, so a state number needs no journal record | Full sync | `Outbox.takeStateNumber`. Unchanged |
| The diff (the input from `old_num` to `new_num`) | An `INPUT` record for every event up to the state's end | `write()` | `TransportCore.type` / `resize` record before `log.append`; `Outbox.send`: `newEnd <= recorded.inputEnd` |
| `old_num` | Nothing more: it is the front, or a state this process sent | | `Outbox.send` (`baseStateUnknown`). Unchanged |
| `throwaway_num` = `t` | `FRONT` with number `t` (or `t` is the checkpoint's front) | `write()` | The front moves in memory only after its `FRONT` is appended; `Outbox.send`: `throwawayNum <= recorded.frontNumber` |
| `ack_num` = `n` | `REMOTE` with `newNum` = `n` (or `n` is in the checkpoint) | `write()` | A remote state is stored only after its `REMOTE` is appended; `Outbox.send`: `ackNum == recorded.newestRemoteNumber` |
| `ack_num` = 2^64 - 1 | `SERVER_SHUTDOWN` | `write()` | `serverShutdownSeen` is set only after the append; `Outbox.send`: `recorded.serverShutdown` |
| Timestamps, chaff | Nothing | | |

Before the first of these `write()` calls after a synced checkpoint, both `counters` slots say
`open(boot)` (two full syncs). That is the one place where the old "dirty before send" rule
lives on, as "open before append" (J4 below).

### 4.2 Which writes need what

| Write | Needs |
|---|---|
| A record appended to the journal | `write()` returned. No sync |
| A new generation made while the record is `open` (compaction in the foreground): the temporary file, its rename, removing the old file | The calls returned. No sync |
| A reservation (new limits) | Full sync of each slot, both slots (R1). Unchanged |
| `open(boot)` | Full sync of each slot, both slots, before the first append |
| Sealing: the new generation, its rename, the mark | Full sync of the file, rename, full sync of the directory, then one slot with full sync |
| `ended`, `dead` | Full sync of each slot, both slots. Unchanged |

"Full sync" is `Storage.sync` (`fcntl(F_FULLFSYNC)` on Apple platforms, R21).

### 4.3 Where the hooks sit

**The gate protocol** gets one method and one read-only property. Every durable change of the
transport goes through the method:

```swift
/// One change of the transport's durable state, recorded before it is applied.
public enum DurableTransition: Equatable, Sendable {
    case input(firstIndex: UInt64, events: [UserEvent])
    case front(number: UInt64, inputCount: UInt64, receiverSequence: UInt64)
    case remote(oldNum: UInt64, newNum: UInt64, throwawayNum: UInt64, diff: [UInt8],
                receiverSequence: UInt64)
    case throwaway(UInt64, receiverSequence: UInt64)
    case serverShutdown(receiverSequence: UInt64)
}

public protocol DurabilityGate: AnyObject, Sendable {
    // ... the members of today ...

    /// Records the transitions, in order. When it returns, they survive the death of the
    /// process. If it throws, none of them may be applied, and none of them is in the record.
    func record(_ transitions: [DurableTransition]) throws

    /// Where the journal ends now; nil for a gate without a journal. Read together with a
    /// checkpoint (section 7).
    var journalPosition: JournalPosition? { get }
}
```

No default implementations: a gate wrapper that forgot to pass `record` on (`LoggingGate` in
`moshcli`, test doubles) must not compile.

**`TransportCore`** is rearranged into "plan, record, apply". The apply functions are the only
code that changes durable state, and replay calls the same ones.

```
type(bytes) / resize(size):                     (TransportCore.type, .resize)
    guard acceptsInput
    try gate.record([.input(firstIndex: log.end, events)])   // throws: event .gateFailed, return false
    recorded.inputEnd += events.count
    apply: log.append(events); currentSize
    return true

receive(datagram):                              (TransportCore.receive, .process)
    decrypt; sequence, timestamp, RTT, last heard          // memory only, as today
    fragment assembly                                      // memory only
    plan = what this instruction changes, computed without changing anything:
        .front           if ack_num names a sent state above the front and is not 2^64 - 1
        .serverShutdown  if new_num is 2^64 - 1 and it was not seen before
        .remote          if new_num is not held, old_num is held, throwaway_num <= old_num,
                         the queue rule lets it in and the diff applies to a copy of the base
        .throwaway       if the throwaway would act and no state is stored
    if the plan is not empty:
        try gate.record(plan)        // throws: drop the instruction, event .gateFailed, return
        note the plan in `recorded`
    apply each transition                // applyFront, applyRemote, applyThrowaway, applyServerShutdown
    then what is not durable: ackNum, pendingDataAck, senderLastHeard, events
```

- `plan` follows `Transport::recv` step by step (S1): the ack first, then the shutdown case,
  the duplicate check, the base check, the throwaway, the queue rule, the diff.
- A `.front` and a `.remote` from one instruction are one `record` call and one `write()`:
  `[FRONT][REMOTE]`. Either alone is a state the client could have reached (an ack without the
  state, or the reverse), so a kill between the two frames is covered by L1.
- A failed `record` leaves memory as if the datagram had been lost. The server repeats: a
  state under its own number until acknowledged, an ack with every instruction.
- The core records in every phase; the gate decides what a record is still worth. Once
  `ended` or `dead` is in both slots the record will never be resumed, and the gate drops
  `record` calls (the journal is retired). Two things are never recorded: anything after a
  recorded `SERVER_SHUTDOWN` (it must be the last record), and the server's ack of our own
  shutdown (2^64 - 1 never enters the journal; it can only arrive after a shutdown datagram
  left, which the gate allows only once `ended` is in both slots, R16).
- After a recorded `SERVER_SHUTDOWN` the core plans nothing and applies nothing: "not
  recorded" always means "not applied" (J1 has no exception). An instruction that arrives
  then causes only the repeat of the ack 2^64 - 1. In particular an `ack_num` that names a
  state sent before the shutdown was seen, which the server's repeats carry
  (`networktransport-impl.h:159-160`), does not move the front (R2-6).
- `applyFront(number:inputCount:)` takes both values from the transition, live and at replay.
  Live, the plan reads the count from the sent state the ack names; at replay the sender
  holds the front alone and could not look it up (J11; S-4).
- `recorded` is a small private struct in the core (`frontNumber`, `frontInputEnd`,
  `inputEnd`, `newestRemoteNumber`, `serverShutdown`), changed only where `gate.record`
  returned (and seeded from the core's own state when the core is made: from the result of a
  replay, or, for a new session, from its initial log, whose first Resize is in the checkpoint
  of `journal.1` and in no `INPUT` record; R2-4). It is a second set of books beside the
  sender's and receiver's own lists, and the send point compares the two.

Where today's code goes:

| Today (`TransportCore.swift`) | Stage 2 |
|---|---|
| `type`, `resize`: `log.append` | Record `.input`, then `applyInput` |
| `processAcknowledgment(through:)`: drops the sent states below the ack | Plans `.front`; `applyFront` drops them. The ack of our own shutdown (2^64 - 1) is not recorded: the record is `ended` by then |
| `process`: duplicate check, base check, `processThrowaway`, queue rule, `apply(diff:)`, insert | `planRemote`, which changes nothing (the queue rule counts what the throwaway would leave; the quench timer is set afterwards with the other non-durable things), then `applyRemote` or `applyThrowaway` |
| `processServerShutdown` | Plans `.serverShutdown`; `applyServerShutdown`. The final screen stays in memory only |
| `rationalizeStates` (`log.discard`) | Unchanged; it acts on the applied front |
| `init(restoring:)` | The same, then the apply function of each replayed transition; the `Outbox` and `recorded` are made from the result |

**`Outbox.send`** gets three checks next to the existing ones, before anything is encrypted.
Each is a new `InvariantViolation` and halts the transport like the others:

| Check | Violation |
|---|---|
| `request.throwawayNum <= recorded.frontNumber` | `.frontNotRecorded(throwaway:front:)` |
| `request.ackNum == recorded.newestRemoteNumber`, or it is 2^64 - 1 and `recorded.serverShutdown` | `.ackNotRecorded(ack:newest:)` |
| `request.newEnd <= recorded.inputEnd` | `.inputNotRecorded(end:recorded:)` |

**`FileBackedGate.record`** (one lock with the counters):

```
record(transitions):
    ended or dead is in both slots          -> return (the journal is retired)
    ended was asked for, not yet in both    -> write it to both slots (R16); then return
    dead was asked for, not yet in both     -> write it to both slots (J15); then return
    the gate is not armed                   -> throw notArmed; nothing is written       [J14]
    state is not open, or open is not known to be in both slots
                                            -> write open(b) to both slots (full sync each)   [J4]
    journal.append(frames of the transitions)       // one pwrite at the journal's end
```

Any of these writes that fails makes the call throw, and the transitions are not applied.

`willSendDatagram()` no longer writes "dirty". It counts, and completes an `ended` or `dead`
mark that is
not yet in both slots (R16, J15).

**`Journal.append`** (J10): one `pwrite` of all frames at `end`, repeated for short writes. On
an error the file is cut back to `end` (`ftruncate`); if that fails too the journal is
"poisoned": every append throws until a compaction has installed a new file, and the gate asks
for one at once (the new file is made from the export and from the bytes before `end`, so what
lies behind `end` is left behind). Either way the call throws and nothing was applied. The
journal checks what it is given against its own count (`INPUT.firstIndex == inputEnd`, a
`FRONT` above the last) and throws if it does not fit.

### 4.4 Input accepted by the session API

`ResumeCoordinator.type` → `MoshSession.type` → `MoshConnection.type` → `TransportCore.type`.
The last one records the `INPUT` and only then appends to the input log, with no suspension in
between (`MoshConnection.type` is one actor call). So when `type` returns true the bytes are in
the journal. When it returns false they are not in the log and never go on the wire from this
process, and the journal's end has not moved. The same holds for `resize`. (One corner: a
write that failed half way and could not be cut back leaves bytes behind the journal's end
until the compaction that follows. A single `INPUT` record can only be there in part, and a
part is cut by any reader. A paste of more than 1 MiB is several records, and whole ones
among them would be found by a restart that came first: that part of the paste would then be
delivered, once.)

In the foreground this is one `write()` per call. In the background (the record is sealed and
the session quiesced) the coordinator first makes the record `open` (both slots; if that fails
the input is refused, as in C6 today), lets the session take the input, and seals again.

Input before `start()` is still refused (C11); section 14, attack 7.

### 4.5 New invariants (for `docs/RESUME.md` when this is built)

| # | Invariant | Enforced by |
|---|---|---|
| J1 | **Log before apply.** The front, the input log, the held remote states and "server shut down" change only after their record was appended | `TransportCore` (plan, record, apply) |
| J2 | **Accepted input is journaled.** `type` and `resize` return true only after the `INPUT` append returned | `TransportCore.type`, `.resize` |
| J3 | **The send point checks the books.** No instruction with a throwaway above the recorded front, an ack that is not the recorded newest state, or input beyond the recorded end | `Outbox.send` |
| J4 | **Open before append or rename.** A record is appended, and a generation gets its name, only while both slots say `open(b)` for this boot. (One rename comes before: the conversion of a stage 1 record, whose slots say `clean(id)` and name the file `snapshot`, never a journal) | `FileBackedGate.record`, `.seal`, `.compact` |
| J5 | **Sealed means one synced checkpoint.** "Sealed" is written only after the generation and its name are synced, and only if nothing was appended since the export it holds; check and write are one critical section with `record` | `FileBackedGate.seal` |
| J6 | **An open record is resumed only in the boot that wrote it** | `SessionRecord.loadState` |
| J7 | **Only the last record can be torn; anything else is damage** | The reader (3.4) |
| J8 | **Only the highest generation present is read.** It is never passed over for a lower one, whatever is wrong with it | `SessionRecord.loadState` |
| J9 | **A generation gets its name complete**: checkpoint plus every record appended since the export, copied under the append lock | `Journal.replace` |
| J10 | **A failed append changes nothing**, in memory and in the file | `Journal.append`, `TransportCore` |
| J11 | **Replay runs the code that ran live** | `TransportCore.init(restoring:inputBase:replaying:)` |
| J12 | **The input window never shrinks for a record** (a restored first state must not hold less input than an earlier one) | Journal header `inputWindow`; the restore uses the larger of it and the configuration's; every later generation's header carries the window the core then uses (the export has it, section 7) |
| J13 | **No number comes from the journal** (R1 to R3 unchanged) | `FileBackedGate` |
| J14 | **Armed before open, append or rename.** The gate of a cold-started record appends nothing, makes no generation and writes neither `open` nor `sealed` until `beginSending()` has cut the torn tail, converted a stage 1 record and written `open(b)` to both slots. `beginSending()` is the only way out of `clean(id)` (3.5) | `FileBackedGate` (`notArmed`), `ResumeCoordinator` |
| J15 | **`ended` and `dead` are final from the call on.** Every later slot write of the gate writes the final state (3.5) | `FileBackedGate` |

R4 to R8 of stage 1 (dirty before send, the clean mark, the snapshot replaced whole) are
replaced by J4 to J9; C5, C6, C9 and C10 change accordingly (section 10.4).

## 5. Restore

On the way to `.resumed`, `coldStart` writes nothing and sends nothing; all writes of a resumed
cold start happen in `start()` (C1, C2 unchanged). A fallback marks the record as today (C4).

**`coldStart`:**

1. Take the lock. Check the backup exclusion. Read `meta` and `counters`.
2. Decide by the record's state:
   - `ended`: fallback `.ended`. `dead`: fallback `.givenUp`.
   - `open(d)`: if the current boot identity is unknown (section 8) or `d` is 0: fallback
     `.bootUnknown`. If both are known and differ: fallback `.rebooted`. Either way the record
     is marked `dead`. Otherwise go on.
   - `sealed(id)`: go on; the journal must be exactly header and one `CHECKPOINT` with that
     id (another id: `.snapshotDoesNotMatch`; anything after it, also a torn tail: DAMAGED).
   - `clean(id)` (stage 1): the checkpoint is the file `snapshot`, as today; there are no
     records, and step 3 is skipped.
3. Find the journal: the highest `g` among the files named `journal.<g>`. None: fallback
   `.missing(.journal)`. Read it as in 3.4. DAMAGED: fallback `.damaged`. TORN: the `Journal`
   object
   remembers (generation, cut offset); the file is not touched.
4. Decode the `CHECKPOINT` with `SnapshotCodec` (the body is unchanged) into a
   `SessionSnapshot`; decode the records into `[DurableTransition]`.
5. If the last record is `SERVER_SHUTDOWN`: fallback `.ended` (and the mark `ended` is
   written, which the dead process was about to do).
6. Get the key (`KeySource`, C12 unchanged).
7. Build the session: `MoshSession(restoring: checkpoint, inputBase: header.inputBase,
   inputWindow: header.inputWindow, replaying: transitions, ...)`. The core is built as today
   from the checkpoint and then applies each transition with the apply functions of 4.3. A
   transition that does not fit: fallback `.snapshotRefused`, record marked `dead`.
8. Return `.resumed(coordinator)`. Nothing has been written or sent. The gate is unarmed (J14).

Where every value of the rebuilt transport comes from:

| Value | Source |
|---|---|
| Sequence number, state number, fragment id | `counters`: the highest limits in any valid slot (R2); `start()` reserves new blocks |
| Front `A` and its input count | The last `FRONT`; without one, the checkpoint's `acknowledgedStateNumber` and `inputBase` |
| Input stream | The checkpoint's pending input (first index `inputBase`), then the `INPUT` records |
| Pending input | The stream from the front's input count on. This is the plan's `FRONT(num, inputCount)` rule, with events counted, not records (section 13) |
| Held remote states | The checkpoint's, then each `REMOTE` in append order: look up `oldNum`, apply the diff to a copy, drop the states below `throwawayNum`, insert `newNum` in number order. `THROWAWAY` drops only. Pruning happens at each record, as it did live; the result equals "replay all, prune afterwards", and a state's base is always there when its record is replayed, because it was there live (L0) |
| `ack_num` | The number of the newest held state |
| Highest throwaway seen | The lowest held number of the checkpoint, raised by each record |
| Expected receive sequence | The largest of the checkpoint's value and every record's `receiverSequence` |
| Echo ack | Part of each terminal state; rebuilt by the diffs (`TerminalRemoteState.apply`) |
| Terminal size | The last Resize in the stream; without one, the checkpoint's |
| Input window | The larger of the configuration's and the header's (J12) |
| Sent states | `[A]` alone, with an old timestamp, as today |
| RTT, timers | Fresh estimator; ack and send due now; "last heard" now; probing on. As `TransportCore.init(restoring:)` today |
| Fragment assembly, saved timestamp, pending data ack, quench timer | Empty or zero |
| Clipboard policy | The checkpoint's (step 9 below) |

**`start()`** (`ResumeCoordinator.runStart`, `FileBackedGate.beginSending`):

1. The journal cuts its own torn tail, if it has one (`ftruncate` of the generation the cut
   was found in; the gate's journal cannot be another file, because an unarmed gate makes no
   generation, J14).
2. For a stage 1 record: write a journal generation from the checkpoint (3.6).
3. One counters change, both slots, full sync each: new reservations and `open(b)`. The gate is
   armed from here.
4. Remove what is stale: `journal.*.tmp`, lower generations, `snapshot`.
5. `session.start()`: the first event is the restored screen (`isLive` false); a socket is
   opened and the first datagram leaves.
6. If the view's size differs from the restored terminal size: `resize(size)`, an ordinary
   journaled input. (Today's import adds that Resize while the session is built. Under J2
   input enters the log only through the journal, and `coldStart` must not write. So
   the restoring initializers of `TransportCore`, `MoshConnection` and `MoshSession` lose
   their `currentSize` parameter: nothing can add input while a session is rebuilt, so there
   is no `record` call before the gate is armed (R2-2). The coordinator announces the size
   here, with the mechanism it already has for `sizeBeforeStart`. The app passes nil already
   (`SessionLauncher.swift:92`); `moshcli resume` and two tests
   (`ResumeEndToEndTests.swift:143`, `:188`) pass a size today and change.)

If step 1, 2 or 3 fails, `start()` throws, nothing was sent, the gate stays unarmed and the
record is as resumable as before (C1). A second `start()` begins at step 1 again.

**Before `start()` has succeeded** the gate is unarmed (J14), and the calls that could write
do this:

| Call | With an unarmed gate |
|---|---|
| `type`, `resize` | Refused (C11); `resize` keeps the size for step 6 |
| `enterBackground()` | Writes nothing and reports what the state on disk promises: `.clean` for `sealed(id)` and `clean(id)`, `.openOnly` for `open(d)`. There is no seal from the replayed state: it would be a new generation beside an uncut tail or an unconverted record (S-3), and its checkpoint would hold a replayed screen under the old clipboard policy (step 9 below) |
| `enterForeground()` | Runs a deferred `start()`; no `markOpen()` of its own |
| `shutdown()` | `markEnded()` directly, without `markOpen()` before it (S-1), then the session's shutdown as today. If the mark fails half way, the disk says what the cold start found, the gate's intent is final (J15), and `ended` is in both slots before a shutdown datagram passes (R16) |
| `abandon()` | `markDead()` |

Further points:

7. **The first datagram.** With pending input: `new_num` = the gate's next state number `N'`,
   `old_num` = `throwaway_num` = `A`, `ack_num` = the newest held remote state, and the diff of
   the pending input (as much as the input window allows). With nothing pending: an empty ack
   with the same numbers. Retransmissions reuse `N'`. A lost first datagram is retried every
   RTO + 100 ms for 10 s (the estimator is fresh, so 1.1 s). This is stage 1's first datagram.
8. **Partial fragment assemblies.** The client's own is lost with the process; a fragment of
   the same instruction that arrives later finds an empty assembly and is dropped when the
   next id comes. On the server, the dead process's last instruction may be half assembled;
   the new process's first fragment has a new id from the gate and clears it (S13).
9. **Clipboard: no second write of an old OSC 52.** `MoshSession.start()` of a restored
   session first observes the checkpoint's newest screen against the checkpoint's policy, as
   today (the two agree for every checkpoint this code writes, C13). Then, if any `REMOTE` was
   replayed, it makes the replayed newest screen the baseline (`ClipboardPolicy.baseline`)
   without a decision. So a copy that arrived after the checkpoint is never written at a
   restore. The dead process wrote it when it arrived; the one copy that can be lost is one
   whose `REMOTE` was appended less than an event delivery (milliseconds) before the kill.
   The other choice, writing it again, could overwrite something the user copied on the phone
   since. A later change of the field is a new copy and is written as always.
10. **A server shutdown seen before the kill.** With `SERVER_SHUTDOWN` in the journal: fallback
    `.ended`, nothing is sent. The server exits by itself within 10 s of its first shutdown
    instruction whether or not it was acknowledged (S14). If the kill came before the append,
    the session is resumed; the server repeats its shutdown if it is still there (and the
    record ends then), or is gone, which the probe finds after 15 s and answers with a new
    session, as for any server that ended while the app was away (PLAN section 4).
11. **A client shutdown in progress.** The record says `ended` in both slots before the first
    shutdown datagram (C7, R16), so the cold start is `.ended`: nothing is sent, no new session
    is started, and the app's existing path for ended records kills the old server after the
    identity check if the request never arrived (`SessionLauncher.finishEnded`). Unchanged. A
    kill while the mark is half written (one slot) reads as `ended` if that slot is whole,
    otherwise as `open`: the session resumes, and nothing of the shutdown was sent.

## 6. Proof obligations

By L1 a restart finds `S = J + p`. Let `A` be the front of `S` and `c` its input count.

- **L2. The server holds `A`, with exactly the first `c` input events.** `A` is the
  checkpoint's front or the number of a `FRONT` record. A `FRONT(N)` is planned only when an
  authentic server instruction carried `ack_num = N` and `N` is a state the planning process
  itself sent, with end `c`; by S4 the server then held `N`, built from this client's own
  diffs. By S3 it erases
  `N` only on an instruction with `throwaway_num > N`. Every instruction ever sent carried the
  memory front of its time (`sentStates[0].num`), which was at most the journal's front of
  that time (J1), which is at most `A` (fronts only go up). For the `p` case: a `FRONT` in `p`
  was never applied, so no instruction carried it, and the server acknowledged it, so it holds
  it.
- **L3. The stream of `S` contains every input event that any datagram ever carried, at the
  same index.** An event enters the log only after its `INPUT` append returned (J2), and a
  state is cut from the log. The one event with no `INPUT` record is the first Resize of a new
  session: it is in the checkpoint of `journal.1`, which is that core's own `checkpointState()`
  (10.3), so the log and the file hold one copy of it, not two (R2-4). Events in `p` were never
  sent.
- **L4. The client of `S` holds the server's front.** The server's front is a number the
  client sent as `ack_num` (S5). The client sends `ack_num = n` only when state `n` is stored,
  which is after `REMOTE(n)` was appended (J1, J3), and `n`'s base was held when the record
  was appended, so replay rebuilds `n` (L0, by induction over the journal). `n` is dropped at
  replay only by a recorded throwaway `t > n`; `t` was the server's front when it sent that
  instruction (S7), and the server's front never goes back, so the server's front is not `n`.
- **L5. Numbers are fresh.** The gate of the new process starts at the highest limit in any
  valid slot, which is above every number any earlier process was handed (R1, R2, R10).
- **L6. Every append went to a whole journal that was the record's authority.** A gate
  appends only when armed (J14), and arming cuts the torn tail, converts a stage 1 record and
  writes `open(b)` first. So no frame was ever written behind a torn frame (the reader would
  hide it behind the torn length, an applied `INPUT` would be lost and its index used again:
  N2 by `statesync/user.cc:68-69`), none into a journal file beside slots that say
  `clean(id)`, and no slot says `open` beside such a file. L0 and L1 are statements about
  armed gates; an unarmed gate changes nothing durable but the final marks.

### N1: a sequence number twice

L5. The journal has no part in it. What is new in stage 2 is that a process sends after an
unannounced death of the one before; its first sequence number is the reserved limit, as after
a stage 1 resume. `Outbox.send` refuses a number that is not above the last one or not below
the limit. The server needs the numbers to go up for a second reason: a datagram below its
expected sequence does not move it to the client's new address (S10).

### N2: a state number reused, or a state with less input than an earlier one

- New states get numbers from the gate (L5), so `N'` is above every number the server holds,
  goes to the end of its list and is never taken for a held state (S1b, S1g).
- `N'` is built on `A`, which the server holds with the client's idea of its content (L2), and
  contains the stream up to `min(end, c + window)`. Every earlier state ended at or before
  `min(its end, its front's count + window)`; ends and fronts only grow, the stream is the same
  at the same indices (L3), and the window does not shrink (J12). So every state the server
  holds is a prefix of `N'`. `diff_from` and `subtract` find their prefixes (S6).
- The same holds for every later state, by the existing `Outbox` checks
  (`stateInputShorter`, `stateContentChanged`), which start from `A`.
- Exactly once: the server passes to the pty only what `N'` has beyond its previous newest
  state (S6), so input it already had is not applied again, and input it did not have arrives
  in `N'`.

### N3: `throwaway_num` above `old_num`

The first instruction has both equal to `A`. Later ones pass `Outbox.send`'s existing check.
The server looks up `old_num` before it erases (S1c, S1d), so with `throwaway_num <= old_num`
and `old_num` held, the erase leaves at least that state: no `fatal_assert`, no use of an
erased state (S2). And `old_num = A` is held (L2).

### N4: a fragment id reused

L5 for fragment ids; one id per instruction (`Outbox.send`), so the server never sees one id
with two contents. A half-assembled instruction of the dead process is cleared by the first
fragment with the new id (S13).

### Soft failure: no shared base

- c2s: the client's base is `A` (L2), afterwards the front or a state it sent recently, as in
  mosh. An ack for a state the new process did not send (the dead process's) is ignored
  (`TransportCore.processAcknowledgment`, as S5); the client keeps sending `N'` on `A` until
  `N'` is acknowledged.
- s2c: after silence the server builds on its front (S7), which the client holds (L4). If the
  client's first `ack_num` names a state the server already thinned out (S8), the ack is
  ignored (S5) and the front stays, still held. An instruction built on a state the client
  never got is dropped, as in mosh, and the server falls back to its front within
  RTO + 100 ms.
- The detector for a lost base (`old_num == throwaway_num`, not held) cannot fire falsely: a
  state the client lacks after replay was dropped by a recorded throwaway above it, so the
  detector's condition `throwawayNum >= highestThrowaway` is false for it.

### Every instant

"Next start" is in the same boot (section 8 has the other case). `N` is a client state, `n` a
server state. Rows marked (2) are a second kill, during or after a restore.

| # | The kill falls | On disk | Next start |
|---|---|---|---|
| A1 | In `type`, before the `INPUT` append | `J` | Resumes without the input. `type` had not returned |
| A2 | Inside the `INPUT` append | Torn tail, cut: `J` | As A1 |
| A3 | After the append, before the log has it or `type` returned | `J`+INPUT | Resumes; the input is pending and is sent once. The caller was never told "taken"; the user did type it |
| A4 | After `type` returned, before a state number is taken; inside a reservation (two slot writes); before the datagram is built | `J`+INPUT; `counters` with the old or new limits (R9, R10) | As A3. Numbers taken and not used are skipped |
| A5 | With none, some or all datagrams of state `N` handed to the socket | The same | As A3. The server has nothing, a partial assembly (cleared, S13) or `N`; `N'` contains `N` (N2) |
| A6 | After the server acknowledged `N`; the ack is on its way, in the socket, or decrypted and not yet recorded | The same, front still `A` | As A5: the input of `N` is sent again inside `N'` and applied once (S6) |
| A7 | Inside the append `[FRONT(N)]` or `[FRONT(N)][REMOTE(n)]`, in the first frame | Cut: as A6 | As A6 |
| A8 | In that append, `FRONT` whole and `REMOTE` cut | ... `FRONT(N)` | Front `N` (held by the server, L2), pending input after `N`. `n` is not held and was never acknowledged |
| A9 | After the append, before memory changed | ... `FRONT(N)`, `REMOTE(n)` | The state the process was about to enter. It sent nothing from it |
| A10 | After memory changed; before, while or after the next instruction (`throwaway_num N`, `ack_num n`) leaves | The same | The same state. The server may have erased below `N` and moved its front to `n`; both are held |
| B1 | Inside a `REMOTE` append | Cut | The state is not held and was not acknowledged; the server sends it again or builds on its front |
| B2 | After a `REMOTE` append, before or after the ack for it is sent (the 100 ms ack delay) | ... `REMOTE(n)` | Holds `n`; acknowledges it in the first datagram |
| B3 | Around a `THROWAWAY` append | With or without it | With it, states below the throwaway are dropped; the server's front is at or above it |
| B4 | Before the `SERVER_SHUTDOWN` append | Without it | Resumes; section 5, step 10 |
| B5 | After it, before or after the ack 2^64 - 1 | With it | `.ended`; nothing sent |
| C1 | Compaction (foreground): after the export, while `journal.<g+1>.tmp` is written or the tail is copied | `journal.<g>` whole, a `.tmp` | From `journal.<g>`; the `.tmp` is removed |
| C2 | After the rename, before `journal.<g>` is removed | Both generations | From `journal.<g+1>` (J8), which was complete when it got its name (J9); the lower one is removed |
| C3 | After the old file is removed | `journal.<g+1>` | From it |
| D1 | Seal: quiesced, before the new generation's rename (also inside its full sync) | `journal.<g>`, `open(b)` | From `journal.<g>` |
| D2 | After the rename, before or inside the directory sync, before the slot write | `journal.<g+1>` (one checkpoint), `open(b)` | From it |
| D3 | Inside the slot write of `sealed(id)` | That slot cut: the other says `open(b)` | From `journal.<g+1>` |
| D4 | After it | `sealed(id)` | From it; also in another boot |
| E1 | Return to the foreground: inside the first slot write of `open(b)`, or between the two | One slot `open(b)` or cut, one `sealed(id)` | Either reading resumes from the checkpoint; nothing was appended yet |
| E2 | After both slots, before the first append | `open(b)`, one checkpoint | From it |
| F1 | (2) Cold start: before `start()` wrote anything | As found | The same decision again |
| F2 | (2) After the tail cut, inside or after the counters change, before the first datagram | Tail cut; old or new limits | Resumes; numbers start at the highest limit |
| F3 | (2) After the first datagram `N'`, before any reply was recorded | The journal as restored | Resumes: front still `A`, a new number `N''` above `N'`, the same or more input. The server holds `A` (the throwaway was `A`) and perhaps `N'`, a prefix of `N''` |
| G1 | Input in the background: before or inside the `open(b)` writes | `sealed(id)` or `open(b)`, one checkpoint | Resumes without the input; `type` had not returned |
| G2 | After `open(b)`, around the `INPUT` append | As A1 to A3 | As A1 to A3 |
| G3 | During the second seal | As D1 to D4, with the input | Resumes with the input |
| H1 | `shutdown()`: around its `open(b)` writes (in the background), or inside the first slot write of `ended` | `sealed(id)` or `open(b)` | Resumes. Nothing of the shutdown was sent (R16) |
| H2 | After one or both slots say `ended` | `ended` | `.ended`; section 5, step 11 |
| H3 | Giving up: before, inside, after the `dead` writes | `open(b)` or `dead` | Resumes (the server may well live), or fallback |
| I1 | `create`: before `counters` exists | No `counters` | Not a record: deleted (R18) |
| I2 | After `create`, before or after the first datagram, before the server's first state | `open(b)`, `journal.1` with the initial checkpoint | Resumes on state 0 with the first Resize pending. If the server was started more than 60 s ago and no client state has reached it, it has exited (S12); the probe finds that |
| M1 | First start of a stage 1 record: before both slots say `open(b)` | Stage 1 `clean(id)`, `snapshot`, perhaps `journal.1` | Resumes from `snapshot` again |
| M2 | After it | `open(b)`, `journal.1`, perhaps `snapshot` | From `journal.1`; `snapshot` is removed |
| M3 | A stage 1 record, cold start, then `shutdown()` or `enterBackground()` before `start()` armed the gate; anywhere in them | `clean(id)` and `snapshot` as found, or `ended` | From `snapshot`, or `.ended`. Never `open` beside a journal that is not the authority (J14) |
| M4 | (2) An `open(d)` record with a torn tail, cold start, then the same calls before `start()` | As found, the tail uncut, or `ended` | The same decision again; nothing lies behind the torn frame (L6) |
| H4 | A `dead` mark failed half way and the process lives; then a `record`, a reservation, or a kill | `dead` in one or both slots, or (no slot took it, then a kill) the state before | Fallback; in the last case a resume from a true journal. `open` is never written over the mark (J15) |
| D5 | A `sealed(id1)` slot write failed half way; then a second seal or a compaction, killed around its rename | `open(b)` in both slots (written before the rename, J4), `journal.<g+1>` or `journal.<g+2>` | From the highest; no slot names an older checkpoint |
| I0 | `create`: the session exists and its checkpoint is taken; before or inside the write of `journal.1` | No `counters` | As I1 |

No row but H4 (a record that was given up) ends in a fallback; none in a reused number, a
shorter state or a lost base. Rows A1, A2 and G1
lose input the API had not accepted; no row loses input for which `type` returned true.

## 7. Compaction, checkpoints, sealing

A generation is replaced by a new one that starts with a checkpoint of the current state.
There are two ways to do it, and they differ only in what is synced.

**When:**

| Trigger | Kind |
|---|---|
| The generation holds 128 KiB or 2,048 records after its checkpoint | Compaction (no sync) |
| The first `INPUT` record of the generation is 30 s old (noticed at the next append) | Compaction. Typed bytes, passwords among them, then leave the file within about 30 s of being typed; the new checkpoint holds only what the server has not acknowledged |
| Leaving the foreground (`enterBackground()`) with an armed gate; input accepted in the background | Seal (synced) |

Not more than one compaction a second, unless the generation is past four times the size
limit. The gate signals "compaction wanted" after an append (`onCompactionWanted`); the
coordinator runs it in its queue (`inOrder`), so it never overlaps a seal, a return to the
foreground or input.

**The sequence.** Steps marked (seal) are left out in a compaction.

| # | Step | Storage step |
|---|---|---|
| 1 | Export: in one actor call of the connection, the transport's checkpoint (front, pending input, held states, counters floor, receive sequence, size), the front's input count, the input window the core uses (it goes into the new header, J12; R2-7), and the journal's position `p` = (generation, end offset). `MoshSession` adds its clipboard policy. A seal exports a quiesced session; a compaction a live one | none |
| 2 | Encode the `CHECKPOINT` with a new random id. Create `journal.<g+1>.tmp`, write header and checkpoint | `journal.next.create`, `journal.next.write` |
| 3 | (seal) Full sync of the temporary file | `journal.next.fsync` |
| 4 | Take the gate's lock. If the gate is not armed (J14), or the journal's generation is not `p`'s (a stale export): give up. If `open(b)` is not known to be in both slots (a `sealed` or `open` mark failed half way): write it to both, full sync each, before going on (J4; S-2) | `counters.write`, `counters.fsync` (only then) |
| 5 | (seal) If the journal's end is not `p`'s offset: give up, remove the temporary file, report "not sealed" (J5). (Compaction) copy the bytes from `p`'s offset to the end of `journal.<g>` behind the checkpoint | `journal.next.append.tail` |
| 6 | Rename `journal.<g+1>.tmp` to `journal.<g+1>` | `journal.rename` |
| 7 | Appends go to the new file from here (descriptor, end, generation swapped under the lock) | none |
| 8 | (seal) Full sync of the directory | `dir.fsync` |
| 9 | (seal) Write `sealed(id)` to one slot, full sync | `counters.write`, `counters.fsync` |
| 10 | Release the lock. Remove `journal.<g>` | `journal.old.remove` |

Why this is right:

- The checkpoint is the state at position `p` (L0: the export and `p` are read in one actor
  call, and only that actor appends). The records after `p` are the transitions since. So the
  new file replays to the same state as the old one (J9). They are copied byte for byte: their
  input indices are absolute and the header carries `inputBase`.
- The lock is held from the copy to the swap, so no record can go to the old file after the
  copy. It is held for a `pread`, a `pwrite` and a `rename`; during a seal also for two full
  syncs, while the session is quiesced and sends nothing.
- A generation is visible under its name only when complete, and the highest name wins (J8).
  The reader never goes back to a lower generation: if the highest is damaged the record is
  not resumed. A lower generation is stale from the first append to its successor. (`sealed`
  names its checkpoint, so a wrong file is refused. `open` names no generation: if the highest
  file vanished and a lower one stayed, the lower one would be read. No step of this code and
  no process kill produces that; a power loss can, and then the boot rule decides.)
- A compaction runs only while the record is `open` and the session started (in step 8 of
  section 12, where `open` does not exist yet: while the gate's state is dirty and the gate
  has a journal); in the
  background the seal does the same job.
- A seal starts from `open` only. `seal` answers "sealed" without writing only while
  `sealed(id)` is the last slot write the gate completed and no slot write was started since
  (nothing can have been appended, J4). After a `sealed` or an `open` mark that failed half
  way the gate does not know what the newest slot says, and it seals in full: `open(b)` to
  both slots (step 4), a new generation, the mark. So there is never a rename while a slot
  names an older checkpoint: the window of reviews A-3 and B-3 does not
  come back. The coordinator's `savedClean` shortcut (C10) stays as a second guard.
- A failed step before the rename removes the temporary file and leaves the old generation in
  use; the compaction is tried again at the next trigger. A failed directory sync or slot
  write leaves the record `open` on a complete new generation.
- Before the slot write of `sealed`, the gate forgets that `open` is in both slots, as it
  forgets "not clean" before a clean mark today (R11). If that write fails half way, a slot
  may say `sealed` while the gate goes on as `open`; the next append then writes `open` to
  both slots first (J4), so no record is ever appended under a slot that says `sealed`. Step 4
  does the same before a rename, so no generation gets its name
  under a slot that names another checkpoint either (S-2).

**Every crash point** is in the table of section 6, rows C1 to C3 (compaction) and D1 to D4
(seal). The step names above are what `moshcli --crashpoint` and the tests use.

**The lock, the counters, today's save:**

- The `flock` is held by the process that compacts; a restore takes it before it looks at
  generations, and removes temporary files and lower generations only in `start()`.
- Reservations are untouched. A reservation while the record is sealed writes both slots with
  the sealed state and higher limits, as it writes the clean state today.
- `enterBackground()` is today's save with the journal in the place of `snapshot`: quiesce,
  export, new generation, mark. The same three full syncs (file, directory, one slot).
- `SessionRecord.save` and `loadSnapshot` go; `seal`, `compact` and `loadState` replace them.

## 8. Reboot

Appends are not synced, so after a power loss or a kernel panic the journal may lack records
that were acted on, and renames may be undone. A restart cannot see that from the file.

**The identifier.** `BootIdentity.current() -> UInt64?`: a 64-bit FNV-1a digest (0 is mapped
to 1) of a string the system makes anew at every boot, or nil if it cannot be read.

| Platform | Source |
|---|---|
| Linux | The contents of `/proc/sys/kernel/random/boot_id` (a UUID, new at each boot; the same in every container on one kernel, which is right: the page cache is the kernel's) |
| iOS, macOS | `sysctlbyname("kern.bootsessionuuid")` |
| Tests, `moshcli --boot-id` | A fixed value (`FixedBootIdentity`) |

**Validity, checked at every read** (`BootIdentity.current()`, every platform; R2-3). The raw
value counts only if it is a UUID in text form: after white space and a trailing NUL are
removed, exactly 36 characters, hexadecimal digits in groups of 8-4-4-4-12 joined by hyphens,
and not all zeros. An error from the call, an empty string, another length or shape, or the
nil UUID give nil ("unknown"). The digest is taken over the lower-case form. The value is read
at the cold start's decision and again whenever `open(b)` is written; if two reads of one
process differ, the identity is unknown for the rest of that process. Unknown is always the
safe side: `open` is written with digest 0 and an open record is never resumed (the rule
below).

What no check at run time can show is a value that is well formed and yet the same in every
boot. J6 would then promise nothing after a power loss, and a resume from a journal that lost
records is N2. Whether iOS gives an app a per-boot UUID is a device question that step 0 of
section 12 answers and this file does not (section 15). If step 0 shows anything but "the same
in
two launches, another after a restart" on the phone, `DarwinBootIdentity` returns nil on iOS:
stage 2 is then stage 1 for a kill in the foreground, and safe.

Whether an app may read `kern.bootsessionuuid` on iOS is not known from anything in this
repository (section 15). The design is safe either way: if it cannot be read, `open` is
written with digest 0, which matches nothing, and a kill in the foreground ends in the
fallback exactly as in stage 1. `kern.boottime` is not used as a second choice: it moves when
the clock is set, so it would either lose sessions or, worse, match by accident.

**Where it is stored.** In the `open` state of the `counters` slots (3.5), written to both
slots with a full sync before the first unsynced append (J4).

**The rule** (J6), by the record's state at the cold start:

| State | Current boot | Result |
|---|---|---|
| `sealed(id)` | Any | Resumed. The checkpoint and its name were synced before the mark was written, and nothing was appended after it: an append needs `open` in both slots first. This is the case "the last thing written was a synced checkpoint" |
| `open(d)` | Digest equals `d`, and neither is 0 or unknown | Resumed. Every `write()` and `rename()` that returned is visible in the same boot |
| `open(d)` | `d` is 0, or the current identity is unknown | `.bootUnknown`: dead, like `.rebooted`, with a text that does not claim a restart (R2-12) |
| `open(d)` | Both known, and they differ | `.rebooted`: dead. This also covers a checkpoint written by a compaction in the foreground (not synced) and a seal that was killed before its mark |
| One slot `open(d)`, one `sealed(id)` | Any | The newest valid slot decides, as always. A seal's slot damaged later falls back to `open`: resumed in the same boot, dead after a reboot (a lost resume, never an unsafe one) |

What this costs: an app killed in the foreground and a phone restarted before the app is
opened again is a fallback, also when the restart was an orderly one. An app cannot tell an
orderly shutdown from a panic.

The plan says "treated as dead". That is `.rebooted`: nothing is sent under the old key, the
record is marked `dead` and handed to the app's fallback (new session, the old server killed
after the identity check), like any other given-up record.

## 9. Cost

**Appends.** No sync, one `pwrite` each.

| Event | Records | Bytes | `write()` calls |
|---|---|---|---|
| A key (`type` of one byte) | `INPUT` | 31 | 1 |
| The server's answer to it (ack of the client's state, and the echo) | `FRONT`, `REMOTE` | 37 + 49 + diff (a few tens of bytes) | 1 |
| A further server state for it (its echo ack, 50 ms later: `completeterminal.cc:130-160`, `mosh-server.cc:909-912`) | `REMOTE`, sometimes `FRONT` | about 55 to 95 | 1 |
| A received state with output | `REMOTE` | 49 + diff | 1 |
| Idle, every 3 s (S9): the server's empty ack, which also acknowledges the client's | `FRONT`, `REMOTE` | 86 | 1 |
| A line of 3,000 pasted bytes | `INPUT` | 3,030 | 1 |

So a keystroke is two or three small writes, 150 to 250 bytes together. An idle session
writes two records and 86 bytes every 3 s (103 KB an hour) and reaches the limit of 2,048
records after about 51 minutes.

**Heavy output.** From the corpus (`Tests/MoshTerminalTests/Corpus`, 38 cases, 2,916
instructions, 235,314 bytes of diffs): 81 bytes per instruction on average; `rec-htop` 340 on
average and 2,080 at most, `rec-less` 187, `rec-vim` 125, `rec-bash` 59; zlib would halve them
(116,242 bytes), which is not worth a compressor in this path. The server sends a state at
most every 20 ms (`SEND_INTERVAL_MIN`, `transportsender.h:52`; the interval is SRTT / 2,
`transportsender-impl.h:71-83`).

| Load | States per second | Journal bytes per second | A compaction every |
|---|---|---|---|
| htop over a link with 100 ms SRTT | 20 | 8 KB | 16 s |
| htop on a LAN (20 ms interval) | 50 | 20 KB | 7 s |
| Upper bound: a full repaint of 2 KB in every state, 50 a second | 50 | 106 KB | 1.2 s |
| The netem soak (wave 1: 634 datagrams received in 601 s, 238 typed lines) | about 1 | under 0.2 KB | by the 30 s input rule only |

**Compaction** (no sync): encode a checkpoint and write it. The repository's figures are for a
debug build: a full 100x30 screen is 6,071 bytes, 7.8 ms to encode and 6.4 ms to decode
(`docs/notes/wave1-term.md`); eight held states of a full 80x24 screen are about 15 KB
(`docs/RESUME.md`). So 10 to 20 ms on the coordinator's executor per compaction, at worst once
a second: 1 to 2 percent. The transport's actor is held only for the export (copies of values
that share their rows, about 1 us per state) and, through the gate's lock, for the tail copy
and the rename.

**Restore.** Decode the checkpoint and replay. The applier takes 260 us per instruction and
3.5 us per byte in a debug build (`docs/notes/wave1-term.md`), so a generation at its limits
replays in about half a second there (128 KiB of diffs: 0.46 s; 2,048 small records: 0.53 s).
That is why the limits are 128 KiB and 2,048. An interactive session's journal is a few
kilobytes and replays in milliseconds. The phone runs debug builds (review M6-11); no release
figures exist in the repository.

**Syncs,** with the phone's measurements from `docs/RESUME.md` (run 0014b1eee2b2):

| Operation | Full syncs | Stage 1 equivalent and its time on the phone |
|---|---|---|
| Appends, compaction | 0 | none |
| Seal on leaving the foreground | 3 | The save: 12.0 ms median, 15.6 ms p90, 16.5 ms max (a 1,402-byte snapshot) |
| `open` at the return to the foreground, and at a cold start (with reservations) | 2 | The first datagram after a save: 6.9 ms median, 8.3 ms max |
| A reservation (per 1,024 states, 65,536 datagrams) | 2 | 4.3 ms |
| `create` | As today (7 with a `key` file, 5 without), plus `journal.1` unsynced | 24.8 ms |

The foreground pays no sync it does not pay today. What is new is a `write()` of a few tens of
bytes per event; its time on the phone is not measured yet (section 12, step 12).

## 10. API changes

### 10.1 MoshTransport

- `DurableTransition`, `JournalPosition { generation, offset }` (new, `DurabilityGate.swift`).
- `DurabilityGate`: `record(_:)` and `journalPosition` (4.3). `InMemoryGate` implements
  `record` by keeping nothing (or, with `keepsTransitions: true`, a list for tests) and has no
  position. `markClean(ifDatagramsPassed:)`, `isDirty`, `datagramsPassed` stay for the
  in-memory resume (`moshcli resume-mem`, the transport's own tests).
- `TransportCore`:
  - `init(restoring:inputBase:inputWindow:replaying:cipher:gate:configuration:now:)`:
    three new parameters with defaults (`inputBase` 0, `replaying` nothing, `inputWindow` the
    configuration's). The `currentSize` parameter goes: a restoring initializer adds no input
    (J14; section 5,
    step 6). The new-session initializer seeds `recorded` from its own initial log (4.3).
  - Input indices are absolute: `InputLog` starts at `inputBase`, and so do the front's `end`
    and the `Outbox`'s `baseEnd`.
  - `checkpointState() throws -> TransportCheckpoint<Remote>` (`snapshot`, `inputBase` = the
    front's end): the export without the "quiesced" condition. `exportState()` stays and is
    `checkpointState()` plus that condition. Both throw `sessionEnded` as today.
  - `type` and `resize` also return false when the record could not be written.
  - New `InvariantViolation` cases (4.3) and `SnapshotError.replayFailed(String)`.
- `MoshConnection`: the restoring initializer takes the same three new parameters;
  `checkpointState()`; `TransportExport` gains `inputBase`, `inputWindow` (the one the core
  uses) and `position: JournalPosition?`
  (read in the same actor call as the snapshot).

### 10.2 MoshSession

-
  `MoshSession(restoring:inputBase:inputWindow:replaying:endpoint:gate:configuration:clock:makeTransport:)`:
  the same three new parameters; `currentSize` goes.
- `checkpointState()`; `SessionExport` gains `inputBase`, `inputWindow` and `position`.
- `start()` of a restored session: clipboard as in section 5, step 9.
- `terminalSize()` (the size last announced), for the coordinator's Resize at `start()`.
- No `SessionSnapshot.initial`: the checkpoint of `journal.1` is `checkpointState()` of the new
  session itself (10.3, `create`), so there is no second copy of its first events that could
  differ (R2-4).

### 10.3 MoshResume: the record

- `RecordState`: `.clean(snapshotID:)` (read only), `.sealed(checkpointID:)`, `.open(boot:)`,
  `.dead` (was `.dirty`), `.ended`. `CountersSlot` reads versions 1 and 2, writes 2.
  `RecordState.mayResume(currentBoot: UInt64?) -> Bool` says what the state alone promises
  (`clean` and `sealed`: yes; `open(d)`: only if `d` is not 0 and equals the current boot;
  `dead`, `ended`: no), for readers that only show a hint, like the app's host list.
- `RecordPart`: `+ .journal`.
- `BootIdentity` (protocol), `LinuxBootIdentity`, `DarwinBootIdentity`, `FixedBootIdentity`,
  `BootIdentities.platform`.
- `Journal` (internal): `append`, `position`,
  `replace(checkpoint:id:inputBase:inputWindow:from:durable:)`
  (refused while a cut is pending), the pending cut (generation, offset),,
  the reader of 3.4.
- `FileBackedGate`: `record`, `journalPosition`; `markOpen()` (return to the foreground,
  before input in the background); `markDead()` (was `markDirty()` where it meant "given up");
  `markEnded()`, `beginSending()` (now: tail cut, stage 1 conversion, reservations and
  `open`, clean-up); `onCompactionWanted`; `markClean(snapshotID:_:)` and `markDirty()` go.
  `willSendDatagram()` writes nothing but an unfinished `ended` or `dead`. `isArmed`; `record`,
  `markOpen()`, `seal` and `compact` throw `GateError.notArmed` until `beginSending()` has
  returned (J14).
- `SessionRecord`: `create(root:meta:key:blocks:hook:protection:boot:makeInitial:)`:
  `makeInitial` is called with the record's gate, which has no `counters` on disk yet, hands
  out no number and is not armed; it builds the new session on that gate and returns the
  session's own `checkpointState()`. `create` then writes `journal.1` from it, the initial
  counters (`open(b)`), and arms the gate. A caller cannot hand in a checkpoint of its own
  making (R2-4), and a kill before `counters` exists leaves no record (R18); `open(...)`
  unchanged in signature;
  `loadState() throws -> StoredState` (`checkpoint`, `inputBase`, `inputWindow`,
  `transitions`, `tornBytes`) replaces `loadSnapshot()`; `seal(_:) throws -> Bool` replaces
  `save(_:)`; `compact(_:) throws -> Bool`.
- `SessionStore`: journal files; `delete` removes them; a read-only summary for `--info`.
- `Storage`: steps `journal.append.<tag>` (the tag is the append's frame types joined by `+`:
  `input`,
  `input+input` for two or more `INPUT` frames, `front`, `remote`, `front+remote`,
  `front+throwaway`, `front+server-shutdown`, `throwaway`, `server-shutdown`; S-4),
  `journal.truncate`, and the steps of section 7; an install
  of a temporary file with or without syncs; and a second hook that is called right after a
  step's system call returned (`moshcli` kills itself in it, see 10.6).

### 10.4 MoshResume: the coordinator

Signatures stay; meanings change.

| Call | Stage 2 |
|---|---|
| `create` | The record is resumable from its first datagram (`open(b)`, `journal.1`) |
| `coldStart` | Section 5. Writes nothing on the way to `.resumed`; the session is built with `currentSize: nil` |
| `start()` | Section 5: all of a cold start's writes, then the first datagram, then the Resize if the size changed |
| `type`, `resize` | True means journaled, in the foreground too (today: "taken by the session, not stored"). Two exceptions, both harmless: `resize` before `start()` returns true and only keeps the size (`ResumeCoordinator.swift:601-606`), and once `ended` or `dead` is in both slots the journal is retired, so input the session still takes is not journaled (that record is never resumed). False also when the journal could not be written; a `.gateFailed` event says why |
| `enterBackground()` | Quiesce and seal. Before `start()` succeeded (an unarmed gate): writes nothing and reports what the state on disk promises (section 5) |
| `enterForeground()` | `markOpen()`, then `session.resume()`. If the mark fails, the gate writes it before the first append; until then no state changes. On disk the record then reads `sealed(id)` or `open(b)` (one slot may have been written); both are true, because nothing was appended. The gate no longer answers "sealed" without a full seal (section 7), so `SaveOutcome.clean` is not reported for a record that reads `open` (S-2) |
| `shutdown()` | As today with `markOpen()` where `markDirty()` is: `markOpen()` (refused if it fails, nothing changed; it writes only when the record is sealed), then `markEnded()` (final from the call on, R16), then the session's shutdown. Between the two marks the record is `open`, not "dirty": a kill there resumes the session and never starts a new one. Before `start()` succeeded there is no `markOpen()`: `markEnded()` directly (section 5; S-1) |
| `abandon()`, a lost base state, a halted transport | `markDead()`: final from the call on, also when its slot writes fail (J15). A halted transport still receives (`TransportCore.swift:270-272` checks `isQuiesced` only), and its `record` calls complete the mark and journal nothing |

`Options`: `+ bootIdentity: any BootIdentity = BootIdentities.platform`,
`+ compaction: CompactionPolicy` (128 KiB, 2,048 records, 30 s, 1 s; tests use small values).

```swift
public enum SaveOutcome: Equatable, Sendable {
    case clean                          // sealed: resumable, also after a restart of the device
    case openOnly(String)               // new: resumable until the device restarts; why not sealed
    case notResumable(NotSavedReason)   // .ended, .closed, .failed
}
```

`NotSavedReason.datagramSentSinceExport` goes (a datagram no longer matters).

```swift
public enum FallbackReason {
    case givenUp                        // was .dirty: "the session was given up earlier"
    case rebooted                       // new: "the phone restarted while the session was open"
    case bootUnknown                    // new: "could not tell whether the phone restarted while the session was open"
    case ended
    case snapshotDoesNotMatch           // a stage 1 record, or a sealed mark for another checkpoint
    case missing(RecordPart)            // also .journal
    case damaged(String)
    case snapshotRefused(String)        // also: the journal did not replay
}
```

`wantsNewSession` is false for `.ended` only, as today.

### 10.5 The app (for the session on the Mac)

The app's calls and their order do not change. What does:

1. **Cold start.** `.resumed` now also follows a kill in the foreground. The banner cases:

   | Outcome | The app |
   |---|---|
   | `.resumed` | The terminal with the stored screen, `start()`. No banner, whether the app was killed in the background or in the foreground |
   | `.fallback(.rebooted)` | New. `ColdStartFallback.userMessage` with the reason "(the phone restarted while the session was open)", then the fallback as for any other reason |
   | `.fallback(.bootUnknown)` | New. The same path, with the reason "(could not tell whether the phone restarted)" |
   | `.fallback(.givenUp)` | Today's `.dirty` path; only the reason's text changes. It no longer means "killed in the foreground" |
   | `.fallback(.ended)`, `.missing`, `.damaged`, `.snapshotDoesNotMatch`, `.snapshotRefused`, `.retryLater` | As today |

2. **Leaving the foreground.** Still `enterBackground()` inside a background task. It is no
   longer what makes the session resumable; it makes it survive a restart of the phone. If
   the task expires first, nothing is lost in this boot. The result has the new case
   `.openOnly` (log it; the UI-test mark becomes `background-open`). `SceneSavePolicy` stays.
3. **Input.** `coordinator.type` can return false in the foreground (the journal could not be
   written). The `.gateFailed` handling that shows "The session's record could not be
   written" already covers it. Suggested: put `start()` into the screen's command queue ahead
   of input, so that a key typed in the first milliseconds waits for the start instead of
   being refused.
4. **Tests.** `ResumeUITests.testACrashInTheForegroundFallsBackToANewSession` becomes "resumes":
   the same `$$`, the same server (`/alive`), no banner, and a line typed right before the
   crash is in `cat -v` once. The tests that need a dead record after `-debugCrashAfter`
   (`ResumeUITests.testADirtyRecordAtRelaunchKillsTheLiveOldServerOverSSH`,
   `BannerLayoutUITests.testTheFallbackBannerSitsAboveTheTerminalAndTakesItsRows`) get it from
   a new debug launch argument `-debugBootID TEXT`: relaunch with another value and the
   outcome is `.rebooted`; the reason they look for is that one's text, not "the record is
   dirty". `SessionLauncher.options` is the one place that builds `Options`, so the argument
   becomes `Options.bootIdentity` there, and the host list (item 7) uses the same identity.
   The "resumes" test passes no `-debugBootID`, so it also shows that the simulator reads a
   real identity. `SessionLauncherTests.testARecordThatWasNeverSavedFallsBackWithItsMeta`:
   such a record now resumes; with another boot identity it falls back with its `meta`. The
   end of `testAnEndedRecordIsListedWithItsServerIdentityAndIsNotASession` expects that
   record's fallback too and now gets `.resumed`.
5. **`DeviceProbe`** (phone). Its two passes use the record directly and follow 10.3:
   `create` takes `makeInitial` (10.3); `save` is `seal`, with an export that carries the
   gate's `journalPosition`; `loadSnapshot` is `loadState`; "the first datagram after a save"
   is timed as `gate.markOpen()`, where its two syncs went (`willSendDatagram()` writes
   nothing now); the closed record reopened while locked reads `sealed` (the verdict's
   `reopen == "clean"` becomes `"sealed"`, in `DeviceProbeTests` too); a record that was only
   created reads `open`, not "dirty". New items: `kern.bootsessionuuid` reads, is not empty,
   is the same in two launches, differs after a restart of the phone; the time of 1,000
   appends of 64 bytes, of a compaction and a seal of a 15 KB checkpoint, of `open`; the
   protection class of `journal.<g>`; an append with the phone locked; "write 100 records,
   `kill(getpid(), SIGKILL)`, read them back at the next launch".
6. **The owner's checklist.** The M6 row "Crash now ... shows the banner and lands in the same
   tmux" becomes "resumes: same `$$`, no banner". New: Crash Now, restart the phone, open the
   app: the banner with "the phone restarted", then the same tmux through the new session.
7. **The host list.** `ListedSessionState.derive` (`SessionList.swift`) is the one place that
   turns a record's state into a label, and its comment already names M9. It gets the current
   boot digest as a third argument (`SessionList.load` reads it once), and maps: `.clean` and
   `.sealed` to "resumable"; `.open(d)` to "resumable" when
   `RecordState.mayResume(currentBoot:)` says so, else to "dead"; `.dead` (the old `.dirty`)
   to "dead"; `.ended` as today. So a session whose app was killed in the foreground is listed
   as resumable until the phone restarts. The label stays a hint: a tap still goes through
   `SessionLauncher.coldStart`, which decides. `lastUsed` (the newest file date) now moves
   with every journaled event, not only with a save.
   `SessionListTests.testStatesFromTheCounters`
   gets the new states; `SessionListUITests` can add "killed in the foreground, listed as
   resumable, a tap resumes it", and with `-debugBootID` (item 4) the "dead" row, which the
   simulator could not produce for M8 (`docs/PLAN.md`).
8. **Names to follow:** `RecordState.dirty` is `.dead`; `FallbackReason.dirty` is `.givenUp`
   and `.rebooted` is new (the app shows `reason.description`, so only texts change);
   `SaveOutcome` has `.openOnly`, for which `isClean` is false. The comments and log lines of
   `TerminalViewController` that say "dirty" mean two things now: the record of a running
   session is `open` and resumes; the record of a session that was given up (`abandon()`, a
   cold start's fallback) is `dead` and does not, exactly as "dirty" today. The code beside
   those comments needs no change.
9. Nothing changes in `SessionLauncher.endedRecords` (`.ended` keeps its name), in
   `SessionFiles` (`forget` deletes through `ResumeCoordinator.deleteRecord`, which removes
   the journal files with the rest), in "End Session" and "Forget", or in the Keychain use.

### 10.6 moshcli

- `resume` continues a record whatever way its last process ended. Exit 3 is left for `dead`,
  `ended`, `.rebooted`, a damaged or missing part. "A script that ends without a quiesce
  leaves a record that does not resume" is no longer true and leaves the usage text.
- `connect --session-root`: resumable from the first datagram.
- `--info` adds: `state` (`sealed`, `open`, `dead`, `ended`, `clean` for stage 1),
  `resumable=yes|no (<reason>)`, `boot_match`, `journal_generation`, `journal_bytes`,
  `journal_records`, `torn_bytes`, `front`, `pending_events`, `remote_states`.
- `--crashpoint` and `--step-log` know the new steps: `journal.append.input`,
  `journal.append.front`, `journal.append.remote`, `journal.append.front+remote`,
  `journal.append.throwaway`, `journal.append.server-shutdown`,
  `journal.append.front+throwaway`,
  `journal.append.front+server-shutdown`, `journal.append.input+input`, `journal.truncate`,
  `journal.next.create`, `journal.next.write`, `journal.next.fsync`,
  `journal.next.append.tail`, `journal.rename`, `journal.old.remove`. For an append, `:after`
  is "the record is in the file, nothing after it happened" (attack 1 of section 14),
  `:before` is "not written", `:torn=BYTES` is the middle of the record. `--crashpoint list`
  prints them. `:after` and `:torn` now kill the process inside the storage layer, right
  after the system call returned (the new second hook). Today the storage layer plays the
  crash and the process dies 50 ms later. That is exact for stage 1's steps (a reservation
  that blocks the send waiting for it, and the save of a quiesced session); it is not exact
  when the transport keeps running for 50 ms on a journal it can no longer write.
- `--boot-id TEXT`: the boot identity of this process (to play a restart of the device).
- `--loss-in PERCENT`, `--loss-out PERCENT` beside `--loss` (100 inbound is "nothing was
  received").
- `--intent-log FILE`: before each `type` of a script the line `intent <line number>`, after
  it returned true `typed <line number>`, each written with one `write()`.
- `--compact-bytes N`, `--compact-records N`: small limits, so that a short run compacts.
- `moshcli journal --session-root DIR [--session ID]`: prints header and records (type,
  numbers, sizes; no input bytes, no diff bytes), without the lock.

### 10.7 scripts/killloop.sh: the M9 exit test

A new part `stage2` (and `scripts/itest.sh killloop-stage2 [iterations]`), 500 iterations by
default. One `mosh-server` and one tmux (window 0 `cat > log`, window 1 a shell) for the whole
run; one session record; `tcpdump` as in stage 1.

Each iteration is one client process (`moshcli resume`, the first one `connect`) whose script
types numbered lines into `cat` without waiting, makes output in the shell window
(`seq 1 200`), switches windows, and never quiesces unless its kind says so. Every script
begins by selecting its window, and a window switch is one `type` call (tmux prefix and digit
together), so that a kill cannot leave half a prefix key behind. How it dies:

| Kind | Share | The kill |
|---|---|---|
| random instant | 300 | `SIGKILL` from the script after a random 0 to 1,500 ms from the process's start. That covers the cold start itself (replay, tail cut, counters change), the first datagram, typing, receiving, compaction (`--compact-bytes 2000`) |
| storage step | 120 | `--crashpoint '#K:MODE'`, `K` random within the steps of a reference run, `MODE` one of `before`, `after`, `torn=1`, `torn=7`, `torn=9`, `torn=13`, `torn=40` |
| deaf | 30 | The process runs with `--loss-in 100`, types a line and is killed after 300 to 1,500 ms. The process after it starts from a journal in which nothing was received since the kill before: two kills in a row |
| sealed | 30 | `quiesce`, then `SIGKILL` (the stage 1 path) |
| long gap | 20 with `--long`, else 2 | 61 s before the next process starts |

Every 8th process also runs with `--loss 20`.

Pass conditions:

- After every kill `--info` says `resumable=yes`, and the next process reports "resumed
  session". Any exit 3 fails the run.
- The `mosh-server` pid named by the record is alive and the same after every iteration and
  at the end, and so is the shell's `$$`: no server abort.
- Exactly-once input: after the loop one more process types `END` and waits for its ack. The
  file `log` then holds, in order and each exactly once, every line with a `typed` entry;
  a line with only an `intent` entry at most once; and nothing else. Lines are whole
  (a line is one `type` call and one `INPUT` record).
- Screen equality: every 25th process (not under loss) runs to `wait-ack`, `settle 500`,
  `dump-screen`; the rows equal `tmux capture-pane -p`.
- Numbers: `scripts/check-seq-log.sh` over the one sequence log and its numbers log (sequence
  numbers, state numbers and fragment ids only go up across all 501 processes), and the
  capture shows no client sequence number twice and none that is not in the log.

After the loop, each with a server of its own:

| Row | Pass |
|---|---|
| Killed in the foreground, next start with another `--boot-id` | Exit 3, "fallback (the device restarted ...); nothing sent"; the sequence log did not grow; the server is alive |
| Sealed, next start with another `--boot-id` | Resumes |
| `truncate -s -3` of the journal | Resumes; `torn_bytes` was not 0 |
| One byte changed inside a record that is not the last | Exit 3, nothing sent |
| A stale lower generation and a `.tmp` put beside the newest | Resumes from the newest; both are gone afterwards |
| Sealed, and the journal replaced by a sealed one of another run (another checkpoint id) | Exit 3, nothing sent |
| A stage 1 record (a fixture made with the version 1 writers kept in the test support) | Resumes; `--info` says `open` afterwards |
| Guards (section 11) | The server exits without the rule, lives with it |

The stage 1 rows "SIGKILL while dirty" and "quiesce, return to the foreground at once, type,
SIGKILL" stay in the script with the opposite expectation: a resume, the typed line in `log`
once. About 25 minutes for 500 iterations.

## 11. Tests

**Per step, without a server** (names are suggestions; one XCTest class per file):

| Target | Tests |
|---|---|
| `MoshResumeTests/JournalFormatTests` | Round trip of every record. Every truncation of a journal is TORN at the start of the cut record (or DAMAGED inside the header). Every changed byte is DAMAGED, never TORN and never accepted. A length whose complement does not match is DAMAGED also when it points past the end. Random bytes never trap; a `THROWAWAY` above every held state is refused at replay, not a trap |
| `MoshResumeTests/CountersTests` | Version 1 slots still read (`clean`, dirty as `dead`, `ended`). State 3. A version 1 and a version 2 slot together. Every damaged byte, as today. A fuzz over files with one slot of each version (`CountersFile.read` compares generations and limits across them, `Counters.swift:154-190`; R2-8). A version 2 `open` and a version 2 `sealed` record on the step 6 code: fallback, nothing sent, the next reservation starts at their limits (S-5) |
| `MoshResumeTests/JournalTests` | Append then read. A failed append (the hook's `.fail` with some bytes written) leaves the file and the count as before; a failed cut poisons until a compaction. Compaction with appends from another thread during it: the new file replays to the same state. A stale position is refused. Kill at every step of a compaction and of a seal (before, after, torn): the reader finds the old state or the new one, by the rule of J8. Lower generations and temporary files are removed at `start()` only. `testASealAfterAHalfWrittenSealedMarkNeverLeavesAMismatch`, `testAHalfWrittenOpenMarkIsNotReportedAsSealed` (S-2). The header's window after a compaction is the one in use, with the configuration's below and above the old header's (R2-7) |
| `MoshResumeTests/BootIdentityTests` | Linux reads `boot_id`; the digest is stable and not 0; the fixed one; `testEmptyOrZeroIdentifierIsUnknown` (empty, another length, not hexadecimal, the nil UUID, two reads that differ: all unknown) |
| `MoshTransportTests/WriteAheadTests` | For each transition: a gate whose `record` throws leaves the core exactly as it was (`type` false and nothing pending; an ack ignored; a state not held and not acknowledged; a server shutdown not seen), and the next try succeeds. A gate that records sees the transition before a tick can send anything that depends on it. The three `Outbox` checks, with the test hooks. A new core's first datagram passes them (`recorded` seeded from its own log). After a recorded `SERVER_SHUTDOWN`, an instruction whose `ack_num` names a state sent before the shutdown was seen changes nothing and halts nothing. `FRONT` and `THROWAWAY` are recorded past `journalFull` |
| `MoshTransportTests/ReplayTests` | After every step of a long scripted run with `InMemoryGate(keepsTransitions: true)`: a core restored from the first checkpoint plus the transitions so far equals the live core in front, pending input, held states and their numbers, `ack_num`, size; the receive sequence as `restored <= live` (a duplicate or a retransmission moves the live value and plans nothing, `TransportCore.swift:277-279`; R2-10). The same across a checkpoint taken in the middle |
| `MoshSessionTests/RestoredClipboardTests` | A copy that arrived in a replayed `REMOTE` is not written at the restore; a different copy after it is. The three existing tests stay |
| `MoshResumeTests/ResumeCoordinatorTests`, `ReviewFixTests` | The stage 1 tests with their new expectations (a kill in the foreground resumes; input in the foreground is in the record; a second `enterBackground()` writes nothing; a stage 1 record is converted at `start()`; another boot identity is `.rebooted`; unknown boot identity never resumes an open record and reports `.bootUnknown`). For J14 and J15: `testRecordBeforeConversionWritesNothing`, `testRecordBeforeTheTailCutIsRefused`, `testShutdownBeforeStartNeverLeavesAStage1RecordOpen` (a version 1 `clean` fixture with a stale `journal.1`, a kill at the first `counters.write` of `ended`: the state is `clean(id)` or `ended`), `testEnterBackgroundBeforeStartWritesNothing`, `testASealBeforeStartDoesNotLeaveACutForTheNewGeneration`, `testADeadMarkThatFailedHalfWayIsNeverCoveredByOpen` (also across a reservation), `testInitialCheckpointIsTheCoresOwn` |

**Crash points.** `Stage2CrashTests.testAProcessDeathAtEveryStorageStepIsResumable`, the
successor of
`FileBackedGateTests.testACrashAtEveryStepNeverReusesANumberOrResumesAStaleSnapshot`:
a script (create, start, type, a server answer, more of both until a compaction, seal, return,
type, answer) against the server model below, with small blocks and small compaction limits.
A first process is killed at each storage step (before, after, and for each write at every
torn length of a set that includes 1, 7, 8, 9, 11, 12, 13 and length - 1); a second at a
random step of its restore or after; a third is checked. Asserted: every number handed out is
above every earlier one; the model has no problem; the restored durable state equals the
killed process's state or that plus the append in progress (L1), compared with an independent
replayer in the test (a few lines over the decoded records).

**Model-based fuzz.** `KillFuzzTests`, in two layers, after the pattern of
`docs/notes/review-transport/ReviewIFuzzTests.swift` (a random schedule, a `ServerModel` that
turns mosh's asserts into recorded problems) and
`docs/notes/review-resume/ReviewAFuzzTests.swift`
(storage hooks that fail, tear and kill).

- The schedule: `type` (1 to 1,500 bytes), `resize`, time steps, ticks, a server state with or
  without data, loss in either direction, a silent server, a new socket, gate failures
  (numbers), **record failures**, quiesce and return, compaction, and **kill and restore**.
- A kill is one of: between two operations; inside a `record` call, with a random prefix of
  its transitions kept (and, in the file layer, a random number of bytes of the next frame);
  after a `record` call and before its apply; inside a restore; twice in a row with nothing
  delivered in between; after a time step of more than 60 s.
- The server model, from section 1: the list of client states with their input (S1); the
  problems "state list empty" and "reference erased" (S2), "not a prefix" at `diff_from` and at
  `subtract` (S6), "sequence number seen" and "fragment id seen with other content" (N1, N4);
  what it passed to the pty (S6). New compared with the reviewers' model: its own sender (S5,
  S7, S8): the states it sent, its front, thinning at 32, the base it would use now.
- Checked after every operation: no model problem; the server holds the client's front; the
  client holds the server's front (the two soft failures). After a settle phase without loss:
  the pty got exactly the accepted input, in order, once (plus, at most once and whole, a
  batch whose `record` was in progress at a kill).
- Layer 1 (`MoshTransportTests`) uses the in-memory journal, thousands of seeds, fast. Layer 2
  (`MoshResumeTests`) runs the same schedule through `ResumeCoordinator` with real files,
  hooks and a fake clock, a few hundred seeds.

**Against the real server:**

- `UnannouncedKillTests`: connect, type, kill the client object at each storage step of a
  short run (all the journal steps), cold start, type again: the same shell, each line once.
- `GuardTests`, two more that break a server on purpose, to show the asserts are live for the
  new rules and the tests would see a violation: (a) a client restored from a journal whose
  last `INPUT` record was removed after its state had been sent sends a shorter state: the
  server's `UserStream` assert fires; (b) the same journal untouched: the server lives.
- `scripts/killloop.sh stage2` (10.7).

## 12. Implementation plan

Each step builds, passes the whole suite and can be committed alone. Until step 9 the dirty
rule still decides every cold start, so every commit before it is a correct stage 1 system.
**[N]** marks steps that touch the nonce, state-number or fragment-id paths.

| # | Step | Files | Proved by |
|---|---|---|---|
| 0 | First, because its answer decides what M9 is worth on the device: `DeviceProbe` reads `kern.bootsessionuuid` on the phone (two launches, then once after a restart of the phone). In the same commit the app's two switches over `RecordState` stop naming `.dirty` (`ListedSessionState.derive`: every other state is "dead"; `DeviceProbe`: every other state prints itself), so that steps 1 to 8 need no change in `App/` | `App/IOSMosh/DeviceProbe.swift`, `App/IOSMosh/SessionList.swift` | `scripts/sim-test.sh`; `scripts/phone-selftest.sh`; needs the owner once |
| 1 | The journal's byte format: header, frame, records, the reader with TORN and DAMAGED. `SnapshotCodec` split into body and file frame (same bytes) | `Sources/MoshResume/JournalFormat.swift` (new), `SnapshotCodec.swift` | `JournalFormatTests`; `SnapshotCodecTests` unchanged |
| 2 | `DurableTransition`, `JournalPosition`, `record` and `journalPosition` in the gate protocol. `InMemoryGate`, `FileBackedGate` (records to nowhere for now) and `moshcli`'s `LoggingGate` conform | `Sources/MoshTransport/DurabilityGate.swift`, `Sources/MoshResume/FileBackedGate.swift`, `Sources/moshcli/ResumeSupport.swift`, `Tests/MoshTransportTests/GateTests.swift` (`ScriptedGate`), `Tests/MoshResumeTests/ResumeEndToEndTests.swift` (its private `LoggingGate`, `:15`) | `GateTests`; the suite |
| 3 | **[N]** `TransportCore` as plan, record, apply; absolute input indices; `recorded` and the three `Outbox` checks; the three new parameters of `init(restoring:)`, which loses `currentSize`; `recorded` seeded for a new core; nothing planned after a recorded server shutdown; `checkpointState()`. Touches how `throwaway_num`, `ack_num` and the diff's end are decided, not how numbers are taken | `TransportCore.swift`, `Outbox.swift`, `UserInput.swift`, `TransportTypes.swift` | Every existing transport test unchanged; `WriteAheadTests`, `ReplayTests`, `KillFuzzTests` layer 1 |
| 4 | Connection and session: restoring initializers with replay, `checkpointState()`, `SessionExport` fields (its initializer keeps the two-argument form: the new fields default to 0 and nil), the clipboard baseline, `terminalSize()` | `MoshConnection.swift`, `MoshSession.swift`, `SessionTypes.swift`, `ResumeCoordinator.swift` (the Resize moves to `start()`; the app passes nil already, so this changes `moshcli resume` and the two `ResumeEndToEndTests` that pass a size) | `MoshSessionTests`, `RestoredClipboardTests`, `ResumeSeamTests` |
| 5 | `Storage`: append and truncate steps with tags, install with or without syncs. `BootIdentity` | `Storage.swift`, `BootIdentity.swift` (new) | `BootIdentityTests`; storage step tests |
| 6 | **[N]** `counters` slot version 2 and the states `sealed` and `open`: the slot codec reads and writes both versions. The gate still writes version 1 with stage 1's states, so a record made by this build is a stage 1 record; nothing writes `open` or `sealed` yet, and until step 9 the stage 1 code treats a slot that says so like dirty (not resumable; its limits count as always). The slot also holds the three limits, so this is the file N1, N2 and N4 rest on | `Counters.swift` | `CountersTests` (old ones unchanged; version 2; a file with one slot of each version, and the fuzz over such files; the version 2 record on this step's code, S-5) |
| 7 | `Journal`: file object with append, position, replace, read; `SessionStore` knows the files and deletes them | `Journal.swift` (new), `SessionStore.swift` | `JournalTests` |
| 8 | **[N]** The gate writes the journal: `record` appends, `SessionRecord.create` writes `journal.1`, compaction and the signal for it. A compaction is permitted in this step while the gate's state is dirty and the gate has a journal (`open` does not exist yet). The states written are still stage 1's (`clean`, dirty), and no cold start reads a journal. A record opened by a cold start has no journal to append to (its files are stale from the first stage 1 resume on): its gate records to nowhere, as since step 2. So does the gate of a record made by the old `create` without `makeInitial:`, which stays until step 9 for its one caller outside the package (`DeviceProbe`). The reservation code is in the same file and is not changed | `FileBackedGate.swift`, `SessionRecord.swift`, `ResumeCoordinator.swift` (compaction only) | `FileBackedGateTests` unchanged; a test that reads the journal of a run against the real server back and replays it to the session's own state, also across compactions (`ResumeEndToEndTests` addition) |
| 9 | **[N]** The switch: states `open`, `sealed`, `dead` (the new name of `.dirty`); the gate writes version 2 slots, and the version 1 encoder moves to the test support, for fixtures of stage 1 records; `markOpen`, `seal`, `beginSending` with the armed rule (J14); the final marks (J15); `loadState` with the boot rule; `coldStart` and `start()` of section 5; stage 1 records converted; the dirty rule, the snapshot file, `save`, `loadSnapshot` and the old `create` removed. `SaveOutcome`, `FallbackReason`. With it, in the same commit, the app's source for 10.5, items 1, 2, 4, 7 and 8 and the existing passes of item 5 (see below) | `FileBackedGate.swift`, `SessionRecord.swift`, `ResumeCoordinator.swift`, `Counters.swift`, `Tests/MoshResumeTests/ResumeTestSupport.swift`; `App/IOSMosh/{SessionList,SessionLauncher,DeviceProbe,TerminalViewController}.swift`, the app's tests | `Stage2CrashTests`, `KillFuzzTests` layer 2, `ResumeCoordinatorTests` and `ReviewFixTests` with new expectations, `UnannouncedKillTests`, `GuardTests`; `scripts/sim-test.sh` |
| 10 | `moshcli`: 10.6 | `Sources/moshcli/*` | `scripts/itest.sh script`, `resume-mem`, a new `journal` check |
| 11 | `scripts/killloop.sh stage2` and its rows; the stage 1 parts adjusted; `docs/RESUME.md` (J1 to J15, the format, the results), `docs/PLAN.md` (stage 2 text and a table "Resume, stage 2"), the project status | `scripts/killloop.sh`, `scripts/itest.sh`, docs | The M9 exit test on yellow (capture and netem need it) |
| 12 | The phone: the probe's new items and its timings (10.5, item 5), the suggested order of `start()` and input (item 3), the owner's two checks (item 6) | `App/IOSMosh/DeviceProbe.swift`, `App/IOSMosh/TerminalViewController.swift` | `scripts/sim-test.sh`; `scripts/phone-selftest.sh`; the owner's two checks |

`App/` is built from the same tree and `main` is the only branch, so no commit may leave the
app unbuildable or its tests red. After step 0, the steps 1 to 8, 10 and 11 touch nothing the
app's source uses; they are made and tested with `scripts/dev.sh` alone. Step 9 is the
exception. It removes calls that `DeviceProbe.swift` makes, and it changes what the app's
tests of 10.5, item 4, expect. So it is one commit for the package and the app, made where
`scripts/dev.sh` and `scripts/mac.sh` both work, and pushed after both suites passed. From
that push until the M9 exit test of step 11 has passed, the phone keeps the build it has: no
`scripts/deploy.sh` in between.

Steps 3, 6 and 9 are the ones to give to hostile reviewers before they reach the phone, as was
done for the transport and for stage 1. Step 6 is on the list because the slot codec is the
file N1, N2 and N4 rest on, and from it on one file can hold slots of two versions (R2-8).

## 13. Where the plan's sketch is incomplete or wrong

| Sketch (PLAN section 3, "Stage 2") | Problem | Chosen |
|---|---|---|
| "`FRONT(num, inputCount)` ... how many `INPUT` records it contains" | A state can end inside an `INPUT` record: a paste is one record, and the input window cuts states at 262,144 events. Counting records would send part of a paste twice or not at all | `inputCount` counts events (bytes and resizes), absolutely for the record's life; the header's `inputBase` anchors a generation |
| The rules are about sends: "`ack_num = n` is sent only after `REMOTE(n)` is appended", "`throwaway_num = t` only after `FRONT`" | With send-time rules memory may run ahead of the journal. Then other code acts on unrecorded state: the input log drops acknowledged events, an export for a checkpoint holds a front the old file does not | Log before apply (J1): memory is always what replay gives. The send-time rules follow, and are checked again at the send point (J3) |
| `REMOTE_THROWAWAY` as a record | One more append per received state, for a number that is a field of the instruction | Stored in `REMOTE`; `THROWAWAY` only when no state is stored (3.3) |
| "Compaction writes `journal.<gen+1>` starting with a `CHECKPOINT`, then fsync, then rename" | Says nothing of records appended while the checkpoint is written, of which file a restart reads, or of when the sync is needed | Tail copy under the append lock; the highest generation present is the one read, and never a lower one instead (J8, J9). Sync only for a seal; a compaction in the foreground needs none, because an open record is used only in its own boot |
| "replaces the dirty rule" | Something must still be synced before the first unsynced append, or a restart after a power loss would resume from a synced checkpoint that later, lost records had moved on from (N2) | `open(boot)` in both slots before the first append (J4); `sealed` for a synced checkpoint (J5) |
| "detected with a boot identifier and treated as dead" | Not said where it is stored or when it is written | In the `open` state of the slots, synced before the first append; rule in section 8. Unknown identifier: never resumed while open |
| "CRC-framed" (and the first design's "truncating at the first bad CRC") | A bad checksum in the middle is not a torn tail; cutting there drops records that were acted on | TORN only for a record that runs past the end of the file; everything else is DAMAGED (J7). The length is stored twice so that the distinction holds for a damaged length too |
| "The stage 1 snapshot is the stage 2 `CHECKPOINT`" | True for the bytes. But a checkpoint must also be taken from a live session, and a restore must not judge the clipboard of a replayed state | `checkpointState()` without quiesce; the clipboard baseline (section 5, step 9) |
| `SERVER_SHUTDOWN` | Kept; its relation to "ended" in `counters` was open | The record closes the milliseconds between the transport seeing the shutdown and the coordinator's `ended` mark. The client's own shutdown needs no record |
| Not in the sketch | A journal write can fail | J10: nothing changes; input is refused, a received instruction is dropped |
| Not in the sketch | The expected receive sequence, the highest ack sent, the input window | Section 5; J12 |
| Not in the sketch | A new session before its first save | Resumable from `create` (`journal.1` holds the initial checkpoint) |
| Exit test: "no lost input" | Not defined for input in flight at the kill | Input for which `type` returned true arrives exactly once. Input whose `type` call had not returned arrives once or not at all. A `type` call of up to 1 MiB of events is one `INPUT` record and is never split; a larger one is several records and can arrive as a prefix of whole records (4.4) |

## 14. Attacks on this design

Each was tried against the rules above by hand; the tests of section 11 repeat them.

1. **A kill between the `write()` of a record and the send it permits.** `S = J + p` with the
   whole record. `INPUT`: the input is pending and goes out once (row A3). `FRONT(N)`: the
   server acknowledged `N` and no throwaway above the old front was sent, so it holds `N`
   (L2). `REMOTE(n)`: `n` is held and acknowledged in the first datagram; an ack for a state
   the server sent is always acceptable (S5). `THROWAWAY`: states the server said it will not
   build on are dropped. `SERVER_SHUTDOWN`: ended; the server gives up after 10 s (S14). Safe.
2. **A kill in the middle of a record.** The reader cuts it (3.4); the record was never
   applied (J1). In a two-record append the first record may survive alone: an ack without its
   state (row A8). Safe.
3. **A kill during compaction, at each step.** Rows C1 to C3 and D1 to D4. The one way to go
   wrong would be to read a lower generation after a higher one was used; J8 forbids it, and
   a damaged newest generation is a fallback, not a reason to look further down.
4. **Two kills in a row with no datagram received between.** Row F3. The second restore
   starts from the same front with a higher state number and at least the same input; the
   server holds the front (both processes sent `throwaway_num = A`). Each restart skips a
   block of numbers (65,536 sequence numbers; 2^47 restarts fit). A long series of such kills
   would pile client states up at the server (one per restart, erased only when a front
   moves); above 1,024 it accepts one new state per 15 s (S1e). That slows such a series down
   and breaks nothing.
5. **A kill after the server acknowledged input that the journal's `FRONT` does not show.**
   Rows A6 and A7. The input goes out again inside `N'`, which is built on the older front
   the server still holds; the server passes on only what follows its newest state (S6).
   This is the exactly-once case of stage 1's `quiesce --after-send`, now at any instant.
6. **A kill after the client acknowledged a state whose `REMOTE` record is the torn tail.**
   Cannot happen with a process kill: the state is stored, and `ack_num` moved, only after
   the append returned, and a returned `write()` is in the file. `Outbox.send` checks it from
   the second set of books (J3). It can happen after a power loss, which is section 8.
7. **Input typed while a restore is in progress.** `coldStart` is synchronous and returns a
   coordinator that is not started; `type` before `start()` returns false (C11) and the bytes
   are nowhere. `start()` and `type` run in the coordinator's queue in arrival order, so a
   `type` asked for during `start()` runs after it and is journaled before it is accepted. The
   only loss is a key the app handed over before it asked for the start, which the user sees
   as a key without an echo; 10.5 item 3 removes that.
8. **A resume after more than 60 s of silence.** The server never drops a client it has heard
   from (S12); after 40 s it only stops sending. The first datagram has a higher sequence
   number (L5), so the server takes the new address (S10) and starts sending again, on its
   front (S7), which the client holds (L4). The 60 s exit applies only to a server that never
   received a client state: row I2.
9. **Damage at rest inside the journal.** DAMAGED, fallback. Not resumed from the part before
   the damage.
10. **A slot of `counters` lost at rest.** Both slots say `open(b)` before any append, so the
    other slot says the same. A lost `sealed` slot leaves `open(b)`: resumed in this boot,
    dead after a restart. Limits as in R10.
11. **An app update between kill and restore.** The same boot, so the journal is whole. The
    new build replays with its own applier; if the terminal serialization or the journal
    format has a new version, or a diff no longer applies, the record is refused (fallback).
12. **The input window made smaller by a new build**, with more than that much input pending:
    the first restored state would be shorter than one already sent (N2). J12.
13. **A full disk.** Appends fail: input is refused, received states are dropped, the session
    stands still and stays consistent; the record stays resumable. `.gateFailed` tells the
    app, at most once a second.
14. **A restore from a device backup.** Unchanged: the directory is excluded (R19).
15. **A datagram recorded before the kill, replayed to the new socket.** Its instruction is
    idempotent (held, or its base is gone, or it is a genuine state that is then applied).
    The expected receive sequence after a restore is the highest one in the journal, so only
    a datagram received after the last record, within seconds of the kill, can count as "in
    order" once and disturb the RTT, the banner and the probe timer until the next real
    datagram. Stage 1's snapshot has the exact value; a journal cannot without a record per
    datagram. Accepted (the review rated the unbounded form of this "minor").
16. **Typed input at rest.** The journal holds every key typed since its checkpoint, in a
    file of class "until first user authentication". The 30 s rule bounds how long
    acknowledged keys stay in the file's contents; it does not erase flash. The session key
    in the Keychain has the same protection and gives more.
17. **`enterForeground()` whose `open` mark fails, then traffic.** Sends go on (empty acks
    with new numbers). Every state change needs an append, which needs the mark, so the front
    cannot move, no state is stored, no input is taken. The sealed checkpoint stays exactly
    true, whatever was sent. This is why a datagram alone never makes a record stale.

## 15. Open questions, and what the source did not settle

For the owner:

1. **Phone time for M9.** The device checks take over the screen for about ten minutes and
   need one restart of the phone (boot identifier, the timings, "Crash Now" resumes, "Crash
   Now, restart" falls back). When?
2. **Typed keys in the journal** stay in the file for up to about 30 s after the server
   acknowledged them (longer while the server is unreachable). Acceptable, or should the
   limit be shorter at the cost of more compactions?
3. **After a resume from a crash the app says nothing** (the session is simply there). Should
   it say so once, for example in the debug log only, or on the screen?
4. **No downgrade.** An older build over a stage 2 build with a session record present is
   safe for the server but leaves a directory the old build cannot remove (3.6). Is that
   acceptable, or should the journal live in a sibling directory that old builds ignore (more
   code in the record's store and its backup exclusion)?
5. **A boot identifier that cannot be read or trusted.** Stage 2 then ends every kill in the
   foreground in the fallback (`.bootUnknown`), as stage 1 does. Is that enough, or should a
   second signal be designed (`REVIEW.md`, R2-3 (c) and its first question)? Nothing in this
   file depends on the answer.
6. **Unacknowledged input without a limit.** `type` takes any amount; past 64 MiB pending the
   checkpoint no longer fits a frame. The journal now keeps `FRONT` records flowing (3.3), so
   the session recovers once the server acknowledges. Should `type` refuse input beyond a
   limit instead (`REVIEW.md`, R2-5, first option)?

Not settled from the sources in this repository:

- Whether an iOS app can read `kern.bootsessionuuid`, and whether reading it needs an entry in
  a privacy manifest if a TestFlight build is ever made. If it cannot be read, stage 2 is
  safe and gives nothing over stage 1 for a kill in the foreground. `DeviceProbe` decides
  (step 0 of section 12); until then the Linux and simulator results stand for the mechanism
  only. The run-time check of section 8 covers the
  value's form; that it is new at each boot on every iOS can only be probed, never proved here.
- The time of a small `write()` on the phone's file system with data protection, and of the
  applier and the codec in a release build. Only debug figures from the dev container exist.
- That `write()` returning means "survives the death of the process" on iOS as on Linux is
  the premise of the whole stage (it is the plan's). The kill loop shows it for Linux; the
  probe item "write, kill, read back" and "Crash Now" show it on the phone.
- 2026-11-21: on iOS 27 the app cannot read `kern.bootsessionuuid` (errno 1, Operation not permitted).
