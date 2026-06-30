import Foundation

/// Composition root: constructs every service + the long-lived view models, and wires them together.
@MainActor
@Observable
public final class AppEnvironment {
    public let paths: AppPaths
    let configStore: ConfigStore
    let runner: ProcessRunning
    let linker: GraphicsLinker
    let orchestrator: LaunchOrchestrator
    let discovery: DiscoveryEngine
    let runtimeManager: RuntimeManager
    /// Runs Wine maintenance tools + registry tweaks (Retina) against the shared Steam bottle.
    let wineTools: WineTools

    public let gameLibrary: GameLibraryViewModel
    public let backendSettings: BackendSettingsViewModel
    public let runtime: RuntimeViewModel
    public let gptkManager: GPTKManagerViewModel
    public let steamBottleVM: SteamBottleViewModel
    /// The owner of the GPTK Steam bottle's live client (shared by the Library + the settings pane).
    public let steamClientSession: SteamClientSession
    /// The DXMT Steam bottle's client session (one Steam install/login per backend).
    public let dxmtClientSession: SteamClientSession
    public let steamStore = SteamStoreClient()
    private let updater: Updater
    public private(set) var updateCheck: Updater.UpdateCheck?
    public private(set) var updateState: UpdateState = .idle
    public private(set) var isCheckingForUpdate = false
    public private(set) var didBootstrap = false
    private var isBootstrapping = false

    /// Progress of the inline (download + self-replace + relaunch) update.
    public enum UpdateState: Sendable, Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    public init(
        paths: AppPaths = .standard(),
        runner: ProcessRunning = SystemProcessRunner(),
        updater: Updater? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.wineTools = WineTools(runner: runner)
        self.updater = updater ?? Updater(runner: runner)

        let configStore = ConfigStore(paths: paths)
        let linker = GraphicsLinker()
        let discovery = DiscoveryEngine()
        let orchestrator = LaunchOrchestrator(runner: runner, linker: linker)
        let runtimeManager = RuntimeManager(paths: paths, runner: runner)

        self.configStore = configStore
        self.linker = linker
        self.discovery = discovery
        self.orchestrator = orchestrator
        self.runtimeManager = runtimeManager

        let initialBackend = BackendConfig()
        self.backendSettings = BackendSettingsViewModel(
            config: initialBackend, configStore: configStore)
        self.runtime = RuntimeViewModel(manager: runtimeManager, repo: Silo.wineRepo)
        self.gptkManager = GPTKManagerViewModel(importer: GPTKImporter(runner: runner, paths: paths))

        let bottle = SteamBottle(runner: runner, paths: paths, backend: .gptk)
        let steamClientSession = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        self.steamClientSession = steamClientSession
        // The DXMT Steam bottle + its client session (one Steam install/login per backend). The client runs
        // on the base wine (CEF needs no d3d; a co-resident DXMT game launches on the DXMT variant runtime,
        // which shares the prefix's wineserver). Empty until the user sets it up via onboarding.
        let dxmtBottle = SteamBottle(runner: runner, paths: paths, backend: .dxmt)
        let dxmtSession = SteamClientSession(bottle: dxmtBottle, orchestrator: orchestrator)
        self.dxmtClientSession = dxmtSession
        let gameLibrary = GameLibraryViewModel(
            bottle: bottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend, session: steamClientSession,
            dxmtSession: dxmtSession,
            provisioner: WinePrefixProvisioner(runner: runner))
        self.gameLibrary = gameLibrary
        let steamBottleVM = SteamBottleViewModel(bottle: bottle, session: steamClientSession)
        self.steamBottleVM = steamBottleVM

        backendSettings.onChange = { [weak self] in self?.applyBackend($0) }
        gptkManager.onDefaultChanged = { [weak self] install in
            Task { await self?.backendSettings.applyDefaultGPTK(install) }
        }
        runtime.onDefaultChanged = { [weak self] wine in
            Task { await self?.backendSettings.applyDefaultWine(wine) }
        }
    }

    /// Fan out a backend-config change to the view models that depend on it.
    private func applyBackend(_ config: BackendConfig) {
        gameLibrary.updateBackend(config)
        steamBottleVM.updateWine(config.wineBinaryPath)
        // Both Steam clients run on the base wine (CEF; co-resident games pick the per-backend variant).
        dxmtClientSession.updateWine(config.wineBinaryPath)
    }

    /// Load persisted config and populate the UI. Idempotent.
    public func bootstrap() async {
        guard !didBootstrap, !isBootstrapping else { return }
        isBootstrapping = true
        let state = await configStore.load()
        backendSettings.config = state.backend
        applyBackend(state.backend)
        gptkManager.defaultName = state.backend.gptkRuntimeName
        gptkManager.refresh()
        runtime.defaultName = state.backend.wineRuntimeName
        await runtime.refresh()
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        await checkForUpdate()   // best-effort; sets updateCheck + the "up to date" message (nil on offline)
        didBootstrap = true
        isBootstrapping = false
    }

    /// Reload the bottle's game library (e.g. on app re-activation).
    public func refreshLibraryIfReady() async {
        guard didBootstrap, gameLibrary.steamReady else { return }
        await gameLibrary.load()
    }

    // MARK: - Bottles location

    public private(set) var bottlesBusy = false
    public private(set) var bottlesMessage: String?
    /// Copy progress during a cross-volume move (`0...1`), or nil when indeterminate / not moving.
    public private(set) var bottlesProgress: Double?
    /// Rejects a destination whose filesystem can't hold a Wine bottle (exFAT/FAT). Injectable for tests.
    var bottlesFilesystemRejects: @Sendable (URL) -> Bool = { Filesystem.isFATFamily($0) }

    /// True while any game OR the bottle Steam client is live — relocation is refused then (we'd be moving
    /// prefixes out from under running wineservers).
    public var anythingRunning: Bool {
        gameLibrary.isAnythingRunning || steamClientSession.isRunning
    }

    /// Move all bottles into a `Silo Bottles` folder inside `chosen` (a directory the user picked — e.g. an
    /// external drive), so we never scatter prefixes directly into a shared location. Refuses an exFAT/FAT
    /// destination — a Wine prefix needs POSIX symlinks.
    public func moveBottles(to chosen: URL) async {
        guard !bottlesFilesystemRejects(chosen) else {
            bottlesMessage = "That location is exFAT/FAT, which can't hold a Wine bottle (no symlink "
                + "support). Reformat the drive as APFS or Mac OS Extended, then try again."
            return
        }
        await relocateBottles(to: chosen.appendingPathComponent("Silo Bottles", isDirectory: true))
    }

    /// Move bottles back to the default location (under Application Support).
    public func resetBottlesLocation() async {
        guard paths.bottlesRelocated else { return }
        await relocateBottles(to: paths.supportDir)
    }

    /// Relocate the bottle dirs to `newRoot`, persist the choice, and relaunch to adopt it everywhere
    /// (`AppPaths` is injected by value, so the clean way to re-point every consumer is a fresh launch).
    private func relocateBottles(to newRoot: URL) async {
        guard !bottlesBusy else { return }
        guard !anythingRunning else {
            bottlesMessage = "Stop running games and Steam before moving bottles."
            return
        }
        let old = paths.bottlesRoot
        guard newRoot.standardizedFileURL != old.standardizedFileURL else {
            bottlesMessage = "Bottles are already there."
            return
        }
        bottlesBusy = true
        bottlesProgress = 0
        bottlesMessage = "Moving bottles… this can take a while for installed games."
        defer { bottlesBusy = false; bottlesProgress = nil }

        let names = AppPaths.bottleDirNames
        do {
            // Off the main actor — a cross-volume move is a full copy of (potentially huge) game data.
            // The progress callback hops back to the main actor to update the determinate bar.
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try await BottleRelocator().move(names, from: old, to: newRoot) { fraction in
                    Task { @MainActor in self?.bottlesProgress = fraction }
                }
            }.value
        } catch {
            bottlesMessage = "Couldn't move bottles: \((error as NSError).localizedDescription)"
            return
        }

        // Persist (nil = back to the default), then adopt via relaunch.
        let isDefault = newRoot.standardizedFileURL == paths.supportDir.standardizedFileURL
        BottlesLocation.write(isDefault ? nil : newRoot, supportDir: paths.supportDir)
        if let bundle = Updater.runningAppBundle() {
            bottlesMessage = "Bottles moved. Relaunching…"
            await updater.relaunch(bundle)   // launches the new instance + exit(0); never returns
        } else {
            bottlesMessage = "Bottles moved to \(newRoot.path). Restart Silo to use the new location."
        }
    }

    /// Manually re-check GitHub for a newer app release — the same check `bootstrap()` runs automatically,
    /// surfaced as a "Check for Updates" button in Settings → General.
    public func checkForUpdate() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        updateCheck = try? await updater.checkForUpdate()   // best-effort; nil on failure/offline
        isCheckingForUpdate = false
    }

    /// Apply the available update **inline** (Sparkle-style): download the release, swap the running
    /// `Silo.app` in place, and relaunch — no browser hop or manual install. No-op without a newer
    /// release; surfaces a recoverable `.failed` state when not running from an `.app` bundle (dev/CLI)
    /// or on a download/install error. On success it relaunches and never returns. Surfaced by the General
    /// settings tab (`GeneralSettingsView`).
    public func installUpdate() async {
        guard let check = updateCheck, check.isNewer else { return }
        guard let appBundle = Updater.runningAppBundle() else {
            updateState = .failed("Silo isn't running from an installed app bundle.")
            return
        }
        updateState = .downloading
        do {
            let zip = try await updater.downloadUpdate(check, into: paths.updatesDir)
            updateState = .installing
            try await updater.installUpdate(zip: zip, replacing: appBundle)
            await updater.relaunch(appBundle)   // launches the new build + exit(0); never returns
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Windows Steam client is installed in the bottle (the user signs into it in-app).
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    // MARK: - Steam-bottle Wine tools (Settings → General)

    /// Last result of a bottle-tool action (Retina toggle / winecfg / regedit), shown in Settings.
    public private(set) var bottleToolsMessage: String?
    public private(set) var bottleToolsBusy = false

    /// The wine binary games launch with (nil until Wine is configured).
    public var wineBinary: URL? { backendSettings.config.wineBinaryPath }

    /// Toggle macOS Retina/HiDPI mode for the shared Steam bottle: persist the choice, then write the
    /// `RetinaMode` registry key into the bottle prefix. Takes effect on the next game launch.
    public func setSteamBottleRetina(_ on: Bool) async {
        guard let wine = wineBinary else { bottleToolsMessage = "Set up Wine first."; return }
        guard !bottleToolsBusy else { return }
        bottleToolsBusy = true; defer { bottleToolsBusy = false }
        backendSettings.config.retinaMode = on
        await backendSettings.save()
        do {
            try await wineTools.setRetinaMode(on, prefix: paths.steamBottle, wine: wine)
            bottleToolsMessage = "Retina mode \(on ? "on" : "off") — applies on the next game launch."
        } catch {
            bottleToolsMessage = "Couldn't update Retina mode: \((error as NSError).localizedDescription)"
        }
    }

    /// Open a Wine maintenance tool (winecfg / regedit / control) on the shared Steam bottle so the user
    /// can fix the prefix by hand. Routes through the shared `runWineTool` (single tool-launch path).
    public func openWineTool(_ tool: String) async {
        guard wineBinary != nil else { bottleToolsMessage = "Set up Wine first."; return }
        await orchestrator.runWineTool(tool, prefix: paths.steamBottle, backend: backendSettings.config)
        bottleToolsMessage = "Opened \(tool)."
    }

    /// Generate a Game-Mode-tagged `.app` on the Desktop that launches `game` directly under GPTK (so it's
    /// startable from Spotlight/Dock). The launch env is snapshotted from the same `makePlan` Silo launches
    /// with. Returns the bundle URL, or nil if Wine isn't configured / the write failed. Manual games only —
    /// they don't need the co-resident Steam client.
    public func makeManualGameShortcut(_ game: ManualGame) -> URL? {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let plan = try? LaunchOrchestrator.makePlan(
                config: GameConfig(appID: 0, envFlags: game.envFlags, presence: .none, customArgs: game.customArgs),
                backend: backendSettings.config, gameExe: game.executablePath,
                prefix: paths.manualBottle(game.id), logURL: paths.manualLog(game.id))
        else { return nil }
        return try? GameAppShortcut(name: game.name, plan: plan).write(into: desktop)
    }

    /// Build a per-game settings view model with the game's persisted config.
    public func makeGameSettings(appID: Int) async -> GameSettingsViewModel {
        let state = await configStore.load()
        return GameSettingsViewModel(config: state.config(for: appID), configStore: configStore)
    }

    /// A game's launch log (per appID).
    public nonisolated func logURL(forAppID appID: Int) -> URL {
        paths.log(forAppID: appID)
    }
}
