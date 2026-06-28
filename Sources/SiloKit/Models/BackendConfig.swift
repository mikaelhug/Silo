import Foundation

/// Global runtime configuration: where the wine/GPTK binaries live and the signed-in Steam account.
public struct BackendConfig: Codable, Sendable, Hashable {
    /// Primary wine binary used to launch games (GPTK build).
    public var wineBinaryPath: URL?
    /// Name of the default Wine install (managed in the Wine Manager).
    public var wineRuntimeName: String?
    /// Directory containing GPTK / D3DMetal libraries, overlaid into the wine runtime's `lib/wine` tree
    /// by `GraphicsLinker.overlayGPTK`.
    public var gptkLibDirPath: URL?
    /// Name of the default GPTK install (managed in the GPTK Manager).
    public var gptkRuntimeName: String?
    /// How this config was discovered.
    public var detectedSource: DetectedSource

    public enum DetectedSource: String, Codable, Sendable {
        case whisky, kegworks, crossover, manual, none
    }

    public init(
        wineBinaryPath: URL? = nil,
        wineRuntimeName: String? = nil,
        gptkLibDirPath: URL? = nil,
        gptkRuntimeName: String? = nil,
        detectedSource: DetectedSource = .none
    ) {
        self.wineBinaryPath = wineBinaryPath
        self.wineRuntimeName = wineRuntimeName
        self.gptkLibDirPath = gptkLibDirPath
        self.gptkRuntimeName = gptkRuntimeName
        self.detectedSource = detectedSource
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }
}
