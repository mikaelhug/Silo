import Foundation

/// The library = games installed in the shared **Steam bottle** (a Wine prefix running a logged-in
/// Windows Steam client). Silo discovers them from the bottle's `appmanifest_*.acf`, launches each
/// **co-resident** with the Steam client (so Steamworks/DRM works) under GPTK/D3DMetal, and triggers
/// installs/uninstalls through the bottle's Steam. No SteamCMD: the bottle's Steam is the downloader.
@MainActor
@Observable
public final class GameLibraryViewModel {
    public enum LoadState: Equatable { case idle, notReady, loading, loaded, empty, error(String) }

    /// Games installed in the Steam bottle (parsed from its `appmanifest_*.acf`).
    public private(set) var games: [SteamApp] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var busyAppIDs: Set<Int> = []
    public private(set) var runningPIDs: [Int: Int32] = [:]
    public var searchText: String = ""
    public private(set) var statusMessage: String?
    private var statusDismiss: Task<Void, Never>?

    private let bottle: SteamBottle
    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let paths: AppPaths
    private var backend: BackendConfig
    private var runObservers: [Int: any ProcessObservation] = [:]

    public init(
        bottle: SteamBottle,
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        paths: AppPaths,
        backend: BackendConfig
    ) {
        self.bottle = bottle
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
    }

    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    public var canLaunch: Bool { backend.isWineConfigured }
    public var steamReady: Bool { bottle.isSteamInstalled }

    /// Search filter over the installed games (already name-sorted by `DiscoveryEngine`).
    public var filtered: [SteamApp] {
        searchText.isEmpty ? games
            : games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public func isRunning(_ game: SteamApp) -> Bool { runningPIDs[game.appID] != nil }
    public func isBusy(_ game: SteamApp) -> Bool { busyAppIDs.contains(game.appID) }

    public func sizeString(_ game: SteamApp) -> String? {
        guard game.sizeOnDisk > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)
    }

    private func setStatus(_ message: String?) {
        statusMessage = message
        statusDismiss?.cancel()
        guard message != nil else { return }
        statusDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: - Library

    /// Re-scan the bottle's Steam library for installed games.
    public func load() async {
        guard bottle.isSteamInstalled else { loadState = .notReady; return }
        let found = (try? await discovery.discoverGames(steamRoot: paths.steamBottleClientDir)) ?? []
        games = found
        loadState = found.isEmpty ? .empty : .loaded
    }

    public func refresh() async { await load() }

    // MARK: - Install / uninstall (delegated to the bottle's Steam)

    /// Open the bottle's Steam to a game's install dialog (Steam handles the download + DRM).
    public func install(appID: Int) async {
        await launchSteam(extra: ["steam://install/\(appID)"])
        setStatus("Opening Steam to install… install it there, then Refresh.")
    }

    /// Open the bottle's Steam (Store/Library) so the user can browse + install games.
    public func openSteam() async { await launchSteam(extra: []) }

    /// Ask the bottle's Steam to uninstall a game, then refresh.
    public func uninstall(_ game: SteamApp) async {
        guard !isRunning(game) else { return }
        await launchSteam(extra: ["steam://uninstall/\(game.appID)"])
        setStatus("Asked Steam to uninstall \(game.name). Refresh once it's done.")
    }

    private func launchSteam(extra: [String]) async {
        do {
            if let wine = backend.wineBinaryPath { try? bottle.installWebHelperWrapper(wine: wine) }
            _ = try await bottle.launchSteam(wine: backend.wineBinaryPath,
                                             extraArgs: SteamBottle.cefRenderArgs + extra)
        } catch {
            setStatus("Couldn't launch Steam: \((error as NSError).localizedDescription)")
        }
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game in the Steam bottle under GPTK, with the Steam client co-resident so Steamworks works.
    public func play(_ game: SteamApp) async {
        guard backend.isWineConfigured, !busyAppIDs.contains(game.appID), runningPIDs[game.appID] == nil else { return }
        busyAppIDs.insert(game.appID); defer { busyAppIDs.remove(game.appID) }
        do {
            // Make sure the co-resident Steam client is up first (Steamworks IPC needs it in this prefix).
            await launchSteam(extra: [])
            let config = await configStore.load().config(for: game.appID)
            let pid = try await orchestrator.launchInBottle(
                app: game, config: config, backend: backend,
                prefix: paths.steamBottle, logURL: paths.log(forAppID: game.appID))
            var stamped = config; stamped.lastPlayed = Date()
            _ = try? await configStore.saveGame(stamped)
            runningPIDs[game.appID] = pid
            observeRun(appID: game.appID, pid: pid)
            setStatus("Launched \(game.name).")
        } catch {
            setStatus("\(game.name): \((error as NSError).localizedDescription)")
        }
    }

    /// Stop a running game. Terminates just the game process (the shared bottle keeps Steam alive — a
    /// `wineserver -k` would kill the co-resident Steam client too).
    public func stop(_ game: SteamApp) async {
        guard let pid = runningPIDs[game.appID] else { return }
        orchestrator.terminate(pid: pid)
        clearRunState(game.appID)
    }

    public func openWinecfg(_ game: SteamApp) async {
        guard backend.isWineConfigured else { setStatus("No Wine configured."); return }
        await orchestrator.runWineTool("winecfg", prefix: paths.steamBottle, backend: backend)
    }

    private func observeRun(appID: Int, pid: Int32) {
        runObservers[appID]?.cancel()
        runObservers[appID] = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in self?.gameDidExit(appID: appID, pid: pid) }
        }
    }

    private func gameDidExit(appID: Int, pid: Int32) {
        guard runningPIDs[appID] == pid else { return }
        clearRunState(appID)
    }

    private func clearRunState(_ id: Int) {
        runningPIDs[id] = nil
        runObservers[id]?.cancel(); runObservers[id] = nil
    }
}
