#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/VariantCollisionSmoke"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Tests/VariantCollisionSmoke.swift" \
  -framework AppKit -framework ScreenSaver \
  -o "$BUILD/variant-collision-smoke"

set +e
OUTPUT="$("$BUILD/variant-collision-smoke" "$@" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUTPUT"
if [[ $STATUS -ne 0 ]]; then exit "$STATUS"; fi
if [[ "$OUTPUT" == *"implemented in both"* ]]; then
  echo "Objective-C runtime class collision detected." >&2
  exit 1
fi
