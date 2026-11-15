#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MODE="${1:-quick}"
BUILD_ROOT="$ROOT/.build/AgentHarness"

cd "$ROOT"
"$ROOT/Scripts/agent_preflight.sh" change

quick_gate() {
  local bundle="$BUILD_ROOT/SnoopyScreenSaver.saver"
  SNOOPY_BUILD_DIR="$BUILD_ROOT" "$ROOT/Scripts/build_saver.sh" --code-only
  local architecture
  for architecture in arm64 x86_64; do
    xcrun lipo "$bundle/Contents/MacOS/SnoopyScreenSaver" -verify_arch "$architecture"
  done
  codesign --verify --deep --strict "$bundle"
  bash -n "$ROOT/Scripts/install_saver.sh"
  "$ROOT/Scripts/run_installer_smoke.sh" "$bundle"
  xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT"/Sources/*.swift "$ROOT/Tests/FrameDecoderSmoke.swift" -o "$BUILD_ROOT/frame-decoder-smoke"
  "$BUILD_ROOT/frame-decoder-smoke"
  git diff --check
  git diff --cached --check
  echo "Agent quick gate passed: universal standard bundle, strict signature, installer recovery, and decoder cancellation."
}

case "$MODE" in
  quick)
    quick_gate
    ;;
  theme)
    quick_gate
    "$ROOT/Scripts/run_theme_smoke_tests.sh" "${@:2}"
    ;;
  runtime)
    test -n "${2:-}"
    quick_gate
    "$ROOT/Scripts/run_runtime_smoke.sh" "$2"
    ;;
  *)
    echo "usage: agent_check.sh quick|theme [RESOURCES]|runtime SAVER" >&2
    exit 2
    ;;
esac
