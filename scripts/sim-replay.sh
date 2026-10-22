#!/bin/bash
# Replay in the iOS Simulator: install the SDK=iphonesimulator build, launch with -replay, collect scene snapshots.
#   SDK=iphonesimulator CONF=Debug scripts/build.sh && scripts/sim-replay.sh [synth|file.jsonl] [seconds]
# A session file is copied from build/sessions/<file> into the app's Documents/sessions inside the Simulator.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ROOT"
SRC=${1:-synth}; WAIT=${2:-13}
SIM=${SIM:-HandGrab-sim}
APP=build/sym/${CONF:-Debug}-iphonesimulator/HandGrab.app
if ! xcrun simctl list devices | grep -q "$SIM ("; then
  RT=$(xcrun simctl list runtimes -j | python3 -c 'import sys,json;print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["identifier"]][-1])')
  xcrun simctl create "$SIM" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RT" >/dev/null
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
DATA=$(xcrun simctl get_app_container "$SIM" $BUNDLE_ID data)
rm -rf "$DATA"/Documents/*.jpg "$DATA"/Documents/events.log "$DATA"/Documents/sessions/*
if [ "$SRC" != synth ] && [ "$SRC" != synthnoise ]; then mkdir -p "$DATA/Documents/sessions" && cp "build/sessions/$SRC" "$DATA/Documents/sessions/"; fi
xcrun simctl launch "$SIM" $BUNDLE_ID -replay "$SRC" ${EXTRA:-} >/dev/null
sleep "$WAIT"
mkdir -p build/replay && rm -f build/replay/*
cp "$DATA"/Documents/*.jpg "$DATA"/Documents/events.log build/replay/ 2>/dev/null || true
mkdir -p build/sessions && cp "$DATA"/Documents/sessions/*.jsonl build/sessions/ 2>/dev/null || true
xcrun simctl io "$SIM" screenshot build/replay/screen-final.png >/dev/null 2>&1 || true
ls build/replay
cat build/replay/events.log 2>/dev/null || true
