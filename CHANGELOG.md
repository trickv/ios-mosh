# iOS-mosh changelog

What changed in each TestFlight build of iOS-mosh. The section of the version being uploaded is
also the build's "What to Test" text in TestFlight (`App/fastlane/Fastfile` cuts it from here), so
inside a section each item stays on one line and the text stays plain: no "<", no emoji.

## 0.2.1 (2026-11-24)

Licences, privacy and a display fix. Nothing changes in how sessions work.

- Settings, About now shows the GNU General Public License (version 3), the App Store permission (the mosh developers' statement and the author's own additional permission), and a "Third-party licences" page with the licence and notice texts of every library the app is built with.
- About names the copyright holders: the author, and the mosh authors for the parts ported from mosh 1.4.0.
- A new Privacy page in Settings shows the privacy policy. The app also carries Apple's privacy manifest now. As before it collects nothing: its only network traffic is SSH and mosh to the hosts you add.
- In light mode the title and the status bar above the terminal can be read again: they take the terminal's own background and a text colour that contrasts with it.
- Known limits are those of 0.2. One more: with the theme "System" the terminal stays dark in light mode, although the note under the themes says it follows the phone.
- This build was tested on the simulator only.

## 0.2 (2026-11-23)

Several sessions at once, on one host and on several hosts.

- One Hosts screen for hosts and open sessions. Each open session is a row under its host, with its window title (or else the last line on its screen that is not empty), when it was started and when it was last used. A green dot marks the session you looked at last.
- A tap on a host starts a new session there. A host that already has sessions shows a small "+", and a tap on it starts another one. A tap on a session row goes back into that session.
- "Hosts" (back) no longer ends a session: it stays on the server, and its row brings it back. Opening the app goes straight into the session with the dot; when no session has the dot, it shows the list.
- Ending a session: exit or Ctrl-D in the shell ends it and returns to the list; "End Session" behind the "…" button in the terminal (asks once); or swipe a session row for "End Session" or "Forget" (each asks once; Forget removes the row without contacting the host). "End Session" on a session that is not on screen asks its server through mosh to end it.
- When a host's UDP port range is full, the app says so and names the range.
- The first start after the update from 0.1 shows the list once, because the session from 0.1 has no dot yet; a tap on its row goes back into it.

Known limits:

- Sessions that are not on screen show no bell and no badge.
- Typing that the server had not yet confirmed when you went back to Hosts is sent when you open that session again (or end it from its row).
- On a host with an old mosh, where the app cannot learn the server's pid: when the server does not confirm an "End Session", the session is removed although the server may still be running (from a session row at once; from "…" the row reads "Ended, server not yet stopped" until the app next starts, which then removes it).
- Tested on the simulator. On a phone only in part: an earlier test build (Dev build 218, 2026-11-22) had the session rows, the dot and back keeping a session; the "+", opening into the session with the dot, "End Session" on a session row, the port range message and the session's age have not yet run on a phone.

## 0.1 (189, 2026-11-21)

The first TestFlight build. One mosh session to a saved host: log in over SSH with a password or with the app's own key ("Install my key"), and the session survives the app going to the background or being closed by iOS.
Local echo per host (Adaptive, Always or Never), a key bar above the keyboard, and the Hack Nerd Font.
