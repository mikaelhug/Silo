#!/usr/bin/env bash
# Build the app bundle and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-app.sh
open dist/Silo.app
