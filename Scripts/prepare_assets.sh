#!/bin/bash
set -euo pipefail

SOURCE_ROOT="${1:?usage: prepare_assets.sh SOURCE_ROOT RESOURCES_ROOT}"
RESOURCES_ROOT="${2:?usage: prepare_assets.sh SOURCE_ROOT RESOURCES_ROOT}"
ASSETS_ROOT="$RESOURCES_ROOT/Assets"
RESOLVED="$ASSETS_ROOT/Resolved"
AVAILABILITY="$ASSETS_ROOT/Availability"

rm -rf "$ASSETS_ROOT"
mkdir -p "$RESOLVED" "$AVAILABILITY"

copy_shared_resources() {
  local metadata
  for metadata in optional-assets.json lowres-build.json heic-build.json alpha-preservation.json lite-selection.json cdn-manifest.json; do
    if [[ -f "$SOURCE_ROOT/$metadata" ]]; then
      cp "$SOURCE_ROOT/$metadata" "$RESOURCES_ROOT/$metadata"
    fi
  done
  if [[ -f "$SOURCE_ROOT/halftone_pattern.png" ]]; then
    cp "$SOURCE_ROOT/halftone_pattern.png" "$RESOURCES_ROOT/halftone_pattern.png"
  elif [[ -f "$SOURCE_ROOT/FrameworkResources/halftone_pattern.png" ]]; then
    cp "$SOURCE_ROOT/FrameworkResources/halftone_pattern.png" \
      "$RESOURCES_ROOT/halftone_pattern.png"
  fi
}

# Low-resolution and CDN-lite pipelines already produce one preferred copy per
# Asset ID plus the original availability references. Reuse that normalized
# tree directly rather than reconstructing source-package precedence.
if [[ -d "$SOURCE_ROOT/Assets/Resolved" ]]; then
  cp -cR "$SOURCE_ROOT/Assets/Resolved/." "$RESOLVED/"
  if [[ -d "$SOURCE_ROOT/Assets/Availability" ]]; then
    cp -cR "$SOURCE_ROOT/Assets/Availability/." "$AVAILABILITY/"
  fi
  copy_shared_resources
  find "$RESOURCES_ROOT" -name '.DS_Store' -delete
  test "$(find "$RESOLVED" -mindepth 1 -maxdepth 1 -type d -name '*.icasset' | wc -l | tr -d ' ')" -gt 0
  exit 0
fi

copy_bundle() {
  local bundle="$1"
  local availability_name="$2"
  [[ -d "$bundle" ]] || return 0
  mkdir -p "$AVAILABILITY/$availability_name"
  local asset
  for asset in "$bundle"/*.icasset; do
    [[ -d "$asset" ]] || continue
    local name
    name="$(basename "$asset")"
    rm -rf "$RESOLVED/$name"
    cp -cR "$asset" "$RESOLVED/$name"
    touch "$AVAILABILITY/$availability_name/${name%.icasset}.assetref"
  done
}

# Later sources replace earlier copies. Optional downloads are Apple's
# high-resolution replacements for matching Default Asset IDs.
copy_bundle "$SOURCE_ROOT/DefaultAssetBundle" "__yearRound"
copy_bundle "$SOURCE_ROOT/DefaultAssetBundleV2" "__yearRound"

if compgen -G "$SOURCE_ROOT/OptionalDownloads/expanded/*" >/dev/null; then
  for package in "$SOURCE_ROOT"/OptionalDownloads/expanded/*; do
    [[ -d "$package" ]] || continue
    copy_bundle "$package" "$(basename "$package")"
  done
fi

copy_shared_resources
find "$RESOURCES_ROOT" -name '.DS_Store' -delete

test "$(find "$RESOLVED" -mindepth 1 -maxdepth 1 -type d -name '*.icasset' | wc -l | tr -d ' ')" -gt 0
