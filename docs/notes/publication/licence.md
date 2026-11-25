# Licence position of iOS-mosh (GPLv3, mosh port, TestFlight / App Store)

Written 2026-11-24 from the checkout at `main` (in step with `origin/main`), the mosh 1.4.0
copy in `.refs/mosh` (tag `mosh-1.4.0`), the package checkouts in the dev container's
`.build/checkouts`, and the Xcode build tree and release archive on charlie (read only).
What I ran and read is in `out/yellow/store/licence-*.txt`.

I am not your lawyer, and this is not legal advice. It is a careful reading of the licence
texts against what is in the repository and the app.

## Short answer

- **No full line-by-line source review is needed.** What GPLv3 needs here is a provenance
  check: which code comes from where, and under which terms. This note is that check. Everything
  that ships in the app is GPLv3 or compatible with it: mosh-derived code (GPLv3+), your own
  code, Apache 2.0 Swift packages, MIT SwiftTerm, and fonts under MIT, OFL, CC BY, Apache and
  the Unlicense. Nothing has to be removed or rewritten.
- **What is missing is paperwork, not code:** the GPL text inside the app, the full MIT and
  Apache notices of the libraries, mosh's copyright notice on the ported files, your own App
  Store permission, and access to the source of each released build. Today the About screen
  links to `https://github.com/trickv/ios-mosh`, which is private, so the link does not work
  for anyone but you.
- **Going public has two practical costs.** Your commits carry a personal (non-noreply) email
  address (see "Before the repository is public"). And from then on every App Store or TestFlight
  build must be traceable to a public commit. Neither is a reason not to do it. The first one needs
  a decision.

## 1. What the repository says about its own licence

| Place | What it says |
|---|---|
| `LICENSE` | The full GPLv3 text, unmodified. It is the current FSF copy: it differs from mosh's `COPYING` only in `http` versus `https` in three URLs. There is no copyright line of the project and no "or later" statement in the file itself. |
| `README.md` | "Licence: GPL-3.0-or-later. Parts are ported from mosh (GPLv3)." |
| Source files | **No file has a licence or copyright header**, and none has an SPDX line. The mosh-derived files say "Port of mosh 1.4.0 ..." with the mosh file names (list in section 2), but they have no copyright notice. |
| `Package.swift` | No licence information (SwiftPM has no field for it). |
| `App/project.yml` | Copies `App/Fonts` (fonts and `licenses/`) into the app. No other licence file is a resource. |
| App, Settings > About (`App/IOSMosh/TextPageViewController.swift:117-151`) | Version, build and git sha; "Source code: https://github.com/trickv/ios-mosh"; "Copyright the iOS-mosh authors." followed by the standard GPLv3-or-later notice and no-warranty sentence, with a link to gnu.org; "The protocol and terminal code follow mosh (https://mosh.org), GPL version 3."; "Built with" naming SwiftTerm (MIT) and the Apple packages (Apache 2.0) by name only; then the font notice and **all font licence texts in full** (`TerminalFont.licencePage`, read from `Fonts/licenses/` in the bundle). |

So the app shows a GPL notice but not the GPL text itself. It does not show SwiftTerm's MIT
notice, the Apache NOTICE texts or mosh's copyright holders. The copyright holder is given only as
"the iOS-mosh authors".

Git authors (`git log --format=%an`): "Patrick van Staveren" (170 commits), "Claude" (60),
"Trick van Staveren" (1). First commit 2026-11-12. There are no tags.

## 2. What is derived from mosh

### Files that say they port mosh 1.4.0 (they ship in the app)

| Area | Files | mosh source named |
|---|---|---|
| Terminal emulation | `Sources/MoshTerminal/{Parser,Dispatcher,TerminalFunctions,Emulator,Framebuffer,Cell,DrawState,Renditions,TerminalState,UserInput}.swift` | `src/terminal/parser*.{cc,h}`, `terminaldispatcher`, `terminalfunctions`, `terminal`, `terminalframebuffer`, `terminaluserinput` |
| Display diff | `Sources/MoshTerminal/DisplayDiff.swift`, `SurfaceFeed.swift` | `terminaldisplay*.cc`, `statesync/completeterminal.cc` |
| Prediction (local echo) | `Sources/MoshTerminal/Prediction.swift` (824 lines) | `src/frontend/terminaloverlay.{h,cc}` |
| Transport | `Sources/MoshTransport/TransportCore.swift`, plus constants in `TransportTypes.swift`, `MoshConnection.swift` | `network.cc`, `networktransport-impl.h`, `transportsender-impl.h`, `stmclient.cc` |
| Wire format | `Sources/MoshWire/WireConstants.swift` (constants copied from `network.h` and others), and the wire files `Packet`, `Fragment`, `Instruction`, `HostMessage`, `UserMessage`, `Compressor` (they reimplement `transportfragment.cc`, `compressor.cc` and the `.proto` schemas) | as named in each file |
| Session glue | `Sources/MoshSession/{TerminalRemoteState,ClipboardPolicy}.swift`, `Sources/MoshBootstrap/ConnectLineParser.swift`, `App/IOSMosh/PortRangeFull.swift` | `completeterminal.cc`, mosh's `MOSH CONNECT` line, the port range message |

The mosh source files concerned all carry the same header: "Copyright 2012 Keith Winstein",
GPL version 3 or (at your option) any later version, **plus an OpenSSL linking exception**
("you may extend this exception to your version of the file(s), but you are not obligated to
do so. If you do not wish to do so, delete this exception statement"). The Swift port links no
OpenSSL, so dropping the exception is allowed and costs nothing. Say so once (section 5).

### Not derived from mosh code

- `Sources/MoshCrypto/OCB3.swift` says it is written from the pseudocode of RFC 7253. It is not
  ported from mosh's `ocb_internal.cc`, which is under Ted Krovetz's ISC-style licence and would
  be fine anyway. (The OCB patents carry a GPL patent grant in mosh's `ocb-license.html`.
  Rogaway has also since released the OCB patents for general use. I did not check that last
  point against a primary source here.)
- `AESBlock.swift` uses CommonCrypto (an iOS system library, outside "Corresponding Source").

### Tests and tools (in the repository, not in the app)

- `Tools/mosh-oracle/{main.cc,predict.cc}` and `Tests/MoshTerminalTests/Support/moshref.cc`
  **link mosh's own built libraries** and say "licensed like mosh (GPLv3+)". That is right. They
  are GPL works in the repository and are never shipped.
- `Tests/MoshCryptoTests/MoshOCBVectors.swift`: "Generated once from mosh 1.4.0
  src/tests/ocb-aes.cc" (that file is "Copyright 2012 Keith Winstein", GPLv3+). These are test
  vectors under the same licence as the repository. That is fine. It should carry the mosh
  copyright line like the ported files.
- `Tests/MoshTerminalTests/Corpus/*`: output of `mosh-oracle` (mosh's emulator run on recorded
  sessions of bash, vim, htop and the like in the dev container). It is data produced by a GPL
  program, kept in a GPL repository, so there is no issue. A grep found no owner names or host
  names in it.
- `docs/` quotes mosh source in places (for example `docs/notes/m10/mosh-prediction.md`). That
  is GPL material inside a GPL repository, so it is fine.
- `.refs/` (mosh, SwiftTerm, swift-nio-ssh clones) is **gitignored and untracked**. Nothing of
  it would be published.

### What mosh's licence files ask

`.refs/mosh/COPYING` is the plain GPLv3. `.refs/mosh/COPYING.iOS` says, in full:

> The Mosh developers are aware that the terms of service that apply to apps distributed via
> Apple's App Store services may conflict with rights granted under Mosh's license, the GNU
> General Public License, version 3. The Mosh copyright holders do not wish this conflict to
> prevent the otherwise-compliant distribution of Mosh-derived apps via the App Store.
> Therefore, we have committed not to pursue any license violation that results solely from
> the conflict between the GPLv3 and the Apple App Store terms of service. In other words, as
> long as you comply with the GPL in all other respects, including its requirements to provide
> users with source code and the text of the license, we will not object to your distribution
> of Mosh through the App Store.

What exactly that gives:

- **It is a promise not to enforce, not a section 7 licence term.** It does not change the GPL.
  It says the mosh copyright holders will not act on the one kind of violation that comes only
  from Apple's terms. Those terms are the Usage Rules that limit copying and redistribution, and
  they clash with GPLv3 section 10, "You may not impose any further restrictions".
- **It covers the mosh copyright holders' code only**: mosh itself and what is derived from it
  ("Mosh-derived apps"). It says nothing for code whose copyright someone else holds, which
  here means **your own code**.
- **It covers the App Store.** TestFlight runs on the same Apple services. Reading it as covering
  TestFlight is reasonable, but the text does not name TestFlight.
- **It has a condition: comply with the GPL in every other respect.** The text names two
  things: **source code** and **the text of the license** for users. Both are missing today.

## 3. Third-party components

### Swift packages

The package's `Package.resolved` and the Xcode build on charlie
(`DerivedData/IOSMosh-*/SourcePackages/workspace-state.json`) resolve **the same 12 pins**. The
licences come from each checkout's own LICENSE file in `.build/checkouts`.

| Package | Version | Licence | In the iOS app? | Compatible with GPLv3? |
|---|---|---|---|---|
| SwiftTerm | 1.99.3 (exact) | MIT (Miguel de Icaza; xterm.js authors; SourceLair; Christopher Jeffrey; Ryan L McIntyre) | yes | yes. MIT requires the copyright and permission notice "in all copies or substantial portions": **not shown in the app today** |
| swift-nio | 2.105.0 | Apache 2.0, NOTICE.txt (lists llhttp MIT, FreeBSD sha1 BSD-3, cpp_magic MIT, and others) | yes (NIOCore, NIOPosix) | yes (FSF: Apache 2.0 is GPLv3-compatible). Apache 4(d): NOTICE text must reach users: **missing** |
| swift-nio-ssh | 0.15.1 (exact) | Apache 2.0, no NOTICE | yes | yes |
| swift-nio-transport-services | 1.28.0 | Apache 2.0, no NOTICE | yes | yes |
| swift-crypto | 5.1.1 | Apache 2.0, NOTICE.txt (wycheproof vectors, SwiftNIO). On Apple platforms `Crypto` uses CryptoKit, and BoringSSL is built only for non-Darwin (`Package.swift:140`) | yes (`Crypto`) | yes, same NOTICE point |
| swift-asn1 | 1.7.4 | Apache 2.0, NOTICE.txt | probably, through swift-crypto/nio-ssh (I did not inspect the linked binary) | yes |
| swift-atomics 1.3.1, swift-collections 1.7.6, swift-system 1.8.1 | | Apache 2.0 **with the Swift Runtime Library Exception** (no attribution required for compiled-in use) | yes (through swift-nio) | yes |
| swift-png 4.5.2, h 1.0.1 | | Apache 2.0 (with NOTICE) | **no**: SwiftTerm uses them only on Linux, Windows, WASI and Android | n/a |
| swift-argument-parser 1.8.2 | | Apache 2.0 + RLE | **no**: only SwiftTerm's `termcast` tool | n/a |

There is no GPL-incompatible package. The only work is showing the notices.

The Xcode project is generated and gitignored. Its own `Package.resolved` is not in the
repository, and the ranges in `Package.swift` (`from: "2.80.0"`, `"3.0.0"..<"6.0.0"`,
`from: "1.20.0"`) allow a newer resolve. It matched this time, but nothing in the repository
records which versions a given release was built with. That matters for "the source of exactly
this build" (section 4).

### Fonts (`App/Fonts`, shipped as the folder `Fonts`)

Hack Nerd Font Mono 3.003 from Nerd Fonts v3.5.1, unmodified (SHA-256 sums in `App/Fonts/README.md`).

- Licences: Hack is MIT plus the Bitstream Vera License (the font is renamed, as Vera requires).
  Nerd Fonts' own work is MIT/OFL 1.1. The glyph sets are MIT, CC BY 4.0 (Codicons, Font Awesome
  icons), Apache 2.0 (Material Design Icons), OFL 1.1 (Pomicons with RFN, Weather Icons) and
  the Unlicense (Font Logos).
- **All 18 licence texts are in `App/Fonts/licenses/`, ship in the app and are shown under
  About.** That is right as it is. The fonts are separate files, not part of the GPL program,
  and the app says so ("not covered by this program's GPL licence").
- A small point that needs no action: CC BY 4.0 forbids applying "Effective Technological
  Measures" that restrict recipients. App Store FairPlay encrypts the executable, not resource
  files such as fonts, so the CC BY glyphs are not under DRM.

### Generated tables

- `Sources/MoshTerminal/WCWidthTable.swift` is generated by `scripts/gen-wcwidth.c` from
  glibc 2.39's `wcwidth()` in the dev container. It records the width of each code point. glibc's
  width data is itself derived from the Unicode Character Database, which is under the permissive
  Unicode licence. The table is a set of facts produced by running a system library, not code
  copied from glibc, so it raises no licence issue. A one-line provenance note is already in the
  file header, which is enough.

## 4. What GPLv3 asks when you convey the app as a binary

"Convey" means giving copies to other people. A TestFlight build used only by you is not
conveying. Testers other than you, and the App Store, are.

1. **Corresponding Source for exactly that build** (section 6). For network distribution the
   usual route is 6(d): offer the source "from a designated place ... at no further charge",
   with "clear directions next to the object code saying where to find" it. The source may be on
   another server, such as GitHub. Option 6(b), a written offer valid for three years, also
   works but is clumsier. In practice:
   - a **public repository with a tag per release** at the commit the build came from;
   - the **About screen** naming that commit or tag (it already shows the sha);
   - the **App Store description or support page** saying where the source is.
   Corresponding Source includes the build scripts (`App/project.yml`, `scripts/mac.sh`,
   `scripts/mac-testflight.sh`, `App/fastlane/Fastfile`, `App/Local.xcconfig`), and all of these
   are tracked. It does not include System Libraries (the iOS SDK, CommonCrypto, CryptoKit).
   For the Apache and MIT packages, naming the exact versions is enough, since their source is
   public at those tags.
   - Verified: **0.2 (229)** was archived from `a489f08` with a clean tree (the archive's
     `Info.plist` on charlie: `IOSMoshGitSHA = a489f08`, no `-dirty`), and `a489f08` is on
     `origin/main`.
   - Not verifiable: **0.1 (189)**. Its archive was overwritten. Commit number 189 is `91942c0`
     (2026-11-21 03:29 UTC), but `scripts/mac.sh` rsyncs the *working tree*, uncommitted changes
     included, and marks such a build `<sha>-dirty`. The About screen of a 0.1 install would show
     which.
   - **Installation Information** (signing keys) is required only when the binary comes with
     the sale or transfer of a "User Product", meaning the phone itself. An App Store download
     is not that, so the signing material on charlie stays private. This is the common reading;
     the FSF has not ruled on this exact case.
2. **The licence text reaches the user** (sections 4 and 6: "give all recipients a copy of this
   License along with the Program"). COPYING.iOS repeats this condition. A link to gnu.org is
   not a copy. The app should bundle `LICENSE` and show it.
3. **Appropriate Legal Notices in the interactive UI** (sections 0 and 5(d)): "an appropriate
   copyright notice", no warranty, that the user may convey the work under this licence, and how
   to view a copy of it. The About page has everything but the copyright notice ("the iOS-mosh
   authors" names no one, and leaves out mosh's holders) and a viewable copy of the licence.
4. **Modified works are marked** (section 5(a)): "prominent notices stating that you modified
   it, and giving a relevant date". Section 4 also says to "keep intact all notices". For a port,
   that means each ported file keeps mosh's "Copyright 2012 Keith Winstein" notice and its GPL
   statement, and adds a line saying it was ported to Swift in 2026. The files have the second
   part ("Port of mosh 1.4.0 ...") but not the first. The OpenSSL exception may be dropped
   (mosh's own text allows it), and saying that it was dropped avoids any doubt.
5. **The App Store conflict.** Apple's Usage Rules add restrictions that GPLv3 section 10
   forbids. For **mosh's code**, COPYING.iOS covers it, provided 1 to 4 are met. For **your own
   code** you are the licensor, and you cannot breach a licence you grant to yourself. You can
   distribute your own work on any terms. But anyone else who builds from your public source and
   ships it through the App Store (a fork, or the "Claude" commits if anyone ever claimed them)
   has no permission from you for the conflict. Blink Shell and VLC solve this with a section 7
   additional permission in their licence file. A text in the style of mosh, for the
   repository and the About page:

   > Additional permission under GNU GPL version 3 section 7: as the copyright holder of the
   > parts of iOS-mosh that are not derived from mosh, Patrick van Staveren permits conveying
   > iOS-mosh and works based on it through Apple's App Store and TestFlight, notwithstanding
   > any conflict between the GPLv3 and the terms of those services, as long as the GPL is
   > complied with in all other respects, including its requirements to provide source code
   > and the text of the license. The mosh-derived parts are covered by the mosh developers'
   > statement in COPYING.iOS.

   (Downstream may remove a section 7 additional permission. That is normal.)
6. **Other contributors.** If the public repository takes outside pull requests, each
   contributor holds copyright in their part and has given no App Store permission. A line in
   `CONTRIBUTING.md` ("contributions are accepted under GPLv3-or-later together with the App
   Store permission in COPYING.iOS") closes that gap.

## 5. What is missing, in the order I would do it

| # | Change | Kind | Needed before |
|---|---|---|---|
| 1 | Copy `LICENSE` into the app (a resource, like `Fonts/licenses`) and show it under Settings > About as a page "GNU General Public License v3". | app (`App/project.yml`, `TextPageViewController.swift`) | the next build given to anyone but you, and any App Store release |
| 2 | Add a "Third-party licences" page that ships SwiftTerm's full MIT notice and `LICENSE`, the Apache 2.0 text (already bundled as `Fonts/licenses/Apache-2.0.txt`, but say it covers the packages too), and the NOTICE texts of swift-nio, swift-crypto and swift-asn1. A `licenses/` folder of copied files (with the versions) is the simplest form. | app + files | same as 1 |
| 3 | Fix the copyright notice. About: "Copyright (C) 2026 Patrick van Staveren. Portions Copyright 2012 Keith Winstein and the mosh authors (https://mosh.org), ported from mosh 1.4.0." Change "follow mosh" to "ported from mosh". Put the same lines in `README.md` and at the head of `LICENSE`, or in a new `COPYRIGHT`/`NOTICE` file. Use the same name and year as the App Store copyright field. | app + docs | App Store release; public repository |
| 4 | Put a header on each mosh-derived file (section 2 list, plus `MoshOCBVectors.swift`): mosh's copyright line, "GPL-3.0-or-later", "Ported to Swift from mosh 1.4.0 src/... in 2026; the OpenSSL linking exception of the original is not carried over." | source comments only | public repository (good practice before the App Store) |
| 5 | Add `COPYING.iOS`: mosh's statement quoted verbatim, followed by your own section 7 permission (text in 4.5). Link it from README and show it in About. | file + app | App Store release; public repository |
| 6 | Make the source reachable for every build already conveyed: tag `v0.2-229` at `a489f08` (verified) and `v0.1-189` at `91942c0` (unverified, see 4.1). Then either make the repository public, or give each TestFlight tester other than you access, or a written offer. Point About at the exact build (`<sourceURL>/tree/<sha>`). | your GitHub (your call, not done here) | App Store release. **Already owed** for 0.1 and 0.2 if any tester other than you installed them |
| 7 | App Store listing: the description (or the support page in the repository) says "Free software under the GNU GPL v3. Source code: <url>". If the listing goes live before the repository is public, that link is dead, so leave it out until the repository is public or the link works. | listing / support page | App Store release |
| 8 | Release guard: `scripts/mac-testflight.sh beta` refuses a dirty tree (other agents edit this checkout at the same time, and `mac.sh` rsyncs the working tree), and each release records its dependency versions. Either commit the Xcode workspace `Package.resolved` or write the resolved list into the release notes or tag message. | script | the next upload |
| 9 | SPDX line (`// SPDX-License-Identifier: GPL-3.0-or-later`) on all own source files; a `CONTRIBUTING.md` line on the licence of contributions. | good practice | — |

### Before the repository is public (not licence, but it decides "any reason not to")

- **Commit email:** the commits by "Patrick van Staveren" and "Trick van Staveren" carry a
  personal address, not a GitHub noreply one (`git log --format=%ae`; I did not print the
  value). Publishing the repository publishes it in every commit. The choices:
  - accept that;
  - rewrite history with `git filter-repo --mailmap`. This changes every sha, so the shas shown
    in the 0.1 and 0.2 About screens no longer match a commit, and tags would need a note of the
    old sha;
  - publish a fresh squashed history from a release commit.
  This is your decision, so I made none of these changes.
- I checked only licence matters. A separate pass for secrets and personal details in the
  tracked files and the history (host names, IPs, logs in `docs/`) belongs before publication.
  The signing material itself is not tracked (`App/Signing.xcconfig` and `scripts/mac.env` are
  gitignored).

## What is already right

- GPLv3 text in `LICENSE`. README states GPL-3.0-or-later and the mosh origin. Both match
  mosh's own "version 3 or any later version".
- The ported files name the mosh files and version they come from, line by line. That is the
  substance of a "modified" notice; only the copyright line and the date are missing.
- The mosh-linking test tools state their GPLv3+ licence and do not ship.
- Every dependency is Apache 2.0 or MIT, so all are GPLv3-compatible. None are GPL-incompatible
  and there are no unknown licences. The pins are identical on yellow and in the Xcode build.
- Fonts: provenance, hashes and all 18 licence texts are in the repository, ship with the app
  and are shown in About.
- OCB3 is written from the RFC. The wcwidth table is generated from glibc output with its
  provenance noted.
- The About screen shows version, build and git sha, so a binary can be matched to a commit,
  and 0.2 (229) matches a clean, pushed commit.
- The GPL notice and no-warranty text are already in the app's UI.
- `.refs/` is not tracked. The signing files are gitignored.

## Could not confirm

- Which Swift package modules are actually linked into the iOS binary (for example swift-asn1).
  This is from the manifests, not from a link map.
- Whether 0.1 (189) was built from a clean `91942c0`.
- Who the TestFlight testers are. If you are the only one, nothing has been conveyed yet.
- The current status of the OCB patents, from a primary source.
