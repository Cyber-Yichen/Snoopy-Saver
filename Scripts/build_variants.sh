#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOWRES_ROOT="${1:?usage: build_variants.sh LOWRES_ASSET_ROOT CDN_LITE_ASSET_ROOT}"
LITE_ROOT="${2:?usage: build_variants.sh LOWRES_ASSET_ROOT CDN_LITE_ASSET_ROOT}"
OUTPUT="${SNOOPY_VARIANTS_DIR:-$ROOT/.build/Variants}"
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
STANDARD="$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver"

test -d "$LOWRES_ROOT/Assets/Resolved"
test -d "$LITE_ROOT/Assets/Resolved"
if [[ -z "$OUTPUT" || "$OUTPUT" == "/" || "$OUTPUT" == "$HOME" || "$OUTPUT" == "$ROOT" ]]; then
  echo "Refusing unsafe variants directory: $OUTPUT" >&2
  exit 2
fi
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

if [[ -d "$STANDARD" ]]; then
  ditto "$STANDARD" "$OUTPUT/Snoopy-Standard.saver"
fi

SNOOPY_ASSET_ROOT="$LOWRES_ROOT" \
SNOOPY_BUILD_DIR="$ROOT/.build/SnoopyScreenSaver-1080p" \
SNOOPY_VARIANT="1080p" \
  "$ROOT/Scripts/build_saver.sh"
ditto "$ROOT/.build/SnoopyScreenSaver-1080p/SnoopyScreenSaver.saver" \
  "$OUTPUT/Snoopy-1080p.saver"

SNOOPY_ASSET_ROOT="$LITE_ROOT" \
SNOOPY_BUILD_DIR="$ROOT/.build/SnoopyScreenSaver-CDN-Lite" \
SNOOPY_VARIANT="cdn-lite" \
  "$ROOT/Scripts/build_saver.sh"
ditto "$ROOT/.build/SnoopyScreenSaver-CDN-Lite/SnoopyScreenSaver.saver" \
  "$OUTPUT/Snoopy-CDN-Lite.saver"
if [[ -f "$LITE_ROOT/cdn-manifest.json" ]]; then
  cp "$LITE_ROOT/cdn-manifest.json" "$OUTPUT/cdn-manifest.json"
fi
cp "$ROOT/Scripts/download_cdn_assets.py" "$OUTPUT/download_cdn_assets.py"

for saver in "$OUTPUT"/*.saver; do
  codesign --verify --deep --strict "$saver"
  file "$saver/Contents/MacOS/SnoopyScreenSaver"
  du -sh "$saver"
done
