# Review of the revised plan

> Addresses, ports and details of the author's own network were removed before publication.

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## results

### 1. check:owner-read

**check:** check:owner-read

#### r

##### summary

Reviewed lines 1-92 of /home/trick/.claude/plans/new-project-call-it-harmonic-moon.md only (nothing below "# Implementation reference"). Nothing was modified and ssh was not run.

Verdict on the four checks:
1. His three points: TestFlight is answered clearly, and cycles are answered (two runs, ten milestones internal). "What do you need to ask me" is never answered in so many words, and nothing says what starts Run 1.
2. Setup steps: not all can be done as written. Step 1 fails right now, step 4 has a switch that will not be there yet, step 3 points at a folder that does not exist, and step 5 defers a hand-off that can be done up front.
3. Clarity and promises: "more than one session" hides possible hand-offs. "Complete daily driver" does not say what is untested. "The host's command" and "session list" are undefined.
4. Length: about 90 lines is fine. The Context paragraph and one duplicated bullet can go; the fixes below keep it about the same length.

Facts I checked on yellow (read-only):
- `charlie` resolves through Tailscale to <charlie's tailnet address>, but `tailscale status` showed it offline, last seen 20 minutes earlier.
- `~/.ssh/config` has no Host or User entry for charlie, so `ssh charlie` logs in as `trick`.
- `~/.ssh/ios-mosh-charlie` does not exist yet.
- `mosh-server` is installed on yellow; `swift` is not.
- [account details removed for publication]

Not checked: whether Remote Login is on, what the account name on charlie is, and whether Xcode is installed there. The findings on Wi-Fi installs and on what the simulator covers rest on general knowledge, not on a test.

Sources for the Apple behaviour in findings 2 and 10:
- [Allow USB and other accessories to connect to your Mac](https://support.apple.com/102282)
- [Apple Developer Forums thread 716697 on the missing Developer Mode switch](https://developer.apple.com/forums/thread/716697?answerId=730839022)
- [Capawesome: how to enable iOS Developer Mode](https://capawesome.io/docs/blog/how-to-enable-ios-developer-mode/)

##### findings

###### 1. Lines 46-49, step 1 "SSH key for me" (and its position before step 2)

**severity:** must-fix

**where:** Lines 46-49, step 1 "SSH key for me" (and its position before step 2)

###### problem

The syntax is correct, but the step cannot be carried out as written today. (a) Tailscale on yellow reported charlie offline (last seen 20 minutes earlier), so `ssh-copy-id` will hang and fail; "charlie stays up" is step 2 but has to come first. (b) After that failure, re-running the same line makes `ssh-keygen` ask "Overwrite (y/n)?"; answering n exits 1 and the `&&` skips `ssh-copy-id`. (c) There is no charlie entry in `~/.ssh/config`, so the command logs in as `trick`; it fails if the Mac account has another name. (d) Remote Login on charlie is never mentioned.

###### fix

Move the "charlie stays up" step to position 1 and add to it: "Remote Login must be on (System Settings > General > Sharing > Remote Login)." Then replace the SSH step with:

**SSH key for me.** On yellow, two lines. Replace MACUSER with your account name on charlie, and tell me the name if it is not `trick`:
`[ -f ~/.ssh/ios-mosh-charlie ] || ssh-keygen -t ed25519 [an option removed for publication] -C ios-mosh-agent -f ~/.ssh/ios-mosh-charlie`
`ssh-copy-id -i ~/.ssh/ios-mosh-charlie.pub MACUSER@charlie`
Check: `ssh -i ~/.ssh/ios-mosh-charlie -o IdentitiesOnly=yes MACUSER@charlie true` returns with no prompt.
My sessions cannot use your agent while you are logged out. This key is a dedicated key, used only for charlie.

**confidence:** high

###### 2. Lines 57-58, step 4 "Phone"

**severity:** must-fix

**where:** Lines 57-58, step 4 "Phone"

###### problem

"Then Settings > Privacy & Security > Developer Mode: on" will usually fail: iOS hides that switch until Xcode on a Mac has seen the phone (or a development app has been installed). Plugging in and tapping Trust is not enough. Also missing: on an Apple silicon laptop, macOS asks "Allow accessory to connect?" and Apple says the Mac must be unlocked to approve it, so he has to be at charlie with it unlocked. The passcode prompts are not mentioned either.

###### fix

Replace step 4 with:

**Phone (at charlie, with charlie unlocked).** Plug the phone into charlie with a data cable. If charlie asks "Allow accessory to connect?", click Allow. Unlock the phone, tap Trust and enter the passcode. Open Xcode and choose Window > Devices and Simulators so that Xcode sees the phone; the Developer Mode switch does not exist on the phone until it has. Then on the phone: Settings > Privacy & Security > Developer Mode, switch it on, tap Restart, and after the restart tap Turn On and enter the passcode.

**confidence:** medium

###### 3. Lines 59-60, step 5 "Possibly one sudo line", and line 44 "about 15 minutes"

**severity:** should-fix

**where:** Lines 59-60, step 5 "Possibly one sudo line", and line 44 "about 15 minutes"

###### problem

"Possibly ... I will know after my first look" is a hand-off waiting to happen in the first hour of Run 1, which is what he asked to avoid. The plan also never says Xcode must be installed on charlie. His other app builds through GitHub Actions, so Xcode may not be there, and only he can install it (App Store login, long download). In that case "about 15 minutes" is wrong.

###### fix

Replace step 5 with:

**Xcode.** charlie needs Xcode 16 or later, and not older than the phone's iOS version (App Store; a long download if it is not there yet). Then run this once on charlie, whether or not Xcode was already installed:
`sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
I cannot use sudo on charlie. If anything else needs it I will send you one exact line.

Change the heading to: "What I need from you, once (about 15 minutes if Xcode is already on charlie)".

**confidence:** medium

###### 4. Lines 52-56, step 3 "Signing key"

**severity:** should-fix

**where:** Lines 52-56, step 3 "Signing key"

###### problem

`charlie:~/signing/` does not exist, so a copy to it fails (or creates a file called `signing`). The step does not say where a Team key is made, where the issuer id is found, or that the file name must be kept because it carries the key id. If he no longer has the `.p8` he has to create a new key and is given no path. It also does not say how much an Admin key can do, which he should know before leaving one on disk.

###### fix

Replace step 3 with:

**Signing key.** In App Store Connect: Users and Access > Integrations > App Store Connect API > Team Keys. Use a Team key with the Admin role. The one behind your GitHub secrets works if you kept its `.p8`; Apple lets you download that file once, so otherwise generate a new key. Note the Issuer ID shown above the key list. On charlie:
`mkdir -p ~/signing && chmod 700 ~/signing`
`mv ~/Downloads/AuthKey_*.p8 ~/signing/` (keep the file name: it carries the key id)
`echo 'PASTE-ISSUER-ID' > ~/signing/issuer.txt`
An Admin key can change almost anything in your App Store Connect account. It stays in that folder and never goes into the repo. With it I create the development certificate, register the phone and make the profile myself.

**confidence:** high

###### 5. Line 74, "Run 1 is many hours of agent work, probably over more than one session."

**severity:** should-fix

**where:** Line 74, "Run 1 is many hours of agent work, probably over more than one session."

###### problem

This is the sentence that decides whether "two runs" is true, and it is vague. "Session" is not defined, and it does not say who starts the next one. If he has to come back and type something each time a session ends, Run 1 is several hand-offs, not one, and the column heading "What I do without you" is overstated.

###### fix

Decide which is true and say it. Either:

"Run 1 is many hours of agent work and will not fit in one sitting. When one sitting ends I start the next myself from a scheduled task. You are not asked for anything in between."

or:

"Run 1 is many hours of agent work and will not fit in one sitting. Each time one ends I send you a Slack DM, and the only thing you do is reply 'continue'. Expect that about N times before Build 1."

**confidence:** high

###### 6. Line 66 (Run 1, "What you do") and lines 85-87 (decision on the connect test)

**severity:** should-fix

**where:** Line 66 (Run 1, "What you do") and lines 85-87 (decision on the connect test)

###### problem

Run 1 needs the phone unlocked at least twice (the blank app in the first hour, then Build 1), but the cell reads as one event. It does not say how long the phone must stay unlocked, although the connect test opens the app after the install. Two messages are implied ("a build is waiting", then "ready") without saying so. If the test reaches yellow on its home-network address, iOS will ask for Local Network access during the test, and nobody is told to tap Allow.

###### fix

Replace the Run 1 "What you do" cell with:

"Twice, at home, when I DM you: unlock the phone and keep it awake for about two minutes. The first time (first hour) a blank test app appears. The second time Build 1 installs and opens by itself for a few seconds to run a connect test; if iOS asks to allow Local Network access, tap Allow. After my 'ready' DM, use Build 1 for real work and tell me what is wrong."

Also make the on-phone test connect to yellow by its Tailscale name. As far as I know that traffic does not raise the Local Network prompt, and it is the route he will use on cellular.

**confidence:** medium

###### 7. Lines 3-12 (Context) and the end of "What I need from you" / "Decisions I made for you"

**severity:** should-fix

**where:** Lines 3-12 (Context) and the end of "What I need from you" / "Decisions I made for you"

###### problem

He asked "What do you need to ask me about?" and the page never answers it; he has to infer that the answer is "nothing, I decided". The Context paragraph tells him in the third person what he already knows. Nothing says what starts Run 1, or what happens if he says nothing about the decisions.

###### fix

Replace the Context section with:

## Answers to your three points
- **What I need to ask you:** nothing. I made the open calls myself (see "Decisions I made for you"). I need five set-up steps from you, once.
- **TestFlight:** gone. I build on charlie over SSH and install straight onto the phone.
- **Cycles:** two. The ten milestones are now my own checkpoints. The first thing you test is the full daily-driver build.

You only need to read down to "Implementation reference".

Add after step 5: "When the steps are done, tell me 'go'. If one of the decisions below is wrong, say so then; if you say nothing about them, I go ahead as written."

**confidence:** high

###### 8. Line 16 ("the complete daily driver") and lines 75-76 (Limits, second sentence)

**severity:** should-fix

**where:** Line 16 ("the complete daily driver") and lines 75-76 (Limits, second sentence)

###### problem

"Complete daily driver" is a strong promise, and the hedge sits 60 lines later and is incomplete. It does not say what will have been tested before hand-over. It also leaves out one promised item that cannot be tested without him: resume after a phone reboot needs his passcode. It lists the Local Network prompt as untested, although the connect test on the phone may meet it.

###### fix

Replace the sentence "Things only a phone can show ... expect rough edges there." with the following, adjusted to what the reference's tests really cover:

"Before I call Build 1 ready, everything in 'What you get' will have passed on charlie's simulator, plus one scripted connect on your phone. Three things I cannot test without you, so expect rough edges there: keyboard feel, Wi-Fi to cellular roaming, and resume after a phone reboot."

**confidence:** medium

###### 9. Lines 50-51, step 2 "charlie stays up", and line 42 (third bullet of "Three limits")

**severity:** should-fix

**where:** Lines 50-51, step 2 "charlie stays up", and line 42 (third bullet of "Three limits")

###### problem

"sleep 'never' on the power adapter" names a setting that current macOS no longer shows under that label, so he has to go looking. The step does not say for how long charlie must stay up. The same requirement appears twice (line 42 and step 2).

###### fix

Replace step 2 (and make it step 1, see the first finding) with:

**charlie stays up for the whole of Runs 1 and 2.** On power, lid open, your user logged in (a locked screen is fine). So that it never sleeps on power: `sudo pmset -c sleep 0` (same as System Settings > Battery > Options > "Prevent automatic sleeping on power adapter when the display is off"). Remote Login must be on (System Settings > General > Sharing > Remote Login).

Delete the third bullet under "Three limits" and change the lead-in to "Two limits:".

**confidence:** high

###### 10. Lines 38-41, first two bullets of "Three limits"

**severity:** should-fix

**where:** Lines 38-41, first two bullets of "Three limits"

###### problem

"Plugged into charlie or on the same Wi-Fi" presents the two routes as equal, and "unlocking the phone at home is all you do" depends on the Wi-Fi route working every time. In my experience wireless installs through Apple's device tools fail more often than cabled ones; I did not test this here. Separately, Apple documents that a Mac laptop locked for three days or more may need unlocking before it accepts a USB device again, so "locked is fine" has a limit.

###### fix

Replace the two bullets with:

- The reliable route is the phone plugged into charlie. On the same Wi-Fi it usually works too, once the phone has been paired by cable. If nothing has installed a minute after you unlock, plug it in. Tailscale is not enough for an install.
- The phone must be unlocked while a build installs. I leave an installer waiting on charlie, so normally unlocking the phone at home is all you do. If charlie has sat locked for three days or more, it may need unlocking once before it talks to the phone over the cable.

**confidence:** medium

###### 11. Lines 27-29 ("the host's command"), lines 31-32 and line 67 ("session list")

**severity:** nit

**where:** Lines 27-29 ("the host's command"), lines 31-32 and line 67 ("session list")

###### problem

Two terms are used without being defined. "With the host's command set to `tmux new -A -s main`" does not say what a host's command is or who sets it. "Session list" appears as Run 2 work but not in "Not in Build 1", so he cannot tell whether Build 1 can hold more than one host or session, which matters for daily use.

###### fix

Replace lines 27-29 with the following, if the preset is what the reference does:

"Known gap in Build 1: if the app crashes while it is on screen, the mosh session is lost and the app connects afresh (2-3 seconds). Each saved host has a start command, which I preset to `tmux new -A -s main`, so you land back in the same tmux."

In "Not in Build 1", add whichever is true: "a list of several open sessions (Build 2; Build 1 holds one session at a time)" or "a session list screen (Build 2; Build 1 switches hosts from the connect screen)".

**confidence:** medium

###### 12. Lines 80-82, first decision ("Swift code can be tested on yellow without the Mac")

**severity:** nit

**where:** Lines 80-82, first decision ("Swift code can be tested on yellow without the Mac")

###### problem

Swift is not installed on yellow, and a system install would be one more step for him that the page does not list [account details removed for publication]. It need not be: the toolchain can run in a container or under his home directory. The rationale is also more technical detail than he asked for.

###### fix

Replace the first decision with:

"I write the mosh client in Swift and do not wrap Blink's library (Blink's is the fallback). That lets me test it on yellow without the Mac. Swift runs there in Docker, so there is nothing for you to install."

Make sure the reference uses Docker or a home-directory toolchain on yellow, not `apt`.

**confidence:** high

### 2. check:consistency

**check:** check:consistency

#### r

##### summary

Reviewed /home/trick/.claude/plans/new-project-call-it-harmonic-moon.md (929 lines) read-only. I also checked the template it points at (/home/trick/src/github.com/trickv/<the author's Swift app>/ios/<App>/project.yml and that repo's CLAUDE.md) and the planning outputs named in M0.

What holds: every "section N" reference resolves, including the new section 7. No main-flow text still delivers through TestFlight or GitHub Actions. The Build 1 feature list matches M0-M7. The summary and the reference agree that Trick is first asked to try the app at Build 1. The paths into <the author's Swift app> and the two /tmp files named in M0 exist.

What is wrong falls into four groups:
- **Trick's part inside a run is understated.** The reference says runs need nothing from him, yet M0, M5 and M7 each need his phone unlocked at home. The self-test needs Tailscale on the phone. The phone table expects a scripted checklist that includes rebooting yellow.
- **The M0 phone install is both a hard gate and deferrable.** An unattended session cannot tell whether to block M1-M4 on the phone.
- **The new self-test is under-specified.** As written it can replace or type into Trick's live session from Build 2 on. Its `--smoke` flag, its app hooks and the "Crash now" control are not in any synopsis or milestone.
- **Leftovers from the old model.** M0 converts only the TestFlight-era research files and omits today's devicectl file. The `project.yml` edit list keeps CI version literals and a TestFlight compliance key. M6-M8 rows, two Verification header lines, two Risks rows and the CLAUDE.md "Release pipeline" heading are stale.

Finding 5 (pairing and Developer Mode) rests on the plan's own research notes; I could not test it against a Mac here. In finding 7, the claims that target-level settings beat an xcconfig and that xcodegen stops on a missing source path are from memory, not run.

##### findings

###### 1. Lines 665, 708-709, 660-661, 150-151 (M0 exit test, M0 body, Milestones intro, Approach)

**severity:** must-fix

**confidence:** high

**where:** Lines 665, 708-709, 660-661, 150-151 (M0 exit test, M0 body, Milestones intro, Approach)

###### problem

The M0 phone install is both a hard gate and deferrable. Exit test: "| M0 | Repo, toolchain, pipeline proof | yellow, charlie | `swift test` green on Linux and on charlie; blank app built on charlie, UI test green on its simulator, installed on the phone |". Line 660: "Each milestone ends with its exit test passing." Line 150: "A blank app is built on charlie and installed on the phone before anything else". But the M0 body says: "If the phone is out of reach, carry on and retry; this must pass before M5 is called done." The summary also says "If charlie sleeps or the phone is away, I carry on with the Linux work". An unattended session cannot tell whether M1-M4 may start before Trick has unlocked the phone.

###### fix

Replace the M0 row with: "| M0 | Repo, toolchain, pipeline proof | yellow, charlie, phone | `swift test` green on Linux and on charlie; blank app built and device-signed on charlie, UI test green on its simulator. Install and launch on the phone pass here if the phone is in reach; otherwise they stay queued (`deploy.sh --wait`) and must pass before M5's exit test |". Replace the line 150-151 sentence with: "A blank app is built and signed on charlie first and installed on the phone as soon as the phone is in reach, so signing and device problems show up on day one."

###### 2. Lines 677-678 (Runs intro) against lines 38-41, 59-60, 66 (summary) and 588, 621-622, 634, 697

**severity:** must-fix

**confidence:** high

**where:** Lines 677-678 (Runs intro) against lines 38-41, 59-60, 66 (summary) and 588, 621-622, 634, 697

###### problem

Line 677: "The milestones are grouped into runs that need nothing from Trick once the setup at the top of this file is done". The reference contradicts this and asks for things the summary does not list. (a) Run 1 needs the phone unlocked at home three times: M0 install and launch, the M5 self-test ("Phone: the self-test from section 7 passes"), and Build 1. (b) The self-test connects to "yellow's Tailscale name", so the phone needs Tailscale on; the summary only says "Tailscale is not enough for an install". (c) "ask Trick to run `sudo modprobe sch_netem`" is on yellow; summary item 5 says "Possibly one `sudo` line on charlie". (d) "If that is refused, Trick registers it in the developer portal" is not in the summary. (e) "A phone reboot can need the cable once more" is not in the summary, and the M6 phone row asks him to reboot the phone.

###### fix

Replace lines 677-678 with: "**Runs.** The milestones are grouped into runs. After the setup at the top of this file a run needs only this from Trick: the phone at home (cable or charlie's Wi-Fi), unlocked, with Tailscale on, when a build is waiting. Run 1 asks for that up to three times (blank app in M0, first connecting build in M5, Build 1 in M7). Contingent asks go to him as one literal line each: `sudo` on charlie, `sudo modprobe sch_netem` on yellow, registering the App ID in the developer portal." Replace summary lines 40-41 with: "- The phone must be unlocked while a build installs and for about a minute after, with Tailscale on: I then open the app and run a connect test to yellow. I leave an installer waiting on charlie, so unlocking the phone at home is all you do. Expect this up to three times in Run 1. After the phone restarts it may need the cable once more." Replace summary item 5 with: "5. Possibly one `sudo` line on charlie (Xcode licence or Homebrew) and one on yellow (`sudo modprobe sch_netem`, for the bad-network tests). If Apple refuses to create the App ID through the API, I ask you to register `us.v9n.ios-mosh` in the developer portal."

###### 3. Lines 841-850 (phone table) against line 66 (summary Runs table)

**severity:** should-fix

**confidence:** high

**where:** Lines 841-850 (phone table) against line 66 (summary Runs table)

###### problem

The summary's only test ask is "Use Build 1 for real work and tell me what is wrong". The reference expects a scripted checklist: "Trick does the M5–M7 rows while using Build 1". Row M5 says "deny it once and confirm the error text". Row M6 says "after 10 minutes in the background; after force-quit; ... after a phone reboot with the app in the background. "Crash now" (debug menu) in the foreground shows the banner and lands in the same tmux. Reboot yellow: the app reports "server gone" and reconnects". Rebooting yellow also stops the implementing session.

###### fix

In row M6 replace "Reboot yellow: the app reports "server gone" and reconnects" with "The implementing session kills the `mosh-server` on yellow while the app is in the background (yellow is not rebooted): the app reports "server gone" and reconnects". Append to the Run 1 "What you do" cell on line 66: "With Build 1 I send a ten-minute checklist (force-quit, restart the phone, Wi-Fi to cellular, deny the Local Network prompt once, Crash now). Those paths get no other test on a real phone."

###### 4. Lines 629-639 (Phone self-test) against lines 20-21, 752-754, 848

**severity:** should-fix

**confidence:** medium

**where:** Lines 629-639 (Phone self-test) against lines 20-21, 752-754, 848

###### problem

Line 635: "The app bootstraps over SSH, starts mosh, runs the `hello-42` command, writes the result and timings to `Documents/smoke.json`, and leaves yellow in the host list with `tmux new -A -s main`." The self-test runs before every "build is ready" message. From Build 2 on, the phone holds Trick's backgrounded session to the same host. Nothing says what a `-smokeHost` launch does to a stored record, or whether the smoke session uses the tmux command. As written it can replace his session or type `echo hello-...` into his `main` tmux. That breaks the summary promise "the session comes back after the app was suspended, force-quit or updated" and the M6 check "after a new build is installed over the old one". The debug arguments have a guard ("only when no record exists"); the smoke arguments have none. From M6 on, each smoke run also leaves a record and a `mosh-server` behind.

###### fix

Add a bullet to the self-test: "- The smoke session runs with no remote command (a plain shell, not tmux), keeps its session record in memory only, and ends its own `mosh-server` once `smoke.json` is written. It never reads, replaces or deletes a stored record. If a resumable record exists (any build after Build 1 is in use), `--smoke` only installs and checks that the app launches; "new build over the old one" stays Trick's check."

###### 5. Lines 57-58 (summary item 4), lines 620-627 (section 7 Phone), M0 body lines 698-709

**severity:** should-fix

**confidence:** medium

**where:** Lines 57-58 (summary item 4), lines 620-627 (section 7 Phone), M0 body lines 698-709

###### problem

Summary item 4 puts this in the one-time setup, before any session has reached charlie: "Plug it into charlie once, unlock, tap Trust. Then Settings > Privacy & Security > Developer Mode: on, restart, confirm." The plan's own verification notes (`wels4cgg0.output` in the M0 tasks directory) say "Developer Mode only appears in Settings > Privacy & Security once pairing has been initiated" and "the agent can run `xcrun devicectl manage pair` over SSH meanwhile". The reference has no pairing step anywhere; the word "pair" does not appear in section 7 or M0. Trick may find no Developer Mode switch, and the first pairing is a joint step the summary does not announce. If the phone was already paired with Xcode on charlie, this does not bite.

###### fix

Replace summary item 4 with: "4. **Phone.** Plug it into charlie, unlock, tap Trust and enter the passcode. If Settings > Privacy & Security shows Developer Mode, turn it on, restart, confirm. If the switch is not there, leave the phone plugged in: I start pairing from charlie in the first hour and message you to tap Trust and turn it on then." Add to section 7 "Phone": "- First pairing (M0): with the phone cabled and unlocked, run `xcrun devicectl manage pair` over SSH; Trick taps Trust and enters the passcode. Developer Mode appears in Settings only after pairing has started. Confirm with `devicectl list devices`."

###### 6. Lines 691-693 (M0 first step)

**severity:** should-fix

**confidence:** high

**where:** Lines 691-693 (M0 first step)

###### problem

"(`wy03nl1jh.output`, `w6xc1utub.output`) and will not survive a reboot." Both named files predate today's change. `w6xc1utub.output` is the first design and cites the "TestFlight-only decision". `wy03nl1jh.output` covers "iOS platform/build pipeline, existing local CI". The facts behind section 7 are in `wels4cgg0.output` in the same directory ("Verify facts for building on a Mac over SSH and installing directly to an iPhone (no TestFlight)"). The resume and SwiftTerm reviews are in `wgqm521n1.output` and `wmui2hjiy.output`. None of these three is listed, so `docs/research/` would carry the old delivery model and lose the new one. One other file in that directory (`bwsxjro7a.output`) disappeared between two listings during this review; it may have been a live task's own output.

###### fix

Replace the parenthesis with: "(`wy03nl1jh.output` research, `w6xc1utub.output` first design, `wgqm521n1.output` and `wmui2hjiy.output` resume and SwiftTerm reviews, `wels4cgg0.output` charlie, signing and devicectl facts behind section 7) and will not survive a reboot. The first two predate the 2026-11-12 change: when converting, mark their TestFlight, GitHub Actions and fastlane parts as superseded by section 7."

###### 7. Lines 643-651 (`project.yml` edits), 594-595, 602-605

**severity:** should-fix

**confidence:** medium

**where:** Lines 643-651 (`project.yml` edits), 594-595, 602-605

###### problem

Line 646: "Remove the Sentry package and `SentryDSN`, `CODE_SIGN_ENTITLEMENTS`, `NSPhotoLibraryAddUsageDescription`, `NSAppTransportSecurity` and the post-build git script (the version comes from `Local.xcconfig`)." The template still carries CI and TestFlight parts this list keeps. (a) Target-level `MARKETING_VERSION: "1.0"` and `CURRENT_PROJECT_VERSION: "1"`, commented "CI overrides both on the xcodebuild command line". Target settings take precedence over an xcconfig, so the About page would always show 1.0 (1). (b) `ITSAppUsesNonExemptEncryption: false`, a TestFlight export-compliance answer that is also untrue for an app shipping its own AES-OCB and SSH. (c) The explicit `PrivacyInfo.xcprivacy` source entry; xcodegen stops on a missing source path. (d) The header comment "CI / TestFlight: `bundle exec fastlane ios beta`". Separately, no `configFiles` entry is listed, `Local.xcconfig` is not in the layout table, and it has two writers on two machines: "The team id is read from the profile into a generated, gitignored `Local.xcconfig`" (charlie) and "It writes the commit count and short SHA into `Local.xcconfig`" (`mac.sh` on yellow, where `.git` is). The rsync overwrites or omits one half.

###### fix

Replace the Remove bullet with: "- Remove the Sentry package and `SentryDSN`, `CODE_SIGN_ENTITLEMENTS` and the `.entitlements` exclude, the `PrivacyInfo.xcprivacy` source entry, `ITSAppUsesNonExemptEncryption`, `NSPhotoLibraryAddUsageDescription`, `NSAppTransportSecurity`, the target-level `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` literals, the header comment about CI and TestFlight, and the post-build git script." Add: "- `configFiles` (Debug and Release) on the app target point at the committed `App/Local.xcconfig`, which holds `#include? "Version.xcconfig"` and `#include? "Signing.xcconfig"`. `mac.sh` writes `App/Version.xcconfig` on yellow before the rsync (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` = commit count, `GIT_SHA`). The signing step writes `App/Signing.xcconfig` on charlie (`DEVELOPMENT_TEAM`), and the rsync excludes it. Both are gitignored." Change lines 594-595 and 604 to name those two files, and add `App/Local.xcconfig` to the layout table.

###### 8. Lines 670-673 (milestone table rows M5-M8), 738, 522-523

**severity:** should-fix

**confidence:** high

**where:** Lines 670-673 (milestone table rows M5-M8), 738, 522-523

###### problem

The rows still read as per-milestone phone hand-offs. "| M6 | Resume, stage 1, and server probe | yellow, simulator, phone | Kill tests green; ..." has no phone step in its exit test or body; the M6 phone row is Trick's check on Build 1. "| M7 | Input and clipboard | simulator, phone | Key bar, paste and OSC 52 tests green. **v1 daily driver** |" does not include what Run 1 "Ends with": the install, the self-test and the message. M8 likewise omits the Build 2 install. Line 522: "None of these should show the iOS paste prompt (checked on the phone in M7)", but line 838 says the paste prompt is a phone check and the phone checks are now Trick's after the run. The table calls M5 "First session in the app"; line 738 calls it "**M5 — First session on the phone.**"

###### fix

Replace the rows with: "| M6 | Resume, stage 1, and server probe | yellow, simulator | Kill tests green; same `mosh-server` PID after the app is killed on the simulator; probe tells server gone, host unreachable and UDP blocked apart |", "| M7 | Input and clipboard | simulator, phone | Key bar, paste and OSC 52 tests green on the simulator; `deploy.sh --smoke` passes on the phone; Trick is told Build 1 is ready. **Build 1** |", "| M8 | Session list and appearance | simulator, phone | List states, "End session" and "Forget" work on the simulator; themes and font; `deploy.sh --smoke` passes; Trick is told Build 2 is ready. **Build 2** |". Change line 522-523 to "(Trick's check on Build 1; the simulator cannot show the prompt)". Change line 738 to "**M5 — First session in the app.**"

###### 9. Lines 606, 629, 630-637, 756, 848; work lists at 738-742 and 766-769; layout row 205

**severity:** should-fix

**confidence:** high

**where:** Lines 606, 629, 630-637, 756, 848; work lists at 738-742 and 766-769; layout row 205

###### problem

Three things are referenced but defined nowhere. (a) Line 629 uses "`deploy.sh --smoke`", but the synopsis is "`scripts/deploy.sh [--wait] [--launch]`". (b) The self-test's app side appears in no milestone work list and not in M5's "Debug launch arguments": a key generated on first launch, `Documents/pubkey.txt`, `-smokeHost`, `-smokeUser`, `-smokeHostKey`, `Documents/smoke.json`, the rolling debug log. M5 only says "the self-test from section 7 passes". (c) ""Crash now" (debug menu)" on line 848 and "(the same code as "Crash now")" on line 756 name a control that no milestone or `App/IOSMosh` entry builds. Trick cannot pass `-debugCrashAfter` on the phone, so his M6 check has nothing to press.

###### fix

Line 606: "`scripts/deploy.sh [--wait] [--launch] [--smoke]`", and add "`--smoke` runs the phone self-test below." Add to the M5 list: "- Debug-build hooks for the phone self-test in section 7: a device key generated on first launch, `Documents/pubkey.txt`, the `-smokeHost`, `-smokeUser` and `-smokeHostKey` arguments, `Documents/smoke.json`, the rolling debug log." Add to the M6 sentence on line 766-768: "a debug-only "Crash now" row in Settings (`kill(getpid(), SIGKILL)`)".

###### 10. Lines 786 and 789-790 (Verification)

**severity:** should-fix

**confidence:** high

**where:** Lines 786 and 789-790 (Verification)

###### problem

Line 786: "Everything below the phone rows runs without Trick." The phone rows are the last thing in Verification; everything else is above them. Lines 789-790: "**Core, before every commit** (container on yellow; `swift test` and the macOS part of `itest.sh` on charlie)". This makes every commit depend on charlie being awake. It contradicts line 140 ("most of the work does not depend on charlie being awake") and the summary ("If charlie sleeps or the phone is away, I carry on with the Linux work").

###### fix

Line 786: "Everything above the phone table runs without Trick." Lines 789-790: "**Core, before every commit** (container on yellow). `swift test` and the macOS part of `itest.sh` also run on charlie whenever it is awake, and always before a deploy:"

###### 11. Lines 70, 75-76, 68 (summary) against lines 663-675, 838-839, 182, 684

**severity:** should-fix

**confidence:** high

**where:** Lines 70, 75-76, 68 (summary) against lines 663-675, 838-839, 182, 684

###### problem

Three summary statements disagree with the reference. (a) "The ten milestones in the reference are my own checkpoints inside these runs." The table has eleven, M0 to M10. (b) "Things only a phone can show (keyboard feel, the Local Network prompt, cellular roaming)" omits what line 838 lists: "Not testable on the simulator: Local Network privacy, the paste prompt, Keychain behaviour while locked." Yet the summary promises "paste without the iOS prompt" and resume after "the phone rebooted in your pocket" as Build 1 features; they reach Trick untested on a device. (c) The summary's Later row offers "Resume after a crash at any instant; local echo; TestFlight". The reference Later row has only M9 and M10, and Scope lists TestFlight under "Not planned".

###### fix

Line 70: "The eleven milestones (M0–M10) in the reference are my own checkpoints inside these runs." Lines 75-76: "Things only a phone can show (keyboard feel, the Local Network prompt, the iOS paste prompt, cellular roaming, resume after a phone restart) get their first real test when you use Build 1, so expect rough edges there." Line 684: "| Later, if wanted | M9, M10; TestFlight (section 7) | Resume after a kill at any instant; local echo; builds away from charlie |"

###### 12. Lines 212, 862, 857, 168 and 672

**severity:** nit

**confidence:** high

**where:** Lines 212, 862, 857, 168 and 672

###### problem

Stale leftovers. (a) Line 212: "`CLAUDE.md` | House style: Project Status, Release pipeline ("things that will bite"), Repository Layout, Commands". "Release pipeline" is the heading of the TestFlight section in <the author's Swift app>'s CLAUDE.md; this repo has no release pipeline. (b) Risks line 862: "Tests use the container's `sshd`. On yellow the key can be pasted by hand". The self-test now appends the key itself (line 631). (c) Risks line 857: "kill loop before any phone test". M0 and M5 now put builds and the self-test on the phone before M6's kill loop. (d) "In v1 (M0–M8)" on line 168 against "**v1 daily driver**" on the M7 row: "v1" names two different sets now that the summary uses Build 1 and Build 2.

###### fix

(a) "House style: Project Status, Build and install pipeline ("things that will bite"), Repository Layout, Commands". (b) "Tests use the container's `sshd`. On yellow the self-test appends the device key to `authorized_keys`, so password login is not needed there". (c) "Guards in one place (`DurabilityGate`), guard tests, kill loop before any build with resume goes on the phone". (d) Line 168: "In v1 (M0–M8; Build 1 is M0–M7, Build 2 adds M8):"; the M7 label is already replaced by "**Build 1**" in the milestone-row finding.

### 3. check:pipeline-facts

**check:** check:pipeline-facts

#### r

##### summary

Section 7 is mostly sound, but two things will fail as written (single-dash launch arguments; no CoreDevice pairing step) and several signing and polling details need exact commands. Read-only review; nothing was run on charlie.

What checked out:
- (a) `devicectl list devices`, `device install app`, `device process launch` and `device copy from --source --destination --domain-type appDataContainer --domain-identifier <bundle id>` are in Apple's doc (https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line). `--console` and `--terminate-existing` are real (Flutter's core_devices.dart uses both). Apple says to unlock the device before devicectl commands; whether an install succeeds on a locked phone could not be confirmed, so the plan's "to be safe" wording stands.
- (b) No Apple page states it outright. The manual trust step is documented for enterprise apps (https://support.apple.com/118254) and reported for free Personal Teams. A paid-team development build on a device in its profile should launch without it (medium confidence; confirm on the first launch).
- (c) `keychain_path` plus `keychain_password` is enough: fastlane runs `security set-key-partition-list` itself after import (keychain_importer.rb), but only when the password is supplied. Provisioning endpoints need a Team key ("Individual keys aren't able to use Provisioning endpoints"), as the plan asks. `cert`, `sigh` and `register_devices` accept `api_key_path`; `produce` does not.
- (d) Target-level signing settings are the right place, and `--keychain` in `OTHER_CODE_SIGN_FLAGS` is a known pattern.
- (e) Unlocking the keychain in the same SSH command is correct (Apple DTS, https://developer.apple.com/forums/thread/712005).

Real Mac or phone only: whether a literal `--` reaches the app's argv; install while locked; tunnel state of an idle Wi-Fi phone; the WWDR import failure; whether `--timeout` bounds a `--console` wait; the trust step; openrsync against Linux rsync 3.x.

##### findings

###### 1. /home/trick/.claude/plans/new-project-call-it-harmonic-moon.md lines 647-649 (smoke launch) and 656-658 (M0 "launching with arguments")

**severity:** must-fix

**where:** /home/trick/.claude/plans/new-project-call-it-harmonic-moon.md lines 647-649 (smoke launch) and 656-658 (M0 "launching with arguments")

###### problem

`devicectl device process launch ... <bundle id> -smokeHost ...` fails. devicectl parses single-dash tokens after the bundle id as clusters of its own short options. XcodeBuildMCP issue #434 (Xcode 26.5, https://github.com/getsentry/XcodeBuildMCP/issues/434) shows `-FIRDebugEnabled` failing with "Missing value for '-l <path>'"; it works only after a literal `--`. Apple's devicectl doc names `--environment-variables` for passing values to the app, and Flutter's core_devices.dart shows the JSON form (`--environment-variables '{"OS_ACTIVITY_DT_MODE": "enable"}'`), with every devicectl option before the bundle id.

###### fix

Replace lines 647-649 with: "The script reads the container's host-key fingerprint and launches the app with `xcrun devicectl device process launch --device "$DEV" --terminate-existing --environment-variables '{"SMOKE_HOST":"...","SMOKE_PORT":"...","SMOKE_USER":"...","SMOKE_PASSWORD":"...","SMOKE_HOSTKEY":"...","SMOKE_UDP_RANGE":"...","SMOKE_RUN_ID":"..."}' us.v9n.ios-mosh`; the app reads them from `ProcessInfo.processInfo.environment`. Debug builds only." Fallback if environment variables do not arrive: `... us.v9n.ios-mosh -- -smokeHost ... -smokePort ...` with the literal `--`, read through `UserDefaults` and tolerating a `--` element in argv. Replace the bracket in line 658 with: "(`devicectl device process launch --environment-variables '{...}' <bundle id>`; fallback `<bundle id> -- <args>`)". Whether the `--` itself reaches argv can only be seen on a real Mac.

**confidence:** high

###### 2. Same file, lines 53-55 (setup step 3), lines 632-635 (section 7 "Phone"), line 42 ("locked is fine"), M0 order lines 703-705

**severity:** must-fix

**where:** Same file, lines 53-55 (setup step 3), lines 632-635 (section 7 "Phone"), line 42 ("locked is fine"), M0 order lines 703-705

###### problem

The plan never pairs the phone with CoreDevice. Apple documents `devicectl manage pair` for cable pairing and says: "Developer Mode only appears in Settings if you initiate pairing or if you previously paired the device to a Mac" (https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). Step 3 asks Trick to switch Developer Mode on before anything on charlie has started pairing, so the switch may not be there. Two more gaps: (1) on an Apple silicon laptop the default accessory setting needs approval on the Mac, and "If your Mac is locked, you need to unlock it before you can allow an accessory to connect"; after 3 or more days locked, even a known accessory can need an unlock (https://support.apple.com/102282). That contradicts "locked is fine" for the cable. (2) Apple's Device Hub doc: "If you upgrade the operating system later, you'll need to pair the device again", and Wi-Fi use needs IPv6 enabled on the shared network.

###### fix

Replace step 3 with: "**Phone.** With charlie unlocked at its screen, plug the phone in, click Allow on charlie if it asks about the accessory, unlock the phone and tap Trust. Stay there until I DM you: I start pairing from charlie, and only then does Settings > Privacy & Security > Developer Mode appear. Switch it on, restart, confirm." Add to section 7 "Phone": "First evening, phone cabled and unlocked: `xcrun devicectl manage pair --device <udid>`, then check `xcrun devicectl list devices --json-output f.json` shows `connectionProperties.pairingState` = `paired` and `deviceProperties.developerModeStatus` = `enabled`. An iOS update on the phone needs the cable and a new `manage pair`. Wi-Fi installs need IPv6 enabled on the network. charlie must be unlocked when the cable is first plugged in, and again if it has been locked for 3 days." The exact prompts can only be confirmed with the real phone and Mac.

**confidence:** medium

###### 3. Same file, lines 621-622 ("`--launch` adds `devicectl device process launch --console`") and the smoke flow, lines 647-655

**severity:** should-fix

**where:** Same file, lines 621-622 ("`--launch` adds `devicectl device process launch --console`") and the smoke flow, lines 647-655

###### problem

`--console` does not return. Xcode 16 release note (quoted at https://developer.apple.com/forums/thread/756393): "devicectl device process launch now supports a --console option to capture standard output and standard error from the launched app and to wait until the app exits." An iOS app does not exit by itself, so `deploy.sh --launch` (and `--smoke` if it reuses it) hangs the SSH command. The smoke flow also has no rule for when to pull `smoke.json`, and a file left by an earlier run would be read as the new result.

###### fix

Replace the `--launch` sentence with: "`--launch` adds `devicectl device process launch --terminate-existing us.v9n.ios-mosh` (returns once the app has started). `--console` is used only by `deploy.sh --logs`, under a hard limit: `perl -e 'alarm shift; exec @ARGV' 120 xcrun devicectl device process launch --console --terminate-existing ...` (macOS has no `timeout`)." Add to the smoke flow: "The script passes a random `SMOKE_RUN_ID`. It then polls every 5 s for up to 180 s with `xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier us.v9n.ios-mosh --source Documents/smoke.json --destination /tmp/smoke.json` and accepts the file only when its `runId` matches." Whether killing devicectl also ends the app, and whether devicectl's `--timeout` bounds a `--console` wait, can only be seen on a real Mac.

**confidence:** high

###### 4. Same file, lines 597-602 (keychain creation; `fastlane run cert development:true`, `register_devices`, `sigh development:true`)

**severity:** should-fix

**where:** Same file, lines 597-602 (keychain creation; `fastlane run cert development:true`, `register_devices`, `sigh development:true`)

###### problem

Answer to (c): no separate `security set-key-partition-list` is needed, but only if `keychain_password` is passed. fastlane's keychain_importer.rb runs `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> <keychain>` after import. In a non-interactive session with no password it warns ("Specify the 'keychain_password' option to prevent the UI permission popup when code signing") and uses an empty password, so the first `codesign` over SSH blocks or fails. The plan line names none of `keychain_path`, `keychain_password`, `api_key_path`, `output_path`, `app_identifier`. Also: `sigh` has no keychain option; `register_devices devices:` is a Hash, awkward with `fastlane run`; fastlane needs a UTF-8 locale (https://docs.fastlane.tools/getting-started/ios/setup/), which a non-interactive SSH shell does not set; and `security list-keychains -s` replaces the search list, so the login keychain must be listed again.

###### fix

Replace the two bullets with these commands, all in one SSH command:
`export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8; S=$HOME/signing; KC=$HOME/Library/Keychains/ios-mosh.keychain-db; PW=$(cat $S/kc.pass)`
`security create-keychain -p "$PW" "$KC" && security set-keychain-settings "$KC"`
`security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')`
`security unlock-keychain -p "$PW" "$KC"`
`CERT_KEYCHAIN_PASSWORD="$PW" fastlane run cert development:true api_key_path:$S/asc.json keychain_path:"$KC" output_path:$S`
`fastlane run register_devices api_key_path:$S/asc.json devices_file:$S/devices.txt`
`fastlane run sigh development:true api_key_path:$S/asc.json app_identifier:us.v9n.ios-mosh provisioning_name:ios-mosh-dev force:true output_path:$S filename:ios-mosh-dev.mobileprovision`
Then prove it in a new SSH session: `security unlock-keychain -p "$PW" "$KC" && cp /usr/bin/true /tmp/t && codesign -f -s "Apple Development" --keychain "$KC" /tmp/t`. If that blocks or reports errSecInternalComponent, run the `set-key-partition-list` line above by hand once. Route 2 (an identity already in the login keychain, not imported by fastlane) probably needs that manual line too.

**confidence:** high

###### 5. Same file, lines 601-602 (cert and sigh run over SSH with a dedicated keychain)

**severity:** should-fix

**where:** Same file, lines 601-602 (cert and sigh run over SSH with a dedicated keychain)

###### problem

Found in fastlane source, not in the earlier research. After creating a certificate, `cert` verifies it with `CertChecker.installed?(ENV["CER_FILE_PATH"], in_keychain: ENV["CER_KEYCHAIN_PATH"])`; that variable is only set when an existing certificate is found, not on the create path. `sigh` calls `CertChecker.installed?` with no keychain at all. With no keychain, CertChecker first imports any missing Apple WWDR intermediates into the default keychain, which is the login keychain. Over SSH that keychain is locked, so the import is likely to fail and raise "Could not install WWDR certificate", stopping `cert` after the certificate already exists on the portal, or stopping `sigh`.

###### fix

Add to the signing bullets: "Run `cert` with `CER_KEYCHAIN_PATH="$KC"` exported, and `sigh` with `skip_certificate_verification:true`, so fastlane's WWDR check uses the dedicated keychain and not the locked login keychain. If either still fails on a WWDR import: `OLD=$(security default-keychain -d user | tr -d ' "'); security default-keychain -d user -s "$KC"; <fastlane command>; security default-keychain -d user -s "$OLD"`. Afterwards `security find-identity -v -p codesigning "$KC"` must list one valid identity." This could only be confirmed on a real Mac; it does not arise if the login keychain already holds every intermediate fastlane checks for.

**confidence:** low

###### 6. Same file, lines 601-602 ("`register_devices` with the phone's UDID")

**severity:** should-fix

**where:** Same file, lines 601-602 ("`register_devices` with the phone's UDID")

###### problem

The plan does not say where the UDID comes from. The identifier that `devicectl list devices` shows is a CoreDevice UUID, not the hardware UDID the developer portal needs. Flutter's parser of `devicectl list devices --json-output` keeps them apart: `coreDeviceIdentifier: data['identifier']` versus `hardwareProperties.udid` (example `00001234-0001234A3C03401E`) (https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/ios/core_devices.dart). Registering the wrong value uses up a device slot for the membership year and yields a profile that does not cover the phone, so the install fails later with a confusing error.

###### fix

Replace with: "`register_devices` with the phone's hardware UDID, which is `hardwareProperties.udid` in the JSON and not the `identifier` column: `xcrun devicectl list devices --json-output /tmp/dev.json >/dev/null; UDID=$(plutil -extract result.devices.0.hardwareProperties.udid raw -o - /tmp/dev.json)` (pick the entry whose `hardwareProperties.deviceType` is `iPhone` if there are several; cross-check with `xcrun xctrace list devices`). Then `printf 'Device ID\tDevice Name\tDevice Platform\n%s\tTrick iPhone\tios\n' "$UDID" > ~/signing/devices.txt` and pass `devices_file:`. The CoreDevice `identifier`, the UDID or the device name all work for `--device`." The `result.devices` path is from Flutter's parser and memory; check it on the first real output.

**confidence:** medium

###### 7. item

**severity:** should-fix

###### where

Same file, lines 606-607 (team id into `Local.xcconfig` on charlie), 616 (`mac.sh` writes commit count and SHA into `Local.xcconfig` on yellow), 665

###### problem

`Local.xcconfig` has two writers on two machines. `mac.sh` writes it on yellow and rsyncs the tree, which overwrites the file holding the team id that only charlie can produce (or deletes it if rsync runs with `--delete`). Separately, XcodeGen checks that config files exist: its `options.disabledValidations` list has `missingConfigFiles`, "Disable checking for the existence of configuration files" (https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md). So `xcodegen generate` fails on a fresh checkout or before signing has run, which also blocks simulator builds in M0.

###### fix

Replace the last sentence of line 606-607 with: "`App/Local.xcconfig` is committed and holds only `#include? "Version.xcconfig"` and `#include? "Signing.xcconfig"`. `mac.sh` writes `App/Version.xcconfig` (commit count, short SHA) on yellow before the rsync. The signing step writes `App/Signing.xcconfig` (`DEVELOPMENT_TEAM = <id>`) on charlie; it is gitignored and excluded from the rsync (`--exclude App/Signing.xcconfig`)." Change line 616 to say `Version.xcconfig`. The app target lists `configFiles: {Debug: Local.xcconfig, Release: Local.xcconfig}`.

**confidence:** high

###### 8. Same file, lines 620-621 ("`--wait` polls `devicectl list devices` until the phone is reachable")

**severity:** should-fix

**where:** Same file, lines 620-621 ("`--wait` polls `devicectl list devices` until the phone is reachable")

###### problem

Two problems. Apple's devicectl doc says scripts should use `--json-output` and "don't rely on or parse the Terminal output from these commands". And "reachable" is not defined: the JSON has `connectionProperties.pairingState`, `transportType` (`wired` or `localNetwork`) and `tunnelState` (field names confirmed in Flutter's parser). From the earlier research and memory, an idle paired phone on Wi-Fi sits at `tunnelState` `disconnected` until a command opens the tunnel, so a loop waiting for `connected` could wait forever. The plan also has a lock check available that it does not use: `devicectl device info lockState`.

###### fix

Replace with: "`--wait` loops every 20 s: `xcrun devicectl list devices --timeout 20 --json-output $TMP`, find the phone by `hardwareProperties.udid`; when `connectionProperties.pairingState` is `paired`, run `xcrun devicectl device info lockState --device $DEV --json-output $TMP2` and, when the phone is unlocked, attempt the install; any failure (tunnel, locked, not found) sleeps and retries. It never waits for `tunnelState` = `connected` and never parses the text table." The idle tunnel state and the lockState JSON shape can only be confirmed on a real Mac.

**confidence:** medium

###### 9. Same file, lines 599-600 ("App ID `us.v9n.ios-mosh` is created through the API (`bundleIds`)")

**severity:** should-fix

**where:** Same file, lines 599-600 ("App ID `us.v9n.ios-mosh` is created through the API (`bundleIds`)")

###### problem

No mechanism is named, and the obvious one does not work. fastlane's `produce` has no API-key support; the fastlane App Store Connect API page lists it as unsupported, while `cert`, `sigh` and `match` are supported (https://docs.fastlane.tools/app-store-connect-api/). The endpoint itself exists (`POST /v1/bundleIds`, "Register a new bundle ID for app development") and needs a Team key: "Individual keys aren't able to use Provisioning endpoints" (https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api). Homebrew's fastlane gems are not on the system Ruby path, so a plain Ruby script cannot load Spaceship. Without the App ID, `sigh` fails.

###### fix

Replace the bullet with: "App ID `us.v9n.ios-mosh` is created by a one-lane `~/signing/fastlane/Fastfile` run with `fastlane appid`: `lane :appid do; Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(File.expand_path('~/signing/asc.json')); Spaceship::ConnectAPI::BundleId.find('us.v9n.ios-mosh') || Spaceship::ConnectAPI::BundleId.create(name: 'IOSMosh', platform: 'IOS', identifier: 'us.v9n.ios-mosh'); end`. The name has no hyphen. If the call returns 403, Trick registers the App ID in the developer portal." Apple's page does not list the roles allowed for this endpoint, so the plan's Admin Team key is the safe request.

**confidence:** medium

###### 10. Same file, lines 564-565 and 614-615 (rsync from yellow to charlie), line 572 (`brew install xcodegen mosh fastlane`)

**severity:** should-fix

**where:** Same file, lines 564-565 and 614-615 (rsync from yellow to charlie), line 572 (`brew install xcodegen mosh fastlane`)

###### problem

Since macOS 15.4 `/usr/bin/rsync` is openrsync (protocol 29); Apple removed the Samba rsync. It "accepts only a subset of rsync's command-line arguments", and users report broken options and assertion failures (https://mjtsai.com/blog/2025/06/06/sequoias-new-rsync/; https://developer.apple.com/forums/thread/778978). A Linux rsync 3.x on yellow would talk to openrsync on charlie. No source found describes this exact pairing failing, so this is a risk, not a certainty.

###### fix

Change line 572 to `brew install xcodegen mosh fastlane rsync`, and line 614 to: "`scripts/mac.sh CMD...` runs `rsync -az --delete --exclude .git --exclude .build --exclude App/Signing.xcconfig --exclude '*.xcodeproj' --rsync-path=/opt/homebrew/bin/rsync -e 'ssh -i ~/.ssh/ios-mosh-charlie' ./ charlie:ios-mosh-build/`". Until Homebrew is installed, use only `-a --delete --exclude` and compare a file count after the first sync. Real behaviour against charlie's macOS version can only be seen there.

**confidence:** medium

###### 11. Same file, lines 603-607 (`project.yml` signing settings and team id)

**severity:** should-fix

**where:** Same file, lines 603-607 (`project.yml` signing settings and team id)

###### problem

Three details for (d). (1) Build settings do not expand `~`; `OTHER_CODE_SIGN_FLAGS: --keychain ~/Library/...` would hand codesign a literal tilde. (2) The plan gives no command for reading the team id, and `sigh` needs a known output file for it. (3) `PROVISIONING_PROFILE_SPECIFIER` and a manual identity in `base` also apply to simulator builds of the app target, and the test targets stay on automatic signing with no team. Simulator builds may reject the profile setting, and a device build that includes the test targets would fail for lack of a team. Point 3 is low confidence and needs a real Mac.

###### fix

Use in `project.yml` on the app target: `CODE_SIGN_STYLE: Manual`, `"CODE_SIGN_IDENTITY[sdk=iphoneos*]": Apple Development`, `"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": ios-mosh-dev`, `OTHER_CODE_SIGN_FLAGS: --keychain $(HOME)/Library/Keychains/ios-mosh.keychain-db`. Team id: `security cms -D -i ~/signing/ios-mosh-dev.mobileprovision 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - -`, written as `DEVELOPMENT_TEAM = <id>` into `Signing.xcconfig`. Add: "The device build uses a scheme whose build action lists only the app target, so the test targets never need signing." The keychain must stay in the user search list as well; `--keychain` alone does not let Xcode resolve the identity.

**confidence:** medium

###### 12. Same file, lines 570-582 (charlie chores, `nohup caffeinate -is`) and 629-630 (LaunchAgent fallback)

**severity:** should-fix

**where:** Same file, lines 570-582 (charlie chores, `nohup caffeinate -is`) and 629-630 (LaunchAgent fallback)

###### problem

Three headless details for (e). (1) `ssh charlie 'nohup caffeinate -is &'` does not return: ssh waits until the background process closes its inherited stdout and stderr. (2) The LaunchAgent fallback must stay simulator-only. Apple TN3179: local network access is allowed for "Command-line tools run from Terminal or over SSH, including any child processes they spawn", but "The exception for launchd daemons doesn't apply to launchd agents" (https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). A script started from the agent that reaches the phone or the LAN can be blocked behind a prompt nobody sees. (3) "Check `xcodebuild -version`" has no pass criterion. An Xcode older than the phone's iOS major may not be able to launch on it, and updating Xcode needs the App Store or an Apple ID sign-in, which is a human step of several GB.

###### fix

(1) Use `pgrep -x caffeinate >/dev/null || nohup caffeinate -is </dev/null >/dev/null 2>&1 &`. (2) Add after line 630: "The LaunchAgent only ever runs simulator tests. `devicectl`, rsync and anything that touches the phone or the network stay in the SSH session." (3) Replace the start of line 570 with: "Check `xcodebuild -version`: Xcode 16 or later is required (iOS 18 SDK, `devicectl --console`), and its major version should be at least the phone's iOS major (`deviceProperties.osVersionNumber` in the devicectl JSON). If it is older, the first Slack list asks Trick to update Xcode from the App Store." The version rule is medium confidence; older Xcode sometimes still installs but fails to launch, which only a real Mac shows.

**confidence:** medium

