#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="${1:?usage: run_lite_catalog_smoke.sh RESOURCES_PATH [EXTERNAL_MEDIA_ROOT]}"
EXTERNAL_MEDIA="${2:-$ROOT/.build/LiteCatalogSmoke/EmptyExternalMedia}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="$ROOT/.build/LiteCatalogSmoke"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" -parse-as-library \
  "$ROOT"/Sources/*.swift "$ROOT/Tests/LiteCatalogSmoke.swift" \
  -framework AppKit -framework AVFoundation -framework CoreLocation \
  -framework CoreImage -framework CryptoKit -framework ImageIO \
  -framework QuartzCore -framework ScreenSaver \
  -o "$BUILD/lite-catalog-smoke"

if [[ $# -ge 2 ]]; then
  SNOOPY_MEDIA_ROOT="$EXTERNAL_MEDIA" \
    "$BUILD/lite-catalog-smoke" "$RESOURCES" hydrated
else
  SNOOPY_MEDIA_ROOT="$EXTERNAL_MEDIA" \
    "$BUILD/lite-catalog-smoke" "$RESOURCES"
fi
