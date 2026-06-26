import Foundation

/// Global runtime configuration: where the Master Steam bottle and the wine/GPTK binaries live.
public struct BackendConfig: Codable, Sendable, Hashable {
    /// Master Steam bottle root (the parent of `drive_c`) — the simple downloader bottle.
    public var masterBottlePath: URL?
    /// Primary wine binary used to launch games (GPTK build).
    public var wineBinaryPath: URL?
    /// Fallback wine binary (CrossOver).
    public var crossoverWinePath: URL?
    /// Directory containing GPTK / D3DMetal libraries to inject into game prefixes.
    public var gptkLibDirPath: URL?
    /// Directory containing DXVK DLLs (`dxgi.dll`, `d3d11.dll`) for the CrossOver/DXVK backend.
    public var dxvkDLLDirPath: URL?
    /// How this config was discovered.
    public var detectedSource: DetectedSource

    public enum DetectedSource: String, Codable, Sendable {
        case whisky, kegworks, crossover, manual, none
    }

    public init(
        masterBottlePath: URL? = nil,
        wineBinaryPath: URL? = nil,
        crossoverWinePath: URL? = nil,
        gptkLibDirPath: URL? = nil,
        dxvkDLLDirPath: URL? = nil,
        detectedSource: DetectedSource = .none
    ) {
        self.masterBottlePath = masterBottlePath
        self.wineBinaryPath = wineBinaryPath
        self.crossoverWinePath = crossoverWinePath
        self.gptkLibDirPath = gptkLibDirPath
        self.dxvkDLLDirPath = dxvkDLLDirPath
        self.detectedSource = detectedSource
    }

    /// Steam install root inside the Master bottle, if configured.
    public var steamRoot: URL? {
        masterBottlePath.map { DiscoveryEngine.steamRoot(inBottle: $0) }
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }

    /// Whether the library can be discovered (a Master bottle is set).
    public var isMasterBottleConfigured: Bool { masterBottlePath != nil }

    /// The wine binary to use for a backend, falling back to the primary when a specific one is unset.
    public func wineBinary(for backend: GraphicsBackend) -> URL? {
        switch backend {
        case .gptk: wineBinaryPath ?? crossoverWinePath
        case .crossover: crossoverWinePath ?? wineBinaryPath
        }
    }
}
