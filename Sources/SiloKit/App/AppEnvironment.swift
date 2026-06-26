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

    public let library: LibraryViewModel
    public let backendSettings: BackendSettingsViewModel
    public let runtime: RuntimeViewModel
    public private(set) var didBootstrap = false

    public init(paths: AppPaths = .standard(), runner: ProcessRunning = SystemProcessRunner()) {
        self.paths = paths
        self.runner = runner

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
        let library = LibraryViewModel(
            discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, provisioner: provisioner, backend: initialBackend)
        self.library = library
        self.backendSettings = BackendSettingsViewModel(
            config: initialBackend, resolver: BackendResolver(), configStore: configStore,
            steamInstaller: SteamBottleInstaller(runner: runner), paths: paths)
        self.runtime = RuntimeViewModel(
            manager: runtimeManager, repo: Silo.defaultRuntimeRepo,
            gptkImporter: GPTKImporter(runner: runner, paths: paths))

        backendSettings.onChange = { [weak library] config in library?.updateBackend(config) }
        runtime.onGPTKImported = { [weak self] result in
            guard let self else { return }
            self.backendSettings.config.gptkLibDirPath = result.gptkLibDir
            Task { await self.backendSettings.save() }
        }
    }

    /// Load persisted config and populate the UI. Idempotent.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        let state = await configStore.load()
        backendSettings.config = state.backend
        library.updateBackend(state.backend)
        await library.refresh()
        await runtime.refreshInstalled()
    }

    /// Build a per-game settings view model with the game's persisted config.
    public func makeGameSettings(for app: SteamApp) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: app.appID), appName: app.name, configStore: configStore)
    }

    public func readLog(for app: SteamApp) async -> String {
        await logStore.read(appID: app.appID)
    }

    public nonisolated func logURL(for app: SteamApp) -> URL {
        logStore.logURL(forAppID: app.appID)
    }
}
