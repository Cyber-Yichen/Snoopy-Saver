#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUNDLE="$1"
FIXTURE="$(mktemp -d "$ROOT/.build/InstallerSmoke.XXXXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
SAVER_DIR="$FIXTURE/user/Library/Screen Savers"
INSTALLED="$SAVER_DIR/Snoopy-4K.saver"
UPDATE="$FIXTURE/Update.saver"
INCOMPLETE="$FIXTURE/Incomplete.saver"
mkdir -p "$SAVER_DIR" "$FIXTURE/bin" "$FIXTURE/Invalid.saver"

# Keep the real copy, verification, locking, and rename operations in the fixture.
sed 's@\$HOME@\$SNOOPY_TEST_USER_DIR@g' "$ROOT/Scripts/install_saver.sh" > "$FIXTURE/install.sh"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/bin/pkill"
cat > "$FIXTURE/bin/mv" <<'MOVE'
#!/bin/bash
if [[ "${SNOOPY_TEST_FAIL_RENAME:-}" == 1 && "$1" == */.snoopy-install.*/Snoopy.saver ]]; then
  exit 1
fi
exec /bin/mv "$@"
MOVE
chmod +x "$FIXTURE/bin/"*
export PATH="$FIXTURE/bin:$PATH"
export SNOOPY_TEST_USER_DIR="$FIXTURE/user"

ditto "$BUNDLE" "$UPDATE"
ASSETS="$UPDATE/Contents/Resources/Assets"
for kind in idleScene characterBasePose; do
  media="$ASSETS/$kind.icasset"
  mkdir -p "$media"
  cat > "$media/metadata.icmetadata" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>$kind</key><dict><key>_0</key><dict>
<key>assetContainer</key><dict><key>content</key><dict>
<key>oneShotSprites</key><dict><key>oneShotSprites</key><dict><key>sprites</key><array><dict>
<key>atlas</key><dict><key>assetBaseName</key><string>fixture</string></dict>
<key>spriteType</key><string>frameSequence</string>
<key>customTiming</key><dict><key>start</key><integer>0</integer><key>end</key><integer>2</integer></dict>
</dict></array></dict></dict></dict></dict></dict></dict></dict></plist>
PLIST
  for number in 00 01 02; do printf 'installer path fixture\n' > "$media/fixture_$number.heic"; done
done
codesign --force --sign - --timestamp=none "$UPDATE"
ditto "$UPDATE" "$INSTALLED"
ditto "$UPDATE" "$INCOMPLETE"
rm "$INCOMPLETE/Contents/Resources/Assets/characterBasePose.icasset/fixture_01.heic"
codesign --force --sign - --timestamp=none "$INCOMPLETE"
touch "$UPDATE/Contents/Resources/installer-smoke-marker"
codesign --force --sign - --timestamp=none "$UPDATE"

if bash "$FIXTURE/install.sh" "$FIXTURE/Invalid.saver"; then
  echo "Installer accepted an invalid bundle." >&2
  exit 1
fi
codesign --verify --deep --strict "$INSTALLED"
test ! -e "$INSTALLED/Contents/Resources/installer-smoke-marker"

for invalid in "$BUNDLE" "$INCOMPLETE"; do
  codesign --verify --deep --strict "$invalid"
  if bash "$FIXTURE/install.sh" "$invalid"; then
    echo "Installer accepted a signed bundle with missing media." >&2
    exit 1
  fi
  test -s "$INSTALLED/Contents/Resources/Assets/characterBasePose.icasset/fixture_00.heic"
  codesign --verify --deep --strict "$INSTALLED"
done

if SNOOPY_TEST_FAIL_RENAME=1 bash "$FIXTURE/install.sh" "$UPDATE"; then
  echo "Installer accepted a failed replacement." >&2
  exit 1
fi
codesign --verify --deep --strict "$INSTALLED"
test ! -e "$INSTALLED/Contents/Resources/installer-smoke-marker"
test ! -e "$SAVER_DIR/.snoopy-install-backup/Snoopy-4K.saver"

# After an interrupted install a signed but incomplete destination must
# never cause the sole complete backup to be discarded.
BACKUP="$SAVER_DIR/.snoopy-install-backup/Snoopy-4K.saver"
mkdir -p "${BACKUP%/*}"
mv "$INSTALLED" "$BACKUP"
ditto "$INCOMPLETE" "$INSTALLED"
if bash "$FIXTURE/install.sh" "$UPDATE"; then
  echo "Installer accepted a conflicting incomplete destination." >&2
  exit 1
fi
test -s "$BACKUP/Contents/Resources/Assets/characterBasePose.icasset/fixture_01.heic"
codesign --verify --deep --strict "$BACKUP"
mv "$INSTALLED" "$FIXTURE/conflict.saver"
mv "$BACKUP" "$INSTALLED"

bash "$FIXTURE/install.sh" "$UPDATE"
codesign --verify --deep --strict "$INSTALLED"
test -e "$INSTALLED/Contents/Resources/installer-smoke-marker"
test ! -e "$SAVER_DIR/Snoopy.saver"

rm -rf "$INSTALLED"
bash "$FIXTURE/install.sh" "$UPDATE"
codesign --verify --deep --strict "$SAVER_DIR/Snoopy.saver"
echo "Installer smoke passed: incomplete media rejected, failed rename restored, conflicting backup preserved, and valid installs succeeded."
