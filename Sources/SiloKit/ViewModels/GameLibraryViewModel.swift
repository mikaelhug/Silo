import Foundation

/// The library: Steam games installed in the shared **Steam bottle** (a Wine prefix running a logged-in
/// Windows Steam client) — discovered from the bottle's `appmanifest_*.acf` and launched **co-resident**
/// with the Steam client (so Steamworks/DRM works) under GPTK/D3DMetal — plus user-added **manual**
/// non-Steam `.exe` games, which run in the same bottle prefix under GPTK without needing Steam. No
/// SteamCMD: the bottle's Steam is the downloader for Steam titles.
@MainActor
@Observable
public final class GameLibraryViewModel {
    public enum LoadState: Equatable { case idle, notReady, loaded, empty, error(String) }

    /// Games installed in the Steam bottle (parsed from its `appmanifest_*.acf`).
    public private(set) var games: [SteamApp] = []
    /// Non-Steam games the user added by hand (persisted in `config.json`; launched in the same bottle
    /// prefix under GPTK, without Steamworks).
    public private(set) var manualGames: [ManualGame] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var busyAppIDs: Set<Int> = []
    /// Live launch tracking (values are wine loader PIDs). Module-internal, NOT public API — callers query
    /// liveness via `isRunning(_:)` / `isAnythingRunning` rather than reaching into the PID tables.
    private(set) var runningPIDs: [Int: Int32] = [:]
    private(set) var manualRunningPIDs: [UUID: Int32] = [:]
    public private(set) var manualBusyIDs: Set<UUID> = []
    public var searchText: String = ""
    /// The most recent action result, shown in the library's status bar. Persists until the next action
    /// replaces it (no timed auto-dismiss — nothing in the app waits).
    public private(set) var statusMessage: String?

    private let bottle: SteamBottle
    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let paths: AppPaths
    private var backend: BackendConfig
    private var runObservers: [Int: any ProcessObservation] = [:]
    private var manualObservers: [UUID: any ProcessObservation] = [:]
    /// Per-launch watchers that surface a silent GPTK→wined3d graphics fallback (keyed like the observers).
    private var graphicsMonitors: [Int: GraphicsFallbackMonitor] = [:]
    private var manualGraphicsMonitors: [UUID: GraphicsFallbackMonitor] = [:]
    /// The owner of the GPTK Steam bottle's live client (shared with the settings pane), and — when the
    /// DXMT Steam bottle exists — the DXMT bottle's client. Keyed by backend so a game routes to its bottle.
    private let session: SteamClientSession
    private let dxmtSession: SteamClientSession?
    /// Boots the per-game isolated bottles that manual (non-Steam) games run in.
    private let provisioner: WinePrefixProvisioner

    public init(
        bottle: SteamBottle,
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        paths: AppPaths,
        backend: BackendConfig,
        session: SteamClientSession,
        dxmtSession: SteamClientSession? = nil,
        provisioner: WinePrefixProvisioner
    ) {
        self.bottle = bottle
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
        self.session = session
        self.dxmtSession = dxmtSession
        self.provisioner = provisioner
    }

    /// The Steam client session that owns a given backend's bottle. Falls back to the GPTK session when a
    /// DXMT session isn't wired (tests / DXMT bottle not set up) — a DXMT Steam game only reaches here once
    /// the DXMT bottle exists, which AppEnvironment always pairs with a DXMT session.
    private func clientSession(for graphics: GraphicsBackend) -> SteamClientSession {
        graphics == .dxmt ? (dxmtSession ?? session) : session
    }

    /// Keep only ONE Steam client online at a time (same account): stop every other backend's client before
    /// bringing up the one the game needs.
    private func stopOtherSteamClients(except graphics: GraphicsBackend) {
        for other in [session, dxmtSession].compactMap({ $0 }) where other.backend != graphics {
            other.stop()
        }
    }

    /// Defensive teardown (these VMs are process-lifetime singletons, so it normally never fires): cancel
    /// any live exit observations so they can't outlive the model. `isolated` to touch its @MainActor state.
    isolated deinit {
        runObservers.values.forEach { $0.cancel() }
        manualObservers.values.forEach { $0.cancel() }
        graphicsMonitors.values.forEach { $0.stop() }
        manualGraphicsMonitors.values.forEach { $0.stop() }
    }

    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    /// Whether any game (Steam or manual) is currently tracked as running. Lets callers ask without
    /// reaching into the internal PID tables.
    public var isAnythingRunning: Bool { !runningPIDs.isEmpty || !manualRunningPIDs.isEmpty }

    public var canLaunch: Bool { backend.isWineConfigured }
    /// At least one Steam bottle (GPTK or DXMT) has its Steam client installed.
    public var steamReady: Bool { GraphicsBackend.allCases.contains { steamInstalled($0) } }

    private func steamInstalled(_ graphics: GraphicsBackend) -> Bool {
        FileManager.default.fileExists(atPath: paths.steamBottleExe(graphics).path)
    }

    /// Search filter over the installed Steam games (already name-sorted by `DiscoveryEngine`).
    public var filtered: [SteamApp] {
        searchText.isEmpty ? games
            : games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Search filter over the manual (non-Steam) games (kept name-sorted).
    public var filteredManual: [ManualGame] {
        searchText.isEmpty ? manualGames
            : manualGames.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public func isRunning(_ game: SteamApp) -> Bool { runningPIDs[game.appID] != nil }
    public func isBusy(_ game: SteamApp) -> Bool { busyAppIDs.contains(game.appID) }
    public func isRunning(_ game: ManualGame) -> Bool { manualRunningPIDs[game.id] != nil }
    public func isBusy(_ game: ManualGame) -> Bool { manualBusyIDs.contains(game.id) }

    public func sizeString(_ game: SteamApp) -> String? {
        guard game.sizeOnDisk > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)
    }

    private func setStatus(_ message: String?) { statusMessage = message }

    // MARK: - Library

    /// Re-scan BOTH Steam bottles (GPTK + DXMT) for installed games, plus the persisted manual games.
    /// Each Steam game is tagged with the backend of the bottle it was discovered in — a Steam game's
    /// backend IS its bottle.
    public func load() async {
        manualGames = sortedManual(await configStore.load().manualGames)
        // Manual games also live in a bottle, so the library still gates on at least one Steam bottle
        // existing (notReady drives the onboarding until Steam is set up).
        guard steamReady else { loadState = .notReady; return }
        var seen = Set<Int>()   // dedup by appID (first wins) in case a title is installed in both bottles
        let discovered = await discoverAllBottles().filter { seen.insert($0.appID).inserted }
        games = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadState = (games.isEmpty && manualGames.isEmpty) ? .empty : .loaded
    }

    /// Discover games across every installed Steam bottle, tagging each with its bottle's backend. A bottle
    /// whose library dir doesn't exist yet (or fails to parse) contributes nothing rather than failing the
    /// whole load — one bad bottle never hides the other's games.
    private func discoverAllBottles() async -> [SteamApp] {
        var all: [SteamApp] = []
        for graphics in GraphicsBackend.allCases where steamInstalled(graphics) {
            let apps = (try? await discovery.discoverGames(
                steamRoot: paths.steamBottleClientDir(graphics))) ?? []
            all += apps.map { var app = $0; app.backend = graphics; return app }
        }
        return all
    }

    private func sortedManual(_ list: [ManualGame]) -> [ManualGame] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func refresh() async { await load() }

    // MARK: - Install / uninstall (routed through the shared Steam client)

    /// Open the bottle's Steam (Store/Library) so the user can browse + install games.
    public func openSteam() async { await session.ensureRunning() }

    /// Ask the bottle's Steam to uninstall a game, then refresh.
    public func uninstall(_ game: SteamApp) async {
        guard !isRunning(game) else { return }
        do {
            try await session.sendURL("steam://uninstall/\(game.appID)")
            setStatus("Asked Steam to uninstall \(game.name). Refresh once it's done.")
        } catch { setStatus("Couldn't reach Steam: \((error as NSError).localizedDescription)") }
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game co-resident in its backend's Steam bottle (GPTK or DXMT), with that bottle's Steam
    /// client up so Steamworks works. Routes prefix + runtime through `BottleResolver` (its backend = its
    /// bottle), and keeps only that bottle's Steam client online.
    public func play(_ game: SteamApp) async {
        guard backend.isWineConfigured, !busyAppIDs.contains(game.appID), runningPIDs[game.appID] == nil else { return }
        busyAppIDs.insert(game.appID); defer { busyAppIDs.remove(game.appID) }
        do {
            // Resolve the game's backend → its bottle prefix + prepared runtime (off-main; clones DXMT).
            let cfg = backend
            let context = try await Task.detached { [paths] in
                try BottleResolver(paths: paths).steam(game.backend, config: cfg)
            }.value
            // Steamworks IPC is prefix-scoped: this bottle's client must be up + logged in first (and it's
            // the ONLY one online — same account can't be in-game on two clients). If it can't start,
            // surface why rather than launching against a dead Steam (which fails SteamAPI_Init silently).
            stopOtherSteamClients(except: game.backend)
            let client = clientSession(for: game.backend)
            guard await client.ensureRunning() else {
                let why = client.launchError.map { ": \($0)" } ?? ""
                setStatus("\(game.name) needs the Steam client, but it couldn't start\(why).")
                return
            }
            let config = await configStore.load().config(for: game.appID)
            var launchBackend = backend
            launchBackend.wineBinaryPath = context.wineBinary
            let pid = try await orchestrator.launchInBottle(
                app: game, config: config, backend: launchBackend, graphics: game.backend,
                prefix: context.prefix, logURL: paths.log(forAppID: game.appID))
            _ = try? await configStore.updateGame(appID: game.appID) { $0.lastPlayed = Date() }
            runningPIDs[game.appID] = pid
            observeRun(appID: game.appID, pid: pid)
            setStatus("Launched \(game.name).")
            // Last, so a detected fallback (which usually arrives a beat later as the log is written, but
            // may already be present) overrides the "Launched" status rather than being clobbered by it.
            watchGraphics(appID: game.appID, log: paths.log(forAppID: game.appID),
                          name: game.name, backend: game.backend)
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
        }
    }

    /// Stop a running game. Terminates just the game (the shared bottle keeps Steam alive — a
    /// `wineserver -k` would kill the co-resident Steam client too). See `LaunchOrchestrator.stopGame`.
    public func stop(_ game: SteamApp) async {
        guard let pid = runningPIDs[game.appID] else { return }
        let config = await configStore.load().config(for: game.appID)
        let exeName = orchestrator.resolvedExecutableName(app: game, config: config)
        await orchestrator.stopGame(
            pid: pid, exeName: exeName, prefix: paths.steamBottle(game.backend), backend: backend)
        clearRunState(game.appID)
    }

    /// SIGTERM every game Silo launched (Steam + manual), synchronously. Used at app quit (where there's no
    /// time for the async `taskkill`/`wineserver -k` cleanup): wine turns SIGTERM into terminating the hosted
    /// game, and we only signal the PIDs Silo spawned — the co-resident Steam client is never touched.
    public func terminateAllSync() {
        for pid in runningPIDs.values { orchestrator.terminate(pid: pid) }
        for pid in manualRunningPIDs.values { orchestrator.terminate(pid: pid) }
    }

    /// Open `winecfg` for a backend's Steam bottle prefix (prefix-wide, so not per-game — but per-bottle).
    public func openWinecfg(_ graphics: GraphicsBackend = .gptk) async {
        guard backend.isWineConfigured else { setStatus("No Wine configured."); return }
        await orchestrator.runWineTool("winecfg", prefix: paths.steamBottle(graphics), backend: backend)
    }

    // MARK: - Manual (non-Steam) games — each in its OWN isolated bottle (paths.manualBottle(id))

    /// Boot a manual game's private bottle (idempotent — fast once booted). Returns whether it's ready.
    @discardableResult
    public func ensureManualBottle(_ id: UUID) async -> Bool {
        guard let wine = backend.wineBinaryPath else { setStatus("Set up Wine first."); return false }
        do {
            try await provisioner.provision(prefix: paths.manualBottle(id), wine: wine)
            return true
        } catch {
            setStatus("Couldn't set up the game's bottle: \((error as NSError).localizedDescription)")
            return false
        }
    }

    /// Delete a draft bottle that was provisioned but never added to the library (Add sheet cancel).
    public func discardManualBottle(_ id: UUID) async {
        await deleteBottle(id)
    }

    /// Run an installer `.exe` in a specific game's bottle (detached) so it installs into THAT bottle's
    /// `drive_c`. The bottle is booted first if needed. The user then picks the installed game `.exe`.
    public func runInstaller(_ installer: URL, forBottle id: UUID) async {
        guard await ensureManualBottle(id) else { return }
        do {
            _ = try await orchestrator.runInstaller(
                exe: installer, backend: backend, prefix: paths.manualBottle(id), logURL: paths.manualLog(id))
            setStatus("Running installer… finish it, then choose the installed .exe.")
        } catch { setStatus("Installer failed: \((error as NSError).localizedDescription)") }
    }

    /// Add a non-Steam game pointing at an absolute `.exe`, provisioning its private bottle. Pass the same
    /// `id` used for any pre-Add installer run so the game adopts that already-booted bottle. Name defaults
    /// to the exe's filename.
    @discardableResult
    public func addManualGame(
        id: UUID = UUID(), name: String, executable: URL, backend graphics: GraphicsBackend = .gptk
    ) async -> ManualGame? {
        guard await ensureManualBottle(id) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? executable.deletingPathExtension().lastPathComponent : trimmed
        let game = ManualGame(id: id, name: finalName, executablePath: executable, backend: graphics)
        do {
            _ = try await configStore.saveManualGame(game)
            manualGames = sortedManual(manualGames + [game])
            if loadState == .empty { loadState = .loaded }
            setStatus("Added \(finalName).")
            return game
        } catch {
            setStatus("Couldn't add game: \((error as NSError).localizedDescription)")
            return nil
        }
    }

    /// Persist edits to a manual game (rename, change exe, launch options, perf flags).
    public func updateManual(_ game: ManualGame) async {
        do {
            _ = try await configStore.saveManualGame(game)
            manualGames = sortedManual(manualGames.filter { $0.id != game.id } + [game])
        } catch { setStatus("Couldn't save: \((error as NSError).localizedDescription)") }
    }

    /// Remove a manual game from the library AND delete its isolated bottle. A portable game's original
    /// files on disk (outside the bottle) are left untouched. Refuses while running.
    public func removeManual(_ game: ManualGame) async {
        guard manualRunningPIDs[game.id] == nil else { return }
        _ = try? await configStore.removeManualGame(id: game.id)
        manualGames.removeAll { $0.id == game.id }
        await deleteBottle(game.id)
        if games.isEmpty && manualGames.isEmpty { loadState = .empty }
        setStatus("Removed \(game.name).")
    }

    /// Launch a manual game in its OWN bottle under its chosen backend (GPTK or DXMT; no Steam needed).
    /// Boots the bottle first, then routes through `BottleResolver` so the game runs on the right runtime —
    /// GPTK in place, or DXMT's cloned+overlaid variant. The clone/overlay runs off the main actor.
    public func playManual(_ game: ManualGame) async {
        guard backend.isWineConfigured, !manualBusyIDs.contains(game.id),
              manualRunningPIDs[game.id] == nil else { return }
        manualBusyIDs.insert(game.id); defer { manualBusyIDs.remove(game.id) }
        guard await ensureManualBottle(game.id) else { return }
        let cfg = backend
        let context: LaunchContext
        do {
            context = try await Task.detached { [paths] in
                try BottleResolver(paths: paths).manual(game, config: cfg)
            }.value
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
            return
        }
        do {
            // The resolved runtime is the backend's variant; feed it to the orchestrator as the launch wine.
            var launchBackend = backend
            launchBackend.wineBinaryPath = context.wineBinary
            let pid = try await orchestrator.launchManualGame(
                game, backend: launchBackend, graphics: context.graphics,
                prefix: context.prefix, logURL: paths.manualLog(game.id))
            _ = try? await configStore.updateManualGame(id: game.id) { $0.lastPlayed = Date() }
            manualRunningPIDs[game.id] = pid
            observeManualRun(id: game.id, pid: pid)
            setStatus("Launched \(game.name).")
            watchManualGraphics(id: game.id, log: paths.manualLog(game.id),
                                name: game.name, backend: game.backend)   // last (see play)
        } catch {
            setStatus("\(game.name): \((error as NSError).localizedDescription)")
        }
    }

    /// Human-readable text for a `BottleResolver.ResolveError` (a missing secondary runtime is the common
    /// case a user can act on).
    private static func resolveMessage(_ error: Error) -> String {
        switch error {
        case BottleResolver.ResolveError.backendNotConfigured(let graphics):
            "\(graphics.displayName) runtime isn't installed — set it up in Settings first."
        case BottleResolver.ResolveError.wineNotConfigured:
            "No Wine configured."
        default:
            (error as NSError).localizedDescription
        }
    }

    /// Stop a running manual game (taskkill its exe in its own bottle).
    public func stopManual(_ game: ManualGame) async {
        guard let pid = manualRunningPIDs[game.id] else { return }
        await orchestrator.stopGame(
            pid: pid, exeName: game.executablePath.lastPathComponent,
            prefix: paths.manualBottle(game.id), backend: backend)
        clearManualRun(game.id)
    }

    /// Open `winecfg` for a manual game's OWN bottle (Windows version, libraries — isolated per game).
    public func openManualWinecfg(_ game: ManualGame) async {
        guard backend.isWineConfigured else { setStatus("No Wine configured."); return }
        guard await ensureManualBottle(game.id) else { return }
        await orchestrator.runWineTool("winecfg", prefix: paths.manualBottle(game.id), backend: backend)
    }

    /// Remove a manual game's bottle directory off the main actor (it can be large once a game is installed).
    private func deleteBottle(_ id: UUID) async {
        let url = paths.manualBottle(id)
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }

    private func observeManualRun(id: UUID, pid: Int32) {
        manualObservers[id]?.cancel()
        manualObservers[id] = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in self?.manualGameDidExit(id: id, pid: pid) }
        }
    }

    private func manualGameDidExit(id: UUID, pid: Int32) {
        guard manualRunningPIDs[id] == pid else { return }
        clearManualRun(id)
    }

    private func clearManualRun(_ id: UUID) {
        manualRunningPIDs[id] = nil
        manualObservers[id]?.cancel(); manualObservers[id] = nil
        manualGraphicsMonitors[id]?.stop(); manualGraphicsMonitors[id] = nil
    }

    /// Start watching a Steam game's launch log; surface a status if its backend silently fell back to wined3d.
    private func watchGraphics(appID: Int, log: URL, name: String, backend: GraphicsBackend) {
        let monitor = GraphicsFallbackMonitor()
        graphicsMonitors[appID] = monitor
        monitor.start(url: log, backend: backend) { [weak self] in
            self?.setStatus("\(name): \(backend.displayName) didn't engage — running on fallback graphics (wined3d).")
            self?.graphicsMonitors[appID] = nil
        }
    }

    /// Same, for a manual game's own bottle log. The message names the game's chosen backend (GPTK or DXMT),
    /// since the "fell back to wined3d" signal applies to whichever translation layer was attempted.
    private func watchManualGraphics(id: UUID, log: URL, name: String, backend: GraphicsBackend) {
        let monitor = GraphicsFallbackMonitor()
        manualGraphicsMonitors[id] = monitor
        monitor.start(url: log, backend: backend) { [weak self] in
            self?.setStatus("\(name): \(backend.displayName) didn't engage — running on fallback graphics (wined3d).")
            self?.manualGraphicsMonitors[id] = nil
        }
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
        graphicsMonitors[id]?.stop(); graphicsMonitors[id] = nil
    }
}
