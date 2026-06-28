# CLAUDE.md — Silo operating manual

> Read this file first, every session. Then read `STATUS.md` to find the current task.
> This file is the contract; `STATUS.md` is the live state.

## Mission
**Silo** is a native macOS (SwiftUI) launcher overlay for Windows Steam games run via Wine + Apple's
Game Porting Toolkit (GPTK / D3DMetal). Topology = **Single Downloader, Multi-Runtime**:
- Steam is installed **once** into a single *simple* Master Wine bottle, used only to download games.
- Each game is **launched in its own isolated Wine prefix** with its own graphics backend + env.

Pipeline: **Discovery** (parse `appmanifest_*.acf`) → **Provision** (seed per-game prefix) →
**Graphics Linker** (inject GPTK/D3DMetal, CrossOver fallback) → **Launch Orchestrator** (detached
process with `WINEPREFIX` overridden to the isolated prefix).

## Hard constraints (non-negotiable)
1. **SwiftPM only — never call `xcodebuild`.** This machine has Command Line Tools only (no Xcode).
   Build with `swift build`; the `.app` is assembled by `Scripts/build-app.sh`.
2. **Swift 6 strict concurrency** (`swiftLanguageMode(.v6)`). No `@unchecked Sendable` to silence
   errors — derive correct isolation from the concurrency model below. (`@unchecked` is allowed only
   in test doubles where it is genuinely safe and commented.)
3. **NOT App-Sandboxed.** `Resources/silo.entitlements` must never contain
   `com.apple.security.app-sandbox`. The app executes `wine` *outside* its bundle and reads/writes
   `~/Library/Application Support` + the Steam bottle — impossible under the sandbox.
4. **Builds, tests, launches, and parses a library with ZERO runtimes installed.** Wine/GPTK/Steam
   are absent on this machine. Everything runtime-dependent sits behind a resolver returning
   `.notConfigured` → a UI state, never a crash. Tests must pass on a clean machine.
5. **No Homebrew / system package-manager dependency.** Fully self-sustained. The app downloads its
   own Wine/GPTK runtime from a *configurable third-party GitHub release* (Heroic-style) and
   self-updates from GitHub Releases.
6. **No external SPM dependencies.** Updater + runtime downloads use `URLSession` + the GitHub API
   directly. Keep `Package.swift` dependency-free.
7. **Never bundle or auto-download Wine, GPTK, or any Steam-API emulator (Goldberg).** The runtime is
   fetched only from a URL the user can see/override; the emulator stub is **user-provided only**,
   with a prominent legal/ToS caveat, original DLL backed up.
8. **The Wine runtime is built ONLY from CrossOver's FOSS source** (`crossover-sources-<ver>.tar.gz` via
   `Scripts/build-wine.sh` / `build-wine.yml`). This is the ONE accepted base. **Do NOT propose, switch to,
   or suggest** Gcenx/`macOS_Wine_builds` (stale, unverifiable source provenance), Whisky, mainline/staging
   prebuilts, or using an installed CrossOver/CodeWeavers product. Every black-window / login / graphics
   problem is to be **fixed on this from-source CrossOver-FOSS Wine** — debug the build flags, Wine
   registry, env, and Silo's launch code; never answer "use a different runtime." Decided 2026-06-28.

## Two runtime roles
- `BottleRole.steam` → a **simple/vanilla** Wine bottle (Steam is finicky; no GPTK overrides).
- `BottleRole.game` → **Apple GPTK / D3DMetal** is the single graphics path (D3DMetal overlaid into the
  wine runtime by `GraphicsLinker.overlayGPTK`). No DXVK/CrossOver-backend fallback — when GPTK isn't
  configured the game simply runs on wine's own wined3d.

## Steam Presence Strategy (per-game, the DRM answer)
Steamworks IPC is **prefix-scoped**: a game can only reach a Steam client running in its OWN Wine prefix
(separate wineservers = no cross-prefix bridge; Valve's Proton↔native-Steam bridge is Linux-only). So a
single "master" Steam can NOT serve games in other bottles — the game and a logged-in Steam client must
be **co-resident in one prefix**.
Per game (`SteamPresenceStrategy`, default `.steamAppIDFile`):
- `.none` — no Steam needed.
- `.steamAppIDFile` — write `steam_appid.txt` next to the exe (enough for most non-DRM titles).
- `.sharedSteamClient` — **planned, not implemented**: run a real Windows Steam client co-resident in the
  game's prefix (the only correct way to satisfy a Steamworks/DRM game with online features intact). The
  open problem is a headless/cached login that sidesteps the macOS-26 CEF black-window. Hidden from the UI.
**Goldberg emulator REMOVED (2026-06-27):** a Steam-API emulator fakes ownership and kills all online
features ("no online" = dealbreaker), so `.emulatorStub` was dropped. Constraint #7 still stands — never
bundle/auto-download an emulator.

## Concurrency model (apply consistently)
- **Pure & synchronous** (trivially `Sendable`): `ACFTokenizer`, `KeyValuesParser`, `KVNode`,
  decoders, `LaunchPlan` + `makePlan`, `BackendResolver`, `RuntimeRelease` decoding. Keep these
  free of I/O so they unit-test instantly.
- **`actor`** (owns mutable FS/network state): `DiscoveryEngine`, `RuntimeManager`, `ConfigStore`.
- **`struct` + injected deps, `async` methods**: `GraphicsLinker`, `LaunchOrchestrator`,
  `SteamPresenceInstaller`, `Updater`.
- **`@MainActor @Observable final class`**: all view models.
- **Models**: `Codable, Sendable, Hashable, Identifiable` value types.
- **All external-binary execution goes through the `ProcessRunning` protocol.** Never call
  `Foundation.Process` directly outside `SystemProcessRunner`.

## Conventions
- Resources are read via `Bundle.module`. Absolute paths everywhere (expand `~`).
- The launch builder `makePlan` is a **pure function** — no side effects, exhaustively table-tested.
- New code ships with tests. Tests use **Swift Testing** (`import Testing`, `@Test`/`#expect`),
  which is bundled in the toolchain (no dependency).
- Test doubles + fixtures live under `Tests/SiloKitTests/{Support,Fixtures}`.

## Definition of done (per task)
`swift build` clean (no warnings) **AND** `swift test` green **AND** the new code has tests.
Then update `STATUS.md` and `git commit`.

## Commands
- Build:        `swift build`
- Test:         `Scripts/test.sh`  (wraps `swift test`; adds the Swift Testing framework search
  path needed under Command Line Tools — plain `swift test` fails with "no such module 'Testing'")
- Release build:`swift build -c release`
- Assemble app: `Scripts/build-app.sh`   → `dist/Silo.app`
- Run app:      `Scripts/run.sh`
- Fast UI dev:  `Scripts/dev.sh`          (`swift run silo`)

## Autonomous loop (per-iteration checklist)
1. Read `STATUS.md`; pick top `TODO` whose deps are `DONE` → mark `DOING`.
2. Restate the acceptance test (the test file/case that proves it).
3. Implement the smallest slice + its test.
4. `swift build` → on failure read the FIRST diagnostic, fix, retry (≤3 focused tries).
5. `swift test` → on red, fix code or a wrong test assumption (never weaken a test to pass).
6. On green: update `STATUS.md`, `git commit` with a milestone message.
7. If two iterations on one task fail to go green → **re-plan**: split the task, log the decision in
   `STATUS.md`, continue. Do not loop forever.
8. Check the stop conditions; if none hit, go to 1.

## HUMAN-INPUT-REQUIRED stop conditions
Write the exact question into `STATUS.md` → `## BLOCKED`, commit the last green state, then stop:
- The third-party GPTK/wine-crossover download URL/license to pin as default, or it 404s.
- Apple Developer login / notarization secrets for signed distribution.
- A real Wine runtime + downloaded game to validate true `wineboot`/launch end-to-end.
- Getting the Windows Steam client to render/log in once in a bottle on macOS 26 (the CEF black-window) —
  the prerequisite for the `.sharedSteamClient` (in-prefix Steam) path.
- A material product/legal ambiguity where guessing risks rework.
- Anything needing SIP disable / Full Disk Access / a TCC prompt the agent can't satisfy headlessly.

## Environment (verified 2026-06-26)
Swift 6.3.2 (`arm64-apple-macosx26.0`); macOS 26.5.1, Apple Silicon; `xcodebuild` absent;
`git`/`codesign` present; Wine/GPTK/Whisky/CrossOver/DXVK/Steam-games all absent.
