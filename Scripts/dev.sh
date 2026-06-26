#!/usr/bin/env bash
# Fast UI iteration: run the executable directly (debug). Pass --smoke for a headless check.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run silo "$@"
