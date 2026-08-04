# Silo 0.4.9

Fixes a bug in 0.4.8's DirectX 9 support.

- **A game needing Wine's virtual desktop no longer works only every other launch.** 0.4.8 decided this from the previous launch log, but a game running inside the virtual desktop writes nothing to that log — so the next launch saw no problem, ran without it, and failed again. The decision is now remembered.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
