# Silo 0.3.5

A stability, correctness, and security hardening release — no new features, just a more production-ready foundation.

## Highlights
- **More reliable launches.** Steam "is it up?" now cross-checks the live wineserver, so a stale process record can't make a game launch against a dead Steam client. A 32-bit manual game on a 64-bit-only DXMT build is now refused with a clear message instead of black-screening.
- **Safer bottle moves.** Relocating bottles re-checks liveness right before the move, so a game launched mid-move can't have its files deleted out from under it.
- **Verified downloads.** The Microsoft core fonts and `d3dcompiler` runtime that Silo downloads and runs during setup are now checked against pinned SHA-256 hashes before they execute — a tampered or corrupt mirror is rejected, not run. (Also fixes Webdings never installing.)
- **Internal cleanups.** Consistency, dead-code, and robustness fixes across the launch, setup, and library-parsing paths, plus doc reconciliation.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
