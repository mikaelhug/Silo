import Foundation

/// Builds launch plans and runs the launch pipeline for a game in the Steam bottle.
///
/// `makePlan` is a **pure** function (exhaustively tested); `launchInBottle` is the thin async wrapper
/// that injects graphics libraries into the (already-provisioned) bottle prefix and spawns the game.
public struct LaunchOrchestrator: Sendable {
    private let runner: ProcessRunning
    private let linker: GraphicsLinker
    private let presenceInstaller: SteamPresenceInstaller

    public init(
        runner: ProcessRunning,
        linker: GraphicsLinker,
        presenceInstaller: SteamPresenceInstaller = SteamPresenceInstaller()
    ) {
        self.runner = runner
        self.linker = linker
        self.presenceInstaller = presenceInstaller
    }

    public enum LaunchError: Error, Sendable, Equatable {
        case wineNotConfigured
        case executableNotFound(URL)
    }

    // MARK: - Pure plan builder

    public static func makePlan(
        app: SteamApp,
        config: GameConfig,
        backend: BackendConfig,
        gameExe: URL,
        prefix: URL,
        logURL: URL
    ) throws -> LaunchPlan {
        guard let wine = backend.wineBinary(for: config.backend) else {
            throw LaunchError.wineNotConfigured
        }

        var environment = config.envFlags.environment(for: config.backend)
        // Layer the base wine env (WINEDEBUG, DYLD bundled deps) under the user's flags, then force the
        // shared Steam-bottle WINEPREFIX (so the game is co-resident with the Steam client), regardless of
        // any user override.
        for (key, value) in Silo.wineEnvironment(prefix: prefix, wine: wine) where environment[key] == nil {
            environment[key] = value
        }
        environment["WINEPREFIX"] = prefix.path
        // The game shares ONE wineserver with the co-resident Steam client — and Wine starts a SEPARATE
        // wineserver per (prefix, sync-mode). Steam runs with msync (SteamBottle.steamEnvironment), so force
        // the game to msync too: an esync/none per-game override would split the wineserver and silently
        // break Steamworks IPC (the exact failure the shared bottle exists to avoid).
        environment["WINEMSYNC"] = "1"
        environment["WINEESYNC"] = nil

        switch config.backend {
        case .gptk:
            // Activate Apple's GPTK/D3DMetal: load GPTK's builtin d3d modules (via WINEDLLPATH) and let
            // them resolve D3DMetal.framework + libd3dshared.dylib from GPTK's lib/external on the DYLD
            // fallback paths (the same mechanism the bundled-deps fix uses for freetype).
            if let external = backend.gptkExternalDirPath {
                environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(external.path):\(wine.siloDyldFallback)"
                environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = external.path
            }
            if let dllDir = backend.gptkWineDLLDirPath {
                environment["WINEDLLPATH"] = [dllDir.path, environment["WINEDLLPATH"]]
                    .compactMap { $0 }.joined(separator: ":")
                environment["WINEDLLOVERRIDES"] = mergeOverride(
                    environment["WINEDLLOVERRIDES"],
                    "d3d9,d3d10,d3d10core,d3d10_1,d3d11,d3d12,d3d12core,dxgi=b"
                )
            }
        case .crossover:
            environment["WINEDLLOVERRIDES"] = mergeOverride(
                environment["WINEDLLOVERRIDES"], "d3d9,d3d10core,d3d11,dxgi=n"
            )
        }

        return LaunchPlan(
            executable: wine,
            arguments: [gameExe.path] + config.customArgs,
            environment: environment,
            currentDirectory: gameExe.deletingLastPathComponent(),
            logURL: logURL
        )
    }

    // MARK: - Full pipeline

    /// Launch a game **co-resident in a shared prefix** (the Steam bottle) under GPTK, where a running
    /// Steam client serves Steamworks. Links graphics into the shared prefix, writes `steam_appid.txt`,
    /// and spawns with `WINEPREFIX` forced to `prefix`. The prefix must already be provisioned (by
    /// `SteamBottle`). Returns the child PID.
    @discardableResult
    public func launchInBottle(
        app: SteamApp, config: GameConfig, backend: BackendConfig, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard backend.wineBinary(for: config.backend) != nil else { throw LaunchError.wineNotConfigured }
        let gameExe = try resolveExecutable(app: app, config: config)
        try linkGraphics(backend: config.backend, prefix: prefix, backendConfig: backend)
        try presenceInstaller.apply(strategy: config.presence, appID: app.appID, gameExe: gameExe)
        let plan = try Self.makePlan(
            app: app, config: config, backend: backend, gameExe: gameExe, prefix: prefix, logURL: logURL
        )
        return try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL
        )
    }

    public func isRunning(pid: Int32) -> Bool { runner.isRunning(pid: pid) }
    public func terminate(pid: Int32) { runner.terminate(pid: pid) }

    /// Stop a game running in the shared Steam bottle. SIGTERMs the launched process AND asks Wine to
    /// `taskkill /IM <game exe>` — the launched PID is only Wine's loader, so a game that re-execs or
    /// spawns children would otherwise be orphaned (SIGTERM hits the loader, not the wineserver-hosted
    /// process). We can't `wineserver -k` (it'd kill the co-resident Steam), but `/IM` targets only the
    /// game's own image name, so Steam (steam.exe / steamwebhelper.exe) is untouched. `WINEMSYNC=1` so the
    /// taskkill joins the SAME wineserver as the game (Steam + games all run msync). Best-effort.
    public func stopGame(pid: Int32, exeName: String?, prefix: URL, backend: BackendConfig) async {
        runner.terminate(pid: pid)
        guard let exeName, let wine = backend.wineBinary(for: .gptk) else { return }
        var env = Silo.wineEnvironment(prefix: prefix, wine: wine)
        env["WINEMSYNC"] = "1"
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: ["taskkill", "/F", "/IM", exeName],
            environment: env, currentDirectory: nil,
            logURL: prefix.appendingPathComponent("winetool.log"))
    }

    /// The basename of the executable a game would launch (for `taskkill`), or nil if unresolvable.
    public func resolvedExecutableName(app: SteamApp, config: GameConfig) -> String? {
        (try? resolveExecutable(app: app, config: config))?.lastPathComponent
    }

    /// Observe a launched game's exit **without polling** (kqueue). Retain the token to keep observing.
    public func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation {
        runner.observeExit(pid: pid, onExit: onExit)
    }

    /// Run a built-in wine tool (e.g. `winecfg`) against `prefix`, detached.
    public func runWineTool(_ tool: String, prefix: URL, backend: BackendConfig) async {
        guard let wine = backend.wineBinary(for: .gptk) else { return }
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: [tool],
            environment: Silo.wineEnvironment(prefix: prefix, wine: wine),
            currentDirectory: nil, logURL: prefix.appendingPathComponent("winetool.log"))
    }

    // MARK: - Helpers

    private func resolveExecutable(app: SteamApp, config: GameConfig) throws -> URL {
        let installURL = app.installURL
        if let relative = config.executableRelativePath {
            return installURL.appendingPathComponent(relative)
        }
        if let found = ExecutableResolver.firstExecutable(in: installURL) { return found }
        throw LaunchError.executableNotFound(installURL)
    }

    /// Inject graphics libraries only when a source dir is configured (some backends provide their own).
    private func linkGraphics(backend: GraphicsBackend, prefix: URL, backendConfig: BackendConfig) throws {
        let dir = backend == .gptk ? backendConfig.gptkLibDirPath : backendConfig.dxvkDLLDirPath
        guard dir != nil else { return }
        try linker.link(
            backend: backend, into: prefix,
            gptkLibDir: backendConfig.gptkLibDirPath, dxvkDLLDir: backendConfig.dxvkDLLDirPath
        )
    }

    private static func mergeOverride(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return existing + ";" + addition
    }
}
