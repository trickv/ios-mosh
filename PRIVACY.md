# iOS-mosh privacy policy

Effective 2026-11-24. This policy covers the iPhone app iOS-mosh (App Store bundle
`us.v9n.ios-mosh`). It describes what the app's code does; the code is in this repository.

## Summary

- The app collects no data. Nothing you enter or do in the app reaches the developer.
- No accounts, no analytics, no advertising, no tracking, no crash reporting, and no
  third-party services or SDKs that send data anywhere.
- The app connects only to the servers you add, over SSH and mosh, when you start or end a
  session there.
- Everything the app keeps stays on your iPhone.

## What the app connects to

- **Your servers, over SSH** (TCP, the SSH port you set, 22 by default): to log in, to start
  `mosh-server`, to stop the `mosh-server` of a session that could not be resumed or that did not
  answer "End Session" over mosh, and, when
  you choose "Install my key on this host", to add the app's public key to
  `~/.ssh/authorized_keys`. The SSH login sends your user name and either a signature made with
  the app's key or the password you type.
- **Your servers, over mosh** (UDP, the port `mosh-server` reports): your keystrokes, pastes
  and the screen size go to the server, and the server's screen comes back. mosh encrypts this
  traffic with a key that the server hands out for each session.
- **The public key line** the app gives to a server, or that you copy or share from the Keys
  screen, ends in the comment `ios-mosh@` followed by the device name iOS reports to apps (since
  iOS 16 this is the model, such as "iphone", not the name you gave the phone).
- To reach a host by name, iOS looks the name up through the phone's own DNS settings.
- iOS asks for **Local Network** access the first time the app connects to a server on your
  local network; the app uses it only for those connections.

The app makes no other network connections: no web requests, no update checks, no telemetry.
It does not open web pages itself; a link tapped on the Help or About page opens in Safari.

Apart from the app: if you have turned on "Share With App Developers" in the iPhone's
Analytics settings, or you test a TestFlight build, Apple may pass crash reports and feedback
you send to the developer. That is Apple's service, under Apple's privacy policy; the app adds
nothing to it.

## What the app stores on your iPhone

| What | Where | Notes |
|---|---|---|
| Saved hosts: name, host, SSH port, user, server path, locale, UDP ports, start command, per-host options | App files (Application Support) | Part of your iPhone's backups, like other app data |
| Host keys of servers you connected to, with their fingerprints | App files (Application Support) | Part of backups |
| The app's SSH private key (Ed25519, made on the phone) | iOS Keychain, "when unlocked, this device only", not synced | Never shown, never sent, not restored to another phone |
| One mosh session key per open session | iOS Keychain, "after first unlock, this device only", not synced | Removed when the session ends or is forgotten |
| Session records: for each open session, the server's address, user and start command, the last screen of the session, and typing the server had not yet confirmed | App files (Application Support), excluded from backups | Lets a session come back after iOS closes the app. Removed when the session ends or is forgotten |
| Which host each session belongs to, and which session you looked at last | App files (Application Support) | |
| Settings: font size, theme, cursor, tmux prefix | iOS user defaults | |
| A debug log of the app's own events (connection steps, errors), up to about 1 MB | App files (Documents) | Can contain host names, addresses and ports. The app is written never to log keys, passwords or what you type. It is not sent anywhere and the app does not show it in the Files app; it is part of backups |

**Passwords are not stored.** A password you type is used for that login only.

**Clipboard.** A program on your server can put text on the iPhone's clipboard with OSC 52 (a
switch per host turns this off). The app reads the clipboard only when you press Paste, and
sends that text to the session on screen. It never sends the clipboard to a server on its own.

## Deleting your data

- "Delete Host" in a host's settings removes the host; "Forget Host Key" removes its host key.
- Ending a session, or "Forget" on a session row, removes that session's record and key.
- Deleting the app removes its files. iOS may keep an app's Keychain items after the app is
  deleted; if you install the app again, it finds and uses the same SSH key. The app has no
  button that deletes its SSH key.

Data on your servers (for example the key line in `~/.ssh/authorized_keys`, or your shell
history) is under your control there, not the app's.

## Children

The app is not directed at children and collects no data from anyone.

## Changes

Changes to this policy are made in this file; its history is the repository's history.

## Contact

Questions about this policy: open an issue at https://github.com/trickv/ios-mosh/issues
