#!/usr/bin/env bash
set -euo pipefail
: "${JARVIS_SIMULATOR_ID:?Set JARVIS_SIMULATOR_ID to an isolated simulator}"
repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/JarvisStorageHarness.app"
mkdir -p "$app"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
cat > "$build_dir/test-entitlements.plist" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>im.talky.jarvis.storageharness</string>
<key>keychain-access-groups</key><array><string>im.talky.jarvis.storageharness</string></array>
</dict></plist>
ENTITLEMENTS
# Match rules_apple: simulator entitlements are link sections, not host signing claims.
/usr/bin/derq query -f xml -i "$build_dir/test-entitlements.plist" -o "$build_dir/entitlements.der" --raw
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$build_dir/test-entitlements.plist" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$build_dir/entitlements.der" \
    "$repo_root/submodules/TelegramCore/Sources/Jarvis/JarvisLocalModel.swift" \
    "$repo_root/Tests/JarvisLocalModelHarness/Device/StorageHarness.swift" -o "$app/JarvisStorageHarness"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>im.talky.jarvis.storageharness</string>
<key>CFBundleExecutable</key><string>JarvisStorageHarness</string>
<key>CFBundleName</key><string>JarvisStorageHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Default</string>
<key>UISceneDelegateClassName</key><string>StorageSceneDelegate</string>
</dict></array></dict></dict>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
xcrun simctl uninstall "$JARVIS_SIMULATOR_ID" im.talky.jarvis.storageharness >/dev/null 2>&1 || true
xcrun simctl install "$JARVIS_SIMULATOR_ID" "$app"
xcrun simctl launch --console "$JARVIS_SIMULATOR_ID" im.talky.jarvis.storageharness | tee "$build_dir/result.log"
rg -q '^JARVIS_KEYCHAIN_DEVICE_TEST_PASS$' "$build_dir/result.log"
if rg -q '^JARVIS_KEYCHAIN_DEVICE_TEST_FAIL' "$build_dir/result.log"; then exit 1; fi
