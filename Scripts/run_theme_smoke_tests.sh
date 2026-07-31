#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver/Contents/Resources}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="$ROOT/.build/ThemeSmokeTests"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -parse-as-library -Onone -module-name SnoopyThemeSmokeTests \
  "$ROOT"/Sources/*.swift "$ROOT/Tests/ThemeSmokeTests.swift" \
  -framework AppKit -framework AVFoundation -framework CoreLocation \
  -framework CoreImage -framework CryptoKit -framework ImageIO \
  -framework QuartzCore -framework ScreenSaver \
  -o "$BUILD/theme-smoke-tests"

rm -rf "$BUILD/ExternalMedia"
SNOOPY_MEDIA_ROOT="$BUILD/ExternalMedia" "$BUILD/theme-smoke-tests" "$RESOURCES"
