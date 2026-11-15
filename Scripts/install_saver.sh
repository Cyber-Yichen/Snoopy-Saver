#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Library/Screen Savers"
DEST="$INSTALL_DIR/Snoopy.saver"
BACKUP="$INSTALL_DIR/.Snoopy.saver.previous"

if [[ "${1:-}" != "--locked" ]]; then
  SOURCE="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver}"
  test -d "$SOURCE"
  mkdir -p "$INSTALL_DIR"
  exec /usr/bin/lockf -k "$INSTALL_DIR/.snoopy-install.lock" /bin/bash "$0" --locked "$SOURCE"
fi
SOURCE="$2"

if [[ -e "$BACKUP" && ! -e "$DEST" ]]; then
  mv "$BACKUP" "$DEST"
elif [[ -e "$BACKUP" ]]; then
  codesign --verify --deep --strict "$DEST"
  rm -rf "$BACKUP"
fi

STAGING="$(mktemp -d "$INSTALL_DIR/.snoopy-install.XXXXXXXX")"
cleanup() {
  local result=$?
  if [[ -e "$BACKUP" && ! -e "$DEST" ]] && ! mv "$BACKUP" "$DEST"; then
    echo "Could not restore Snoopy. The previous bundle is at $BACKUP" >&2
    result=1
  fi
  rm -rf "$STAGING"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

STAGED_SAVER="$STAGING/Snoopy.saver"
ditto "$SOURCE" "$STAGED_SAVER"
codesign --verify --deep --strict "$STAGED_SAVER"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_SAVER/Contents/Info.plist")" != "local.snoopy.ScreenSaver" ]]; then
  echo "Unsupported Snoopy bundle identifier." >&2
  exit 2
fi

# ScreenSaverEngine keeps third-party bundles loaded. Stopping its preview
# helpers before and after replacement lets macOS load the new bundle.
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
pkill -f 'com.apple.ScreenSaver.Engine' 2>/dev/null || true
if [[ -e "$DEST" ]]; then mv "$DEST" "$BACKUP"; fi
mv "$STAGED_SAVER" "$DEST"
rm -rf "$BACKUP"
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
echo "$DEST"
