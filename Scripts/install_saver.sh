#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver}"
DEST="$HOME/Library/Screen Savers/Snoopy.saver"
test -d "$SOURCE"
# ScreenSaverEngine keeps third-party bundles loaded. Stopping its preview
# helpers before and after replacement avoids the otherwise common reboot.
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
pkill -f 'com.apple.ScreenSaver.Engine' 2>/dev/null || true
mkdir -p "$HOME/Library/Screen Savers"
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"
codesign --verify --deep --strict "$DEST"
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
echo "$DEST"
