#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-niang-window-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SDK_PATH="${GPT_NIANG_SDK:-$(xcrun --show-sdk-path)}"

# Run the same assertions as WindowFollowTests without requiring XCTest or SwiftUI.
swiftc -D WINDOW_FOLLOW_STANDALONE -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT_DIR/macos/Sources/GPTNiangMac/WindowFollowPolicy.swift" \
  "$ROOT_DIR/macos/Tests/GPTNiangMacTests/WindowFollowTests.swift" \
  -o "$TEST_DIR/window-follow-tests"
"$TEST_DIR/window-follow-tests"
