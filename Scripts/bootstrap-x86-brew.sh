#!/usr/bin/env bash
# Ensure Rosetta 2 + x86_64 Homebrew (/usr/local), then install the given formulae under `arch -x86_64`.
# Shared by Scripts/build-wine.sh and Scripts/build-dxmt.sh — both builds are x86_64 (CrossOver Wine is
# x86_64; DXMT must match the Wine it loads into), so their deps must come from the x86_64 brew.
#
# Usage: Scripts/bootstrap-x86-brew.sh [formula...]
set -euo pipefail

ARCH="arch -x86_64"
BREW=/usr/local/bin/brew

softwareupdate --install-rosetta --agree-to-license 2>/dev/null || true
# shellcheck disable=SC2016  # the $(...) must run inside the spawned bash, not expand here (brew installer)
[ -x "$BREW" ] || $ARCH /bin/bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
[ $# -eq 0 ] || $ARCH "$BREW" install "$@"
