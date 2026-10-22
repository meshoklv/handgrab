#!/bin/bash
# Download MediaPipe Tasks Vision 0.10.35 (no CocoaPods needed) and the Hand Landmarker model into vendor/mediapipe.
# Optional: HandGrab runs on Apple Vision alone; MediaPipe is used as a second detector and in the benchmark.
# Frameworks come from Google's CocoaPods CDN (see the MediaPipeTasksCommon / MediaPipeTasksVision 0.10.35 podspecs).
set -euo pipefail
cd "$(dirname "$0")/.."
V=0.10.35
D=vendor/mediapipe/$V
mkdir -p "$D" && cd "$D"
[ -d frameworks/MediaPipeTasksCommon.xcframework ] || curl -sL https://dl.google.com/cpdc/20260427-204214/MediaPipeTasksCommon-$V.tar.gz | tar -xzf -
[ -d frameworks/MediaPipeTasksVision.xcframework ] || curl -sL https://dl.google.com/cpdc/20260427-204221/MediaPipeTasksVision-$V.tar.gz | tar -xzf -
cd ../../..
[ -f vendor/mediapipe/hand_landmarker.task ] || curl -sL -o vendor/mediapipe/hand_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task
ls -la vendor/mediapipe "$D/frameworks"
