#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
SWIFT_LIB="$TOOLCHAIN/usr/lib/swift/macosx"
BUILD="${SNOOPY_BUILD_DIR:-$ROOT/.build/SnoopyScreenSaver}"
MODULE_CACHE="$ROOT/.build/ModuleCache"
DESTINATION="$BUILD/SnoopyScreenSaver.saver"
if [[ "${1:-}" != "--locked" ]]; then
  mkdir -p "$BUILD"
  exec /usr/bin/lockf -k "$BUILD/.snoopy-build.lock" /bin/bash "$0" --locked "$@"
fi
shift
WITH_ASSETS=1
[[ "${1:-}" == "--code-only" ]] && WITH_ASSETS=0
STAGING="$(mktemp -d "$BUILD/.snoopy-build.XXXXXXXX")"
BACKUP="$STAGING/previous.saver"
cleanup() {
  local result=$?
  if [[ -e "$BACKUP" && ! -e "$DESTINATION" ]] && ! mv "$BACKUP" "$DESTINATION"; then
    echo "Could not restore the previous build at $BACKUP" >&2
    exit 1
  fi
  rm -rf "$STAGING"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
BUNDLE="$STAGING/SnoopyScreenSaver.saver"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$MODULE_CACHE"
for ARCH in arm64 x86_64; do
  mkdir -p "$STAGING/$ARCH"
  xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx12.0" -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    -parse-as-library -whole-module-optimization -emit-object -module-name SnoopyScreenSaver \
    "$ROOT"/Sources/*.swift -o "$STAGING/$ARCH/SnoopyScreenSaver.o"
  xcrun clang -target "$ARCH-apple-macosx12.0" -isysroot "$SDK" -bundle \
    "$STAGING/$ARCH/SnoopyScreenSaver.o" -L"$SDK/usr/lib/swift" -L/usr/lib/swift -L"$SWIFT_LIB" \
    -lswiftCore -lswiftFoundation -lswiftAppKit -lswiftAVFoundation -lswiftCoreLocation \
    -framework AppKit -framework AVFoundation -framework CoreLocation -framework ImageIO \
    -framework QuartzCore -framework ScreenSaver -o "$STAGING/$ARCH/SnoopyScreenSaver"
done
xcrun lipo -create "$STAGING/arm64/SnoopyScreenSaver" "$STAGING/x86_64/SnoopyScreenSaver" \
  -output "$BUNDLE/Contents/MacOS/SnoopyScreenSaver"
cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"
if [[ "$WITH_ASSETS" -eq 1 ]]; then
  mkdir -p "$BUNDLE/Contents/Resources/Assets/Optional"
  cp -cR "$ROOT/LocalAssets/DefaultAssetBundle" "$BUNDLE/Contents/Resources/Assets/"
  cp -cR "$ROOT/LocalAssets/DefaultAssetBundleV2" "$BUNDLE/Contents/Resources/Assets/"
  if compgen -G "$ROOT/LocalAssets/OptionalDownloads/expanded/*" >/dev/null; then
    for PACKAGE in "$ROOT"/LocalAssets/OptionalDownloads/expanded/*; do
      cp -cR "$PACKAGE" "$BUNDLE/Contents/Resources/Assets/Optional/"
    done
  fi
  if [[ -f "$ROOT/LocalAssets/optional-assets.json" ]]; then
    cp "$ROOT/LocalAssets/optional-assets.json" "$BUNDLE/Contents/Resources/optional-assets.json"
  fi
  cp "$ROOT/LocalAssets/FrameworkResources/halftone_pattern.png" "$BUNDLE/Contents/Resources/halftone_pattern.png"
fi
if [[ -f "$ROOT/Assets/thumbnail.png" ]]; then
  cp "$ROOT/Assets/thumbnail.png" "$BUNDLE/Contents/Resources/thumbnail.png"
  cp "$ROOT/Assets/thumbnail@2x.png" "$BUNDLE/Contents/Resources/thumbnail@2x.png"
fi
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$BACKUP"; fi
mv "$BUNDLE" "$DESTINATION"
echo "$DESTINATION"
