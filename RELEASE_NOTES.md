# Silo 0.4.7

- **"Steamworks Common Redistributables" no longer appears as a game.** It's a support package Steam installs alongside your games, not something you can play. The old filter looked for an unowned app, but Steam records your own account as the owner, so the check never matched.
- **Only installed games are listed.** A title that's still downloading (or being removed) no longer shows as playable.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
