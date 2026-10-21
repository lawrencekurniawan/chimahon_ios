#!/bin/zsh
# Dedicated Chimahon spike simulator — NEVER uses the developer's personal devices.
# Policy (2026-10-21): all simulator runs for this repo go through this script.
#
# Usage:
#   ./scripts/simulator.sh udid    # print UDID (creating the device if missing)
#   ./scripts/simulator.sh boot    # create-if-missing + boot + open Simulator.app
#   ./scripts/simulator.sh erase   # wipe spike device state (fresh run)
#   ./scripts/simulator.sh erase-and-boot  # wipe + boot (default for clean tests)
set -eu
cd "$(dirname "$0")/.."

DEV_NAME="ChimahonSpike-iPhone17"
DEV_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

find_udid() {
  xcrun simctl list devices available -j \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for dev in d['devices'].get('$RUNTIME', []):
    if dev['name'] == '$DEV_NAME':
        print(dev['udid']); break
"
}

UDID=$(find_udid || true)
if [[ -z "${UDID:-}" ]]; then
  echo "creating $DEV_NAME..." >&2
  UDID=$(xcrun simctl create "$DEV_NAME" "$DEV_TYPE" "$RUNTIME")
fi
echo "$UDID" > .simulator-udid

cmd="${1:-}"
case "$cmd" in
  udid)
    echo "$UDID"
    ;;
  boot)
    xcrun simctl boot "$UDID" 2>/dev/null || echo "already booted"
    open -a Simulator
    echo "booted $DEV_NAME ($UDID)"
    ;;
  erase)
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl erase "$UDID"
    echo "erased $DEV_NAME"
    ;;
  erase-and-boot)
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl erase "$UDID"
    xcrun simctl boot "$UDID"
    open -a Simulator
    echo "erased + booted $DEV_NAME ($UDID)"
    ;;
  *)
    echo "usage: $0 udid|boot|erase|erase-and-boot" >&2
    exit 2
    ;;
esac
