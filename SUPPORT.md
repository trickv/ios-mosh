# iOS-mosh support

iOS-mosh is an iPhone terminal for [mosh](https://mosh.org) sessions. This page is the support
page of its App Store listing.

## Getting help, reporting a problem

Open an issue in this repository: https://github.com/trickv/ios-mosh/issues

Please include:

- the app's version and build (the gear on the Hosts screen, then About; first lines);
- the iPhone model and iOS version;
- the server's operating system and `mosh-server --version`;
- what you did, what you expected, and the exact text of any message the app showed.

Issues are public. Do not post passwords, private keys, or host names and addresses you want to
keep to yourself. The public key line the app shows is safe to share.

## What a server needs

The full list is in [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md). In short:

1. **SSH login** with the app's own Ed25519 key or with a password. Two-factor or
   keyboard-interactive-only logins are not supported. The host key must be Ed25519 or ECDSA.
2. **mosh-server** installed and on the PATH of a non-login shell. If it is somewhere else (for
   example Homebrew's `/opt/homebrew/bin`), put its path or folder in the host's "Server path"
   field. The app is built and tested against mosh 1.4.0.
3. **A UTF-8 locale** on the server. The app passes `LANG=en_US.UTF-8` unless the host's
   "Locale" field says otherwise; `locale -a` lists what the server has.
4. **UDP open** from the phone to the server: mosh's documented range is 60000 to 61000
   (mosh-server 1.4.0 picks a port from 60001 to 60999), or the range set in the host's
   "UDP ports" field. Each open session holds one port while its server runs.

## Using the app

- **Add a host:** "+" on the Hosts screen. Name, host, SSH port and user; the rest is optional.
- **First login:** the app shows the host's key for confirmation and asks for the password if
  its own key is not yet accepted. After a password login it offers "Install my key on this
  host", which adds its public key to `~/.ssh/authorized_keys`. The public key is also under
  "Keys" on the Hosts screen, to copy or share.
- **Sessions:** a tap on a host starts a session; a host with sessions shows a "+" to start
  another. "Hosts" (back) goes to the list and keeps the session; a tap on its row returns to
  it. To end a session, exit the shell, use "End Session" behind the "…" button, or swipe its
  row.
- **Start command:** set the host's "Command" to `tmux new -A -s main` (a preset) to land in the
  same tmux session every time.
- **Help** under Settings covers the key bar, copying from the server with OSC 52 (tmux and
  neovim set-up), and local echo.

## Messages and what to do

| Message | What to do |
|---|---|
| "mosh-server was not found on the host. ..." | Install mosh on the server, or set the host's "Server path" |
| "mosh-server needs a UTF-8 native locale to run." | Set the host's "Locale" to one that exists, for example `C.UTF-8` |
| "The server started, but no reply arrived on UDP port ... within 15 seconds. UDP is blocked." | Open the UDP range in the server's firewall and any firewall in front of it, or set "UDP ports" to a range that is open |
| "No free UDP port on ... in ..." | End a session on that host, or widen "UDP ports" |
| "The host key has changed. The connection was refused." | If you know why (the server was reinstalled), use "Forget Host Key" in the host's settings and connect again |
| "The host offers only RSA host keys. They are not supported." | Add an Ed25519 host key on the server (`ssh-keygen -A`, then restart sshd) |

## Known limits

- mosh only: no plain SSH shell, no file transfer, no port forwarding.
- No scrollback on the phone (mosh sends the current screen only); use tmux's.
- A session resumes only at the address it was started on.
- If the app crashes while on screen, that session is not resumed; a new one starts.
- The current list for each version is in [CHANGELOG.md](CHANGELOG.md).

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: the app collects nothing and talks only to the servers
you add.

## Source code and licence

iOS-mosh is free software under the GNU General Public License, version 3 or later
([LICENSE](LICENSE)). Parts are ported from mosh, which is also GPL version 3.

The source code is at https://github.com/trickv/ios-mosh
