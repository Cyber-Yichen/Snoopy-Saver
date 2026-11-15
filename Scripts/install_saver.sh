#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Library/Screen Savers"
DEST="$INSTALL_DIR/Snoopy.saver"
BACKUP_DIR="$INSTALL_DIR/.snoopy-install-backup"
IDENTIFIER="local.snoopy.ScreenSaver"

if [[ "${1:-}" != "--locked" ]]; then
  SOURCE="${1:-$ROOT/.build/SnoopyScreenSaver/SnoopyScreenSaver.saver}"
  test -d "$SOURCE"
  mkdir -p "$INSTALL_DIR"
  exec /usr/bin/lockf -k "$INSTALL_DIR/.snoopy-install.lock" /bin/bash "$0" --locked "$SOURCE"
fi
SOURCE="$2"

bundle_identifier() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"
}

for previous in "$BACKUP_DIR"/*.saver; do
  [[ -e "$previous" ]] || continue
  previous_destination="$INSTALL_DIR/${previous##*/}"
  if [[ -e "$previous_destination" ]]; then
    codesign --verify --deep --strict "$previous_destination"
    rm -rf "$previous"
  else
    mv "$previous" "$previous_destination"
  fi
done

installed=()
for candidate in "$INSTALL_DIR"/*.saver; do
  [[ -d "$candidate" ]] || continue
  if [[ "$(bundle_identifier "$candidate" 2>/dev/null || true)" == "$IDENTIFIER" ]]; then
    installed+=("$candidate")
  fi
done
if [[ "${#installed[@]}" -gt 1 ]]; then
  echo "Multiple installed Snoopy bundles share the standard identifier." >&2
  printf '  %s\n' "${installed[@]}" >&2
  exit 2
elif [[ "${#installed[@]}" -eq 1 ]]; then
  DEST="${installed[0]}"
elif [[ -e "$DEST" ]]; then
  echo "The destination already exists with an unrecognized bundle identifier: $DEST" >&2
  exit 2
fi
BACKUP="$BACKUP_DIR/${DEST##*/}"

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
if [[ "$(bundle_identifier "$STAGED_SAVER")" != "$IDENTIFIER" ]]; then
  echo "Unsupported Snoopy bundle identifier." >&2
  exit 2
fi

# ScreenSaverEngine keeps third-party bundles loaded. Stopping its preview
# helpers before and after replacement lets macOS load the new bundle.
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
pkill -f 'com.apple.ScreenSaver.Engine' 2>/dev/null || true
if [[ -e "$DEST" ]]; then
  mkdir -p "$BACKUP_DIR"
  mv "$DEST" "$BACKUP"
fi
mv "$STAGED_SAVER" "$DEST"
rm -rf "$BACKUP"
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
echo "$DEST"
