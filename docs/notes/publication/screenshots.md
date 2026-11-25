# App Store screenshots

## What Apple requires (read 2026-11-24)

Source: Apple, App Store Connect Help, "Screenshot specifications",
<https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications>
(read on the web on 2026-11-24; the page carries no "last updated" date).

- **Required for an iPhone app**, in Apple's words: "To submit your app, you must provide
  screenshots for the following required display sizes: **iPhone:** At least one screenshot for
  iPhone with Dynamic Island (medium display)." The iPad line ("At least one screenshot for iPad
  13-inch display") applies only "if your app supports iPadOS"; iOS-mosh is iPhone only
  (`TARGETED_DEVICE_FAMILY: "1"` in `App/project.yml`), so no iPad screenshots are needed.
- **iPhone with Dynamic Island (medium display)** (iPhone 18 Pro, 17 Pro, 17, 16 Pro, 16, 15 Pro,
  15, 14 Pro): **1206 x 2622** or **1179 x 2556** pixels portrait (2622 x 1206 or 2556 x 1179
  landscape).
- **How many, which format:** "You must include at least one screenshot and can upload up to 10
  screenshots per device size in .jpeg, .jpg, or .png formats". Images "can't include alpha
  channels or transparencies".
- **Scaling:** "If your app's user interface is consistent across multiple device sizes and
  localizations, you only need to provide screenshots for the highest required resolution. App
  Store Connect automatically scales them down for smaller device sizes."
- **Optional, provided anyway:** iPhone with Dynamic Island (large display) (iPhone Air, 18 Pro Max,
  17 Pro Max, 16 Pro Max, 16 Plus, 15 Pro Max, 15 Plus, 14 Pro Max): 1320 x 2868, 1290 x 2796 or
  1260 x 2736 portrait. The page's row for iPhone with Face ID (large display) (1284 x 2778,
  1242 x 2688) says "Required if app runs on iPhone and screenshots for iPhone with Dynamic Island
  (large display) aren't provided", which reads against the "required" list above. Giving the
  6.9-inch set (1320 x 2868) as well satisfies both readings.
- **Coming:** "iPhone Duo screenshots are required starting April 2027 for apps built with the iOS
  27.1 SDK or later" (outer display 1398 x 2034, inner 2007 x 2853). The app is built with the iOS
  27.2 SDK, so from April 2027 a Duo set will be needed. charlie has no Duo simulator (its only
  runtime is iOS 26.5); not made here.
- fastlane on charlie (2.242.0, `deliver/lib/deliver/app_screenshot.rb`) knows both sizes used
  here (`[1206, 2622]` and `[1320, 2868]`), so `deliver` sorts these files into the right slots by
  their pixel size. Within a size the order is the file names' order.

## The files

`App/fastlane/screenshots/en-US/` (PNG, 8-bit RGB, no alpha channel; checked with `file` and
Pillow on yellow):

| File | Pixels | Shows |
|---|---|---|
| `iphone63-01-terminal.png` | 1206 x 2622 | Shell in a demo git repository: `ls` in colour, `git log --oneline --decorate`, `git status -sb`; key bar open over the keyboard |
| `iphone63-02-hosts.png` | 1206 x 2622 | Hosts list: `build` (alex@build.example.net) with two sessions "webapp" and "vim app.py" ("started ... · last used ...", the green dot, the "+"), and `web-01` (alex@web-01.example.net) |
| `iphone63-03-vim.png` | 1206 x 2622 | Second session on the same host: vim with syntax colours, line numbers and status line, key bar open |
| `iphone63-04-host-editor.png` | 1206 x 2622 | Edit Host with demo values (build.example.net, port 22, user alex, local echo Adaptive) |
| `iphone63-05-swipe.png` | 1206 x 2622 | The session row's swipe: End Session, Forget |
| ~~`iphone63-06-settings.png`~~ | 1206 x 2622 | Settings: font size, themes, cursor, key bar. **Left out by the final check (2026-11-24):** at this height the last row (tmux Prefix) is cut through by the bottom edge. Not committed, not uploaded; the 6.9-inch one shows the whole row and stays. |
| `iphone69-01-terminal.png` | 1320 x 2868 | as above, iPhone 17 Pro Max |
| `iphone69-02-hosts.png` | 1320 x 2868 | as above |
| `iphone69-03-vim.png` | 1320 x 2868 | as above |
| `iphone69-04-host-editor.png` | 1320 x 2868 | as above |
| `iphone69-05-swipe.png` | 1320 x 2868 | as above |
| `iphone69-06-settings.png` | 1320 x 2868 | as above |

All in dark mode (the app's default terminal theme "System", 12 pt), status bar 9:41, full Wi-Fi
and cellular bars, full battery, no carrier name. Each PNG holds only Apple's standard screenshot
metadata (EXIF and XMP with the word "Screenshot", orientation and size); no device or user name.

Checked by eye, picture by picture, and by the test itself (it fails if the terminal text or any
label on the list and editor screens contains `127.0.0.1`, `/Users/`, the spawner's UDP range or
the Mac user's login name): no private name, user, host or address; nothing cut off except the
Settings list, which continues below the screen as it does on a phone.

## Where they come from

`App/IOSMoshUITests/StoreScreenshots.swift`, one UI test against the Debug app (the Dev app
`us.v9n.ios-mosh.dev`, same screens as the TestFlight app; its debug-only "Crash Now" row is below
the bottom of the Settings picture) and `scripts/mosh-spawner.py`'s throwaway sshd on charlie:

1. A host "build" with the spawner's real fields (127.0.0.1, the Mac user: the sshd logs in only
   that user), first session, host key trusted. In the shell: `cd /tmp` first (so the prompt never
   shows the Mac's home), HOME set to `/tmp/iosmosh-store-demo/alex`, git's global and system
   config off, author "Alex <alex@example.net>", prompt `alex@build:~/webapp$`; a demo repository
   is made, the window title set ("webapp"), the screen cleared, then `ls`, `git log`,
   `git status`. Picture 01.
2. A tap on the host row starts a second session; title "vim app.py"; `vim -u NONE` (no vimrc of
   the Mac's) on the demo `app.py`. Picture 03.
3. Host `web-01` added with demo values only (never connected). Host `build`'s fields are changed
   to build.example.net / 22 / alex before any picture shows them; the parked sessions keep
   running from their own records. Pictures 02, 04, 05, 06.

Every server is stopped at the end (the spawner reports "servers left after the run: []"), the
key check found no session key in any kept file. The demo directory on charlie was removed after
the last run.

**Skipped unless asked for:** the test calls `XCTSkipUnless` on `STORE_SCREENSHOTS == "1"` (the
runner sees `TEST_RUNNER_STORE_SCREENSHOTS` as that). Shown on 2026-11-24 with
`scripts/mac.sh scripts/sim-test.sh -only-testing:IOSMoshUITests/StoreScreenshots`: "Executed 1
test, with 1 test skipped and 0 failures", `** TEST EXECUTE SUCCEEDED **`. `scripts/sim-test.sh`
is unchanged.

## Making them again

From yellow, one run at a time, nothing else building on charlie
(`scripts/mac.sh --ssh 'pgrep -fl "xcodebuild|sim-test|fastlane"'` prints nothing).

```bash
cd ~/src/github.com/trickv/ios-mosh   # the checkout on yellow
mkdir -p out/yellow/store

# 1. Prepare both simulators (iOS 26.5 runtime; ids from `xcrun simctl list devices`).
#    Reboot first: on a simulator booted headless with simctl, a change of appearance did not
#    reach apps until it was shut down and booted again (seen 2026-11-24 on the 17 Pro Max).
scripts/mac.sh --ssh 'for N in "iPhone 17" "iPhone 17 Pro Max"; do
  U=$(xcrun simctl list devices available | grep -F "    $N (" | head -1 | sed -E "s/.*\(([0-9A-F-]{36})\).*/\1/");
  xcrun simctl shutdown $U 2>/dev/null; xcrun simctl boot $U; xcrun simctl bootstatus $U -b >/dev/null;
  xcrun simctl ui $U appearance dark;
  xcrun simctl status_bar $U override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100;
done'

# 2. One run per size; output to a file; then copy the PNGs off with their names.
for S in "iPhone 17:iphone63" "iPhone 17 Pro Max:iphone69"; do
  N=${S%%:*}; P=${S##*:}; D=out/yellow/store/shots-$P; rm -rf $D; mkdir -p $D
  scripts/mac.sh env TEST_RUNNER_STORE_SCREENSHOTS=1 SIM_NAME="$N" scripts/sim-test.sh \
    -only-testing:IOSMoshUITests/StoreScreenshots > out/yellow/store/shots-$P.log 2>&1
  grep -E "Test Case|key check" out/yellow/store/shots-$P.log
  scripts/mac.sh --ssh 'cd ~/ios-mosh-out/attachments && tar cf - *.png manifest.json' | tar xf - -C $D
  python3 -c "import json,shutil,sys
d,p=sys.argv[1:]
for t in json.load(open(d+'/manifest.json')):
  for a in t['attachments']:
    shutil.copyfile(d+'/'+a['exportedFileName'],
      'App/fastlane/screenshots/en-US/%s-%s.png'%(p,a['suggestedHumanReadableName'].split('_')[0]))" $D $P
done
file App/fastlane/screenshots/en-US/*.png

# 3. Put the simulators back.
scripts/mac.sh --ssh 'for N in "iPhone 17" "iPhone 17 Pro Max"; do
  U=$(xcrun simctl list devices available | grep -F "    $N (" | head -1 | sed -E "s/.*\(([0-9A-F-]{36})\).*/\1/");
  xcrun simctl status_bar $U clear; xcrun simctl ui $U appearance light; done;
  rm -rf /tmp/iosmosh-store-demo'
```

Each run takes about 5 minutes (build about 2, test about 2). The test also switches the device
to dark mode itself and checks it on the screen before every picture (a pixel near the bottom:
the list's, editor's or keyboard's background); it fails with "the simulator shows dark mode"
when the switch does not take, which is what step 1's reboot prevents.

Then read every PNG (no private text, nothing cut off) before an upload.

## Seen while making them (for the owner)

- **Light mode, terminal screen:** with the phone in light mode the terminal stays black ("System"
  theme) but the status bar (time, signal, battery) and the host's name in the navigation bar are
  drawn black, so on the terminal screen they cannot be seen. The first pictures, taken in light
  mode, showed it; the final set is in dark mode, where they are white. A fix in the app would be a
  light status bar and title over a dark terminal background whatever the system mode.
  **Fixed (2026-11-24, after this set was made):** the terminal screen's navigation bar and status
  bar now take the terminal's own background, with white or black text by contrast
  (`TerminalBars`, `TerminalViewController.applyBars`, `AppNavigationController`); the Hosts list
  and the other screens keep the system's colours. `TerminalBarsUITests` checks it on the screen
  (light mode with the default theme, dark mode with Tango Light): it samples the screenshot's
  pixels in the title's frame and in the left third of the status bar strip, and wants a WCAG
  contrast of at least 4.5 between the text and the bar, and the bar in the terminal's colour.
  **Appearance on the simulator:** the 17 Pro Max simulator above, booted headless with simctl,
  needed a shutdown and boot before a change of appearance reached apps. The test therefore does
  not take the mode on trust: it sets `XCUIDevice.shared.appearance` before and after the launch,
  then waits until the app itself reports the mode (the UI-test element `terminalBars`,
  "system=light" or "system=dark", from the terminal screen's trait collection), switching to the
  other mode and back up to five times if it does not, and fails if it never does. The mode is put
  back at the end. In light mode the terminal of the System theme is still black (its text grey):
  only the bars changed, as the screenshots' finding asked.
- **A failed run's recording:** when a UI test fails, XCTest keeps a screen recording in
  `~/ios-mosh-out/attachments` on charlie. One failed run (dark mode not applied) recorded the shell
  set-up typing, whose prompt then showed the Mac user's home directory for one line, because the
  set-up line changed the prompt before it changed directory. The set-up now does `cd /tmp` first.
  The recording stays on charlie (the next run replaces the attachments); the copy made on yellow
  for the diagnosis was deleted. sim-test.sh's key check does not look for user names, only for
  session keys.
- The simulator counts the Mac's keyboard as a hardware keyboard, so the key bar starts folded into
  its "Keys" button; the test taps it open before the terminal pictures, as a user with a keyboard
  would.
