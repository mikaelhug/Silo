import Foundation

/// The pivoted library: the signed-in account's owned **Windows-only** games. Each is downloaded with
/// SteamCMD into its own bucket (`AppPaths.gameInstallDir`) and launched via GPTK by `LaunchOrchestrator`.
@MainActor
@Observable
public final class GameLibraryViewModel {
    public enum LoadState: Equatable { case idle, needsLogin, loading, loaded, empty, error(String) }

    public private(set) var owned: [SteamAppInfo] = []
    /// Install state per appID, parsed from each bucket's `appmanifest_*.acf` (size + download progress).
    public private(set) var installedByID: [Int: SteamApp] = [:]
    public private(set) var loadState: LoadState = .idle
    public private(set) var isRefreshing = false
    public private(set) var busyAppIDs: Set<Int> = []
    public private(set) var downloadingIDs: Set<Int> = []
    public private(set) var downloadSpeeds: [Int: Double] = [:]   // appID → bytes/sec
    public private(set) var runningPIDs: [Int: Int32] = [:]   // appID → launched wine PID
    private var downloadPIDs: [Int: Int32] = [:]             // appID → SteamCMD PID (this session)
    private var lastBytes: [Int: (bytes: Int64, at: Date)] = [:]
    public var searchText: String = ""
    /// Hide games that also have a native macOS build (run those in the Steam app instead). On by
    /// default — Silo is for the games that *need* Wine/GPTK.
    public var showWindowsOnly: Bool = true
    public var statusMessage: String?

    private let steamCMD: SteamCMDClient
    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let cache: LibraryCacheStore
    private let paths: AppPaths
    private var backend: BackendConfig
    private var username: String?
    private var monitorTask: Task<Void, Never>?
    private var downloadMonitor: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(
        steamCMD: SteamCMDClient,
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        cache: LibraryCacheStore,
        paths: AppPaths,
        backend: BackendConfig
    ) {
        self.steamCMD = steamCMD
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.cache = cache
        self.paths = paths
        self.backend = backend
    }

    public func setAccount(username: String?) { self.username = username }
    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    public var canLaunch: Bool { backend.isWineConfigured }
    public var isLoggedIn: Bool { !(username ?? "").isEmpty }
    public var installedCount: Int { owned.filter { isInstalled($0) }.count }

    /// Search + Windows-only toggle + sort: installed first, then downloading, then by name.
    public var filtered: [SteamAppInfo] {
        var base = searchText.isEmpty ? owned
            : owned.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        if showWindowsOnly { base = base.filter { !$0.supportsMac } }
        // Precompute ranks on the main actor so the (non-isolated) sort closure only compares values.
        let ranked = base.map { (game: $0, rank: isInstalled($0) ? 0 : (isDownloading($0) ? 1 : 2)) }
        return ranked.sorted { a, b in
            a.rank == b.rank
                ? a.game.name.localizedCaseInsensitiveCompare(b.game.name) == .orderedAscending
                : a.rank < b.rank
        }.map(\.game)
    }

    // MARK: - Install state

    public func isInstalled(_ info: SteamAppInfo) -> Bool { installedByID[info.appID]?.isFullyInstalled == true }
    public func isDownloading(_ info: SteamAppInfo) -> Bool {
        downloadingIDs.contains(info.appID) || installedByID[info.appID]?.stateFlags.isDownloading == true
    }
    public func isRunning(_ info: SteamAppInfo) -> Bool { runningPIDs[info.appID] != nil }
    public func isBusy(_ info: SteamAppInfo) -> Bool { busyAppIDs.contains(info.appID) }
    /// Partially downloaded but not actively running (e.g. interrupted by a closed app or lost network).
    /// SteamCMD's app_update resumes from here — surfaced as a "Resume" action.
    public func isPaused(_ info: SteamAppInfo) -> Bool {
        guard let app = installedByID[info.appID] else { return false }
        return !app.isFullyInstalled && !isDownloading(info)
    }

    /// `0...1` download progress for a game being fetched, else nil.
    public func downloadProgress(_ info: SteamAppInfo) -> Double? { installedByID[info.appID]?.downloadProgress }
    /// Human-readable on-disk size for an installed game, else nil.
    public func sizeString(_ info: SteamAppInfo) -> String? {
        guard let size = installedByID[info.appID]?.sizeOnDisk, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    /// Current download speed (e.g. "12.3 MB/s") for an in-progress game, else nil.
    public func speedString(_ info: SteamAppInfo) -> String? {
        guard let bps = downloadSpeeds[info.appID], bps > 1 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
    /// Estimated time remaining (e.g. "4 min") for an in-progress game, else nil.
    public func etaString(_ info: SteamAppInfo) -> String? {
        guard let app = installedByID[info.appID], let total = app.bytesToDownload,
              let done = app.bytesDownloaded, total > done,
              let bps = downloadSpeeds[info.appID], bps > 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: Double(total - done) / bps)
    }
    /// Owned games currently downloading (for the status bar).
    public var activeDownloads: [SteamAppInfo] { owned.filter { isDownloading($0) } }

    private func refreshInstalled() async {
        let found = (try? await discovery.discoverGames(steamRoot: paths.gameLibraryDir)) ?? []
        installedByID = Dictionary(found.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        // Re-attach to a download already in progress — e.g. a SteamCMD orphaned when the app was closed
        // mid-download keeps running and updating its appmanifest; pick its progress back up.
        var reattached = false
        for app in found where app.stateFlags.isDownloading && !downloadingIDs.contains(app.appID) {
            downloadingIDs.insert(app.appID); reattached = true
        }
        if reattached { startDownloadMonitor() }
    }

    // MARK: - Catalog

    /// Show the cached catalog **instantly**, then refresh from SteamCMD in the background and merge —
    /// so launch is fast, the cold-cache "random subset" converges to the full set, and nothing that
    /// was showing disappears on a flaky refresh.
    public func load() async {
        await refreshInstalled()
        guard let username, !username.isEmpty else { loadState = .needsLogin; return }
        if let cached = await cache.load(), cached.username == username {
            owned = cached.games.filter(\.windowsPlayable)   // self-heal: drop anything stale that isn't a Windows game
        }
        if owned.isEmpty { loadState = .loading } else { loadState = .loaded }
        startRefresh(username: username)
    }

    /// Manual refresh (toolbar) — re-enumerate in the background and merge into the cache.
    public func refresh() async {
        guard let username, !username.isEmpty else { loadState = .needsLogin; return }
        await refreshInstalled()
        startRefresh(username: username)
    }

    private func startRefresh(username: String) {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh(username: username)
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }

    /// Enumerate from SteamCMD and merge into the catalog (awaitable; `startRefresh` wraps it in a Task).
    func performRefresh(username: String) async {
        if let fresh = try? await steamCMD.ownedGames(username: username) {
            let snapshot = merge(fresh)
            await cache.save(username: username, games: snapshot, at: Date())
        } else if owned.isEmpty {
            loadState = .error("Couldn't reach Steam — try Refresh.")
        }
    }

    /// Union the fresh catalog into what we have (newer metadata wins; cached-but-missing games are kept,
    /// guarding against a partial cold-cache enumeration). Returns the merged snapshot to persist.
    @discardableResult
    private func merge(_ fresh: [SteamAppInfo]) -> [SteamAppInfo] {
        var byID = Dictionary(owned.map { ($0.appID, $0) }, uniquingKeysWith: { _, new in new })
        for game in fresh { byID[game.appID] = game }
        owned = byID.values
            .filter(\.windowsPlayable)   // drop stale non-games (e.g. cached Proton/un-typed apps)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadState = owned.isEmpty ? .empty : .loaded
        return owned
    }

    // MARK: - Download

    /// Download (or update) a game's Windows files into its bucket via SteamCMD (detached), then poll
    /// its appmanifest for live progress until it finishes.
    public func download(_ info: SteamAppInfo) async {
        guard let username, !busyAppIDs.contains(info.appID), !downloadingIDs.contains(info.appID) else { return }
        busyAppIDs.insert(info.appID); defer { busyAppIDs.remove(info.appID) }
        do {
            // app_update resumes from any kept partial — this same call is "Download" and "Resume".
            let pid = try await steamCMD.download(appID: info.appID, username: username,
                                                  logURL: paths.log(forAppID: info.appID))
            downloadPIDs[info.appID] = pid
            downloadingIDs.insert(info.appID)   // the status bar tracks progress + speed from here
            startDownloadMonitor()
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

    /// Cancel a download and discard the partial files.
    public func cancel(_ info: SteamAppInfo) async {
        steamCMD.cancelDownload(appID: info.appID, pid: downloadPIDs[info.appID])
        downloadingIDs.remove(info.appID)
        downloadSpeeds[info.appID] = nil
        lastBytes[info.appID] = nil
        downloadPIDs[info.appID] = nil
        await refreshInstalled()
        statusMessage = "Cancelled \(info.name)."
    }

    private func startDownloadMonitor() {
        guard downloadMonitor == nil else { return }
        downloadMonitor = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.downloadingIDs.isEmpty else { break }
                await self.refreshInstalled()
                let now = Date()
                for id in self.downloadingIDs {
                    if self.installedByID[id]?.isFullyInstalled == true {
                        self.downloadingIDs.remove(id)
                        self.downloadSpeeds[id] = nil; self.lastBytes[id] = nil
                        self.statusMessage = "\(self.installedByID[id]?.name ?? "Game") finished downloading."
                        continue
                    }
                    // Speed = Δbytes / Δtime between polls.
                    guard let done = self.installedByID[id]?.bytesDownloaded else { continue }
                    if let prev = self.lastBytes[id], now.timeIntervalSince(prev.at) > 0.5 {
                        self.downloadSpeeds[id] = max(0, Double(done - prev.bytes) / now.timeIntervalSince(prev.at))
                    }
                    self.lastBytes[id] = (done, now)
                }
                if self.downloadingIDs.isEmpty { break }
            }
            self?.downloadMonitor = nil
        }
    }

    // MARK: - Launch

    /// Launch an installed game in its isolated GPTK bucket.
    public func play(_ info: SteamAppInfo) async {
        guard backend.isWineConfigured, !busyAppIDs.contains(info.appID),
              runningPIDs[info.appID] == nil else { return }
        busyAppIDs.insert(info.appID); defer { busyAppIDs.remove(info.appID) }
        do {
            let config = await configStore.load().config(for: info.appID)
            let pid = try await orchestrator.launch(app: steamApp(for: info), config: config, backend: backend)
            var stamped = config; stamped.lastPlayed = Date()
            _ = try? await configStore.saveGame(stamped)
            runningPIDs[info.appID] = pid
            statusMessage = "Launched \(info.name)."
            startMonitor()
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

    public func stop(_ info: SteamAppInfo) async {
        guard runningPIDs[info.appID] != nil else { return }
        await orchestrator.stop(appID: info.appID, backend: backend)
        runningPIDs[info.appID] = nil
    }

    public func openWinecfg(_ info: SteamAppInfo) async {
        guard backend.isWineConfigured else { statusMessage = "No Wine configured."; return }
        await orchestrator.runWineTool("winecfg", appID: info.appID, backend: backend)
    }

    /// Bridge owned metadata → the `SteamApp` the launch pipeline expects. Prefer the installed manifest
    /// (real installDir/name); fall back to the bucket layout that matches SteamCMD's force_install_dir.
    private func steamApp(for info: SteamAppInfo) -> SteamApp {
        installedByID[info.appID]
            ?? SteamApp(appID: info.appID, name: info.name, installDir: String(info.appID),
                        stateFlags: .fullyInstalled, sizeOnDisk: 0, libraryPath: paths.gameLibraryDir)
    }

    private func startMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.runningPIDs.isEmpty else { break }
                for (appID, pid) in self.runningPIDs where !self.orchestrator.isRunning(pid: pid) {
                    self.runningPIDs[appID] = nil
                }
                if self.runningPIDs.isEmpty { break }
            }
            self?.monitorTask = nil
        }
    }
}
