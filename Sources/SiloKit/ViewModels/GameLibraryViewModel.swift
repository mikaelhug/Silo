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
    public private(set) var manualBusyIDs: Set<UUID> = []

    /// Live launch tracking, projected from the process coordinator's keyed table. Module-internal, NOT
    /// public API — callers query liveness via `isRunning(_:)` / `isAnythingRunning`.
    var runningPIDs: [Int: Int32] {
        processes.pids.reduce(into: [:]) { if case .steam(let appID, _) = $1.key { $0[appID] = $1.value } }
    }
    var manualRunningPIDs: [UUID: Int32] {
        processes.pids.reduce(into: [:]) { if case .manual(let id) = $1.key { $0[id] = $1.value } }
    }
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
    /// Owns the live-process state (PIDs, exit observers, graphics-fallback monitors) for every launched
    /// game, keyed by `GameID` — see `GameProcessCoordinator`.
    private let processes: GameProcessCoordinator
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
        self.processes = GameProcessCoordinator(orchestrator: orchestrator)
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

    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    /// Whether any game (Steam or manual) is currently tracked as running. Lets callers ask without
    /// reaching into the internal PID tables.
    public var isAnythingRunning: Bool { processes.anythingRunning }

    public var canLaunch: Bool { backend.isWineConfigured }
    /// At least one Steam bottle (GPTK or DXMT) has its Steam client installed.
    public var steamReady: Bool { !steamInstalledBackends.isEmpty }

    /// Backends whose Steam bottle has a Windows Steam client installed. Cached (probed OFF the main
    /// actor by `refreshSteamInstalled`) because `bottlesRoot` can live on a slow or disconnected
    /// external volume, and `steamReady` gates SwiftUI body evaluation — a blocking `fileExists` there
    /// can stall the UI for seconds. Refreshed by every `load()` and after a bottle's Steam install.
    public private(set) var steamInstalledBackends: Set<GraphicsBackend> = []

    public func steamInstalled(_ graphics: GraphicsBackend) -> Bool {
        steamInstalledBackends.contains(graphics)
    }

    /// Re-probe which bottles have Steam installed (off the main actor), updating the cached set.
    public func refreshSteamInstalled() async {
        let paths = self.paths
        steamInstalledBackends = await Task.detached {
            Set(GraphicsBackend.allCases.filter {
                FileManager.default.fileExists(atPath: paths.steamBottleExe($0).path)
            })
        }.value
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

    public func isRunning(_ game: SteamApp) -> Bool { processes.pid(for: gameID(game)) != nil }
    public func isBusy(_ game: SteamApp) -> Bool { busyAppIDs.contains(game.appID) }

    /// The coordinator key for a Steam game — (appID, backend), so the two bottle copies of one title are
    /// tracked independently.
    private func gameID(_ game: SteamApp) -> GameID { .steam(appID: game.appID, backend: game.backend) }

    /// The backend of the bottle a title is currently running in, if any (scans the live-process table).
    /// Used to block launching the SAME title in the other bottle — one Steam account can't be in-game
    /// twice, and bringing up the other bottle's client would kill Steam under the running game.
    private func runningBackend(ofAppID appID: Int) -> GraphicsBackend? {
        for case .steam(appID, let backend) in processes.pids.keys { return backend }
        return nil
    }
    public func isRunning(_ game: ManualGame) -> Bool { processes.pid(for: .manual(game.id)) != nil }
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
        await refreshSteamInstalled()
        manualGames = sortedManual(await configStore.load().manualGames)
        // Manual games also live in a bottle, so the library still gates on at least one Steam bottle
        // existing (notReady drives the onboarding until Steam is set up).
        guard steamReady else { loadState = .notReady; return }
        // A title installed in BOTH bottles surfaces TWICE — one card per backend (each runs in its own
        // bottle on its own runtime; the per-card BackendTag disambiguates them). Identity is
        // (appID, backend), so no dedup. Sort by name, tie-breaking on backend for a stable order.
        let (discovered, failures) = await discoverAllBottles()
        games = discovered.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName == .orderedSame ? $0.backend.rawValue < $1.backend.rawValue
                                          : byName == .orderedAscending
        }
        if !failures.isEmpty {
            // A bottle's library couldn't be READ (permissions/IO — not the benign no-library-yet case).
            // With nothing else to show that's the load's error state; if the other bottle still produced
            // games, keep the library up and surface the failure as a status instead.
            guard !games.isEmpty || !manualGames.isEmpty else {
                loadState = .error(failures.joined(separator: "\n"))
                return
            }
            setStatus(failures.joined(separator: "\n"))
        }
        loadState = (games.isEmpty && manualGames.isEmpty) ? .empty : .loaded
    }

    /// Discover games across every installed Steam bottle, tagging each with its bottle's backend. A bottle
    /// whose library dir doesn't exist yet contributes nothing (benign — a fresh Steam install has no
    /// library), and one whose library can't be READ contributes a failure message instead of silently
    /// hiding its games — either way one bad bottle never hides the other's games.
    private func discoverAllBottles() async -> (apps: [SteamApp], failures: [String]) {
        var all: [SteamApp] = []
        var failures: [String] = []
        for graphics in GraphicsBackend.allCases where steamInstalled(graphics) {
            do {
                let apps = try await discovery.discoverGames(steamRoot: paths.steamBottleClientDir(graphics))
                all += apps.map { var app = $0; app.backend = graphics; return app }
            } catch DiscoveryEngine.DiscoveryError.steamDirNotFound {
                // Steam is installed but hasn't created its library yet — drives onboarding, not alarms.
            } catch DiscoveryEngine.DiscoveryError.libraryUnreadable(let url) {
                failures.append("Couldn't read the \(graphics.displayName) Steam library — "
                    + "\(url.path) isn't readable.")
            } catch {
                failures.append("Couldn't read the \(graphics.displayName) Steam library: "
                    + (error as NSError).localizedDescription)
            }
        }
        return (all, failures)
    }

    private func sortedManual(_ list: [ManualGame]) -> [ManualGame] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func refresh() async { await load() }

    // MARK: - Install / uninstall (routed through the shared Steam client)

    /// Open the bottle's Steam (Store/Library) so the user can browse + install games.
    public func openSteam() async { await session.ensureRunning() }

    /// Ask the game's OWN bottle's Steam to uninstall it, then refresh. Routes through that backend's
    /// client session (not the GPTK one) — with a title surfaced in both bottles, uninstalling the DXMT
    /// copy must reach the DXMT bottle's Steam. Refused while the title runs in EITHER bottle.
    public func uninstall(_ game: SteamApp) async {
        guard runningBackend(ofAppID: game.appID) == nil else { return }
        do {
            try await clientSession(for: game.backend).sendURL("steam://uninstall/\(game.appID)")
            setStatus("Asked Steam to uninstall \(game.name). Refresh once it's done.")
        } catch { setStatus("Couldn't reach Steam: \((error as NSError).localizedDescription)") }
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game co-resident in its backend's Steam bottle (GPTK or DXMT), with that bottle's Steam
    /// client up so Steamworks works. Routes prefix + runtime through `BottleResolver` (its backend = its
    /// bottle), and keeps only that bottle's Steam client online.
    public func play(_ game: SteamApp) async {
        // `busyAppIDs` is keyed by bare appID, so while EITHER bottle's copy is launching the other copy
        // is blocked too — closing the cross-bottle launch race with no extra state.
        guard backend.isWineConfigured, !busyAppIDs.contains(game.appID) else { return }
        // Already running SOMEWHERE? A same-bottle replay is a silent no-op (as before); the OTHER bottle's
        // copy gets an explanatory status (its Play button is enabled). This check runs BEFORE
        // stopOtherSteamClients so we never kill the running game's Steam client. One account can't be
        // in-game on two clients, so co-launching the same title in both bottles is refused by design.
        if let runningIn = runningBackend(ofAppID: game.appID) {
            if runningIn != game.backend {
                setStatus("\(game.name) is already running in the \(runningIn.displayName) bottle — "
                    + "stop it there first (one Steam account can't be in-game twice).")
            }
            return
        }
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
            processes.track(gameID(game), pid: pid)
            do {
                // Per-game config/settings are keyed by appID (shared by both bottle copies — same game,
                // and they can never run simultaneously, so a shared launch date/options is correct).
                _ = try await configStore.updateGame(appID: game.appID) { $0.lastPlayed = Date() }
                setStatus("Launched \(game.name).")
            } catch {
                // The game IS running, but config.json is unwritable — say so (settings won't stick either).
                setStatus("Launched \(game.name), but couldn't save its play date: "
                    + (error as NSError).localizedDescription)
            }
            // Last, so a detected fallback (which usually arrives a beat later as the log is written, but
            // may already be present) overrides the "Launched" status rather than being clobbered by it.
            watchGraphics(gameID(game), log: paths.log(forAppID: game.appID),
                          name: game.name, backend: game.backend)
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
        }
    }

    /// Stop a running game. Terminates just the game (the shared bottle keeps Steam alive — a
    /// `wineserver -k` would kill the co-resident Steam client too). See `LaunchOrchestrator.stopGame`.
    /// Keyed by (appID, backend), so Stop on the non-running bottle copy is a clean no-op.
    public func stop(_ game: SteamApp) async {
        guard let pid = processes.pid(for: gameID(game)) else { return }
        let config = await configStore.load().config(for: game.appID)
        let exeName = orchestrator.resolvedExecutableName(app: game, config: config)
        await orchestrator.stopGame(
            pid: pid, exeName: exeName, prefix: paths.steamBottle(game.backend), backend: backend)
        processes.clear(gameID(game))
    }

    /// SIGTERM every game Silo launched (Steam + manual), synchronously. Used at app quit (where there's no
    /// time for the async `taskkill`/`wineserver -k` cleanup): wine turns SIGTERM into terminating the hosted
    /// game, and we only signal the PIDs Silo spawned — the co-resident Steam client is never touched.
    public func terminateAllSync() { processes.terminateAllSync() }

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
            setStatus("Couldn't set up the game's bottle: \(Self.resolveMessage(error))")
            return false
        }
    }

    /// Delete a draft bottle that was provisioned but never added to the library (Add sheet cancel).
    public func discardManualBottle(_ id: UUID) async {
        if await !deleteBottle(id) {
            setStatus("Couldn't delete the draft bottle — remove it in Finder: \(paths.manualBottle(id).path)")
        }
    }

    /// Run an installer `.exe` in a specific game's bottle (detached) so it installs into THAT bottle's
    /// `drive_c`. The bottle is booted first if needed. The user then picks the installed game `.exe`.
    public func runInstaller(_ installer: URL, forBottle id: UUID) async {
        guard await ensureManualBottle(id) else { return }
        do {
            _ = try await orchestrator.runInstaller(
                exe: installer, backend: backend, prefix: paths.manualBottle(id), logURL: paths.manualLog(id))
            setStatus("Running installer… finish it, then choose the installed .exe.")
        } catch { setStatus("Installer failed: \(Self.resolveMessage(error))") }
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
        guard processes.pid(for: .manual(game.id)) == nil else { return }
        _ = try? await configStore.removeManualGame(id: game.id)
        manualGames.removeAll { $0.id == game.id }
        let deleted = await deleteBottle(game.id)
        if games.isEmpty && manualGames.isEmpty { loadState = .empty }
        setStatus(deleted ? "Removed \(game.name)."
            : "Removed \(game.name), but couldn't delete its bottle — remove it in Finder: "
              + paths.manualBottle(game.id).path)
    }

    /// Launch a manual game in its OWN bottle under its chosen backend (GPTK or DXMT; no Steam needed).
    /// Boots the bottle first, then routes through `BottleResolver` so the game runs on the right runtime —
    /// GPTK in place, or DXMT's cloned+overlaid variant. The clone/overlay runs off the main actor.
    public func playManual(_ game: ManualGame) async {
        guard backend.isWineConfigured, !manualBusyIDs.contains(game.id),
              processes.pid(for: .manual(game.id)) == nil else { return }
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
            processes.track(.manual(game.id), pid: pid)
            do {
                _ = try await configStore.updateManualGame(id: game.id) { $0.lastPlayed = Date() }
                setStatus("Launched \(game.name).")
            } catch {
                // The game IS running, but config.json is unwritable — say so (settings won't stick either).
                setStatus("Launched \(game.name), but couldn't save its play date: "
                    + (error as NSError).localizedDescription)
            }
            watchGraphics(.manual(game.id), log: paths.manualLog(game.id),
                          name: game.name, backend: game.backend)   // last (see play)
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
        }
    }

    /// Human-readable, actionable text for the errors the launch/provision paths throw. (Steam-client
    /// startup failures don't reach here — `SteamClientSession.launchError` surfaces those.) Falls back
    /// to the system description for anything unmapped.
    static func resolveMessage(_ error: Error) -> String {
        switch error {
        case BottleResolver.ResolveError.backendNotConfigured(let graphics):
            "\(graphics.displayName) runtime isn't installed — set it up in Settings first."
        case BottleResolver.ResolveError.wineNotConfigured,
             LaunchOrchestrator.LaunchError.wineNotConfigured,
             WinePrefixProvisioner.ProvisionError.wineNotConfigured:
            "No Wine configured."
        case LaunchOrchestrator.LaunchError.executableNotFound(let url):
            "couldn't find the game's .exe (looked in \(url.path)) — pick one in the game's settings."
        case WinePrefixProvisioner.ProvisionError.winebootFailed(let code):
            "the game's bottle failed to initialize (wineboot exited \(code)) — check Wine in Settings."
        case RuntimeVariants.VariantError.cloneFailed(let url, let errno):
            "couldn't prepare the DXMT runtime copy at \(url.path) (errno \(errno)) — check free disk space."
        case GraphicsLinker.LinkError.sourceMissing(let url):
            "the graphics runtime's modules are missing (\(url.path)) — re-download it in Settings."
        default:
            (error as NSError).localizedDescription
        }
    }

    /// Stop a running manual game (taskkill its exe in its own bottle).
    public func stopManual(_ game: ManualGame) async {
        guard let pid = processes.pid(for: .manual(game.id)) else { return }
        await orchestrator.stopGame(
            pid: pid, exeName: game.executablePath.lastPathComponent,
            prefix: paths.manualBottle(game.id), backend: backend)
        processes.clear(.manual(game.id))
    }

    /// Generate a Game-Mode-tagged `.app` in `directory` (default: the Desktop) that launches the game
    /// directly under ITS backend — startable from Spotlight/Dock without Silo. Routes through
    /// `BottleResolver` exactly like `playManual`, so the snapshotted env carries the game's variant
    /// runtime + dll overrides (a DXMT game's shortcut launches on the DXMT runtime, never the base).
    /// Returns the bundle URL, or nil with the failure surfaced in the status bar. Manual games only —
    /// they don't need the co-resident Steam client.
    @discardableResult
    public func makeShortcut(for game: ManualGame, into directory: URL? = nil) async -> URL? {
        guard let dir = directory
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        let cfg = backend
        do {
            let context = try await Task.detached { [paths] in
                try BottleResolver(paths: paths).manual(game, config: cfg)
            }.value
            var launchBackend = cfg
            launchBackend.wineBinaryPath = context.wineBinary
            let plan = try LaunchOrchestrator.makePlan(
                config: GameConfig(appID: 0, envFlags: game.envFlags, presence: .none, customArgs: game.customArgs),
                backend: launchBackend, graphics: context.graphics, gameExe: game.executablePath,
                prefix: context.prefix, logURL: paths.manualLog(game.id))
            let app = try GameAppShortcut(name: game.name, plan: plan).write(into: dir)
            setStatus("Created a shortcut for \(game.name).")
            return app
        } catch {
            setStatus("Couldn't create the shortcut: \(Self.resolveMessage(error))")
            return nil
        }
    }

    /// Open `winecfg` for a manual game's OWN bottle (Windows version, libraries — isolated per game).
    public func openManualWinecfg(_ game: ManualGame) async {
        guard backend.isWineConfigured else { setStatus("No Wine configured."); return }
        guard await ensureManualBottle(game.id) else { return }
        await orchestrator.runWineTool("winecfg", prefix: paths.manualBottle(game.id), backend: backend)
    }

    /// Remove a manual game's bottle directory off the main actor (it can be large once a game is
    /// installed). Returns whether the bottle is gone — an already-absent dir counts as success (the Add
    /// sheet can cancel before its draft bottle ever provisioned).
    private func deleteBottle(_ id: UUID) async -> Bool {
        let url = paths.manualBottle(id)
        return await Task.detached(priority: .utility) {
            do { try FileManager.default.removeItem(at: url) } catch {
                let nsError = error as NSError
                return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
            }
            return true
        }.value
    }

    /// Watch a launched game's log via the coordinator; surface an actionable status if its backend never
    /// engaged (the log shows wine's own wined3d driving d3d1x — which, for the titles this happens to,
    /// then fails to create a device). Silo has NO fallback/rerouting mechanism (the deterministic
    /// backend⇔bottle rule forbids it), so the message tells the user where the game actually belongs
    /// rather than pretending graphics came up. `dxmtAvailable` is read INSIDE the fired closure so it
    /// reflects the state at detection time.
    private func watchGraphics(_ id: GameID, log: URL, name: String, backend graphics: GraphicsBackend) {
        let isSteamGame: Bool = if case .steam = id { true } else { false }
        processes.watchGraphics(id, log: log, backend: graphics) { [weak self] in
            guard let self else { return }
            let dxmtAvailable = isSteamGame ? self.steamInstalled(.dxmt)
                                            : self.backend.libDir(for: .dxmt) != nil
            self.setStatus(Self.graphicsFallbackMessage(
                name: name, backend: graphics, isSteamGame: isSteamGame, dxmtAvailable: dxmtAvailable))
        }
    }

    /// The user-facing message when a backend didn't engage. Pure + table-testable; backend- and
    /// kind-aware. Never claims a working "fallback" and never suggests Silo rerouted the game — for GPTK
    /// it points the (older DirectX 10/11) title at DXMT, adapting to whether DXMT is set up yet.
    static func graphicsFallbackMessage(
        name: String, backend: GraphicsBackend, isSteamGame: Bool, dxmtAvailable: Bool
    ) -> String {
        switch backend {
        case .gptk:
            let lead = "\(name): GPTK / D3DMetal couldn't drive this game's graphics — this class of "
                + "older DirectX 10/11 titles needs DXMT."
            let next: String
            switch (isSteamGame, dxmtAvailable) {
            case (true, true):
                next = "Install it in the DXMT Steam bottle and play it from there."
            case (true, false):
                next = "Set up DXMT in Settings → DXMT, then install the game in its Steam bottle."
            case (false, true):
                next = "Switch this game's graphics backend to DXMT in its settings."
            case (false, false):
                next = "Set up DXMT in Settings → DXMT first."
            }
            return "\(lead) \(next)"
        case .dxmt:
            return "\(name): DXMT didn't engage — the game fell back to wined3d and likely failed. "
                + "Check the DXMT runtime in Settings → DXMT."
        }
    }
}
