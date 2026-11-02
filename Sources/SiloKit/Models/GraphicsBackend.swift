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
    /// DXVK — D3D9/10/11 → Vulkan, run on the runtime's bundled MoltenVK (Vulkan → Metal). The only backend
    /// that translates **DirectX 9** (GPTK and DXMT are D3D10/11+ only), and a mature compatibility net for
    /// the D3D10/11 titles the two Metal backends can't drive. Built stock from upstream (no patches) and run
    /// as **native** DLLs: its PE d3d modules (incl. DXVK's own `dxgi`) are seeded into the game prefix's
    /// `system32`/`syswow64` and overridden `=n`, so DXVK runs on the **base runtime** with nothing overlaid
    /// into `lib/wine` and no clone. It rides wine's own `winevulkan`, reaching the base runtime's bundled
    /// `libMoltenVK.dylib` — selected by dyld NAME lookup (its dir leads `DYLD_FALLBACK_LIBRARY_PATH`; an
    /// absolute `CX_LIBVULKAN` is ignored, verified on-device). (CrossOver ships DXVK as a builtin and reuses
    /// wine's dxgi — CX patches Silo deliberately avoids.)
    case dxvk

    public var id: String { rawValue }

    /// Full name for settings/menus.
    public var displayName: String {
        switch self {
        case .gptk: "GPTK / D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK / Vulkan"
        }
    }

    /// Compact label for a library badge/chip.
    public var badge: String {
        switch self {
        case .gptk: "GPTK"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        }
    }

    /// One-line guidance shown next to the picker.
    public var recommendedFor: String {
        switch self {
        case .gptk: "Modern DirectX 11 / 12 games"
        case .dxmt: "Older or problem DirectX 10 / 11 games"
        case .dxvk: "DirectX 9 games, and titles the Metal backends can't run"
        }
    }

    /// The `WINEDLLOVERRIDES` clause forcing this backend's translated Direct3D modules to **builtin**, so
    /// the runtime's overlaid versions beat any native wined3d redist copies the in-bottle Steam client
    /// drops into `system32`. Each backend's runtime carries exactly these modules as builtin, so the
    /// override deterministically resolves to the intended layer.
    /// **Every set explicitly names `d3d9` too.** DXVK seeds NATIVE d3d dlls into the SHARED Steam prefix and
    /// never removes them, so after one DXVK launch those files are present for every co-resident game. Any
    /// name a backend leaves unspecified would be resolved by wine's default load order rather than by Silo —
    /// and DXVK's native `d3d9` loading under a GPTK/DXMT launch would run against the wine runtime's STOCK
    /// MoltenVK (DXVK's own is only put on the DYLD path for a `.dxvk` launch), which cannot create a device.
    /// Forcing `=b` here means those games get wine's own builtin d3d9 → wined3d, which is the correct answer.
    /// **The same coherence rule now covers `nvapi64`/`nvngx`**, which GPTK seeds into the shared prefix
    /// (`GraphicsLinker.installGPTKPrefixLoaders`) and likewise never removes: GPTK claims them `=b` to load
    /// its own MetalFX/NGX shim, and DXMT/DXVK **disable** them outright (`=`) rather than leave wine's
    /// default load order to pick up a D3DMetal-backed native under a non-GPTK launch. Disabled is the honest
    /// answer there — neither backend has an NGX provider, so a game correctly concludes there is no NVIDIA
    /// adapter instead of half-binding one.
    /// - GPTK: the full D3DMetal set incl. d3d12 (GPTK covers DX12), plus its NVIDIA shims `nvapi64`/`nvngx`
    ///   (the latter only exists once `GraphicsLinker.activateNVNGX` has aliased GPTK's inert
    ///   `nvngx-on-metalfx`). `d3dcompiler_*` left native.
    /// - DXMT: `d3d10core`/`d3d11`/`dxgi` + `winemetal` (its Metal bridge). D3D10/11 only — no d3d12/d3d9.
    /// - DXVK: `d3d9`/`d3d10core`/`d3d11`/`dxgi` forced **native** (`=n`) — stock upstream DXVK is a native DLL
    ///   set seeded into the prefix, not a wine builtin, so `=n` is what loads it. **Includes `dxgi`** — upstream
    ///   DXVK's d3d11 is coupled to DXVK's own dxgi (setup_dxvk installs both; only CrossOver's *patched* build
    ///   reuses wine's builtin dxgi). **No `winemetal`** — DXVK reaches Metal through `winevulkan` → MoltenVK.
    public var dllOverrides: String {
        switch self {
        case .gptk: "d3d9,d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi,nvapi64,nvngx=b"
        case .dxmt: "d3d9,d3d10,d3d10_1,d3d10core,d3d11,dxgi,winemetal=b;nvapi64,nvngx="
        case .dxvk: "d3d9,d3d10core,d3d11,dxgi=n;nvapi64,nvngx="
        }
    }

    /// Whether the backend can create a **Direct3D 10 / 10.1** device. GPTK cannot: D3DMetal's
    /// `d3d10.dll` `D3D10CreateDevice` and `dxgi.dll` `DXGID3D10CreateDevice` are `return E_FAIL` stubs
    /// (disassembled from GPTK 4.0b2), and wine's `d3d10_1`/`d3d10core` reach their device through the loaded
    /// `dxgi` — so under GPTK every D3D10 path, Direct2D's hardware path included, fails with `0x80004005`.
    /// The `d3d10*` names stay in GPTK's `=b` set anyway: that is the shared-prefix coherence rule (keep
    /// DXVK's seeded natives out), not a claim D3DMetal translates them. DXMT and DXVK both implement D3D10.
    /// Drives `BackendChooser` (a D3D10-only game never goes to GPTK) and `ProcessRouting` (a D3D10 helper
    /// process inside a GPTK launch is routed to DXVK).
    public var supportsD3D10: Bool {
        switch self {
        case .gptk: false
        case .dxmt, .dxvk: true
        }
    }

    /// Whether the backend ships a framework/dylib in the runtime's `lib/external` that dyld must locate at
    /// launch (so `makePlan` prepends it to `DYLD_FALLBACK_*`). GPTK's `D3DMetal.framework` + `libd3dshared`
    /// live there; DXMT's `winemetal.so` links the system `Metal.framework`, so it needs nothing extra; DXVK
    /// gets its MoltenVK via the DYLD path `makePlan` sets from its own runtime dir — so it needs nothing
    /// from `lib/external` either.
    public var overlaysExternalFramework: Bool {
        switch self {
        case .gptk: true
        case .dxmt: false
        case .dxvk: false
        }
    }
}

/// A per-game backend **preference** (what the user picks), distinct from `GraphicsBackend` (the concrete
/// layer a launch resolves to). A game persists a *choice*; `BackendChooser` turns `.auto` into a concrete
/// backend from the game binary + install state at launch time.
public enum GraphicsChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Let Silo pick per launch (see `BackendChooser`): 32-bit → DXMT (GPTK is 64-bit-only), else GPTK, with
    /// an automatic switch to DXMT if GPTK can't drive the game.
    case auto
    case gptk
    case dxmt
    case dxvk

    public var id: String { rawValue }

    /// The explicit backend this choice pins, or nil for `.auto`.
    public var explicitBackend: GraphicsBackend? {
        switch self {
        case .auto: nil
        case .gptk: .gptk
        case .dxmt: .dxmt
        case .dxvk: .dxvk
        }
    }

    /// Full name for the settings picker.
    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .gptk: GraphicsBackend.gptk.displayName
        case .dxmt: GraphicsBackend.dxmt.displayName
        case .dxvk: GraphicsBackend.dxvk.displayName
        }
    }

    /// Compact label for a library badge/chip (Steam and manual cards both show the per-game choice).
    public var badge: String {
        switch self {
        case .auto: "Auto"
        case .gptk: GraphicsBackend.gptk.badge
        case .dxmt: GraphicsBackend.dxmt.badge
        case .dxvk: GraphicsBackend.dxvk.badge
        }
    }

    /// One-line guidance shown next to the picker.
    public var recommendedFor: String {
        switch self {
        case .auto: "Recommended — Silo picks the backend per game"
        case .gptk: GraphicsBackend.gptk.recommendedFor
        case .dxmt: GraphicsBackend.dxmt.recommendedFor
        case .dxvk: GraphicsBackend.dxvk.recommendedFor
        }
    }
}
