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

### Test locally with real Wine — no push / no GitHub needed

Pushing only powers the *CI* Wine build + weekly auto-update. To exercise the whole app (incl. real
`wineboot`, the Steam bottle, and GPTK) locally:

```sh
./Scripts/run.sh                              # build + launch the app

# Provide Wine without a GitHub release — any one of:
#  a) you have CrossOver/Whisky/Kegworks → Library toolbar gear (Advanced) → Auto-detect
#  b) build ours, then side-load it:
./Scripts/build-wine.sh 26.2.0                # ~30–60 min, produces .wine-build/install
./Scripts/install-local-wine.sh .wine-build/install wine-cx-26.2.0
#  c) point Advanced → "Wine binary" at any existing wine64
```

Then in the app: **Wine Manager → Wine tab → Set default**, **GPTK tab → import your .dmg**, and the
Library onboarding's **Install Steam** runs `wineboot` + the Steam installer locally.

CI (`.github/workflows/ci.yml`) runs build + test + bundle on every push/PR; tagging `v*` publishes
an ad-hoc-signed `Silo.zip` via `.github/workflows/release.yml`.

## First-run setup (the human-gated part)

Silo builds and tests fully on a clean machine, but launching a real game needs a runtime + a
downloaded game. On first run the **Library** shows a guided 3-step setup:

1. **Install Wine** — one click; downloads a prebuilt Wine build (~250 MB).
2. **Import Game Porting Toolkit** — choose Apple's GPTK `.dmg`; Silo mounts it and extracts the
   D3DMetal layer. (GPTK is only the graphics layer — it needs the Wine binary from step 1.)
3. **Install Steam** — creates the Master Steam bottle and installs Steam. Then **Open Steam** (the
   Steam card in the Library), log in, and download games — or use **Install entire library**.

After setup, the Library shows a **Steam card** plus your games. **Play** launches a game in GPTK
(CrossOver fallback) in an isolated `WINEPREFIX`; per-game **Settings** cover backend, env flags,
executable, and Steam-presence strategy; **View Log** shows output. Manage Wine/GPTK versions in the
**Wine Manager** (Wine + GPTK tabs); manual wine/DXVK paths live behind the Library toolbar gear
(**Advanced Settings**).

> Gatekeeper: the app is ad-hoc signed, so a downloaded build is quarantined until you right-click →
> Open (or run `xattr -dr com.apple.quarantine Silo.app`). Signed distribution requires an Apple
> Developer ID + notarization.

## Sandboxing

Silo is **not** App-Sandboxed (see `Resources/silo.entitlements`): it executes `wine` outside its
bundle and reads/writes `~/Library/Application Support` and the Steam bottle, which the sandbox
forbids. User-chosen paths go through the system file picker (powerbox) to avoid TCC denials.

## Wine sourcing

Silo's game Wine is a **CrossOver-based build compiled from open (LGPL) source in Silo's own CI and
hosted on Silo's Releases** — no third-party prebuilt dependency. Apple's **D3DMetal** is imported
separately from the user's GPTK `.dmg` (login-gated, so it can't be auto-downloaded). See
[WINE-BUILD.md](WINE-BUILD.md). CrossOver, if installed, is auto-detected and preferred.

## License / legal

Silo does not bundle a Steam-API emulator. The optional emulator stub is **user-provided** and
intended only for games you own; you are responsible for compliance with Steam's Subscriber
Agreement and applicable law.
