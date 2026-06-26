import Foundation

@MainActor
@Observable
public final class LibraryViewModel {
    public enum LoadState: Equatable {
        case idle, loading, loaded, empty
        case error(String)
    }

    public enum SortOrder: String, CaseIterable, Identifiable {
        case name, recentlyPlayed
        public var id: String { rawValue }
        public var label: String { self == .name ? "Name" : "Recently played" }
    }

    public enum Filter: String, CaseIterable, Identifiable {
        case all, installed, updates
        public var id: String { rawValue }
        public var label: String {
            switch self { case .all: "All"; case .installed: "Installed"; case .updates: "Needs update" }
        }
    }

    public private(set) var games: [SteamApp] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var busyAppIDs: Set<Int> = []
    public private(set) var runningPIDs: [Int: Int32] = [:]   // appID → launched wine PID
    public private(set) var isQueueingInstalls = false
    public var searchText: String = ""
    public var sortOrder: SortOrder = .name
    public var filter: Filter = .all
    public var statusMessage: String?

    private var lastPlayedByApp: [Int: Date] = [:]
    private var monitorTask: Task<Void, Never>?

    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let provisioner: PrefixProvisioner
    private let ownedReader: OwnedAppsReader
    private let libraryInstaller: SteamLibraryInstaller
    private var backend: BackendConfig

    public init(
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        provisioner: PrefixProvisioner,
        libraryInstaller: SteamLibraryInstaller,
        ownedReader: OwnedAppsReader = OwnedAppsReader(),
        backend: BackendConfig
    ) {
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.provisioner = provisioner
        self.libraryInstaller = libraryInstaller
        self.ownedReader = ownedReader
        self.backend = backend
    }

    public var filteredGames: [SteamApp] {
        var result = games
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch filter {
        case .all: break
        case .installed: result = result.filter(\.isFullyInstalled)
        case .updates: result = result.filter(\.needsUpdate)
        }
        switch sortOrder {
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyPlayed:
            result.sort { (lastPlayedByApp[$0.appID] ?? .distantPast) > (lastPlayedByApp[$1.appID] ?? .distantPast) }
        }
        return result
    }

    public func prefixURL(for app: SteamApp) -> URL { provisioner.prefixURL(forAppID: app.appID) }

    public var canLaunch: Bool { backend.isWineConfigured }
    public var canInstallLibrary: Bool { backend.isMasterBottleConfigured && backend.steamWine != nil }

    public func isRunning(_ app: SteamApp) -> Bool { runningPIDs[app.appID] != nil }

    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    /// One-click: queue downloads in Steam for every owned game (Steam must be running + logged in).
    public func installEntireLibrary() async {
        guard !isQueueingInstalls else { return }
        guard let bottle = backend.masterBottlePath, let steamRoot = backend.steamRoot else {
            statusMessage = "Configure the Master Steam bottle first."
            return
        }
        isQueueingInstalls = true
        defer { isQueueingInstalls = false }

        let owned = ownedReader.ownedAppIDs(steamRoot: steamRoot)
        guard !owned.isEmpty else {
            statusMessage = "No owned games found. Open Steam and log in first."
            return
        }
        do {
            let count = try await libraryInstaller.queueInstalls(
                appIDs: owned, bottle: bottle, wine: backend.steamWine)
            statusMessage = "Queued \(count) games for download. Confirm/monitor in the Steam client."
        } catch {
            statusMessage = "Install all failed: \(Self.message(for: error))"
        }
    }

    public func refresh() async {
        guard let steamRoot = backend.steamRoot else {
            games = []
            loadState = .error("No Master Steam bottle configured. Set one in Backend & Runtime.")
            return
        }
        loadState = .loading
        do {
            let found = try await discovery.discoverGames(steamRoot: steamRoot)
            games = found
            let state = await configStore.load()
            lastPlayedByApp = Dictionary(
                state.games.compactMap { g in g.lastPlayed.map { (g.appID, $0) } },
                uniquingKeysWith: { first, _ in first })
            loadState = found.isEmpty ? .empty : .loaded
        } catch {
            games = []
            loadState = .error(Self.message(for: error))
        }
    }

    /// Provision the isolated prefix only (no launch).
    public func isolate(_ app: SteamApp) async {
        await withBusy(app) {
            let cfg = await self.configStore.load().config(for: app.appID)
            _ = try await self.provisioner.provision(
                appID: app.appID, wineBinary: self.backend.wineBinary(for: cfg.backend))
            self.statusMessage = "Isolated prefix ready for \(app.name)."
        }
    }

    public func play(_ app: SteamApp) async {
        guard !busyAppIDs.contains(app.appID), runningPIDs[app.appID] == nil else { return }
        busyAppIDs.insert(app.appID)
        defer { busyAppIDs.remove(app.appID) }
        do {
            var cfg = await configStore.load().config(for: app.appID)
            let pid = try await orchestrator.launch(app: app, config: cfg, backend: backend)
            cfg.lastPlayed = Date()
            _ = try? await configStore.saveGame(cfg)
            lastPlayedByApp[app.appID] = cfg.lastPlayed
            runningPIDs[app.appID] = pid
            statusMessage = "Launched \(app.name)."
            startMonitor()
        } catch {
            statusMessage = "\(app.name): \(Self.message(for: error))"
        }
    }

    /// Stop a running game (kills the wine processes in its prefix).
    public func stop(_ app: SteamApp) async {
        guard runningPIDs[app.appID] != nil else { return }
        await orchestrator.stop(appID: app.appID, backend: backend)
        runningPIDs[app.appID] = nil
    }

    /// Delete a game's isolated prefix (it will be re-seeded on next launch).
    public func resetPrefix(_ app: SteamApp) async {
        guard runningPIDs[app.appID] == nil else {
            statusMessage = "Stop \(app.name) before resetting its prefix."
            return
        }
        do {
            try await provisioner.remove(appID: app.appID)
            statusMessage = "Reset prefix for \(app.name)."
        } catch {
            statusMessage = "Couldn't reset prefix: \(Self.message(for: error))"
        }
    }

    /// Open winecfg against a game's prefix.
    public func openWinecfg(_ app: SteamApp) async {
        guard backend.isWineConfigured else { statusMessage = "No Wine configured."; return }
        await orchestrator.runWineTool("winecfg", appID: app.appID, backend: backend)
    }

    // MARK: - Helpers

    /// Poll launched games; prune ones that have exited and refresh install state when they do.
    private func startMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.runningPIDs.isEmpty else { break }
                let finished = self.runningPIDs.filter { !self.orchestrator.isRunning(pid: $0.value) }
                if !finished.isEmpty {
                    for appID in finished.keys { self.runningPIDs[appID] = nil }
                    await self.refresh()
                }
                if self.runningPIDs.isEmpty { break }
            }
            self?.monitorTask = nil
        }
    }

    private func withBusy(_ app: SteamApp, _ work: () async throws -> Void) async {
        guard !busyAppIDs.contains(app.appID) else { return }
        busyAppIDs.insert(app.appID)
        defer { busyAppIDs.remove(app.appID) }
        do {
            try await work()
        } catch {
            statusMessage = "\(app.name): \(Self.message(for: error))"
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case DiscoveryEngine.DiscoveryError.steamDirNotFound:
            "Steam folder not found in the Master bottle."
        case LaunchOrchestrator.LaunchError.wineNotConfigured,
             PrefixProvisioner.ProvisionError.wineNotConfigured:
            "No Wine binary configured. Set one in Backend & Runtime."
        case LaunchOrchestrator.LaunchError.executableNotFound:
            "Could not find the game executable. Set it in the game's settings."
        default:
            (error as NSError).localizedDescription
        }
    }
}
