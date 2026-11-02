# Silo 0.5.1

- **The Rockstar Games Launcher starts under GPTK** (GTA V and other Rockstar titles on Steam). D3DMetal has no Direct3D 10, and the launcher draws its UI on a D3D10.1 device, so it failed with "failed to initialize." When DXVK is installed, Silo now runs just the launcher on DXVK while the game itself stays on D3DMetal. The first launch installs the launcher; it works from the next launch on.
- **Your own `WINEDLLOVERRIDES` in `envFlags.extra` now win**, per DLL, over the graphics backend's overrides, as documented.
- **Direct3D 10-only games go to DXMT** under Automatic, since GPTK can't run them.
- **Games no longer get capped at 1440x900 while the Steam client is open.** The client's virtual desktop is now sized to your display.
- **Built with Xcode 27.2.**

Thanks to [@BrandonRobare](https://github.com/mikaelhug/Silo/issues/9) for the detailed trace!

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
