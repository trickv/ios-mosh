# What Apple requires for an iPhone app's App Store listing

Looked up on 2026-11-24 (UTC) in Apple's own pages, read live, not from memory. Each item names its
page. Quotes are Apple's words. Apple's pages carry no "last updated" date; what is below is what
they said on that day.

Sources (S1 to S9):

- S1 Platform version information:
  https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- S2 App information:
  https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- S3 Screenshot specifications:
  https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- S4 Age ratings values and definitions:
  https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions
- S5 Categories: https://developer.apple.com/app-store/categories/
- S6 App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- S7 App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- S8 Required reason API:
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
  (read through its JSON form, `developer.apple.com/tutorials/data/documentation/...json`)
- S9 Apple trademark list: https://www.apple.com/legal/intellectual-property/trademark/appletmlist.html
  and Guidelines for using Apple trademarks:
  https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html

The page "Required, localizable, and editable properties" lost its check marks when read as text,
so the "required" column below comes from S1 and S2, which say it in words.

## 1. App information (app level, S2)

| Field | Required | Limit | Notes |
|---|---|---|---|
| Name | set on the record | "at least two characters and no more than 30 characters" | Editable until the version is submitted. S7 2.3.7: "App names must be limited to 30 characters" and must be unique |
| Subtitle | optional | "can't be longer than 30 characters" | S7 2.3.7: must not "reference other apps, or make unverifiable product claims" |
| Privacy Policy URL | "Required for iOS and macOS apps" | URL | S6: "Privacy Policy (Required): The URL to your publicly accessible privacy policy." S7 5.1.1(i): the link must also be "within the app in an easily accessible manner" |
| Primary category | needed to submit | one of the list in section 5 | |
| Secondary category | optional | | |
| Age Rating | "This property is required." | questionnaire, section 6 | Set once for the app |
| Content Rights | asked before submission | yes/no | "Apps with third-party content must have all necessary rights" |
| License Agreement | optional | | Apple's standard EULA applies unless a custom one is given |
| Digital Services Act status | required for EU distribution | | A trader's address and contact details are shown to EU users |

## 2. Version information (per version, S1)

| Field | Required | Limit | Notes |
|---|---|---|---|
| Screenshots | "This property is required and can be localized." | 1 to 10 per display size | Section 4 |
| App Preview | optional | up to 3 per size | |
| Promotional Text | optional | "can't be longer than 170 characters" | Can be changed at any time without a new version |
| Description | "This property is required and can be localized." | "Limited to 4000 characters." | "HTML format isn't supported." |
| Keywords | "This property is required and can be localized." | "up to 100 bytes of content", each keyword "greater than two characters" | "Names of other apps or companies aren't allowed." App and company names are searchable already, so repeating them wastes bytes |
| Support URL | "This property is required and can be localized." | full URL with protocol | "This URL must lead to actual contact information (legal address, email address, telephone number), as may be required by local law" (see section 8) |
| Marketing URL | optional | full URL | |
| Version Number | from the version record | | |
| Copyright | "This property is required." | | "The name of the person or entity that owns the exclusive rights to the app, preceded by the year the rights were obtained (for example, 2014 Example, Inc.). The copyright symbol is added automatically." |
| What's New in This Version | "This property isn't available for the first version of the app but required for all subsequent versions." | "Limited to 4000 characters." | deliver skips `release_notes.txt` on a first version |
| App Review information: contact | asked for | phone "in international format, including a plus sign" | Not shown to customers; can be edited at any time |
| App Review notes | optional | "up to 4000 bytes" | |
| Sign-in information | "If your app requires a login to use it." | | The reviewer needs a way to use the app; for this app that means a host to connect to (the owner's call) |

## 3. Pricing, availability, privacy (other pages of the record)

- A price (free is a price) and at least one territory must be set before submitting.
- App Privacy: the "Data Types" answers (or "Data Not Collected") and the Privacy Policy URL
  (S6). S6's definition: "'Collect' refers to transmitting data off the device in a way that
  allows you and/or your third-party partners to access it for a period longer than what is
  necessary to service the transmitted request in real time." And: "Data that is processed only
  on device is not 'collected' and does not need to be disclosed in your answers."

## 4. Screenshots (S3)

- "To submit your app, you must provide screenshots for the following required display sizes:
  iPhone: At least one screenshot for iPhone with Dynamic Island (medium display)." iPad only "if
  your app supports iPadOS": this app is iPhone only (`TARGETED_DEVICE_FAMILY` 1).
- Dynamic Island, medium display (iPhone 18 Pro, 17 Pro, 17, 16 Pro, 16, 15 Pro, 15, 14 Pro):
  1179 x 2556 or 1206 x 2622 portrait (landscape: the same swapped).
- Dynamic Island, large display (iPhone Air, 18 Pro Max, 17 Pro Max, 16 Pro Max, 16 Plus, 15 Pro
  Max, 15 Plus, 14 Pro Max): 1260 x 2736, 1290 x 2796 or 1320 x 2868 portrait. Optional.
- "If your app's user interface is consistent across multiple device sizes and localizations, you
  only need to provide screenshots for the highest required resolution. App Store Connect
  automatically scales them down for smaller device sizes."
- "You must include at least one screenshot and can upload up to 10 screenshots per device size."
  Formats ".jpeg, .jpg, or .png"; "Images can't include alpha channels or transparencies."
- S7 2.3.3: "Screenshots should show the app in use, and not merely the title art, login page, or
  splash screen." S7 2.3.8: metadata, screenshots included, must suit a 4+ rating.
- Older notes (and fastlane's `APP_IPHONE_67` slot) call the 6.9-inch size the required one. Apple's
  page today names the medium Dynamic Island size (6.3-inch, iPhone 17 Pro) as the required one.
  The safe set: one set at 1206 x 2622 (simulator "iPhone 17 Pro") and, if wanted, one at
  1320 x 2868 ("iPhone 17 Pro Max"). In fastlane's deliver source (master, read 2026-11-24)
  1179 x 2556 and 1206 x 2622 map to `APP_IPHONE_61`, 1290 x 2796 and 1320 x 2868 to
  `APP_IPHONE_67`.

## 5. Categories (S5)

Books, Business, Developer Tools, Education, Entertainment, Finance, Food & Drink, Games, Graphics &
Design, Health & Fitness, Lifestyle, Kids, Magazines & Newspapers, Medical, Music, Navigation, News,
Photo & Video, Productivity, Reference, Safari Extensions, Shopping, Social Networking, Sports,
Travel, Utilities, Weather (Stickers for iMessage sticker packs).

- Developer Tools: "Apps that provide tools for app development, management, and distribution.
  For example: coding, testing, debugging, workflow management, text and code editing."
- Utilities: "Apps that enable the user to solve a problem or complete a specific task. For
  example: calculators (...), clocks, measurement, time, web browsing, flashlights, screen locks,
  barcode scanners, unit conversion tools, password management, remote controls."
- "The category must accurately reflect the app's core experience" (S7 2.3).
- deliver's values: `DEVELOPER_TOOLS`, `UTILITIES`.

## 6. Age rating questionnaire (S4)

Questions: In-App Controls (Parental Controls, Age Assurance); Capabilities (Unrestricted Web
Access, User-Generated Content, Social Media, Messaging and Chat, Shared Location, Advertising);
Mature Themes (Profanity or Crude Humor, Horror/Fear, Alcohol/Tobacco/Drugs, Dating and
Relationships); Medical or Wellness; Sexuality or Nudity; Violence; Chance-Based Activities
(Gambling, Simulated Gambling, Contests, Loot Boxes). Content items are answered None, Infrequent or
Frequent.

Ratings: 4+, 9+, 13+, 16+, 18+; "Unrated" cannot be published. "Unrestricted Web Access: Users can
navigate to any webpage within the app or freely browse the web. May include: embedded browser
functionality or browser app." gives 16+. User-generated content, messaging and chat, and
advertising alone stay at 4+.

The proposed answers are in `listing-answers.md`.

## 7. Name and trademarks

- No written length or character rule is broken by "iOS-mosh" (8 characters).
- S9: Apple's trademark list says "IOS is a trademark or registered trademark of Cisco in the U.S.
  and other countries and is used under license." Apple's guidelines for third parties: "You may
  not use or register, in whole or in part, Apple, iPod, iTunes, Macintosh, iMac, or any other
  Apple trademark ... as or as part of a company name, trade name, product name, or service name".
  S7 5.2.1: "Don't use protected third-party material such as trademarks ... without permission".
  So "iOS" in an App Store name is a risk at review (not a length rule); the owner decides.
- The record's current name is "iOS-Mosh" (capital M, `listing-state.md`); a `name.txt` of
  "iOS-mosh" changes the capitalisation.

## 8. Other rules that touch this listing

- Support URL contact (S1) and S7 1.5: "Make sure your app and its Support URL include an easy way
  to contact you". The owner chose the repository's issues, with no email address. "as may be
  required by local law" (S1) refers to cases such as an EU trader, whose contact details the DSA
  makes public anyway.
- Both URLs must be publicly reachable (S6 "publicly accessible privacy policy"). Links to a
  private GitHub repository are a 404 for the reviewer.
- Privacy policy inside the app (S7 5.1.1(i)): the app's Settings has Help and About, and About
  shows the source code link but no privacy policy link. That is an app change for a later build.
- Privacy manifest (S8): "Starting May 1, 2024, apps that don't describe their use of required
  reason API in their privacy manifest file aren't accepted by App Store Connect." The repository
  has no `PrivacyInfo.xcprivacy`; the app uses `UserDefaults` (a required reason API) for its
  settings. Builds 189 and 229 were accepted for TestFlight, so App Store Connect has not refused
  them so far; whether Apple sent the reminder email (S8: "Apple sends you an email reminding you")
  is in the owner's inbox. Adding a manifest is an app change for a later build.
