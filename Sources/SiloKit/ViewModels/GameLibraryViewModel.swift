import Foundation

/// The pivoted library: the signed-in account's owned **Windows-only** games. Each is downloaded with
/// SteamCMD into its own bucket (`AppPaths.gameInstallDir`) and launched via GPTK by `LaunchOrchestrator`.
@MainActor
@Observable
public final class GameLibraryViewModel {
    public enum LoadState: Equatable { case idle, needsLogin, loading, loaded, empty, error(String) }

    public private(set) var owned: [SteamAppInfo] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var busyAppIDs: Set<Int> = []
    public private(set) var runningPIDs: [Int: Int32] = [:]   // appID → launched wine PID
    public var searchText: String = ""
    public var statusMessage: String?

    private let steamCMD: SteamCMDClient
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let paths: AppPaths
    private var backend: BackendConfig
    private var username: String?
    private var monitorTask: Task<Void, Never>?

    public init(
        steamCMD: SteamCMDClient,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        paths: AppPaths,
        backend: BackendConfig
    ) {
        self.steamCMD = steamCMD
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
    }

    public func setAccount(username: String?) { self.username = username }
    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    public var canLaunch: Bool { backend.isWineConfigured }
    public var isLoggedIn: Bool { !(username ?? "").isEmpty }

    public var filtered: [SteamAppInfo] {
        searchText.isEmpty ? owned
            : owned.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// A game is installed once its bucket holds the SteamCMD appmanifest.
    public func isInstalled(_ info: SteamAppInfo) -> Bool {
        let manifest = paths.gameLibraryDir
            .appendingPathComponent("steamapps/appmanifest_\(info.appID).acf")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    public func isRunning(_ info: SteamAppInfo) -> Bool { runningPIDs[info.appID] != nil }
    public func isBusy(_ info: SteamAppInfo) -> Bool { busyAppIDs.contains(info.appID) }

    /// Load the owned Windows-only catalog from SteamCMD (requires a signed-in username).
    public func load() async {
        guard let username, !username.isEmpty else { loadState = .needsLogin; return }
        loadState = .loading
        do {
            owned = try await steamCMD.ownedWindowsGames(username: username)
            loadState = owned.isEmpty ? .empty : .loaded
        } catch {
            loadState = .error((error as NSError).localizedDescription)
        }
    }

    /// Download (or update) a game's Windows files into its bucket via SteamCMD (detached).
    public func download(_ info: SteamAppInfo) async {
        guard let username, !busyAppIDs.contains(info.appID) else { return }
        busyAppIDs.insert(info.appID); defer { busyAppIDs.remove(info.appID) }
        statusMessage = "Downloading \(info.name)…"
        do {
            _ = try await steamCMD.download(appID: info.appID, username: username,
                                            logURL: paths.log(forAppID: info.appID))
            statusMessage = "\(info.name): download started (watch its log for progress)."
        } catch {
            statusMessage = "\(info.name): \((error as NSError).localizedDescription)"
        }
    }

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

    /// Bridge owned metadata → the `SteamApp` the launch pipeline expects. The bucket layout
    /// (`<gameLibrary>/steamapps/common/<appID>`) matches SteamCMD's `force_install_dir`.
    private func steamApp(for info: SteamAppInfo) -> SteamApp {
        SteamApp(appID: info.appID, name: info.name, installDir: String(info.appID),
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
