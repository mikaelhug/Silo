#!/usr/bin/env bash
# Install a Wine build into Silo's Runtimes dir for LOCAL testing — no GitHub release / push needed.
# Afterwards the app's Wine Manager → Wine tab lists it; set it as default and you're ready.
#
# Usage: Scripts/install-local-wine.sh <wine-dir-or-tarball> [name]
#   <wine-dir-or-tarball>:
#     - a directory containing bin/wine64 (e.g. .wine-build/install after Scripts/build-wine.sh,
#       or a CrossOver/Whisky/Kegworks wine directory), OR
#     - a .tar.xz / .tar.gz Wine archive.
#   [name]: runtime name shown in the app (default: wine-local)
set -euo pipefail

SRC="${1:?usage: install-local-wine.sh <wine-dir-or-tarball> [name]}"
NAME="${2:-wine-local}"
DEST="$HOME/Library/Application Support/Silo/Runtimes/$NAME"

# Validate the SOURCE before touching the destination (so a bad arg never leaves an empty runtime).
if [ ! -e "$SRC" ]; then
  echo "ERROR: '$SRC' does not exist."
  echo "Build Wine first:  Scripts/build-wine.sh <crossover_version>   (then pass .wine-build/install)"
  echo "or pass an existing wine directory (containing bin/wine64) or a .tar.* archive."
  exit 1
fi
if [ -d "$SRC" ]; then
  KIND=dir
elif [[ "$SRC" == *.tar.* ]]; then
  KIND=tar
else
  echo "ERROR: '$SRC' is neither a directory nor a .tar.* archive."; exit 1
fi

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mkdir -p "$DEST"
if [ "$KIND" = dir ]; then
  cp -R "$SRC"/. "$DEST"/
else
  tar -xf "$SRC" -C "$DEST"
fi

if find "$DEST" \( -name wine64 -o -name wine \) -type f 2>/dev/null | grep -q .; then
  # Bundle its dependency dylibs (freetype/gstreamer/…) so it's self-contained, matching the CI build.
  "$(dirname "$0")/bundle-wine-dylibs.sh" "$DEST" || echo "(warning: dylib bundling failed — wine may need Homebrew deps)"
  echo "Installed Wine '$NAME' for local testing:"
  echo "  $DEST"
  echo "Open Silo → Wine Manager → Wine tab → Set default."
else
  rm -rf "$DEST"   # don't leave an empty/garbage runtime behind
  echo "ERROR: no wine64/wine binary found under the source — nothing installed. Check '$SRC'."
  exit 1
fi
