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
    public private(set) var downloadProgressByID: [Int: Double] = [:]   // appID → 0...1 (from the log)
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
    private var refreshTask: Task<Void, Never>?
    /// kqueue observers (no polling): per-download [log-write, process-exit] tokens, and per-game exit.
    private var downloadObservers: [Int: [any ProcessObservation]] = [:]
    private var runObservers: [Int: any ProcessObservation] = [:]

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

    /// Search + Windows-only filter. `owned` is already name-sorted (from `merge`) and the UI groups by
    /// state in sections, so no per-access re-sort is needed — keeps this cheap during a download.
    public var filtered: [SteamAppInfo] {
        var base = owned
        if showWindowsOnly { base = base.filter { !$0.supportsMac } }
        if !searchText.isEmpty { base = base.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return base
    }

    // MARK: - Install state

    public func isInstalled(_ info: SteamAppInfo) -> Bool { installedByID[info.appID]?.isFullyInstalled == true }
    public func isDownloading(_ info: SteamAppInfo) -> Bool { downloadingIDs.contains(info.appID) }
    public func isRunning(_ info: SteamAppInfo) -> Bool { runningPIDs[info.appID] != nil }
    public func isBusy(_ info: SteamAppInfo) -> Bool { busyAppIDs.contains(info.appID) }
    /// Partially downloaded but not actively running (e.g. interrupted by a closed app or lost network).
    /// SteamCMD's app_update resumes from here — surfaced as a "Resume" action.
    public func isPaused(_ info: SteamAppInfo) -> Bool {
        installedByID[info.appID] != nil && !isInstalled(info) && !isDownloading(info)
    }

    /// `0...1` download progress — live from the SteamCMD log while active, else the manifest's bytes.
    public func downloadProgress(_ info: SteamAppInfo) -> Double? {
        downloadProgressByID[info.appID] ?? installedByID[info.appID]?.downloadProgress
    }
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

    /// Re-parse every bucket's `appmanifest_*.acf` into `installedByID` (pure file read — no process
    /// probes). SteamCMD's `force_install_dir` nests each manifest at
    /// `<gameLibrary>/steamapps/common/<appID>/steamapps/appmanifest_<appID>.acf`, so scan each bucket
    /// and normalise the `SteamApp` to the bucket layout (installURL = the bucket, matching launch).
    private func refreshInstalled() async {
        let common = paths.gameLibraryDir.appendingPathComponent("steamapps/common")
        let buckets = (try? FileManager.default.contentsOfDirectory(atPath: common.path)) ?? []
        var byID: [Int: SteamApp] = [:]
        for bucket in buckets {
            guard let appID = Int(bucket) else { continue }
            let bucketURL = common.appendingPathComponent(bucket)
            guard let apps = try? await discovery.discoverGames(steamRoot: bucketURL),
                  let app = apps.first(where: { $0.appID == appID }) else { continue }
            byID[appID] = SteamApp(
                appID: appID, name: app.name, installDir: String(appID),
                stateFlags: app.stateFlags, sizeOnDisk: app.sizeOnDisk,
                bytesDownloaded: app.bytesDownloaded, bytesToDownload: app.bytesToDownload,
                buildID: app.buildID, lastUpdated: app.lastUpdated, libraryPath: paths.gameLibraryDir)
        }
        installedByID = byID
    }

    /// Re-attach to any SteamCMD download still running for a partially-installed bucket (e.g. orphaned
    /// when the app was closed mid-download). Looks up the live PID once, then observes it — no polling.
    private func reattachOrphanedDownloads() async {
        for (appID, app) in installedByID where !app.isFullyInstalled && !downloadingIDs.contains(appID) {
            guard let pid = await steamCMD.downloadPID(appID: appID) else { continue }
            downloadPIDs[appID] = pid
            downloadingIDs.insert(appID)
            observeDownload(appID: appID, pid: pid)
        }
    }

    // MARK: - Catalog

    /// Show the cached catalog **instantly**, then refresh from SteamCMD in the background and merge —
    /// so launch is fast, the cold-cache "random subset" converges to the full set, and nothing that
    /// was showing disappears on a flaky refresh.
    public func load() async {
        await refreshInstalled()
        await reattachOrphanedDownloads()
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
        await reattachOrphanedDownloads()
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

    /// Download (or update) a game's Windows files into its bucket via SteamCMD (detached). Progress is
    /// read **reactively** from the SteamCMD log (a kqueue file-watcher), and completion/interruption is
    /// detected from the process's exit — no polling.
    public func download(_ info: SteamAppInfo) async {
        guard let username, !busyAppIDs.contains(info.appID), !downloadingIDs.contains(info.appID) else { return }
        busyAppIDs.insert(info.appID); defer { busyAppIDs.remove(info.appID) }
        do {
            // app_update resumes from any kept partial — this same call is "Download" and "Resume".
            let pid = try await steamCMD.download(appID: info.appID, username: username,
                                                  logURL: paths.log(forAppID: info.appID))
            downloadPIDs[info.appID] = pid
            lastBytes[info.appID] = nil
            downloadingIDs.insert(info.appID)   // the status bar tracks progress + speed from here
            observeDownload(appID: info.appID, pid: pid)
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

    /// Wire up reactive progress (log writes) + completion (process exit) for an active download.
    private func observeDownload(appID: Int, pid: Int32) {
        let log = paths.log(forAppID: appID)
        cancelDownloadObservers(appID)
        downloadObservers[appID] = steamCMD.observeDownload(
            pid: pid, logURL: log,
            // Both handlers run on a background queue: read + parse the log there (off the main actor),
            // then hop to the main actor with the small parsed result.
            onProgress: { [weak self] in
                let snapshot = Self.parseLog(at: log, appID: appID)
                Task { @MainActor in self?.applyProgress(appID: appID, snapshot) }
            },
            onExit: { [weak self] in
                Task { @MainActor in await self?.downloadDidExit(appID: appID) }
            })
    }

    private func applyProgress(appID id: Int, _ snapshot: (progress: SteamCMD.Progress?, finished: Bool)) {
        guard downloadingIDs.contains(id) else { return }   // a late write after we already finished
        if snapshot.finished { endDownload(id, installed: true); Task { await refreshInstalled() }; return }
        guard let p = snapshot.progress else { return }
        if downloadProgressByID[id] != p.fraction { downloadProgressByID[id] = p.fraction }
        let now = Date()
        if let prev = lastBytes[id], now.timeIntervalSince(prev.at) > 0.5 {
            downloadSpeeds[id] = max(0, Double(p.done - prev.bytes) / now.timeIntervalSince(prev.at))
            lastBytes[id] = (p.done, now)
        } else if lastBytes[id] == nil {
            lastBytes[id] = (p.done, now)
        }
    }

    /// SteamCMD exited. The manifest is authoritative: fully installed → done; otherwise the partial is
    /// kept and the game drops to a resumable "paused" state (this is the *only* path to "Resume", so a
    /// live download is never mis-shown as paused).
    private func downloadDidExit(appID id: Int) async {
        guard downloadingIDs.contains(id) else { return }   // already finished via the log watcher
        await refreshInstalled()
        endDownload(id, installed: installedByID[id]?.isFullyInstalled == true)
    }

    /// Pause a download — stop SteamCMD but KEEP the partial files (Resume continues from here).
    public func pause(_ info: SteamAppInfo) async {
        await steamCMD.pauseDownload(appID: info.appID, pid: downloadPIDs[info.appID])
        clearDownloadState(info.appID)
        await refreshInstalled()
        statusMessage = "Paused \(info.name)."
    }

    /// Cancel a download and discard the partial files.
    public func cancel(_ info: SteamAppInfo) async {
        await steamCMD.cancelDownload(appID: info.appID, pid: downloadPIDs[info.appID])
        clearDownloadState(info.appID)
        await refreshInstalled()
        statusMessage = "Cancelled \(info.name)."
    }

    /// Stop tracking a download (cancel its observers + drop transient progress state).
    private func clearDownloadState(_ id: Int) {
        cancelDownloadObservers(id)
        downloadingIDs.remove(id)
        downloadProgressByID[id] = nil; downloadSpeeds[id] = nil; lastBytes[id] = nil; downloadPIDs[id] = nil
    }

    private func cancelDownloadObservers(_ id: Int) {
        downloadObservers[id]?.forEach { $0.cancel() }
        downloadObservers[id] = nil
    }

    /// Finish/stop a download: clear its state and post a one-line status.
    private func endDownload(_ id: Int, installed: Bool) {
        let gameName = name(forAppID: id)
        clearDownloadState(id)
        statusMessage = installed ? "\(gameName) finished downloading."
                                  : "\(gameName) download stopped — Resume to continue."
    }

    /// Read + parse a SteamCMD log tail (progress + completion). `nonisolated` so observer handlers can
    /// call it off the main actor.
    private nonisolated static func parseLog(at url: URL, appID: Int)
        -> (progress: SteamCMD.Progress?, finished: Bool) {
        let text = tail(url)
        return (SteamCMD.parseProgress(text), SteamCMD.isInstalledInLog(text, appID: appID))
    }

    /// Read the tail of a log file (SteamCMD progress lines live near the end).
    private nonisolated static func tail(_ url: URL, maxBytes: Int = 32 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private func name(forAppID id: Int) -> String {
        owned.first { $0.appID == id }?.name ?? installedByID[id]?.name ?? "Game"
    }

    // MARK: - Launch

    /// Launch an installed game in its isolated GPTK bucket. Its exit is observed (kqueue), not polled.
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
            observeRun(appID: info.appID, pid: pid)
            statusMessage = "Launched \(info.name)."
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

    public func stop(_ info: SteamAppInfo) async {
        guard runningPIDs[info.appID] != nil else { return }
        await orchestrator.stop(appID: info.appID, backend: backend)
        clearRunState(info.appID)
    }

    public func openWinecfg(_ info: SteamAppInfo) async {
        guard backend.isWineConfigured else { statusMessage = "No Wine configured."; return }
        await orchestrator.runWineTool("winecfg", appID: info.appID, backend: backend)
    }

    private func observeRun(appID: Int, pid: Int32) {
        runObservers[appID]?.cancel()
        runObservers[appID] = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in self?.gameDidExit(appID: appID, pid: pid) }
        }
    }

    private func gameDidExit(appID: Int, pid: Int32) {
        guard runningPIDs[appID] == pid else { return }   // ignore a stale exit after relaunch
        clearRunState(appID)
    }

    private func clearRunState(_ id: Int) {
        runningPIDs[id] = nil
        runObservers[id]?.cancel(); runObservers[id] = nil
    }

    /// Bridge owned metadata → the `SteamApp` the launch pipeline expects. Prefer the installed manifest
    /// (real installDir/name); fall back to the bucket layout that matches SteamCMD's force_install_dir.
    private func steamApp(for info: SteamAppInfo) -> SteamApp {
        installedByID[info.appID]
            ?? SteamApp(appID: info.appID, name: info.name, installDir: String(info.appID),
                        stateFlags: .fullyInstalled, sizeOnDisk: 0, libraryPath: paths.gameLibraryDir)
    }
}
