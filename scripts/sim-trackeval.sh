#!/bin/bash
# Offline tracking evaluation on recorded sessions in the Simulator (faster than real time).
#   scripts/sim-trackeval.sh [file.jsonl ...]   (files from build/sessions; no args = all)
# Build first: SDK=iphonesimulator CONF=Release scripts/build.sh. Output: build/trackeval.log.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ROOT"
SIM=${SIM:-HandGrab-sim}
APP=build/sym/${CONF:-Release}-iphonesimulator/HandGrab.app
if ! xcrun simctl list devices | grep -q "$SIM ("; then
  RT=$(xcrun simctl list runtimes -j | python3 -c 'import sys,json;print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["identifier"]][-1])')
  xcrun simctl create "$SIM" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RT" >/dev/null
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
DATA=$(xcrun simctl get_app_container "$SIM" $BUNDLE_ID data)
mkdir -p "$DATA/Documents/sessions" && rm -f "$DATA"/Documents/sessions/* "$DATA/Documents/trackeval.log"
if [ $# -eq 0 ]; then cp build/sessions/s-*.jsonl "$DATA/Documents/sessions/"; else for f in "$@"; do cp "build/sessions/$f" "$DATA/Documents/sessions/"; done; fi
xcrun simctl launch "$SIM" $BUNDLE_ID -trackeval "$@" ${EXTRA:-} >/dev/null
for i in $(seq 1 600); do sleep 1; grep -q "TRACKEVAL DONE" "$DATA/Documents/trackeval.log" 2>/dev/null && break; done
xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
cp "$DATA/Documents/trackeval.log" build/trackeval.log; cp "$DATA"/Documents/trackdump-*.csv build/ 2>/dev/null || true
cat build/trackeval.log
