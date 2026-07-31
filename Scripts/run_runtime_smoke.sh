#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAVER="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="$ROOT/.build/RuntimeSmoke"
MODULE_CACHE="$ROOT/.build/ModuleCache"
SANITIZER_FLAGS=( -parse-as-library )
if [[ "${SNOOPY_SANITIZER:-}" == "address" ]]; then
  SANITIZER_FLAGS+=( -sanitize=address )
fi
mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  "${SANITIZER_FLAGS[@]}" \
  "$ROOT/Tests/RuntimeSmoke.swift" \
  -framework AppKit -framework ScreenSaver \
  -o "$BUILD/runtime-smoke"

ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}" \
  SNOOPY_DISABLE_ENVIRONMENT_IO=1 \
  SNOOPY_DISABLE_CDN_UPDATE=1 \
  "$BUILD/runtime-smoke" "$SAVER"
