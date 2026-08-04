# Silo 0.4.6

**Fixes a broken 0.4.5: games refused to launch with "sign in to Steam" even when Steam was running and signed in.**

0.4.5 added a pre-launch check that tried to detect whether the bottle's Steam had signed in, by looking for a Steam Guard token file. Real Steam installs don't reliably have that file, so the check refused to launch anything. It has been removed — Silo launches your game, as it did in 0.4.4 and earlier.

Everything else from 0.4.5 (the working DXVK runtime, the setup and launch hardening) is unchanged.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
