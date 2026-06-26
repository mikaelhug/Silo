import Foundation

/// Builds launch plans and runs the full launch pipeline for a game.
///
/// `makePlan` is a **pure** function (exhaustively tested); `launch` is the thin async wrapper that
/// provisions the prefix, injects graphics libraries, and spawns the detached game process.
public struct LaunchOrchestrator: Sendable {
    private let runner: ProcessRunning
    private let provisioner: PrefixProvisioner
    private let linker: GraphicsLinker
    private let logStore: GameLogStore
    private let presenceInstaller: SteamPresenceInstaller

    public init(
        runner: ProcessRunning,
        provisioner: PrefixProvisioner,
        linker: GraphicsLinker,
        logStore: GameLogStore,
        presenceInstaller: SteamPresenceInstaller = SteamPresenceInstaller()
    ) {
        self.runner = runner
        self.provisioner = provisioner
        self.linker = linker
        self.logStore = logStore
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
        environment["WINEPREFIX"] = prefix.path
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = wine.siloDyldFallback   // bundled deps (freetype, …)
        if environment["WINEDEBUG"] == nil { environment["WINEDEBUG"] = "-all" }

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

    /// Provision → link graphics → prepare log → spawn detached. Returns the child PID.
    @discardableResult
    public func launch(app: SteamApp, config: GameConfig, backend: BackendConfig) async throws -> Int32 {
        guard let wine = backend.wineBinary(for: config.backend) else {
            throw LaunchError.wineNotConfigured
        }
        let gameExe = try resolveExecutable(app: app, config: config)

        let prefix = try await provisioner.provision(appID: app.appID, wineBinary: wine)
        try linkGraphics(backend: config.backend, prefix: prefix, backendConfig: backend)
        try presenceInstaller.apply(
            strategy: config.presence, appID: app.appID, gameExe: gameExe,
            stubSource: config.steamStubSourcePath, masterSteamRoot: backend.steamRoot, prefix: prefix)
        let logURL = try await logStore.prepare(appID: app.appID)

        let plan = try Self.makePlan(
            app: app, config: config, backend: backend, gameExe: gameExe, prefix: prefix, logURL: logURL
        )
        return try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL
        )
    }

    public func isRunning(pid: Int32) -> Bool { runner.isRunning(pid: pid) }

    /// Run a built-in wine tool (e.g. `winecfg`, `regedit`) against a game's prefix, detached.
    public func runWineTool(_ tool: String, appID: Int, backend: BackendConfig) async {
        guard let wine = backend.wineBinary(for: .gptk) else { return }
        let prefix = provisioner.prefixURL(forAppID: appID)
        let log = (try? await logStore.prepare(appID: appID)) ?? logStore.logURL(forAppID: appID)
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: [tool],
            environment: ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all",
                          "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback],
            currentDirectory: nil, logURL: log)
    }

    /// Stop a game by killing every wine process in its isolated prefix (`wineserver -k`).
    public func stop(appID: Int, backend: BackendConfig) async {
        guard let wine = backend.wineBinary(for: .gptk) else { return }
        let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        let prefix = provisioner.prefixURL(forAppID: appID)
        _ = try? await runner.run(
            executable: wineserver, arguments: ["-k"],
            environment: ["WINEPREFIX": prefix.path], currentDirectory: nil)
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
