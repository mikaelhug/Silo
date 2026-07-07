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
# Output: dist/dxmt.tar.xz holding {x86_64-windows, i386-windows, x86_64-unix} — DXMT's D3D10/11 for BOTH
# 64-bit and 32-bit games (32-bit-only titles like Overcooked 2 need the i386 tree; wine auto-selects per
# game by PE machine type). In Silo → Settings → DXMT → Import, point at the extracted x86_64-windows folder
# (winemetal.so rides in the x86_64-unix sibling, and overlayDXMT picks up the i386-windows sibling too).
# Do NOT commit the tarball — attach it to a Release.
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
# Per-wine tag (matches CI): the wine this builds against is the versions.env CrossOver (.wine-build/install).
TAG="${POSITIONAL[1]:-dxmt-$VER-cx$CROSSOVER_VERSION}"
MINGW_DIR="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
WORK="$ROOT/.dxmt-build"
SRC="$WORK/dxmt"

echo "==> Preflight"
# (1) Full Xcode + Metal toolchain — DXMT compiles .metal shaders via `xcrun metal` (meson.build).
echo "    Xcode: $(xcode-select -p 2>/dev/null || echo '?')"
# DXMT compiles .metal shaders. Xcode 16+/26 ship the Metal TOOLCHAIN as a SEPARATE component — the bare
# `metal` binary is present (so `-f metal` finds it) but `metal -c` FAILS until the component is installed.
# Fetch it (idempotent — no-op once present), then verify by actually compiling a probe shader.
xcodebuild -downloadComponent MetalToolchain 2>/dev/null || true
_probe="$(mktemp -d)/p.metal"; printf 'kernel void _p() {}' > "$_probe"
if ! xcrun -sdk macosx metal -c "$_probe" -o "$_probe.air" >/dev/null 2>&1; then
  rm -rf "$(dirname "$_probe")"
  echo "ERROR: the Metal shader compiler can't run (DXMT compiles .metal shaders). Ensure full Xcode is"
  echo "       installed + selected, then:"
  echo "         sudo xcode-select -s /Applications/Xcode.app   # if it points at CommandLineTools"
  echo "         sudo xcodebuild -license accept                # if not yet accepted"
  echo "         xcodebuild -downloadComponent MetalToolchain   # install the Metal toolchain (~2 GB)"
  exit 1
fi
rm -rf "$(dirname "$_probe")"
echo "    Metal toolchain: OK"
# (2) A Wine install to build against (winemetal.so links its winemac.so + needs its headers/import libs).
[ -d "$WINE_INSTALL" ] || {
  echo "ERROR: no Wine install at '$WINE_INSTALL'."
  echo "       Run Scripts/build-wine.sh first (then this finds .wine-build/install), or pass --wine <dir>."
  exit 1
}
WINE_INSTALL="$(cd "$WINE_INSTALL" && pwd)"   # absolute (meson needs it)
echo "    Wine install: $WINE_INSTALL"
echo "==> Rosetta + x86_64 Homebrew deps (llvm@15 for the airconv shader compiler, meson, ninja)"
"$ROOT/Scripts/bootstrap-x86-brew.sh" llvm@15 meson ninja
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
# Native (macOS) toolchain for winemetal.so + airconv: pin the SYSTEM clang by ABSOLUTE path, x86_64. This
# is load-bearing — llvm-mingw AND llvm@15 each ship a bare `clang` on PATH that would otherwise shadow the
# Apple clang; those can't link macOS binaries (you get `ld: library 'System' not found`). Overrides DXMT's
# build-osx.txt (which uses a bare `clang`).
cat > silo-osx.txt <<'EOF'
[binaries]
c = ['/usr/bin/clang', '-arch', 'x86_64']
cpp = ['/usr/bin/clang++', '-arch', 'x86_64']
EOF
# Cross toolchain (llvm-mingw) is referenced by ABSOLUTE path in build-win64.txt, and llvm@15 via
# -Dnative_llvm_path — so keep them AFTER the system dirs on PATH (system clang/ld/ar win for bare names).
export PATH="$PATH:$SRC/toolchains/$MINGW_DIR/bin:$LLVM15/bin"
rm -rf build build32 install

# -Dwine_builtin_dll=true: install d3d10core/d3d11/dxgi AND winemetal all into <arch>-windows as BUILTIN
# (v0.72 defaults false, which drops the d3d dlls in system32 as native). Silo overlays them into the
# runtime's lib/wine as builtin (GraphicsLinker.overlayDXMT) + forces `…=b`, so this is the layout it needs.
#
# Build BOTH ABIs into the SAME install prefix: win64 → install/x86_64-windows (+ x86_64-unix/winemetal.so),
# win32 → install/i386-windows. Wine then loads DXMT's d3d from the tree matching each game's PE machine
# type (64-bit game → x86_64-windows, 32-bit game → i386-windows) with no per-game selection — 32-bit-only
# titles like Overcooked 2 need the i386 tree. The unix winemetal.so is host-arch (x86_64) and shared by
# both PE ABIs (new-WoW64), so the i386 PE winemetal.dll thunks into the same x86_64-unix/winemetal.so.
build_abi() {  # $1 = meson cross-file, $2 = build dir
  $ARCH meson setup \
    --cross-file "$1" --native-file silo-osx.txt \
    -Dnative_llvm_path="$LLVM15" \
    -Dwine_install_path="$WINE_INSTALL" \
    -Dwine_builtin_dll=true \
    "$2" --buildtype release --prefix "$SRC/install" --strip
  $ARCH meson compile -C "$2"
  $ARCH meson install -C "$2"
}
build_abi build-win64.txt build      # → install/x86_64-windows + install/x86_64-unix
build_abi build-win32.txt build32    # → install/i386-windows (shares the x86_64-unix winemetal.so)

echo "==> Verify the artifacts Silo overlays (GraphicsLinker.overlayDXMT)"
# wine_builtin_dll=true → all dlls in <arch>-windows (builtin) + winemetal.so in the x86_64-unix sibling.
UNIXDIR="install/x86_64-unix"
missing=""
for WINDIR in install/x86_64-windows install/i386-windows; do
  for f in "$WINDIR/d3d11.dll" "$WINDIR/dxgi.dll" "$WINDIR/d3d10core.dll" "$WINDIR/winemetal.dll"; do
    [ -e "$f" ] || missing="$missing $f"
  done
done
[ -e "$UNIXDIR/winemetal.so" ] || missing="$missing $UNIXDIR/winemetal.so"
if [ -n "$missing" ]; then echo "ERROR: build did not produce:$missing"; exit 1; fi
echo "    all present: {x86_64,i386}-windows d3d11/dxgi/d3d10core/winemetal.dll + x86_64-unix/winemetal.so"
# winemetal.so MUST be x86_64 or it won't load in the x86_64 CrossOver Wine.
file "$UNIXDIR/winemetal.so" | grep -q "x86_64" \
  || { echo "ERROR: winemetal.so is not x86_64 — it can't load in the x86_64 CrossOver Wine."; exit 1; }

echo "==> Package"
mkdir -p "$ROOT/dist"
# Ship x86_64-windows + i386-windows + x86_64-unix as siblings (overlayDXMT reads winemetal.so from the
# x86_64-unix sibling of the imported x86_64-windows folder, and overlays the i386-windows sibling too when
# present); drop build-time import libs (*.a) — Silo overlays .dll/.so. i386-unix is included only if the
# build produced one (new-WoW64 shares x86_64-unix, so normally there is none).
I386_UNIX=""; [ -d install/i386-unix ] && I386_UNIX="i386-unix"
( cd install && tar -cJf "$ROOT/dist/dxmt.tar.xz" --exclude='*.a' x86_64-windows i386-windows x86_64-unix $I386_UNIX )
( cd "$ROOT/dist" && shasum -a 256 dxmt.tar.xz > dxmt.tar.xz.sha256 )
echo "Built: $ROOT/dist/dxmt.tar.xz (+ .sha256)"
echo "Import in Silo (Settings → DXMT → Import…): <extracted>/x86_64-windows"
echo
echo "Publish BOTH as Release assets (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/dxmt.tar.xz\" \"$ROOT/dist/dxmt.tar.xz.sha256\" -t \"$TAG\" -n \"DXMT $VER (built against CrossOver Wine $CROSSOVER_VERSION)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/dxmt.tar.xz\" \"$ROOT/dist/dxmt.tar.xz.sha256\""
