#!/bin/bash
# Unsigned build on a Mac with Xcode. Used by `make build` (device) and `make sim` (Simulator).
#   CONF=Release|Debug   SDK=iphoneos|iphonesimulator
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=${CONF:-Release}
SDK=${SDK:-iphoneos}
[ -f Config.xcconfig ] || cp Config.example.xcconfig Config.xcconfig
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
xcodegen generate -q
xcodebuild -project HandGrab.xcodeproj -target HandGrab -configuration "$CONF" \
  -sdk "$SDK" -arch arm64 \
  SYMROOT="$PWD/build/sym" OBJROOT="$PWD/build/obj" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
echo "APP: $PWD/build/sym/$CONF-$SDK/HandGrab.app"
