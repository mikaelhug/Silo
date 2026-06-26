import Foundation

/// User-tunable environment toggles applied when launching a game.
public struct EnvFlags: Codable, Sendable, Hashable {
    /// `WINEESYNC` — eventfd-based synchronization.
    public var esync: Bool
    /// `WINEMSYNC` — mach-port-based synchronization (Apple Silicon).
    public var msync: Bool
    /// `MTL_HUD_ENABLED` — Metal performance HUD overlay.
    public var metalHUD: Bool
    /// `DXVK_HUD` value (e.g. `"fps,memory"`); applied only with the CrossOver/DXVK backend. `nil` = off.
    public var dxvkHUD: String?
    /// Free-form extra environment variables (override the above; an escape hatch).
    public var extra: [String: String]

    public init(
        esync: Bool = true,
        msync: Bool = false,
        metalHUD: Bool = false,
        dxvkHUD: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.esync = esync
        self.msync = msync
        self.metalHUD = metalHUD
        self.dxvkHUD = dxvkHUD
        self.extra = extra
    }

    /// Environment variables contributed by these flags for the given backend.
    /// `extra` is merged last so it can override anything.
    public func environment(for backend: GraphicsBackend) -> [String: String] {
        var env: [String: String] = [
            "WINEESYNC": esync ? "1" : "0",
            "WINEMSYNC": msync ? "1" : "0",
        ]
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if let dxvkHUD, backend == .crossover { env["DXVK_HUD"] = dxvkHUD }
        for (key, value) in extra { env[key] = value }
        return env
    }
}
