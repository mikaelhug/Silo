# CLAUDE.md — Silo operating manual

> Read this file first, every session. Then read `STATUS.md` to find the current task.
> This file is the contract; `STATUS.md` is the live state.

## Mission
**Silo** is a native macOS (SwiftUI) launcher overlay for Windows Steam games run via Wine + Apple's
Game Porting Toolkit (GPTK / D3DMetal). Topology = **Single Downloader, Multi-Runtime**:
- Steam is installed **once** into a single *simple* Master Wine bottle, used only to download games.
- Each game is **launched in its own isolated Wine prefix** with its own graphics backend + env.

Pipeline: **Discovery** (parse `appmanifest_*.acf`) → **Provision** (seed per-game prefix) →
**Graphics Linker** (inject GPTK/D3DMetal, wined3d fallback) → **Launch Orchestrator** (detached
process with `WINEPREFIX` overridden to the isolated prefix).

**Dock tiles (Phase 3):** launches spawn through a generated `.app` wrapper (`DockAppBundle`) whose
`Contents/MacOS/<name>` is a **symlink to the wine loader**, so macOS names the Dock tile from the
wrapper's `CFBundleName` (`[NSBundle mainBundle]` resolves from the *unresolved* invoked path) instead of
"wine". The loader still self-locates its runtime because it `realpath`s the symlink; `Silo.pinWineLoader`
sets `WINELOADER`/`WINESERVER` to the real runtime for child processes. Wrappers live in `paths.dockAppsDir`.

**Process lifecycle (Phase 4):** Silo launches games + the Steam client **detached** and never owns their
lifecycle — quitting Silo leaves them running (like CrossOver); there is NO per-game Stop button, PID
tracking, exit observation, or kill-on-quit. Bottle liveness (the move/self-update corruption guard) is
PID-free via `WineServerProbe` (the wineserver socket, keyed by the prefix's dev+inode — catches crash
orphans too). "Steam is up" = `SteamReadiness.isReady`. Only the first-run warm-up still uses
`isRunning`/`terminate` on a transient local PID (setup plumbing).

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

## Graphics backends (GPTK + DXMT — decided 2026-06-30, reverses the GPTK-only stance)
Two Metal translation layers, selectable **per game**: **GPTK / D3DMetal** (Apple's, D3D10/11/12 → Metal,
the default) and **DXMT** (3Shain's, D3D10/11 → Metal directly, the fallback for titles GPTK's
device-creation can't run, e.g. Overcooked 2). DXMT `v0.72` — the **exact version CrossOver 26 bundles** —
is built from its upstream (`3Shain/dxmt`, pinned in `versions.env`) **against the CrossOver Wine**, the
DXMT↔Wine pairing CrossOver itself ships — via `Scripts/build-dxmt.sh` / `.github/workflows/build-dxmt.yml`
(needs full Xcode's Metal toolchain + the wine install for `winemetal.so`). Constraint #8 binds **Wine**
only (DXMT isn't Wine); we build from upstream for the canonical, reproducible build incl. its git
submodules. Never a third-party prebuilt. DXVK was evaluated and rejected (Vulkan/MoltenVK stack; DXMT is
Metal-direct).

**The deterministic rule — backend ⇔ runtime ⇔ bottle** (`GraphicsBackend` is the single source of truth):
- Both backends overlay a **builtin** `d3d11`/`dxgi` into a runtime's `lib/wine` tree, so they can't share
  one runtime. `RuntimeVariants` prepares each: GPTK overlays the base runtime in place (the proven path,
  unchanged); DXMT gets an **APFS clone** of the base + `GraphicsLinker.overlayDXMT`.
- `BottleResolver` is the ONE place that maps a game → `{prefix, wineBinary, graphics}` (`steam(config:)`
  for the Steam bottle, `manual(game,config:)` for a manual game). Every launch/provision/tool path routes
  through it — never hard-code `paths.steamBottle` or `backend.wineBinaryPath`. A launch emits exactly that
  backend's `WINEDLLOVERRIDES` builtin set, so it can never cross GPTK↔DXMT or silently land on wined3d (it
  refuses an unconfigured secondary backend).
- **Steam games run in a SINGLE shared Steam bottle** (`SteamBottle`) under GPTK/D3DMetal. *(Phase 0,
  2026-07-10: the separate `SteamBottle-DXMT` bottle + all dual-Steam-bottle machinery were removed —
  collapsed to one bottle. The Steam bottle is GPTK-only for now; a per-launch **automatic** backend (and a
  manual per-Steam-game override) in the one bottle is planned for a later phase.)*
- **Manual (non-Steam) games** pick a backend per game (`ManualGame.backend`); each runs in its own
  isolated bottle under that backend's runtime — **this is where DXMT runs today**. The DXMT runtime is
  still installed via Settings → DXMT.
- When a backend isn't configured, GPTK degrades to wine's own wined3d (the baseline); a secondary backend
  refuses rather than mis-route. `GraphicsFallback` is backend-aware (surfaces a silent wined3d fallback).

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

## Steam-bottle setup (Phase 1 — 2026-07-10)
Onboarding is **2 steps**: (1) import GPTK `.dmg`, (2) **"Set up"** → `AppEnvironment.runFullSetup()` chains
download Wine → download DXMT runtime → download Steam → `wineboot` → the ordered **component set** → warm-up.
The component set + order is `BottleComponent.allCases` (single source of truth), installed by
`SteamBottle.provisionComponents(wine:onPhase:)` (each component has an `isSatisfied` predicate → skipped when
present, so setup is resumable/idempotent): **Core Fonts** (first font user-guided for its EULA, rest silent)
→ **Source Han Sans** (4 CJK packs, OFL, file-copy) → **d3dcompiler_47** (both ABIs via `wine expand` of the
MS-SDK CABs, native files, no override) → **MSVC redist x86 → x64** (user-guided) → **msync** (no-op — `WINEMSYNC=1` is
launch-time env) → **Steam** (user-guided, no `/S`). License-bearing installers run via `ProcessRunning.run`
(blocks until the user closes the window). New download URLs live in `Silo.swift` (no `versions.env` entry, per
the corefonts precedent). On-device-unverified risks (see STATUS): `wine expand` member extraction, the
user-guided SteamSetup black-window/auto-launch (mitigated by `forceQuit` before warm-up).

**Phase 2 (2026-07-10):** after `wineboot`, `SteamBottle.applyWineDefaults` imports Silo's default
`HKCU\Software\Wine\DllOverrides` set (`Silo.defaultDllOverrides` — the 58-entry standard Windows-compatibility
override set, `Sources/SiloKit/Steam/BottleDefaults.swift`) via one `wine regedit /S`. `d3dcompiler_47`/`msvcp140`/
`vcruntime140` are installed as native files but **NOT** overridden — Wine's load order picks up the real files
once present, so no registry override is needed (the earlier `d3dcompiler_47=native` override was removed).

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

## Versions — single source of truth
**`versions.env` (repo root) is the ONLY place a version number is edited** (app version, GitHub repo,
CrossOver wine source version). It's shell-sourceable; `Scripts/gen-versions.sh` mirrors it into the
*committed* `Sources/SiloKit/Versions.swift` (`Versions.silo`/`.githubRepo`/`.crossoverVersion`), which
`Silo.swift` reads. `build-app.sh` + `build-wine.sh` source it directly. **After editing `versions.env`, run
`Scripts/gen-versions.sh`** (build-app.sh does it for you) — a unit test fails if the two drift. Never
hard-code a version anywhere else.

## Commands
- Build:        `swift build`
- Test:         `Scripts/test.sh`  (wraps `swift test`; adds the Swift Testing framework search
  path needed under Command Line Tools — plain `swift test` fails with "no such module 'Testing'")
- Release build:`swift build -c release`
- Bump version: edit `versions.env` → `Scripts/gen-versions.sh`
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
