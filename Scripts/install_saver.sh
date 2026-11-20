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

has_supported_identity() {
  [[ ! -L "$1" && "$(bundle_identifier "$1" 2>/dev/null)" == "$IDENTIFIER" &&
     "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$1/Contents/Info.plist" 2>/dev/null)" == "SnoopyScreenSaverView" ]]
}

has_sprite_media() {
  local metadata="$1" kind="$2" base type start end digits frame index
  local sprite="$kind._0.assetContainer.content.oneShotSprites.oneShotSprites.sprites.0"
  base="$(plutil -extract "$sprite.atlas.assetBaseName" raw -o - "$metadata" 2>/dev/null)" || return 1
  [[ -n "$base" && "$base" != */* ]] || return 1
  type="$(plutil -extract "$sprite.spriteType" raw -o - "$metadata" 2>/dev/null)" || return 1
  case "$type" in
    video) [[ -s "${metadata%/*}/$base.mov" ]] ;;
    frameSequence)
      start="$(plutil -extract "$sprite.customTiming.start" raw -o - "$metadata" 2>/dev/null)" || start=0
      end="$(plutil -extract "$sprite.customTiming.end" raw -o - "$metadata" 2>/dev/null)" || end=0
      digits="$(plutil -extract "$sprite.atlas.frameIndexDigitCount" raw -o - "$metadata" 2>/dev/null)" || digits=2
      [[ "$start" =~ ^[0-9]{1,6}$ && "$end" =~ ^[0-9]{1,6}$ && "$digits" =~ ^[1-9]$ ]] || return 1
      (( 10#$end >= 10#$start )) || return 1
      for ((index = 10#$start; index <= 10#$end; index++)); do
        printf -v frame '%0*d' "$digits" "$index"
        [[ -s "${metadata%/*}/${base}_$frame.heic" ]] || return 1
      done
      ;;
    *) return 1 ;;
  esac
}

has_idle_media() {
  local assets="$1/Contents/Resources/Assets" metadata have_scene=0 have_pose=0
  [[ -d "$assets" ]] || return 1
  while IFS= read -r -d '' metadata; do
    if [[ "$have_scene" == 0 ]] && has_sprite_media "$metadata" idleScene; then have_scene=1; fi
    if [[ "$have_pose" == 0 ]] && has_sprite_media "$metadata" characterBasePose; then have_pose=1; fi
    if [[ "$have_scene" == 1 && "$have_pose" == 1 ]]; then return 0; fi
  done < <(find "$assets" -type f -name metadata.icmetadata -print0)
  return 1
}

if [[ -L "$BACKUP_DIR" || ( -e "$BACKUP_DIR" && ! -d "$BACKUP_DIR" ) ]]; then
  echo "Invalid backup directory: $BACKUP_DIR" >&2
  exit 2
fi
for previous in "$BACKUP_DIR"/*.saver; do
  [[ -e "$previous" || -L "$previous" ]] || continue
  if ! has_supported_identity "$previous" || ! codesign --verify --deep --strict "$previous"; then
    echo "Unrecognized or invalid backup preserved at $previous" >&2
    exit 2
  fi
  previous_destination="$INSTALL_DIR/${previous##*/}"
  if [[ -e "$previous_destination" || -L "$previous_destination" ]]; then
    if ! has_supported_identity "$previous_destination" ||
       ! codesign --verify --deep --strict "$previous_destination" ||
       ! has_idle_media "$previous_destination"; then
      echo "Cannot safely resolve the existing destination; backup preserved at $previous" >&2
      exit 2
    fi
    rm -rf "$previous"
  else
    mv "$previous" "$previous_destination"
  fi
done

installed=()
for candidate in "$INSTALL_DIR"/*.saver; do
  [[ -d "$candidate" ]] || continue
  if [[ "$(bundle_identifier "$candidate" 2>/dev/null || true)" == "$IDENTIFIER" ]]; then
    if [[ -L "$candidate" ]]; then
      echo "Not replacing a symbolic link: $candidate" >&2
      exit 2
    fi
    installed+=("$candidate")
  fi
done
if [[ "${#installed[@]}" -gt 1 ]]; then
  echo "Multiple installed Snoopy bundles share the standard identifier." >&2
  printf '  %s\n' "${installed[@]}" >&2
  exit 2
elif [[ "${#installed[@]}" -eq 1 ]]; then
  DEST="${installed[0]}"
elif [[ -e "$DEST" || -L "$DEST" ]]; then
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
if ! has_supported_identity "$STAGED_SAVER"; then
  echo "Unsupported Snoopy bundle identity or principal class." >&2
  exit 2
fi
if ! has_idle_media "$STAGED_SAVER"; then
  echo "The Snoopy bundle is missing IdleScene or base-pose media. Install a full build without --code-only." >&2
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
