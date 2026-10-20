#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="${1:?Pass the Swift release products directory}"
TEST_DIR="${2:?Pass a scratch directory for music tests}"
mkdir -p "$TEST_DIR"
SDK_PATH="${GPT_NIANG_SDK:-$(xcrun --show-sdk-path)}"
swiftc -O -D MUSIC_STANDALONE -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT_DIR/macos/Sources/GPTNiangCore/MusicRhythm.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangCore/MusicMotion.swift" \
  "$ROOT_DIR/macos/Tests/GPTNiangCoreTests/MusicRhythmTests.swift" -o "$TEST_DIR/rhythm-tests"
"$TEST_DIR/rhythm-tests"
swiftc -O -D MUSIC_INTEGRATION_STANDALONE -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0" \
  -I "$PRODUCTS" "$PRODUCTS/GPTNiangCore.o" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/SystemMusicCapture.swift" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/MusicController.swift" \
  "$ROOT_DIR/macos/Tests/GPTNiangMacTests/MusicIntegrationTests.swift" -o "$TEST_DIR/integration-tests"
cp -R "$PRODUCTS/GPTNiangMac_GPTNiangCore.bundle" "$TEST_DIR/"
"$TEST_DIR/integration-tests"
