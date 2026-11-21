# FLwatch App

## Homepage: [https://flwatch.app/](https://flwatch.app/)


![Exported PNG image6](https://github.com/user-attachments/assets/68ec6106-4866-442d-8e78-bc80ddba2608)![Exported PNG image1 Kopie](https://github.com/user-attachments/assets/68a92ba6-c590-4b3f-87ad-9ab77c36cb8c)

## Build from source

Install full Xcode and an iOS simulator runtime. Check that `xcode-select -p` points to the full Xcode installation. If it points to Command Line Tools, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

From the FLwatch checkout, install the pinned RoundWhiteDiscKit dependency and build the `FLwatch` scheme:

```sh
bash scripts/setup_roundwhitedisckit.sh
xcodebuild -project LibreWrist.xcodeproj -scheme FLwatch \
  -destination 'generic/platform=iOS Simulator' build
```

The setup script installs RoundWhiteDiscKit at the relative path the Xcode project expects, typically `~/GitHub/RoundWhiteDiscKit` when FLwatch is in `~/sandbox/FLwatch`. If that path already contains a different checkout, move it aside before running the script.

To run the unit tests, use `xcrun simctl list devices available` to find an installed iPhone simulator and substitute its name below.

```sh
xcodebuild -project LibreWrist.xcodeproj -scheme FLwatch \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LibreWristTests test
```

The simulator supports build and unit-test verification. Libre sensor NFC pairing requires a physical iPhone and a signing team that supports NFC Tag Reading. See the [verified simulator baseline](docs/libre2plus-direct-ble-analysis.md#simulator-baseline) for the exact dependency revisions and test results.

