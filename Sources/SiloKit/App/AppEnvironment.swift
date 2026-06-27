import Foundation

/// Composition root: constructs every service + the long-lived view models, and wires them together.
@MainActor
@Observable
public final class AppEnvironment {
    public let paths: AppPaths
    let configStore: ConfigStore
    let runner: ProcessRunning
    let provisioner: PrefixProvisioner
    let linker: GraphicsLinker
    let logStore: GameLogStore
    let orchestrator: LaunchOrchestrator
    let discovery: DiscoveryEngine
    let runtimeManager: RuntimeManager

    public let gameLibrary: GameLibraryViewModel
    public let steamLogin: SteamLoginViewModel
    public let backendSettings: BackendSettingsViewModel
    public let runtime: RuntimeViewModel
    public let gptkManager: GPTKManagerViewModel
    let steamCMD: SteamCMDClient
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
        let provisioner = PrefixProvisioner(runner: runner, paths: paths)
        let linker = GraphicsLinker()
        let logStore = GameLogStore(paths: paths)
        let discovery = DiscoveryEngine()
        let orchestrator = LaunchOrchestrator(
            runner: runner, provisioner: provisioner, linker: linker, logStore: logStore)
        let runtimeManager = RuntimeManager(paths: paths, runner: runner)

        self.configStore = configStore
        self.provisioner = provisioner
        self.linker = linker
        self.logStore = logStore
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.runtimeManager = runtimeManager

        let initialBackend = BackendConfig()
        self.backendSettings = BackendSettingsViewModel(
            config: initialBackend, resolver: BackendResolver(), configStore: configStore, paths: paths)
        self.runtime = RuntimeViewModel(manager: runtimeManager, repo: Silo.wineRepo)
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        let steamCMD = SteamCMDClient(runner: runner, paths: paths)
        self.steamCMD = steamCMD
        let gameLibrary = GameLibraryViewModel(
            steamCMD: steamCMD, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, cache: LibraryCacheStore(paths: paths),
            paths: paths, backend: initialBackend)
        self.gameLibrary = gameLibrary
        self.steamLogin = SteamLoginViewModel(steamCMD: steamCMD)

        backendSettings.onChange = { [weak gameLibrary] config in
            gameLibrary?.updateBackend(config)
        }
        steamLogin.onLoggedIn = { [weak self] username in
            guard let self else { return }
            self.backendSettings.config.steamUsername = username
            self.gameLibrary.setAccount(username: username)
            Task { await self.backendSettings.save(); await self.gameLibrary.load() }
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
        gptkManager.defaultName = state.backend.gptkRuntimeName
        gptkManager.refresh()
        runtime.defaultName = state.backend.wineRuntimeName
        await runtime.refresh()
        // Pivoted library: load the owned Windows-only catalog if a Steam account is remembered.
        gameLibrary.setAccount(username: state.backend.steamUsername)
        await gameLibrary.load()
        updateCheck = try? await updater.checkForUpdate()   // best-effort; nil on failure/offline
    }

    /// Reload the owned catalog (e.g. on app re-activation). Quiet no-op until signed in.
    public func refreshLibraryIfReady() async {
        guard didBootstrap, gameLibrary.isLoggedIn else { return }
        await gameLibrary.load()
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    public var steamLoggedIn: Bool { (backendSettings.config.steamUsername ?? "").isEmpty == false }
    public var setupComplete: Bool { wineReady && gptkReady && steamLoggedIn }

    /// Build a per-game settings view model with the game's persisted config.
    public func makeGameSettings(appID: Int, name: String) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID), appName: name, configStore: configStore)
    }

    /// A game's launch/download log (per appID).
    public nonisolated func logURL(forAppID appID: Int) -> URL {
        logStore.logURL(forAppID: appID)
    }

    /// Install dir for an owned game's bucket (for "Reveal in Finder").
    public nonisolated func gameInstallDir(forAppID appID: Int) -> URL {
        paths.gameInstallDir(forAppID: appID)
    }
}
