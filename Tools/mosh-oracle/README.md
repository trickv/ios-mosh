# mosh-oracle

mosh 1.4.0's own terminal emulator, wrapped as a test oracle for the Swift terminal
model (`Sources/MoshTerminal`). It links the static libraries of the built mosh tree
in the dev container (`/opt/mosh-src`) and prints mosh's complete terminal state as
JSON. The golden corpus in `Tests/MoshTerminalTests/Corpus` is its output.

Linux only, a test tool, not part of the app. `main.cc` links GPLv3 mosh code and is
under the same licence.

| File | What |
|---|---|
| `main.cc`, `build.sh` | the tool |
| `FORMAT.md` | exact format of every corpus file. Read this to write a loader |
| `check_format.py` | reference loader for the state files, and a check that the delta format is lossless |
| `synthetic.py` | the hand-written sessions of the `syn-*` cases |
| `recordings/*.rec`, `recordings/fixtures/` | scripts and files for the recorded `rec-*` cases |
| `../../scripts/record-golden.sh`, `../../scripts/pty-record.py` | the recorder |
| `../../scripts/corpus-check.sh` | check, regenerate, sizes |

## Build and use

```
scripts/dev.sh Tools/mosh-oracle/build.sh       # -> /work/.build/mosh-oracle/mosh-oracle (in the build volume)
scripts/corpus-check.sh                         # apply and server reproduce the committed files
scripts/corpus-check.sh --gen                   # also: gen is deterministic; the format is lossless
scripts/corpus-check.sh --regen                 # write the corpus again from the session files
scripts/corpus-check.sh --sizes                 # size of each case, total against the 10 MB budget
scripts/record-golden.sh [name ...]             # record rec-* cases again (new recordings!)
scripts/dev.sh .build/mosh-oracle/mosh-oracle selftest
scripts/dev.sh .build/mosh-oracle/mosh-oracle screen Tests/MoshTerminalTests/Corpus/rec-vim 100
```

The scripts start the dev container themselves when run on the host.

`build.sh` compiles `main.cc` with the flags of mosh's own build (taken from
`make -n` in `/opt/mosh-src/src/terminal`) plus `-fno-access-control`. That flag lets
`main.cc` read private members and does nothing else, so every class has the layout
it has inside the libraries. (`#define private public` also works with GCC, but
the language lets a compiler order members differently when their access differs.)

Modes:

| Mode | Does |
|---|---|
| `gen --session FILE --out DIR` | Server-side simulation of the session file. Writes `meta.json`, `instructions.jsonl`, `server.jsonl`, then runs `apply` on what it wrote and stores `expected.jsonl`. Fails if fewer than 3 instructions have a base 2 to 8 states old (`--allow-few-old-bases` turns that off) |
| `apply DIR [--no-verify-ops] [--full]` | Client-side simulation of `instructions.jsonl`. Prints `expected.jsonl`. Works on directories written by `gen` and by `moshcli --record`. Checks that `ops` equals the decoded `diff_b64`. `--full` prints every key and every row on every line (for checking loaders; not a corpus format) |
| `server DIR [--full]` | Server-side simulation only. Prints `server.jsonl` |
| `screen DIR N\|last [--plain] [--server]` | For people: the text grid and every dumped field after instruction N (client), or with `--server` after N session lines (server). `--plain` prints only the grid |
| `selftest` | Dump completeness: for each dumped key, a small input that must change it; and the initial values of FORMAT.md |
| `respond W H` | Co-process of the recorder: answers terminal queries as mosh-server would |
| `predict` | mosh's prediction engine (`frontend/terminaloverlay.o`, as linked into `mosh-client`) driven by a command stream on stdin, one JSON reply per command; the oracle of the M10 differential test (FORMAT.md section 11, `docs/notes/m10/DESIGN.md` 7.1) |

The tool needs the `en_US.UTF-8` locale (mosh's parser uses `mbrtowc` and `wcwidth`).

## What gen simulates

After each session line the server-side `Terminal::Complete` is copied as a new
state, numbered 1, 2, 3, ..., and one instruction is written for it: the string
`Complete::diff_from(base)` returns, where `base` is one of the server's earlier
states. The client simulation then does what `Network::Transport::recv` does: copy
its own state `old_num`, `apply_string(diff)` unless the diff is empty, store as
`new_num`.

**Base pattern.** For instruction k, `old_num = k - age(k)`:

```
c = k / 10 (integer division), p = k % 10
p == 3:  age = 2 + c % 7            2..8, one old base
p == 7:  age = 2 + (c + 3) % 6      2..7
p == 8:  age = 3 + (c + 3) % 6      3..8: the same base as instruction k-1
else:    age = 1
age = min(age, k)                   state 0 is the oldest
```

So 3 of every 10 instructions have an old base, the ages run through 2 to 8, and
each decade has one pair of consecutive instructions that share a base. This is
what a server does when acks are late: `update_assumed_receiver_state` falls back
to the last acknowledged state once newer ones time out, and
`attempt_prospective_resend_optimization` keeps diffing from it.

**Empty diffs.** When nothing the display protocol carries has changed,
`diff_from` returns an empty string. `gen` still gives the state a number and writes
an instruction with `"diff_b64":""` and no ops, as the server's `send_empty_ack`
does: the server keeps its *current* state under the new number, the client stores
a copy of its base state. From then on server state n and client state n differ in
what was not sent. About a quarter of the instructions in the `syn-*` cases are of
this kind (the numbers are further down).

**Where gen is simpler than a real server** (`src/network/transportsender-impl.h`):

1. One state per session line. A real server cuts states by timers, so several
   reads can fall into one state.
2. Every state gets a new number. A real server sends nothing while the diff is
   empty and no ack is due, and when its state equals the last one sent it sends
   that number again instead of a new one. The corpus has each `new_num` once.
3. The base follows the fixed pattern, not acks and timeouts.
4. The client receives every instruction, once, in order, and keeps every state.
   No loss, no reordering, no `throwaway_num`.
5. Server state 0 has the client's first size. A real server starts at the size of
   its own pty; the first instruction then carries a resize.

None of this changes what a client must do with an instruction.

## The corpus

`rec-*`: recorded from real programs. `syn-*`: hand-written. At most 150 states per
case. Sizes are in the table at the end.

Recorded cases (`recordings/NAME.rec` is the script that was played):

| Case | Content |
|---|---|
| `rec-bash` | prompt, `ls --color /etc`, `seq 1 120` scrolling, line editing with cursor keys, home, end, backspace, history up and down, kill line, `clear` |
| `rec-wrap` | 60 columns: a 300-digit line, a file with lines of 59, 60, 61, 120 and 121 characters, a command line longer than the window edited at its start, `seq -s ' ' 1 200` |
| `rec-vim` | `vim hello.c` with syntax colours: move, open a line and insert, page down and up, visual line mode, `:split`, window switch, `G`, a search, `:qa!` |
| `rec-tmux` | 100x30: new session, status line, split left/right and top/bottom, `seq`, copy mode with a selection (tmux sends `OSC 52;;...`, which mosh drops), `set -g mouse on` (modes 1002 and 1006), next pane, `kill-server` |
| `rec-htop` | `htop -d 5` for five seconds, then `q` |
| `rec-less` | `less long.txt`: page down twice, a search with highlighting, `G`, `g`, line moves, `q` |
| `rec-unicode` | 40 columns, from `printf`: emoji, a ZWJ family, a flag, CJK, Hangul, Thai, Devanagari, combining marks (also at column 0), variation selector and keycap, ambiguous-width characters, soft hyphen, no-break space, box drawing, wide characters and an emoji at the right margin, a row of wide characters over the margin, a combining mark after the last column, wide characters overwritten on either half |
| `rec-colors` | 16 colours fg and bg, bright colours, every attribute including the ones mosh ignores, the 256-colour cube and grey ramp, true-colour gradients, erase with a background colour (EL 0/1/2, ECH, ED), scrolling with a background colour, clear with a true-colour background |
| `rec-modes` | bracketed paste, mouse modes 9, 1000, 1001, 1002, 1003, encodings 1005, 1006, 1015, focus events, alternate scroll, application cursor keys, cursor visibility, reverse video, alternate screen (which mosh does not have) |
| `rec-titles` | OSC 0, 1, 2, ST and BEL terminators, UTF-8 title, OSC without a number, empty title, OSC 7, a 300-character title, bells |
| `rec-osc52` | valid, repeated, ST-terminated, empty selection (tmux form), primary selection, not base64, query, empty payload, UTF-8 payload, oversize (20000 characters, cut by mosh), small again |
| `rec-resize-bash` | 80x24 → 100x30 → 60x10 → 80x1 → 2x24 → 1x1 → 80x24 with commands in between |
| `rec-resize-vim` | vim open: 80x24 → 100x30 → 40x10 → 80x1 → 2x24 → 80x24, edits in between |
| `rec-resize-tmux` | tmux with two panes: 80x24 → 120x40 → 50x12 → 80x1 → 2x24 → 80x24 |

Synthetic cases, one per family of functions in mosh's
`src/terminal/terminalfunctions.cc` (the complete list of what mosh 1.4.0
implements; the key is the one in its dispatch registry), plus parser cases:

| Case | Functions of mosh |
|---|---|
| `syn-c0` | controls BEL `07`, BS `08`, HT `09`, LF `0A`, VT `0B`, FF `0C`, CR `0D`; NUL, DEL and controls without a function; CAN, SUB |
| `syn-cursor` | CSI `A` `B` `C` `D` (CUU, CUD, CUF, CUB), `H` `f` (CUP, HVP), `d` (VPA), `G` (CHA), `` ` `` (HPA); defaults, zero, clamping, origin mode |
| `syn-erase` | CSI `K` (EL 0, 1, 2), `J` (ED 0, 1, 2), `X` (ECH); with background colours, on wide characters, on wrapped rows |
| `syn-sgr` | CSI `m` (SGR): 1, 3, 4, 5, 7, 8 and 22-28, 30-37, 39, 40-47, 49, 90-97, 100-107, `38;5;n`, `48;5;n`, `38;2;r;g;b`, `48;2;r;g;b`; malformed and overflowing forms; codes mosh ignores; colon forms |
| `syn-tabs` | HT, control `88` and ESC `H` (HTS), CSI `I` (CHT), `Z` (CBT), `g` (TBC 0 and 3); default stops across resizes and RIS |
| `syn-scroll` | CSI `r` (DECSTBM), `S` (SU), `T` (SD), `L` (IL), `M` (DL); controls `84` / ESC `D` (IND), `85` / ESC `E` (NEL), `8D` / ESC `M` (RI); LF, VT, FF in a region; origin mode; background colour in new rows |
| `syn-insdel` | CSI `@` (ICH), `P` (DCH), insert mode (SM/RM 4); wide characters; the wrap bit moved by DCH and ICH |
| `syn-modes` | CSI `?h` `?l` (DECSET, DECRST) 1, 3, 5, 6, 7, 25, 1004, 1007, 2004, mouse 9, 1000, 1001, 1002, 1003, encodings 1005, 1006, 1015, several in one sequence, modes mosh does not have; CSI `h` `l` (SM, RM) 4 and others |
| `syn-savecursor` | ESC `7` (DECSC), ESC `8` (DECRC): position, pen, auto wrap, origin mode; across resizes; after DECSTR and RIS |
| `syn-reset` | ESC `c` (RIS), CSI `!p` (DECSTR), ESC `#8` (DECALN) |
| `syn-osc` | OSC 0, 1, 2 (also without a number), ST, BEL and C1 terminators, controls inside, titles over 256 characters; OSC `52;c;`: valid, repeated, other selections, query, not base64, empty, 20000 characters (cut at 16384 with the prefix) |
| `syn-utf8` | 2, 3 and 4 byte characters fed whole and byte by byte; lone continuation bytes, overlong forms, truncated characters, surrogates, values above U+10FFFF, 5 and 6 byte forms, FE and FF; non-characters, zero-width characters; a resize inside a character |
| `syn-c1` | C1 controls as UTF-8 (IND, NEL, HTS, RI, CSI, OSC, DCS, SOS, PM, APC, ST, and the ones without a function) and their ESC forms; DCS, SOS, PM, APC strings; CAN, SUB, ESC and C0 controls inside sequences; ESC sequences without a function |
| `syn-wide` | printing: wide characters at and over the right margin, with auto wrap off, overwritten on either half, in insert mode; combining marks on normal, wide, empty and erased cells, in the last column, more than a cell holds, after a resize; zero-width characters, emoji sequences, Hangul jamo |
| `syn-wrap` | auto wrap: the pending wrap and what clears or keeps it, wrap flags, wrap at the bottom, DECAWM off, resizes of wrapped rows |
| `syn-params` | parameter strings over 100 characters, values over 65535, empty and leading-zero parameters, intermediates, private markers, CSI that mosh ignores, odd final bytes including non-ASCII, DEL and NUL inside; CSI `c` (DA), `>c` (secondary DA), `n` (DSR 5 and 6) with their replies in `server.jsonl` |
| `syn-split` | sequences of every kind fed one, two, three and five bytes per state |
| `syn-resize` | resizes without a program: larger, smaller, 1x1, 2x2, 80x24, one row, one column, the same size; with wrapped rows, a scrolling region, a pending wrap, a combining cell, tab stops, a saved cursor, and in the middle of an escape sequence |
| `syn-echoack` | echo acks alone, with output, with a resize, repeated, and above 2^40 |
| `syn-invisible` | changes the client is never told about (DECCKM, insert mode, auto wrap, tabs, saved cursor, alternate scroll, a pen change, queries, redrawing the same thing, an icon-name-only change) |
| `syn-del` | DEL, NUL and C0 controls inside escape sequences (Escape, Escape_Intermediate, CSI_Intermediate, CSI_Ignore, parameters, OSC and SOS strings); `CSI :`; a NUL that cuts a UTF-8 sequence short |
| `syn-dcs` | every way through the DCS states: private marker, parameters, `:`, one and two intermediates, a parameter after an intermediate, DEL and C0 in each state, the passthrough, ended by ST, C1 ST, CAN and ESC; C1 DCS |
| `syn-margins` | DECSTBM with a bottom margin past the screen, set while in origin mode, refused forms; TBC with parameters other than 0 and 3 |
| `syn-blanks` | what `Display::new_frame` does with runs of erased cells: adjacent runs in different colours and attributes, short and long, to the end of the line, between text; a wrapped line that continues with an erased cell |

`mosh-oracle selftest` covers every dumped key; FORMAT.md section 9 lists the
members of mosh's state that are not dumped and why.

## Recording

`scripts/record-golden.sh NAME` runs `bash --norc --noprofile -i` in a pty through
`scripts/pty-record.py`, plays `recordings/NAME.rec` (keys with delays, waits for
text, `TIOCSWINSZ` resizes; the command list is in the docstring of
`pty-record.py`), and runs `gen` on the result.

- Fixed: `TERM=xterm-256color`, `LANG` and `LC_ALL` `en_US.UTF-8`, `PS1='golden$ '`,
  `TZ=UTC`, host name `golden`, a fresh temporary `HOME` that holds only the fixture
  files (no vimrc, tmux.conf or htoprc; tmux runs with `-f /dev/null` and gets the
  same plain bash for its panes).
- One `read()` from the pty is one session line. The read sizes come from a fixed
  pseudo-random sequence (1 to 16 bytes, 17 to 256 bytes, or a whole buffer), so
  state boundaries fall inside escape sequences and inside UTF-8 characters. If a
  recording has more reads than `max_states` (150), neighbouring reads are merged,
  smallest pair first.
- `mosh-oracle respond` runs beside the program and answers DA, secondary DA and DSR
  the way mosh-server's terminal does; the answers are written to the pty.
- Not fixed: timing, clocks, process lists, pids. Recording again gives a different
  session, so the committed files change. The oracle files are a function of
  `session.jsonl` alone; `corpus-check.sh --gen` verifies that.

## Things about mosh 1.4.0 that the corpus shows

These are mosh's behaviour, found or confirmed with the oracle. A port must
reproduce them to match `expected.jsonl`; they are not bugs of the oracle.

1. **Cursor one column left after the bottom-right cell is written.** When a frame
   writes the last cell of the bottom row, `Display` believes its cursor is at
   column `width`, while the client's emulator holds it at `width-1` with a wrap
   pending. A following short move left is sent as backspaces counted from `width`,
   so the client ends one column left of the server, and stays there until the next
   absolute move. In the corpus 73 of 2916 client states have the cursor one column
   left of the server's (for example `syn-c0` state 16: server `[5,19]`, client
   `[5,18]`). Text can then land in the wrong cell: in `rec-unicode` state 52 the
   server's bottom row ends in `0`, `é` and the client's in `é`, `e`.
2. `next_print_will_wrap` is never true in a client state: every frame ends with a
   cursor move or leaves the cursor inside the row.
3. A cell under the right half of a wide character is never sent (`put_row` steps
   over it), so the server can hold text the client does not (`syn-wide`).
4. A change of the icon name alone is not sent: `Framebuffer::operator==` does not
   look at it, so the diff is empty. If that state becomes the base of the next
   diff (after a server's empty ack; in `gen`, always) the client never gets the new
   icon name, unless a later diff starts from an older base (`syn-invisible`
   instructions 29 to 33).
5. One BEL per frame however often the bell rang, so the client's `bell_count`
   counts frames.
6. Mode 1007 (alternate scroll) makes the states unequal but produces no bytes; the
   client never learns it. DECCKM, insert mode, origin mode, auto wrap, tab stops,
   the saved cursor and the scrolling region are not sent either.
7. OSC 52 is stored only for the literal prefix `52;c;`, as received (not decoded),
   and sent again only when the stored text differs from the base state's. tmux's
   `52;;` is dropped (`rec-tmux`). The OSC string is cut at 16384 characters
   including the prefix; titles at 256 including the prefix.
8. Row wrap flags are the wrap bit of the last cell; on the server DCH, ICH and a
   narrower window can move a bit into or out of that cell (`syn-insdel`).
9. A frame whose base state has another size is a full repaint (`ESC[r`, `ESC[0m`,
   `ESC[H`, `ESC[2J`, every row) and writes every mode again whether it changed or
   not: cursor visibility, the pen, bracketed paste, mouse mode, focus, encoding.
10. Up to four empty cells in the middle of a row, and the blank end of a wrapped
    row, are sent as spaces. The client then has cells that hold a space where the
    server's are empty (356 states of the corpus).
11. A cell that starts with a combining character (`fallback`) is sent as U+00A0
    followed by the combining characters. On the client the cell holds the no-break
    space too and `fallback` is false; no client state has `fallback` true.

The corpus has 2916 states in 38 cases. 867 instructions have a base 2 to 8 states
old and 497 have an empty diff (450 of the 1499 `syn-*` instructions). These figures
are printed by `CorpusDisplayTests.testFiguresOfTheCorpus`.

## Reproducing the recorded diffs byte for byte

`diff_b64` of instruction k is `diff_from(server state old_num)` evaluated on server
state `new_num`, where server state n is the terminal after session line n+1. A port
of `Display::new_frame` can be tested against it only with the server's states
(built from `session.jsonl`, checked with `server.jsonl`), not with the client's.
Two things that are not in any dump decide some of the bytes:

- **Row objects.** `Framebuffer` holds `shared_ptr<Row>`. Copying a state shares the
  rows; `get_mutable_row` gives the framebuffer its own copy the first time it asks
  for write access to a shared row, even if nothing is then changed
  (`Emulator::print` asks for the cursor's row for every character, printable or
  not).
  `Framebuffer::operator==` compares the row *pointers*, together with the window
  title, clipboard, bell count and the `DrawState` fields of its `operator==`
  (width, height, cursor, cursor visibility, reverse video, pen, bracketed paste,
  mouse mode, focus, alternate scroll, encoding). `diff_from` calls `new_frame` only
  when that comparison fails. A value type can model the pointers with a per-row
  token that is renewed on every write access.
- **`Row::gen`.** `new_frame` looks for a scroll by comparing rows with
  `Row::operator==`, which needs equal `gen` as well as equal cells. `gen` comes from
  a counter: a new value for the one row object shared by all rows of a new
  framebuffer, for the one object inserted (possibly several times) by each
  `insert_line`, `delete_line` or scroll, for the one blank row object a resize adds,
  for the one object `Framebuffer::reset` fills the screen with, and for every row
  reset by `Row::reset` (EL 2, ED, DECCOLM). Copies keep it; writing cells does not
  change it. Without it, blank rows match each other and a different, equally valid
  scroll is found.

Everything else in `new_frame` is a function of the dumped fields.

## Coverage

`scripts/corpus-coverage.sh` runs the port's three plain corpus tests (client states,
server states, the server's diffs) with code coverage and lists the code regions of the
Swift emulator and display diff that were never executed. The port follows mosh's
source function by function, so the list reads as a list for mosh as well.

With the first 34 cases, reachable code that no case exercised was: DEL in the Escape,
Escape_Intermediate and CSI_Intermediate states; C0 controls in CSI_Intermediate and
CSI_Ignore; `CSI :`; most transitions of the DCS states; a NUL byte after an incomplete
UTF-8 sequence (the only way a NUL reaches `mbrtowc`: a lone NUL takes the parser's
one-byte shortcut); DECSTBM with a bottom margin past the screen and DECSTBM in origin
mode; TBC with a parameter other than 0 and 3; and in `Display::new_frame` / `put_row`
a run of erased cells followed directly by an erased cell of another rendition, and a
wrapped row followed by a row whose first cell is erased (it is sent as a space).
`syn-del`, `syn-dcs`, `syn-margins` and `syn-blanks` were added for these. The port
matched mosh on all four without a change.

What the 38 cases still do not reach, all of it for a reason:

- Code that cannot be reached in mosh either (the port keeps it to stay line by line
  with the source): the "no rule" exit of `Ground` (every character below 0xA0 has a
  rule or is taken by `anywhere_rule`, and 0xA0 and above are parsed as `A`), the GR
  half of `GLGR` for the same reason, `0x9C` in `DCS_Passthrough`, `DCS_Ignore` and
  `SOS_PM_APC_String` (`anywhere_rule` takes it first), the surrogate check after
  `mbrtowc` (glibc rejects surrogates), a NUL in `Emulator::print`, the `default` of the
  cursor-movement switch, CHT/CBT with a parameter of 0 and DECSTBM with a top of 0
  (`getparam` never returns less than 1), `set_scrolling_region` with a negative top,
  a bottom above the top or a height of 0, `insert_line` and `delete_line` with a count
  of 0, the second `parsed` check in `parse_params`, and in `new_frame` the reuse of the
  blank row made for a taller screen by the scroll shortcut (a size change turns the
  shortcut off) and a negative number in a cursor address.
- `new_frame` without BCE (`can_use_erase` when the pen is not the default): the
  server's `Display` always has BCE. The port's other capability settings are compared
  with mosh in `DisplayDiffCrossCheckTests`.
- What a byte stream from the host does not drive: user keystrokes
  (`Terminal::UserInput`, `Emulator::act( UserByte )`; the sessions hold no keystrokes,
  the port's are compared with mosh in `MoshCrossCheckTests`), `prefix_window_title`
  (mosh-client's title prefix), and the port's own constructors, equality operators and
  debugging helpers.

## Sizes

`scripts/corpus-check.sh --sizes`, all five files of each case:

```
rec-bash            133 states     77410 bytes
rec-colors           94 states    112113 bytes
rec-htop             75 states    173897 bytes
rec-less             79 states    102142 bytes
rec-modes            60 states     28901 bytes
rec-osc52            57 states    301411 bytes
rec-resize-bash     140 states     60693 bytes
rec-resize-tmux     150 states    131799 bytes
rec-resize-vim       75 states     91650 bytes
rec-titles           45 states     20450 bytes
rec-tmux            150 states    100996 bytes
rec-unicode          65 states     33517 bytes
rec-vim             144 states    141915 bytes
rec-wrap            150 states     82407 bytes
syn-blanks           12 states      8033 bytes
syn-c0               41 states     13518 bytes
syn-c1               92 states     25109 bytes
syn-cursor           58 states     25091 bytes
syn-dcs              92 states     15379 bytes
syn-del              53 states     14819 bytes
syn-echoack          17 states      5507 bytes
syn-erase            49 states     32588 bytes
syn-insdel           58 states     27836 bytes
syn-invisible        44 states      9322 bytes
syn-margins          36 states     13242 bytes
syn-modes           102 states     33635 bytes
syn-osc              76 states    271405 bytes
syn-params           94 states     24641 bytes
syn-reset            46 states     22241 bytes
syn-resize           51 states     41597 bytes
syn-savecursor       59 states     20636 bytes
syn-scroll           84 states     37542 bytes
syn-sgr              62 states     39918 bytes
syn-split           129 states     25949 bytes
syn-tabs             42 states     22415 bytes
syn-utf8             71 states     25408 bytes
syn-wide             80 states     40686 bytes
syn-wrap             51 states     24408 bytes
total                            2280226 bytes (2.17 MB of 10 MB)
```

The cap is 150 states per case; the largest files are the two cases with a 16 KiB
clipboard, where every state on the way holds the OSC string read so far.
