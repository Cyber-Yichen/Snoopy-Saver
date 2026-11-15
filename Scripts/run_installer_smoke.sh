#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUNDLE="$1"
FIXTURE="$(mktemp -d "$ROOT/.build/InstallerSmoke.XXXXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
SAVER_DIR="$FIXTURE/user/Library/Screen Savers"
INSTALLED="$SAVER_DIR/Snoopy-4K.saver"
UPDATE="$FIXTURE/Update.saver"
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

ditto "$BUNDLE" "$INSTALLED"
ditto "$BUNDLE" "$UPDATE"
touch "$UPDATE/Contents/Resources/installer-smoke-marker"
codesign --force --sign - --timestamp=none "$UPDATE"

if bash "$FIXTURE/install.sh" "$FIXTURE/Invalid.saver"; then
  echo "Installer accepted an invalid bundle." >&2
  exit 1
fi
codesign --verify --deep --strict "$INSTALLED"
test ! -e "$INSTALLED/Contents/Resources/installer-smoke-marker"

if SNOOPY_TEST_FAIL_RENAME=1 bash "$FIXTURE/install.sh" "$UPDATE"; then
  echo "Installer accepted a failed replacement." >&2
  exit 1
fi
codesign --verify --deep --strict "$INSTALLED"
test ! -e "$INSTALLED/Contents/Resources/installer-smoke-marker"
test ! -e "$SAVER_DIR/.snoopy-install-backup/Snoopy-4K.saver"

bash "$FIXTURE/install.sh" "$UPDATE"
codesign --verify --deep --strict "$INSTALLED"
test -e "$INSTALLED/Contents/Resources/installer-smoke-marker"
test ! -e "$SAVER_DIR/Snoopy.saver"

rm -rf "$INSTALLED"
bash "$FIXTURE/install.sh" "$UPDATE"
codesign --verify --deep --strict "$SAVER_DIR/Snoopy.saver"
echo "Installer smoke passed: invalid input and failed rename preserved the old bundle, updated its existing filename, and installed to the default on a clean system."
