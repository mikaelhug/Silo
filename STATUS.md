# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **All requested one-click features (M13–M16) COMPLETE.** M0–M16 done; 101 tests / 23 suites green.
  Remaining work is human-gated E2E (download a wine binary, log into Steam, real game launch).
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
- Confirm the exact third-party Wine/GPTK runtime repo/release to pin as default (currently placeholder `Kegworks-App/Kegworks` in `Silo.defaultRuntimeRepo`; overridable in Settings). Non-blocking for build/test.

## Handoff checklist (for human, post-loop E2E)
- [ ] Download a Wine/GPTK runtime via in-app RuntimeManager (or set the URL in Settings).
- [ ] Create the simple Master Steam bottle; install Steam; log in; download ≥1 game.
- [ ] Point Silo at the Master bottle; confirm discovery lists the game.
- [ ] Isolate → seeds prefix; Play → launches in isolated `WINEPREFIX` with GPTK (CrossOver fallback).
- [ ] (If DRM-gated) pick a Steam Presence Strategy; for `.emulatorStub` provide the stub path.
- [ ] (Distribution) provide Apple Developer ID + notarization secrets for signed releases.
