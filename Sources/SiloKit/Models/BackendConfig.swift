import Foundation

/// Global runtime configuration: where the wine/GPTK binaries live and the signed-in Steam account.
public struct BackendConfig: Codable, Sendable, Hashable {
    /// Primary wine binary used to launch games (GPTK build).
    public var wineBinaryPath: URL?
    /// Name of the default Wine install (managed in the Wine settings tab).
    public var wineRuntimeName: String?
    /// Directory containing GPTK / D3DMetal libraries, overlaid into the wine runtime's `lib/wine` tree
    /// by `GraphicsLinker.overlayGPTK`.
    public var gptkLibDirPath: URL?
    /// Name of the default GPTK install (managed in the GPTK settings tab).
    public var gptkRuntimeName: String?
    /// Directory containing DXMT's PE modules (`d3d11`/`dxgi`/`d3d10core`/`winemetal`), overlaid into the
    /// wine runtime's `lib/wine` tree by `GraphicsLinker.overlayDXMT`. The DXMT counterpart of `gptkLibDirPath`.
    public var dxmtLibDirPath: URL?
    /// Name of the default DXMT install (managed in the Runtimes settings).
    public var dxmtRuntimeName: String?
    /// macOS Retina/HiDPI mode ("High Resolution Mode") for the shared Steam bottle. Mirrors what Silo last
    /// wrote to the prefix; off is Wine's default. Drives a coupled PAIR of registry keys —
    /// `HKCU\Software\Wine\Mac Driver\RetinaMode` (crisp native rendering) plus its DPI companion
    /// `HKCU\Control Panel\Desktop\LogPixels` (192 so the UI isn't tiny) — see `WineTools.setRetinaMode`.
    public var retinaMode: Bool

    public init(
        wineBinaryPath: URL? = nil,
        wineRuntimeName: String? = nil,
        gptkLibDirPath: URL? = nil,
        gptkRuntimeName: String? = nil,
        dxmtLibDirPath: URL? = nil,
        dxmtRuntimeName: String? = nil,
        retinaMode: Bool = false
    ) {
        self.wineBinaryPath = wineBinaryPath
        self.wineRuntimeName = wineRuntimeName
        self.gptkLibDirPath = gptkLibDirPath
        self.gptkRuntimeName = gptkRuntimeName
        self.dxmtLibDirPath = dxmtLibDirPath
        self.dxmtRuntimeName = dxmtRuntimeName
        self.retinaMode = retinaMode
    }

    private enum CodingKeys: String, CodingKey {
        case wineBinaryPath, wineRuntimeName, gptkLibDirPath, gptkRuntimeName
        case dxmtLibDirPath, dxmtRuntimeName, retinaMode
    }

    /// Tolerant decode (mirrors `AppState`): every field defaults if absent, so adding one never makes an
    /// old `config.json` undecodable — which would otherwise discard the whole document on load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wineBinaryPath = try c.decodeIfPresent(URL.self, forKey: .wineBinaryPath)
        wineRuntimeName = try c.decodeIfPresent(String.self, forKey: .wineRuntimeName)
        gptkLibDirPath = try c.decodeIfPresent(URL.self, forKey: .gptkLibDirPath)
        gptkRuntimeName = try c.decodeIfPresent(String.self, forKey: .gptkRuntimeName)
        dxmtLibDirPath = try c.decodeIfPresent(URL.self, forKey: .dxmtLibDirPath)
        dxmtRuntimeName = try c.decodeIfPresent(String.self, forKey: .dxmtRuntimeName)
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }

    /// The lib dir overlaid for a given backend — the single place that maps a `GraphicsBackend` to its
    /// configured runtime modules, so `makePlan` and the linker never hard-code one backend's path.
    public func libDir(for backend: GraphicsBackend) -> URL? {
        switch backend {
        case .gptk: gptkLibDirPath
        case .dxmt: dxmtLibDirPath
        }
    }
}
