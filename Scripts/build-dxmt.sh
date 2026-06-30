#!/usr/bin/env bash
# Build 3Shain's DXMT from source LOCALLY against Silo's CrossOver Wine, then upload it as a GitHub
# Release asset. (Same recipe as .github/workflows/build-dxmt.yml — use whichever is easier.)
#
# DXMT is Silo's OLDER-GAMES backend: a Metal implementation of Direct3D 10/11 (the GPTK fallback for
# titles D3DMetal can't run, e.g. Overcooked 2). We pin the EXACT version CrossOver 26 bundles
# (DXMT_VERSION in versions.env) and build it against the CrossOver Wine from Scripts/build-wine.sh —
# the DXMT↔Wine pairing CrossOver itself ships. We build from DXMT's upstream (3Shain/dxmt) because that
# is its canonical, reproducible build (with the git submodules CrossOver's source tarball omits). DXMT
# is NOT Wine, so constraint #8 (Wine = CrossOver-FOSS only) is unaffected.
#
# Output: dist/dxmt.tar.xz holding lib/wine/{x86_64-windows,x86_64-unix}. In Silo → Settings → DXMT →
# Import, point at the extracted lib/wine/x86_64-windows folder (winemetal.so rides in its x86_64-unix
# sibling, which GraphicsLinker.overlayDXMT reads). Do NOT commit the tarball — attach it to a Release.
#
# PREREQUISITES (more than the Wine build needs):
#   1. A Silo CrossOver Wine INSTALL to build against. Run Scripts/build-wine.sh first (this script then
#      finds .wine-build/install automatically), or pass --wine <dir>. DXMT's winemetal.so links Wine's
#      winemac.so APIs; Silo's Wine is built -fvisibility=default, which is exactly what DXMT requires.
#   2. FULL Xcode with the Metal toolchain (`xcrun -sdk macosx metal`). Command Line Tools alone is NOT
#      enough — the build compiles .metal shaders. Install Xcode, then
#      `sudo xcode-select -s /Applications/Xcode.app`.
#   3. x86_64 Homebrew (the build is x86_64, matching the x86_64 CrossOver Wine + winemetal.so).
#
# Usage: Scripts/build-dxmt.sh [--wine <wine-install-dir>] [dxmt_version] [release_tag]
#   e.g. Scripts/build-dxmt.sh                          # version + paths from versions.env / defaults
#        Scripts/build-dxmt.sh --wine /path/to/install v0.72 dxmt-v0.72
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091  # versions.env is resolved at runtime, not available to the linter
. "$ROOT/versions.env"
set +a
ARCH="arch -x86_64"          # DXMT must be x86_64 to match the x86_64 CrossOver Wine (Rosetta)
BREW=/usr/local/bin/brew     # x86_64 Homebrew (so llvm@15 etc. are x86_64, like build-wine.sh)

# --- args (a --wine flag, then optional positional version + tag) ---
WINE_INSTALL="$ROOT/.wine-build/install"   # default: where build-wine.sh installs
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wine) WINE_INSTALL="${2:?--wine needs a directory}"; shift 2;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done
VER="${POSITIONAL[0]:-$DXMT_VERSION}"
TAG="${POSITIONAL[1]:-dxmt-$VER}"
MINGW_DIR="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
WORK="$ROOT/.dxmt-build"
SRC="$WORK/dxmt"

echo "==> Preflight"
# (1) Full Xcode + Metal toolchain — DXMT compiles .metal shaders via `xcrun metal` (meson.build).
xcrun -sdk macosx -f metal >/dev/null 2>&1 || {
  echo "ERROR: the Metal toolchain isn't available. DXMT compiles .metal shaders, which needs FULL Xcode"
  echo "       (not just Command Line Tools). Install Xcode, then:"
  echo "       sudo xcode-select -s /Applications/Xcode.app"
  exit 1
}
# (2) A Wine install to build against (winemetal.so links its winemac.so + needs its headers/import libs).
[ -d "$WINE_INSTALL" ] || {
  echo "ERROR: no Wine install at '$WINE_INSTALL'."
  echo "       Run Scripts/build-wine.sh first (then this finds .wine-build/install), or pass --wine <dir>."
  exit 1
}
WINE_INSTALL="$(cd "$WINE_INSTALL" && pwd)"   # absolute (meson needs it)
echo "    Wine install: $WINE_INSTALL"
# (3) x86_64 Rosetta + Homebrew.
softwareupdate --install-rosetta --agree-to-license 2>/dev/null || true
# shellcheck disable=SC2016  # the $(...) must run inside the spawned bash, not expand here (brew installer)
[ -x "$BREW" ] || $ARCH /bin/bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

echo "==> x86_64 Homebrew deps (llvm@15 for the airconv shader compiler, meson, ninja)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
$ARCH "$BREW" install llvm@15 meson ninja
LLVM15="$($ARCH "$BREW" --prefix llvm@15)"   # = /usr/local/opt/llvm@15 (meson's default native_llvm_path)

echo "==> Fetch DXMT $VER ($DXMT_REPO) + submodules (directx headers, nvapi)"
rm -rf "$WORK"; mkdir -p "$WORK"
# Keep .git: meson stamps the build version from the tag via vcs_tag (version.h.in → @VCS_TAG@).
git clone --depth 1 --branch "$VER" --recurse-submodules --shallow-submodules \
  "https://github.com/${DXMT_REPO}.git" "$SRC"
cd "$SRC"

echo "==> Fetch the cross toolchain (mstorsjo/llvm-mingw $LLVM_MINGW_VERSION) DXMT's cross-file pins"
# build-win64.txt references @GLOBAL_SOURCE_ROOT@/toolchains/$MINGW_DIR — so it must live in the source tree.
mkdir -p toolchains
curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${MINGW_DIR}.tar.xz" \
  -o llvm-mingw.tar.xz
tar -xf llvm-mingw.tar.xz -C toolchains
rm llvm-mingw.tar.xz
[ -x "toolchains/$MINGW_DIR/bin/x86_64-w64-mingw32-gcc" ] \
  || { echo "ERROR: unexpected llvm-mingw layout (no toolchains/$MINGW_DIR/bin/x86_64-w64-mingw32-gcc)"; exit 1; }

echo "==> Configure + build (x86_64, release) against the Wine install — compiles Metal shaders + airconv"
# Force the NATIVE (winemetal.so + airconv) compile to x86_64 so it matches the x86_64 Wine + x86_64
# llvm@15 (the upstream build-osx.txt sets only `c = clang`; this pins the arch on top of it).
cat > arch-x86_64.txt <<'EOF'
[built-in options]
c_args = ['-arch', 'x86_64']
cpp_args = ['-arch', 'x86_64']
c_link_args = ['-arch', 'x86_64']
cpp_link_args = ['-arch', 'x86_64']
EOF
BREW_BIN="$($ARCH "$BREW" --prefix)/bin"
export PATH="$SRC/toolchains/$MINGW_DIR/bin:$LLVM15/bin:$BREW_BIN:$PATH"
rm -rf build install
$ARCH meson setup \
  --cross-file build-win64.txt --native-file build-osx.txt --native-file arch-x86_64.txt \
  -Dnative_llvm_path="$LLVM15" \
  -Dwine_install_path="$WINE_INSTALL" \
  build --buildtype release --prefix "$SRC/install" --strip
$ARCH meson compile -C build
$ARCH meson install -C build

echo "==> Verify the artifacts Silo overlays (GraphicsLinker.overlayDXMT)"
WINDIR="install/lib/wine/x86_64-windows"; UNIXDIR="install/lib/wine/x86_64-unix"
missing=""
for f in "$WINDIR/d3d11.dll" "$WINDIR/dxgi.dll" "$WINDIR/d3d10core.dll" "$WINDIR/winemetal.dll" \
         "$UNIXDIR/winemetal.so"; do
  [ -e "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then echo "ERROR: build did not produce:$missing"; exit 1; fi
echo "    all present: d3d11/dxgi/d3d10core/winemetal.dll + winemetal.so"
# winemetal.so MUST be x86_64 or it won't load in the x86_64 CrossOver Wine.
file "$UNIXDIR/winemetal.so" | grep -q "x86_64" \
  || { echo "ERROR: winemetal.so is not x86_64 — it can't load in the x86_64 CrossOver Wine."; exit 1; }

echo "==> Package"
mkdir -p "$ROOT/dist"
# Ship lib/ only (the importable tree); drop build-time import libs (*.a) — Silo overlays only .dll/.so.
( cd install && tar -cJf "$ROOT/dist/dxmt.tar.xz" --exclude='*.a' lib )
( cd "$ROOT/dist" && shasum -a 256 dxmt.tar.xz > dxmt.tar.xz.sha256 )
echo "Built: $ROOT/dist/dxmt.tar.xz (+ .sha256)"
echo "Import in Silo (Settings → DXMT → Import…): <extracted>/lib/wine/x86_64-windows"
echo
echo "Publish BOTH as Release assets (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/dxmt.tar.xz\" \"$ROOT/dist/dxmt.tar.xz.sha256\" -t \"$TAG\" -n \"DXMT $VER (built against CrossOver Wine $CROSSOVER_VERSION)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/dxmt.tar.xz\" \"$ROOT/dist/dxmt.tar.xz.sha256\""
