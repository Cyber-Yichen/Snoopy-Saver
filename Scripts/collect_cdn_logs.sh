#!/bin/bash
set -euo pipefail

DESTINATION="${1:-$HOME/Desktop/Snoopy-CDN-Lite.log}"
CANDIDATES=(
  "$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/Snoopy/CDN-Lite.log"
  "$HOME/Library/Logs/Snoopy/CDN-Lite.log"
)

for source in "${CANDIDATES[@]}"; do
  if [[ -f "$source" ]]; then
    cp "$source" "$DESTINATION"
    if [[ -f "$source.1" ]]; then cp "$source.1" "$DESTINATION.1"; fi
    echo "$DESTINATION"
    exit 0
  fi
done

echo "No Snoopy CDN diagnostic log was found." >&2
exit 1
