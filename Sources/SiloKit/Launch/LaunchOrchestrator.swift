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
        /// A 32-bit (i386) game was launched under GPTK, which is 64-bit-only (Apple ships no 32-bit
        /// D3DMetal) — it could only fall back to wined3d and fail. The caller steers the user to DXMT.
        case unsupported32BitOnGPTK(URL)
    }

    /// GPTK / D3DMetal is 64-bit-only, so a 32-bit game under it can only fall back to wined3d and fail.
    /// Refuse it up front (the caller surfaces an honest "use DXMT" message) rather than launching into a
    /// guaranteed graphics-init failure. Fails **open**: only a CONFIRMED i386 PE is refused — an
    /// unreadable/unknown executable is allowed through. DXMT (32-bit-capable) is never refused here.
    private func check32BitSupported(_ exe: URL, graphics: GraphicsBackend) throws {
        if graphics == .gptk, WindowsExecutable.is32Bit(exe) {
            throw LaunchError.unsupported32BitOnGPTK(exe)
        }
    }

    // MARK: - Pure plan builder

    /// Build the launch plan for ANY executable in the bottle (a Steam game's resolved exe or a manual
    /// game's `.exe`) — it's keyed off `gameExe` + `config`, not the app identity, so it serves both.
    /// - Parameter wine: the resolved launch binary — the per-backend variant runtime `BottleResolver`
    ///   hands back (the DXMT clone, or the base for GPTK). Defaults to `backend.wineBinaryPath` when a
    ///   caller has no variant to inject, so `backend` still gates the graphics overrides via `libDir(for:)`.
    public static func makePlan(
        config: GameConfig,
        backend: BackendConfig,
        graphics: GraphicsBackend = .gptk,
        wine: URL? = nil,
        gameExe: URL,
        prefix: URL,
        logURL: URL
    ) throws -> LaunchPlan {
        guard let wine = wine ?? backend.wineBinaryPath else {
            throw LaunchError.wineNotConfigured
        }

        var environment = config.envFlags.environment(graphics: graphics)
        // Layer the base wine env (WINEDEBUG, DYLD bundled deps) under the user's flags, then force the
        // shared Steam-bottle WINEPREFIX (so the game is co-resident with the Steam client), regardless of
        // any user override.
        for (key, value) in Silo.wineEnvironment(prefix: prefix, wine: wine) where environment[key] == nil {
            environment[key] = value
        }
        environment["WINEPREFIX"] = prefix.path
        // The game shares ONE wineserver with the co-resident Steam client (see `Silo.enforceMsync`).
        // This deliberately overrides whatever EnvFlags.syncMode (and any WINEMSYNC/WINEESYNC in
        // envFlags.extra) produced — an esync/none per-game override would split the wineserver and
        // silently break Steamworks IPC, the exact failure the shared bottle exists to avoid.
        Silo.enforceMsync(&environment)

        // The active backend's translated d3d modules are overlaid into the wine runtime's own lib/wine
        // tree (GraphicsLinker.overlayGPTK / overlayDXMT), so wine loads them directly — no WINEDLLPATH.
        // Force exactly that backend's module set to builtin (`GraphicsBackend.dllOverrides`) so the
        // overlaid versions beat the native wined3d copies the in-bottle Steam client's redist (Steamworks
        // Common Redistributables) drops into system32. Each backend's runtime carries only its own builtin
        // d3d set, so the override resolves deterministically to that one layer. GPTK additionally ships
        // D3DMetal.framework + libd3dshared in the runtime's lib/external, which dyld must find; DXMT's
        // winemetal.so links the system Metal.framework, so it needs no extra DYLD path. Gated on the
        // backend being configured — an unconfigured backend means the game falls back to wine's wined3d.
        if backend.libDir(for: graphics) != nil {
            if graphics.overlaysExternalFramework {
                let external = wine.wineRuntimeExternalDir
                environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(external.path):\(wine.siloDyldFallback)"
                environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = external.path
            }
            environment["WINEDLLOVERRIDES"] = mergeOverride(
                environment["WINEDLLOVERRIDES"], graphics.dllOverrides)
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
        app: SteamApp, config: GameConfig, backend: BackendConfig,
        graphics: GraphicsBackend = .gptk, wine: URL? = nil, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard let launchWine = wine ?? backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        let gameExe = try resolveExecutable(app: app, config: config)
        try check32BitSupported(gameExe, graphics: graphics)
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: launchWine, prefix: prefix)
        try presenceInstaller.apply(strategy: config.presence, appID: app.appID, gameExe: gameExe)
        let plan = try Self.makePlan(
            config: config, backend: backend, graphics: graphics, wine: launchWine,
            gameExe: gameExe, prefix: prefix, logURL: logURL
        )
        return try await spawn(plan)
    }

    // MARK: - Manual (non-Steam) games

    /// Launch a user-added non-Steam game in the bottle prefix under GPTK. No Steam presence (these don't
    /// use Steamworks) and no Steam client requirement — just wine + the absolute `.exe` path. Returns PID.
    @discardableResult
    public func launchManualGame(
        _ game: ManualGame, backend: BackendConfig,
        graphics: GraphicsBackend = .gptk, wine: URL? = nil, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard let launchWine = wine ?? backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: game.executablePath.path) else {
            throw LaunchError.executableNotFound(game.executablePath)
        }
        try check32BitSupported(game.executablePath, graphics: graphics)
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: launchWine, prefix: prefix)
        let plan = try Self.makePlan(
            config: game.gameConfig, backend: backend, graphics: graphics, wine: launchWine,
            gameExe: game.executablePath, prefix: prefix, logURL: logURL)
        return try await spawn(plan)
    }

    /// Run an arbitrary installer `.exe` in the bottle prefix (detached, so the user drives its GUI). It
    /// installs into the bottle's `drive_c`; the user then points the game at the installed executable.
    @discardableResult
    public func runInstaller(
        exe: URL, backend: BackendConfig, graphics: GraphicsBackend = .gptk, prefix: URL, logURL: URL
    ) async throws -> Int32 {
        guard let wine = backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw LaunchError.executableNotFound(exe)
        }
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: wine, prefix: prefix)
        let plan = try Self.makePlan(
            config: GameConfig(appID: 0, presence: .none), backend: backend, graphics: graphics,
            wine: wine, gameExe: exe, prefix: prefix, logURL: logURL)
        return try await spawn(plan)
    }

    /// Prepare a bottle's graphics WITHOUT launching: overlay the backend's translated d3d into the runtime
    /// and (for DXMT) seed `winemetal.dll` into the game `prefix`. Used by the Desktop-shortcut builder,
    /// whose standalone `.app` execs wine directly with no launch pipeline — so the prefix must already
    /// carry the DXMT loader (a normal first launch seeds it via `launch…` → `linkGraphics`; a shortcut made
    /// before any launch would otherwise leave the prefix without it → DXMT falls back to wined3d and fails).
    /// No-op for GPTK (needs no prefix loader) and for an unconfigured backend.
    public func prepareGraphics(
        backendConfig: BackendConfig, graphics: GraphicsBackend, wine: URL, prefix: URL
    ) throws {
        try linkGraphics(backendConfig: backendConfig, graphics: graphics, wine: wine, prefix: prefix)
    }

    private func spawn(_ plan: LaunchPlan) async throws -> Int32 {
        writeLogHeader(for: plan)
        return try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL)
    }

    /// Truncate the log and write the resolved launch context at the top (a fresh log per launch); the
    /// child's stdout/stderr then appends after it (`spawnDetached` seeks to end). Best-effort — a failed
    /// header write never blocks the launch.
    private func writeLogHeader(for plan: LaunchPlan) {
        try? FileManager.default.createDirectory(
            at: plan.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(plan.logHeader(at: Date()).utf8).write(to: plan.logURL)
    }

    public func isRunning(pid: Int32) -> Bool { runner.isRunning(pid: pid) }

    /// SIGTERM a launched process (synchronous, best-effort). Used to stop games at app quit, where there's
    /// no time for the async `taskkill` cleanup `stopGame` does. Wine translates SIGTERM into terminating
    /// the hosted Windows process, so this stops a Silo-launched game; the co-resident Steam client (a
    /// different PID we never SIGTERM) is untouched.
    public func terminate(pid: Int32) { runner.terminate(pid: pid) }

    /// Stop a game running in the shared Steam bottle. SIGTERMs the launched process AND asks Wine to
    /// `taskkill /IM <game exe>` — the launched PID is only Wine's loader, so a game that re-execs or
    /// spawns children would otherwise be orphaned (SIGTERM hits the loader, not the wineserver-hosted
    /// process). We can't `wineserver -k` (it'd kill the co-resident Steam), but `/IM` targets only the
    /// game's own image name, so Steam (steam.exe / steamwebhelper.exe) is untouched. `WINEMSYNC=1` so the
    /// taskkill joins the SAME wineserver as the game (Steam + games all run msync). Best-effort.
    public func stopGame(pid: Int32, exeName: String?, prefix: URL, backend: BackendConfig) async {
        runner.terminate(pid: pid)
        guard let exeName, let wine = backend.wineBinaryPath else { return }
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: ["taskkill", "/F", "/IM", exeName],
            environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine), currentDirectory: nil,
            logURL: prefix.appendingPathComponent("winetool.log"))
    }

    /// The basename of the executable a game would launch (for `taskkill`), or nil if unresolvable.
    public func resolvedExecutableName(app: SteamApp, config: GameConfig) -> String? {
        (try? resolveExecutable(app: app, config: config))?.lastPathComponent
    }

    /// Whether launching `app` under `graphics` is a dead end because it's a 32-bit game on GPTK (which is
    /// 64-bit-only). Lets the UI refuse EARLY — before bringing the Steam client up — for a game that could
    /// never render under GPTK. Fails open (unresolvable exe → false).
    public func isBlocked32BitOnGPTK(app: SteamApp, config: GameConfig, graphics: GraphicsBackend) -> Bool {
        guard graphics == .gptk, let exe = try? resolveExecutable(app: app, config: config) else { return false }
        return WindowsExecutable.is32Bit(exe)
    }

    /// Observe a launched game's exit **without polling** (kqueue). Retain the token to keep observing.
    public func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation {
        runner.observeExit(pid: pid, onExit: onExit)
    }

    /// Run a built-in wine tool (e.g. `winecfg`) against `prefix`, detached. Msync env so the tool shares
    /// the bottle's wineserver instead of forking a second one on the same prefix.
    public func runWineTool(_ tool: String, prefix: URL, backend: BackendConfig) async {
        guard let wine = backend.wineBinaryPath else { return }
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: [tool],
            environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine), currentDirectory: nil,
            logURL: prefix.appendingPathComponent("winetool.log"))
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

    /// Wire up the selected backend's graphics translation before launch: overlay D3DMetal (GPTK) or DXMT
    /// into the wine RUNTIME (idempotent, shared by every co-resident game in that backend's bottle). For
    /// DXMT it ALSO seeds `winemetal.dll` into the game `prefix` (see `installDXMTPrefixLoaders` — wine can't
    /// load the winemetal builtin otherwise). Skipped when that backend is unconfigured — the game then falls
    /// back to wine's own wined3d.
    private func linkGraphics(
        backendConfig: BackendConfig, graphics: GraphicsBackend, wine: URL, prefix: URL
    ) throws {
        guard let libDir = backendConfig.libDir(for: graphics) else { return }
        switch graphics {
        case .gptk: try linker.overlayGPTK(wineBinary: wine, gptkLibDir: libDir)
        case .dxmt:
            try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: libDir)
            try linker.installDXMTPrefixLoaders(prefix: prefix, dxmtLibDir: libDir)
        }
    }

    private static func mergeOverride(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return existing + ";" + addition
    }
}
