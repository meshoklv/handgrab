#!/bin/bash
# Install a build onto a connected iPhone and launch it (needs a signed app: use Xcode for the first run).
#   DEVICE=<udid-or-name> scripts/install.sh [path/to/HandGrab.app]
# List devices: xcrun devicectl list devices
set -euo pipefail
source "$(dirname "$0")/env.sh"
APP=${1:-$ROOT/build/signed/HandGrab.app}
: "${DEVICE:?set DEVICE (see: xcrun devicectl list devices)}"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || echo "launch failed (phone locked?) - open HandGrab by hand"
