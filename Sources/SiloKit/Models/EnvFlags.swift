import Foundation

/// Wine thread-synchronization primitive. Mutually exclusive — you pick one. **MSync** is the
/// Apple-Silicon default (maps to native Mach semaphores; lower CPU than ESync's emulated eventfd and
/// no file-descriptor limits — it's what modern macOS Wine wrappers default to).
public enum SyncMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case msync, esync, none

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .msync: "MSync (recommended)"
        case .esync: "ESync"
        case .none: "Off"
        }
    }
}

/// User-tunable environment toggles applied when launching a game.
public struct EnvFlags: Codable, Sendable, Hashable {
    /// Sync primitive (`WINEMSYNC`/`WINEESYNC`). Defaults to `.msync` on Apple Silicon.
    public var syncMode: SyncMode
    /// `MTL_HUD_ENABLED` — Metal performance HUD overlay.
    public var metalHUD: Bool
    /// `DXVK_HUD` value (e.g. `"fps,memory"`); applied only with the CrossOver/DXVK backend. `nil` = off.
    public var dxvkHUD: String?
    /// Free-form extra environment variables (override the above; an escape hatch).
    public var extra: [String: String]

    public init(
        syncMode: SyncMode = .msync,
        metalHUD: Bool = false,
        dxvkHUD: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.syncMode = syncMode
        self.metalHUD = metalHUD
        self.dxvkHUD = dxvkHUD
        self.extra = extra
    }

    /// Environment variables contributed by these flags for the given backend.
    /// `extra` is merged last so it can override anything.
    public func environment(for backend: GraphicsBackend) -> [String: String] {
        var env: [String: String] = [:]
        switch syncMode {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if let dxvkHUD, backend == .crossover { env["DXVK_HUD"] = dxvkHUD }
        for (key, value) in extra { env[key] = value }
        return env
    }

    // MARK: - Codable (migrates legacy esync/msync bools)

    private enum CodingKeys: String, CodingKey {
        case syncMode, metalHUD, dxvkHUD, extra
        case esync, msync   // legacy fields from configs written before the SyncMode enum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try c.decodeIfPresent(SyncMode.self, forKey: .syncMode) {
            syncMode = mode
        } else {
            // Old config: prefer msync if it was on, else esync, else the new msync default.
            let legacyMsync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? false
            let legacyEsync = try c.decodeIfPresent(Bool.self, forKey: .esync) ?? false
            syncMode = legacyMsync ? .msync : (legacyEsync ? .esync : .msync)
        }
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        dxvkHUD = try c.decodeIfPresent(String.self, forKey: .dxvkHUD)
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(syncMode, forKey: .syncMode)
        try c.encode(metalHUD, forKey: .metalHUD)
        try c.encodeIfPresent(dxvkHUD, forKey: .dxvkHUD)
        try c.encode(extra, forKey: .extra)
    }
}
