# Silo

A native macOS (SwiftUI) launcher overlay for Windows Steam games on Apple Silicon, built on Wine +
Apple's Game Porting Toolkit (GPTK / D3DMetal).

**Single Downloader, Multi-Runtime.** Install Steam once into a single *simple* Master Wine bottle
to download games; Silo reads that bottle's metadata and launches each game in its **own isolated
Wine prefix** — separate `WINEPREFIX`, graphics backend, and environment — with one click.

- Native SwiftUI, async/await, no main-thread blocking.
- **Self-contained:** no Homebrew dependency. Downloads its own Wine/GPTK runtime from a
  configurable GitHub release (Heroic-style) and self-updates from GitHub Releases.
- **Per-game isolation:** GPTK / D3DMetal primary, CrossOver wine fallback; per-game env flags
  (ESYNC / MSYNC / Metal HUD) and Steam-presence strategy.

> Architecture lives in [CLAUDE.md](CLAUDE.md); current progress in [STATUS.md](STATUS.md).

## How it works (the pipeline)

1. **Discovery** — parse the Master bottle's `appmanifest_*.acf` (+ `libraryfolders.vdf`) into typed
   games.
2. **Provision** — on Play/Isolate, seed a minimal Wine prefix at
   `~/Library/Application Support/Silo/Prefixes/<appID>/` (`wineboot --init`), idempotent.
3. **Graphics linker** — inject GPTK/D3DMetal (or DXVK for CrossOver) into the prefix's `system32`.
4. **Launch** — spawn a detached process running the game's exe with `WINEPREFIX` overridden to the
   isolated prefix, streaming output to a per-game log.

### Steam DRM / presence

The Master bottle can't project Steam presence into an isolated prefix (Steam IPC is prefix-scoped),
so each game picks a **Steam Presence Strategy**: `none` → `steam_appid.txt` (default) →
`sharedSteamClient` (symlink the master Steam into the prefix) → `emulatorStub` (copy a
**user-provided** Steam-API stub next to the exe, original backed up). Silo never bundles or
downloads any emulator.

## Build (developers)

Requires the Swift 6 toolchain — **Command Line Tools are sufficient, no Xcode needed**.

```sh
swift build              # compile
./Scripts/test.sh       # run the test suite (passes with no Wine/GPTK installed)
./Scripts/build-app.sh  # assemble + ad-hoc sign dist/Silo.app
./Scripts/run.sh        # build the app and open it
./Scripts/dev.sh        # fast iteration: swift run silo
```

`Scripts/test.sh` wraps `swift test` with the Swift Testing framework search path that Command Line
Tools needs (plain `swift test` fails with "no such module 'Testing'" without Xcode).

CI (`.github/workflows/ci.yml`) runs build + test + bundle on every push/PR; tagging `v*` publishes
an ad-hoc-signed `Silo.zip` via `.github/workflows/release.yml`.

## First-run setup (the human-gated part)

Silo builds and tests fully on a clean machine, but launching a real game needs a runtime + a
downloaded game:

1. **Wine Manager** — two tabs:
   - *Wine* — install a prebuilt Wine build in one click (lists the latest releases).
   - *GPTK* — "Import GPTK from Apple .dmg…": Silo mounts the DMG and extracts the D3DMetal layer.
   Set a default in each tab. (GPTK is only the graphics layer — it needs a Wine binary underneath,
   which the Wine tab provides.)
2. **Master Steam bottle** — in *Setup*, click "Create Master Steam Bottle (1-click)" (or point at an
   existing bottle). Then open Steam, log in, and download games — or use **Install entire library**.
3. **Play** — Silo discovers the game; **Isolate** seeds its prefix, **Play** launches it in GPTK
   (CrossOver fallback) in an isolated `WINEPREFIX`. Use *Settings* per game for backend, env flags,
   executable, and Steam-presence strategy; *View Log* to see output. (Manual wine/DXVK paths live
   under *Setup → Advanced*.)

> Gatekeeper: the app is ad-hoc signed, so a downloaded build is quarantined until you right-click →
> Open (or run `xattr -dr com.apple.quarantine Silo.app`). Signed distribution requires an Apple
> Developer ID + notarization.

## Sandboxing

Silo is **not** App-Sandboxed (see `Resources/silo.entitlements`): it executes `wine` outside its
bundle and reads/writes `~/Library/Application Support` and the Steam bottle, which the sandbox
forbids. User-chosen paths go through the system file picker (powerbox) to avoid TCC denials.

## License / legal

Silo does not bundle or download Wine, GPTK, or any Steam-API emulator. Runtimes are fetched from a
user-visible, configurable third-party release. The optional emulator stub is **user-provided** and
intended only for games you own; you are responsible for compliance with Steam's Subscriber
Agreement and applicable law.
