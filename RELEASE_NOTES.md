# Silo 0.4.3

## New: DXVK / Vulkan graphics backend — DirectX 9 support

- **DirectX 9 games can run now.** GPTK doesn't translate DX9 at all and DXMT is DirectX 10/11-only, so DX9 titles previously fell back to Wine's own renderer and usually black-screened. The new **DXVK** backend (DirectX 9/10/11 → Vulkan → Metal) fills that gap, and also acts as a compatibility fallback for DirectX 10/11 games the two Metal backends can't drive.
- **Install it in Settings → DXVK.** Like Wine and DXMT, the runtime is built from source in Silo's own CI and downloaded on demand. Automatic won't route anything to DXVK until it's installed.
- **⚠️ Brand new, not yet proven on real games.** Direct3D device creation is verified working on Apple Silicon, but no full game has been played through it end to end. Treat DXVK as experimental in this release — GPTK and DXMT are unchanged and remain the default paths.

## Smarter automatic backend selection

- **Silo now inspects a game's DLLs, not just its `.exe`.** Most games keep the renderer in a library (Source in `shaderapidx9.dll`, Unity in `UnityPlayer.dll`, Unreal in its `Binaries` folder) while the `.exe` is a thin launcher — so the graphics API was often mis-detected. DirectX 9 titles are now recognised on the **first** launch instead of after two failed ones.
- **Bundled installers are no longer mistaken for the game.** A `VC_redist.x64.exe` or `UEPrereqSetup_x64.exe` sitting in a game folder could be picked as the executable to launch, which also produced the wrong graphics backend. Redistributables and prerequisites are now skipped.
- **DirectX 8 games are left alone.** No translation layer supports DirectX 8, so Wine's own renderer is the correct choice — Silo no longer reports a false graphics failure or suggests a backend switch for them.
- **32-bit games now honour a learned backend.** A 32-bit game that couldn't run on DXMT kept being sent back to DXMT on every launch, even after Silo had decided DXVK should be used instead.
- **A remembered backend is dropped if you uninstall its runtime**, instead of leaving the game unable to launch at all.
- **DXVK no longer writes into your game folders.** Its logs and shader cache are kept in Silo's own directories; the shader cache now survives a game reinstall.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
