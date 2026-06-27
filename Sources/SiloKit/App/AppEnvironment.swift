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

    public let gameLibrary: GameLibraryViewModel
    public let backendSettings: BackendSettingsViewModel
    public let runtime: RuntimeViewModel
    public let gptkManager: GPTKManagerViewModel
    public let steamBottleVM: SteamBottleViewModel
    public let steamStore = SteamStoreClient()
    private let updater: Updater
    public private(set) var updateCheck: Updater.UpdateCheck?
    public private(set) var didBootstrap = false

    public init(
        paths: AppPaths = .standard(),
        runner: ProcessRunning = SystemProcessRunner(),
        updater: Updater = Updater()
    ) {
        self.paths = paths
        self.runner = runner
        self.updater = updater

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
            config: initialBackend, resolver: BackendResolver(), configStore: configStore, paths: paths)
        self.runtime = RuntimeViewModel(manager: runtimeManager, repo: Silo.wineRepo)
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        let bottle = SteamBottle(runner: runner, paths: paths)
        let gameLibrary = GameLibraryViewModel(
            bottle: bottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend)
        self.gameLibrary = gameLibrary
        let steamBottleVM = SteamBottleViewModel(bottle: bottle)
        self.steamBottleVM = steamBottleVM

        backendSettings.onChange = { [weak gameLibrary, weak steamBottleVM] config in
            gameLibrary?.updateBackend(config)
            steamBottleVM?.updateWine(config.wineBinaryPath)
        }
        gptkManager.onDefaultChanged = { [weak self] install in
            guard let self else { return }
            self.backendSettings.config.gptkLibDirPath = install.gptkLibDir
            self.backendSettings.config.gptkRuntimeName = install.name
            Task { await self.backendSettings.save() }
        }
        runtime.onDefaultChanged = { [weak self] wine in
            guard let self else { return }
            self.backendSettings.config.wineBinaryPath = wine.wineBinary
            self.backendSettings.config.wineRuntimeName = wine.name
            Task { await self.backendSettings.save() }
        }
    }

    /// Load persisted config and populate the UI. Idempotent.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        let state = await configStore.load()
        backendSettings.config = state.backend
        gameLibrary.updateBackend(state.backend)
        steamBottleVM.updateWine(state.backend.wineBinaryPath)
        gptkManager.defaultName = state.backend.gptkRuntimeName
        gptkManager.refresh()
        runtime.defaultName = state.backend.wineRuntimeName
        await runtime.refresh()
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        updateCheck = try? await updater.checkForUpdate()   // best-effort; nil on failure/offline
    }

    /// Reload the bottle's game library (e.g. on app re-activation).
    public func refreshLibraryIfReady() async {
        guard didBootstrap, gameLibrary.steamReady else { return }
        await gameLibrary.load()
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Windows Steam client is installed in the bottle (the user signs into it in-app).
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    /// Build a per-game settings view model with the game's persisted config.
    public func makeGameSettings(appID: Int, name: String) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID), appName: name, configStore: configStore)
    }

    /// A game's launch log (per appID).
    public nonisolated func logURL(forAppID appID: Int) -> URL {
        paths.log(forAppID: appID)
    }

    /// The log-window target for a game (title + its log URL), opened via `openWindow(id:)`.
    func logTarget(for game: SteamApp) -> LogTarget {
        LogTarget(title: "\(game.name) — Log", url: logURL(forAppID: game.appID))
    }
}
