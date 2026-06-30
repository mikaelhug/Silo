import Foundation

/// The resolved launch target for a game: which Wine prefix, which Wine runtime, and the graphics backend.
public struct LaunchContext: Sendable, Equatable {
    /// The Wine prefix the game runs in (a backend's shared Steam bottle, or a manual game's own bottle).
    public let prefix: URL
    /// The Wine binary to launch with — the backend's prepared (overlaid) runtime.
    public let wineBinary: URL
    /// The graphics backend this context runs under.
    public let graphics: GraphicsBackend

    public init(prefix: URL, wineBinary: URL, graphics: GraphicsBackend) {
        self.prefix = prefix
        self.wineBinary = wineBinary
        self.graphics = graphics
    }
}

/// The single deterministic mapping from a game + its backend to *where and how it runs* — its bottle
/// prefix and its prepared per-backend runtime. Every launch / provision / wine-tool path routes through
/// here instead of hard-coding `paths.steamBottle` or `backend.wineBinaryPath`, so a game can never run in
/// the wrong bottle or under the wrong runtime:
/// - A **Steam** game's backend IS its bottle — GPTK games in the GPTK Steam bottle, DXMT games in the
///   DXMT one (each an independent Steam install).
/// - A **manual** game runs in its own isolated bottle under its chosen backend.
public struct BottleResolver: Sendable {
    private let paths: AppPaths
    private let variants: RuntimeVariants

    public init(paths: AppPaths, variants: RuntimeVariants = RuntimeVariants()) {
        self.paths = paths
        self.variants = variants
    }

    public enum ResolveError: Error, Sendable, Equatable {
        case wineNotConfigured
        /// A secondary backend (DXMT) was requested but its runtime modules aren't installed.
        case backendNotConfigured(GraphicsBackend)
    }

    /// Resolve a Steam game's launch context: its prefix is `backend`'s shared Steam bottle and its runtime
    /// is that backend's prepared variant.
    public func steam(_ backend: GraphicsBackend, config: BackendConfig) throws -> LaunchContext {
        try context(backend: backend, prefix: paths.steamBottle(backend), config: config)
    }

    /// Resolve a manual game's launch context: its OWN isolated bottle under its chosen backend's variant.
    public func manual(_ game: ManualGame, config: BackendConfig) throws -> LaunchContext {
        try context(backend: game.backend, prefix: paths.manualBottle(game.id), config: config)
    }

    private func context(
        backend: GraphicsBackend, prefix: URL, config: BackendConfig
    ) throws -> LaunchContext {
        guard let baseWine = config.wineBinaryPath else { throw ResolveError.wineNotConfigured }
        if let libDir = config.libDir(for: backend) {
            // Prepare (overlay, and clone for a secondary backend) the runtime this backend launches with.
            let wine = try variants.prepare(backend: backend, baseWine: baseWine, libDir: libDir)
            return LaunchContext(prefix: prefix, wineBinary: wine, graphics: backend)
        }
        // Backend not configured: GPTK degrades to wine's own wined3d on the base runtime (the documented
        // baseline). A secondary backend has no such baseline, so refuse rather than silently mis-route it
        // onto the base (possibly GPTK-overlaid) runtime — that would be exactly the accidental either/or
        // the two-bottle design exists to prevent.
        guard backend == .gptk else { throw ResolveError.backendNotConfigured(backend) }
        return LaunchContext(prefix: prefix, wineBinary: baseWine, graphics: .gptk)
    }
}
