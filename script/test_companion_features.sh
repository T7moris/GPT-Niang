#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="${1:?Pass the Swift release products directory}"
TEST_DIR="${2:?Pass a new scratch directory for feature tests}"
mkdir -p "$TEST_DIR"
SDK_PATH="${GPT_NIANG_SDK:-$(xcrun --show-sdk-path)}"
swiftc -D COMPANION_FEATURE_STANDALONE -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" -I "$PRODUCTS" \
  "$PRODUCTS/GPTNiangCore.o" "$PRODUCTS/GPTNiangUpdate.o" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/WidgetModel.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/AudioImport.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/CharacterLibrary.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/CharacterInteraction.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/SystemMusicCapture.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/MusicController.swift" \
  "$ROOT_DIR/macos/Tests/GPTNiangMacTests/CompanionFeatureTests.swift" \
  -o "$TEST_DIR/companion-feature-tests"
cp -R "$PRODUCTS/GPTNiangMac_GPTNiangCore.bundle" "$TEST_DIR/"
"$TEST_DIR/companion-feature-tests" "$TEST_DIR/fixtures"
