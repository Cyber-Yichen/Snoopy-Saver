#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
SWIFT_LIB="$TOOLCHAIN/usr/lib/swift/macosx"
BUILD="${SNOOPY_BUILD_DIR:-$ROOT/.build/SnoopyScreenSaver}"
[[ "$BUILD" == /* ]] || BUILD="$ROOT/$BUILD"
BUNDLE="$BUILD/SnoopyScreenSaver.saver"
MODULE_CACHE="$ROOT/.build/ModuleCache"
ASSET_ROOT="${SNOOPY_ASSET_ROOT:-$ROOT/LocalAssets}"
ARCHS=( ${SNOOPY_ARCHS:-arm64 x86_64} )
SWIFT_EXTRA=( -parse-as-library )
CLANG_EXTRA=( -bundle )
VARIANT="${SNOOPY_VARIANT:-standard}"
case "$VARIANT" in
  standard)
    MODULE_NAME="SnoopyScreenSaver"
    BUNDLE_ID="local.snoopy.ScreenSaver"
    PRINCIPAL_CLASS="SnoopyScreenSaverView"
    DISPLAY_NAME="Snoopy"
    ;;
  1080p)
    SWIFT_EXTRA+=( -D SNOOPY_VARIANT_1080P )
    MODULE_NAME="SnoopyScreenSaver1080p"
    BUNDLE_ID="local.snoopy.ScreenSaver.1080p"
    PRINCIPAL_CLASS="Snoopy1080ScreenSaverView"
    DISPLAY_NAME="Snoopy 1080p"
    ;;
  cdn-lite)
    SWIFT_EXTRA+=( -D SNOOPY_VARIANT_CDN_LITE )
    MODULE_NAME="SnoopyScreenSaverCDNLite"
    BUNDLE_ID="local.snoopy.ScreenSaver.CDNLite"
    PRINCIPAL_CLASS="SnoopyCDNLiteScreenSaverView"
    DISPLAY_NAME="Snoopy CDN"
    ;;
  *)
    echo "Unknown SNOOPY_VARIANT: $VARIANT" >&2
    exit 2
    ;;
esac
if [[ "${SNOOPY_SANITIZER:-}" == "address" ]]; then
  SWIFT_EXTRA+=( -sanitize=address )
  CLANG_EXTRA+=( -fsanitize=address )
fi
WITH_ASSETS=1
[[ "${1:-}" == "--code-only" ]] && WITH_ASSETS=0
if [[ -z "$BUILD" || "$BUILD" == "/" || "$BUILD" == "$HOME" || "$BUILD" == "$ROOT" ]]; then
  echo "Refusing unsafe build directory: $BUILD" >&2
  exit 2
fi
rm -rf "$BUILD"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$MODULE_CACHE"
BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  mkdir -p "$BUILD/$ARCH"
  xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx12.0" -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    "${SWIFT_EXTRA[@]}" \
    -whole-module-optimization -emit-object -module-name "$MODULE_NAME" \
    "$ROOT"/Sources/*.swift -o "$BUILD/$ARCH/SnoopyScreenSaver.o"
  xcrun clang -target "$ARCH-apple-macosx12.0" -isysroot "$SDK" \
    "${CLANG_EXTRA[@]}" \
    "$BUILD/$ARCH/SnoopyScreenSaver.o" -L"$SDK/usr/lib/swift" -L/usr/lib/swift -L"$SWIFT_LIB" \
    -lswiftCore -lswiftFoundation -lswiftAppKit -lswiftAVFoundation -lswiftCoreLocation \
    -framework AppKit -framework AVFoundation -framework CoreLocation -framework ImageIO \
    -framework CryptoKit -framework QuartzCore -framework ScreenSaver \
    -o "$BUILD/$ARCH/SnoopyScreenSaver"
  BINARIES+=( "$BUILD/$ARCH/SnoopyScreenSaver" )
done
if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$BUNDLE/Contents/MacOS/SnoopyScreenSaver"
else
  xcrun lipo -create "${BINARIES[@]}" \
    -output "$BUNDLE/Contents/MacOS/SnoopyScreenSaver"
fi
cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NSPrincipalClass $PRINCIPAL_CLASS" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$BUNDLE/Contents/Info.plist"
if [[ "$WITH_ASSETS" -eq 1 ]]; then
  "$ROOT/Scripts/prepare_assets.sh" "$ASSET_ROOT" "$BUNDLE/Contents/Resources"
fi
if [[ -f "$ROOT/Assets/thumbnail.png" ]]; then
  cp "$ROOT/Assets/thumbnail.png" "$BUNDLE/Contents/Resources/thumbnail.png"
  cp "$ROOT/Assets/thumbnail@2x.png" "$BUNDLE/Contents/Resources/thumbnail@2x.png"
fi
xattr -cr "$BUNDLE"
codesign --force --sign - --timestamp=none "$BUNDLE"
echo "$BUNDLE"
