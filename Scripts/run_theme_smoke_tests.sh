#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="$ROOT/.build/ThemeSmoke"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$BUILD" "$MODULE_CACHE"
FIXTURE="$(mktemp -d "$BUILD/Fixtures.XXXXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "$ROOT"/Sources/{Catalog,Environment,Models}.swift \
  "$ROOT/Tests/ThemeSmokeTests.swift" -o "$BUILD/theme-smoke"
SNOOPY_DISABLE_ENVIRONMENT_IO=1 "$BUILD/theme-smoke" "$FIXTURE" "$@"
