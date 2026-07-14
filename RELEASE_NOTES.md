# Silo 0.4.0

Desktop shortcuts are back, and manual games now get the same Automatic graphics backend as Steam.

## Highlights
- **Desktop shortcuts.** Right-click any game — Steam or non-Steam — → **Create Desktop Shortcut** for a double-clickable launcher that plays it through Silo from the Desktop, Spotlight, or Launchpad, always resolving the current backend and bottle.
- **Automatic graphics for non-Steam games.** Manual games now default to the same **Automatic** GPTK/DXMT selection as Steam games, instead of a fixed backend — 32-bit titles route to DXMT automatically. Still overridable per game.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
