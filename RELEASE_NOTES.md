# Silo 0.3.4

The big one: **automatic graphics, one Steam bottle.** Steam games no longer pick a graphics backend up front — Silo chooses GPTK or DXMT per game and switches automatically, all co-resident with a single logged-in Steam client. Plus a rebuilt, guided onboarding.

## Highlights
- **Automatic graphics backend (GPTK ⇄ DXMT).** Silo picks the Metal backend per game — Apple's GPTK/D3DMetal by default, DXMT for 32-bit titles and as the fallback when GPTK can't drive a game (it remembers the switch for next time). Override to a specific backend per game anytime; GPTK and DXMT games co-reside.
- **One shared Steam bottle.** The old two-bottle model (one per backend) is gone — every Steam game runs co-resident with a single logged-in Windows Steam client, so Steamworks and DRM keep working.
- **Correct Dock tiles.** Launched games and the Steam client show their real name in the Dock, not "wine".
- **CrossOver-like lifecycle.** Quitting Silo leaves Steam and your games running — no per-game Stop button, no kill-on-quit.

## Onboarding & setup
- **Two-step guided setup:** import Apple's GPTK `.dmg`, then one **Set up** that downloads Wine + the DXMT runtime and installs Windows Steam into the shared bottle (fonts, VC++ runtimes and all), then sign in once.
- License/installer windows now **come to the front** so you don't miss them, and **cancelling** a font or MSVC-redist installer now stops setup (and re-prompts next time) instead of silently continuing.
- The setup progress bar animates properly and shows the current phase (including "Accept the license for …"). A real Wine-download failure now surfaces its actual error instead of a generic message, and a missing DXMT is flagged on the completion screen.

## Fixes & polish
- Fixed the MSVC redistributable + `d3dcompiler_47` being skipped because of a Wine fakedll marker.
- Professionalized user-facing status messages; Steam now launches silently (no stray spinner/label).
- Removed the "Create Desktop Shortcut" feature; fixed a misplaced "Opened winecfg" toast.
- Now licensed under **LGPL-2.1-or-later**.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
