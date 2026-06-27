#!/usr/bin/env bash
# Recompile ONLY the steamwebhelper CEF wrapper into an already-installed Wine runtime — NO full wine
# rebuild. Use when steamwebhelper-wrapper.c's flags changed but the Wine binary did NOT (the wrapper is a
# tiny mingw .exe; the wine build is the slow ~hour part and is unaffected).
#
# Usage: Scripts/update-wrapper.sh [wine-runtime-dir]
#   default: the newest ~/Library/Application Support/Silo/Runtimes/wine-cx-*  (or pass a runtime dir).
# After running it, just relaunch the Steam bottle — Silo re-applies the wrapper before each launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RT="${1:-}"
if [ -z "$RT" ]; then
  RT="$(ls -d "$HOME/Library/Application Support/Silo/Runtimes/"wine-cx-* 2>/dev/null | sort | tail -1 || true)"
fi
[ -n "$RT" ] && [ -d "$RT" ] || { echo "ERROR: wine runtime dir not found — pass it as an argument" >&2; exit 1; }

GCC="$(/usr/local/bin/brew --prefix mingw-w64 2>/dev/null)/bin/x86_64-w64-mingw32-gcc"
[ -x "$GCC" ] || GCC="$(command -v x86_64-w64-mingw32-gcc || true)"
[ -x "$GCC" ] || { echo "ERROR: x86_64-w64-mingw32-gcc not found (brew install mingw-w64)" >&2; exit 1; }

mkdir -p "$RT/share/silo"
WRAPPER="$RT/share/silo/steamwebhelper-wrapper.exe"
echo "==> Compiling wrapper into $WRAPPER"
"$GCC" -O2 -municode -mwindows -o "$WRAPPER" "$ROOT/Scripts/steamwebhelper-wrapper.c"

# Verify the compiled wrapper carries the correct CEF flags (same guard as the full build).
python3 - "$WRAPPER" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
ok  = "--in-process-gpu".encode("utf-16-le") in data
bad = "--single-process".encode("utf-16-le") in data
if not ok or bad:
    sys.exit(f"ERROR: wrapper has wrong CEF flags (in-process-gpu={ok}, single-process={bad})")
print("✓ wrapper OK (--in-process-gpu)")
PY
echo "Done. Relaunch the Steam bottle (Silo re-applies the wrapper before launch)."
