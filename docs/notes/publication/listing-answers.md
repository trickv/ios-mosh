# Proposed answers for the owner's own declarations

These are declarations the owner makes in App Store Connect himself. Each answer below is a
proposal with the reason found in the code or in Apple's text (sources S1 to S9 are listed in
`listing-requirements.md`). Checked against the code on `main` as of 2026-11-24.

## 1. App Privacy: "Data Not Collected"

Proposal: **No, we do not collect data from this app** ("Data Not Collected").

Apple's test (S6): "'Collect' refers to transmitting data off the device in a way that allows you
and/or your third-party partners to access it for a period longer than what is necessary to service
the transmitted request in real time." And: "You are not responsible for disclosing data collected
by Apple."

What the code shows:

- **Network:** the only connections are SSH (swift-nio-ssh over SwiftNIO Transport Services) and
  mosh UDP (`Sources/MoshTransport/NWDatagramTransport.swift`), both to the host the user typed
  into a saved host. No `URLSession`, `URLRequest` or `WKWebView` anywhere in `App/` or
  `Sources/`. The other `NWConnection` users (`App/IOSMosh/SmokeProbe.swift`) are inside
  `#if DEBUG`, as are `DeviceProbe.swift`, `StageTwoProbe.swift` and the UI-test hooks, so they
  are not in the Release (App Store) build.
- **SDKs:** the dependencies are SwiftTerm, SwiftNIO, SwiftNIO SSH, SwiftNIO Transport Services
  and Swift Crypto (`Package.swift`, `App/project.yml`); `Package.resolved` adds only their own
  dependencies (swift-asn1, swift-atomics, swift-collections, swift-system), swift-png and h
  (SwiftTerm's `Package.swift` uses swift-png only on Linux, Windows, WASI and Android, not on
  iOS) and swift-argument-parser (command-line tools such as `moshcli`). No
  analytics, crash reporting, ads, attribution, Firebase, Sentry, StoreKit, CloudKit, MetricKit,
  advertising identifier or App Tracking Transparency.
- **Identifiers:** no `identifierForVendor`, no advertising identifier. `UIDevice.current.name`
  is read once, to name the SSH key (`ios-mosh@iphone`; since iOS 16 the name is the model).
- **Clipboard:** written only on an OSC 52 copy from the host, behind a per-host switch
  (`ClipboardWriter.swift`), and when the user taps Copy on the Keys screen or in the key-install
  prompt. Read only through the Paste key (`UIPasteControl`, `KeyBarView.swift`) and the edit
  menu's Paste, which send the text to the session on screen. SwiftTerm's own clipboard hooks
  are stubbed out (`App/SurfaceKit/TerminalSurface.swift`: `clipboardCopy` does nothing,
  `clipboardRead` returns nil).
- **Links:** SwiftTerm's iOS default for OSC 8 links does nothing, and the app does not override
  it. Links on the Help and About pages open in Safari.
- **Storage:** all on the phone (hosts, host keys, session records, settings, debug log; the SSH
  key and session keys in the Keychain, "this device only", not synchronizable). Nothing is
  uploaded.

What goes to the user's own servers (user name, password or key signature, keystrokes, the
public key line) does not reach the developer or any partner of his, so it does not meet "you
and/or your third-party partners" in Apple's definition. Apple's page does not speak about
servers the user chooses; this reading is the usual one for SSH and terminal apps, but it is the
owner's declaration.

Apple's own opt-in crash sharing ("Share With App Developers", TestFlight feedback) is data
collected by Apple, which S6 says the developer does not disclose.

## 2. Age rating questionnaire

Proposal: every content question **None**, every capability **No**, giving **4+**.

| Question (S4) | Answer | Reason |
|---|---|---|
| Parental Controls | No | The app has none |
| Age Assurance | No | The app has none |
| Unrestricted Web Access | No | The app has no browser and no web view. OSC 8 links do nothing; Help and About links leave the app for Safari. See the note below |
| User-Generated Content | No | Nothing is distributed between users; the app shows only the user's own servers |
| Social Media | No | None |
| Messaging and Chat | No | The app has no messaging between users |
| Shared Location | No | No location API is used |
| Advertising | No | No ads |
| Profanity or Crude Humor | None | The app's own texts contain none |
| Horror/Fear Themes | None | |
| Alcohol, Tobacco, or Drug Use or References | None | |
| Dating and Relationships | None | |
| Medical or Treatment Information | None | |
| Health or Wellness Topics | None | |
| Mature or Suggestive Themes | None | |
| Sexual Content or Nudity | None | |
| Graphic Sexual Content and Nudity | None | |
| Cartoon or Fantasy Violence | None | |
| Realistic Violence | None | |
| Prolonged Graphic or Sadistic Realistic Violence | None | |
| Guns or Other Weapons | None | |
| Gambling, Simulated Gambling, Contests, Loot Boxes | None | |
| Made for Kids | No | A developer tool |

Note on "Unrestricted Web Access" (16+ if Yes): S4 defines it as "Users can navigate to any
webpage within the app or freely browse the web. May include: embedded browser functionality or
browser app." The app itself cannot show a web page. A user can run a text-mode browser on his own
server and see its output, as with any SSH or terminal app; that is the server's content, not a
capability of the app. Answering Yes would be the cautious choice if a reviewer reads it that way
(the rating would then be 16+). The proposal is No.

## 3. Content rights

Question: "Does your app contain, show, or access third-party content?" Proposal: **No.** The app
shows only what the user's own servers send. What it bundles is under licences that allow this:
the Hack Nerd Font (MIT, Bitstream Vera, and the glyph sets' licences: MIT, CC BY 4.0, Apache
2.0, SIL OFL 1.1, Unlicense; texts on the About page), SwiftTerm (MIT), SwiftNIO and Swift Crypto
(Apache 2.0), and code ported from mosh (GPLv3). If the owner prefers to count the bundled font
and libraries as third-party content, "Yes, and I have the rights" is also true.

## 4. Categories

Proposal: primary **Developer Tools**, secondary **Utilities**. Apple's Developer Tools text names
"workflow management, text and code editing"; a terminal for servers is where developers look
for SSH and terminal apps. Utilities ("solve a problem or complete a specific task", it lists
"remote controls") fits as the second. The reverse order would also be defensible.

## 5. Other declarations, for the owner

- **Export compliance:** done (`ITSAppUsesNonExemptEncryption` = NO in every build).
- **Price and availability:** not set on the record (`listing-state.md`); a price (free) and the
  territories are needed before a submission.
- **EU Digital Services Act status:** account level. As a trader, his name, address, phone and
  email are shown to EU users; as a non-trader the app is not offered in the EU. His decision.
- **App Review contact and notes:** already filled by him (`listing-state.md`), left alone. A
  reviewer cannot use a mosh app without a server: S1's "Sign-in required" and guideline 2.1 ask
  for a way to test, so the notes need a reachable host with mosh-server and a login for the
  reviewer, or a statement of how to test. His call.
- **Copyright line:** "2026 Patrick van Staveren" (the name on 170 of his commits; one GitHub
  merge commit carries "Trick van Staveren"). Apple's field means "the name of the person or
  entity that owns the exclusive rights to the app"; parts are ported from mosh under the GPL and
  the About page says "Copyright the iOS-mosh authors". The line is customary, and his to confirm.
