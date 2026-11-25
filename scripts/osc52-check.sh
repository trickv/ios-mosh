#!/bin/bash
# Does a copy made inside tmux reach a mosh client? (docs/SERVER-SETUP.md section 6)
#
#   scripts/osc52-check.sh [--raw] [--no-tmux] [TMUX_CONF]
#   scripts/osc52-check.sh ~/.tmux.conf
#   NVIM=$(command -v nvim) scripts/osc52-check.sh ~/.tmux.conf
#
# Starts `mosh-server new -c 256 -i 127.0.0.1` (TERM=xterm-256color, as the app does) running
# tmux with TMUX_CONF (default: the lines recommended in SERVER-SETUP.md), connects a mosh
# client to it, and makes these copies inside tmux, one every 2 s, each with its own text:
#
#   copy-mode    tmux copy mode: search a line the pane printed, copy-selection-and-cancel
#   set-buffer   tmux set-buffer -w
#   printf-c     a program prints ESC ]52;c;<base64> BEL
#   printf-st    a program prints ESC ]52;c;<base64> ESC \  (the form neovim uses)
#   printf-p     a program prints ESC ]52;p;<base64> BEL   (neovim's * register)
#   passthrough  a program prints the OSC wrapped in tmux's DCS passthrough (counted only
#                if TMUX_CONF sets allow-passthrough on)
#   nvim         neovim "+yy with the neovim lines of SERVER-SETUP.md (only if NVIM=path
#                is set; neovim 0.10 or newer)
#
# Then it decodes every OSC 52 the client received and says which copies arrived.
# The client is the stock mosh-client run under script(1), or moshcli if MOSHCLI=path
# is set (its dump-bytes step records what the server sent).
# --no-tmux runs the programs straight in the mosh session, without tmux.
# OSC52_SERVER_ARGS replaces "-c 256" (for example OSC52_SERVER_ARGS= gives TERM=xterm).
# --raw also logs what tmux wrote to the server's pty (a script(1) pty between them) and
# prints every OSC 52 in it, so you see what was sent and what mosh-server passed on.
# Needs mosh-server, tmux, script (util-linux), base64. Exits 1 if a copy did not arrive.
set -uo pipefail

RAW=0
NO_TMUX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --no-tmux) NO_TMUX=1; shift ;;
    *) break ;;
  esac
done
TMP="$(mktemp -d)"
SOCKET="osc52-$$"
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  [ -n "${OSC52_KEEP:-}" ] && cp -r "$TMP" "$OSC52_KEEP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for tool in mosh-server tmux script base64; do
  command -v "$tool" >/dev/null || { echo "osc52-check: $tool is not in PATH" >&2; exit 2; }
done
if [ -z "${MOSHCLI:-}" ]; then
  command -v mosh-client >/dev/null || { echo "osc52-check: mosh-client is not in PATH (or set MOSHCLI)" >&2; exit 2; }
fi

if [ $# -gt 0 ]; then
  cp "$1" "$TMP/tmux.conf" || exit 2
else
  cat > "$TMP/tmux.conf" <<'EOF'
set -s set-clipboard on
set -as terminal-overrides ',xterm*:Ms=\E]52;c;%?%{0}%t%p1%s%;%p2%s\a'
EOF
fi
echo "osc52-check: tmux $(tmux -V | cut -d' ' -f2), $(mosh-server --version 2>&1 | head -n 1), conf:"
sed 's/^/  | /' "$TMP/tmux.conf"

ID="$$"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
if [ "$NO_TMUX" = 1 ]; then
  STEPS="printf-c printf-st"
else
  STEPS="copy-mode set-buffer printf-c printf-st printf-p"
  # The passthrough copy only counts when the conf turns allow-passthrough on.
  grep -q '^[^#]*allow-passthrough *\(on\|all\)' "$TMP/tmux.conf" && STEPS="$STEPS passthrough"
fi
[ -n "${NVIM:-}" ] && STEPS="$STEPS nvim"

# The neovim lines of SERVER-SETUP.md (neovim 0.10 or newer).
cat > "$TMP/init.lua" <<'EOF'
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
EOF
cat > "$TMP/pane.sh" <<EOF
#!/bin/bash
printf 'copy-mode-%s\n' '$ID'; sleep 3
if [ -n "\${TMUX:-}" ]; then
  tmux copy-mode
  tmux send-keys -X search-backward 'copy-mode-$ID'
  tmux send-keys -X begin-selection
  tmux send-keys -X end-of-line
  tmux send-keys -X copy-selection-and-cancel
  sleep 2; tmux set-buffer -w 'set-buffer-$ID'
fi
sleep 2; printf '\033]52;c;$(b64 "printf-c-$ID")\a'
sleep 2; printf '\033]52;c;$(b64 "printf-st-$ID")\033\\\\'
sleep 2; printf '\033]52;p;$(b64 "printf-p-$ID")\a'
sleep 2; printf '\033Ptmux;\033\033]52;c;$(b64 "passthrough-$ID")\a\033\\\\'
if [ -n "${NVIM:-}" ]; then
  sleep 2
  '${NVIM:-}' --clean -u '$TMP/init.lua' -c 'call setline(1, "nvim-$ID")' \\
    -c 'lua vim.defer_fn(function() vim.cmd([[normal! "+yy]]) end, 500)' \\
    -c 'lua vim.defer_fn(function() vim.cmd("qa!") end, 2000)'
fi
sleep 8
EOF
chmod +x "$TMP/pane.sh"

INNER="tmux -L $SOCKET -f $TMP/tmux.conf new-session -s check $TMP/pane.sh"
[ "$NO_TMUX" = 1 ] && INNER="$TMP/pane.sh"
if [ "$RAW" = 1 ]; then
  CMD=(script -qfec "$INNER" "$TMP/raw.bin")
else
  CMD=($INNER)
fi
if locale -a 2>/dev/null | grep -qix 'C\.utf-\?8'; then LOC=C.UTF-8; else LOC=en_US.UTF-8; fi
OUT="$(env -u TMUX LANG=$LOC LC_ALL=$LOC mosh-server new ${OSC52_SERVER_ARGS--c 256} -i 127.0.0.1 -- "${CMD[@]}" 2>&1 </dev/null)"
PORT="$(printf '%s\n' "$OUT" | sed -n 's/^MOSH CONNECT \([0-9]*\) .*/\1/p')"
KEY="$(printf '%s\n' "$OUT" | sed -n 's/^MOSH CONNECT [0-9]* \([^[:space:]]*\).*/\1/p')"
PID="$(printf '%s\n' "$OUT" | sed -n 's/.*detached, pid = \([0-9]*\).*/\1/p')"
[ -n "$PORT" ] && [ -n "$KEY" ] || { echo "osc52-check: mosh-server did not start: $OUT" >&2; exit 2; }

SECONDS_NEEDED=16
[ -n "${NVIM:-}" ] && SECONDS_NEEDED=21
if [ -n "${MOSHCLI:-}" ]; then
  printf 'sleep %d000\ndump-bytes %s\n' "$SECONDS_NEEDED" "$TMP/client.bin" > "$TMP/client.script"
  MOSH_KEY="$KEY" "$MOSHCLI" connect --quiet --host 127.0.0.1 --port "$PORT" \
    --no-reply-ms 0 --script "$TMP/client.script" >/dev/null 2>"$TMP/client.err"
  echo "osc52-check: client moshcli (exit $?)"
else
  MOSH_KEY="$KEY" LANG=$LOC LC_ALL=$LOC TERM=xterm-256color timeout "$((SECONDS_NEEDED + 20))" \
    script -qfec "stty rows 24 cols 80; mosh-client 127.0.0.1 $PORT" "$TMP/client.bin" \
    </dev/null >/dev/null 2>&1
  echo "osc52-check: client mosh-client (exit $?)"
fi

# Every OSC 52 in a byte stream, one per line, as "<selection>;<payload>" (BEL or ST ended).
osc52s() { LC_ALL=C grep -aoE $'\e\\]52;[^;\a\e]*;[^\a\e]*' "$1" | sed $'s/^\e\\]52;//'; }

if [ "$RAW" = 1 ]; then
  echo "osc52-check: OSC 52 written to mosh-server's pty:"
  osc52s "$TMP/raw.bin" | sed 's/^/  sent   52;/'
fi
echo "osc52-check: OSC 52 that the mosh client received:"
osc52s "$TMP/client.bin" | sed 's/^/  passed 52;/'
GOT="$(osc52s "$TMP/client.bin" | sed -n 's/^c;//p' | while read -r p; do printf '%s' "$p" | base64 -d 2>/dev/null; echo; done)"
FAILED=0
for step in $STEPS; do
  if printf '%s\n' "$GOT" | grep -qx "$step-$ID"; then
    echo "  ok      $step"
  else
    echo "  MISSING $step"; FAILED=1
  fi
done
exit $FAILED
