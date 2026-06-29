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

/// Per-game performance + environment tuning applied at launch. Defaults reflect the known-good GPTK
/// configuration for Apple Silicon (MSync + advertise-AVX).
public struct EnvFlags: Codable, Sendable, Hashable {
    /// Sync primitive (`WINEMSYNC`/`WINEESYNC`). Defaults to `.msync` on Apple Silicon.
    public var syncMode: SyncMode
    /// `ROSETTA_ADVERTISE_AVX=1` — make Rosetta advertise AVX so games that gate features on AVX run
    /// (the whole x86 Wine runs under Rosetta, so this applies to every backend). Default on.
    public var advertiseAVX: Bool
    /// `MTL_HUD_ENABLED=1` — Apple's Metal performance HUD (FPS / frame time overlay). The perf metric.
    public var metalHUD: Bool
    /// `D3DM_ENABLE_METALFX=1` — let D3DMetal use MetalFX upscaling where the game supports it (GPTK).
    public var metalFX: Bool
    /// `D3DM_SUPPORT_DXR=1` — expose DirectX Raytracing in D3DMetal's DX12 layer (GPTK; M3+).
    public var dxr: Bool
    /// Free-form extra environment variables — a config.json-only escape hatch (no UI). Merged last in
    /// `environment()`, so it overrides the flags above — EXCEPT the sync keys (`WINEMSYNC`/`WINEESYNC`),
    /// which `LaunchOrchestrator.makePlan` force-overrides afterward for shared-bottle co-residency.
    public var extra: [String: String]

    public init(
        syncMode: SyncMode = .msync,
        advertiseAVX: Bool = true,
        metalHUD: Bool = false,
        metalFX: Bool = false,
        dxr: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.syncMode = syncMode
        self.advertiseAVX = advertiseAVX
        self.metalHUD = metalHUD
        self.metalFX = metalFX
        self.dxr = dxr
        self.extra = extra
    }

    /// Environment variables contributed by these flags.
    /// `extra` is merged last so it can override anything.
    public func environment() -> [String: String] {
        var env: [String: String] = [:]
        switch syncMode {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }
        if advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }   // x86 Wine runs under Rosetta
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
        if dxr { env["D3DM_SUPPORT_DXR"] = "1" }
        for (key, value) in extra { env[key] = value }
        return env
    }

    // MARK: - Codable (migrates legacy esync/msync bools; tolerates missing perf fields)

    private enum CodingKeys: String, CodingKey {
        case syncMode, advertiseAVX, metalHUD, metalFX, dxr, extra
        case esync, msync   // legacy fields from configs written before the SyncMode enum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try c.decodeIfPresent(SyncMode.self, forKey: .syncMode) {
            syncMode = mode
        } else {
            let legacyMsync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? false
            let legacyEsync = try c.decodeIfPresent(Bool.self, forKey: .esync) ?? false
            syncMode = legacyMsync ? .msync : (legacyEsync ? .esync : .msync)
        }
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? true
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        metalFX = try c.decodeIfPresent(Bool.self, forKey: .metalFX) ?? false
        dxr = try c.decodeIfPresent(Bool.self, forKey: .dxr) ?? false
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(syncMode, forKey: .syncMode)
        try c.encode(advertiseAVX, forKey: .advertiseAVX)
        try c.encode(metalHUD, forKey: .metalHUD)
        try c.encode(metalFX, forKey: .metalFX)
        try c.encode(dxr, forKey: .dxr)
        try c.encode(extra, forKey: .extra)
    }
}
