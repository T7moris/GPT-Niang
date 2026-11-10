#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/niang-host-check.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
TASK_ARGS=()
if [ -n "${GPT_NIANG_SDK:-}" ]; then TASK_ARGS+=(-sdk "$GPT_NIANG_SDK"); fi
swiftc ${TASK_ARGS[@]+"${TASK_ARGS[@]}"} -module-cache-path "$TASK_TEMP/cache" \
  "$TASK_ROOT/macos/Sources/GPTNiangCore/HostLink.swift" \
  "$TASK_ROOT/script/verify_host_link.swift" -o "$TASK_TEMP/verify"
"$TASK_TEMP/verify"
