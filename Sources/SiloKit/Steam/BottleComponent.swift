import Foundation

/// The component set Silo installs into the Steam bottle, in the fixed **install order**
/// (the `allCases` declaration order is the single source of truth for ordering). `SteamBottle` owns the
/// per-component predicate + install method (`isSatisfied`/`install`); the driver `provisionComponents`
/// walks these in order. Wine/DXMT runtime downloads, the Steam *download*, and `wineboot` are
/// orchestrator/VM-level pre-steps, not components.
public enum BottleComponent: String, CaseIterable, Sendable {
    case coreFonts        // Microsoft Core Fonts for the Web (first font user-guided EULA, rest silent)
    case sourceHanSans    // Adobe Source Han Sans — 4 CJK language packs (OFL, no prompt)
    case d3dcompiler47    // native d3dcompiler_47.dll, both ABIs (no prompt)
    case vcRedistX86      // Microsoft Visual C++ Redistributable x86 (user-guided license)
    case vcRedistX64      // …then x64 (user-guided license)
    case msync            // "Enable MSync" — no-op (WINEMSYNC=1 is a launch-time env var, always applied)
    case steamClient      // the Windows Steam client, user-guided (no /S)

    /// Human-readable name for status/progress narration.
    public var title: String {
        switch self {
        case .coreFonts:     "Core Fonts"
        case .sourceHanSans: "Asian Fonts"
        case .d3dcompiler47: "d3dcompiler_47"
        case .vcRedistX86:   "Visual C++ Runtime (x86)"
        case .vcRedistX64:   "Visual C++ Runtime (x64)"
        case .msync:         "MSync"
        case .steamClient:   "Steam"
        }
    }

    /// Whether installing this component shows a GUI the user must click through (a license/installer window).
    /// For `.coreFonts` only the FIRST font is interactive; the flag still drives the "accept the license"
    /// narration.
    public var isUserGuided: Bool {
        switch self {
        case .coreFonts, .vcRedistX86, .vcRedistX64, .steamClient: true
        case .sourceHanSans, .d3dcompiler47, .msync:               false
        }
    }
}
