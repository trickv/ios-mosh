# Secrets and credentials in the whole history

> Addresses, ports and details of the author's own network were removed before publication.
> Line numbers below are those of the files before that redaction; some now point a line or two off,
> or into a passage that was removed.
> This audit is dated (2026-11-24, before the redaction). Since then `.gitignore` has the
> defensive rules of point 6 and the line for `scripts/smoke.env`, and the redaction put
> placeholders in place of the other repositories' names (point 3), the private artifact link
> (point 4) and the phone's device and tailnet names (point 5).

Audit of 2026-11-24 (UTC), read only, of `trickv/ios-mosh` at `main` = `0c60dcf`. Question: does any
commit of any branch hold a secret that would become public if the repository is made public?
No value of a secret or personal detail is written here: only the file, the commit and the kind.

## Answer

**No blocker.** No credential of any kind is in any commit: no private key (PEM or OpenSSH), no
App Store Connect key, key id or issuer id, no team id, certificate, profile, keychain password,
phone UDID, Tailscale auth key or token. The real values were checked by exact match, not only by
pattern (section 2). Nothing needs rotating and no history rewrite is needed for secrets.

What is left are smaller things that become public with the history: the owner's email address as
commit author, and notes that describe the home network. They are listed under "Should fix".

## 1. What was scanned

- Refs: `main`, `cloud-work` (both on GitHub; `refs/pull/1/head` on GitHub equals `cloud-work`),
  the local-only branches `wt/boot`, `wt/core`, `wt/oracle`, `wt/term` (10 to 42 commits each that
  are not in `main` and are not on GitHub). No tags, no stash. 305 commits, 1327 distinct blobs
  (40.6 MB), every commit message and every author and committer line.
- Seventeen unreachable objects exist only in the local object store; `git push` never sends them.
- GitHub side (read only): one pull request (#1, merged, its body is a commit message), no
  issues, no releases, no Actions runs, no repository secrets or variables, wiki off.

## 2. Methods

1. **gitleaks 8.21.2** (Docker image, repository mounted read only) over `--all`: 5 hits, all
   rule `generic-api-key`, all false positives (section 3).
2. **trufflehog 3.88.0** (Docker image) over the git history: 0 verified, 0 unverified.
3. **Exact match of the real values, on the Mac.** A corpus of `git log --all -p`, every blob and
   every commit header (55 MB) was copied to the Mac, a script there read the real values from
   `~/signing/` and `App/Signing.xcconfig` and counted matches, case-sensitive and not, then the
   corpus was deleted. Only names and counts came back. Values checked: team id, API key id (from
   the key file name and from `asc.json`), issuer id (from `issuer.txt` and `asc.json`), every line
   of the `.p8` key body, the keychain password, the phone's UDID (as stored, lower case, without
   dash), the development and distribution certificate ids and the `.cer` names, the UUID of each
   of the three provisioning profiles and every device id provisioned in them. **All zero.**
   A control string (the bundle id) matched 767 times, so the search worked.
4. **Patterns over every added line and every commit message** of `git log --all -p`: PEM and
   OpenSSH key blocks, SSH public keys, Tailscale `tskey-`, GitHub, AWS, Slack, Anthropic/OpenAI,
   Google key formats, `password|secret|token|api_key = ...` assignments, team-id assignments,
   `MOSH CONNECT` lines, `MOSH_KEY=`, 22-character base64 (the shape of a mosh session key), iPhone
   UDID shape, UUIDs near "device/udid/identifier", Tailscale and private IPv4 addresses, email
   addresses, phone numbers, street addresses, `*.ts.net` and host names under the owner's domain,
   `ProvisionedDevices`/`DeveloperCertificates`, signing identity strings, long hex strings.
5. **Entropy** over added lines: tokens of 20 or more characters with upper case, lower case and
   digits and Shannon entropy of at least 4 bits per character, outside the terminal corpus: 95
   distinct, all test names, file paths, URLs or the known test values below.
6. **File names and extensions** over `git log --all --name-only` (640 paths ever): no `signing/`,
   `.env`, `*.p8`, `*.p12`, `*.pem`, `*.key`, `*.cer`, `*.mobileprovision`, `*.pcap`, `mac.env`,
   `known_hosts` or `authorized_keys` was ever committed. The only `*.xcconfig` ever committed is
   `App/Local.xcconfig`: its two versions hold only version numbers and `#include?` lines.
   Binary blobs: the four Hack Nerd Font files and the app icon PNG (no text or EXIF chunks).
7. **SSH public keys in tests** compared with the real ones: yellow's `authorized_keys`,
   `known_hosts`, host keys, the Mac's `authorized_keys`, `known_hosts` and host keys, and the keys
   published for the GitHub account: no test key is any of them.
8. **Terminal corpus** (`Tests/MoshTerminalTests/Corpus/*/*.jsonl`, 152 files): all `bytes_b64`
   payloads decoded and joined, then searched for user and host names, home paths, addresses,
   keys and passwords: nothing. The recordings ran in the dev container with host name `golden`
   and a fresh `HOME` (`Tools/mosh-oracle/README.md`); `rec-htop` shows only the container's
   `ubuntu` processes.

## 3. Hits and what each one is

| Commit | Path | Kind | Real or throwaway, and how known | Before publication |
|---|---|---|---|---|
| `87fbbf5` | `App/IOSMosh/DeviceProbe.swift:32` | gitleaks: a Keychain *service name* | not a secret: a reverse-DNS label of the app's smoke probe | nothing |
| `55ff23c`, `2033cef` | `Tests/MoshCryptoTests/MoshOCBVectors.swift:208` | AES-OCB test-vector key | published test vectors; the file says it was generated from mosh 1.4.0 `src/tests/ocb-aes.cc` | nothing |
| `6d845fd`, `c250ee0` | `Tests/MoshBootstrapTests/ConnectLineParserTests.swift:5` | mosh session key (22 base64 chars) | parser fixture; no server ever used it; a mosh key lives only as long as its server process | nothing |
| `55ff23c` | `Tests/MoshTransportTests/TestPeer.swift:35` | mosh session key | key of the in-process test peer on loopback | nothing |
| `55ff23c` | `Tests/MoshWireTests/MoshServerProcessTests.swift:71-76` | a `MOSH CONNECT` line with a key | parser fixture; even if copied from a real `mosh-server`, that key died with its server | nothing |
| `55ff23c` | `Tests/MoshCryptoTests/Base64KeyTests.swift`, `MoshCipherTests.swift` | keys with a visible bit pattern | hand-made test keys | nothing |
| `6d845fd` | `Tests/MoshKeysTests/KeyStoreTests.swift` | Ed25519 secret seed | RFC 8032 test vector 1 (the file names it "rfc") | nothing |
| `6d845fd` | `Tests/MoshKeysTests/OpenSSHPublicKeyTests.swift`, `KeyStoreTests.swift`, `Tests/MoshBootstrapTests/KnownHostsTests.swift` | SSH public keys (ed25519, rsa, ecdsa) and fingerprints | test keys; method 7 shows none is a key of the owner, of yellow, of the Mac or of the GitHub account; public keys in any case | nothing |
| `025113a`, `6d845fd` | `scripts/itest-sshd.sh`, `scripts/itest-mosh.sh` | test user's SSH password | made at run time from `/dev/urandom` inside the throwaway container; the literal in `itest-mosh.sh` is the deliberate wrong password `not-the-password` | nothing |
| `899f3e7` | `docs/research/14-revised-plan-review.md` | UDID-shaped string | the documentation example from Flutter's parser, not a real device; the real UDID is absent (method 3) | nothing |
| `899f3e7`, `7393bf2`, `a57a21f` | `docs/research/07-local-pipeline.md`, `scripts/mac-signing-setup.sh`, `App/fastlane/Fastfile` | names of secrets and of files that hold them (`kc.pass`, `issuer.txt`, `AuthKey_<id>.p8`, the GitHub secret names of another repository) | names only; every value is read from `~/signing/` at run time | nothing |
| `899f3e7` | `docs/research/05-swift-libs.md` | the words `openssh-key-v1` | the format's name in prose, no key block | nothing |

`.gitignore` covers `out/`, `tmp/`, `App/Signing.xcconfig`, `App/Version.xcconfig`,
`scripts/mac.env`, `*.pcap`, `.refs/`, `.worktrees/`, build output. Nothing tracked now matches it
(`git ls-files -ci --exclude-standard` is empty) and no path it covers was ever committed, before
or after the rule was added.

## 4. Should fix (not secrets; decide before publication)

1. **The owner's email address is the author and committer of 245 commits** (all but Claude's 60).
   It is a personal-domain address, not a GitHub noreply one. It is not in any file. It is already
   public: the same address is the author of recent commits in 35 of the 40 public repositories
   of the account checked. Keeping it public needs nothing; hiding it needs a history rewrite of
   both GitHub branches (a `.mailmap` does not change what GitHub shows), and then a force-push.
2. **A description of the home network**, in `docs/research/07-local-pipeline.md` section 8
   (commit `899f3e7`, still tracked): yellow's LAN address, its tailnet IPv4 and IPv6 addresses,
   the tailnet names and addresses of the Mac and the phone, the listening ports, the host
   firewall's state, CPU and memory. Also the tailnet address of the Mac in
   `docs/research/14-revised-plan-review.md:24`, and the tailnet address of another of the owner's
   machines used as a sample "public" address in `Tests/MoshBootstrapTests/BootstrapErrorTests.swift`
   (lines 18, 33, 201). None is reachable from outside the tailnet or LAN, so nothing needs
   rotating; removing them from the tree (and the test using an address such as 8.8.8.8 or
   100.64.0.1) is enough for most owners. Removing them from history too needs a rewrite.
3. The same research note describes the release setup of two other repositories of the account
   (<the author's Cordova app> with a branch name, <the author's Swift app>): the names of their GitHub secrets, not
   values. Harmless if those repositories are public; worth a look if not.
4. **Private links**: 11 commit messages carry a `Claude-Session:` link, and
   `docs/notes/multi-session/BRIEF.md` links a claude.ai artifact marked private to the owner.
   Others cannot open them; they reveal only that the links exist.
5. **Device names**: the phone's device name and its tailnet name appear in `docs/MAC.md`,
   `docs/PLAN.md` and the research notes; home paths `/home/<user>` and `/Users/<user>` appear in notes and one test. Not identifiers Apple uses;
   harmless.
6. **`.gitignore` has no defensive rules** for signing material. Nothing has leaked, but adding
   `*.p8`, `*.p12`, `*.cer`, `*.certSigningRequest`, `*.mobileprovision`, `signing/`, `kc.pass`,
   `.env` would stop a future slip once the repository is public.

## 5. Not checked

- The 17 unreachable local objects (never pushed by any ref).
- Whatever GitHub keeps outside refs (it has never had Actions logs, issues or releases here).
- The App Store Connect app record and TestFlight (not part of the repository).
