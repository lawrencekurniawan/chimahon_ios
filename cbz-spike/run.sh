#!/bin/zsh
# Builds + runs the CBZ spike on the DEDICATED simulator (scripts/simulator.sh).
# Usage: ./run.sh            → headless bench (CBZ_VERDICT, exit 0/1)
#        ./run.sh ui         → launch interactive reader (open Simulator.app)
set -euo pipefail
cd "$(dirname "$0")"

UDID=$(../scripts/simulator.sh udid)
echo "== dedicated simulator: $UDID =="

xcodegen generate
xcodebuild -project CbzSpike.xcodeproj \
  -scheme CbzSpike \
  -destination "id=$UDID" \
  -derivedDataPath build \
  build | grep -E "error:|BUILD" | tail -5

APP=build/Build/Products/Debug-iphonesimulator/CbzSpike.app
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

if [[ "${1:-}" == "ui" ]]; then
  open -a Simulator
  xcrun simctl launch "$UDID" app.chimahon.spike.cbz
  echo "interactive reader launched — scroll to check smoothness"
  exit 0
fi

echo "== launching CBZ bench =="
set +e
OUT=$(xcrun simctl launch --console "$UDID" app.chimahon.spike.cbz -RunCBZBench 2>&1)
set -e
echo "$OUT" | grep -v "^$" | tail -12

VERDICT=$(echo "$OUT" | grep -o 'CBZ_VERDICT:.*' | head -1 | sed 's/^CBZ_VERDICT://')
if [[ -z "$VERDICT" ]]; then
  echo "!! no verdict captured"
  exit 1
fi
echo "$VERDICT" | python3 -m json.tool
python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['pass'] else 1)" "$VERDICT"
