# Silo 0.4.1

Add non-Steam games straight from their installer — Silo finds the installed games for you.

## Highlights
- **Install-and-detect for non-Steam games.** After you run a game's installer, Silo reads the shortcuts it created and lists the installed games automatically the moment the installer closes — each with the right executable, launch arguments, and working directory, so you no longer hunt for the correct `.exe`. One installer that adds several games puts them all in a single bottle.
- **`.msi` installers supported.** Windows Installer packages now run directly when adding a game.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
