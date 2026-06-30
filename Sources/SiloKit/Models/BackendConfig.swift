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
    /// macOS Retina/HiDPI mode for the shared Steam bottle (`HKCU\Software\Wine\Mac Driver\RetinaMode`).
    /// Mirrors what Silo last wrote to the prefix; off is Wine's default. See `WineTools.setRetinaMode`.
    public var retinaMode: Bool

    public init(
        wineBinaryPath: URL? = nil,
        wineRuntimeName: String? = nil,
        gptkLibDirPath: URL? = nil,
        gptkRuntimeName: String? = nil,
        retinaMode: Bool = false
    ) {
        self.wineBinaryPath = wineBinaryPath
        self.wineRuntimeName = wineRuntimeName
        self.gptkLibDirPath = gptkLibDirPath
        self.gptkRuntimeName = gptkRuntimeName
        self.retinaMode = retinaMode
    }

    private enum CodingKeys: String, CodingKey {
        case wineBinaryPath, wineRuntimeName, gptkLibDirPath, gptkRuntimeName, retinaMode
    }

    /// Tolerant decode (mirrors `AppState`): every field defaults if absent, so adding one never makes an
    /// old `config.json` undecodable — which would otherwise discard the whole document on load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wineBinaryPath = try c.decodeIfPresent(URL.self, forKey: .wineBinaryPath)
        wineRuntimeName = try c.decodeIfPresent(String.self, forKey: .wineRuntimeName)
        gptkLibDirPath = try c.decodeIfPresent(URL.self, forKey: .gptkLibDirPath)
        gptkRuntimeName = try c.decodeIfPresent(String.self, forKey: .gptkRuntimeName)
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }
}
