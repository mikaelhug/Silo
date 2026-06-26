# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **Milestone:** M11 — Build scripts + .app bundle (next)

## Build/test snapshot
- `swift build`: ✅ clean (M10, no warnings)
- `swift test`:  ✅ 88 tests / 19 suites passing (run via `Scripts/test.sh`)
- `swift run silo --smoke`: ✅ links SwiftUI + runs headlessly
- Last green commit: M10 SwiftUI UI

## Task board

### DOING
- _(none)_

### TODO (in order; each ends in a green commit)
- M11 — Build scripts + .app bundle · accept: `Scripts/run.sh` launches `dist/Silo.app`
- M12 — CI + release workflows + README · accept: `ci.yml` defined; README handoff checklist

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
