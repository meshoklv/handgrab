#!/bin/bash
# Sculpt mode in the iOS Simulator: install the SDK=iphonesimulator build, launch, collect screenshots and the event log.
#   scripts/sculpt-sim.sh demo all 160                         # -sculptdemo all (no tracking)
#   scripts/sculpt-sim.sh replay sculpt-spiral 12 plasticine   # through the tracking pipeline
# Uses its own Simulator (HandGrab-sculpt-sim); shut down afterwards unless KEEP_SIM=1.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ROOT"
KIND=${1:-demo}; NAME=${2:-all}; WAIT=${3:-60}; PRESET=${4:-}
SIM=${SIM:-HandGrab-sculpt-sim}
APP=build/sym/${CONF:-Release}-iphonesimulator/HandGrab.app
if ! xcrun simctl list devices | grep -q "$SIM ("; then
  xcrun simctl create "$SIM" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-18-6 >/dev/null
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
DATA=$(xcrun simctl get_app_container "$SIM" $BUNDLE_ID data)
rm -rf "$DATA"/Documents/*.jpg "$DATA"/Documents/events.log "$DATA"/Documents/sculpt-bench.log
ARGS=()
if [ "$KIND" = demo ]; then ARGS=(-sculptdemo "$NAME"); else ARGS=(-replay "$NAME"); fi
[ -n "$PRESET" ] && ARGS+=(-preset "$PRESET")
xcrun simctl launch "$SIM" $BUNDLE_ID "${ARGS[@]}" >/dev/null
sleep 6
xcrun simctl io "$SIM" screenshot build/sculpt-screen-hud.png >/dev/null 2>&1 || true
sleep "$WAIT"
OUT=build/sculpt-out/${KIND}-${NAME}${PRESET:+-$PRESET}
mkdir -p "$OUT" && rm -f "$OUT"/*
cp "$DATA"/Documents/*.jpg "$DATA"/Documents/events.log "$OUT"/ 2>/dev/null || true
cp "$DATA"/Documents/sculpt-bench.log "$OUT"/ 2>/dev/null || true
xcrun simctl io "$SIM" screenshot "$OUT/screen-final.png" >/dev/null 2>&1 || true
mv build/sculpt-screen-hud.png "$OUT/screen-start.png" 2>/dev/null || true
xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
[ -n "${KEEP_SIM:-}" ] || xcrun simctl shutdown "$SIM" 2>/dev/null || true
echo "OUT: $PWD/$OUT"; ls "$OUT"
