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
# NB: sdl2 is NOT installed from Homebrew — we build the pinned SDL_VERSION from source below (a generic
# Homebrew libSDL2 aborted Wine off the main thread; the pinned CrossOver version does not). cmake builds it.
"$ROOT/Scripts/bootstrap-x86-brew.sh" bison mingw-w64 freetype gnutls gstreamer molten-vk cmake

echo "==> Fetch CrossOver source $VER"
mkdir -p "$WORK" && cd "$WORK"
curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VER}.tar.gz" -o sources.tar.gz
rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
WINE_SRC="$(find src -maxdepth 3 -type d -name wine | head -1)"
[ -n "$WINE_SRC" ] || { echo "ERROR: wine source dir not found in tarball"; exit 1; }

echo "==> Build pinned SDL $SDL_VERSION (x86_64) — winebus's game-controller backend dlopens libSDL2"
# Build the EXACT SDL CrossOver ships (versions.env) from libsdl-org source, x86_64 to match Wine. This
# gives Wine's configure the SDL2 headers (so winebus compiles its SDL backend) AND the runtime dylib we
# bundle. A generic Homebrew libSDL2 aborted Wine off the main thread; this pinned build does not.
SDL_PREFIX="$WORK/sdl-install"
export PATH="$($ARCH "$BREW" --prefix cmake)/bin:$($ARCH "$BREW" --prefix bison)/bin:$PATH"
curl -fL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL2-${SDL_VERSION}.tar.gz" -o sdl.tar.gz
rm -rf sdl-src sdl-build "$SDL_PREFIX" && mkdir sdl-src && tar -xzf sdl.tar.gz -C sdl-src --strip-components=1
$ARCH cmake -S sdl-src -B sdl-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_INSTALL_PREFIX="$SDL_PREFIX" -DSDL_SHARED=ON -DSDL_STATIC=OFF
$ARCH cmake --build sdl-build -j"$(sysctl -n hw.ncpu)"
$ARCH cmake --install sdl-build
test -f "$SDL_PREFIX/lib/libSDL2-2.0.0.dylib" || { echo "ERROR: SDL build produced no libSDL2-2.0.0.dylib"; exit 1; }

echo "==> Configure + build (x86_64, wow64) — this takes ~30–60 min"
# Point Wine's --with-sdl at the pinned SDL prefix (headers + pkg-config); winebus dlopens the dylib at
# runtime by SONAME, so the build only needs the SDL2 header to compile its backend.
export PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
rm -rf build install && mkdir build install && cd build
# -fvisibility=default: build Wine with all symbols visible so winemac.drv ('macdrv') exposes its
# Metal/window-surface helpers via dlsym — this is what lets **GPTK/D3DMetal GAMES** present correctly
# (without it the macOS surface path is broken for layered windows and D3D→Metal output is black). NOTE:
# this is NOT what fixes the Steam *client* CEF UI — that black window is fixed at RUNTIME by forcing CEF
# onto its SwiftShader software-GL renderer (STEAM_CEF_COMMAND_LINE + the --in-process-gpu wrapper, see
# SteamBottle.steamEnvironment), not by Metal presentation. Set on BOTH CFLAGS (Wine's Unix-side .so
# thunks, incl. winemac.so) AND CROSSCFLAGS (the PE-side built-in DLLs). -O2 keeps the optimization an
# explicit *FLAGS would otherwise drop. gnutls = Wine's schannel TLS (Steam's networking needs it).
# --with-sdl: build winebus's SDL game-controller backend (dlopens the pinned libSDL2 bundled below).
# With Wine's default `Map Controllers=1` it remaps ANY recognized pad to a standard XInput gamepad — the
# "controllers just work" behaviour. An earlier `--without-sdl` was a workaround for a generic Homebrew
# libSDL2 aborting Wine off the main thread; the pinned SDL_VERSION (= CrossOver's) doesn't, so SDL is on.
$ARCH env CFLAGS="-fvisibility=default -O2" CROSSCFLAGS="-fvisibility=default -O2" \
  CPPFLAGS="-I$SDL_PREFIX/include ${CPPFLAGS:-}" LDFLAGS="-L$SDL_PREFIX/lib ${LDFLAGS:-}" \
  "$WORK/$WINE_SRC/configure" --prefix="$WORK/install" \
  --enable-archs=i386,x86_64 --disable-tests --without-x \
  --with-freetype --with-gstreamer --with-gnutls --with-sdl
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
# SILO_SDL_DYLIB tells the bundler to ship our pinned libSDL2 (winebus dlopens it by leaf name from
# DYLD_FALLBACK_LIBRARY_PATH=<wine>/lib/silo-bundled).
SILO_SDL_DYLIB="$SDL_PREFIX/lib/libSDL2-2.0.0.dylib" "$ROOT/Scripts/bundle-wine-dylibs.sh" "$WORK/install"

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
