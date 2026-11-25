# ios-mosh

iOS-mosh is an iPhone terminal that connects with [mosh](https://mosh.org) only. It logs in
over SSH, starts `mosh-server` on the host and then speaks mosh's own protocol, so the session
lives on the server and comes back after iOS suspends or kills the app. The app is on
TestFlight; it is not on the App Store yet.

Where to start:

- [SUPPORT.md](SUPPORT.md): help and how to report a problem.
- [PRIVACY.md](PRIVACY.md): the privacy policy (the app collects no data).
- [CHANGELOG.md](CHANGELOG.md): what changed in each TestFlight build.
- [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md): what a host needs so the app can log in and
  start `mosh-server`.
- [docs/BUILD.md](docs/BUILD.md): how the core is built and tested on Linux and the app on a Mac.
- [docs/PLAN.md](docs/PLAN.md): the design and the plan the work followed.

The code: `Sources/` is MoshKit, the mosh client core (a Swift package, built and tested on
Linux against the real `mosh-server` 1.4.0); `App/` is the UIKit app, with SwiftTerm drawing the
screen.

`docs/CLOUD.md`, `docs/MAC.md`, `docs/research` and `docs/notes` are the working logs and notes
of the coding agents that built the app, kept as they were written. Lines in them such as
"private repo" or "no TestFlight yet" are history, not the present state. The commit ids they
cite name the unpublished history of the private repository, and their `out/...` paths name
logs that were not published, so neither can be looked up here. Addresses and details of the
author's network were removed from them before publication.

Copyright (C) 2026 Patrick van Staveren. Portions Copyright 2012 Keith Winstein and the
mosh authors (https://mosh.org), ported from mosh 1.4.0.

Licence: GPL-3.0-or-later ([LICENSE](LICENSE)). Parts are ported from mosh (GPLv3 or later).
The copyright and third-party notices are in [NOTICE](NOTICE).
The permission to distribute through Apple's App Store is in [COPYING.iOS](COPYING.iOS); how to
contribute is in [CONTRIBUTING.md](CONTRIBUTING.md).
