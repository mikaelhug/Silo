# Silo 0.4.5

**DXVK now actually works.** 0.4.4 shipped the DXVK backend with a Vulkan driver that couldn't create a graphics device, so DirectX 9 games still failed. This release fixes that and hardens setup and launching throughout.

## DXVK / DirectX 9

- **The DXVK runtime works.** Silo's Vulkan driver is now built from CodeWeavers' published CrossOver sources — the same sources Silo already builds Wine from — because the stock upstream driver is missing a feature DirectX 10/11 needs and could not create a device at all. Verified reaching DirectX feature level 11.0 on Apple Silicon. Reinstall DXVK in **Settings → DXVK**.
- **DXVK no longer writes into your game folders.** Its logs and shader cache move to Silo's own storage, and the shader cache now survives a game reinstall.
- **OpenGL games are recognised.** They can't use any graphics backend (all three translate DirectX), so Silo no longer suggests switching backend for them.

## Launching

- **Silo no longer says "Launched" when the game didn't start.** Three cases: Steam being open but *not signed in* (the game would quietly fail and vanish), Steam never finishing startup, and a pinned executable that a game update had renamed or moved.
- **DirectX 8 games are left alone.** No translation layer supports DirectX 8, so Wine's own renderer is correct — Silo no longer reports a false graphics failure for them.
- **Games can't be affected by another game's backend.** A DirectX 9 game using DXVK leaves files in the shared Steam bottle; every other game and the Steam client are now explicitly insulated from them.

## Setup

- **Fonts install completely.** A single interrupted download could permanently leave the bottle missing most Microsoft core fonts, with later setup runs skipping the step entirely.
- **Setup tells you if something didn't install** instead of reporting success over a bottle missing, say, the Visual C++ runtime — which would later look like every game being broken.
- **An interrupted first-time setup is retried** rather than being remembered as complete.
- **Cancelling the Steam installer** is recognised as a cancellation instead of showing a raw installer error code.
- **Downloads no longer keep running after a failed setup**, and a brief network blip no longer discards a completed runtime download.
- **A disk image that isn't Apple's GPTK** is now rejected with a clear message instead of reporting a successful import.

## Settings

- **Your settings can't be wiped by a downgrade.** A value written by a newer Silo could make the whole configuration file unreadable, silently resetting every runtime path, per-game setting and manual game.
- **Error messages are readable** — rate limits, checksum failures, a full disk, and setup errors all explain themselves now.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
