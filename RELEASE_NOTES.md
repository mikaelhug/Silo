# Silo 0.4.8

**DirectX 9 games now work.** This release is mostly one long bug hunt against real games.

- **DirectX 9 renders.** DXVK declared a shadow (depth-compare) copy of every texture sampler on the same slot as the normal one, which MoltenVK cannot map onto Metal — so the shaders that draw the scene failed to compile and games ran with working audio over a black screen. Silo now builds DXVK with that removed. Costs hardware shadow compare; everything else renders.
- **Steam's own launch options are used.** Silo reads the executable and arguments Steam itself would use, so a Source game gets its `-game <mod>` automatically. Without it, Double Action: Boogaloo silently ran base Half-Life 2 content and Transmissions: Element 120 refused to start. Arguments you've typed yourself still win and are never duplicated.
- **The game launches, not the tools beside it.** Silo picked the largest `.exe` anywhere in the install, which for Source games meant a 3 MB model viewer in `bin/` instead of the 250 KB launcher at the root. Alien Swarm launched its addon installer.
- **Games that ask for an unavailable screen mode now work.** Alien Swarm had 640×480 saved, which a Retina display doesn't offer, so it quit at startup. Silo re-runs such a game inside a Wine desktop, where any resolution is fine.
- **`d3dcompiler_47` actually installs.** It never had: the install shelled out to `wine expand` with a flag Wine doesn't implement, which exited successfully without extracting anything, leaving Wine's own stub in place. Silo now reads the Microsoft cabinet directly.
- **Core Fonts no longer re-install on every setup.** The check looked for its own marker files rather than the fonts, so a fully set-up bottle reported them missing — and that false alarm hid the `d3dcompiler_47` failure sitting next to it.
- **Backend detection fixes.** A game that ships the Microsoft C++ redistributable no longer looks like a DirectX 11 title (which could route a DirectX 9 game away from the only backend that can run it), and 32-bit DirectX 9 games now go to DXVK rather than a backend with no DirectX 9 support at all.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
