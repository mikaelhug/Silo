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

# swift test's own exit code is unreliable here: under the Command Line Tools framework-search-path
# invocation, Swift Testing failures are printed but the process can still exit 0 (verified on Swift
# 6.3.3, full suite). release.yml gates publishing a release on this script, so a false pass would ship
# a broken build. Run it through a capture (live output preserved via tee) and treat ANY reported
# failure line as a failure, whatever the process exit code — correct on both CLT and full Xcode.
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# Expand FLAGS only when non-empty: under `set -u` on bash 3.2 (the macOS/CI default shell),
# "${FLAGS[@]}" on an empty array errors as "unbound variable". With full Xcode FLAGS is empty and
# plain `swift test` resolves Swift Testing natively. `set +e` so the failure check runs instead of
# `set -e` aborting on a non-zero pipeline first.
set +e
if [ "${#FLAGS[@]}" -gt 0 ]; then
  swift test "${FLAGS[@]}" "$@" 2>&1 | tee "$out"
else
  swift test "$@" 2>&1 | tee "$out"
fi
status=${PIPESTATUS[0]}
set -e

# `✘` prefixes every Swift Testing failure line (test + suite); a clean run prints none.
if [ "$status" -ne 0 ] || grep -q '✘' "$out"; then
  echo "Scripts/test.sh: test failures detected (swift test exit $status)." >&2
  exit 1
fi
