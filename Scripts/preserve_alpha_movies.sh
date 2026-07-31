#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${1:?usage: preserve_alpha_movies.sh SOURCE_ROOT NORMALIZED_ROOT [MAX_WIDTH] [MAX_HEIGHT]}"
NORMALIZED_ROOT="${2:?usage: preserve_alpha_movies.sh SOURCE_ROOT NORMALIZED_ROOT [MAX_WIDTH] [MAX_HEIGHT]}"
MAX_WIDTH="${3:-1920}"
MAX_HEIGHT="${4:-1080}"
TOOL_ROOT="$ROOT/.build/Tools"
TOOL="$TOOL_ROOT/preserve_alpha_movies"

mkdir -p "$TOOL_ROOT"
xcrun swiftc -parse-as-library \
  -framework AVFoundation \
  -framework CoreMedia \
  "$ROOT/Scripts/preserve_alpha_movies.swift" \
  -o "$TOOL"

"$TOOL" "$SOURCE_ROOT" "$NORMALIZED_ROOT" "$MAX_WIDTH" "$MAX_HEIGHT"
