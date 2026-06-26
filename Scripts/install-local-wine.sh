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

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mkdir -p "$DEST"

if [ -d "$SRC" ]; then
  cp -R "$SRC"/. "$DEST"/
elif [[ "$SRC" == *.tar.* ]]; then
  tar -xf "$SRC" -C "$DEST"
else
  echo "ERROR: '$SRC' is neither a directory nor a .tar.* archive"; exit 1
fi

if find "$DEST" \( -name wine64 -o -name wine \) -type f 2>/dev/null | grep -q .; then
  echo "Installed Wine '$NAME' for local testing:"
  echo "  $DEST"
  echo "Open Silo → Wine Manager → Wine tab → Set default."
else
  echo "WARNING: no wine64/wine binary found under $DEST — the app won't list it. Check the source."
  exit 1
fi
