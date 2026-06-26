#!/usr/bin/env bash
# Run the Silo test suite.
#
# Silo uses Swift Testing (`import Testing`). With *Command Line Tools only* (no Xcode), the
# Testing framework and its interop dylib ship with the toolchain but are NOT on SwiftPM's default
# search paths, so we add them. With full Xcode (e.g. GitHub CI runners) Swift Testing resolves
# natively and these dirs simply don't exist, so we add the flags only when present.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

FLAGS=()
if [ -d "$FW" ]; then
  FLAGS+=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW")
fi
if [ -d "$LIB" ]; then
  FLAGS+=(-Xlinker -rpath -Xlinker "$LIB")
fi

exec swift test "${FLAGS[@]}" "$@"
