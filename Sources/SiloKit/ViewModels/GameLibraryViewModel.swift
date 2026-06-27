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
    public private(set) var busyAppIDs: Set<Int> = []
    public private(set) var downloadingIDs: Set<Int> = []
    public private(set) var runningPIDs: [Int: Int32] = [:]   // appID → launched wine PID
    public var searchText: String = ""
    public var statusMessage: String?

    private let steamCMD: SteamCMDClient
    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let paths: AppPaths
    private var backend: BackendConfig
    private var username: String?
    private var monitorTask: Task<Void, Never>?
    private var downloadMonitor: Task<Void, Never>?

    public init(
        steamCMD: SteamCMDClient,
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        paths: AppPaths,
        backend: BackendConfig
    ) {
        self.steamCMD = steamCMD
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
    }

    public func setAccount(username: String?) { self.username = username }
    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    public var canLaunch: Bool { backend.isWineConfigured }
    public var isLoggedIn: Bool { !(username ?? "").isEmpty }
    public var installedCount: Int { owned.filter { isInstalled($0) }.count }

    /// Search + sort: installed first, then downloading, then by name.
    public var filtered: [SteamAppInfo] {
        let base = searchText.isEmpty ? owned
            : owned.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
        downloadingIDs.contains(info.appID) || (installedByID[info.appID].map { !$0.isFullyInstalled } ?? false)
    }
    public func isRunning(_ info: SteamAppInfo) -> Bool { runningPIDs[info.appID] != nil }
    public func isBusy(_ info: SteamAppInfo) -> Bool { busyAppIDs.contains(info.appID) }

    /// `0...1` download progress for a game being fetched, else nil.
    public func downloadProgress(_ info: SteamAppInfo) -> Double? { installedByID[info.appID]?.downloadProgress }
    /// Human-readable on-disk size for an installed game, else nil.
    public func sizeString(_ info: SteamAppInfo) -> String? {
        guard let size = installedByID[info.appID]?.sizeOnDisk, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func refreshInstalled() async {
        let found = (try? await discovery.discoverGames(steamRoot: paths.gameLibraryDir)) ?? []
        installedByID = Dictionary(found.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Catalog

    /// Load the owned Windows-only catalog from SteamCMD (requires a signed-in username) + install state.
    public func load() async {
        await refreshInstalled()
        guard let username, !username.isEmpty else { loadState = .needsLogin; return }
        loadState = .loading
        do {
            owned = try await steamCMD.ownedWindowsGames(username: username)
            loadState = owned.isEmpty ? .empty : .loaded
        } catch {
            loadState = .error((error as NSError).localizedDescription)
        }
    }

    // MARK: - Download

    /// Download (or update) a game's Windows files into its bucket via SteamCMD (detached), then poll
    /// its appmanifest for live progress until it finishes.
    public func download(_ info: SteamAppInfo) async {
        guard let username, !busyAppIDs.contains(info.appID) else { return }
        busyAppIDs.insert(info.appID); defer { busyAppIDs.remove(info.appID) }
        statusMessage = "Starting download: \(info.name)…"
        do {
            _ = try await steamCMD.download(appID: info.appID, username: username,
                                            logURL: paths.log(forAppID: info.appID))
            downloadingIDs.insert(info.appID)
            startDownloadMonitor()
            statusMessage = "Downloading \(info.name)…"
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

    private func startDownloadMonitor() {
        guard downloadMonitor == nil else { return }
        downloadMonitor = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.downloadingIDs.isEmpty else { break }
                await self.refreshInstalled()
                for id in self.downloadingIDs where self.installedByID[id]?.isFullyInstalled == true {
                    self.downloadingIDs.remove(id)
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
