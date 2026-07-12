import Foundation

/// Composition root: constructs every service + the long-lived view models, and wires them together.
@MainActor
@Observable
public final class AppEnvironment {
    public let paths: AppPaths
    let configStore: ConfigStore
    let runner: ProcessRunning
    let linker: GraphicsLinker
    let orchestrator: LaunchOrchestrator
    let discovery: DiscoveryEngine
    let runtimeManager: RuntimeManager
    /// Runs Wine maintenance tools + registry tweaks (Retina) against the shared Steam bottle.
    let wineTools: WineTools

    public let gameLibrary: GameLibraryViewModel
    public let backendSettings: BackendSettingsViewModel
    public let runtime: RuntimeViewModel
    /// The DXMT settings tab / onboarding step — the SAME install flow as `runtime`, parameterized for
    /// DXMT (its own releases, its own default persisted to `BackendConfig.dxmtLibDirPath`).
    public let dxmtRuntime: RuntimeViewModel
    public let gptkManager: GPTKManagerViewModel
    /// The Steam bottle's settings VM (setup / launch), shared by the Library + the settings pane.
    public let steamBottleVM: SteamBottleViewModel
    /// The owner of the Steam bottle's live client (shared by the Library + the settings pane).
    public let steamClientSession: SteamClientSession
    public let steamStore = SteamStoreClient()

    private let updater: Updater
    /// The inline self-update flow (check / download / relaunch) — Settings → General → Updates.
    public let updates: UpdateCoordinator
    /// The bottles-location move flow (Settings → General → Bottles).
    public let bottles: BottlesRelocationCoordinator
    public private(set) var didBootstrap = false
    private var isBootstrapping = false

    public init(
        paths: AppPaths = .standard(),
        runner: ProcessRunning = SystemProcessRunner(),
        updater: Updater? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.wineTools = WineTools(runner: runner)
        let updater = updater ?? Updater(runner: runner)
        self.updater = updater
        self.updates = UpdateCoordinator(updater: updater, updatesDir: paths.updatesDir)
        self.bottles = BottlesRelocationCoordinator(paths: paths, updater: updater)

        let configStore = ConfigStore(paths: paths)
        let linker = GraphicsLinker()
        let discovery = DiscoveryEngine()
        let orchestrator = LaunchOrchestrator(runner: runner, linker: linker)
        let runtimeManager = RuntimeManager(paths: paths, runner: runner)

        self.configStore = configStore
        self.linker = linker
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.runtimeManager = runtimeManager

        let initialBackend = BackendConfig()
        self.backendSettings = BackendSettingsViewModel(
            config: initialBackend, configStore: configStore)
        self.runtime = RuntimeViewModel(manager: runtimeManager, repo: Silo.wineRepo)
        let backendSettings = self.backendSettings
        self.dxmtRuntime = RuntimeViewModel(
            kind: .dxmt(manager: runtimeManager,
                        wineRuntimeName: { backendSettings.config.wineRuntimeName }),
            manager: runtimeManager, repo: Silo.wineRepo)
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        // The single Steam bottle + its live client session + settings VM. The client runs on the base wine
        // (CEF needs no d3d; a co-resident game picks the variant runtime — shared wineserver).
        let steamBottle = SteamBottle(runner: runner, paths: paths)
        let steamClientSession = SteamClientSession(bottle: steamBottle, orchestrator: orchestrator)
        let steamBottleVM = SteamBottleViewModel(
            bottle: steamBottle, session: steamClientSession, focuser: InstallerWindowFocuser())
        self.steamClientSession = steamClientSession
        self.steamBottleVM = steamBottleVM

        let gameLibrary = GameLibraryViewModel(
            bottle: steamBottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend,
            session: steamClientSession,
            provisioner: WinePrefixProvisioner(runner: runner))
        self.gameLibrary = gameLibrary

        backendSettings.onChange = { [weak self] in self?.applyBackend($0) }
        gptkManager.onDefaultChanged = { [weak self] install in
            Task { await self?.backendSettings.applyDefaultGPTK(install) }
        }
        runtime.onDefaultChanged = { [weak self] install in
            Task { await self?.backendSettings.applyDefaultWine(install) }
        }
        // The DXMT default persists to a different config field (the DXMT lib dir); an unusable install
        // (no module dir) is ignored so the config never adopts a broken runtime.
        dxmtRuntime.onDefaultChanged = { [weak self] install in
            guard let lib = install.artifact else { return }
            Task { await self?.backendSettings.applyDXMTLibDir(lib, name: install.name) }
        }
        // Removing the CURRENT default runtime clears its persisted config path, so the readiness gates
        // (all `!= nil` checks) don't stick true against a deleted runtime — every launch would otherwise
        // fail with a dangling path, and onboarding would keep showing the step "Done".
        runtime.onDefaultRemoved = { [weak self] in Task { await self?.backendSettings.clearWineDefault() } }
        gptkManager.onDefaultRemoved = { [weak self] in Task { await self?.backendSettings.clearGPTKDefault() } }
        dxmtRuntime.onDefaultRemoved = { [weak self] in Task { await self?.backendSettings.clearDXMTDefault() } }
        // A fresh Steam install must flip the library's cached `steamReady` gate (it drives onboarding);
        // load() re-probes the cache off-main. Without this, onboarding would stall until a relaunch.
        steamBottleVM.onSteamInstalled = { [weak self] in Task { await self?.gameLibrary.load() } }
        // Relocation must refuse while anything runs in a bottle (see `anythingRunning`). Both gates probe
        // the wineserver socket at the decision point (a button press — not a hot path), so an orphan left by
        // a prior run's hard crash still blocks a move/update over its live prefix.
        bottles.isBlocked = { [weak self] in self?.blockedForBottleWork() ?? true }
        // A self-update relaunches Silo (tearing everything down), so refuse it while a game/client is live.
        updates.isBlocked = { [weak self] in self?.blockedForBottleWork() ?? true }
        // Refuse launches while bottles are being moved (the prefixes are being copied off-volume + deleted).
        gameLibrary.isRelocating = { [weak self] in self?.bottles.busy ?? false }
        // …and while a self-update is downloading/installing (it relaunches Silo via exit(0), which would
        // otherwise orphan a game started in that window).
        gameLibrary.isUpdating = { [weak self] in self?.updates.isInstalling ?? false }
    }

    /// Fan out a backend-config change to the view models that depend on it.
    private func applyBackend(_ config: BackendConfig) {
        gameLibrary.updateBackend(config)
        // The Steam client runs on the base wine (CEF; a co-resident game picks the variant runtime).
        // updateWine on the bottle VM also updates its session's wine.
        steamBottleVM.updateWine(config.wineBinaryPath)
    }

    /// Load persisted config and populate the UI. Idempotent.
    public func bootstrap() async {
        guard !didBootstrap, !isBootstrapping else { return }
        isBootstrapping = true
        let state = await configStore.load()
        backendSettings.config = state.backend
        applyBackend(state.backend)
        gptkManager.defaultName = state.backend.gptkRuntimeName
        gptkManager.refresh()
        runtime.defaultName = state.backend.wineRuntimeName
        await runtime.refresh()
        dxmtRuntime.defaultName = state.backend.dxmtRuntimeName
        await dxmtRuntime.refresh()
        // Populate the bottle VM's cached installed-flag (settings buttons gate on it).
        await steamBottleVM.refreshInstalled()
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        await updates.checkForUpdate()   // best-effort; nil updateCheck on offline
        didBootstrap = true
        isBootstrapping = false
    }

    /// Reload the bottle's game library (e.g. on app re-activation).
    public func refreshLibraryIfReady() async {
        // Reload on every re-activation once bootstrapped — NOT gated on the last-known `steamReady`, which
        // would block the very reload that would notice a bottle deleted (or restored) out-of-band. `load()`
        // re-probes readiness off-main, so the cache re-syncs both directions.
        guard didBootstrap else { return }
        await gameLibrary.load()
    }

    // MARK: - Bottles location

    /// "Is anything running in a bottle right now" — a launch in flight, a bottle mid-setup, or ANY bottle
    /// with a live `wineserver` (a running game/Steam, detected PID-free by `WineServerProbe`, even one
    /// orphaned by a prior crash). Relocation/update refuse then (moving a prefix out from under its live
    /// server corrupts it). It reads a `stat` per bottle — cheap enough for the Move/Update button's disabled
    /// state, though it won't reactively re-render when a server appears/disappears; the action gate
    /// (`blockedForBottleWork`) re-checks at the moment the user acts, so correctness never depends on the
    /// body being current.
    public var anythingRunning: Bool {
        gameLibrary.launchInFlight
            || steamBottleVM.busy
            || WineServerProbe.isAnyBottleLive(paths: paths)
    }

    /// The relocation/update gate — evaluated at the moment the user acts (a button press, never a hot path).
    /// Refuse while: anything runs in a bottle now (incl. an in-flight launch, a bottle mid-setup, or a live
    /// wineserver — even a crash orphan); or the OTHER relaunching operation is already in flight (a move and
    /// a self-update must not overlap — both end in a relaunch/exit).
    func blockedForBottleWork() -> Bool {
        anythingRunning || bottles.busy || updates.isInstalling
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Steam bottle has a warmed client — drives the library's onboarding-vs-content gate.
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    /// The bottles live on a relocated drive that isn't currently mounted — a distinct "reconnect the drive"
    /// state, NOT first-run onboarding (the app would otherwise fall back to onboarding when it finds no
    /// bottle on the missing volume). Cheap: a couple of stats, fast even when the volume is absent.
    public var bottlesDisconnected: Bool { paths.bottlesRelocated && !paths.bottlesRootReachable }

    // MARK: - DXMT (graphics backend for manual games)

    /// The DXMT runtime (its module dir) is configured — enables the DXMT graphics backend for manual
    /// (non-Steam) games.
    public var dxmtReady: Bool { backendSettings.config.dxmtLibDirPath != nil }

    // MARK: - Guided setup (the onboarding "Set up" chain)

    /// True while any part of the guided setup is running (a Wine/DXMT runtime download, or the Steam-bottle
    /// setUp) — drives the onboarding "Set up" step's spinner.
    public var setupBusy: Bool {
        runtime.isInstalling || dxmtRuntime.isInstalling || steamBottleVM.busy
    }

    /// The full ordered onboarding setup, chained from a single "Set up" click: download the latest Wine
    /// runtime (if missing) → download the latest DXMT runtime (if missing) → set up the Steam bottle
    /// (download Steam → create the bottle → install the game-dependency component set, user-guided where a
    /// license is shown → warm up the client). GPTK is imported separately (its own onboarding step).
    public func runFullSetup() async {
        // 1. Wine — then wait for the new default to persist AND reach the bottle VM. `installLatest` applies
        //    the default via `onDefaultChanged` (a Task), so `setUp` could otherwise read a nil wine binary.
        if !wineReady {
            await runtime.installLatest()
            await waitFor { self.wineReady && self.steamBottleVM.canSetUp }
        }
        // 2. DXMT runtime (best-effort — readies the future auto-backend; not a prerequisite for the bottle).
        //    Matched to the configured wine, so it must run AFTER the wine default is applied (step 1's wait).
        if !dxmtReady {
            await dxmtRuntime.installLatest()
        }
        // 3. The Steam bottle: download → create → components → user-guided Steam → warm-up + wrap.
        await steamBottleVM.setUp()
    }

    /// Bounded wait for a main-actor condition to hold (e.g. an async config-persist `Task` fired by a
    /// runtime-default change to land). Best-effort — returns after ~5s regardless.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<250 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: - Steam-bottle Wine tools (Settings → General)

    /// Last result of a bottle-tool action (Retina toggle / winecfg / regedit), shown in Settings.
    public private(set) var bottleToolsMessage: String?
    public private(set) var bottleToolsBusy = false

    /// The wine binary games launch with (nil until Wine is configured).
    public var wineBinary: URL? { backendSettings.config.wineBinaryPath }

    /// Toggle macOS Retina/HiDPI ("High Resolution Mode") for the Steam bottle: persist the preference, then
    /// write the coupled `RetinaMode` + `LogPixels` (DPI companion) registry keys into the bottle's prefix.
    /// Takes effect on the next game launch.
    public func setSteamBottleRetina(_ on: Bool) async {
        guard let wine = wineBinary else { bottleToolsMessage = "Set up Wine first."; return }
        guard !bottleToolsBusy else { return }
        bottleToolsBusy = true; defer { bottleToolsBusy = false }
        backendSettings.config.retinaMode = on
        await backendSettings.save()
        do {
            if gameLibrary.steamInstalled {
                try await wineTools.setRetinaMode(on, prefix: paths.steamBottle, wine: wine)
            }
            bottleToolsMessage = "Retina mode \(on ? "on" : "off") — applies on the next game launch."
        } catch {
            bottleToolsMessage = "Couldn't update Retina mode: \((error as NSError).localizedDescription)"
        }
    }

    /// Open a Wine maintenance tool (winecfg / regedit / control) on the Steam bottle so the user can fix
    /// the prefix by hand. Routes through the shared `runWineTool` (single tool-launch path). The tool's own
    /// window IS the feedback — it deliberately posts NO status (the UI's status line lives in a different,
    /// Retina-preferences section, where an "Opened winecfg" toast just reads as misplaced).
    public func openWineTool(_ tool: String) async {
        guard wineBinary != nil else { return }
        await orchestrator.runWineTool(tool, prefix: paths.steamBottle, backend: backendSettings.config)
    }

    /// Build a per-game settings view model with the game's persisted config, keyed by appID.
    public func makeGameSettings(appID: Int) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID), configStore: configStore)
    }

    /// A game's launch log (`<appID>.log`).
    public nonisolated func logURL(forAppID appID: Int) -> URL {
        paths.log(forAppID: appID)
    }
}
