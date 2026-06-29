# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **✅ M112 — single source of truth for versions (`versions.env`, Velox-style).** The app version (0.1.1)
  was hard-coded in `Silo.swift` AND duplicated as a fallback in `build-app.sh`. Now `versions.env` (repo
  root) is the ONLY place a version is edited — `SILO_VERSION`, `SILO_GITHUB_REPO`, `CROSSOVER_VERSION`
  (the CrossOver FOSS wine-build input). `Scripts/gen-versions.sh` mirrors it into the committed
  `Sources/SiloKit/Versions.swift` (`Versions` enum); `Silo.version`/`updateRepo`/`wineRepo` read from it.
  `build-app.sh` regenerates + sources `versions.env` (dropped the grep + hard-coded `0.1.1` fallback);
  `build-wine.sh` defaults its CrossOver version to `CROSSOVER_VERSION`. A unit test fails if
  `Versions.swift` drifts from `versions.env` (verified: editing the env without regenerating turns it
  red). 197 tests / 31 suites green; clean build; app reassembled (Info.plist 0.1.1 flows from the env).
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
