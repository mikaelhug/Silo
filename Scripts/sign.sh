#!/usr/bin/env bash
# Ad-hoc sign the app and strip the quarantine bit for local runs.
# Distribution requires Developer ID + notarization (a human-input step; see STATUS.md).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Silo.app}"

codesign --force --deep --sign - \
    --entitlements Resources/silo.entitlements \
    "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --verbose "$APP"
echo "==> Ad-hoc signed: $APP"
