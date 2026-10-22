# Sourced by the other scripts: reads HANDGRAB_BUNDLE_ID from Config.xcconfig (falls back to the example value).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID=${BUNDLE_ID:-$(sed -n 's/^HANDGRAB_BUNDLE_ID *= *//p' "$ROOT/Config.xcconfig" "$ROOT/Config.example.xcconfig" 2>/dev/null | head -1)}
