#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NORMALIZED_ROOT="${1:?usage: validate_alpha_movies.sh NORMALIZED_ROOT}"
TOOL_ROOT="$ROOT/.build/Tools"
TOOL="$TOOL_ROOT/validate_alpha_movies"
MODULE_CACHE="$ROOT/.build/ModuleCache"

mkdir -p "$TOOL_ROOT" "$MODULE_CACHE"
xcrun swiftc -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework AVFoundation \
  -framework CoreMedia \
  "$ROOT/Scripts/validate_alpha_movies.swift" \
  -o "$TOOL"

"$TOOL" "$NORMALIZED_ROOT"
