# Wine sourcing strategy

## Decision (2026-06-26)

Silo's game Wine is the **CrossOver-based Wine, built from open source in our own CI and hosted on
our own GitHub Releases** — not a third-party prebuilt that can go stale.

### Why CrossOver-based (not upstream Wine, not built-from-scratch-and-optimized)
- Apple's **D3DMetal** (the DX11/12→Metal layer we extract from the GPTK `.dmg`) is built and
  validated against **CrossOver-patched Wine's ABI**. Pairing it with plain upstream Wine is weaker.
- CrossOver's Wine carries years of game/CEF patches and `msync` that upstream lacks. Re-implementing
  these ourselves would be slower and unmaintainable. On macOS, performance comes from the
  translation layers (D3DMetal / DXMT / DXVK→MoltenVK) and the x86 translator (Rosetta / rosettax87),
  **not** from our Wine compile.
- CrossOver's Wine is **LGPL open source** (CodeWeavers publishes the sources). Apple's
  `apple/apple/game-porting-toolkit` Homebrew formula compiles exactly this base. So we can build the
  same thing ourselves.

### Why self-hosted (vs. Gcenx / Sikarugir prebuilts)
Those projects are just "someone compiled CrossOver's source for you" — convenient, but a third-party
dependency that can lag or disappear (Gcenx's GPTK repo is stale; Kegworks became Sikarugir). Building
it in our own CI removes that dependency and lets us control the cadence.

## Pipeline
- `.github/workflows/build-wine.yml` (manual `workflow_dispatch`, inputs: CrossOver version + release
  tag) downloads **CrossOver's FOSS source** from CodeWeavers
  (`media.codeweavers.com/pub/crossover/source/crossover-sources-<ver>.tar.gz`; mirror:
  `PhoenicisOrg/winecx`), builds it (`configure --enable-archs=i386,x86_64 … && make`, x86_64 via
  Rosetta — CrossOver is Intel code), packages `wine.tar.xz`, and publishes a `wine-*` Release.
- The app's Wine tab / onboarding pulls Wine from `Silo.wineRepo` (= this repo). `RuntimeManager`
  downloads + extracts the tarball and `locateWineBinary` finds `bin/wine64`.
- **GPTK / D3DMetal is NEVER built or bundled here** — it's Apple-licensed; the user imports it from
  their own GPTK `.dmg` (login-gated) via `GPTKImporter`. This workflow produces **Wine only**.

## Status / caveats
- Building Wine for macOS is intricate and slow (~30+ min) and **the workflow needs CI iteration to
  converge — it is not yet validated end-to-end.** Until the first `wine-*` release is published, the
  Wine tab is empty; users can install **CrossOver** (auto-detected by `BackendResolver`) or override
  `wineRepo`/the wine path under *Advanced Settings* in the meantime.

## Steam client
The Steam client (CEF web helper) crashes/black-screens under GPTK Wine. Silo launches Steam with
`Silo.steamLaunchArgs` (`-allosarches -cef-force-32bit -cef-disable-gpu`) and can use a separate plain
Wine for the Steam bottle (`BackendConfig.steamWineBinaryPath`).

## Deferred performance work (after architecture is settled)
- **DXMT** (Sikarugir) as a selectable D3D11/10 backend alongside D3DMetal.
- **rosettax87** faster x86 translation.
- `msync` on by default for new games.
