# Silo 0.4.2

## Controller support

- **Game controllers now work with Silo Wine.** Silo preserves the pinned SDL 2.30.12 library included in `wine-cx-26.3.0`, allowing WineBus to map supported controllers to XInput.
- **Reinstall Wine once after updating.** Existing Wine installations were created by older Silo versions that removed this library. Remove and reinstall `wine-cx-26.3.0` from the Wine settings after updating to restore it.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
