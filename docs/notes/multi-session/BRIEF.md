# Several sessions at once: what the owner approved

> Addresses, ports and details of the author's own network were removed before publication.

Trick asked for this on 2026-11-21 and approved the sketch the same day ("ok, build the
multi-connect feature"). This file is the brief for the design and the build: what he sees and
what each action does. It is not the technical design; that comes next, in `DESIGN.md` beside
this file, and must not change anything listed here without asking him.

## What he asked for, in his words

- "I want to be able to run multiple sessions simultaneously. Multiple hosts, and multiple
  sessions per host."
- "When looking at a session, the back button should just go back to the sessions/hosts list
  to switch to another session, or start a new one."
- "Ending a session should be a separate and out of the way button as a pro user will probably
  Ctrl+D more often than not."
- "One pet peeve I've seen in other terminal apps is that open sessions and the list of new
  hosts are separate screens." He wants one screen: "The host list can indent open connections
  below each host; tapping the host name starts anew and tapping the sub-item goes to the
  existing session."

## The approved behaviour

1. **One screen, "Hosts".** Each saved host is a row as today. Its open sessions are rows
   indented under it. Sessions of no saved host keep their own section.
2. **Tap a host: a new session on that host**, also when it already has sessions. A host that
   has sessions shows a small "+" on its row, so that it is plain that a tap starts another one.
   A host without sessions looks as it does today.
3. **Tap a session row: back into that session.**
4. **In a session, "‹ Hosts" goes back to the list and does not end the session.**
5. **Ending a session:**
   - Ctrl-D or `exit` (the server ends the session): the session is removed and the app shows
     the list;
   - "End Session" behind a "…" button in the terminal's navigation bar, asking once;
   - a swipe on a session row: "End Session" and "Forget", as on a host row today.
6. **Sessions that are not on screen are parked** (his choice of two): saved exactly as the app
   saves a session today when it leaves the screen, and resumed when tapped. Only the session on
   screen talks to its server. They keep running on the server. The price, which he accepted: no
   bell and no activity badge from a parked session.
7. **A session row shows what is in it:** the window title if the host set one, otherwise the
   last line on its screen that is not empty, and when it was last used. The rare states say so
   in the row ("Could not be resumed", "Ended, server not yet stopped") instead of taking over
   the screen.
8. **A green dot marks the session he looked at last. Opening the app goes straight into that
   session**, as the app resumes its one session today; if it cannot be resumed, the list.
9. **If iOS kills the app,** parked sessions are untouched, and the one on screen behaves as it
   does today (a kill off screen resumes; a kill on screen falls back to a new session with the
   banner).
10. **Sessions per host are limited by the host's UDP port range** (`60001:60010` allows ten).

The sketch he approved: [a private claude.ai artifact; link removed for publication].

## Added by him after trying the build (2026-11-22)

11. **A session row also shows the session's age.** His words, with two idle sessions on one
    host both reading "last used just now": "it would be useful to differentiate two idle
    sessions like the hg ones by showing their age (how long since started)". So the row's second
    line says how long ago the session was started as well as when it was last used. To build
    after step 13, before the docs and the TestFlight upload.

## To confirm in the code before it is promised

"End Session" on a parked session should end it through mosh's own shutdown (resume it, send the
shutdown, wait for the server's answer), so that it also works on a host where the app does not
know the server's pid (his host `hg`; `docs/CLOUD.md`, entries of 2026-11-21). If the code does
not allow that, say so in the design and ask him.

## His standing rules that bear on this

- Follow mosh's defaults wherever mosh has one, and say so instead of asking.
- No engineering for cases that do not happen to him: he shelved resume stage 2 for that reason,
  and he is not concerned about mosh-servers left running on a host.
- The phone is his: simulator only, and an install only on his word (an install ends the session
  he has open).
- Usage: never above 60% of a 5-hour window, 85% of the week (`CLAUDE.md`).
- Nothing under `Sources/MoshResume` or the transport changes how a record is saved, resumed or
  given up without a hostile review; the failures N1 to N4 stay impossible by construction.

## How it will be built

1. Maps of what exists (the list screen and its tests; every place in the app that assumes one
   session; the calls of `ResumeCoordinator` that parking, the row preview and "End Session"
   need).
2. `DESIGN.md`: a table of every action and event against every state of a session with the
   calls it makes, the changes per file, the tests, and steps that each build and pass alone.
   Two critiques (the screen, tests and plan; the session lifecycle and resume invariants), then
   a revision.
3. The steps, one at a time on the simulator, each checked by a second agent before it is
   pushed. Then a device build, and an install when he says so.
