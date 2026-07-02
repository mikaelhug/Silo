#!/usr/bin/env bash
# Build CrossOver's Wine from FOSS source LOCALLY, then upload it as a GitHub Release asset.
# (Same recipe as .github/workflows/build-wine.yml — use whichever is easier.)
#
# The result is a ~250 MB wine.tar.xz. Do NOT commit it into git — attach it to a Release with the
# `gh release` command printed at the end. The app downloads it from Silo.wineRepo's Releases.
#
# We build Wine ONLY. GPTK/D3DMetal is Apple-licensed and is imported in-app from the user's .dmg.
#
# Usage: Scripts/build-wine.sh [crossover_version] [release_tag]
#   e.g. Scripts/build-wine.sh 26.2.0 wine-cx-26.2.0
#   With no version, defaults to CROSSOVER_VERSION from versions.env (the single source of truth).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
VER="${1:-$CROSSOVER_VERSION}"
TAG="${2:-wine-cx-$VER}"
WORK="$ROOT/.wine-build"
ARCH="arch -x86_64"   # CrossOver is x86_64; runs on Apple Silicon via Rosetta
BREW=/usr/local/bin/brew

echo "==> Rosetta + x86_64 Homebrew dependencies"
"$ROOT/Scripts/bootstrap-x86-brew.sh" bison mingw-w64 freetype gnutls gstreamer sdl2 molten-vk cmake

echo "==> Fetch CrossOver source $VER"
mkdir -p "$WORK" && cd "$WORK"
curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VER}.tar.gz" -o sources.tar.gz
rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
WINE_SRC="$(find src -maxdepth 3 -type d -name wine | head -1)"
[ -n "$WINE_SRC" ] || { echo "ERROR: wine source dir not found in tarball"; exit 1; }

echo "==> Configure + build (x86_64, wow64) — this takes ~30–60 min"
export PATH="$($ARCH "$BREW" --prefix bison)/bin:$PATH"
rm -rf build install && mkdir build install && cd build
# -fvisibility=default: build Wine with all symbols visible so winemac.drv ('macdrv') exposes its
# Metal/window-surface helpers via dlsym — this is what lets **GPTK/D3DMetal GAMES** present correctly
# (without it the macOS surface path is broken for layered windows and D3D→Metal output is black). NOTE:
# this is NOT what fixes the Steam *client* CEF UI — that black window is fixed at RUNTIME by forcing CEF
# onto its SwiftShader software-GL renderer (STEAM_CEF_COMMAND_LINE + the --in-process-gpu wrapper, see
# SteamBottle.steamEnvironment), not by Metal presentation. Set on BOTH CFLAGS (Wine's Unix-side .so
# thunks, incl. winemac.so) AND CROSSCFLAGS (the PE-side built-in DLLs). -O2 keeps the optimization an
# explicit *FLAGS would otherwise drop. gnutls = Wine's schannel TLS (Steam's networking needs it).
# --without-sdl: build winebus WITHOUT the SDL game-controller backend. On macOS that backend `dlopen`s
# libSDL2, whose initializer pops an NSAlert off the main thread → the whole Wine process aborts the moment
# winebus loads (before Steam draws). Costs in-Wine controller support; gains a Wine that actually launches.
$ARCH env CFLAGS="-fvisibility=default -O2" CROSSCFLAGS="-fvisibility=default -O2" \
  "$WORK/$WINE_SRC/configure" --prefix="$WORK/install" \
  --enable-archs=i386,x86_64 --disable-tests --without-x \
  --with-freetype --with-gstreamer --with-gnutls --without-sdl
$ARCH make -j"$(sysctl -n hw.ncpu)"
$ARCH make install

echo "==> Build the steamwebhelper wrapper (forces CEF --in-process-gpu + software GL so Steam's UI paints)"
mkdir -p "$WORK/install/share/silo"
WRAPPER="$WORK/install/share/silo/steamwebhelper-wrapper.exe"
"$($ARCH "$BREW" --prefix mingw-w64)/bin/x86_64-w64-mingw32-gcc" -O2 -municode -mwindows \
  -o "$WRAPPER" "$ROOT/Scripts/steamwebhelper-wrapper.c"
# The wrapper is load-bearing — fail the build if its CEF flags are wrong (shared check, also run in CI).
python3 "$ROOT/Scripts/check-webhelper-wrapper.py" "$WRAPPER"

echo "==> Bundle dependency dylibs (self-contained runtime)"
"$ROOT/Scripts/bundle-wine-dylibs.sh" "$WORK/install"

echo "==> Package"
mkdir -p "$ROOT/dist"
# New WoW64 builds install a unified `wine`; add a wine64 alias for consumers expecting it.
if [ -e "$WORK/install/bin/wine" ] && [ ! -e "$WORK/install/bin/wine64" ]; then
  ( cd "$WORK/install/bin" && ln -s wine wine64 )
fi
( cd "$WORK/install" && tar -cJf "$ROOT/dist/wine.tar.xz" . )
( cd "$ROOT/dist" && shasum -a 256 wine.tar.xz > wine.tar.xz.sha256 )   # app verifies this before extracting
echo "Built: $ROOT/dist/wine.tar.xz (+ .sha256)"
echo
echo "Publish BOTH as Release assets (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/wine.tar.xz\" \"$ROOT/dist/wine.tar.xz.sha256\" -t \"$TAG\" -n \"CrossOver Wine $VER (FOSS source build)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/wine.tar.xz\" \"$ROOT/dist/wine.tar.xz.sha256\""
