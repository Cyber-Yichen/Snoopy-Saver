#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MODE="${1:-quick}"
BUILD_ROOT="$ROOT/.build/AgentHarness"

cd "$ROOT"
"$ROOT/Scripts/agent_preflight.sh" change

quick_gate() {
  mkdir -p "$BUILD_ROOT"
  local variant
  local bundles=()
  for variant in standard 1080p cdn-lite; do
    SNOOPY_VARIANT="$variant" \
    SNOOPY_BUILD_DIR="$BUILD_ROOT/$variant" \
      "$ROOT/Scripts/build_saver.sh" --code-only
    local bundle="$BUILD_ROOT/$variant/SnoopyScreenSaver.saver"
    local executable="$bundle/Contents/MacOS/SnoopyScreenSaver"
    xcrun lipo "$executable" -verify_arch arm64 x86_64
    codesign --verify --strict "$bundle"
    bundles+=( "$bundle" )
  done
  "$ROOT/Scripts/run_variant_collision_smoke.sh" "${bundles[@]}"
  git diff --check
  git diff --cached --check
  echo "Agent quick gate passed: three universal code-only variants and collision smoke."
}

case "$MODE" in
  quick)
    quick_gate
    ;;
  theme)
    test -n "${2:-}"
    quick_gate
    "$ROOT/Scripts/run_theme_smoke_tests.sh" "$2"
    ;;
  alpha)
    test -n "${2:-}"
    quick_gate
    "$ROOT/Scripts/validate_alpha_movies.sh" "$2"
    ;;
  cdn)
    quick_gate
    "$ROOT/Scripts/run_cdn_updater_smoke.sh"
    ;;
  runtime)
    test -n "${2:-}"
    quick_gate
    "$ROOT/Scripts/run_runtime_smoke.sh" "$2"
    ;;
  collision)
    shift
    (( $# >= 2 ))
    "$ROOT/Scripts/run_variant_collision_smoke.sh" "$@"
    ;;
  *)
    echo "usage: agent_check.sh quick|theme RESOURCES|alpha ROOT|cdn|runtime SAVER|collision SAVER..." >&2
    exit 2
    ;;
esac
