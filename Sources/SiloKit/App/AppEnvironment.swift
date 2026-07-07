import Foundation

/// One backend's Steam-bottle service bundle: the bottle, its live client session, and the settings VM
/// driving setup/launch. Built once per `GraphicsBackend` by `AppEnvironment`, so backend services are
/// a keyed table instead of gptk/dxmt copy-paste pairs. Every backend's Steam client runs on the BASE
/// wine (CEF needs no d3d; a co-resident game picks the per-backend variant runtime — shared wineserver);
/// a secondary backend's bottle stays empty until the user sets it up via onboarding.
@MainActor
public final class BackendServices {
    public let backend: GraphicsBackend
    public let bottle: SteamBottle
    public let session: SteamClientSession
    public let bottleVM: SteamBottleViewModel

    init(backend: GraphicsBackend, runner: ProcessRunning, paths: AppPaths,
         orchestrator: LaunchOrchestrator, setupGate: SteamSetupGate) {
        self.backend = backend
        self.bottle = SteamBottle(runner: runner, paths: paths, backend: backend)
        self.session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        self.bottleVM = SteamBottleViewModel(bottle: bottle, session: session, setupGate: setupGate)
    }
}

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
    /// Per-backend Steam-bottle service bundles (bottle + client session + settings VM) — the ONE place
    /// backend services are built, keyed so nothing is duplicated per backend.
    public let backends: [GraphicsBackend: BackendServices]
    public let steamStore = SteamStoreClient()

    /// A backend's service bundle. Total by construction — `init` builds one per `GraphicsBackend`.
    public func services(for backend: GraphicsBackend) -> BackendServices {
        guard let services = backends[backend] else {
            preconditionFailure("BackendServices missing for \(backend) — init builds one per backend")
        }
        return services
    }

    // Convenience forwards (the pre-bundle names the views + tests use).
    public var steamBottleVM: SteamBottleViewModel { services(for: .gptk).bottleVM }
    /// Setup + launch for the DXMT Steam bottle (the older-games path) — same flow, the DXMT prefix.
    public var dxmtBottleVM: SteamBottleViewModel { services(for: .dxmt).bottleVM }
    /// The owner of the GPTK Steam bottle's live client (shared by the Library + the settings pane).
    public var steamClientSession: SteamClientSession { services(for: .gptk).session }
    /// The DXMT Steam bottle's client session (one Steam install/login per backend).
    public var dxmtClientSession: SteamClientSession { services(for: .dxmt).session }
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

        // One service bundle (bottle + client session + settings VM) per backend — see BackendServices.
        // A shared setup gate serializes bottle setup across backends, so the seed can't clone a sibling
        // whose client is still mid-download (→ a broken Steam).
        let setupGate = SteamSetupGate()
        var backends: [GraphicsBackend: BackendServices] = [:]
        for backend in GraphicsBackend.allCases {
            backends[backend] = BackendServices(
                backend: backend, runner: runner, paths: paths, orchestrator: orchestrator, setupGate: setupGate)
        }
        self.backends = backends

        let gameLibrary = GameLibraryViewModel(
            bottle: backends[.gptk]!.bottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend,
            session: backends[.gptk]!.session, dxmtSession: backends[.dxmt]?.session,
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
        // A fresh Steam install must flip the library's cached `steamReady` gate (it drives onboarding);
        // load() re-probes the cache off-main. Without this, onboarding would stall until a relaunch.
        for services in backends.values {
            services.bottleVM.onSteamInstalled = { [weak self] in Task { await self?.gameLibrary.load() } }
        }
        // Relocation must refuse while anything runs in a bottle (see `anythingRunning`).
        bottles.isBlocked = { [weak self] in self?.anythingRunning ?? true }
    }

    /// Fan out a backend-config change to the view models that depend on it.
    private func applyBackend(_ config: BackendConfig) {
        gameLibrary.updateBackend(config)
        // Every backend's Steam client runs on the base wine (CEF; co-resident games pick the per-backend
        // variant). updateWine on each bottle VM also updates its session's wine.
        for services in backends.values { services.bottleVM.updateWine(config.wineBinaryPath) }
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
        // Populate the bottle VMs' cached installed-flags (settings buttons gate on them).
        for services in backends.values { await services.bottleVM.refreshInstalled() }
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        await updates.checkForUpdate()   // best-effort; nil updateCheck on offline
        didBootstrap = true
        isBootstrapping = false
    }

    /// Reload the bottle's game library (e.g. on app re-activation).
    public func refreshLibraryIfReady() async {
        guard didBootstrap, gameLibrary.steamReady else { return }
        await gameLibrary.load()
    }

    // MARK: - Bottles location

    /// True while any game OR any bottle's Steam client is live — relocation is refused then (we'd be
    /// moving prefixes out from under running wineservers). Checks EVERY backend's session: a live DXMT
    /// client is just as much a running wineserver as the GPTK one.
    public var anythingRunning: Bool {
        gameLibrary.isAnythingRunning || backends.values.contains { $0.session.isRunning }
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Windows Steam client is installed in the bottle (the user signs into it in-app).
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    // MARK: - DXMT (optional older-games backend)

    /// The DXMT runtime (its module dir, built from CrossOver source) is configured.
    public var dxmtReady: Bool { backendSettings.config.dxmtLibDirPath != nil }
    /// The DXMT Steam bottle has its Windows Steam client installed (the library's off-main cache — a
    /// blocking `fileExists` here would run inside SwiftUI body evaluation).
    public var dxmtSteamReady: Bool { gameLibrary.steamInstalled(.dxmt) }

    // MARK: - Steam-bottle Wine tools (Settings → General)

    /// Last result of a bottle-tool action (Retina toggle / winecfg / regedit), shown in Settings.
    public private(set) var bottleToolsMessage: String?
    public private(set) var bottleToolsBusy = false

    /// The wine binary games launch with (nil until Wine is configured).
    public var wineBinary: URL? { backendSettings.config.wineBinaryPath }

    /// Toggle macOS Retina/HiDPI ("High Resolution Mode") for the Steam bottles: persist the ONE preference,
    /// then write the coupled `RetinaMode` + `LogPixels` (DPI companion) registry keys into EVERY installed
    /// bottle's prefix (GPTK + DXMT stay consistent). Takes effect on the next game launch.
    public func setSteamBottleRetina(_ on: Bool) async {
        guard let wine = wineBinary else { bottleToolsMessage = "Set up Wine first."; return }
        guard !bottleToolsBusy else { return }
        bottleToolsBusy = true; defer { bottleToolsBusy = false }
        backendSettings.config.retinaMode = on
        await backendSettings.save()
        do {
            for graphics in GraphicsBackend.allCases where gameLibrary.steamInstalled(graphics) {
                try await wineTools.setRetinaMode(on, prefix: paths.steamBottle(graphics), wine: wine)
            }
            bottleToolsMessage = "Retina mode \(on ? "on" : "off") — applies on the next game launch."
        } catch {
            bottleToolsMessage = "Couldn't update Retina mode: \((error as NSError).localizedDescription)"
        }
    }

    /// Open a Wine maintenance tool (winecfg / regedit / control) on a backend's Steam bottle so the user
    /// can fix that prefix by hand. Routes through the shared `runWineTool` (single tool-launch path).
    public func openWineTool(_ tool: String, for graphics: GraphicsBackend = .gptk) async {
        guard wineBinary != nil else { bottleToolsMessage = "Set up Wine first."; return }
        await orchestrator.runWineTool(tool, prefix: paths.steamBottle(graphics), backend: backendSettings.config)
        bottleToolsMessage = "Opened \(tool)."
    }

    /// Build a per-game settings view model with the game's persisted config for a specific bottle. Keyed by
    /// (appID, backend) so editing the GPTK card's settings doesn't mutate the DXMT card's, and vice versa.
    public func makeGameSettings(appID: Int, backend: GraphicsBackend = .gptk) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID, backend: backend), configStore: configStore)
    }

    /// A game's launch log (per appID + graphics backend — the GPTK and DXMT copies log separately).
    public nonisolated func logURL(forAppID appID: Int, backend: GraphicsBackend = .gptk) -> URL {
        paths.log(forAppID: appID, backend: backend)
    }
}
