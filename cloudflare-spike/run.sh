#!/bin/zsh
# Builds + runs the Cloudflare cookie-bridge spike on the DEDICATED simulator
# (scripts/simulator.sh) — never the developer's personal devices.
#
# Usage:
#   ./run.sh                                   # target: https://nhattruyenqq.com/
#   ./run.sh -TargetURL https://example.com   # any CF-protected site (e.g. the
#                                              # one Tachimanga trips on)
#   ERASE=1 ./run.sh                           # wipe cookie state first (fresh CF state)
set -euo pipefail
cd "$(dirname "$0")"

UDID=$(../scripts/simulator.sh udid)
echo "== dedicated simulator: $UDID =="

xcodegen generate
xcodebuild -project CloudflareBridge.xcodeproj \
  -scheme CloudflareBridge \
  -destination "id=$UDID" \
  -derivedDataPath build \
  build | grep -E "error:|BUILD" | tail -5

APP=build/Build/Products/Debug-iphonesimulator/CloudflareBridge.app

if [[ "${ERASE:-0}" == "1" ]]; then
  ../scripts/simulator.sh erase >/dev/null
fi
xcrun simctl boot "$UDID" 2>/dev/null || true

xcrun simctl install "$UDID" "$APP"
echo "== launching bridge test =="
set +e
OUT=$(xcrun simctl launch --console "$UDID" app.chimahon.spike.cloudflare -RunBridgeTest "$@" 2>&1)
set -e
echo "$OUT" | grep -v "^$" | tail -20

VERDICT=$(echo "$OUT" | grep -o 'BRIDGE_VERDICT:.*' | head -1 | sed 's/^BRIDGE_VERDICT://')
if [[ -z "$VERDICT" ]]; then
  echo "!! no verdict captured"
  exit 1
fi
echo "$VERDICT" | python3 -m json.tool
python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['pass'] else 1)" "$VERDICT"
