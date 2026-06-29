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
    /// The single owner of the live bottle Steam client (shared by the Library + the settings pane).
    public let steamClientSession: SteamClientSession
    public let steamStore = SteamStoreClient()
    private let updater: Updater
    public private(set) var updateCheck: Updater.UpdateCheck?
    public private(set) var updateState: UpdateState = .idle
    public private(set) var didBootstrap = false
    private var isBootstrapping = false

    /// Progress of the inline (download + self-replace + relaunch) update.
    public enum UpdateState: Sendable, Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    public init(
        paths: AppPaths = .standard(),
        runner: ProcessRunning = SystemProcessRunner(),
        updater: Updater? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.updater = updater ?? Updater(runner: runner)

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
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        let bottle = SteamBottle(runner: runner, paths: paths)
        let steamClientSession = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        self.steamClientSession = steamClientSession
        let gameLibrary = GameLibraryViewModel(
            bottle: bottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend, session: steamClientSession)
        self.gameLibrary = gameLibrary
        let steamBottleVM = SteamBottleViewModel(bottle: bottle, session: steamClientSession)
        self.steamBottleVM = steamBottleVM

        backendSettings.onChange = { [weak self] in self?.applyBackend($0) }
        gptkManager.onDefaultChanged = { [weak self] install in
            Task { await self?.backendSettings.applyDefaultGPTK(install) }
        }
        runtime.onDefaultChanged = { [weak self] wine in
            Task { await self?.backendSettings.applyDefaultWine(wine) }
        }
    }

    /// Fan out a backend-config change to the view models that depend on it.
    private func applyBackend(_ config: BackendConfig) {
        gameLibrary.updateBackend(config)
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
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        updateCheck = try? await updater.checkForUpdate()   // best-effort; nil on failure/offline
        didBootstrap = true
        isBootstrapping = false
    }

    /// Reload the bottle's game library (e.g. on app re-activation).
    public func refreshLibraryIfReady() async {
        guard didBootstrap, gameLibrary.steamReady else { return }
        await gameLibrary.load()
    }

    /// Apply the available update **inline** (Sparkle-style): download the release, swap the running
    /// `Silo.app` in place, and relaunch — no browser hop or manual install. No-op without a newer
    /// release; surfaces a recoverable `.failed` state when not running from an `.app` bundle (dev/CLI)
    /// or on a download/install error. On success it relaunches and never returns. Surfaced by the General
    /// settings tab (`GeneralSettingsView`).
    public func installUpdate() async {
        guard let check = updateCheck, check.isNewer else { return }
        guard let appBundle = Updater.runningAppBundle() else {
            updateState = .failed("Silo isn't running from an installed app bundle.")
            return
        }
        updateState = .downloading
        do {
            let zip = try await updater.downloadUpdate(check, into: paths.updatesDir)
            updateState = .installing
            try await updater.installUpdate(zip: zip, replacing: appBundle)
            await updater.relaunch(appBundle)   // launches the new build + exit(0); never returns
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Windows Steam client is installed in the bottle (the user signs into it in-app).
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    /// Build a per-game settings view model with the game's persisted config.
    public func makeGameSettings(appID: Int) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID), configStore: configStore)
    }

    /// A game's launch log (per appID).
    public nonisolated func logURL(forAppID appID: Int) -> URL {
        paths.log(forAppID: appID)
    }
}
