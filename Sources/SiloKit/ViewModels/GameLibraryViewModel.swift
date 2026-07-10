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
    /// Steam games mid-launch, keyed by appID so only the launching card's button spins.
    public private(set) var busyGames: Set<Int> = []
    public private(set) var manualBusyIDs: Set<UUID> = []

    public var searchText: String = ""
    /// The most recent action result, shown in the library's status bar. Transient: it self-clears a few
    /// seconds after it's set (see `setStatus`), so a stale "Launched …" doesn't linger once the game's
    /// closed. The next action replaces it immediately (and resets the timer).
    public private(set) var statusMessage: String?
    /// The pending auto-dismiss of `statusMessage` — cancelled/replaced by the next `setStatus` so a stale
    /// timer can never wipe a newer message.
    private var statusDismissal: Task<Void, Never>?
    /// How long a status line stays before it self-clears. A transient confirmation, not a persistent
    /// banner. Overridable so tests assert the auto-dismiss without a real-time wait.
    var statusVisibleDuration: Duration = .seconds(5)

    private let bottle: SteamBottle
    private let discovery: DiscoveryEngine
    private let orchestrator: LaunchOrchestrator
    private let configStore: ConfigStore
    private let paths: AppPaths
    private var backend: BackendConfig
    /// Owns the live-process state (PIDs, exit observers, graphics-fallback monitors) for every launched
    /// game, keyed by `GameID` — see `GameProcessCoordinator`.
    private let processes: GameProcessCoordinator
    /// The owner of the Steam bottle's live client (shared with the settings pane).
    private let session: SteamClientSession
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
        provisioner: WinePrefixProvisioner,
        ledger: ProcessLedger? = nil
    ) {
        self.bottle = bottle
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
        self.session = session
        self.provisioner = provisioner
        self.processes = GameProcessCoordinator(orchestrator: orchestrator, ledger: ledger)
    }

    public func updateBackend(_ backend: BackendConfig) { self.backend = backend }

    /// True while a bottles-location move is in progress (AppEnvironment wires this to `bottles.busy`).
    /// Launches are refused then — the move copies the prefixes off-volume and deletes the originals, so
    /// launching into the old root would orphan the process onto deleted files and corrupt the copy.
    var isRelocating: () -> Bool = { false }
    /// True while an inline self-update is downloading/installing (AppEnvironment wires this to
    /// `updates.isInstalling`). The update ends in `exit(0)` with no teardown, so a game launched during it
    /// would be orphaned — refuse launches for the duration.
    var isUpdating: () -> Bool = { false }

    /// Refuse a launch when the bottles are unavailable — a move in progress, a relocated drive unplugged
    /// (launching into an unmounted prefix would silently fail, or worse write to a phantom path), or an
    /// app self-update in flight (it relaunches Silo). Sets the status and returns true if refused.
    private func launchBlockedByBottles() -> Bool {
        if isRelocating() {
            setStatus("Silo is moving your bottles — wait for that to finish before launching.")
            return true
        }
        if isUpdating() {
            setStatus("Silo is installing an update — it'll relaunch in a moment; launch again after.")
            return true
        }
        if paths.bottlesRelocated, !paths.bottlesRootReachable {
            setStatus("Your bottles drive isn't connected — reconnect it to launch games.")
            return true
        }
        return false
    }

    /// Whether any game (Steam or manual) is running OR mid-launch. Includes the busy sets so a launch that
    /// has claimed a bottle but not yet spawned its process is still visible to the relocation/update gate —
    /// otherwise a move started in that window would copy/delete the prefix out from under the arriving game.
    public var isAnythingRunning: Bool {
        processes.anythingRunning || !busyGames.isEmpty || !manualBusyIDs.isEmpty
    }

    public var canLaunch: Bool { backend.isWineConfigured }
    /// The Steam bottle has its Steam client installed.
    public var steamReady: Bool { steamInstalled }

    /// Whether the Steam bottle has a Windows Steam client installed. Cached (probed OFF the main actor by
    /// `refreshSteamInstalled`) because `bottlesRoot` can live on a slow or disconnected external volume,
    /// and `steamReady` gates SwiftUI body evaluation — a blocking `fileExists` there can stall the UI for
    /// seconds. Refreshed by every `load()` and after the bottle's Steam install.
    public private(set) var steamInstalled = false

    /// Re-probe whether the bottle has a WARMED Steam client (off the main actor), updating the cache. Keys
    /// on `hasWarmedClient` (steamui.dll + a CEF webhelper), NOT the ~2 MB bootstrapper — so a failed
    /// first-run warm-up can't read as "ready" and let onboarding finish over a non-functional bottle.
    public func refreshSteamInstalled() async {
        let paths = self.paths
        steamInstalled = await Task.detached { SteamBottle.hasWarmedClient(paths: paths) }.value
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

    public func isRunning(_ game: SteamApp) -> Bool { pid(for: game) != nil }
    public func isBusy(_ game: SteamApp) -> Bool { busyGames.contains(game.appID) }

    /// The tracked wine-loader PID for a launched game (nil if not running) — the PID-returning sibling of
    /// `isRunning`. The UI only needs `isRunning`; this exists for tests driving exit/terminate scenarios.
    func pid(for game: SteamApp) -> Int32? { processes.pid(for: gameID(game)) }

    /// The coordinator key for a Steam game.
    private func gameID(_ game: SteamApp) -> GameID { .steam(appID: game.appID) }

    /// Whether a title is currently RUNNING (its wine-loader PID is tracked).
    private func isRunning(appID: Int) -> Bool { processes.pid(for: .steam(appID: appID)) != nil }

    public func isRunning(_ game: ManualGame) -> Bool { pid(for: game) != nil }
    public func isBusy(_ game: ManualGame) -> Bool { manualBusyIDs.contains(game.id) }
    /// The tracked PID for a launched manual game (nil if not running) — see `pid(for:)` above.
    func pid(for game: ManualGame) -> Int32? { processes.pid(for: .manual(game.id)) }

    public func sizeString(_ game: SteamApp) -> String? {
        guard game.sizeOnDisk > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)
    }

    /// Show a transient status line, then auto-clear it after `statusVisibleDuration`. Each call cancels the
    /// previous message's dismissal, so a fresh status resets the timer and a stale timer can never clear a
    /// newer message. Passing nil clears immediately.
    private func setStatus(_ message: String?) {
        statusDismissal?.cancel()
        statusMessage = message
        guard message != nil else { statusDismissal = nil; return }
        let duration = statusVisibleDuration
        statusDismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }   // superseded by a newer status → leave it be
            self?.statusMessage = nil
            self?.statusDismissal = nil
        }
    }

    // MARK: - Library

    /// Re-scan the Steam bottle for installed games, plus the persisted manual games.
    public func load() async {
        await refreshSteamInstalled()
        manualGames = sortedManual(await configStore.load().manualGames)
        // Manual games also live in a bottle, so the library still gates on the Steam bottle existing
        // (notReady drives the onboarding until Steam is set up).
        guard steamReady else { loadState = .notReady; return }
        var failure: String?
        do {
            games = try await discovery.discoverGames(steamRoot: paths.steamBottleClientDir)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch DiscoveryEngine.DiscoveryError.steamDirNotFound {
            games = []   // Steam installed but no library yet — drives onboarding, not alarms.
        } catch DiscoveryEngine.DiscoveryError.libraryUnreadable(let url) {
            games = []; failure = "Couldn't read the Steam library — \(url.path) isn't readable."
        } catch {
            games = []; failure = "Couldn't read the Steam library: \((error as NSError).localizedDescription)"
        }
        if let failure {
            // The library couldn't be READ (permissions/IO). With nothing else to show that's the load's
            // error state; if manual games exist, keep the library up and surface the failure as a status.
            guard !manualGames.isEmpty else { loadState = .error(failure); return }
            setStatus(failure)
        }
        loadState = (games.isEmpty && manualGames.isEmpty) ? .empty : .loaded
    }

    private func sortedManual(_ list: [ManualGame]) -> [ManualGame] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func refresh() async { await load() }

    // MARK: - Install / uninstall (routed through the shared Steam client)

    /// Open the bottle's Steam so the user can browse + install games.
    public func openSteam() async {
        if launchBlockedByBottles() { return }
        await session.ensureRunning()
    }

    /// Ask the bottle's Steam to uninstall the game, then refresh. Refused while the title is running.
    public func uninstall(_ game: SteamApp) async {
        guard !isRunning(appID: game.appID) else { return }
        do {
            try await session.sendURL("steam://uninstall/\(game.appID)")
            setStatus("Asked Steam to uninstall \(game.name). Refresh once it's done.")
        } catch { setStatus("Couldn't reach Steam: \((error as NSError).localizedDescription)") }
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game co-resident in the Steam bottle, with the Steam client up so Steamworks works. Routes
    /// prefix + runtime through `BottleResolver`.
    public func play(_ game: SteamApp) async {
        // No-op if it's already mid-launch (its button spins) or already running.
        guard backend.isWineConfigured, !busyGames.contains(game.appID),
              !isRunning(appID: game.appID) else { return }
        if launchBlockedByBottles() { return }
        busyGames.insert(game.appID); defer { busyGames.remove(game.appID) }
        let config = await configStore.load().config(for: game.appID)
        // A 32-bit game in the Steam bottle is a dead end — GPTK / D3DMetal is 64-bit-only, so it could only
        // fall back to wined3d and fail. Refuse up front (before bringing Steam up).
        if orchestrator.isBlocked32BitOnGPTK(app: game, config: config, graphics: .gptk) {
            setStatus(Self.unsupported32BitMessage(name: game.name, isSteamGame: true, dxmtAvailable: false))
            return
        }
        do {
            // Resolve the bottle prefix + prepared runtime (off-main).
            let cfg = backend
            let context = try await Task.detached { [paths] in
                try BottleResolver(paths: paths).steam(config: cfg)
            }.value
            // Steamworks IPC is prefix-scoped: the client must be up + logged in first. If it can't start,
            // surface why rather than launching against a dead Steam (which fails SteamAPI_Init silently).
            guard await session.ensureRunning() else {
                let why = session.launchError.map { ": \($0)" } ?? ""
                setStatus("\(game.name) needs the Steam client, but it couldn't start\(why).")
                return
            }
            let pid = try await orchestrator.launchInBottle(
                app: game, config: config, backend: backend, graphics: .gptk,
                wine: context.wineBinary, prefix: context.prefix,
                logURL: paths.log(forAppID: game.appID),
                dock: .init(name: game.name, folder: "app-\(game.appID)", containerDir: paths.dockAppsDir))
            processes.track(gameID(game), pid: pid)
            do {
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
                          name: game.name, backend: .gptk)
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
        }
    }

    /// Stop a running game. Terminates just the game (the shared bottle keeps Steam alive — a
    /// `wineserver -k` would kill the co-resident Steam client too). See `LaunchOrchestrator.stopGame`.
    public func stop(_ game: SteamApp) async {
        guard let pid = processes.pid(for: gameID(game)) else { return }
        let state = await configStore.load()
        let config = state.config(for: game.appID)
        let exeName = orchestrator.resolvedExecutableName(app: game, config: config)
        // `taskkill /IM <image>` matches by image name across the WHOLE wineserver (one per bottle). Two
        // DIFFERENT Steam games co-resident in the shared bottle CAN run at once, so if another one happens
        // to share this exe's basename, /IM would take it down too. Drop to a SIGTERM-only stop (the loader
        // PID) in that rare case rather than risk a bystander. Manual games each get their own isolated
        // bottle, so they never share this wineserver.
        // Case-insensitive: wine's `taskkill /IM` matches image names case-insensitively, so `Game.exe`
        // and `game.exe` collide.
        let siblings = coResidentImageNames(excluding: game, in: state)
        let safeExeName = exeName.flatMap { siblings.contains($0.lowercased()) ? nil : $0 }
        await orchestrator.stopGame(
            pid: pid, exeName: safeExeName, prefix: paths.steamBottle, backend: backend)
        processes.clear(gameID(game), ifPID: pid)
    }

    /// Exe basenames of OTHER Steam games currently running in the shared Steam bottle (they share one
    /// wineserver, so a `taskkill /IM` would hit them). Excludes `game` itself. Used by `stop` to avoid a
    /// basename collision.
    private func coResidentImageNames(excluding game: SteamApp, in state: AppState) -> Set<String> {
        var names: Set<String> = []
        for other in games
        where other.appID != game.appID && processes.pid(for: gameID(other)) != nil {
            if let name = orchestrator.resolvedExecutableName(
                app: other, config: state.config(for: other.appID)) {
                names.insert(name.lowercased())   // case-folded — see `stop`'s case-insensitive match
            }
        }
        return names
    }

    /// SIGTERM every game Silo launched (Steam + manual), synchronously. Used at app quit (where there's no
    /// time for the async `taskkill`/`wineserver -k` cleanup): wine turns SIGTERM into terminating the hosted
    /// game, and we only signal the PIDs Silo spawned — the co-resident Steam client is never touched.
    public func terminateAllSync() { processes.terminateAllSync() }

    /// Open `winecfg` for the Steam bottle prefix (prefix-wide, so not per-game).
    public func openWinecfg() async {
        guard backend.isWineConfigured else { setStatus("No Wine configured."); return }
        await orchestrator.runWineTool("winecfg", prefix: paths.steamBottle, backend: backend)
    }

    // MARK: - Manual (non-Steam) games — each in its OWN isolated bottle (paths.manualBottle(id))

    /// Boot a manual game's private bottle (idempotent — fast once booted). Returns whether it's ready.
    @discardableResult
    public func ensureManualBottle(_ id: UUID) async -> Bool {
        // The choke point for all manual-bottle provisioning (add/install/winecfg/play). Refuse while bottles
        // are moving or the drive is unplugged — provisioning writes into a prefix under `bottlesRoot`.
        if launchBlockedByBottles() { return false }
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
        if launchBlockedByBottles() { return }
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
        if launchBlockedByBottles() { return }
        manualBusyIDs.insert(game.id); defer { manualBusyIDs.remove(game.id) }
        // A 32-bit game on GPTK can't render (GPTK / D3DMetal is 64-bit-only) — refuse before provisioning
        // its bottle and steer to switching this game's backend to DXMT.
        if game.backend == .gptk, WindowsExecutable.is32Bit(game.executablePath) {
            setStatus(Self.unsupported32BitMessage(
                name: game.name, isSteamGame: false, dxmtAvailable: backend.libDir(for: .dxmt) != nil))
            return
        }
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
            let pid = try await orchestrator.launchManualGame(
                game, backend: backend, graphics: context.graphics,
                wine: context.wineBinary, prefix: context.prefix, logURL: paths.manualLog(game.id),
                dock: .init(name: game.name, folder: "manual-\(game.id.uuidString)",
                            containerDir: paths.dockAppsDir))
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
        case LaunchOrchestrator.LaunchError.unsupported32BitOnGPTK:
            // Backstop: the UI refuses 32-bit-on-GPTK earlier with a richer, DXMT-steering message
            // (unsupported32BitMessage); this covers any launch path that reaches the orchestrator directly.
            "this is a 32-bit game — GPTK / D3DMetal is 64-bit-only. Use DXMT (Settings → DXMT)."
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
        processes.clear(.manual(game.id), ifPID: pid)
    }

    /// Generate a Game-Mode-tagged `.app` in `directory` (default: the Desktop) that launches the game
    /// directly under ITS backend — startable from Spotlight/Dock without Silo. Routes through
    /// `BottleResolver` exactly like `playManual`, so the snapshotted env carries the game's variant
    /// runtime + dll overrides (a DXMT game's shortcut launches on the DXMT runtime, never the base).
    /// Returns the bundle URL, or nil with the failure surfaced in the status bar. Manual games only —
    /// they don't need the co-resident Steam client.
    @discardableResult
    public func makeShortcut(for game: ManualGame, into directory: URL? = nil) async -> URL? {
        if launchBlockedByBottles() { return nil }   // prepareGraphics seeds the prefix — not during a move
        // A 32-bit game on GPTK can't render (GPTK / D3DMetal is 64-bit-only), so the shortcut would launch
        // to a wined3d-fallback failure with no in-app steer. Refuse here exactly like `playManual` does.
        if game.backend == .gptk, WindowsExecutable.is32Bit(game.executablePath) {
            setStatus(Self.unsupported32BitMessage(
                name: game.name, isSteamGame: false, dxmtAvailable: backend.libDir(for: .dxmt) != nil))
            return nil
        }
        guard let dir = directory
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        let cfg = backend
        do {
            // Resolve + prepare graphics + build the plan off-main: the clone/overlay is slow, and a DXMT
            // game also needs its prefix loader (winemetal.dll) seeded — the shortcut execs wine directly
            // with no launch pipeline, so `linkGraphics` never runs for it otherwise.
            let plan = try await Task.detached { [paths, orchestrator] in
                let context = try BottleResolver(paths: paths).manual(game, config: cfg)
                try orchestrator.prepareGraphics(
                    backendConfig: cfg, graphics: context.graphics,
                    wine: context.wineBinary, prefix: context.prefix)
                return try LaunchOrchestrator.makePlan(
                    config: game.gameConfig, backend: cfg, graphics: context.graphics,
                    wine: context.wineBinary, gameExe: game.executablePath,
                    prefix: context.prefix, logURL: paths.manualLog(game.id))
            }.value
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
            // Only manual games can steer to DXMT (a Steam game has no DXMT bottle to move to yet).
            let dxmtAvailable = isSteamGame ? false : (self.backend.libDir(for: .dxmt) != nil)
            self.setStatus(Self.graphicsFallbackMessage(
                name: name, backend: graphics, isSteamGame: isSteamGame, dxmtAvailable: dxmtAvailable))
        }
    }

    /// The user-facing message when a backend didn't engage. Pure + table-testable; backend- and
    /// kind-aware. Never claims a working "fallback" and never suggests Silo rerouted the game. A GPTK
    /// MANUAL title is steered to DXMT (adapting to whether DXMT is set up); a GPTK Steam title has no DXMT
    /// bottle to move to yet, so it's told the class isn't supported in the Steam bottle.
    static func graphicsFallbackMessage(
        name: String, backend: GraphicsBackend, isSteamGame: Bool, dxmtAvailable: Bool
    ) -> String {
        switch backend {
        case .gptk:
            if isSteamGame {
                return "\(name): GPTK / D3DMetal couldn't drive this game's graphics. This class of older "
                    + "DirectX 10/11 titles isn't supported in the Steam bottle yet."
            }
            return "\(name): GPTK / D3DMetal couldn't drive this game's graphics — this class of older "
                + "DirectX 10/11 titles needs DXMT. " + dxmtSteer(dxmtAvailable: dxmtAvailable)
        case .dxmt:
            return "\(name): DXMT didn't engage — the game fell back to wined3d and likely failed. "
                + "Check the DXMT runtime in Settings → DXMT."
        }
    }

    /// The message when a 32-bit (i386) game is refused under GPTK. GPTK / D3DMetal is 64-bit-only (Apple
    /// ships no 32-bit D3DMetal). A manual title is steered to DXMT; a Steam title has no DXMT bottle yet.
    /// Pure + table-testable.
    static func unsupported32BitMessage(name: String, isSteamGame: Bool, dxmtAvailable: Bool) -> String {
        let base = "\(name) is a 32-bit game — GPTK / D3DMetal is 64-bit-only and can't run it. "
        return isSteamGame
            ? base + "32-bit Steam games aren't supported yet."
            : base + dxmtSteer(dxmtAvailable: dxmtAvailable)
    }

    /// Where an (older DirectX 10/11, or 32-bit) MANUAL title actually belongs — the DXMT-steering suffix
    /// shared by the graphics-fallback and 32-bit-refusal messages, adapting to DXMT readiness.
    private static func dxmtSteer(dxmtAvailable: Bool) -> String {
        dxmtAvailable
            ? "Switch this game's graphics backend to DXMT in its settings."
            : "Set up DXMT in Settings → DXMT first."
    }
}
