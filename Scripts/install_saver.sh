#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver}"
test -d "$SOURCE"
INFO="$SOURCE/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
case "$BUNDLE_ID" in
  local.snoopy.ScreenSaver) DEST_NAME="Snoopy.saver" ;;
  local.snoopy.ScreenSaver.1080p) DEST_NAME="Snoopy-1080p.saver" ;;
  local.snoopy.ScreenSaver.CDNLite) DEST_NAME="Snoopy-CDN-Lite.saver" ;;
  *) echo "Unsupported screen saver identifier: $BUNDLE_ID" >&2; exit 2 ;;
esac
DEST="$HOME/Library/Screen Savers/$DEST_NAME"
# ScreenSaverEngine keeps third-party bundles loaded. Stopping its preview
# helpers before and after replacement avoids the otherwise common reboot.
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
pkill -f 'com.apple.ScreenSaver.Engine' 2>/dev/null || true
mkdir -p "$HOME/Library/Screen Savers"
# Release archives have used several filenames. Remove every old copy of the
# same identifier before installing, otherwise legacyScreenSaver can load two
# bundles that export the same Objective-C principal class.
for candidate in "$HOME/Library/Screen Savers"/*.saver; do
  [[ -d "$candidate" ]] || continue
  candidate_info="$candidate/Contents/Info.plist"
  [[ -f "$candidate_info" ]] || continue
  candidate_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_info" 2>/dev/null || true)"
  if [[ "$candidate_id" == "$BUNDLE_ID" ]]; then rm -rf "$candidate"; fi
done
ditto "$SOURCE" "$DEST"
codesign --verify --deep --strict "$DEST"
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
echo "$DEST"
