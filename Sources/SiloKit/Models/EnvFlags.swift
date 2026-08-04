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

/// Which renderer D3DMetal's **DirectX 12** path translates through. GPTK 4.0 beta 1 shipped the Metal 4
/// backend as opt-in (`D3DM_MTL4=1`); beta 2 makes it the default on macOS 27 and later, with
/// `D3DM_MTL4=0` as the way back to the Metal 3 backend. Which of those two Apple's default resolves to
/// therefore depends on BOTH the GPTK version and the OS — so `.auto` deliberately emits **nothing** and
/// lets D3DMetal decide. That keeps `makePlan` pure (no OS-version probe) and means a config written today
/// can't silently pin an old renderer once macOS 27 ships.
///
/// This is a *backend* selector, not a feature toggle (compare `metalFX`/`dxr`, which add a capability),
/// so it gets the Automatic-plus-members shape Silo already uses for `GraphicsChoice` and `SyncMode`.
public enum MetalBackendChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Emit no `D3DM_MTL4` — Apple's default for this GPTK + OS combination.
    case auto
    /// `D3DM_MTL4=1` — force the Metal 4 backend (the opt-in on macOS 26).
    case metal4
    /// `D3DM_MTL4=0` — force the Metal 3 backend. The first thing to try when a game regresses on a
    /// newer GPTK.
    case metal3

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .metal4: "Metal 4"
        case .metal3: "Metal 3 (compatibility)"
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
    /// MetalFX upscaling where the game supports it. The env var is backend-specific: `D3DM_ENABLE_METALFX`
    /// for GPTK/D3DMetal, `DXMT_METALFX_SPATIAL_SWAPCHAIN` for DXMT — see `environment(graphics:)`.
    public var metalFX: Bool
    /// `D3DM_SUPPORT_DXR=1` — expose DirectX Raytracing in D3DMetal's DX12 layer. GPTK only (DXMT is
    /// D3D10/11, no DX12), so it's emitted only for the GPTK backend.
    public var dxr: Bool
    /// Which renderer D3DMetal's DX12 path uses (`D3DM_MTL4`). GPTK only, and `.auto` (the default)
    /// emits nothing — see `MetalBackendChoice`.
    public var metalBackend: MetalBackendChoice
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
        metalBackend: MetalBackendChoice = .auto,
        extra: [String: String] = [:]
    ) {
        self.syncMode = syncMode
        self.advertiseAVX = advertiseAVX
        self.metalHUD = metalHUD
        self.metalFX = metalFX
        self.dxr = dxr
        self.metalBackend = metalBackend
        self.extra = extra
    }

    /// Environment variables contributed by these flags, for the game's graphics backend (the MetalFX /
    /// DXR vars differ between GPTK's D3DMetal and DXMT). `extra` is merged last so it can override anything.
    public func environment(graphics: GraphicsBackend = .gptk) -> [String: String] {
        var env: [String: String] = [:]
        switch syncMode {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }
        if advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }   // x86 Wine runs under Rosetta
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }             // Apple's Metal HUD — any Metal backend
        if metalFX {
            switch graphics {
            case .gptk: env["D3DM_ENABLE_METALFX"] = "1"
            case .dxmt: env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            case .dxvk: break   // DXVK renders through Vulkan/MoltenVK — no MetalFX upscaling hook to toggle
            }
        }
        if dxr, graphics == .gptk { env["D3DM_SUPPORT_DXR"] = "1" }   // DX12 raytracing — GPTK only
        if graphics == .gptk {
            // D3DMetal's DX12 renderer. `.auto` emits nothing so Apple's own default applies (Metal 3 on
            // macOS 26, Metal 4 on 27+ with GPTK 4.0b2) — the other backends have no Metal-4 concept.
            switch metalBackend {
            case .auto: break
            case .metal4: env["D3DM_MTL4"] = "1"
            case .metal3: env["D3DM_MTL4"] = "0"
            }
        }
        for (key, value) in extra { env[key] = value }
        return env
    }

    // MARK: - Codable (migrates legacy esync/msync bools; tolerates missing perf fields)

    private enum CodingKeys: String, CodingKey {
        case syncMode, advertiseAVX, metalHUD, metalFX, dxr, metalBackend, extra
        case esync, msync   // legacy fields from configs written before the SyncMode enum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Raw string, not the enum: an unknown sync mode written by a NEWER Silo must not throw here, or
        // the whole config document is discarded on downgrade (see GameConfig.init(from:)).
        if let mode = (try c.decodeIfPresent(String.self, forKey: .syncMode)).flatMap(SyncMode.init(rawValue:)) {
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
        // Decoded via the raw string so a value written by a NEWER Silo (or hand-edited junk) degrades to
        // `.auto` instead of throwing and wiping the whole document — same tolerance as `ManualGame.graphics`.
        metalBackend = (try c.decodeIfPresent(String.self, forKey: .metalBackend))
            .flatMap(MetalBackendChoice.init(rawValue:)) ?? .auto
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(syncMode, forKey: .syncMode)
        try c.encode(advertiseAVX, forKey: .advertiseAVX)
        try c.encode(metalHUD, forKey: .metalHUD)
        try c.encode(metalFX, forKey: .metalFX)
        try c.encode(dxr, forKey: .dxr)
        try c.encode(metalBackend, forKey: .metalBackend)
        try c.encode(extra, forKey: .extra)
    }
}
