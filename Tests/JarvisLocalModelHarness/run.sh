#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
source_file="$repo_root/submodules/TelegramCore/Sources/Jarvis/JarvisLocalModel.swift"
swiftc -swift-version 5 -warnings-as-errors "$repo_root"/submodules/TelegramCore/Sources/Jarvis/*.swift "$repo_root/Tests/JarvisLocalModelHarness/main.swift" -o "$test_dir/checks"
"$test_dir/checks"
sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
swiftc -swift-version 5 -warnings-as-errors -typecheck -sdk "$sim_sdk" -target arm64-apple-ios15.0-simulator "$repo_root"/submodules/TelegramCore/Sources/Jarvis/*.swift
