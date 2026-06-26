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

    public init(
        runner: ProcessRunning,
        provisioner: PrefixProvisioner,
        linker: GraphicsLinker,
        logStore: GameLogStore
    ) {
        self.runner = runner
        self.provisioner = provisioner
        self.linker = linker
        self.logStore = logStore
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
        if environment["WINEDEBUG"] == nil { environment["WINEDEBUG"] = "-all" }
        if config.backend == .crossover {
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
        let logURL = try await logStore.prepare(appID: app.appID)

        let plan = try Self.makePlan(
            app: app, config: config, backend: backend, gameExe: gameExe, prefix: prefix, logURL: logURL
        )
        return try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL
        )
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
