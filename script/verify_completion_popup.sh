#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/niang-popup-check.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
TASK_ARGS=()
if [ -n "${GPT_NIANG_SDK:-}" ]; then TASK_ARGS+=(-sdk "$GPT_NIANG_SDK"); fi
TASK_ARGS+=(-module-cache-path "$TASK_TEMP/cache")
printf 'import Foundation\nextension Bundle { static var module: Bundle { .main } }\n' > "$TASK_TEMP/BundleResources.swift"
swiftc "${TASK_ARGS[@]}" -emit-library -emit-module -module-name GPTNiangCore \
  "$TASK_ROOT"/macos/Sources/GPTNiangCore/*.swift "$TASK_TEMP/BundleResources.swift" \
  -emit-module-path "$TASK_TEMP/GPTNiangCore.swiftmodule" -o "$TASK_TEMP/libGPTNiangCore.dylib"
swiftc "${TASK_ARGS[@]}" -I "$TASK_TEMP" -L "$TASK_TEMP" -lGPTNiangCore \
  "$TASK_ROOT/macos/Sources/GPTNiangMac/WidgetModel.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangMac/AlertCoordinator.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangMac/AlertNotifications.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangMac/CompletionPopup.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangMac/OriginalBubbleShape.swift" \
  "$TASK_ROOT/script/verify_completion_popup.swift" -o "$TASK_TEMP/verify"
"$TASK_TEMP/verify"
