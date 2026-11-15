#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MODE="${1:-read}"
case "$MODE" in
  read|change|release) ;;
  *) echo "usage: agent_preflight.sh [read|change|release]" >&2; exit 2 ;;
esac

cd "$ROOT"
git rev-parse --git-dir >/dev/null
test -f AGENTS.md
test -f .agents/project-state.json
test -x Scripts/agent_preflight.sh
test -x Scripts/agent_check.sh

"$ROOT/Scripts/validate_agent_state.py" "$ROOT"

BRANCH="$(git branch --show-current)"
COMMIT="$(git rev-parse HEAD)"
CHANGES="$(git status --porcelain)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"

echo "Agent preflight: $MODE"
echo "root: $ROOT"
echo "branch: ${BRANCH:-detached}"
echo "commit: $COMMIT"
echo "version: $VERSION build $BUILD"
if [[ -n "$CHANGES" ]]; then
  echo "working tree: dirty"
  git status --short
else
  echo "working tree: clean"
fi

if [[ "$MODE" == "change" ]]; then
  case "$BRANCH" in
    main|master|"")
      echo "Refusing product mutation on protected or detached branch: ${BRANCH:-detached}" >&2
      exit 3
      ;;
    beta) ;;
    *)
      echo "Refusing mutation outside the beta branch: $BRANCH" >&2
      exit 3
      ;;
  esac
fi

if [[ "$MODE" == "release" ]]; then
  if [[ "${SNOOPY_RELEASE_APPROVED:-}" != "1" ]]; then
    echo "Release mode requires explicit SNOOPY_RELEASE_APPROVED=1." >&2
    exit 4
  fi
  case "$BRANCH" in
    beta|main) ;;
    *)
      echo "Release mode is permitted only on beta or main, not $BRANCH." >&2
      exit 4
      ;;
  esac
fi

FORBIDDEN="$(git ls-files | awk '
  /^\.build\// || /^LocalAssets\// || /^Releases\// ||
  /\.mov$/ || /\.heic$/ || /\.saver(\/|$)/ || /\.tar\.encrypted$/ { print }
')"
if [[ -n "$FORBIDDEN" ]]; then
  echo "Forbidden media/build content is tracked:" >&2
  echo "$FORBIDDEN" >&2
  exit 5
fi
echo "tracked media audit: pass"

if [[ -x /Users/yichen/.local/bin/codex-vm ]]; then
  /Users/yichen/.local/bin/codex-vm project-info "$ROOT"
fi

SAVER_ROOT="$HOME/Library/Screen Savers"
if [[ -d "$SAVER_ROOT" ]]; then
  DUPLICATE_IDENTIFIERS="$(
    for info in "$SAVER_ROOT"/Snoopy*.saver/Contents/Info.plist; do
      [[ -f "$info" ]] || continue
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null || true
    done | sort | uniq -c | awk '$1 > 1 { print $1 " " $2 }'
  )"
  if [[ -n "$DUPLICATE_IDENTIFIERS" ]]; then
    while read -r count identifier; do
      echo "warning: duplicate installed bundle identifier $identifier ($count)" >&2
    done <<< "$DUPLICATE_IDENTIFIERS"
  fi
fi

echo "Agent preflight passed."
