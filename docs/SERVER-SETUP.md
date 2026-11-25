# Server setup

> Addresses, ports and details of the author's own network were removed before publication.

What a host needs so the app can log in, start `mosh-server` and receive the clipboard.
Sources: `docs/PLAN.md` sections 4 and 5, `Sources/MoshBootstrap`,
`Sources/MoshSession/ClipboardPolicy.swift`, and the mosh 1.4.0 source (`.refs/mosh`).
Where those do not decide something, this file says "not decided".

## 1. SSH

- The app logs in with its own Ed25519 key, or with a password if the key is rejected.
  Passwords are not stored. After a password login the app offers to append its key to
  `~/.ssh/authorized_keys`.
- The host must offer `publickey` or `password`. Other methods only (for example 2FA)
  are not supported.
- The host key must be Ed25519 or ECDSA. A host with only RSA host keys is refused.

## 2. mosh-server

- The app is built and tested against mosh-server 1.4.0. The lowest version that works
  is not decided. The app does not check the version.
- The app runs this over SSH, with a pty:

  ```
  <server> new -c 256 -s -l LANG=<locale> [-p <range>] [-- <remote command>]
  ```

  - `-c 256` makes mosh-server set `TERM=xterm-256color` in the session
    (`mosh-server.cc`).
  - `-s` binds the UDP socket to the address the SSH connection arrived on
    (`SSH_CONNECTION`).
- The command runs through your login shell as `$SHELL -c '<line>'`, which does not
  read your profile. So `mosh-server` must be on the PATH of a non-login shell.
  If it is not (common with Homebrew on a Mac, or `/usr/local`), set the host's
  "server path" field in the app. It takes:
  - empty: `mosh-server`;
  - a program name without a slash, for example `mosh-server-1.4`;
  - a full path to the program, for example `/opt/homebrew/bin/mosh-server`;
  - a directory, for example `/opt/homebrew/bin` or `~/.local/bin/`
    (`/mosh-server` is appended).
- If the app says "mosh-server was not found on the host", this is the cause.

## 3. Locale

- The app passes `LANG=<locale>`. The default is `en_US.UTF-8`; it can be changed per
  host.
- The locale must exist on the host and be UTF-8. If not, mosh-server stops with
  "mosh-server needs a UTF-8 native locale to run." The app then suggests `C.UTF-8`.
- `locale -a` lists what exists (names may be printed as `en_US.utf8`, `C.utf8`).

## 4. UDP and firewall

- mosh-server picks the first free UDP port in 60001-60999 (`network.h`,
  `PORT_RANGE_LOW` / `PORT_RANGE_HIGH`) unless the host has a port range set in the app.
  The app passes the range as `-p PORT` or `-p LOW:HIGH`.
- Open that UDP range in the host's firewall and in any firewall in front of it.
- If the server starts but no UDP reply arrives within 15 s, the app says UDP is
  blocked.
- Because of `-s`, the server only listens on the address SSH used. If you later reach
  the host by another address, the session cannot be resumed there. Use a name that
  works on every network (for example a Tailscale name).

## 5. Remote command and tmux start

- Optional per host. Presets: `tmux new -A -s main` and `tmux new -A -s $(hostname -s)`.
- The app runs it through your login shell (`$SHELL -lc`), so it sees your profile's
  PATH (Homebrew `tmux` on a Mac is found). The login shell must accept `-l -c`
  (tcsh does not; the app has a plain `sh -c` option for that case).
- mosh-server starts the command only after the first datagram from the app.
- Every session runs the command again. With the presets (`tmux new -A -s …`, `-A`: attach if
  the session exists), a second session of the same host attaches to the same tmux session and
  shows the same windows. For a shell of its own per session, use a command that makes a new
  tmux session (for example `tmux new`), or none.
- Each session holds one UDP port of the host's range while its server runs (section 4), also
  while it is parked on the phone: a range of ten ports allows ten sessions. When none is free
  the app says "No free UDP port on <host> in <range>"; end a session of that host, or widen the
  range in the host's settings.

### What a session's row shows

The Hosts list shows each open session as a row under its host. Its first line is the window
title, if the host set one, otherwise the last line on the session's screen that is not empty
(read from the session as it was saved, so it is the screen when the session was last on the
phone's screen). This is by design (the brief's item 7), not a bug:

- **With tmux**, the last line that is not empty is tmux's status line, so every tmux session
  reads alike. Let tmux set the title: put this line in `~/.tmux.conf`, then
  `tmux source-file ~/.tmux.conf`:

  ```
  set -g set-titles on
  ```

  tmux then sends the title in its `set-titles-string`, by default
  `#S:#I:#W - "#T" #{session_alerts}`: session, window number, window name and the pane's
  title, for example `main:0:sh - "<host name>"` (checked with `TERM=xterm-256color`,
  which mosh-server sets with `-c 256`; with the line removed tmux sends no title). For a
  shorter row, set the string as well, for example `set -g set-titles-string '#S: #W'`.
- **With a plain shell** the row shows the prompt, so two sessions on one host that both sit
  at a prompt read the same. A shell that sets a title for `xterm*` terminals shows that title
  instead: Ubuntu's default `~/.bashrc` does (`user@host: dir`; seen in `/etc/skel/.bashrc`).
- A resumable row's second line says when the session was started and when it was last used
  ("started 2 h ago · last used just now"), which tells two such sessions apart; a row that cannot
  be resumed says "Could not be resumed" before them, the other states show their state instead.

## 6. Clipboard (OSC 52)

### How a copy reaches the phone

- mosh-server runs its own terminal emulator. It keeps an OSC 52 only if the string
  starts with the literal `52;c;` (`terminalfunctions.cc`, `Dispatcher::OSC_dispatch`).
  Anything else (`52;;`, `52;p;`, `52;cc;`) is dropped. A query (`52;c;?`) gets no
  answer.
- It stores the text as the framebuffer's clipboard and sends `ESC ]52;c;<text> BEL` to
  the client when that text changes (`terminaldisplay.cc`). The client cannot change
  what travels, so the fix is server-side configuration.
- Inside tmux, tmux is the program that talks to mosh-server. tmux writes its clipboard
  with the terminfo capability `Ms` of the outer terminal. mosh-server sets the outer
  `TERM`: `xterm-256color` with `-c 256` (what the app passes), `xterm` without
  (`mosh-server.cc`).

### tmux

Put these two lines in `~/.tmux.conf`:

```
set -s set-clipboard on
set -as terminal-overrides ',xterm*:Ms=\E]52;c;%?%{0}%t%p1%s%;%p2%s\a'
```

What each line does:

- `set-clipboard on`: tmux also forwards OSC 52 that programs in a pane print (neovim,
  `printf`). With the default `external`, tmux sends only its own copies.
- The `Ms` override makes tmux always send `52;c;<base64>`. tmux's own copy names no
  selection (default `Ms` gives `52;;`), and a program's copy names its own (`c` or
  `p`). Both reach mosh-server as `c`.
- The part `%?%{0}%t%p1%s%;` is never printed. It is there because tmux 3.4 sends
  nothing at all for an `Ms` that does not mention `%p1` (checked here:
  `Ms=\E]52;c;%p2%s\007` gives no output, see the table).
- `xterm*` matches both `TERM` values mosh-server sets.

After editing the file: run `tmux source-file ~/.tmux.conf`, then detach and attach again
(`prefix d`, then a new session from the app with `tmux new -A -s main`). The `Ms`
override is read when a client attaches; `source-file` alone does not change an attached
client (checked here).

Not needed:

- `allow-passthrough`: not needed for the above. With it on, a program that wraps OSC
  52 in tmux's DCS passthrough (`ESC Ptmux;ESC ESC]52;c;...BEL ESC \`) also reaches the
  phone. Turn it on only if a program you use does that.
- `default-terminal` (the `TERM` inside tmux): `tmux-256color` and `screen-256color`
  give the same result.
- `terminal-features`: no line needed; the override above sets `Ms` directly.

tmux version: checked with tmux 3.4 only. No line needs a newer tmux. Older versions
were not checked.

### neovim

Put this in `~/.config/nvim/init.lua` (neovim 0.10 or newer):

```lua
local osc52 = require('vim.ui.clipboard.osc52')
local last = { {}, 'v' }
local function copy(reg)
  local send = osc52.copy(reg)
  return function(lines, regtype)
    last = { lines, regtype }
    send(lines)
  end
end
local function paste() return last end
vim.g.clipboard = {
  name = 'OSC 52',
  copy = { ['+'] = copy('+'), ['*'] = copy('*') },
  paste = { ['+'] = paste, ['*'] = paste },
}
```

What it does:

- Copy: neovim's own OSC 52 provider. `"+y` sends `52;c;`, `"*y` sends `52;p;`.
- Paste: `"+p` pastes the last text copied in this neovim. It does not ask the
  terminal. To paste from the phone, use the app's Paste key.
- Copy with `"+y` (or set `clipboard=unnamedplus`, then plain `y`). Inside tmux with the
  lines above, `"*y` works too. Without tmux, `"*y` does not reach the phone (`52;p;`
  is dropped).

Why not the shorter forms:

- `vim.g.clipboard = 'osc52'` works only from neovim 0.11. neovim 0.10 rejects a string
  ("clipboard: invalid g:clipboard"; `provider/clipboard.vim` of 0.10.4).
- Its paste asks the terminal (`52;c;?`). mosh-server never answers, so `"+p` without
  tmux waits 10 s and then fails ("Timed out waiting for a clipboard response from the
  terminal", "E353: Nothing in register +"; checked with 0.11.5). Inside tmux with
  `set-clipboard on`, tmux answers from its own buffer (checked).
- neovim's automatic OSC 52 detection is not reliable here (neovim's help says tmux may
  inhibit it), so set `vim.g.clipboard` yourself.

### What was sent, what mosh-server passed on

Checked here on 2026-11-15 with tmux 3.4, mosh-server 1.4.0 (`-c 256`, so
`TERM=xterm-256color`), neovim 0.10.4 and 0.11.5 (release tarballs). Each row is one run
of `scripts/osc52-check.sh --raw`. "Sent" is what tmux wrote to mosh-server's pty;
"passed" is what a real mosh client received.

- Own: tmux copy mode and `tmux set-buffer -w`.
- Program: `printf '\033]52;c;...\a'`, the same ended by `ESC \`, and neovim `"+yy`.
- `p`: `printf '\033]52;p;...\a'` (what neovim's `"*y` sends).

| tmux.conf | Own: sent | Own: passed | Program: sent | Program: passed | `p`: sent / passed |
|---|---|---|---|---|---|
| (empty) | `52;;` | nothing | nothing | nothing | nothing / nothing |
| `set-clipboard on` | `52;;` | nothing | `52;c;` | yes | `52;p;` / nothing |
| PLAN line (`Ms=\E]52;c%p1%s;%p2%s\a`) | `52;c;` | yes | nothing | nothing | nothing / nothing |
| PLAN line + `set-clipboard on` | `52;c;` | yes | `52;cc;` | nothing | `52;cp;` / nothing |
| `Ms=\E]52;c;%p2%s\007` + `set-clipboard on` | nothing | nothing | nothing | nothing | nothing / nothing |
| recommended `Ms` only (`external`) | `52;c;` | yes | nothing | nothing | nothing / nothing |
| **recommended (both lines)** | `52;c;` | **yes** | `52;c;` | **yes** | `52;c;` / **yes** |
| recommended, `TERM=xterm` (no `-c 256`) | `52;c;` | yes | `52;c;` | yes | `52;c;` / yes |
| recommended + `default-terminal screen-256color` | `52;c;` | yes | `52;c;` | yes | `52;c;` / yes |
| recommended + `default-terminal tmux-256color` | `52;c;` | yes | `52;c;` | yes | `52;c;` / yes |
| `allow-passthrough on` only | `52;;` | nothing | nothing | nothing | nothing / nothing |

DCS passthrough (`ESC Ptmux;...`): arrives as `52;c;` with `allow-passthrough on`
(alone or with the recommended lines); without it tmux drops it.

Without tmux (`--no-tmux`): `52;c;` from `printf` and neovim `"+yy` arrive; `52;p;` is
dropped.

How the proof was made: the script starts a real `mosh-server new -i 127.0.0.1` running
tmux, connects the stock `mosh-client` (under `script(1)`, its terminal output saved),
and decodes each `ESC ]52;c;` the client wrote. The recommended configuration was also
run with the repo's `moshcli` as the client (`MOSHCLI=...`, its `dump-bytes` step), with
the same result. "Sent" comes from a `script(1)` pty placed between mosh-server and tmux.

### Size

- mosh keeps at most 16384 characters of the OSC string (`MAXIMUM_CLIPBOARD_SIZE`,
  `terminaldispatcher.cc`), so at most 16379 characters of base64 after `52;c;`. A
  longer copy arrives cut off. tmux 3.4 did not cut a 66668-character copy (checked).
- The app refuses a clipboard field of 16379 characters or more as probably cut off.
  So the largest copy that arrives is 12282 bytes of text (16376 characters of base64).
  Checked: 12282 bytes arrived whole; 12283 bytes arrived cut to 16379 characters, which
  the app refuses.

### What the app does with OSC 52

- It writes the iOS clipboard when a live screen update changes the clipboard. It never
  writes during a resume repaint.
- It decodes strict base64 and strict UTF-8. Anything else is not written; the app shows
  "Clipboard data from the host was invalid or truncated".
- Copying the same text twice: the second copy does not arrive (mosh sends the clipboard
  only when it changes, mosh issue 1090). The app also skips a write equal to the last
  one it wrote.
- An empty clipboard and a query (`?`) are ignored. The app never sends the iOS clipboard
  to the host.
- A toast shows "Copied N bytes". The per-host switch "allow clipboard write" turns
  writing off.

## 7. Check it works

From a computer, with the same user the app will use. These use a non-login shell, as
the app does.

```
ssh HOST 'command -v mosh-server'         # must print a path
ssh HOST 'mosh-server --version'          # first line: mosh-server (mosh 1.4.0) ...
ssh HOST 'locale -a'                      # must list the locale you set (default en_US.UTF-8)
ssh -t HOST 'mosh-server new -c 256 -s -l LANG=en_US.UTF-8'
```

The last one must print `MOSH CONNECT <port> <key>` and
`[mosh-server detached, pid = N]`. Stop that server with `ssh HOST kill N`.
If you set a server path or locale in the app, use the same values here.

UDP: from a computer with mosh installed, `mosh HOST` must connect. This uses the same
default port range.

Clipboard, on the host, without the phone (needs `mosh-server`, `mosh-client`, `tmux`
and `script` on the host; takes about 25 s):

```
scripts/osc52-check.sh ~/.tmux.conf                          # tmux copies and printf
NVIM=$(command -v nvim) scripts/osc52-check.sh ~/.tmux.conf  # also neovim "+yy
scripts/osc52-check.sh --raw ~/.tmux.conf                    # also show what tmux sent
```

Each copy must say `ok`. Copy the script to the host first if the repo is not there.
The neovim step uses the neovim lines above, not your `init.lua`.

Clipboard, in the app (each with new text, because the same text twice does not
arrive):

- In a shell: `printf '\033]52;c;%s\a' "$(printf hello | base64)"` must show
  "Copied 5 bytes".
- In tmux with the lines above: `tmux set-buffer -w hello2` must show "Copied 6 bytes".
  A copy in copy mode goes the same way.
- In tmux: `printf '\033]52;c;%s\a' "$(printf hello3 | base64)"` must show
  "Copied 6 bytes".
- In neovim, in or out of tmux: `"+yy` on a line `abc` must show "Copied 4 bytes" (the
  line and its newline).
