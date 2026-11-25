# Corpus format

The golden corpus of the terminal model: what each file of a case holds, exactly.
Written so that a loader can be made from this document alone.
`check_format.py` in this directory is such a loader, a short Python file, and
`scripts/corpus-check.sh --gen` proves that it rebuilds every state of the corpus.

Everything here describes mosh 1.4.0 built on Ubuntu 24.04 (glibc 2.39, locale
`en_US.UTF-8`). Character widths in the corpus are that glibc's `wcwidth`.

## 1. Files of a case

A case is a directory `Tests/MoshTerminalTests/Corpus/<case>/`:

| File | Written by | Holds |
|---|---|---|
| `meta.json` | `gen` | format version and the first window size |
| `session.jsonl` | recorder or `synthetic.py` | input of the server-side simulation |
| `instructions.jsonl` | `gen` (or `moshcli --record` for live recordings) | what the server sent |
| `expected.jsonl` | `gen`, `apply` | the client's state after each instruction |
| `server.jsonl` | `gen`, `server` | the server's own state after each session line |

All files are UTF-8 text, one JSON value per line (`meta.json`: one line), lines end
with `\n`, no blank lines. Binary data is standard base64 with padding (RFC 4648
section 4), in keys whose name ends in `_b64`.

A directory recorded from a live server by `moshcli --record` has `meta.json` and
`instructions.jsonl` only; `mosh-oracle apply DIR` prints its `expected.jsonl`.

## 2. meta.json

```
{"format":1,"width":80,"height":24}
```

`format` is `1` for everything in this document. `width` and `height` are the size
of state 0, the blank terminal both sides start from.

## 3. session.jsonl

Line 1 is `{"width":W,"height":H}`. Every later line is one step of the server-side
simulation and has exactly one of these keys:

| Key | Value | Meaning |
|---|---|---|
| `bytes_b64` | base64 | bytes the program wrote to the pty; fed to the server's terminal with `Complete::act(string)` |
| `resize` | `[w, h]` | the window was resized; `Complete::act(Parser::Resize(w, h))` |
| `echo_ack` | integer n | the server's echo ack becomes n (as `register_input_frame` and `set_echo_ack` do); n never decreases |

Any other key is a comment and is ignored (`note` in the `syn-*` cases repeats the
bytes as a Python bytes literal without the quotes).

Session line k+1 (the k-th step, k from 1) produces server state k and instruction
k. So in a generated case state numbers are 1, 2, 3, ... and line k of
`instructions.jsonl`, `expected.jsonl` and `server.jsonl` all belong to session line
k+1.

## 4. instructions.jsonl

One line per instruction, in the order the client received them:

```
{"old_num":3,"new_num":4,"diff_b64":"CjAS...","ops":[{"hostbytes_b64":"G1sw..."}]}
```

| Key | Type | Meaning |
|---|---|---|
| `old_num` | integer | number of the state the diff applies to (the base). State 0 is the blank terminal of `meta.json` |
| `new_num` | integer | number of the state the diff produces. Each `new_num` appears exactly once in a file |
| `diff_b64` | base64 | the diff string of the transport instruction: a serialized `HostBuffers.HostMessage`. Empty string for an empty diff |
| `ops` | array | that `HostMessage` decoded, in order |

Each element of `ops` is an object with exactly one key:

| Key | Value | Client action (`Complete::apply_string`) |
|---|---|---|
| `hostbytes_b64` | base64 | feed the bytes to the terminal, `act(string)` |
| `resize` | `[w, h]` | `act(Parser::Resize(w, h))` |
| `echo_ack` | integer | `echo_ack = n` |

`diff_from` writes them in the order echo ack, resize, host bytes, each at most once.
The protobuf behind `diff_b64` (proto2, `src/protobufs/hostinput.proto`):
`HostMessage { repeated Instruction instruction = 1; }`, and `Instruction` carries one
of the extensions `hostbytes = 2` (`HostBytes { bytes hoststring = 4; }`),
`resize = 3` (`ResizeMessage { int32 width = 5; int32 height = 6; }`),
`echoack = 7` (`EchoAck { uint64 echo_ack_num = 8; }`). If one `Instruction` had
several extensions, `ops` holds only the first in the order hostbytes, resize,
echoack, because `apply_string` looks no further. `mosh-oracle apply` fails if `ops`
does not match `diff_b64`.

**Empty diff.** `"diff_b64":""` with `"ops":[]`. The receiver stores a copy of state
`old_num` as `new_num` and does not call `apply_string` (as
`Network::Transport::recv` does). A mosh server sends this as an ack when it has
nothing to show; see README.md for when `gen` emits it.

**The base.** `old_num` is usually `new_num - 1`. In generated cases, instructions
with `new_num % 10` equal to 3, 7 or 8 use an older base (2 to 8 states back; 7 and 8
share one base), like a server whose acks are late. The rule is `base_age()` in
main.cc and is spelled out in README.md. A loader must not assume anything about
`old_num` except that the state exists.

## 5. State lines: expected.jsonl and server.jsonl

Both files have one line per state, in the same line format.

- `expected.jsonl`, line i: the **client's** state after instruction i of
  `instructions.jsonl` (the state stored as `new_num`).
- `server.jsonl`, line k: the **server's** own state after session line k+1 (state
  number k).

The two differ in everything the display protocol does not carry; section 8 says why
both are needed.

### 5.1 The delta rule

A line is a JSON object. It does not repeat what did not change:

1. Keep a *current state*: a value for every key of the table in 5.2, and a list of
   `height` rows. Before line 1 the current state is the **initial state**: the
   initial values of the table for the `width` and `height` of `meta.json`, and
   every row blank (`width` empty cells with default renditions, `[{"e":width}]`).
2. `num` is always present. In `expected.jsonl` it is the instruction's `new_num`; in
   `server.jsonl` it is the state number k. It is not part of the state.
3. Every other key except `rows` is present if and only if its value differs from
   the current state. Its value is the complete new value: `pen`, `saved` and the
   arrays are replaced whole, never merged. A key that is absent keeps its value.
4. `rows` is an object whose keys are row indices in decimal, as strings (`"0"` is
   the top row). It is absent when no row changed.
   - If the line has `width` or `height` (the size changed), `rows` is present and
     lists **every** row `0 .. height-1`, each as an array of runs (5.4). Rows of
     the earlier state are discarded.
   - Otherwise it lists only the rows that differ from the row with the same index
     in the current state. A value is either an array of runs, or an **integer j**:
     this row is identical, cell for cell, to row j of the current state *as it was
     before this line* (the state of the previous line). This makes scrolling
     cheap. Resolve all integers against the old rows before replacing anything.
5. After the line, the current state is the state the line describes.

"Previous line" always means the line above in the file. It has nothing to do with
`old_num`: the delta is between consecutive lines even when the instruction's base is
an older state.

`server.jsonl` lines may have one more key, `reply_b64`: the bytes the terminal
answered to the host while it processed this session line (the return value of
`Complete::act`: replies to DA, secondary DA and DSR). It belongs to that line only,
is absent when the reply is empty, and is not part of the state.

The oracle prints keys in the order of the table, then `rows`, then `reply_b64`.
Loaders must not depend on the order.

To look at one whole state without replaying the deltas, `mosh-oracle apply DIR
--full` and `mosh-oracle server DIR --full` print every key on every line and `rows`
as an array of all rows; `mosh-oracle screen DIR N` prints it for people.

### 5.2 Keys

`W` and `H` are the width and height of the state. Positions are zero-based, row
first. "mosh field" names the member read by the oracle (`fb` is
`Complete::terminal.fb`, `ds` is `fb.ds`, `dp` is `Complete::terminal.dispatch`).

| Key | JSON type | Initial value | mosh field |
|---|---|---|---|
| `width` | integer ≥ 1 | from `meta.json` | `ds.width` |
| `height` | integer ≥ 1 | from `meta.json` | `ds.height` |
| `cursor` | `[row, col]` | `[0,0]` | `ds.cursor_row`, `ds.cursor_col` |
| `combining` | `[row, col]` | `[0,0]` | `ds.combining_char_row`, `ds.combining_char_col`: the cell a combining character is added to. `[-1,-1]` after a resize cut it off |
| `default_tabs` | boolean | `true` | `ds.default_tabs` |
| `tabs` | array of integers, ascending | every multiple of 8 below `W` (`[0,8,16,...]`) | the columns c with `ds.tabs[c]` true. The vector itself has `W` elements |
| `scroll_region` | `[top, bottom]` | `[0, H-1]` | `ds.scrolling_region_top_row`, `ds.scrolling_region_bottom_row` |
| `pen` | renditions object (5.3) | `{}` | `ds.renditions`, the current rendition |
| `saved` | object | `{"cursor":[0,0],"pen":{},"auto_wrap_mode":true,"origin_mode":false}` | `ds.save` (DECSC): `cursor` is `[cursor_row, cursor_col]`, `pen` is a renditions object. All four members are always present |
| `next_print_will_wrap` | boolean | `false` | `ds.next_print_will_wrap` |
| `origin_mode` | boolean | `false` | `ds.origin_mode` |
| `auto_wrap_mode` | boolean | `true` | `ds.auto_wrap_mode` |
| `insert_mode` | boolean | `false` | `ds.insert_mode` |
| `cursor_visible` | boolean | `true` | `ds.cursor_visible` |
| `reverse_video` | boolean | `false` | `ds.reverse_video` |
| `bracketed_paste` | boolean | `false` | `ds.bracketed_paste` |
| `mouse_reporting_mode` | integer | `0` | `ds.mouse_reporting_mode`: 0 none, 9, 1000, 1001, 1002, 1003 |
| `mouse_focus_event` | boolean | `false` | `ds.mouse_focus_event` (mode 1004) |
| `mouse_alternate_scroll` | boolean | `false` | `ds.mouse_alternate_scroll` (mode 1007) |
| `mouse_encoding_mode` | integer | `0` | `ds.mouse_encoding_mode`: 0 default, 1005, 1006, 1015 |
| `application_mode_cursor_keys` | boolean | `false` | `ds.application_mode_cursor_keys` (mode 1) |
| `icon_name` | string (5.5) | `""` | `fb.icon_name` |
| `window_title` | string | `""` | `fb.window_title` |
| `title_initialized` | boolean | `false` | `fb.title_initialized` |
| `clipboard` | string | `""` | `fb.clipboard`: the text after `52;c;`, not decoded |
| `bell_count` | integer ≥ 0 | `0` | `fb.bell_count` |
| `echo_ack` | integer ≥ 0 (64-bit unsigned) | `0` | `Complete::echo_ack` |
| `parser_state` | string | `"Ground"` | the class of `Complete::parser.parser.state`, one of `Ground`, `Escape`, `Escape_Intermediate`, `CSI_Entry`, `CSI_Param`, `CSI_Intermediate`, `CSI_Ignore`, `DCS_Entry`, `DCS_Param`, `DCS_Intermediate`, `DCS_Passthrough`, `DCS_Ignore`, `OSC_String`, `SOS_PM_APC_String` |
| `utf8_buf` | array of integers 0..255 | `[]` | the first `buf_len` bytes of `Complete::parser.buf`: an unfinished UTF-8 character |
| `params` | string of `0`-`9` and `;` | `""` | `dp.params`, at most 100 characters |
| `dispatch_chars` | array of integers 0..255 | `[]` | the bytes of `dp.dispatch_chars`: private marker, intermediates and, after a dispatch, the final byte; at most 8 |
| `parsed` | boolean | `false` | `dp.parsed` |
| `parsed_params` | array of integers | `[]` | `dp.parsed_params`; each element is -1 (absent or over 65535) or 0..65535 |
| `osc_string` | string | `""` | `dp.OSC_string`, at most 16384 characters |

The self-test (`mosh-oracle selftest`) checks this table of initial values against
a fresh `Terminal::Complete`.

### 5.3 Renditions

A renditions object has up to three integer members. A member that is absent is 0.
`{}` is the default rendition.

| Member | Value, exactly as mosh stores it |
|---|---|
| `fg` | `Renditions::foreground_color` (25 bits). 0: default. 30..37: colours 0..7 (SGR 30-37, and `38;5;0..7`). 38..285: palette index + 30, for indices 8..255 (SGR 90-97 store 38..45). 16777216 and above: true colour, `0x1000000 \| r<<16 \| g<<8 \| b`, kept to 25 bits (so at most 33554431) |
| `bg` | `Renditions::background_color` (25 bits). 0: default. 40..47: colours 0..7. 48..295: palette index + 40, for indices 8..255. True colour as for `fg` |
| `at` | `Renditions::attributes` (8 bits): 1 bold, 2 faint, 4 italic, 8 underlined, 16 blink, 32 inverse, 64 invisible, added together. mosh 1.4.0 never sets faint (2) |

In a run (5.4) the same three members sit directly in the run object.

### 5.4 Rows, runs, cells

A row is a JSON array of runs. The runs, left to right, describe all `W` cells of the
row: the cell counts of the runs add up to `W` exactly.

A run is an object: the cells of a run are adjacent and share everything except
their contents. A run has **exactly one** of the three content keys:

| Content key | Value | Cells |
|---|---|---|
| `t` | non-empty string of printable ASCII (bytes 0x20..0x7E) | one cell per character; the cell's contents are that one byte |
| `c` | non-empty array of strings | one cell per string; the cell's contents are the UTF-8 bytes of the string. Used for every cell whose contents are not a single printable ASCII byte: other characters, characters with combining marks, cells that hold only combining marks |
| `e` | integer ≥ 1 | that many empty cells (contents are zero bytes long) |

and any of these attribute keys, which apply to every cell of the run:

| Attribute key | Type | When absent | mosh field |
|---|---|---|---|
| `fg`, `bg`, `at` | integers | 0 | `Cell::renditions` (5.3) |
| `wide` | `true` | false | `Cell::wide`: a double-width character. The next cell is a separate, normally empty cell and is listed like any other |
| `fallback` | `true` | false | `Cell::fallback`: the contents start with a combining character (mosh draws a no-break space under it) |
| `wrap` | `true` | false | `Cell::wrap` |

`wide`, `fallback` and `wrap` are only ever written as `true`.

**The wrap flag.** mosh keeps a wrap bit in every cell. The wrap flag of a *row*
(`Row::get_wrap()`) is the bit of its **last** cell, so a wrapped row ends in a run
with `"wrap":true`. On the server a bit can sit in another cell (DCH moves it left,
ICH moves it back, a narrower window can make it the last cell again), which is why
the dump has it per cell. On a client it only appears in the last cell.

**Cell contents are bytes.** A cell's contents are a `std::string` of at most 35
bytes (mosh adds combining characters only while it holds fewer than 32): empty, or
one character of width 1 or 2 followed by zero or more combining characters, or
(with `fallback`) combining characters only. It is always valid
UTF-8 and never holds a control character. Compare contents as UTF-8 bytes. Do not
compare them as Swift `String` (that would treat canonically equivalent sequences
as equal) and do not split a `c` string into grapheme clusters: one array element is
one cell, whatever it contains. An empty cell (`e`) and a cell holding a space
(`{"t":" "}`) are different cells.

The oracle writes the unique shortest form (runs are as long as possible, `t` is
used whenever the contents are one printable ASCII byte), so two rows are equal
exactly when their JSON text is equal. Loaders should accept any valid form.

### 5.5 Strings and bytes

- `icon_name`, `window_title`, `clipboard`, `osc_string` are mosh
  `std::vector<wchar_t>`. The JSON string has the same characters: its Unicode
  scalar values, in order, are the elements of the vector. Each is U+0020..U+007F or
  U+00A0..U+10FFFF (no surrogates). In the file `"` and `\` are written `\"` and
  `\\`, U+007F is written `\u007f`, everything else is literal UTF-8. Compare scalar
  by scalar (or as UTF-8 bytes).
- `params` is ASCII.
- `utf8_buf` and `dispatch_chars` are raw bytes, written as arrays of integers
  because they need not be valid UTF-8 (`dispatch_chars` can hold a byte 0xA0..0xFF).
- Strings in `c` arrays: see 5.4.

JSON `\uXXXX` escapes other than `\u007f` do not occur in files written by the
oracle, but a loader should handle them as JSON says.

## 6. Worked example

A 10x3 terminal. `session.jsonl` (the `note` shows the bytes):

```
{"width":10,"height":3}
{"bytes_b64":"aGk=","note":"hi"}
{"bytes_b64":"G1sxOzMxbVIbWzBtDQo=","note":"\\x1b[1;31mR\\x1b[0m\\r\\n"}
{"bytes_b64":"5ryiZcyBG1s0NG0bW0s=","note":"\\xe6\\xbc\\xa2e\\xcc\\x81\\x1b[44m\\x1b[K"}
{"bytes_b64":"G1swbQ0KbGFzdA0K","note":"\\x1b[0m\\r\\nlast\\r\\n"}
{"bytes_b64":"G10yO3QHG1s/MjVs","note":"\\x1b]2;t\\x07\\x1b[?25l"}
{"resize":[12,3]}
{"echo_ack":4}
{"bytes_b64":"G1sz","note":"\\x1b[3"}
```

The instructions, with `ops` decoded for reading (`ESC` is byte 0x1B):

| new | old | ops |
|---|---|---|
| 1 | 0 | hostbytes `hi` |
| 2 | 1 | hostbytes `ESC[0;1;31mR\r\nESC[0m` |
| 3 | 1 | hostbytes `ESC[0;1;31mRESC[?25l\r\nESC[0m漢éESC[0;44mESC[KESC[?25h` (base two states back, so `R` is sent again) |
| 4 | 3 | hostbytes `ESC[0mESC[1;2rESC[?25lESC[2;1H\nESC[rESC[2;1Hlast\r\nESC[?25h` (a scroll) |
| 5 | 4 | hostbytes `ESC]1;BELESC]2;tBELESC[?25l` |
| 6 | 5 | resize `[12,3]`, then hostbytes: a full repaint |
| 7 | 2 | echo_ack 4, resize `[12,3]`, hostbytes: titles and a full repaint |
| 8 | 2 | the same three ops as 7: the server's state changed only inside its parser |

`expected.jsonl`, and how to read each line:

```
{"num":1,"cursor":[0,2],"combining":[0,1],"rows":{"0":[{"t":"hi"},{"e":8}]}}
```
State 1. Row 0 is `h`, `i` and 8 empty cells, all with default renditions. Rows 1 and
2 are not listed: they are still the blank rows of the initial state. Every key that
is absent has its initial value (`width` 10, `pen` `{}`, `parser_state` `"Ground"`, ...).

```
{"num":2,"cursor":[1,0],"combining":[1,0],"params":"0","dispatch_chars":[109],"parsed":true,"parsed_params":[0],"rows":{"0":[{"t":"hi"},{"t":"R","fg":31,"at":1},{"e":7}]}}
```
Row 0 again, complete: the third cell is `R` with foreground 31 (red) and attribute
1 (bold). The dispatcher keeps what the last sequence left behind: `ESC[0m` left
parameters `"0"`, the final byte `m` (109) and the parsed list `[0]`.

```
{"num":3,"cursor":[1,3],"combining":[1,2],"pen":{"bg":44},"params":"25","dispatch_chars":[63,104],"parsed_params":[25],"rows":{"1":[{"c":["漢"],"wide":true},{"e":1},{"c":["é"]},{"e":7,"bg":44}]}}
```
Row 1: a wide cell holding `漢` (bytes E6 BC A2), its empty right half, a cell
holding `e` plus U+0301 (bytes 65 CC 81, one cell), and 7 empty cells erased with a
blue background. Row 0 is not listed because it equals row 0 of the line above, even
though this instruction was applied to state 1, not to state 2. `parsed` is not
listed: it was `true` already.

```
{"num":4,"cursor":[2,0],"combining":[2,0],"pen":{},"rows":{"0":1,"1":[{"t":"last"},{"e":6}]}}
```
The screen scrolled. Row 0 is now what row 1 was on the line above (`"0":1`), row 1
is new, row 2 is unchanged (blank). `pen` is back to the default.

```
{"num":5,"cursor_visible":false,"window_title":"t","title_initialized":true,"dispatch_chars":[63,108],"osc_string":"2;t"}
```
No row changed, so there is no `rows`. `osc_string` keeps the last OSC.

```
{"num":6,"width":12,"params":"1005","parsed_params":[1005],"rows":{"0":[{"c":["漢"],"wide":true},{"e":1},{"c":["é"]},{"e":7,"bg":44},{"e":2}],"1":[{"t":"last"},{"e":8}],"2":[{"e":12}]}}
```
The size changed (`width`; `height` is still 3 and is not listed), so all three rows
are listed in full, 12 cells each. `tabs` (`[0,8]`) and `scroll_region` (`[0,2]`)
are not listed because their values did not change.

```
{"num":7,"echo_ack":4}
{"num":8}
```
State 7 differs from state 6 only in the echo ack, although it was built from state
2 by a different diff. State 8 is equal to state 7 in every key and row.

`server.jsonl` of the same case ends with

```
{"num":8,"parser_state":"CSI_Param","params":"3","dispatch_chars":[],"parsed":false}
```
because the server has read `ESC[3` and waits for the rest. The client never sees
that.

## 7. Computing the states

**Client (expected.jsonl).** What `mosh-oracle apply` does, and what the Swift test
must do:

```
states = { 0: Complete(meta.width, meta.height) }
for each line of instructions.jsonl, in order:
    s = copy of states[old_num]
    if diff is not empty:
        for op in ops:                      # or decode diff_b64
            hostbytes: s.act(bytes)         # must produce no reply to the host
            resize:    s.resize(w, h)
            echo_ack:  s.echo_ack = n
    states[new_num] = s
    compare s with the state described by the same line of expected.jsonl
```

Keep every state: a later instruction may use any earlier one as its base.

**Server (server.jsonl).** What `mosh-oracle server` does:

```
s = Complete(width, height of session line 1)
for k = 1, 2, ...: apply session line k+1 to s (section 3)
    compare s with line k of server.jsonl
    compare the reply returned by act() with reply_b64 (absent means empty)
```

The diff of instruction k was computed as `diff_from(server state old_num)` on
server state `new_num`. README.md lists what a port needs in order to reproduce
`diff_b64` byte for byte.

## 8. Why two state files

A mosh client never sees the program's output. It sees frames drawn by mosh's
`Display::new_frame`, which uses a small set of sequences (CUP, EL, ECH, SGR, a few
modes, titles, OSC 52) and always ends a frame with complete sequences. So in
`expected.jsonl`:

- `parser_state` is always `"Ground"` and `utf8_buf` is always `[]`;
- `saved`, `default_tabs`, `origin_mode`, `auto_wrap_mode`, `insert_mode`,
  `application_mode_cursor_keys` and `mouse_alternate_scroll` never leave their
  initial values, and `tabs` changes only with the width;
- client and server states with the same number can differ in visible ways too (a
  cell hidden under the right half of a wide character is never sent; the client's
  `bell_count` counts frames with a bell, not bells; the client's cursor can be one
  column left of the server's, see README.md).

They are dumped all the same: a faulty applier could change them. `server.jsonl`
is where those fields move: there the terminal reads the program's own bytes, one
`read()` at a time, with state boundaries in the middle of escape sequences and of
UTF-8 characters. The `syn-*` cases exercise every function of
`terminalfunctions.cc` this way. A port of `Terminal::Complete` should pass both.

## 9. Fields of mosh's state that are not dumped

| Field | Why it is left out |
|---|---|
| `Row::gen` | A number from a process-wide counter, taken when a row object is created or reset and copied with the row. Its value means nothing outside one process. It does not influence how bytes are applied. It does influence `Display::new_frame` (`Row::operator==` needs equal `gen`); README.md describes that for whoever ports the display |
| `Dispatcher::terminal_to_host` | Emptied by `Emulator::read_octets_to_host()` at the end of every `Complete::act`, so it is empty in every state at rest (the oracle aborts otherwise). What it held is `reply_b64` |
| `Emulator::user` (`UserInput::state`) | Changes only in `UserByte` actions (user keystrokes). `apply_string` and the session steps never create one; it stays `Ground` |
| `Complete::input_history` | Server-side list behind the echo ack; private, used only by `register_input_frame`, `set_echo_ack` and `wait_time`. Its effect is `echo_ack` |
| `Complete::actions` | Scratch vector, empty outside `act()` (the oracle aborts otherwise) |
| `Complete::display` | Constant: `Display(false)`, i.e. ECH, BCE and titles on, no terminfo |
| `UTF8Parser::buf` beyond `buf_len` | Never read |
| attribute bit 2, faint | Dumped (it is part of `at`), but `Renditions::set_rendition` has no case for SGR 2, so it is never set |

## 10. Dispatcher leftovers

`params`, `dispatch_chars`, `parsed`, `parsed_params` and `osc_string` are real
members and are dumped as they are, including what the last finished sequence left
in them. From the source (`parserstate.cc`, `terminaldispatcher.cc`), these
leftovers cannot affect later behaviour:

- `params` and `dispatch_chars` are read only by a CSI or ESC dispatch. Every path
  to one passes the entry action of `Escape` or `CSI_Entry`, which is `Clear`. They
  are *live* (collected for the sequence in progress) while `parser_state` is
  `Escape`, `Escape_Intermediate`, `CSI_Entry`, `CSI_Param` or `CSI_Intermediate`.
  In any other state they are leftovers.
- `osc_string` is read only at the end of an OSC, and `OSC_Start` clears it on
  entry. It is live while `parser_state` is `OSC_String`.
- `parsed` and `parsed_params` are a cache of `params`; every reader parses again
  when `parsed` is false, and `Clear` and every new parameter character set it false.

A port that is faithful line by line reproduces the leftovers and can compare all
five keys always. A port that clears them at other moments may compare `params` and
`dispatch_chars` only in the five live states, `osc_string` only in `OSC_String`,
and skip `parsed` and `parsed_params`, without missing any behaviour. Every other
key must always match.

## 11. The predict mode

`mosh-oracle predict` is not a corpus format: it drives mosh's own
`Overlay::PredictionEngine` (`src/frontend/terminaloverlay.o` of the built tree, the
object `mosh-client` links) for the differential test of the Swift port
(`docs/notes/m10/DESIGN.md` 7.1). The engine's only clock, `Network::timestamp()`, is
defined in `predict.cc` and returns the last `time` value; nothing else in it reads a
clock.

Input on stdin: one command per line, tokens separated by one space, numbers in
decimal, `HEX` lowercase hex of bytes (may be empty or left out). Each command prints
exactly one line on stdout, so a reply belongs to its command by position. Every
command except `dump` replies `{"ok":"<command>"}`. A bad command prints
`{"error":"..."}` and the tool exits 65. The first command must be `new`.

| Command | Does (mosh source it mirrors) |
|---|---|
| `new W H` | `server = Complete(W, H)`; `shown = Framebuffer(W, H)` (stc:245); `engine = PredictionEngine()` (toh:294) |
| `display NAME` | `set_display_preference`: `always`, `never`, `adaptive`, `experimental` (sth:109-120) |
| `overwrite 0\|1` | `set_predict_overwrite` |
| `time MS` | the value `Network::timestamp()` returns from now on; absolute |
| `host HEX` | `server.act(bytes)`: the server's terminal |
| `hostresize W H` | `server.act(Parser::Resize(W, H))` |
| `echoack N` | the server state's `echo_ack = N` (completeterminal.h:58) |
| `recv ACKED SI` | `set_local_frame_acked(ACKED)`, `set_send_interval(SI)`, `set_local_frame_late_acked(server.get_echo_ack())` (stc:298-300) |
| `read SENT HEX` | `set_local_frame_sent(SENT)`; more than 100 bytes: `reset()`, else `new_user_byte(b, shown)` for each byte (stc:322-334) |
| `frame` | a copy `f` of the server's framebuffer, `cull(f)`, `apply(f)`, `shown = f` (stc:274-287 and toc:335-336, without notifications, title and display) |
| `reset` | `reset()` (stc:418) |
| `dump` | one line `{"dump":K,"engine":E,"shown":S}` |

In a `dump` line, `K` counts dumps from 1. `S` is `null` unless a `new` or `frame`
came since the previous dump (only they change `shown`); otherwise it is a state
line of section 5 with every key and all rows (as `apply --full`), numbered `K`, of
a fresh `Complete` of `shown`'s own size whose framebuffer is `shown` (so its
`echo_ack`, parser and dispatcher keys are those of a fresh terminal). `E` is:

```
{"prediction_epoch":"U","confirmed_epoch":"U","flagging":B,"srtt_trigger":B,
 "glitch_trigger":N,"last_quick_confirmation":"U","send_interval":N,
 "last_height":N,"last_width":N,"local_frame_sent":"U","local_frame_acked":"U",
 "local_frame_late_acked":"U","last_byte":N,"parser_state":"NAME","parser_buf":"HEX",
 "display":"NAME","overwrite":B,"active":B,"wait_time":N,
 "cursors":[["U exp",row,col,B active,"U tentative","U prediction_time"],...],
 "overlays":[{"row":R,"cells":[[col,B active,"U exp","U tentative","U prediction_time",
              B unknown,CELL,[CELL,...]],...]},...]}
CELL = {"c":"base64 contents","r":RENDITIONS,"w":B wide,"f":B fallback,"x":B wrap}
```

- `"U"` is a `uint64_t` as a decimal string (`UINT64_MAX` does not fit a double).
- `last_byte` is mosh's `char last_byte` (toh:215) printed as `unsigned char`: it is
  signed on x86-64, and the engine only compares it for equality.
- `parser_state` is the engine's own `UTF8Parser` state, named as in section 5;
  `parser_buf` its pending UTF-8 bytes.
- `active` is `active()` (toc:913-932), `wait_time` is `wait_time()` (toh:287-292),
  `INT_MAX` being 2147483647.
- Lists are in mosh's list order. Every cell of every overlay row is dumped, active
  or not: an inactive cell's stale `replacement` still matters (`reset` leaves it,
  toh:77, 115). `RENDITIONS` is the pen object of section 5.3.

