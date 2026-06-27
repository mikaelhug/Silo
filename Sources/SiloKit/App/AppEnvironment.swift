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
    public let gptkManager: GPTKManagerViewModel
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
        let library = LibraryViewModel(
            discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, provisioner: provisioner,
            libraryInstaller: SteamLibraryInstaller(runner: runner), backend: initialBackend)
        self.library = library
        self.backendSettings = BackendSettingsViewModel(
            config: initialBackend, resolver: BackendResolver(), configStore: configStore,
            steamInstaller: SteamBottleInstaller(runner: runner), paths: paths)
        self.runtime = RuntimeViewModel(manager: runtimeManager, repo: Silo.wineRepo)
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        backendSettings.onChange = { [weak library] config in library?.updateBackend(config) }
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
        library.updateBackend(state.backend)
        gptkManager.defaultName = state.backend.gptkRuntimeName
        gptkManager.refresh()
        runtime.defaultName = state.backend.wineRuntimeName
        await runtime.refresh()
        await library.refresh()
        updateCheck = try? await updater.checkForUpdate()   // best-effort; nil on failure/offline
    }

    /// Re-scan the library (e.g. after returning from Steam). Quiet no-op if not set up.
    public func refreshLibraryIfReady() async {
        guard didBootstrap, setupComplete else { return }
        await library.refresh()
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    public var steamReady: Bool { backendSettings.config.masterBottlePath != nil }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    /// The Master Steam client log (written by `openSteam`).
    public nonisolated var steamLogURL: URL { paths.logsDir.appendingPathComponent("steam.log") }

    /// Launch the Steam client in the Master bottle (detached) so the user can browse/download games.
    public func openSteam() async {
        guard let bottle = backendSettings.config.masterBottlePath else { return }
        let steamExe = DiscoveryEngine.steamRoot(inBottle: bottle).appendingPathComponent("steam.exe")
        guard let wine = await spawnInMasterBottle([steamExe.path] + Silo.steamLaunchArgs, logName: "steam.log")
        else { return }
        // Safety net: if Steam's CEF ever crash-loops again, kill the bottle before it floods the Mac.
        Task.detached { [runner] in
            await CrashLoopGuard(runner: runner).monitor(wine: wine, bottle: bottle)
        }
    }

    /// Open winecfg against the Master Steam bottle (detached).
    public func openMasterWinecfg() async {
        await spawnInMasterBottle(["winecfg"], logName: "winecfg.log")
    }

    /// Spawn a command detached in the Master Steam bottle. Returns the wine binary used (for follow-up
    /// like the crash-loop guard), or nil if the bottle/wine isn't configured.
    @discardableResult
    private func spawnInMasterBottle(_ arguments: [String], logName: String) async -> URL? {
        let config = backendSettings.config
        guard let bottle = config.masterBottlePath, let wine = config.steamWine else { return nil }
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: arguments,
            environment: Silo.wineEnvironment(prefix: bottle, wine: wine),
            currentDirectory: nil, logURL: paths.logsDir.appendingPathComponent(logName))
        return wine
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
