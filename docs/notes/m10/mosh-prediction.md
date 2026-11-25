# Local echo (prediction) in mosh 1.4.0: specification

Source of truth: `.refs/mosh/src` (mosh 1.4.0). Every claim cites `file:line`
relative to that directory, except `scripts/mosh.pl`, which is relative to
`.refs/mosh`. Abbreviations: `toh` = `frontend/terminaloverlay.h`,
`toc` = `frontend/terminaloverlay.cc`, `stc` = `frontend/stmclient.cc`,
`sth` = `frontend/stmclient.h`, `tfb` = `terminal/terminalframebuffer.h`,
`tfbc` = `terminal/terminalframebuffer.cc`, `tsi` = `network/transportsender-impl.h`,
`tsh` = `network/transportsender.h`, `ct` = `statesync/completeterminal.cc`,
`pst` = `terminal/parserstate.cc`.

This document describes what mosh does, including what looks wrong. It
proposes nothing.

---

## 1. Overview

The prediction engine (`Overlay::PredictionEngine`, toh:201-308) watches every
byte the user types, guesses what the server's screen will look like once it
has echoed that byte, and paints the guess on top of the last frame received
from the server. Each guess (a *prediction*) is either one cell's new contents
(`ConditionalOverlayCell`) or a cursor position (`ConditionalCursorMove`). Each
remembers the number of the client state that carries the keystroke
(`expiration_frame`). When the server says it has had that state for a while
(the *echo ack*, section 9.3), the guess is compared with the server's real
screen: right guesses are retired, a wrong guess throws away all guesses (or
only the guesses made after the last "uncertain" input, section 5).

Guesses are grouped into *epochs*. After any input whose effect the engine
cannot model (a control character, an escape sequence, a wide character, the
last column...), the engine opens a new epoch. Guesses of an epoch are *not
drawn* until the server confirms one guess of that epoch (or a later one). So
after an uncertain input, nothing is echoed locally until one round trip proves
the engine right again.

Whether anything is drawn at all depends on the display preference and on
timing triggers (slow round trip, or a guess that stayed unconfirmed too long).

---

## 2. Types and every field

### 2.1 `enum Validity` (toh:52-58)

`Pending`, `Correct`, `CorrectNoCredit`, `IncorrectOrExpired`, `Inactive`, in
that order (values 0..4; the values are never used numerically).

### 2.2 `ConditionalOverlay` (toh:60-82), base class

| field | type | meaning |
|---|---|---|
| `expiration_frame` | uint64 | number of the client state that carries the input this guess depends on. The guess is judged once `late_ack >= expiration_frame`. (toh:62) |
| `col` | int | column of the cell, or predicted cursor column (toh:63) |
| `active` | bool | "represents a prediction at all" (toh:64). Constructor sets false (toh:70). |
| `tentative_until_epoch` | uint64 | the epoch this guess belongs to; it is drawn only once `confirmed_epoch >= tentative_until_epoch` (toh:65, 76) |
| `prediction_time` | uint64 | `timestamp()` when the guess was last made or renewed; used for glitch timing. Constructor sets `uint64_t(-1)` (toh:71). |

Methods:

- Constructor `(s_exp, s_col, s_tentative)`: `expiration_frame = s_exp`,
  `col = s_col`, `active = false`, `tentative_until_epoch = s_tentative`,
  `prediction_time = UINT64_MAX` (toh:68-72).
- `tentative(confirmed_epoch)` returns `tentative_until_epoch > confirmed_epoch`
  (toh:76).
- `reset()`: `expiration_frame = tentative_until_epoch = UINT64_MAX`,
  `active = false` (toh:77). It does not touch `col` or `prediction_time`. An
  inactive overlay is therefore "tentative" for every epoch.
- `expire(s_exp, now)`: `expiration_frame = s_exp; prediction_time = now`
  (toh:78-81).

### 2.3 `ConditionalCursorMove : ConditionalOverlay` (toh:84-95)

Extra field `row` (int, toh:86). Constructor `(s_exp, s_row, s_col,
s_tentative)` passes `s_exp, s_col, s_tentative` to the base (toh:92-94); so a
new cursor move is inactive with `prediction_time = UINT64_MAX` until the caller
sets `active = true` (every caller does, toh:393, 429, 436).

`get_validity(fb, early_ack, late_ack)` (toc:116-139). `early_ack` is unused
(toc:117). In order:

1. `!active` → `Inactive` (toc:120-122).
2. `row >= fb height` or `col >= fb width` → `IncorrectOrExpired` (toc:124-128).
3. `late_ack >= expiration_frame`: if `fb.ds.cursor_col == col` and
   `fb.ds.cursor_row == row` → `Correct`, else `IncorrectOrExpired`
   (toc:130-136).
4. otherwise `Pending` (toc:138).

A cursor move never returns `CorrectNoCredit`.

`apply(fb, confirmed_epoch)` (toc:141-157): return if `!active` (143) or
`tentative(confirmed_epoch)` (147). Then `assert(row < height)`,
`assert(col < width)`, `assert(!fb.ds.origin_mode)` (151-153), then
`fb.ds.move_row(row, false)` and `fb.ds.move_col(col, false, false)` (155-156).
With origin mode off, `move_row(N,false)` sets `cursor_row = N` (tfbc:134-145,
`limit_top()` = 0 at tfbc:254-257), clamps to the screen
(`snap_cursor_to_border`, tfbc:126-132), starts a new grapheme and clears
`next_print_will_wrap`. `move_col(N,false,false)` sets `cursor_col = N`, clamps,
starts a new grapheme and clears `next_print_will_wrap` (tfbc:147-168).

### 2.4 `ConditionalOverlayCell : ConditionalOverlay` (toh:97-125)

| field | type | meaning |
|---|---|---|
| `replacement` | `Terminal::Cell` | the predicted cell. Constructed as `Cell(0)` (toh:110): empty contents, `Renditions(0)` (fg 0, bg 0, no attributes, tfbc:456-459), `wide = fallback = wrap = false` (tfbc:41-47). |
| `unknown` | bool | the engine knows this cell will change but not to what (toh:100); constructor false (toh:111) |
| `original_contents` | `vector<Cell>` | cells this position held before (screen contents, and the engine's own earlier guesses); a guess that matches one of them earns no credit (toh:102-103) |

Methods:

- Constructor `(s_exp, s_col, s_tentative)` (toh:108-113).
- `reset()`: `unknown = false`, `original_contents.clear()`, then base
  `reset()` (toh:115). `replacement` is **not** cleared.
- `reset_with_orig()` (toh:116-124): if `!active || unknown` → full `reset()`.
  Otherwise push the current `replacement` onto `original_contents` and do only
  the base reset (so `original_contents` is kept and grows).
- `get_validity(fb, row, early_ack, late_ack)` (toc:74-114), `early_ack`
  unused (toc:75). In order:
  1. `!active` → `Inactive` (78-80).
  2. `row >= height` or `col >= width` → `IncorrectOrExpired` (82-85).
  3. `late_ack < expiration_frame` → `Pending` (90-92).
  4. `unknown` → `CorrectNoCredit` (94-96).
  5. `replacement.is_blank()` → `CorrectNoCredit` ("too easy for this to
     trigger falsely", 98-100).
  6. If `current.contents_match(replacement)` (current = `fb` cell at
     `(row,col)`): if any element of `original_contents` also
     `contents_match(replacement)` → `CorrectNoCredit`, else `Correct`
     (102-112).
  7. otherwise `IncorrectOrExpired` (113).
- `apply(fb, confirmed_epoch, row, flag)`: section 8.

Cell helpers used (tfb):

- `is_blank()`: contents empty, or `" "`, or `"\xC2\xA0"` (U+00A0) (tfb:133-139).
- `contents_match(o)`: both blank, or byte-identical contents (tfb:141-145).
  Renditions, `wide`, `fallback`, `wrap` are ignored.
- `operator==`: contents, `fallback`, `wide`, renditions and `wrap` all equal
  (tfb:114-121). Renditions equality is attributes, fg, bg (tfb:82-87).
- `clear()` empties contents only (tfb:131); `append(c)` appends the UTF-8 bytes
  of `c` (ASCII directly, others via `wcrtomb`) (tfb:170-182).
- Contents are a byte string (tfb:100-101), so comparisons are on UTF-8 bytes.

### 2.5 `ConditionalOverlayRow` (toh:127-137)

`row_num` (int) and `overlay_cells` (`vector<ConditionalOverlayCell>`).
`apply(fb, confirmed_epoch, flag)` calls each cell's `apply(fb,
confirmed_epoch, row_num, flag)` in column order (toc:347-354).

Rows are made only by `get_or_make_row(row_num, num_cols)` (toc:628-650): it
returns the first row in `overlays` with that `row_num`; otherwise it appends a
new row with `num_cols` cells, cell `i` built as
`ConditionalOverlayCell(0, i, prediction_epoch)` (inactive, `col = i`), and
returns it. So every row has one cell per column of the width at creation time,
and `overlay_cells[i].col == i` (toc:646).

### 2.6 `PredictionEngine` (toh:201-308)

Private fields and initial values (constructor toh:294-307):

| field | initial | meaning |
|---|---|---|
| `last_byte` (char) | 0 | previous byte seen, for the `ESC O` rule (toh:215) |
| `parser` (`Parser::UTF8Parser`) | fresh | the engine's own terminal-input parser (toh:216) |
| `overlays` (`list<ConditionalOverlayRow>`) | empty | cell predictions, one entry per row ever predicted since last reset (toh:218-219) |
| `cursors` (`list<ConditionalCursorMove>`) | empty | cursor predictions, oldest first; `cursor()` is `cursors.back()` and asserts non-empty (toh:221-222, 242) |
| `local_frame_sent` | 0 | number of the last state the client sent, set per read of user input (toh:226) |
| `local_frame_acked` | 0 | number of the newest client state the server acknowledged; stored, passed as `early_ack`, never used (toh:226) |
| `local_frame_late_acked` | 0 | the server's echo ack (section 9.3) (toh:226) |
| `prediction_epoch` | 1 | epoch new guesses are put in (toh:230) |
| `confirmed_epoch` | 0 | highest epoch confirmed by the server (toh:231) |
| `flagging` | false | underline predictions (toh:237) |
| `srtt_trigger` | false | show predictions because the round trip is slow (toh:238) |
| `glitch_trigger` (unsigned) | 0 | show predictions temporarily because a guess stayed pending long (toh:239) |
| `last_quick_confirmation` | 0 | time of the last glitch-trigger decrement (toh:240) |
| `send_interval` (unsigned) | 250 | the transport's send interval in ms (toh:248) |
| `last_height`, `last_width` | 0, 0 | screen size seen by the last `cull` (toh:250) |
| `display_preference` | `Adaptive` | section 10 (toh:261) |
| `predict_overwrite` | false | overwrite instead of insert (toh:262) |

`enum DisplayPreference { Always, Never, Adaptive, Experimental }` (toh:253-258).

Private methods: `get_or_make_row` (2.5), `become_tentative` (5.2),
`newline_carriage_return` (6.6), `kill_epoch` (5.3), `init_cursor` (6.2),
`active()` (toc:913-932: true if `cursors` is non-empty, or any cell in any row
has `active`), `timing_tests_necessary()` = `!(glitch_trigger && flagging)`
(toh:266-269).

Public: `set_display_preference`, `set_predict_overwrite` (toh:272-273),
`apply` (section 8), `new_user_byte` (section 6), `cull` (section 7), `reset`
(section 10.1), `set_local_frame_sent/acked/late_acked` (plain stores,
toh:281-283), `set_send_interval` (toh:285), `wait_time()` = 50 if
`timing_tests_necessary() && active()`, else `INT_MAX` (toh:287-292).

### 2.7 `NotificationEngine` (toh:140-199, toc:159-331)

Draws the blue bar on row 0 ("mosh: Last contact N seconds ago.", "Connecting...",
network errors, the quit-key hint). It keeps `last_word_from_server` and
`last_acked_state` (both initialised to `timestamp()`, toc:160-161), a message,
its expiry, and whether it is a network error. "Server late" is more than
6500 ms since last word (toh:150); "reply late" is more than 10000 ms since the
last acknowledged state (toh:151). Ordinary messages expire 1000 ms after being
set (toh:168), network errors after `ACK_INTERVAL + 100` = 3100 ms (toh:188,
tsh:54), and `clear_network_error` shortens that to at most 1000 ms
(toh:191-196). Its `wait_time` asks for a redraw when the message expires and
every 1000 ms while counting up (every `ACK_INTERVAL` after 60 s of silence)
(toc:312-331). `apply` hides the cursor if it is on row 0, paints row 0 with fg 7 /
bg 4 spaces, and writes the message in bold (toc:182-303). It runs **after**
the prediction engine on the same frame, so it covers any prediction on row 0.
It does not interact with prediction state.

### 2.8 `TitleEngine` (toh:310-318, toc:342-345)

Holds a window-title prefix and calls `fb.prefix_window_title(prefix)` on
apply. stmclient sets `"[mosh] "` while connecting and `""` afterwards
(stc:126, 206). No interaction with prediction.

### 2.9 `OverlayManager` (toh:321-341, toc:333-340)

Owns one `NotificationEngine`, one `PredictionEngine`, one `TitleEngine`.
`apply(fb)` runs, in this order: `predictions.cull(fb)`,
`predictions.apply(fb)`, `notifications.adjust_message()`,
`notifications.apply(fb)`, `title.apply(fb)` (toc:333-340). `wait_time()` is the
minimum of the notification and prediction wait times (toh:337-340).

---

## 3. Constants

| name | value | where | use |
|---|---|---|---|
| `SRTT_TRIGGER_LOW` | 20 ms | toh:203 | `srtt_trigger` turns off only if `send_interval <= 20` (toc:458-462) |
| `SRTT_TRIGGER_HIGH` | 30 ms | toh:204 | `srtt_trigger` turns on if `send_interval > 30` (toc:456-457) |
| `FLAG_TRIGGER_LOW` | 50 ms | toh:206 | `flagging` off if `send_interval <= 50` (toc:467-468) |
| `FLAG_TRIGGER_HIGH` | 80 ms | toh:207 | `flagging` on if `send_interval > 80` (toc:465-466) |
| `GLITCH_THRESHOLD` | 250 ms | toh:209 | pending this long sets `glitch_trigger = 10` (toc:581-583); a confirmation faster than this may decrement it (toc:555) |
| `GLITCH_REPAIR_COUNT` | 10 | toh:210 | level of `glitch_trigger` for "display" (toc:583); `glitch_trigger > 10` forces flagging (toc:472-474); `2 * 10 = 20` is "display and underline" (toc:580) |
| `GLITCH_REPAIR_MININTERVAL` | 150 ms | toh:211 | minimum time between two decrements of `glitch_trigger` (toc:556) |
| `GLITCH_FLAG_THRESHOLD` | 5000 ms | toh:213 | pending this long sets `glitch_trigger = 20` (toc:579-580) |
| wait time | 50 ms | toh:290 | engine asks the main loop to wake every 50 ms while it has guesses and some timing trigger has not fired |
| paste threshold | 100 bytes | stc:325 | a single `read()` of more than 100 bytes resets the engine and predicts none of it |
| `ECHO_TIMEOUT` | 50 ms | statesync/completeterminal.h:60 | server side: a client state counts as echo-acked once the server has held it 50 ms (ct:138) |
| `SEND_INTERVAL_MIN` / `MAX` | 20 / 250 ms | tsh:52-53 | clamp of `send_interval()` (tsi:73-83) |
| `ACK_INTERVAL` | 3000 ms | tsh:54 | notification timing only |
| initial `SRTT` | 1000 ms | network/network.cc:248, 370 | so `send_interval()` is 250 until the first RTT sample |
| initial `send_interval` field | 250 | toh:302 | value until stmclient first calls `set_send_interval` |
| initial `prediction_epoch` / `confirmed_epoch` | 1 / 0 | toh:297 | |

---

## 4. Time

`timestamp()` inside the engine resolves to `Network::timestamp()` (namespace
`Overlay` has `using namespace Network`, toh:46), which returns
`frozen_timestamp()` (network/network.cc:596-599). That returns a cached
millisecond value of a monotonic clock (util/timestamp.cc:61-70). The cache is
refreshed only by `freeze_timestamp()` (util/timestamp.cc:72-130), which is
called:

- at the end of every `Select::select()` (util/select.h:187), i.e. once per
  main-loop iteration, right after the wait;
- after a `NetworkException` in the client main loop, after a 200 ms sleep
  (stc:563-567);
- on the very first `frozen_timestamp()` call if the cache is empty
  (util/timestamp.cc:65-67).

So all engine calls within one main-loop iteration see the same "now".

Engine reads of `timestamp()` (each must come from the test's clock):

| where | use |
|---|---|
| `cull`, toc:453 | `now` for glitch decrement (555-558) and pending ages (579-584) |
| `new_user_byte`, toc:663 | `now` passed to every `expire(..., now)` in that call (702, 709, 722, 771, 796, 821, 847, 854) |
| `newline_carriage_return`, toc:866 | `now`, used only by the commented-out scroll code (871-884); the blank-row prediction calls `expire(local_frame_sent + 1, now)` with it (893) |

Not engine, same manager: `NotificationEngine` reads `timestamp()` at
toh:168, 188, 194, toc:160-161, 184, 307, 316. The transport's own reads
(e.g. `tsi:208`, `tsi:254`) determine state numbers and `send_interval`, which
reach the engine only through the setters of section 9.

---

## 5. Epochs

### 5.1 Meaning

- `prediction_epoch`: every new or renewed guess gets
  `tentative_until_epoch = prediction_epoch`.
- `confirmed_epoch`: a guess is drawn only when
  `tentative_until_epoch <= confirmed_epoch` (toh:76; toc:51, 147).
- `confirmed_epoch` only grows: in `cull`, a `Correct` cell with
  `tentative_until_epoch > confirmed_epoch` sets `confirmed_epoch` to it
  (toc:543-545). Cursor moves never confirm. `reset()` and `kill_epoch` do not
  change it.

### 5.2 `become_tentative()` (toc:901-911)

`prediction_epoch++`, except in `Experimental` mode, where it does nothing.

### 5.3 `kill_epoch(epoch, fb)` (toc:378-408)

Called by `cull` when a guess that was still tentative turns out wrong
(non-Experimental only, toc:507).

1. Erase every cursor move with `tentative(epoch - 1)`, i.e.
   `tentative_until_epoch >= epoch` (toc:380-387).
2. Append a new cursor move at the frame's actual cursor:
   `ConditionalCursorMove(local_frame_sent + 1, fb cursor_row, fb cursor_col,
   prediction_epoch)`, `active = true` (toc:389-393). Its `prediction_time`
   stays `UINT64_MAX`.
3. `reset()` every cell (in every row) with `tentative_until_epoch >= epoch`
   (toc:395-405). Inactive cells qualify (their epoch is `UINT64_MAX`) and are
   reset again, harmlessly.
4. `become_tentative()` (toc:407).

Guesses of earlier, already-confirmed epochs survive.

### 5.4 Worked example (Adaptive, slow link, insert mode, 80x24, shell prompt
at row 5 col 2, cursor there; `local_frame_sent` = 10)

1. First `cull` ever: size 0x0 differs from 80x24 → `reset()` →
   `prediction_epoch = 2` (toc:446-451, 410-414).
2. User types `l`. `init_cursor`: no cursors → push cursor (5,2), exp 11,
   epoch 2. Cells (5,3..79) shifted right, cell (5,2) = `l`, all epoch 2, exp
   11. Cursor col → 3. `confirmed_epoch = 0 < 2`: nothing drawn.
3. User types `s`: same epoch 2, (5,3) = `s`, cursor col 4. Still not drawn.
4. Server echoes; a frame arrives whose echo ack is 11 and which shows `ls`.
   `cull`: cell (5,2) `l` is `Correct` (not in its `original_contents`) →
   `confirmed_epoch = 2`; the cell is reset. Cell (5,3) `s` likewise. From now
   on epoch-2 guesses are drawn at once: typing `-` immediately shows `-`.
5. User presses Return (`0x0d`): `become_tentative` → epoch 3; new cursor
   (6,0) in epoch 3. Typing `x` puts `x` in epoch 3: not drawn
   (`confirmed_epoch` 2 < 3) until the server confirms a cell of epoch 3.
6. Suppose instead the server shows (6,0) = `y` when the echo ack reaches the
   `x`'s state. The `x` cell is `IncorrectOrExpired` and tentative
   (3 > 2) → `kill_epoch(3)`: cursors and cells of epoch >= 3 go, a fresh
   cursor at the server's cursor is pushed in epoch 3, `prediction_epoch = 4`.
   Epoch-2 guesses still pending are kept.
7. Had the wrong cell been in epoch 2 (already confirmed, so not tentative),
   `cull` would call `reset()` and return: every guess is discarded
   (toc:528-533).

---

## 6. `new_user_byte(the_byte, fb)` (toc:652-862)

`fb` is the client's *displayed* framebuffer (`local_framebuffer`, stc:334),
which already contains the previous frame's overlays (section 9.5).

### 6.1 Preamble, per byte

1. `Never` → return; nothing else happens, not even parser or `last_byte`
   updates (toc:654-656).
2. `Experimental` → `prediction_epoch = confirmed_epoch` (toc:657-659).
3. `cull(fb)` (toc:661) — every byte, including UTF-8 continuation bytes and
   bytes inside escape sequences.
4. `now = timestamp()` (toc:663).
5. If `last_byte == 0x1b` and `the_byte == 'O'`, replace `the_byte` with `'['`
   (toc:666-669). Then `last_byte = the_byte` (the replaced value) (toc:670).
   Purpose: the client puts the outer terminal into application cursor-key
   mode (`ESC [ ? 1 h`, terminal/terminaldisplay.cc:48-51, sent at stc:122 in
   init and stc:77 on resume), so arrows arrive as `ESC O C`; this turns them into
   `ESC [ C`.
6. `parser.input(the_byte, actions)` (toc:672-673), then handle each action in
   order (toc:675-861). Only four action types matter: `Print`, `Execute`,
   `Esc_Dispatch`, `CSI_Dispatch` (`typeid` tests, toc:685-860). All others
   (`Clear`, `Collect`, `Param`, `OSC_Start`, `OSC_Put`, `OSC_End`, `Hook`,
   `Put`, `Unhook`) do nothing. `Ignore` actions are never delivered
   (terminal/parser.cc:43-51).

### 6.2 `init_cursor(fb)` (toc:419-438)

- No cursors: append `ConditionalCursorMove(local_frame_sent + 1, fb
  cursor_row, fb cursor_col, prediction_epoch)`, `active = true` (421-429).
- Else if `cursor().tentative_until_epoch != prediction_epoch`: append a copy
  of the last cursor's row and col with `exp = local_frame_sent + 1` and
  `epoch = prediction_epoch`, active (430-437).
- Else nothing (the current cursor is reused and mutated).

New cursor moves have `prediction_time = UINT64_MAX` until `expire` is called.

### 6.3 The engine's parser (UTF8Parser + X.364 state machine)

`UTF8Parser::input(c)` (terminal/parser.cc:76-156):

- If no bytes are buffered and `c <= 0x7f`, feed it as a code point directly
  (81-84).
- Otherwise buffer it and decode with `mbrtowc` (locale must be UTF-8; the
  client refuses to run otherwise, stc:85). Incomplete → no action (123-126).
  Invalid → emit U+FFFD and retry from the last byte (111-122). NUL → U+0000
  (105-110). Code points above U+10FFFF and surrogates → U+FFFD (139-150).

`Parser::input(ch)` (terminal/parser.cc:53-67): leaving a state emits its
`exit` action, then the transition action, then entering the new state emits
its `enter` action. "Anywhere" rules apply in every state first (pst:39-61,
63-71): 0x18, 0x1A, 0x80-0x8F, 0x91-0x97, 0x99, 0x9A → `Execute` and go to
Ground; 0x9C → Ground; 0x1B → Escape; 0x98/0x9E/0x9F → SOS/PM/APC string;
0x90 → DCS entry; 0x9D → OSC string; 0x9B → CSI entry. Otherwise the state's
rule runs on `ch`, with any `ch >= 0xA0` treated as `'A'` for the decision
(pst:74), and the action's `ch` is the real code point (pst:75-76).

"C0'" = 0x00-0x17, 0x19, 0x1C-0x1F (pst:80-85).

| state | input → action, next state |
|---|---|
| Ground (pst:93-104) | C0' → `Execute`; 0x20-0x7F and 0xA0-0xFF (and so every ch >= 0xA0) → `Print` |
| Escape (enter: `Clear`) (pst:106-147) | C0' → `Execute`; 0x20-0x2F → `Collect`, Escape_Intermediate; 0x30-0x4F, 0x51-0x57, 0x59, 0x5A, 0x5C, 0x60-0x7E → `Esc_Dispatch`, Ground; `[` → CSI_Entry; `]` → OSC_String; `P` → DCS_Entry; `X ^ _` → SOS/PM/APC; else (0x7F) ignore |
| Escape_Intermediate (pst:149-164) | C0' → `Execute`; 0x20-0x2F → `Collect`; 0x30-0x7E → `Esc_Dispatch`, Ground |
| CSI_Entry (enter: `Clear`) (pst:166-199) | C0' → `Execute`; 0x40-0x7E → `CSI_Dispatch`, Ground; digits and `;` → `Param`, CSI_Param; 0x3C-0x3F → `Collect`, CSI_Param; `:` → CSI_Ignore; 0x20-0x2F → `Collect`, CSI_Intermediate |
| CSI_Param (pst:201-224) | C0' → `Execute`; digits `;` → `Param`; `:` or 0x3C-0x3F → CSI_Ignore; 0x20-0x2F → `Collect`, CSI_Intermediate; 0x40-0x7E → `CSI_Dispatch`, Ground |
| CSI_Intermediate (pst:226-245) | C0' → `Execute`; 0x20-0x2F → `Collect`; 0x40-0x7E → `CSI_Dispatch`, Ground; 0x30-0x3F → CSI_Ignore |
| CSI_Ignore (pst:247-258) | C0' → `Execute`; 0x40-0x7E → Ground (no dispatch) |
| DCS_* (pst:260-358) | no `Execute`/`Print`/dispatch actions reach the engine; exit only via 0x9C or anywhere rules |
| OSC_String (pst:360-381) | 0x20-0x7F → `OSC_Put`; 0x9C or 0x07 → Ground |
| SOS_PM_APC (pst:383-390) | 0x9C → Ground |

The parser state persists across bytes and across reads.

### 6.4 Decision table

"Tentative" means `become_tentative()` is called. "exp" means
`local_frame_sent + 1`. Every listed `expire` uses `now` from toc:663.

| input (as action) | what happens |
|---|---|
| `Print` 0x7F (DEL, the usual Backspace key) | `init_cursor` (689). `get_or_make_row(cursor().row, width)` (698). If `cursor().col > 0`: `col--`, `cursor().expire(exp, now)` (700-702), then overwrite or insert-mode delete (6.5). At col 0: nothing more. Never tentative. |
| `Print` of a printable code point with `wcwidth(ch) == 1` (ASCII 0x20-0x7E, narrow non-ASCII such as `é`, and U+FFFD from invalid UTF-8) | `init_cursor`; predict the character at `cursor()` (6.5); advance or wrap. Tentative only at the last column (6.5). |
| `Print` with `ch < 0x20` or `wcwidth(ch) != 1`: wide (2), combining/zero-width (0), non-printable (-1) | `init_cursor` (689) then tentative (746-748). Nothing predicted; the cursor is not moved. (`ch < 0x20` cannot occur from Ground; the test is dead.) |
| UTF-8 lead and continuation bytes before the last | no action (parser buffers); `cull` still ran. The last byte yields one `Print` with the decoded code point. |
| `Execute` 0x0D (CR, the Return key) | tentative, then `newline_carriage_return` (832-834, 6.6) |
| any other `Execute`: C0' bytes (Tab 0x09, LF 0x0A, Ctrl-H 0x08, Ctrl-C, Ctrl-^ ...), 0x18, 0x1A, C1 Execute code points | tentative only (835-838) |
| `Esc_Dispatch` (e.g. Alt-x = `ESC x`) | tentative (839-841) |
| `CSI_Dispatch` final `C` (right arrow; also `ESC O C` via 6.1 step 5) | `init_cursor`; if `cursor().col < width - 1`: `col++`, `cursor().expire(exp, now)` (843-848). Parameters, private markers and intermediates are ignored. Never tentative. |
| `CSI_Dispatch` final `D` (left arrow) | `init_cursor`; if `col > 0`: `col--`, `expire` (849-855). Same caveats. |
| any other `CSI_Dispatch` (up/down `A`/`B`, Home/End, `ESC [ 3 ~` Delete, function keys...) | tentative (856-859) |
| bare `ESC`, `ESC [`, parameters, intermediates, OSC/DCS contents | nothing (only `Clear`/`Collect`/`Param`/... actions). The byte after ESC is consumed by the Escape state, not printed. |
| `ESC` then `O` (any `O` right after a 0x1B byte) | becomes `ESC [` → CSI_Entry, whatever the user meant |

### 6.5 Predicting a printable character (toc:750-830)

Preconditions asserted: `0 <= cursor().row < height`, `0 <= cursor().col <
width` (751-754). Let `W = width`, `c = cursor().col`, `r = cursor().row`,
`row = get_or_make_row(r, W)` (756).

1. **Last column**: if `c + 1 >= W`, tentative (758-762) — so the character
   typed into the last column lands in a new epoch.
2. **Shift (insert mode)**: `rightmost = predict_overwrite ? c : W - 1` (765).
   For `i` from `rightmost` down to `c + 1` (766-790), cell `i`:
   `reset_with_orig()`, `active = true`, `tentative_until_epoch =
   prediction_epoch`, `expire(exp, now)`, push `fb(r,i)` onto
   `original_contents`; then
   - `i == W - 1` → `unknown = true` (the character pushed off the edge is not
     modeled);
   - else if cell `i-1` is active: copy its `unknown`; if known,
     `replacement = cell(i-1).replacement` (whole Cell);
   - else `unknown = false`, `replacement = fb(r, i-1)` (whole Cell, from the
     displayed frame).
   Because `i` descends, cell `i-1` still holds its value from before this
   keystroke. In overwrite mode the loop is empty.
3. **The typed cell** `c` (792-812): `reset_with_orig()`, `active = true`,
   `tentative_until_epoch = prediction_epoch`, `expire(exp, now)`;
   `replacement.renditions = fb.ds.get_renditions()` (the displayed frame's
   current SGR state); if `c > 0`: renditions of cell `c-1`'s replacement if
   that cell is active and known, else renditions of `fb(r, c-1)` (799-808);
   then `replacement.clear()`, `append(ch)` (810-811); push `fb(r, c)` onto
   `original_contents` (812). `unknown` is not assigned here: it was cleared by
   `reset_with_orig` unless the cell was active-and-known (in which case it was
   already false).
4. `cursor().expire(exp, now)` (821).
5. **Advance**: if `c < W - 1`, `cursor().col++` (824-825); else tentative
   again and `newline_carriage_return(fb)` (826-829).

So typing at the last column uses two new epochs: one for the character
(step 1), one for the wrap (step 5).

**Backspace (0x7F) after `col--`** (toc:704-744), with `c` the new column:

- Overwrite mode: cell `c`: `reset_with_orig()`, active, epoch, `expire`;
  `orig_cell = *fb.get_cell()` — the cell under the *frame's* cursor, not at
  `(r, c)` (tfb:411-417 defaults to the frame cursor); push it onto
  `original_contents`; `replacement = orig_cell`, `clear()`, `append(' ')`
  (705-714). The prediction is a blank, so it never confirms or fails
  (section 2.4 step 5).
- Insert mode: for `i` from `c` up to `W - 1` (716-743), cell `i`:
  `reset_with_orig()`, active, epoch, `expire`, push `fb(r,i)`; then if
  `i + 2 < W`: take cell `i+1`'s prediction if active (copy `unknown`; if known,
  copy `replacement`), else `replacement = fb(r, i+1)`, `unknown = false`;
  otherwise (`i >= W - 2`) `unknown = true`. Ascending `i` means cell `i+1`
  still holds its pre-keystroke value.

**Unknown cells** never change the screen contents; they are judged
`CorrectNoCredit` once acked (toc:94-96), so they neither confirm an epoch nor
kill one, and are drawn only as an underline when flagging (section 8).

### 6.6 `newline_carriage_return(fb)` (toc:864-899)

1. `now = timestamp()` (866); `init_cursor(fb)` (867); `cursor().col = 0`
   (868). `cursor().expire` is **not** called.
2. If `cursor().row == height - 1` (last row): no scroll is predicted (the
   scroll code is commented out, 870-884). Instead every cell of that row
   (`get_or_make_row(row, width)`) gets `active = true`,
   `tentative_until_epoch = prediction_epoch`, `expire(exp, now)`,
   `replacement.clear()` — contents emptied, renditions and other flags kept;
   `unknown` and `original_contents` untouched; no `reset_with_orig` (886-895).
   That is a blank prediction for the whole last row.
3. Else `cursor().row++` (897).

---

## 7. `cull(fb)` (toc:440-626)

Called by `OverlayManager::apply` on each new frame (with the server's frame,
section 9.5) and at the start of every `new_user_byte` (with the displayed
frame). Steps, in order:

1. `Never` → return (442-444).
2. If `fb` height or width differs from `last_height`/`last_width`: store the
   new size and `reset()` (446-451). (Initial 0x0 makes the first cull reset.)
3. `now = timestamp()` (453).
4. **srtt_trigger** (456-462): if `send_interval > 30` → true; else if it is
   true and `send_interval <= 20` and `!active()` → false. (21..30 keeps the
   current value.)
5. **flagging** (465-469): `send_interval > 80` → true; else
   `send_interval <= 50` → false (51..80 keeps).
6. If `glitch_trigger > 10` → `flagging = true` (472-474).
7. **Rows** (478-593), in list order. A row with `row_num < 0` or `>= height` is
   erased (482-486). Otherwise for each cell `j` in column order, switch on
   `j.get_validity(fb, row_num, local_frame_acked, local_frame_late_acked)`:
   - `IncorrectOrExpired`:
     - if `j.tentative(confirmed_epoch)`: Experimental → `j.reset()`; else
       `kill_epoch(j.tentative_until_epoch, fb)` and continue with the next
       cell (494-508).
     - else: Experimental → `j.reset()`; else `reset()` and **return** from
       `cull` (514-533). The cursor checks below are skipped.
   - `Correct` (536-575):
     1. if `j.tentative_until_epoch > confirmed_epoch` → `confirmed_epoch =
        j.tentative_until_epoch` (543-545);
     2. glitch repair: if `now - j.prediction_time < 250` and
        `glitch_trigger > 0` and `now - 150 >= last_quick_confirmation` →
        `glitch_trigger--`, `last_quick_confirmation = now` (555-559);
     3. copy the renditions of `fb(row_num, j.col)` into the `replacement` of
        cell `j` and of every later cell in the row, active or not (562-569);
     4. fall through to `CorrectNoCredit`.
   - `CorrectNoCredit`: `j.reset()` (572-575).
   - `Pending` (576-586): `age = now - j.prediction_time`; if `age >= 5000` →
     `glitch_trigger = 20`; else if `age >= 250` and `glitch_trigger < 10` →
     `glitch_trigger = 10`.
   - `Inactive`: nothing (587-588).
8. **Last cursor** (596-614): if `cursors` is non-empty and `cursor()` (the
   newest) is `IncorrectOrExpired`: Experimental → `cursors.clear()`; else
   `reset()` and return. Tentative or not makes no difference here.
9. **Erase settled cursors** (618-625): remove every cursor move whose validity
   is not `Pending` (`Correct`, `IncorrectOrExpired` for older ones,
   `Inactive`).

Timing inputs: `send_interval` drives steps 4-5; `now` and `prediction_time`
drive 7 (Correct, Pending); `local_frame_late_acked` decides Pending vs judged;
`local_frame_acked` is passed but unused; `local_frame_sent` is used only in
`kill_epoch`'s new cursor (step 7).

---

## 8. `apply(fb)` (toc:356-376) and the underline rule

1. Draw nothing if `Never`, or unless `srtt_trigger || glitch_trigger ||
   Always || Experimental` (358-363). In `Adaptive` mode predictions are shown
   only while a trigger is on.
2. Every cursor move in list order, `ConditionalCursorMove::apply` (365-369):
   active and non-tentative ones move the frame's cursor; the last such one
   wins.
3. Every row in list order, each cell, `ConditionalOverlayCell::apply(fb,
   confirmed_epoch, row_num, flagging)` (371-375).

`ConditionalOverlayCell::apply` (toc:43-72):

1. Return if `!active`, `row >= height` or `col >= width` (45-49).
2. Return if `tentative(confirmed_epoch)` (51-53).
3. If `replacement.is_blank()` and the frame cell is blank → `flag = false`
   (55-57).
4. If `unknown`: if `flag` and `col != width - 1`, set `underlined` on the
   frame cell's renditions; return (59-64). Contents are untouched.
5. If the frame cell `!= replacement` (full equality, 2.4): overwrite the frame
   cell with `replacement`, then if `flag` set `underlined` on it (66-71). If
   they are already equal, nothing is drawn and nothing is underlined.

The underline is the only visual mark of a prediction; it appears when
`flagging` is on, which is when `send_interval > 80` (≈ SRTT > 160 ms, until
it drops to `<= 50`), or `glitch_trigger > 10`.

---

## 9. How stmclient drives the engine

### 9.1 Main loop (stc:423-579)

Each iteration: `output_new_frame()` (442); `wait_time = min(network wait,
overlays.wait_time())` (444), at most 250 while connecting (447-449);
`select` (462, which refreshes the frozen time); if any network fd is
readable, `process_network_input()` (480-482); then if stdin is readable,
`process_user_input()` (484); then resize (493) and other signals; finally
`network->tick()` (549), which may send the new state. Network input is
handled **before** user input in the same iteration.

### 9.2 On user input (stc:303-398)

1. `read(fd, buf, 16384)` (305-309). EOF/error → return false.
2. If shutdown is in progress, return without touching the engine (319-321).
3. `set_local_frame_sent(net.get_sent_state_last())` (322) — once per read.
   `get_sent_state_last()` is `sent_states.back().num` (tsh:154), the number of
   the newest state sent so far. The next state sent that differs gets
   `back().num + 1` (tsi:241-246), so `local_frame_sent + 1` is the state that
   will carry these bytes.
4. `paste = bytes_read > 100`; if so, `reset()` (325-328).
5. For each byte: if not paste, `new_user_byte(byte, local_framebuffer)` (334)
   — **before** the escape-key handling, so Ctrl-^ (0x1E), the `.` that quits,
   and bytes swallowed by the escape logic are all fed to the engine. Then the
   byte goes to `net.get_current_state()` (or is handled as the escape key)
   (337-394).

### 9.3 On network input (stc:290-301)

After `network->recv()`:

- `set_local_frame_acked(network->get_sent_state_acked())` (298): the number of
  the oldest kept sent state, `sent_states.front().num` (tsh:153), which after
  `process_acknowledgment_through` (tsi:358-378) is the newest state the server
  acknowledged.
- `set_send_interval(network->send_interval())` (299): `ceil(SRTT / 2)` clamped
  to 20..250 ms (tsi:73-83).
- `set_local_frame_late_acked(network->get_latest_remote_state().state.get_echo_ack())`
  (300): the echo ack carried by the newest received server state.

Echo ack, server side: when the server applies a client state that carried user
input, it records `(state number, now)` (frontend/mosh-server.cc:767-770 →
ct:162-165). `set_echo_ack(now)` (ct:130-160, called each server loop,
mosh-server.cc:909-912) sets `echo_ack` to the newest recorded number received
at least 50 ms ago (ct:138), drops older records, and if it changed the server
sends a new state. So `late_ack >= expiration_frame` means "the server has had
the keystroke for 50 ms; its screen should show the echo by now".

Also on network input: `server_heard` / `server_acked` for notifications
(295-296).

### 9.4 On resize (stc:400-421)

Sends a `Resize` and calls `reset()` (418). `cull` also resets when the frame
size changes.

### 9.5 Putting a frame on the screen (stc:267-288)

1. `new_state = latest remote state's framebuffer` (a copy) (274).
2. `overlays.apply(new_state)`: cull, apply predictions, notifications, title
   (277, toc:333-340).
3. Diff against `local_framebuffer` and write to the terminal (280-283).
4. `local_framebuffer = new_state` (287) — so the frame later passed to
   `new_user_byte` contains the drawn predictions, underlines, notification bar
   and the predicted cursor position.

`main_init` makes `local_framebuffer` the window size (stc:245), so the first
`new_user_byte` sees a blank frame of the right size before any server frame.

---

## 10. Reset and display preferences

### 10.1 `reset()` (toc:410-417)

Clear `cursors` and `overlays`, then `become_tentative()`. It keeps
`confirmed_epoch`, `prediction_epoch` (incremented), triggers, flagging,
`last_byte`, the parser state, the frame counters, `send_interval`,
`last_height/width`.

Callers: `cull` size change (toc:450), wrong confirmed cell (531), wrong last
cursor (611), paste (stc:327), resize (stc:418).

### 10.2 Modes

| mode | `new_user_byte` | `cull` | `apply` draws | on a wrong guess |
|---|---|---|---|---|
| `Never` | returns at once | returns at once | nothing | — |
| `Adaptive` (default) | normal | normal | only if `srtt_trigger` or `glitch_trigger` | tentative: `kill_epoch`; confirmed: `reset()` |
| `Always` | normal | normal | always | same as Adaptive |
| `Experimental` | `prediction_epoch = confirmed_epoch` per byte; `become_tentative` is a no-op | normal | always | only that cell is `reset()`; wrong last cursor → `cursors.clear()` |

In `Experimental` everything is non-tentative from the start, because
`prediction_epoch` is pulled down to `confirmed_epoch` (initially 0).

### 10.3 How the client chooses

- `scripts/mosh.pl`: `--predict=adaptive|always|never|experimental`, `-a`
  (always), `-n` (never) (scripts/mosh.pl:157-161; help text 98-103). If no
  option is given, `MOSH_PREDICTION_DISPLAY` from the environment is used; else
  `adaptive` (185-193). Unknown values are rejected (143-153). The script
  deletes the variable for the ssh step (236) and sets it to the chosen mode for
  `mosh-client` (463). `--predict-overwrite` / `-o` (158) sets
  `MOSH_PREDICTION_OVERWRITE=yes` (209-211).
- `mosh-client` reads `MOSH_PREDICTION_DISPLAY` and `MOSH_PREDICTION_OVERWRITE`
  (frontend/mosh-client.cc:174-180) and passes them to `STMClient`.
- `STMClient` constructor (sth:109-125): `"always"`, `"never"`, `"adaptive"`,
  `"experimental"` set the preference; any other non-null value prints
  `Unknown prediction mode` and exits 1; unset keeps `Adaptive`. Overwrite is
  on only if the variable is exactly `"yes"`.

---

## 11. Quirks to reproduce

1. **The engine judges against the displayed frame on keystrokes.** `cull` in
   `new_user_byte` (toc:661) uses `local_framebuffer` (stc:334), which holds
   the previous frame *with predictions drawn* (stc:287). Because network input
   is processed before user input in the same iteration (stc:480-484), a fresh
   echo ack can be checked against the stale frame: a shown prediction is then
   compared with itself and counts as `Correct`, confirming its epoch. Copied
   renditions (toc:563-568) may include the drawn underline.
2. **Original contents and copied neighbours come from the displayed frame**,
   including earlier predictions and the notification bar on row 0 (toc:723,
   738, 772, 788, 797, 806, 812).
3. **Overwrite-mode backspace uses the wrong cell**: `*fb.get_cell()` is the
   cell under the frame's cursor, not at the predicted column (toc:710-714).
4. **Insert-mode backspace marks two columns unknown**: test is `i + 2 < W`,
   so columns `W-2` and `W-1` become unknown (toc:725, 740-742).
5. **`replacement.clear()` keeps stale flags**: only contents are cleared, so
   `wide`, `fallback`, `wrap` and (for the newline row) renditions persist from
   whatever Cell was last copied into that replacement (toc:810, 894; tfb:131).
   `reset()` never clears `replacement` (toh:115, 77).
6. **Blank last-row prediction on wrap or Return at the bottom row**: the whole
   row is predicted blank in place (no scroll), wiping the character just
   predicted there; `unknown` and `original_contents` are left as they were
   (toc:869-895).
7. **`newline_carriage_return` does not expire the cursor**: in Experimental
   (no new epoch, so `init_cursor` reuses the cursor) the moved cursor keeps its
   old `expiration_frame` and `prediction_time` (toc:867-868, 430).
8. **Arrow keys ignore parameters**: any CSI ending in `C` or `D` moves one
   column (`ESC [ 5 C`, `ESC [ 1 ; 5 C`, `ESC [ ? C`) (toc:843-855).
9. **`ESC O` rewriting applies to any `O` after ESC**, e.g. vim's Esc then
   `O`; the next byte is then parsed as a CSI final (`h` → tentative, `C` →
   cursor move) (toc:666-670). `last_byte` stores the rewritten `'['`.
10. **The byte after a bare ESC is eaten** by the Escape state and only makes
    things tentative (pst:121-127); the parser state persists across reads.
11. **Paste skips the parser**: reads over 100 bytes are not fed to
    `new_user_byte`, so `parser` and `last_byte` can be left mid-sequence
    (stc:325-335).
12. **The escape key and quit/suspend bytes are predicted** (stc:334 before
    337): e.g. `Ctrl-^ .` predicts a `.`.
13. **`Never` does not update parser or `last_byte`** (toc:654-656).
14. **Only the newest cursor can reset**: an older cursor move that is
    `IncorrectOrExpired` is silently erased (toc:596-625); a wrong newest cursor
    calls `reset()` even when tentative (no `kill_epoch`).
15. **Cursor moves never confirm an epoch**; only `Correct` cells do
    (toc:543-545).
16. **A correct confirmation recolours the rest of the row**, including
    inactive cells and cells already judged (toc:562-569).
17. **Unsigned arithmetic**: `now - GLITCH_REPAIR_MININTERVAL` wraps when
    `now < 150` (toc:556), making the test true; `now - prediction_time` with
    `prediction_time = UINT64_MAX` gives `now + 1` (toh:71). Tests with a clock
    starting near 0 hit the first case.
18. **`apply` asserts `!origin_mode`** for a non-tentative cursor move
    (toc:153). With assertions compiled in, mosh aborts if the server frame is
    in origin mode while such a cursor exists.
19. **Blank guesses never count**: a predicted space, an overwrite backspace,
    or a blank newline row is `CorrectNoCredit` once acked, never wrong
    (toc:98-100).
20. **`wcwidth` decides what is predicted** (toc:746) and is the C library's
    table; a differential test must use the same table as the oracle.
21. **`ch < 0x20` in the Print branch is dead code** (Ground never prints C0,
    pst:95-101); 0x7F is a `Print` (GL range, pst:89) and is the backspace.
22. **`get_or_make_row` in the backspace path runs even at column 0**, creating
    an all-inactive row (toc:698).
23. **`local_frame_acked` (`early_ack`) is never used** (toc:75, 117); only the
    late (echo) ack judges guesses.
24. **`kill_epoch`'s new cursor uses the frame's cursor**, which, when called
    from a keystroke's `cull`, is the displayed (possibly predicted) cursor
    (toc:389-392).
25. **One `local_frame_sent` per read**: all bytes of one read share
    `expiration_frame`, set before the bytes are queued (stc:322).
