# Building Talky for iOS

## Prerequisites

- macOS and Xcode; see `versions.json` for the source's pinned versions.
- Python 3 and the Xcode command-line tools.
- All pinned Git submodules (`git submodule update --init --recursive`).
- Your own Telegram API ID/hash if required by your target service.
- Your own Apple team, application identifiers and signing material for device builds.

Use `Make.py` to build the full `Telegram/Telegram` target. Simulator and device builds are distinct artifacts; an arm64 simulator IPA cannot be uploaded to App Store Connect.

## Local configuration

Copy `build-system/talky-configuration.example.json` to `build-system/talky-configuration.local.json` and replace every `YOUR_*` value. Choose your own bundle ID and Apple team. This local file is ignored by Git. The tracked `appstore-configuration.json` is also a placeholder example, not production credentials.

The product source contains Talky's public service address and application identifiers. These are not login credentials. Running your own backend requires adapting service configuration and the network address setup in `submodules/TelegramCore/Sources/Network/Network.swift`.

## Simulator

```sh
scripts/build-ios.sh --no-launch
```

The wrapper uses `debug_sim_arm64` and explicitly permits the installed Xcode version override. It creates the local example on first use and stops until you fill in your settings. Output is `out/build-artifacts/talky.ipa`.

To install, extract the newly built IPA and use `xcrun simctl install <UDID> <extracted-app>`. When replacing an existing build with the same build number, check that the new binary actually replaced the installed bundle. Preserve the separate simulator data container.

## Development device

Create a development profile for your main bundle ID, including the appropriate App Group and push capability. Put profiles outside the repository in `~/talky-ios-profiles/profiles/`; the main profile must resolve to `Telegram.mobileprovision`.

```sh
scripts/build-ios.sh --device --no-launch --profiles "$HOME/talky-ios-profiles"
```

This development wrapper disables the six extensions. Each extension needs its own profile before a distribution build can include it.

## Distribution

Use your own production configuration outside Git, set `is_internal_build` to `false` and `is_appstore_build` to `true`, and configure your own App Store ID and products. Required profile suffixes are `.Share`, `.NotificationContent`, `.NotificationService`, `.Intents`, `.Widget` and `.BroadcastUpload`.

Remove the development-only `build --//Telegram:disableExtensions` and `build --//Telegram:disableProvisioningProfiles` flags for the distribution invocation, then restore your local development settings afterward. Do not pass `--xcodeManagedCodesigning` when supplying explicit distribution profiles.

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion \
  --cacheDir "$HOME/talky-ios-bazel-cache" build \
  --buildNumber 1 \
  --configurationPath /path/outside/git/release-configuration.json \
  --codesigningInformationPath /path/outside/git/signing-material \
  --configuration release_arm64 \
  --outputBuildArtifactsPath out/appstore
```

Retain the generated dSYMs. Verify signatures, bundle/profile identifiers, production push entitlement and matching versions for the main app and all extensions before upload. Real signing certificates, APNs keys, App Store Connect keys, review accounts and backend deployment configuration are not distributed here.

The optional watch app is not embedded by default and needs its own build and signing setup. Legacy third-party map link resolution has no embedded provider credentials in the public source; it falls back to sharing the URL.

For upstream context, see [UPSTREAM_BUILDING.md](UPSTREAM_BUILDING.md).
