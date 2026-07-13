# Silo 0.3.6

A setup reliability and polish release — first-run setup is faster, more robust, and clearer.

## Highlights
- **Fixed Core Fonts setup.** An accepted font license was misread as a cancel, halting setup right after the first installer. Setup now runs straight through.
- **Faster setup.** Every component's files (fonts, runtimes, MSVC redist) now download in the background the moment you press **Set up**, overlapping the Steam install and bottle creation instead of stalling each step in turn. The stale-installer download cache is gone — downloads are always fresh.
- **Clearer status messages.** Reviewed every user-facing line for one consistent, minimal voice. Setup now says what's actually happening ("Installing Steam — follow its installer…", "Steam is updating itself…") instead of misleading or verbose copy, and the unreliable update percentage is gone.
- **Internal cleanups.** Removed the window-focus workaround that didn't reliably work across macOS versions.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
