# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **M0–M31 COMPLETE.** 125 tests / 25 suites green; CI green.
- M31 (bug: can't right-click library cards): GameCardView had only the ellipsis `Menu`, no
  `.contextMenu`. Added a right-click menu (Play/Stop, Isolate, Settings…, View Log…, Reveal Prefix,
  Wine Config…, View on Steam Store, Reset Prefix) via a shared `managementMenu()` builder reused by
  the ellipsis menu, which is now always visible (even while running). Per-game settings pane gained
  **Launch options** (`GameConfig.launchOptionsString` ↔ `customArgs`, Steam-style) and a DXVK HUD
  field (CrossOver backend only). `SteamApp.storePageURL` added. +3 tests.
- M30 (bug: Install Steam hung + crash storm): the silent `SteamSetup.exe /S` auto-launches Steam.exe,
  which crash-loops under wine (Steam CEF) and spawns *hundreds* of `winedbg --auto` processes, so the
  installer NEVER returns → app stuck "Installing…", `masterBottlePath` never set. Fix: `SteamBottleInstaller`
  now SPAWNS the installer detached, polls for `Steam.exe` to appear (≤180s), then `wineserver -k`s the
  bottle so the crash-loop can't accumulate; full client downloads on first real run via "Open Steam"
  (which passes CEF-safe flags). Verified on the user's machine: bottle + Steam.exe present; storm killed.
- M29 (D3DMetal path wiring): GPTK game launches now (a) put GPTK's `lib/external` on
  `DYLD_FALLBACK_LIBRARY_PATH` + `DYLD_FALLBACK_FRAMEWORK_PATH` so `d3d11.so` resolves
  `@rpath/libd3dshared.dylib` and `D3DMetal.framework`; (b) add GPTK's `lib/wine` to `WINEDLLPATH`
  and force d3d/dxgi `=b` (builtin) so wine loads GPTK's d3d instead of the base wine's. New
  `BackendConfig.gptkExternalDirPath` / `gptkWineDLLDirPath` derive these from `gptkLibDirPath`.
  STATICALLY VERIFIED on the real GPTK-4.0_beta_1: D3DMetal.framework loads under x86_64; converter
  libs (libmetalirconverter/libdxccontainer) resolve via the framework's own rpath; wine honors
  DYLD_FALLBACK (proven by the freetype fix). **E2E activation is human-gated** (see BLOCKED).
- M28 (self-contained wine): `Scripts/bundle-wine-dylibs.sh` copies the transitive closure of wine's
  non-system dylib deps (arch-filtered to the wine's arch — x86_64) into `<wine>/lib/silo-bundled`;
  the app launches wine with `DYLD_FALLBACK_LIBRARY_PATH=<…>/lib/silo-bundled` (URL.siloDyldFallback)
  so freetype/gstreamer/etc. resolve without Homebrew. Wired into build-wine (CI + local) + install-
  local-wine. **VERIFIED**: wineboot with the app's exact env → 0 FreeType warnings, prefix boots.
- M27 (bug: "Install Steam does nothing"): first-run `wineboot` was hanging on blocking wine-mono/
  wine-gecko install dialogs. Now `wineboot` (SteamBottleInstaller + PrefixProvisioner) sets
  `WINEDLLOVERRIDES=mscoree,mshtml=` (`Silo.winePrefixInitOverrides`) so it completes headlessly.
  Verified: the user's wine-cx-26.2.0 boots a home-dir prefix cleanly with the override.
- **KNOWN (build follow-up):** the locally-built wine logs "cannot find the FreeType font library" —
  the self-built wine depends on Homebrew dylibs (freetype/gstreamer/…) not bundled/relocated, so it's
  not fully self-contained. Prefix creation still works; fonts won't render until deps are bundled.
- CI FIX: `Scripts/test.sh` crashed on the runner (bash 3.2 + `set -u` + empty `FLAGS` array →
  "unbound variable"); now guards the empty-array expansion. (This was failing every CI run.)
- M26 = game artwork: `SteamApp.headerArtURL` (Steam CDN header.jpg); GameCardView shows the cover
  via AsyncImage with a gradient placeholder fallback.
- M25 (Wine Manager fixes from user report): `locateWineBinary` now excludes directories, so GPTK
  installs (`lib/wine` dir) no longer masquerade as Wine in the Wine tab; Wine tab simplified to a
  single "Install latest Wine" (dropped the broken multi-version refresh — CI publishes the canonical
  latest); removed a stray `Runtimes/GPTK` left by the M15 verification import.
- M24 = downloaded-Wine SHA-256 verification (build-wine publishes `.sha256`; RuntimeManager verifies).
- M23 = audit robustness + UX: downloaded Wine is
  de-quarantined + ad-hoc re-signed (Gatekeeper), extraction cleans up on failure; GPTK de-quarantined
  (no re-sign — keeps Apple's signature); live log tail; library recently-played sort + installed/updates
  filter; prefix management (reveal / Wine config / reset); CI concurrency + ccache + timeouts + read perms.
  **Perf levers (msync default, DXMT, rosettax87, DXVK install) still deferred — say "do perf" to start.**

- M22 = launch feedback + UX wins: Running/exited
  state + Stop button (`ProcessRunning.isRunning`, `LaunchOrchestrator.stop` via `wineserver -k`,
  `LibraryViewModel` PID monitor); `lastPlayed` stamped; `Updater` wired (bootstrap check → About
  "Update available"); exe **picker** in GameSettingsSheet (`ExecutableResolver.allExecutables`);
  library auto-refresh on app re-activation (scenePhase).

## Review backlog (remaining)
- PERF (deferred per user — say "do perf"): msync default-on (esync/msync mutually-exclusive enum);
  DXMT backend; rosettax87 fast x86; DXVK install path (the `.crossover` backend is unreachable on a clean install).
- HUMAN-GATED: notarization in release.yml (needs your Apple Developer ID + secrets).
- D3DMETAL PATH: DONE (M29). Runtime env wired + statically verified. Real activation needs a game launch (BLOCKED).
- NICE-TO-HAVE: pin GitHub Actions by commit SHA (clears Node-20 deprecation notice).
- All other audit findings (correctness, robustness, UX) are DONE (M21–M24). Wine sourcing architecture settled (see
  WINE-BUILD.md): self-hosted CrossOver-based Wine built in our own CI (`build-wine.yml`,
  workflow_dispatch) → published to our Releases → app pulls from `Silo.wineRepo` (= mikaelhug/Silo);
  no third-party prebuilt dependency. D3DMetal still imported from Apple's `.dmg`. Steam launches with
  CEF crash-workaround flags. **Perf work (DXMT/rosettax87/msync) deferred per user.**

## Wine strategy decision (2026-06-26) — see WINE-BUILD.md
- CrossOver's Wine is LGPL open source (what Apple's GPTK formula compiles). We build it ourselves in
  CI and host it, rather than depend on Gcenx/Sikarugir prebuilts (which can go stale). Don't build
  upstream Wine from scratch — perf comes from translation layers (D3DMetal/DXMT/DXVK) + x86 translator.
- **CI-gated:** `build-wine.yml` is a best-effort recipe NOT yet validated end-to-end; until the first
  `wine-*` release exists, the Wine tab is empty — use CrossOver (auto-detected) or override the path.
- **Pivot (user, 2026-06-26):** GPTK acquisition is "Browse to Apple `.dmg`" → Silo mounts + extracts
  `redist/lib`. VERIFIED against the real `Game_Porting_Toolkit_4.0_beta_1.dmg` (gitignored) via
  `silo --import-gptk <dmg>`: extracts D3DMetal.framework + 6 DLLs to Runtimes/GPTK (68M), clean detach.

## Research findings (2026-06-26, grounds M13–M16)
- `apple/game-porting-toolkit` is a **resources repo, no binary releases**; official GPTK = a DMG
  behind Apple-ID login (not automatable). **`Gcenx/game-porting-toolkit/releases`** has prebuilt
  GPTK binaries (no login) → use as the 1-click default; link Apple's repo for the manual route.
- Steam Windows installer: `https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe`
  (akamai mirror: `https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe`), silent flag `/S`.
- No single "install whole library" command. Mechanism = `steam://install/<appid>` per owned app via
  the running Steam client; owned appids parsed from `userdata/*/config/localconfig.vdf`.
- "wine-mirror/wine" is source-only (no mac binaries) → it means "use a vanilla Wine runtime" as the
  Steam-bottle fallback when GPTK can't run the Steam client.

## Build/test snapshot
- `swift build`: ✅ clean (no warnings)
- `swift test`:  ✅ 88 tests / 19 suites passing (run via `Scripts/test.sh`)
- `Scripts/build-app.sh`: ✅ produces ad-hoc-signed `dist/Silo.app` (com.mikael.silo, min OS 26.0); bundled binary smoke-runs
- CI/Release: ✅ `.github/workflows/{ci,release}.yml` valid YAML
- Last green commit: M12 CI + release + README

## Task board

### DOING
- _(none)_

### TODO (in order; each ends in a green commit)
- _(none — all milestones complete)_

### DONE
- M0 — Scaffold SPM project + harness docs (Package.swift, silo/SiloKit/SiloKitTests, CLAUDE.md, STATUS.md, README, .gitignore, Scripts/test.sh).
- M1 — KeyValues tokenizer + parser + KVNode (`Discovery/{ACFTokenizer,KeyValuesParser,KVNode}.swift`; 14 parser/tokenizer tests).
- M2 — Models (`SteamApp`, `StateFlags`, `LibraryFolder`) + decoders (`AppManifestDecoder`, `LibraryFoldersDecoder`) + fixtures + `FixtureLoader`; 10 decoder tests.
- M3 — `DiscoveryEngine` (actor): scans primary + extra libraries, skips bad manifests; `TempDir` helper; 5 tests.
- M4 — Config models (`GraphicsBackend`, `SteamPresenceStrategy`, `EnvFlags`, `WineRuntime`, `BackendConfig`, `GameConfig`) + `AppPaths` + `AppState` + `ConfigStore` actor (JSON); 8 tests.
- M5 — `ProcessRunning` protocol + `ProcessResult` + `SystemProcessRunner` (temp-file redirect, env merge, detached spawn) + `FakeProcessRunner` (lock-guarded); 8 tests incl real subprocesses.
- M6 — `PrefixLayout`, `PrefixProvisioner` actor (idempotent wineboot --init), `GraphicsLinker` (symlink/copy GPTK or DXVK into system32); 9 tests. Note: Sendable structs use computed `FileManager.default` (can't store non-Sendable); actors may store it.
- M7 — `LaunchPlan`, pure `LaunchOrchestrator.makePlan` (static; isolated WINEPREFIX, backend env, DXVK overrides), `launch` pipeline (provision→link→log→spawn), `ExecutableResolver`, `GameLogStore`; GameConfig gained `executableRelativePath`; 12 tests.
- M8 — `BackendResolver` (Whisky/Kegworks/CrossOver detection, .none on clean machine) + `SteamPresenceInstaller` (none/appIDFile/sharedClient/emulatorStub with backup+revert), wired into launch pipeline; 10 tests.
- M9 — `GitHubRelease` model, `Updater` (GH Releases version check, numeric compare), `RuntimeManager` actor (list/fetch/download+tar-extract/remove); `FakeURLProtocol` test support; 9 tests. Note: Swift Testing runs in parallel — network tests use unique stub URLs (no shared-state reset).
- M10 — `AppEnvironment` composition root + `SiloApp` (SwiftUI App); view models (`LibraryViewModel`, `BackendSettingsViewModel`, `GameSettingsViewModel`, `RuntimeViewModel`); views (Root/Sidebar/LibraryGrid/GameCard/Badge/BackendSettings/RuntimeManager/GameSettingsSheet/LogViewer/About/PathPickerRow); `silo --smoke` headless path; 7 VM tests.
- M11 — `Resources/{Info.plist.template,silo.entitlements (no sandbox)}` + `Scripts/{build-app,sign,run,dev,clean}.sh`; assembles + ad-hoc signs `dist/Silo.app`, strips quarantine. Verified bundle valid + bundled binary smoke-runs.
- M12 — `.github/workflows/{ci,release}.yml` (build+test+bundle on push/PR; tag → ad-hoc-signed Silo.zip release) + README (build, first-run setup, sandbox, legal).
- M13 — App icon: CoreGraphics generator (`Scripts/make-icon.swift`) + `make-icon.sh` (sips/iconutil) -> `Resources/AppIcon.icns`; wired via `CFBundleIconFile`; bundled by build-app.sh.
- M14 — `SteamBottleInstaller` (boot bottle → download SteamSetup.exe → silent `/S` install) + `BackendConfig.steamWine` (vanilla fallback) + AppPaths.masterBottleDefault; "Create Master Steam Bottle (1-click)" button + VM; 4 tests.
- M15 — `GPTKImporter` (browse Apple .dmg → `hdiutil attach` outer+nested via plist → copy `redist/lib` → Runtimes/GPTK, set `gptkLibDirPath`); RuntimeVM.importGPTK + "Import GPTK from .dmg…" UI + Apple link; `silo --import-gptk` CLI; **verified on real GPTK 4.0 DMG**; 4 tests. Decision log: GPTK has no wine binary (overlay only); base wine still from CrossOver/download.
- M16 — `OwnedAppsReader` (parse userdata/*/config/localconfig.vdf owned appids) + `SteamLibraryInstaller` (queue `steam://install/<appid>` per owned app via wine); LibraryVM.installEntireLibrary + "Install entire library" toolbar button; localconfig.vdf fixture; 6 tests.
- M17 — GPTK Manager: versioned installs (`Runtimes/GPTK-<version>` from DMG name) via `GPTKImporter.runtimeName/installed/remove`; `GPTKInstall` model; `BackendConfig.gptkRuntimeName`; `GPTKManagerViewModel` (import/remove/set-default, auto-default on first import) + `GPTKManagerView` + sidebar "GPTK Manager". Moved GPTK import out of Wine Runtimes view. 5 new tests.
- M18 — Wine Manager (`WineManagerView` segmented GPTK|Wine tabs): GPTK tab = `GPTKManagerView`; Wine tab = `WineDownloadView` driven by rewritten `RuntimeViewModel` (latest 3 Gcenx releases, 1-click install, set-default, remove). `WineInstall` model; `RuntimeManager.availableReleases/preferredAsset/installWine/installedWines/locateWineBinary`; `BackendConfig.wineRuntimeName`; `Silo.wineRepo` (Gcenx, .tar.xz ~250MB). Backend view → "Setup" with Advanced disclosure for manual paths; deleted RuntimeManagerView; sidebar Library/Setup/Wine Manager/About. 3 new tests (109 total).
- M23 — Audit robustness+UX: RuntimeManager `harden` (xattr de-quarantine + ad-hoc codesign) + extraction cleanup; GPTKImporter de-quarantine; LogViewer live tail+autoscroll; LibraryViewModel SortOrder/Filter + lastPlayed map; PrefixProvisioner.remove + LaunchOrchestrator.runWineTool (winecfg) + GameCard prefix menu; CI concurrency/ccache/timeouts/read-perms; 3 tests (117 total).
- M22 — Launch feedback + UX: `ProcessRunning.isRunning(pid:)` (kill(pid,0)); `LaunchOrchestrator.stop` (wineserver -k); `LibraryViewModel` runningPIDs + monitor + Stop + `lastPlayed`; Updater wired into AppEnvironment/About; exe picker (`ExecutableResolver.allExecutables`); scenePhase auto-refresh; 3 new tests (116 total).
- M21 — Post-review correctness hardening (see git log).
- M20 — Wine sourcing architecture: `Silo.wineRepo` → self-hosted `mikaelhug/Silo` (removed stale Gcenx `defaultRuntimeRepo`/`gptkRepo`); `WINE-BUILD.md` decision doc; `.github/workflows/build-wine.yml` (CI builds CrossOver-base Wine from open source → our Releases; workflow_dispatch, needs CI iteration). Steam launches with `Silo.steamLaunchArgs` CEF flags (`openSteam`). 1 new test (112 total). Perf (DXMT/rosettax87/msync) deferred.
- M19 — Library-as-home: removed Setup sidebar pane. `OnboardingView` (3 StepRows: Install Wine/Import GPTK/Install Steam) shown when `AppEnvironment.setupComplete` is false; `SteamCardView` (Open Steam via `AppEnvironment.openSteam`) pinned first in the grid when complete. `RuntimeViewModel.installLatest`; setup-readiness computed on AppEnvironment; Advanced settings via Library toolbar gear → `AdvancedSettingsSheet`(BackendSettingsView). Sidebar Library/Wine Manager/About. 2 new tests (111 total).

## Decision log
- 2026-06-26 — Use Swift Testing (`import Testing`) not XCTest: bundled in toolchain, keeps zero deps. XCTest is NOT available under Command Line Tools (no Xcode), Testing is.
- 2026-06-26 — Testing under CLT needs framework search paths: `Testing.framework` lives in `$(xcode-select -p)/Library/Developer/Frameworks` and `lib_TestingInterop.dylib` in `.../Library/Developer/usr/lib`. `Scripts/test.sh` adds both via `-F` + `-rpath`. Plain `swift test` fails with "no such module 'Testing'".
- 2026-06-26 — Package `platforms: .macOS(.v15)`; real min OS enforced via Info.plist `LSMinimumSystemVersion=26.0`.
- 2026-06-26 — Custom `URLSession` GitHub-Releases updater instead of Sparkle to keep `Package.swift` dependency-free.

## Known follow-ups (non-blocking)
- DiscoveryEngine skips Windows-style (`C:\...`) library paths in `libraryfolders.vdf`; only host-absolute (`/...`) extra libraries are scanned. In the single-downloader model games land in the primary C: library (always scanned), so this is sufficient for v1. Add Wine `dosdevices` drive-letter translation if cross-drive libraries are needed.
- `.sharedSteamClient` presence symlinks the master Steam into the prefix but does not yet launch a background `steam.exe` inside the prefix; full live-client wiring is a launch-time follow-up (most DRM cases use `.emulatorStub`).

## BLOCKED
- _(none — building continues; the items below are human-input for real E2E, not for the build)_
- **GPTK E2E activation (M29):** the D3DMetal env wiring is in place + statically verified, but whether
  CrossOver wine-cx-26.2.0 actually loads GPTK-4.0_beta_1's d3d modules via `WINEDLLPATH` (vs needing an
  overlay copy into the wine's own `lib/wine`), and whether that GPTK↔CrossOver version pair is ABI-
  compatible, can ONLY be confirmed by launching a real D3D game and reading its log. If wine ignores
  WINEDLLPATH for the new PE builtin format, the fallback is to overlay GPTK's `lib/wine/*` into the
  wine runtime's `lib/wine/*` (Whisky's method) — a small, well-scoped follow-up once a launch log exists.
- Confirm the exact third-party Wine/GPTK runtime repo/release to pin as default (currently placeholder `Kegworks-App/Kegworks` in `Silo.defaultRuntimeRepo`; overridable in Settings). Non-blocking for build/test.

## Handoff checklist (for human, post-loop E2E)
- [ ] Download a Wine/GPTK runtime via in-app RuntimeManager (or set the URL in Settings).
- [ ] Create the simple Master Steam bottle; install Steam; log in; download ≥1 game.
- [ ] Point Silo at the Master bottle; confirm discovery lists the game.
- [ ] Isolate → seeds prefix; Play → launches in isolated `WINEPREFIX` with GPTK (CrossOver fallback).
- [ ] (If DRM-gated) pick a Steam Presence Strategy; for `.emulatorStub` provide the stub path.
- [ ] (Distribution) provide Apple Developer ID + notarization secrets for signed releases.
