import Foundation

/// One backend's Steam-bottle service bundle: the bottle, its live client session, and the settings VM
/// driving setup/launch. Built once per `GraphicsBackend` by `AppEnvironment`, so backend services are
/// a keyed table instead of gptk/dxmt copy-paste pairs. Every backend's Steam client runs on the BASE
/// wine (CEF needs no d3d; a co-resident game picks the per-backend variant runtime — shared wineserver);
/// a secondary backend's bottle stays empty until the user sets it up via onboarding.
@MainActor
public final class BackendServices {
    public let backend: GraphicsBackend
    public let bottle: SteamBottle
    public let session: SteamClientSession
    public let bottleVM: SteamBottleViewModel

    init(backend: GraphicsBackend, runner: ProcessRunning, paths: AppPaths,
         orchestrator: LaunchOrchestrator) {
        self.backend = backend
        self.bottle = SteamBottle(runner: runner, paths: paths, backend: backend)
        self.session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        self.bottleVM = SteamBottleViewModel(bottle: bottle, session: session)
    }
}

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
    /// Per-backend Steam-bottle service bundles (bottle + client session + settings VM) — the ONE place
    /// backend services are built, keyed so nothing is duplicated per backend.
    public let backends: [GraphicsBackend: BackendServices]
    public let steamStore = SteamStoreClient()

    /// A backend's service bundle. Total by construction — `init` builds one per `GraphicsBackend`.
    public func services(for backend: GraphicsBackend) -> BackendServices {
        guard let services = backends[backend] else {
            preconditionFailure("BackendServices missing for \(backend) — init builds one per backend")
        }
        return services
    }

    // Convenience forwards (the pre-bundle names the views + tests use).
    public var steamBottleVM: SteamBottleViewModel { services(for: .gptk).bottleVM }
    /// Setup + launch for the DXMT Steam bottle (the older-games path) — same flow, the DXMT prefix.
    public var dxmtBottleVM: SteamBottleViewModel { services(for: .dxmt).bottleVM }
    /// The owner of the GPTK Steam bottle's live client (shared by the Library + the settings pane).
    public var steamClientSession: SteamClientSession { services(for: .gptk).session }
    /// The DXMT Steam bottle's client session (one Steam install/login per backend).
    public var dxmtClientSession: SteamClientSession { services(for: .dxmt).session }
    private let updater: Updater
    /// The inline self-update flow (check / download / relaunch) — Settings → General → Updates.
    public let updates: UpdateCoordinator
    public private(set) var didBootstrap = false
    private var isBootstrapping = false

    public init(
        paths: AppPaths = .standard(),
        runner: ProcessRunning = SystemProcessRunner(),
        updater: Updater? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.wineTools = WineTools(runner: runner)
        let updater = updater ?? Updater(runner: runner)
        self.updater = updater
        self.updates = UpdateCoordinator(updater: updater, updatesDir: paths.updatesDir)

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

        // One service bundle (bottle + client session + settings VM) per backend — see BackendServices.
        var backends: [GraphicsBackend: BackendServices] = [:]
        for backend in GraphicsBackend.allCases {
            backends[backend] = BackendServices(
                backend: backend, runner: runner, paths: paths, orchestrator: orchestrator)
        }
        self.backends = backends

        let gameLibrary = GameLibraryViewModel(
            bottle: backends[.gptk]!.bottle, discovery: discovery, orchestrator: orchestrator,
            configStore: configStore, paths: paths, backend: initialBackend,
            session: backends[.gptk]!.session, dxmtSession: backends[.dxmt]?.session,
            provisioner: WinePrefixProvisioner(runner: runner))
        self.gameLibrary = gameLibrary

        backendSettings.onChange = { [weak self] in self?.applyBackend($0) }
        gptkManager.onDefaultChanged = { [weak self] install in
            Task { await self?.backendSettings.applyDefaultGPTK(install) }
        }
        runtime.onDefaultChanged = { [weak self] wine in
            Task { await self?.backendSettings.applyDefaultWine(wine) }
        }
        // A fresh Steam install must flip the library's cached `steamReady` gate (it drives onboarding);
        // load() re-probes the cache off-main. Without this, onboarding would stall until a relaunch.
        for services in backends.values {
            services.bottleVM.onSteamInstalled = { [weak self] in Task { await self?.gameLibrary.load() } }
        }
    }

    /// Fan out a backend-config change to the view models that depend on it.
    private func applyBackend(_ config: BackendConfig) {
        gameLibrary.updateBackend(config)
        // Every backend's Steam client runs on the base wine (CEF; co-resident games pick the per-backend
        // variant). updateWine on each bottle VM also updates its session's wine.
        for services in backends.values { services.bottleVM.updateWine(config.wineBinaryPath) }
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
        // Populate the bottle VMs' cached installed-flags (settings buttons gate on them).
        for services in backends.values { await services.bottleVM.refreshInstalled() }
        // Library = games installed in the Steam bottle.
        await gameLibrary.load()
        await updates.checkForUpdate()   // best-effort; nil updateCheck on offline
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

    /// True while any game OR any bottle's Steam client is live — relocation is refused then (we'd be
    /// moving prefixes out from under running wineservers). Checks EVERY backend's session: a live DXMT
    /// client is just as much a running wineserver as the GPTK one.
    public var anythingRunning: Bool {
        gameLibrary.isAnythingRunning || backends.values.contains { $0.session.isRunning }
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

    // MARK: - Setup readiness (drives the Library onboarding)

    public var wineReady: Bool { backendSettings.config.wineBinaryPath != nil }
    public var gptkReady: Bool { backendSettings.config.gptkLibDirPath != nil }
    /// The Windows Steam client is installed in the bottle (the user signs into it in-app).
    public var steamReady: Bool { gameLibrary.steamReady }
    public var setupComplete: Bool { wineReady && gptkReady && steamReady }

    // MARK: - DXMT (optional older-games backend)

    /// The DXMT runtime (its module dir, built from CrossOver source) is configured.
    public var dxmtReady: Bool { backendSettings.config.dxmtLibDirPath != nil }
    /// The DXMT Steam bottle has its Windows Steam client installed (the library's off-main cache — a
    /// blocking `fileExists` here would run inside SwiftUI body evaluation).
    public var dxmtSteamReady: Bool { gameLibrary.steamInstalled(.dxmt) }

    /// Import a DXMT runtime by pointing at its `x86_64-windows` module dir (the `d3d11`/`winemetal`
    /// artifacts built from the CrossOver source). Validates the folder, then adopts it as the backend's
    /// DXMT lib dir (persisted + fanned out), enabling the DXMT bottle to launch games.
    public func importDXMTRuntime(from dir: URL) async {
        let required = ["d3d11.dll", "winemetal.dll"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
        else {
            backendSettings.statusMessage =
                "That folder isn't a DXMT runtime (expected d3d11.dll + winemetal.dll)."
            return
        }
        await backendSettings.applyDXMTLibDir(dir)
    }

    public private(set) var dxmtDownloading = false

    /// Download + install the latest DXMT build published to Silo's Releases (built by `build-dxmt.yml`)
    /// and adopt it as the backend's DXMT runtime — the auto-download counterpart of `importDXMTRuntime`.
    /// Reuses the Wine downloader engine end-to-end: `RuntimeManager.availableReleases` → `preferredAsset`
    /// → `installDXMT` (HTTPS-only, mandatory SHA-256 for our own repo, safe extract, de-quarantine +
    /// ad-hoc sign), exactly like `RuntimeViewModel.installLatest`.
    public func downloadLatestDXMT() async {
        guard !dxmtDownloading else { return }
        dxmtDownloading = true
        defer { dxmtDownloading = false }
        do {
            // The repo hosts app v* + wine-cx-* + dxmt-* releases. Pick the DXMT built against the
            // configured wine (tags are dxmt-<ver>-cx<wine>), else the newest dxmt-* — keeps winemetal.so
            // paired with the wine it runs on.
            let releases = try await runtimeManager.availableReleases(repo: Silo.wineRepo, limit: 30)
            guard let release = RuntimeManager.matchedDXMTRelease(
                releases, forWine: backendSettings.config.wineRuntimeName) else {
                backendSettings.statusMessage =
                    "No DXMT build published yet (the build-dxmt CI workflow must run first)."
                return
            }
            // Already installed? Adopt it without re-downloading.
            if let lib = await runtimeManager.installedDXMT()
                .first(where: { $0.name == release.tagName })?.libDir {
                await backendSettings.applyDXMTLibDir(lib, name: release.tagName)
                backendSettings.statusMessage = "Latest DXMT (\(release.tagName)) is already installed."
                return
            }
            guard let asset = RuntimeManager.preferredAsset(release) else {
                backendSettings.statusMessage = "Latest DXMT release has no installable archive."
                return
            }
            backendSettings.statusMessage = "Downloading DXMT \(release.tagName)…"
            // Our own repo → a published SHA-256 is mandatory (fail-closed), like Wine.
            let install = try await runtimeManager.installDXMT(
                name: release.tagName, from: asset.browserDownloadUrl, requireDigest: Silo.wineRepo == Versions.githubRepo)
            guard let lib = install.libDir else {
                backendSettings.statusMessage =
                    "Downloaded DXMT, but its x86_64-windows module folder wasn't found in the archive."
                return
            }
            await backendSettings.applyDXMTLibDir(lib, name: release.tagName)
            // Same warning the Wine installer surfaces: a failed de-quarantine/re-sign means Gatekeeper
            // may block winemetal.so — say so now rather than at a mysterious launch failure.
            let warning = await runtimeManager.lastHardeningIssue
            backendSettings.statusMessage = warning.map { "Installed DXMT \(release.tagName) — ⚠️ \($0)" }
                ?? "Installed DXMT \(release.tagName)."
        } catch {
            backendSettings.statusMessage = "DXMT download failed: \((error as NSError).localizedDescription)"
        }
    }

    // MARK: - Steam-bottle Wine tools (Settings → General)

    /// Last result of a bottle-tool action (Retina toggle / winecfg / regedit), shown in Settings.
    public private(set) var bottleToolsMessage: String?
    public private(set) var bottleToolsBusy = false

    /// The wine binary games launch with (nil until Wine is configured).
    public var wineBinary: URL? { backendSettings.config.wineBinaryPath }

    /// Toggle macOS Retina/HiDPI mode for the Steam bottles: persist the ONE preference, then write the
    /// `RetinaMode` registry key into EVERY installed bottle's prefix (GPTK + DXMT stay consistent).
    /// Takes effect on the next game launch.
    public func setSteamBottleRetina(_ on: Bool) async {
        guard let wine = wineBinary else { bottleToolsMessage = "Set up Wine first."; return }
        guard !bottleToolsBusy else { return }
        bottleToolsBusy = true; defer { bottleToolsBusy = false }
        backendSettings.config.retinaMode = on
        await backendSettings.save()
        do {
            for graphics in GraphicsBackend.allCases where gameLibrary.steamInstalled(graphics) {
                try await wineTools.setRetinaMode(on, prefix: paths.steamBottle(graphics), wine: wine)
            }
            bottleToolsMessage = "Retina mode \(on ? "on" : "off") — applies on the next game launch."
        } catch {
            bottleToolsMessage = "Couldn't update Retina mode: \((error as NSError).localizedDescription)"
        }
    }

    /// Open a Wine maintenance tool (winecfg / regedit / control) on a backend's Steam bottle so the user
    /// can fix that prefix by hand. Routes through the shared `runWineTool` (single tool-launch path).
    public func openWineTool(_ tool: String, for graphics: GraphicsBackend = .gptk) async {
        guard wineBinary != nil else { bottleToolsMessage = "Set up Wine first."; return }
        await orchestrator.runWineTool(tool, prefix: paths.steamBottle(graphics), backend: backendSettings.config)
        bottleToolsMessage = "Opened \(tool)."
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
