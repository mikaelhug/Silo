import Foundation

/// The Direct3D → Metal translation layer a game runs under.
///
/// GPTK and DXMT both overlay a **builtin** `d3d11`/`dxgi` into a Wine runtime's `lib/wine` tree, so they
/// can never co-exist in one runtime (a prefix has one wineserver/runtime). The backend therefore selects
/// a deterministic **(runtime, bottle, DLL-override)** triple — see `BottleResolver` — and the
/// `WINEDLLOVERRIDES` it emits can only ever resolve to the one translation layer that runtime carries,
/// never the other backend and never native wined3d.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple's Game Porting Toolkit / D3DMetal — D3D10/11/12 → Metal. Silo's default path.
    case gptk
    /// 3Shain's DXMT — D3D10/11 → Metal directly (no Vulkan). The fallback for titles D3DMetal can't run.
    case dxmt

    public var id: String { rawValue }

    /// Full name for settings/menus.
    public var displayName: String {
        switch self {
        case .gptk: "GPTK / D3DMetal"
        case .dxmt: "DXMT"
        }
    }

    /// Compact label for a library badge/chip.
    public var badge: String {
        switch self {
        case .gptk: "GPTK"
        case .dxmt: "DXMT"
        }
    }

    /// One-line guidance shown next to the picker.
    public var recommendedFor: String {
        switch self {
        case .gptk: "Modern DirectX 11 / 12 games"
        case .dxmt: "Older or problem DirectX 10 / 11 games"
        }
    }

    /// The `WINEDLLOVERRIDES` clause forcing this backend's translated Direct3D modules to **builtin**, so
    /// the runtime's overlaid versions beat any native wined3d redist copies the in-bottle Steam client
    /// drops into `system32`. Each backend's runtime carries exactly these modules as builtin, so the
    /// override deterministically resolves to the intended layer.
    /// - GPTK: the full D3DMetal set incl. d3d12 (GPTK covers DX12). `d3d9`/`d3dcompiler_*` left native.
    /// - DXMT: `d3d10core`/`d3d11`/`dxgi` + `winemetal` (its Metal bridge). D3D10/11 only — no d3d12/d3d9.
    public var dllOverrides: String {
        switch self {
        case .gptk: "d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
        case .dxmt: "d3d10core,d3d11,dxgi,winemetal=b"
        }
    }

    /// Whether the backend ships a framework/dylib in the runtime's `lib/external` that dyld must locate at
    /// launch (so `makePlan` prepends it to `DYLD_FALLBACK_*`). GPTK's `D3DMetal.framework` + `libd3dshared`
    /// live there; DXMT's `winemetal.so` links the system `Metal.framework`, so it needs nothing extra.
    public var overlaysExternalFramework: Bool {
        switch self {
        case .gptk: true
        case .dxmt: false
        }
    }
}
