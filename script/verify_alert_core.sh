#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/niang-alert-check.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
TASK_ARGS=()
if [ -n "${GPT_NIANG_SDK:-}" ]; then TASK_ARGS+=(-sdk "$GPT_NIANG_SDK"); fi
swiftc "${TASK_ARGS[@]}" -module-cache-path "$TASK_TEMP/cache" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/Usage.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/InterfaceLanguage.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/Alerts.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/Placement.swift" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/WindowFollowCadence.swift" \
  "$TASK_ROOT/script/verify_alert_core.swift" -o "$TASK_TEMP/verify"
"$TASK_TEMP/verify"
