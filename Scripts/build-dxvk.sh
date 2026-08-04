#!/usr/bin/env bash
# Build DXVK from source (doitsujin/dxvk) → native d3d9/d3d10core/d3d11/dxgi PE dlls for BOTH ABIs, then
# upload as a GitHub Release asset. (Same recipe as .github/workflows/build-dxvk.yml — use whichever is easier.)
#
# DXVK is Silo's DirectX 9 translator AND the broad compatibility fallback below GPTK/DXMT: D3D9/10/11 →
# Vulkan → the wine runtime's already-bundled MoltenVK → Metal. Built STOCK from upstream (no patches) and
# shipped as NATIVE dlls — Silo seeds them into the game prefix's system32/syswow64 and overrides them `=n`
# (GraphicsLinker.installDXVKPrefixLoaders), running on the base wine runtime with nothing overlaid into
# lib/wine. DXVK is NOT Wine, so constraint #8 (Wine = CrossOver-FOSS only) is unaffected. Never a prebuilt.
#
# Unlike the DXMT / Wine builds, DXVK targets Windows PE and needs NO macOS Metal toolchain or Wine install —
# so this runs on a COMMAND-LINE-TOOLS-ONLY box (no full Xcode required).
#
# Output: dist/dxvk.tar.xz holding {x86_64-windows, i386-windows} + **lib/libMoltenVK.dylib** — DXVK's
# D3D9/10/11 + its own dxgi for 64-bit and 32-bit games (wine auto-selects per game by PE machine type; the
# i386 tree runs 32-bit DirectX 9 titles, which neither GPTK nor DXMT can), plus the Vulkan driver DXVK runs
# on. In Silo → Settings → DXVK → Import, point at the extracted x86_64-windows folder
# (installDXVKPrefixLoaders picks up the i386-windows sibling; the launch puts `<dxvk>/lib` first on
# DYLD_FALLBACK_LIBRARY_PATH so THIS MoltenVK is the driver). Do NOT commit the tarball — attach to a Release.
#
# ⚠️ **The bundled MoltenVK is LOAD-BEARING** (proven on-device 2026-08-04): a STOCK MoltenVK cannot create a
#    D3D device for DXVK at ANY feature level; a PATCHED one works (FL 11_0). See versions.env. Also validate
#    the DXVK_VERSION↔MoltenVK pairing when bumping either — a newer DXVK needs more Vulkan features.
#
# PREREQUISITES: meson + ninja + glslang (glslangValidator) on PATH → `brew install meson ninja glslang`.
#   Building MoltenVK from source additionally needs full Xcode (it compiles Metal shaders); when Xcode is
#   absent this script SKIPS the MoltenVK build and warns — the DXVK dlls alone are then NOT usable, so
#   produce the dylib on a machine/CI runner with Xcode (build-dxvk.yml does).
#
# Usage: Scripts/build-dxvk.sh [dxvk_version] [release_tag]
#   e.g. Scripts/build-dxvk.sh                 # version + tag from versions.env / defaults
#        Scripts/build-dxvk.sh v2.6.2 dxvk-v2.6.2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091  # versions.env is resolved at runtime, not available to the linter
. "$ROOT/versions.env"
set +a

VER="${1:-$DXVK_VERSION}"
# Per-wine tag (matches CI): DXVK is wine-independent, but we tag by the CrossOver wine it's validated with,
# mirroring the dxmt-<ver>-cx<ver> scheme so Silo can match a DXVK release to the installed wine.
TAG="${2:-dxvk-$VER-cx$CROSSOVER_VERSION}"
MINGW_DIR="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
WORK="$ROOT/.dxvk-build"
SRC="$WORK/dxvk"
WANT_DLLS=(d3d9.dll d3d10core.dll d3d11.dll dxgi.dll)   # what Silo seeds (isDXVKModule); d3d8/d3d10 wrapper dropped

echo "==> Preflight (meson, ninja, glslangValidator — no Metal toolchain / Wine install needed)"
for tool in meson ninja glslangValidator; do
  command -v "$tool" >/dev/null \
    || { echo "ERROR: '$tool' not found. Install: brew install meson ninja glslang"; exit 1; }
done

echo "==> Fetch DXVK $VER ($DXVK_REPO) + submodules"
rm -rf "$WORK"; mkdir -p "$WORK"
git clone --depth 1 --branch "$VER" --recurse-submodules --shallow-submodules \
  "https://github.com/${DXVK_REPO}.git" "$SRC"
cd "$SRC"

echo "==> Fetch the cross toolchain (mstorsjo/llvm-mingw $LLVM_MINGW_VERSION) — provides x86_64/i686-w64-mingw32"
mkdir -p toolchains
curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${MINGW_DIR}.tar.xz" \
  -o llvm-mingw.tar.xz
tar -xf llvm-mingw.tar.xz -C toolchains
rm llvm-mingw.tar.xz
# DXVK's own cross-files (build-win64.txt / build-win32.txt) call the x86_64-/i686-w64-mingw32 tools by bare
# name, so the toolchain must lead PATH.
export PATH="$SRC/toolchains/$MINGW_DIR/bin:$PATH"
command -v x86_64-w64-mingw32-gcc >/dev/null \
  || { echo "ERROR: unexpected llvm-mingw layout (no x86_64-w64-mingw32-gcc on PATH)"; exit 1; }

echo "==> Configure + build (release), both ABIs, into clean prefixes"
rm -rf build.w64 build.w32 install64 install32
# Take DXVK's DEFAULT enabled targets (dxgi/d3d9/d3d10/d3d11 — and d3d8, which we just don't ship) rather than
# passing -Denable_* flags, so this stays robust across DXVK versions that add/rename those options. We
# cherry-pick the dlls Silo seeds after install. `meson install` drops the PE dlls in <prefix>/bin.
build_abi() {  # $1 = DXVK cross-file, $2 = build dir, $3 = install prefix
  meson setup --cross-file "$1" --buildtype release --prefix "$SRC/$3" "$2"
  ninja -C "$2"
  ninja -C "$2" install
}
build_abi build-win64.txt build.w64 install64
build_abi build-win32.txt build.w32 install32

echo "==> Assemble the Silo layout (x86_64-windows + i386-windows)"
rm -rf out; mkdir -p out/x86_64-windows out/i386-windows
locate_dll() { find "$1" -name "$2" -type f 2>/dev/null | head -1; }   # robust to bin/ vs other install layout
for dll in "${WANT_DLLS[@]}"; do
  s64="$(locate_dll install64 "$dll")"; s32="$(locate_dll install32 "$dll")"
  [ -n "$s64" ] && cp "$s64" "out/x86_64-windows/$dll"
  [ -n "$s32" ] && cp "$s32" "out/i386-windows/$dll"
done

echo "==> Verify the artifacts Silo seeds (GraphicsLinker.installDXVKPrefixLoaders)"
missing=""
for dir in out/x86_64-windows out/i386-windows; do
  for f in "${WANT_DLLS[@]}"; do [ -e "$dir/$f" ] || missing="$missing $dir/$f"; done
done
[ -n "$missing" ] && { echo "ERROR: build did not produce:$missing"; exit 1; }
# The dlls MUST be PE (Windows) images, not host Mach-O.
file "out/x86_64-windows/d3d11.dll" | grep -qi "PE32" \
  || { echo "ERROR: d3d11.dll is not a PE image — the cross-build didn't target Windows."; exit 1; }
echo "    all present: {x86_64,i386}-windows d3d9/d3d10core/d3d11/dxgi.dll"

echo "==> Build MoltenVK $MOLTENVK_VERSION (the Vulkan driver DXVK runs on — LOAD-BEARING, see header)"
# A STOCK MoltenVK cannot create a D3D device for DXVK at any feature level (on-device 2026-08-04); the
# runtime must therefore carry its own. MoltenVK compiles Metal shaders, so it needs FULL Xcode.
mkdir -p out/lib
if xcrun -sdk macosx metal -e /dev/null -o /dev/null >/dev/null 2>&1 || \
   (xcodebuild -version >/dev/null 2>&1 && [ "$(xcode-select -p)" != "/Library/Developer/CommandLineTools" ]); then
  rm -rf "$WORK/MoltenVK"
  git clone --depth 1 --branch "$MOLTENVK_VERSION" "https://github.com/${MOLTENVK_REPO}.git" "$WORK/MoltenVK"
  ( cd "$WORK/MoltenVK" && ./fetchDependencies --macos && make macos )
  MVK_DYLIB="$(find "$WORK/MoltenVK/Package/Release/MoltenVK" -name 'libMoltenVK.dylib' -type f 2>/dev/null | head -1)"
  if [ -n "$MVK_DYLIB" ]; then
    cp "$MVK_DYLIB" out/lib/libMoltenVK.dylib
    echo "    MoltenVK: $(file -b out/lib/libMoltenVK.dylib)"
  else
    echo "::warning:: MoltenVK build produced no libMoltenVK.dylib — the DXVK dlls alone are NOT usable."
  fi
else
  echo "::warning:: full Xcode not selected — SKIPPING the MoltenVK build."
  echo "            The DXVK dlls alone are NOT usable (stock MoltenVK can't drive DXVK). Build on a runner"
  echo "            with Xcode (see .github/workflows/build-dxvk.yml), or run:"
  echo "              sudo xcode-select -s /Applications/Xcode.app"
fi

echo "==> Package"
mkdir -p "$ROOT/dist"
( cd out && tar -cJf "$ROOT/dist/dxvk.tar.xz" x86_64-windows i386-windows lib )
( cd "$ROOT/dist" && shasum -a 256 dxvk.tar.xz > dxvk.tar.xz.sha256 )
echo "Built: $ROOT/dist/dxvk.tar.xz (+ .sha256)"
echo "Import in Silo (Settings → DXVK → Import…): <extracted>/x86_64-windows"
echo
echo "Publish BOTH as Release assets (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/dxvk.tar.xz\" \"$ROOT/dist/dxvk.tar.xz.sha256\" -t \"$TAG\" -n \"DXVK $VER (validated with CrossOver Wine $CROSSOVER_VERSION)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/dxvk.tar.xz\" \"$ROOT/dist/dxvk.tar.xz.sha256\""
