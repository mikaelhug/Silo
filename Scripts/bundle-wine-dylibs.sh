#!/usr/bin/env bash
# Make a Wine install self-contained: copy the transitive closure of its non-system (Homebrew) dylib
# dependencies into <wine>/lib/silo-bundled. The app launches wine with
# DYLD_FALLBACK_LIBRARY_PATH=<wine>/lib/silo-bundled, so dyld resolves both link-time deps (whose
# absolute /opt/homebrew|/usr/local paths are absent on the user's machine) AND dlopen'd libs
# (freetype, MoltenVK, …) by leaf name from there. No install-name rewriting needed.
#
# Usage: bundle-wine-dylibs.sh <wine-install-dir>
set -euo pipefail

WD="${1:?usage: bundle-wine-dylibs.sh <wine-install-dir>}"
BUNDLED="$WD/lib/silo-bundled"
rm -rf "$BUNDLED"; mkdir -p "$BUNDLED"

# Bundle only dylibs matching the wine binary's architecture (CrossOver wine is x86_64; a Mac with
# arm64 Homebrew must not contribute arm64 copies an x86_64 wine can't load).
WINE="$WD/bin/wine64"; [ -x "$WINE" ] || WINE="$WD/bin/wine"
ARCH="$(lipo -archs "$WINE" 2>/dev/null | awk '{print $1}')"; ARCH="${ARCH:-x86_64}"
echo "Target arch: $ARCH"

QUEUE="$(mktemp)"; DONE="$(mktemp)"
trap 'rm -f "$QUEUE" "$DONE"' EXIT

realpath_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
has_arch() { lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$ARCH"; }

# Seed: every non-system dylib referenced by any Mach-O in the tree, plus libs wine dlopen's by name
# (invisible to otool) resolved from Homebrew.
{
  find "$WD/bin" "$WD/lib" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}'
  done
  for pkg in freetype gnutls molten-vk sdl2 libpng; do
    find "/opt/homebrew/opt/$pkg/lib" "/usr/local/opt/$pkg/lib" -maxdepth 1 -name '*.dylib' 2>/dev/null || true
  done
} | grep -E '^/opt/homebrew/|^/usr/local/' | sort -u > "$QUEUE"

# Transitive closure (BFS over the queue file; bash 3.2-safe).
while [ -s "$QUEUE" ]; do
  path="$(head -n1 "$QUEUE")"
  tail -n +2 "$QUEUE" > "$QUEUE.t" && mv "$QUEUE.t" "$QUEUE"
  leaf="$(basename "$path")"
  grep -qxF "$leaf" "$DONE" 2>/dev/null && continue
  real="$(realpath_of "$path")"
  [ -f "$real" ] || continue
  # Skip wrong-arch copies WITHOUT marking the leaf done, so a matching-arch sibling can still win.
  has_arch "$real" || continue
  echo "$leaf" >> "$DONE"
  cp -f "$real" "$BUNDLED/$leaf"
  chmod u+w "$BUNDLED/$leaf"
  otool -L "$real" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -E '^/opt/homebrew/|^/usr/local/' >> "$QUEUE" || true
done

# Ad-hoc sign the bundled dylibs (they're modified copies).
find "$BUNDLED" -type f -name '*.dylib' -exec codesign --force --sign - {} + 2>/dev/null || true

echo "Bundled $(find "$BUNDLED" -type f -name '*.dylib' | wc -l | tr -d ' ') dylibs into $BUNDLED ($(du -sh "$BUNDLED" | cut -f1))"
