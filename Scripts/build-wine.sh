#!/usr/bin/env bash
# Build CrossOver's Wine from FOSS source LOCALLY, then upload it as a GitHub Release asset.
# (Same recipe as .github/workflows/build-wine.yml — use whichever is easier.)
#
# The result is a ~250 MB wine.tar.xz. Do NOT commit it into git — attach it to a Release with the
# `gh release` command printed at the end. The app downloads it from Silo.wineRepo's Releases.
#
# We build Wine ONLY. GPTK/D3DMetal is Apple-licensed and is imported in-app from the user's .dmg.
#
# Usage: Scripts/build-wine.sh <crossover_version> [release_tag]
#   e.g. Scripts/build-wine.sh 25.0.1 wine-cx-25.0.1
set -euo pipefail

VER="${1:?usage: build-wine.sh <crossover_version> [release_tag]}"
TAG="${2:-wine-cx-$VER}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.wine-build"
ARCH="arch -x86_64"   # CrossOver is x86_64; runs on Apple Silicon via Rosetta
BREW=/usr/local/bin/brew

echo "==> Rosetta + x86_64 Homebrew dependencies"
softwareupdate --install-rosetta --agree-to-license 2>/dev/null || true
[ -x "$BREW" ] || $ARCH /bin/bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
$ARCH "$BREW" install bison mingw-w64 freetype gnutls gstreamer sdl2 molten-vk cmake

echo "==> Fetch CrossOver source $VER"
mkdir -p "$WORK" && cd "$WORK"
curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VER}.tar.gz" -o sources.tar.gz
rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
WINE_SRC="$(find src -maxdepth 3 -type d -name wine | head -1)"
[ -n "$WINE_SRC" ] || { echo "ERROR: wine source dir not found in tarball"; exit 1; }

echo "==> Configure + build (x86_64, wow64) — this takes ~30–60 min"
export PATH="$($ARCH "$BREW" --prefix bison)/bin:$PATH"
rm -rf build install && mkdir build install && cd build
$ARCH "$WORK/$WINE_SRC/configure" --prefix="$WORK/install" \
  --enable-archs=i386,x86_64 --disable-tests --without-x \
  --with-freetype --with-gstreamer --with-gnutls
$ARCH make -j"$(sysctl -n hw.ncpu)"
$ARCH make install

echo "==> Package"
mkdir -p "$ROOT/dist"
( cd "$WORK/install" && tar -cJf "$ROOT/dist/wine.tar.xz" . )
echo "Built: $ROOT/dist/wine.tar.xz"
echo
echo "Publish it as a Release asset (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/wine.tar.xz\" -t \"$TAG\" -n \"CrossOver Wine $VER (FOSS source build)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/wine.tar.xz\""
