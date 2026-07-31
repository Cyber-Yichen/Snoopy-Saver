#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_ROOT="${1:?usage: downscale_heic_assets.sh ASSET_ROOT [MAX_PIXEL_SIZE] [QUALITY]}"
MAXIMUM="${2:-1920}"
QUALITY="${3:-0.85}"
BUILD="$ROOT/.build/HEICDownscaler"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$MODULE_CACHE" -parse-as-library \
  "$ROOT/Scripts/downscale_heic_assets.swift" \
  -framework CoreGraphics -framework ImageIO \
  -o "$BUILD/downscale-heic-assets"

"$BUILD/downscale-heic-assets" "$ASSET_ROOT" "$MAXIMUM" "$QUALITY"
