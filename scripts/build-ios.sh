#!/bin/bash
# Build Talky iOS (Telegram-iOS 13.x base) for the simulator or a device.
#
# Usage:
#   scripts/build-ios.sh                    # simulator (debug_sim_arm64), installs & launches
#   scripts/build-ios.sh --no-launch        # build only
#   scripts/build-ios.sh --device           # device debug build (see DEVICE SIGNING below)
#
# Environment notes (macOS 27 / Xcode 27 era):
#   - Xcode must be installed; a version different from the official pin
#     (see versions.json) is fine — Make.py gets --overrideXcodeVersion.
#   - The Metal toolchain is a per-Xcode-build component: after EVERY Xcode
#     update run `xcodebuild -downloadComponent MetalToolchain` (the script
#     does this automatically when `xcrun metal --version` fails).
#   - Bazel is downloaded automatically by Make.py (pinned in versions.json).
#
# Configuration: build-system/talky-configuration.local.json (gitignored;
# first run copies the template and asks for credentials).
#
# DEVICE SIGNING (current route — main app only):
#   - Main app signs with the local dev profile matched by UUID in
#     Telegram/BUILD (dev_talk: com.qxdev.talky + push + registered devices).
#   - --//Telegram:disableExtensions drops the six extensions from the build
#     graph: they would each need their own profile (app groups / push).
#     Bring them back by creating per-extension profiles, then removing the
#     disableExtensions flag below and restoring the extension selects.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

DEVICE=0
NO_LAUNCH=0
PROFILES_DIR="$HOME/talky-ios-profiles"
while [ $# -gt 0 ]; do
	case "$1" in
		--device) DEVICE=1 ;;
		--no-launch) NO_LAUNCH=1 ;;
		--profiles) PROFILES_DIR="$2"; shift ;;
		*) fail "unknown option: $1" ;;
	esac
	shift
done

command -v python3 >/dev/null || fail "python3 not found"
command -v xcodebuild >/dev/null || fail "Xcode not found"

# 1. Submodules (first run on a fresh clone).
if [ -z "$(ls submodules/TgVoipWebrtc 2>/dev/null)" ] || [ -z "$(ls third-party/webrtc 2>/dev/null)" ]; then
	log "Initializing submodules (first run, large download)"
	git submodule update --init --recursive
fi

# 2. Local build configuration (gitignored; never commit).
config="build-system/talky-configuration.local.json"
if [ ! -f "$config" ]; then
    cp build-system/talky-configuration.example.json "$config"
    fail "Created $config. Set your own API ID, API hash, Apple team and bundle ID, then rerun. See docs/BUILDING.md."
fi

# 3. Metal toolchain — per-Xcode-build component, re-download after Xcode updates.
if ! xcrun metal --version >/dev/null 2>&1; then
	log "Metal toolchain missing for this Xcode — downloading component"
	xcodebuild -downloadComponent MetalToolchain
fi

BAZEL_FLAGS=(--overrideXcodeVersion --cacheDir "$HOME/talky-ios-bazel-cache")

# The provisioning-disable flag is required for simulator builds (no
# profiles exist) but fatal for device builds (rules_apple needs the main
# app profile). Device builds additionally drop the extensions
# (disableExtensions) — they each need their own profile.
# Flip the .bazelrc lines according to the mode.
prov_line="build --//Telegram:disableProvisioningProfiles"
ext_line="build --//Telegram:disableExtensions"
if [ "$DEVICE" -eq 1 ]; then
	# device: provisioning ON (main app profile), extensions OFF (no profiles for them)
	grep -v "^${prov_line}$" .bazelrc | grep -v "^${ext_line}$" > .bazelrc.tmp && mv .bazelrc.tmp .bazelrc
	echo "$ext_line" >> .bazelrc
else
	# sim: provisioning OFF (no profiles at all), extensions included
	grep -v "^${prov_line}$" .bazelrc | grep -v "^${ext_line}$" > .bazelrc.tmp && mv .bazelrc.tmp .bazelrc
	echo "$prov_line" >> .bazelrc
fi

if [ "$DEVICE" -eq 0 ]; then
	# ---------------------------------------------------------------- sim
	log "Building for simulator (debug_sim_arm64)"
	python3 build-system/Make/Make.py "${BAZEL_FLAGS[@]}" build \
		--buildNumber "${IOS_BUILD_NUMBER:-1}" \
		--configurationPath "$config" \
		--xcodeManagedCodesigning \
		--configuration debug_sim_arm64 \
		--outputBuildArtifactsPath out/build-artifacts \
		> build-ios-sim.log 2>&1 || {
		grep -m5 "ERROR" build-ios-sim.log || true
		fail "build failed — see build-ios-sim.log"
	}

	ipa="out/build-artifacts/Telegram.ipa"
	[ -f "$ipa" ] || fail "expected $ipa not found"
	mv -f "$ipa" "out/build-artifacts/talky.ipa"
	ipa="out/build-artifacts/talky.ipa"

	if [ "$NO_LAUNCH" -eq 0 ]; then
		log "Installing to booted simulator"
		udid="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)"
		if [ -z "$udid" ]; then
			log "No booted simulator — booting iPhone 16 Pro"
			xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
			udid="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)"
		fi
		[ -n "$udid" ] || fail "no simulator available"
		rm -rf /tmp/talky-ipa && mkdir -p /tmp/talky-ipa
		unzip -qo "$ipa" -d /tmp/talky-ipa
		xcrun simctl install "$udid" /tmp/talky-ipa/Payload/Telegram.app
		xcrun simctl launch "$udid" com.qxdev.talky \
			&& log "Launched on simulator ($udid)" \
			|| fail "launch failed (check build-ios-sim.log)"
	fi
	log "Done. IPA: $ipa"
else
	# -------------------------------------------------------------- device
	log "Building for device (debug_arm64) with profiles from $PROFILES_DIR"
	python3 build-system/Make/Make.py "${BAZEL_FLAGS[@]}" build \
		--buildNumber "${IOS_BUILD_NUMBER:-1}" \
		--configurationPath "$config" \
		--codesigningInformationPath "$PROFILES_DIR" \
		--configuration debug_arm64 \
		--outputBuildArtifactsPath out/build-artifacts-device \
		> build-ios-device.log 2>&1 || {
		grep -m5 "ERROR" build-ios-device.log || true
		fail "device build failed — see build-ios-device.log"
	}

	ipa="out/build-artifacts-device/Telegram.ipa"
	[ -f "$ipa" ] || fail "expected $ipa not found"
	mv -f "$ipa" "out/build-artifacts-device/talky.ipa"
	ipa="out/build-artifacts-device/talky.ipa"
	if [ "$NO_LAUNCH" -eq 1 ]; then
		log "Done. IPA: $ipa"
		exit 0
	fi
	stage="$(mktemp -d "${TMPDIR:-/tmp}/talky-device.XXXXXX")"
	unzip -qo "$ipa" -d "$stage"
	app="$(find "$stage/Payload" -maxdepth 1 -name '*.app' | head -1)"
	[ -n "$app" ] || fail "built .app not found in IPA"
	log "Installing to device"
	udid="$(xcrun devicectl list devices 2>/dev/null | grep 'physical' | grep -oE '[0-9A-F]{8}-[0-9A-F]{8,24}' | head -1)"
	[ -n "$udid" ] || fail "no physical device connected — plug in, unlock, trust this computer, then rerun"
	xcrun devicectl device install app --device "$udid" "$app"
	log "Done — launch Talky on the device (bundle id com.qxdev.talky)."
fi
