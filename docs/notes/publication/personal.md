# Personal and infrastructure details: what a public repository would show

> Addresses, ports and details of the author's own network were removed before publication.
> Line numbers below are those of the files before that redaction; some now point a line or two off,
> or into a passage that was removed.

Audit of 2026-11-24, read only. It covers every tracked file at `main` (621 files) and the
whole history of all branches (`git log --all`, 305 commits: `main`, `cloud-work`, `wt/*`).
The two long logs (`docs/CLOUD.md`, `docs/MAC.md`) were read through, with greps for the
markers below on their later entries. All other files were checked by pattern: names,
e-mail addresses, phone numbers, IPv4 and Tailscale IPv6 addresses, host and device names,
domains, home-directory paths, Apple identifiers (team, key, UDID, UUID, profile,
certificate), private-key and certificate headers, other repositories, and usage and model
words. It also covers commit authors and every commit message. No value of a secret or of a
private detail is written here: findings give the file, line or commit and the kind of thing.

## Short answer

- **No secret is in the repository or its history.** There is no private key, certificate,
  provisioning profile, API key or key id, issuer id, team id, keychain password, phone UDID,
  `App/Signing.xcconfig`, `scripts/mac.env` or `out/smoke/host.env` in any tracked file or in
  any commit. Only the app icon ever existed as an image. The scripts read the secrets from
  `charlie:~/signing/` at run time and mask identifiers in what they print.
- **One blocker: the owner's personal e-mail address** is the author and committer address of
  245 of the 305 commits. It appears in no file. In a public repository anyone can read it
  with `git log` or the `.patch` view of any commit. Editing files does not remove it. Only a
  history rewrite or a fresh repository does.
- **A great deal about his machines and habits** is in the working logs and research notes:
  host names, Tailscale and LAN addresses, which services listen where, an old OS on one of his
  hosts, his other repositories, his usage limits and sleep and work times, and his words to the
  agents. None of it gives a stranger a way in. Together it is a detailed map for someone who
  already has a foothold, and it is private. Nearly all of it sits in files that are only
  working logs.

## Findings by kind

| # | Kind | Where (rough count) | What a stranger learns | To remove |
|---|---|---|---|---|
| 1 | **Owner's personal e-mail address** | Author and committer of 245 commits (244 his own, plus the first one, committed by GitHub). Not in any file | His private address | History rewrite (mailmap to his GitHub noreply address) or a fresh repository. **Blocker** |
| 2 | Owner's full name | Commit authors. As first name only ("Trick") in 17 files, 194 lines, and in 13 commit messages | His name, which he wants in the copyright line anyway | Nothing to do: chosen |
| 3 | Tailscale addresses of his machines | `docs/research/07-local-pipeline.md` §1 and §8 (yellow's IPv4 and its tailnet IPv6, charlie's, the iPhone's); `docs/research/14-revised-plan-review.md:24` (charlie). `Tests/MoshBootstrapTests/BootstrapErrorTests.swift:18,33,201`: a real tailnet address of another of his machines, used as a test value | The machines' addresses on his tailnet. They can only be reached from inside his tailnet, so they are not usable from outside | Edit the docs. Replace the test value with a made-up 100.64/10 address. Both stay in history unless it is rewritten |
| 4 | LAN address, interfaces and open services of yellow | `07-local-pipeline.md:7, 201-209, 368, 420-427`: LAN address, sshd and firewall state, listening ports, Docker version, CPU and RAM, OS release [network details removed for publication] | His home LAN layout and how yellow is secured | Edit or drop the file. History keeps it |
| 5 | Host names | `yellow` (24 files, 346 lines), `charlie` (23 files, 259 lines), `hg` (15 files, 56 lines), `<the phone's tailnet name>` as the tailnet name of the phone (3 files, 11 lines), the phone's device name (`docs/MAC.md:688, 1004`) | The names of his Linux box, his Mac, another Linux host and his phone | Too many places to edit (and they are in scripts and defaults: `scripts/mac.sh` defaults `MAC_HOST` to `charlie`). Harmless on their own: keep them, or use a fresh repository without the logs |
| 6 | Software age on his host `hg` | `docs/CLOUD.md:733-740, 760`; `docs/MAC.md` 2026-11-21 02:45 entry; `docs/notes/multi-session/BRIEF.md:64` | `hg` runs an old Debian with an old kernel and the distribution's mosh 1.2.x (release and kernel removed for publication) | Edit those entries. History keeps them |
| 7 | User names and home paths | `trick` as the login on yellow and charlie (`14-revised-plan-review.md:25,28`, test fixture `Tests/MoshBootstrapTests/IdentityCheckTests.swift:17,52`), `/home/trick/...` (5 files, 23 lines: `docs/PLAN.md`, research 10, 11, 14), his plan file under `~/.claude/plans/`, Claude scratch paths with session ids (review notes), the path of a local helper that finds a running ssh-agent (`scripts/mac.sh`, `scripts/deploy.sh`, `docs/BUILD.md:54`; now read from the untracked `scripts/mac.env`), `~/.ssh/ios-mosh-charlie`, `~/signing/` with its file names | His login name. **[account details removed for publication]** (`14-revised-plan-review.md:28`, `11-plan-review.md:321`). A dedicated SSH key exists for charlie, and the layout of the signing directory is described (names only) | Docs: edit. Scripts: the paths are defaults and are fine. The account line is worth removing |
| 8 | Domain and service names | `<subdomains of the author's domain>` on his server, how they are deployed, and the names of three small services of his (`07-local-pipeline.md:183-189`). The bundle-id prefix `us.v9n.` and an older prefix built from his surname (`07:79, 197`) | His domain, the sites on it, and their names | Bundle ids are public on the App Store anyway: keep. The service list and the older prefix: edit file 07 |
| 9 | His Apple developer account | Bundle ids `us.v9n.ios-mosh` and `.dev` (about 90 lines, unavoidable), profile names `ios-mosh-appstore` and `ios-mosh-dev-app` (6 files), App ID name, device registered as "<first name> iPhone" (`scripts/mac-signing-setup.sh:80`, `docs/PLAN.md:707`), "the team's third and last distribution certificate slot" (`docs/BUILD.md:207`), the tester group "Internal" with the account holder. Team id, key id, issuer and UDID: **none** anywhere | How his signing is set up, with no value that can be used | Nothing needed. The certificate-slot line is optional |
| 10 | His other projects and accounts | `docs/research/07-local-pipeline.md` (55 lines), `10-first-design.md` (14), `11-plan-review.md` (15), `14-revised-plan-review.md` (8), `13-charlie-pipeline-facts.md` (2), `docs/PLAN.md` (3): names and contents of his repositories (one Cordova app, one native app said to be public, one private React Native app, one more app, his fork of an upstream project), their workflow files, secret **names** (no values), run ids and dates, an Android package id, his runner minutes | The names of private repositories and how his release pipelines work | Edit or drop the research notes. History keeps them |
| 11 | His Claude usage, plan and model names | `CLAUDE.md:36-54` (5-hour and weekly caps, "I will be sleeping", a "reset coupon"), `docs/CLOUD.md` (figures in about 15 entries, "Fable" 10 lines), `docs/MAC.md` §1, `scripts/usage-watch.sh`, commit messages (`Cap usage at 40%...`, `Record that the weekly usage cap is lifted`) | His subscription's limits, how much of it this project spent, model names | Edit CLAUDE.md and the logs. The commit messages stay unless history is rewritten |
| 12 | Working hours and time zone | Every log entry is timed in UTC: phone sittings at about 02:00-03:00 UTC, "the night of 2026-11-22", "give times in US Eastern Time" (`CLAUDE.md:61`, commit "Give times to Trick in Eastern Time") | When he works and sleeps, and his time zone | Edit CLAUDE.md. The log times are inherent to the logs |
| 13 | Private exchanges with his agents | His quoted words (`CLAUDE.md:30-44`, `docs/CLOUD.md:743-761`, `docs/notes/multi-session/BRIEF.md:8-18`), his decisions, his reports from the phone, "Trick DMs" on Slack in `docs/PLAN.md:662-682`, the plan's addresses to him ("Trick can stop reading here", PLAN.md:139) | How he works with Claude. Harmless but personal | Edit or leave out the logs and CLAUDE.md. BRIEF.md reads fine as a product brief |
| 14 | Other people | None. The only third-party addresses are licence and upstream contacts (a font author in `App/Fonts/licenses`, mosh's mailing list) and the `alice@` and `bob@box.example` test values | - | - |
| 15 | Phone number, street address | None found, in files or in history | - | - |
| 16 | Test fixtures | `Tests/MoshTerminalTests/Corpus/*` and `Tools/mosh-oracle/recordings/*` were recorded in the container: no host, user, path or address in them | - | - |

## Could a stranger use any of it against him?

- **No credential and no way to log in is published.** There are no passwords, keys, tokens or
  signing material. Session keys of the throwaway test servers were kept out on purpose
  (`docs/MAC.md`, 2026-11-20 06:28 entry; `scripts/sim-test.sh` fails a run that keeps one).
- **The addresses are not reachable from the internet.** They are inside his tailnet or his
  home LAN (checked locally on yellow, read only). Nothing was probed from outside.
- **What helps an attacker who already has a foothold** (on his LAN or tailnet, or with one of
  his accounts): [network details removed for publication] This point listed which details of
  his hosts' sshd, firewall, accounts, OS age and public domain the notes gave away. None of it
  is a hole in itself. It is reconnaissance worth keeping private.
- **No pattern of secrets.** The scripts name only file names (`~/signing/kc.pass`, `udid`,
  `asc.json`). These say where the secrets sit on charlie, which matters only to someone who is
  already on charlie as his user.

## Choices for the owner

1. **Publish as it is.** No work. His personal e-mail goes public in 245 commits. So do the
   whole infrastructure map, his other repositories' names, his usage and sleep pattern, and
   his notes to the agents. **Not recommended**, because of the e-mail alone.
2. **Edit named files, then publish this repository.** Edit or remove `docs/research/07`,
   `10`, `11`, `13`, `14`, `docs/CLOUD.md`, `docs/MAC.md`, `CLAUDE.md` (status and usage
   parts), and the Tailscale test value in `BootstrapErrorTests.swift`. **This alone is not
   enough**: every removed line, and the e-mail, stay in the history. To fix that, rewrite the
   history: `git filter-repo` with a mailmap (his address to his GitHub noreply address),
   `--replace-text` for the addresses and names, and `--path ... --invert-paths` for the logs.
   Then force-push `main` and the other branches. Costs: every commit id changes, so the many
   commit ids quoted in the docs and the TestFlight build notes point nowhere. Every clone must
   be replaced: yellow's, charlie's (`~/src/github.com/trickv/ios-mosh`) and the worktrees. It
   needs a force-push, which the project's rules forbid without his word. The build-number rule
   (commit count) survives if no commit is dropped. GitHub may keep the old commits reachable
   through cached views and pull request #1 until they are purged by GitHub support.
3. **A fresh public repository, without the history and without the working logs.** Make a new
   repository with one first commit, authored with his GitHub noreply address. Put in it: the
   package, app, tests, tools, scripts, `LICENSE`, `README.md`, `CHANGELOG.md`, `docs/BUILD.md`,
   `docs/SERVER-SETUP.md`, `docs/RESUME.md` and probably `docs/PLAN.md` and the design notes
   once trimmed. Leave out: `docs/CLOUD.md`, `docs/MAC.md`, `docs/research/`, the review and
   step logs under `docs/notes/`, and CLAUDE.md's status part. The private repository stays as
   the archive. Costs: the public history starts at that commit. Either the work moves to the
   new repository (new clones on yellow and charlie, a new `origin`) or the two repositories must
   be kept in step. Build numbers from the new repository's commit count would start low, but
   `App/fastlane/Fastfile` already takes one above the newest upload, so TestFlight is not
   affected. The new repository's own commits must also use the noreply address
   (`git config user.email`).

**What I would do: option 3.** It is the only one that removes the e-mail and the logs with no
force-push in the existing repository and no risk to the clones the agents work in. The logs
are worth keeping, but privately. Before the first public commit, run the same scans as this
audit on the new tree. Whichever option he takes, set GitHub's "Keep my email addresses private"
and "Block command line pushes that expose my email" so that later commits do not bring the
address back.
