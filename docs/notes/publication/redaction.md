# Redaction before publication

> Addresses, ports and details of the author's own network were removed before publication.

Done 2026-11-24 on yellow, on the tracked tree of `main`, and committed as `0c9614c`. A final audit
of that tree followed the same day, in four passes; what each still found was removed or repaired
in a commit of its own, and this file describes the tree after all of them. The owner's brief: publish the working
logs, research notes, design notes and `CLAUDE.md`, because they are the interesting part, but
strip "anything like a map of my home network". His name and e-mail stay. No history was
rewritten: the old commits stay as they are in this private repository, and the public copy is
made from the tree alone (last section).

Each document that lost something has this line under its title: "Addresses, ports and details
of the author's own network were removed before publication." Nothing was invented and no fact of
the engineering story was changed; where a value went, a placeholder in angle or square brackets
keeps the sentence true. The list of real values with their places is kept on yellow only, in
`out/yellow/redact/redaction-list.md` (git-ignored), and is never copied anywhere.

## What was removed, and the placeholder for it

| Kind | Placeholder (the same everywhere) |
|---|---|
| Tailnet addresses of the author's machines (IPv4 and IPv6) | `<yellow's tailnet address>`, `<yellow's tailnet IPv6 address>`, `<charlie's tailnet address>`, `<the phone's tailnet address>` |
| LAN address of yellow | `<yellow's LAN address>` |
| A real tailnet address used as a sample "public" address in `Tests/MoshBootstrapTests/BootstrapErrorTests.swift` | `100.64.0.1`, the first address of the Tailscale (100.64.0.0/10) range, so the test still checks that a Tailscale address is not a local network |
| sshd settings, firewall state, listening ports | `[sshd and firewall details removed for publication]`; the host key types of yellow's sshd became "a host key type swift-nio-ssh supports" |
| Account details on yellow (groups, sudo, Docker) | `[account details removed for publication]` |
| Whole passages that were only a description of the network: `docs/research/07-local-pipeline.md` section 8, and the "what helps an attacker" point of `personal.md` | `[network details removed for publication]`, then one sentence saying what the passage listed |
| The exact OS release and kernel of `hg`, and its exact mosh version (also the source line numbers that would pin it) | "an old Debian", "mosh 1.2.x", "the 1.2 release that host's distribution packages" (the fact the story needs stays: an old Debian whose mosh 1.2.x never reports the server's pid) |
| The exact kernel build of yellow, its OS release, and the tmux version read on it | "the running kernel", "tmux 3.x"; where the OS release stood beside yellow's mosh, the sentence now says only that its mosh-server is 1.4.0 |
| Where two checks of the session-row work were made (`docs/MAC.md`: tmux's window title and `/etc/skel/.bashrc`), the example window title in `docs/SERVER-SETUP.md`, which was a host's name, and a tmux version and a distribution release that stood beside them there | the log says what was checked, not where; the title reads `main:0:sh - "<host name>"`; the version and the release were dropped |
| The exact Docker release on yellow | `Docker [release removed for publication]` |
| The distribution package version of mosh on yellow, and the distribution's name beside its 1.4.0 binary, which give the host's OS release away | "the distribution's mosh 1.4.0 package", "the packaged 1.4.0 binary", "the distribution's 1.4.0 binary" |
| The exact macOS patch release of charlie and the exact iOS release of the phone | the major version the build needs: "macOS 26", "iOS 27" |
| A remark on how the dedicated SSH key from yellow to charlie is protected (`docs/PLAN.md` owner steps, `docs/research/14-revised-plan-review.md`, and this file), and the `ssh-keygen` option that shows it | "a dedicated key", `[an option removed for publication]` |
| Log lines of the 2026-11-21 03:05 entry of `docs/CLOUD.md` with a host's details, and two details of that host in the entry itself. The entry still says what was tried and what it proved: "Install my key" on a real host, and the server's pid found there | `[the log lines with that host's details removed for publication]`; "a second host" |
| The author's domain where it names his server, the small services that run on it, how they are deployed there, and which of his machines serves them | `<subdomains of the author's domain>`, `<three small services of the author's>`, `[deployment details removed for publication]`; the machine is not named |
| Names of the author's other repositories and apps, their Xcode project and scheme names, bundle ids, the upstream id of a fork, GitHub run ids, their release tags, branch names, commit ids and a distinctive entitlement of one of them | `<the author's Cordova app>`, `<the author's Swift app>`, `<the author's React Native app>`, `<another of the author's apps>`, `<plugin>`, `<App>`, `<app>` (so `us.v9n.<app>`), `<the upstream project's id>`, `<a run>`, `<a check run>`, `<a release tag>`, `<a release branch>`, `<a commit>`, `<required entitlement>` |
| The phone's tailnet name and its device name, and how the device name is built | `<the phone's tailnet name>`, `<the phone's device name>`; the hint was dropped |
| The ports of the throwaway smoke container (`scripts/smoke-host.sh`) in the logs | `<the smoke ssh port>`, `<the smoke echo port>`, `<the smoke UDP range>`, `<the first port of the smoke UDP range>`, `<a port in the smoke UDP range>`, `<another port in that range>` |
| A detail of his Apple developer team (`listing-state.md`); the lengths of his App Review contact fields | dropped: the note says only that the key can read the team's user list; the lengths were dropped |
| The name of another repository of the author's, standing as a directory in the path of a local helper that finds a running ssh-agent (`scripts/mac.sh`, `scripts/deploy.sh`, `docs/BUILD.md`, `personal.md`) | "a local helper that finds a running ssh-agent"; the scripts read its path from `SSH_AGENT_FINDER` in the untracked `scripts/mac.env` and skip that branch when it is unset |
| A link to a private claude.ai artifact (`docs/notes/multi-session/BRIEF.md`) | `[a private claude.ai artifact; link removed for publication]` |

Three of these placeholders occur nowhere in the tree: `<yellow's tailnet IPv6 address>`, `<yellow's
LAN address>` and `<the phone's tailnet address>` stood only in passages that were removed whole
(section 8 of `docs/research/07-local-pipeline.md`).

Files edited: `README.md` (its opening and the paragraph on the working logs, for a stranger), `docs/research/02-mosh-resume.md`,
`07-local-pipeline.md`, `10-first-design.md`, `11-plan-review.md`, `14-revised-plan-review.md`,
`docs/PLAN.md`, `docs/CLOUD.md`, `docs/MAC.md`, `docs/BUILD.md`, `docs/SERVER-SETUP.md`,
`docs/notes/stage2/DESIGN.md`, `docs/notes/multi-session/BRIEF.md`,
`docs/notes/publication/personal.md`, `secrets.md`, `listing-state.md` and this file,
`Tests/MoshBootstrapTests/BootstrapErrorTests.swift`, `scripts/smoke-host.sh`, `scripts/mac.sh`,
`scripts/deploy.sh`.

## Scripts and their settings

- `scripts/smoke-host.sh` has neutral default ports now (ssh 2222, UDP echo 61000, mosh UDP
  61001-61011) and reads `SMOKE_SSH_PORT`, `SMOKE_ECHO_PORT`, `SMOKE_UDP_LO`, `SMOKE_UDP_HI`,
  `SMOKE_TTL` from `scripts/smoke.env` when that file exists. The file is read line by line (only
  those five names, nothing executed) and a variable already set in the environment wins. On
  yellow it holds the ports used so far, so the script behaves exactly as before. It is not
  tracked: `.gitignore` has the line `scripts/smoke.env`, beside `scripts/mac.env` and the rules
  for signing material.
- `scripts/mac.sh` and `scripts/deploy.sh`: their only host default is the nickname `charlie`,
  and the real settings go in the untracked `scripts/mac.env`. The one change: the path of the
  agent-finding helper is no longer a tracked default but `SSH_AGENT_FINDER` from that file (set
  there on yellow, so the scripts behave as before).
- No other tracked script or config holds an address, a tailnet name or a port of the author's.

## Kept on purpose

- The author's name and e-mail address (his choice), the nicknames `yellow`, `charlie` and `hg`,
  paths under his home directory (except the one directory that named another repository of his), the bundle ids `us.v9n.ios-mosh` and `.dev`, and the Apple
  portal label of his phone (his first name and "iPhone").
- His quoted instructions and the exchanges with the agents, the usage rules and figures, model
  names, the reset coupon, the hours of the work, and everything about how the work was run
  (including that yellow's sessions reach charlie with a dedicated key, and the command the owner
  ran to make it, with the one option removed).
- The engineering facts: mosh 1.4.0 in the dev container and on yellow, the old mosh 1.2.x on
  `hg` and what it means for the server's pid, charlie's macOS major version and its Xcode
  versions, the phone's model and iOS major version, yellow's CPU and memory, the dev container's
  Ubuntu release, and the tmux version of the 2026-11-15 clipboard check that
  `docs/SERVER-SETUP.md` names for its users (made in the cloud session's container).
- Two plan rows say that yellow's password setting was not known at the time (`docs/PLAN.md`
  risks table, `docs/research/10-first-design.md`); they state no setting.
- The names of the documents in the author's Swift app (`APP-STORE-RELEASE.md` and the like) in
  `docs/research/07-local-pipeline.md`: generic names, and the house style the note describes.
- Test values (`10.0.0.x`, `192.168.x`, `100.101.102.103`, the `62700:62799` test range, the
  `ufw` directory name in a terminal recording made in the dev container).

## Making the public copy

1. The redacted tree is committed on `main` here (private): `0c9614c` and the corrections after
   the four passes of the final audit.
2. Check the tree once more right before the copy: run the patterns at the end of
   `out/yellow/redact/redaction-list.md` (on yellow) with `git grep` over the tracked files. Logs
   written after 2026-11-24 (new entries at the end of `docs/MAC.md` and `docs/CLOUD.md`) are not
   covered by this pass and must be read for the same kinds first.
3. Export the tree without the history: `git archive --format=tar main | tar -x -C <new dir>`.
   Only tracked files come out: `out/`, `.refs/`, `.worktrees/`, `scripts/mac.env`,
   `scripts/smoke.env`, `App/Signing.xcconfig` and other ignored files are not in it.
4. In the new directory: `git init`, set `user.name` and `user.email` as the author wants them,
   one first commit, a new public repository, push. The commit messages of this repository (with
   their session links) and every older version of the redacted files stay behind.
5. Keep this repository private as the archive, or move the work to the new one.
