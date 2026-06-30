#!/usr/bin/env bash
# Assemble dist/Silo.app from the SwiftPM release build (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Silo"
BIN_NAME="silo"
CONFIG="release"
APP="dist/$APP_NAME.app"

# Versions come from versions.env (the single source of truth). Regenerate the committed Swift mirror so
# the assembled app always matches, then read the marketing version for the Info.plist.
./Scripts/gen-versions.sh
set -a; . ./versions.env; set +a
VERSION="$SILO_VERSION"
BUILD=$(date +%Y%m%d%H%M)

# CI/distribution builds compile wine logging OFF (SILO_QUIET_WINE → WINEDEBUG=-all); LOCAL builds stay
# verbose (+loaddll) so launch logs carry the diagnostics we (and the GraphicsFallback guardrail) need
# while developing. GitHub Actions sets $CI, so the shipped app is automatically silent.
QUIET=""
if [ -n "${CI:-}" ]; then QUIET="-Xswiftc -DSILO_QUIET_WINE"; echo "==> CI build: wine logging OFF"; fi
echo "==> swift build -c $CONFIG $QUIET"
swift build -c "$CONFIG" $QUIET
BIN_PATH=".build/$CONFIG/$BIN_NAME"

echo "==> assembling $APP (v$VERSION build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/\${VERSION}/$VERSION/g" -e "s/\${BUILD}/$BUILD/g" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles (SiloKit has none today; copy any that appear later).
shopt -s nullglob
for bundle in ".build/$CONFIG"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

./Scripts/sign.sh "$APP"
echo "==> Built $APP"
