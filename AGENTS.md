# FLwatch

iOS and watchOS app that shows CGM glucose readings on the iPhone, Apple Watch, widgets, Live Activities and CarPlay. It also tracks insulin/IOB, exports to Apple Health and uploads to Nightscout. Folder and target names still use the old name "LibreWrist". This repo is a personal fork; the upstream author is Phil.

## Prerequisites

- **Full Xcode must be selected.** Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. `xcodebuild` fails when xcode-select points at Command Line Tools.
- **RoundWhiteDiscKit** is a local Swift package referenced at `../../GitHub/RoundWhiteDiscKit`, relative to the project (so `~/GitHub/RoundWhiteDiscKit`). Run `bash scripts/setup_roundwhitedisckit.sh` to install the pinned pairing and watch support revisions. Without this package, the `Libre3BLE` code and the tests don't compile.
- There are no remote SPM dependencies. Fastlane comes from `Gemfile`, so run it with `bundle exec`.

## Build and test

Project: `LibreWrist.xcodeproj`. Schemes: `FLwatch` (iPhone app, which embeds the watch app and widgets), `FLwatch Watch App`, `FLwatchWidgetExtension`, `FLwatch Watch WidgetExtension`.

```sh
# Build the iPhone app
xcodebuild -project LibreWrist.xcodeproj -scheme FLwatch \
  -destination 'generic/platform=iOS Simulator' build

# Unit tests (LibreWristTests, XCTest)
xcodebuild -project LibreWrist.xcodeproj -scheme FLwatch \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:LibreWristTests test

# Run one test: same command, narrower filter
#   -only-testing:LibreWristTests/LibreWristTests/testNightscoutMinuteDiffReturnsCompleteBackfillBurst
```

- Run `xcrun simctl list devices available` to choose a simulator.
- All unit tests are in one file, `LibreWristTests/LibreWristTests.swift`, as `func test…` methods on one XCTestCase. Add new tests there in the same style, and name them after the behaviour they check.
- The UI tests are only Xcode boilerplate. Don't depend on them.

## Layout

The project uses Xcode 16 **file-system synchronized groups**. A new `.swift` file is picked up from its folder automatically, so don't edit `project.pbxproj` to add it. Which targets get the file depends on its folder:

| Folder | Target(s) |
|---|---|
| `LibreWrist/` | iPhone app only: BLE heartbeat, notifications, CarPlay, phone views |
| `LibreWristWatch Watch App/` | Watch app only: workout mode, watch views |
| `LibreWristWidget/` | iPhone widgets and the Live Activity |
| `LibreWristWatchWidget/` | Watch complications |
| `SharedPhoneWatch/` | Shared by the phone, watch and widget targets: models, providers, App Intents, localizations |

Code that differs per platform uses `#if os(iOS)` / `#if os(watchOS)` inside `SharedPhoneWatch`.

Deployment targets are iOS 18.0 and watchOS 10.5. The project uses Swift 5 mode with `SWIFT_STRICT_CONCURRENCY = targeted`.

## Architecture

- **Providers**: `SharedPhoneWatch/Models/CGMProvider.swift`. `LibreLinkUpService.shared` is the orchestrator and holds an `activeProvider`. There are three kinds:
  - `libreLinkUp` and `dexcomShare` are cloud providers that you poll.
  - `libre3BLE` is a direct Bluetooth connection that pushes readings. `Libre3DirectManager` (large and `@MainActor`) decodes the notifications and writes to the store.
- **Store**: every provider writes into the shared `LibreLinkUpHistory` store, whatever the provider is. Each reading records its source (`CGMReadingSource`). Upload eligibility checks the reading's source, not just the active provider, because a provider switch keeps the old provider's cached readings.
- **Nightscout**: only direct-BLE readings are uploaded (`isDirectBLE`). Never re-publish cloud-follow data. The outbox and backfill logic is in `Models/Nightscout/` and has a lot of test coverage.
- **Phone↔watch**: `WatchConnectivityManager` (shared and versioned with `currentProtocolVersion`). It sends settings and provider snapshots, and it hands the Libre 3 sensor to the watch during a workout and back afterwards. If you change the message format, keep older peers working.
- **Shared state**: `SharedDefaults` reads `UserDefaults` from the App Group `APP_GROUP_ID`, which is set in `LibreWristConfig.xcconfig` and exposed through Info.plist. Secrets go in the Keychain: `PasswordKeychain`, `NightscoutSecretKeychain`, `DexcomShareTokenStore`, `Libre3PINStore`.
- Most managers are `static let shared` singletons.
- **Persisted Codable data must stay backward compatible.** New fields must decode from old snapshots. The tests contain `…DecodesPre…Snapshot` / `Legacy…Decodes…` cases; add one when you change a persisted model.

## Conventions

- Strings are in `SharedPhoneWatch/Localizations/Localizable.xcstrings`, a String Catalog with source language `en` and 10 locales. Put user-facing text in the catalog; don't hardcode it.
- Developer-only features (for example, Libre 3 Parallel pairing) are hidden behind developer mode.
- This is a medical-adjacent app. Changes to glucose values, units, timestamps, alerts, IOB or backfill must not drop, duplicate or shift readings. Add a test for these changes.
- Diagnostics go through `Libre3DiagnosticsLog`, `DebugMessageSingleton` and OSLog. Never log PINs, tokens or passwords.

## Git and versioning

- Remotes: `origin` = fork (`richard-gibson/FLwatch`), `upstream` = original (`poml88/FLwatch`). Push to `origin` only.
- The working branch is `moresimple`. Feature branches are named `feature/…` and `fix/…` and are merged into it.
- Commit subjects are short, imperative and describe the change from the user's view, e.g. "Show trend in unused Live Activity space".
- The version and build number are in `LibreWristConfig.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Bump them in their own commit, e.g. "Version bump 3.1.7.242". Fastlane does not increment the build number.

## Release (only when explicitly asked)

The scripts in `scripts/` wrap the lanes in `fastlane/Fastfile`. They upload to App Store Connect, so run them only on explicit request:
- `testflight_internal.sh` / `testflight_external.sh`: upload a TestFlight build.
- `release.sh [--localized]`: upload an App Store build. Release notes come from `fastlane/whats_new/<locale>/release_notes.txt`. `SUBMIT_FOR_REVIEW=1` and `AUTO_RELEASE=1` are opt-in.
- `upload_whats_new.sh` and `upload_descriptions.sh` upload metadata only.
- Credentials come from `.env.fastlane.local` (gitignored). Never commit `.env*` or `*.p8` files.

## Gitignored local material

These directories may exist locally as reference material and are never committed: `libre3-ble-integration/`, `dexcom-api-docs/`, `smartguide-integration/`, `power_profile_traces/`, `support-analysis/`. Comments in the code sometimes cite "PLAN §N". That refers to a planning doc that isn't in the repo.
