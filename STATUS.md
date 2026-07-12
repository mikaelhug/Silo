# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **🪟 Setup installer windows: focus them + a cancel now stops setup (2026-07-12, `main`; `swift build` clean +
  zero warnings, 360 tests green).** Two onboarding annoyances the user hit during a real setup:
  - **Focus the license/installer windows.** A window Silo's forked `wine` opens (a Core Fonts EULA, an MSVC
    redist, the Steam installer) lands *behind* the still-active Silo, so the user can miss that it appeared at
    all. New `InstallerWindowFocuser` (`Sources/SiloKit/Support/`, behind a `GuidedInstallFocusing` protocol so
    the VM unit-tests with a spy) observes `NSWorkspace.didLaunchApplicationNotification` and `activate()`s the
    launched app whose executable lives under the Wine runtime root (`isWineApp`, trailing-slash guarded so
    `…/wine-dxmt` can't match `…/wine`). `SteamBottleViewModel` arms it per **user-guided** component step and
    disarms between steps / before the windowless warm-up / on exit. Fail-safe: an unmatched window just stays
    where macOS put it (today's behaviour) — never a regression. On-device-unverified (Wine absent on the dev
    box); the arm/disarm bracketing + the match predicate are unit-tested.
  - **Cancelling a font/redist installer now FAILS setup** instead of silently continuing with a
    half-provisioned bottle. Declining the first Core Font EULA, or a non-success MSVC redist exit (incl. a
    1602 user cancel), throws `BottleError.componentCancelled(component)`; `provisionComponents` rethrows it
    (was best-effort for everything but Steam). Nothing is marked, so the next Set up re-prompts that
    component. The VM surfaces it as a pause — "Setup paused — you cancelled the … installer. Run Set up again
    to finish." — not a hard failure.
  - Tests (+5): VC-redist cancel now asserts the throw; first-Core-Font decline throws + installs nothing +
    stops after the first font; `provisionComponents` rethrows a mid-set cancel (Steam never runs);
    `isWineApp` predicate; the setUp flow arms the focuser with the runtime root on the user-guided step, then
    disarms; `setupFailureMessage` cancel copy.
- **🎛️ Automatic graphics backend (GPTK ⇄ DXMT) for the shared Steam bottle (2026-07-11, `main`; `swift build`
  clean + zero warnings, 354 tests green).** Steam games are no longer GPTK-only: each has a per-game
  `GraphicsChoice` (`.auto`/`.gptk`/`.dxmt`, default `.auto`) and GPTK + DXMT games co-reside in the ONE Steam
  bottle. Investigation (local CrossOver 26 + web) confirmed CrossOver's "Automatic" is a proprietary online
  per-title DB (default → wined3d, unusable) and that backend selection is per-process env — so Silo's
  variant-runtime + per-launch-overrides design already matches, and Silo's Automatic is an **educated guess
  from the game binary + reactive learning** instead of a title DB.
  - **`BackendChooser`** (pure, `Sources/SiloKit/Launch/BackendChooser.swift`): `.auto` → 32-bit ⇒ DXMT (GPTK
    is 64-bit-only), else GPTK (the proven default; also the only D3D12 path). `dxmtMightHelp` reads the PE
    **import table** (`WindowsExecutable.importedDLLs`) to gate the reactive switch — fail-open (empty imports
    / dynamic `LoadLibrary` loaders → try DXMT), suppressed only when confident DXMT can't help (imports D3D12,
    or D3D9 with no D3D10/11).
  - **Reactive learning**: when the `GraphicsFallbackMonitor` detects "GPTK didn't engage" on an `.auto` game
    and DXMT is installed + might help, `play` persists `.dxmt` for that game ("Silo will use DXMT next time").
  - `GameConfig.graphics` (tolerant decode, `graphics` key — the legacy dual-bottle `backend` key stays
    ignored); `BottleResolver.steam(backend:config:)` routes a DXMT Steam game onto the DXMT variant clone in
    the SAME Steam prefix (unconfigured DXMT still throws `backendNotConfigured`); `play` picks the backend off
    the chooser (32-bit-on-explicit-GPTK still refused, now steering to DXMT); a **Graphics** picker
    (Automatic/GPTK/DXMT) added to the Steam game settings sheet. Fallback/refusal messages unified to steer to
    DXMT (Steam + manual both have a per-game Graphics setting).
  - Tests (+10): `BackendChooser` table + PE-import reader (synthetic PE32/PE32+ fixtures, fail-open);
    `BottleResolver.steam(backend:.dxmt)` → clone runtime + Steam prefix (+ refusal); `play` auto-routes a
    32-bit Steam game onto the DXMT clone in the shared prefix with winemetal seeded; reactive switch persists
    `.dxmt`; `GameConfig` graphics codec.
  - **Review fixes (2026-07-11, high-effort multi-agent review):** the Steam Graphics picker now actually
    persists (`GameSettingsViewModel.save` was dropping `graphics`); the reactive switch re-reads fresh config
    at fire time (can't clobber an explicit pin or write for an uninstalled DXMT) and only promises the switch
    when the write succeeds; the fallback message steers to DXMT only when it could help (no false steer for
    D3D12/D3D9-only); a 32-bit game routed to a 64-bit-only DXMT is refused up front (`BackendConfig
    .dxmtSupports32Bit`); `play` resolves the exe ONCE and hands it to `launchInBottle` (no double install-dir
    walk, decision + launch use the same binary); `BackendChooser.choose` is now pure (`is32Bit:` in). 355
    tests green.
  - **Quality pass:** the failure-only PE import read (`dxmtMightHelp`) is now lazy — computed in
    `handleGraphicsFallback` only when a fallback actually fires, never on a healthy launch; the reactive-learn
    logic is factored into named `handleGraphicsFallback`/`learnDXMT`/`fallbackMessage` methods (no dense
    nested closure); the `.gptk` default was removed from `BottleResolver.steam` / `launchInBottle` /
    `launchManualGame` so a future launch path can't silently land on GPTK (`makePlan` keeps its default — it's
    the pure builder, always fed `graphics` by those methods); the four copied test PE-byte builders collapsed
    into one `Support/PEFixture`. No polling loops (fallback detection stays kqueue-driven via
    `GraphicsFallbackMonitor`).
  - **On-device (Wine absent here):** (1) **co-residency** — with the bottle Steam up, launch a DXMT-routed
    game and confirm it joins the SAME wineserver (one `server-*` socket under `/tmp/.wine-$(id -u)/` or
    `$TMPDIR`), Steamworks connects, and the log shows DXMT's feature level; (2) a 32-bit Steam title (e.g.
    Overcooked 2) end-to-end via Automatic → DXMT (needs the both-ABI DXMT release asset — confirm i386 is
    published, else run `build-dxmt.yml`); (3) a known-good GPTK title unchanged; (4) a GPTK-failing DX11 title
    flips itself to DXMT and works on the second launch.
- **🚪 Phase 4 — quit leaves Steam + games running; PID-free bottle liveness (2026-07-10, `main`; `swift build`
  clean + zero warnings, 350 tests green).** Like CrossOver, Silo now LAUNCHES detached and never owns a
  launched process's lifecycle: quitting Silo no longer kills Steam or games, and there is no per-game Stop
  button, PID tracking, or exit observer.
  - **Removed:** the app-quit teardown (`AppEnvironment.terminateAllOnQuit` + the `RootView` willTerminate
    hook); `GameProcessCoordinator` (the PID/observer table); the per-game Stop button + running badge (tiles
    are just Play / Launching…); `SteamClientSession.stop`/force-quit + `SteamBottle.forceQuitSync`;
    `LaunchOrchestrator.stopGame`/`observeExit`/`resolvedExecutableName`; and the `ProcessLedger` PID shadow
    (+ the now-dead `observeExit`/`spawnDetachedForget`/`startTime`/`ProcessObservation` primitives). KEPT
    `isRunning`/`terminate` + `SteamBottle.forceQuit`/`shutdownSteam` for the first-run WARM-UP only (setup
    plumbing that owns a transient client PID locally to drive its download/relaunch loop).
  - **New `WineServerProbe`** (`Sources/SiloKit/Process/WineServerProbe.swift`): PID-free bottle liveness via
    the wineserver socket (`<tmp>/.wine-<uid>/server-<dev>-<inode>/socket`, keyed by the prefix's dev+inode —
    the identity wine itself uses). Replaces the ledger as the corruption guard: `blockedForBottleWork` /
    `anythingRunning` refuse a bottle move / self-update while ANY bottle's wineserver is live — INCLUDING a
    crash orphan (its socket persists), so the crash-orphan protection survives PID-free. `removeManual`
    refuses while the game's own bottle is live.
  - **`SteamClientSession` off PIDs**: `isRunning` = `SteamReadiness.isReady` (Steam's own registered
    `ActiveProcess` pid, not a PID Silo tracks); `ensureRunning` coalesces concurrent callers, skips a
    redundant relaunch when already ready (Steam single-instances anyway), and reports launch success.
  - **What the "wine" processes taught us** (winedevice.exe ×2, wineserver, wineloader when only Steam runs):
    the wineserver is the detached per-prefix daemon that outlives the launcher — so bottle liveness belongs
    to the SOCKET, not a PID Silo holds. That's the basis for both halves of this phase.
  - Tests: deleted the coordinator/ledger suites + every stop/kill/track test; added `WineServerProbeTests` +
    a fake-socket fixture; the gate tests drive a fake wineserver socket and the Steam tests drive readiness
    via `user.reg`. New: "quitting does NOT kill launched games or Steam."
  - **On-device (Wine absent here):** confirm the exact temp root wine uses for its socket (`/tmp` vs
    `$TMPDIR` vs `$XDG_RUNTIME_DIR` — all three are probed; verify the one this runtime uses) so the guard
    actually fires; confirm quitting Silo leaves Steam + a running game alive.
- **🪟 Phase 3 — correctly NAMED Dock tiles for Silo-launched Steam + games (2026-07-10, `main`; `swift build`
  clean + zero warnings, 371 tests green).** A bare `wine steam.exe` launch shows a Dock tile named "wine".
  macOS names a GUI process's tile from `[NSBundle mainBundle].CFBundleName`, resolved from the executable
  path AS INVOKED — so Silo now spawns each launch through a generated `.app` wrapper whose
  `Contents/MacOS/<name>` is a **symlink to the wine loader**: spawning that in-bundle path makes `mainBundle`
  resolve to the wrapper → the tile is named "Steam" / the game's name. Confirmed from the loader binary that
  this is safe: the macOS loader maps ntdll **in-process** (no preloader re-exec — no exec symbols; it
  `realpath`s `_NSGetExecutablePath` for lib discovery, which FOLLOWS the symlink to the real runtime, while
  CFBundle uses the UNRESOLVED invoked path), so a bare symlink yields BOTH the name AND correct lib
  self-location at once.
  - New `DockAppBundle` (`Sources/SiloKit/Launch/DockAppBundle.swift`): pure plist builder + `write` that
    (re)creates `<folder>.app` with the `MacOS/<exe>` symlink. No bundle icon — `winemac.drv` supplies the
    live tile icon from the game window at runtime; the wrapper only fixes the NAME.
  - `Silo.pinWineLoader` sets `WINELOADER`/`WINESERVER` to the REAL runtime (safe: the INITIAL process never
    re-execs the loader; only child procs do — so it must NOT be the symlink, or every child would be named).
    `makePlan` gains `launchVia`; `launchInBottle`/`launchManualGame` gain a `DockIdentity` (name + stable
    folder slug + `paths.dockAppsDir`). `SteamBottle.launchSteam` wraps the client as `Steam.app` (its
    `explorer /desktop=` root window owns the tile). Best-effort: a wrapper-write failure falls back to
    launching the loader directly (tile → "wine").
  - Wrappers live under `supportDir/DockApps` (always reachable — not the relocatable bottles drive).
  - Tests (+7): `DockAppBundleTests` (names via CFBundleName, no icon/LSUIElement, symlink target, idempotent
    repoint); `makePlan` launchVia (spawns the symlink + pins WINELOADER/WINESERVER); the DXMT-manual + Steam
    launch tests now assert the wrapper executable + pinned loader.
  - **On-device (Wine absent here):** confirm the Steam window's PID reports `<Name>` via
    `lsappinfo info -only name <pid>` and that a single primary tile appears (a stray `steamwebhelper` tile
    would be a child-coalescing follow-up — CrossOver solves that with a proprietary helper Silo doesn't have).
- **🧹 Post-Phase-4 — removed the "Create Desktop Shortcut" feature (2026-07-10, `main`; 344 tests green).**
  Per the user, the Desktop-shortcut feature is gone entirely (`GameAppShortcut`, `GameLibraryViewModel.makeShortcut`,
  `LaunchOrchestrator.prepareGraphics`, the tile menu item, and their tests) — which also moots the Phase 3
  follow-up (that standalone `.app` `exec`'d wine, so its tile read "wine"). Manual games launch from Silo
  (correctly named tile) or their own `winecfg`; no standalone launcher `.app`.
- **🔧 Phase 2 — default Wine config for the Steam bottle (2026-07-10, `main`; `swift build` clean +
  zero warnings, 364 tests green serial + parallel).** A vanilla `wineboot` prefix carries no
  `HKCU\Software\Wine\DllOverrides`, but games expect the standard Windows-compatibility set. Silo now applies
  its own **58-entry** default override set (the classic Wine default template) to the Steam bottle.
  - New `Silo.defaultDllOverrides` (`Sources/SiloKit/Steam/BottleDefaults.swift`) + `SteamBottle.applyWineDefaults`:
    builds a REGEDIT4 `.reg` and imports it with ONE `wine regedit /S` (cheaper than 58 `reg add`s), idempotent
    (`.silo-installed/wine-defaults` marker). Called in `setUp` right after `provision` ("Configuring the bottle…").
  - **Removed Silo's `d3dcompiler_47=native` override** (kept the DLL file) — the native DLLs
    (d3dcompiler_47 4.3 MB, msvcp140 643 KB, vcruntime140 179 KB) are present, so Wine's load order picks them
    up with **NO** override. Dropped the now-dead `setDllOverride` helper.
  - **MSVC unchanged** — Phase 1 already installs the redist without overrides. The redist places the real
    `msvcp140.dll` on this Wine (bug-57518 doesn't bite cx-26.x), so the winetricks force-native workaround
    (+ risky CAB-extract) is **not** needed.
  - Tests (+2): a completeness pin (the 58-entry set, and NOT msvcp140/vcruntime140/d3dcompiler_47/concrt140),
    the `regedit` import + idempotency, `installD3DCompiler47` now asserts NO override.
  - **On-device:** after a fresh setUp, confirm winecfg → Libraries shows the override set, `d3dcompiler_47`
    no longer appears, and `system32/msvcp140.dll` is the real 643 KB file.
- **📦 Phase 1 — bottle provisioning + 2-step onboarding (2026-07-10, `main`; `swift build`
  clean + zero warnings, `swift test` green serial + parallel, 360 tests).** The Steam bottle now installs its
  game-dependency component set in a fixed order, with the license-bearing pieces run as **user-guided**
  GUI installers (`ProcessRunning.run` blocks until the user closes the window). Onboarding collapses from 3
  steps to **2**: (1) import GPTK `.dmg`, (2) **"Set up"** → `AppEnvironment.runFullSetup()` chains it all.
  - **Ordered component model.** `BottleComponent` enum (`allCases` = the single source of truth for order) +
    per-component `isSatisfied`/`install` on `SteamBottle`, driven by `provisionComponents(wine:onPhase:)` —
    satisfied components are skipped (resumable/idempotent), best-effort per component except the terminal
    Steam install. Order: **Core Fonts → Source Han Sans → d3dcompiler_47 → MSVC x86 → MSVC x64 → msync →
    Steam**. `SteamBottleViewModel.setUp()` now: download Steam → `wineboot` → `provisionComponents` →
    `forceQuit` (black-window guard) → warm-up → webhelper wrap.
  - **Core Fonts** (`installCoreFonts` reworked): installed in the FIXED `Silo.coreFonts` order; the FIRST
    font runs its installer **bare** (shows the Microsoft EULA, blocks), the rest extract silently (`/T /C /Q`)
    — "user-guided initially then auto." Added a GitHub-mirror fallback URL (SourceForge is flaky).
  - **Source Han Sans** (new `installSourceHanSans`): all **4** language packs (J/K/SC/TC, ~360 MB, OFL, no
    prompt) — download → bsdtar extract → copy `.otf` into `windows/Fonts`; **per-pack markers** make the big
    download resumable.
  - **d3dcompiler_47** (new `installD3DCompiler47`): both ABIs, extracted from Microsoft's Windows-SDK CABs via
    Wine's builtin **`wine expand`** (no cabextract), 64-bit→`system32` / 32-bit→`syswow64` (Phase 1 added a
    native override here; Phase 2 removed it — the file's presence is enough). **⚠️ R2 (highest on-device risk):**
    whether `wine expand -F:<member>` pulls the named member on a real Mac — fallback is re-hosting the two
    redistributable DLLs as Silo release assets.
  - **MSVC redist** (new `installVCRedist`): x86 then x64, **user-guided** (no `/quiet` → license shown).
    **msync** is a no-op (env-only, always satisfied → skipped).
  - **🐛 On-device fix (2026-07-10): MSVC never showed its user-guided installer.** Root cause: `wineboot`
    pre-populates system32/syswow64 with tiny **fakedll** stubs for Wine's builtins (incl. `msvcp140.dll`),
    so the "is `msvcp140.dll` present?" marker read true on a fresh prefix and **skipped the redist entirely**
    — same latent bug for `d3dcompiler_47`. Fixed: MSVC now tracks a **Silo marker** (`.silo-installed/
    vcredist-{x86,x64}`) written only on a success exit code (0/3010/1638; a cancel 1602 re-prompts), and
    d3dcompiler is **size-gated** (real DLL is multi-MB vs the ~KB stub). +2 tests pin it (a fakedll stub no
    longer satisfies either; a cancel re-prompts). 362 tests green.
  - **Steam** install is now **user-guided** (`runSteamInstaller(userGuided:)` drops `/S`); `installSteam`
    (silent) kept for the CLI/tests. `downloadSteamInstaller` is a separate early step (fails fast on network;
    now creates the prefix since it runs before `wineboot`).
  - **Orchestrator** `AppEnvironment.runFullSetup()`: download Wine (if `!wineReady`, then **await** the
    default-persist so the DXMT match / setUp don't read a nil wine binary — R7) → download DXMT (if
    `!dxmtReady`) → `steamBottleVM.setUp()`. `setupBusy` drives the onboarding spinner. `OnboardingView` → 2
    `StepRow`s; `--setup-steam` CLI drives the whole chain.
  - **New constants** in `Silo.swift` (no `versions.env` change): corefonts mirror, Source Han Sans base +
    packs, MSVC `aka.ms` URLs, d3dcompiler CAB URLs + member ids.
  - **Tests (+9):** per-component (EULA-first fonts, 4-pack SHS + resume, `wine expand` d3dcompiler + override,
    user-guided MSVC no-`/quiet`, user-guided Steam no-`/S`), the ordered-driver sequence + skip-satisfied, the
    reworked `setUp` (user-guided Steam + `forceQuit` before warm-up), the pure `componentStatus` mapping, and
    `runFullSetup` skip-when-ready delegation. `createComponentMarkers` test helper added.
  - **Pending on-device validation (a real Mac + Wine/GPTK; not gating the commit):** R1 SteamSetup
    auto-launch black-window (forceQuit mitigation); **R2 `wine expand` member extraction**; R3 MSVC bug-57518
    (manual `msvcp140.dll`); R4 first-corefont bare EULA under Wine; R5 exact aka.ms redirect / SHS asset +
    OTF names; R6 MSVC DLL-override set.
- **🧹 Phase 0 — removed the DXMT Steam bottle; collapsed to a SINGLE "Steam" bottle (2026-07-10, `main`;
  `swift build` clean + zero warnings, `swift test` green serial + parallel, 351 tests).** First of a
  multi-phase restructure. The dual-Steam-bottle topology (a GPTK `SteamBottle` + a `SteamBottle-DXMT`, each
  its own Steam install/login) is gone — there is now ONE shared Steam bottle, GPTK-only for now, with no
  GPTK/DXMT tags on it. **DXMT the graphics *backend* stays** (manual/non-Steam games still pick it; the
  DXMT *runtime* is still installed via Settings → DXMT). Removed/collapsed:
  - `AppPaths.steamBottle(_:)` family → single no-arg `steamBottle`/`…ClientDir`/`…Exe`/`…CEFDir`/`…Log`;
    `"SteamBottle-DXMT"` dropped from `bottleDirNames`; `log(forAppID:backend:)` → `log(forAppID:)`.
  - `SteamApp.ID` composite `(appID,backend)` + `SteamApp.backend` → plain `id = appID`; discovery no longer
    tags a bottle backend. `GameID.steam(appID:backend:)` → `.steam(appID:)`. `GameConfig` un-keyed from
    backend (appID only; a legacy `backend` JSON key decodes-and-ignores — no data loss).
  - `AppEnvironment`: the per-backend `BackendServices` dict + `services(for:)` + `dxmtBottleVM`/
    `dxmtClientSession`/`dxmtSteamReady`/`gptkSteamReady` → one inlined `steamBottleVM`/`steamClientSession`;
    `steamReady` is the single gate.
  - `GameLibraryViewModel`: dropped `dxmtSession`, the cross-bottle co-residency guards
    (`activeSteamBackend`/`stopOtherSteamClients`/`activeBackend`/`runningBackend`), `steamInstalledBackends`
    set → `steamInstalled: Bool`, dual-bottle discovery + two-cards-per-title. `busyGames: Set<Int>`.
  - `SteamBottle`/`SteamClientSession`/`SteamBottleViewModel`: dropped the `backend` field, the sibling-seed
    fast path (`seedFromCompleteBottle`), and the cross-backend `SteamSetupGate` + "other bottle" wiring.
  - UI: the "Steam bottle (DXMT)" General-settings section, the whole DXMT-bottle onboarding step, and the
    GPTK/DXMT **backend tag on Steam cards** are gone; "Steam bottle (GPTK)" → just "Steam bottle"; the
    "Open Steam" toolbar is a plain button again. `DXMTManagerView` (runtime tab) kept. CLI `--setup-steam`
    is no-arg. A 32-bit Steam game (GPTK is 64-bit-only) now says "not supported yet" instead of steering to
    the removed DXMT Steam bottle.
  - Decisions (user): the whole optional DXMT onboarding section removed (runtime still in Settings → DXMT);
    an existing on-disk `SteamBottle-DXMT` is **left in place** (Silo just stops using it — no auto-delete).
  - Tests: dual-bottle/cross-bottle/seed/setup-gate cases (which asserted now-removed behavior) deleted;
    per-backend config + discovery cases rewritten to single-bottle; fallback-message assertions updated.
- **✨ Library status line is now transient — auto-dismisses (2026-07-08, `main`; shipped in 0.3.2).** The
  bottom status bar set `"Launched X."` once and never cleared it, so it lingered long after the game closed
  (the game card's running indicator cleared correctly via kqueue; only the status *text* was sticky).
  `setStatus` now schedules a self-clear (default 5s) and each new status cancels the prior message's timer,
  so a stale timer can never wipe a newer line (e.g. a graphics-fallback warning that legitimately replaced
  it). Scoped to the library bar; settings/manager panes keep their own `statusMessage`. +2 tests, 365 green.
- **🔁 Second adversarial sweep (post-0.3.0) — 8 more real bugs, all fixed (2026-07-08, `main`; serial +
  parallel green, 362 tests).** Prompted by "are there no more remaining fixes?" — a fresh three-lens review
  (ledger/gates, launch/co-residency, setup/readiness) that INCLUDED the just-shipped crash-orphan code found
  bugs file-local review missed. Commits `656f608`→`3ebcf11`:
  - **(HIGH) Durable ledger dropped an entry before confirmed death.** `terminateAllSync`/`stop`/`clear`
    removed optimistically right after a bare async SIGTERM — on a clean quit where the game outlived the
    signal, the next launch's gate saw no survivor → move/update over a live wineserver. Now removed ONLY on
    confirmed death (kqueue exit) or self-prune (once the PID is actually gone). The exact false-negative the
    ledger exists to prevent.
  - **(HIGH) Relocation vacuously "succeeded" when the current root was on an ejected drive** → persisted the
    new location + relaunched into an empty dir while the real bottles sat orphaned on the drive. Now refuses
    until `bottlesRootReachable`.
  - **(MED-HIGH) The gate was blind to in-flight work:** `isAnythingRunning` ignored the busy sets (a launch
    that claimed a bottle but hadn't spawned), and `anythingRunning` ignored a bottle mid-setup/warm-up. Both
    now count; the warm-up download client is also recorded in the ledger (crash-during-setup).
  - **(MED) Launches weren't blocked during a self-update** (ends in `exit(0)`, no teardown → orphan) and a
    move + update could overlap (both relaunch). `launchBlockedByBottles` now refuses during an update; the
    gate is mutually exclusive with a move/update in flight.
  - **(MED) openSteam/uninstall could race a cross-bottle `play` into TWO live Steam clients** (one account →
    Steam logs one out). `stop()` no-op'd against a client caught mid-spawn; it now cancels the in-flight
    launch and `startSteam` self-terminates if cancelled after the spawn.
  - **(LOW-MED) `makeShortcut` skipped the 32-bit-on-GPTK refusal** → a shortcut that launches to a
    wined3d-fallback failure with no steer. Now refused like `playManual`.
  - **(LOW) taskkill sibling-collision guard was case-sensitive** but wine's `/IM` isn't — `Game.exe` vs
    `game.exe` slipped through. Now case-folded.
  - **Verified sound (no change):** the `(pid, startTime)` reuse-proofing, the seed exclude-list + setup-gate
    (the two earlier user-found bugs can't regress), `ensureRunning` coalescing/readiness, ConfigStore
    recovery. Residual: a game that re-execs under a PID Silo never recorded still needs the on-device
    wineserver-lock probe (a Wine-verified handoff item).
- **🏛️ Architecture-level review before onboarding users — 4 themes, ~15 bugs, all fixed (2026-07-07, branch
  `gptk-path-review`; SERIAL + PARALLEL both green, 340 tests).** Three lifecycle-scoped adversarial reviewers
  (launch/co-residency, setup/discovery/onboarding, relocation/update/persistence) found cross-subsystem
  bugs that file-local review missed. Commits `62dde8f`→`093fbfc`:
  - **Theme A — co-residency was per-appID, must be per-backend.** `play`/`openSteam`/`uninstall` refused only
    the SAME title cross-bottle, but `stopOtherSteamClients` tears down the other bottle's client — so
    launching a DIFFERENT game in the other bottle killed a running game's Steamworks. Now
    `activeSteamBackend(excluding:)` refuses any cross-bottle Steam launch, checked+claimed before any await.
  - **Theme B — liveness was in-memory only; gates were start-only.** Per the user's call, quit (and
    self-update relaunch) now TEARS DOWN games + Steam clients (`terminateAllOnQuit`; retired the opt-in
    toggle), so nothing orphans and cross-session gates stay accurate. Update refused while anything runs;
    launches refused during a bottles move. **Crash-orphan residual now closed (2026-07-08)** by
    `ProcessLedger`: a crash-durable (pid, start-time) shadow of every process Silo spawns into a bottle
    (games + Steam clients). The relocation/update gate (`blockedForBottleWork`) also refuses while a PRIOR
    run's process is still alive; (pid, start-time) identity makes a reused PID never falsely block; fail-open
    + self-pruning; the durable probe runs only at the action gate, never a SwiftUI body. Remaining residual:
    a game that re-execs under a PID Silo never recorded (a wineserver-lock probe — needs Wine to verify).
  - **Theme C — "ready" was defined 3 ways; gates picked the weakest.** "Installed" now means the WARMED
    client (`hasWarmedClient`: steamui.dll + webhelper), not the bootstrapper; onboarding's GPTK step +
    `setupComplete` key on `gptkSteamReady` (DXMT-first can't mark GPTK done); removing a runtime reconciles
    `BackendConfig` (no sticky readiness against a deleted runtime); `refreshLibraryIfReady` re-syncs both ways.
  - **Theme D — ejected relocated drive** now shows a distinct `BottlesDisconnectedView` (not first-run
    onboarding); launches + `setUp` refuse when the root is unreachable (no phantom bottle on the boot disk).
  - **Bonus:** `BottlesRelocationCoordinator` uses the injectable app-bundle resolver, so relocation's
    `relaunch`/`exit(0)` no longer kills the SERIAL test run — the whole suite passes serially for the first
    time (the parallel `tee` had been masking failures). +co-residency/relocation/warmed-client tests.
  - **Sweep leftovers cleared (2026-07-08):** `taskkill /IM` basename collision FIXED (`stop` drops to a
    SIGTERM-only stop when a co-resident sibling shares the exe basename, else fires /IM); the crash-orphan
    residual FIXED (`ProcessLedger`, see Theme B); `terminateAllOnQuit` composition now has a dedicated test.
    Reviewed + consciously left: `strand-on-failed-delete` is already surfaced (removeManual /
    discardManualBottle show a Finder path); `isSharedSystemApp` is a documented LastOwner heuristic with no
    better single-manifest signal; `bottlesDisconnected` short-circuits to zero I/O in the default location
    and must stay live to detect drive ejection.
- **🐛 Adversarial correctness pass — 10 bugs fixed (2026-07-07, `swift build` clean + `Scripts/test.sh`
  green, +2 tests).** Two independent adversarial reviewers swept the GPTK bottle path for BUGS (not just
  rot). The GPTK core came back clean; the fixes (most-severe first):
  1. **Steam readiness race (GPTK, the one important core bug).** `SteamClientSession.ensureRunning` checked
     the `steamPID` fast path before joining an in-flight launch — so a 2nd Play during Steam cold-start
     returned "ready" before Steam had registered its `ActiveProcess` pid, and the game's `SteamAPI_Init`
     could lose to Steam's init. Now joins the in-flight launch (which owns the readiness wait) FIRST.
  2. **DXMT manual-game shortcuts never seeded `winemetal.dll` into the prefix.** `makeShortcut` called
     `makePlan` directly, bypassing `linkGraphics`/`installDXMTPrefixLoaders`; a shortcut made before any
     in-Silo launch produced a `.app` that fell back to wined3d and failed. New
     `LaunchOrchestrator.prepareGraphics` (launch-free graphics prep); `makeShortcut` now calls it. Test added.
  3. **Clone race + interrupted-clone reuse.** `RuntimeVariants.ensureClone` was check-then-act; two quick
     first-time DXMT launches could make the loser's copy-fallback hit EEXIST, and a hard-killed mid-clone
     left a partial tree later reused. Now clones into a `.cloning-<uuid>` staging dir published by atomic
     rename (loser reuses the winner's; a partial never becomes the clone).
  4. **GPTK importer leaked a mount** when `hdiutil attach` succeeded but the plist had no mount-point (the
     caller never received a URL to detach). `attach` now best-effort detaches the parsed `dev-entry`. Test added.
  5. **`overlayGPTK` partial-overlay masquerade.** A mid-copy failure could leave a fresh `d3d11.dll` (the
     witness) beside stale siblings, so the next launch's witness check wrongly skipped. Copy the witness LAST.
  6. **Webhelper wrap could strand a CEF dir** (real webhelper preserved as `_orig`, no `steamwebhelper.exe`)
     on a mid-op I/O failure → black login, no self-heal. Now stage-then-rename (byte copy first, swap by rename).
  7. **Stale `errno`** in the clone copy-fallback error message — now the underlying POSIX code, captured at
     the failure point.
  8. **`RuntimeManager.install` reinstall was non-atomic** — extracted in place and removed `dest` on a
     mid-extract failure (nuking an existing good install; also merged stale files on reinstall). Now extracts
     into a `.extracting-<uuid>` staging dir and publishes with an atomic rename.
  9. **`stripBundledSDL` only searched `lib/silo-bundled`** — a custom-repo runtime bundling libSDL2 elsewhere
     kept the winebus/SDL crash. Now walks the whole runtime tree.
  10. **`GraphicsFallbackMonitor` armed a kqueue watch even when the pre-check already fired** — now returns
      before arming, so no fd lingers.
  Ruled out after tracing: `stopGame`'s base-wine taskkill (correct — wineserver is prefix-keyed) and the
  double-overlay (harmless idempotent no-op). **Left as-is (documented):** the readiness kqueue watch on
  `user.reg` can miss an atomic rename-replace and fall back to the bounded 20 s failsafe — but it's
  on-device-validated as event-driven, degrades gracefully, and the only fix touches the shared `FileWatch`
  the log tailer also uses (wide blast radius for a case the evidence says doesn't occur).
- **🧹 GPTK-path quality pass — 5 review findings fixed (2026-07-07, `swift build` clean + `Scripts/test.sh`
  green, EXIT=0/"All tests passed").** A focused audit of the GPTK bottle path (deterministic core, launch
  pipeline, runtime pieces) found it largely clean; five items closed:
  1. **Dead pre-dual-bottle shims removed.** All five no-arg `AppPaths.steamBottle*` convenience vars
     (`steamBottle`/`ClientDir`/`Exe`/`CEFDir`/`Log`) dropped from the shipping type — four were unused in
     Sources, the one live caller (`GeneralSettingsView`) now passes `.gptk`; the four the test suite uses
     moved to `Tests/SiloKitTests/Support/AppPaths+TestSupport.swift`. Also removed the dead
     `RuntimeVariants.variantWine` (superseded by `prepare`/`ensureClone`; test-only) + its `cloneWine` helper
     and the now-orphaned test.
  2. **`ManualGame.gameConfig`** — the `GameConfig(appID: 0, …)` mapping was open-coded in two places
     (`LaunchOrchestrator.launchManualGame`, `GameLibraryViewModel.makeShortcut`); now one computed property.
  3. **Resolver output threaded explicitly.** `makePlan`/`launchInBottle`/`launchManualGame` gained an
     optional `wine:` param (defaults to `backend.wineBinaryPath`), so the VM feeds the resolved variant
     runtime directly instead of mutating a `BackendConfig` copy at three call sites; `linkGraphics` takes the
     wine explicitly too. Backward-compatible — every existing makePlan/pipeline test unchanged.
  4. **Test-only PID projections retired.** `GameLibraryViewModel.runningPIDs`/`manualRunningPIDs` (dictionary
     reshaping that existed only for the test suite) replaced by narrow `pid(for:)` accessors mirroring
     `isRunning`; the ~8 test sites migrated.
  5. **Doc fix:** `WineRuntimeLayout`'s no-arg `windowsModulesDir`/`unixModulesDir` were mislabeled
     "back-compat" — they're the live GPTK-x86_64-only overlay path (`overlayGPTK` uses them; `overlayDXMT`
     passes an explicit `WineArch`) — relabeled.
- **🖥️ High Resolution Mode: pair LogPixels with RetinaMode (2026-07-07, on-device validated).** The Retina
  toggle wrote only `HKCU\Software\Wine\Mac Driver\RetinaMode`, so turning it on made game/UI text render
  tiny (Wine renders at native backing pixels with no DPI compensation). That's the missing half of what
  CrossOver calls "High Resolution Mode" — it reports **192 DPI** alongside RetinaMode so the UI scales up to
  match. `WineTools.setRetinaMode` now writes the **coupled pair**: `RetinaMode` (y/n) **and**
  `HKCU\Control Panel\Desktop\LogPixels` (192/96), so retina is never tiny and the two can't drift; LogPixels
  is only ever written here (192 DPI on a non-retina bottle would just bloat the UI). Validated on-device in
  the DXMT bottle: Overcooked 2 runs on DXMT (feature level 11_1) crisp + legible. Two findings recorded:
  (1) **second monitor stays live in fullscreen** because Silo never enables `CaptureDisplaysForFullscreen`
  (Wine's default-off = non-capturing borderless fullscreen; capture=y is what blanks other displays).
  (2) **games must be launched via Silo, not the co-resident Steam client's Play button** — Steam runs on the
  BASE runtime with no DXMT override, so a game it spawns falls to wined3d → "None of the requested D3D
  feature levels" → `InitializeEngineGraphics failed` (see the `silo-steam-launch-gotcha` note).
- **🔎 Dependency + per-runtime audit vs AppleGamingWiki (2026-07-06) — two gaps closed, on-device validated.**
  - **Core fonts (dependency gap).** Wine ships no MS TrueType fonts (the bottle's `windows/Fonts` was
    empty), which the Wine-Steam community flags as blank/garbled text in the client UI + games. `setUp()`
    now installs Microsoft's redistributable "core fonts for the web" (the winetricks `corefonts` set,
    `Silo.coreFonts`) into BOTH bottles — downloaded from SourceForge's canonical mirror and extracted with
    **Wine's own IExpress `/T /C /Q`** (no cabextract/winetricks dependency; validated on-device →
    25 fonts: Arial/Times/Courier/Verdana/Georgia/Comic/Impact/Andale/Trebuchet/Webdings). Idempotent
    (`SteamBottle.hasCoreFonts` marker), best-effort per font, cleans up after itself.
  - **MetalFX was GPTK-only (per-runtime gap).** The per-game MetalFX toggle always emitted
    `D3DM_ENABLE_METALFX` — a no-op for a DXMT game. `EnvFlags.environment(graphics:)` is now backend-aware:
    GPTK → `D3DM_ENABLE_METALFX`, DXMT → `DXMT_METALFX_SPATIAL_SWAPCHAIN`. DXR stays GPTK-only (DXMT has no
    DX12/raytracing). `makePlan` passes the launch backend through.
  - **Verified already-correct:** GPTK env set complete (`ROSETTA_ADVERTISE_AVX`, `MTL_HUD_ENABLED`, DXR);
    `WINEMSYNC` (deliberately msync, not the wiki's esync — required for shared-bottle co-residency);
    per-runtime DLL overrides + D3DMetal-framework-in-DYLD (GPTK only) + cloned runtimes; Windows 10 both
    bottles; DXVK/VKD3D/Vulkan correctly N/A (Metal-direct); vcrun covered by Wine builtins + Steam's
    per-game installers. **Onboarding already lean** — the 3 steps map to 3 genuinely-required user actions
    (GPTK needs a manual Apple `.dmg`, can't be automated); no meaningful simplification available.
- **🩹 Steam-bottle warm-up: fold the first-run self-update into setup (2026-07-06, on-device validated).**
  Problem: after setup, the user's first Steam launch hit "failed to load steamui.dll", the second was a
  black login window, and only the THIRD reached login. Root cause: `SteamSetup.exe /S` installs only the
  ~2 MB bootstrapper; the real client (steamui.dll + CEF/steamwebhelper) self-downloads on first run, and
  the webhelper wrap races that download. Fix: `SteamBottleViewModel.setUp()` now runs a one-time **warm-up**
  (`SteamClientSession.warmUpUpdate`) that completes the download BEFORE the user's first launch, then wraps
  the webhelper against the now-existing CEF dir. Works for BOTH GPTK + DXMT bottles (setUp is shared),
  non-invasive (rootless `steam.exe`, no window pops up), with a real **progress bar** (parsed from Steam's
  `Downloading update (X of Y KB)` log). Validated on-device against the fresh DXMT bottle: 7.1 MB
  bootstrapper → **1.0 GB fully-installed client** (steamui.dll + wrapped webhelper), no rollback, no
  leftover processes. **The debugging took several real runs; each found a concrete bug** (recorded so the
  hard-won knowledge isn't lost):
  - `-silent` makes Steam start minimized and SKIP the first-run client download → dropped it (launch bare
    `steam.exe`, rootless).
  - "steamui.dll exists" fires MID-download (Steam extracts it early); shutting down then makes Steam roll
    the half-applied update all the way back. The reliable "done" signal is Steam's own **"Update complete"**
    log marker (a single launch does the whole download→install→commit).
  - Wine spams thousands of `msync_init Failed` lines that pushed Steam's progress lines out of any log
    tail → parse the WHOLE log (`SteamBottle.updateState`).
  - The bottle log lives OUTSIDE the client dir and persists across setups, so a stale "Update complete"
    fired completion instantly → `SteamBottle.resetLog()` at warm-up start.
  - `--setup-steam <gptk|dxmt>` CLI harness added (like `--import-gptk`) to run setup headlessly on-device.
  - Pending: on-device confirm the DXMT bottle's first real launch now lands on login (the whole point);
    commit is on `dxmt-dualbottle-fixes`. **Corefonts install (recommended follow-up) not yet done.**
- **🔧 Six dual-backend UX/correctness fixes (2026-07-06, branch `dxmt-dualbottle-fixes`, 5 commits,
  each `swift build` clean + `Scripts/test.sh` green; app assembles + smoke ok).** Reported from on-device
  use of the dual-bottle build. Note on the test gate: the parallel `Scripts/test.sh` `tee` can drop both
  `✔`/`✘` lines cosmetically, so each commit was ALSO verified with a full `swift test --no-parallel` run
  — the ONLY serial failure is the pre-existing, environment-dependent `installUpdateNoBundle`
  (`runningAppBundle()` resolves differently under `--no-parallel`; fails identically on `main`, unrelated
  to this work). Commits:
  - **A — runtime listings exclude DXMT variant clones; `remove()` cascades.** The DXMT variant runtime is
    an APFS clone `<base>-dxmt` created as a SIBLING in `Runtimes/` by `RuntimeVariants`; it carries both a
    wine binary AND the overlaid DXMT modules, so it surfaced in BOTH `installedWines()` and
    `installedDXMT()` (cross-listing the Wine + DXMT panes). `RuntimeVariants` now owns the ONE
    clone-naming source of truth (`cloneName(ofBase:backend:)` + `isVariantClone`, on `rawValue` not
    `badge`); both listings skip clones; a real `dxmt-*-cx*` tag is never flagged. `remove(name:)` cascades
    to the base's derived clone (dead weight once its base is gone — `ensureClone` keeps an existing clone
    forever). **Decision:** `setDefault` does NOT touch clones (re-derived per launch by `BottleResolver`).
  - **B — honest, backend-aware graphics-failure message.** The old "running on fallback graphics
    (wined3d)" implied Silo has a working fallback; it doesn't (the wined3d fallback is inside GPTK's own
    d3d11.dll and, for Overcooked-class titles, then fails device creation) and Silo deliberately has NO
    rerouting (deterministic backend⇔bottle rule). New pure, table-tested
    `graphicsFallbackMessage(name:backend:isSteamGame:dxmtAvailable:)`: a GPTK title is pointed at DXMT,
    adapting to whether the DXMT bottle/runtime is set up (read at detection time); a DXMT title admits the
    wined3d fallback likely failed → Settings → DXMT. `GraphicsFallback` doc comments corrected. Detection
    + the pure GPTK→D3DMetal launch path untouched.
  - **C — a title installed in BOTH bottles surfaces as two cards.** `load()` deduped by appID (first
    wins), hiding the second bottle's copy. Identity is now (appID, backend): `SteamApp.id` is a computed
    composite `ID{appID,backend}` (no persistence change) and `GameID.steam(appID:backend:)` carries the
    backend, so both cards render (each with its GPTK/DXMT `BackendTag`) and tracking/stop/monitors are
    per-copy. `play()` gains a cross-bottle guard BEFORE `stopOtherSteamClients` (never kill the running
    game's co-resident Steam; one account can't be in-game twice → explanatory status). **Busy/spinner is
    per-COPY** (`busyGames: Set<SteamApp.ID>`) so only the launching card's button spins — an earlier
    appID-keyed set made BOTH cards spin during a launch (fixed 2026-07-06); cross-bottle launch protection
    is separate via `activeBackend(ofAppID:)` (running OR mid-launch), so blocking the other copy no longer
    requires marking it busy. `uninstall()` routes `steam://uninstall` through the game's OWN backend
    session (the DXMT copy must reach the DXMT bottle's Steam). Per-game config/settings/log stay
    appID-keyed (shared; the copies can never run at once). **Known, out of scope (noted for a follow-up):**
    launching a *different* game in the other bottle still stops the first bottle's Steam client under a
    running game — pre-existing, orthogonal to this fix.
  - **D — both Steam bottles in Settings → General** ("Steam bottle (GPTK)" then "Steam bottle (DXMT)"),
    moved out of the DXMT tab. The DXMT tab is now runtime-only.
  - **E — ONE runtime-install flow for Wine + DXMT (kills the onboarding/settings duplication).** A
    `RuntimeKind` strategy (`.wine`/`.dxmt`: noun, download hint, release picker, installed-list, install
    fn) parameterizes a single `RuntimeViewModel`; a new `RuntimeInstall` value is the common shape of
    `WineInstall`/`DXMTInstall` for the VM + a shared `RuntimeInstalledSection` list row. `AppEnvironment`
    gains `dxmtRuntime` (matched to the configured wine at click time), wires its default to
    `applyDXMTLibDir`, seeds it in `bootstrap`; `downloadLatestDXMT`/`dxmtDownloading` deleted. The DXMT
    tab now mirrors the Wine tab (install latest / import folder / installed list with Set default +
    Remove); onboarding's DXMT step + status chain use `dxmtRuntime` with Wine's string templates.
    **Decision:** DXMT adopts-as-default only when none is set (Wine semantics, was always-adopt); first
    install still flips `dxmtReady` via `onDefaultChanged`. The convenience `RuntimeViewModel(manager:repo:)`
    = Wine kind, keeping every existing call site + test valid.
  - **Pending (needs a human / on-device):** a `Scripts/dev.sh` visual pass (both bottle sections in
    General; DXMT tab mirrors Wine; two cards for a dual-installed title; the honest Overcooked-2 message);
    merge `dxmt-dualbottle-fixes` → `main`.
- **🧹 Full-project cleanup COMPLETE (2026-07-02, 3 tiers — robustness, dedupe, structure; 12 phases,
  each landed green).** Branch `dxmt-dual-bottle-backend` merged to `main` (ff); all phases on `main`.
  **Final verification:** `swift build` zero warnings, **305 tests green**, `Scripts/build-app.sh`
  assembles + ad-hoc-signs `dist/Silo.app`, `SILO_SMOKE=1` run passes, `git status` clean.
  Remaining (needs a human/on-device): a `Scripts/dev.sh` visual pass over the deduped views (library
  grid, both settings sheets, both bottle sections) + the next `build-wine` CI dispatch exercises the
  shared wrapper-check script. Phase log:
  - **Phase 0:** `.dxmt-build/` + `.dxmt-build-fullrun.log` gitignored (670 MB build artifacts).
  - **Phase 1:** `ConfigStore` recovery copy — every save refreshes `config.json.bak`; a
    present-but-corrupt primary restores the last good save (and self-heals the primary) instead of
    silently wiping all state. A *missing* primary still resets (deliberate).
  - **Phase 2:** swallowed errors surfaced. `DiscoveryEngine` distinguishes an *unreadable* primary
    library (`libraryUnreadable`, thrown) from the benign no-library-yet (`steamDirNotFound`, silently
    skipped); the library shows a per-bottle failure status (or `.error` when nothing else can show —
    LibraryGridView's error case is now reachable). `GameSettingsViewModel.save() -> Bool` +
    `errorMessage` (sheet only dismisses on success). A failed `lastPlayed` write after launch says the
    config is unwritable. `deleteBottle` failures say "remove it in Finder: <path>". `resolveMessage`
    maps the whole launch stack (exe-not-found / wineboot / DXMT-clone / linker-source-missing) to
    actionable text and all catch-sites route through it. 282 tests green.
  - **Phase 3:** correctness fixes. (1) **Manual-game shortcuts route through `BottleResolver`**
    (`GameLibraryViewModel.makeShortcut`, replaces `AppEnvironment.makeManualGameShortcut`) — a DXMT
    game's Desktop `.app` now snapshots the DXMT variant runtime + overrides instead of silently using
    the base/GPTK env; failures surface in the status bar. (2) Bottle tools (`setSteamBottleRetina` /
    `openWineTool`) take a `GraphicsBackend` (default `.gptk`) so the DXMT bottle can get Retina/winecfg
    (UI row lands with Phase 7's shared component). (3) `GameAppShortcut` writes atomically.
    (4) `deQuarantine` returns a `HardeningOutcome`; `RuntimeManager.lastHardeningIssue` +
    GPTK-import `onWarning` surface a failed de-quarantine/re-sign at install time ("Gatekeeper may
    refuse…") instead of a cryptic launch failure (new `LockedBox` Mutex util). (5) `LogTailer.start`
    creates/reads the log OFF the main actor (generation-guarded against stale arms). 287 tests green.
  - **Phase 4:** no more sync disk probes in SwiftUI body evaluation (bottles can live on a
    slow/disconnected external volume). `GameLibraryViewModel.steamInstalledBackends` = off-main cache
    (probed by `refreshSteamInstalled()`, called by every `load()`); `steamReady`/`steamInstalled(_:)`
    + `AppEnvironment.dxmtSteamReady` read it. `SteamBottleViewModel.steamInstalled` cached the same way
    (`refreshInstalled()` at bootstrap; `setUp` sets it). **Invalidation wiring:** `onSteamInstalled`
    fires after a fresh install → AppEnvironment reloads the library, so the onboarding gate flips
    without a relaunch (pinned by a wiring test — a missed invalidation would stall onboarding).
    290 tests green.
  - **Phase 5:** the co-residency sync rule (`WINEMSYNC=1`, strip `WINEESYNC`) now lives in ONE place —
    `Silo.enforceMsync` / `msyncWineEnvironment` — adopted by all five sites that each rebuilt it
    (`makePlan`, `stopGame`, `runWineTool`, `WineTools.environment`, `SteamBottle.steamEnvironment`).
    Zero behavior change (pinned by the exact env assertions across those suites). 292 tests green.
  - **Phase 6:** `GraphicsLinker` mechanics dedupe — `isGPTKModule`/`isDXMTModule` parameterize one
    `isOverlayModule(_:prefixes:)`; the witness idempotency check and the per-dll+`.so` copy loop are
    shared (`witnessMatches`, `copyModules`). SEMANTICS untouched: GPTK keeps its exact choreography
    (pre-witness framework-link self-repair → copy → re-link; no `wineWinDir` creation), DXMT keeps its
    dir creation. Pinned by the idempotency/self-repair/symlink suites + new direct helper tests.
    294 tests green.
  - **Phase 7:** view dedupe. `GameTileCard` = the one library-tile chrome (artwork band, three-state
    Play/Launching/Stop button, menu, hover treatment) — Steam + manual tiles now inject only their
    artwork/subtitle/menu/confirmations. `PerformanceFlagsSection` + `LaunchOptionsSection` shared by
    both settings sheets (manual sheet gains the guidance footers). `SteamBottleControls` = the one
    Setup/Launch/Reset-login/log block for the GPTK + DXMT settings sections; the **DXMT section gains
    a Repair row** (winecfg/regedit/control on the DXMT bottle, the Phase-3 backend-aware tools) and
    the **Retina toggle now writes the registry key into EVERY installed bottle** (one preference, both
    bottles consistent). No view tests per repo convention; logic unchanged (VM suites). 294 green.
  - **Phase 8:** scripts dedupe. `Scripts/check-webhelper-wrapper.py` = the ONE load-bearing CEF-flag
    guard (was duplicated between `build-wine.sh` and `build-wine.yml` — a drift there ships a broken
    Steam login); verified on synthetic pass/fail PEs. `Scripts/bootstrap-x86-brew.sh` = the shared
    Rosetta + x86_64-Homebrew bootstrap for `build-wine.sh` + `build-dxmt.sh`. `bash -n` + YAML-parse
    clean; CI proper validates on the next workflow dispatch. Toolchain pins untouched.
  - **Phase 9:** `GameProcessCoordinator` — the live-process bookkeeping (PIDs, kqueue exit observers,
    graphics-fallback monitors) moved out of `GameLibraryViewModel` into SINGLE tables keyed by
    `GameID{.steam(appID)|.manual(uuid)}`, replacing the four parallel Steam/manual dictionaries + 8
    observe/exit/clear/watch methods. The VM's public API (`isRunning`/`isBusy`/`isAnythingRunning`/
    `terminateAllSync`) is unchanged (zero view edits); `runningPIDs`/`manualRunningPIDs` remain as
    computed projections so the 507-line VM test suite passed UNMODIFIED. New coordinator tests pin the
    pid-match stale-exit guard, re-track cancellation, clear-stops-monitor, and exact-PID terminate.
    300 tests green.
  - **Phase 10 (a/b/c):** AppEnvironment decomposition, three green commits. **(a)** `BackendServices`
    = one keyed bundle (bottle + client session + settings VM) per `GraphicsBackend`, built in a loop
    (killing the gptk/dxmt construction copy-paste); pre-bundle names kept as computed forwards so
    views/tests were untouched. **Bonus fix:** `anythingRunning` now checks EVERY backend's session —
    a live DXMT Steam client blocks bottle relocation like the GPTK one. **(b)** `UpdateCoordinator`
    (`env.updates`) owns the inline self-update flow + its state. **(c)** `BottlesRelocationCoordinator`
    (`env.bottles`, in Provisioning/ next to `BottleRelocator`) owns the move flow;
    relocation-via-relaunch design unchanged; `isBlocked` late-bound to `env.anythingRunning`.
    AppEnvironment is now ≈300 lines of composition + thin orchestration. 301 tests green.
  - **Phase 11:** `RuntimeVariants` direct tests (the one real coverage gap): GPTK prepares in place
    (no clone), DXMT clones to `<root>-dxmt` + overlays the CLONE only, an existing clone survives
    re-prepare (idempotency — a re-clone would wipe in-clone state), `variantWine` is pure path math.
    305 tests green.
- **🩹 Two follow-up fixes (2026-07-05):**
  - **Runtime install no longer ad-hoc re-signs.** The install hardening ran `codesign --force --sign -
    --deep <runtime-dir>`, which ALWAYS failed (`bundle format unrecognized` — a runtime root is a plain
    `bin/lib/share` tree, not a bundle) and surfaced a scary "couldn't re-sign… Gatekeeper may refuse"
    warning after the cleanup made hardening report its result. Re-signing is also unnecessary: the
    runtimes are x86_64 (run unsigned under Rosetta) and GPTK's D3DMetal must keep Apple's signature.
    Removed the whole re-sign path (`reSign` param, the codesign branch, `HardeningOutcome.signed`,
    `RuntimeManager.harden`); `deQuarantine` now only strips `com.apple.quarantine` (the load-bearing
    step). Warnings now fire only on a genuine de-quarantine failure.
  - **`Scripts/test.sh` now fails when tests fail.** `swift test` under the CLT framework-search-path
    invocation printed Swift Testing failures but exited 0 on a full-suite run (verified Swift 6.3.3) —
    and `release.yml` gates publishing on this script, so CI could ship a broken build. test.sh now tees
    output and exits non-zero if any `✘` failure line appears OR swift test itself errors. Verified: clean
    → exit 0, deliberate failure → exit 1.
- **🪟 Settings UX pass (2026-07-05):** DXMT is now its own **runtime tab** (`DXMTManagerView`)
  alongside Wine + GPTK — Settings tabs are General · Wine · GPTK · DXMT. The whole DXMT concern
  (runtime download/import + its Steam bottle + repair tools) moved out of the General tab into the
  DXMT tab, so General is just the primary Steam bottle, bottle tools, bottle location, and updates.
  Trimmed explanatory captions across onboarding + settings (kept labels, status/error messages, and
  warnings) to cut visual clutter. 305 tests still green; app assembles + smoke ok.
- **🧩 DXMT as a second graphics backend — dual-bottle feature built end-to-end (2026-06-30, 267 tests green).**
  Reverses the GPTK-only stance (and M87's DXVK removal) per the user's design; `CLAUDE.md` "Graphics
  backends" rewritten to match. Branch `dxmt-dual-bottle-backend`. **Done + green:**
  - **Deterministic core (backend ⇔ runtime ⇔ bottle):** `GraphicsBackend{gptk,dxmt}` = single source of
    truth (per-backend `dllOverrides`/`overlaysExternalFramework`); `makePlan` emits exactly one backend's
    builtin set (determinism test: DXMT never leaks GPTK's). `GraphicsLinker.overlayDXMT`. `RuntimeVariants`
    (GPTK in place; DXMT = APFS clonefile clone + overlay) + `BottleResolver` (the one `(game,backend) →
    {prefix,wineBinary,graphics}` dispatch; refuses an unconfigured secondary backend).
  - **Models:** `ManualGame.backend` (tolerant decode) + `SteamApp.backend` (discovery-derived).
  - **Manual games:** `playManual` → resolver → a DXMT manual game runs on its cloned DXMT runtime in its
    own bottle. Backend picker in Add-a-Game + settings.
  - **Two Steam bottles:** `AppPaths.steamBottle(_:)` → `SteamBottle` (GPTK) / `SteamBottle-DXMT`.
    `SteamBottle` + `SteamClientSession` are backend-aware; `AppEnvironment` runs a GPTK + a DXMT bottle/
    session. `play/stop/openWinecfg` route by `game.backend` (DXMT Steam game → DXMT bottle on `/wine-dxmt`,
    only that bottle's client online). Discovery scans BOTH bottles, tags each game. Steam clients run on
    base wine (CEF; the co-resident game picks the variant — shared wineserver). **No login sync** (machine
    tokens are per-prefix → sign into each bottle once, by design).
  - **UI:** per-card backend tag on EVERY library card (Steam + manual); onboarding "Older games (DXMT) —
    optional" section + a General-settings DXMT section. `GraphicsFallback` backend-aware.
  - **DXMT runtime delivery:** **auto-download** from Silo's Releases (`AppEnvironment.downloadLatestDXMT`
    → `RuntimeManager.installDXMT`, reusing the Wine downloader engine — SHA-256 verify + extract +
    de-quarantine/ad-hoc-sign) OR manual folder import. One-click "Download…" in onboarding + Settings.
  - **Decision:** GPTK keeps the existing `SteamBottle` dir (no migration of the multi-GB prefix); DXMT is a
    sibling. Dropped the plan's `SteamBottle-GPTK` rename + `SteamLoginSync`.
  - **DXMT build — BUILDS on-device (macOS 26 Tahoe + Xcode 26.6, 2026-06-30):** `Scripts/build-dxmt.sh`
    (local) + `.github/workflows/build-dxmt.yml` (CI) build **DXMT v0.72 from upstream `3Shain/dxmt`** (the
    version CrossOver 26 bundles) against the published `wine-cx-*` CrossOver Wine, via DXMT's canonical
    Meson build, x86_64 to match the Wine. Full `meson compile` succeeds; `dxmt.tar.xz` (6.5 MB) ships
    `x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll` + `x86_64-unix/winemetal.so` (all builtin) — the
    exact tree `importDXMTRuntime`/`overlayDXMT` expect. Pins in `versions.env`. Real bugs fixed while
    validating:
    - **Toolchain:** llvm-mingw (clang) is REQUIRED — v0.72 doesn't compile with Homebrew GCC-mingw (tested:
      `std::setfill`/libc++ deps). It's DXMT's own pinned, intended toolchain.
    - **Native clang:** pin `/usr/bin/clang -arch x86_64` via a meson native file — llvm-mingw/llvm@15 both
      ship a bare `clang` that shadowed the Apple clang → `ld: library 'System' not found`.
    - **Metal:** Xcode 26 ships `metal` but its toolchain is a separate ~688 MB component; fetch it + probe
      an actual compile (a `-f metal` check is insufficient).
    - **Layout:** `-Dwine_builtin_dll=true` (v0.72 defaults false → d3d in system32); package the
      `x86_64-windows` + `x86_64-unix` sibling dirs.
  - **Decision:** GPTK keeps the existing `SteamBottle` dir (no migration of the multi-GB prefix); DXMT is a
    sibling. Dropped the plan's `SteamBottle-GPTK` rename + `SteamLoginSync`.
  - **PENDING (final on-device):** publish `dxmt-v0.72-cx26.2.0` (build-dxmt chained off wine-autoupdate, or
    `gh release`), Download it in Silo → Settings → DXMT, then confirm DXMT renders Overcooked 2.
- **✨ Tier-1 features from the Whisky study (2026-06-30, 239 tests green).** Five features mined from
  Whisky (the closest analog launcher) + Apple's GPTK materials, each with tests:
  1. **Retina/HiDPI toggle** for the Steam bottle (`WineTools.setRetinaMode` → `HKCU\…\Mac Driver\RetinaMode`;
     persisted in `BackendConfig.retinaMode` with a tolerant decoder so old config never wipes). Settings →
     General → "Bottle tools". The standard fix for wrong-sized game windows.
  2. **Wine repair tools** (winecfg / regedit / Control Panel + "Reveal Bottle in Finder") — escape hatch to
     fix a prefix by hand. Routes through the existing `LaunchOrchestrator.runWineTool`, which gained
     `WINEMSYNC=1` (shares the bottle's wineserver, no 2nd-server fork — also fixes the existing callers).
     `WineTools` is now registry-only (no duplicate tool-launcher).
  3. **Structured launch-log header** (`LaunchPlan.logHeader`, pure): every launch log opens with the
     resolved exe/args/cwd/env (sorted), written before spawn → a black-window report is self-explanatory.
  4. **Opt-in kill-on-quit** (Settings toggle, default off): `RootView`'s `willTerminate` hook →
     `GameLibraryViewModel.terminateAllSync` SIGTERMs only the games Silo launched, never the co-resident
     Steam client (test-verified).
  5. **PE icon extraction for manual games** (`PEIcon`, clean-room PE/.rsrc/.ico parser, bounds-checked):
     manual (non-Steam) games now show their `.exe`'s real icon in the grid (parsed off-main, cached). Steam
     games keep cover-art.
  6. **Game-Mode `.app` shortcut** for manual games (`GameAppShortcut`): "Create Desktop Shortcut" writes a
     standalone `.app` (categorized `public.app-category.games` → macOS Game Mode) that execs wine directly
     with a snapshot of the real launch env. Steam-game shortcuts deferred (need co-resident orchestration).
  Verified earlier vs Whisky: its `WINEESYNC`-under-msync quirk is GONE in GPTK 4 (NOT adopted); skipped
  DXVK/winetricks/custom-registry-UI/CLI per Silo's constraints.
- **🟢 GPTK D3DMetal CONFIRMED working — it IS Silo's active graphics path (2026-06-30).** Decisive
  on-device positive control: **We Were Here (582500)** launched co-resident under GPTK with verbose
  logging renders **D3D11 through D3DMetal**, proven by THREE independent signals (not a single-signal
  overclaim): (1) `d3d11.dll` + `dxgi.dll` load as **`builtin`** (GPTK's overlaid DLLs, not the native
  wined3d redist copies); (2) its Unity `Player.log` reports `Direct3D 11.0 [level 11.1]`, adapter
  **"AMD Compatibility Mode (ID=0x66af)"** — D3DMetal's signature fake adapter (wined3d-on-MoltenVK would
  report "Apple M4 Pro"); (3) **ZERO** wined3d/Vulkan/dlopen/feature-level signatures across 405 verbose
  lines (wined3d ALWAYS prints `err:winediag:…Using the Vulkan renderer` — absent). So the M83 "Bloons
  renders" gate is **vindicated**, the `GPTK-4.0_beta_1` + `wine-cx-26.2.0` pairing works, and the
  dlopen-layer fix (`linkD3DMetalFramework` symlink, self-repairing) holds.
  - **"How did wined3d slip in?" — it didn't.** wined3d lives *inside Apple's GPTK `d3d11.dll`* (built
    from wine d3d11 source + a D3DMetal backend + a `unix_call_fallback`). Silo is GPTK-only (DXVK removed
    M87) and never added a wined3d path. The fallback is GPTK's own, triggered only when a specific game's
    D3DMetal device-creation fails.
  - **Overcooked! 2 is a GAME-SPECIFIC exception, not a global failure.** Its `D3D11CreateDevice` via
    D3DMetal fails (opaque — inside closed GPTK; `d3dm_print`/os_log give nothing), so GPTK's d3d11 falls
    to its internal wined3d → `None of the requested D3D feature levels is supported` → "failed to
    initialize graphics." We Were Here (same Unity/D3D11 family) succeeds, so this is Overcooked-specific.
    **Prime lever: a different / non-beta GPTK version** (user can supply other `.dmg`s) — the beta likely
    matters for this class. RULED OUT for the global path: arch, native-redist shadowing, Metal-unavailable,
    dlopen. **Correction of my prior STATUS:** "device creation STILL fails (UNRESOLVED, casts doubt on
    whether GPTK renders ANYTHING)" was overgeneralized from Overcooked alone and is now disproven.
  - **Verbose wine logging for local builds (07c1c1e):** `Silo.wineDebug` = `+loaddll` locally, `-all`
    under CI (gated on `SILO_QUIET_WINE`, set by `build-app.sh` only when `$CI`). `WINEDEBUG=-all` had been
    *hiding* the very fallback `fixme:winediag` signatures the `GraphicsFallback` guardrail keys on — so the
    guardrail can now actually fire in dev. Shipped app stays silent automatically.
  - **Guardrail (shipped, working):** `GraphicsFallback` + `GraphicsFallbackMonitor` surface "GPTK didn't
    engage — fallback graphics" for the failing class instead of a silent "Launched". 224 tests green.
  - **GPTK 4 best-practice investigation (2026-06-30, read Apple's docs + cloned `apple/game-porting-toolkit`).**
    Key correction to the premise: **GPTK 4 is a NATIVE-Metal-porting toolkit** (AI agent skills + Metal
    Shader Converter + metal-cpp + native samples; prereqs macOS 27 / Xcode 27). The Windows-game
    "evaluation environment" (the D3DMetal that Silo overlays) is positioned as a **developer triage/eval
    tool**, not a documented end-user runtime. The repo has **ZERO** Wine/D3DMetal launcher-integration
    guidance (grepped the whole tree) — the only launch-env vars Apple documents are Metal-level
    (`MTL_HUD_ENABLED`, `MTL_HUD_LOG_ENABLED`, `MTL_CAPTURE_ENABLED`). So there is **no Apple reference
    implementation to "match"** for Silo's overlay-into-CrossOver-wine approach; Silo's launch env already
    matches the de-facto launcher standard (WINEPREFIX iso, WINEMSYNC, `ROSETTA_ADVERTISE_AVX=1` default-on,
    DYLD→lib/external, builtin d3d overrides, the D3DMetal.framework symlink) and is **proven working**
    (We Were Here). Overcooked-class device-creation failures are **D3DMetal's own feature/format limits**
    (Apple's `debugging-rendering-issues` skill flags Apple-GPU format gaps, e.g. `DXGI_FORMAT_D24_UNORM_S8_UINT`
    is not universally supported) — NOT a Silo implementation bug. Levers for that class: a different/non-beta
    **GPTK 4** build, or per-game Unity graphics args (`-force-feature-level-11-0` / `-force-d3d11-no-singlethreaded`).
- **🏷️ Release v0.2.1 (2026-06-29).** Patch over v0.2.0. (a) **Adversarial multi-agent quality audit**
  closed in four tiers — P0: readiness **TOCTOU** fixed (kqueue is edge-triggered; re-check after arming) +
  the M114 event-driven gate now tested **live** (`FileWatch` + readiness, previously never run with
  `readinessTimeout>0`); P1: `makePlan` exhaustiveness gaps (WINEDLLOVERRIDES `;`-merge, perf-flag
  propagation) + `BottleRelocator` failure paths (rollback, non-writable dest) covered, `play()` now
  surfaces a Steam-couldn't-start failure instead of launching against a dead client; P2: stale docs fixed +
  dead public surface removed (`installLocation`, `SteamBottle.isProvisioned`, `SteamStoreDetails.categories`
  /`.directXVersion`) + `KeyValuesParser` depth cap (no stack-overflow on hostile `.acf`) + manifest size
  guard; P3: PID maps encapsulated, denylist also strips `extra`, `..`-escape guard on relative exe, store
  fetch via `requireHTTPS`, new `RuntimeHardening`/`Filesystem` tests. **216 tests / 36 suites green; clean
  build.** (b) **GitHub Pages site** (`docs/`, Velox-style) — landing page at mikaelhug.github.io/Silo.
- **🏷️ Release v0.2.0 (2026-06-29).** Minor bump from 0.1.1 via `versions.env`. Highlights since 0.1.1:
  **manual non-Steam .exe games** (each in its **own isolated bottle**), **redistributables hidden**
  (`LastOwner==0`), **relocatable bottles** (move to another disk/external drive — % progress, exFAT guard),
  **versions.env single-source-of-truth**, **fully event-driven** (every sleep/poll removed; readiness via a
  kqueue watch on Steam's `ActiveProcess`), and a compact fixed-size **Settings** window. 202 tests / 32
  suites green; clean build (no warnings). Code/runtime production-quality (0% idle CPU, ~50 MB, no leaks);
  remaining ship-to-others gaps are on-device validation + notarization (human-gated), not code.
- **✅ M114 — removed every sleep/poll; readiness is now event-driven.** No fixed waits anywhere:
  - **Cold-start 10s grace → gone.** `SteamClientSession` now resolves the instant the co-resident Steam
    is ready via a **kqueue watch on the prefix's `user.reg`** for Steam's `ActiveProcess` pid (exactly what
    a game's `SteamAPI_Init` reads) — `SteamReadiness` (pure parse, unit-tested) + the reusable `FileWatch`.
    A cold launch waits only as long as Steam actually takes, not a flat 10s. The one remaining `Task.sleep`
    is a **bounded failsafe** (`readinessTimeout`, default 20s) that only fires if the signal never arrives
    (so a wrong signal can't hang a launch) — it is NOT the mechanism.
  - **Status auto-dismiss (6s) → gone:** the status bar shows the last action until replaced (no timer).
  - **Update-check spinner floor (700ms) → gone:** the spinner reflects the real check duration.
  - **Log-viewer throttle (150ms) → gone:** replaced with timer-free per-main-actor-turn coalescing (still
    event-driven, still coalesces bursts). Extracted `FileWatch` to `Support/` (shared by the log tailer +
    the readiness watch).
  - 202 tests / 32 suites green; clean build (no warnings); app reassembled.
- **✅ M112/M113 — single source of truth for versions (`versions.env`, Velox-style).** The app version was
  hard-coded in `Silo.swift` AND duplicated as a fallback in `build-app.sh`. Now `versions.env` (repo root)
  is the ONLY place a version is edited — `SILO_VERSION`, `SILO_GITHUB_REPO`, `CROSSOVER_VERSION` (the
  CrossOver FOSS wine-build input). `Scripts/gen-versions.sh` mirrors it into the committed (generated,
  DO-NOT-EDIT) `Sources/SiloKit/Versions.swift` (`Versions` enum); `Silo.version`/`updateRepo`/`wineRepo`
  read from it. `build-app.sh` regenerates + sources `versions.env` (dropped the grep + hard-coded version
  fallback); `build-wine.sh` defaults its CrossOver version to `CROSSOVER_VERSION`. A unit test fails if
  `Versions.swift` drifts from `versions.env` (verified). M113: scrubbed coincidental version literals from
  update test fixtures (arbitrary "current"/decoy-release versions that happened to equal the live one) so
  the live version lives ONLY in `versions.env` + its generated mirror. 197 tests / 31 suites green; clean
  build; app reassembled (the Info.plist version flows from the env).
- **✅ M111 — bottle move now has a progress bar + refuses exFAT/FAT.** Building on M109–M110:
  - **Progress bar.** `BottleRelocator` now does a byte-counting recursive copy for cross-volume moves
    (same-volume stays an instant rename) — preserves symlinks (a Wine prefix is full of them), sums total
    bytes up front, and reports a throttled `0...1` fraction. `AppEnvironment.bottlesProgress` drives a
    determinate `ProgressView` with a % label in Settings → Bottles (indeterminate spinner until the first
    fraction). Rollback unchanged (sources removed only after every dir copies).
  - **exFAT guard.** `Filesystem.isFATFamily` (via `statfs` `f_fstypename`) — `moveBottles` refuses an
    exFAT/`msdos`/`vfat` destination ("can't hold a Wine bottle, no symlink support — reformat as APFS / Mac
    OS Extended") rather than silently creating a broken prefix. Injectable check for tests.
  - 195 tests / 30 suites green; clean build (no warnings); app reassembled.
- **✅ M109–M110 — bottles are relocatable (move to another disk / external drive).** App state
  (config/logs/runtimes) stays under Application Support, but the **bottles** (Steam + every manual game's)
  now live under a configurable `AppPaths.bottlesRoot` (default = supportDir).
  - `BottlesLocation` persists the chosen root in a tiny file read SYNCHRONOUSLY at startup (`AppPaths.
    standard`), so every derived bottle path is correct from the first frame (M109).
  - `BottleRelocator` does a validated old→new move (writable + not-occupied checks; cross-volume
    copy+delete; best-effort rollback so it never half-relocates) (M109).
  - `AppEnvironment.moveBottles(to:)` / `resetBottlesLocation()`: refuse while anything's running, relocate
    off the main actor, persist, then **relaunch** to adopt the new root everywhere (AppPaths is injected
    by value). `anythingRunning` gate (M110).
  - UI: **Settings → General → Bottles** — shows the location (+ an "isn't reachable, is the drive
    connected?" warning when a relocated drive is ejected), **Move…** (folder picker → `<chosen>/Silo
    Bottles`), and **Reset to Default**; a spinner while moving (M110).
  - 193 tests / 30 suites green; clean build (no warnings); app reassembled.
- **✅ M107–M108 — each manual (non-Steam) game now runs in its OWN isolated bottle.** Steam games still
  share the one Steam bottle (Steamworks needs co-residency), but manual games no longer do — each gets a
  private Wine prefix at `~/Library/Application Support/Silo/ManualBottles/<uuid>` (own registry/drive_c/
  winecfg), so they can't pollute each other or Steam.
  - `WinePrefixProvisioner` (M107) = reusable `wineboot --init` for any prefix; `SteamBottle` delegates to
    it (DRY). `AppPaths.manualBottle(id)`.
  - VM (M108): `ensureManualBottle` (idempotent boot), play/install/stop/winecfg use `paths.manualBottle(id)`,
    `removeManual` deletes the bottle, `discardManualBottle` cleans up an unsaved draft.
  - UI: **Add Game** provisions the game's bottle (installer runs into it; a "Setting up…" spinner; Cancel
    discards a draft bottle). Manual settings sheet gains a **Bottle** section ("Run Installer in this
    bottle…", "Show bottle in Finder"); the tile's Wine Config opens the game's own bottle.
  - 187 tests / 29 suites green; clean build (no warnings); app reassembled.
- **✅ M101–M105 — non-Steam (.exe) games + hide Steam's redistributables.** Two core-app changes:
  - **Redistributables no longer surface as a game (M101).** Root cause: discovery parsed every
    `appmanifest_*.acf`; "Steamworks Common Redistributables" (228980) looks like a normal manifest. The
    principled signal (verified on-device): Steam auto-installs shared packages with `LastOwner == 0`,
    while user-owned games carry the owner's SteamID64. `SteamApp.isSharedSystemApp` + a DiscoveryEngine
    filter — not a name match. (An exe-presence heuristic would wrongly drop real games like Split Fiction,
    whose exe is nested.)
  - **Add non-Steam .exe games (M102–M105).** New `ManualGame` model persisted in `config.json`
    (backward-compatible tolerant decoder so a new key never wipes existing config); `LaunchOrchestrator.
    launchManualGame` + `runInstaller` (reuse `makePlan`, which lost its long-dead `app:` param); a
    UUID-keyed manual run-state in `GameLibraryViewModel` (Steam path untouched); and the UI: an
    **Add Game** wizard (Run Installer → Choose .exe → Add), `ManualGameTileView`, and a manual settings
    sheet. Manual games launch in the shared bottle prefix under GPTK without needing Steam.
  - 184 tests / 28 suites green; clean build (no warnings); app reassembled. Commits M101–M105.
- **✅ M100 — polished, stateful Updates UI in Settings → General.** Replaced the bare
  version/button/text rows with one self-contained status row that morphs between states (a `Phase` enum
  → icon + tint + title + subtitle + action): **Check Now** shows an animated spinner (held for a ~700 ms
  minimum so the loading always reads as deliberate), then the result cross-fades in — a green
  ✓ "You're on the latest version" or an accent ↓ "Version X is available" with a prominent **Update &
  Relaunch** button; install progress (downloading/installing) and a ⚠ failed+Retry state share the same
  row. Smooth (`.smooth(0.32)`) animation + `contentTransition(.opacity)` on the text + a scale/opacity
  transition on the icon. Mirrors the Wine tab's "load → result surfaces" flow. Dropped the now-redundant
  `AppEnvironment.updateMessage` (the view derives all copy from `updateCheck`). 175 tests green; clean build.
- **✅ M99 — code-rot sweep after the settings reshape (M94–M98).** Audited every file the settings
  reshaping touched. Removed **dead code**: `PathPickerRow` (the manual-paths picker, orphaned when the
  "Advanced (manual paths)" disclosure was dropped) and `BackendSettingsViewModel.isConfigured` (declared,
  never read). Fixed **stale references**: a user-visible onboarding string and a doc comment still said
  "Advanced → …" (now "Settings → General"); a leftover duplicate doc line called the Settings window "a
  sheet (Wine/GPTK paths)"; and "Wine Manager" / "GPTK Manager" doc mentions across `RuntimeViewModel`,
  `BackendSettingsViewModel`, `BackendConfig`, `WineInstall` (+ a test) now say "the Wine/GPTK settings
  tab". Dropped the stale "experimental" framing on `SteamBottleViewModel`. Verified all readiness flags,
  VM members, and picker helpers are still live. 175 tests green; clean build (no warnings).
- **✅ M98 — dropped settings explanatory footers + "already latest" update message.** Removed the
  descriptive footer `Text` under **Steam bottle**, **Updates** (General tab), **Wine**, and **GPTK** —
  the sections speak for themselves. Added an "already latest" confirmation to the app updater: a manual
  **Check for Updates** (or the bootstrap auto-check) now sets `AppEnvironment.updateMessage` to "You're on
  the latest version (X)" when current (nil when an update is available — the install button says it — or on
  offline), shown under the Check button. Mirrors the Wine tab's "already installed" message. 175 tests
  green; clean build (no warnings).
- **✅ M97 — Wine "install latest" no-op when current + a manual update check.** (1) `RuntimeViewModel.
  installLatest` now short-circuits when the newest published Wine is already installed — instead of
  re-downloading the ~250 MB build it reports "Latest Wine (X) is already installed" (and adopts it as
  default if none set). (2) Added a **"Check for Updates"** button to Settings → General → Updates
  (`AppEnvironment.checkForUpdate` + `isCheckingForUpdate`) so the user can re-check on demand, even though
  bootstrap still checks automatically. +2 tests → 175 / 28 suites green; clean build (no warnings).
- **✅ M96 — Settings tabs restructured to General / GPTK / Wine.** The Settings window now has three
  top-level tabs: **General** (the former Steam-bottle pane, with the app version + inline updater moved to
  a "Updates" section at the bottom — `GeneralSettingsView`, renamed from `BackendSettingsView`), **GPTK**
  (`GPTKManagerView`), and **Wine** (`WineDownloadView`). Removed the combined "Runtimes" tab + its
  `WineManagerView` wrapper (the GPTK/Wine segmented sub-tabs are now top-level tabs), and the standalone
  `UpdatesView` (folded into General). 173 tests / 28 suites green; clean build (no warnings).
- **✅ M95 — UI refinements (6 changes).** (1) Renamed "Advanced Settings" → **Settings** and made it the
  standard macOS **Settings window** (app-menu "Settings…" / ⌘, via a `Settings` scene + `openSettings`;
  the Library toolbar gear now opens it). Tabs: **Steam Bottle**, **Runtimes**, **Updates**. (2) Removed the
  Status section (Ready-to-launch / Default Wine / Default GPTK) and (3) the "Advanced (manual paths)"
  disclosure + the now-vestigial Save button from `BackendSettingsView` (it's just the Steam-bottle pane
  now). (4) **Removed the experimental HW-accelerated Steam UI** entirely (`cefHardwareArgs` /
  `hardwareAccelerated` everywhere) — on-device it only black-screened, confirming the ANGLE-D3D11-under-GPTK
  limit. (5) **Fixed the GPTK Runtimes list showing wine runtimes** — the M83 overlay copies
  `D3DMetal.framework` into the wine runtime's `lib/external`, so `GPTKImporter.installed()` matched it;
  now excludes any dir with a wine binary. (6) **Fixed the updater offering a Wine version as an app
  update** — it queried `/releases/latest` (often `wine-cx-*`); now fetches the release list and considers
  only the app's own `v*` releases (`isAppRelease`). 173 tests / 28 suites green; clean build.
- **✅ M94 — UI: single-pane Library + consolidated Advanced Settings.** Removed the sidebar entirely
  (`RootView` is now just `NavigationStack { LibraryGridView() }`); deleted `SidebarView`/`SidebarItem` and
  the **About** pane. **Advanced Settings** (Library toolbar → gear) is now a `TabView`: **Backend** (the
  former `BackendSettingsView`), **Runtimes** (the former Wine Manager — GPTK + Wine tabs), and **Updates**
  (new `UpdatesView` = version + the inline updater, replacing About). Update availability also surfaces as
  a small "· Update vX.Y.Z available" note to the right of the "X games" subtitle. 173 tests / 28 suites
  green; clean build. (Pending: a real Steam logo for the Steam button needs a bundled asset — SF Symbols
  has none and I won't fabricate Valve's mark; kept the SF Symbol for now.)
- **✅ M93 — unify the live Steam client under one owner (fixes the double-spawn bug).** The bottle's
  Steam client had TWO uncoordinated owners: `GameLibraryViewModel` tracked it (PID + coalescing +
  cold-start grace), while `SteamBottleViewModel.launchSteam` spawned its OWN untracked copy — so clicking
  Advanced → "Launch Steam" then Play on a game could start a second client (the Library's `steamPID` was
  still nil). Extracted **`SteamClientSession`** (`@MainActor @Observable`) as the single owner of the live
  client: PID tracking, launch coalescing, cold-start grace, the experimental HW-accel flag, and
  `ensureRunning()`/`sendURL()`. Both view models now route through it (Library `openSteam`/`play`/install/
  uninstall and settings `launchSteam` → `session.ensureRunning()`), keeping their distinct roles
  (operational library vs setup/admin) but with ONE tracked client. New test proves the cross-VM case
  (settings launch + Play → exactly one client). 173 tests / 28 suites green; clean build (no warnings).
  (This was the architecture finding I'd deferred at M88; safe to do now with M89's coalescing coverage.)
- **✅ M92 — Phase 5: hardware-accelerated Steam bottle (experimental opt-in path; on-device test needed).**
  Important framing first: **games launched from the bottle are ALREADY hardware-accelerated** — GPTK
  D3DMetal, proven on-device (Bloons TD 6, M83). Only the **2D Steam *client* UI** is software-rendered
  (SwiftShader), a deliberate CEF black-window workaround. That workaround predates the **M83 overlay** that
  made GPTK's D3D11 actually work, so CEF's GPU path (ANGLE→D3D11→D3DMetal) *might* now render where it
  couldn't before. Added an **opt-in experimental HW path** to test that:
  - `SteamBottle.cefHardwareArgs` + `steamEnvironment(hardwareAccelerated:)` — enables CEF's GPU process
    (`--use-gl=angle --use-angle=d3d11`, drops `--disable-gpu`/`--use-gl=swiftshader`/`STEAM_DISABLE_GPU_PROCESS`)
    and points the DYLD fallbacks at the runtime's overlaid D3DMetal (same wiring a game launch uses) so
    ANGLE's D3D11 can reach Metal. Default launch stays software (verified).
  - Toggle: **Advanced Settings → Steam bottle → "Hardware-accelerated UI (experimental)"**, then Launch Steam.
  - **Honest caveat:** our own GeoGuessr/Electron test showed ANGLE's D3D11 backend FAILS under GPTK
    (`eglInitialize D3D11 failed`) even post-overlay, so this may still black-screen; and even if it renders,
    the surface may not present. It's opt-in precisely so it can't break the working software default.
  - 172 tests / 28 suites green; clean build; `dist/Silo.app` reassembled.
- **✅ M91 — Phase 4 performance review (agentic).** 4 lenses (UI re-layout, main-actor blocking,
  redundant work, I/O) → skeptical verify → only 3 real worth-doing fixes (the codebase was already
  perf-clean since the 100%-CPU fix + polling removal): (1) roomier `URLCache.shared` (32 MB mem / 128 MB
  disk) so library cover-art is a cache hit on scroll-back, not a re-fetch; (2) hoisted `GameLibraryVM.
  filtered` to compute the filter+sort ONCE per `LibraryGridView` body (was twice — subtitle count + grid);
  (3) `LogTailer` now coalesces log-file write bursts to ~7×/sec (trailing throttle) so a noisy launch
  doesn't re-lay-out the 256 KB monospaced log Text on every kqueue event. No fix-now/high findings.
  171 tests / 28 suites green; clean build (no warnings).
- **✅ M90 — Phase 3 security hardening (agentic adversarial review, 14 findings).** 4 threat lenses
  (download/execute integrity, archive extraction, process-exec injection, error/failure modes) →
  exploitability verification → applied 8 hardenings:
  - **CRITICAL — in-app updater had ZERO integrity check** before replacing+executing the running app.
    Added fail-closed **SHA-256** verification of the release `.zip` against a published `<asset>.zip.sha256`
    (release.yml now ships it) + **https-only** download guard. (App is ad-hoc signed → no Developer-ID/spctl
    to pin; this defeats MITM/CDN tampering. **Defeating a *compromised release* needs notarization** — see
    BLOCKED.)
  - **HIGH — path traversal** via an attacker-named release tag flowing into a `Runtimes/` path: added
    `safeRuntimeComponent` sanitizer + a `runtimesDir`-containment assert; **HIGH — runtime SHA-256 now
    mandatory** (fail-closed) for the built-in `Silo.wineRepo` (was best-effort-skip).
  - https-only guard on all release-derived downloads (+ `NSAppTransportSecurity` ATS dict, default-deny);
    appmanifest `installdir` path-escape validation; **scrub `DYLD_INSERT_LIBRARIES`/`DYLD_FORCE_FLAT_NAMESPACE`**
    from inherited env for wine children; crash-safe staged GPTK import; honest checksum UI copy.
  - Shared `FileDigest.sha256` + `DownloadGuard.requireHTTPS`. +10 tests → **171 / 28 suites green**; clean build.
- **✅ M89 — Phase 2 test-coverage gaps (agentic, +49 tests → 161).** 4 domain mappers (orchestration,
  error/edge, graphics/runtime, parsing/models) → adversarial verify (real gap + catches a real bug, not
  coverage theater) → 25 verified gaps filled. New: `AppEnvironment.installUpdate` orchestration (no-bundle
  `.failed` + not-newer no-op), `applyBackend` fan-out, full `SteamBottleViewModel` suite, `GameLibraryVM`
  stop/uninstall-guard, and error branches across `Updater`/`RuntimeManager`/`GPTKImporter`/`ConfigStore`/
  `SteamBottle` (download/unpack/replace/wineboot/checksum failures + corrupt-config fallback), plus
  parser/Codable edges (`SteamPresenceStrategy` unknown-case, `EnvFlags` legacy migration + round-trip,
  `AppManifestDecoder`/`LibraryFoldersDecoder`). Test-infra only: `FakeProcessRunner` real terminate +
  incrementing PIDs; `FakeURLProtocol` per-session stub scoping (fixes a shared-registry race). No
  production code touched; **no production bugs found** (all assert existing behavior). 161 tests / 28
  suites green; clean build.
- **✅ M88 — Phase 1 architecture review (agentic, 8 verified fixes).** 4 cross-file lenses (boundaries,
  abstraction value, dependency direction, concurrency-fit) → adversarial verify → 12 actionable, applied
  the 8 safe ones: deleted the vestigial **`BackendResolver`** (it adopted an installed Whisky/CrossOver
  runtime — contradicts #8) + its `detectedSource`; `ProcessRunning.observeExit` now required (dropped the
  dead Noop default that could silently swallow game-exit); propagated the injected runner into `Updater`
  (closed a test-seam leak); removed `AppEnvironment.logTarget` view-type leak; added
  `ConfigStore.updateGame` field-scoped transaction (fixes a `lastPlayed` lost-update vs a concurrent
  settings save); consolidated the backend-config fan-out (`applyBackend` + `applyDefaultWine/GPTK`);
  extracted **`WineRuntimeLayout`** (one home for runtime FS-layout math, mirrors `PrefixLayout`). Stale
  CLAUDE.md actor list fixed. **Deferred** (flagged, regression-risky on validated CEF code): unify the
  Steam-client lifecycle (two VMs own it → possible double-spawn) and an `UpdaterViewModel` extraction.
  112 tests / 25 suites green; clean build (no warnings).
- **✅ M87 — removed the dead `.crossover`/DXVK backend (GPTK-only).** The CrossOver/DXVK fallback was
  advertised across config, UI, and policy but never wired (no DXVK download, no install path) — pure rot
  (decided with the user, 2026-06-28). Collapsed to a single graphics path: deleted `GraphicsBackend` +
  `BackendPolicy` (+ their tests), dropped `GameConfig.backend`,
  `BackendConfig.{crossoverWinePath,dxvkDLLDirPath,wineBinary(for:)}`, `EnvFlags.dxvkHUD`,
  `GraphicsLinker.linkDXVK`, the backend Picker + the CrossOver/DXVK path rows in Advanced Settings, the
  per-game DXVK-HUD field, the GameDetail backend recommendation, and the now-dead `applicationsDirectory`
  autodetect param (it only existed to find CrossOver.app). `makePlan`/`linkGraphics` are GPTK-only.
  Legit "CrossOver **source**" wine-build references (constraint #8) preserved; CLAUDE.md "Two runtime
  roles" updated to GPTK-only. 112 tests / 25 suites green; clean build (no warnings).
- **✅ M86 — agentic codebase audit (17 verified cleanups).** A 5-reviewer multi-agent audit
  (dedup → adversarial verify, 17 of 21 confirmed) → applied: dead code removed (`Asset.size`,
  `AppPaths.steamBottleWebHelper`, `BackendSettingsViewModel.paths`, `GameSettingsViewModel.appName`);
  duplication collapsed (`GPTKImporter.Result`→`GPTKInstall`, shared `deQuarantine()` +
  `RuntimeInstallRow`, generic `AppManifestDecoder.opt<T>`); `bootstrap()` re-entrancy fixed
  (`isBootstrapping`/`didBootstrap` split); **`BackendPolicy.effective` wired into `play()`** (gptk→
  crossover fallback — was dead code; covered by BackendPolicyTests); four stale M83 GPTK "system32"
  docs corrected to the overlay mechanism. 122 tests / 26 suites green; clean build (no warnings).
- **✅ M85 — inline in-app updater (Sparkle-style).** The updater now applies updates **inline**:
  download the release `.zip` → unpack beside `Silo.app` → atomic `replaceItemAt` → `lsregister` →
  relaunch — no browser hop / manual install, replacing the old check+download-Link. `Updater`.
  `downloadUpdate`/`installUpdate`/`relaunch` (binary exec via `ProcessRunning`);
  `AppEnvironment.installUpdate` + `UpdateState`; `AboutView` "Download & Relaunch" button + progress.
- **✅ CI(wine) — brew-link crash fixed (follow-up to M84 GnuTLS).** The x86_64-Homebrew step
  hard-failed on a transitive `python@3.14` link conflict (`idle3 already exists`). Now tolerates link
  failures (we reference every formula by `brew --prefix`, never the linked name) and asserts the needed
  formulae are installed. Validated in CI: "Build dependencies" + "Fetch CrossOver source" steps pass;
  the build proceeds into compiling Wine.
- **✅ M84 — Wine CI GnuTLS configure fix.**
  `build-wine.yml` now fails fast if x86_64 Homebrew dependencies do not install, installs `pkgconf`,
  and exports the x86_64 Homebrew `pkg-config` / include / library paths plus explicit x86_64 clang
  selection before Wine configure. This should unblock the GitHub runner failure:
  `libgnutls 64-bit development files not found` while keeping `--with-gnutls` required for schannel.
  Local verification: workflow YAML parses; `swift build --disable-sandbox` clean; `Scripts/test.sh
  --disable-sandbox` green (119 tests / 26 suites). The `--disable-sandbox` flag was only needed because
  this managed local session blocks SwiftPM's manifest sandbox.
- **✅ M83 — GPTK D3DMetal OVERLAY baked into Silo (native DX11 games render under GPTK on-device).**
  119 tests / 26 suites green; clean build (no warnings); `dist/Silo.app` reassembled. The load-bearing
  GPTK activation: Apple's d3d modules must be OVERLAID into the wine runtime's OWN `lib/wine` tree, not
  merely put on `WINEDLLPATH` (which loads GPTK's PE dll but pairs it with wine's own `wined3d`→OpenGL
  backend → `D3D11CreateDevice` 0x80004005). This **replaces the M29 WINEDLLPATH/system32-symlink wiring**.
  - **`GraphicsLinker.overlayGPTK(wineBinary:gptkLibDir:)`** copies GPTK's 6 graphics modules' PE `.dll`
    into `<wine>/lib/wine/x86_64-windows`, **recreates** each unix `.so` as a relative symlink in
    `x86_64-unix` (preserved, not dereferenced — keeps D3DMetal.framework's `@rpath` lookup working), and
    copies `lib/external` (libd3dshared.dylib + D3DMetal.framework) into `<wine>/lib/external`. The runtime
    is then self-contained for D3DMetal (GPTK not consulted at launch). Idempotent (byte-compares a witness
    module): no-op when current, re-applies on a runtime re-download or GPTK update — so it survives both.
  - **`makePlan` GPTK env** now points the DYLD fallbacks at the runtime's own `lib/external` and forces
    only the GPTK-translated modules builtin (`WINEDLLOVERRIDES=d3d10,d3d11,d3d12,dxgi=b`; no WINEDLLPATH;
    d3d9/wined3d untouched). Optimally-tuned set confirmed against Apple's GPTK README (documented env is
    just `ROSETTA_ADVERTISE_AVX` + `D3DM_SUPPORT_DXR`; MetalFX/DXR are per-game, off by default) — all
    already in `EnvFlags`. The overlay was the only substantive gap.
  - **Proven on-device:** Bloons TD 6 (native Unity D3D11) creates a real D3DMetal device
    (`Direct3D 11.0 level 10.1`), renders with sound + fullscreen, co-resident Steamworks connected.
  - Cleanup: old GPTK-into-`system32` path deleted; `link()`→`linkDXVK()` (crossover-only); dead
    `gptkExternalDirPath`/`gptkWineDLLDirPath`/`LinkError.backendNotConfigured` removed.
- **✅ M73–M81 — THE GATE IS CLEARED: bottle Steam RENDERS + LOGS IN on the from-source CrossOver wine
  (on-device, 2026-06-28).** 117 tests / 26 suites green; clean build. Three fixes, each found from live
  logs, finally got the Windows Steam client visible + signed in:
  - **winebus/SDL crash** (the recurring `NSWindow … main thread` abort): `winebus.so` dlopens libSDL2
    whose macOS init pops an off-main-thread NSAlert → Wine aborts. `WINEDLLOVERRIDES=winebus=` does NOT
    disable a PnP `.sys` driver; the reliable fix is removing the dylib. → build `--without-sdl` (M80) +
    `RuntimeManager.stripBundledSDL` auto-strips bundled `libSDL2*` (no rebuild needed).
  - **wrapper stranded** (M81): a Steam update switched the CEF dir `cef.win7x64`→`cef.win64`, leaving the
    single-dir wrapper orphaned while Steam ran the unwrapped webhelper → black. `installWebHelperWrapper`
    now wraps ALL `bin/cef/*/steamwebhelper.exe`. (Path was also wrongly `cef.win64`-hardcoded pre-M78.)
  - **presentation** (M79): Steam launches in a Wine virtual desktop (`explorer /desktop=`) so winemac.drv
    presents the CEF surface (rootless = black on CrossOver). CEF forced onto SwiftShader software GL via
    `STEAM_CEF_COMMAND_LINE` + the `--in-process-gpu` wrapper (M76).
  - Login via QR (Steam mobile) succeeded + cached (AllowAutoLogin=1). The Chromium `WSALookupServiceBegin`/
    `10045`/`Transport Error` log spam is NON-fatal background noise, not a login blocker.
  - **✅ CO-RESIDENT LAUNCH + STEAMWORKS VALIDATED:** GeoGuessr Steam Edition (3478870 — previously FAILED
    Steamworks with no logged-in Steam) launched via `launchInBottle` under GPTK and got
    `getAuthTicketForWebApi -> OK` from the co-resident Steam. The whole shared-bottle architecture works.
    Per-game polish left: GeoGuessr is Electron and its ANGLE/WebGL doesn't init under GPTK (map renders
    broken) — fixable per-game via software/SwiftShader GL, separate from the (working) architecture.
- **M68–M72 — REVERT to the Steam-bottle model + a 3-round agentic audit.** 115 tests / 26 suites green;
  clean build (no warnings). SteamCMD + macOS credential-seeding were removed and the app reverted to a
  single shared **Steam bottle**: one Wine prefix hosting a logged-in Windows Steam client; games install
  there and launch **co-resident** under GPTK/D3DMetal so Steamworks/DRM works (IPC is prefix-scoped). Then
  an agentic audit-fix loop (4 read-only audits → verify → apply → re-audit):
  - **M68:** the revert itself (bottle foundation, discovery from the bottle's `appmanifest`, launchInBottle).
  - **M69:** removed the dead isolated-prefix layer (PrefixProvisioner, GameLogStore, SteamBottle.launchGame,
    AppPaths.prefix/prefixesDir, RuntimeManager.installedRuntimes/availableAssets, SteamApp.downloadProgress/
    needsUpdate). Bottle now launches Steam in a Wine **virtual desktop** (`explorer /desktop=`) with
    overlay-disable overrides + msync; `play()` brings Steam up ONCE (tracked PID) with a cold-start grace.
    Wine build: add `CROSSCFLAGS=-fvisibility=default`; drop `/usr/local/lib` from the DYLD fallback (it
    leaked Homebrew's duplicate gtk → the "implemented in both" crash seen launching bottle Steam).
  - **M70:** removed the now-obsolete `.sharedSteamClient` strategy + unused `Receipt`/`revert` (the bottle
    IS the in-prefix Steam); `load()` surfaces real discovery errors instead of swallowing them.
  - **M71:** force msync for every bottle game launch (a per-game esync/none would fork a 2nd wineserver and
    break Steamworks); `steam://` install/uninstall deliver via single-instance forwarding (no 2nd Steam in
    a duplicate desktop); GraphicsLinker scoped to `d3d*`/`dxgi*` so it can't clobber the shared bottle;
    removed the orphaned `WineRuntime` type.
  - **M72:** `stop()` also `wine taskkill /F /IM <game exe>` in the bottle's msync wineserver so a
    child/relauncher game isn't orphaned (Steam untouched — different image names).
- **M58–M60 COMPLETE — spring cleaning.** 150 tests / 30 suites green; clean build (no warnings).
  Three parallel audits (dead code / duplication / post-pivot vestigial) → verified findings → acted.
  - **M58:** Uninstall also removes the game's isolated Wine prefix (full reclaim).
  - **M59 (dedup):** SteamAppInfo.headerArtURL/storePageURL (views stop hand-rolling URLs); one
    GameArtworkPlaceholder; one URL.tailString; shared .uninstallConfirmation modifier; LogTarget.windowID
    + AppEnvironment.logTarget(for:).
  - **M60 (removals):** deleted zero-ref dead symbols + post-pivot vestigial code (masterBottlePath/
    steamRoot/steamWineBinaryPath/isMasterBottleConfigured/steamWine, DiscoveryEngine.steamRoot(inBottle:),
    Silo.steamInstallerURL/steamLaunchArgs, AppPaths.masterBottleDefault, WineRuntime.wineserverBinary,
    PrefixLayout.syswow64/dosDevices, StateFlags.isDownloading, SteamApp URL helpers, requiresUserStub),
    removed CrashLoopGuard + orphaned ProcessRunning.processCount, hid the inert .sharedSteamClient from
    the picker, reworded stale Master-bottle docs. Net −156 lines (5045→4940 LOC) despite adding helpers.
- **M51–M57 COMPLETE — perf + reliability + UX pass.** 153 tests / 31 suites green; clean build (no
  warnings); .app assembles; verified running at **0.0% idle CPU** (was pinned at 100%).
  - **M51 (the energy bug):** sampled the live app → main thread pinned in SwiftUI layout driven by a
    CADisplayLink. Root cause: indeterminate `ProgressView()` spinners INSIDE the ScrollView (loading /
    "Updating" / AsyncImage placeholder) re-laid out the whole grid every frame. Moved spinners out of
    the scroll content; download bar `safeAreaInset`→VStack sibling; `filtered` no longer re-sorts.
    Verified 100%→0%.
  - **M52 (event-driven, no polling):** `ProcessRunning` gains `observeExit` (DispatchSource process) +
    `observeWrites` (file-system) + `firstPID`. Downloads read progress reactively from the SteamCMD log
    and detect completion/interruption from the process's real exit (no 2s poll, no flaky pgrep) — fixes
    the false "Resume"; manifest is authoritative on exit. Game-exit clears state via an exit observer.
  - **M53 (UX):** whole card opens details; detail view shows Disk size / Metacritic / Minimum
    requirements; status messages auto-dismiss (6s); refresh toolbar keeps button chrome while spinning.
    Fixed logged-in account "falling away" — `autodetect` was wiping `steamUsername`; now preserved + the
    account shows in the navigation subtitle.
  - **M54:** Uninstall (menu + details, confirmed) deletes the game's bucket files.
  - **M55:** fast refresh — incremental app-metadata cache (`ownedGames(known:)` only `app_info`s new
    apps; the cache persists the full owned catalog).
  - **M56:** `BackendPolicy` — GPTK default for DirectX 9–12, auto CrossOver fallback when GPTK absent;
    detail view shows the recommended backend + DirectX-derived rationale.
  - **M57:** log viewer is now a kqueue file-watcher (was a 1s poll). No timer/poll loops remain anywhere.
- **M0–M41 COMPLETE — pivot DONE.** 137 tests / 29 suites green; clean build (no warnings); .app assembles.
- **PIVOT COMPLETE (M36–M41):** Wine Steam-client GUI fully removed; replaced by native-macOS SteamCMD.
  - M37–M38: SteamCMDClient (install + force-windows download + capture) + SteamAppInfo metadata +
    ownedWindowsGames enumeration (licenses→packages→app_info, filtered to windows-only games).
  - M39: SyncMode enum, MSync default (Apple-Silicon best practice).
  - M40: GameLibraryViewModel + SteamLoginViewModel wired into AppEnvironment (account in BackendConfig).
  - M41 (UI swap + rip-out): new SteamLoginView + SteamGameTileView; LibraryGridView lists owned
    Windows-only games (Download→SteamCMD, Play→GPTK bucket); OnboardingView step 3 = "Sign in to Steam";
    readiness = wineReady && gptkReady && steamLoggedIn. DELETED: SteamBottleInstaller, SteamCardView,
    GameCardView, LibraryViewModel, SteamLibraryInstaller, OwnedAppsReader (+ their tests). ViewModelTests
    pruned to the surviving VMs. CrashLoopGuard retained (available; no longer wired to Steam GUI).
  - REMAINING (human-gated): real SteamCMD login + a real Windows-only game download → launch in a GPTK
    bucket (needs the user's Steam credentials). All headless-testable logic is done + green.
- **>>> ARCHITECTURE PIVOT (2026-06-27, user decision) <<<** The Wine **Steam-client GUI** does not
  render under our self-built wine on macOS 26 (CEF black window; verified that -no-cef-sandbox fixes the
  crash-loop but neither GPU-on nor GPU-off nor RetinaMode nor virtual-desktop renders it — this is the
  industry-wide problem that got Whisky archived). New model **"Native Steam library → SteamCMD → GPTK
  buckets"**: (1) DROP the Wine Steam bottle entirely (SteamBottleInstaller/openSteam/CEF flags/shared-
  client presence); (2) library = the user's owned games filtered to **Windows-only** (no native mac
  build); (3) download via **native macOS SteamCMD** `@sSteamCmdForcePlatformType windows` (no Wine/CEF);
  (4) launch each in a per-game **GPTK bucket** configured from the game's Steam metadata (DirectX→backend)
  else sensible default. Owned-list + metadata via SteamCMD itself (licenses_print / app_info_print) — no
  Web API key needed.
  - P0 DONE: native macOS SteamCMD **verified on macOS 26** (bootstraps, accepts force-windows, returns
    app_info platforms for appID 70).
  - M36 / P1-foundation DONE: `SteamCMD` pure command builders (download / app_info / licenses) + tests.
  - TODO: P1 `SteamCMDClient` (install steamcmd + run download/login via ProcessRunning); P2 owned
    Windows-only library + metadata; P3 metadata-driven GPTK bucket; P4 rip out old Steam-bottle code + UI rework.
- M35 = bundler no longer bundles glib/gstreamer/ffmpeg media stack (killed the "implemented in both" +
  glib-type dup warnings); 44→21 libs; clean wineboot = 0 freetype + 0 dup. RetinaMode reverted (broke windowing).
- M33 (user UX/bug fixes): (1) Steam card now has a right-click context menu + always-visible ellipsis
  (Open Steam, Reinstall, View Log…, Wine Config…, Reveal Bottle, Settings…). (2) Log viewer opens as a
  STANDALONE WINDOW (WindowGroup id "silo-log" + openWindow), not a modal sheet, so it live-tails while
  you drive the main window; generalized to any file (title+url), added an Autoscroll toggle. (3) (b)
  CrashLoopGuard + ProcessRunning.processCount: auto `wineserver -k` if a `winedbg` storm appears, wired
  behind openSteam. (4) (a) gstreamer dedup: reorder to bundled-LAST was tried but BREAKS FreeType
  (wine only finds its dlopen'd freetype from the bundle), so kept bundled-FIRST; proper dedup = don't
  bundle the glib/gstreamer/ffmpeg media stack (TODO in bundler; only manifests during video playback).
- **OPEN (windowing):** Steam launches but renders as two blank/black rootless windows (steam + CEF
  steamwebhelper). Testing a wine VIRTUAL DESKTOP (HKCU\Software\Wine\Explorer Desktop=Default) to
  composite into one window — enabled on the user's bottle; awaiting visual confirmation it renders.
- M32 (bug: "Open Steam" opens nothing): Steam WAS launching but its CEF UI renderer went
  "unresponsive" and Steam killed+relaunched it every ~90s forever, so the window stayed 0x0/blank.
  Root cause: the CEF sandbox under wine. Fix: `Silo.steamLaunchArgs` now passes `-no-cef-sandbox`
  (+ `-cef-disable-gpu -allosarches`; dropped obsolete `-cef-force-32bit`). EMPIRICALLY VERIFIED on
  the user's machine: 0 "unresponsive" events after relaunch and a real 705x440 Steam login window appeared.
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
- **HW-accelerated Steam *UI* (M92, on-device test):** flip Advanced → Steam bottle → "Hardware-accelerated
  UI (experimental)" → Launch Steam. If the CEF window renders (not black) and the GPU log shows ANGLE/D3D11
  (not SwiftShader), GPTK now drives the Steam UI on Metal — report back and it can become the default. If it
  black-screens / `eglInitialize D3D11 failed`, the ANGLE-D3D11-under-GPTK limit still holds and software GL
  stays the path (the 2D UI is fine on software; games are HW regardless). Only the user can run this gate.
- _(none for the build — the items below need a real Wine runtime + on-device launch, not code changes)_
- **Bottle Steam CEF render + login (M76, verified recipe applied — needs on-device confirm):** deep-research
  (→ MelonForAll/vineport, confirmed working macOS 2026) found the root cause of BOTH the black window AND
  the `Transport Error 2` login failure: the steamwebhelper wrapper injected `--single-process`, which also
  breaks Chromium's network service under Wine. Fixed to `--in-process-gpu` + SwiftShader software GL
  (`STEAM_CEF_COMMAND_LINE`/`STEAM_DISABLE_GPU_PROCESS`/`GALLIUM_DRIVER=llvmpipe`) + rootless launch +
  Vineport's steam.exe flags. **To verify:** rebuild wine (`Scripts/build-wine.sh <ver>` — corrected
  wrapper) + rebuild the app, Advanced → Reset Steam login → Launch Steam → confirm the UI paints + login
  completes. If still failing, the research's fallback is kaon's model (native macOS Steam primary).
- **`explorer /desktop=` program-path form:** `launchSteam` passes the macOS **unix** path of `steam.exe`
  as the program arg to `wine explorer /desktop=Silo,<geom>`. If wine's explorer needs a Windows path
  (`C:\Program Files (x86)\Steam\steam.exe`) instead, Steam won't launch — verify on-device and switch if so.
- **stop() under real Wine:** `stop()` SIGTERMs the loader PID **and** `wine taskkill /F /IM <exe>`. Confirm
  a real game (esp. one with a separate launcher exe) actually exits and isn't orphaned; tune the image
  name if a game's runtime process differs from the launched exe.
- **Cold-start grace:** `play()` waits a flat 10s after cold-starting Steam before launching the game. If
  Steam's first boot (self-update + login) is slower, the game can start before Steamworks is ready — may
  need a readiness probe (Steam pipe/registry) instead of a fixed sleep.
- **GPTK E2E activation — RESOLVED (M83).** Confirmed from a real D3D game (Bloons TD 6): `WINEDLLPATH`
  alone does NOT activate GPTK (wine keeps its own wined3d backend → device-creation failure); the overlay
  copy into wine's own `lib/wine` (Whisky's method) is required and now automated by
  `GraphicsLinker.overlayGPTK`. D3DMetal device creation + render verified on-device.
- Confirm the exact third-party Wine/GPTK runtime repo/release to pin as default (currently placeholder
  `Kegworks-App/Kegworks` in `Silo.defaultRuntimeRepo`; overridable in Settings). Non-blocking.

## Handoff checklist (for human, post-loop E2E)
- [ ] Build the patched wine: `Scripts/build-wine.sh 26.2.0` (adds `-fvisibility=default` + the
      steamwebhelper wrapper). Download/point Silo at a GPTK runtime.
- [ ] Advanced → Steam bottle → **Set up** (installs Windows Steam into the bottle) → **Launch Steam**.
      Confirm the CEF login window actually PAINTS (the gate above); sign in once (Steam caches it).
- [ ] Confirm the library lists games installed in the bottle; **Install** routes a `steam://` URL to the
      running Steam.
- [ ] **Play** → game launches co-resident in the bottle under GPTK (CrossOver fallback); Steamworks/online
      works. **Stop** actually exits it.
- [ ] (Distribution) provide Apple Developer ID + notarization secrets for signed releases.
