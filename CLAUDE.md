# CLAUDE.md — Silo operating manual

> Read this file first, every session. Then read `STATUS.md` to find the current task.
> This file is the contract; `STATUS.md` is the live state.

## Mission
**Silo** is a native macOS (SwiftUI) launcher overlay for Windows Steam games run via Wine + Apple's
Game Porting Toolkit (GPTK / D3DMetal), 3Shain's DXMT, and DXVK. Topology = **one shared Steam bottle +
isolated manual bottles**:
- **Steam games** run co-resident in **ONE shared "Steam" bottle** (`SteamBottle`) next to a logged-in
  Windows Steam client — Steamworks IPC is prefix-scoped, so a game and its client must share a prefix.
  Each game launches under an **automatically chosen graphics backend** (GPTK / DXMT / DXVK, per game,
  overridable), pinned at launch by runtime + `WINEDLLOVERRIDES` (+ seeded prefix dlls for DXVK) — never baked
  into the shared prefix, so all three co-reside.
- **Manual (non-Steam) games** each run in their **own isolated Wine prefix** under a per-game graphics
  choice — Automatic (the default, resolved by `BackendChooser` exactly like Steam) or an explicit backend.

Pipeline: **Discovery** (parse `appmanifest_*.acf`) → **Provision** (seed the shared Steam prefix, or a
manual game's own prefix) → **Backend choice** (`BackendChooser`: DX9-only → DXVK; else 32-bit → DXMT; else
GPTK; reactive GPTK→DXMT→DXVK learning when a Metal backend can't drive an `.auto` game) → **Graphics Linker**
(overlay GPTK/DXMT into the chosen runtime, or seed DXVK's native dlls into the prefix; wined3d fallback) →
**Launch Orchestrator** (detached; `BottleResolver` is the one map from game → `{prefix, wineBinary,
graphics}`).

**Dock tiles:** Silo-launched Wine processes show a Dock tile named "wine" (macOS names it after the
resolved loader binary). A `DockAppBundle` `.app`-wrapper attempt to rename it was **removed 2026-07-13** —
it couldn't reach Steam's window-owning child processes (the `explorer` desktop + CEF `steamwebhelper`, which
wine spawns via `WINELOADER`), and a co-located named-loader retry didn't work either (wine resolves the
loader symlink back to "wine"). Deemed not worth the complexity for a cosmetic tile name. Launches now spawn
the wine loader directly.

**Process lifecycle (Phase 4):** Silo launches games + the Steam client **detached** and never owns their
lifecycle — quitting Silo leaves them running (like CrossOver); there is NO per-game Stop button, PID
tracking, exit observation, or kill-on-quit. Bottle liveness (the move/self-update corruption guard) is
PID-free via `WineServerProbe` (the wineserver socket, keyed by the prefix's dev+inode — catches crash
orphans too). "Steam is up" = `SteamReadiness.isReady`. Only the first-run warm-up still uses
`isRunning`/`terminate` on a transient local PID (setup plumbing).

**Desktop shortcuts (`silo://` deep links, re-added 2026-07-14):** a game's tile menu → *Create Desktop
Shortcut* writes a tiny `LSUIElement` agent `.app` (`GameShortcut`, per-game bundle id, sanitized filename)
whose launch script only does `open silo://play/steam/<appID>` or `…/manual/<uuid>` (`SiloDeepLink` — pure
parse/build). The custom scheme is registered in `Info.plist.template` (`CFBundleURLTypes`) and handled by
`SiloApp.onOpenURL` → `AppEnvironment.handleDeepLink` → route to `play`/`playManual`. A shortcut is a
*reference* to a library game, NOT a launch snapshot — so the backend (Automatic/learned-DXMT), prefix, and
(for Steam) the co-resident client are all resolved fresh at click time; it works for both game kinds with no
prefix pre-seeding. A link that arrives before the library finishes loading is held in a one-slot pending
queue and routed once `bootstrap()` completes. *(This is the deliberately-simpler replacement for the old
`GameAppShortcut`, removed 2026-07-10, which baked a resolved `LaunchPlan` into a wine-exec'ing `.app` — that
went stale, needed DXMT prefix-seeding, showed a "wine" Dock tile, and couldn't serve Steam titles.)*

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

## Graphics backends (GPTK + DXMT + DXVK — DXVK added 2026-07-26; GPTK+DXMT decided 2026-06-30)
Three D3D→GPU translation layers, selectable **per game**: **GPTK / D3DMetal** (Apple's, D3D10/11/12 → Metal,
the default), **DXMT** (3Shain's, D3D10/11 → Metal directly, the fallback for titles GPTK's device-creation
can't run, e.g. Overcooked 2), and **DXVK** (`doitsujin/dxvk`, D3D9/10/11 → Vulkan → the runtime's bundled
MoltenVK → Metal). DXMT `v0.72` — the **exact version CrossOver 26 bundles** — is built from its upstream
(`3Shain/dxmt`, pinned in `versions.env`) **against the CrossOver Wine** via `Scripts/build-dxmt.sh` /
`build-dxmt.yml` (needs full Xcode's Metal toolchain + the wine install for `winemetal.so`).

**DXVK is the DirectX 9 backend AND the broad-compat fallback** — GPTK doesn't translate DX9 at all and DXMT
is D3D10/11-only, so a DX9 title had NO backend (it black-screened on wined3d). DXVK fills that gap, exactly
as CrossOver ships DXVK as its Vulkan tier below D3DMetal. **Built STOCK from upstream (zlib, no patches) and
run NATIVE** — its d3d9/d3d10core/d3d11/dxgi dlls are seeded into the game prefix's `system32`/`syswow64` and
overridden `=n`, so DXVK runs on the **base runtime** with nothing overlaid into `lib/wine` and no clone
(`GraphicsLinker.installDXVKPrefixLoaders`). It rides wine's own `winevulkan` → **the MoltenVK the DXVK
runtime ships itself** (`<dxvk>/lib/libMoltenVK.dylib`). **Two load-bearing facts, both proven on-device
2026-08-04** (a `D3D11CreateDevice` probe reached **feature level 11_0** on an M4 Pro): (1) a **STOCK**
MoltenVK — including the Homebrew one the wine build bundles — **cannot create a D3D device for DXVK at ANY
feature level**; only a **patched** MoltenVK works, so `build-dxvk.sh`/`build-dxvk.yml` build it from Khronos
source into the DXVK artifact. (2) The Vulkan driver is selected by **dyld NAME lookup**, NOT by
`CX_LIBVULKAN` (an absolute path there is silently ignored) — so `makePlan` puts `<dxvk>/lib` FIRST on
`DYLD_FALLBACK_LIBRARY_PATH` (`URL.dxvkMoltenVKDir`) to pick it. We deliberately do NOT adopt CrossOver's *builtin* DXVK
(a CX patch) — upstream ships native, which is patch-free and needs no runtime clone. `Scripts/build-dxvk.sh`
/ `build-dxvk.yml` cross-compile it (meson + llvm-mingw, both ABIs). The dlls are pure Windows-PE (no Metal
toolchain), but the bundled MoltenVK is built from source and needs **full Xcode** — a CLT-only box builds the
dlls and skips MoltenVK with a warning, producing a NON-shippable artifact; build releases in CI. Constraint #8 binds **Wine** only (neither DXMT nor DXVK is
Wine); never a third-party prebuilt. *(This REVERSES the earlier "DXVK evaluated and rejected" note — the
rejection assumed the Vulkan/MoltenVK stack wasn't worth it, but the substrate already ships in Silo's wine
and DXVK is the only DX9 path, so it earns its place as the third tier below the two Metal backends.)*
DXVK-on-Vulkan-only titles (games that call Vulkan directly) also work via this substrate. d9mt (a future
D3D9→Metal-direct layer) is still deferred — DXVK covers DX9 today.

**The deterministic rule — backend ⇔ runtime ⇔ overrides** (`GraphicsBackend` is the single source of truth
for a backend's runtime + `WINEDLLOVERRIDES`; the *bottle* is per-launch, not per-backend — Steam games on
GPTK and DXMT co-reside in one prefix, each pinned to its own runtime + overrides at launch):
- GPTK/DXMT overlay a **builtin** `d3d11`/`dxgi` into a runtime's `lib/wine` tree, so they can't share one
  runtime. `RuntimeVariants` prepares each: GPTK overlays the base runtime in place (the proven path,
  unchanged); DXMT gets an **APFS clone** of the base + `GraphicsLinker.overlayDXMT`. **DXVK is different — it's
  NATIVE, not a builtin overlay**: `prepare(.dxvk)` returns the base wine (no clone, nothing in `lib/wine`),
  and the dlls are seeded into the game *prefix* at launch — so DXVK co-resides on the base runtime and its
  `=n` native dlls load regardless of what `lib/wine` carries.
- `BottleResolver` is the ONE place that maps a game → `{prefix, wineBinary, graphics}` (`steam(backend:config:)`
  for the Steam bottle, `manual(game,backend:,config:)` for a manual game — both take the caller's resolved
  backend explicitly, so neither launch path can silently land on GPTK). Every launch/provision/tool path routes
  through it — never hard-code `paths.steamBottle` or `backend.wineBinaryPath`. A launch emits exactly that
  backend's `WINEDLLOVERRIDES` builtin set, so it can never cross GPTK↔DXMT or silently land on wined3d (it
  refuses an unconfigured secondary backend).
- **Steam games run in a SINGLE shared Steam bottle** (`SteamBottle`) with a **per-launch backend** — GPTK,
  DXMT and DXVK games co-reside in the one bottle (backend-ness is per-launch: runtime + `WINEDLLOVERRIDES` +
  the seeded prefix dlls, never baked into the shared prefix; a DXMT clone / the base runtime for DXVK joins
  the Steam client's prefix-keyed wineserver). Each game has a `GameConfig.graphics` choice
  (`GraphicsChoice = .auto | .gptk | .dxmt | .dxvk`, default `.auto`). **One signal drives every decision: the
  `D3DProfile`** (`D3DProfile.scan`, computed once per launch off-main) — which unions the PE imports of the
  game's exe **AND the DLLs shipped beside it** (depth ≤2, redist dirs skipped, file-capped). Scanning only the
  `.exe` is not enough: the renderer usually lives in a DLL (Source → `bin/shaderapidx9.dll`, Unity →
  `UnityPlayer.dll`, UE → its `Binaries/Win64` DLLs) while the exe is a thin stub. **Automatic**
  (`BackendChooser.choose`): **DX9-only → DXVK** (`profile.isD3D9Only` — the only DX9 translator,
  bitness-independent); **Vulkan-native → DXVK** (`isVulkanNative`: the game drives Vulkan itself and needs no
  D3D translation, but only the DXVK runtime ships a MoltenVK that works — routing it there is what puts that
  driver first on the launch DYLD path); else 32-bit → DXMT/learned (GPTK is 64-bit-only, but DXMT *and* DXVK
  both ship i386, so a 32-bit hint IS honored); else GPTK (or the learned hint). **DirectX 8 is deliberately
  left on wined3d** (`isD3D8Only`): nothing translates d3d8 — DXVK ships none, and wine's builtin `d3d8` sits
  directly on wined3d rather than forwarding to `d3d9` — so wined3d IS correct, both ladder gates refuse, and
  `handleGraphicsFallback` stays SILENT for it (wined3d's renderer line is expected there, not a failure).
  A `d3d8to9` wrapper imports `d3d9`, so a wrapped DX8 game correctly becomes a DX9 title and reaches DXVK. **Reactive learning walks GPTK → DXMT → DXVK**:
  if a backend can't drive an `.auto` game (`GraphicsFallback`) and the next rung could plausibly help
  (`dxmtMightHelp`/`dxvkMightHelp` — now **pure** functions of the same profile, so the ladder can never
  contradict the forward choice) and is installed, `play` persists a `learnedBackend` hint (`.dxmt` or
  `.dxvk`; DXVK terminal) — `.auto` intent and the settings UI stay intact, a GPTK upgrade re-probes GPTK, and
  a hint whose runtime was uninstalled is dropped. An `isUnknown` profile (dynamic `LoadLibrary`, packed exe)
  fails **open**: normal GPTK-first path, both rungs still allowed. OpenGL titles need no backend — wine's GL.
- **Manual (non-Steam) games** carry a per-game `GraphicsChoice` (`ManualGame.graphics`, default `.auto`) —
  the SAME Automatic selector as Steam games (incl. DX9→DXVK), resolved forward by `BackendChooser.choose` in
  `playManual`. They do NOT carry the reactive learned hint (that machinery is Steam-only), so Automatic for a
  manual game is the pure forward choice; a Metal-backend failure surfaces the honest "switch to X" fallback
  message rather than auto-rerouting. Each runs in its own isolated bottle under the resolved backend's runtime
  (`BottleResolver.manual(_:backend:config:)`). The DXMT/DXVK runtimes install via Settings → DXMT / DXVK
  (`runFullSetup` installs both best-effort so Automatic works out of the box).
- When a backend isn't configured, GPTK degrades to wine's own wined3d (the baseline); a secondary backend
  refuses rather than mis-route. `GraphicsFallback` is backend-aware (surfaces a silent wined3d fallback).

### GPTK versions + D3DMetal's Metal 3 / Metal 4 renderer (beta 2 support, 2026-08-04)
GPTK is the ONE runtime with no pinned version (it's a manual Apple `.dmg` import, so it is deliberately
absent from `versions.env`). **Nothing in `Sources/` hard-codes a GPTK version** and nothing should:
`GPTKImporter.runtimeName(forDMG:)` derives `GPTK-<version>` from the DMG filename, `installed()` validates
by *layout* (`lib/wine/x86_64-windows` + `lib/external/D3DMetal.framework`, and NO wine binary — the only
thing distinguishing a GPTK tree from an already-overlaid wine runtime), and `overlayGPTK` selects modules by
prefix (`d3d`/`dxgi`/`nv`), never by name list. So a new GPTK drops in with zero code — verified end-to-end
against the real `4.0_beta_2` dmg. Two consequences worth knowing:
- **`overlayGPTK` refreshes on a version change** because it byte-compares a witness (`d3d11.dll`) before
  skipping, and copies the witness *last* so a mid-copy failure re-does the whole set next launch. Re-running
  the same GPTK is a true no-op; a different one re-overlays all 12 modules + `lib/external`.
- **Switching the default GPTK re-probes every learned backend.** `learnedUnderRuntime` is compared against
  `BackendConfig.gptkRuntimeName`, so a new install invalidates every reactive GPTK→DXMT/DXVK downgrade and
  those titles retry GPTK once. Intended — a new D3DMetal may fix them — but it is not silent-free: expect
  one GPTK attempt on titles that had settled onto a fallback.

**`EnvFlags.metalBackend` (`MetalBackendChoice = .auto | .metal4 | .metal3` → `D3DM_MTL4`)** picks which
renderer D3DMetal's **DirectX 12** path translates through. GPTK 4.0b1 shipped Metal 4 as opt-in (`=1`);
4.0b2 makes it the **default on macOS 27+**, with `=0` the way back to Metal 3 — so Apple's default depends on
BOTH the GPTK version and the OS. `.auto` (the default) therefore emits **nothing** and lets D3DMetal decide:
`makePlan` stays pure, needs no OS-version probe, and a config written today can't silently pin a stale
renderer once macOS 27 ships. Emitted for `.gptk` only (DXMT/DXVK have no Metal 4 concept), `extra` still
overrides it. Modelled as a selector-with-Automatic rather than a Bool because Metal 3 vs Metal 4 is a
*backend*, not a capability toggle like `metalFX`/`dxr` — which is also how CrossOver splits its own graphics
settings (`setGraphicsBackendAuto`/…/`setGraphicsBackendDXVK` vs the `isDLSSAvailable`/`isDLSSEnabled` switch).

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
  decoders, `LaunchPlan` + `makePlan`, `BackendChooser.choose`, `BottleResolver`, `RuntimeRelease`
  decoding. Keep these free of I/O so they unit-test instantly. (One exception: `BackendChooser`'s
  *other* method, `dxmtMightHelp`, reads the game exe's PE import table — a synchronous, non-`async`
  file read on the rare fallback path; `choose` stays pure.)
- **`actor`** (owns mutable FS/network state): `DiscoveryEngine`, `RuntimeManager`, `ConfigStore`.
- **`struct` + injected deps, `async` methods**: `GraphicsLinker`, `LaunchOrchestrator`,
  `SteamPresenceInstaller`, `Updater`.
- **`@MainActor @Observable final class`**: all view models.
- **Models**: value types. *Persisted* models (`AppState`, `GameConfig`, `BackendConfig`, `ManualGame`,
  `EnvFlags`, `SteamApp`, …) are `Codable, Sendable, Hashable, Identifiable` with tolerant decode.
  Live filesystem-probe descriptors (`WineInstall`, `GPTKInstall`, `DXMTInstall`, `RuntimeInstall`) are
  never serialized, so they're the lighter `Sendable, Equatable, Identifiable` — not `Codable`.
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

## Environment (verified 2026-06-26; runtimes added 2026-07-13; GPTK 4.0b2 added 2026-08-04)
Swift 6.3.2 (`arm64-apple-macosx26.0`); macOS 26.6, Apple Silicon; `xcodebuild` absent;
`git`/`codesign` present. **The dev box now HAS a provisioned Silo bottle + all three runtimes** at
`~/Library/Application Support/Silo` (`Runtimes/`: `GPTK-4.0_beta_1` **and `GPTK-4.0_beta_2`** — both kept,
so the GPTK Manager's default radio is a one-click A/B — plus `dxmt-v0.72-cx26.2.0`, `wine-cx-26.2.0`;
a set-up `SteamBottle`), so on-device launch/log capture is possible here. This does NOT relax constraint #4:
the build **and** `swift test` must still pass on a machine with ZERO runtimes (everything runtime-dependent
stays behind a resolver → `.notConfigured`). Whisky/CrossOver/DXVK absent; no game installed in the bottle yet
(only `Logs/steam-bottle.log` exists — no per-game log until a game is launched through Silo).
