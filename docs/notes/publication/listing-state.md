# App Store listing: state of the record and what deliver can do

> Addresses, ports and details of the author's own network were removed before publication.

Read on 2026-11-24 (about 03:00 to 03:15 UTC) from yellow, through `scripts/mac.sh --ssh` on
charlie, with fastlane 2.242.0 (Homebrew, Ruby 4.0.9) and the project's App Store Connect API key
(`~/signing/asc.json`, loaded with `Spaceship::ConnectAPI::Token.from_json_file`, exactly as
`App/fastlane/Fastfile` `connect` does). Only GET requests were made: four throw-away read-only
lanes in the Mac's `/tmp/asc-read*` (deleted afterwards). Nothing was written to App Store Connect.
Masked logs: `out/yellow/store/listing-readstate{,2,3,4}.log`; fastlane sources read:
`out/yellow/store/listing-deliver-src{1..5}.log`.

`fastlane deliver download_metadata` was NOT run: it writes the App Review contact fields (the
owner's name, phone and email) into `review_information/*.txt`, and personal details go into no
file. The same data came from spaceship directly (field names and lengths only).
`download_screenshots` was not needed: the record has no screenshot sets.

## 1. The record today

App: name **"iOS-Mosh"** (capital M; the repo and docs say "iOS-mosh"), primary locale en-US,
SKU set, bundle id `us.v9n.ios-mosh`. No live version, no review submissions.

| Item | State |
|---|---|
| App Store versions | one: **0.1**, iOS, `PREPARE_FOR_SUBMISSION` (both appStoreState and appVersionState), created 2026-11-20 by the app record, release type AFTER_APPROVAL |
| Build attached to 0.1 | none |
| Builds | 0.2 (229) VALID, 0.1 (189) VALID, neither expired |
| Version locales | en-US only |
| en-US version texts | description EMPTY, keywords EMPTY, promotional text EMPTY, marketing URL EMPTY, support URL EMPTY, whats_new EMPTY |
| Copyright | EMPTY |
| Screenshots | 0 screenshot sets, 0 preview sets |
| App info (edit) | state PREPARE_FOR_SUBMISSION; no live app info |
| App info locales | en-US only: name set ("iOS-Mosh"), subtitle EMPTY, privacy policy URL EMPTY, privacy choices URL EMPTY |
| Categories | primary NONE, secondary NONE |
| Age rating | declaration exists but unanswered: of 32 attributes only the three overrides (`ageRatingOverride`, `ageRatingOverrideV2`, `koreaAgeRatingOverride` = NONE) are set; computed `appStoreAgeRating` null |
| Content rights declaration | null (not answered) |
| Price | no price: `appPriceSchedules/{id}` answers with a bare resource, but manual and automatic prices are 404 |
| Availability | none: `appAvailabilities` (v2) for the app is 404, so no territories chosen |
| App Privacy (data collection) | not readable with the key: the official API has no `dataUsages` / `dataUsagePublishState` relationship (404 "URL path is not valid") |
| App Review contact | **already filled**: first name, last name, phone, email are all set; demo account empty, `demo_account_required` false; review **notes set (148 chars)**; 0 review attachments. Values not read out. |
| Phased release / reset ratings | none |

The App Review contact fields are therefore not empty today (someone, likely the owner, typed them
in the web interface). The upload must leave them alone; see section 3.

## 2. What the API key may do

- The API does not report a key's own role, so the role is **not known directly**. `asc.json`
  holds `issuer_id`, `key_id`, `key`, `in_house` (values not read).
- Indications: the key can read the team's user list, which Apple reserves for Admin keys; this repo's `signing_dist` lane created a distribution
  certificate and the `testers` lane manages beta groups with it. Most likely **Admin**, which
  may edit metadata, screenshots, categories, age rating, pricing and availability. Editing App
  Store metadata needs App Manager or Admin. Nothing was tried that writes.

## 3. Required fields: who can set them

"key" = deliver (or spaceship) can set it with the API key; "web" = App Store Connect web
interface only (or an Apple ID login, which needs the owner's 2FA); "owner" = his own entry.

| Field (required unless noted) | Today | Who |
|---|---|---|
| Name | set | key (`name.txt`; only if a change is wanted) |
| Subtitle (optional) | empty | key |
| Description | empty | key |
| Keywords | empty | key |
| Support URL | empty | key (must be reachable by anyone: see note A) |
| Marketing URL (optional) | empty | key |
| Promotional text (optional) | empty | key |
| Privacy policy URL | empty | key (`privacy_url.txt`; note A) |
| Copyright | empty | key (`copyright` option or `copyright.txt`) |
| Primary category (secondary optional) | none | key (`primary_category`, e.g. `DEVELOPER_TOOLS` or `UTILITIES`) |
| iPhone screenshots, 6.9" (1320x2868 etc.) or 6.5"; 1 to 10 | none | key. App is iPhone only (`TARGETED_DEVICE_FAMILY` 1): no iPad screenshots needed |
| Age rating questionnaire | unanswered | key via `app_rating_config_path` (JSON, raw API keys pass through), but fastlane 2.242's model lacks some of Apple's current questions (e.g. `datingAndRelationships`, `sharedLocation`): the web interface is the safe way |
| Content rights ("contains third-party content?") | null | web (deliver sends it only inside `submission_information` at submit; a raw API PATCH of the app would work but is not deliver) |
| Price | none | web (deliver's `price_tier` uses the removed price-tier API) |
| Availability (territories) | none | web |
| App Privacy (data collection answers) | not readable | web (fastlane's `upload_app_privacy_details_to_app_store` logs in with an Apple ID, not the key) |
| App Review contact name, phone, email | already set | owner (leave untouched) |
| Sign-in info / review notes | demo none, notes set | owner (a mosh app needs a reachable host for review; his call) |
| Build attached to the version | none | web, or deliver only on the submit path; needed only to submit |
| Version string | 0.1 | key (`app_version`, see section 5) |
| Export compliance | from `ITSAppUsesNonExemptEncryption` = NO in the build | done |
| EU trader status (DSA, account level) | not readable | owner, web |

Note A: the owner wants the support page and privacy policy as files in this repository. While
the repository is PRIVATE, a github.com link to them is a 404 for Apple's reviewer and for users;
Apple requires both URLs to be reachable. They work only once the repo is public, or if the files
are served from somewhere public.

## 4. The deliver call (texts and screenshots, no binary, no submission)

A lane in `App/fastlane/Fastfile`, run through `scripts/mac-testflight.sh` style (keychain not
needed: no signing). Use a scratch metadata dir that holds ONLY the files to set:
`metadata/en-US/{description,keywords,support_url,privacy_url,subtitle,promotional_text}.txt`
(optional `marketing_url.txt`; no `name.txt` unless the name changes; no `release_notes.txt`;
**no `review_information/` folder**), and `screenshots/en-US/*.png` at 1320x2868.

```ruby
deliver(
  api_key_path: KEY, app_identifier: BUNDLE, platform: "ios",
  metadata_path: "<scratch>/metadata", screenshots_path: "<scratch>/screenshots",
  languages: ["en-US"], ignore_language_directory_validation: false,
  skip_binary_upload: true,            # no ipa / pkg given either
  skip_app_version_update: true,       # keep 0.1; drop this and set app_version: "0.2" to rename (sec. 5)
  submit_for_review: false,
  run_precheck_before_submit: false,   # else precheck runs anyway and, with an API key and the
  precheck_include_in_app_purchases: false, # default IAP check true, ends in user_error!
  force: true,                         # no HTML preview / confirmation
  overwrite_screenshots: false,        # 0 sets today; true deletes every set of the uploaded locale first
  copyright: "#{Time.now.year} <author name as in git log>",
  primary_category: "DEVELOPER_TOOLS"
  # NOT passed: app_review_information, price_tier, automatic_release, app_rating_config_path,
  # submission_information, phased_release, reset_ratings, edit_live, reject_if_possible
)
```

What that does, from the 2.242.0 source (`deliver/lib/deliver/{runner,upload_metadata,
upload_screenshots,upload_price_tier}.rb`):
- Version texts and copyright go on the edit version (0.1); app-info texts on the edit app info.
  Only non-empty values are sent; fields without a file stay as they are.
- `release_notes` is skipped anyway ("first version of the app").
- Review contact: `review_information` returns early when `app_review_information` is empty and
  there is no `review_information/` folder, so the set contact fields and notes are untouched.
- `review_attachment_file`: with no `app_review_attachment_file` option it **deletes all existing
  review attachments**. There are 0 today, so harmless now; on a later rerun it would remove any
  the owner had added.
- `automatic_release` unset: release type is not sent (stays AFTER_APPROVAL).
- `phased_release` and `reset_ratings` default to false: deliver looks for an existing phased
  release / reset request (none; the lookup errors and is rescued) and changes nothing.
- Categories: only the keys given are PATCHed (`patch_app_info_categories` includes a
  relationship only when the key is in the map), so passing only `primary_category` leaves
  secondary empty, which is allowed.
- Price: `UploadPriceTier` returns at once without `price_tier`.
- No build is attached: build selection happens only on the `submit_for_review` path.
- Locales: only en-US is used; deliver creates a locale only when a folder for it exists.
- Screenshots: display type is detected from pixel size; 1320x2868 and 1290x2796 map to
  `APP_IPHONE_67` (the 6.9" slot); max 10 per set; uploaded files are sorted by file name.

## 5. Version string 0.1 against build 0.2

- Without `app_version` and without an ipa, deliver's `verify_version` does not run: everything
  lands on the existing **0.1** version, unchanged in name.
- With `app_version: "0.2"` and `skip_app_version_update` false, `App#ensure_version!` finds the
  edit version 0.1 and PATCHes its `versionString` to "0.2" (a rename of the same record, texts
  and screenshots kept; it creates a new version only when there is no edit version at all).
- Submitting later needs a build whose version matches the App Store version: 0.2 (229) can be
  attached only after the rename; on 0.1 only build 189 fits. Not tried.

## 6. Other observations

- The record's name is "iOS-Mosh", not "iOS-mosh"; a `name.txt` would change it (the name must be
  unique on the store).
- `git log --format=%an` has two spellings of the owner's name (170 commits and 1 commit) plus
  "Claude" (60); the copyright line should use the 170-commit spelling, the owner to confirm.
