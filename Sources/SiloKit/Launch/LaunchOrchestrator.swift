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

    /// Build the launch plan for ANY executable in the bottle (a Steam game's resolved exe or a manual
    /// game's `.exe`) — it's keyed off `gameExe` + `config`, not the app identity, so it serves both.
    public static func makePlan(
        config: GameConfig,
        backend: BackendConfig,
        gameExe: URL,
        prefix: URL,
        logURL: URL
    ) throws -> LaunchPlan {
        guard let wine = backend.wineBinaryPath else {
            throw LaunchError.wineNotConfigured
        }

        var environment = config.envFlags.environment()
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
        // break Steamworks IPC (the exact failure the shared bottle exists to avoid). This deliberately
        // overrides whatever EnvFlags.syncMode (and any WINEMSYNC/WINEESYNC in envFlags.extra) produced.
        environment["WINEMSYNC"] = "1"
        environment["WINEESYNC"] = nil

        // GPTK's D3DMetal d3d modules are overlaid into the wine runtime's own lib/wine tree
        // (GraphicsLinker.overlayGPTK), so wine loads them directly — no WINEDLLPATH needed. Point the
        // DYLD fallbacks at the runtime's lib/external (where the overlay placed libd3dshared.dylib +
        // D3DMetal.framework) and force the FULL set of GPTK-translated d3d modules to builtin so GPTK's
        // overlaid versions beat the native wined3d copies that the in-bottle Steam client's redist
        // (Steamworks Common Redistributables) drops into system32. The set must include d3d10core/d3d10_1/
        // d3d12core, not just d3d10/11/12/dxgi — a native `d3d10core` etc. would otherwise pull wined3d into
        // the device-creation path. d3d9 (wined3d, intentional) and d3dcompiler_* (a helper, not a renderer
        // — keep the redist's native one) are deliberately left untouched.
        if backend.gptkLibDirPath != nil {
            let external = wine.wineRuntimeExternalDir
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(external.path):\(wine.siloDyldFallback)"
            environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = external.path
            environment["WINEDLLOVERRIDES"] = mergeOverride(
                environment["WINEDLLOVERRIDES"], "d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
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
        guard backend.wineBinaryPath != nil else { throw LaunchError.wineNotConfigured }
        let gameExe = try resolveExecutable(app: app, config: config)
        try linkGraphics(backendConfig: backend)
        try presenceInstaller.apply(strategy: config.presence, appID: app.appID, gameExe: gameExe)
        let plan = try Self.makePlan(
            config: config, backend: backend, gameExe: gameExe, prefix: prefix, logURL: logURL
        )
        return try await spawn(plan)
    }

    // MARK: - Manual (non-Steam) games

    /// Launch a user-added non-Steam game in the bottle prefix under GPTK. No Steam presence (these don't
    /// use Steamworks) and no Steam client requirement — just wine + the absolute `.exe` path. Returns PID.
    @discardableResult
    public func launchManualGame(
        _ game: ManualGame, backend: BackendConfig, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard backend.wineBinaryPath != nil else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: game.executablePath.path) else {
            throw LaunchError.executableNotFound(game.executablePath)
        }
        try linkGraphics(backendConfig: backend)
        let config = GameConfig(appID: 0, envFlags: game.envFlags, presence: .none, customArgs: game.customArgs)
        let plan = try Self.makePlan(
            config: config, backend: backend, gameExe: game.executablePath, prefix: prefix, logURL: logURL)
        return try await spawn(plan)
    }

    /// Run an arbitrary installer `.exe` in the bottle prefix (detached, so the user drives its GUI). It
    /// installs into the bottle's `drive_c`; the user then points the game at the installed executable.
    @discardableResult
    public func runInstaller(
        exe: URL, backend: BackendConfig, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard backend.wineBinaryPath != nil else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw LaunchError.executableNotFound(exe)
        }
        try linkGraphics(backendConfig: backend)
        let plan = try Self.makePlan(
            config: GameConfig(appID: 0, presence: .none), backend: backend,
            gameExe: exe, prefix: prefix, logURL: logURL)
        return try await spawn(plan)
    }

    private func spawn(_ plan: LaunchPlan) async throws -> Int32 {
        try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL)
    }

    public func isRunning(pid: Int32) -> Bool { runner.isRunning(pid: pid) }

    /// Stop a game running in the shared Steam bottle. SIGTERMs the launched process AND asks Wine to
    /// `taskkill /IM <game exe>` — the launched PID is only Wine's loader, so a game that re-execs or
    /// spawns children would otherwise be orphaned (SIGTERM hits the loader, not the wineserver-hosted
    /// process). We can't `wineserver -k` (it'd kill the co-resident Steam), but `/IM` targets only the
    /// game's own image name, so Steam (steam.exe / steamwebhelper.exe) is untouched. `WINEMSYNC=1` so the
    /// taskkill joins the SAME wineserver as the game (Steam + games all run msync). Best-effort.
    public func stopGame(pid: Int32, exeName: String?, prefix: URL, backend: BackendConfig) async {
        runner.terminate(pid: pid)
        guard let exeName, let wine = backend.wineBinaryPath else { return }
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
        guard let wine = backend.wineBinaryPath else { return }
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: [tool],
            environment: Silo.wineEnvironment(prefix: prefix, wine: wine),
            currentDirectory: nil, logURL: prefix.appendingPathComponent("winetool.log"))
    }

    // MARK: - Helpers

    private func resolveExecutable(app: SteamApp, config: GameConfig) throws -> URL {
        let installURL = app.installURL
        if let relative = config.executableRelativePath {
            // A user-entered relative exe must stay inside the install dir — reject a path that climbs out.
            guard !relative.split(separator: "/").contains("..") else {
                throw LaunchError.executableNotFound(installURL)
            }
            return installURL.appendingPathComponent(relative)
        }
        if let found = ExecutableResolver.firstExecutable(in: installURL) { return found }
        throw LaunchError.executableNotFound(installURL)
    }

    /// Wire up GPTK's graphics translation before launch: overlay D3DMetal into the wine RUNTIME
    /// (idempotent, shared by every co-resident game). Skipped when unconfigured — the game then falls
    /// back to wine's own wined3d.
    private func linkGraphics(backendConfig: BackendConfig) throws {
        guard let wine = backendConfig.wineBinaryPath,
              let gptkLibDir = backendConfig.gptkLibDirPath else { return }
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
    }

    private static func mergeOverride(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return existing + ";" + addition
    }
}
