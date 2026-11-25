# Research: mosh_terminal

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

The newest mosh release is still mosh-1.4.0 (2022-10-27). Master is 39 commits ahead, and the only display-visible change there is OSC 8 hyperlinks (PR #1360, merged 2026-03-29, not in any release). The server runs a full emulator (UTF8Parser -> Dispatcher -> Framebuffer). Terminal::Complete::diff_from sends a HostMessage containing EchoAck(8), Resize(5,6) and HostBytes(4). HostBytes is the output of Display(false).new_frame(true, reference_fb, current_fb). The client applies each diff by running the same emulator on a COPY of the reference state it holds. That is a list of up to 1024 states, picked by old_num. So the client needs a copyable framebuffer and an emulator; streaming the bytes into a generic terminal is not enough. The display emits a small fixed dialect: C0 BEL/BS/CR/LF; CUP; DECSTBM; ECH/EL/ED2; SGR that always starts with 0 (16/256/truecolor; bold, italic, underline, blink, inverse, invisible; no faint or strike); modes ?5, ?25, ?2004, ?9/1000-1003, ?1004, ?1005/1006/1015; OSC 0/1/2; OSC 52;c; on master also OSC 8. Wrap and wide characters are conveyed only implicitly, through autowrap and the client's own wcwidth. OSC 52: the server accepts only a literal "52;c;" prefix, caps the OSC at 16 KiB, and re-emits only when the stored text changes. So copying identical text twice fails (issue #1090, open; the fix is PR #1104, unmerged). tmux's default empty selection "52;;" is dropped (PRs #1054/#1104 unmerged). No OSC 52 read support exists. A "?" is forwarded as clipboard content "?", which a client could answer through user input, but only once. DA1 replies ESC[?62c, so neovim does not auto-enable OSC 52. Not carried: scrollback, alternate screen, cursor shape, application cursor mode, ?1007, sync output, kitty keyboard/graphics, sixel, OSC 7/9/10/11.

## details

## 0. Versions
- Releases (`gh release list`): mosh-1.4.0 (Latest, 2022-10-27), 1.3.2.95rc2, rc1, 1.3.2. Nothing newer than 1.4.0.
- master HEAD decd9b705e (2026-03-22). Changes since 1.4.0: clang-format, C++17, a startup pipe, getrandom, and **OSC 8 hyperlinks (#1360, merged 2026-03-29)**. OSC 52, SGR, modes and the diff algorithm are otherwise unchanged (diff of terminaldisplay.cc is formatting plus hyperlink code only).
- Open PRs that touch this area: #1104 (OSC 52 selection param plus clipboard seqnum), #1054 (relax the 52 prefix), #1440 (close OSC 8 in Display::close, opened 2026-11-07), #1394 (OSC 10/11 colour queries), #1383 (OSC 7), #1144 (OSC 9/777/1337).

## 1. Wire model (src/statesync/completeterminal.cc, src/protobufs/hostinput.proto)
```
message HostMessage { repeated Instruction instruction = 1; }
extend Instruction { HostBytes hostbytes = 2; ResizeMessage resize = 3; EchoAck echoack = 7; }
HostBytes { optional bytes hoststring = 4; }  ResizeMessage { int32 width = 5; int32 height = 6; }  EchoAck { uint64 echo_ack_num = 8; }
```
**diff_from(existing)** emits instructions in this order:
1. echoack, if the echo_ack differs.
2. If the framebuffers differ: first resize, if the size differs, then `hostbytes = display.new_frame(true, existing.fb, current.fb)`, if non-empty.

`display` is `Display(false)` (from `Complete(...) : ... display( false )`). That constructor sets has_ech=true, has_bce=true, has_title=true, smcup=rmcup=NULL. No terminfo is consulted.

**apply_string**: for each instruction in order:
- hostbytes: feed the bytes to the emulator. The code asserts there is no terminal-to-host output ("server never interrogates client terminal").
- resize: `Emulator::resize(w,h)`.
- echoack: monotonic store.

**Transport::recv** (network/networktransport-impl.h):
- Looks up `inst.old_num()` in `received_states`. If it is missing, the packet is dropped.
- Copies that state, applies the diff to the copy, and inserts it sorted by num. The queue is capped at 1024 states.
- The client therefore needs O(1)-copy state: a Swift struct of `[Row]` with copy-on-write fits.
- The initial state 0 is a blank `Complete(w,h)`.

**Server echo ack**: `ECHO_TIMEOUT = 50` ms. echo_ack is the newest input state number received at least 50 ms ago (`set_echo_ack`).

## 2. Display::new_frame output dialect (Display(false), initialized=true)
`initialized` is passed as true, but new_frame sets it to false internally whenever the width or height changed. Every "!initialized" branch below therefore fires after a resize. Emission order:
1. **Bell**: if `bell_count` changed, emit a single `BEL` (0x07), even if the bell rang many times.
2. **Titles**: only if `title_initialized` and (icon or title changed):
   - icon == title: `ESC ] 0 ; <title UTF-8> BEL`
   - otherwise: `ESC ] 1 ; <icon> BEL ESC ] 2 ; <title> BEL`
   - The server truncates titles: `min(OSC_string.size(),256)` counts the "N;" prefix.
   - Gotcha: `Framebuffer::operator==` compares window_title but **not** icon_name. An icon-only change does not trigger a send.
3. **Clipboard**: if `clipboard` (vector<wchar_t>) != the reference state's clipboard, emit `ESC ] 52 ; c ; <raw stored payload> BEL`. The payload is whatever followed "52;c;" on the server and is not validated as base64.
4. **Reverse video**: `ESC [ ? 5 h` or `ESC [ ? 5 l`, when changed or not initialized.
5. **On size change**: `ESC [ r` then `ESC [ 0 m ESC [ H ESC [ 2 J`, then a full redraw. The local cursor becomes (0,0) and the rendition is reset.
6. **When not initialized**: `ESC [ ? 2 5 l`.
7. **Scroll shortcut**: the server looks for an old row equal to new row 0 at offset k>0 and takes the longest run of matching rows, giving scroll_height. It then emits `ESC[0m` (forced). Then either:
   - the whole screen scrolled and the cursor is on the bottom row: `CR` followed by k×`LF`; or
   - otherwise: `ESC [ 1 ; <b+1> r`, an absolute CUP to (b,0) (preceded by `ESC[?25l` if the cursor was visible), k×`LF`, then `ESC [ r`. The cursor is then treated as unknown, so the next move is an absolute CUP.
   - On master, a forced `ESC]8;;ESC\` is emitted there as well.
8. **Rows**: per-row diff (put_row):
   - Unchanged cells are skipped.
   - A run of empty cells with the same rendition becomes either:
     - mid-row: `SGR(bg-only rendition)` plus either `ESC [ n X` (ECH, used when n>4) or n spaces; or
     - at end of line: `ESC [ K`. The exception is a wrap-flagged row: there the run is written as spaces and counts as "wrote last cell".
   - Character cells: move, then SGR if it changed, then the grapheme bytes.
   - **Moves (append_move)**, used only when the position is known:
     - target x==0 and dy in 0..4: `CR` (if x≠0) plus dy×`LF`;
     - same row with dx in −1..−4: |dx|×`BS`;
     - otherwise `ESC [ y+1 ; x+1 H`.
     - Unknown position (−1) always uses CUP. "Silent" moves emit `ESC[?25l` first if the cursor is currently shown.
   - **Wrap**: when a row has its wrap flag (the last cell's wrap bit) and the last column was written, no CRLF follows. The next row's first cell is printed immediately, so the receiver's own autowrap (deferred wrap / next_print_will_wrap) carries the cursor to the next row and sets that row's wrap flag. Before printing the last cell of a wrapping row, the cursor is invalidated, which forces an explicit CUP. For a non-wrapping row whose last column was written (and which is not the bottom row), `CR LF` is emitted.
9. **Final cursor**: a move to the true cursor position if it differs (CR/LF/BS/CUP forms as above).
10. **Cursor visibility**: `ESC[?25h` or `ESC[?25l`, if it differs from the tracked value.
11. **Rendition**: `SGR(current ds.renditions)` if it changed; forced when not initialized.
12. **Master only**: the hyperlink, `ESC ] 8 ; <params> ; <url> ESC \`, or `ESC ] 8 ; ; ESC \` to close.
13. **Bracketed paste**: `ESC[?2004h` or `ESC[?2004l`.
14. **Mouse reporting**:
    - new mode NONE: `ESC[?1003l ESC[?1002l ESC[?1001l ESC[?1000l`;
    - otherwise: `ESC[?<old>l` (if the old mode was not NONE), then `ESC[?<new>h`. The mode is one of 9, 1000, 1001, 1002, 1003.
15. **Focus events**: `ESC[?1004h` or `ESC[?1004l`.
16. **Mouse encoding**:
    - DEFAULT: `ESC[?1015l ESC[?1006l ESC[?1005l`;
    - otherwise: `ESC[?<old>l`, then `ESC[?<new>h`. The mode is one of 1005, 1006, 1015.

**SGR format** (`Renditions::sgr`, terminalframebuffer.cc). Always a full reset first:

`ESC [ 0 [;1][;3][;4][;5][;7][;8] [fg] [bg] m`

- fg:
  - stored value 30..37: `;30`..`;37`;
  - stored value >37 (palette index 8..255): `;38;5;N`;
  - truecolor (bit 0x1000000): `;38;2;R;G;B`.
- bg: the same, using 40..47, `;48;5;N` and `;48;2;R;G;B`.
- 90..97 and 100..107 are stored as palette indices 8..15 and so re-emitted as `38;5;8..15` / `48;5;8..15`.
- Never emitted: faint (SGR 2 is ignored by the server; 22 only clears bold), strikethrough 9, overline, underline styles/colours (no colon sub-params: ':' sends the parser to CSI_Ignore and the whole CSI is dropped), fraktur, double underline.

**Graphemes** (`Cell::print_grapheme`):
- An empty cell prints as a space.
- A cell whose content starts with a combining character ("fallback") is sent as U+00A0 NBSP followed by the combining characters. Render NBSP as a space.
- A wide cell prints its character and the following cell is skipped (frame_x += 2).

**Never emitted by new_frame**:
- `?1h` (DECCKM): application_mode_cursor_keys is not in DrawState==.
- `?1007` (alternate scroll): it IS in DrawState==, so a change triggers a send, but no bytes describe it.
- Also never emitted: ?7 autowrap, ?6 origin, IRM 4, DECSC/DECRC, tabs, ?1049/47 alternate screen, DECSCUSR, ?2026, kitty/CSI u, DCS/APC/sixel, OSC 4/7/9/10/11/104/777/1337, C1 8-bit controls, ESC c.

**Client process (stmclient.cc)**:
- At start it writes `Display::open()` = smcup + `ESC[?1h`, so the local terminal is always in application cursor mode.
- At exit it writes `ESC[?1l ESC[0m ESC[?25h ESC[?1003l ESC[?1002l ESC[?1001l ESC[?1000l ESC[?1015l ESC[?1006l ESC[?1005l` + rmcup.
- Each frame: `new_state = latest_remote.fb; overlays.apply(new_state); diff = Display(true /*TERM*/).new_frame(!repaint_requested, local_fb, new_state)`, written to stdout.
- The connect-phase title prefix is "[mosh] " (TitleEngine).

## 3. Minimal Swift applier: required semantics (from terminalfunctions.cc, terminal.cc, terminalframebuffer.cc)

**Cell**:
- contents: UTF-8 string, max 32 bytes;
- renditions: fg (25-bit), bg (25-bit), 8 attribute bits (bold, faint (unused), italic, underlined, blink, inverse, invisible);
- wide: Bool; fallback: Bool; wrap: Bool (meaningful on the last cell of a row).

**Row** = [Cell], width W. **DrawState**:
- cursor row/col, next_print_will_wrap, auto_wrap_mode (default true), scroll region top/bottom, renditions, cursor_visible (default true);
- reverse_video, bracketed_paste, mouse_reporting_mode, mouse_focus_event, mouse_encoding_mode;
- master adds hyperlink.

**Framebuffer**: rows, window_title, icon_name, clipboard, bell_count, title_initialized.

**Parser**: a DEC/ECMA-48 state machine (parserstate.cc).
- C0 executes in every state; anywhere-rules: 0x18/0x1A cancel, ESC, and C1 0x80-0x9F after UTF-8 decoding.
- CSI params: digits and ';' only, at most 100 param chars. A missing or zero param takes the default.
- OSC terminates on BEL or ST; ESC '\' also works because ESC exits the OSC state and fires OSC_End. Only chars 0x20-0x7F and ≥0xA0 are accepted.
- OSC buffer capped at 16384 chars.
- UTF-8 decoding; invalid input becomes U+FFFD (parser.cc, not re-read in detail).

**Must implement** for the display dialect:
- Print with wcwidth:
  - width 1 or 2. If auto_wrap and next_print_will_wrap: set the current row's wrap flag, CR, then LF with autoscroll.
  - A wide character at the last column wraps without setting the flag (that cell is cleared).
  - Write the cell with the current renditions; a wide character also clears col+1.
  - `move_col(w, relative, implicit)`: next_print_will_wrap = (col ≥ W), then clamp the column to W−1.
  - Width 0 (combining): append to the combining cell (last printed position). If that cell is empty, set fallback and advance.
- BEL: bell_count += 1.
- BS: col−1, clamped; clears pending wrap.
- CR.
- LF/VT/FF/IND (0x84): autoscroll within the region. Scroll = delete row at top, insert a blank row at bottom (blank cells get bg = current bg).
- CUP `H`/`f`: absolute; origin mode is never set by the dialect.
- DECSTBM `r`: validate as xterm does; homes the cursor; no params means the full screen.
- ECH `X`, EL `K` (0/1/2), ED `J` (0/1/2): erased cells get `Renditions(bg=current bg)` with fg=0 and no attributes (BCE).
- SGR: as in §2. Parse 38/48;5;n and 38/48;2;r;g;b; 0 resets everything; 39/49 restore default colours.
- DECSET/DECRST: 5, 25, 2004, 9/1000-1003, 1004, 1005/1006/1015.
- OSC 0/1/2 and 52; OSC 8 for master servers.
- Every CSI, ESC or control function except HT, CHT/CBT, TBC, SGR, DECSET and DECRST clears next_print_will_wrap. Unknown functions also clear it.

**Optional** (server-side only; the dialect never sends them): IL/DL/ICH/DCH, VPA/HPA/CHA, CUU-CUF, SU/SD, tabs, DECSC/DECRC, RIS, DECSTR, DECALN, IRM.

**Unicode width pitfall**:
- The server computes widths with its own libc wcwidth, plus a shortcut for printable ISO-8859-1 characters (always width 1). The client's emulator recomputes widths from the bytes it receives.
- Display advances its cursor model by the server's cell width and prints the next adjacent cell without a move. If client and server disagree (emoji, East Asian ambiguous, newer Unicode), every following cell in that row shifts until the next explicit move, and wide-at-last-column wrapping diverges.
- Mitigation: ship a wcwidth table matching modern glibc (Unicode 15/16) rather than Apple's wcwidth.
- The protocol carries no width information and there is no resync except via a full repaint.

## 4. Keyboard input (terminaluserinput.cc, stmclient.cc)
- The client sends raw bytes as UserByte and its window size as Resize.
- The server's UserInput state machine rewrites `ESC O A/B/C/D` to `ESC [ A..D` when the server app is NOT in DECCKM. The comment says "The user will always be in application mode".
- So the iOS client should always send `ESC O A..D` for arrows. The DECCKM state never reaches the client.
- Keypad application mode (ESC =/>) is not implemented in the emulator; send plain codes for other keys.
- Home/End etc. pass through unchanged.
- The client must do locally what an outer terminal would do:
  - wrap pastes in `ESC[200~` … `ESC[201~` when fb.bracketed_paste;
  - generate mouse reports from mouse_reporting_mode and encoding (X10 for 9; 1000 normal; 1002 button-event; 1003 any-event; 1006 SGR `ESC[<b;x;yM/m`; 1015 urxvt; 1005 UTF-8);
  - send focus `ESC[I`/`ESC[O` when mouse_focus_event.
- mosh-client's escape key is Ctrl-^ (0x1E) followed by '.', which is unneeded on iOS.
- mosh-client skips prediction for reads over 100 bytes (paste heuristic).

## 5. Prediction engine and notification bar (src/frontend/terminaloverlay.h/.cc, 932 lines in 1.4.0)

**Inputs** (stmclient.cc process_network_input / process_user_input):
- `set_local_frame_sent(sender.get_sent_state_last())`, before each batch of user bytes;
- `set_local_frame_acked(get_sent_state_acked())`;
- `set_local_frame_late_acked(latest_remote_state.echo_ack)`;
- `set_send_interval(send_interval())`, where send_interval = ceil(SRTT/2) clamped to [20,250] ms;
- notification engine: `server_heard(latest_remote.timestamp)`, `server_acked(sent_state_acked_timestamp)`.

**Algorithm**:
- Each user byte goes through its own UTF8Parser (ESC O is rewritten to ESC [).
- A Print of width 1 creates a ConditionalOverlayCell at the predicted cursor position, tagged with expiration_frame = local_frame_sent+1 and the current prediction_epoch. Insert mode by default: cells to the right shift and the last column becomes "unknown". The rendition is copied from the left neighbour.
- 0x7f (backspace) predicts a delete with shift-left.
- CR predicts a newline; on the bottom row it predicts a blank row.
- CSI C/D move the predicted cursor.
- Anything else (control characters, escapes, wide or other printable characters) calls become_tentative(), i.e. epoch++.
- **cull()**, run on every frame:
  - Once `late_ack >= expiration_frame`, each cell is checked against the real framebuffer:
    - Correct: confirmed_epoch is raised; the rest of the row's renditions are synced.
    - CorrectNoCredit: blank, unknown, or matches the original contents.
    - IncorrectOrExpired: if tentative, kill that epoch; otherwise reset everything.
  - The cursor prediction is checked the same way.
- **Display triggers**:
  - srtt_trigger turns on when send_interval > 30 ms and off when ≤ 20 ms and idle;
  - flagging (underline predictions) turns on when send_interval > 80 ms and off when ≤ 50 ms;
  - glitch_trigger: pending ≥ 250 ms shows predictions; ≥ 5000 ms shows and underlines; repaired after 10 quick confirmations at least 150 ms apart.
- Preferences: Always/Never/Adaptive (default)/Experimental; predict_overwrite.
- A size change resets all predictions.
- Predictions in tentative epochs (> confirmed_epoch) are not drawn.

**NotificationEngine**:
- A blue bar on row 0 (fg 7, bg 4, bold).
- Text is either "mosh: Last contact/reply N seconds ago." or a message.
- server_late after 6500 ms; reply_late after 10000 ms.
- Countdown updates every 1 s, or every ACK_INTERVAL (3000 ms) after 60 s.

**Porting**: about 900 lines of C++ that depend only on Framebuffer/Cell/Renditions, the parser, wcwidth and timestamp(). The overlay is applied to a copy of the latest remote framebuffer before rendering, so a Swift renderer can draw the copy directly. Notification UI could be native UIKit instead of row 0.

## 6. OSC 52 end to end (1.4.0 and master are identical)

**Server path**:
1. The pty bytes `ESC ] 52 ; c ; <b64> (BEL | ESC \ | 0x9C)` go through the parser's OSC_String state.
2. `Dispatcher::OSC_put` appends while `OSC_string.size() < MAXIMUM_CLIPBOARD_SIZE (16*1024)`. Anything beyond is silently truncated, so at most 16379 payload chars (about 12 KB decoded), possibly invalid base64.
3. `OSC_dispatch` accepts ONLY when `OSC_string[0..4] == "52;c;"` and calls `fb->set_clipboard(rest)`.
4. Any other selection is dropped silently: `52;;` (tmux), `52;p;` (nvim '*' register), `52;s0;`, `52;pc;`.

**Diff path**:
- `if (f.get_clipboard() != frame.last_frame.get_clipboard())` emits `ESC]52;c;<payload>BEL`.
- Consequence 1: copying text equal to the clipboard in the reference state sends nothing (issue #1090, open). PR #1104 (open, unmerged) would add `uint8_t clipboard_seqnum` and also forward the selection param (`ESC]52;<sel>;<data>`).
- Consequence 2: the clipboard persists in server state. A client that restarts from blank state 0 will receive the last clipboard again on reconnect. `RIS` (ESC c) clears it.

**Read/query**: no support. The `52;c;?` from neovim's paste is stored as clipboard "?" and forwarded as `ESC]52;c;?BEL`.
- Stock mosh-client writes it to the outer terminal, whose reply arrives on stdin and would be sent as keystrokes. This is unverified behaviour.
- An iOS client could deliberately answer by injecting `ESC]52;c;<b64>BEL` (or with ST) into the user byte stream. Neovim's matcher `'\027%]52;%w?;([A-Za-z0-9+/=]*)'` accepts it.
- That works only the first time: a second "?" equals the stored "?" and is not re-emitted, so it needs a clipboard change in between.
- Security: make it opt-in with a per-request prompt.

**DA1**: `CSI_DA` answers `ESC[?62c`. There is no `52`, and XTGETTCAP (DCS +q) gets no reply. Neovim's runtime/plugin/osc52.lua therefore never sets termfeatures.osc52, and users must set `vim.g.clipboard = 'osc52'` themselves. Issue #1399 (open) asks for DA1 to advertise it.

**Neovim copy**: `string.format('\027]52;%s;%s\027\\', clipboard, contents)` with `'+'`→`c` and `'*'`→`p`. '+' works through mosh; '*' is dropped.

**tmux**:
- mosh-server sets `TERM=xterm-256color` when the client reports 256 colours, else `xterm` (mosh-server.cc:552-556).
- tmux's default `terminal-features` contains `xterm*:clipboard:ccolour:cstyle:focus:title`. The clipboard feature defines `Ms=\E]52;%p1%s;%p2%s\a`. `set-clipboard` defaults to 1 ("external").
- tmux always passes the clip argument "" for copy-mode, load-buffer -w and set-buffer -w (window-copy.c:6686,6782; cmd-load-buffer.c:81; cmd-set-buffer.c:133). It emits `ESC]52;;<b64>BEL`, which mosh 1.4.0 and master DROP.
- An application inside tmux sending OSC 52 is re-emitted with its own clip letters (input.c:3563).
- Workaround in ~/.tmux.conf on the server: `set -as terminal-overrides ',xterm*:Ms=\E]52;c%p1%s;%p2%s\a'`. The issue #1311 comment of 2026-09-24 proposes `\E]52;%p1%sc;%p2%s\a`; keep %p1%s in the string. Then detach and reattach.
- Recommend that the app's docs and onboarding show this snippet.

**iOS client handling**:
- Accept `OSC 52 ; Pc ; Pd` for any Pc, to tolerate PR #1104 servers.
- Treat Pd="?" as a query and do not set the clipboard.
- Decode base64 leniently; discard on failure.
- Cap the size.
- Optionally ignore a clipboard that arrives in the first diff after a cold reconnect.

## 7. Not carried to the client (evidence: absent from get_DEC_mode, the function registry and new_frame)
- **Scrollback**: none. The Framebuffer holds only `rows` at the screen height. Lines scrolled off are discarded by delete_line.
- **Alternate screen** (?47, ?1047, ?1049): not implemented, so apps draw over the single screen. The client's own smcup comes only from the local terminfo.
- **Cursor shape** (DECSCUSR `CSI Ps SP q`): unregistered and ignored.
- **DECCKM** (?1) and **?1007**: tracked by the server, never sent.
- **Synchronized output** (?2026), **kitty keyboard** (CSI >/=/< u), **modifyOtherKeys** (CSI > 4 m): ignored. The `>` collect then 'm' has no handler.
- **Graphics**: sixel and other DCS passthrough are ignored (Hook/Put are not implemented in Emulator). Kitty graphics and iTerm2 1337 go via APC/OSC and are ignored.
- **OSC 7** (cwd, PR #1383 open), **OSC 9/777** notifications (PR #1144 open), **OSC 10/11/4** colour queries (PR #1394 open), **OSC 104**, **OSC 133** prompts: not supported.
- **OSC 8**: dropped in 1.4.0; carried on master only.
- **SGR faint/strike/overline/underline styles/colon forms**: not supported.
- **Bell**: count only, at most one BEL per frame.
- **Focus events (?1004)**: ARE carried, contrary to the task's assumption.

## 8. Recommended test strategy
1. **Golden-trace oracle (Docker on Linux)**:
   - Build mosh-1.4.0 and master from source.
   - Write a small C++ recorder linking libmoshterminal and libmoshstatesync (the same pattern as src/fuzz/terminal_fuzzer.cc and src/examples/termemu.cc). It:
     - runs vim, nvim, tmux, htop, less, emacs -nw, an `ls --color` loop, Unicode/emoji/CJK files and `printf` OSC 52 tests in a pty with TERM=xterm-256color;
     - feeds the output into `Terminal::Complete server`;
     - every 20 ms, snapshots and emits `HostMessage = server.diff_from(prev_snapshot)` plus a canonical JSON dump of the resulting framebuffer (cells: contents, wide, fallback, fg, bg, attrs, wrap; cursor; modes; title; clipboard; bell_count).
   - Also generate diffs from non-adjacent references (k frames back) to mimic packet loss and old_num.
2. **Swift tests**: apply each HostMessage to a copy of the reference state and assert equality with the golden dump. Run on Linux with swift-corelibs: XCTest/swift-testing in Docker. CI on macOS runners.
3. **Live integration**: run the real mosh-server 1.4.0 on the box and record the decrypted Instruction.diff payloads, with a debug hook in the Swift client or by decrypting with MOSH_KEY via src/examples/decrypt.cc.
4. **Targeted cases**:
   - 80th-column wrap across frames (mirror src/tests/emulation-80th-column.test and emulation-wrap-across-frames.test);
   - scroll-region scroll (emulation-multiline-scroll.test);
   - BCE (emulation-attributes-bce.test);
   - 16/256/truecolor (emulation-attributes-*.test);
   - wide character at the last column; combining character at column 0 (the NBSP fallback);
   - resize during output;
   - OSC 52: same text twice, tmux `52;;`, the 16 KiB cap, `52;c;?`;
   - title vs icon;
   - mouse mode transitions 1000→1002→none;
   - BS cursor moves after a last-column write on the bottom row (see unverified).
5. **Fuzz**: feed random bytes to the mosh emulator, take a diff, and assert that the Swift applier reaches the same framebuffer (seed from src/fuzz/terminal_corpus).
6. **Prediction engine**: unit-test with synthetic ack and echo-ack timelines. Use src/tests/prediction-unicode.test as a reference.

## findings

### 1. Release status

**topic:** Release status

#### claim

mosh-1.4.0 (2022-10-27) is still the latest release. Master is 39 commits ahead; its only display-dialect change is OSC 8 hyperlinks (PR #1360, merged 2026-03-29, unreleased).

#### evidence

gh release list: 'mosh-1.4.0 Latest 2022-10-27'; master commit 0618218946 2026-03-22 'Add OSC8 hyperlink support'; PR 1360 merged 2026-03-29

**confidence:** high

### 2. Display config for network diffs

**topic:** Display config for network diffs

#### claim

Complete constructs Display(false), giving has_ech=true, has_bce=true, has_title=true and no smcup/rmcup. diff_from always passes initialized=true.

#### evidence

src/statesync/completeterminal.h: 'terminal( width, height ), display( false )'; terminaldisplayinit.cc: 'has_ech( true ), has_bce( true ), has_title( true ), smcup( NULL )'; completeterminal.cc: 'display.new_frame( true, existing.get_fb(), terminal.get_fb() )'

**confidence:** high

### 3. Client applies diffs via full emulator on copies of reference states

**topic:** Client applies diffs via full emulator on copies of reference states

#### claim

The client copies the reference state named by old_num and runs the hostbytes through the full parser and emulator. Up to 1024 received states are kept. Streaming bytes into a generic terminal is therefore insufficient.

#### evidence

src/network/networktransport-impl.h recv(): 'TimestampedState<RemoteState> new_state = *reference_state; ... new_state.state.apply_string( inst.diff() );' and 'received_states.size() > 1024'

**confidence:** high

### 4. HostMessage format

**topic:** HostMessage format

#### claim

The Instruction extensions are hostbytes=2 (HostBytes.hoststring=4), resize=3 (width=5, height=6) and echoack=7 (echo_ack_num=8). Order: echoack, then resize, then hostbytes.

**evidence:** src/protobufs/hostinput.proto; completeterminal.cc diff_from

**confidence:** high

### 5. SGR emission

**topic:** SGR emission

#### claim

Every SGR starts with 0 and may add 1, 3, 4, 5, 7, 8 and 30-37, 38;5;N or 38;2;R;G;B (bg likewise). Faint (2) and strikethrough (9) are unsupported. Colon sub-params cause the whole CSI to be ignored.

#### evidence

terminalframebuffer.cc Renditions::sgr: 'ret.append( "\033[0" ); ... ";38;2;%d;%d;%d" ... ";38;5;%d"'; set_rendition handles only 1/22,3/23,4/24,5/25,7/27,8/28; parserstate.cc CSI_Param: 'ch == 0x3A ... s_CSI_Ignore'

**confidence:** high

### 6. Cursor and erase forms

**topic:** Cursor and erase forms

#### claim

Moves are CR plus up to 4 LFs, up to 4 BSs, or CSI y;x H. Erases are CSI n X (n>4), spaces, or CSI K; a full clear is CSI r CSI 0m CSI H CSI 2J. Scrolls are CR+LFs, or CSI 1;b r + CUP + LFs + CSI r.

**evidence:** terminaldisplay.cc FrameState::append_move, put_row ('clear_count > 4' -> '\033[%dX', '\033[K'), new_frame scroll block ('\033[%d;%dr')

**confidence:** high

### 7. Modes conveyed

**topic:** Modes conveyed

**claim:** Conveyed modes: ?5, ?25, ?2004, mouse ?9/?1000-1003, ?1004 focus, ?1005/?1006/?1015 encoding. DECCKM (?1) and ?1007 are never emitted.

#### evidence

terminaldisplay.cc new_frame; terminalframebuffer.h DrawState::operator== omits application_mode_cursor_keys but includes mouse_alternate_scroll

**confidence:** high

### 8. Wrap and wide/combining

**topic:** Wrap and wide/combining

#### claim

Wrap is conveyed implicitly by letting the receiver's deferred autowrap run. Combining-first cells are sent as NBSP + combining. Widths are recomputed by the client's wcwidth, and any mismatch with the server's misplaces the rest of the row.

#### evidence

terminaldisplay.cc put_row 'we let the real cursor actually wrap around'; terminalframebuffer.h print_grapheme 'if ( fallback ) output.append( "\xC2\xA0" )'; terminal.cc Emulator::print uses wcwidth(ch)

**confidence:** high

### 9. Arrow keys

**topic:** Arrow keys

#### claim

Clients should always send ESC O A-D. The server rewrites them to ESC [ A-D when the remote app is not in DECCKM, and mosh-client always puts its local terminal in ?1h.

**evidence:** terminaluserinput.cc: 'The user will always be in application mode'; terminaldisplay.cc Display::open(): '\033[?1h'

**confidence:** high

### 10. OSC 52 accepted form and size

**topic:** OSC 52 accepted form and size

#### claim

Only the literal prefix '52;c;' is accepted, and the OSC buffer is capped at 16*1024 chars with silent truncation. tmux's '52;;' and nvim's '52;p;' are dropped.

#### evidence

terminalfunctions.cc OSC_dispatch: "OSC_string[ 3 ] == L'c' && OSC_string[ 4 ] == L';'"; terminaldispatcher.cc: 'MAXIMUM_CLIPBOARD_SIZE = 16*1024' and 'if ( OSC_string.size() < MAXIMUM_CLIPBOARD_SIZE)'

**confidence:** high

### 11. OSC 52 repeat bug

**topic:** OSC 52 repeat bug

#### claim

The clipboard is re-emitted only when its content differs from the reference state, so copying identical text twice does nothing. This is unfixed in 1.4.0 and master. The fix (clipboard_seqnum) is in open, unmerged PR #1104.

#### evidence

terminaldisplay.cc: 'if (f.get_clipboard() != frame.last_frame.get_clipboard())'; issue #1090 open; gh pr diff 1104 adds 'clipboard_seqnum++'; PR 1104 state OPEN

**confidence:** high

### 12. tmux interaction

**topic:** tmux interaction

#### claim

tmux always emits OSC 52 with an empty selection via Ms='\E]52;%p1%s;%p2%s\a' for xterm* (mosh-server sets TERM=xterm-256color or xterm). mosh drops it, so a terminal-overrides Ms that inserts 'c' is required.

#### evidence

tmux tty-features.c: '"Ms=\\E]52;%p1%s;%p2%s\\a"'; options-table.c terminal-features default 'xterm*:clipboard:...'; window-copy.c:6686 'screen_write_setselection(&ctx, "", buf, len)'; cmd-load-buffer.c:81 'tty_set_selection(&tc->tty, "", ...)'; mosh-server.cc:553-556 TERM xterm/xterm-256color

**confidence:** high

### 13. OSC 52 read and DA1

**topic:** OSC 52 read and DA1

#### claim

Clipboard query is unsupported: '52;c;?' is stored and forwarded as clipboard '?'. DA1 replies ESC[?62c without 52, so neovim's autodetect stays off.

#### evidence

terminalfunctions.cc CSI_DA: '\033[?62c'; neovim runtime/plugin/osc52.lua checks DA1 for param '52' then XTGETTCAP Ms; osc52.lua paste sends osc52(clipboard,'?')

**confidence:** high

### 14. Not supported features

**topic:** Not supported features

#### claim

Not supported: alternate screen, scrollback, DECSCUSR, sync output, kitty keyboard/graphics, sixel, OSC 7/9/10/11. Only modes 1, 3, 5, 6, 7, 25, 1004, 1007, 2004 and the mouse modes are recognised.

#### evidence

terminalfunctions.cc get_DEC_mode switch (cases 1,3,5,6,7,25,1004,1007,2004); Emulator has no Hook/Put handling; Framebuffer holds only screen rows

**confidence:** high

### 15. Prediction engine inputs

**topic:** Prediction engine inputs

#### claim

Prediction needs: local_frame_sent, local_frame_acked, late_acked = server echo_ack (50 ms ECHO_TIMEOUT), and send_interval = ceil(SRTT/2) clamped to 20..250 ms. Thresholds: SRTT trigger 30/20 ms, flagging 80/50 ms, glitch 250 ms and 5000 ms.

#### evidence

terminaloverlay.h constants SRTT_TRIGGER_HIGH=30 etc.; stmclient.cc process_network_input set_local_frame_late_acked(...get_echo_ack()); transportsender-impl.h send_interval; completeterminal.h ECHO_TIMEOUT = 50

**confidence:** high

### 16. Master OSC 8

**topic:** Master OSC 8

**claim:** Master servers emit ESC ] 8 ; params ; url ESC \ per cell-run, and ESC ] 8 ; ; ESC \ to close. Clients must parse an ST-terminated OSC.

**evidence:** master terminalframebuffer.cc Hyperlink::osc8: 'ret.append( "\033]8;" ) ... ret.append( "\033\\" )'

**confidence:** high

## recommendations

- Implement the client-side state as a copy-on-write Swift Framebuffer (struct of [Row] of Cell) plus a parser and emulator subset that matches mosh semantics exactly (deferred wrap, BCE erase to a bg-only rendition, scroll region homing, combining/fallback). Alternatively, compile mosh's C++ src/terminal and src/statesync into the iOS target and render the Framebuffer directly. Either way, render from the framebuffer, not by feeding bytes to SwiftTerm.
- Ship your own wcwidth table that matches current glibc/Unicode rather than Apple's libc wcwidth, to minimise width desync with Linux servers.
- Always send arrows as ESC O A..D. Implement bracketed-paste wrapping, mouse reporting (modes 9/1000/1002/1003 with encodings 1005/1006/1015) and focus reports locally, all driven by the received DrawState.
- OSC 52 client handling: accept any Pc (to tolerate PR #1104-patched servers); decode base64 leniently; treat '?' as a query and do not write it to the clipboard; offer an opt-in prompt that answers queries by injecting ESC]52;c;<b64>BEL into user input; suppress a clipboard set that arrives in the first diff after a cold-start reconnect.
- Document for users the tmux workaround set -as terminal-overrides ',xterm*:Ms=\E]52;c%p1%s;%p2%s\a' (then reattach), and vim.g.clipboard='osc52' for neovim. Mention that identical re-copies do not propagate on stock mosh-server.
- Port terminaloverlay.cc (about 900 lines) to Swift for local echo, but replace NotificationEngine's row-0 bar with a native UI banner. Feed it sent and acked state numbers, echo_ack and send_interval from the transport port.
- Build a golden-trace harness in Docker that links mosh 1.4.0 and master libs, records HostMessages and framebuffer dumps from real vim/tmux/htop sessions, and replays them in Swift tests. Include diffs against non-adjacent reference states, resize-mid-stream cases, and the mosh emulation-*.test scenarios.
- For the stated no-background-persistence goal: resuming after iOS kills the app requires persisting the received reference state(s) with their state numbers, plus the transport's sequence and nonce state, so the next diff's old_num can be found. Coordinate with the network-layer researcher, because otherwise the server will not resync from blank state 0.

## risks

- Unicode width mismatch between server glibc wcwidth and the client causes row corruption until the next full repaint. The protocol carries no width metadata.
- Possible off-by-one: after the bottom row's last column is written (non-wrapping row), the Display's cursor model sits at x=width while the emulator's cursor is clamped to width-1. A following 1-4 BS move could then land one column off. Not confirmed; needs a golden test.
- OSC 52 payloads over about 16 KiB are silently truncated server-side into possibly-invalid base64, which then reaches the client.
- The clipboard and title persist in server state, so they can be re-delivered unexpectedly after the client restores an older or blank reference state.
- Answering OSC 52 '?' queries hands the iOS clipboard to any remote program. It must be opt-in and prompt each time. It also works only once per distinct stored value because of the content-compare bug.
- Master-only features (OSC 8) mean servers built from master emit ESC]8 sequences, so the client must tolerate them even if it targets 1.4.0.
- Mouse alternate-scroll (?1007) state changes trigger diffs but carry no bytes, so the client cannot know the mode. Treat scroll gestures on the main screen as arrow keys or not, by user preference.
- Without an alternate screen or scrollback in mosh, users expect local scrollback that mosh cannot provide. Any client-side history derived from scroll detection would be heuristic.

## unverified

- Whether stock mosh-client's outer terminal reply to a forwarded ESC]52;c;? actually reaches the remote app as keystrokes (inferred from stmclient reading stdin as user bytes; not tested).
- The exact UTF-8 invalid-sequence handling in parser.cc (U+FFFD replacement); not re-read in detail.
- The BS-after-last-column-on-bottom-row off-by-one hypothesis in the risks list.
- The specific tmux terminal-overrides string from the issue #1311 comment ('\E]52;%p1%sc;%p2%s\a') was not tested here. The tmux source confirms the empty clip argument and the default Ms.
- Whether neovim versions older than master use the same DA1/XTGETTCAP detection (checked master runtime/plugin/osc52.lua only).
- The behaviour of open PRs #1394/#1383/#1440 beyond their titles was not inspected.

