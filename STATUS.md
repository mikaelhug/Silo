# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **Milestone:** M5 — ProcessRunning seam (next)

## Build/test snapshot
- `swift build`: ✅ clean (M4)
- `swift test`:  ✅ 37 tests / 7 suites passing (run via `Scripts/test.sh`)
- Last green commit: M4 config + persistence

## Task board

### DOING
- _(none)_

### TODO (in order; each ends in a green commit)
- M5 — ProcessRunning seam · accept: `ProcessRunningTests` (FakeProcessRunner)
- M6 — PrefixProvisioner + GraphicsLinker · accept: `PrefixProvisionerTests`, `GraphicsLinkerTests`
- M7 — LaunchOrchestrator (makePlan pure + launch pipeline) · accept: `LaunchOrchestratorTests`
- M8 — BackendResolver + SteamPresenceInstaller · accept: `BackendResolverTests`, `SteamPresenceInstallerTests`
- M9 — RuntimeManager + Updater · accept: `RuntimeManagerTests`, `UpdaterTests` (FakeURLProtocol)
- M10 — ViewModels + SwiftUI views · accept: `swift run silo` shows window; VM unit tests
- M11 — Build scripts + .app bundle · accept: `Scripts/run.sh` launches `dist/Silo.app`
- M12 — CI + release workflows + README · accept: `ci.yml` defined; README handoff checklist

### DONE
- M0 — Scaffold SPM project + harness docs (Package.swift, silo/SiloKit/SiloKitTests, CLAUDE.md, STATUS.md, README, .gitignore, Scripts/test.sh).
- M1 — KeyValues tokenizer + parser + KVNode (`Discovery/{ACFTokenizer,KeyValuesParser,KVNode}.swift`; 14 parser/tokenizer tests).
- M2 — Models (`SteamApp`, `StateFlags`, `LibraryFolder`) + decoders (`AppManifestDecoder`, `LibraryFoldersDecoder`) + fixtures + `FixtureLoader`; 10 decoder tests.
- M3 — `DiscoveryEngine` (actor): scans primary + extra libraries, skips bad manifests; `TempDir` helper; 5 tests.
- M4 — Config models (`GraphicsBackend`, `SteamPresenceStrategy`, `EnvFlags`, `WineRuntime`, `BackendConfig`, `GameConfig`) + `AppPaths` + `AppState` + `ConfigStore` actor (JSON); 8 tests.

## Decision log
- 2026-06-26 — Use Swift Testing (`import Testing`) not XCTest: bundled in toolchain, keeps zero deps. XCTest is NOT available under Command Line Tools (no Xcode), Testing is.
- 2026-06-26 — Testing under CLT needs framework search paths: `Testing.framework` lives in `$(xcode-select -p)/Library/Developer/Frameworks` and `lib_TestingInterop.dylib` in `.../Library/Developer/usr/lib`. `Scripts/test.sh` adds both via `-F` + `-rpath`. Plain `swift test` fails with "no such module 'Testing'".
- 2026-06-26 — Package `platforms: .macOS(.v15)`; real min OS enforced via Info.plist `LSMinimumSystemVersion=26.0`.
- 2026-06-26 — Custom `URLSession` GitHub-Releases updater instead of Sparkle to keep `Package.swift` dependency-free.

## Known follow-ups (non-blocking)
- DiscoveryEngine skips Windows-style (`C:\...`) library paths in `libraryfolders.vdf`; only host-absolute (`/...`) extra libraries are scanned. In the single-downloader model games land in the primary C: library (always scanned), so this is sufficient for v1. Add Wine `dosdevices` drive-letter translation if cross-drive libraries are needed.

## BLOCKED
- _(none)_

## Handoff checklist (for human, post-loop E2E)
- [ ] Download a Wine/GPTK runtime via in-app RuntimeManager (or set the URL in Settings).
- [ ] Create the simple Master Steam bottle; install Steam; log in; download ≥1 game.
- [ ] Point Silo at the Master bottle; confirm discovery lists the game.
- [ ] Isolate → seeds prefix; Play → launches in isolated `WINEPREFIX` with GPTK (CrossOver fallback).
- [ ] (If DRM-gated) pick a Steam Presence Strategy; for `.emulatorStub` provide the stub path.
- [ ] (Distribution) provide Apple Developer ID + notarization secrets for signed releases.
