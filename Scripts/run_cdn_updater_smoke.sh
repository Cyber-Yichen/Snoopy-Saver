#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/.build/CDNUpdaterFixture"
SERVER_ROOT="$FIXTURE/server"
BUNDLE="$FIXTURE/Fixture.bundle"
DESTINATION="$FIXTURE/cache/Resolved"
PORT_FILE="$FIXTURE/port"
LOG_FILE="$FIXTURE/server.log"
BUILD="$ROOT/.build/CDNUpdaterSmoke"

rm -rf "$FIXTURE" "$BUILD"
mkdir -p "$SERVER_ROOT/Fixture.icasset" \
  "$BUNDLE/Contents/Resources" "$DESTINATION" "$BUILD"
python3 -c 'from pathlib import Path; Path("'"$SERVER_ROOT"'/Fixture.icasset/Fixture.mov").write_bytes(b"alpha-fixture\n")'
python3 "$ROOT/Tests/CDNFixtureServer.py" "$SERVER_ROOT" "$PORT_FILE" \
  >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in {1..50}; do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
test -s "$PORT_FILE"
PORT="$(cat "$PORT_FILE")"
python3 -c '
import hashlib, json
from pathlib import Path
root = Path("'"$SERVER_ROOT"'")
movie = root / "Fixture.icasset" / "Fixture.mov"
manifest = {
    "schemaVersion": 1,
    "baseURL": "http://127.0.0.1:'"$PORT"'",
    "files": [{
        "path": "Fixture.icasset/Fixture.mov",
        "size": movie.stat().st_size,
        "sha256": hashlib.sha256(movie.read_bytes()).hexdigest(),
        "url": "http://127.0.0.1:'"$PORT"'/Fixture.icasset/Fixture.mov",
    }],
}
text = json.dumps(manifest, indent=2) + "\n"
(root / "cdn-manifest.json").write_text(text)
Path("'"$BUNDLE"'/Contents/Resources/cdn-manifest.json").write_text(text)
'
cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"

xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Sources/CDNMediaUpdater.swift" \
  "$ROOT/Tests/CDNUpdaterSmoke.swift" \
  -framework CryptoKit \
  -o "$BUILD/cdn-updater-smoke"

SNOOPY_CDN_ALLOW_HTTP_FOR_TESTS=1 \
SNOOPY_CDN_MIN_CHECK_INTERVAL=0 \
SNOOPY_CDN_DESTINATION="$DESTINATION" \
  "$BUILD/cdn-updater-smoke" "$BUNDLE" "$DESTINATION"
