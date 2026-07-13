# Silo 0.3.7

A graphics-backend release — Automatic is now self-correcting and honest, with better failure detection, plus internal cleanup.

## Highlights
- **Smarter, honest Automatic graphics.** When Automatic learns a game needs DXMT (because GPTK couldn't run it), it no longer overwrites your choice — the setting stays **Automatic** and the learned backend is remembered separately, so it can re-try GPTK on its own after you update the graphics runtime. A game's graphics settings also gain a **Re-probe GPTK** button to force that retry.
- **Better backend detection.** Silo now positively confirms DXMT engaged (rather than only inferring failure), so it won't warn about a fallback when DXMT actually worked; and it reads delay-loaded Direct3D imports, so it picks the right backend for more titles.
- **Cleanup.** Removed a non-functional Dock-tile-naming attempt (Silo-launched processes were never actually renamed), simplifying launches; fixed a settings screen that could misreport the active backend right after a runtime update.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
