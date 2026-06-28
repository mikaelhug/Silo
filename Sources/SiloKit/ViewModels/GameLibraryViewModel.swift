import Foundation

/// The library = games installed in the shared **Steam bottle** (a Wine prefix running a logged-in
/// Windows Steam client). Silo discovers them from the bottle's `appmanifest_*.acf`, launches each
/// **co-resident** with the Steam client (so Steamworks/DRM works) under GPTK/D3DMetal, and triggers
/// installs/uninstalls through the bottle's Steam. No SteamCMD: the bottle's Steam is the downloader.
@MainActor
@Observable
public final class GameLibraryViewModel {
    public enum LoadState: Equatable { case idle, notReady, loaded, empty, error(String) }

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
    /// The bottle's Steam client PID (so we launch it once and don't relaunch per game).
    private var steamPID: Int32?
    private var steamObserver: (any ProcessObservation)?
    /// The in-flight Steam launch, so concurrent callers coalesce onto one instead of each starting Steam.
    private var steamLaunch: Task<Void, Never>?
    /// Seconds to wait after cold-starting Steam before launching a game (lets it boot + auto-login).
    /// Overridden to 0 in tests.
    var coldStartGraceSeconds: Double = 10

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
        do {
            let found = try await discovery.discoverGames(steamRoot: paths.steamBottleClientDir)
            games = found
            loadState = found.isEmpty ? .empty : .loaded
        } catch DiscoveryEngine.DiscoveryError.steamDirNotFound {
            games = []; loadState = .empty   // Steam installed but its library dir doesn't exist yet
        } catch {
            games = []; loadState = .error((error as NSError).localizedDescription)
        }
    }

    public func refresh() async { await load() }

    // MARK: - The co-resident Steam client

    /// Bring the bottle's Steam client up (and keep it tracked) if it isn't already running. On a cold
    /// start, waits briefly for Steam to boot, auto-login from cache, and connect before returning — so a
    /// game launched right after can actually reach it via Steamworks. Concurrent callers (two quick Play
    /// clicks, or Play + Open Steam) coalesce onto ONE launch via `steamLaunch` — `steamPID` is only set
    /// after an `await`, so without this they'd each start a second Steam client.
    private func ensureSteamRunning() async {
        if let pid = steamPID, orchestrator.isRunning(pid: pid) { return }   // already up
        if let inFlight = steamLaunch { await inFlight.value; return }       // a launch is already running
        let task = Task { @MainActor in await startSteam() }
        steamLaunch = task
        await task.value
        steamLaunch = nil
    }

    private func startSteam() async {
        guard let pid = await launchSteamProcess() else { return }
        steamPID = pid
        steamObserver = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in if self?.steamPID == pid { self?.steamPID = nil } }
        }
        if coldStartGraceSeconds > 0 { try? await Task.sleep(for: .seconds(coldStartGraceSeconds)) }
    }

    /// Launch the bottle's Steam client (re-applying the steamwebhelper wrapper first); returns the PID.
    private func launchSteamProcess() async -> Int32? {
        do {
            if let wine = backend.wineBinaryPath { try bottle.installWebHelperWrapper(wine: wine) }
            return try await bottle.launchSteam(wine: backend.wineBinaryPath)
        } catch {
            setStatus("Couldn't launch Steam: \((error as NSError).localizedDescription)")
            return nil
        }
    }

    /// Route a `steam://…` URL to the bottle's Steam, bringing it up first if needed.
    private func sendSteamURL(_ url: String) async {
        await ensureSteamRunning()
        do { try await bottle.sendURL(url, wine: backend.wineBinaryPath) }
        catch { setStatus("Couldn't reach Steam: \((error as NSError).localizedDescription)") }
    }

    // MARK: - Install / uninstall (delegated to the bottle's Steam)

    /// Open the bottle's Steam to a game's install dialog (Steam handles the download + DRM).
    public func install(appID: Int) async {
        await sendSteamURL("steam://install/\(appID)")
        setStatus("Opening Steam to install… install it there, then Refresh.")
    }

    /// Open the bottle's Steam (Store/Library) so the user can browse + install games.
    public func openSteam() async { await ensureSteamRunning() }

    /// Ask the bottle's Steam to uninstall a game, then refresh.
    public func uninstall(_ game: SteamApp) async {
        guard !isRunning(game) else { return }
        await sendSteamURL("steam://uninstall/\(game.appID)")
        setStatus("Asked Steam to uninstall \(game.name). Refresh once it's done.")
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game in the Steam bottle under GPTK, with the Steam client co-resident so Steamworks works.
    public func play(_ game: SteamApp) async {
        guard backend.isWineConfigured, !busyAppIDs.contains(game.appID), runningPIDs[game.appID] == nil else { return }
        busyAppIDs.insert(game.appID); defer { busyAppIDs.remove(game.appID) }
        do {
            // Steamworks IPC is prefix-scoped: the client must be up + logged in in this same prefix first.
            await ensureSteamRunning()
            let config = await configStore.load().config(for: game.appID)
            let pid = try await orchestrator.launchInBottle(
                app: game, config: config, backend: backend,
                prefix: paths.steamBottle, logURL: paths.log(forAppID: game.appID))
            _ = try? await configStore.updateGame(appID: game.appID) { $0.lastPlayed = Date() }
            runningPIDs[game.appID] = pid
            observeRun(appID: game.appID, pid: pid)
            setStatus("Launched \(game.name).")
        } catch {
            setStatus("\(game.name): \((error as NSError).localizedDescription)")
        }
    }

    /// Stop a running game. Terminates just the game (the shared bottle keeps Steam alive — a
    /// `wineserver -k` would kill the co-resident Steam client too). See `LaunchOrchestrator.stopGame`.
    public func stop(_ game: SteamApp) async {
        guard let pid = runningPIDs[game.appID] else { return }
        let config = await configStore.load().config(for: game.appID)
        let exeName = orchestrator.resolvedExecutableName(app: game, config: config)
        await orchestrator.stopGame(pid: pid, exeName: exeName, prefix: paths.steamBottle, backend: backend)
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
