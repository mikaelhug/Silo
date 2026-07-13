import Foundation

/// Identity of a launched game across both kinds — the key for the per-launch graphics-fallback monitors.
/// A Steam game is identified by its appID; a manual (non-Steam) game by its stable id.
enum GameID: Hashable, Sendable {
    case steam(appID: Int)
    case manual(UUID)
}

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
    /// The owner of the Steam bottle's live client (shared with the settings pane).
    private let session: SteamClientSession
    /// Boots the per-game isolated bottles that manual (non-Steam) games run in.
    private let provisioner: WinePrefixProvisioner
    /// Per-launch watchers that surface a silent backend→wined3d graphics fallback, keyed by `GameID`. Silo
    /// does NOT track launched games' PIDs (it launches them detached and lets them — and Steam — outlive the
    /// app, like CrossOver); this is the only per-launch state it keeps, and each monitor self-drops after it
    /// fires (or is superseded by a relaunch of the same game).
    private var monitors: [GameID: GraphicsFallbackMonitor] = [:]

    public init(
        bottle: SteamBottle,
        discovery: DiscoveryEngine,
        orchestrator: LaunchOrchestrator,
        configStore: ConfigStore,
        paths: AppPaths,
        backend: BackendConfig,
        session: SteamClientSession,
        provisioner: WinePrefixProvisioner
    ) {
        self.bottle = bottle
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.configStore = configStore
        self.paths = paths
        self.backend = backend
        self.session = session
        self.provisioner = provisioner
    }

    /// Cancel any live graphics monitors so they can't outlive the VM (a process-lifetime singleton, so this
    /// normally never fires). `isolated` to touch `@MainActor` state.
    isolated deinit { monitors.values.forEach { $0.stop() } }

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
            setStatus("Silo is moving your bottles — try again shortly.")
            return true
        }
        if isUpdating() {
            setStatus("Installing an update — Silo will relaunch shortly.")
            return true
        }
        if paths.bottlesRelocated, !paths.bottlesRootReachable {
            setStatus("Bottles drive not connected.")
            return true
        }
        return false
    }

    /// Whether a launch is currently in flight — a Play that has claimed a bottle but not yet spawned. Feeds
    /// the relocation/update gate so a move started in that window can't copy/delete the prefix out from under
    /// an arriving game. Games that are actually RUNNING are detected PID-free by `WineServerProbe` (a live
    /// wineserver on the bottle), NOT tracked here — Silo launches detached and lets them outlive the app.
    public var launchInFlight: Bool { !busyGames.isEmpty || !manualBusyIDs.isEmpty }

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

    public func isBusy(_ game: SteamApp) -> Bool { busyGames.contains(game.appID) }
    public func isBusy(_ game: ManualGame) -> Bool { manualBusyIDs.contains(game.id) }

    /// The graphics-monitor key for a Steam game.
    private func gameID(_ game: SteamApp) -> GameID { .steam(appID: game.appID) }

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

    /// Ask the bottle's Steam to uninstall the game, then refresh. (Steam itself declines to uninstall a
    /// title that's running, so no separate guard is needed now that Silo doesn't track game PIDs.)
    public func uninstall(_ game: SteamApp) async {
        do {
            try await session.sendURL("steam://uninstall/\(game.appID)")
            setStatus("Told Steam to uninstall \(game.name).")
        } catch { setStatus("Couldn't reach Steam: \((error as NSError).localizedDescription)") }
    }

    // MARK: - Launch (co-resident in the bottle)

    /// Launch a game co-resident in the Steam bottle, with the Steam client up so Steamworks works. Routes
    /// prefix + runtime through `BottleResolver`.
    public func play(_ game: SteamApp) async {
        // No-op if it's already mid-launch (its button spins) or already running.
        guard backend.isWineConfigured, !busyGames.contains(game.appID) else { return }
        if launchBlockedByBottles() { return }
        busyGames.insert(game.appID); defer { busyGames.remove(game.appID) }
        let config = await configStore.load().config(for: game.appID)
        let cfg = backend
        let dxmtConfigured = backend.libDir(for: .dxmt) != nil
        // Resolve the exe ONCE off-main (the install-dir scan can be a large walk) and read its bitness; pick
        // the backend from that. The SAME exe is handed to `launchInBottle` (so the decision and the launch
        // can't disagree) and to `watchGraphics` (which reads its imports only if a failure actually fires).
        let (exe, is32): (URL?, Bool) = await Task.detached { [orchestrator] in
            let exe = orchestrator.resolvedExecutable(app: game, config: config)
            return (exe, exe.map { WindowsExecutable.is32Bit($0) } ?? false)
        }.value
        // A learned hint only counts if it was learned under the CURRENT GPTK runtime — a GPTK upgrade may
        // fix the title, so a stale hint is dropped (passed as nil) and GPTK is re-probed.
        let learned = config.learnedUnderRuntime == cfg.gptkRuntimeName ? config.learnedBackend : nil
        let chosen = BackendChooser.choose(config.graphics, is32Bit: is32, learned: learned)
        // A 32-bit game under an EXPLICIT GPTK choice is a dead end (Apple ships no i386 D3DMetal). Automatic
        // routes 32-bit to DXMT, so this is only reachable when the user pinned GPTK. Refuse with a DXMT steer.
        if config.graphics == .gptk, is32 {
            setStatus(Self.unsupported32BitMessage(name: game.name, dxmtAvailable: dxmtConfigured))
            return
        }
        // A 32-bit game routed to DXMT needs the DXMT runtime to ship i386 modules; a 64-bit-only DXMT build
        // would launch to a silent black screen. Refuse honestly. (If DXMT isn't configured at all, the
        // resolver throws `backendNotConfigured` below with its own "install DXMT" message.)
        if is32, chosen == .dxmt, dxmtConfigured, !cfg.dxmtSupports32Bit {
            setStatus("\(game.name) needs the 32-bit DXMT build — update DXMT in Settings.")
            return
        }
        do {
            // Resolve the bottle prefix + prepared runtime for the chosen backend (off-main). An unconfigured
            // DXMT throws here (before Steam is brought up), surfaced via `resolveMessage`.
            let context = try await Task.detached { [paths] in
                try BottleResolver(paths: paths).steam(backend: chosen, config: cfg)
            }.value
            // Steamworks IPC is prefix-scoped: the client must be up + logged in first. If it can't start,
            // surface why rather than launching against a dead Steam (which fails SteamAPI_Init silently).
            guard await session.ensureRunning() else {
                let why = session.launchError.map { ": \($0)" } ?? ""
                setStatus("\(game.name) needs Steam, which couldn't start\(why).")
                return
            }
            try await orchestrator.launchInBottle(
                app: game, config: config, backend: backend, graphics: chosen,
                wine: context.wineBinary, prefix: context.prefix,
                logURL: paths.log(forAppID: game.appID),
                gameExe: exe)
            do {
                _ = try await configStore.updateGame(appID: game.appID) { $0.lastPlayed = Date() }
                setStatus("Launched \(game.name).")
            } catch {
                // The game IS running, but config.json is unwritable — say so (settings won't stick either).
                setStatus("Launched \(game.name) — play date not saved.")
            }
            // Automatic learns: an AUTO game GPTK can't drive gets remembered as DXMT for next time. The
            // eligibility is RE-checked with fresh state when the failure actually fires (see `watchGraphics`),
            // so a pin/uninstall between now and then can't clobber the user. Last, so a detected fallback
            // overrides the "Launched" status.
            let learnAppID = config.graphics == .auto && chosen == .gptk ? game.appID : nil
            watchGraphics(gameID(game), log: paths.log(forAppID: game.appID), name: game.name,
                          backend: chosen, exe: exe, autoLearnAppID: learnAppID)
        } catch {
            setStatus("\(game.name): \(Self.resolveMessage(error))")
        }
    }

    /// Open `winecfg` for the Steam bottle prefix (prefix-wide, so not per-game).
    public func openWinecfg() async {
        guard let ctx = try? BottleResolver(paths: paths).steamTool(config: backend) else {
            setStatus("No Wine configured."); return
        }
        await orchestrator.runWineTool("winecfg", prefix: ctx.prefix, wine: ctx.wineBinary)
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
            setStatus("Couldn't remove the bottle. Delete it in Finder: \(paths.manualBottle(id).path)")
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
            setStatus("Running installer — then choose the installed .exe.")
        } catch { setStatus("Couldn't run the installer: \(Self.resolveMessage(error))") }
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
    /// files on disk (outside the bottle) are left untouched. Refuses while the game's bottle is live (a live
    /// wineserver ⇒ the game is running; deleting the prefix under it would corrupt/orphan it).
    public func removeManual(_ game: ManualGame) async {
        guard !WineServerProbe.isLive(prefix: paths.manualBottle(game.id)) else {
            setStatus("\(game.name) is running — quit it first.")
            return
        }
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
        guard backend.isWineConfigured, !manualBusyIDs.contains(game.id) else { return }
        if launchBlockedByBottles() { return }
        manualBusyIDs.insert(game.id); defer { manualBusyIDs.remove(game.id) }
        let is32 = WindowsExecutable.is32Bit(game.executablePath)
        let dxmtConfigured = backend.libDir(for: .dxmt) != nil
        // A 32-bit game on GPTK can't render (GPTK / D3DMetal is 64-bit-only) — refuse before provisioning
        // its bottle and steer to switching this game's backend to DXMT.
        if game.backend == .gptk, is32 {
            setStatus(Self.unsupported32BitMessage(name: game.name, dxmtAvailable: dxmtConfigured))
            return
        }
        // A 32-bit game on DXMT needs the DXMT runtime's i386 modules; a 64-bit-only DXMT build would launch
        // to a silent black screen. Refuse honestly (mirrors `play`) — but only when DXMT IS configured; an
        // unconfigured DXMT is caught by `BottleResolver.manual` below with its own "install DXMT" message.
        if game.backend == .dxmt, is32, dxmtConfigured, !backend.dxmtSupports32Bit {
            setStatus("\(game.name) needs the 32-bit DXMT build — update DXMT in Settings.")
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
            try await orchestrator.launchManualGame(
                game, backend: backend, graphics: context.graphics,
                wine: context.wineBinary, prefix: context.prefix, logURL: paths.manualLog(game.id))
            do {
                _ = try await configStore.updateManualGame(id: game.id) { $0.lastPlayed = Date() }
                setStatus("Launched \(game.name).")
            } catch {
                // The game IS running, but config.json is unwritable — say so (settings won't stick either).
                setStatus("Launched \(game.name) — play date not saved.")
            }
            watchGraphics(.manual(game.id), log: paths.manualLog(game.id),   // last (see play); manual games
                          name: game.name, backend: game.backend, exe: game.executablePath)   // never auto-learn
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
            "couldn't find the game's program in \(url.path) — choose the correct .exe in the game's settings."
        case LaunchOrchestrator.LaunchError.unsupported32BitOnGPTK:
            // Backstop: the UI refuses 32-bit-on-GPTK earlier with a richer, DXMT-steering message
            // (unsupported32BitMessage); this covers any launch path that reaches the orchestrator directly.
            "this is a 32-bit game — GPTK / D3DMetal is 64-bit-only. Use DXMT (Settings → DXMT)."
        case WinePrefixProvisioner.ProvisionError.winebootFailed:
            "couldn't initialize the game's Wine bottle — check your Wine setup in Settings."
        case RuntimeVariants.VariantError.cloneFailed:
            "couldn't prepare the DXMT runtime — you may be low on disk space."
        case GraphicsLinker.LinkError.sourceMissing:
            "the graphics runtime is incomplete — re-download it in Settings."
        default:
            (error as NSError).localizedDescription
        }
    }

    /// Open `winecfg` for a manual game's OWN bottle (Windows version, libraries — isolated per game).
    public func openManualWinecfg(_ game: ManualGame) async {
        guard await ensureManualBottle(game.id) else { return }
        guard let ctx = try? BottleResolver(paths: paths).manualTool(game.id, config: backend) else {
            setStatus("No Wine configured."); return
        }
        await orchestrator.runWineTool("winecfg", prefix: ctx.prefix, wine: ctx.wineBinary)
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

    /// Watch a launched game's log; surface an actionable status if its backend never engaged (the log shows
    /// wine's own wined3d driving d3d1x, which for the titles this happens to then fails to create a device).
    /// For an `.auto` Steam game under GPTK (`autoLearnAppID` set) Silo REROUTES: it persists `.dxmt` so the
    /// next launch uses it. Nothing happens until a failure fires, so the failure-only work (reading the exe's
    /// imports, a fresh config read) is deferred to `handleGraphicsFallback` rather than done on every launch.
    private func watchGraphics(_ id: GameID, log: URL, name: String, backend graphics: GraphicsBackend,
                               exe: URL?, autoLearnAppID: Int? = nil) {
        monitors[id]?.stop()   // supersede any prior launch's monitor for the same game
        let monitor = GraphicsFallbackMonitor()
        monitors[id] = monitor
        monitor.start(url: log, backend: graphics) { [weak self] in
            guard let self else { return }
            self.monitors[id] = nil          // fires at most once, then drops itself
            Task { @MainActor in
                await self.handleGraphicsFallback(name: name, backend: graphics, exe: exe, autoLearnAppID: autoLearnAppID)
            }
        }
    }

    /// React to a detected backend non-engagement. `dxmtMightHelp` — a PE import-table read — is computed
    /// HERE, only on the rare failure (never on a healthy launch). An `.auto` Steam GPTK game DXMT could help
    /// is rerouted (`learnDXMT`); everything else gets an honest message.
    private func handleGraphicsFallback(
        name: String, backend graphics: GraphicsBackend, exe: URL?, autoLearnAppID: Int?) async {
        let dxmtMightHelp = await Task.detached { exe.map { BackendChooser.dxmtMightHelp(exe: $0) } ?? true }.value
        if graphics == .gptk, dxmtMightHelp, let appID = autoLearnAppID, backend.libDir(for: .dxmt) != nil {
            await learnBackend(appID: appID, name: name, dxmtMightHelp: dxmtMightHelp)
        } else {
            setStatus(fallbackMessage(name: name, backend: graphics, dxmtMightHelp: dxmtMightHelp))
        }
    }

    /// Record a `.dxmt` LEARNED hint (not the user's `graphics`) for an `.auto` Steam game GPTK couldn't
    /// drive, so the next launch uses DXMT while `.auto` — and the settings UI — stay intact. The hint is
    /// stamped with the current GPTK runtime so a later GPTK upgrade re-probes GPTK. Re-reads current state
    /// first, so a backend the user pinned (or a DXMT uninstalled) since launch is never clobbered, and the
    /// "will use DXMT next time" line is shown only if the write actually stuck.
    private func learnBackend(appID: Int, name: String, dxmtMightHelp: Bool) async {
        guard await configStore.load().config(for: appID).graphics == .auto, backend.libDir(for: .dxmt) != nil
        else { setStatus(fallbackMessage(name: name, backend: .gptk, dxmtMightHelp: dxmtMightHelp)); return }
        let runtime = backend.gptkRuntimeName   // captured out of the @Sendable mutate closure
        do {
            _ = try await configStore.updateGame(appID: appID) {
                $0.learnedBackend = .dxmt
                $0.learnedUnderRuntime = runtime
            }
            setStatus("\(name): GPTK / D3DMetal couldn't run this game — Silo will use DXMT next launch.")
        } catch {   // persist failed — don't promise a switch that didn't stick
            setStatus("\(name): GPTK / D3DMetal couldn't run this game. Set its graphics to DXMT.")
        }
    }

    /// `graphicsFallbackMessage` with `dxmtAvailable` read live from the current config.
    private func fallbackMessage(name: String, backend graphics: GraphicsBackend, dxmtMightHelp: Bool) -> String {
        Self.graphicsFallbackMessage(
            name: name, backend: graphics, dxmtAvailable: backend.libDir(for: .dxmt) != nil, dxmtMightHelp: dxmtMightHelp)
    }

    /// The user-facing message when a backend didn't engage. Pure + table-testable. Never claims a working
    /// "fallback". Steers to DXMT (Steam and manual games both have a per-game Graphics setting) only when
    /// DXMT could actually translate this game (`dxmtMightHelp`) — a D3D12 or D3D9-only title, which DXMT
    /// can't run, gets no false steer.
    static func graphicsFallbackMessage(
        name: String, backend: GraphicsBackend, dxmtAvailable: Bool, dxmtMightHelp: Bool
    ) -> String {
        switch backend {
        case .gptk:
            guard dxmtMightHelp else {
                // DXMT can't help (D3D12 → GPTK is the only Metal path; D3D9-only → Wine's wined3d).
                return "\(name): GPTK / D3DMetal couldn't drive this game's graphics."
            }
            return "\(name): GPTK / D3DMetal couldn't drive this game's graphics. "
                + dxmtSteer(dxmtAvailable: dxmtAvailable)
        case .dxmt:
            return "\(name): DXMT couldn't drive this game's graphics. "
                + "Check the DXMT runtime in Settings → DXMT."
        }
    }

    /// The message when a 32-bit (i386) game is refused under an explicit GPTK choice. GPTK / D3DMetal is
    /// 64-bit-only (Apple ships no 32-bit D3DMetal), so the game is steered to DXMT / Automatic. Pure.
    static func unsupported32BitMessage(name: String, dxmtAvailable: Bool) -> String {
        "\(name) is a 32-bit game — GPTK / D3DMetal is 64-bit-only and can't run it. "
            + dxmtSteer(dxmtAvailable: dxmtAvailable)
    }

    /// The DXMT-steering suffix shared by the graphics-fallback and 32-bit-refusal messages, adapting to
    /// DXMT readiness. Both Steam and manual games expose a per-game Graphics setting.
    private static func dxmtSteer(dxmtAvailable: Bool) -> String {
        dxmtAvailable
            ? "Switch this game's graphics to DXMT in its settings."
            : "Set up DXMT in Settings → DXMT first."
    }
}
